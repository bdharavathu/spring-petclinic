#!/usr/bin/env bash
# install ingress-nginx, mint a self-signed TLS cert, enable the Ingress via the on-prem overlay
set -euo pipefail

NS=petclinic
HOST=petclinic.local
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Installing ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s

echo "==> Creating self-signed TLS secret for ${HOST}"
tmp=$(mktemp -d)
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout "$tmp/tls.key" -out "$tmp/tls.crt" \
  -subj "/CN=${HOST}/O=petclinic" -addext "subjectAltName=DNS:${HOST}" 2>/dev/null
kubectl create secret tls petclinic-tls -n "$NS" \
  --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$tmp"

echo "==> Enabling Ingress via on-prem overlay"
helm upgrade petclinic "$ROOT/helm/petclinic" -n "$NS" -f "$ROOT/helm/petclinic/values-onprem.yaml"

echo "==> Done. Test with:"
echo "   curl -H 'Host: ${HOST}' http://localhost:8081/"
echo "   curl -k -H 'Host: ${HOST}' https://localhost:8443/"
