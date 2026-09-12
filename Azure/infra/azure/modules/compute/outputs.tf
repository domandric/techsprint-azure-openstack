output "hosts" {
  description = "Sanitized host topology; never includes SSH public-key text or credentials."
  value = {
    for key, host in azurerm_linux_virtual_machine.host : key => merge(
      {
        id             = host.id
        name           = host.name
        private_ip     = azurerm_network_interface.host[key].private_ip_address
        admin_username = var.admin_username
        size           = host.size
        os             = "rocky-linux-10"
      },
      try(azurerm_public_ip.host[key].ip_address, null) == null ? {} : {
        public_ip = azurerm_public_ip.host[key].ip_address
      },
      try(host.zone, null) == null ? {} : {
        zone = host.zone
      },
      try(azurerm_managed_disk.data[key].id, null) == null ? {} : {
        data_disk_id = azurerm_managed_disk.data[key].id
      },
    )
  }
}

output "public_ip_ids" {
  value = { for key, pip in azurerm_public_ip.host : key => pip.id }
}

output "public_ips" {
  description = "Non-secret public-IP inventory. Guardrails permit only the Jump entry."
  value = {
    for key, pip in azurerm_public_ip.host : key => {
      id         = pip.id
      name       = pip.name
      ip_address = pip.ip_address
    }
  }
}

output "network_interfaces" {
  description = "Non-secret NIC inventory for the root-owned resource manifest."
  value = {
    for key, nic in azurerm_network_interface.host : key => {
      id                          = nic.id
      name                        = nic.name
      private_ip                  = nic.private_ip_address
      subnet_id                   = nic.ip_configuration[0].subnet_id
      public_ip_id                = try(nic.ip_configuration[0].public_ip_address_id, null)
      application_security_groups = var.hosts[key].application_security_group_ids
    }
  }
}

output "os_disks" {
  description = "Provider-exported managed OS-disk IDs and frozen disk properties."
  value = {
    for key, host in azurerm_linux_virtual_machine.host : key => {
      id                   = host.os_disk[0].id
      name                 = host.os_disk[0].name
      storage_account_type = host.os_disk[0].storage_account_type
      disk_size_gb         = host.os_disk[0].disk_size_gb
    }
  }
}

output "asg_association_host_keys" {
  description = <<-EOT
    Maps every azurerm_network_interface_application_security_group_association.host
    for_each instance key (e.g. "app01:0") back to the var.hosts key it
    belongs to (e.g. "app01"). Every value here is derived only from
    var.hosts' own map keys and each host's application_security_group_ids
    list index -- never from an ASG id, which may legitimately still be
    unknown until apply (e.g. a brand-new spoke's ASG created in the same
    plan as its app VMs). This output is therefore always fully known at
    plan time and allows callers one level up to consume the association
    for_each map's instance keys without needing this module's own internal
    resource addresses to be reachable from a parent root.
  EOT
  value       = { for key, pair in local.asg_associations : key => pair.host_key }
}

output "data_disks" {
  description = "Provider-exported managed application data-disk IDs and frozen disk properties."
  value = {
    for key, disk in azurerm_managed_disk.data : key => {
      id                   = disk.id
      name                 = disk.name
      storage_account_type = disk.storage_account_type
      disk_size_gb         = disk.disk_size_gb
    }
  }
}
