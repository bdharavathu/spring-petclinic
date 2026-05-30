# Rollback plan

Rollback is fast because the on-prem stack stays warm through hypercare and DNS TTL is low.

## When to roll back

- Smoke or business validation fails after cutover.
- 5xx rate or p95 latency breaches SLO and isn't recovering.
- Data integrity problem against the managed database.

Decision owner: migration lead, on the cutover call.

## App tier

- Traffic: revert the DNS record to the on-prem VIP (TTL already 60s), or set the canary weight
  back to 0. This alone restores service if on-prem is still healthy.
- Release: `helm rollback petclinic <previous-revision> -n petclinic`, or
  `kubectl -n petclinic rollout undo deploy/petclinic`. The manual rollback workflow
  ([`../../.github/workflows/migration-rollback.yml`](../../.github/workflows/migration-rollback.yml))
  runs `helm rollback`.

## Database

- If cutover hasn't taken writes on AKS yet: revert traffic; on-prem PostgreSQL is still source
  of truth, no data action needed.
- If AKS has taken writes: do not silently fail back. Capture the delta from Azure PostgreSQL,
  reconcile into on-prem, then revert traffic. This is the highest-risk path - prefer a short
  read-only window during cutover so this case doesn't arise.

## After rollback

- Confirm on-prem smoke + business checks pass.
- Leave the AKS release in place (scaled down) for diagnosis.
- Record what triggered the rollback and the fix before re-attempting.
