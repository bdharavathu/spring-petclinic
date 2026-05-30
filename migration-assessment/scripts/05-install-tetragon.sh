#!/usr/bin/env bash
# install tetragon for runtime observability (observe-only)
set -euo pipefail

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade --install tetragon cilium/tetragon -n kube-system

kubectl -n kube-system rollout status ds/tetragon --timeout=180s
kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon -o wide
