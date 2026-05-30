# Migration Readiness Report - Spring PetClinic (Module 1.4 / 1.5)

Source: simulated on-prem **k3d (K3s v1.33) + Cilium** cluster, namespace `petclinic`.
Target: **AKS** (Azure CNI powered by Cilium) - IaC + documented in this submission.

## Readiness summary

| Dimension | State | Ready? |
|---|---|---|
| Containerized | Multi-stage, non-root image built | yes |
| Stateless app tier | `petclinic` holds no local state | yes |
| Stateful tier | `postgres` StatefulSet + PVC - needs managed target | no replatform |
| Config externalized | ConfigMap + Secret (no hardcoded values) | yes |
| Health probes | liveness/readiness/startup via actuator | yes |
| Secrets management | plain K8s Secret today -> Key Vault on AKS | no remediate |
| Network policy | none in source -> default-deny + Cilium on target | no add |
| Image registry | local only -> ACR multi-arch | no add |

## Migration blockers

| # | Blocker | Owner | Remediation | Risk |
|---|---|---|---|---|
| B1 | In-cluster `postgres` is stateful; lift-and-shift of PVC data across clusters is fragile | Platform / DBA | Replatform to Azure DB for PostgreSQL Flexible Server; migrate data via dump/restore in a maintenance window | **High** - data loss / drift if cutover mishandled |
| B2 | Local image is `arm64` but AKS node pools are `amd64` | DevOps | Build multi-arch (`buildx linux/amd64,linux/arm64`) and push to ACR | High - `exec format error` on AKS if single-arch |
| B3 | DB credentials stored as a plain Kubernetes `Secret` | Security | Azure Key Vault + Secret Store CSI + workload identity | Medium - secret sprawl / no rotation |
| B4 | No NetworkPolicy in source (flat east-west) | Platform | Default-deny NetworkPolicy + CiliumNetworkPolicy egress allowlist | Medium - lateral movement |
| B5 | Ingress exposure differs (Traefik/NodePort -> ingress-nginx + DNS/TLS) | Network | Provision ingress-nginx, migrate cert, lower DNS TTL, blue/green switch | Medium - downtime at DNS cutover |
| B6 | No HPA / PDB | App team | Add HPA (CPU) + PDB (minAvailable) in Helm chart | Low - availability under load/disruption |
| B7 | `local-path` storage class not present on AKS | Platform | Use Azure managed CSI; or eliminate by moving DB to managed service (see B1) | Low |
| B8 | Spring actuator probe endpoints must stay enabled | App team | Keep `MANAGEMENT_*` flags in ConfigMap; verify `/actuator/health/{liveness,readiness}` | Low |

## Wave grouping

See [`migration_waves.csv`](./migration_waves.csv). Dependency order is enforced: landing
zone (wave 0) -> managed DB + data load (wave 1) -> app deploy (wave 2) -> DNS/TLS cutover
(wave 3) -> policy + runtime enforcement hardening (wave 4). The database must be ready and
validated before the app tier cuts over.

## Evidence index

- `workload_inventory.json` / `.csv` - generated inventory
- `dependency_summary.md` - dependency classification + graph
- `network_flows.csv` - ingress/egress flow matrix
- `../docs/test_evidence.md` - `kubectl get all -A`, URL test, command output
