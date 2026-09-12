resource "terraform_data" "consistency_guard" {
  input = {
    tenant_identity = var.tenants
    name_seed       = var.name_seed
    jump_server_id  = var.jump_server_id
    jump_sg_id      = var.jump_security_group_id
  }

  lifecycle {
    precondition {
      condition     = alltrue([for slug, tenant in var.tenants : slug == tenant.developer_slug])
      error_message = "Each shared-reconcile tenant map key must equal the developer_slug in that developer state's tenant output."
    }
    precondition {
      condition     = alltrue([for tenant in values(var.tenants) : tenant.name_seed == var.name_seed])
      error_message = "Every developer tenant name_seed must equal the shared foundation name_seed before management ports are created."
    }
  }
}

resource "openstack_networking_port_v2" "jump_management" {
  for_each = var.tenants

  depends_on = [terraform_data.consistency_guard]

  name                  = "${var.name_seed}-${each.key}-jump-management"
  network_id            = each.value.network_id
  admin_state_up        = true
  port_security_enabled = true
  security_group_ids    = [var.jump_security_group_id]
  tags                  = ["project=iruo", "component=shared-reconcile", "developer=${each.key}"]

  fixed_ip {
    subnet_id  = each.value.subnet_id
    ip_address = cidrhost(each.value.tenant_cidr, 5)
  }
}

resource "openstack_compute_interface_attach_v2" "jump_management" {
  for_each = var.tenants

  depends_on = [terraform_data.consistency_guard]

  instance_id = var.jump_server_id
  port_id     = openstack_networking_port_v2.jump_management[each.key].id
}
