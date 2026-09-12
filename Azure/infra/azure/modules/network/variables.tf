variable "mode" {
  description = "Network topology mode."
  type        = string

  validation {
    condition     = contains(["hub", "tenant"], var.mode)
    error_message = "mode must be hub or tenant."
  }
}

variable "name" {
  description = "Canonical VNet name."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "location_short_name" {
  description = "Resolved short location suffix (module.naming.location_short_name) used in every resource name created by this module."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2,6}$", var.location_short_name))
    error_message = "location_short_name must be a short (2-6 character) lower-case alphabetic suffix, for example weu or swc."
  }
}

variable "tags" {
  type = map(string)
}

variable "allowed_ssh_cidr" {
  description = "Jump-host SSH source CIDR; 0.0.0.0/0 supports CGNAT and is protected by key-only SSH plus Fail2ban."
  type        = string
  default     = null
}

variable "network_slot" {
  description = "Required only by tenant topology."
  type        = number
  default     = null
}

variable "hub_vnet_id" {
  description = "Required only by tenant topology for its single spoke-to-hub peering."
  type        = string
  default     = null
}

variable "tenant_networks" {
  description = "All tenant VNets known to the reconciliation phase, keyed by canonical slug."
  type = map(object({
    slug         = string
    network_slot = number
    vnet_id      = optional(string)
  }))
  default = {}
}

variable "tenant_slug" {
  description = "Required only by tenant topology."
  type        = string
  default     = null
}

variable "mysql_allowed_developers" {
  description = "Hub-mode only. Every validated developer known to the shared root (slug + immutable network_slot), used to derive exactly one shared-MySQL-subnet NSG allow rule per developer scoped to that developer's own /24 app subnet CIDR. Available at shared-foundation-apply time directly from var.users.developers (no tenant VNet has to exist yet), so this never creates a shared<->tenant root dependency cycle."
  type = map(object({
    slug         = string
    network_slot = number
  }))
  default = {}
}
