# Managed PostgreSQL (the replatform target for the in-cluster StatefulSet).

resource "random_password" "pg" {
  length  = 24
  special = false
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "${var.prefix}-pg-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = var.pg_version
  administrator_login           = var.pg_admin_login
  administrator_password        = random_password.pg.result
  sku_name                      = var.pg_sku
  storage_mb                    = 32768
  public_network_access_enabled = true # demo reaches it over public + the Azure-services firewall rule
  tags                          = var.tags

  lifecycle {
    # Azure auto-assigns an availability zone at creation; don't fight it on later applies.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "petclinic" {
  name      = "petclinic"
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Allow connections from Azure services (the AKS nodes) - 0.0.0.0/0.0.0.0 is the Azure-internal rule.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Store the DB credentials in Key Vault so the app gets them via the Secret Store CSI driver.
# The RBAC-mode vault needs the principal that writes secrets to have a data-plane role first.
# Both the CI identity (steady state) and the bootstrap user (laptop applies) need it, but each
# as its own resource bound to a *stable* principal - using data.azurerm_client_config.current
# would flip the role assignment every time the runner changed (local <-> CI).
resource "azurerm_role_assignment" "tf_kv_officer_github" {
  count                = var.github_repo != "" ? 1 : 0
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.github[0].principal_id
}

resource "azurerm_role_assignment" "tf_kv_officer_user" {
  count                = var.bootstrap_user_object_id != "" ? 1 : 0
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.bootstrap_user_object_id
}

# State migration: the previous single tf_kv_officer carried the runner's object_id; rename
# it into the user-bound resource (matched when -var bootstrap_user_object_id=<your id>),
# so the apply is a state rename, not a destroy + recreate.
moved {
  from = azurerm_role_assignment.tf_kv_officer
  to   = azurerm_role_assignment.tf_kv_officer_user[0]
}

resource "time_sleep" "kv_rbac" {
  depends_on = [
    azurerm_role_assignment.tf_kv_officer_github,
    azurerm_role_assignment.tf_kv_officer_user,
  ]
  create_duration = "60s" # let the role assignment propagate before writing secrets
}

resource "azurerm_key_vault_secret" "pg_username" {
  name         = "petclinic-db-username"
  value        = var.pg_admin_login
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [time_sleep.kv_rbac]
}

resource "azurerm_key_vault_secret" "pg_password" {
  name         = "petclinic-db-password"
  value        = random_password.pg.result
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [time_sleep.kv_rbac]
}
