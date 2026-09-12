tenant_networks = {
  luka-lukic = {
    slug         = "luka-lukic"
    network_slot = 10
    vnet_id      = "/subscriptions/REPLACE/resourceGroups/rg-ts-luka-lukic-testing-weu/providers/Microsoft.Network/virtualNetworks/vnet-ts-luka-lukic-testing-weu"
  }
  iva-ivic = {
    slug         = "iva-ivic"
    network_slot = 11
    vnet_id      = "/subscriptions/REPLACE/resourceGroups/rg-ts-iva-ivic-testing-weu/providers/Microsoft.Network/virtualNetworks/vnet-ts-iva-ivic-testing-weu"
  }
}

tenant_backends = {
  luka-lukic = {
    slug             = "luka-lukic"
    network_slot     = 10
    app01_private_ip = "10.20.40.10"
    app02_private_ip = "10.20.40.11"
  }
  iva-ivic = {
    slug             = "iva-ivic"
    network_slot     = 11
    app01_private_ip = "10.20.44.10"
    app02_private_ip = "10.20.44.11"
  }
}

app_gateway_enabled = true
