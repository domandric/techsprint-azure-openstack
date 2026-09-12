module "naming" {
  source = "../modules/naming"

  scope               = "shared"
  owner               = "shared"
  name_seed           = var.name_seed
  location            = var.location
  location_short_name = var.location_short_name
}

locals {
  all_users = merge(
    {
      (var.users.lead.slug) = {
        slug = var.users.lead.slug
        upn  = var.users.lead.upn
        role = var.users.lead.rola
      }
    },
    {
      for developer in var.users.developers : developer.slug => {
        slug = developer.slug
        upn  = developer.upn
        role = developer.rola
      }
    },
  )

  developer_users = {
    for developer in var.users.developers : developer.slug => developer
  }

  jump_ssh_keys = {
    (var.users.lead.slug) = var.lead_ssh_public_key
  }
  lead_ssh_keys = {
    (var.users.lead.slug) = var.lead_ssh_public_key
  }

  inventory_directory = abspath("${path.root}/../../../runtime/ansible/inventory")

  ansible_inventory = {
    all = {
      vars = {
        ansible_user     = module.compute.hosts["jump"].admin_username
        allowed_ssh_cidr = var.allowed_ssh_cidr
      }
      children = {
        jump = {
          vars = {
            app_gateway_private_ip = try(module.app_gateway.application_gateway.private_ip, "")
            app_gateway_port       = try(module.app_gateway.application_gateway.frontend_port, 0)
          }
          hosts = {
            (module.naming.vm_names.jump) = {
              ansible_host = module.compute.hosts["jump"].public_ip
              app_role     = "jump"
            }
          }
        }
        lead = {
          hosts = {
            (module.naming.vm_names.lead) = {
              ansible_host            = module.compute.hosts["lead"].private_ip
              ansible_ssh_common_args = format("-o ProxyCommand=\"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -W %%h:%%p %s@%s\"", module.compute.hosts["jump"].admin_username, module.compute.hosts["jump"].public_ip)
              app_role                = "lead"
            }
          }
        }
      }
    }
  }

  tenant_dns_links = {
    for pair in flatten([
      for zone_key, zone in azurerm_private_dns_zone.shared : [
        for slug, tenant in var.tenant_networks : {
          key      = "${zone_key}:${slug}"
          zone_key = zone_key
          slug     = slug
          vnet_id  = tenant.vnet_id
        }
      ]
    ]) : pair.key => pair
  }
}

resource "terraform_data" "guardrails" {
  input = local.all_users

  lifecycle {
    precondition {
      condition     = var.users.lead.rola == "devops_lead"
      error_message = "shared requires exactly one devops_lead object."
    }

    precondition {
      condition     = length(local.developer_users) >= 2
      error_message = "At least two developers are required (docs/IRUO_Projekt_2025_2026-2.pdf's tested scope: 2 developers + 1 lead)."
    }

    precondition {
      condition     = length(distinct([for developer in values(local.developer_users) : developer.network_slot])) == length(local.developer_users)
      error_message = "network_slot collisions are a hard failure."
    }

    precondition {
      condition     = alltrue([for slug in keys(local.all_users) : can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", slug)) && length(slug) <= 40])
      error_message = "Canonical user slugs must be valid and at most 40 characters under the locked Azure VM naming bound."
    }

    precondition {
      condition = alltrue([
        for key in values(local.jump_ssh_keys) : length(trimspace(key)) > 0 && can(regex("^(ssh-|ecdsa-sha2-|sk-ssh-)", trimspace(key)))
        ]) && alltrue([
        for key in values(local.lead_ssh_keys) : length(trimspace(key)) > 0 && can(regex("^(ssh-|ecdsa-sha2-|sk-ssh-)", trimspace(key)))
      ])
      error_message = "Provide the lead public SSH key before planning shared compute; private keys are never accepted."
    }

    precondition {
      condition     = !var.app_gateway_enabled || length(var.tenant_backends) > 0
      error_message = "Enable the Application Gateway only during shared reconciliation after tenant backend outputs exist."
    }
  }
}

resource "azurerm_resource_group" "shared" {
  name     = module.naming.resource_group_name
  location = var.location
  tags     = module.naming.tags
}

module "network" {
  source = "../modules/network"

  mode                     = "hub"
  name                     = module.naming.vnet_name
  resource_group_name      = azurerm_resource_group.shared.name
  location                 = azurerm_resource_group.shared.location
  location_short_name      = module.naming.location_short_name
  tags                     = module.naming.tags
  allowed_ssh_cidr         = var.allowed_ssh_cidr
  tenant_networks          = var.tenant_networks
  mysql_allowed_developers = local.developer_users

  depends_on = [terraform_data.guardrails]
}

module "identity" {
  source = "../modules/identity"

  entra_mode        = var.entra_mode
  users             = local.all_users
  initial_passwords = var.entra_initial_passwords

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_role_definition" "vm_power_operator" {
  name               = "TechSprint VM Power Operator"
  scope              = "/subscriptions/${var.subscription_id}"
  role_definition_id = "6814e859-5c67-469b-975a-0887b17393d6"
  description        = "Least-privilege start/restart/power-off/deallocate operations for Azure app VMs."

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/instanceView/read",
      "Microsoft.Compute/virtualMachines/start/action",
      "Microsoft.Compute/virtualMachines/restart/action",
      "Microsoft.Compute/virtualMachines/powerOff/action",
      "Microsoft.Compute/virtualMachines/deallocate/action",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
    ]
    not_actions = []
  }

  assignable_scopes = ["/subscriptions/${var.subscription_id}"]
}

resource "azurerm_role_assignment" "lead_vm_power_shared" {
  scope              = azurerm_resource_group.shared.id
  role_definition_id = azurerm_role_definition.vm_power_operator.role_definition_resource_id
  principal_id       = module.identity.lead_group_id

  principal_type = "Group"
}

resource "azurerm_private_dns_zone" "shared" {
  for_each = {
    blob   = "privatelink.blob.core.windows.net"
    file   = "privatelink.file.core.windows.net"
    moodle = "moodle.test"
    mysql  = "privatelink.mysql.database.azure.com"
  }

  name                = each.value
  resource_group_name = azurerm_resource_group.shared.name
  tags                = module.naming.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each = azurerm_private_dns_zone.shared

  name                  = "link-hub-${replace(each.key, "_", "-")}"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = module.network.hub.vnet_id
  registration_enabled  = false
  tags                  = module.naming.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "tenant" {
  for_each = local.tenant_dns_links

  name                  = "link-${each.value.slug}-${each.value.zone_key}"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.shared[each.value.zone_key].name
  virtual_network_id    = each.value.vnet_id
  registration_enabled  = false
  tags                  = module.naming.tags
}

module "paas" {
  source = "../modules/paas"

  resource_group_name          = azurerm_resource_group.shared.name
  location                     = azurerm_resource_group.shared.location
  tags                         = module.naming.tags
  shared_mysql_name            = module.naming.shared_mysql_name
  delegated_subnet_id          = module.network.hub.mysql_subnet_id
  private_dns_zone_id          = azurerm_private_dns_zone.shared["mysql"].id
  mysql_administrator_password = var.mysql_administrator_password
  developers                   = local.developer_users

  depends_on = [
    terraform_data.guardrails,
    azurerm_private_dns_zone_virtual_network_link.hub,
  ]
}

module "compute" {
  source = "../modules/compute"

  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  location_short_name = module.naming.location_short_name
  tags                = module.naming.tags
  rocky_image         = var.rocky_image
  hosts = {
    jump = {
      name                           = module.naming.vm_names.jump
      private_ip                     = module.naming.addresses.jump_private_ip
      subnet_id                      = module.network.hub.jump_subnet_id
      size                           = var.vm_sku
      data_disk_enabled              = false
      public_ip_enabled              = true
      ip_forwarding_enabled          = true
      application_security_group_ids = []
      user_assigned_identity_ids     = []
      ssh_public_keys                = local.jump_ssh_keys
      cloud_init_role                = "jump"
    }
    lead = {
      name                           = module.naming.vm_names.lead
      private_ip                     = module.naming.addresses.lead_private_ip
      subnet_id                      = module.network.hub.lead_subnet_id
      size                           = var.vm_sku
      data_disk_enabled              = false
      public_ip_enabled              = false
      ip_forwarding_enabled          = false
      application_security_group_ids = []
      user_assigned_identity_ids     = []
      ssh_public_keys                = local.lead_ssh_keys
      cloud_init_role                = "lead"
    }
  }

  depends_on = [terraform_data.guardrails]
}

module "app_gateway" {
  source = "../modules/appgw"

  enabled                                     = var.app_gateway_enabled
  name                                        = module.naming.app_gateway_name
  resource_group_name                         = azurerm_resource_group.shared.name
  location                                    = azurerm_resource_group.shared.location
  tags                                        = module.naming.tags
  subnet_id                                   = module.network.hub.app_gateway_subnet_id
  private_ip                                  = module.naming.addresses.app_gateway_private_ip
  tenant_backends                             = var.tenant_backends
  moodle_private_dns_zone_name                = azurerm_private_dns_zone.shared["moodle"].name
  moodle_private_dns_zone_resource_group_name = azurerm_resource_group.shared.name
}

resource "terraform_data" "ansible_inventory_guardrails" {
  input = var.app_gateway_enabled ? module.app_gateway.application_gateway : null

  lifecycle {
    precondition {
      condition = !var.app_gateway_enabled || (
        length(trimspace(try(module.app_gateway.application_gateway.private_ip, ""))) > 0 &&
        try(module.app_gateway.application_gateway.frontend_port, 0) == 8080
      )
      error_message = "The shared Ansible inventory is generated only after the private Application Gateway has a private IP and port 8080."
    }

    precondition {
      condition = !var.app_gateway_enabled || (
        length(trimspace(try(module.compute.hosts["jump"].public_ip, ""))) > 0 &&
        length(trimspace(module.compute.hosts["jump"].admin_username)) > 0 &&
        length(trimspace(module.compute.hosts["lead"].private_ip)) > 0
      )
      error_message = "The shared Ansible inventory requires the Jump public IP, VM admin username, and Lead private IP."
    }
  }

  depends_on = [module.app_gateway, module.compute]
}

resource "local_sensitive_file" "ansible_inventory" {
  count = var.app_gateway_enabled ? 1 : 0

  filename             = "${local.inventory_directory}/00-shared.yml"
  content              = yamlencode(local.ansible_inventory)
  file_permission      = "0600"
  directory_permission = "0700"

  depends_on = [terraform_data.ansible_inventory_guardrails]
}
