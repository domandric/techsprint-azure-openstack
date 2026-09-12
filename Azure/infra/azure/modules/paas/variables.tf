variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "shared_mysql_name" {
  description = "Collision-safe shared MySQL Flexible Server name (module.naming's shared_mysql_name output)."
  type        = string
}

variable "delegated_subnet_id" {
  description = "The shared hub snet-mysql-shared subnet ID, delegated to Microsoft.DBforMySQL/flexibleServers, for Private Access/VNet Integration."
  type        = string
}

variable "private_dns_zone_id" {
  description = "The shared privatelink.mysql.database.azure.com private DNS zone ID (from the shared root's own azurerm_private_dns_zone.shared map); this module never creates its own MySQL DNS zone."
  type        = string
}

variable "mysql_administrator_login" {
  type    = string
  default = "azure_admin"
}

variable "mysql_administrator_password" {
  description = "Sensitive shared MySQL administrator password. Exactly one CSPRNG secret for the whole shared server, supplied only through the runtime TF_VAR_mysql_administrator_password secret channel."
  type        = string
  sensitive   = true
}

variable "developers" {
  description = "Every validated developer, keyed by its own canonical slug (map key must equal .slug), used with for_each to create exactly one azurerm_mysql_flexible_database per developer named moodle_<slug_with_underscores>."
  type = map(object({
    slug = string
  }))
}
