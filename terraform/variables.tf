variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Short environment tag used in resource names (e.g. demo)."
  type        = string
  default     = "demo"
}

variable "aks_node_count" {
  description = "Number of nodes in the default AKS node pool."
  type        = number
  default     = 1
}

variable "aks_vm_size" {
  description = "VM size for the default AKS node pool. This subscription's quota disallows burstable B-series entirely (only D/E/F/M/N-series are permitted), so Standard_D2s_v7 (2 vCPU/8GiB) is the smallest allowed general-purpose size."
  type        = string
  default     = "Standard_D2s_v7"
}
