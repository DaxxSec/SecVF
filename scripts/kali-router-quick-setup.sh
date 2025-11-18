#!/bin/bash
# Quick Kali Router Setup - Minimal version for copy-paste
# Run as: sudo bash kali-router-quick-setup.sh

set -e

echo "=== SecVF Kali Router Quick Setup ==="
echo ""

# Detect interface
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
echo "Detected interface: $IFACE"

# Configure static IP
echo "Configuring network..."
ip addr flush dev $IFACE
ip addr add 10.0.100.1/24 dev $IFACE
ip link set $IFACE up

# Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Make persistent
cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.ip_forward=1
EOF

# Configure iptables
echo "Configuring firewall..."
iptables -F
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Update and install essential tools
echo "Installing tools (this may take a while)..."
apt-get update -qq
apt-get install -y tcpdump nmap netcat-openbsd iptables iproute2

echo ""
echo "=== Setup Complete! ==="
echo "Router IP: 10.0.100.1"
echo "Network: 10.0.100.0/24"
echo "Interface: $IFACE"
echo ""
echo "Other VMs should use:"
echo "  IP: 10.0.100.x (where x = 10-254)"
echo "  Gateway: 10.0.100.1"
echo "  Netmask: 255.255.255.0"
echo ""
echo "Reboot recommended"
