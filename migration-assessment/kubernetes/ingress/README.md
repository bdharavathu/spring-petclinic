# Ingress: NGINX (live) + HAProxy (alternative) - Module 4

The on-prem and AKS path uses **ingress-nginx**. The PetClinic Ingress is templated in the
Helm chart ([`../../helm/petclinic/templates/ingress.yaml`](../../helm/petclinic/templates/ingress.yaml))
and enabled per overlay. A **HAProxy** alternative ([`haproxy-ingress.yaml`](./haproxy-ingress.yaml))
is provided for comparison and as a migration option.

## Route

    DNS petclinic.local -> k3d loadbalancer :8081/:8443 -> ingress-nginx controller
      -> (Host: petclinic.local, TLS petclinic-tls) -> Service petclinic:80 -> pods :8080

On AKS the k3d loadbalancer is replaced by an Azure Load Balancer / public IP in front of the
ingress controller; DNS points at that IP and TLS is issued by cert-manager.

## NGINX vs HAProxy - when to use each

| Dimension | ingress-nginx | HAProxy ingress |
|---|---|---|
| Core | NGINX + Lua | HAProxy engine |
| Config model | annotations + `ConfigMap`, `nginx.conf` snippets | `haproxy.org/*` annotations, native ACLs |
| L7 routing | mature host/path, rewrites, canary by header/weight | strong host/path, ACL-based routing |
| Load balancing | round-robin, ewma | roundrobin, **leastconn**, source, uri |
| Health checks | passive (+ active via snippets) | native **active** backend checks |
| TLS | termination, passthrough, mTLS | termination, passthrough, mTLS |
| Throughput/latency | very good | excellent at high connection counts / TCP |
| AKS fit | managed app-routing addon ships ingress-nginx | self-managed (Helm) |

**Use ingress-nginx** as the default - it's the AKS application-routing addon, has the widest
ecosystem, and covers PetClinic's host/path + TLS needs. **Use HAProxy** when you need
strong active health checking, leastconn/connection-heavy or TCP/L4 edge load balancing,
or you already run HAProxy at the edge on-prem and want parity during migration.

## Cutover design (on-prem ingress -> AKS ingress)

1. Pre-cutover: AKS ingress-nginx up with a public IP; issue/import the TLS cert (cert-manager
   `letsencrypt-prod` or import the existing cert into a `petclinic-tls` secret). Validate against
   the AKS IP using a `Host:` header override before touching DNS.
2. Lower DNS TTL on `petclinic.example.com` to 60s ~24h ahead so rollback is fast.
3. Traffic switch - choose one:
   - Blue/green (DNS): flip the A/AAAA record from the on-prem VIP to the AKS public IP. Simple, atomic, rollback = flip back.
   - Canary (weighted): ingress-nginx `canary` annotations or weighted DNS to send 5->25->100% to AKS while watching error rate/latency.
4. Validation: `curl` 200 on `/` and `/actuator/health`, valid TLS chain, DB-backed page
   (`/vets.html`) renders, p95 latency and 5xx within SLO.
5. Rollback: revert the DNS record (TTL already low) or the canary weight to 0; on-prem stays
   warm through hypercare.
6. Decommission on-prem ingress only after the hypercare window passes clean.
