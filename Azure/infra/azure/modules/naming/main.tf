locals {
  project     = "techsprint"
  environment = "testing"
  cloud       = "azure"

  known_region_short_names = {
    westeurope    = "weu"
    swedencentral = "swc"
  }

  location_short_name = var.location_short_name != null ? var.location_short_name : lookup(local.known_region_short_names, var.location, null)

  scope_name      = var.scope == "developer" ? var.slug : var.scope
  vnet_scope_name = var.scope == "shared" ? "hub" : local.scope_name

  base_hash = var.slug == null ? substr(sha256("${var.name_seed}:${var.scope}"), 0, 4) : substr(sha256("${var.name_seed}:${var.slug}"), 0, 4)

  storage_slug = var.slug == null ? "state" : substr(replace(var.slug, "-", ""), 0, 15)
  paas_slug    = var.slug == null ? var.scope : substr(var.slug, 0, 48)

  storage_blob_hash  = var.slug == null ? local.base_hash : substr(sha256("${var.name_seed}:${var.slug}:b"), 0, 4)
  storage_files_hash = var.slug == null ? local.base_hash : substr(sha256("${var.name_seed}:${var.slug}:f"), 0, 4)

  tags = {
    project      = local.project
    environment  = local.environment
    owner        = var.owner
    scope        = var.scope
    "managed-by" = "terraform"
    cloud        = local.cloud
  }

  spoke_third_octet = var.network_slot == null ? null : var.network_slot * 4
  spoke_cidr        = var.network_slot == null ? null : "10.20.${local.spoke_third_octet}.0/22"
  app_subnet_cidr   = var.network_slot == null ? null : "10.20.${local.spoke_third_octet}.0/24"
  pe_subnet_cidr    = var.network_slot == null ? null : "10.20.${local.spoke_third_octet + 1}.0/24"
  mysql_subnet_cidr = var.network_slot == null ? null : "10.20.${local.spoke_third_octet + 2}.0/24"
  reserved_2_cidr   = var.network_slot == null ? null : "10.20.${local.spoke_third_octet + 3}.0/24"
}

resource "terraform_data" "guardrails" {
  input = var.location

  lifecycle {
    precondition {
      condition     = local.location_short_name != null
      error_message = "No known short location suffix for location '${var.location}' (known: ${join(", ", keys(local.known_region_short_names))}). Add it to known_region_short_names in infra/azure/modules/naming/main.tf, or supply location_short_name explicitly."
    }
  }
}
