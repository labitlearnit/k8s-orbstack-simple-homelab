# Vault PKI Role

This role sets up a complete PKI hierarchy in HashiCorp Vault for a Kubernetes cluster.

## PKI Hierarchy

```
┌─────────────────────────────────────────────────────────────┐
│                     Root CA (pki_root)                      │
│                   CN: Homelab Root CA                       │
│                TTL: 365 days | pathlen:2                    │
└─────────────────────────┬───────────────────────────────────┘
                          │ signs
                          ▼
┌─────────────────────────────────────────────────────────────┐
│               Intermediate CA (pki_int)                     │
│              CN: Homelab Intermediate CA                    │
│                TTL: 180 days | pathlen:1                    │
└───────┬─────────────────┼─────────────────┬─────────────────┘
        │ signs           │ signs           │ signs
        ▼                 ▼                 ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────────────┐
│ Kubernetes CA │ │   etcd CA     │ │   Front Proxy CA      │
│(pki_kubernetes)│ │  (pki_etcd)   │ │  (pki_front_proxy)    │
│ TTL: 90 days  │ │ TTL: 90 days  │ │    TTL: 90 days       │
│  pathlen:0    │ │  pathlen:0    │ │     pathlen:0         │
└───────────────┘ └───────────────┘ └───────────────────────┘
```

## Certificate Authorities

### Root CA (`pki_root`)

| Property | Value |
|----------|-------|
| Common Name | Homelab Root CA |
| TTL | 365 days (8760h) |
| Path Length | 2 |
| Vault Path | `pki_root/` |

**Purpose:** The trust anchor for the entire PKI hierarchy. This CA is kept offline conceptually—it only signs the Intermediate CA certificate. All trust in the cluster ultimately chains back to this Root CA.

---

### Intermediate CA (`pki_int`)

| Property | Value |
|----------|-------|
| Common Name | Homelab Intermediate CA |
| TTL | 180 days (4320h) |
| Path Length | 1 |
| Vault Path | `pki_int/` |
| Signed By | Root CA |

**Purpose:** Acts as a signing CA for the three sub-CAs (Kubernetes, etcd, Front Proxy). This layer provides:
- **Isolation:** Root CA key is only used once (to sign the Intermediate)
- **Rotation:** Sub-CAs can be rotated without touching the Root
- **Revocation:** Revoking the Intermediate invalidates all downstream certificates

---

### Kubernetes CA (`pki_kubernetes`)

| Property | Value |
|----------|-------|
| Common Name | Kubernetes CA |
| TTL | 90 days (2160h) |
| Path Length | 0 |
| Vault Path | `pki_kubernetes/` |
| Signed By | Intermediate CA |

**Purpose:** Signs all certificates for Kubernetes control plane and node authentication:

| Component | Certificate Type | Description |
|-----------|-----------------|-------------|
| kube-apiserver | Server | TLS for API server endpoints |
| kube-apiserver | Client | Authenticates to kubelet for logs/exec |
| kube-controller-manager | Client | Authenticates to kube-apiserver |
| kube-scheduler | Client | Authenticates to kube-apiserver |
| admin | Client | Cluster admin authentication |
| service-account | Signing Key | Signs ServiceAccount tokens |
| kube-proxy | Client | Authenticates to kube-apiserver |
| kubelet | Server | TLS for kubelet API on each node |
| kubelet | Client | Node authenticates to kube-apiserver |

---

### etcd CA (`pki_etcd`)

| Property | Value |
|----------|-------|
| Common Name | etcd CA |
| TTL | 90 days (2160h) |
| Path Length | 0 |
| Vault Path | `pki_etcd/` |
| Signed By | Intermediate CA |

**Purpose:** Signs all certificates for etcd cluster communication:

| Certificate | Description |
|-------------|-------------|
| etcd-server | TLS for etcd client-facing endpoints (port 2379) |
| etcd-peer | Mutual TLS between etcd cluster members (port 2380) |
| etcd-client | Clients connecting to etcd (kube-apiserver) |
| etcd-healthcheck | Health check probes for etcd |

**Why separate from Kubernetes CA?**
- **Security isolation:** Compromised K8s certs can't access etcd directly
- **etcd is the source of truth:** Extra protection for cluster state
- **Different trust domain:** etcd cluster is a distinct service

---

### Front Proxy CA (`pki_front_proxy`)

| Property | Value |
|----------|-------|
| Common Name | Front Proxy CA |
| TTL | 90 days (2160h) |
| Path Length | 0 |
| Vault Path | `pki_front_proxy/` |
| Signed By | Intermediate CA |

**Purpose:** Signs certificates for the Kubernetes aggregation layer (API aggregation).

| Certificate | Description |
|-------------|-------------|
| front-proxy-client | kube-apiserver uses this to authenticate when proxying requests to extension API servers |

**Why separate from Kubernetes CA?**
- **Extension API servers** (like metrics-server) need to verify the request is from kube-apiserver
- The front-proxy-client cert proves the request was proxied by a legitimate kube-apiserver
- Different trust domain prevents cert confusion attacks

---

## Trust Relationships

```
                    ┌──────────────┐
                    │   Root CA    │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │Intermediate  │
                    │     CA       │
                    └──────┬───────┘
           ┌───────────────┼───────────────┐
           │               │               │
    ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
    │ Kubernetes  │ │    etcd     │ │ Front Proxy │
    │     CA      │ │     CA      │ │     CA      │
    └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │               │               │
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │  K8s certs  │ │ etcd certs  │ │ front-proxy │
    │ (apiserver, │ │  (server,   │ │    cert     │
    │  kubelet,   │ │   peer,     │ └─────────────┘
    │  scheduler) │ │   client)   │
    └─────────────┘ └─────────────┘
```

## Usage

```bash
# Set Vault token
export VAULT_TOKEN="hvs.xxxxx"

# Run the playbook
ansible-playbook playbooks/vault-pki.yml
```

## Prerequisites

- Vault initialized and unsealed
- `VAULT_TOKEN` environment variable set
- `community.hashi_vault` Ansible collection installed
- `hvac` Python library installed
