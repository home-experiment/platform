#!/usr/bin/env bash
# Applies the vm-app-<name> project metadata keys to this VM. For each valid
# app: /srv/<name> directories, its database, its Caddy site, the deploy-<name>
# wrapper and the sudoers rule that lets the app's deploy account run only that
# wrapper. Files of apps whose key is gone are removed (directories and
# databases never are); an invalid app keeps what it had. Runs as root, from
# startup.sh on every boot and from platform-deploy.sh before every activation;
# re-running is harmless. Exits non-zero when any step failed.
#
# Knobs (environment), mostly for tests: SRV_DIR (/srv), CADDY_SITES
# (/etc/caddy/sites), CADDYFILE (/etc/caddy/Caddyfile), BIN_DIR
# (/usr/local/bin), SUDOERS_DIR (/etc/sudoers.d), APP_USER (app), and those of
# platform-common.sh.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=platform-common.sh
. "$LIB_DIR/platform-common.sh"

SRV_DIR="${SRV_DIR:-/srv}"
CADDY_SITES="${CADDY_SITES:-/etc/caddy/sites}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
APP_USER="${APP_USER:-app}"
FAILED=0
CADDY_CHANGED=0

# install_file <path> <mode>: writes stdin to path when the content differs.
# Returns 0 when the file changed, 1 when it was already up to date.
install_file(){
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if cmp -s "$tmp" "$1"; then
    rm -f "$tmp"
    return 1
  fi
  install -m "$2" "$tmp" "$1"
  rm -f "$tmp"
  return 0
}

caddy_site(){
  local domains port
  domains="$(jq -r '.domains | join(", ")' <<<"$1")"
  port="$(jq -r .port <<<"$1")"
  cat <<EOF
$domains {
	# Deferred so it replaces an HSTS header the app already sends.
	header {
		Strict-Transport-Security "max-age=31536000"
		defer
	}
	reverse_proxy 127.0.0.1:$port
}
EOF
}

sync_dirs(){
  local root="$SRV_DIR/$1"
  mkdir -p "$root/releases" "$root/shared/logs"
  chown "$APP_USER:$APP_USER" "$root" "$root/releases" "$root/shared" "$root/shared/logs"
}

sync_db(){
  [ -n "$1" ] || return 0
  mariadb_cmd mariadb -e "CREATE DATABASE IF NOT EXISTS \`$1\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
}

sync_wrapper(){
  install_file "$BIN_DIR/deploy-$1" 755 <<EOF || true
#!/bin/bash
# Written by platform-sync: the only command the $1 deploy account may run with
# sudo. platform-deploy.sh checks the arguments.
exec $LIB_DIR/platform-deploy.sh --app $1 "\$@"
EOF
}

# sync_sudoers <name> <deploy user>: installs the rule only when visudo accepts it.
sync_sudoers(){
  local tmp
  tmp="$(mktemp)"
  echo "$2 ALL=(root) NOPASSWD: $BIN_DIR/deploy-$1" > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn "vm-app-$1: visudo rejected the sudoers rule; not installed"
    return 1
  fi
  install_file "$SUDOERS_DIR/platform-$1" 440 < "$tmp" || true
  rm -f "$tmp"
}

sync_app(){
  local app="$1" name
  name="$(jq -r .name <<<"$app")"
  log "Syncing $name"
  sync_dirs "$name" || { warn "$name: directories failed"; FAILED=1; }
  sync_db "$(jq -r .db <<<"$app")" || { warn "$name: database failed"; FAILED=1; }
  if install_file "$CADDY_SITES/$name.caddy" 644 < <(caddy_site "$app"); then
    CADDY_CHANGED=1
  fi
  sync_wrapper "$name"
  sync_sudoers "$name" "$(jq -r .deploy_user <<<"$app")" || FAILED=1
}

# remove_gone <present names>: drops the files of apps that have no metadata key.
remove_gone(){
  local present="$1" file name
  for file in "$CADDY_SITES"/*.caddy "$BIN_DIR"/deploy-* "$SUDOERS_DIR"/platform-*; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    name="${name%.caddy}"
    name="${name#deploy-}"
    name="${name#platform-}"
    if ! grep -qx "$name" <<<"$present"; then
      log "Removing $file (vm-app-$name is gone)"
      rm -f "$file"
      case "$file" in *.caddy) CADDY_CHANGED=1 ;; esac
    fi
  done
}

reload_caddy(){
  [ "$CADDY_CHANGED" = 1 ] || return 0
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    warn "the Caddy config does not validate; Caddy keeps running the previous one"
    FAILED=1
    return 0
  fi
  systemctl reload-or-restart caddy || FAILED=1
}

main(){
  local present apps app
  mkdir -p "$CADDY_SITES"
  present="$(present_apps)" || die "cannot read the project metadata"
  apps="$(valid_apps)" || die "cannot read the project metadata"
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    sync_app "$app"
  done <<<"$apps"
  remove_gone "$present"
  reload_caddy
  exit "$FAILED"
}

main "$@"
