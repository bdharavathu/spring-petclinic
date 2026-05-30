#!/usr/bin/env bash
# create the k3d on-prem sim cluster with Cilium as CNI (flannel/traefik disabled)
set -euo pipefail

CLUSTER="k3s-to-aks"
CILIUM_VERSION="${CILIUM_VERSION:-1.16.5}"

if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER}\b"; then
  echo "Cluster '${CLUSTER}' already exists. Delete it with: k3d cluster delete ${CLUSTER}"
  exit 0
fi

echo "==> Creating k3d cluster '${CLUSTER}' (flannel/traefik/netpol disabled)"
k3d cluster create "${CLUSTER}" \
  --k3s-arg "--flannel-backend=none@server:*" \
  --k3s-arg "--disable-network-policy@server:*" \
  --k3s-arg "--disable=traefik@server:*" \
  --port "8081:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --wait

echo "==> Installing Cilium ${CILIUM_VERSION} via Helm"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version "${CILIUM_VERSION}" \
  --set operator.replicas=1 \
  --set ipam.mode=kubernetes \
  --set cni.exclusive=false \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

echo "==> Waiting for Cilium to be ready"
kubectl -n kube-system rollout status ds/cilium --timeout=180s
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=180s

echo "==> Waiting for nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "==> Cluster ready:"
kubectl get nodes -o wide
