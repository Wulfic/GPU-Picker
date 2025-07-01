Proxmox GPU Auto-Passthrough 🚀
Turn your Proxmox VE host into a dynamic, multi-GPU powerhouse—fully automatic!



📦 Components
GPU Auto-Pick Hook Script (gpu-autopick.sh) A Proxmox VM “hook script” that runs just before each VM boots.
Nginx Proxy Configuration (pve-proxy.conf) An Nginx (or OpenResty) site that fronts your Proxmox web UI.



🔍 Features
1. GPU Auto-Pick Hook Script

-Dynamic GPU assignment Scans for all discrete (VGA/3D) controllers and detects which are free.

-Conflict-free Reads existing VM configs, skips GPUs already in use.

-Automatic injection Uses qm set <vmid> --hostpciX to assign the first available GPU.

-Graceful fallback If no GPU is free, automatically switches the VM’s display to QXL.

-Full logging Records every decision—GPU chosen or QXL fallback—for easy auditing.

-Configurable Override its behavior via environment variables at the top of the script.


2. Nginx Proxy Configuration

-Secure HTTPS Terminates SSL on port 8443 (or 443), encrypting all Proxmox web traffic.

-Smooth Web Console Proxies Proxmox’s no-VNC/HTML5 console without socket errors.

-Large-file uploads Bumps client-max_body_size for seamless ISO, backup, and template uploads.

-Hook-script integration Triggers the GPU-picker script on VM start/stop via embedded Lua (or shell) logic.



📋 Prerequisites

-Proxmox VE (any recent version)

-Nginx with lua-nginx-module (or OpenResty)

-pvesh CLI (bundled with Proxmox)

-A valid SSL certificate & private key for your Proxmox UI

-At least 2 NVIDIA GPUs (one for host console + ≥1 free for VMs)



⚙️ Quick-Start Installation

-Copy and paste the following into your Proxmox host shell:



#Copy from here out
#!/bin/bash

# Comment out enterprise Proxmox repos
sed -i '/enterprise.proxmox.com/ s/^/# /' /etc/apt/sources.list /etc/apt/sources.list.d/*.list

# Add PVE and Ceph repos
cat <<EOF | tee /etc/apt/sources.list.d/pve-no-subscription.list
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
deb http://download.proxmox.com/debian/ceph-quincy bookworm main
EOF

# Update and install NGINX with extra modules
apt update && apt install -y nginx-extras curl

# Create required directories
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled \
         /etc/ssl/nginx /usr/local/share/pve-hook-scripts

# Get IP for cert generation
IP=$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1{print $7}')

# Generate a self-signed cert with the host IP as CN
openssl req -x509 -nodes -days 36500 \
  -newkey rsa:2048 \
  -keyout /etc/ssl/nginx/pve-proxy.key \
  -out /etc/ssl/nginx/pve-proxy.crt \
  -subj "/CN=${IP}"

# Download NGINX config and hook script
curl -fsSL https://raw.githubusercontent.com/Wulfic/GPU-Picker/main/pve-proxy.conf \
  -o /etc/nginx/sites-available/pve-proxy.conf

curl -fsSL https://raw.githubusercontent.com/Wulfic/GPU-Picker/main/gpu-autopick.sh \
  -o /usr/local/share/pve-hook-scripts/gpu-autopick.sh

# Make hook script executable
chmod +x /usr/local/share/pve-hook-scripts/gpu-autopick.sh
chmod 755 /usr/local/share/pve-hook-scripts/gpu-autopick.sh

# Enable NGINX site
ln -sf /etc/nginx/sites-available/pve-proxy.conf /etc/nginx/sites-enabled/pve-proxy.conf

# Test and reload NGINX
nginx -t && systemctl reload nginx
#End of copy


🔧 Configuration Tips
-Edit /etc/nginx/sites-available/pve-proxy.conf to change:

-Listening port (443 vs. 8443)

-Paths to your SSL cert & key

-Any custom proxy timeouts or buffer sizes



-At the top of gpu-autopick.sh, adjust:

-Which PCI bus classes to scan

-Log-file path and verbosity

-Fallback display type (e.g., qxl, virtio-gpu)
