#!/bin/bash
#
# macOS Network Setup Script for SecVF
#
# Configures network interface for VirtualNetworkSwitch communication
#
# Usage: sudo ./macos-network-setup.sh [IP_ADDRESS]
# Example: sudo ./macos-network-setup.sh 10.0.100.50
#

set -e

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Default configuration
DEFAULT_IP="10.0.100.50"
NETMASK="255.255.255.0"
GATEWAY="10.0.100.1"
NETWORK="10.0.100.0/24"

# Use provided IP or default
VM_IP="${1:-$DEFAULT_IP}"

echo -e "${GREEN}=== SecVF macOS Network Setup ===${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Detect primary network interface
echo "Detecting network interface..."
INTERFACE=$(networksetup -listallhardwareports | awk '/Hardware Port: Ethernet/{getline; print $2}' | head -n1)

if [ -z "$INTERFACE" ]; then
    # Try to find any active interface
    INTERFACE=$(ifconfig | grep -E "^en[0-9]:" | head -n1 | cut -d: -f1)
fi

if [ -z "$INTERFACE" ]; then
    echo -e "${RED}Error: Could not detect network interface${NC}"
    exit 1
fi

echo -e "${GREEN}Detected interface: $INTERFACE${NC}"

# Get the service name for this interface
SERVICE=$(networksetup -listallhardwareports | grep -B1 "Device: $INTERFACE" | awk '/Hardware Port:/{print $3" "$4" "$5" "$6}' | sed 's/[[:space:]]*$//')

if [ -z "$SERVICE" ]; then
    SERVICE="Ethernet"
fi

echo "Service name: $SERVICE"

# Configure static IP
echo ""
echo "Configuring network..."
echo "  IP Address: $VM_IP"
echo "  Netmask: $NETMASK"
echo "  Gateway: $GATEWAY"
echo ""

# Set manual IP configuration
networksetup -setmanual "$SERVICE" "$VM_IP" "$NETMASK" "$GATEWAY"

# Set DNS to router (optional)
networksetup -setdnsservers "$SERVICE" "$GATEWAY"

# Verify configuration
echo ""
echo -e "${GREEN}Configuration applied!${NC}"
echo ""
echo "Verifying..."
ifconfig $INTERFACE | grep "inet "

echo ""
echo -e "${GREEN}=== Setup Complete! ===${NC}"
echo ""
echo "Network Configuration:"
echo "  IP: $VM_IP"
echo "  Netmask: $NETMASK"
echo "  Gateway: $GATEWAY"
echo "  Interface: $INTERFACE"
echo "  Service: $SERVICE"
echo ""
echo "To test connectivity:"
echo "  ping $GATEWAY    # Ping the router"
echo "  ping 10.0.100.x  # Ping other VMs"
echo ""
echo "To change IP later:"
echo "  sudo $0 10.0.100.X"
echo ""
