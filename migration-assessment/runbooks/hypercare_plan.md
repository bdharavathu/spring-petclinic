# Hypercare plan

Heightened monitoring and on-call right after cutover, until the workload is proven stable on AKS.

## Window

- 2 weeks post-cutover (1 week minimum). On-prem stays warm for the first week for fast fallback.

## Monitoring

- Azure Monitor / Container Insights: pod health, restarts, node and cluster autoscaler events.
- Prometheus + Grafana: request rate, p95 latency, 5xx, JVM heap/GC, DB connection pool.
- Azure DB for PostgreSQL metrics: connections, CPU, storage, slow queries.
- Tetragon: process exec and outbound connections in the petclinic namespace (escalation rules in
  [`../tetragon/README.md`](../tetragon/README.md)).

## SLOs and alerts

- Availability: 99.9% on `/actuator/health`.
- Latency: p95 < 500ms for read paths.
- Errors: 5xx < 1% over 5 min.

Page on: SLO breach, crashloop, DB connection saturation, unexpected shell exec or egress
(Tetragon), Cilium policy drops to an expected destination.

## Incident triage

1. Check the Grafana dashboard and recent deploy/scale events.
2. Pull pod logs and the Tetragon event timeline for the affected pod.
3. If release-related, roll back per [`rollback_plan.md`](./rollback_plan.md).
4. If infra-related (DB, networking), engage the platform team; use the runbook mapping to locate
   the component.

## Ownership

| Area | Owner |
|---|---|
| App (PetClinic) | application team |
| Cluster, node pools, networking, add-ons | platform team |
| Managed PostgreSQL | platform / DBA |
| Incident command during hypercare | migration lead |

## Exit criteria

- No Sev1/Sev2 incidents for 7 consecutive days.
- SLOs met across the window.
- On-prem decommissioned and DNS fully cut to AKS.
