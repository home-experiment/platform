#!/usr/bin/env bash
# Tests for scripts/platform-sync.sh. chown, mariadb, caddy, systemctl, visudo,
# id, useradd, runuser, pm2 and nft are stubs on PATH; useradd appends to a
# fake passwd file that id reads. Every test gets fresh directories in a temp dir.
#
#   bash scripts/tests/platform-sync.test.sh
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

file_mode(){ stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# app_value <name> <port> [jq filter]: a vm-app metadata value.
app_value(){
  jq -cn --arg name "$1" --argjson port "$2" \
    '{name: $name, port: $port, domains: [($name + ".example.com")], db: $name, health_path: "/health", deploy_user: "sa_123"}' \
    | jq -c "${3:-.}"
}

metadata(){
  local pair json='{}'
  for pair in "$@"; do
    json="$(jq -c --arg k "${pair%%=*}" --arg v "${pair#*=}" '. + {($k): $v}' <<<"$json")"
  done
  echo "$json" > "$PLATFORM_METADATA_FILE"
}

# stub <command> <body>: a fake command on PATH that logs its arguments first.
stub(){
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n%s\n' "$1" "$2" > "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}

setup(){
  WORK="$(mktemp -d)"
  WORK="$(cd "$WORK" && pwd -P)"
  export PLATFORM_METADATA_FILE="$WORK/metadata.json" MYSQL_DEFAULTS="$WORK/no-login-file"
  export SRV_DIR="$WORK/srv" CADDY_SITES="$WORK/caddy/sites" CADDYFILE="$WORK/caddy/Caddyfile"
  export BIN_DIR="$WORK/usr-bin" SUDOERS_DIR="$WORK/sudoers" HOME_BASE="$WORK/home"
  export SYSTEMD_DIR="$WORK/systemd" NFT_FILE="$WORK/nftables.d/platform.nft" PASSWD="$WORK/passwd"
  export STUB_LOG="$WORK/calls.log" MARIADB_EXIT=0 CADDY_EXIT=0 VISUDO_BAD=""
  export USERADD_BAD="" PM2_EXIT=0 NFT_EXIT=0 NFT_LIST_EXIT=0
  mkdir -p "$WORK/bin" "$BIN_DIR" "$SUDOERS_DIR" "$WORK/caddy" "$SYSTEMD_DIR"
  touch "$STUB_LOG" "$PASSWD"
  # id -u <user>: the uid from the fake passwd file (name:uid lines); fails for unknown users.
  stub id 'if [ "${1:-}" = -u ] && [ -n "${2:-}" ]; then
  uid="$(awk -F: -v u="$2" '"'"'$1 == u { print $2 }'"'"' "$PASSWD")"
  [ -n "$uid" ] || exit 1
  echo "$uid"
  exit 0
fi
echo 0'
  # useradd ... <user>: appends <user>:<1001 + existing lines>, or fails for names in USERADD_BAD.
  stub useradd 'for user in "$@"; do :; done
case " $USERADD_BAD " in *" $user "*) exit 1 ;; esac
echo "$user:$((1001 + $(wc -l < "$PASSWD")))" >> "$PASSWD"'
  stub pm2 'exit "$PM2_EXIT"'
  stub nft 'case "${1:-}" in list) exit "$NFT_LIST_EXIT" ;; -f) exit "$NFT_EXIT" ;; esac'
  stub chown 'exit 0'
  stub mariadb 'exit "$MARIADB_EXIT"'
  stub caddy 'exit "$CADDY_EXIT"'
  stub systemctl 'exit 0'
  stub runuser 'while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift; exec "$@"'
  stub visudo 'if [ -n "$VISUDO_BAD" ] && grep -q "$VISUDO_BAD" "$2"; then exit 1; fi'
  export PATH="$WORK/bin:$ORIG_PATH"
}

teardown(){
  export PATH="$ORIG_PATH"
  rm -rf "$WORK"
}

run_sync(){ bash "$SCRIPTS/platform-sync.sh" > "$WORK/out.log" 2>&1; }

# nft_expected [rule line]: the nft file platform-sync writes, with that line in the chain.
nft_expected(){
  printf '%s\n' \
    "# Written by platform-sync: app users may not reach the metadata server, which" \
    "# hands out the VM service account's credentials. DNS (port 53) on the same" \
    "# address stays allowed." \
    "table inet platform" \
    "delete table inet platform" \
    "table inet platform {" \
    "	chain output {" \
    "		type filter hook output priority 0; policy accept;"
  if [ -n "${1:-}" ]; then printf '\t\t%s\n' "$1"; fi
  printf '%s\n' "	}" "}"
}

test_sync_app(){
  metadata "vm-app-demo=$(app_value demo 4100)"
  run_sync || fail "sync exited non-zero: $(cat "$WORK/out.log")"
  [ -d "$SRV_DIR/demo/releases" ] || fail "releases directory missing"
  [ -d "$SRV_DIR/demo/shared/logs" ] || fail "logs directory missing"
  assert_eq "$(grep '^useradd' "$STUB_LOG")" \
    "useradd --create-home --home-dir $HOME_BASE/app-demo --shell /bin/bash --user-group app-demo" "useradd call"
  assert_eq "$(grep '^chown' "$STUB_LOG")" "chown -h app-demo:app-demo $SRV_DIR/demo" "chown calls"
  assert_eq "$(file_mode "$SRV_DIR/demo")" "750" "app directory mode"
  grep -q "^runuser -u app-demo -- mkdir -p $SRV_DIR/demo/releases $SRV_DIR/demo/shared/logs" "$STUB_LOG" \
    || fail "subdirectories not created as the app user"
  assert_eq "$(grep '^pm2' "$STUB_LOG")" "pm2 startup systemd -u app-demo --hp $HOME_BASE/app-demo" "pm2 startup"
  assert_eq "$(cat "$NFT_FILE")" "$(nft_expected "ip daddr 169.254.169.254 meta skuid { 1001 } th dport != 53 reject")" "nft file"
  grep -q "^nft -f $NFT_FILE" "$STUB_LOG" || fail "nft rules not loaded"
  grep -q 'mariadb -e CREATE DATABASE IF NOT EXISTS `demo` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci' "$STUB_LOG" \
    || fail "database not created"
  assert_eq "$(cat "$CADDY_SITES/demo.caddy")" "$(cat <<'EOF'
demo.example.com {
	# Deferred so it replaces an HSTS header the app already sends.
	header {
		Strict-Transport-Security "max-age=31536000"
		defer
	}
	reverse_proxy 127.0.0.1:4100
}
EOF
)" "Caddy site"
  [ -x "$BIN_DIR/deploy-demo" ] || fail "wrapper missing or not executable"
  assert_eq "$(tail -n 1 "$BIN_DIR/deploy-demo")" "exec $SCRIPTS/platform-deploy.sh --app demo \"\$@\"" "wrapper"
  assert_eq "$(cat "$SUDOERS_DIR/platform-demo")" "sa_123 ALL=(root) NOPASSWD: $BIN_DIR/deploy-demo" "sudoers rule"
  assert_eq "$(file_mode "$SUDOERS_DIR/platform-demo")" "440" "sudoers mode"
  grep -q "caddy validate --config $CADDYFILE --adapter caddyfile" "$STUB_LOG" || fail "Caddy config not validated"
  grep -q "systemctl reload-or-restart caddy" "$STUB_LOG" || fail "Caddy not reloaded"
}

test_several_domains(){
  metadata "vm-app-demo=$(app_value demo 4100 '.domains = ["a.example.com", "b.example.com"]')"
  run_sync || fail "sync exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(head -n 1 "$CADDY_SITES/demo.caddy")" "a.example.com, b.example.com {" "site address"
}

test_no_db(){
  metadata "vm-app-demo=$(app_value demo 4100 'del(.db)')"
  run_sync || fail "sync exited non-zero: $(cat "$WORK/out.log")"
  if grep -q '^mariadb' "$STUB_LOG"; then fail "database created for an app without db"; fi
}

test_second_run_no_reload(){
  metadata "vm-app-demo=$(app_value demo 4100)"
  run_sync || fail "first sync failed: $(cat "$WORK/out.log")"
  touch "$SYSTEMD_DIR/pm2-app-demo.service"
  : > "$STUB_LOG"
  run_sync || fail "second sync failed: $(cat "$WORK/out.log")"
  if grep -q "reload-or-restart caddy" "$STUB_LOG"; then fail "Caddy reloaded although nothing changed"; fi
  if grep -q "^useradd" "$STUB_LOG"; then fail "useradd called for an existing user"; fi
  if grep -q "^pm2 startup" "$STUB_LOG"; then fail "pm2 startup called although the unit exists"; fi
  if grep -q "^nft -f" "$STUB_LOG"; then fail "nft rules reloaded although nothing changed"; fi
}

test_nft_reloaded_when_table_missing(){
  metadata "vm-app-demo=$(app_value demo 4100)"
  run_sync || fail "first sync failed: $(cat "$WORK/out.log")"
  export NFT_LIST_EXIT=1
  : > "$STUB_LOG"
  run_sync || fail "second sync failed: $(cat "$WORK/out.log")"
  grep -q "^nft -f $NFT_FILE" "$STUB_LOG" || fail "nft rules not loaded although the table is missing"
}

test_two_apps_uids_sorted(){
  echo "app-other:999" > "$PASSWD"
  metadata "vm-app-demo=$(app_value demo 4100)" "vm-app-other=$(app_value other 4200)"
  run_sync || fail "sync exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(grep '^useradd' "$STUB_LOG" | wc -l | tr -d ' ')" "1" "useradd only for the new user"
  assert_eq "$(cat "$NFT_FILE")" "$(nft_expected "ip daddr 169.254.169.254 meta skuid { 999, 1002 } th dport != 53 reject")" "nft file"
}

test_useradd_failure_skips_app(){
  export USERADD_BAD=app-demo
  metadata "vm-app-demo=$(app_value demo 4100)" "vm-app-other=$(app_value other 4200)"
  if run_sync; then fail "sync must fail when a user cannot be created"; fi
  grep -q "warning: demo: " "$WORK/out.log" || fail "no warning for the failed user: $(cat "$WORK/out.log")"
  [ ! -e "$SRV_DIR/demo" ] || fail "directories made for an app without a user"
  [ ! -e "$CADDY_SITES/demo.caddy" ] || fail "Caddy site written for an app without a user"
  [ -f "$CADDY_SITES/other.caddy" ] || fail "other app not synced"
  [ -d "$SRV_DIR/other/releases" ] || fail "other app's directories missing"
  assert_eq "$(cat "$NFT_FILE")" "$(nft_expected "ip daddr 169.254.169.254 meta skuid { 1001 } th dport != 53 reject")" "nft file"
}

test_no_app_users_keeps_empty_chain(){
  metadata
  run_sync || fail "sync exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(cat "$NFT_FILE")" "$(nft_expected)" "nft file without users"
}

test_removed_app_user_stays_blocked(){
  metadata "vm-app-demo=$(app_value demo 4100)" "vm-app-other=$(app_value other 4200)"
  run_sync || fail "first sync failed: $(cat "$WORK/out.log")"
  metadata "vm-app-other=$(app_value other 4200)"
  run_sync || fail "second sync failed: $(cat "$WORK/out.log")"
  assert_eq "$(cat "$NFT_FILE")" "$(nft_expected "ip daddr 169.254.169.254 meta skuid { 1001, 1002 } th dport != 53 reject")" "nft file"
}

test_nft_failure_reported(){
  export NFT_EXIT=1
  metadata "vm-app-demo=$(app_value demo 4100)"
  if run_sync; then fail "sync must fail when nft cannot load the rules"; fi
  grep -q "warning: .*$NFT_FILE" "$WORK/out.log" || fail "nft failure not reported: $(cat "$WORK/out.log")"
}

test_pm2_startup_failure_reported(){
  export PM2_EXIT=1
  metadata "vm-app-demo=$(app_value demo 4100)"
  if run_sync; then fail "sync must fail when pm2 startup fails"; fi
  grep -q "warning: demo: " "$WORK/out.log" || fail "pm2 startup failure not reported"
}

test_invalid_app_keeps_files_and_others_sync(){
  metadata "vm-app-demo=$(app_value demo 4100)" "vm-app-other=$(app_value other 4200)"
  run_sync || fail "first sync failed: $(cat "$WORK/out.log")"
  metadata "vm-app-demo=broken" "vm-app-other=$(app_value other 4300)"
  run_sync || fail "an invalid app must not fail the sync: $(cat "$WORK/out.log")"
  [ -f "$CADDY_SITES/demo.caddy" ] || fail "invalid app lost its Caddy site"
  [ -f "$SUDOERS_DIR/platform-demo" ] || fail "invalid app lost its sudoers rule"
  [ -f "$BIN_DIR/deploy-demo" ] || fail "invalid app lost its wrapper"
  grep -q "127.0.0.1:4300" "$CADDY_SITES/other.caddy" || fail "other app not updated"
}

test_removed_app_cleaned(){
  metadata "vm-app-demo=$(app_value demo 4100)" "vm-app-other=$(app_value other 4200)"
  run_sync || fail "first sync failed: $(cat "$WORK/out.log")"
  metadata "vm-app-other=$(app_value other 4200)"
  run_sync || fail "second sync failed: $(cat "$WORK/out.log")"
  [ ! -e "$CADDY_SITES/demo.caddy" ] || fail "Caddy site of a removed app kept"
  [ ! -e "$BIN_DIR/deploy-demo" ] || fail "wrapper of a removed app kept"
  [ ! -e "$SUDOERS_DIR/platform-demo" ] || fail "sudoers rule of a removed app kept"
  [ -d "$SRV_DIR/demo" ] || fail "app directory must never be removed"
  [ -f "$CADDY_SITES/other.caddy" ] || fail "other app's site removed"
  grep -q "systemctl reload-or-restart caddy" "$STUB_LOG" || fail "Caddy not reloaded after a removal"
}

test_bad_sudoers_not_installed(){
  export VISUDO_BAD=sa_123
  metadata "vm-app-demo=$(app_value demo 4100)"
  if run_sync; then fail "sync must fail when visudo rejects the rule"; fi
  [ ! -e "$SUDOERS_DIR/platform-demo" ] || fail "rejected sudoers rule installed"
  [ -f "$CADDY_SITES/demo.caddy" ] || fail "the rest of the app was not synced"
}

test_caddy_invalid_no_reload(){
  metadata "vm-app-demo=$(app_value demo 4100)"
  run_sync || fail "first sync failed: $(cat "$WORK/out.log")"
  export CADDY_EXIT=1
  : > "$STUB_LOG"
  metadata "vm-app-demo=$(app_value demo 4500)" "vm-app-fresh=$(app_value fresh 4600)"
  if run_sync; then fail "sync must fail when Caddy rejects the config"; fi
  if grep -q "reload-or-restart caddy" "$STUB_LOG"; then fail "an invalid config was reloaded"; fi
  grep -q "127.0.0.1:4100" "$CADDY_SITES/demo.caddy" || fail "failed change left in the demo snippet"
  [ ! -e "$CADDY_SITES/fresh.caddy" ] || fail "new snippet left after a failed validation"
}

test_unrelated_files_survive(){
  metadata "vm-app-demo=$(app_value demo 4100)"
  printf '#!/bin/bash\necho manual\n' > "$BIN_DIR/deploy-manual"
  printf 'admin ALL=(root) NOPASSWD: /bin/true\n' > "$SUDOERS_DIR/platform-admin"
  run_sync || fail "sync exited non-zero: $(cat "$WORK/out.log")"
  [ -f "$BIN_DIR/deploy-manual" ] || fail "unrelated wrapper removed"
  [ -f "$SUDOERS_DIR/platform-admin" ] || fail "unrelated sudoers file removed"
}

test_unwritable_dir_reports_failure(){
  metadata "vm-app-demo=$(app_value demo 4100)"
  chmod 555 "$BIN_DIR"
  local rc=0
  run_sync || rc=$?
  chmod 755 "$BIN_DIR"
  [ "$rc" -ne 0 ] || fail "sync must fail when a file cannot be written"
  grep -q "cannot write $BIN_DIR/deploy-demo" "$WORK/out.log" || fail "write error not reported"
}

test_symlink_below_app_not_followed(){
  metadata "vm-app-demo=$(app_value demo 4100)"
  mkdir -p "$WORK/outside" "$SRV_DIR/demo"
  ln -s "$WORK/outside" "$SRV_DIR/demo/shared"
  run_sync || fail "sync exited non-zero: $(cat "$WORK/out.log")"
  if grep '^chown' "$STUB_LOG" | grep -q "$SRV_DIR/demo/"; then fail "chown called below the app directory"; fi
  if grep '^chown' "$STUB_LOG" | grep -q "$WORK/outside"; then fail "chown followed a symlink out of /srv"; fi
}

test_db_failure_other_apps_continue(){
  export MARIADB_EXIT=1
  metadata "vm-app-demo=$(app_value demo 4100)" "vm-app-other=$(app_value other 4200)"
  if run_sync; then fail "sync must fail when a database cannot be created"; fi
  [ -f "$CADDY_SITES/other.caddy" ] || fail "other app not synced"
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
