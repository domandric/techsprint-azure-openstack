location             = "swedencentral"
location_short_name  = "swc"
vm_sku               = "Standard_B2s"
name_seed = "replace-with-the-same-stable-non-secret-seed"

developer = {
  slug         = "luka-lukic"
  rola         = "developer"
  network_slot = 10
}

known_developers = {
  luka-lukic = { slug = "luka-lukic", network_slot = 10 }
  iva-ivic   = { slug = "iva-ivic", network_slot = 11 }
}

shared = {
  hub_vnet_id = "/subscriptions/REPLACE/resourceGroups/rg-ts-shared-testing-weu/providers/Microsoft.Network/virtualNetworks/vnet-ts-hub-testing-weu"
  jump_public_ip = "203.0.113.20"
  admin_username = "azureuser"
  private_dns_zone_ids = {
    blob   = "/subscriptions/REPLACE/resourceGroups/rg-ts-shared-testing-weu/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    file   = "/subscriptions/REPLACE/resourceGroups/rg-ts-shared-testing-weu/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net"
    moodle = "/subscriptions/REPLACE/resourceGroups/rg-ts-shared-testing-weu/providers/Microsoft.Network/privateDnsZones/moodle.test"
  }
  developer_group_id        = "00000000-0000-0000-0000-000000000000"
  lead_group_id             = "00000000-0000-0000-0000-000000000000"
   custom_role_definition_id = "/subscriptions/REPLACE/providers/Microsoft.Authorization/roleDefinitions/REPLACE"
   mysql = {
     fqdn                    = "REPLACE_WITH_SHARED_MYSQL_FQDN"
     version                 = "8.4"
     sku_name                = "GP_Standard_D2ds_v4"
     sku_tier                = "GeneralPurpose"
     high_availability_mode  = "ZoneRedundant"
     administrator_login     = "azure_admin"
     database_names          = {
       luka-lukic = "moodle_luka_lukic"
       iva-ivic   = "moodle_iva_ivic"
     }
   }
 }

developer_ssh_public_key = "ssh-ed25519 REPLACE_WITH_PUBLIC_KEY luka-lukic"
lead_ssh_public_key      = "ssh-ed25519 REPLACE_WITH_PUBLIC_KEY ana-anic"

rocky_image = {
  publisher = "resf"
  offer     = "rockylinux-x86_64"
  sku       = "10-lvm"
  version   = "REPLACE_WITH_PINNED_ROCKY_10_VERSION"
}
