variable "name_seed" {
  description = "Deployment-wide resource name seed."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{3,31}$", var.name_seed))
    error_message = "name_seed must start with a lowercase ASCII letter and contain 4-32 lowercase letters, digits, or hyphens."
  }
}

variable "shared_project_id" {
  description = "Shared project ID owning the administration router."
  type        = string

  validation {
    condition     = trimspace(var.shared_project_id) != ""
    error_message = "shared_project_id must not be empty."
  }
}

variable "jump_server_id" {
  description = "Existing shared-project Jump server ID receiving direct management interfaces."
  type        = string

  validation {
    condition     = trimspace(var.jump_server_id) != ""
    error_message = "jump_server_id must not be empty."
  }
}

variable "jump_security_group_id" {
  description = "Shared-project Jump security group applied to direct management ports."
  type        = string

  validation {
    condition     = trimspace(var.jump_security_group_id) != ""
    error_message = "jump_security_group_id must not be empty."
  }
}

variable "tenants" {
  description = "Developer workspace identity and network data consumed by reconciliation."
  type = map(object({
    project_id     = string
    network_id     = string
    subnet_id      = string
    tenant_cidr    = string
    developer_slug = string
    name_seed      = string
  }))

  validation {
    condition     = length(var.tenants) >= 2
    error_message = "At least two developer tenants are required."
  }

  validation {
    condition     = alltrue([for slug in keys(var.tenants) : slug != "default" && can(regex("^[a-z][a-z0-9-]{0,31}$", slug))])
    error_message = "tenant keys must be lowercase deterministic slugs other than \"default\"."
  }

  validation {
    condition = alltrue([
      for tenant in values(var.tenants) :
      trimspace(tenant.project_id) != "" &&
      trimspace(tenant.network_id) != "" &&
      trimspace(tenant.subnet_id) != "" &&
      can(cidrnetmask(tenant.tenant_cidr)) &&
      trimspace(tenant.developer_slug) != ""
    ])
    error_message = "Every tenant must provide non-empty IDs and a valid IPv4 tenant CIDR."
  }

  validation {
    condition = alltrue([
      for tenant in values(var.tenants) :
      tenant.developer_slug != "default" && can(regex("^[a-z][a-z0-9-]{0,31}$", tenant.developer_slug)) && trimspace(tenant.name_seed) != ""
    ])
    error_message = "Every tenant must include a lowercase developer_slug other than \"default\" and non-empty name_seed from its developer state."
  }

  validation {
    condition     = length(distinct([for tenant in values(var.tenants) : tenant.project_id])) == length(var.tenants) && length(distinct([for tenant in values(var.tenants) : tenant.network_id])) == length(var.tenants) && length(distinct([for tenant in values(var.tenants) : tenant.tenant_cidr])) == length(var.tenants)
    error_message = "Tenant project, network, and CIDR values must be unique."
  }

}
