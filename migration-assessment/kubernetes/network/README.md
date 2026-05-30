# Egress & network security (Module 5)

The namespace is **default-deny** for ingress and egress; everything else is an explicit
allowlist. Standard `NetworkPolicy` handles L3/L4 (DNS, DB, ingress-from-nginx); a
`CiliumNetworkPolicy` adds **DNS-aware FQDN egress** so the app can only call an approved
partner API. Cilium unions all policies that select an endpoint.

| File | Purpose |
|---|---|
| `00-default-deny.yaml` | deny all ingress + egress in the namespace |
| `10-allow-dns.yaml` | egress to kube-dns (53) |
| `20-allow-ingress-from-nginx.yaml` | ingress to app:8080 only from the ingress-nginx namespace |
| `30-allow-db.yaml` | app -> postgres:5432, and postgres only accepts the app |
| `40-cilium-egress-fqdn.yaml` | DNS via Cilium L7 proxy + egress to `api.github.com:443` only |

## Test matrix (verified on k3d + Cilium)

| Flow | Port | Expected | Result |
|---|---|---|---|
| petclinic -> postgres | 5432 | Allowed | `succeeded` |
| petclinic -> approved FQDN (`api.github.com`) | 443 | Allowed | `http_status=200` |
| petclinic -> unapproved (`example.com`) | 443 | Denied | curl exit 28 (timeout) |
| ingress-nginx -> petclinic | 8080 | Allowed | `200` via ingress |
| unauthorized namespace -> petclinic | 8080 | Denied | curl exit 28 (timeout) |

Tests run from an ephemeral `netshoot` container sharing the app pod's Cilium identity
(the app image is distroless, so it has no shell of its own). Output in
[`../../docs/test_evidence.md`](../../docs/test_evidence.md).

## AKS variant

The on-prem policies above use `toFQDNs` for the DB and partner-API egress. **Azure CNI powered
by Cilium does not support `toFQDNs`** matching
([Microsoft docs](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium)),
so the AKS overlay in [`../network-aks/`](../network-aks/) uses `toCIDR` for the same flows.
Production layers **Azure Firewall** in front of the cluster for FQDN-level egress, with the
Cilium policy as L3/L4 defense-in-depth. Live AKS test matrix:
[`../../docs/test_evidence.md`](../../docs/test_evidence.md) (Module 5 - egress matrix on AKS).

## AKS outbound strategy

On-prem the firewall/allowlist sits at the edge; on AKS outbound is a cluster property
(`outboundType`). Options:

| Option | What it is | Use when |
|---|---|---|
| `loadBalancer` (default) | SNAT via the cluster's public LB | quick start, no fixed egress IP requirement |
| **`userAssignedNATGateway`** | NAT Gateway on the node subnet | **recommended** - stable egress IP(s), no SNAT port exhaustion at scale |
| `userDefinedRouting` + Azure Firewall | UDR forces egress through a firewall | central FQDN/allowlist enforcement, full traffic logging, compliance |
| Static egress gateway | pin egress to specific node(s)/IP | partner allowlists that key on a fixed source IP |

**Recommendation:** NAT Gateway for stable egress + scale; add UDR->Azure Firewall when the
partner allowlist must be enforced and audited centrally (defense in depth alongside the
in-cluster Cilium FQDN policy).

## Dependencies, private endpoints, limitations

- Partner allowlist: `api.github.com:443` is the modeled approved destination. Real
  partners go in `toFQDNs` (Cilium) and, where enforced at the edge, in the Azure Firewall
  application rules. Source IP for partner allowlists = the NAT Gateway / firewall public IP.
- DNS dependency: FQDN policy only works while DNS flows through Cilium's proxy. The
  `allow-dns` + Cilium DNS rule must exist or FQDN egress silently fails - DNS is a hard
  dependency of the policy.
- Private endpoints: Azure PostgreSQL is reached over a private endpoint (private DNS
  zone `privatelink.postgres.database.azure.com`), so DB traffic never leaves the VNet and
  isn't subject to the egress allowlist.
- Limitations: FQDN policy matches DNS names, not arbitrary IP literals - an app dialing a
  raw IP bypasses `toFQDNs` (mitigate by also denying by CIDR / forcing DNS). TLS SNI isn't
  inspected by L3/L4 NetworkPolicy. Short DNS TTLs can briefly race the policy cache on first
  contact.
