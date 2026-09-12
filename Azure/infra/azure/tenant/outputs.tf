output "tenant_values" {
  description = "Non-secret tenant values for Ansible and shared reconciliation."
  value = {
    slug                     = var.developer.slug
    network_slot             = var.developer.network_slot
    developer_ssh_public_key = var.developer_ssh_public_key
    resource_group_name      = azurerm_resource_group.tenant.name
    vnet_id                  = module.network.tenant.vnet_id
    subnet_ids = {
      app               = module.network.tenant.app_subnet_id
      private_endpoints = module.network.tenant.private_endpoints_subnet_id
    }
    moodle_hostname = "${var.developer.slug}.moodle.test"
    apps = {
      app01 = module.compute.hosts["app01"]
      app02 = module.compute.hosts["app02"]
    }
    mysql = {
      fqdn                   = var.shared.mysql.fqdn
      version                = var.shared.mysql.version
      sku_name               = var.shared.mysql.sku_name
      sku_tier               = var.shared.mysql.sku_tier
      high_availability_mode = var.shared.mysql.high_availability_mode
      administrator_login    = var.shared.mysql.administrator_login
      database_name          = local.mysql_database_name
    }
    storage        = module.storage.storage
    uami_id        = azurerm_user_assigned_identity.apps.id
    uami_client_id = azurerm_user_assigned_identity.apps.client_id
    mount_targets  = module.storage.mount_targets
    role_assignment_ids = concat(
      module.storage.role_assignment_ids,
      [
        azurerm_role_assignment.developer_reader.id,
        azurerm_role_assignment.developer_vm_power.id,
        azurerm_role_assignment.lead_reader.id,
        azurerm_role_assignment.lead_vm_power.id,
      ],
    )
  }
}

output "runtime_secrets" {
  description = "Sensitive only. A local operator may materialize this in a 0600 Ansible vars file and must remove it after configuration."
  sensitive   = true
  value = {
    moodle_secrets = {
      (var.developer.slug) = {
        db_name     = local.mysql_database_name
        db_user     = "moodle"
        db_password = var.moodle_database_password
      }
    }
  }
}

output "reconciliation" {
  description = "Non-secret data for the shared post-tenant VNet peering, DNS, and Application Gateway step."
  value = {
    network = {
      slug         = var.developer.slug
      network_slot = var.developer.network_slot
      vnet_id      = module.network.tenant.vnet_id
    }
    backend = {
      slug             = var.developer.slug
      network_slot     = var.developer.network_slot
      app01_private_ip = module.compute.hosts["app01"].private_ip
      app02_private_ip = module.compute.hosts["app02"].private_ip
    }
  }
}
