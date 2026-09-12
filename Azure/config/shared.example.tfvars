subscription_id  = "00000000-0000-0000-0000-000000000000"
location            = "swedencentral"
location_short_name = "swc"
vm_sku              = "Standard_B2s"
name_seed        = "replace-with-a-stable-non-secret-seed"
allowed_ssh_cidr = "0.0.0.0/0"
entra_mode       = "existing"

rocky_image = {
  publisher = "resf"
  offer     = "rockylinux-x86_64"
  sku       = "10-lvm"
  version   = "REPLACE_WITH_PINNED_ROCKY_10_VERSION"
}

users = {
  lead = {
    slug = "ana-anic"
    rola = "devops_lead"
    upn  = "ana.anic@tenant.example"
  }
  developers = [
    {
      slug         = "luka-lukic"
      rola         = "developer"
      upn          = "luka.lukic@tenant.example"
      network_slot = 10
    },
    {
      slug         = "iva-ivic"
      rola         = "developer"
      upn          = "iva.ivic@tenant.example"
      network_slot = 11
    },
  ]
}

lead_ssh_public_key = "ssh-ed25519 REPLACE_WITH_PUBLIC_KEY ana-anic"

tenant_networks     = {}
tenant_backends     = {}
app_gateway_enabled = false
