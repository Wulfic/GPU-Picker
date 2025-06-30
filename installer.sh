#!/usr/bin/env bash
# installer.sh – install GPU-Picker (https://github.com/Wulfic/GPU-Picker) on Proxmox
set -euo pipefail
IFS=$'\n\t'

### ─── CONFIG ──────────────────────────────────────────────
GIT_REPO="https://github.com/Wulfic/GPU-Picker.git"
TMPDIR="$(mktemp -d)"
HOOK_SCRIPT="gpu-autopick.sh"
NGINX_CONF="pve-proxy.conf"

HOOK_DIR="/usr/local/share/pve-hook-scripts"
NGINX_SITES_AVAIL="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"

# OS packages required for nginx+Lua, JSON parsing, PCI utils, git
PKGS=(git nginx libnginx-mod-http-lua jq pciutils)

LOGFILE="/var/log/installer.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo ">>> INSTALLER START $(date -u)"

### ─── 1) INSTALL DEPENDENCIES ────────────────────────────
echo "Installing packages: ${PKGS[*]}"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"

### ─── 2) CLONE OR UPDATE REPO ────────────────────────────
if [ -d "$TMPDIR/.git" ]; then
  echo "Updating existing clone in $TMPDIR"
  git -C "$TMPDIR" pull --ff-only
else
  echo "Cloning $GIT_REPO → $TMPDIR"
  git clone "$GIT_REPO" "$TMPDIR"
fi

### ─── 3) DEPLOY NGINX CONFIG ─────────────────────────────
echo "Deploying nginx config → $NGINX_SITES_AVAIL/$NGINX_CONF"
install -Dm644 "$TMPDIR/$NGINX_CONF" "$NGINX_SITES_AVAIL/$NGINX_CONF"

echo "Enabling site → $NGINX_SITES_ENABLED/$NGINX_CONF"
ln -sf "../sites-available/$NGINX_CONF" "$NGINX_SITES_ENABLED/$NGINX_CONF"

### ─── 4) DEPLOY HOOK SCRIPT ─────────────────────────────
echo "Ensuring hook directory → $HOOK_DIR"
install -d -m755 "$HOOK_DIR"

echo "Copying hook script → $HOOK_DIR/$HOOK_SCRIPT"
install -Dm755 "$TMPDIR/$HOOK_SCRIPT" "$HOOK_DIR/$HOOK_SCRIPT"

### ─── 5) TEST & RELOAD NGINX ────────────────────────────
echo "Testing nginx configuration"
nginx -t

echo "Reloading nginx"
systemctl reload nginx

### ─── 6) CLEANUP ─────────────────────────────────────────
rm -rf "$TMPDIR"
echo ">>> INSTALLER COMPLETE $(date -u)"
