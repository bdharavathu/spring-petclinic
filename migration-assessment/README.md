# Rancher/K3s -> AKS Migration Assessment - Spring PetClinic

Candidate submission for the Kubernetes Engineer hands-on assessment. The source workload
(Spring PetClinic, a Java/Spring Boot monolith + PostgreSQL) is migrated from a simulated
on-prem **k3d (K3s) + Cilium** cluster to **AKS** (Azure CNI powered by Cilium). The Terraform
landing zone is applied against a trial Azure subscription and the workload runs end to end -
including a live data cutover, Tetragon `tcp_connect` events on the real kernel, and an
OIDC-only CI/CD chain (build, deploy, infra and rollback).

Live URL while the demo cluster is up: <http://petclinic.southeastasia.cloudapp.azure.com>
Full live evidence: [`docs/test_evidence.md`](./docs/test_evidence.md) (Live AKS section).

## Environment

| | |
|---|---|
| Workstation | arm64 workstation, local container runtime |
| On-prem sim | k3d (K3s v1.33) with Cilium CNI (flannel/traefik disabled) |
| Database | PostgreSQL 18 (in-cluster StatefulSet on-prem -> Azure DB for PostgreSQL on AKS) |
| AKS target | Terraform IaC applied against a trial subscription; remote state in an `azurerm` backend |
| Registry | GHCR (CI artifact via `migration-ci`) + ACR (AKS pulls via kubelet AcrPull) |

## Quick start (on-prem simulation)

```bash
cd migration-assessment
./scripts/01-create-cluster.sh     # k3d + Cilium
./scripts/03-deploy-app.sh         # build image, load into k3d, deploy app + Postgres
kubectl -n petclinic get pods,svc
# ./scripts/99-teardown.sh         # delete the cluster
```

## Folder map -> assessment modules

| Path | Module |
|---|---|
| [`discovery/`](./discovery) | M1 - inventory crawler, dependency summary, network flows, readiness report, wave plan |
| [`docker/`](./docker) | M2 - multi-stage hardened Dockerfile, compose, Trivy scan |
| [`kubernetes/base/`](./kubernetes/base) | M3 - namespace, Postgres StatefulSet, app Deployment/Service/ConfigMap |
| [`kubernetes/network/`](./kubernetes/network) | M5 - on-prem NetworkPolicy + CiliumNetworkPolicy (toFQDNs) |
| [`kubernetes/network-aks/`](./kubernetes/network-aks) | M5 - AKS variant: toCIDR (Azure CNI Cilium doesn't support toFQDNs) |
| [`kubernetes/ingress/`](./kubernetes/ingress) | M4 - NGINX Ingress + HAProxy alternative |
| [`kubernetes/security/`](./kubernetes/security) | M3/M7 - Pod Security, RBAC, Key Vault CSI |
| [`kubernetes/hpa-pdb/`](./kubernetes/hpa-pdb) | M3 - rendered HPA + PDB (chart is source of truth) |
| [`helm/petclinic/`](./helm/petclinic) | M3 - Helm chart + on-prem/AKS overlays |
| [`tetragon/`](./tetragon) | M6 - Tetragon TracingPolicy + escalation rules |
| [`cicd/`](./cicd) | M8 - GitHub Actions: `migration-ci` (build/scan/push), `aks-deploy` (OIDC), `terraform` (infra), `migration-rollback`; all chained via `workflow_run` |
| [`iac/terraform/`](./iac/terraform) | M7 - AKS + ACR + Key Vault + monitoring |
| [`runbooks/`](./runbooks) | M9 - cutover, rollback, hypercare |
| [`docs/`](./docs) | architecture, decisions, test evidence, risks, presentation |

## Status

- [x] Module 1 - Discovery & inventory (live)
- [x] Module 2 - Containerization & hardening (distroless, Trivy, compose)
- [x] Module 3 - Helm chart & overlays (onprem/aks-nonprod/aks-prod, deployed live)
- [x] Module 4 - Ingress (NGINX + TLS live, HAProxy comparison + cutover)
- [x] Module 5 - Egress & Cilium policy (default-deny + FQDN on-prem, toCIDR on AKS; full test matrix passed both clusters)
- [x] Module 6 - Tetragon runtime observability (process-exec on k3d, `tcp_connect` on the real AKS kernel)
- [x] Module 7 - AKS IaC (Cilium AKS + ACR + Key Vault + NAT, applied live, `terraform plan/apply` runs from CI via OIDC)
- [x] Module 8 - CI/CD (build, Trivy gate (red->green), GHCR push, OIDC deploy, terraform-via-CI, rollback - all chained)
- [x] Module 9 - Runbook & hypercare (cutover, rollback, hypercare; **live data migration cutover executed** - drop/create/restore via in-cluster jump pod)
