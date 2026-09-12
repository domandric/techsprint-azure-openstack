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

variable "developer_slugs" {
  description = "Set of developer slugs whose Terraform workspaces are read from developer/<slug>/developer.tfstate."
  type        = set(string)

  validation {
    condition     = length(var.developer_slugs) >= 2 && alltrue([for slug in var.developer_slugs : slug != "default" && can(regex("^[a-z][a-z0-9-]{0,31}$", slug))])
    error_message = "developer_slugs must contain at least two lowercase slug-keyed developer workspaces other than \"default\"."
  }
}
