#!/bin/bash
#
# Destroy all K8s OrbStack Simple Homelab VMs and clean up host configs
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VMS=("vault" "jump" "etcd-1" "master-1" "worker-1" "worker-2")

echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  K8s OrbStack Simple Homelab - Destroy VMs${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"

# Delete VMs
for vm in "${VMS[@]}"; do
    if orb list 2>/dev/null | grep -q "^${vm} "; then
        echo -e "${YELLOW}Deleting VM: ${vm}${NC}"
        orb delete -f "$vm"
    else
        echo -e "${GREEN}VM '${vm}' does not exist, skipping${NC}"
    fi
done

# Clean /etc/hosts
MARKER="# K8s OrbStack Simple Homelab"
if grep -q "$MARKER" /etc/hosts 2>/dev/null; then
    echo -e "${YELLOW}Removing /etc/hosts entries (requires sudo)...${NC}"
    sudo sed -i '' "/${MARKER} BEGIN/,/${MARKER} END/d" /etc/hosts
    echo -e "${GREEN}Removed /etc/hosts entries${NC}"
fi

# Clean SSH config
SSH_CONFIG="$HOME/.ssh/config"
if grep -q "$MARKER" "$SSH_CONFIG" 2>/dev/null; then
    echo -e "${YELLOW}Removing SSH config entries...${NC}"
    sed -i '' "/${MARKER} BEGIN/,/${MARKER} END/d" "$SSH_CONFIG"
    # Remove any trailing blank lines left behind
    sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$SSH_CONFIG"
    echo -e "${GREEN}Removed SSH config entries${NC}"
fi

# Clean known_hosts (stale host keys cause warnings on recreate)
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
if [[ -f "$KNOWN_HOSTS" ]]; then
    echo -e "${YELLOW}Removing known_hosts entries for VMs...${NC}"
    for vm in "${VMS[@]}"; do
        ssh-keygen -R "$vm" -f "$KNOWN_HOSTS" 2>/dev/null || true
    done
    echo -e "${GREEN}Removed known_hosts entries${NC}"
fi

echo ""
echo -e "${GREEN}All VMs destroyed and configs cleaned up.${NC}"
orb list
