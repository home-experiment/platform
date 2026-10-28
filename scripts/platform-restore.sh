#!/usr/bin/env bash
# Restores app databases from the dumps platform-backup.sh writes to
# gs://<backups bucket>/<name>/<name>-YYYY-MM-DD-HHMMSS.sql.gz. Meant for a fresh
# VM after a region move, where startup created empty databases. Run as root.
#
#   platform-restore --app NAME latest       the newest backup of NAME
#   platform-restore --app NAME gs://<backups bucket>/NAME/NAME-YYYY-MM-DD-HHMMSS.sql.gz
#   platform-restore --all latest            the newest backup of every app with a database
#   platform-restore --help                  this text
#   add --force to restore into a database that already has tables
#
# A database that already has tables is left alone unless --force is given. The
# dump is downloaded and checked before anything is written; it holds no CREATE
# DATABASE or USE (platform-backup dumps one database), so it is loaded into
# the app's own database from its metadata. --all goes on past an app that
# fails, skips an app without backups and exits non-zero when any app failed.
#
# Knobs (environment): BACKUP_TMP_DIR (where the dump is downloaded, default
# /var/tmp), plus those of platform-common.sh.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=platform-common.sh
. "$LIB_DIR/platform-common.sh"

BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-/var/tmp}"
BACKUP_NAME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.sql\.gz$'
# Exit code of restore_app when the app has no backup (skipped by --all).
NO_BACKUP=3

APP="" ALL=0 SOURCE="" FORCE=0 DUMP=""
trap 'rm -f "$DUMP"' EXIT
trap 'exit 1' TERM INT

usage(){ awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

parse_args(){
  local usage_line="usage: platform-restore --app NAME latest|URL | --all latest [--force] (see --help)"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --force) FORCE=1 ;;
      --all) ALL=1 ;;
      --app) [ -n "${2:-}" ] || die "$usage_line"; APP="$2"; shift ;;
      *) [ -z "$SOURCE" ] || die "$usage_line"; SOURCE="$1" ;;
    esac
    shift
  done
  if [ "$ALL" = 1 ]; then
    [ -z "$APP" ] || die "--app and --all exclude each other"
    [ "$SOURCE" = latest ] || die "--all takes only 'latest'"
  else
    [ -n "$APP" ] && [ -n "$SOURCE" ] || die "$usage_line"
    [[ "$APP" =~ $APP_NAME_RE ]] || die "bad app name: '$APP'"
  fi
}

# is_backup <name> <url>: true when url is a backup file directly in the app's
# folder of the backups bucket.
is_backup(){
  local prefix="gs://$BACKUPS_BUCKET/$1/$1-" rest
  case "$2" in "$prefix"*) ;; *) return 1 ;; esac
  rest="${2#"$prefix"}"
  [[ "$rest" =~ $BACKUP_NAME_RE ]]
}

# latest_backup <name>: the URL of the newest backup of the app, or nothing when
# there is none. The timestamp in the name sorts lexicographically.
latest_backup(){
  local name="$1" listing url
  if ! listing="$(gcloud storage ls "gs://$BACKUPS_BUCKET/$name/" 2>&1)"; then
    # gcloud fails on an empty folder; that is "no backup", anything else an error.
    grep -q "matched no objects" <<<"$listing" && return 0
    echo "$listing" >&2
    return 1
  fi
  while IFS= read -r url; do
    if is_backup "$name" "$url"; then echo "$url"; fi
  done <<<"$listing" | sort | tail -n 1
}

# table_count <db>: the number of tables in the database (0 when it does not exist).
table_count(){
  mariadb_cmd mariadb -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$1'"
}

# restore_app <name> <latest|url>: restores the app's database. Returns 1 on
# failure and NO_BACKUP when "latest" finds no backup.
restore_app(){
  local name="$1" source="$2" app db url tables
  app="$(app_json "$name")" || { warn "cannot read the project metadata"; return 1; }
  if [ -z "$app" ]; then warn "no valid vm-app-$name in the project metadata"; return 1; fi
  db="$(jq -r .db <<<"$app")"
  if [ -z "$db" ]; then warn "$name has no database"; return 1; fi
  if [ "$source" = latest ]; then
    url="$(latest_backup "$name")" || { warn "cannot list the backups of $name"; return 1; }
    [ -n "$url" ] || return "$NO_BACKUP"
  else
    url="$source"
    if ! is_backup "$name" "$url"; then
      warn "not a backup of $name: $url (expected gs://$BACKUPS_BUCKET/$name/$name-YYYY-MM-DD-HHMMSS.sql.gz)"
      return 1
    fi
  fi
  tables="$(table_count "$db")" || { warn "cannot read the tables of $db"; return 1; }
  if [ "$tables" != 0 ] && [ "$FORCE" != 1 ]; then
    warn "$db already has $tables table(s); add --force to restore over them"
    return 1
  fi
  log "Restoring $name ($db) from $url"
  DUMP="$(mktemp "$BACKUP_TMP_DIR/restore.XXXXXX")" || { warn "cannot create a file in $BACKUP_TMP_DIR"; return 1; }
  local rc=0
  if ! gcloud storage cp "$url" "$DUMP"; then
    warn "cannot download $url"
    rc=1
  elif ! gzip -t "$DUMP"; then
    warn "$url is not a valid gzip file"
    rc=1
  elif ! gunzip -c "$DUMP" | mariadb_cmd mariadb "$db"; then
    warn "loading $url into $db failed"
    rc=1
  fi
  rm -f "$DUMP"
  return "$rc"
}

restore_all(){
  local apps app name rc restored="" skipped="" failed=""
  apps="$(valid_apps)" || die "cannot read the project metadata"
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    name="$(jq -r .name <<<"$app")"
    [ -n "$(jq -r .db <<<"$app")" ] || continue
    rc=0
    restore_app "$name" latest || rc=$?
    case "$rc" in
      0) restored+=" $name" ;;
      "$NO_BACKUP") warn "no backup of $name; skipped"; skipped+=" $name" ;;
      *) warn "restore of $name failed"; failed+=" $name" ;;
    esac
  done <<<"$apps"
  log "Restored:${restored:- none}; skipped (no backup):${skipped:- none}; failed:${failed:- none}"
  [ -z "$failed" ]
}

main(){
  local rc=0
  parse_args "$@"
  load_conf
  if [ "$ALL" = 1 ]; then
    restore_all || exit 1
    exit 0
  fi
  restore_app "$APP" "$SOURCE" || rc=$?
  case "$rc" in
    0) ;;
    "$NO_BACKUP") die "no backup of $APP under gs://$BACKUPS_BUCKET/$APP/" ;;
    *) die "restore of $APP failed" ;;
  esac
}

main "$@"
