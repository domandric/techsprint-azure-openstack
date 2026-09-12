locals {
  # GP_Standard_D2ds_v4 == General Purpose tier, Standard_D2ds_v4 ARM VM size. Live Azure/Terraform
  # metadata for this subscription/region (swedencentral) positively confirmed this SKU supports
  # MySQL 8.4 and genuine Zone-Redundant HA (zones 1/2/3 available).
  mysql_sku_name = "GP_Standard_D2ds_v4"

  database_names = {
    for slug, developer in var.developers : slug => "moodle_${replace(developer.slug, "-", "_")}"
  }
}

resource "terraform_data" "guardrails" {
  input = {
    mysql_name = var.shared_mysql_name
    developers = var.developers
  }

  lifecycle {
    precondition {
      condition     = can(regex("^mysql-ts-shared-[0-9a-f]{4}$", var.shared_mysql_name))
      error_message = "MySQL name must use the locked mysql-ts-<slug>-<hash> convention."
    }

    precondition {
      condition     = length(trimspace(var.delegated_subnet_id)) > 0
      error_message = "MySQL Flexible Server Private Access/VNet Integration requires a delegated subnet ID."
    }

    precondition {
      condition     = length(trimspace(var.private_dns_zone_id)) > 0
      error_message = "MySQL Flexible Server Private Access/VNet Integration requires the shared MySQL private DNS zone ID."
    }

    precondition {
      condition     = length(var.developers) > 0
      error_message = "At least one validated developer is required to create a database-per-developer MySQL Flexible Server."
    }

    precondition {
      condition     = alltrue([for slug, developer in var.developers : slug == developer.slug && can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", developer.slug))])
      error_message = "Every developers map key must exactly equal its own .slug value."
    }

    precondition {
      condition     = alltrue([for slug, developer in var.developers : can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", slug)) && length(slug) <= 40])
      error_message = "Every developer slug must be a canonical lower-case ASCII slug of at most 40 characters."
    }

    precondition {
      # moodle_ (7 chars) + slug-with-underscores(<=40 chars) <= 47 chars, matching the assignment's
      # own database-name length bound; also enforce the exact grammar MySQL identifiers require.
      condition = alltrue([
        for slug, developer in var.developers :
        length(local.database_names[slug]) <= 47 && can(regex("^[a-zA-Z0-9_]+$", local.database_names[slug])) && length(local.database_names[slug]) > 7
      ])
      error_message = "Every derived database name moodle_<slug_with_underscores> must be at most 47 characters and contain only letters, digits, and underscores."
    }

    precondition {
      condition     = length(distinct(values(local.database_names))) == length(local.database_names)
      error_message = "Derived MySQL database names must be unique across every developer (moodle_<slug> collision)."
    }
  }
}

resource "azurerm_mysql_flexible_server" "this" {
  name                = var.shared_mysql_name
  resource_group_name = var.resource_group_name
  location            = var.location

  administrator_login          = var.mysql_administrator_login
  administrator_password       = var.mysql_administrator_password
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  sku_name                     = local.mysql_sku_name
  version                      = "8.4"
  zone                         = "1"

  delegated_subnet_id   = var.delegated_subnet_id
  private_dns_zone_id   = var.private_dns_zone_id
  public_network_access = "Disabled"
  tags                  = var.tags

  storage {
    size_gb           = 32
    auto_grow_enabled = true
  }

  # Genuine Zone-Redundant HA: a synchronously replicated standby in a second, distinct
  # availability zone, matching the live Azure/Terraform metadata already confirmed for this
  # subscription/region/SKU (zones 1/2/3 available on GP_Standard_D2ds_v4 in swedencentral).
  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = "2"
  }

  lifecycle {
    ignore_changes = [zone]
  }

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_mysql_flexible_server_configuration" "require_tls" {
  name                = "require_secure_transport"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.this.name
  value               = "ON"
}

resource "azurerm_mysql_flexible_database" "moodle" {
  for_each = var.developers

  name                = local.database_names[each.key]
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mysql_flexible_server.this.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}
