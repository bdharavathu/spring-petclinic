#!/usr/bin/env bash
# Delete the on-prem simulation cluster.
set -euo pipefail
CLUSTER="${CLUSTER:-k3s-to-aks}"
k3d cluster delete "${CLUSTER}"
echo "Deleted cluster '${CLUSTER}'."
