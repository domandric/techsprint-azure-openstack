output "storage" {
  description = "Non-secret storage topology for Ansible inventory."
  value = {
    files = {
      account_id                    = azurerm_storage_account.files.id
      account_name                  = azurerm_storage_account.files.name
      endpoint                      = "${azurerm_storage_account.files.name}.file.core.windows.net"
      private_endpoint_id           = azurerm_private_endpoint.files.id
      public_network_access_enabled = false
      protocol                      = "NFSv4.1"
      authorization                 = "AUTH_SYS"
    }
    blob = {
      account_id                    = azurerm_storage_account.blob.id
      account_name                  = azurerm_storage_account.blob.name
      endpoint                      = "${azurerm_storage_account.blob.name}.blob.core.windows.net"
      private_endpoint_id           = azurerm_private_endpoint.blob.id
      public_network_access_enabled = false
    }
    files_share_name    = local.files_share_name
    blob_container_name = local.blob_container_name
  }
}

output "mount_targets" {
  value = {
    files = "${azurerm_storage_account.files.name}.file.core.windows.net"
    blob  = "${azurerm_storage_account.blob.name}.blob.core.windows.net"
  }
}

output "role_assignment_ids" {
  value = [
    azurerm_role_assignment.uami_blob_data.id,
  ]
}
