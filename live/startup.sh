#!/bin/bash
# Bootstrap for the shared VM (film-picker-vm), run by the Google guest agent
# on every boot. Rendered by Terraform templatefile(): it fills in the bucket
# names and pastes in the platform scripts from ../scripts; the script's own
# variables are written without braces. Every step checks before it changes
# something, so re-running is harmless. To apply a change without a reboot:
# terraform apply, then on the VM: sudo google_metadata_script_runner startup
# shellcheck disable=SC2154
set -euo pipefail

LIB=/usr/local/lib/platform
NODE_MAJOR=24
export DEBIAN_FRONTEND=noninteractive

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

# Backups (04:30) and the apps' own jobs run on local time.
timedatectl set-timezone Europe/Tallinn

# File names below that mention film-picker predate the platform; they are kept
# so that nothing restarts because a file moved.

# 2 GB swap: MariaDB and every app's Node processes share the VM's RAM.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
grep -q '^/swapfile ' /proc/swaps || swapon /swapfile
if install_file /etc/sysctl.d/99-film-picker.conf 644 <<'EOF'
vm.swappiness = 10
EOF
then
  sysctl -q -p /etc/sysctl.d/99-film-picker.conf
fi

# Wait for the dpkg lock (unattended-upgrades on first boot) instead of failing.
install_file /etc/apt/apt.conf.d/90-film-picker 644 <<'EOF' || true
DPkg::Lock::Timeout "300";
EOF

# Packages: Debian's MariaDB and Caddy, Node from NodeSource, PM2 from npm.
if ! command -v mariadb >/dev/null || ! command -v caddy >/dev/null || ! command -v jq >/dev/null \
  || ! command -v nft >/dev/null; then
  apt-get update
  apt-get install -y mariadb-server caddy gzip curl jq sudo nftables
fi
if ! command -v node >/dev/null || ! node -v | grep -q "^v$NODE_MAJOR\."; then
  curl -fsSL "https://deb.nodesource.com/setup_$NODE_MAJOR.x" | bash -
  apt-get install -y nodejs
fi
command -v pm2 >/dev/null || npm install -g pm2

# MariaDB: local only, sized for a small VM. platform-sync creates each app's
# database; each app's user is created by hand (platform README).
if install_file /etc/mysql/mariadb.conf.d/90-film-picker.cnf 644 <<'EOF'
[mysqld]
bind-address = 127.0.0.1
innodb_buffer_pool_size = 128M
performance_schema = OFF
max_connections = 30
EOF
then
  systemctl restart mariadb
fi

# Each app runs as its own user app-<name> with its own PM2 daemon; platform-sync
# creates them. Every user with uid 1000 or above (apps, deploy accounts, people)
# is blocked from the metadata server, except DNS on port 53: platform-sync writes
# /etc/nftables.d/platform.nft, which nftables.service loads on every boot before
# the apps start.
install -d /etc/nftables.d
if ! grep -q '^include "/etc/nftables.d/\*.nft"' /etc/nftables.conf; then
  echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
fi
systemctl enable nftables

# Platform config and scripts (scripts/ in the platform repository).
install -d /etc/platform "$LIB"
install_file /etc/platform/platform.conf 644 <<EOF || true
RELEASES_BUCKET=${releases_bucket}
BACKUPS_BUCKET=${backups_bucket}
EOF
install_file "$LIB/platform-common.sh" 644 <<'PLATFORM_SCRIPT' || true
${platform_common}
PLATFORM_SCRIPT
install_file "$LIB/platform-sync.sh" 755 <<'PLATFORM_SCRIPT' || true
${platform_sync}
PLATFORM_SCRIPT
install_file "$LIB/platform-deploy.sh" 755 <<'PLATFORM_SCRIPT' || true
${platform_deploy}
PLATFORM_SCRIPT
install_file "$LIB/platform-backup.sh" 755 <<'PLATFORM_SCRIPT' || true
${platform_backup}
PLATFORM_SCRIPT
for script in sync deploy backup; do
  ln -sfn "$LIB/platform-$script.sh" "/usr/local/bin/platform-$script"
done

# Caddy: one site per app in sites/, written by platform-sync.
install -d /etc/caddy/sites
caddyfile_changed=0
if install_file /etc/caddy/Caddyfile 644 <<'EOF'
# One site per app, written by platform-sync from the vm-app-* metadata keys.
import /etc/caddy/sites/*.caddy
EOF
then
  caddyfile_changed=1
fi

# film-picker's own backup job predates the platform; platform-backup replaces it.
if [ -e /etc/systemd/system/film-picker-backup.timer ]; then
  systemctl disable --now film-picker-backup.timer || true
  rm -f /etc/systemd/system/film-picker-backup.timer /etc/systemd/system/film-picker-backup.service \
    /usr/local/bin/film-picker-backup
fi

# Nightly dump of every app database to Cloud Storage.
install_file /etc/systemd/system/platform-backup.service 644 <<'EOF' || true
[Unit]
Description=Dump every app database to Cloud Storage

[Service]
Type=oneshot
ExecStart=/usr/local/lib/platform/platform-backup.sh
# A hung dump or upload must not block the timer forever.
TimeoutStartSec=1h
EOF
install_file /etc/systemd/system/platform-backup.timer 644 <<'EOF' || true
[Unit]
Description=Nightly app database backups

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now platform-backup.timer

# Apps: directories, databases, Caddy sites, deploy wrappers and sudoers rules.
"$LIB/platform-sync.sh" || echo "platform-sync reported problems; see above" >&2
if [ "$caddyfile_changed" = 1 ] && caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  systemctl reload-or-restart caddy
elif [ "$caddyfile_changed" = 1 ]; then
  echo "the Caddy config does not validate; Caddy keeps its previous config" >&2
fi
