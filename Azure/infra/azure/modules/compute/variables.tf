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

variable "approved_vm_skus" {
  description = <<-EOT
    Ordered allow-list of VM SKUs a subscription-aware, read-only, quota-aware
    preflight (scripts/Resolve-AzureDeploymentProfile.ps1) may resolve for
    this project's app/Jump/Lead compute: Standard_B2s where the assignment
    brief literally names it and it is available (hardware + quota) in the
    target subscription/region, Standard_B2als_v2 as the assignment-compliant
    fallback (same x64/2 vCPU/4 GiB/zone 1+2 shape) when Standard_B2s is
    NotAvailableForSubscription or its own standardBSFamily quota cannot fit
    this project's 6-VM/12-vCPU fleet, and Standard_D2als_v6 as a further
    assignment-compliant fallback (same x64/2 vCPU/4 GiB/zone 1+2 shape,
    AMD-based "Dalsv6" family) when Standard_B2als_v2's own standardBasv2Family
    quota also cannot fit the fleet even though it is otherwise unrestricted
    (the preflight checks both the region's total vCPU quota and each
    candidate SKU's own family quota via Get-AzVMUsage before selecting it --
    see Test-DeploySkuQuotaSufficient). Standard_B2ats_v2 (1 GiB RAM) must
    never be listed here: it does not meet this project's 4 GiB requirement.
  EOT
  type        = list(string)
  default     = ["Standard_B2s", "Standard_B2als_v2", "Standard_D2als_v6"]

  validation {
    condition     = !contains(var.approved_vm_skus, "Standard_B2ats_v2")
    error_message = "Standard_B2ats_v2 has only 1 GiB RAM and must never be an approved VM SKU for this project."
  }
}

variable "rocky_image" {
  description = "Preflight-approved Rocky Linux 10 x86_64 marketplace/community-gallery image reference."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })

  validation {
    condition     = can(regex("(^|[^0-9])10([^0-9]|$)", lower("${var.rocky_image.offer}-${var.rocky_image.sku}")))
    error_message = "rocky_image offer or SKU must explicitly identify Rocky Linux 10; preflight must approve publisher/offer/SKU and terms."
  }
}

variable "admin_username" {
  type    = string
  default = "azureuser"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{0,30}$", var.admin_username))
    error_message = "admin_username must be a safe Linux account name."
  }
}

variable "hosts" {
  description = "Non-secret VM topology. Public keys are public material and are intentionally never output."
  type = map(object({
    name                           = string
    private_ip                     = string
    subnet_id                      = string
    size                           = string
    zone                           = optional(string)
    data_disk_enabled              = optional(bool, false)
    public_ip_enabled              = optional(bool, false)
    ip_forwarding_enabled          = optional(bool, false)
    application_security_group_ids = optional(list(string), [])
    user_assigned_identity_ids     = optional(list(string), [])
    ssh_public_keys                = map(string)
    cloud_init_role                = string
  }))

  validation {
    condition     = alltrue([for host in values(var.hosts) : can(regex("^[0-9.]+$", host.private_ip)) && length(host.name) <= 64])
    error_message = "Every host needs an IPv4 private address and an Azure-valid VM name (64 characters or fewer)."
  }
}
