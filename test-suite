#!/usr/bin/env bash
# test-suite.sh — end-to-end CI for installer.sh + gpu-autopick (VMID 666)

set -euo pipefail
IFS=$'\n\t'

# ——— CONFIG ——————————————————————————————————————————————————————————
NODE="$(hostname -s)"
PROXY_HOST=127.0.0.1
PROXY_PORT=8443
TEST_VMID=666

# prompt for root@pam password so pvesh can auth via the proxy
if [[ -z "${PVE_PASSWORD:-}" ]]; then
  read -rsp "Enter Proxmox root@pam password: " PVE_PASSWORD
  echo
fi

export PVE_HOST="$PROXY_HOST"
export PVE_PORT="$PROXY_PORT"
export PVE_USER="root@pam"
export PVE_PASSWORD

# Color helpers
log()  { echo -e "\e[1;34m[TEST]\e[0m $*"; }
fail() { echo -e "\e[1;31m[FAIL]\e[0m $*"; exit 1; }
pass() { echo -e "\e[1;32m[ OK ]\e[0m $*"; }

# ——— 1. SYNTAX-CHECK installer.sh ————————————————————————————————————
log "Validating installer.sh syntax…"
bash -n installer.sh || fail "installer.sh has syntax errors"
pass "installer.sh parsed cleanly"

# ——— 2. RUN installer.sh —————————————————————————————————————————
log "Installing proxy & hook…"
bash installer.sh <<EOF
$(hostname -f)
/etc/ssl/nginx/pve-proxy.crt
/etc/ssl/nginx/pve-proxy.key
EOF
pass "installer.sh completed without error"

# ——— 3. VERIFY NGINX LISTENING ————————————————————————————————————
log "Waiting for nginx reload…"; sleep 2
ss -tunlp | grep -q ":$PROXY_PORT " || fail "port $PROXY_PORT not listening"
pass "nginx is listening on :$PROXY_PORT"

# ——— 4. FIRE THE LUA HOOK ————————————————————————————————————————
log "Triggering API hook via pvesh…"
pvesh create /nodes/$NODE/qemu/$TEST_VMID/status/start \
  &>/dev/null || echo "(expected fail: VM $TEST_VMID not exist yet)"

# check for our Lua-init marker
grep -q "

\[GPU\]

 nginx+lua is alive" /var/log/nginx/pve-proxy-error.log \
  || fail "Lua hook never initialized"
pass "Lua hook is alive"

# ——— 5. CREATE & START TEST VM —————————————————————————————————————
log "Creating VM $TEST_VMID…"
qm create $TEST_VMID \
  --name testGPU \
  --memory 128 \
  --net0 virtio,bridge=vmbr0 \
  --scsi0 local-lvm:2 \
  --ide2 local-lvm:cloudinit \
  --ciuser root \
  --cipassword password
pass "VM $TEST_VMID created"

log "Starting VM $TEST_VMID…"
pvesh create /nodes/$NODE/qemu/$TEST_VMID/status/start
pass "Start API call issued"

# ——— 6. WAIT & VERIFY GPU-PICK ————————————————————————————————————
log "Waiting for gpu-autopick output…"
for i in {1..10}; do
  grep -q "vm$TEST_VMID → acquired lock" /var/log/pve-hook-gpu.log && break
  sleep 1
done
grep -q "vm$TEST_VMID → GPU" /var/log/pve-hook-gpu.log \
  || fail "gpu-autopick did not assign a GPU"
pass "gpu-autopick assigned a GPU"

# ——— 7. STOP & VERIFY CLEANUP ————————————————————————————————————
log "Stopping VM $TEST_VMID…"
pvesh create /nodes/$NODE/qemu/$TEST_VMID/status/stop

for i in {1..10}; do
  grep -q "vm$TEST_VMID → cleared passthru" /var/log/pve-hook-gpu.log && break
  sleep 1
done
grep -q "vm$TEST_VMID → cleared passthru" /var/log/pve-hook-gpu.log \
  || fail "gpu-autopick did not clear passthru"
pass "gpu-autopick cleaned up on stop"

# ——— 8. TEARDOWN —————————————————————————————————————————————
log "Destroying VM $TEST_VMID…"
qm destroy $TEST_VMID --purge
pass "Test VM $TEST_VMID destroyed"

echo -e "\n🎉 All tests passed. Your one-shot installer is rock-solid!"
