#!/usr/bin/env bash
# Tests for scripts/platform-deploy.sh. gcloud, pm2, curl, id, runuser and the
# sync script are stubs; releases are real tarballs in a temp directory that
# the gcloud stub serves for "gcloud storage cat".
#
#   bash scripts/tests/platform-deploy.test.sh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ORIG_PATH="$PATH"
FAILURES=0
WORK=""
ROOT=""

fail(){ echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

assert_eq(){
  if [ "$1" != "$2" ]; then
    fail "$3: expected '$2', got '$1'"
  fi
}

file_mode(){ stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

stub(){
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n%s\n' "$1" "$2" > "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}

setup(){
  WORK="$(mktemp -d)"
  WORK="$(cd "$WORK" && pwd -P)"
  export PLATFORM_METADATA_FILE="$WORK/metadata.json" PLATFORM_CONF="$WORK/platform.conf"
  export MYSQL_DEFAULTS="$WORK/no-login-file" SRV_DIR="$WORK/srv" APP_USER=app
  export HEALTH_TIMEOUT=1 HEALTH_INTERVAL=0 STUB_LOG="$WORK/calls.log" STUB_TARS="$WORK/tars"
  export CURL_BAD="" PM2_BAD="" STUB_UID=1000 PRE_START_EXIT=0 PLATFORM_SYNC="$WORK/bin/fake-sync"
  printf 'RELEASES_BUCKET=rel\nBACKUPS_BUCKET=bak\n' > "$PLATFORM_CONF"
  jq -cn '{"vm-app-demo": ({name: "demo", port: 4100, domains: ["demo.example.com"], db: "demo", health_path: "/health", deploy_user: "sa_123"} | tojson)}' \
    > "$PLATFORM_METADATA_FILE"
  ROOT="$SRV_DIR/demo"
  mkdir -p "$ROOT/releases" "$ROOT/shared" "$WORK/bin" "$STUB_TARS"
  touch "$STUB_LOG"
  stub gcloud 'case "$1 $2" in
  "storage cat") f="$STUB_TARS/$(basename "$3")"; [ -f "$f" ] || exit 1; cat "$f" ;;
  "secrets versions") echo "DB_HOST=localhost" ;;
esac'
  # PM2_BAD and CURL_BAD: space-separated release names that fail while current points at them.
  stub pm2 'target="$(basename "$(readlink "$SRV_DIR/demo/current" || true)")"
if [ "${1:-}" = start ]; then case " $PM2_BAD " in *" $target "*) exit 1 ;; esac; fi
exit 0'
  stub curl 'target="$(basename "$(readlink "$SRV_DIR/demo/current" || true)")"
case " $CURL_BAD " in *" $target "*) exit 7 ;; esac
exit 0'
  stub id 'echo "$STUB_UID"'
  stub runuser 'while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"'
  stub fake-sync 'exit 0'
  export PATH="$WORK/bin:$ORIG_PATH"
}

teardown(){
  export PATH="$ORIG_PATH"
  rm -rf "$WORK"
}

# make_tar <name> [links file content]: a release tarball served as gs://rel/demo/<name>.tar.gz.
make_tar(){
  local src="$WORK/src/$1"
  mkdir -p "$src/.platform" "$src/app"
  echo "module.exports = { apps: [] };" > "$src/ecosystem.config.cjs"
  printf '%s\n' "${2:-app.env app/.env
logs app/logs}" > "$src/.platform/links"
  printf '#!/usr/bin/env bash\necho "pre-start in $PWD" >> "$STUB_LOG"\nexit "$PRE_START_EXIT"\n' \
    > "$src/.platform/pre-start"
  chmod +x "$src/.platform/pre-start"
  tar -czf "$STUB_TARS/$1.tar.gz" -C "$src" .
}

# old_release <name> <touch -t stamp>: an already unpacked release.
old_release(){
  mkdir -p "$ROOT/releases/$1"
  echo "module.exports = { apps: [] };" > "$ROOT/releases/$1/ecosystem.config.cjs"
  touch -t "$2" "$ROOT/releases/$1"
}

url(){ echo "gs://rel/demo/$1.tar.gz"; }
run_deploy(){ bash "$SCRIPTS/platform-deploy.sh" --app demo "$@" > "$WORK/out.log" 2>&1; }
current(){ readlink "$ROOT/current" || true; }
out_has(){ grep -qF "$1" "$WORK/out.log" || fail "$2: '$1' not in output: $(cat "$WORK/out.log")"; }

test_activate(){
  make_tar r1
  run_deploy activate "$(url r1)" || fail "activate exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
  assert_eq "$(cat "$ROOT/shared/app.env")" "DB_HOST=localhost" "config content"
  assert_eq "$(file_mode "$ROOT/shared/app.env")" "600" "config mode"
  assert_eq "$(readlink "$ROOT/releases/r1/app/.env")" "$ROOT/shared/app.env" "config link"
  assert_eq "$(readlink "$ROOT/releases/r1/app/logs")" "$ROOT/shared/logs" "logs link"
  grep -q "gcloud secrets versions access latest --secret=demo-env" "$STUB_LOG" || fail "config not fetched"
  grep -q "pre-start in $ROOT/releases/r1" "$STUB_LOG" || fail "pre-start not run from the release root"
  grep -q "pm2 delete $ROOT/current/ecosystem.config.cjs" "$STUB_LOG" || fail "pm2 delete not called"
  grep -q "pm2 start $ROOT/current/ecosystem.config.cjs" "$STUB_LOG" || fail "pm2 start not called"
  grep -q "pm2 save" "$STUB_LOG" || fail "pm2 save not called"
  grep -q "curl .*http://127.0.0.1:4100/health" "$STUB_LOG" || fail "health check not on the app's port and path"
  assert_eq "$(find "$ROOT/releases" -maxdepth 1 -name '.incoming-*' | wc -l | tr -d ' ')" "0" "leftover incoming dirs"
  if grep -q "fake-sync" "$STUB_LOG"; then fail "sync must only run as root"; fi
}

test_rejects_bad_urls(){
  make_tar r1
  local bad
  for bad in gs://rel/other/r1.tar.gz gs://other/demo/r1.tar.gz gs://rel/demo/r1.zip \
    gs://rel/demo/../other/r1.tar.gz gs://rel/demo/sub/r1.tar.gz gs://rel/demo/.hidden.tar.gz \
    gs://rel/demo/.tar.gz; do
    if run_deploy activate "$bad"; then fail "accepted $bad"; fi
    out_has "not a release of demo" "$bad"
  done
  assert_eq "$(current)" "" "current"
  if grep -q "storage cat" "$STUB_LOG"; then fail "downloaded a rejected URL"; fi
}

test_unknown_app(){
  if bash "$SCRIPTS/platform-deploy.sh" --app ghost status > "$WORK/out.log" 2>&1; then
    fail "status of an unknown app succeeded"
  fi
  out_has "no valid vm-app-ghost" "unknown app"
}

test_bad_arguments(){
  if run_deploy deploy; then fail "unknown command accepted"; fi
  out_has "unknown command" "unknown command"
  if run_deploy activate; then fail "activate without URL accepted"; fi
  if run_deploy status extra; then fail "status with an argument accepted"; fi
  if bash "$SCRIPTS/platform-deploy.sh" status > "$WORK/out.log" 2>&1; then fail "missing --app accepted"; fi
}

test_help(){
  bash "$SCRIPTS/platform-deploy.sh" --help > "$WORK/out.log" 2>&1 || fail "--help exited non-zero"
  out_has "platform-deploy.sh --app NAME activate" "help text"
}

test_failed_pre_start(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  make_tar r2
  export PRE_START_EXIT=1
  if run_deploy activate "$(url r2)"; then fail "activate succeeded although pre-start failed"; fi
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
  out_has "pre-start failed; current still points at $ROOT/releases/r1" "message"
  if grep -q "pm2 start" "$STUB_LOG"; then fail "restarted after a failed pre-start"; fi
}

test_rollback_on_failed_health(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  make_tar r2
  export CURL_BAD=r2
  if run_deploy activate "$(url r2)"; then fail "activate succeeded although r2 is unhealthy"; fi
  assert_eq "$(current)" "$ROOT/releases/r1" "current after rollback"
  out_has "rolled back to r1, which is healthy" "message"
}

test_rollback_not_healthy(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  make_tar r2
  export CURL_BAD="r1 r2"
  if run_deploy activate "$(url r2)"; then fail "activate succeeded"; fi
  out_has "rolled back to r1, which is NOT healthy either" "message"
}

test_failed_pm2_start_rolls_back(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  make_tar r2
  export PM2_BAD=r2
  if run_deploy activate "$(url r2)"; then fail "activate succeeded although pm2 start failed"; fi
  assert_eq "$(current)" "$ROOT/releases/r1" "current after rollback"
}

test_first_deploy_unhealthy(){
  make_tar r1
  export CURL_BAD=r1
  if run_deploy activate "$(url r1)"; then fail "activate succeeded"; fi
  out_has "health check failed" "message"
}

test_already_live(){
  make_tar r1
  run_deploy activate "$(url r1)" || fail "first activate failed: $(cat "$WORK/out.log")"
  : > "$STUB_LOG"
  if run_deploy activate "$(url r1)"; then fail "re-activating the live release succeeded"; fi
  out_has "release r1 is already live" "message"
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
  if grep -q "pm2" "$STUB_LOG"; then fail "touched PM2"; fi
}

test_missing_tarball(){
  if run_deploy activate "$(url nope)"; then fail "activate of a missing tarball succeeded"; fi
  out_has "cannot download or unpack" "message"
  assert_eq "$(find "$ROOT/releases" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0" "nothing left behind"
}

test_unsafe_link(){
  make_tar r1 "../outside app/.env"
  if run_deploy activate "$(url r1)"; then fail "accepted an unsafe link"; fi
  out_has "unsafe path" "message"
  assert_eq "$(current)" "" "current"
}

test_prune_keeps_five(){
  local i
  for i in 1 2 3 4 5 6; do
    old_release "r$i" "20260101000$i"
  done
  ln -sfn "$ROOT/releases/r6" "$ROOT/current"
  make_tar r7
  run_deploy activate "$(url r7)" || fail "activate exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(find "$ROOT/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "5" "release count"
  [ ! -e "$ROOT/releases/r1" ] || fail "r1 should be pruned"
  [ ! -e "$ROOT/releases/r2" ] || fail "r2 should be pruned"
  [ -d "$ROOT/releases/r7" ] || fail "r7 must stay"
}

test_rollback_command(){
  old_release r1 202601010001
  old_release r2 202601010002
  ln -sfn "$ROOT/releases/r2" "$ROOT/current"
  run_deploy rollback || fail "rollback exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
  grep -q "pm2 start $ROOT/current/ecosystem.config.cjs" "$STUB_LOG" || fail "not restarted"
}

test_rollback_without_older_release(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  if run_deploy rollback; then fail "rollback without an older release succeeded"; fi
  out_has "no older release to roll back to" "message"
}

test_status(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  run_deploy status || fail "status exited non-zero"
  out_has "current: $ROOT/releases/r1" "status line"
}

test_as_root_syncs_and_switches_user(){
  export STUB_UID=0
  make_tar r1
  run_deploy activate "$(url r1)" || fail "activate as root failed: $(cat "$WORK/out.log")"
  grep -q "fake-sync" "$STUB_LOG" || fail "sync not run"
  grep -q "runuser -u app --" "$STUB_LOG" || fail "did not switch to the app user"
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
}

test_as_root_rejects_bad_url_before_sync(){
  export STUB_UID=0
  if run_deploy activate gs://rel/other/r1.tar.gz; then fail "accepted another app's release"; fi
  if grep -q "fake-sync" "$STUB_LOG"; then fail "sync ran for a rejected URL"; fi
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
