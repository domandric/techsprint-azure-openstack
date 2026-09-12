locals {
  custom_role_definition_id = azurerm_role_definition.vm_power_operator.role_definition_resource_id
}

output "shared_values" {
  description = "Non-secret shared values used when preparing tenant inputs. It is complete after shared reconciliation enables App Gateway."
  value = {
    resource_group_name       = azurerm_resource_group.shared.name
    allowed_ssh_cidr          = var.allowed_ssh_cidr
    hub_vnet_id               = module.network.hub.vnet_id
    jump                      = module.compute.hosts["jump"]
    jump_public_ip            = module.compute.hosts["jump"].public_ip
    admin_username            = module.compute.hosts["jump"].admin_username
    lead                      = module.compute.hosts["lead"]
    app_gateway               = module.app_gateway.application_gateway
    private_dns_zone_ids      = { for key, zone in azurerm_private_dns_zone.shared : key => zone.id }
    custom_role_definition_id = local.custom_role_definition_id
    mysql                     = module.paas.mysql
    mysql_database_names      = module.paas.database_names
  }
}

output "mysql" {
  description = "Non-secret shared MySQL contract: one shared, Zone-Redundant GP_Standard_D2ds_v4 MySQL Flexible Server, and its map of developer slug to derived database name (moodle_<slug_with_underscores>)."
  value = {
    id                     = module.paas.mysql.id
    name                   = module.paas.mysql.name
    fqdn                   = module.paas.mysql.fqdn
    version                = module.paas.mysql.version
    sku_name               = module.paas.mysql.sku_name
    sku_tier               = module.paas.mysql.sku_tier
    high_availability_mode = module.paas.mysql.high_availability_mode
    administrator_login    = module.paas.mysql.administrator_login
    delegated_subnet_id    = module.paas.mysql.delegated_subnet_id
    private_dns_zone_id    = module.paas.mysql.private_dns_zone_id
    database_names         = module.paas.database_names
  }
}

output "shared_runtime_secrets" {
  description = "Sensitive only. The single shared MySQL administrator credential. Stored only in shared Terraform state and the final encrypted Ansible Vault; never duplicated into any tenant Terraform state."
  sensitive   = true
  value = {
    mysql_administrator_login    = module.paas.runtime_secrets.mysql_administrator_login
    mysql_administrator_password = module.paas.runtime_secrets.mysql_administrator_password
  }
}

output "identity" {
  description = "Non-secret identity values used when preparing tenant inputs."
  value = {
    developer_group_ids       = module.identity.developer_group_ids
    lead_group_id             = module.identity.lead_group_id
    custom_role_definition_id = local.custom_role_definition_id
  }
}

output "hub_network" {
  description = "Non-secret network value used when preparing tenant inputs."
  value = {
    hub_vnet_id = module.network.hub.vnet_id
  }
}
