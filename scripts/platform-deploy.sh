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
# As root it checks the arguments, runs platform-sync.sh, then runs itself again
# as APP_USER for the rest. activate unpacks the release into
# /srv/NAME/releases/<release>, writes the secret NAME-env to
# /srv/NAME/shared/app.env, makes the links in the release's .platform/links,
# runs .platform/pre-start, switches current, restarts the release's
# ecosystem.config.cjs in PM2 and checks http://127.0.0.1:<port><health_path>
# from the app's metadata; when that fails it rolls back to the previous release.
#
# Knobs (environment): SRV_DIR (/srv), APP_USER (app), KEEP_RELEASES (5),
# HEALTH_TIMEOUT seconds (30), HEALTH_INTERVAL seconds (2), PLATFORM_SYNC (the
# sync script), and those of platform-common.sh.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=platform-common.sh
. "$LIB_DIR/platform-common.sh"

SRV_DIR="${SRV_DIR:-/srv}"
APP_USER="${APP_USER:-app}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"
PLATFORM_SYNC="${PLATFORM_SYNC:-$LIB_DIR/platform-sync.sh}"
RELEASE_RE='^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$'
LINK_PATH_RE='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

APP="" CMD="" URL="" APP_JSON="" RELEASES="" SHARED="" CURRENT=""

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

# as_root: sync the VM, then continue as the app user.
as_root(){
  if [ "$CMD" = activate ]; then check_url; fi
  cd /
  "$PLATFORM_SYNC" || warn "platform-sync reported problems (see above); continuing"
  exec runuser -u "$APP_USER" -- env HOME="/home/$APP_USER" PLATFORM_SWITCHED=1 \
    bash "$LIB_DIR/platform-deploy.sh" --app "$APP" "$CMD" ${URL:+"$URL"}
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

fetch_config(){
  log "Fetching the config ($APP-env)"
  (
    umask 077
    gcloud secrets versions access latest --secret="$APP-env" > "$SHARED/app.env.tmp"
  ) || die "cannot read the secret $APP-env"
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
  if ! gcloud storage cat "$URL" | tar -xzf - -C "$incoming"; then
    rm -rf "$incoming"
    die "cannot download or unpack $URL"
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
  fetch_config
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
  APP_JSON="$(app_json "$APP")"
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
