#!/usr/bin/env bash
# Tests for scripts/platform-backup.sh. mariadb-dump and gcloud are stubs; the
# gcloud stub copies uploads into a temp directory.
#
#   bash scripts/tests/platform-backup.test.sh
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
  export MYSQL_DEFAULTS="$WORK/no-login-file" STUB_LOG="$WORK/calls.log" UPLOADS="$WORK/uploads"
  export DUMP_BAD="" GCLOUD_EXIT=0 BACKUP_TMP_DIR="$WORK/tmp"
  mkdir -p "$BACKUP_TMP_DIR"
  printf 'RELEASES_BUCKET=rel\nBACKUPS_BUCKET=bak\n' > "$PLATFORM_CONF"
  jq -cn '{
    "vm-app-demo": ({name: "demo", port: 4100, domains: ["demo.example.com"], db: "demo_db", deploy_user: "sa_1"} | tojson),
    "vm-app-other": ({name: "other", port: 4200, domains: ["other.example.com"], db: "other_db", deploy_user: "sa_2"} | tojson),
    "vm-app-nodb": ({name: "nodb", port: 4300, domains: ["nodb.example.com"], deploy_user: "sa_3"} | tojson)
  }' > "$PLATFORM_METADATA_FILE"
  mkdir -p "$WORK/bin" "$UPLOADS"
  touch "$STUB_LOG"
  stub mariadb-dump 'db="${!#}"
case " $DUMP_BAD " in *" $db "*) exit 2 ;; esac
echo "-- dump of $db"'
  stub gcloud 'echo "upload-from $3" >> "$STUB_LOG"
[ "$GCLOUD_EXIT" = 0 ] || exit "$GCLOUD_EXIT"
cp "$3" "$UPLOADS/$(echo "$4" | sed "s:^gs\://::; s:/:__:g")"'
  export PATH="$WORK/bin:$ORIG_PATH"
}

teardown(){
  export PATH="$ORIG_PATH"
  rm -rf "$WORK"
}

run_backup(){ bash "$SCRIPTS/platform-backup.sh" > "$WORK/out.log" 2>&1; }

# uploaded <app>: the uploaded object name for the app (bucket__app__file), or nothing.
uploaded(){ find "$UPLOADS" -name "bak__$1__*" -exec basename {} \; ; }

test_backs_up_every_db(){
  run_backup || fail "backup exited non-zero: $(cat "$WORK/out.log")"
  local demo other
  demo="$(uploaded demo)"
  other="$(uploaded other)"
  [[ "$demo" =~ ^bak__demo__demo-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.sql\.gz$ ]] || fail "demo object name: '$demo'"
  [[ "$other" =~ ^bak__other__other-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.sql\.gz$ ]] || fail "other object name: '$other'"
  assert_eq "$(gzip -dc "$UPLOADS/$demo")" "-- dump of demo_db" "demo dump content"
  grep -q "mariadb-dump --single-transaction --routines demo_db" "$STUB_LOG" || fail "dump options"
  grep -q "upload-from $BACKUP_TMP_DIR/" "$STUB_LOG" || fail "dump not staged in BACKUP_TMP_DIR"
  assert_eq "$(uploaded nodb)" "" "app without db"
  assert_eq "$(ls -A "$BACKUP_TMP_DIR")" "" "staging dir left behind after success"
}

test_one_failure_continues(){
  export DUMP_BAD=demo_db
  if run_backup; then fail "backup must fail when one dump fails"; fi
  assert_eq "$(uploaded demo)" "" "failed dump uploaded"
  [ -n "$(uploaded other)" ] || fail "other app not backed up"
  grep -q "backup of demo failed" "$WORK/out.log" || fail "no failure message"
  assert_eq "$(ls -A "$BACKUP_TMP_DIR")" "" "staging dir left behind after failed dump"
}

test_upload_failure(){
  export GCLOUD_EXIT=1
  if run_backup; then fail "backup must fail when the upload fails"; fi
  assert_eq "$(ls -A "$BACKUP_TMP_DIR")" "" "staging dir left behind after failed upload"
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
