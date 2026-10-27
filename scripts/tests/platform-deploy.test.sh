#!/usr/bin/env bash
# Tests for scripts/platform-deploy.sh. gcloud, pm2, curl, id, runuser, chgrp
# and the sync script are stubs; releases are real tarballs in a temp directory
# that the gcloud stub serves for "gcloud storage cp". Tests of the app phase
# (STUB_UID=1000) stage the tarball and the config themselves, as the root
# phase would; tests of the root phase (STUB_UID=0) let the root phase stage.
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
  export MYSQL_DEFAULTS="$WORK/no-login-file" SRV_DIR="$WORK/srv" HOME_BASE="$WORK/home"
  export STAGING_DIR="$WORK/run" NO_METADATA="$WORK/no-metadata.json" MODES="$WORK/staged-modes"
  export HEALTH_TIMEOUT=1 HEALTH_INTERVAL=0 STUB_LOG="$WORK/calls.log" STUB_TARS="$WORK/tars"
  export CURL_BAD="" PM2_BAD="" STUB_UID=1000 PRE_START_EXIT=0 PLATFORM_SYNC="$WORK/bin/fake-sync"
  export SECRETS_EXIT=0
  printf 'RELEASES_BUCKET=rel\nBACKUPS_BUCKET=bak\n' > "$PLATFORM_CONF"
  jq -cn '{"vm-app-demo": ({name: "demo", port: 4100, domains: ["demo.example.com"], db: "demo", health_path: "/health", deploy_user: "sa_123"} | tojson)}' \
    > "$PLATFORM_METADATA_FILE"
  ROOT="$SRV_DIR/demo"
  mkdir -p "$ROOT/releases" "$ROOT/shared" "$WORK/bin" "$STUB_TARS"
  touch "$STUB_LOG"
  stub gcloud 'case "$1 $2" in
  "storage cp") f="$STUB_TARS/$(basename "$3")"; [ -f "$f" ] || exit 1; cp "$f" "$4" ;;
  "secrets versions") [ "$SECRETS_EXIT" = 0 ] || exit "$SECRETS_EXIT"; echo "DB_HOST=localhost" ;;
esac'
  # PM2_BAD and CURL_BAD: space-separated release names that fail while current points at them.
  stub pm2 'target="$(basename "$(readlink "$SRV_DIR/demo/current" || true)")"
if [ "${1:-}" = start ]; then case " $PM2_BAD " in *" $target "*) exit 1 ;; esac; fi
exit 0'
  stub curl 'target="$(basename "$(readlink "$SRV_DIR/demo/current" || true)")"
case " $CURL_BAD " in *" $target "*) exit 7 ;; esac
exit 0'
  stub id 'echo "$STUB_UID"'
  stub chgrp 'exit 0'
  # The app user cannot reach the metadata server: the app phase gets no metadata.
  # The modes of what was staged are recorded for the tests.
  stub runuser 'for f in "$STAGING_DIR/demo" "$STAGING_DIR/demo/release.tar.gz" "$STAGING_DIR/demo/app.env"; do
  if [ -e "$f" ]; then
    echo "$(basename "$f") $(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" >> "$MODES"
  fi
done
export PLATFORM_METADATA_FILE="$NO_METADATA"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
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

# stage <release>: what the root phase leaves for the app phase.
stage(){
  mkdir -p "$STAGING_DIR/demo"
  if [ -f "$STUB_TARS/$1.tar.gz" ]; then cp "$STUB_TARS/$1.tar.gz" "$STAGING_DIR/demo/release.tar.gz"; fi
  echo "DB_HOST=localhost" > "$STAGING_DIR/demo/app.env"
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
no_gcloud(){ if grep -q "^gcloud" "$STUB_LOG"; then fail "$1: gcloud called: $(grep '^gcloud' "$STUB_LOG")"; fi; }
line_of(){ grep -nF "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1; }

test_activate(){
  make_tar r1
  stage r1
  run_deploy activate "$(url r1)" || fail "activate exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
  assert_eq "$(cat "$ROOT/shared/app.env")" "DB_HOST=localhost" "config content"
  assert_eq "$(file_mode "$ROOT/shared/app.env")" "600" "config mode"
  [ ! -e "$ROOT/shared/app.env.tmp" ] || fail "temporary config left behind"
  assert_eq "$(readlink "$ROOT/releases/r1/app/.env")" "$ROOT/shared/app.env" "config link"
  assert_eq "$(readlink "$ROOT/releases/r1/app/logs")" "$ROOT/shared/logs" "logs link"
  grep -q "pre-start in $ROOT/releases/r1" "$STUB_LOG" || fail "pre-start not run from the release root"
  grep -q "pm2 delete demo" "$STUB_LOG" || fail "pm2 delete not called"
  grep -q "pm2 start $ROOT/current/ecosystem.config.cjs" "$STUB_LOG" || fail "pm2 start not called"
  grep -q "pm2 save" "$STUB_LOG" || fail "pm2 save not called"
  grep -q "curl .*http://127.0.0.1:4100/health" "$STUB_LOG" || fail "health check not on the app's port and path"
  assert_eq "$(find "$ROOT/releases" -maxdepth 1 -name '.incoming-*' | wc -l | tr -d ' ')" "0" "leftover incoming dirs"
  if grep -q "fake-sync" "$STUB_LOG"; then fail "sync must only run as root"; fi
  no_gcloud "app phase"
}

test_rejects_bad_urls(){
  make_tar r1
  stage r1
  local bad
  for bad in gs://rel/other/r1.tar.gz gs://other/demo/r1.tar.gz gs://rel/demo/r1.zip \
    gs://rel/demo/../other/r1.tar.gz gs://rel/demo/sub/r1.tar.gz gs://rel/demo/.hidden.tar.gz \
    gs://rel/demo/.tar.gz; do
    if run_deploy activate "$bad"; then fail "accepted $bad"; fi
    out_has "not a release of demo" "$bad"
  done
  assert_eq "$(current)" "" "current"
  no_gcloud "rejected URLs"
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
  out_has "STAGING_DIR" "help text names the staging knob"
}

test_failed_pre_start(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  make_tar r2
  stage r2
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
  stage r2
  export CURL_BAD=r2
  if run_deploy activate "$(url r2)"; then fail "activate succeeded although r2 is unhealthy"; fi
  assert_eq "$(current)" "$ROOT/releases/r1" "current after rollback"
  out_has "rolled back to r1, which is healthy" "message"
}

test_rollback_not_healthy(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  make_tar r2
  stage r2
  export CURL_BAD="r1 r2"
  if run_deploy activate "$(url r2)"; then fail "activate succeeded"; fi
  out_has "rolled back to r1, which is NOT healthy either" "message"
}

test_failed_pm2_start_rolls_back(){
  old_release r1 202601010001
  ln -sfn "$ROOT/releases/r1" "$ROOT/current"
  make_tar r2
  stage r2
  export PM2_BAD=r2
  if run_deploy activate "$(url r2)"; then fail "activate succeeded although pm2 start failed"; fi
  assert_eq "$(current)" "$ROOT/releases/r1" "current after rollback"
}

test_first_deploy_unhealthy(){
  make_tar r1
  stage r1
  export CURL_BAD=r1
  if run_deploy activate "$(url r1)"; then fail "activate succeeded"; fi
  out_has "health check failed" "message"
}

test_already_live(){
  make_tar r1
  stage r1
  run_deploy activate "$(url r1)" || fail "first activate failed: $(cat "$WORK/out.log")"
  : > "$STUB_LOG"
  if run_deploy activate "$(url r1)"; then fail "re-activating the live release succeeded"; fi
  out_has "release r1 is already live" "message"
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
  if grep -q "pm2" "$STUB_LOG"; then fail "touched PM2"; fi
}

test_missing_tarball(){
  stage nope
  if run_deploy activate "$(url nope)"; then fail "activate of a missing tarball succeeded"; fi
  out_has "cannot unpack $(url nope)" "message"
  assert_eq "$(find "$ROOT/releases" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0" "nothing left behind"
  no_gcloud "app phase"
}

test_broken_tarball(){
  stage nope
  echo "not a tarball" > "$STAGING_DIR/demo/release.tar.gz"
  if run_deploy activate "$(url nope)"; then fail "activate of a broken tarball succeeded"; fi
  out_has "cannot unpack $(url nope)" "message"
  assert_eq "$(find "$ROOT/releases" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0" "nothing left behind"
}

test_missing_staged_config(){
  make_tar r1
  stage r1
  rm "$STAGING_DIR/demo/app.env"
  if run_deploy activate "$(url r1)"; then fail "activate without a staged config succeeded"; fi
  out_has "no staged config for demo" "message"
  assert_eq "$(current)" "" "current"
  no_gcloud "app phase"
}

test_unsafe_link(){
  make_tar r1 "../outside app/.env"
  stage r1
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
  stage r7
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

test_as_root_stages_and_switches_user(){
  export STUB_UID=0
  make_tar r1
  run_deploy activate "$(url r1)" || fail "activate as root failed: $(cat "$WORK/out.log")"
  local sync download config switch
  sync="$(line_of "fake-sync")"
  download="$(line_of "gcloud storage cp $(url r1) $STAGING_DIR/demo/release.tar.gz")"
  config="$(line_of "gcloud secrets versions access latest --secret=demo-env")"
  switch="$(line_of "runuser -u app-demo -- env HOME=$HOME_BASE/app-demo PLATFORM_SWITCHED=1 PLATFORM_APP_JSON=")"
  grep "^runuser" "$STUB_LOG" | grep -qF "bash $SCRIPTS/platform-deploy.sh --app demo activate $(url r1)" \
    || fail "app phase not run with the same URL: $(cat "$STUB_LOG")"
  if [ -z "$sync" ] || [ -z "$download" ] || [ -z "$config" ] || [ -z "$switch" ]; then
    fail "missing step (sync '$sync', download '$download', config '$config', runuser '$switch'): $(cat "$STUB_LOG")"
  elif ! [ "$sync" -lt "$download" ] || ! [ "$download" -lt "$config" ] || ! [ "$config" -lt "$switch" ]; then
    fail "steps out of order: $(cat "$STUB_LOG")"
  fi
  assert_eq "$(grep -c "^gcloud" "$STUB_LOG")" "2" "gcloud calls (root phase only)"
  grep -q "^chgrp app-demo $STAGING_DIR/demo$" "$STUB_LOG" || fail "staging directory not given to the app group"
  grep -q "^chgrp app-demo $STAGING_DIR/demo/release.tar.gz $STAGING_DIR/demo/app.env$" "$STUB_LOG" \
    || fail "staged files not given to the app group"
  assert_eq "$(tr '\n' ' ' < "$MODES")" "demo 750 release.tar.gz 640 app.env 640 " "staged modes"
  [ ! -e "$STAGING_DIR/demo" ] || fail "staging directory left behind"
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
  assert_eq "$(cat "$ROOT/shared/app.env")" "DB_HOST=localhost" "config content"
}

test_as_root_removes_staging_after_failed_app_phase(){
  export STUB_UID=0 PRE_START_EXIT=1
  make_tar r1
  if run_deploy activate "$(url r1)"; then fail "activate succeeded although pre-start failed"; fi
  out_has "pre-start failed" "message"
  grep -q "^runuser -u app-demo" "$STUB_LOG" || fail "app phase not run"
  [ ! -e "$STAGING_DIR/demo" ] || fail "staging directory left behind"
}

test_as_root_failed_download(){
  export STUB_UID=0
  if run_deploy activate "$(url nope)"; then fail "activate of a missing tarball succeeded"; fi
  out_has "cannot download $(url nope)" "message"
  if grep -q "^runuser" "$STUB_LOG"; then fail "switched user after a failed download"; fi
  if grep -q "secrets versions" "$STUB_LOG"; then fail "read the config after a failed download"; fi
  [ ! -e "$STAGING_DIR/demo" ] || fail "staging directory left behind"
}

test_as_root_failed_config(){
  export STUB_UID=0 SECRETS_EXIT=1
  make_tar r1
  if run_deploy activate "$(url r1)"; then fail "activate succeeded without a config"; fi
  out_has "cannot read the secret demo-env" "message"
  if grep -q "^runuser" "$STUB_LOG"; then fail "switched user without a config"; fi
  [ ! -e "$STAGING_DIR/demo" ] || fail "staging directory left behind"
}

test_as_root_rejects_bad_url_before_sync(){
  export STUB_UID=0
  make_tar r1
  if run_deploy activate gs://rel/other/r1.tar.gz; then fail "accepted another app's release"; fi
  if grep -q "fake-sync" "$STUB_LOG"; then fail "sync ran for a rejected URL"; fi
  no_gcloud "rejected URL"
  if grep -q "^runuser" "$STUB_LOG"; then fail "switched user for a rejected URL"; fi
}

test_as_root_rollback(){
  export STUB_UID=0
  old_release r1 202601010001
  old_release r2 202601010002
  ln -sfn "$ROOT/releases/r2" "$ROOT/current"
  run_deploy rollback || fail "rollback as root failed: $(cat "$WORK/out.log")"
  grep -qF "runuser -u app-demo -- env HOME=$HOME_BASE/app-demo PLATFORM_SWITCHED=1 PLATFORM_APP_JSON=" "$STUB_LOG" \
    || fail "did not switch to the app user: $(cat "$STUB_LOG")"
  grep "^runuser" "$STUB_LOG" | grep -qF "bash $SCRIPTS/platform-deploy.sh --app demo rollback" \
    || fail "app phase not run with rollback: $(cat "$STUB_LOG")"
  no_gcloud "rollback"
  assert_eq "$(current)" "$ROOT/releases/r1" "current"
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
