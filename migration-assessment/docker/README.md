# Image build & hardening (Module 2)

Multi-stage build for the PetClinic monolith. Build with the repo root as context:

```bash
docker build -f migration-assessment/docker/Dockerfile -t petclinic:onprem .
# multi-arch for ACR (AKS nodes are amd64; local is arm64):
docker buildx build --platform linux/amd64,linux/arm64 \
  -f migration-assessment/docker/Dockerfile -t <acr>.azurecr.io/petclinic:<tag> --push .
```

## Dependencies

| | |
|---|---|
| Build-time | JDK 21 (`eclipse-temurin:21-jdk`), Maven via the repo's `./mvnw` wrapper, deps from `pom.xml` |
| Runtime | JRE 21 only, shipped inside `gcr.io/distroless/java21-debian12`, plus the application fat jar |
| Config | `SPRING_PROFILES_ACTIVE`, `POSTGRES_URL/USER/PASS` via env / ConfigMap / Secret - nothing hardcoded |
| Health | Spring Boot Actuator (`/actuator/health/{liveness,readiness}`), used by the Kubernetes probes |

## Base image decision

Runtime is **distroless nonroot** (`gcr.io/distroless/java21-debian12:nonroot`, uid 65532):

- No shell, no package manager, minimal userland -> smaller attack surface and nothing to exec if a process is compromised.
- Runs as nonroot by default, so the workload satisfies Pod Security `restricted`.
- Multi-arch (arm64 + amd64), matching local-dev and AKS node architectures.

Trade-off: no shell means no in-container `HEALTHCHECK`/debugging - acceptable because health is enforced by Kubernetes probes and we debug via ephemeral containers (`kubectl debug`).

## Scanning & remediation (Trivy)

The image is scanned with Trivy in CI. Moving the runtime from a full JRE base to distroless
removed the bundled `pebble` Go binary and the shell/package manager, shrinking the OS attack
surface. Severity summary (before/after, counts only): [`trivy-summary.txt`](./trivy-summary.txt).

Remediation policy:
- Application-dependency findings are the actionable risk and are remediated by upgrading
  the Spring Boot parent and the PostgreSQL JDBC driver in `pom.xml`, then rebuilding.
- Base-OS findings are predominantly upstream "won't-fix" / no-fix items; these are reviewed
  and allowlisted in [`.trivyignore`](./.trivyignore), and clear on routine base-image refreshes.
- CI gate: the pipeline fails the build on *fixable* HIGH/CRITICAL findings and ignores only
  the documented allowlisted CVEs (see [`../cicd/`](../cicd)).
