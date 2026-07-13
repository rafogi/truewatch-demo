# Resource group that owns every resource this demo creates, so the whole
# thing can be torn down with a single `terraform destroy` (or, in a pinch,
# `az group delete`).
resource "azurerm_resource_group" "main" {
  name     = "rg-todo-${var.environment}"
  location = var.location
}

# Azure Container Registry: holds the todo-app image GitHub Actions builds.
# SKU "Basic" is the cheapest tier -- fine for a single low-traffic demo image.
resource "azurerm_container_registry" "main" {
  # Must be globally unique across all of Azure and alphanumeric only.
  name                = "acrtodo${var.environment}${substr(md5(azurerm_resource_group.main.id), 0, 6)}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false # access is via managed identity / OIDC, not admin creds
}

# The AKS cluster itself. One system-mode node pool running both system and
# app workloads -- a production cluster would split these, but that doubles
# node cost for no benefit in a demo.
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-todo-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = "aks-todo-${var.environment}"

  # Azure enables this by default on new clusters and (as of this API
  # version) refuses to disable it once set -- declared explicitly so
  # Terraform's plan matches reality instead of endlessly trying to unset it.
  oidc_issuer_enabled = true

  default_node_pool {
    name       = "system"
    node_count = var.aks_node_count
    vm_size    = var.aks_vm_size

    # Matches the defaults Azure applies to a new node pool automatically --
    # declared explicitly for the same reason as oidc_issuer_enabled above:
    # avoids Terraform repeatedly trying to unset provider-side defaults.
    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }
  }

  # System-assigned managed identity -- AKS manages its own credentials
  # rather than us provisioning/rotating a service principal by hand.
  identity {
    type = "SystemAssigned"
  }
}

# Grants the AKS cluster's kubelet identity permission to pull images from
# ACR without needing imagePullSecrets or admin credentials in the cluster.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
