#!/usr/bin/env bash
#
# NVIDIA v2/v3-only Auto-Picker for Proxmox VE
#   – Ignores slot 1 & host console GPU
#   – Dynamically discovers NVIDIA devices
#   – Only counts GPUs assigned to *running* VMs as “in use”
#   – Allows IOMMU groups of 1 (GPU alone) or 2 (GPU+audio)
#   – Binds both GPU (hostpci0) and its audio function (hostpci1)
#   – Clears mapping/vga on post-stop
# ----------------------------------------------------------------------------

# 1) Grab & default args before “set -u”
VMID="${1:?Usage: $0 VMID [pre-start|post-stop]}"
EVENT="${2:-pre-start}"
NODE="$(hostname -s)"

# 2) All output → our log
LOG=/var/log/pve-hook-gpu.log
exec >>"$LOG" 2>&1

# 3) Only “exit 1” aborts; any other error just logs & exit 0
trap 'exit 0' ERR
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# Only handle pre-start / post-stop
[[ "$EVENT" != pre-start && "$EVENT" != post-stop ]] && exit 0

# ==== SINGLE-INSTANCE GUARD via mkdir() ====
LOCK_BASE="/run/lock/pve-gpu-autopick.$VMID"
LOCKDIR="${LOCK_BASE}.lck"
mkdir -p /run/lock
if mkdir "$LOCKDIR" 2>/dev/null; then
  trap 'rmdir "$LOCKDIR"' EXIT
  log "vm$VMID → acquired single-instance lock"
else
  log "another instance for vm$VMID is running, exit"
  exit 0
fi

# Helper: call pvesh set without aborting the hook
run_set() {
  if pvesh set /nodes/$NODE/qemu/"$VMID"/config "$@" &>/dev/null; then
    log "vm$VMID → pvesh set: $*"
  else
    log "vm$VMID → pvesh set FAILED (ignored): $*"
  fi
}

# Helper: clear passthrough/mapping/vga  (split deletes so one bad key won't abort)
clear_passthru() {
  for key in hostpci0 hostpci1 vga mapping; do
    run_set --delete "$key"
  done
  log "vm$VMID → cleared passthrough + mapping"
}



# 0) Skip VMs tagged no-gpu-autopick
if pvesh get /nodes/$NODE/qemu/"$VMID"/config \
     --output-format=json \
   | jq -er '.tags // "" | contains("no-gpu-autopick")' &>/dev/null; then
  log "vm$VMID → skipping (no-gpu-autopick tag)"
  exit 0
fi

# 1) Detect host console GPU (slot 1)
HOST_GPU=""
if [[ -e /sys/class/graphics/fb0/device ]]; then
  HOST_GPU="$(basename "$(readlink -f /sys/class/graphics/fb0/device)")"
  log "detected host console GPU: $HOST_GPU"
fi

# 2) On post-stop, just clear & exit
if [[ "$EVENT" == post-stop ]]; then
  clear_passthru
  exit 0
fi

# ==== PRE-START ====
log "vm$VMID → pre-start"

CONF=/etc/pve/qemu-server/"$VMID".conf

# 3) Unbind stale vfio-pci globally
for D in /sys/bus/pci/devices/0000:[0-9a-f][0-9a-f]:00.0; do
  [[ -d "$D/driver" ]] || continue
  [[ "$(basename "$(readlink -f "$D/driver")")" == "vfio-pci" ]] || continue
  DEV="${D##*/}"
  echo "$DEV" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
  log "cleanup: unbound stale vfio-pci $DEV"
done

# 4) Build NVIDIA candidate list
CANDS=()
for P in /sys/bus/pci/devices/0000:*:00.0; do
  DEV="${P##*/}"
  [[ "$DEV" =~ ^0000:01: ]]   && { log "skip $DEV (slot 1)"; continue; }
  [[ "$DEV" == "$HOST_GPU" ]] && { log "skip $DEV (host console)"; continue; }
  vend=$(<"$P/vendor")
  [[ "$vend" == "0x10de" ]]   || { log "skip $DEV (vendor $vend)"; continue; }
  CANDS+=("$DEV")
done
log "vm$VMID → candidate slots: ${CANDS[*]:-none}"

# 5) GPUs in use by running VMs
mapfile -t RUNNING < <(qm list | awk '$3=="running"{print $1}')
USED="$(
  for VM in "${RUNNING[@]}"; do
    sed -n 's/^hostpci[0-9]\+: *\(0000:[0-9a-f:.]\+\).*/\1/p' \
      "/etc/pve/qemu-server/$VM.conf"
  done | sort -u
)"
log "vm$VMID → GPUs in use by running guests: ${USED:-none}"

# 6) If VM already has hostpci0, skip or clear
EXIST=$(sed -En 's/^hostpci0:\s+([^,]+).*/\1/p' "$CONF" || echo "")
if [[ -n "$EXIST" ]]; then
  if grep -Fxq "$EXIST" <<<"$USED"; then
    log "vm$VMID → existing hostpci0 ($EXIST) stolen—clearing"
    clear_passthru
  else
    log "vm$VMID → existing hostpci0 ($EXIST) still free—skipping"
    exit 0
  fi
fi

# 7) Pick the first free, non-vfio GPU
FREE=""
for DEV in "${CANDS[@]}"; do
  if grep -qxF "$DEV" <<<"$USED"; then
    log "skip $DEV (in use)"; continue
  fi
  drv=$(lspci -k -s "$DEV" 2>/dev/null | awk -F': ' '/Kernel driver in use/ {print $2}')
  [[ "$drv" == "vfio-pci" ]] && { log "skip $DEV (already vfio)"; continue; }
  FREE="$DEV"
  break
done

# 8) No free GPU? fall back to QXL if needed
if [[ -z "$FREE" ]]; then
  orig_vga=$(grep -m1 '^vga:' "$CONF" | awk '{print $2}' || echo "")
  log "vm$VMID → no free GPU, original vga='$orig_vga'"
  if [[ -z "$orig_vga" || "$orig_vga" == "none" ]]; then
    log "vm$VMID → falling back to qxl"
    clear_passthru
    run_set --vga qxl
  else
    log "vm$VMID → keeping vga='$orig_vga'"
  fi
  exit 0
fi

# ==== BIND FREE GPU + AUDIO SIBLING ====
log "vm$VMID → selecting GPU $FREE"

# (a) Unbind current driver
if [[ -d /sys/bus/pci/devices/$FREE/driver ]]; then
  OLD=$(basename "$(readlink -f /sys/bus/pci/devices/$FREE/driver)")
  echo "$FREE" > /sys/bus/pci/drivers/$OLD/unbind 2>/dev/null \
    && log "unbound $FREE from $OLD"
fi

# (b) Bind GPU → vfio-pci
ven=$(sed 's/^0x//' /sys/bus/pci/devices/$FREE/vendor)
dev=$(sed 's/^0x//' /sys/bus/pci/devices/$FREE/device)
echo "$ven $dev" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null \
  && log "new_id($ven $dev)"
echo "$FREE" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null \
  && log "bound GPU $FREE → vfio-pci"

# (c) Bind audio function if present
AUDIO="${FREE%.*}.1"
if [[ -e /sys/bus/pci/devices/$AUDIO ]]; then
  if [[ -d /sys/bus/pci/devices/$AUDIO/driver ]]; then
    AD=$(basename "$(readlink -f /sys/bus/pci/devices/$AUDIO/driver)")
    echo "$AUDIO" > /sys/bus/pci/drivers/$AD/unbind 2>/dev/null \
      && log "unbound audio $AUDIO from $AD"
  fi
  van=$(sed 's/^0x//' /sys/bus/pci/devices/$AUDIO/vendor)
  dan=$(sed 's/^0x//' /sys/bus/pci/devices/$AUDIO/device)
  echo "$van $dan" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null \
    && log "new_id(audio $van $dan)"
  echo "$AUDIO" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null \
    && log "bound audio $AUDIO → vfio-pci"
fi

# (d) Apply passthrough to the VM
clear_passthru
run_set --hostpci0 "$FREE,pcie=1,x-vga=1" \
        --hostpci1 "${AUDIO:-}",pcie=1 \
        --vga none

exit 0
