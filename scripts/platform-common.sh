#!/usr/bin/env bash
# Shared by platform-sync.sh, platform-deploy.sh, platform-backup.sh and
# platform-restore.sh; sourced, never run. Reads /etc/platform/platform.conf and
# the vm-app-<name> project metadata keys that the vm-app Terraform module
# writes, and validates them.
#
# Knobs (environment): PLATFORM_CONF (default /etc/platform/platform.conf),
# PLATFORM_METADATA_FILE (a JSON file read instead of the metadata server, for
# tests), MYSQL_DEFAULTS (default /root/.my.cnf, used when it exists).

PLATFORM_CONF="${PLATFORM_CONF:-/etc/platform/platform.conf}"
MYSQL_DEFAULTS="${MYSQL_DEFAULTS:-/root/.my.cnf}"
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/project/attributes/?recursive=true"
# 2-23 characters, as in Terraform, so app-<name> fits the 32-character user name limit.
APP_NAME_RE='^[a-z][a-z0-9-]{1,22}$'
DB_NAME_RE='^[a-z][a-z0-9_]{1,63}$'
PORT_RE='^[1-9][0-9]{3,4}$'
DEPLOY_USER_RE='^sa_[0-9]{1,40}$'
DOMAIN_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
HEALTH_PATH_RE='^/[A-Za-z0-9._~/-]*$'

log(){ echo "=== $* ==="; }
warn(){ echo "warning: $*" >&2; }
die(){ echo "error: $*" >&2; exit 1; }

# app_user <name>: the Linux user that owns /srv/<name> and runs the app's processes.
app_user(){ echo "app-$1"; }

# load_conf: sets RELEASES_BUCKET and BACKUPS_BUCKET from PLATFORM_CONF.
load_conf(){
  [ -r "$PLATFORM_CONF" ] || die "cannot read $PLATFORM_CONF"
  # shellcheck disable=SC1090
  . "$PLATFORM_CONF"
  [ -n "${RELEASES_BUCKET:-}" ] || die "RELEASES_BUCKET is not set in $PLATFORM_CONF"
  [ -n "${BACKUPS_BUCKET:-}" ] || die "BACKUPS_BUCKET is not set in $PLATFORM_CONF"
}

# mariadb_cmd <command> [args]: runs a MariaDB client, with the root login file
# when it exists (otherwise root logs in over the socket).
mariadb_cmd(){
  local cmd="$1"
  shift
  if [ -f "$MYSQL_DEFAULTS" ]; then
    "$cmd" --defaults-extra-file="$MYSQL_DEFAULTS" "$@"
  else
    "$cmd" "$@"
  fi
}

raw_metadata(){
  if [ -n "${PLATFORM_METADATA_FILE:-}" ]; then
    cat "$PLATFORM_METADATA_FILE"
  else
    curl -fsS --max-time 10 -H "Metadata-Flavor: Google" "$METADATA_URL"
  fi
}

# present_apps: the names of all vm-app-* keys, valid or not, one per line.
present_apps(){
  raw_metadata | jq -r 'keys[] | select(startswith("vm-app-")) | ltrimstr("vm-app-")'
}

# check_app <key> <value>: prints the app as normalised JSON when the value is
# valid; otherwise says why on stderr and returns 1.
check_app(){
  local key="$1" app name port db user health
  app="$(jq -cn --arg v "$2" '$v | fromjson? | select(type == "object")')"
  if [ -z "$app" ]; then
    warn "$key: the value is not a JSON object"
    return 1
  fi
  name="$(jq -r '.name // "" | tostring' <<<"$app")"
  port="$(jq -r '.port // "" | tostring' <<<"$app")"
  db="$(jq -r '.db // "" | tostring' <<<"$app")"
  user="$(jq -r '.deploy_user // "" | tostring' <<<"$app")"
  health="$(jq -r '.health_path // "/" | tostring' <<<"$app")"
  if ! [[ "$name" =~ $APP_NAME_RE ]]; then warn "$key: bad name '$name'"; return 1; fi
  if [ "$key" != "vm-app-$name" ]; then warn "$key: name '$name' does not match the key"; return 1; fi
  if ! [[ "$port" =~ $PORT_RE ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
    warn "$key: bad port '$port'"
    return 1
  fi
  if [ -n "$db" ] && ! [[ "$db" =~ $DB_NAME_RE ]]; then warn "$key: bad db '$db'"; return 1; fi
  if ! [[ "$user" =~ $DEPLOY_USER_RE ]]; then warn "$key: bad deploy_user '$user'"; return 1; fi
  if ! [[ "$health" =~ $HEALTH_PATH_RE ]]; then warn "$key: bad health_path '$health'"; return 1; fi
  if ! jq -e '.domains | type == "array" and length > 0 and all(type == "string")' <<<"$app" >/dev/null; then
    warn "$key: domains must be a non-empty list of host names"
    return 1
  fi
  # Checked per element inside jq: a bash line loop would accept a value with an
  # embedded newline as two valid domains. Control characters are refused outright.
  if ! jq -e --arg re "$DOMAIN_RE" \
    'all(.domains[]; (test("[[:cntrl:]]") | not) and test($re))' <<<"$app" >/dev/null; then
    warn "$key: bad domain (each must be a host name without control characters)"
    return 1
  fi
  jq -cn --arg name "$name" --argjson port "$port" --argjson domains "$(jq -c .domains <<<"$app")" \
    --arg db "$db" --arg health "$health" --arg user "$user" \
    '{name: $name, port: $port, domains: $domains, db: $db, health_path: $health, deploy_user: $user}'
}

# valid_apps: the valid apps as normalised JSON, one per line, sorted by name.
# Invalid apps are reported on stderr and left out, and so are both apps of a
# port claimed twice.
valid_apps(){
  local raw line key value app dup
  local -a apps=()
  raw="$(raw_metadata)" || die "cannot read the project metadata"
  while IFS= read -r line; do
    key="$(jq -r .key <<<"$line")"
    value="$(jq -r .value <<<"$line")"
    if app="$(check_app "$key" "$value")"; then
      apps+=("$app")
    fi
  done < <(jq -c 'to_entries[] | select(.key | startswith("vm-app-"))' <<<"$raw")
  [ "${#apps[@]}" -gt 0 ] || return 0
  dup="$(printf '%s\n' "${apps[@]}" | jq -r .port | sort | uniq -d)"
  for app in "${apps[@]}"; do
    if grep -qx "$(jq -r .port <<<"$app")" <<<"$dup"; then
      warn "vm-app-$(jq -r .name <<<"$app"): port $(jq -r .port <<<"$app") is used by another app"
      continue
    fi
    echo "$app"
  done | sort
}

# app_json <name>: the app's normalised JSON, or nothing when it is not a valid app.
app_json(){
  local apps
  apps="$(valid_apps)" || return 1
  [ -n "$apps" ] || return 0
  jq -c --arg name "$1" 'select(.name == $name)' <<<"$apps"
}
