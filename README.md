# Kubernetes Simple Homelab on OrbStack (Apple Silicon)

A minimal, single-master Kubernetes cluster built from scratch on macOS using OrbStack virtualization. Fully automated — no kubeadm, no managed services, just raw binaries and certificates.

Based on [k8s-utm-simple-homelab](https://github.com/shyamsundart14/k8s-utm-simple-homelab) — same architecture, ported from UTM to OrbStack for faster VM creation and better macOS integration.

## Highlights

- **Kubernetes v1.32.0** — the hard way, installed from official binaries (ARM64)
- **6 Ubuntu 24.04 VMs** on OrbStack with cloud-init provisioning
- **HashiCorp Vault PKI** — 3-tier CA hierarchy for all TLS certificates
- **Single etcd node** for simplicity
- **Single master** — no load balancer needed
- **Jump/bastion server** — Mac connects only to jump; all management happens from there
- **Calico CNI** for pod networking
- **Single-command deployment** — one shell script does everything
- **Dynamic networking** — auto-detects OrbStack subnet, no hardcoded IPs

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                   Mac Host (Apple Silicon)                       │
│                    OrbStack Network                              │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                     OrbStack Shared Network
                      {NETWORK_PREFIX}.0/24
                              │
       ┌──────────┬───────────┼───────────┬──────────┐
       │          │           │           │          │
  ┌────┴────┐ ┌───┴───┐ ┌────┴────┐ ┌────┴────┐     │
  │  Vault  │ │ Jump  │ │ etcd-1  │ │master-1 │     │
  │   .11   │ │  .12  │ │  .21    │ │  .31    │     │
  │  (PKI)  │ │(bast.)│ │         │ │  (CP)   │     │
  └─────────┘ └───┬───┘ └─────────┘ └────┬────┘     │
                  │                       │          │
             ┌────┴───────────────────────┴──────────┴──┐
             │              Workers                      │
             │  ┌──────────┐  ┌──────────┐               │
             │  │ worker-1 │  │ worker-2 │               │
             │  │   .41    │  │   .42    │               │
             │  └──────────┘  └──────────┘               │
             └───────────────────────────────────────────┘
```

## VM Specifications

| VM | Role | IP Suffix | Notes |
|----|------|-----------|-------|
| vault | PKI & Secrets (HashiCorp Vault 1.15.4) | .11 | Vault server |
| jump | Bastion / Ansible Controller | .12 | Only host accessible from Mac |
| etcd-1 | etcd (single node) | .21 | Key-value store |
| master-1 | K8s control plane | .31 | API server, controller-manager, scheduler |
| worker-1 | K8s worker node | .41 | Runs workloads |
| worker-2 | K8s worker node | .42 | Runs workloads |

> IPs are dynamically assigned based on OrbStack's network subnet (e.g., `192.168.139.x`).

## Component Versions

| Component | Version |
|-----------|---------|
| Kubernetes | 1.32.0 |
| etcd | 3.5.12 |
| containerd | 1.7.24 |
| runc | 1.2.4 |
| Calico CNI | 3.28.0 |
| HashiCorp Vault | 1.15.4 |
| Ubuntu | 24.04 LTS (ARM64, OrbStack) |

## Prerequisites

- **macOS** on Apple Silicon (M1/M2/M3/M4)
- **OrbStack** installed from [orbstack.dev](https://orbstack.dev/)
- **SSH key** at `~/.ssh/k8slab.key` (and `.pub`)

## Quick Start

### Shell Script (recommended)

```bash
./scripts/k8s-orbstack-simple-homelab.sh
```

The script does everything in a single run:

1. **Detects OrbStack network** subnet automatically
2. **Creates 6 OrbStack VMs** with Ubuntu cloud-init
3. **Downloads all binaries** in parallel (K8s, etcd, containerd, runc, Calico)
4. **Configures Mac** — `/etc/hosts`, SSH config for jump host
5. **Sets up the jump server** — copies SSH keys, Ansible project, binaries
6. **Bootstraps Vault** — install, initialize, unseal
7. **Configures Vault PKI** — 3-tier CA hierarchy with all certificate roles
8. **Issues & deploys certificates** to all nodes via Vault
9. **Deploys etcd** (single node with TLS)
10. **Deploys control plane** — kube-apiserver, controller-manager, scheduler
11. **Deploys worker nodes** — containerd, kubelet, kube-proxy on 2 workers
12. **Installs Calico CNI** and verifies the cluster

### Access the Cluster

```bash
# SSH to the jump server (only host accessible from Mac)
ssh jump

# From jump, access any VM
ssh master-1
ssh worker-1

# Use kubectl (pre-configured on jump)
kubectl get nodes
kubectl get pods -A
```

### Destroy Everything

```bash
./scripts/destroy-vms.sh
```

## Step-by-Step Deployment

For more control, run each phase individually from the jump server:

```bash
# SSH to jump
ssh jump
cd ~/k8s-orbstack-simple-homelab/ansible

# Phase 1: Bootstrap Vault (install, init, unseal, PKI setup)
ansible-playbook -i inventory/homelab.yml playbooks/vault-full-setup.yml

# Phase 2: Issue and deploy certificates to all nodes
ansible-playbook -i inventory/homelab.yml playbooks/k8s-certs.yml

# Phase 3: Deploy etcd
ansible-playbook -i inventory/homelab.yml playbooks/etcd-cluster.yml

# Phase 4: Deploy control plane
ansible-playbook -i inventory/homelab.yml playbooks/control-plane.yml

# Phase 5: Deploy worker nodes
ansible-playbook -i inventory/homelab.yml playbooks/worker.yml
```

## PKI Architecture

All TLS certificates are issued by HashiCorp Vault using a 3-tier CA hierarchy:

```
Root CA (365 days, pathlen:2)
└── Intermediate CA (180 days, pathlen:1)
    ├── Kubernetes CA (90 days, pathlen:0)
    │   ├── kube-apiserver (server + kubelet-client)
    │   ├── kube-controller-manager
    │   ├── kube-scheduler
    │   ├── admin (cluster-admin)
    │   ├── service-account signing key
    │   ├── kube-proxy
    │   └── kubelet (server + client per node)
    ├── etcd CA (90 days, pathlen:0)
    │   ├── etcd-server
    │   ├── etcd-peer
    │   ├── etcd-client (apiserver → etcd)
    │   └── etcd-healthcheck-client
    └── Front Proxy CA (90 days, pathlen:0)
        └── front-proxy-client (API aggregation)
```

## Project Structure

```
k8s-orbstack-simple-homelab/
├── README.md
├── cloud-init/                     # OrbStack cloud-init configs
│   ├── vault.yaml
│   ├── jump.yaml
│   ├── etcd-1.yaml
│   ├── master-1.yaml
│   ├── worker-1.yaml
│   └── worker-2.yaml
├── scripts/
│   ├── k8s-orbstack-simple-homelab.sh   # Full deploy script
│   └── destroy-vms.sh                   # Destroy all VMs + cleanup
├── k8s-binaries/                   # Downloaded binaries (gitignored)
└── ansible/
    ├── ansible.cfg
    ├── requirements.yml
    ├── inventory/
    │   ├── homelab.yml             # Cluster inventory (used on jump)
    │   └── localhost.yml           # Mac localhost inventory
    ├── playbooks/
    │   ├── k8s-orbstack-simple-homelab.yml  # Full orchestration
    │   ├── vault-full-setup.yml
    │   ├── vault-bootstrap.yml
    │   ├── vault-pki.yml
    │   ├── vault-issue-certs.yml
    │   ├── k8s-certs.yml
    │   ├── etcd-cluster.yml
    │   ├── control-plane.yml
    │   ├── worker.yml
    │   └── ping.yml
    └── roles/
        ├── control-plane/          # API server, controller-manager, scheduler
        ├── download-binaries/      # Parallel binary downloads
        ├── etcd/                   # Single-node etcd with TLS
        ├── jump-setup/             # Bastion server configuration
        ├── k8s-certs/              # Certificate issuance via Vault
        ├── mac-setup/              # Mac /etc/hosts + SSH config
        ├── vault-bootstrap/        # Vault install, init, unseal
        ├── vault-pki/              # 3-tier PKI hierarchy
        └── worker/                 # containerd, kubelet, kube-proxy
```

## Comparison: OrbStack vs UTM

| | OrbStack | UTM |
|---|---------|-----|
| VM creation | `orb create` (seconds) | QEMU disk clone + cloud-init ISO |
| Networking | Auto-detected subnet | Fixed 192.168.64.0/24 |
| Resource usage | Lightweight (shared kernel) | Full QEMU emulation |
| Boot time | ~5 seconds | ~30-60 seconds |
| File transfer | `orb push` / `orb run` | SSH/rsync |
| macOS integration | Native menu bar | Separate app |
