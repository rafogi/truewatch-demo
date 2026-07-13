#!/usr/bin/env bash
# One-time setup for Terraform's remote state backend.
#
# Terraform can't create the storage account it stores its own state in
# (chicken-and-egg problem), so this is a plain az CLI script you run ONCE,
# by hand, before the first `terraform init`. It is NOT run by CI.
#
# Names here must match terraform/providers.tf's backend "azurerm" block
# exactly, or `terraform init` will fail to find the backend.
set -euo pipefail

RESOURCE_GROUP="rg-tfstate-todo-demo"
LOCATION="eastus"
STORAGE_ACCOUNT="sttfstatetododemo" # must be globally unique across Azure
CONTAINER_NAME="tfstate"

echo "Creating resource group for Terraform state: $RESOURCE_GROUP"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

echo "Creating storage account: $STORAGE_ACCOUNT"
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --encryption-services blob \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

echo "Creating blob container: $CONTAINER_NAME"
# --auth-mode login uses your own az credentials (no storage key needed),
# consistent with avoiding long-lived secrets wherever possible.
az storage container create \
  --name "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login

echo "Done. Backend ready:"
echo "  resource_group_name  = $RESOURCE_GROUP"
echo "  storage_account_name = $STORAGE_ACCOUNT"
echo "  container_name       = $CONTAINER_NAME"
echo "Confirm these match terraform/providers.tf's backend block, then run terraform init."
