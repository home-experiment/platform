#!/usr/bin/env bash
# Tests for scripts/platform-common.sh: reading and validating the vm-app-*
# project metadata keys. The metadata comes from a file (PLATFORM_METADATA_FILE).
#
#   bash scripts/tests/platform-common.test.sh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAILURES=0
WORK=""

fail(){ echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

assert_eq(){
  if [ "$1" != "$2" ]; then
    fail "$3: expected '$2', got '$1'"
  fi
}

# app_value <name> <port> [jq filter]: a vm-app metadata value, optionally changed by the filter.
app_value(){
  jq -cn --arg name "$1" --argjson port "$2" \
    '{name: $name, port: $port, domains: [($name + ".example.com")], db: ($name | gsub("-"; "_")), health_path: "/health", deploy_user: "sa_123"}' \
    | jq -c "${3:-.}"
}

# metadata <key=value>...: writes the fake project metadata.
metadata(){
  local pair json='{}'
  for pair in "$@"; do
    json="$(jq -c --arg k "${pair%%=*}" --arg v "${pair#*=}" '. + {($k): $v}' <<<"$json")"
  done
  echo "$json" > "$PLATFORM_METADATA_FILE"
}

setup(){
  WORK="$(mktemp -d)"
  export PLATFORM_METADATA_FILE="$WORK/metadata.json"
}

teardown(){ rm -rf "$WORK"; }

# names: the names valid_apps returns, space-separated; warnings go to $WORK/err.log.
names(){
  (
    # shellcheck source=../platform-common.sh
    . "$SCRIPTS/platform-common.sh"
    valid_apps 2>"$WORK/err.log" | jq -r .name | tr '\n' ' ' | sed 's/ $//'
  )
}

one_app(){
  (
    # shellcheck source=../platform-common.sh
    . "$SCRIPTS/platform-common.sh"
    app_json "$1"
  )
}

test_valid_app(){
  metadata "vm-app-demo=$(app_value demo 4100)" "other-key=x"
  assert_eq "$(names)" "demo" "names"
  local app
  app="$(one_app demo)"
  assert_eq "$(jq -r .port <<<"$app")" "4100" "port"
  assert_eq "$(jq -r .db <<<"$app")" "demo" "db"
  assert_eq "$(jq -r .health_path <<<"$app")" "/health" "health path"
  assert_eq "$(jq -r '.domains | join(",")' <<<"$app")" "demo.example.com" "domains"
  assert_eq "$(jq -r .deploy_user <<<"$app")" "sa_123" "deploy user"
}

test_defaults(){
  metadata "vm-app-demo=$(app_value demo 4100 'del(.db, .health_path)')"
  local app
  app="$(one_app demo)"
  assert_eq "$(jq -r .db <<<"$app")" "" "db default"
  assert_eq "$(jq -r .health_path <<<"$app")" "/" "health path default"
}

test_null_db(){
  metadata "vm-app-demo=$(app_value demo 4100 '.db = null')"
  assert_eq "$(jq -r .db <<<"$(one_app demo)")" "" "null db"
}

test_unknown_app(){
  metadata "vm-app-demo=$(app_value demo 4100)"
  assert_eq "$(one_app ghost)" "" "unknown app"
}

test_invalid_apps_skipped(){
  metadata \
    "vm-app-good=$(app_value good 4100)" \
    "vm-app-notjson=not json" \
    "vm-app-Bad=$(app_value Bad 4101)" \
    "vm-app-mismatch=$(app_value other 4102)" \
    "vm-app-lowport=$(app_value lowport 80)" \
    "vm-app-baddomain=$(app_value baddomain 4104 '.domains = ["bad domain"]')" \
    "vm-app-nodomain=$(app_value nodomain 4105 '.domains = []')" \
    "vm-app-baddb=$(app_value baddb 4106 '.db = "x; DROP"')" \
    "vm-app-baduser=$(app_value baduser 4107 '.deploy_user = "root"')" \
    "vm-app-badpath=$(app_value badpath 4108 '.health_path = "health"')"
  assert_eq "$(names)" "good" "only the valid app"
  local key
  for key in vm-app-notjson vm-app-Bad vm-app-mismatch vm-app-lowport vm-app-baddomain \
    vm-app-nodomain vm-app-baddb vm-app-baduser vm-app-badpath; do
    grep -q "$key" "$WORK/err.log" || fail "no warning for $key"
  done
}

test_name_length(){
  metadata \
    "vm-app-abcdefghijklmnopqrstuvw=$(app_value abcdefghijklmnopqrstuvw 4100)" \
    "vm-app-abcdefghijklmnopqrstuvwx=$(app_value abcdefghijklmnopqrstuvwx 4101)"
  assert_eq "$(names)" "abcdefghijklmnopqrstuvw" "23 characters accepted, 24 rejected"
  grep -q "vm-app-abcdefghijklmnopqrstuvwx: bad name" "$WORK/err.log" || fail "no warning for a 24-character name"
}

test_app_user(){
  local got
  got="$(
    # shellcheck source=../platform-common.sh
    . "$SCRIPTS/platform-common.sh"
    app_user demo
  )"
  assert_eq "$got" "app-demo" "app user"
}

test_domain_with_newline_skipped(){
  metadata \
    "vm-app-good=$(app_value good 4100)" \
    "vm-app-twodomains=$(app_value twodomains 4101 '.domains = ["a.example.com\nb.example.com"]')"
  assert_eq "$(names)" "good" "newline domain left out"
  grep -q "vm-app-twodomains: bad domain" "$WORK/err.log" || fail "no warning for newline domain"
}

test_duplicate_port_skips_both(){
  metadata "vm-app-one=$(app_value one 4100)" "vm-app-two=$(app_value two 4100)" \
    "vm-app-three=$(app_value three 4200)"
  assert_eq "$(names)" "three" "names"
  grep -q "port 4100 is used by another app" "$WORK/err.log" || fail "no duplicate port warning"
}

test_present_apps_includes_invalid(){
  metadata "vm-app-good=$(app_value good 4100)" "vm-app-broken=nope"
  local present
  present="$(
    # shellcheck source=../platform-common.sh
    . "$SCRIPTS/platform-common.sh"
    present_apps | tr '\n' ' '
  )"
  assert_eq "$present" "broken good " "present apps"
}

test_load_conf(){
  export PLATFORM_CONF="$WORK/platform.conf"
  printf 'RELEASES_BUCKET=rel\nBACKUPS_BUCKET=bak\n' > "$PLATFORM_CONF"
  local got
  got="$(
    # shellcheck source=../platform-common.sh
    . "$SCRIPTS/platform-common.sh"
    load_conf
    echo "$RELEASES_BUCKET $BACKUPS_BUCKET"
  )"
  assert_eq "$got" "rel bak" "buckets"
  unset PLATFORM_CONF
}

test_mariadb_cmd_uses_login_file(){
  export MYSQL_DEFAULTS="$WORK/my.cnf"
  touch "$MYSQL_DEFAULTS"
  local got
  got="$(
    # shellcheck source=../platform-common.sh
    . "$SCRIPTS/platform-common.sh"
    mariadb_cmd echo -e x
  )"
  assert_eq "$got" "--defaults-extra-file=$WORK/my.cnf -e x" "with login file"
  rm -f "$MYSQL_DEFAULTS"
  got="$(
    # shellcheck source=../platform-common.sh
    . "$SCRIPTS/platform-common.sh"
    mariadb_cmd echo x
  )"
  assert_eq "$got" "x" "without login file"
  unset MYSQL_DEFAULTS
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
