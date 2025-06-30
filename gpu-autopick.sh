#!/usr/bin/env bash
#
# NVIDIA v2/v3-only Auto-Picker for Proxmox VE
# ----------------------------------------------------------------------------
# Automatically assigns an unused NVIDIA GPU (plus its audio function) to a VM
# on VM pre-start, and cleans up GPU mappings on VM post-stop. 
# Ideal for systems with multiple NVIDIA cards where you want dynamic passthrough.

### Section 1 – Argument Parsing & Environment Setup
# 1.1) Read VMID and EVENT from arguments. VMID is required; EVENT defaults to “pre-start”.
VMID="${1:?Usage: $0 VMID [pre-start|post-stop]}"   # VM numeric ID (from qm)
EVENT="${2:-pre-start}"                             # “pre-start” or “post-stop”
NODE="$(hostname -s)"                               # short hostname of this Proxmox node

# 1.2) All stdout and stderr go to our log file for debugging
LOG=/var/log/pve-hook-gpu.log
exec >>"$LOG" 2>&1

# 1.3) Errors trigger trap (to prevent hook abort). Only an explicit exit 1 stops the hook.
trap 'exit 0' ERR
set -euo pipefail  # -e: exit on error, -u: fail on undefined var, -o pipefail: catch pipeline errors

# 1.4) Helper function: timestamped log entries
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# 1.5) If the hook is triggered for anything other than pre-start/post-stop, do nothing
if [[ "$EVENT" != pre-start && "$EVENT" != post-stop ]]; then
  exit 0
fi

### Section 2 – Single-Instance Guard
# Prevent multiple concurrent runs for the same VMID by creating a lock directory.
LOCK_BASE="/run/lock/pve-gpu-autopick.$VMID"
LOCKDIR="${LOCK_BASE}.lck"
mkdir -p /run/lock
if mkdir "$LOCKDIR" 2>/dev/null; then
  # On any script exit, remove the lock directory
  trap 'rmdir "$LOCKDIR"' EXIT
  log "vm$VMID → acquired single-instance lock"
else
  log "vm$VMID → another instance running, exiting"
  exit 0
fi

### Section 3 – Helper Functions
# 3.1) run_set: wrap `pvesh set` so failures don't abort the hook.
#       pvesh is Proxmox VE’s REST API command-line tool.
run_set() {
  if pvesh set /nodes/$NODE/qemu/"$VMID"/config "$@" &>/dev/null; then
    log "vm$VMID → pvesh set: $*"
  else
    log "vm$VMID → pvesh set FAILED (ignored): $*"
  fi
}

# 3.2) clear_passthru: remove any existing GPU passthrough or VGA settings
#       --delete hostpci0/1, vga, mapping
clear_passthru() {
  for key in hostpci0 hostpci1 vga mapping; do
    run_set --delete "$key"
  done
  log "vm$VMID → cleared passthrough + mapping"
}

### Section 4 – Skip Tagged VMs
# If this VM’s config contains the tag “no-gpu-autopick”, skip all logic.
if pvesh get /nodes/$NODE/qemu/"$VMID"/config \
     --output-format=json \
   | jq -er '.tags // "" | contains("no-gpu-autopick")' &>/dev/null; then
  log "vm$VMID → skipping (no-gpu-autopick tag)"
  exit 0
fi

### Section 5 – Identify Host Console GPU
# We don’t want to steal the GPU the host is using for its console (framebuffer).
HOST_GPU=""
if [[ -e /sys/class/graphics/fb0/device ]]; then
  # Follow the symlink to the PCI device (e.g., “0000:01:00.0”)
  HOST_GPU="$(basename "$(readlink -f /sys/class/graphics/fb0/device)")"
  log "detected host console GPU: $HOST_GPU"
fi

### Section 6 – Handle post-stop (Cleanup)
if [[ "$EVENT" == post-stop ]]; then
  # On VM stop: remove passthrough settings so GPU is free again.
  clear_passthru
  exit 0
fi

### Section 7 – Begin pre-start Workflow
log "vm$VMID → pre-start"
CONF=/etc/pve/qemu-server/"$VMID".conf

### Section 8 – Unbind any stale vfio-pci devices
# Sometimes VMs crash and leave devices bound to vfio-pci. Clean them up.
for D in /sys/bus/pci/devices/0000:[0-9a-f][0-9a-f]:00.0; do
  [[ -d "$D/driver" ]] || continue
  [[ "$(basename "$(readlink -f "$D/driver")")" == "vfio-pci" ]] || continue
  DEV="${D##*/}"  # strip path, get “0000:0x:00.0”
  echo "$DEV" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
  log "cleanup: unbound stale vfio-pci $DEV"
done

### Section 9 – Build List of NVIDIA GPU Candidates
CANDS=()
for P in /sys/bus/pci/devices/0000:*:00.0; do
  DEV="${P##*/}"
  # Skip PCI slot 1 (0x01:00.0) – typically primary GPU
  if [[ "$DEV" =~ ^0000:01: ]]; then
    log "skip $DEV (slot 1)"
    continue
  fi
  # Skip the host console GPU
  if [[ "$DEV" == "$HOST_GPU" ]]; then
    log "skip $DEV (host console)"
    continue
  fi
  # Check vendor; 0x10de means NVIDIA
  vend=$(<"$P/vendor")
  if [[ "$vend" != "0x10de" ]]; then
    log "skip $DEV (vendor $vend)"
    continue
  fi
  # Add to our candidate list
  CANDS+=("$DEV")
done
log "vm$VMID → candidate GPUs: ${CANDS[*]:-none}"

### Section 10 – Find GPUs Already Used by Running VMs
# 10.1) List all running VMs (qm list shows VMID, status)
mapfile -t RUNNING < <(qm list | awk '$3=="running"{print $1}')
# 10.2) For each running VM, extract hostpci assignments from its config
USED="$(
  for VM in "${RUNNING[@]}"; do
    sed -n 's/^hostpci[0-9]\+: *\(0000:[0-9a-f:.]\+\).*/\1/p' \
      "/etc/pve/qemu-server/$VM.conf"
  done | sort -u
)"
log "vm$VMID → GPUs in use: ${USED:-none}"

### Section 11 – Check If VM Already Has a GPU Assigned
# If config has hostpci0, VM was previously assigned a GPU.
EXIST=$(sed -En 's/^hostpci0:\s+([^,]+).*/\1/p' "$CONF" || echo "")
if [[ -n "$EXIST" ]]; then
  # If that GPU is now in use elsewhere, clear and reassign
  if grep -Fxq "$EXIST" <<<"$USED"; then
    log "vm$VMID → existing hostpci0 ($EXIST) stolen—clearing"
    clear_passthru
  else
    # If it’s still free, keep it
    log "vm$VMID → existing hostpci0 ($EXIST) still free—keeping"
    exit 0
  fi
fi

### Section 12 – Select a Free NVIDIA GPU
FREE=""
for DEV in "${CANDS[@]}"; do
  # Skip if in use
  if grep -qxF "$DEV" <<<"$USED"; then
    log "skip $DEV (in use)"
    continue
  fi
  # Skip if already bound to vfio-pci on the host
  drv=$(lspci -k -s "$DEV" 2>/dev/null | awk -F': ' '/Kernel driver in use/ {print $2}')
  if [[ "$drv" == "vfio-pci" ]]; then
    log "skip $DEV (already vfio-pci)"
    continue
  fi
  FREE="$DEV"
  break
done

### Section 13 – Fallback to QXL if No Free GPU Found
if [[ -z "$FREE" ]]; then
  # Read original vga setting from VM config (if any)
  orig_vga=$(grep -m1 '^vga:' "$CONF" | awk '{print $2}' || echo "")
  log "vm$VMID → no free GPU; original vga='$orig_vga'"
  if [[ -z "$orig_vga" || "$orig_vga" == "none" ]]; then
    # Default to QXL paravirtualized graphics
    log "vm$VMID → falling back to QXL vga"
    clear_passthru
    run_set --vga qxl
  else
    # Preserve whatever VGA was explicitly set
    log "vm$VMID → preserving vga='$orig_vga'"
  fi
  exit 0
fi
log "vm$VMID → selected GPU $FREE for passthrough"

### Section 14 – Bind Selected GPU (and Audio) to vfio-pci
# 14.1) Unbind GPU from its current driver (e.g., nouveau or nvidia)
if [[ -d /sys/bus/pci/devices/$FREE/driver ]]; then
  OLD_DRV=$(basename "$(readlink -f /sys/bus/pci/devices/$FREE/driver)")
  echo "$FREE" > /sys/bus/pci/drivers/$OLD_DRV/unbind 2>/dev/null \
    && log "unbound $FREE from $OLD_DRV"
fi

# 14.2) Register this GPU’s vendor/device IDs with vfio-pci and bind it
ven_id=$(sed 's/^0x//' /sys/bus/pci/devices/$FREE/vendor)
dev_id=$(sed 's/^0x//' /sys/bus/pci/devices/$FREE/device)
echo "$ven_id $dev_id" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null \
  && log "vfio-pci new_id($ven_id $dev_id)"
echo "$FREE" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null \
  && log "bound GPU $FREE → vfio-pci"

# 14.3) Also bind the audio function (same PCI slot, function .1)
AUDIO="${FREE%.*}.1"
if [[ -e /sys/bus/pci/devices/$AUDIO ]]; then
  if [[ -d /sys/bus/pci/devices/$AUDIO/driver ]]; then
    ADRV=$(basename "$(readlink -f /sys/bus/pci/devices/$AUDIO/driver)")
    echo "$AUDIO" > /sys/bus/pci/drivers/$ADRV/unbind 2>/dev/null \
      && log "unbound audio $AUDIO from $ADDRV"
  fi
  van_id=$(sed 's/^0x//' /sys/bus/pci/devices/$AUDIO/vendor)
  dan_id=$(sed 's/^0x//' /sys/bus/pci/devices/$AUDIO/device)
  echo "$van_id $dan_id" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null \
    && log "vfio-pci new_id(audio $van_id $dan_id)"
  echo "$AUDIO" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null \
    && log "bound audio $AUDIO → vfio-pci"
fi

### Section 15 – Configure VM for GPU Passthrough
# Clear any old passthrough first, then set new hostpci entries and disable paravirt VGA.
clear_passthru
run_set \
  --hostpci0 "$FREE,pcie=1,x-vga=1" \    # assign GPU on PCIe, enable x-vga
  --hostpci1 "${AUDIO:-},pcie=1" \        # assign audio function if present
  --vga none                              # disable QXL/VGA emulation

log "vm$VMID → GPU $FREE passed through (audio: ${AUDIO:-none})"
exit 0
