#######################################################################################


Proxmox GPU Auto-Passthrough 🚀
Turn your Proxmox VE host into a dynamic, multi-GPU powerhouse—fully automatic!

#######################################################################################



📦 Components
GPU Auto-Pick Hook Script (gpu-autopick.sh) A Proxmox VM “hook script” that runs just before each VM boots.
Nginx Proxy Configuration (pve-proxy.conf) An Nginx (or OpenResty) site that fronts your Proxmox web UI.

#######################################################################################


🔍 Features

-Dynamic GPU assignment Scans for all discrete (VGA/3D) controllers and detects which are free.

-Conflict-free Reads existing VM configs, skips GPUs already in use.

-Automatic injection Uses qm set <vmid> --hostpciX to assign the first available GPU.

-Graceful fallback If no GPU is free, automatically switches the VM’s display to QXL.

-Full logging Records every decision—GPU chosen or QXL fallback—for easy auditing.

-Configurable Override its behavior via environment variables at the top of the script.

#######################################################################################


📋 Prerequisites

-Proxmox VE (any recent version)(Fresh Install)

-At least 2 NVIDIA GPUs (one for host console + ≥1 free for VMs)

#######################################################################################


⚙️ Quick-Start Installation

-Copy and paste the following into your Proxmox host shell:


#!/bin/bash

sed -i '/enterprise.proxmox.com/ s/^/# /' /etc/apt/sources.list /etc/apt/sources.list.d/*.list

cat <<EOF | tee /etc/apt/sources.list.d/pve-no-subscription.list
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
deb http://download.proxmox.com/debian/ceph-quincy bookworm main
EOF

apt update && apt install -y nginx-extras curl

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled \
         /etc/ssl/nginx /usr/local/share/pve-hook-scripts

IP=$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1{print $7}')

openssl req -x509 -nodes -days 36500 \
  -newkey rsa:2048 \
  -keyout /etc/ssl/nginx/pve-proxy.key \
  -out /etc/ssl/nginx/pve-proxy.crt \
  -subj "/CN=${IP}"

curl -fsSL https://raw.githubusercontent.com/Wulfic/GPU-Picker/main/pve-proxy.conf \
  -o /etc/nginx/sites-available/pve-proxy.conf

curl -fsSL https://raw.githubusercontent.com/Wulfic/GPU-Picker/main/gpu-autopick.sh \
  -o /usr/local/share/pve-hook-scripts/gpu-autopick.sh

chmod +x /usr/local/share/pve-hook-scripts/gpu-autopick.sh

chmod 755 /usr/local/share/pve-hook-scripts/gpu-autopick.sh

ln -sf /etc/nginx/sites-available/pve-proxy.conf /etc/nginx/sites-enabled/pve-proxy.conf

nginx -t && systemctl reload nginx

echo "########################################################################"

echo "Use the new interface page moving forward or the script will not work!"

echo "Login and use as normal."

echo "Your new address is "${IP}":8443"

echo "########################################################################"


#End of copy

#######################################################################################


🔧 Configuration Tips

🔧Edit /etc/nginx/sites-available/pve-proxy.conf to change:

-Listening port (443 vs. 8443)

-Paths to your SSL cert & key

-Any custom proxy timeouts or buffer sizes

#

🔧Edit /usr/local/share/pve-hook-scripts/gpu-autopick.sh

-Which PCI bus classes to scan

-Log-file path and verbosity

-Fallback display type (e.g., qxl, virtio-gpu)
