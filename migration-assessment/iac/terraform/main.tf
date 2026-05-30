data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.prefix}-law"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ---------- Network ----------
resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_subnet_cidr]
}

# ---------- Egress: NAT Gateway (stable outbound IP, no SNAT exhaustion) ----------
resource "azurerm_public_ip" "nat" {
  name                = "${var.prefix}-nat-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_nat_gateway" "main" {
  name                = "${var.prefix}-nat"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

# ---------- Registry ----------
resource "azurerm_container_registry" "main" {
  name                = "${var.prefix}acr${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.acr_sku
  admin_enabled       = false # use AcrPull via managed identity, not admin creds
  tags                = var.tags
}

# ---------- Key Vault (RBAC mode) ----------
resource "azurerm_key_vault" "main" {
  name                       = "${var.prefix}-kv-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  tags                       = var.tags
}

# ---------- AKS ----------
resource "azurerm_kubernetes_cluster" "main" {
  name                      = "${var.prefix}-aks"
  resource_group_name       = azurerm_resource_group.main.name
  location                  = azurerm_resource_group.main.location
  dns_prefix                = var.prefix
  kubernetes_version        = var.kubernetes_version
  automatic_upgrade_channel = "patch"

  private_cluster_enabled   = var.private_cluster_enabled
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  azure_policy_enabled      = true
  local_account_disabled    = var.local_account_disabled

  # Entra integration is required when local accounts are disabled (production path).
  dynamic "azure_active_directory_role_based_access_control" {
    for_each = var.local_account_disabled ? [1] : []
    content {
      azure_rbac_enabled = true
    }
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_size
    vnet_subnet_id               = azurerm_subnet.aks.id
    orchestrator_version         = var.kubernetes_version
    auto_scaling_enabled         = var.system_autoscaling
    node_count                   = var.system_autoscaling ? null : var.system_node_count
    min_count                    = var.system_autoscaling ? var.system_min_count : null
    max_count                    = var.system_autoscaling ? var.system_max_count : null
    zones                        = var.zones
    only_critical_addons_enabled = var.system_only_critical
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "userAssignedNATGateway"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.api_authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_authorized_ip_ranges
    }
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  }

  monitor_metrics {} # managed Prometheus

  web_app_routing {
    dns_zone_ids = [] # managed ingress-nginx (application routing add-on); no BYO DNS zone
  }

  tags = var.tags

  depends_on = [azurerm_subnet_nat_gateway_association.aks]
}

# BYO VNet: the cluster identity needs subnet join (for LoadBalancer services) on our VNet.
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.identity[0].principal_id
}

# ---------- User node pool ----------
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  count                 = var.enable_user_pool ? 1 : 0
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.user_node_size
  orchestrator_version  = var.kubernetes_version
  vnet_subnet_id        = azurerm_subnet.aks.id
  mode                  = "User"
  auto_scaling_enabled  = true
  min_count             = 1
  max_count             = 5
  zones                 = var.zones
  tags                  = var.tags
}

# ---------- Role assignments (no admin creds, no image pull secrets) ----------
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "kv_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
}
