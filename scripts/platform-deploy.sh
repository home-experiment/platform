#!/usr/bin/env bash
# Activates a release of one app on the shared VM. The CI deploy job runs it
# through "sudo /usr/local/bin/deploy-<app>" (written by platform-sync.sh); an
# operator can run it as root directly.
#
#   platform-deploy.sh --app NAME activate gs://<releases bucket>/NAME/<release>.tar.gz
#   platform-deploy.sh --app NAME rollback   point current at the previous release and restart
#   platform-deploy.sh --app NAME status     show the current release and the PM2 process list
#   platform-deploy.sh --help                this text
#
# It runs in two phases. The root phase checks the arguments, the URL and the
# app's metadata, runs platform-sync.sh from /, and for activate stages the
# release: it downloads the tarball to STAGING_DIR/NAME/release.tar.gz and the
# secret NAME-env to STAGING_DIR/NAME/app.env (directory 750, files 640, group
# app-NAME, so no other app can read them). gcloud runs only here, as root. It
# then runs the app phase as the app's own Linux user app-NAME (HOME
# HOME_BASE/app-NAME) and removes the staging directory when that ends, whether
# it succeeded or not. The app phase never calls gcloud and cannot reach the
# metadata server; it gets the app's metadata from the root phase. activate
# unpacks the staged release into /srv/NAME/releases/<release>, copies the
# staged config to /srv/NAME/shared/app.env, makes the links in the release's
# .platform/links, runs .platform/pre-start, switches current, restarts the
# release's ecosystem.config.cjs in the user's PM2 and checks
# http://127.0.0.1:<port><health_path> from the app's metadata; when that fails
# it rolls back to the previous release.
#
# Knobs (environment): SRV_DIR (/srv), HOME_BASE (/home), STAGING_DIR
# (/run/platform), KEEP_RELEASES (5), HEALTH_TIMEOUT seconds (30),
# HEALTH_INTERVAL seconds (2), PLATFORM_SYNC (the sync script), and those of
# platform-common.sh.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=platform-common.sh
. "$LIB_DIR/platform-common.sh"

SRV_DIR="${SRV_DIR:-/srv}"
HOME_BASE="${HOME_BASE:-/home}"
STAGING_DIR="${STAGING_DIR:-/run/platform}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"
PLATFORM_SYNC="${PLATFORM_SYNC:-$LIB_DIR/platform-sync.sh}"
RELEASE_RE='^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$'
LINK_PATH_RE='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

APP="" CMD="" URL="" APP_JSON="" RELEASES="" SHARED="" CURRENT="" STAGING_PATH=""

usage(){ awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

parse_args(){
  case "${1:-}" in -h|--help) usage; exit 0 ;; esac
  if [ "${1:-}" != --app ] || [ -z "${2:-}" ]; then
    die "usage: platform-deploy.sh --app NAME activate URL|rollback|status (see --help)"
  fi
  APP="$2"
  CMD="${3:-}"
  [[ "$APP" =~ $APP_NAME_RE ]] || die "bad app name: '$APP'"
  case "$CMD" in
    activate) [ "$#" -eq 4 ] || die "activate takes one release URL"; URL="$4" ;;
    rollback|status) [ "$#" -eq 3 ] || die "$CMD takes no arguments" ;;
    *) die "unknown command: '$CMD' (see --help)" ;;
  esac
}

# release_name <url>: the release name when url is a tarball directly in this
# app's folder of the releases bucket; fails otherwise.
release_name(){
  local prefix="gs://$RELEASES_BUCKET/$APP/" rest
  case "$1" in "$prefix"*) ;; *) return 1 ;; esac
  rest="${1#"$prefix"}"
  [[ "$rest" == *.tar.gz ]] || return 1
  rest="${rest%.tar.gz}"
  [[ "$rest" =~ $RELEASE_RE ]] || return 1
  echo "$rest"
}

check_url(){
  release_name "$URL" >/dev/null \
    || die "not a release of $APP: $URL (expected gs://$RELEASES_BUCKET/$APP/<release>.tar.gz)"
}

# stage <dir>: downloads the release and the config into dir, readable by the
# app's group only. Dies (after removing dir) when a step fails.
stage(){
  local dir="$1" group
  group="$(app_user "$APP")"
  rm -rf "$dir"
  if ! { mkdir -p "$dir" && chmod 755 "$(dirname "$dir")" && chmod 750 "$dir" && chgrp "$group" "$dir"; }; then
    rm -rf "$dir"
    die "cannot create $dir"
  fi
  log "Downloading $URL"
  if ! gcloud storage cp "$URL" "$dir/release.tar.gz"; then
    rm -rf "$dir"
    die "cannot download $URL"
  fi
  log "Fetching the config ($APP-env)"
  if ! (umask 027 && gcloud secrets versions access latest --secret="$APP-env" > "$dir/app.env"); then
    rm -rf "$dir"
    die "cannot read the secret $APP-env"
  fi
  if ! { chgrp "$group" "$dir/release.tar.gz" "$dir/app.env" && chmod 640 "$dir/release.tar.gz" "$dir/app.env"; }; then
    rm -rf "$dir"
    die "cannot hand $dir to $group"
  fi
}

# as_root: sync the VM, stage what the app user cannot fetch, then continue as
# the app user.
# The app's metadata goes along to the app phase because the app user cannot
# reach the metadata server.
as_root(){
  local user rc=0
  local -a app_phase
  STAGING_PATH="$STAGING_DIR/$APP"
  if [ "$CMD" = activate ]; then check_url; fi
  APP_JSON="$(app_json "$APP")"
  [ -n "$APP_JSON" ] || die "no valid vm-app-$APP in the project metadata"
  cd /
  "$PLATFORM_SYNC" || warn "platform-sync reported problems (see above); continuing"
  user="$(app_user "$APP")"
  app_phase=(runuser -u "$user" -- env HOME="$HOME_BASE/$user" PLATFORM_SWITCHED=1
    PLATFORM_APP_JSON="$APP_JSON" bash "$LIB_DIR/platform-deploy.sh" --app "$APP")
  if [ "$CMD" != activate ]; then
    exec "${app_phase[@]}" "$CMD"
  fi
  trap 'rm -rf "$STAGING_PATH"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  stage "$STAGING_PATH"
  "${app_phase[@]}" activate "$URL" || rc=$?
  rm -rf "$STAGING_PATH"
  exit "$rc"
}

current_target(){
  if [ -L "$CURRENT" ]; then readlink "$CURRENT"; fi
}

# Release directories, newest first (by mtime; activate touches the directory,
# so the mtime is the activation time).
releases_newest_first(){
  # shellcheck disable=SC2012 # release names match RELEASE_RE, no odd characters
  ls -1dt "$RELEASES"/*/ 2>/dev/null | sed 's:/$::'
}

# The newest release older than the one current points at.
previous_release(){
  local target found=0 dir
  target="$(current_target)"
  while IFS= read -r dir; do
    if [ "$found" = 1 ]; then
      echo "$dir"
      return 0
    fi
    if [ "$dir" = "$target" ]; then found=1; fi
  done < <(releases_newest_first)
  return 1
}

switch_current(){
  ln -sfn "$1" "$CURRENT"
}

# The ecosystem file resolves cwd from its real path, so a plain restart would
# keep the old release; delete and start picks up the new one. Deleting by the
# app's PM2 namespace also stops processes the new release no longer declares.
restart(){
  pm2 delete "$APP" >/dev/null 2>&1 || true
  pm2 start "$CURRENT/ecosystem.config.cjs" || return 1
  pm2 save || return 1
}

healthy(){
  local port path deadline=$((SECONDS + HEALTH_TIMEOUT))
  port="$(jq -r .port <<<"$APP_JSON")"
  path="$(jq -r .health_path <<<"$APP_JSON")"
  while true; do
    if curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$port$path"; then
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then return 1; fi
    sleep "$HEALTH_INTERVAL"
  done
}

# install_config: copies the config the root phase staged to shared/app.env.
install_config(){
  local staged="$STAGING_DIR/$APP/app.env"
  [ -f "$staged" ] || die "no staged config for $APP"
  log "Installing the config ($APP-env)"
  rm -f "$SHARED/app.env.tmp"
  (umask 077 && cp "$staged" "$SHARED/app.env.tmp") || die "cannot copy the staged config for $APP"
  mv "$SHARED/app.env.tmp" "$SHARED/app.env"
}

safe_link_path(){
  [[ "$1" =~ $LINK_PATH_RE ]] && [[ "/$1/" != */../* ]] && [[ "/$1/" != */./* ]]
}

# link_shared <release dir>: makes the links listed in .platform/links.
link_shared(){
  local dir="$1" src dst rest
  mkdir -p "$SHARED/logs"
  [ -f "$dir/.platform/links" ] || return 0
  while read -r src dst rest || [ -n "${src:-}" ]; do
    case "$src" in ''|'#'*) continue ;; esac
    if [ -z "${dst:-}" ] || [ -n "${rest:-}" ]; then
      die ".platform/links: expected '<shared path> <release path>', got '$src ${dst:-} ${rest:-}'"
    fi
    if ! safe_link_path "$src" || ! safe_link_path "$dst"; then
      die ".platform/links: unsafe path in '$src $dst'"
    fi
    mkdir -p "$(dirname "$dir/$dst")"
    rm -rf "${dir:?}/$dst"
    ln -sfn "$SHARED/$src" "$dir/$dst"
  done < "$dir/.platform/links"
}

pre_start(){
  local dir="$1" previous="$2"
  [ -e "$dir/.platform/pre-start" ] || return 0
  log "Running .platform/pre-start"
  (cd "$dir" && ./.platform/pre-start) || die "pre-start failed; current still points at ${previous:-nothing}"
}

prune(){
  local target n=0 dir
  target="$(current_target)"
  while IFS= read -r dir; do
    n=$((n + 1))
    if [ "$n" -gt "$KEEP_RELEASES" ] && [ "$dir" != "$target" ]; then
      rm -rf "$dir"
    fi
  done < <(releases_newest_first)
}

unpack(){
  local release="$1" dir="$2" incoming="$RELEASES/.incoming-$1"
  log "Unpacking $release"
  rm -rf "$incoming"
  mkdir -p "$incoming"
  if ! tar -xzf "$STAGING_DIR/$APP/release.tar.gz" -C "$incoming"; then
    rm -rf "$incoming"
    die "cannot unpack $URL"
  fi
  if [ ! -f "$incoming/ecosystem.config.cjs" ]; then
    rm -rf "$incoming"
    die "$URL has no ecosystem.config.cjs at its root"
  fi
  rm -rf "$dir"
  mv "$incoming" "$dir"
  touch "$dir"
}

activate(){
  local release dir previous
  check_url
  release="$(release_name "$URL")"
  dir="$RELEASES/$release"
  previous="$(current_target)"
  [ "$previous" != "$dir" ] || die "release $release is already live"

  unpack "$release" "$dir"
  install_config
  link_shared "$dir"
  pre_start "$dir" "$previous"

  log "Activating $release"
  switch_current "$dir"

  if ! restart || ! healthy; then
    if [ -n "$previous" ] && [ "$previous" != "$dir" ]; then
      echo "health check failed; rolling back to $(basename "$previous")" >&2
      switch_current "$previous"
      if restart && healthy; then
        die "health check failed; rolled back to $(basename "$previous"), which is healthy"
      fi
      die "health check failed; rolled back to $(basename "$previous"), which is NOT healthy either"
    fi
    die "health check failed"
  fi

  prune
  log "Release $release of $APP is live"
}

rollback(){
  local previous
  previous="$(previous_release)" || die "no older release to roll back to"
  switch_current "$previous"
  restart
  log "Rolled back $APP to $(basename "$previous")"
}

status(){
  echo "current: $(current_target)"
  pm2 status
}

main(){
  parse_args "$@"
  load_conf
  if [ "$(id -u)" = 0 ] && [ "${PLATFORM_SWITCHED:-}" != 1 ]; then
    as_root
  fi
  # Run as the app user by the root phase, which passes the app's metadata; run
  # directly (an operator as the app user), it reads the metadata itself.
  APP_JSON="${PLATFORM_APP_JSON:-}"
  [ -n "$APP_JSON" ] || APP_JSON="$(app_json "$APP")"
  [ -n "$APP_JSON" ] || die "no valid vm-app-$APP in the project metadata"
  RELEASES="$SRV_DIR/$APP/releases"
  SHARED="$SRV_DIR/$APP/shared"
  CURRENT="$SRV_DIR/$APP/current"
  # The caller's directory (root's home under sudo) may not be readable by the
  # app user, and PM2 fails to spawn its daemon there.
  cd "$SRV_DIR/$APP" 2>/dev/null || cd /
  case "$CMD" in
    activate) activate ;;
    rollback) rollback ;;
    status) status ;;
  esac
}

main "$@"
