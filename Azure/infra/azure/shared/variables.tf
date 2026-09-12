variable "subscription_id" {
  description = "Target TechSprint testing subscription UUID. This is an identifier, not a secret."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "location" {
  description = "Azure location. Normally resolved automatically by scripts/Resolve-AzureDeploymentProfile.ps1 for the active subscription (for example Sweden Central, when a management-group policy blocks West Europe); westeurope remains only the historical literal default for advanced/manual tfvars."
  type        = string
  default     = "swedencentral"
}

variable "location_short_name" {
  description = "Optional explicit short location suffix override. Left null, infra/azure/modules/naming auto-derives it from `location` (westeurope=>weu, swedencentral=>swc)."
  type        = string
  default     = null
}

variable "vm_sku" {
  description = "Resolved, subscription-available, quota-checked VM SKU applied consistently to Jump, Lead, and both app hosts (scripts/Resolve-AzureDeploymentProfile.ps1). Standard_B2s is preferred where available; Standard_B2als_v2 and Standard_D2als_v6 are assignment-compliant fallbacks selected when a higher-preference SKU is NotAvailableForSubscription or its own SKU-family/regional vCPU quota cannot fit this project's 6-VM/12-vCPU fleet. See infra/azure/modules/compute's approved_vm_skus for the enforced allow-list."
  type        = string
  default     = "Standard_B2s"
}

variable "name_seed" {
  type = string
}

variable "allowed_ssh_cidr" {
  description = "Jump SSH source CIDR. Defaults to all IPv4 for CGNAT/dynamic-address users; narrow it when a stable source CIDR exists. Fail2ban and key-only SSH protect the public Jump service."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "allowed_ssh_cidr must be a valid IPv4 CIDR."
  }
}

variable "users" {
  description = "Lead and developer details supplied explicitly in local shared tfvars."
  type = object({
    lead = object({
      slug = string
      rola = string
      upn  = string
    })
    developers = list(object({
      slug         = string
      rola         = string
      upn          = string
      network_slot = number
    }))
  })
}

variable "lead_ssh_public_key" {
  description = "Lead public SSH key supplied in protected local tfvars. It is never output."
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

variable "entra_mode" {
  type    = string
  default = "existing"
}

variable "entra_initial_passwords" {
  description = "Create-mode only; sensitive and never output. Existing mode is the recommended default."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "tenant_networks" {
  description = "Reconciliation input after tenant roots are created. Empty for the initial hub deployment."
  type = map(object({
    slug         = string
    network_slot = number
    vnet_id      = string
  }))
  default = {}
}

variable "tenant_backends" {
  description = "Reconciliation input after tenant roots are created. Empty for the initial hub deployment."
  type = map(object({
    slug             = string
    network_slot     = number
    app01_private_ip = string
    app02_private_ip = string
  }))
  default = {}
}

variable "app_gateway_enabled" {
  description = "False for initial shared foundation; true only in the post-tenant shared reconciliation phase."
  type        = bool
  default     = false
}

variable "mysql_administrator_password" {
  description = "Sensitive shared MySQL administrator password supplied only through the runtime TF_VAR_mysql_administrator_password secret channel. Exactly one CSPRNG secret for the whole shared, Zone-Redundant MySQL Flexible Server (see infra/azure/modules/paas); it is reused (never rotated) across shared applies and is never duplicated into any tenant Terraform state."
  type        = string
  sensitive   = true
}
