#!/usr/bin/env bash
# Tests for scripts/platform-restore.sh. gcloud and mariadb are stubs: gcloud
# lists and copies objects from a temp directory standing in for the backups
# bucket, mariadb answers the table count from TABLES_<db> and records what is
# loaded.
#
#   bash scripts/tests/platform-restore.test.sh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ORIG_PATH="$PATH"
FAILURES=0
WORK=""

fail(){ echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

assert_eq(){
  if [ "$1" != "$2" ]; then
    fail "$3: expected '$2', got '$1'"
  fi
}

stub(){
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n%s\n' "$1" "$2" > "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}

setup(){
  WORK="$(mktemp -d)"
  export PLATFORM_METADATA_FILE="$WORK/metadata.json" PLATFORM_CONF="$WORK/platform.conf"
  export MYSQL_DEFAULTS="$WORK/no-login-file" STUB_LOG="$WORK/calls.log" BUCKET="$WORK/bucket"
  export LOADED="$WORK/loaded" MARIADB_BAD="" BACKUP_TMP_DIR="$WORK/tmp"
  mkdir -p "$BACKUP_TMP_DIR" "$BUCKET" "$LOADED" "$WORK/bin"
  printf 'RELEASES_BUCKET=rel\nBACKUPS_BUCKET=bak\n' > "$PLATFORM_CONF"
  jq -cn '{
    "vm-app-demo": ({name: "demo", port: 4100, domains: ["demo.example.com"], db: "demo_db", deploy_user: "sa_1"} | tojson),
    "vm-app-other": ({name: "other", port: 4200, domains: ["other.example.com"], db: "other_db", deploy_user: "sa_2"} | tojson),
    "vm-app-nodb": ({name: "nodb", port: 4300, domains: ["nodb.example.com"], deploy_user: "sa_3"} | tojson)
  }' > "$PLATFORM_METADATA_FILE"
  touch "$STUB_LOG"
  # gs://bak/<path> is $BUCKET/<path>; ls behaves like gcloud on an empty folder.
  stub gcloud 'case "$2" in
  ls)
    dir="$BUCKET/${3#gs://bak/}"
    [ -n "$(ls -A "$dir" 2>/dev/null)" ] || { echo "ERROR: (gcloud.storage.ls) One or more URLs matched no objects." >&2; exit 1; }
    for f in "$dir"*; do echo "$3$(basename "$f")"; done ;;
  cp)
    cp "$BUCKET/${3#gs://bak/}" "$4" ;;
esac'
  stub mariadb 'db="${!#}"
case " $* " in *" -e "*) ;; *)
  case " $MARIADB_BAD " in *" $db "*) cat > /dev/null; exit 1 ;; esac
  cat > "$LOADED/$db"
  exit 0 ;;
esac
schema="$(echo "$*" | sed -n "s/.*table_schema = .\([a-z_]*\).*/\1/p")"
var="TABLES_$schema"
echo "${!var:-0}"'
  export PATH="$WORK/bin:$ORIG_PATH"
}

teardown(){
  export PATH="$ORIG_PATH"
  unset TABLES_demo_db TABLES_other_db
  rm -rf "$WORK"
}

run_restore(){ bash "$SCRIPTS/platform-restore.sh" "$@" > "$WORK/out.log" 2>&1; }

# put <app> <file> <content>: stores a gzipped dump with mariadb-dump's closing
# line in the fake bucket.
put(){
  mkdir -p "$BUCKET/$1"
  printf '%s\n-- Dump completed on 2026-10-01  4:30:00\n' "$3" | gzip > "$BUCKET/$1/$2"
}

# loaded <db>: the first line loaded into the database (the content given to put).
loaded(){ head -n 1 "$LOADED/$1" 2>/dev/null || true; }

test_latest_picks_newest_matching(){
  put demo demo-2026-10-01-043000.sql.gz "-- old"
  put demo demo-2026-10-03-043000.sql.gz "-- newest"
  put demo demo-2026-10-02-043000.sql.gz "-- middle"
  put demo demo-2026-12-31-235959.sql.gz.tmp "-- not a backup"
  put demo other-2026-12-31-235959.sql.gz "-- another app's name"
  put demo zz-latest.sql.gz "-- not a backup"
  run_restore --app demo latest || fail "restore exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(loaded demo_db)" "-- newest" "restored content"
  assert_eq "$(ls -A "$BACKUP_TMP_DIR")" "" "temp file left behind"
}

test_url_restores_that_backup(){
  put demo demo-2026-10-01-043000.sql.gz "-- old"
  put demo demo-2026-10-03-043000.sql.gz "-- newest"
  run_restore --app demo gs://bak/demo/demo-2026-10-01-043000.sql.gz || fail "restore exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(loaded demo_db)" "-- old" "restored content"
}

test_url_rejected(){
  put other other-2026-10-01-043000.sql.gz "-- other"
  put demo other-2026-10-01-043000.sql.gz "-- other"
  local url
  for url in gs://bak/other/other-2026-10-01-043000.sql.gz \
    gs://bak/demo/other-2026-10-01-043000.sql.gz \
    gs://elsewhere/demo/demo-2026-10-01-043000.sql.gz \
    gs://bak/demo/demo-2026-10-01.sql.gz \
    gs://bak/demo/sub/demo-2026-10-01-043000.sql.gz \
    gs://bak/demo/demo-2026-10-01-043000.sql.gz.tmp \
    $'gs://bak/demo/demo-2026-10-01-043000.sql.gz\nx' \
    'gs://bak/demo/demo-2026-10-0*-043000.sql.gz'; do
    if run_restore --app demo "$url"; then fail "accepted $url"; fi
    grep -q "not a backup of demo" "$WORK/out.log" || fail "no message for $url"
  done
  assert_eq "$(ls -A "$LOADED")" "" "something was loaded"
  if grep -q "gcloud storage cp" "$STUB_LOG"; then fail "rejected URL downloaded"; fi
}

test_non_empty_db_needs_force(){
  put demo demo-2026-10-01-043000.sql.gz "-- dump"
  export TABLES_demo_db=4
  if run_restore --app demo latest; then fail "restored over existing tables"; fi
  grep -q "demo_db already has 4 table(s)" "$WORK/out.log" || fail "no refusal message"
  assert_eq "$(loaded demo_db)" "" "loaded without --force"
  if grep -q "gcloud storage cp" "$STUB_LOG"; then fail "downloaded without --force"; fi
  run_restore --app demo latest --force || fail "--force restore exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(loaded demo_db)" "-- dump" "restored with --force"
}

test_no_backup_for_app(){
  if run_restore --app demo latest; then fail "restore without a backup must fail"; fi
  grep -q "no backup of demo" "$WORK/out.log" || fail "no message"
}

test_unknown_app(){
  if run_restore --app ghost latest; then fail "unknown app accepted"; fi
  grep -q "no valid vm-app-ghost" "$WORK/out.log" || fail "no message for unknown app"
  if run_restore --app nodb latest; then fail "app without a database accepted"; fi
  grep -q "nodb has no database" "$WORK/out.log" || fail "no message for app without db"
  if run_restore --app 'Bad!' latest; then fail "bad app name accepted"; fi
  grep -q "bad app name: 'Bad!'" "$WORK/out.log" || fail "no message for bad app name"
}

test_bad_dump_fails(){
  mkdir -p "$BUCKET/demo"
  echo "not gzip" > "$BUCKET/demo/demo-2026-10-01-043000.sql.gz"
  if run_restore --app demo latest; then fail "corrupt dump accepted"; fi
  assert_eq "$(loaded demo_db)" "" "corrupt dump loaded"
  assert_eq "$(ls -A "$BACKUP_TMP_DIR")" "" "temp file left behind after failure"
}

test_truncated_dump_fails(){
  mkdir -p "$BUCKET/demo"
  printf -- '-- dump\nINSERT INTO t VALUES (1);\n' | gzip > "$BUCKET/demo/demo-2026-10-01-043000.sql.gz"
  if run_restore --app demo latest; then fail "dump without the completion line accepted"; fi
  grep -q "not a complete mariadb-dump" "$WORK/out.log" || fail "no message: $(cat "$WORK/out.log")"
  assert_eq "$(loaded demo_db)" "" "truncated dump loaded"
}

test_load_failure_says_force(){
  put demo demo-2026-10-01-043000.sql.gz "-- dump"
  export MARIADB_BAD=demo_db
  if run_restore --app demo latest; then fail "failed load reported success"; fi
  grep -q "demo_db may be partly loaded, so a rerun needs --force" "$WORK/out.log" || fail "no --force hint: $(cat "$WORK/out.log")"
}

test_login_file_reaches_load(){
  put demo demo-2026-10-01-043000.sql.gz "-- dump"
  touch "$MYSQL_DEFAULTS"
  run_restore --app demo latest || fail "restore exited non-zero: $(cat "$WORK/out.log")"
  grep -qx "mariadb --defaults-extra-file=$MYSQL_DEFAULTS demo_db" "$STUB_LOG" || fail "load without the login file: $(cat "$STUB_LOG")"
}

test_all_skips_and_reports(){
  put demo demo-2026-10-01-043000.sql.gz "-- demo"
  if run_restore --all latest; then :; else fail "--all with one app lacking backups must succeed: $(cat "$WORK/out.log")"; fi
  assert_eq "$(loaded demo_db)" "-- demo" "demo restored"
  grep -q "no backup of other; skipped" "$WORK/out.log" || fail "no skip warning"
  grep -q "Restored: demo; skipped (no backup): other; failed: none" "$WORK/out.log" || fail "summary: $(cat "$WORK/out.log")"
}

test_all_failure_exits_non_zero(){
  put demo demo-2026-10-01-043000.sql.gz "-- demo"
  put other other-2026-10-01-043000.sql.gz "-- other"
  export MARIADB_BAD=demo_db
  if run_restore --all latest; then fail "--all must fail when one app fails"; fi
  assert_eq "$(loaded other_db)" "-- other" "other app not restored after a failure"
  grep -q "restore of demo failed" "$WORK/out.log" || fail "no failure message"
  grep -q "failed: demo" "$WORK/out.log" || fail "summary: $(cat "$WORK/out.log")"
}

test_bad_arguments(){
  if run_restore --all gs://bak/demo/demo-2026-10-01-043000.sql.gz; then fail "--all accepted a URL"; fi
  if run_restore --app demo; then fail "missing source accepted"; fi
  if run_restore --app demo --all latest; then fail "--app with --all accepted"; fi
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "$t"
  setup
  "$t"
  teardown
done

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)"
  exit 1
fi
echo "all tests passed"
