output "tags" {
  description = "Mandatory version-1 Azure tags."
  value       = local.tags
}

output "location_short_name" {
  description = "Resolved short location suffix used in every resource name in this and every dependent module (never null; see terraform_data.guardrails)."
  value       = local.location_short_name
}

output "resource_group_name" {
  value = var.scope == "state" ? "rg-ts-state-testing-${local.location_short_name}" : (
    var.scope == "shared" ? "rg-ts-shared-testing-${local.location_short_name}" : "rg-ts-${var.slug}-testing-${local.location_short_name}"
  )
}

output "vnet_name" {
  value = "vnet-ts-${local.vnet_scope_name}-testing-${local.location_short_name}"
}

output "app_gateway_name" {
  value = "agw-ts-shared-testing-${local.location_short_name}"
}

output "vm_names" {
  value = {
    jump  = "vm-ts-shared-jump-testing-${local.location_short_name}"
    lead  = "vm-ts-shared-lead-testing-${local.location_short_name}"
    app01 = var.slug == null ? null : "vm-ts-${var.slug}-app01-testing-${local.location_short_name}"
    app02 = var.slug == null ? null : "vm-ts-${var.slug}-app02-testing-${local.location_short_name}"
  }
}

output "storage_account_names" {
  value = {
    blob  = "stts${local.storage_slug}b${local.storage_blob_hash}"
    files = "stts${local.storage_slug}f${local.storage_files_hash}"
  }
}

output "shared_mysql_name" {
  description = "One collision-safe shared MySQL Flexible Server name, stable for the shared name_seed. Developer naming scopes intentionally have no MySQL server name."
  value       = var.scope == "shared" ? "mysql-ts-shared-${local.base_hash}" : null
}

output "entra_developer_group_name" {
  value = var.slug == null ? null : "grp-ts-dev-${var.slug}"
}

output "entra_leads_group_name" {
  value = "grp-ts-devops-leads"
}

output "addresses" {
  value = {
    hub                    = "10.10.0.0/16"
    jump_subnet            = "10.10.0.0/24"
    lead_subnet            = "10.10.1.0/24"
    app_gateway_subnet     = "10.10.2.0/24"
    mysql_subnet_shared    = "10.10.3.0/24"
    jump_private_ip        = "10.10.0.10"
    lead_private_ip        = "10.10.1.10"
    app_gateway_private_ip = "10.10.2.10"
    developer_spoke        = local.spoke_cidr
    developer_app_subnet   = local.app_subnet_cidr
    developer_pe_subnet    = local.pe_subnet_cidr
    developer_mysql_subnet = local.mysql_subnet_cidr
    developer_reserved_2   = local.reserved_2_cidr
  }
}
