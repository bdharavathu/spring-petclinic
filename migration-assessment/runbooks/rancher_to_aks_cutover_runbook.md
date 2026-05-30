# Rancher/K3s -> AKS cutover runbook

Migrating PetClinic (app + PostgreSQL) from the on-prem K3s cluster to AKS. Rollback and
hypercare are in [`rollback_plan.md`](./rollback_plan.md) and [`hypercare_plan.md`](./hypercare_plan.md).

## Workload classification (6R)

| Workload | Pattern | Target |
|---|---|---|
| PetClinic app | Replatform | container in ACR, Helm release on AKS |
| PostgreSQL | Replatform | Azure DB for PostgreSQL Flexible Server (private endpoint) |
| Kubernetes Secret | Replatform | Key Vault + Secret Store CSI |

## Source -> target mapping

| Resource | On-prem | AKS | How |
|---|---|---|---|
| Namespace | `petclinic` | `petclinic` | Helm / kubectl |
| ServiceAccount | plain SA | SA + workload-identity annotation | Helm values |
| RBAC | local kubeconfig | Entra-group RoleBindings | apply per namespace |
| Secrets | `demo-db` Secret | Key Vault -> `petclinic-db` via CSI | SecretProviderClass |
| ConfigMap | `petclinic-config` | same (per-env values) | Helm overlay |
| PVC | `data-postgres-0` (local-path) | none (managed DB) | dump/restore into Azure PostgreSQL |
| Ingress | ingress-nginx, self-signed TLS | ingress-nginx + Azure LB, cert-manager TLS | Helm overlay |
| Certificates | self-signed | cert-manager (Let's Encrypt) or imported | cluster issuer |
| Scheduling | single node | app -> user node pool; system pool tainted | node pools |

Wave order is in [`../discovery/migration_waves.csv`](../discovery/migration_waves.csv): landing
zone -> managed DB + data load -> app deploy -> DNS/TLS cutover -> policy/runtime hardening.

## Pre-cutover

1. Apply the Terraform landing zone (AKS + ACR + Key Vault + NAT + monitoring).
2. Build and push the image to ACR (multi-arch); confirm the AKS overlay points at it.
3. Provision Azure DB for PostgreSQL + private endpoint; create the DB/user.
4. Sync DB credentials into Key Vault; verify the CSI `petclinic-db` Secret projects into a pod.
5. Deploy to the AKS non-prod overlay; run the validation checks below.
6. Lower DNS TTL on the app hostname to 60s at least 24h ahead.

## Cutover (maintenance window)

1. Drain the AKS app while we migrate data: `kubectl scale deploy petclinic --replicas=0`.
2. **Data migration** - drop/create/restore via an in-cluster jump pod, so the data plane never
   leaves the VNet and the source needs no firewall whitelisting:
   - On the source, dump in custom format: `pg_dump -U petclinic -d petclinic -Fc -f /tmp/petclinic.dump`.
   - Launch a `postgres:18-alpine` pod in the AKS `petclinic` namespace (has `psql` and
     `pg_restore`), with `PGPASSWORD` from Key Vault as an env. `kubectl cp` the dump in.
   - From inside the jump pod, drop and recreate the target DB - has to be from the
     `postgres` bootstrap DB, and each statement as its own `psql -c` (multi-statement `-c` wraps
     in an implicit transaction and `DROP DATABASE` won't run there):
     ```
     psql "...dbname=postgres..." \
       -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='petclinic' AND pid <> pg_backend_pid();" \
       -c "DROP DATABASE petclinic;" \
       -c "CREATE DATABASE petclinic;"
     ```
   - `pg_restore -h $PGHOST -U $PGUSER -d petclinic --no-owner --no-acl /tmp/petclinic.dump`.
     `--no-owner` / `--no-acl` survive the role mismatch (source owner role `petclinic` doesn't
     exist on Azure DB). Schema, data, indexes, FKs and sequences load in one pass - no FK
     ordering games, no `setval` follow-up.
   - Verify row counts match the source for `owners`, `pets`, `visits`.
3. `helm upgrade --install` the prod overlay on AKS (CI deploy job or manual) and bring the app
   back: `kubectl scale deploy petclinic --replicas=1`.
4. Validate against the AKS ingress IP using a `Host:` header before touching DNS.
5. Switch traffic: blue/green DNS flip to the AKS public IP (or canary 5 -> 25 -> 100%).

Why drop/create/restore over `--data-only`: `pg_restore --data-only` against an existing schema
restores tables in TOC (alphabetical) order, not FK-dependency order, so `pets` tries to load
before `types` and the run fails on FK constraints; `--disable-triggers` would fix it but needs
superuser, which Azure DB Flexible Server's admin role does not have. Dropping and recreating
the database side-steps the whole class of problem.

## Post-cutover

1. Run the full validation set (below); watch dashboards and Tetragon events.
2. Keep the on-prem stack warm through the hypercare window.
3. Decommission on-prem only after hypercare exits clean.

## Validation

- Smoke: `/` returns 200, `/actuator/health` UP, `vets.html` renders, create/find an owner.
- Performance: p95 latency and 5xx rate within SLO under expected load.
- Observability: Container Insights + Prometheus scraping, Tetragon events flowing.
- Business: a user can register a pet and book a visit end to end.

## Rollback

Full procedure in [`rollback_plan.md`](./rollback_plan.md). Triggers: smoke fails, p95 latency
or 5xx rate exceeds SLO during the canary, or business validation reports a critical defect.
Per-stage:

- DNS not flipped yet -> stop the cutover, leave on-prem live, fix forward.
- DNS flipped, AKS unhealthy -> reverse DNS (TTL is already 60s) and `helm rollback petclinic 0
  -n petclinic` to the previous release.
- Data migration mid-flight -> abort the dump/restore, point on-prem back to writes, re-plan.
