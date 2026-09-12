variable "name_seed" {
  description = "Short deployment-wide name seed used in OpenStack resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{3,31}$", var.name_seed))
    error_message = "name_seed must start with a lowercase ASCII letter and contain 4-32 lowercase letters, digits, or hyphens."
  }
}

variable "project_id" {
  description = "Developer project ID to which the caller's provider is scoped."
  type        = string

  validation {
    condition     = trimspace(var.project_id) != ""
    error_message = "project_id must not be empty."
  }
}

variable "shared_project_id" {
  description = "Shared project ID that receives access to the developer network."
  type        = string

  validation {
    condition     = trimspace(var.shared_project_id) != ""
    error_message = "shared_project_id must not be empty."
  }
}

variable "developer_slug" {
  description = "Stable Linux/developer slug from the validated users CSV."
  type        = string

  validation {
    condition     = var.developer_slug != "default" && can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", var.developer_slug))
    error_message = "developer_slug must be a lowercase deterministic slug other than \"default\"."
  }
}

variable "network_slot" {
  description = "Decimal octet used by the private 10.210.<slot>.0/24 network."
  type        = number

  validation {
    condition     = var.network_slot >= 0 && var.network_slot <= 63 && floor(var.network_slot) == var.network_slot
    error_message = "network_slot must be a whole number from 0 through 63."
  }
}

variable "external_network_name" {
  description = "Existing external/provider network name from shared state."
  type        = string

  validation {
    condition     = trimspace(var.external_network_name) != ""
    error_message = "external_network_name must not be empty."
  }
}

variable "image_id" {
  description = "Glance image ID used to boot all three instances directly."
  type        = string
}

variable "app_flavor_id" {
  description = "Flavor ID for the two application instances."
  type        = string
}

variable "db_flavor_id" {
  description = "Flavor ID for the standalone database instance."
  type        = string
}

variable "keypair_name" {
  description = "Existing Nova keypair name applied to every developer VM."
  type        = string

  validation {
    condition     = trimspace(var.keypair_name) != ""
    error_message = "keypair_name must not be empty."
  }
}

variable "volume_type" {
  description = "Cinder type for each of the three 10 GiB data volumes."
  type        = string
  default     = "tripleo"

  validation {
    condition     = trimspace(var.volume_type) != ""
    error_message = "volume_type must not be empty."
  }
}

variable "data_volume_size" {
  description = "Size in GiB of each Cinder data volume."
  type        = number
  default     = 10

  validation {
    condition     = var.data_volume_size == 10
    error_message = "data_volume_size is fixed at 10 GiB."
  }
}

variable "templates_dir" {
  description = "Absolute or module-relative directory containing Terraform cloud-init templates."
  type        = string

  validation {
    condition     = trimspace(var.templates_dir) != ""
    error_message = "templates_dir must not be empty."
  }
}

variable "public_ssh_key" {
  description = "OpenSSH public key installed for the developer account."
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

variable "lead_ssh_public_key" {
  description = "OpenSSH public key retained for Lead administration of developer VMs."
  type        = string

  validation {
    condition = can(regex(
      "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+/]{4}([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?( [A-Za-z0-9._@%+=:,/-]+)*$",
      var.lead_ssh_public_key,
    )) && !can(regex("[\\r\\n]", var.lead_ssh_public_key))
    error_message = "lead_ssh_public_key must be exactly one newline-free OpenSSH public-key line with a supported algorithm, valid base64 blob, and optional safe comment."
  }
}

variable "db_password" {
  description = "Sensitive Moodle database password read by the caller from bootstrap state."
  type        = string
  sensitive   = true

  validation {
    condition     = trimspace(var.db_password) != ""
    error_message = "db_password must not be empty."
  }
}

variable "moodle_version" {
  description = "Moodle release archive version, e.g. 5.2.2 for Rocky Linux 8.10 with Remi PHP 8.3 and MariaDB 10.11."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.moodle_version))
    error_message = "moodle_version must be a numeric dotted release such as 5.2.2."
  }
}

variable "moodle_sha256" {
  description = "SHA-256 checksum for the Moodle release archive."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", var.moodle_sha256))
    error_message = "moodle_sha256 must be a 64-character hexadecimal SHA-256 checksum."
  }
}

variable "base_domain" {
  description = "Base DNS domain used in the Moodle virtual host and URL."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$", var.base_domain))
    error_message = "base_domain must be a lowercase fully-qualified DNS domain."
  }
}

variable "dns_nameservers" {
  description = "DNS servers advertised by the private subnet."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}
