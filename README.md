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

download installer.sh or copy/paste into a new file called installer.sh and run:

chmod +x installer.sh

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
