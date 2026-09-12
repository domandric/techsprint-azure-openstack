module "naming" {
  source = "../modules/naming"

  scope               = "developer"
  owner               = var.developer.slug
  slug                = var.developer.slug
  network_slot        = var.developer.network_slot
  name_seed           = var.name_seed
  location            = var.location
  location_short_name = var.location_short_name
}

locals {
  tenant_networks = {
    for slug, developer in var.known_developers : slug => {
      slug         = developer.slug
      network_slot = developer.network_slot
    }
  }

  app_ssh_keys = {
    developer = var.developer_ssh_public_key
    lead      = var.lead_ssh_public_key
  }

  app01_private_ip = cidrhost(module.naming.addresses.developer_app_subnet, 10)
  app02_private_ip = cidrhost(module.naming.addresses.developer_app_subnet, 11)

  # The shared root is the source of truth for database ownership. The exact name remains
  # deterministic, but tenants consume the shared slug -> database-name contract.
  mysql_database_name = var.shared.mysql.database_names[var.developer.slug]

  inventory_directory    = abspath("${path.root}/../../../runtime/ansible/inventory")
  tenant_app_private_ips = [module.compute.hosts["app01"].private_ip, module.compute.hosts["app02"].private_ip]

  ansible_inventory_hosts = {
    (module.naming.vm_names.app01) = {
      ansible_host             = module.compute.hosts["app01"].private_ip
      ansible_ssh_common_args  = format("-o ProxyCommand=\"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -W %%h:%%p %s@%s\"", var.shared.admin_username, var.shared.jump_public_ip)
      tenant_slug              = var.developer.slug
      app_role                 = "app01"
      azure_deployment_id      = format("azure-%s-%d", var.developer.slug, var.developer.network_slot)
      moodle_hostname          = "${var.developer.slug}.moodle.test"
      mysql_fqdn               = var.shared.mysql.fqdn
      mysql_version            = var.shared.mysql.version
      mysql_sku_name           = var.shared.mysql.sku_name
      mysql_sku_tier           = var.shared.mysql.sku_tier
      mysql_high_availability  = var.shared.mysql.high_availability_mode
      mysql_database_name      = local.mysql_database_name
      files_endpoint           = module.storage.storage.files.endpoint
      files_share_name         = module.storage.storage.files_share_name
      files_protocol           = module.storage.storage.files.protocol
      files_authorization      = module.storage.storage.files.authorization
      blob_endpoint            = module.storage.storage.blob.endpoint
      blob_container_name      = module.storage.storage.blob_container_name
      uami_client_id           = azurerm_user_assigned_identity.apps.client_id
      mysql_allowed_client_ips = local.tenant_app_private_ips
      developer_ssh_public_key = var.developer_ssh_public_key
      tenant_app_private_ips   = local.tenant_app_private_ips
    }
    (module.naming.vm_names.app02) = {
      ansible_host             = module.compute.hosts["app02"].private_ip
      ansible_ssh_common_args  = format("-o ProxyCommand=\"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -W %%h:%%p %s@%s\"", var.shared.admin_username, var.shared.jump_public_ip)
      tenant_slug              = var.developer.slug
      app_role                 = "app02"
      azure_deployment_id      = format("azure-%s-%d", var.developer.slug, var.developer.network_slot)
      moodle_hostname          = "${var.developer.slug}.moodle.test"
      mysql_fqdn               = var.shared.mysql.fqdn
      mysql_version            = var.shared.mysql.version
      mysql_sku_name           = var.shared.mysql.sku_name
      mysql_sku_tier           = var.shared.mysql.sku_tier
      mysql_high_availability  = var.shared.mysql.high_availability_mode
      mysql_database_name      = local.mysql_database_name
      files_endpoint           = module.storage.storage.files.endpoint
      files_share_name         = module.storage.storage.files_share_name
      files_protocol           = module.storage.storage.files.protocol
      files_authorization      = module.storage.storage.files.authorization
      blob_endpoint            = module.storage.storage.blob.endpoint
      blob_container_name      = module.storage.storage.blob_container_name
      uami_client_id           = azurerm_user_assigned_identity.apps.client_id
      mysql_allowed_client_ips = local.tenant_app_private_ips
      developer_ssh_public_key = var.developer_ssh_public_key
      tenant_app_private_ips   = local.tenant_app_private_ips
    }
  }

  ansible_inventory = {
    all = {
      children = {
        app = {
          hosts = local.ansible_inventory_hosts
        }
      }
    }
  }
}

resource "terraform_data" "guardrails" {
  input = var.developer.slug

  lifecycle {
    precondition {
      condition     = var.developer.rola == "developer" && can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", var.developer.slug)) && length(var.developer.slug) <= 40
      error_message = "Tenant input must be a canonical developer with a slug no longer than 40 characters."
    }

    precondition {
      condition     = var.developer.network_slot >= 0 && var.developer.network_slot <= 63 && floor(var.developer.network_slot) == var.developer.network_slot
      error_message = "network_slot must be an integer from 0 through 63."
    }

    precondition {
      condition     = contains(keys(var.known_developers), var.developer.slug) && var.known_developers[var.developer.slug].network_slot == var.developer.network_slot
      error_message = "known_developers must contain this developer at its immutable network_slot."
    }

    precondition {
      condition = (
        contains(keys(var.shared.mysql.database_names), var.developer.slug) &&
        var.shared.mysql.database_names[var.developer.slug] == "moodle_${replace(var.developer.slug, "-", "_")}"
      )
      error_message = "Shared MySQL database_names must contain this developer's exact deterministic Moodle database name."
    }

    precondition {
      condition     = length(distinct([for developer in values(var.known_developers) : developer.network_slot])) == length(var.known_developers)
      error_message = "network_slot collisions are a hard failure."
    }

    precondition {
      condition = alltrue([
        for key in values(local.app_ssh_keys) : length(trimspace(key)) > 0 && can(regex("^(ssh-|ecdsa-sha2-|sk-ssh-)", trimspace(key)))
      ])
      error_message = "Both developer and lead public SSH keys must be resolved before tenant compute is planned."
    }

    precondition {
      condition     = module.naming.storage_account_names.blob != module.naming.storage_account_names.files
      error_message = "Locked blob/files storage names must be distinct."
    }
  }
}

resource "azurerm_resource_group" "tenant" {
  name     = module.naming.resource_group_name
  location = var.location
  tags     = module.naming.tags
}

module "network" {
  source = "../modules/network"

  mode                = "tenant"
  name                = module.naming.vnet_name
  resource_group_name = azurerm_resource_group.tenant.name
  location            = azurerm_resource_group.tenant.location
  location_short_name = module.naming.location_short_name
  tags                = module.naming.tags
  network_slot        = var.developer.network_slot
  tenant_slug         = var.developer.slug
  hub_vnet_id         = var.shared.hub_vnet_id
  tenant_networks     = local.tenant_networks

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_user_assigned_identity" "apps" {
  name                = "uami-ts-${var.developer.slug}-apps-testing-${module.naming.location_short_name}"
  resource_group_name = azurerm_resource_group.tenant.name
  location            = azurerm_resource_group.tenant.location
  tags                = module.naming.tags
}

module "compute" {
  source = "../modules/compute"

  resource_group_name = azurerm_resource_group.tenant.name
  location            = azurerm_resource_group.tenant.location
  location_short_name = module.naming.location_short_name
  tags                = module.naming.tags
  rocky_image         = var.rocky_image
  hosts = {
    app01 = {
      name                           = module.naming.vm_names.app01
      private_ip                     = local.app01_private_ip
      subnet_id                      = module.network.tenant.app_subnet_id
      size                           = var.vm_sku
      zone                           = "1"
      data_disk_enabled              = true
      public_ip_enabled              = false
      ip_forwarding_enabled          = false
      application_security_group_ids = [module.network.tenant.app_asg_id]
      user_assigned_identity_ids     = [azurerm_user_assigned_identity.apps.id]
      ssh_public_keys                = local.app_ssh_keys
      cloud_init_role                = "app"
    }
    app02 = {
      name                           = module.naming.vm_names.app02
      private_ip                     = local.app02_private_ip
      subnet_id                      = module.network.tenant.app_subnet_id
      size                           = var.vm_sku
      zone                           = "2"
      data_disk_enabled              = true
      public_ip_enabled              = false
      ip_forwarding_enabled          = false
      application_security_group_ids = [module.network.tenant.app_asg_id]
      user_assigned_identity_ids     = [azurerm_user_assigned_identity.apps.id]
      ssh_public_keys                = local.app_ssh_keys
      cloud_init_role                = "app"
    }
  }

  depends_on = [terraform_data.guardrails]
}

module "storage" {
  source = "../modules/storage"

  resource_group_name        = azurerm_resource_group.tenant.name
  location                   = azurerm_resource_group.tenant.location
  tags                       = module.naming.tags
  storage_account_names      = module.naming.storage_account_names
  private_endpoint_subnet_id = module.network.tenant.private_endpoints_subnet_id
  private_dns_zone_ids       = var.shared.private_dns_zone_ids
  uami_principal_id          = azurerm_user_assigned_identity.apps.principal_id
}

resource "azurerm_role_assignment" "developer_reader" {
  scope                = azurerm_resource_group.tenant.id
  role_definition_name = "Reader"
  principal_id         = var.shared.developer_group_id

  principal_type = "Group"
}

resource "azurerm_role_assignment" "developer_vm_power" {
  scope              = azurerm_resource_group.tenant.id
  role_definition_id = var.shared.custom_role_definition_id
  principal_id       = var.shared.developer_group_id
  principal_type     = "Group"
}

resource "azurerm_role_assignment" "lead_reader" {
  scope                = azurerm_resource_group.tenant.id
  role_definition_name = "Reader"
  principal_id         = var.shared.lead_group_id
  principal_type       = "Group"
}

resource "azurerm_role_assignment" "lead_vm_power" {
  scope              = azurerm_resource_group.tenant.id
  role_definition_id = var.shared.custom_role_definition_id
  principal_id       = var.shared.lead_group_id
  principal_type     = "Group"
}

resource "terraform_data" "ansible_inventory_guardrails" {
  input = {
    app_hosts            = keys(local.ansible_inventory_hosts)
    developer_public_key = var.developer_ssh_public_key
    jump_public_ip       = var.shared.jump_public_ip
    admin_username       = var.shared.admin_username
  }

  lifecycle {
    precondition {
      condition = length(local.ansible_inventory_hosts) == 2 && alltrue([
        for host in values(local.ansible_inventory_hosts) : length(trimspace(host.ansible_host)) > 0
      ])
      error_message = "The tenant Ansible inventory requires exactly two non-empty app host private IPs."
    }

    precondition {
      condition     = length(trimspace(var.developer_ssh_public_key)) > 0 && can(regex("^(ssh-|ecdsa-sha2-|sk-ssh-)", trimspace(var.developer_ssh_public_key)))
      error_message = "The tenant Ansible inventory requires the developer public SSH key; private keys are never accepted."
    }

    precondition {
      condition     = length(trimspace(var.shared.jump_public_ip)) > 0 && length(trimspace(var.shared.admin_username)) > 0
      error_message = "The tenant Ansible inventory requires the shared Jump public IP and VM admin username for ProxyJump."
    }
  }

  depends_on = [module.compute, module.storage]
}

resource "local_sensitive_file" "ansible_inventory" {
  filename             = "${local.inventory_directory}/20-${var.developer.slug}.yml"
  content              = yamlencode(local.ansible_inventory)
  file_permission      = "0600"
  directory_permission = "0700"

  depends_on = [terraform_data.ansible_inventory_guardrails]
}
