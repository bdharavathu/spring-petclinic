# Test Evidence

Captured from the on-prem simulation (K3s + Cilium, namespace `petclinic`).

---

## Module 1 - Discovery (Task 1.1: app running in simulated K3s)

### Cluster / node
```
❯ kubectl get nodes
NAME                      STATUS   ROLES                  AGE   VERSION
k3d-k3s-to-aks-server-0   Ready    control-plane,master   16h   v1.33.4+k3s1
```

### Cilium is the CNI (flannel disabled)
```
❯ kubectl -n kube-system get pods -l k8s-app=cilium
NAME           READY   STATUS    RESTARTS   AGE
cilium-hnlzx   1/1     Running   0          16h
```

### Workloads and services
```
❯ kubectl -n petclinic get all
NAME                             READY   STATUS    RESTARTS   AGE
pod/petclinic-5b8b4bcbbc-ql4tj   1/1     Running   0          3h1m
pod/postgres-0                   1/1     Running   0          15h

NAME                TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/petclinic   ClusterIP   10.43.229.114   <none>        80/TCP     15h
service/postgres    ClusterIP   None            <none>        5432/TCP   15h

NAME                        READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/petclinic   1/1     1            1           15h

NAME                        READY   AGE
statefulset.apps/postgres   1/1     15h

❯ kubectl -n petclinic get pvc
NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data-postgres-0   Bound    pvc-818dd8a9-a878-4439-992f-0c48b0e1e03e   1Gi        RWO            local-path
```

### URL test (Task 1.1 evidence)
```
❯ kubectl -n petclinic port-forward svc/petclinic 8088:80 &
❯ curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8088/
200
❯ curl -s http://127.0.0.1:8088/actuator/health
{"groups":["liveness","readiness"],"status":"UP"}
❯ curl -s http://127.0.0.1:8088/vets.html | grep -o "<title>.*</title>"
<title>PetClinic :: a Spring Framework demonstration</title>
```
The DB-backed `vets.html` rendering confirms PetClinic <-> PostgreSQL connectivity and that
`spring.sql.init` initialized the schema/data on startup.

---

## Module 1 - Inventory crawler (Task 1.2)

```
❯ python3 k8s_inventory_crawler.py -n petclinic
2 workload containers, 2 services, 0 ingress, 2 configmaps, 1 secrets, 1 pvc, ...
```

Generated CSV:
```
namespace,kind,name,container,image,runtime,...,databases,...
petclinic,Deployment,petclinic,petclinic,petclinic:onprem,...,jdbc:postgresql://postgres:5432/petclinic,...
petclinic,StatefulSet,postgres,postgres,postgres:18.3,postgres,...,...
```

Secret handling - **keys only, values never read**:
```json
{ "namespace": "petclinic", "name": "demo-db", "type": "Opaque",
  "keys": ["database", "password", "username"] }
```

Artifacts: [`discovery/workload_inventory.json`](../discovery/workload_inventory.json),
[`discovery/workload_inventory.csv`](../discovery/workload_inventory.csv),
[`discovery/dependency_summary.md`](../discovery/dependency_summary.md),
[`discovery/network_flows.csv`](../discovery/network_flows.csv),
[`discovery/migration_readiness_report.md`](../discovery/migration_readiness_report.md),
[`discovery/migration_waves.csv`](../discovery/migration_waves.csv).

---

## Module 2 - Containerization & hardening

### Non-root distroless image runs and serves
```
❯ kubectl -n petclinic get pod -l app.kubernetes.io/name=petclinic -o jsonpath='{.items[0].spec.securityContext}'
{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}

❯ curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8089/
200
❯ curl -s http://127.0.0.1:8089/actuator/health
{"groups":["liveness","readiness"],"status":"UP"}
```

### Image scanning (Trivy)
Moving the runtime from a full JRE base to **distroless**.
There are two application-dependency CVEs issues, which were fixed by upgrading them to newer versions, documented the Scan policy and remediation approach in [`docker/README.md`](../docker/README.md).

---

## Module 3 - Helm chart & overlays

### Lint, environment separation (same chart, different overlays)
```
❯ helm lint helm/petclinic -f helm/petclinic/values-onprem.yaml
1 chart(s) linted, 0 chart(s) failed

# with onprem.yaml: in-cluster Postgres sts, no Ingress
ConfigMap Deployment HPA PDB Service(x2) ServiceAccount StatefulSet
# with aks-prod.yaml: Ingress present, NO StatefulSet (managed Azure PostgreSQL)
ConfigMap Deployment HPA Ingress PDB Service ServiceAccount
```
Rendered snapshots: [`kubernetes/rendered/onprem.yaml`](../kubernetes/rendered/onprem.yaml),
[`kubernetes/rendered/aks-prod.yaml`](../kubernetes/rendered/aks-prod.yaml).

### Deployed live (on-prem overlay)
```
❯ helm -n petclinic history petclinic
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         deployed    Upgrade complete     

❯ kubectl -n petclinic get pods -l app.kubernetes.io/name=petclinic
NAME              READY   STATUS    RESTARTS
petclinic-5b8b4bcbbc-ql4tj   1/1     Running   0

❯ kubectl -n petclinic get hpa
NAME        REFERENCE              TARGETS       MINPODS   MAXPODS   REPLICAS
petclinic   Deployment/petclinic   cpu: 2%/75%   1         4         1          

❯ kubectl -n petclinic get pdb
NAME        MIN AVAILABLE   ALLOWED DISRUPTIONS
petclinic   1               0
```
Rollback is `helm rollback petclinic 1 -n petclinic` (mentioned in Module 8).

---

## Module 4 - Ingress (NGINX live and TLS)

```
❯ kubectl -n petclinic describe ingress petclinic
Ingress Class:  nginx
TLS:            petclinic-tls terminates petclinic.local
Rules:          petclinic.local  /  ->  petclinic:80 (10.42.0.191:8080)

# HTTP is redirected to HTTPS (ingress-nginx force-ssl-redirect)
❯ curl -s -o /dev/null -w "%{http_code}\n" -H 'Host: petclinic.local' http://localhost:8081/
308

# HTTPS terminates at the controller with our cert, returns 200
❯ curl -sk -o /dev/null -w "%{http_code}\n" -H 'Host: petclinic.local' https://localhost:8443/
200
❯ echo | openssl s_client -connect localhost:8443 -servername petclinic.local 2>/dev/null | openssl x509 -noout -subject
subject=CN=petclinic.local, O=petclinic

# DB-backed page served end-to-end through ingress + TLS
❯ curl -sk -H 'Host: petclinic.local' https://localhost:8443/vets.html | grep -o "<title>.*</title>"
<title>PetClinic :: a Spring Framework demonstration</title>
```

NGINX vs HAProxy comparison, HAProxy alternative manifest, and the DNS/TLS cutover design:
[`kubernetes/ingress/README.md`](../kubernetes/ingress/README.md),
[`kubernetes/ingress/haproxy-ingress.yaml`](../kubernetes/ingress/haproxy-ingress.yaml).

---

## Module 5 - Egress & Cilium network policy

Namespace is default-deny; allowlist via standard NetworkPolicy (L3/L4) + CiliumNetworkPolicy
(DNS-aware FQDN). App still serves 200 through ingress after default-deny (DNS/DB/ingress allows OK).

Egress tests from an ephemeral `jump` container sharing the app pod's Cilium identity:
```
[1] DB postgres:5432 (expect ALLOWED)
Connection to postgres (10.42.0.77) 5432 port [tcp/postgresql] succeeded!
[2] approved FQDN api.github.com:443 (expect ALLOWED)
  http_status=200
[3] unapproved example.com:443 (expect DENIED)
  http_status=000
  BLOCKED exit=28
```
Cross-namespace isolation (pod in `test-unauthorized` -> petclinic pod 8080):
```
status=000
BLOCKED exit=28
```

| Flow | Port | Expected | Result |
|---|---|---|---|
| petclinic -> postgres | 5432 | Allowed | succeeded |
| petclinic -> api.github.com | 443 | Allowed | 200 |
| petclinic -> example.com | 443 | Denied | exit 28 |
| ingress-nginx -> petclinic | 8080 | Allowed | 200 |
| unauthorized ns -> petclinic | 8080 | Denied | exit 28 |

Policies + AKS outbound strategy: [`kubernetes/network/`](../kubernetes/network/).

---

## Module 6 - Tetragon runtime observability

Tetragon installed observe-only; DaemonSet `2/2 Running` (eBPF loads successfully).

Live process-exec capture for the petclinic namespace (via the `export-stdout` container):
```
process_exec  petclinic-5b8b4bcbbc-ql4tj  /usr/lib/jvm/.../bin/java -jar /app/app.jar             # pod start
process_exec  petclinic-5b8b4bcbbc-ql4tj  /bin/sh -c "curl ...; nc -zv -w3 postgres 5432; id"     # injected shell
process_exec  petclinic-5b8b4bcbbc-ql4tj  /usr/bin/curl -s -m5 -o /dev/null https://api.github.com
process_exec  petclinic-5b8b4bcbbc-ql4tj  /usr/bin/nc -zv -w3 postgres 5432
process_exec  postgres-0       /usr/lib/postgresql/18/bin/pg_isready -U petclinic -d petclinic
```
Notes and escalation rules:
[`tetragon/README.md`](../tetragon/README.md), [`tetragon/sample-events.txt`](../tetragon/sample-events.txt).

---

## Module 7 - AKS IaC (Terraform)

```
❯ terraform fmt
❯ terraform init -backend=false
❯ terraform validate
Success! The configuration is valid.
```
Provisions Cilium-powered AKS (azure CNI overlay + cilium data plane), system+user node pools
(autoscaled, zonal), NAT Gateway egress, ACR (AcrPull, no admin), Key Vault + Secret Store CSI,
workload identity, Azure Policy, Container Insights + managed Prometheus. Code + architecture
decisions (endpoint/subnet/DNS/ingress IP/firewall/backup/governance/RBAC):
[`iac/terraform/`](../iac/terraform/). Key Vault CSI pattern: [`kubernetes/security/`](../kubernetes/security/).

---

## Module 8 - CI/CD

Two workflows (build vs deploy), copies under [`cicd/`](../cicd/):
[`migration-ci.yml`](../../.github/workflows/migration-ci.yml) (build -> Trivy scan -> GHCR push)
and [`aks-deploy.yml`](../../.github/workflows/aks-deploy.yml) (OIDC -> Helm deploy to AKS).

- The scan gate first failed on the app's fixable HIGH/CRITICAL dependency CVEs; the build went
  red and push was skipped.

- Remediated by bumping the Spring Boot parent to 4.0.6 and overriding tomcat to 11.0.22 and the
  PostgreSQL JDBC driver to 42.7.11 in `pom.xml`. The next run passed the gate and published:
  ```
  ghcr.io/bdharavathu/petclinic:$commit_sha
  ghcr.io/bdharavathu/petclinic:latest
  ```

- `aks-deploy` authenticates by **OIDC workload-identity federation** (no stored kubeconfig) and
  is gated by the GitHub `production` environment. Every endpoint/ID is a GitHub environment
  variable sourced from Terraform outputs..

- Rollback: [`.github/workflows/migration-rollback.yml`](../../.github/workflows/migration-rollback.yml)
  (manual, OIDC) runs `helm rollback`.

---

## Module 9 - Migration runbook, rollback and hypercare

Runbooks are in [`../runbooks/`](../runbooks/) - `rancher_to_aks_cutover_runbook.md` (source->target
mapping, 6R, pre/cutover/post steps, validation), `rollback_plan.md`, `hypercare_plan.md` - and
the wave plan is [`../discovery/migration_waves.csv`](../discovery/migration_waves.csv). Live
cutover execution is below under [Data migration cutover (live)](#data-migration-cutover-live).

---

## Live AKS deployment

```
❯ curl -o /dev/null -s -w "%{http_code}\n" http://petclinic.southeastasia.cloudapp.azure.com
200
```
Tweaks made for AKS provision due to free trial limitations:

- **Cluster:** AKS 1.33, Azure CNI **powered by Cilium**, 2 x `Standard_B2s_v2` nodes (4 vCPU regional cap on the trial). Public API with authorized IP ranges, NAT Gateway for egress.
- **Image:** `petclinicacrgqweq.azurecr.io/petclinic:1.0.0`, pulled via the kubelet AcrPull
  identity (no image-pull secrets).
- **Database:** Azure DB for PostgreSQL Flexible Server (`petclinic-pg-gqweq...`); credentials in Azure Key Vault, projected into the `petclinic-db` Secret via the **Secret Store CSI driver + workload identity** (`SecretProviderClass` rendered from the Helm chart).
- **Ingress:** managed `webapprouting.kubernetes.azure.com` (the AKS app-routing add-on, which is managed ingress-nginx). Public IP carries an Azure DNS label.
- **Public URL:** `http://petclinic.southeastasia.cloudapp.azure.com/` returns the PetClinic UI; `/vets.html` renders DB-backed rows, proving the Key Vault -> CSI -> managed PG chain works.


- **Tetragon:** installed via the OIDC `aks-deploy` workflow. The `monitor-egress-connect`
  TracingPolicy delivers `tcp_connect` events with full socket details on the real Ubuntu 22.04 kernel - see [`../tetragon/aks-events.json`](../tetragon/aks-events.json). This closes the k3d lab limitation where the kprobe loaded but did not emit events.


### Egress matrix on the live AKS cluster

The same Module 5 matrix, now executed against AKS instead of the k3d simulation. Network
policies in [`kubernetes/network-aks/`](../kubernetes/network-aks/) are applied by the
[`aks-deploy`](../../.github/workflows/aks-deploy.yml) workflow on every run, so cluster state
matches git. Matrix tests run from inside the petclinic pod's network namespace via
`kubectl debug --target=petclinic`, so the debug container inherits the pod's Cilium identity.

| Flow | Port | Expected | Result |
|---|---|---|---|
| petclinic -> managed PG | 5432 | Allowed | `4.193.230.74:5432 open` |
| petclinic -> api.github.com (modeled partner) | 443 | Allowed | `http_status=200` |
| petclinic -> example.com (unapproved) | 443 | Denied | `http_status=000` |
| ingress (app-routing) -> petclinic | 8080 | Allowed | `/vets.html` -> 200 (DB-backed) |
| unauthorized ns -> petclinic | 8080 | Denied | `http_status=000` |

The on-prem policies in [`kubernetes/network/`](../kubernetes/network/) use `toFQDNs` for the DB
and partner API egress. The AKS variants use `toCIDR` instead because **Azure CNI powered by
Cilium does not support `toFQDNs` matching**
([Microsoft docs](https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium)).
Production mitigation: layer **Azure Firewall** in front for FQDN-level egress with these Cilium
rules as L3/L4 defense-in-depth - two enforcement points, two failure modes.


### Data migration cutover (live)

End-to-end data move from the on-prem k3d cluster to AKS, executed with the runbook
[Cutover (maintenance window)](../runbooks/rancher_to_aks_cutover_runbook.md#cutover-maintenance-window)
procedure - drop/create/restore through an in-cluster jump pod, so the source database needs no
firewall whitelisting.

1. **Add data through the on-prem UI** at `http://petclinic.local/owners/new`: owner
   `Migration / Demo` (1 Cutover Street, Production), pet `Patch`. Verified in the source DB.
2. **Drain AKS** with `kubectl scale deploy petclinic --replicas=0`.
3. **Dump source** in custom format from the on-prem postgres pod:
   `pg_dump -U petclinic -d petclinic -Fc -f /tmp/petclinic.dump`.

4. **Launch jump pod** `pg-jump` (`postgres:18-alpine`) in the AKS `petclinic` namespace with
   `PGPASSWORD` from Key Vault as an env; `kubectl cp` the dump into `/tmp/petclinic.dump`.

5. **Drop + recreate** the target DB from the bootstrap DB (each statement as its own `-c`):
   ```
   pg-jump:/# psql "host=petclinic-xx-xxxx.postgres.database.azure.com port=5432 dbname=postgres user=pgadmin sslmode=require" \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='petclinic' AND pid <> pg_backend_pid();" \
    -c "DROP DATABASE petclinic;" \
    -c "CREATE DATABASE petclinic;"
    Password for user pgadmin:
    pg_terminate_backend
    ----------------------
    t
    t
    t
    t
    t
    t
    t
    t
    t
    (9 rows)

    DROP DATABASE
    CREATE DATABASE
   ```
6. **Restore**:
   ```
   pg-jump:/# pg_restore -h petclinic-pg-gqweq.postgres.database.azure.com -U pgadmin -d petclinic \
    --no-owner --no-acl /tmp/petclinic.dump
    Password:
    Command was: SET transaction_timeout = 0;
    pg_restore: warning: errors ignored on restore: 1
    pg-jump:/# psql "host=petclinic-pg-gqweq.postgres.database.azure.com port=5432 dbname=petclinic user=pgadmin sslmode=require" \
      -c "SELECT (SELECT count(*) FROM owners) owners, (SELECT count(*) FROM pets) pets, (SELECT count(*) FROM visits) visits;"
    Password for user pgadmin:
    owners | pets | visits
    --------+------+--------
        11 |   14 |      4
    (1 row)
   ```
7. **Verify** on AKS - row counts now match the source (see step 6 output) and the new owner
   row is present:
   ```
   petclinic=> SELECT id, first_name, last_name FROM owners WHERE last_name='Demo';
    id | first_name | last_name
   ----+------------+-----------
    11 | Migration  | Demo
   ```
8. **Bring AKS app back**: `kubectl scale deploy petclinic --replicas=1`; refresh
   `http://petclinic.southeastasia.cloudapp.azure.com/owners/find` and search `Demo` - the
   migrated owner and pet appear, served from Azure DB for PostgreSQL.

