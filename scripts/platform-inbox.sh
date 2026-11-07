#!/usr/bin/env bash
# Copies the top-level files of each vm-app's inbox bucket onto the VM. For an
# app with inbox_bucket: gcloud storage rsync mirrors gs://<bucket> into
# INBOX_STAGING_DIR/<name> (root only, 700), then every staged file that is new
# or changed is published into INBOX_DIR/<name> (root:app-<name>, 750; files
# root:app-<name>, 640) under a temporary name and renamed into place, so the
# app never reads a half-written file; files that left the bucket are removed.
# A failed rsync leaves the published inbox as it was. Inbox and staging
# directories of apps that are gone or have no inbox_bucket are deleted; an
# invalid app keeps what it had. Run as root by platform-inbox.service (timer,
# every 5 minutes). One app failing does not stop the others; the exit code is
# non-zero when any app failed.
#
# Root never writes through a path the app user controls: both trees are owned
# by root and the app's group can only read them; anything in the way that is
# not a real directory or regular file (a symlink, say) is removed, never
# followed.
#
# Knobs (environment): INBOX_DIR (default /var/lib/platform/inbox),
# INBOX_STAGING_DIR (default /var/lib/platform/inbox-staging), plus those of
# platform-common.sh.
set -euo pipefail
shopt -s nullglob dotglob

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=platform-common.sh
. "$LIB_DIR/platform-common.sh"

INBOX_DIR="${INBOX_DIR:-/var/lib/platform/inbox}"
INBOX_STAGING_DIR="${INBOX_STAGING_DIR:-/var/lib/platform/inbox-staging}"
TMP_PREFIX=".tmp."

# real_dir <path> <owner:group> <mode>: makes <path> a real directory with that
# owner and mode; a symlink or file in its place is removed, not followed.
real_dir(){
  local path="$1" owner="$2" mode="$3"
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
    rm -f "$path" || return 1
  fi
  if [ ! -d "$path" ]; then
    mkdir "$path" || return 1
  fi
  chown "$owner" "$path" && chmod "$mode" "$path"
}

# regular <path>: true for a regular file that is not a symlink.
regular(){ [ -f "$1" ] && [ ! -L "$1" ]; }

# publish <name> <staging> <inbox>: copies new and changed staged files into the
# inbox via a temporary name, removes inbox entries not in staging, and logs the
# counts.
publish(){
  local name="$1" staging="$2" inbox="$3" group src file dst tmp entry
  local added=0 updated=0 removed=0
  group="$(app_user "$name")"
  for src in "$staging"/*; do
    regular "$src" || continue
    file="${src##*/}"
    if [[ "$file" == "$TMP_PREFIX"* ]]; then
      warn "$name: skipping $file (names starting with $TMP_PREFIX are reserved)"
      continue
    fi
    dst="$inbox/$file"
    tmp="$inbox/$TMP_PREFIX$file"
    if regular "$dst"; then
      cmp -s "$src" "$dst" && continue
      updated=$((updated + 1))
    else
      added=$((added + 1))
    fi
    rm -rf "$tmp" || return 1
    install -m 640 -o root -g "$group" "$src" "$tmp" || return 1
    if [ -L "$dst" ] || { [ -e "$dst" ] && [ ! -f "$dst" ]; }; then
      rm -rf "$dst" || return 1
    fi
    mv -f "$tmp" "$dst" || return 1
  done
  for entry in "$inbox"/*; do
    file="${entry##*/}"
    if [[ "$file" == "$TMP_PREFIX"* ]]; then
      rm -rf "$entry" || return 1
    elif ! regular "$staging/$file"; then
      rm -rf "$entry" || return 1
      removed=$((removed + 1))
    fi
  done
  log "$name: $added added, $updated updated, $removed removed"
}

# sync_inbox <name> <bucket>: mirrors the bucket into staging, then publishes.
sync_inbox(){
  local name="$1" bucket="$2"
  local staging="$INBOX_STAGING_DIR/$name" inbox="$INBOX_DIR/$name"
  real_dir "$staging" root:root 700 || return 1
  if ! gcloud storage rsync --delete-unmatched-destination-objects "gs://$bucket" "$staging"; then
    warn "$name: copying gs://$bucket failed; the inbox is unchanged"
    return 1
  fi
  real_dir "$inbox" "root:$(app_user "$name")" 750 || return 1
  publish "$name" "$staging" "$inbox"
}

# remove_unused <keep names> <base dir>: deletes the entries of <base dir> whose
# name is not in <keep names>; rm -rf removes a symlink without following it.
remove_unused(){
  local keep="$1" base="$2" entry name
  for entry in "$base"/*; do
    name="${entry##*/}"
    grep -qxF -- "$name" <<<"$keep" && continue
    log "Removing $entry (no inbox_bucket for $name)"
    rm -rf "$entry" || return 1
  done
}

main(){
  local present apps app name bucket keep failed=0
  load_conf
  present="$(present_apps)" || die "cannot read the project metadata"
  apps="$(valid_apps)" || die "cannot read the project metadata"
  mkdir -p "$(dirname "$INBOX_DIR")" "$(dirname "$INBOX_STAGING_DIR")"
  real_dir "$INBOX_DIR" root:root 755 || die "cannot prepare $INBOX_DIR"
  real_dir "$INBOX_STAGING_DIR" root:root 700 || die "cannot prepare $INBOX_STAGING_DIR"
  # Keep every present app (an invalid one keeps what it had) except valid apps
  # without a bucket.
  keep="$present"
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    name="$(jq -r .name <<<"$app")"
    bucket="$(jq -r .inbox_bucket <<<"$app")"
    if [ -z "$bucket" ]; then
      keep="$(grep -vxF -- "$name" <<<"$keep" || true)"
      continue
    fi
    if ! sync_inbox "$name" "$bucket"; then
      warn "inbox of $name failed"
      failed=1
    fi
  done <<<"$apps"
  remove_unused "$keep" "$INBOX_DIR" || failed=1
  remove_unused "$keep" "$INBOX_STAGING_DIR" || failed=1
  exit "$failed"
}

main "$@"
