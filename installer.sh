#!/bin/bash

sed -i '/enterprise.proxmox.com/ s/^/# /' /etc/apt/sources.list /etc/apt/sources.list.d/*.list

cat <<EOF | tee /etc/apt/sources.list.d/pve-no-subscription.list deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription deb http://download.proxmox.com/debian/ceph-quincy bookworm main EOF

apt update && apt install -y nginx-extras curl

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
/etc/ssl/nginx /usr/local/share/pve-hook-scripts

IP=$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1{print $7}')

openssl req -x509 -nodes -days 36500
-newkey rsa:2048
-keyout /etc/ssl/nginx/pve-proxy.key
-out /etc/ssl/nginx/pve-proxy.crt
-subj "/CN=${IP}"

curl -fsSL https://raw.githubusercontent.com/Wulfic/GPU-Picker/main/pve-proxy.conf
-o /etc/nginx/sites-available/pve-proxy.conf

curl -fsSL https://raw.githubusercontent.com/Wulfic/GPU-Picker/main/gpu-autopick.sh
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
