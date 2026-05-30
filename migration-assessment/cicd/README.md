# CI/CD pipeline (Module 8)

Three GitHub Actions workflows plus a manual rollback, split by concern and chained via
`workflow_run`:

- **`migration-ci.yml`** - build -> Trivy scan gate -> push image. Runs on every push to `main`.
- **`aks-deploy.yml`** - OIDC login to Azure -> deploy Tetragon + the app to AKS via Helm,
  behind the `production` approval gate. Fires after `migration-ci` or `terraform` succeeds.
- **`terraform.yml`** - infra in CI. Auto-plans on any push to `iac/terraform/**`; apply is
  dispatch-only behind the `production` gate. Remote `azurerm` state, OIDC, no stored creds.
- **`migration-rollback.yml`** - manual `helm rollback` to a previous revision (also OIDC).

GitHub only runs workflows from `.github/workflows/`, so those are the live files.
[`github-actions-aks.yml`](./github-actions-aks.yml) here is a copy of `aks-deploy.yml`, kept
under the required `/cicd` path for the submission structure.

## Authentication: OIDC, no stored kubeconfig

The deploy/rollback jobs authenticate with **workload-identity federation** (`azure/login@v2`
with `id-token: write`). A user-assigned identity (`petclinic-github-ci`, created by Terraform
when `github_repo` is set) trusts the subject
`repo:<owner>/<repo>:environment:production` and holds the *Azure Kubernetes Service Cluster
User Role*. No kubeconfig, client secret, or PAT is stored in the repo - the runner exchanges its
short-lived OIDC token for an Azure token at job time.

## No hardcoded endpoints

Every endpoint/ID the deploy uses is a GitHub **environment variable** sourced from Terraform
outputs - Terraform is the single source of truth:

| Variable | Terraform output |
|---|---|
| `AZURE_CLIENT_ID` | `github_client_id` |
| `AZURE_TENANT_ID` | `tenant_id` |
| `AKS_RESOURCE_GROUP` / `AKS_NAME` | `resource_group` / `aks_name` |
| `ACR_LOGIN_SERVER` | `acr_login_server` |
| `PG_HOST` | `postgres_fqdn` |
| `APP_IDENTITY_CLIENT_ID` | `app_identity_client_id` |
| `KEY_VAULT_NAME` | `key_vault_name` |

(`AZURE_SUBSCRIPTION_ID`, `IMAGE_TAG`, `INGRESS_HOST` are set the same way.)

## Stages (`migration-ci.yml`)

1. build - `docker buildx build` of the multi-stage Dockerfile.
2. scan (gate) - Trivy fails the build on fixable HIGH/CRITICAL; triaged base-OS CVEs are
   allowlisted in `../docker/.trivyignore`, application-dependency CVEs are not.
3. push - tag and push to GHCR (`ghcr.io/$owner_account/petclinic:<sha>` and `:latest`) using the
   built-in `GITHUB_TOKEN`.

AKS pulls from **ACR** (kubelet AcrPull). On the trial subscription used here, ACR Tasks/cloud
build is disabled, so the ACR image was produced with local `buildx` during bootstrap; on a
standard subscription the build job pushes straight to ACR via the same OIDC identity + AcrPush.

## Approval gate

`production` environment (repo Settings -> Environments -> production) with a required reviewer.
The deploy/rollback jobs pause for manual approval before they run.

Note: GitHub doesn't allow environment protection rules on free private repos, so the gate is
unenforced on the dev repo we built in. It becomes active on the public fork at submission.

## Agent choice (tradeoff)

- GitHub-hosted (managed) runners for build/scan/push and - because this cluster keeps a public
  API server with authorized IP ranges - for the OIDC deploy too: zero maintenance, ephemeral.
- A self-hosted / VNet-joined runner becomes necessary only if the API server is made private
  (`private_cluster_enabled = true`), at the cost of patching and securing the runner.

## Rollback

`migration-rollback.yml` (manual `workflow_dispatch`, optional revision input) runs
`helm rollback petclinic <rev> -n petclinic` (blank = previous). Manual equivalent:
`kubectl -n petclinic rollout undo deploy/petclinic`.
