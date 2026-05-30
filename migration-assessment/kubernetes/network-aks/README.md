# Network policies - AKS overlay (Module 5 on the live target)

Mirrors [`../network/`](../network/) but adapted for the AKS deploy:

- **Ingress** allows from `app-routing-system` (the managed app-routing add-on namespace), not
  `ingress-nginx`.
- **External egress** (managed PG, partner API) is `CiliumNetworkPolicy` with **`toCIDR`** -
  not `toFQDNs` - because Azure CNI powered by Cilium does not support FQDN matching:
  [docs](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium#limitations).
  On-prem uses `toFQDNs`; production AKS would layer **Azure Firewall** in front for
  FQDN-level egress with these Cilium rules as L3/L4 defense-in-depth. The IPs pinned here are
  the currently-resolved targets and will rotate; in production they would be Azure Firewall
  application rules.
- **DNS** and **default-deny** are identical to on-prem.

## Apply order matters

Filenames are numbered so `kubectl apply -f .` applies them in the right order: the four
allowlists (10/20/30/40) land first, `99-default-deny` last. Reversing this would momentarily
block existing connections; this order keeps the app healthy throughout.

Applied by the [`aks-deploy`](../../../.github/workflows/aks-deploy.yml) workflow on every run,
so the cluster's policy set always matches what's in git. Manual reconcile:

```bash
kubectl apply -f .
```

If the app loses the DB after `99-default-deny` lands, `kubectl delete -f 99-default-deny.yaml`
restores the implicit-allow and we debug the FQDN rule.
