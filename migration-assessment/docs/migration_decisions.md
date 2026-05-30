# Migration decisions

Key choices made during the migration and why. Workload classification uses the 6R model.

## Workload classification

| Workload | Pattern | Reason |
|---|---|---|
| PetClinic app | Replatform | Already a container; harden the image and externalize config, no code rewrite |
| PostgreSQL | Replatform | Move from in-cluster StatefulSet to Azure DB for PostgreSQL (managed backups/PITR/HA) |
| Kubernetes Secret | Replatform | Move to Key Vault + CSI rather than carrying plain Secrets forward |

The other 6R patterns apply elsewhere in a real estate even if not used here: **Rehost** when a
workload is already production-grade on Kubernetes and just needs the deployment lifted to AKS
unchanged; **Refactor** when the platform move is the trigger for a code rewrite (e.g., adopting
managed identity in the app instead of a static connection string); **Retire** when the workload
is being deprecated and the migration is the moment to switch it off rather than re-host it.

## Platform and packaging

- CNI: Cilium on both sides. Running Cilium on-prem and Azure CNI powered by Cilium on AKS means
  the same NetworkPolicy/CiliumNetworkPolicy and FQDN model carries over unchanged.
- Packaging: Helm with three values files (on-prem, AKS non-prod, AKS prod). The AKS overlays swap
  the registry, ingress host/TLS, replica counts, and point the app at the managed database instead
  of the in-cluster one. Picked over Kustomize so releases get `helm rollback`.
- Base image: distroless, non-root (uid 65532). Smaller attack surface, satisfies Pod Security
  restricted. Trade-off: no in-container shell, so debugging uses ephemeral `kubectl debug`.
- Multi-arch images: local dev is arm64, AKS nodes are amd64, so images are built for both with
  buildx to avoid exec-format errors on AKS.

## Data and secrets

- Managed PostgreSQL instead of moving the PVC across clusters. Cross-cluster PV moves are fragile;
  a managed Flexible Server with a private endpoint removes the in-cluster stateful risk and keeps
  data in the VNet. Migration is a dump/restore in a maintenance window.
- Key Vault + CSI + workload identity, so no long-lived secrets sit in the cluster. The app's
  ServiceAccount federates to a user-assigned identity and the CSI driver projects the secret the
  chart already references via existingSecret.

## Networking

- Ingress: ingress-nginx, which is the AKS application-routing add-on, so the on-prem setup maps
  across directly. HAProxy is documented as an alternative for connection-heavy, active-health-check
  or L4 edge cases.
- Egress: NAT Gateway for a stable egress IP and to avoid SNAT port exhaustion. Add UDR -> Azure
  Firewall when a partner allowlist has to be enforced and audited centrally.
- Egress on AKS - FQDN limitation: **Azure CNI powered by Cilium does not support `toFQDNs`**
  policies, so the AKS network-policy overlay falls back to `toCIDR` rules for the managed PG
  and partner API egress. Production layers Azure Firewall in front for FQDN-level allowlists
  with the Cilium policy as L3/L4 defense-in-depth. On-prem (upstream Cilium) keeps the precise
  FQDN policy. Evidence and the live AKS matrix are in `docs/test_evidence.md`.
- API endpoint: public with authorized IP ranges here, private for production. Private removes
  public API exposure but needs reachability from CI runners (self-hosted or VNet-joined).

## Delivery and observability

- Registry: GHCR holds the CI build artifact, ACR is what AKS pulls from. GHCR works from Actions
  with the built-in `GITHUB_TOKEN`; ACR is pulled via the kubelet AcrPull role, no image pull
  secrets.
- Observability: Container Insights + managed Prometheus for metrics and logs, Tetragon for eBPF
  runtime visibility (observe-only, enforcement staged later).

## State and configuration source of truth

- Terraform state: **remote `azurerm` backend** (Storage Account + container) so CI runs share
  state and blob lease provides locking. Local state is only used for the one-time bootstrap
  of the state Storage Account itself (chicken-and-egg). See
  [`iac/terraform/README.md`](../iac/terraform/README.md) for the bootstrap commands.
- Terraform runs from CI via the [`terraform`](../../.github/workflows/terraform.yml) workflow
  (manual dispatch, `plan` or `apply`, gated by the `production` environment), authenticated
  via the same OIDC federated identity the deploy uses. No `terraform.tfstate` files on
  engineer laptops, no admin credentials in CI; one source of truth for infra.
- GitHub Environment variables that the workflows consume: currently set as a one-time bootstrap
  from `terraform output` via the `gh variable set` CLI. The production-grade follow-up is the
  `integrations/github` terraform provider to declare each variable as a
  `github_actions_environment_variable` resource - then `terraform apply` updates Azure and
  GitHub atomically.

## Operations: backup, governance, quota, RBAC, support boundaries

- Backup/restore: Azure DB for PostgreSQL keeps automated backups with point-in-time recovery
  (7 days default, up to 35). The cluster itself stores no persistent state by design - the chart
  and values are in git, secrets are in Key Vault - so cluster recovery is `helm upgrade` against
  a freshly applied Terraform landing zone. Velero is the answer if cluster state grows (PVCs,
  CRDs).
- Namespace governance: one namespace per workload, labeled with owner and cost center. Azure
  Policy (the `azure_policy_enabled` add-on) enforces baselines - restricted Pod Security,
  no privileged pods, allowed registries, required labels.
- Quota: ResourceQuota and LimitRange per namespace cap CPU/memory and PVC count; node-pool
  autoscaler ceilings cap cluster spend; the subscription vCPU quota is the hard ceiling above.
- RBAC: production AKS runs Entra-integrated (`local_account_disabled = true`) with
  `azure_rbac_enabled`, so namespace access is granted as Azure role assignments on the cluster.
  App-to-Azure access is workload identity, never kubeconfig or client secrets.
- Support boundaries: Platform owns the cluster, NAT, ingress controller and policies. The app
  team owns the chart, image and rollout. Data team owns managed PostgreSQL. Security owns Key
  Vault contents and the Tetragon policy library.
