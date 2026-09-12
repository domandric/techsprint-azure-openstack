variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "storage_account_names" {
  description = "Locked b/f storage account names from the naming module."
  type = object({
    blob  = string
    files = string
  })
}

variable "private_endpoint_subnet_id" {
  type = string
}

variable "private_dns_zone_ids" {
  description = "Shared private DNS zone IDs (this module uses only the blob and file keys; the full shared map also carries moodle for other tenant modules)."
  type        = map(string)
}

variable "uami_principal_id" {
  description = "Tenant app UAMI principal ID; it receives the Blob data-plane role only."
  type        = string
}
