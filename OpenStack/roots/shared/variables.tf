variable "cloud" {
  description = "Optional clouds.yaml entry; otherwise the sourced admin OpenRC is used."
  type        = string
  default     = ""
}

variable "region" {
  description = "OpenStack region."
  type        = string
  default     = "regionOne"

  validation {
    condition     = var.region == "regionOne"
    error_message = "region must be exactly regionOne."
  }
}

variable "state_bucket" {
  description = "Deployment-level Swift container used as the Terraform S3 state bucket."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$", var.state_bucket))
    error_message = "state_bucket must be a valid non-empty Swift container name."
  }
}

variable "state_s3_endpoint" {
  description = "Swift S3 API endpoint generated or explicitly overridden by the state-backend helper."
  type        = string

  validation {
    condition     = can(regex("^https?://[^[:space:]'\"]+$", var.state_s3_endpoint))
    error_message = "state_s3_endpoint must be an HTTP(S) URL for Swift's S3 API."
  }
}

variable "state_region" {
  description = "S3 backend signing region label passed to Swift's S3 compatibility API; defaults to us-east-1."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = trimspace(var.state_region) != ""
    error_message = "state_region must not be empty."
  }
}

variable "state_use_path_style" {
  description = "Use path-style S3 addressing required by Swift compatibility deployments."
  type        = bool
  default     = true
}

variable "state_skip_credentials_validation" {
  description = "Skip AWS credential validation because the endpoint is Swift S3 compatibility."
  type        = bool
  default     = true
}

variable "state_skip_region_validation" {
  description = "Skip AWS region validation for the Swift S3 compatibility endpoint."
  type        = bool
  default     = true
}

variable "state_skip_requesting_account_id" {
  description = "Skip AWS account ID discovery, which is not provided by Swift S3 compatibility."
  type        = bool
  default     = true
}

variable "state_skip_metadata_api_check" {
  description = "Skip AWS EC2 metadata checks for the Swift S3 compatibility endpoint."
  type        = bool
  default     = true
}

variable "state_skip_s3_checksum" {
  description = "Skip AWS S3 checksum behavior not implemented consistently by Swift compatibility APIs."
  type        = bool
  default     = true
}

variable "auth_url" {
  description = "Keystone URL written to the Lead OpenRC."
  type        = string

  validation {
    condition     = trimspace(var.auth_url) != "" && !can(regex("[[:cntrl:]'\"]", var.auth_url))
    error_message = "auth_url must not be empty or contain quotes/control characters."
  }
}

variable "domain_id" {
  description = "Keystone domain ID written to the Lead OpenRC."
  type        = string

  validation {
    condition     = trimspace(var.domain_id) != "" && !can(regex("[[:cntrl:]'\"]", var.domain_id))
    error_message = "domain_id must not be empty or contain quotes/control characters."
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

variable "lead_ssh_public_key" {
  description = "OpenSSH public key installed on Jump and Lead."
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
  description = "Private SSH key installed on Lead."
  type        = string
  sensitive   = true

  validation {
    condition     = trimspace(var.lead_ssh_private_key) != ""
    error_message = "lead_ssh_private_key must not be empty."
  }
}

variable "templates_dir" {
  description = "Optional templates directory; defaults to templates/."
  type        = string
  default     = ""
}

variable "external_network_name" {
  description = "Existing external/provider network name."
  type        = string
  default     = "provider-datacentre"
}

variable "allowed_ssh_cidr" {
  description = "CIDR permitted to reach Jump over SSH."
  type        = string
  default     = "0.0.0.0/0"
}
