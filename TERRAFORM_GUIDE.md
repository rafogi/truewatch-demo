# Terraform Guide

A walk-through of what each file/block in `terraform/` does and why, for
anyone (including future-you) learning Terraform through this project.

## File organization

Terraform doesn't care how you split `.tf` files — it reads every file in
the directory and merges them into one configuration. The split here is
by convention/readability:

- `providers.tf` — which providers we need and where state lives.
- `variables.tf` — inputs, with defaults, so `terraform.tfvars` can be
  small (or omitted entirely and defaults used).
- `main.tf` — the actual resources.
- `outputs.tf` — values printed after apply / readable via `terraform output`.

## `providers.tf`

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers { azurerm = { ... } }
  backend "azurerm" { ... }
}
```

- `required_providers` pins which provider (Azure, in our case) and version
  range Terraform should download. Pinning avoids a provider update
  silently changing behavior between runs.
- `backend "azurerm"` tells Terraform *where to store its state file* —
  the JSON record of what Terraform believes exists in the real world.
  Without a remote backend, state lives in a local `terraform.tfstate`
  file, which doesn't work for CI (each run would start from empty state)
  or collaboration (two people's local state files diverge). Storing it in
  Azure Blob Storage means every `terraform plan`/`apply`, whether run
  locally or in GitHub Actions, reads/writes the same source of truth, and
  Azure Blob's lease mechanism prevents two applies from running
  concurrently and corrupting state.
- **Why a separate bootstrap script instead of Terraform-managed backend
  storage?** Terraform needs a backend to store state *before* it can
  create anything — including the storage account meant to be that
  backend. `scripts/bootstrap-state-backend.sh` breaks that circular
  dependency by creating the storage account with plain `az` commands,
  one time, outside Terraform's management.

`provider "azurerm" { features {} }` — the empty `features` block is
required by the azurerm provider even with no customization; it's how the
provider expects certain default behaviors (e.g. auto-deleting resources
in a resource group on `terraform destroy`) to be configured.

## `variables.tf`

Each `variable` block declares an input with an optional type, default,
and description. Declaring `type = string` catches typos early (passing a
number where a string is expected fails at plan time, not apply time).
Defaults mean you can `terraform apply` with zero configuration and still
get sane values — useful for a demo where you don't want fifteen required
inputs.

## `main.tf`

- **`azurerm_resource_group`** — Azure's logical container for related
  resources. Everything below references `azurerm_resource_group.main.name`
  so the whole demo lives in one resource group and can be deleted in one
  shot.
- **`azurerm_container_registry`** — the private Docker registry
  (`Basic` SKU = cheapest tier, fine for one low-traffic image). The name
  includes an `md5` hash suffix of the resource group ID purely to satisfy
  ACR's *globally unique across all of Azure* naming requirement without
  you having to hand-pick a unique string.
- **`azurerm_kubernetes_cluster`** — the AKS cluster itself.
  - `default_node_pool` — every AKS cluster needs at least one node pool;
    this is it, sized small (`Standard_D2s_v7`, 1 node) to keep cost down --
    the smallest VM size this subscription's quota permits (B-series
    burstable is disallowed entirely here).
  - `identity { type = "SystemAssigned" }` — instead of us creating and
    rotating a service principal for AKS to use, Azure creates and manages
    an identity tied to the cluster's lifecycle automatically.
- **`azurerm_role_assignment.aks_acr_pull`** — this is the piece that lets
  AKS actually pull images from ACR without imagePullSecrets. AKS's
  *kubelet identity* (a separate managed identity from the cluster's
  control-plane identity, used specifically for node-level operations like
  image pulls) is granted the built-in `AcrPull` role, scoped to just this
  one registry.

## `outputs.tf`

Outputs surface values Terraform computed (like ACR's auto-generated
login server hostname) so scripts, CI, and humans don't have to
re-derive them via separate `az` calls. `terraform output -raw
acr_login_server` is used directly in RUNBOOK.md and in GitHub Actions
variable setup.

## Common commands

```bash
terraform fmt -recursive     # auto-format all .tf files
terraform validate            # catch syntax/type errors without touching Azure
terraform plan                 # show what would change, without changing anything
terraform apply                 # actually create/update/destroy resources
terraform destroy                # tear down everything Terraform manages here
terraform output                  # print the outputs.tf values from current state
```
