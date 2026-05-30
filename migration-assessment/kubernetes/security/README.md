# Security: Pod Security, secrets, RBAC

## Pod Security Admission

The `petclinic` namespace ([`../base/00-namespace.yaml`](../base/00-namespace.yaml)) enforces
`baseline` and warns/audits on `restricted`. The app already meets `restricted` (non-root uid
65532, all caps dropped, read-only root FS, seccomp RuntimeDefault); the in-cluster Postgres
keeps the namespace at `baseline` (the official image starts as root). On AKS the database is a
managed service, so the namespace moves to **enforce `restricted`**.

## Secrets - Key Vault + CSI + workload identity (AKS)

No long-lived secrets live in the cluster. Flow:

1. Terraform grants the cluster's Secret Store CSI identity `Key Vault Secrets User`.
2. The app `ServiceAccount` is federated to a user-assigned identity via the cluster OIDC issuer
   and annotated `azure.workload.identity/client-id: <client-id>`.
3. [`secretproviderclass.yaml`](./secretproviderclass.yaml) mounts the KV secrets and projects
   them into a `petclinic-db` Secret.
4. The Helm chart references it as `database.existingSecret: petclinic-db` (AKS overlays) -
   the same indirection used on-prem, so the Deployment template is unchanged.

```
Key Vault --(CSI + workload identity)--> Secret petclinic-db --secretKeyRef--> petclinic pod
```

## RBAC & registry governance

- Cluster auth is Entra-only (`local_account_disabled=true`). Access is granted via
  namespace-scoped `RoleBinding`s to Entra groups; cluster-admin is reserved to the platform team.
- Azure Policy / Gatekeeper enforces: Pod Security baseline/restricted, allowed registries
  (ACR only), required labels, and no privileged/hostPath workloads.
- Image pull uses the kubelet's `AcrPull` role - no image pull secrets.
