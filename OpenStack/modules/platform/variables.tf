variable "region" {
  description = "OpenStack region."
  type        = string
  default     = "regionOne"

  validation {
    condition     = var.region == "regionOne"
    error_message = "region must be exactly \"regionOne\"."
  }
}

variable "name_seed" {
  description = "Deployment-wide resource name seed."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{3,31}$", var.name_seed))
    error_message = "name_seed must start with a lowercase ASCII letter and contain 4-32 lowercase letters, digits, or hyphens."
  }
}

variable "shared_project_id" {
  description = "Keystone project ID in which this foundation is created."
  type        = string

  validation {
    condition     = trimspace(var.shared_project_id) != ""
    error_message = "shared_project_id must not be empty."
  }
}

variable "project_ids" {
  description = "Shared and developer project IDs rendered into the lead's operator inventory."
  type        = list(string)

  validation {
    condition     = length(var.project_ids) >= 3 && length(distinct(var.project_ids)) == length(var.project_ids) && alltrue([for id in var.project_ids : trimspace(id) != ""])
    error_message = "project_ids must contain unique, non-empty shared and developer project IDs."
  }
}

variable "admin_cidr" {
  description = "Fixed shared administration subnet CIDR."
  type        = string
  default     = "10.200.0.0/24"

  validation {
    condition     = var.admin_cidr == "10.200.0.0/24"
    error_message = "admin_cidr is fixed at 10.200.0.0/24."
  }
}

variable "external_network_name" {
  description = "Existing external/provider network name."
  type        = string

  validation {
    condition     = trimspace(var.external_network_name) != ""
    error_message = "external_network_name must not be empty."
  }
}

variable "image_id" {
  description = "Glance image ID for Jump and Lead."
  type        = string

  validation {
    condition     = trimspace(var.image_id) != ""
    error_message = "image_id must not be empty."
  }
}

variable "flavor_id" {
  description = "Nova flavor ID for Jump and Lead."
  type        = string

  validation {
    condition     = trimspace(var.flavor_id) != ""
    error_message = "flavor_id must not be empty."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDR permitted to reach Jump over SSH."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "allowed_ssh_cidr must be a valid IPv4 CIDR."
  }
}

variable "templates_dir" {
  description = "Directory containing jump.yaml.tftpl and lead.yaml.tftpl."
  type        = string

  validation {
    condition     = trimspace(var.templates_dir) != ""
    error_message = "templates_dir must not be empty."
  }
}

variable "lead_slug" {
  description = "CSV-normalized devops lead slug."
  type        = string

  validation {
    condition     = var.lead_slug != "default" && can(regex("^[a-z][a-z0-9-]{0,31}$", var.lead_slug))
    error_message = "lead_slug must be a lowercase deterministic slug other than \"default\"."
  }
}

variable "lead_ssh_public_key" {
  description = "OpenSSH public key for Jump and Lead."
  type        = string
  sensitive   = true

  validation {
    condition = can(regex(
      "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+/]{4}([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?( [A-Za-z0-9._@%+=:,/-]+)*$",
      var.lead_ssh_public_key,
    )) && !can(regex("[\\r\\n]", var.lead_ssh_public_key))
    error_message = "lead_ssh_public_key must be exactly one newline-free OpenSSH public-key line with a supported algorithm, valid base64 blob, and optional safe comment."
  }
}

variable "developer_ssh_public_keys" {
  description = "OpenSSH public keys keyed by normalized developer slug for Jump login."
  type        = map(string)

  validation {
    condition = alltrue([
      for slug, public_key in var.developer_ssh_public_keys :
      can(regex("^[a-z][a-z0-9-]{0,31}$", slug)) &&
      can(regex(
        "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+/]{4}([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?( [A-Za-z0-9._@%+=:,/-]+)*$",
        public_key,
      )) && !can(regex("[\\r\\n]", public_key))
    ])
    error_message = "developer_ssh_public_keys must map lowercase developer slugs to newline-free OpenSSH public-key lines."
  }
}

variable "lead_ssh_private_key" {
  description = "Private key installed on Lead for operator use."
  type        = string
  sensitive   = true

  validation {
    condition     = trimspace(var.lead_ssh_private_key) != ""
    error_message = "lead_ssh_private_key must not be empty."
  }
}

variable "auth_url" {
  description = "Keystone authentication URL rendered into the Lead OpenRC."
  type        = string

  validation {
    condition     = trimspace(var.auth_url) != "" && !can(regex("[[:cntrl:]'\"]", var.auth_url))
    error_message = "auth_url must not be empty or contain quotes/control characters."
  }
}

variable "domain_id" {
  description = "Keystone domain ID rendered into the Lead OpenRC."
  type        = string

  validation {
    condition     = trimspace(var.domain_id) != "" && !can(regex("[[:cntrl:]'\"]", var.domain_id))
    error_message = "domain_id must not be empty or contain quotes/control characters."
  }
}

variable "lead_username" {
  description = "Lead Keystone username."
  type        = string
}

variable "lead_password" {
  description = "Lead Keystone password."
  type        = string
  sensitive   = true
}
