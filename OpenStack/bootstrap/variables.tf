variable "cloud" {
  description = "Optional clouds.yaml entry name. Leave empty to authenticate purely from a sourced OpenRC (OS_* environment variables), which is the default operating mode for this deployment."
  type        = string
  default     = ""
}

variable "region" {
  description = "OpenStack region. This deployment is pinned to the exact RHOSP 16.1 region name regionOne."
  type        = string
  default     = "regionOne"

  validation {
    condition     = var.region == "regionOne"
    error_message = "region must be exactly \"regionOne\"."
  }
}

variable "domain_id" {
  description = "Keystone domain ID that owns every project, user, and group created by this module."
  type        = string

  validation {
    condition     = trimspace(var.domain_id) != ""
    error_message = "domain_id must not be empty."
  }
}

variable "name_seed" {
  description = "Deployment-wide name seed used as the exact Keystone project/user/group name prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{3,31}$", var.name_seed))
    error_message = "name_seed must start with a lowercase ASCII letter and contain 4-32 lowercase letters, digits, or hyphens."
  }
}

variable "users" {
  description = <<-EOT
    CSV-derived guest users, already normalized and keyed by their stable
    lowercase slug outside this module's write scope. Exactly one
    "devops_lead" and at least two "developer" entries are required.
  EOT
  type = map(object({
    role       = string
    first_name = string
    last_name  = string
    email      = string
  }))

  validation {
    condition     = alltrue([for slug in keys(var.users) : slug != "default" && can(regex("^[a-z][a-z0-9-]{0,31}$", slug))])
    error_message = "every users key must be a lowercase deterministic slug other than \"default\"."
  }

  validation {
    condition     = alltrue([for u in values(var.users) : contains(["devops_lead", "developer"], u.role)])
    error_message = "every user role must be exactly \"devops_lead\" or \"developer\"."
  }

  validation {
    condition     = length([for u in values(var.users) : u if u.role == "devops_lead"]) == 1
    error_message = "exactly one devops_lead user is required."
  }

  validation {
    condition     = length([for u in values(var.users) : u if u.role == "developer"]) >= 2
    error_message = "at least two developer users are required."
  }

  validation {
    condition     = alltrue([for u in values(var.users) : trimspace(u.first_name) != "" && trimspace(u.last_name) != "" && can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", u.email))])
    error_message = "every user requires a non-empty first_name, last_name, and a syntactically valid email."
  }
}

variable "member_role_name" {
  description = "Standard Keystone role granted to each developer group on its own project, and to the lead group on every project. Defaults to the built-in \"member\" role present in every Keystone deployment, so no custom role is required as a platform prerequisite."
  type        = string
  default     = "member"
}

variable "admin_role_name" {
  description = "Standard Keystone administrator role granted to provisioner_user_id on every deployment project."
  type        = string
  default     = "admin"
}

variable "provisioner_user_id" {
  description = "Required Keystone user ID from the sourced administrator OpenRC. This user receives the admin role on the shared and developer projects."
  type        = string

  validation {
    condition     = trimspace(var.provisioner_user_id) != ""
    error_message = "provisioner_user_id must be supplied; bootstrap never infers or silently substitutes the authenticated user."
  }
}

variable "flavors" {
  description = <<-EOT
    Public Nova flavors created by this root, keyed by logical role.
  EOT
  type = map(object({
    name    = string
    vcpus   = number
    ram_mib = number
    disk_gb = number
  }))
  default = {
    shared = {
      name    = "flv-techsprint-lab-small"
      vcpus   = 1
      ram_mib = 2048
      disk_gb = 10
    }
    app = {
      name    = "flv-techsprint-app"
      vcpus   = 2
      ram_mib = 4096
      disk_gb = 10
    }
    database = {
      name    = "flv-techsprint-db"
      vcpus   = 2
      ram_mib = 4096
      disk_gb = 10
    }
  }

  validation {
    condition     = sort(keys(var.flavors)) == sort(["app", "database", "shared"])
    error_message = "flavors must define exactly the keys \"shared\", \"app\", and \"database\"."
  }

  validation {
    condition = alltrue([
      for f in values(var.flavors) :
      trimspace(f.name) != "" && f.vcpus >= 1 && floor(f.vcpus) == f.vcpus &&
      f.ram_mib >= 512 && floor(f.ram_mib) == f.ram_mib &&
      f.disk_gb >= 1 && floor(f.disk_gb) == f.disk_gb
    ])
    error_message = "every flavor requires a non-empty name and whole-number vcpus >= 1, ram_mib >= 512, disk_gb >= 1."
  }

  validation {
    condition     = length(distinct([for f in values(var.flavors) : f.name])) == length(var.flavors)
    error_message = "flavor names must be unique."
  }
}
