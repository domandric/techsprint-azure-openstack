variable "scope" {
  description = "Resource scope: state, shared, or developer."
  type        = string

  validation {
    condition     = contains(["state", "shared", "developer"], var.scope)
    error_message = "scope must be state, shared, or developer."
  }
}

variable "owner" {
  description = "Canonical owner tag value; a developer slug for developer scope, otherwise shared."
  type        = string
}

variable "slug" {
  description = "Developer slug. It is required for developer resource names."
  type        = string
  default     = null

  validation {
    condition     = var.slug == null || can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", var.slug))
    error_message = "slug must be a canonical lower-case ASCII slug."
  }
}

variable "network_slot" {
  description = "Stable developer network slot (0 through 63)."
  type        = number
  default     = null

  validation {
    condition     = var.network_slot == null || (var.network_slot >= 0 && var.network_slot <= 63 && floor(var.network_slot) == var.network_slot)
    error_message = "network_slot must be an integer from 0 through 63."
  }
}

variable "name_seed" {
  description = "Non-secret stable naming seed."
  type        = string

  validation {
    condition     = length(trimspace(var.name_seed)) >= 8
    error_message = "name_seed must be a non-secret stable string with at least eight characters."
  }
}

variable "location" {
  description = "Azure location. West Europe is the historical default, but this project's normal auto mode (scripts/Resolve-AzureDeploymentProfile.ps1) resolves whichever region actually accepts new resources for the active subscription (for example Sweden Central, when a management-group policy blocks West Europe) -- see docs/architecture/README.md."
  type        = string
  default     = "westeurope"
}

variable "location_short_name" {
  description = "Short location suffix used in every resource name. Optional: when omitted (null), it is auto-derived from `location` via this module's own known-region map (currently westeurope=>weu, swedencentral=>swc). Supply it explicitly only to add support for a region not yet in that map, or to pin a specific short name."
  type        = string
  default     = null

  validation {
    condition     = var.location_short_name == null || can(regex("^[a-z]{2,6}$", var.location_short_name))
    error_message = "location_short_name must be a short (2-6 character) lower-case alphabetic suffix, for example weu or swc."
  }
}
