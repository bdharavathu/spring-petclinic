variable "subscription_id" {
  type        = string
  default     = null # null -> provider uses ARM_SUBSCRIPTION_ID; or set TF_VAR_subscription_id
  description = "Azure subscription ID"
}

variable "prefix" {
  type    = string
  default = "petclinic"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "private_cluster_enabled" {
  type        = bool
  default     = false # public API with authorized IP ranges in this design; flip to true for prod
  description = "Use a private API server endpoint"
}

variable "api_authorized_ip_ranges" {
  type    = list(string)
  default = [] # populate with admin/CI egress CIDRs when public
}

variable "system_node_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "user_node_size" {
  type    = string
  default = "Standard_D4s_v5"
}

# Node pool shape. Defaults are production; free-tier.tfvars overrides to a single small node.
variable "system_node_count" {
  type    = number
  default = 2
}

variable "system_autoscaling" {
  type    = bool
  default = true
}

variable "system_min_count" {
  type    = number
  default = 1
}

variable "system_max_count" {
  type    = number
  default = 3
}

variable "system_only_critical" {
  type    = bool
  default = true # taint the system pool so app workloads land on the user pool
}

variable "enable_user_pool" {
  type    = bool
  default = true
}

variable "zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "acr_sku" {
  type    = string
  default = "Premium"
}

variable "local_account_disabled" {
  type    = bool
  default = true # Entra-only in production; free-tier sets false for simple kubeconfig access
}

variable "pg_admin_login" {
  type    = string
  default = "pgadmin"
}

variable "pg_sku" {
  type    = string
  default = "B_Standard_B1ms" # free-tier burstable
}

variable "pg_version" {
  type    = string
  default = "16"
}

variable "github_repo" {
  type        = string
  default     = "" # "owner/repo"; when set, creates the GitHub Actions OIDC identity + AKS role
  description = "GitHub repo for Actions OIDC federation (pass via -var, not committed)"
}

variable "bootstrap_user_object_id" {
  type        = string
  default     = ""
  description = "Object ID of the human bootstrap user that needs Key Vault Secrets Officer (set once during local apply; pinning it stops the per-runner toggle that would otherwise destroy/recreate the role on every alternation between local and CI)"
}

variable "vnet_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "aks_subnet_cidr" {
  type    = string
  default = "10.1.0.0/20"
}

variable "pod_cidr" {
  type        = string
  default     = "10.244.0.0/16" # overlay pod CIDR (not consumed from the subnet)
  description = "Cilium overlay pod CIDR"
}

variable "service_cidr" {
  type    = string
  default = "10.2.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "10.2.0.10"
}

variable "tags" {
  type = map(string)
  default = {
    app        = "petclinic"
    managed-by = "terraform"
  }
}
