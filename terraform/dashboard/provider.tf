# Separate Terraform working directory from ../  on purpose: this manages
# TrueWatch SaaS dashboard config, not Azure infrastructure, so it uses a
# different provider entirely and doesn't need the Azure remote state
# backend. State stays local here since it's small, low-risk, and only
# describes a dashboard layout (easy to recreate from dashboard.json if lost).
terraform {
  required_version = ">= 1.0"

  required_providers {
    truewatch = {
      source = "TrueWatchTech/truewatch"
    }
  }
}

variable "truewatch_access_token" {
  description = "TrueWatch API key. Set via terraform.tfvars (gitignored), never committed."
  type        = string
  sensitive   = true
}

provider "truewatch" {
  access_token = var.truewatch_access_token
}
