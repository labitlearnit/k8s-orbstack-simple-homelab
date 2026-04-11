#!/bin/bash
# Download all K8s binaries in parallel
# Called by Ansible script module with env vars set

set -e
cd "$BIN_DIR"
pids=()

dl() {
  local url="$1" dest="$2"
  if [[ ! -f "$dest" ]]; then
    curl -sL -o "$dest" "$url" &
    pids+=($!)
  fi
}

# K8s binaries
for bin in kube-apiserver kube-controller-manager kube-scheduler kubectl kubelet kube-proxy; do
  dl "${K8S_DOWNLOAD_URL}/$bin" "$bin"
done

# etcd
dl "$ETCD_DOWNLOAD_URL" "etcd-v${ETCD_VERSION}-linux-arm64.tar.gz"

# containerd
dl "$CONTAINERD_DOWNLOAD_URL" "containerd-${CONTAINERD_VERSION}-linux-arm64.tar.gz"

# runc
dl "$RUNC_DOWNLOAD_URL" "runc.arm64"

# calico
dl "$CALICO_MANIFEST_URL" "calico.yaml"

# Wait for all
failed=0
for pid in "${pids[@]}"; do
  wait "$pid" || failed=$((failed + 1))
done

# Make binaries executable
chmod +x kube-* kubectl kubelet 2>/dev/null || true
chmod +x runc.arm64 2>/dev/null || true

echo "Downloads complete (${#pids[@]} started, $failed failed)"
[[ $failed -eq 0 ]]
