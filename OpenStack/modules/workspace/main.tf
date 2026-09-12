locals {
  prefix             = "${var.name_seed}-${var.developer_slug}"
  tenant_cidr        = "10.210.${var.network_slot}.0/24"
  gateway_ip         = "10.210.${var.network_slot}.1"
  app_ips            = ["10.210.${var.network_slot}.10", "10.210.${var.network_slot}.11"]
  db_ip              = "10.210.${var.network_slot}.20"
  jump_management_ip = cidrhost(local.tenant_cidr, 5)
  tags               = ["project=iruo", "environment=testing", "developer=${var.developer_slug}"]
  metadata = {
    project     = "iruo"
    environment = "testing"
    developer   = var.developer_slug
  }

  # Derive the packaging branch from the validated numeric Moodle version,
  # e.g. "5.2.2" becomes "stable502".
  moodle_version_parts = split(".", var.moodle_version)
  moodle_branch        = "stable${local.moodle_version_parts[0]}${format("%02d", tonumber(local.moodle_version_parts[1]))}"
}

resource "openstack_networking_network_v2" "developer" {
  name           = "${local.prefix}-net"
  admin_state_up = true
  tags           = local.tags
}

resource "openstack_networking_rbac_policy_v2" "developer_network_shared" {
  action        = "access_as_shared"
  object_id     = openstack_networking_network_v2.developer.id
  object_type   = "network"
  target_tenant = var.shared_project_id
}

resource "openstack_networking_subnet_v2" "developer" {
  name            = "${local.prefix}-subnet"
  network_id      = openstack_networking_network_v2.developer.id
  cidr            = local.tenant_cidr
  gateway_ip      = local.gateway_ip
  ip_version      = 4
  enable_dhcp     = true
  dns_nameservers = var.dns_nameservers
  tags            = local.tags
}

resource "openstack_networking_router_v2" "developer" {
  name = "${local.prefix}-router"
  tags = local.tags

  external_network_id = data.openstack_networking_network_v2.external.id
  enable_snat         = true
}

data "openstack_networking_network_v2" "external" {
  name     = var.external_network_name
  external = true
}

resource "openstack_networking_router_interface_v2" "developer" {
  router_id = openstack_networking_router_v2.developer.id
  subnet_id = openstack_networking_subnet_v2.developer.id
}

resource "openstack_networking_secgroup_v2" "app" {
  name                 = "${local.prefix}-app-sg"
  description          = "HTTP from the developer subnet and SSH only from the direct Jump management NIC"
  delete_default_rules = true
  tags                 = local.tags
}

resource "openstack_networking_secgroup_rule_v2" "app_ssh_from_jump" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "${local.jump_management_ip}/32"
  security_group_id = openstack_networking_secgroup_v2.app.id
}

resource "openstack_networking_secgroup_rule_v2" "app_http_from_admin" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = local.tenant_cidr
  security_group_id = openstack_networking_secgroup_v2.app.id
}

resource "openstack_networking_secgroup_rule_v2" "app_egress" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.app.id
}

resource "openstack_networking_secgroup_v2" "db" {
  name                 = "${local.prefix}-db-sg"
  description          = "MariaDB from the developer subnet and SSH only from the direct Jump management NIC"
  delete_default_rules = true
  tags                 = local.tags
}

resource "openstack_networking_secgroup_rule_v2" "db_mysql_from_tenant" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 3306
  port_range_max    = 3306
  remote_ip_prefix  = local.tenant_cidr
  security_group_id = openstack_networking_secgroup_v2.db.id
}

resource "openstack_networking_secgroup_rule_v2" "db_ssh_from_jump" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "${local.jump_management_ip}/32"
  security_group_id = openstack_networking_secgroup_v2.db.id
}

resource "openstack_networking_secgroup_rule_v2" "db_egress" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.db.id
}

resource "openstack_networking_port_v2" "app" {
  count              = 2
  name               = "${local.prefix}-app0${count.index + 1}-port"
  network_id         = openstack_networking_network_v2.developer.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.app.id]
  tags               = local.tags

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.developer.id
    ip_address = local.app_ips[count.index]
  }
}

resource "openstack_networking_port_v2" "db" {
  name               = "${local.prefix}-db-port"
  network_id         = openstack_networking_network_v2.developer.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.db.id]
  tags               = local.tags

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.developer.id
    ip_address = local.db_ip
  }
}

resource "openstack_lb_loadbalancer_v2" "developer" {
  name                  = "lb-${local.prefix}"
  vip_subnet_id         = openstack_networking_subnet_v2.developer.id
  vip_address           = cidrhost(local.tenant_cidr, 50)
  loadbalancer_provider = "ovn"
  tags                  = local.tags
}

resource "openstack_lb_listener_v2" "tcp" {
  name            = "listener-${local.prefix}-tcp"
  loadbalancer_id = openstack_lb_loadbalancer_v2.developer.id
  protocol        = "TCP"
  protocol_port   = 80
}

resource "openstack_lb_pool_v2" "tcp" {
  name        = "pool-${local.prefix}-tcp"
  listener_id = openstack_lb_listener_v2.tcp.id
  protocol    = "TCP"
  lb_method   = "SOURCE_IP_PORT"
}

resource "openstack_lb_member_v2" "app" {
  count = 2

  name          = "member-${local.prefix}-app0${count.index + 1}"
  pool_id       = openstack_lb_pool_v2.tcp.id
  address       = local.app_ips[count.index]
  protocol_port = 80
  subnet_id     = openstack_networking_subnet_v2.developer.id
}

resource "openstack_blockstorage_volume_v3" "data" {
  for_each = toset(["db", "app01", "app02"])

  name        = "${local.prefix}-${each.key}-data"
  size        = var.data_volume_size
  volume_type = var.volume_type
  description = "IRUO application/database data disk"
  metadata    = local.metadata
}

resource "openstack_blockstorage_volume_v3" "dataroot" {
  for_each = toset(["app01", "app02"])

  name        = "${local.prefix}-${each.key}-dataroot"
  size        = var.data_volume_size
  volume_type = var.volume_type
  description = "IRUO application Moodle dataroot disk"
  metadata    = local.metadata
}

resource "openstack_compute_instance_v2" "db" {
  name         = "${local.prefix}-db"
  image_id     = var.image_id
  flavor_id    = var.db_flavor_id
  key_pair     = var.keypair_name
  config_drive = true
  user_data = templatefile("${var.templates_dir}/db.yaml.tftpl", {
    db_name         = var.developer_slug
    db_password_b64 = base64encode(var.db_password)
    db_user         = "moodle_${var.developer_slug}"
    developer_slug  = var.developer_slug
    lead_public_key = var.lead_ssh_public_key
    public_key      = var.public_ssh_key
    subnet_prefix   = "10.210.${var.network_slot}"
    volume_device   = "/dev/vdb"
  })
  metadata = merge(local.metadata, { tier = "database" })
  tags     = local.tags

  network {
    port = openstack_networking_port_v2.db.id
  }

  depends_on = [openstack_networking_router_interface_v2.developer]
}

resource "openstack_compute_volume_attach_v2" "db" {
  instance_id = openstack_compute_instance_v2.db.id
  volume_id   = openstack_blockstorage_volume_v3.data["db"].id
  device      = "/dev/vdb"
}

resource "openstack_compute_instance_v2" "app" {
  count        = 2
  name         = "${local.prefix}-app0${count.index + 1}"
  image_id     = var.image_id
  flavor_id    = var.app_flavor_id
  key_pair     = var.keypair_name
  config_drive = true
  user_data = templatefile("${var.templates_dir}/app.yaml.tftpl", {
    app_index              = count.index + 1
    base_domain            = var.base_domain
    db_host                = local.db_ip
    db_name                = var.developer_slug
    db_password_b64        = base64encode(var.db_password)
    db_user                = "moodle_${var.developer_slug}"
    developer_slug         = var.developer_slug
    lead_public_key        = var.lead_ssh_public_key
    moodle_branch          = local.moodle_branch
    moodle_sha256          = var.moodle_sha256
    moodle_version         = var.moodle_version
    public_key             = var.public_ssh_key
    dataroot_volume_device = "/dev/vdc"
    volume_device          = "/dev/vdb"
  })
  metadata = merge(local.metadata, { tier = "application", app_index = tostring(count.index + 1) })
  tags     = local.tags

  network {
    port = openstack_networking_port_v2.app[count.index].id
  }

  depends_on = [openstack_networking_router_interface_v2.developer]
}

resource "openstack_compute_volume_attach_v2" "app" {
  for_each = {
    app01 = 0
    app02 = 1
  }

  instance_id = openstack_compute_instance_v2.app[each.value].id
  volume_id   = openstack_blockstorage_volume_v3.data[each.key].id
  device      = "/dev/vdb"
}

resource "openstack_compute_volume_attach_v2" "app_dataroot" {
  for_each = {
    app01 = 0
    app02 = 1
  }

  instance_id = openstack_compute_instance_v2.app[each.value].id
  volume_id   = openstack_blockstorage_volume_v3.dataroot[each.key].id
  device      = "/dev/vdc"
}
