output "mysql" {
  description = "Non-secret shared MySQL contract: identity, connection, and HA/SKU literals that exactly match the azurerm_mysql_flexible_server.this resource block above."
  value = {
    id                     = azurerm_mysql_flexible_server.this.id
    name                   = azurerm_mysql_flexible_server.this.name
    fqdn                   = azurerm_mysql_flexible_server.this.fqdn
    version                = "8.4"
    sku_name               = local.mysql_sku_name
    sku_tier               = "GeneralPurpose"
    high_availability_mode = "ZoneRedundant"
    administrator_login    = var.mysql_administrator_login
    public_network_access  = azurerm_mysql_flexible_server.this.public_network_access
    delegated_subnet_id    = azurerm_mysql_flexible_server.this.delegated_subnet_id
    private_dns_zone_id    = var.private_dns_zone_id
  }
}

output "database_names" {
  description = "Non-secret map of developer slug to its own derived MySQL database name (moodle_<slug_with_underscores>)."
  value       = local.database_names
}

output "runtime_secrets" {
  description = "Sensitive only. The single shared MySQL administrator credential. It is merged in memory with per-tenant database credentials and written only to the encrypted Ansible Vault; it is never duplicated into any tenant Terraform state."
  sensitive   = true
  value = {
    mysql_administrator_login    = var.mysql_administrator_login
    mysql_administrator_password = var.mysql_administrator_password
  }
}
