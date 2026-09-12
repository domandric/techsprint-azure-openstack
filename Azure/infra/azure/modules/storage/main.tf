locals {
  blob_container_name = "moodle-objects"
  files_share_name    = "moodle"
}

resource "terraform_data" "guardrails" {
  input = var.storage_account_names

  lifecycle {
    precondition {
      condition     = alltrue([for name in values(var.storage_account_names) : can(regex("^[a-z0-9]{3,24}$", name))])
      error_message = "Storage account names must use 3-24 lower-case letters and numbers."
    }

    precondition {
      condition     = try(var.private_dns_zone_ids.blob, null) != null && try(var.private_dns_zone_ids.file, null) != null
      error_message = "Tenant storage requires shared blob and file private DNS zone IDs."
    }
  }
}

resource "azurerm_storage_account" "blob" {
  name                            = var.storage_account_names.blob
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  local_user_enabled              = false
  tags                            = var.tags

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_storage_account" "files" {
  name                            = var.storage_account_names.files
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_kind                    = "FileStorage"
  account_tier                    = "Premium"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = false
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  local_user_enabled              = false
  tags                            = var.tags

  depends_on = [terraform_data.guardrails]
}

resource "azapi_resource" "blob_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2025-06-01"
  name      = local.blob_container_name
  parent_id = "${azurerm_storage_account.blob.id}/blobServices/default"
  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

resource "azapi_resource" "files_share" {
  type      = "Microsoft.Storage/storageAccounts/fileServices/shares@2025-06-01"
  name      = local.files_share_name
  parent_id = "${azurerm_storage_account.files.id}/fileServices/default"
  body = {
    properties = {
      enabledProtocols = "NFS"
      accessTier       = "Premium"
      rootSquash       = "NoRootSquash"
      shareQuota       = 100
    }
  }
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-ts-${var.storage_account_names.blob}-blob"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.blob.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-blob"
    private_dns_zone_ids = [var.private_dns_zone_ids.blob]
  }
}

resource "azurerm_private_endpoint" "files" {
  name                = "pe-ts-${var.storage_account_names.files}-file"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-file"
    private_connection_resource_id = azurerm_storage_account.files.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-file"
    private_dns_zone_ids = [var.private_dns_zone_ids.file]
  }

  depends_on = [azapi_resource.files_share]
}

resource "azurerm_role_assignment" "uami_blob_data" {
  scope                = azurerm_storage_account.blob.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.uami_principal_id
}
