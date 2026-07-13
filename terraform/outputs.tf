output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "acr_login_server" {
  description = "Push/pull images here; GitHub Actions uses this to tag+push the app image."
  value       = azurerm_container_registry.main.login_server
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "get_credentials_command" {
  description = "Run this locally to configure kubectl against the new cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}
