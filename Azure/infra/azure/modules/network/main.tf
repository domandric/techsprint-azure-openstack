locals {
  hub = {
    vnet_cidr    = "10.10.0.0/16"
    jump_subnet  = "10.10.0.0/24"
    lead_subnet  = "10.10.1.0/24"
    appgw_subnet = "10.10.2.0/24"
    mysql_subnet = "10.10.3.0/24"
  }

  # Deterministic developer app-subnet /24 CIDRs derived from each known developer's own
  # network_slot, using the same formula as modules/naming (10.20.<slot*4>.0/24). Supplied
  # directly to the shared root (var.mysql_allowed_developers) so the one shared MySQL NSG
  # rule per developer never needs an actual tenant VNet/subnet ID to exist yet -- this keeps
  # the shared foundation apply (which creates the shared MySQL server) free of any
  # shared<->tenant root dependency cycle.
  mysql_allowed_developer_cidrs = var.mode == "hub" ? {
    for slug, developer in var.mysql_allowed_developers : slug => "10.20.${developer.network_slot * 4}.0/24"
  } : {}

  spoke_third_octet = var.network_slot == null ? null : var.network_slot * 4
  spoke = {
    vnet_cidr    = var.network_slot == null ? null : "10.20.${local.spoke_third_octet}.0/22"
    app_subnet   = var.network_slot == null ? null : "10.20.${local.spoke_third_octet}.0/24"
    pe_subnet    = var.network_slot == null ? null : "10.20.${local.spoke_third_octet + 1}.0/24"
    mysql_subnet = var.network_slot == null ? null : "10.20.${local.spoke_third_octet + 2}.0/24"
    reserved_two = var.network_slot == null ? null : "10.20.${local.spoke_third_octet + 3}.0/24"
  }

  foreign_tenants = var.mode == "tenant" ? {
    for slug, tenant in var.tenant_networks : slug => tenant if slug != var.tenant_slug
  } : {}
}

resource "terraform_data" "guardrails" {
  input = var.mode

  lifecycle {
    precondition {
      condition     = var.mode != "hub" || (var.allowed_ssh_cidr != null && can(cidrnetmask(var.allowed_ssh_cidr)))
      error_message = "Hub mode requires a valid Jump SSH source CIDR."
    }

    precondition {
      condition     = var.mode != "tenant" || (var.network_slot != null && var.network_slot >= 0 && var.network_slot <= 63 && var.hub_vnet_id != null && var.tenant_slug != null)
      error_message = "Tenant mode requires tenant_slug, network_slot 0..63, and hub_vnet_id."
    }

    precondition {
      condition     = length(distinct([for tenant in values(var.tenant_networks) : tenant.network_slot])) == length(var.tenant_networks)
      error_message = "Every known tenant network_slot must be unique."
    }

    precondition {
      condition     = var.mode != "hub" || alltrue([for tenant in values(var.tenant_networks) : try(tenant.vnet_id != null && tenant.vnet_id != "", false)])
      error_message = "Shared hub reconciliation requires a VNet ID for every tenant."
    }

    precondition {
      condition     = var.mode != "hub" || length(distinct([for developer in values(var.mysql_allowed_developers) : developer.network_slot])) == length(var.mysql_allowed_developers)
      error_message = "Every mysql_allowed_developers network_slot must be unique (one deterministic shared-MySQL-subnet NSG rule per developer)."
    }

    precondition {
      condition     = var.mode != "hub" || alltrue([for slot in [for developer in values(var.mysql_allowed_developers) : developer.network_slot] : slot >= 0 && slot <= 63 && floor(slot) == slot])
      error_message = "Every mysql_allowed_developers network_slot must be an integer from 0 through 63."
    }

    precondition {
      condition = var.mode != "hub" || alltrue([
        for slug, developer in var.mysql_allowed_developers :
        slug == developer.slug && can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", slug)) && length(slug) <= 40
      ])
      error_message = "Every mysql_allowed_developers entry must be a validated canonical developer slug of at most 40 characters."
    }
  }
}

resource "azurerm_virtual_network" "hub" {
  count = var.mode == "hub" ? 1 : 0

  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [local.hub.vnet_cidr]
  tags                = var.tags

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_subnet" "jump" {
  count = var.mode == "hub" ? 1 : 0

  name                 = "snet-jump"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub[0].name
  address_prefixes     = [local.hub.jump_subnet]
}

resource "azurerm_subnet" "lead" {
  count = var.mode == "hub" ? 1 : 0

  name                 = "snet-lead"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub[0].name
  address_prefixes     = [local.hub.lead_subnet]
}

resource "azurerm_subnet" "app_gateway" {
  count = var.mode == "hub" ? 1 : 0

  name                 = "snet-appgw"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub[0].name
  address_prefixes     = [local.hub.appgw_subnet]

  delegation {
    name = "application-gateway"

    service_delegation {
      name    = "Microsoft.Network/applicationGateways"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "mysql" {
  count = var.mode == "hub" ? 1 : 0

  name                 = "snet-mysql-shared"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub[0].name
  address_prefixes     = [local.hub.mysql_subnet]

  delegation {
    name = "mysql-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforMySQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_network_security_group" "jump" {
  count = var.mode == "hub" ? 1 : 0

  name                = "nsg-ts-shared-jump-testing-${var.location_short_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "jump_ssh" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "allow-jump-ssh"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.allowed_ssh_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.jump[0].name
}

resource "azurerm_network_security_rule" "jump_tenant_transit" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "allow-tenant-transit"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "10.20.0.0/16"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.jump[0].name
}

resource "azurerm_network_security_rule" "jump_deny_other_inbound" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "deny-other-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.jump[0].name
}

resource "azurerm_subnet_network_security_group_association" "jump" {
  count = var.mode == "hub" ? 1 : 0

  subnet_id                 = azurerm_subnet.jump[0].id
  network_security_group_id = azurerm_network_security_group.jump[0].id
}

resource "azurerm_network_security_group" "lead" {
  count = var.mode == "hub" ? 1 : 0

  name                = "nsg-ts-shared-lead-testing-${var.location_short_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "lead_ssh_from_jump" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "allow-jump-ssh"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "10.10.0.10/32"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.lead[0].name
}

resource "azurerm_network_security_rule" "lead_deny_other_inbound" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "deny-other-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.lead[0].name
}

resource "azurerm_subnet_network_security_group_association" "lead" {
  count = var.mode == "hub" ? 1 : 0

  subnet_id                 = azurerm_subnet.lead[0].id
  network_security_group_id = azurerm_network_security_group.lead[0].id
}

resource "azurerm_network_security_group" "app_gateway" {
  count = var.mode == "hub" ? 1 : 0

  name                = "nsg-ts-shared-appgw-testing-${var.location_short_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "app_gateway_gateway_manager" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "allow-gateway-manager"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.app_gateway[0].name
}

resource "azurerm_network_security_rule" "app_gateway_health_probe" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "allow-azure-load-balancer"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.app_gateway[0].name
}

resource "azurerm_network_security_rule" "app_gateway_private_listener" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "allow-jump-private-listener"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = "10.10.0.10/32"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.app_gateway[0].name
}

resource "azurerm_network_security_rule" "app_gateway_deny_other_inbound" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "deny-other-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.app_gateway[0].name
}

resource "azurerm_subnet_network_security_group_association" "app_gateway" {
  count = var.mode == "hub" ? 1 : 0

  subnet_id                 = azurerm_subnet.app_gateway[0].id
  network_security_group_id = azurerm_network_security_group.app_gateway[0].id
}

resource "azurerm_network_security_group" "mysql" {
  count = var.mode == "hub" ? 1 : 0

  name                = "nsg-ts-shared-mysql-testing-${var.location_short_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# One deterministic allow rule per validated developer, scoped to that developer's own app
# subnet /24 only (never the whole 10.20.0.0/16 spoke range), with a safe unique priority
# derived from the developer's own immutable network_slot (0..63 -> priority 100..163).
resource "azurerm_network_security_rule" "mysql_allow_developer" {
  for_each = var.mode == "hub" ? var.mysql_allowed_developers : {}

  name                        = "allow-mysql-${each.value.slug}"
  priority                    = 100 + each.value.network_slot
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3306"
  source_address_prefix       = local.mysql_allowed_developer_cidrs[each.key]
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.mysql[0].name
}

resource "azurerm_network_security_rule" "mysql_deny_other_inbound" {
  count = var.mode == "hub" ? 1 : 0

  name                        = "deny-other-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.mysql[0].name
}

resource "azurerm_subnet_network_security_group_association" "mysql" {
  count = var.mode == "hub" ? 1 : 0

  subnet_id                 = azurerm_subnet.mysql[0].id
  network_security_group_id = azurerm_network_security_group.mysql[0].id
}

resource "azurerm_virtual_network_peering" "hub_to_tenant" {
  for_each = var.mode == "hub" ? var.tenant_networks : {}

  name                         = "peer-hub-to-${each.key}"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.hub[0].name
  remote_virtual_network_id    = each.value.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network" "tenant" {
  count = var.mode == "tenant" ? 1 : 0

  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [local.spoke.vnet_cidr]
  tags                = var.tags

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_subnet" "tenant_app" {
  count = var.mode == "tenant" ? 1 : 0

  name                 = "snet-app"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.tenant[0].name
  address_prefixes     = [local.spoke.app_subnet]
}

resource "azurerm_subnet" "tenant_private_endpoints" {
  count = var.mode == "tenant" ? 1 : 0

  name                              = "snet-private-endpoints"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.tenant[0].name
  address_prefixes                  = [local.spoke.pe_subnet]
  private_endpoint_network_policies = "Disabled"
}

# RESERVED/UNUSED: MySQL Flexible Server is now one shared instance in the hub's own
# snet-mysql-shared subnet (see azurerm_subnet.mysql above), created once during shared
# foundation apply with genuine Zone-Redundant HA and one database per developer. This
# per-tenant delegated subnet is intentionally left in place, unchanged, only so an existing
# tenant's Terraform apply never proposes destroying it out-of-band; no new resource is ever
# placed in it.
resource "azurerm_subnet" "tenant_mysql" {
  count = var.mode == "tenant" ? 1 : 0

  name                 = "snet-mysql"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.tenant[0].name
  address_prefixes     = [local.spoke.mysql_subnet]

  delegation {
    name = "mysql-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforMySQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "tenant_reserved_two" {
  count = var.mode == "tenant" ? 1 : 0

  name                 = "snet-reserved-02"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.tenant[0].name
  address_prefixes     = [local.spoke.reserved_two]
}

resource "azurerm_application_security_group" "tenant_apps" {
  count = var.mode == "tenant" ? 1 : 0

  name                = "asg-ts-${var.tenant_slug}-apps-testing-${var.location_short_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_group" "tenant_apps" {
  count = var.mode == "tenant" ? 1 : 0

  name                = "nsg-ts-${var.tenant_slug}-apps-testing-${var.location_short_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "tenant_ssh_from_jump" {
  count = var.mode == "tenant" ? 1 : 0

  name                                       = "allow-jump-ssh"
  priority                                   = 100
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "22"
  source_address_prefix                      = "10.10.0.10/32"
  destination_application_security_group_ids = [azurerm_application_security_group.tenant_apps[0].id]
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.tenant_apps[0].name
}

resource "azurerm_network_security_rule" "tenant_ssh_from_lead" {
  count = var.mode == "tenant" ? 1 : 0

  name                                       = "allow-lead-ssh"
  priority                                   = 110
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "22"
  source_address_prefix                      = "10.10.1.10/32"
  destination_application_security_group_ids = [azurerm_application_security_group.tenant_apps[0].id]
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.tenant_apps[0].name
}

resource "azurerm_network_security_rule" "tenant_http_from_app_gateway" {
  count = var.mode == "tenant" ? 1 : 0

  name                                       = "allow-appgw-http"
  priority                                   = 120
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "80"
  source_address_prefix                      = "10.10.2.0/24"
  destination_application_security_group_ids = [azurerm_application_security_group.tenant_apps[0].id]
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.tenant_apps[0].name
}

resource "azurerm_network_security_rule" "tenant_to_own_private_endpoints" {
  count = var.mode == "tenant" ? 1 : 0

  name                                  = "allow-own-private-endpoints"
  priority                              = 100
  direction                             = "Outbound"
  access                                = "Allow"
  protocol                              = "Tcp"
  source_port_range                     = "*"
  destination_port_ranges               = ["443", "2049"]
  source_application_security_group_ids = [azurerm_application_security_group.tenant_apps[0].id]
  destination_address_prefix            = local.spoke.pe_subnet
  resource_group_name                   = var.resource_group_name
  network_security_group_name           = azurerm_network_security_group.tenant_apps[0].name
}

resource "azurerm_network_security_rule" "tenant_deny_foreign_spoke" {
  for_each = var.mode == "tenant" ? local.foreign_tenants : {}

  name                                       = "deny-${each.key}"
  priority                                   = 200 + each.value.network_slot
  direction                                  = "Inbound"
  access                                     = "Deny"
  protocol                                   = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  source_address_prefix                      = "10.20.${each.value.network_slot * 4}.0/22"
  destination_application_security_group_ids = [azurerm_application_security_group.tenant_apps[0].id]
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.tenant_apps[0].name
}

resource "azurerm_network_security_rule" "tenant_deny_other_inbound" {
  count = var.mode == "tenant" ? 1 : 0

  name                                       = "deny-other-inbound"
  priority                                   = 4096
  direction                                  = "Inbound"
  access                                     = "Deny"
  protocol                                   = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  source_address_prefix                      = "*"
  destination_application_security_group_ids = [azurerm_application_security_group.tenant_apps[0].id]
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.tenant_apps[0].name
}

resource "azurerm_subnet_network_security_group_association" "tenant_apps" {
  count = var.mode == "tenant" ? 1 : 0

  subnet_id                 = azurerm_subnet.tenant_app[0].id
  network_security_group_id = azurerm_network_security_group.tenant_apps[0].id
}

resource "azurerm_route_table" "tenant_apps" {
  count = var.mode == "tenant" ? 1 : 0

  name                          = "rt-ts-${var.tenant_slug}-apps-testing-${var.location_short_name}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  bgp_route_propagation_enabled = false
  tags                          = var.tags
}

resource "azurerm_route" "tenant_default_to_jump" {
  count = var.mode == "tenant" ? 1 : 0

  name                   = "default-to-jump-nva"
  resource_group_name    = var.resource_group_name
  route_table_name       = azurerm_route_table.tenant_apps[0].name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "10.10.0.10"
}

resource "azurerm_route" "tenant_blackhole_foreign_spoke" {
  for_each = var.mode == "tenant" ? local.foreign_tenants : {}

  name                = "blackhole-${each.key}"
  resource_group_name = var.resource_group_name
  route_table_name    = azurerm_route_table.tenant_apps[0].name
  address_prefix      = "10.20.${each.value.network_slot * 4}.0/22"
  next_hop_type       = "None"
}

resource "azurerm_subnet_route_table_association" "tenant_apps" {
  count = var.mode == "tenant" ? 1 : 0

  subnet_id      = azurerm_subnet.tenant_app[0].id
  route_table_id = azurerm_route_table.tenant_apps[0].id
}

resource "azurerm_virtual_network_peering" "tenant_to_hub" {
  count = var.mode == "tenant" ? 1 : 0

  name                         = "peer-${var.tenant_slug}-to-hub"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.tenant[0].name
  remote_virtual_network_id    = var.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
