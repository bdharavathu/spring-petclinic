# Workload identity for the app: a user-assigned identity federated to the petclinic
# ServiceAccount, granted read access to the Key Vault secrets (used by the CSI driver).

resource "azurerm_user_assigned_identity" "petclinic" {
  name                = "${var.prefix}-app-identity"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "petclinic" {
  name                = "petclinic-fedcred"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.petclinic.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:petclinic:petclinic"
}

resource "azurerm_role_assignment" "app_kv_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.petclinic.principal_id
}

# GitHub Actions OIDC: an identity federated to the repo's production environment, so the CI
# deploy job authenticates with no stored credentials. Created only when github_repo is set.
resource "azurerm_user_assigned_identity" "github" {
  count               = var.github_repo != "" ? 1 : 0
  name                = "${var.prefix}-github-ci"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "github" {
  count               = var.github_repo != "" ? 1 : 0
  name                = "github-actions-production"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.github[0].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repo}:environment:production"
}

# Lets the CI identity pull cluster credentials (admin on this non-AAD cluster) to run helm/kubectl.
resource "azurerm_role_assignment" "github_aks" {
  count                = var.github_repo != "" ? 1 : 0
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.github[0].principal_id
}

# Lets the same identity run terraform from CI. Owner (not Contributor) because terraform
# manages role assignments, which need User Access Admin or Owner. Scope is the single
# petclinic-rg, so the blast radius is one RG; the OIDC fed cred still restricts which
# workflow (only environment:production of the named repo) can assume it.
resource "azurerm_role_assignment" "github_rg_owner" {
  count                = var.github_repo != "" ? 1 : 0
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Owner"
  principal_id         = azurerm_user_assigned_identity.github[0].principal_id
}
