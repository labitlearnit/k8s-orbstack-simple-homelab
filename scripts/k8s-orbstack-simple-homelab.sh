#!/bin/bash
#
# K8s OrbStack Simple Homelab - Automated VM Creation & Cluster Deployment
# Creates 6 VMs using OrbStack with cloud-init, then deploys a simple K8s cluster
#

set -e

# Track total script time
SCRIPT_START_TIME=$(date +%s)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Directories
PROJECT_DIR="$HOME/k8s-orbstack-simple-homelab"
CLOUD_INIT_DIR="$PROJECT_DIR/cloud-init"
BIN_DIR="$PROJECT_DIR/k8s-binaries"

# SSH Key
SSH_KEY_PRIVATE="$HOME/.ssh/k8slab.key"
SSH_KEY_PUBLIC="${SSH_KEY_PRIVATE}.pub"

# VM Definitions: name:ip_suffix
VMS=(
    "vault:11"
    "jump:12"
    "etcd-1:21"
    "master-1:31"
    "worker-1:41"
    "worker-2:42"
)

# Binary versions
ETCD_VERSION="3.5.12"
K8S_VERSION="1.32.0"
CONTAINERD_VERSION="1.7.24"
RUNC_VERSION="1.2.4"
CALICO_VERSION="3.28.0"

header() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
}

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

elapsed() { echo $(( $(date +%s) - SCRIPT_START_TIME )); }

# Per-step timing helpers
STEP_START=0
step_start() { STEP_START=$(date +%s); }
step_duration() {
    local dur=$(( $(date +%s) - STEP_START ))
    echo -e "  ${GREEN}Step completed in ${dur}s${NC}"
}

# =============================================================================
# Step 0: Pre-flight checks
# =============================================================================
preflight_checks() {
    header "Step 0: Pre-flight Checks [$(elapsed)s]"
    step_start

    if ! command -v orb &>/dev/null; then
        log_error "OrbStack CLI (orb) not found. Install OrbStack first."
        exit 1
    fi
    log_info "OrbStack CLI: $(orb version 2>&1 | head -1)"

    if [[ ! -f "$SSH_KEY_PUBLIC" ]]; then
        log_error "SSH public key not found: $SSH_KEY_PUBLIC"
        exit 1
    fi
    log_info "SSH public key: $SSH_KEY_PUBLIC"

    # Detect OrbStack network subnet dynamically
    local subnet
    subnet=$(orb config show 2>/dev/null | grep "network.subnet4" | awk '{print $2}')
    if [[ -z "$subnet" ]]; then
        log_error "Could not detect OrbStack network subnet"
        exit 1
    fi

    # Use upper /24 of the /23 subnet for static IPs
    local base_ip
    base_ip=$(echo "$subnet" | cut -d'/' -f1)
    IFS='.' read -r o1 o2 o3 o4 <<< "$base_ip"
    NETWORK_PREFIX="${o1}.${o2}.$((o3 + 1))"

    log_info "OrbStack subnet: $subnet"
    log_info "Static IP prefix: ${NETWORK_PREFIX}.x/24"

    # Cache sudo credentials upfront so later steps don't prompt mid-deployment
    if ! grep -q "# K8s OrbStack Simple Homelab" /etc/hosts 2>/dev/null; then
        log_info "Caching sudo credentials (needed for /etc/hosts)..."
        sudo -v
    fi
    step_duration
}

# =============================================================================
# Step 1: Prepare cloud-init configs (substitute placeholders)
# =============================================================================
prepare_cloud_init() {
    header "Step 1: Prepare Cloud-Init Configs [$(elapsed)s]"
    step_start

    local ssh_key
    ssh_key=$(cat "$SSH_KEY_PUBLIC")

    local temp_dir
    temp_dir=$(mktemp -d)
    TEMP_CLOUD_INIT_DIR="$temp_dir"

    for vm_def in "${VMS[@]}"; do
        IFS=':' read -r name ip_suffix <<< "$vm_def"
        local src="$CLOUD_INIT_DIR/${name}.yaml"
        local dst="$temp_dir/${name}.yaml"

        if [[ ! -f "$src" ]]; then
            log_error "Cloud-init template not found: $src"
            exit 1
        fi

        sed -e "s|__SSH_PUBLIC_KEY__|${ssh_key}|g" \
            -e "s|__NETWORK_PREFIX__|${NETWORK_PREFIX}|g" \
            "$src" > "$dst"
    done
    log_info "Prepared cloud-init for ${#VMS[@]} VMs"
    step_duration
}

# =============================================================================
# Step 2: Create VMs (in background for parallelism)
# =============================================================================
create_vms() {
    header "Step 2: Create OrbStack VMs [$(elapsed)s]"
    step_start

    local pids=()
    local names=()

    for vm_def in "${VMS[@]}"; do
        IFS=':' read -r name ip_suffix <<< "$vm_def"

        if orb list 2>/dev/null | grep -q "^${name} "; then
            log_warn "VM '${name}' already exists, skipping"
            continue
        fi

        log_info "Creating VM: ${name} (${NETWORK_PREFIX}.${ip_suffix})..."
        orb create -u k8s \
            -c "$TEMP_CLOUD_INIT_DIR/${name}.yaml" \
            ubuntu:noble "$name" &
        pids+=($!)
        names+=("$name")
    done

    # Wait for all background VM creations
    local failed=0
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            log_info "VM '${names[$i]}' created"
        else
            log_error "VM '${names[$i]}' creation failed"
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed VM(s) failed to create"
        exit 1
    fi

    log_info "All ${#VMS[@]} VMs created"
    step_duration
}

# =============================================================================
# Step 3: Download K8s binaries in background (while VMs boot)
# =============================================================================
download_binaries() {
    header "Step 3: Download K8s Binaries (background) [$(elapsed)s]"
    step_start

    mkdir -p "$BIN_DIR"

    local K8S_URL="https://dl.k8s.io/release/v${K8S_VERSION}/bin/linux/arm64"
    local ETCD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz"
    local CONTAINERD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz"
    local RUNC_URL="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.arm64"
    local CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

    local download_pids=()

    # K8s binaries
    for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy; do
        if [[ ! -f "$BIN_DIR/$bin" ]]; then
            curl -sSL "$K8S_URL/$bin" -o "$BIN_DIR/$bin" && chmod +x "$BIN_DIR/$bin" &
            download_pids+=($!)
            echo "  Downloading $bin..."
        fi
    done

    # etcd
    if [[ ! -f "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" ]]; then
        curl -sSL "$ETCD_URL" -o "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" &
        download_pids+=($!)
        echo "  Downloading etcd..."
    fi

    # containerd
    if [[ ! -f "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" ]]; then
        curl -sSL "$CONTAINERD_URL" -o "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" &
        download_pids+=($!)
        echo "  Downloading containerd..."
    fi

    # runc
    if [[ ! -f "$BIN_DIR/runc.arm64" ]]; then
        curl -sSL "$RUNC_URL" -o "$BIN_DIR/runc.arm64" && chmod +x "$BIN_DIR/runc.arm64" &
        download_pids+=($!)
        echo "  Downloading runc..."
    fi

    # Calico
    if [[ ! -f "$BIN_DIR/calico.yaml" ]]; then
        curl -sSL "$CALICO_URL" -o "$BIN_DIR/calico.yaml" &
        download_pids+=($!)
        echo "  Downloading calico manifest..."
    fi

    DOWNLOAD_PIDS=("${download_pids[@]}")

    if [[ ${#download_pids[@]} -eq 0 ]]; then
        log_info "All binaries already cached"
    else
        log_info "${#download_pids[@]} downloads started in background"
    fi
    step_duration
}

wait_for_downloads() {
    if [[ ${#DOWNLOAD_PIDS[@]} -gt 0 ]]; then
        log_info "Waiting for binary downloads to complete..."
        for pid in "${DOWNLOAD_PIDS[@]}"; do
            wait "$pid" || { log_error "A download failed"; exit 1; }
        done
        log_info "All downloads complete"
    fi
}

# =============================================================================
# Step 4: Wait for SSH on all VMs
# =============================================================================
wait_for_ssh() {
    header "Step 4: Wait for VMs [$(elapsed)s]"
    step_start

    for vm_def in "${VMS[@]}"; do
        IFS=':' read -r name ip_suffix <<< "$vm_def"

        echo -n "  Waiting for ${name}..."
        local retries=0
        local max_retries=60
        while ! orb run -m "$name" -u k8s bash -c 'true' &>/dev/null; do
            retries=$((retries + 1))
            if [[ $retries -ge $max_retries ]]; then
                echo " TIMEOUT"
                log_error "Timeout waiting for ${name}"
                exit 1
            fi
            echo -n "."
            sleep 2
        done
        echo -e " ${GREEN}OK${NC}"
    done
    step_duration
}

# =============================================================================
# Step 5: Configure jump server SSH for bastion access
# =============================================================================
setup_jump_ssh() {
    header "Step 5: Configure Jump Server SSH [$(elapsed)s]"
    step_start

    # Copy private key
    log_info "Copying SSH private key to jump server..."
    local key_content
    key_content=$(cat "$SSH_KEY_PRIVATE")
    orb run -m jump -u k8s bash -c "
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        cat > ~/.ssh/k8slab.key << 'KEYEOF'
${key_content}
KEYEOF
        chmod 600 ~/.ssh/k8slab.key
    "

    # Generate SSH config for all VMs (except jump itself)
    log_info "Creating SSH config on jump server..."
    local ssh_config=""
    for vm_def in "${VMS[@]}"; do
        IFS=':' read -r name ip_suffix <<< "$vm_def"
        [[ "$name" == "jump" ]] && continue
        ssh_config+="Host ${name}
    HostName ${NETWORK_PREFIX}.${ip_suffix}
    User k8s
    IdentityFile ~/.ssh/k8slab.key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR

"
    done

    orb run -m jump -u k8s bash -c "
        cat > ~/.ssh/config << 'SSHEOF'
${ssh_config}SSHEOF
        chmod 600 ~/.ssh/config
    "
    log_info "Jump SSH config created for ${#VMS[@]} VMs"
    step_duration
}

# =============================================================================
# Step 6: Configure macOS /etc/hosts (jump only)
# =============================================================================
setup_mac_hosts() {
    header "Step 6: Configure macOS /etc/hosts [$(elapsed)s]"
    step_start

    local jump_ip="${NETWORK_PREFIX}.12"
    local marker="# K8s OrbStack Simple Homelab"

    if grep -q "$marker" /etc/hosts 2>/dev/null; then
        log_warn "Homelab entries already in /etc/hosts, skipping"
        step_duration
        return 0
    fi

    log_info "Adding jump server entry to /etc/hosts (requires sudo)..."
    sudo bash -c "cat >> /etc/hosts << EOF

${marker} BEGIN
${jump_ip}  jump
${marker} END
EOF"
    log_info "Added: ${jump_ip}  jump"
    step_duration
}

# =============================================================================
# Step 7: Configure SSH on macOS
# =============================================================================
setup_mac_ssh() {
    header "Step 7: Configure macOS SSH Config [$(elapsed)s]"
    step_start

    local jump_ip="${NETWORK_PREFIX}.12"
    local ssh_config="$HOME/.ssh/config"
    local marker="# K8s OrbStack Simple Homelab"

    if grep -q "$marker" "$ssh_config" 2>/dev/null; then
        log_warn "Homelab SSH config already exists, skipping"
        step_duration
        return 0
    fi

    log_info "Adding jump server SSH config..."
    cat >> "$ssh_config" << EOF

${marker} BEGIN
Host jump
    HostName ${jump_ip}
    User k8s
    IdentityFile ${SSH_KEY_PRIVATE}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    GSSAPIAuthentication no
    PreferredAuthentications publickey

Host vault etcd-1 master-1 worker-1 worker-2
    User k8s
    IdentityFile ${SSH_KEY_PRIVATE}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ProxyJump jump
${marker} END
EOF
    chmod 600 "$ssh_config"
    log_info "SSH config updated — all VMs accessible via jump bastion"
    step_duration
}

# =============================================================================
# Step 8: Copy binaries to jump server
# =============================================================================
copy_binaries_to_jump() {
    header "Step 8: Copy Binaries to Jump [$(elapsed)s]"
    step_start

    wait_for_downloads

    local jump_bin_dir="/tmp/k8s-binaries"
    local jump_etcd_dir="/tmp/etcd-cache"
    local jump_containerd_dir="/tmp/containerd-cache"

    orb run -m jump -u k8s bash -c "mkdir -p $jump_bin_dir $jump_etcd_dir $jump_containerd_dir"

    # Copy K8s binaries
    for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy; do
        log_info "Copying $bin to jump..."
        cat "$BIN_DIR/$bin" | orb run -m jump -u k8s bash -c "cat > $jump_bin_dir/$bin && chmod +x $jump_bin_dir/$bin"
    done

    # Copy etcd tarball
    log_info "Copying etcd tarball..."
    cat "$BIN_DIR/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz" | orb run -m jump -u k8s bash -c "cat > $jump_etcd_dir/etcd-v${ETCD_VERSION}-linux-arm64.tar.gz"

    # Copy containerd tarball
    log_info "Copying containerd tarball..."
    cat "$BIN_DIR/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz" | orb run -m jump -u k8s bash -c "cat > $jump_containerd_dir/containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz"

    # Copy runc
    log_info "Copying runc..."
    cat "$BIN_DIR/runc.arm64" | orb run -m jump -u k8s bash -c "cat > $jump_containerd_dir/runc.arm64 && chmod +x $jump_containerd_dir/runc.arm64"

    # Copy Calico manifest
    log_info "Copying calico manifest..."
    cat "$BIN_DIR/calico.yaml" | orb run -m jump -u k8s bash -c "cat > /tmp/calico.yaml"

    log_info "All binaries copied to jump server"
    step_duration
}

# =============================================================================
# Step 9: Copy Ansible project to jump server
# =============================================================================
copy_ansible_to_jump() {
    header "Step 9: Copy Ansible Project to Jump [$(elapsed)s]"
    step_start

    local project_dir_jump="/home/k8s/k8s-orbstack-simple-homelab"

    orb run -m jump -u k8s bash -c "mkdir -p $project_dir_jump"

    # Use rsync via orb to copy ansible directory
    log_info "Syncing ansible directory to jump..."
    orb push -m jump "$PROJECT_DIR/ansible" "$project_dir_jump/ansible"

    log_info "Ansible project copied to jump:$project_dir_jump/ansible"
    step_duration
}

# =============================================================================
# Step 10: Verify setup
# =============================================================================
verify_setup() {
    header "Step 10: Verification [$(elapsed)s]"
    step_start

    echo ""
    log_info "VM Status:"
    orb list
    echo ""

    # Test connectivity from jump to all other VMs
    log_info "Testing SSH connectivity from jump..."
    for vm_def in "${VMS[@]}"; do
        IFS=':' read -r name ip_suffix <<< "$vm_def"
        [[ "$name" == "jump" ]] && continue

        if orb run -m jump -u k8s bash -c "ssh -o ConnectTimeout=5 ${name} hostname" 2>/dev/null | grep -q "${name}"; then
            echo -e "  ${GREEN}jump → ${name}: OK${NC}"
        else
            echo -e "  ${YELLOW}jump → ${name}: Pending (cloud-init may still be running)${NC}"
        fi
    done

    # Show tools on jump
    echo ""
    log_info "Jump server tools:"
    orb run -m jump -u k8s bash -c '
        echo "  Terraform: $(terraform version 2>/dev/null | head -1 || echo "installing...")"
        echo "  Vault CLI: $(vault version 2>/dev/null || echo "installing...")"
        echo "  Ansible:   $(ansible --version 2>/dev/null | head -1 || echo "installing...")"
        echo "  kubectl:   $(kubectl version --client 2>/dev/null | head -1 || echo "installing...")"
        echo "  Helm:      $(helm version --short 2>/dev/null || echo "installing...")"
        echo "  jq:        $(jq --version 2>/dev/null || echo "installing...")"
    '
    step_duration
}

# =============================================================================
# Step 11: Deploy K8s cluster from jump server
# =============================================================================
deploy_cluster() {
    header "Step 11: Deploy K8s Cluster [$(elapsed)s]"
    step_start

    local ansible_cmd="cd ~/k8s-orbstack-simple-homelab/ansible && ansible-playbook -i inventory/homelab.yml"
    local run_on_jump="orb run -m jump -u k8s bash -c"

    # --- Jump Setup (VAULT_TOKEN, .bashrc, etc.) ---
    log_info "Configuring jump server environment..."
    $run_on_jump "cd ~/k8s-orbstack-simple-homelab/ansible && ansible-playbook -i inventory/homelab.yml playbooks/k8s-orbstack-simple-homelab.yml --tags jump-setup" || log_warn "Jump setup had issues, continuing..."

    # --- Vault ---
    log_info "Deploying Vault (bootstrap + PKI)..."
    $run_on_jump "$ansible_cmd playbooks/vault-full-setup.yml" || { log_error "Vault setup failed"; return 1; }

    # --- K8s Certificates ---
    log_info "Issuing K8s certificates..."
    $run_on_jump "$ansible_cmd playbooks/k8s-certs.yml" || { log_error "K8s certs failed"; return 1; }

    # --- etcd ---
    log_info "Deploying etcd..."
    $run_on_jump "$ansible_cmd playbooks/etcd-cluster.yml" || { log_error "etcd deployment failed"; return 1; }

    # --- etcd encryption key ---
    log_info "Storing etcd encryption key in Vault..."
    $run_on_jump "$ansible_cmd playbooks/vault-etcd-encryption-key.yml" || { log_error "etcd encryption key failed"; return 1; }

    # --- Control Plane ---
    log_info "Deploying control plane..."
    $run_on_jump "$ansible_cmd playbooks/control-plane.yml" || { log_error "Control plane failed"; return 1; }

    # --- Workers ---
    log_info "Deploying workers..."
    $run_on_jump "$ansible_cmd playbooks/worker.yml" || { log_error "Worker deployment failed"; return 1; }

    # --- Calico CNI ---
    log_info "Applying Calico CNI..."
    $run_on_jump "export KUBECONFIG=~/.kube/config && kubectl apply -f /tmp/calico.yaml" || { log_error "Calico apply failed"; return 1; }

    # --- Wait for nodes ---
    log_info "Waiting for all nodes to be Ready..."
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        local ready
        ready=$($run_on_jump "export KUBECONFIG=~/.kube/config && kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || echo 0" 2>/dev/null)
        ready=${ready//[^0-9]/}
        if [[ "${ready:-0}" -ge 2 ]]; then
            log_info "All $ready nodes are Ready!"
            break
        fi
        echo -e "  ${YELLOW}$ready/2 nodes ready, waiting...${NC}"
        sleep 10
        ((attempts++))
    done

    # --- Show final status ---
    echo ""
    $run_on_jump "export KUBECONFIG=~/.kube/config && echo '=== Nodes ===' && kubectl get nodes -o wide && echo '' && echo '=== System Pods ===' && kubectl get pods -n kube-system"
    step_duration
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    if [[ -n "${TEMP_CLOUD_INIT_DIR:-}" && -d "$TEMP_CLOUD_INIT_DIR" ]]; then
        rm -rf "$TEMP_CLOUD_INIT_DIR"
    fi
}
trap cleanup EXIT

# =============================================================================
# Main
# =============================================================================
main() {
    header "K8s OrbStack Simple Homelab - Full Cluster Deployment"
    echo -e "  VMs: vault, jump, etcd-1, master-1, worker-1, worker-2"
    echo -e "  Backend: OrbStack (Ubuntu Noble)"
    echo ""

    preflight_checks
    prepare_cloud_init
    create_vms
    download_binaries        # Start downloads while VMs boot
    wait_for_ssh
    setup_jump_ssh
    setup_mac_hosts
    setup_mac_ssh
    copy_binaries_to_jump    # Wait for downloads + copy to jump
    copy_ansible_to_jump
    verify_setup
    deploy_cluster

    # Final summary
    local elapsed_total=$(( $(date +%s) - SCRIPT_START_TIME ))
    local mins=$(( elapsed_total / 60 ))
    local secs=$(( elapsed_total % 60 ))
    header "K8s OrbStack Simple Homelab - Deployment Complete!"
    echo ""
    echo -e "  ${GREEN}Total deployment time:${NC} ${mins}m ${secs}s"
    echo ""
    orb list
    echo ""
    echo -e "  ${GREEN}SSH Access:${NC}"
    echo -e "    ssh jump              (direct)"
    echo -e "    ssh vault             (via jump)"
    echo -e "    ssh master-1          (via jump)"
    echo ""
    echo -e "  ${BLUE}Kubernetes:${NC}"
    echo -e "    ssh jump"
    echo -e "    kubectl get nodes"
    echo ""
}

main "$@"
