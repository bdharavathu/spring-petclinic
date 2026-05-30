# Known risks

Risk register for the migration. Likelihood/impact are L/M/H.

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | Database cutover loses or drifts data | M | H | Dump/restore inside a maintenance window with the app in read-only; validate row counts and a smoke test against the managed DB before flipping the app |
| R2 | Image arch mismatch (arm64 build, amd64 AKS nodes) | M | H | Build multi-arch with `buildx linux/amd64,linux/arm64`; verify the pulled digest on AKS |
| R3 | DNS cutover causes downtime | M | M | Lower TTL ahead of time, blue/green flip with on-prem kept warm, rollback by reverting the record |
| R4 | Secret migration to Key Vault misconfigured | M | M | Provision Key Vault and CSI and federated identity first; verify the projected Secret in non-prod before prod cutover |
| R5 | Application dependency CVEs (criticals present) | M | M | Upgrade the Spring Boot parent and JDBC driver before production; CI fails on fixable HIGH/CRITICAL |
| R6 | Tetragon enforcement disrupts workloads | L | M | Keep observe-only initially; enable Sigkill actions only after the observe baseline is trusted |
| R7 | Cilium FQDN policy silently fails if DNS is blocked | L | M | Keep the DNS allow rule alongside the FQDN policy; test allowed and denied destinations after any policy change |
| R8 | Private API server unreachable from CI | M | M | Use a self-hosted or VNet-joined runner, or keep public with authorized IP ranges until the runner is in place |
| R9 | Cost (AKS, NAT Gateway, Premium ACR, managed DB) | M | M | Right-size node pools, rely on autoscaling, review SKUs per environment |
| R10 | k3d/OrbStack lab differences from AKS | L | L | Treat the local cluster as a functional simulation; validate platform-specific behavior (private endpoints, managed identity) on AKS during non-prod |

## Assumptions

- A single representative workload is migrated to prove the pattern; further waves reuse it.
- AKS is delivered as Terraform and applied against a trial Azure subscription for end-to-end
  validation; the live evidence is in `docs/test_evidence.md`.
- The partner API is modeled with a stable public FQDN to exercise the egress allowlist.
