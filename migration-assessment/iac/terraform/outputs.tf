output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "oidc_issuer_url" {
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
  description = "Federate workload-identity service accounts against this issuer"
}

output "nat_gateway_public_ip" {
  value       = azurerm_public_ip.nat.ip_address
  description = "Stable cluster egress IP (partner allowlists key on this)"
}

output "kubelet_identity_object_id" {
  value = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

# Stage 2 - wire these into the SecretProviderClass and the Helm DB host.
output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "app_identity_client_id" {
  value       = azurerm_user_assigned_identity.petclinic.client_id
  description = "clientID for the SecretProviderClass / pod workload-identity annotation"
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "github_client_id" {
  value       = try(azurerm_user_assigned_identity.github[0].client_id, "")
  description = "AZURE_CLIENT_ID for the GitHub Actions OIDC login"
}
