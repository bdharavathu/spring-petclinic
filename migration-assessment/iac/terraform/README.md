# AKS target architecture & IaC (Module 7)

Terraform for a production-shaped AKS landing zone for PetClinic. Validated with
`terraform validate` and applied against the trial subscription to validate the end-to-end
path (see `docs/test_evidence.md` for the live evidence). Run via the
[`terraform`](../../../.github/workflows/terraform.yml) GitHub workflow on every change;
the manual path below is just for the first-time bootstrap.

## Bootstrap (one time, manual)

CI can't create its own state backend (chicken-and-egg). Run these once with admin credentials,
then everything afterwards goes through the workflow.

```bash
# 1. State storage account + container
az group create --name tfstate-rg --location southeastasia
SA="petclinictfstate$(openssl rand -hex 4)"   # remember this name
az storage account create --name "$SA" --resource-group tfstate-rg \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2
az storage container create --name tfstate --account-name "$SA"

# 1. grant user access
USER_ID=$(az ad signed-in-user show --query id -o tsv)
SA_SCOPE=$(az storage account show -n "$SA" -g tfstate-rg --query id -o tsv)
az role assignment create --assignee "$USER_ID" --role "Storage Blob Data Contributor" --scope "$SA_SCOPE"
sleep 60   # storage data-plane RBAC propagation

# 2. Migrate the local tfstate to the new backend
cd migration-assessment/iac/terraform
terraform init -migrate-state -backend-config="storage_account_name=$SA"

# 3. Apply once locally. github_repo provisions the CI identity + its Owner on petclinic-rg;
#    bootstrap_user_object_id pins your user as a second Key Vault Secrets Officer (terraform
#    needs whichever principal writes secrets to have that role; pinning both stops a
#    per-runner toggle that would destroy/recreate the role every local <-> CI alternation).
USER_ID=$(az ad signed-in-user show --query id -o tsv)
terraform apply -var-file=free-tier.tfvars \
  -var="github_repo=<owner>/<repo>" \
  -var="bootstrap_user_object_id=$USER_ID"

# 4. grant ci identity access to state SA
GH_PRINCIPAL=$(az identity show -g petclinic-rg -n petclinic-github-ci --query principalId -o tsv)
SA_SCOPE=$(az storage account show -n "$SA" -g tfstate-rg --query id -o tsv)
az role assignment create --assignee "$GH_PRINCIPAL" --role "Reader"                         --scope "$SA_SCOPE"
az role assignment create --assignee "$GH_PRINCIPAL" --role "Storage Blob Data Contributor"  --scope "$SA_SCOPE"

# 5. Tell the workflow where state lives
gh variable set TFSTATE_SA --env production -R <owner>/<repo> -b "$SA"
```

## Day-to-day (via CI)

GitHub Actions -> Run workflow -> `terraform` -> choose `plan` or `apply`. The job runs in the
`production` environment so it's gated; OIDC swaps the workflow token for the GitHub CI
identity (no stored credentials). `plan` and `apply` both write to the remote state.

Local runs still work for emergency operations:

```bash
terraform init -backend-config="storage_account_name=$SA"
terraform plan -var-file=free-tier.tfvars -var="github_repo=<owner>/<repo>"
```

## What it provisions

- AKS with Azure CNI powered by Cilium (`network_plugin=azure`, `network_plugin_mode=overlay`, `network_data_plane=cilium`), so the same CiliumNetworkPolicy/FQDN model from Module 5 carries over.
- System + user node pools, both autoscaled and zone-spread (1/2/3). System pool is tainted (`only_critical_addons_enabled`) so app workloads land on the user pool.
- NAT Gateway egress (`outbound_type=userAssignedNATGateway`) with a static public IP.
- ACR (Premium), `admin_enabled=false`; the kubelet identity gets `AcrPull` (no image pull secrets).
- Key Vault (RBAC mode) + the cluster's Secret Store CSI add-on identity granted `Key Vault Secrets User`.
- Workload identity (`oidc_issuer_enabled`, `workload_identity_enabled`), Azure Policy, Container Insights (Log Analytics) + managed Prometheus.
- `local_account_disabled=true` - Entra-only cluster auth.

## Key decisions

| Decision | Choice & rationale |
|---|---|
| **API endpoint** | Public + authorized IP ranges in this design (`private_cluster_enabled=false`), flip to **private** for prod. Private removes public API exposure but needs private DNS + reachability from CI/runners (self-hosted agent or VNet-joined). |
| **Subnet sizing** | Overlay mode means **pods don't consume subnet IPs** - only nodes do. A `/20` AKS subnet (~4091 usable) comfortably covers node + autoscale + surge. Pod CIDR `10.244.0.0/16` and service CIDR `10.2.0.0/16` are separate and must not overlap the VNet. |
| **DNS** | `dns_service_ip` (`10.2.0.10`) in the service CIDR for in-cluster DNS. App hostnames resolve to the ingress IP via external DNS / a delegated zone; private clusters use a Private DNS Zone for the API server. |
| **Ingress IP** | ingress-nginx fronted by an Azure LB. **Public** for internet apps; **internal** (`service.beta.kubernetes.io/azure-load-balancer-internal`) for private-only apps reached over ExpressRoute/VPN. |
| **Egress** | **NAT Gateway** for a stable egress IP + no SNAT port exhaustion at scale. Add **UDR -> Azure Firewall** when partner allowlists must be enforced/audited centrally (defense in depth with the Cilium FQDN policy). |
| **Secrets** | Key Vault + Secret Store CSI + workload identity - no long-lived secrets in cluster (see [`../../kubernetes/security/`](../../kubernetes/security/)). |

## Operations

- Backup/restore: AKS Backup (Backup vault + the cluster extension) for PV + cluster-resource snapshots; the managed Postgres has its own PITR. Workloads are re-created from the Helm chart.
- Namespace governance & quota: per-team namespaces with `ResourceQuota` + `LimitRange`; Azure Policy (Gatekeeper) enforces baseline/restricted Pod Security, allowed registries (ACR-only), and required labels.
- RBAC: Entra-integrated, `local_account_disabled=true`; namespace-scoped `RoleBinding`s to Entra groups, cluster-admin reserved to the platform team.
- Support boundaries: Microsoft owns the managed control plane; the platform team owns node pools, networking, add-ons, and governance; app teams own their namespace, workloads, and Helm values.
```