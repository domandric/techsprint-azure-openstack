locals {
  public_hosts = {
    for key, host in var.hosts : key => host if host.public_ip_enabled
  }

  data_disk_hosts = {
    for key, host in var.hosts : key => host if host.data_disk_enabled
  }

  distinct_vm_sizes = distinct([for host in values(var.hosts) : host.size])

  asg_associations = {
    for pair in flatten([
      for host_key, host in var.hosts : [
        for idx, asg_id in host.application_security_group_ids : {
          key      = "${host_key}:${idx}"
          host_key = host_key
          asg_id   = asg_id
        }
      ]
    ]) : pair.key => pair
  }
}

resource "terraform_data" "guardrails" {
  input = keys(var.hosts)

  lifecycle {
    precondition {
      condition     = length(local.public_hosts) <= 1
      error_message = "This module permits at most one public IP; Azure assigns it only to the shared Jump VM."
    }

    precondition {
      condition     = alltrue([for host in values(var.hosts) : length(host.ssh_public_keys) > 0 && alltrue([for key in values(host.ssh_public_keys) : length(trimspace(key)) > 0])])
      error_message = "Every VM must receive at least one non-empty public SSH key; passwords are never supported."
    }

    precondition {
      condition     = length(local.distinct_vm_sizes) <= 1
      error_message = "Every host in a single compute module invocation must use the exact same resolved VM SKU; found ${length(local.distinct_vm_sizes)} distinct sizes (${join(", ", local.distinct_vm_sizes)}). Rerun scripts/Resolve-AzureDeploymentProfile.ps1 and pass its single resolved var.vm_sku to every host -- do not hand-mix VM sizes within one invocation even if each individual size is separately approved."
    }
  }
}

resource "azurerm_public_ip" "host" {
  for_each = local.public_hosts

  name                = "pip-ts-shared-jump-testing-${var.location_short_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = each.key == "jump"
      error_message = "The only permitted public IP is the Jump host public IP."
    }
  }
}

resource "azurerm_network_interface" "host" {
  for_each = var.hosts

  name                           = "nic-${each.value.name}"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = each.value.ip_forwarding_enabled
  accelerated_networking_enabled = false
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig-primary"
    subnet_id                     = each.value.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
    public_ip_address_id          = try(azurerm_public_ip.host[each.key].id, null)
  }

  depends_on = [terraform_data.guardrails]
}

resource "azurerm_network_interface_application_security_group_association" "host" {
  for_each = local.asg_associations

  network_interface_id          = azurerm_network_interface.host[each.value.host_key].id
  application_security_group_id = each.value.asg_id
}

resource "azurerm_linux_virtual_machine" "host" {
  for_each = var.hosts

  name                            = each.value.name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = each.value.size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.host[each.key].id]
  zone                            = try(each.value.zone, null)
  custom_data = base64encode(join("\n", [
    "#cloud-config",
    yamlencode({
      hostname       = each.value.name
      ssh_pwauth     = false
      package_update = false
      packages       = ["python3"]
      write_files = [{
        path        = "/etc/azure-role"
        permissions = "0644"
        content     = each.value.cloud_init_role
      }]
    })
  ]))
  tags = var.tags

  dynamic "admin_ssh_key" {
    for_each = each.value.ssh_public_keys
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  source_image_reference {
    publisher = var.rocky_image.publisher
    offer     = var.rocky_image.offer
    sku       = var.rocky_image.sku
    version   = var.rocky_image.version
  }

  plan {
    publisher = var.rocky_image.publisher
    product   = var.rocky_image.offer
    name      = var.rocky_image.sku
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 32
  }

  dynamic "identity" {
    for_each = length(each.value.user_assigned_identity_ids) > 0 ? [each.value.user_assigned_identity_ids] : []
    content {
      type         = "UserAssigned"
      identity_ids = identity.value
    }
  }

  lifecycle {
    precondition {
      condition     = contains(var.approved_vm_skus, each.value.size)
      error_message = "VM size '${each.value.size}' for host '${each.key}' is not in the resolved approved_vm_skus list (${join(", ", var.approved_vm_skus)}). Rerun the one-shot deploy so scripts/Resolve-AzureDeploymentProfile.ps1 re-resolves a subscription-available SKU; never hand-edit a VM size outside that resolved profile."
    }

    precondition {
      condition     = each.key != "app01" || each.value.zone == "1"
      error_message = "Azure app01 is frozen in Availability Zone 1."
    }

    precondition {
      condition     = each.key != "app02" || each.value.zone == "2"
      error_message = "Azure app02 is frozen in Availability Zone 2."
    }
  }
}

resource "azurerm_managed_disk" "data" {
  for_each = local.data_disk_hosts

  name                 = "disk-${each.value.name}-data"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 32
  zone                 = try(each.value.zone, null)
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each = local.data_disk_hosts

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.host[each.key].id
  lun                = 0
  caching            = "ReadWrite"
}
