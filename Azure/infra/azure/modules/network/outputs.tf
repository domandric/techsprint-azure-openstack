output "hub" {
  value = var.mode == "hub" ? {
    vnet_id               = azurerm_virtual_network.hub[0].id
    vnet_name             = azurerm_virtual_network.hub[0].name
    jump_subnet_id        = azurerm_subnet.jump[0].id
    lead_subnet_id        = azurerm_subnet.lead[0].id
    app_gateway_subnet_id = azurerm_subnet.app_gateway[0].id
    mysql_subnet_id       = azurerm_subnet.mysql[0].id
    mysql_subnet_cidr     = local.hub.mysql_subnet
    jump_nsg_id           = azurerm_network_security_group.jump[0].id
    lead_nsg_id           = azurerm_network_security_group.lead[0].id
    app_gateway_nsg_id    = azurerm_network_security_group.app_gateway[0].id
    mysql_nsg_id          = azurerm_network_security_group.mysql[0].id
  } : null
}

output "tenant" {
  value = var.mode == "tenant" ? {
    vnet_id                       = azurerm_virtual_network.tenant[0].id
    vnet_name                     = azurerm_virtual_network.tenant[0].name
    app_subnet_id                 = azurerm_subnet.tenant_app[0].id
    private_endpoints_subnet_id   = azurerm_subnet.tenant_private_endpoints[0].id
    mysql_subnet_id               = azurerm_subnet.tenant_mysql[0].id
    app_asg_id                    = azurerm_application_security_group.tenant_apps[0].id
    app_nsg_id                    = azurerm_network_security_group.tenant_apps[0].id
    vnet_cidr                     = local.spoke.vnet_cidr
    app_subnet_cidr               = local.spoke.app_subnet
    private_endpoints_subnet_cidr = local.spoke.pe_subnet
    mysql_subnet_cidr             = local.spoke.mysql_subnet
  } : null
}

output "taggable_resources" {
  description = "Non-secret taggable network resources for the root inventory manifest."
  value = var.mode == "hub" ? {
    jump_nsg = {
      id   = azurerm_network_security_group.jump[0].id
      name = azurerm_network_security_group.jump[0].name
      type = "Microsoft.Network/networkSecurityGroups"
    }
    lead_nsg = {
      id   = azurerm_network_security_group.lead[0].id
      name = azurerm_network_security_group.lead[0].name
      type = "Microsoft.Network/networkSecurityGroups"
    }
    app_gateway_nsg = {
      id   = azurerm_network_security_group.app_gateway[0].id
      name = azurerm_network_security_group.app_gateway[0].name
      type = "Microsoft.Network/networkSecurityGroups"
    }
    mysql_nsg = {
      id   = azurerm_network_security_group.mysql[0].id
      name = azurerm_network_security_group.mysql[0].name
      type = "Microsoft.Network/networkSecurityGroups"
    }
    } : {
    app_asg = {
      id   = azurerm_application_security_group.tenant_apps[0].id
      name = azurerm_application_security_group.tenant_apps[0].name
      type = "Microsoft.Network/applicationSecurityGroups"
    }
    app_nsg = {
      id   = azurerm_network_security_group.tenant_apps[0].id
      name = azurerm_network_security_group.tenant_apps[0].name
      type = "Microsoft.Network/networkSecurityGroups"
    }
    app_route_table = {
      id   = azurerm_route_table.tenant_apps[0].id
      name = azurerm_route_table.tenant_apps[0].name
      type = "Microsoft.Network/routeTables"
    }
  }
}
