#!/usr/bin/env bash
# Applies the vm-app-<name> project metadata keys to this VM. For each valid
# app: its own Linux user app-<name> (home HOME_BASE/app-<name>), /srv/<name>
# directories owned by that user, its database, its Caddy site, the
# deploy-<name> wrapper, the sudoers rule that lets the app's deploy account run
# only that wrapper, and a PM2 systemd unit that resurrects the user's processes
# at boot. Then an nftables table that stops every app user from reaching the
# metadata server (169.254.169.254), which hands out the VM service account's
# credentials; only DNS (port 53) on that address stays open to them. Files of apps whose key is gone are removed (users, directories
# and databases never are, and the users stay blocked); an invalid app keeps
# what it had. A Caddy config that does not validate is rolled back to the
# previous snippets and not reloaded. Runs as root, from startup.sh on every
# boot and from platform-deploy.sh before every activation; re-running is
# harmless. Exits non-zero when any step failed.
#
# Only /srv/<name> itself is created, chowned and chmodded (750), as root. Its
# subdirectories are created as the app user, so the app (which owns everything
# below /srv/<name>) cannot make root follow a symlink it planted.
#
# Knobs (environment), mostly for tests: SRV_DIR (/srv), HOME_BASE (/home),
# CADDY_SITES (/etc/caddy/sites), CADDYFILE (/etc/caddy/Caddyfile), BIN_DIR
# (/usr/local/bin), SUDOERS_DIR (/etc/sudoers.d), SYSTEMD_DIR
# (/etc/systemd/system), NFT_FILE (/etc/nftables.d/platform.nft), and those of
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
HOME_BASE="${HOME_BASE:-/home}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
NFT_FILE="${NFT_FILE:-/etc/nftables.d/platform.nft}"
FAILED=0
CADDY_CHANGED=0
CHANGES_DIR=""

# install_file <path> <mode>: writes stdin to path when the content differs.
# Returns 0 when the file changed, 2 when it was already up to date, 1 when a
# step failed (the temporary file is removed on every path).
install_file(){
  local tmp
  tmp="$(mktemp)" || return 1
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "$1"; then
    rm -f "$tmp"
    return 2
  fi
  if ! install -m "$2" "$tmp" "$1"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

# snapshot <path>: remembers the previous state of a Caddy snippet, once per
# run, so restore_snippets can undo this run's changes.
snapshot(){
  local path="$1" key
  key="$(basename "$path")"
  if grep -qxF "$path" "$CHANGES_DIR/list"; then
    return 0
  fi
  if [ -e "$path" ]; then
    cp -p "$path" "$CHANGES_DIR/$key.old"
  fi
  echo "$path" >> "$CHANGES_DIR/list"
}

# restore_snippets: puts back every snippet this run touched; snippets that did
# not exist before are removed.
restore_snippets(){
  local path key
  while IFS= read -r path; do
    key="$(basename "$path")"
    if [ -f "$CHANGES_DIR/$key.old" ]; then
      cp -p "$CHANGES_DIR/$key.old" "$path"
    else
      rm -f "$path"
    fi
  done < "$CHANGES_DIR/list"
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

# sync_user <name>: creates the app's Linux user and group when missing.
sync_user(){
  local user
  user="$(app_user "$1")"
  if id -u "$user" >/dev/null 2>&1; then return 0; fi
  log "Creating the user $user"
  useradd --create-home --home-dir "$HOME_BASE/$user" --shell /bin/bash --user-group "$user"
}

# sync_dirs <name>: /srv/<name> is created and given to the app as root (only
# that directory, not following links; /srv is root's, so it cannot be swapped);
# everything below it is made as the app.
sync_dirs(){
  local root="$SRV_DIR/$1" user
  user="$(app_user "$1")"
  mkdir -p "$root" \
    && chown -h "$user:$user" "$root" \
    && chmod 750 "$root" \
    && runuser -u "$user" -- mkdir -p "$root/releases" "$root/shared/logs"
}

# sync_pm2_boot <name>: a systemd unit that starts the user's PM2 daemon at
# boot and resurrects its saved processes. pm2 writes it once.
sync_pm2_boot(){
  local user
  user="$(app_user "$1")"
  [ ! -e "$SYSTEMD_DIR/pm2-$user.service" ] || return 0
  pm2 startup systemd -u "$user" --hp "$HOME_BASE/$user" >/dev/null
}

sync_db(){
  [ -n "$1" ] || return 0
  mariadb_cmd mariadb -e "CREATE DATABASE IF NOT EXISTS \`$1\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
}

sync_wrapper(){
  local rc=0
  install_file "$BIN_DIR/deploy-$1" 755 <<EOF || rc=$?
#!/bin/bash
# Written by platform-sync: the only command the $1 deploy account may run with
# sudo. platform-deploy.sh checks the arguments.
exec $LIB_DIR/platform-deploy.sh --app $1 "\$@"
EOF
  case "$rc" in
    0|2) ;;
    *) warn "$1: cannot write $BIN_DIR/deploy-$1"; FAILED=1 ;;
  esac
}

# sync_sudoers <name> <deploy user>: installs the rule only when visudo accepts it.
sync_sudoers(){
  local tmp rc=0
  tmp="$(mktemp)" || { warn "vm-app-$1: cannot create a temporary file"; return 1; }
  if ! { echo "$2 ALL=(root) NOPASSWD: $BIN_DIR/deploy-$1" > "$tmp"; }; then
    rm -f "$tmp"
    warn "vm-app-$1: cannot write the sudoers rule"
    return 1
  fi
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn "vm-app-$1: visudo rejected the sudoers rule; not installed"
    return 1
  fi
  install_file "$SUDOERS_DIR/platform-$1" 440 < "$tmp" || rc=$?
  rm -f "$tmp"
  case "$rc" in
    0|2) return 0 ;;
    *) warn "$1: cannot write $SUDOERS_DIR/platform-$1"; return 1 ;;
  esac
}

sync_app(){
  local app="$1" name rc=0
  name="$(jq -r .name <<<"$app")"
  log "Syncing $name"
  if ! sync_user "$name"; then
    warn "$name: cannot create the user $(app_user "$name"); the app is not synced"
    FAILED=1
    return 0
  fi
  sync_dirs "$name" || { warn "$name: directories failed"; FAILED=1; }
  sync_db "$(jq -r .db <<<"$app")" || { warn "$name: database failed"; FAILED=1; }
  snapshot "$CADDY_SITES/$name.caddy"
  install_file "$CADDY_SITES/$name.caddy" 644 < <(caddy_site "$app") || rc=$?
  case "$rc" in
    0) CADDY_CHANGED=1 ;;
    2) ;;
    *) warn "$name: cannot write $CADDY_SITES/$name.caddy"; FAILED=1 ;;
  esac
  sync_wrapper "$name"
  sync_sudoers "$name" "$(jq -r .deploy_user <<<"$app")" || FAILED=1
  sync_pm2_boot "$name" || { warn "$name: pm2 startup failed"; FAILED=1; }
}

# app_uids <present names>: the uids of the existing app users, numerically
# sorted and joined with ", ". Besides the apps that have a metadata key, the
# names of the /srv directories (root's, never removed) are checked, so the
# users of removed apps stay blocked.
app_uids(){
  local dir name uid
  {
    printf '%s\n' "$1"
    for dir in "$SRV_DIR"/*/; do
      [ -d "$dir" ] || continue
      basename "$dir"
    done
  } | sort -u | while IFS= read -r name; do
    [[ "$name" =~ $APP_NAME_RE ]] || continue
    uid="$(id -u "$(app_user "$name")" 2>/dev/null)" || continue
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    echo "$uid"
  done | sort -nu | paste -sd, - | sed 's/,/, /g'
}

# nft_rules <uids>: the nftables table; without uids the chain stays empty.
nft_rules(){
  cat <<'EOF'
# Written by platform-sync: app users may not reach the metadata server, which
# hands out the VM service account's credentials. DNS (port 53) on the same
# address stays allowed.
table inet platform
delete table inet platform
table inet platform {
	chain output {
		type filter hook output priority 0; policy accept;
EOF
  if [ -n "$1" ]; then
    printf '\t\tip daddr 169.254.169.254 meta skuid { %s } th dport != 53 reject\n' "$1"
  fi
  printf '\t}\n}\n'
}

# sync_nft <present names>: writes NFT_FILE and loads it when it changed or
# the table is not loaded (after a reboot).
sync_nft(){
  local rc=0
  if ! mkdir -p "$(dirname "$NFT_FILE")"; then
    warn "cannot create $(dirname "$NFT_FILE")"
    FAILED=1
    return 0
  fi
  install_file "$NFT_FILE" 644 < <(nft_rules "$(app_uids "$1")") || rc=$?
  case "$rc" in
    0) ;;
    2) if nft list table inet platform >/dev/null 2>&1; then return 0; fi ;;
    *) warn "cannot write $NFT_FILE"; FAILED=1; return 0 ;;
  esac
  log "Loading $NFT_FILE"
  if ! nft -f "$NFT_FILE"; then
    warn "nft cannot load $NFT_FILE; app users may still reach the metadata server"
    FAILED=1
  fi
}

# ours_wrapper <file>: true when the file was written by this script.
ours_wrapper(){
  grep -qF '# Written by platform-sync' "$1"
}

# ours_sudoers <file> <name>: true when the file is exactly the rule this
# script writes for the app (one line, deploy user sa_<digits>).
ours_sudoers(){
  local content line
  [ "$(wc -l < "$1" | tr -d ' ')" = 1 ] || return 1
  content="$(cat "$1")"
  [[ "$content" =~ ^sa_[0-9]+\ ALL=\(root\)\ NOPASSWD:\ (.+)$ ]] || return 1
  line="${BASH_REMATCH[1]}"
  [ "$line" = "$BIN_DIR/deploy-$2" ]
}

# remove_gone <present names>: drops the files of apps that have no metadata key.
# Caddy snippets all belong to the platform; a wrapper or sudoers rule is removed
# only when this script wrote it.
remove_gone(){
  local present="$1" file name
  for file in "$CADDY_SITES"/*.caddy; do
    [ -e "$file" ] || continue
    name="$(basename "$file" .caddy)"
    if ! grep -qx "$name" <<<"$present"; then
      log "Removing $file (vm-app-$name is gone)"
      snapshot "$file"
      rm -f "$file"
      CADDY_CHANGED=1
    fi
  done
  for file in "$BIN_DIR"/deploy-*; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    name="${name#deploy-}"
    if ! grep -qx "$name" <<<"$present" && ours_wrapper "$file"; then
      log "Removing $file (vm-app-$name is gone)"
      rm -f "$file"
    fi
  done
  for file in "$SUDOERS_DIR"/platform-*; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    name="${name#platform-}"
    if ! grep -qx "$name" <<<"$present" && ours_sudoers "$file" "$name"; then
      log "Removing $file (vm-app-$name is gone)"
      rm -f "$file"
    fi
  done
}

reload_caddy(){
  [ "$CADDY_CHANGED" = 1 ] || return 0
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    warn "the Caddy config does not validate; the snippets of this run are rolled back and Caddy keeps running the previous config"
    restore_snippets
    FAILED=1
    return 0
  fi
  systemctl reload-or-restart caddy || FAILED=1
}

main(){
  local present apps app
  mkdir -p "$CADDY_SITES"
  CHANGES_DIR="$(mktemp -d)"
  trap 'rm -rf "$CHANGES_DIR"' EXIT
  : > "$CHANGES_DIR/list"
  present="$(present_apps)" || die "cannot read the project metadata"
  apps="$(valid_apps)" || die "cannot read the project metadata"
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    sync_app "$app"
  done <<<"$apps"
  remove_gone "$present"
  sync_nft "$present"
  reload_caddy
  exit "$FAILED"
}

main "$@"
