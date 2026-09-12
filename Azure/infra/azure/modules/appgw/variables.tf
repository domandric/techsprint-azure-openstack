variable "enabled" {
  description = "Creates the private Application Gateway only during the shared reconciliation phase after tenant backend IPs exist."
  type        = bool
  default     = true
}

variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  type    = string
  default = "10.10.2.10"
}

variable "tenant_backends" {
  description = "Tenant backend addresses from tenant-root sanitized outputs, keyed by canonical slug."
  type = map(object({
    slug             = string
    network_slot     = number
    app01_private_ip = string
    app02_private_ip = string
  }))
  default = {}
}

variable "moodle_private_dns_zone_name" {
  type    = string
  default = "moodle.test"
}

variable "moodle_private_dns_zone_resource_group_name" {
  type = string
}
