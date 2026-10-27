#!/usr/bin/env bash
# Dumps the database of every vm-app that has one to
# gs://<backups bucket>/<name>/<name>-YYYY-MM-DD-HHMMSS.sql.gz. Run as root by
# platform-backup.service (nightly timer, 04:30 local time) or by hand with
# "sudo systemctl start platform-backup". One app failing does not stop the
# others; the exit code is non-zero when any backup failed.
#
# Knobs (environment): those of platform-common.sh.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=platform-common.sh
. "$LIB_DIR/platform-common.sh"

DUMP=""
trap 'rm -f "$DUMP"' EXIT

# backup <name> <db>: dumps to a temp file first so a failed dump never uploads
# a truncated backup.
backup(){
  local name="$1" db="$2"
  log "Backing up $name ($db)"
  DUMP="$(mktemp)"
  if ! mariadb_cmd mariadb-dump --single-transaction --routines "$db" | gzip > "$DUMP"; then
    rm -f "$DUMP"
    return 1
  fi
  gcloud storage cp "$DUMP" "gs://$BACKUPS_BUCKET/$name/$name-$(date +%F-%H%M%S).sql.gz" || {
    rm -f "$DUMP"
    return 1
  }
  rm -f "$DUMP"
}

main(){
  local apps app name db failed=0
  load_conf
  apps="$(valid_apps)" || die "cannot read the project metadata"
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    name="$(jq -r .name <<<"$app")"
    db="$(jq -r .db <<<"$app")"
    [ -n "$db" ] || continue
    if ! backup "$name" "$db"; then
      warn "backup of $name failed"
      failed=1
    fi
  done <<<"$apps"
  exit "$failed"
}

main "$@"
