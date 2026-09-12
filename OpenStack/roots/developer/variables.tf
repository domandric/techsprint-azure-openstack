variable "cloud" {
  description = "Optional clouds.yaml entry used for OpenStack authentication."
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

variable "developer" {
  description = "The one CSV-derived developer record represented by this workspace."
  type = object({
    slug = string
  })

  validation {
    condition     = var.developer.slug != "default" && can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", var.developer.slug))
    error_message = "developer.slug must be a lowercase deterministic slug other than \"default\"."
  }

}

variable "image_id" {
  description = "Rocky image ID used to boot the developer VMs directly."
  type        = string

  validation {
    condition     = trimspace(var.image_id) != ""
    error_message = "image_id must not be empty."
  }
}

variable "app_flavor_id" {
  description = "Optional application flavor ID; empty default selects flavor_ids.shared."
  type        = string
  default     = ""
}

variable "db_flavor_id" {
  description = "Optional database flavor ID; empty default selects flavor_ids.shared."
  type        = string
  default     = ""
}

variable "volume_type" {
  description = "Cinder type for all three developer data volumes."
  type        = string
  default     = "tripleo"

  validation {
    condition     = trimspace(var.volume_type) != ""
    error_message = "volume_type must not be empty."
  }
}

variable "templates_dir" {
  description = "Optional absolute path to templates; defaults to this repository's templates directory."
  type        = string
  default     = ""
}

variable "public_ssh_key" {
  description = "OpenSSH public key read from the shared deployment key material."
  type        = string
  sensitive   = true

  validation {
    condition = can(regex(
      "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+/]{4}([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?( [A-Za-z0-9._@%+=:,/-]+)*$",
      var.public_ssh_key,
    )) && !can(regex("[\\r\\n]", var.public_ssh_key))
    error_message = "public_ssh_key must be exactly one newline-free OpenSSH public-key line with a supported algorithm, valid base64 blob, and optional safe comment."
  }
}

variable "moodle_version" {
  description = "Moodle release archive version. Defaults to Moodle 5.2.2, supported by the Remi PHP 8.3 and MariaDB 10.11 repositories on Rocky Linux 8.10."
  type        = string
  default     = "5.2.2"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.moodle_version))
    error_message = "moodle_version must be a numeric dotted release such as 5.2.2."
  }
}

variable "moodle_sha256" {
  description = "SHA-256 checksum for the Moodle release archive."
  type        = string
  default     = "72be209e7c0f5341b87de0bc993b2430087fda2769d8c3cc2f32736d1513e88c"

  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", var.moodle_sha256))
    error_message = "moodle_sha256 must be exactly 64 hexadecimal characters."
  }
}

variable "base_domain" {
  description = "Base DNS domain for the developer Moodle host."
  type        = string
  default     = "moodle.example.invalid"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$", var.base_domain))
    error_message = "base_domain must be a lowercase DNS-safe fully-qualified domain."
  }
}
