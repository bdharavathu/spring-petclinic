# Architecture: on-prem K3s -> AKS

PetClinic is a Java/Spring Boot monolith with a PostgreSQL dependency. The source runs on a
Rancher/K3s-style cluster (simulated with k3d + Cilium); the target is AKS with Azure CNI
powered by Cilium. The application packaging stays identical across both - only the Helm
overlay and the backing services change.

## Source (on-prem) vs target (AKS)

On-prem (K3s + Cilium):

    client -> ingress-nginx -> petclinic Deployment -> postgres StatefulSet (PVC)

AKS (Azure CNI powered by Cilium):

    client -> Azure LB -> ingress-nginx -> petclinic Deployment
    petclinic -> Azure DB for PostgreSQL (private endpoint)
    petclinic -> Key Vault (secrets projected by the CSI driver)
    petclinic -> NAT Gateway -> approved partner FQDN
    ACR -> petclinic (image pulled via the AcrPull identity, no pull secret)

The app tier and its packaging are unchanged between the two; what changes is the backing
database (in-cluster -> managed), where secrets come from (Secret -> Key Vault), and the
surrounding network (Azure LB ingress, NAT gateway egress).

## Component mapping

| Concern | On-prem | AKS target |
|---|---|---|
| Cluster | k3d / K3s | AKS, system + user node pools, autoscaled, zonal |
| CNI / policy | Cilium (Helm) | Azure CNI powered by Cilium |
| App image | local `petclinic:onprem` | multi-arch image in ACR (AcrPull, no pull secret) |
| Database | in-cluster Postgres StatefulSet + PVC | Azure DB for PostgreSQL Flexible Server (private endpoint) |
| Secrets | Kubernetes `Secret` | Key Vault + Secret Store CSI + workload identity |
| Ingress | ingress-nginx + self-signed TLS | ingress-nginx + Azure LB + cert-manager TLS |
| Egress | cluster default route | NAT Gateway (+ optional UDR/Azure Firewall) |
| Observability | metrics-server, Tetragon | Container Insights + managed Prometheus + Tetragon |
| Auth | local kubeconfig | Entra-only (`local_account_disabled`) |

## Traffic and trust flows

- Inbound from the internet: client -> Azure LB -> ingress-nginx (TLS termination) -> Service ->
  pod 8080.
- Pod-to-pod inside the cluster: default-deny NetworkPolicy; only ingress-nginx may reach the
  app, only the app may reach Postgres.
- Egress: Cilium FQDN policy allows DNS and the approved partner API only; everything else
  denied. Cluster egress leaves through the NAT Gateway's stable IP (partner allowlists key on it).
- Identity: the app's ServiceAccount federates to a user-assigned identity via the cluster OIDC
  issuer; Key Vault secrets are projected into the pod by the CSI driver, never stored in git.

## Repeatability

The same Helm chart with per-environment values (on-prem / AKS non-prod / AKS prod) packages the
workload; the Terraform module stamps out the landing zone. A second workload follows the same
path: discover -> containerize -> chart -> policy -> deploy.
