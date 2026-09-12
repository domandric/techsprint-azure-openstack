variable "location" {
  description = "Azure location. Must match the shared root's own resolved location for this deployment (scripts/Resolve-AzureDeploymentProfile.ps1); westeurope remains only the historical literal default for advanced/manual tfvars."
  type        = string
  default     = "swedencentral"
}

variable "location_short_name" {
  description = "Optional explicit short location suffix override. Left null, infra/azure/modules/naming auto-derives it from `location` (westeurope=>weu, swedencentral=>swc). Must match the shared root's own resolved value."
  type        = string
  default     = null
}

variable "vm_sku" {
  description = "Resolved, subscription-available, quota-checked VM SKU applied to both app hosts (scripts/Resolve-AzureDeploymentProfile.ps1). Must match the shared root's own resolved value; see infra/azure/modules/compute's approved_vm_skus for the enforced allow-list (Standard_B2s preferred; Standard_B2als_v2 and Standard_D2als_v6 quota-aware fallbacks)."
  type        = string
  default     = "Standard_B2s"
}

variable "name_seed" {
  type = string
}

variable "developer" {
  description = "One developer copied explicitly from the local shared input."
  type = object({
    slug         = string
    rola         = string
    network_slot = number
  })
}

variable "known_developers" {
  description = "Complete developer set used to generate deterministic foreign-spoke blackhole routes."
  type = map(object({
    slug         = string
    network_slot = number
  }))
}

variable "shared" {
  description = "Non-secret shared-root hand-off copied explicitly from shared Terraform outputs."
  type = object({
    hub_vnet_id               = string
    private_dns_zone_ids      = map(string)
    developer_group_id        = string
    lead_group_id             = string
    custom_role_definition_id = string
    jump_public_ip            = string
    admin_username            = string
    mysql = object({
      fqdn                   = string
      version                = string
      sku_name               = string
      sku_tier               = string
      high_availability_mode = string
      administrator_login    = string
      database_names         = map(string)
    })
  })
}

variable "developer_ssh_public_key" {
  description = "Resolved public key for this developer. It is public material included in the non-secret tenant hand-off and generated inventory."
  type        = string
}

variable "lead_ssh_public_key" {
  description = "Resolved public key for the sole DevOps Lead. It is public material and never output."
  type        = string
}

variable "rocky_image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
}

variable "moodle_database_password" {
  type        = string
  sensitive   = true
  description = "Sensitive runtime input; do not place it in tfvars committed to Git."
}
