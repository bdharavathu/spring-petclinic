#!/usr/bin/env bash
# build the image, load it into k3d, create the demo db secret, deploy the base manifests
set -euo pipefail

CLUSTER="${CLUSTER:-k3s-to-aks}"
IMAGE="${IMAGE:-petclinic:onprem}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASE="${ROOT}/migration-assessment/kubernetes/base"

echo "==> Building ${IMAGE}"
docker build -f "${ROOT}/migration-assessment/docker/Dockerfile" -t "${IMAGE}" "${ROOT}"

echo "==> Importing ${IMAGE} into k3d cluster '${CLUSTER}'"
k3d image import "${IMAGE}" -c "${CLUSTER}"

echo "==> Applying namespace"
kubectl apply -f "${BASE}/00-namespace.yaml"

echo "==> Creating/updating demo DB secret (generated password; not committed to git)"
DB_PASS="${POSTGRES_PASS:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}"
kubectl create secret generic demo-db -n petclinic \
  --from-literal=username=petclinic \
  --from-literal=password="$DB_PASS" \
  --from-literal=database=petclinic \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying Postgres + PetClinic manifests"
kubectl apply -f "${BASE}/11-postgres.yaml"
kubectl apply -f "${BASE}/20-petclinic-configmap.yaml"
kubectl apply -f "${BASE}/21-petclinic-deployment.yaml"
kubectl apply -f "${BASE}/22-petclinic-service.yaml"

echo "==> Waiting for Postgres"
kubectl -n petclinic rollout status statefulset/postgres --timeout=180s

echo "==> Waiting for PetClinic"
kubectl -n petclinic rollout status deploy/petclinic --timeout=300s

echo "==> Deployed:"
kubectl -n petclinic get pods,svc
