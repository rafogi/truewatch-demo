# The azurerm backend stores Terraform state remotely (Azure Storage) so
# state isn't lost/local-only and CI can run plan/apply without needing a
# local state file. The storage account/container referenced here must
# already exist -- created once by scripts/bootstrap-state-backend.sh,
# since Terraform can't create the very backend it depends on to run.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
  }

  backend "azurerm" {
    # Fill these in (or pass via `-backend-config=` flags/partial config)
    # to match whatever bootstrap-state-backend.sh actually created.
    resource_group_name  = "rg-tfstate-todo-demo"
    storage_account_name = "sttfstatetododemo" # must be globally unique
    container_name       = "tfstate"
    key                  = "todo-demo.tfstate"
  }
}

provider "azurerm" {
  features {}

  # By default azurerm tries to auto-register every resource provider it
  # supports (dozens of Microsoft.* namespaces) on every plan/apply, even
  # ones this project never touches (Microsoft.Maps, Microsoft.SecurityInsights,
  # etc). That's slow and fails outright if any single one is unreachable or
  # blocked. We've already manually registered exactly the providers this
  # config needs (Compute, Network, Storage, ContainerService,
  # ContainerRegistry, Authorization, ManagedIdentity) via `az provider
  # register`, so we skip the provider's own auto-registration entirely.
  skip_provider_registration = true
}
