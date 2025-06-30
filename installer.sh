#!/usr/bin/env bash
set -euo pipefail

# ─── 1. CHECK ROOT ─────────────────────────────────────────────────────────────
if (( EUID != 0 )); then
  echo "ERROR: must run as root"
  exit 1
fi

# ─── 2. GATHER INPUT ───────────────────────────────────────────────────────────
read -rp "Enter your Proxmox FQDN or IP (for SSL vhost): " SERVER_NAME
read -rp "Path to SSL certificate (e.g. /etc/ssl/nginx/pve-proxy.crt): " SSL_CERT
read -rp "Path to SSL key         (e.g. /etc/ssl/nginx/pve-proxy.key): " SSL_KEY

# ─── 3. INSTALL DEPENDENCIES ─────────────────────────────────────────────────
apt-get update
apt-get install -y nginx libnginx-mod-http-lua jq

# ─── 4. DROP NGINX PROXY CONFIG ────────────────────────────────────────────────
NGINX_CONF=/etc/nginx/sites-available/pve-proxy.conf

cat >"$NGINX_CONF" <<EOF
map \$http_upgrade \$connection_upgrade {
  default   upgrade;
  ''        close;
}

server {
  listen       8443 ssl;
  server_name  $SERVER_NAME;

  ssl_certificate     $SSL_CERT;
  ssl_certificate_key $SSL_KEY;

  access_by_lua_block {
    ngx.log(ngx.ERR, "[GPU] nginx+lua is alive")
  }

  location ~ ^/api2/(?:json|extjs)/nodes/[^/]+/qemu/\\d+/status/(?:start|stop|shutdown|reboot|reset)\$ {
    access_by_lua_block {
      local uri    = ngx.var.request_uri
      local vmid   = uri:match("/qemu/(%d+)/status")
      local action = uri:match("/status/(%a+)\$")
      local mode   = (action=="start") and "pre-start" or "post-stop"
      ngx.log(ngx.ERR, "[GPU] vm", vmid, "→ hooking", action, "as", mode)
      local cmd = "sudo /usr/local/share/pve-hook-scripts/gpu-autopick.sh "
                .. vmid .. " " .. mode .. " 2>&1"
      local h   = io.popen(cmd)
      local out = h:read("*a")
      local ok, typ, st = h:close()
      ngx.log(ngx.ERR,
        "[GPU] cmd=", cmd,
        " ok=", tostring(ok),
        " type=", typ or "-",
        " stat=", tostring(st),
        " output=", out:gsub("\\n","\\\\n"))
    }

    proxy_http_version 1.1;
    proxy_set_header  Upgrade             \$http_upgrade;
    proxy_set_header  Connection          \$connection_upgrade;
    proxy_set_header  Host                \$host;
    proxy_set_header  X-Real-IP           \$remote_addr;
    proxy_set_header  Authorization       \$http_authorization;
    proxy_set_header  Cookie              \$http_cookie;
    proxy_set_header  CSRFPreventionToken \$http_csrfpreventiontoken;
    proxy_ssl_verify  off;
    proxy_connect_timeout 60s;
    proxy_send_timeout    60s;
    proxy_read_timeout    60s;
    proxy_pass https://127.0.0.1:8006;
  }

  location / {
    proxy_http_version 1.1;
    proxy_set_header  Upgrade             \$http_upgrade;
    proxy_set_header  Connection          \$connection_upgrade;
    proxy_set_header  Host                \$host;
    proxy_set_header  X-Real-IP           \$remote_addr;
    proxy_set_header  Authorization       \$http_authorization;
    proxy_set_header  Cookie              \$http_cookie;
    proxy_set_header  CSRFPreventionToken \$http_csrfpreventiontoken;
    proxy_ssl_verify  off;
    proxy_read_timeout   3600s;
    proxy_send_timeout   3600s;
    proxy_pass https://127.0.0.1:8006;
  }

  access_log  /var/log/nginx/pve-proxy-access.log;
  error_log   /var/log/nginx/pve-proxy-error.log debug;
}
EOF

ln -fs "$NGINX_CONF" /etc/nginx/sites-enabled/pve-proxy.conf

# ─── 5. DROP GPU AUTOPICK HOOK ────────────────────────────────────────────────
HOOK_DIR=/usr/local/share/pve-hook-scripts
HOOK_SCRIPT=$HOOK_DIR/gpu-autopick.sh

mkdir -p "$HOOK_DIR"
cat >"$HOOK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
VMID="${1:?Usage: $0 VMID [pre-start|post-stop]}"
EVENT="${2:-pre-start}"
NODE="$(hostname -s)"
LOG=/var/log/pve-hook-gpu.log
exec >>"$LOG" 2>&1
trap 'exit 0' ERR
set -euo pipefail

log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
if [[ "$EVENT" != pre-start && "$EVENT" != post-stop ]]; then exit 0; fi

LOCKDIR="/run/lock/pve-gpu-autopick.$VMID.lck"
mkdir -p /run/lock
if mkdir "$LOCKDIR" 2>/dev/null; then
  trap 'rmdir "$LOCKDIR"' EXIT
  log "vm$VMID → acquired lock"
else
  log "vm$VMID → lock exists, exiting"
  exit 0
fi

run_set(){ pvesh set /nodes/$NODE/qemu/"$VMID"/config "$@" &>/dev/null && log "set: $*"; }
clear_passthru(){ for k in hostpci0 hostpci1 vga mapping; do run_set --delete "$k"; done; log "cleared passthru"; }

if pvesh get /nodes/$NODE/qemu/"$VMID"/config --output-format=json \
   | jq -er '.tags // "" | contains("no-gpu-autopick")' &>/dev/null; then
  log "vm$VMID → skipping (tag)"
  exit 0
fi

if [[ "$EVENT" == post-stop ]]; then clear_passthru; exit 0; fi
log "vm$VMID → pre-start"
CONF=/etc/pve/qemu-server/"$VMID".conf

HOST_GPU=""
if [[ -e /sys/class/graphics/fb0/device ]]; then
  HOST_GPU="$(basename "$(readlink -f /sys/class/graphics/fb0/device)")"
  log "host console GPU: $HOST_GPU"
fi

# cleanup stale vfio-pci
for D in /sys/bus/pci/devices/0000:[0-9a-f][0-9a-f]:00.0; do
  [[ -d "$D/driver" ]] || continue
  [[ "$(basename "$(readlink -f "$D/driver")")" == "vfio-pci" ]] || continue
  DEV="${D##*/}"
  echo "$DEV" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
  log "cleanup unbound $DEV"
done

CANDS=()
for P in /sys/bus/pci/devices/0000:*:00.0; do
  DEV="${P##*/}"
  [[ "$DEV" =~ ^0000:01: ]] && continue
  [[ "$DEV" == "$HOST_GPU" ]] && continue
  vend=$(<"$P/vendor")
  [[ "$vend" != "0x10de" ]] && continue
  CANDS+=("$DEV")
done
log "candidates: ${CANDS[*]:-none}"

mapfile -t RUNNING < <(qm list | awk '$3=="running"{print $1}')
USED="$(for VM in "${RUNNING[@]}"; do
  sed -n 's/^hostpci[0-9]\+: *\(0000:[0-9a-f:.]\+\).*/\1/p' "/etc/pve/qemu-server/$VM.conf"
done | sort -u)"
log "used: ${USED:-none}"

EXIST=$(sed -En 's/^hostpci0:\s+([^,]+).*/\1/p' "$CONF" || echo "")
if [[ -n "$EXIST" ]]; then
  if grep -Fxq "$EXIST" <<<"$USED"; then
    log "existing $EXIST in use—clearing"
    clear_passthru
  else
    log "existing $EXIST free—keeping"
    exit 0
  fi
fi

FREE=""
for DEV in "${CANDS[@]}"; do
  grep -qxF "$DEV" <<<"$USED" && continue
  drv=$(lspci -k -s "$DEV" 2>/dev/null | awk -F': ' '/Kernel driver in use/ {print $2}')
  [[ "$drv" == "vfio-pci" ]] && continue
  FREE="$DEV"; break
done

if [[ -z "$FREE" ]]; then
  orig_vga=$(grep -m1 '^vga:' "$CONF" | awk '{print $2}' || echo "")
  log "no free GPU; orig_vga='$orig_vga'"
  if [[ -z "$orig_vga" || "$orig_vga" == "none" ]]; then
    log "falling back to QXL" ; clear_passthru ; run_set --vga qxl
  else
    log "preserving vga='$orig_vga'"
  fi
  exit 0
fi
log "selected GPU $FREE"

if [[ -d /sys/bus/pci/devices/$FREE/driver ]]; then
  OLD=$(basename "$(readlink -f /sys/bus/pci/devices/$FREE/driver)")
  echo "$FREE" > /sys/bus/pci/drivers/$OLD/unbind 2>/dev/null && log "unbound $FREE from $OLD"
fi

ven_id=$(sed 's/^0x//' /sys/bus/pci/devices/$FREE/vendor)
dev_id=$(sed 's/^0x//' /sys/bus/pci/devices/$FREE/device)
echo "$ven_id $dev_id" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null && log "vfio new_id($ven_id $dev_id)"
echo "$FREE" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null && log "bound $FREE"

AUDIO="${FREE%.*}.1"
if [[ -e /sys/bus/pci/devices/$AUDIO ]]; then
  if [[ -d /sys/bus/pci/devices/$AUDIO/driver ]]; then
    AOLD=$(basename "$(readlink -f /sys/bus/pci/devices/$AUDIO/driver)")
    echo "$AUDIO" > /sys/bus/pci/drivers/$AOLD/unbind 2>/dev/null && log "unbound audio $AUDIO"
  fi
  van=$(sed 's/^0x//' /sys/bus/pci/devices/$AUDIO/vendor)
  dan=$(sed 's/^0x//' /sys/bus/pci/devices/$AUDIO/device)
  echo "$van $dan" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null && log "vfio new_id(audio $van $dan)"
  echo "$AUDIO" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null && log "bound audio $AUDIO"
fi

clear_passthru
run_set --hostpci0 "$FREE,pcie=1,x-vga=1" \
        --hostpci1 "${AUDIO:-},pcie=1" \
        --vga none
log "vm$VMID → GPU $FREE passthrough"
exit 0
EOF

chmod +x "$HOOK_SCRIPT"

# ─── 6. RELOAD NGINX ───────────────────────────────────────────────────────────
systemctl reload nginx

echo -e "\n✅ Installation complete!"
echo " • Proxy is listening on https://$SERVER_NAME:8443"
echo " • Hook script installed at $HOOK_SCRIPT"
echo " • Check logs: /var/log/pve-hook-gpu.log & /var/log/nginx/pve-proxy-error.log"
echo " • Tag any VM with 'no-gpu-autopick' to skip."
