# Foundation resources only; access links are added after workspaces exist.

locals {
  tags = ["project=iruo", "component=shared"]
  metadata = {
    project   = "iruo"
    component = "shared"
  }

  project_ids_for_template = join("\n", [
    for project_id in var.project_ids : "\"${project_id}\""
  ])

  jump_user_data = templatefile("${var.templates_dir}/jump.yaml.tftpl", {
    developer_ssh_public_keys = var.developer_ssh_public_keys
    developer_slug            = var.lead_slug
    public_key                = var.lead_ssh_public_key
  })

  lead_user_data = templatefile("${var.templates_dir}/lead.yaml.tftpl", {
    auth_url       = var.auth_url
    domain_id      = var.domain_id
    password       = var.lead_password
    private_key    = var.lead_ssh_private_key
    project_ids    = local.project_ids_for_template
    public_key     = var.lead_ssh_public_key
    region         = var.region
    username       = var.lead_username
    developer_slug = var.lead_slug
  })
}

data "openstack_networking_network_v2" "external" {
  name     = var.external_network_name
  external = true
}

resource "openstack_networking_network_v2" "admin" {
  name           = "${var.name_seed}-admin"
  admin_state_up = true
  tags           = local.tags
}

resource "openstack_networking_subnet_v2" "admin" {
  name            = "${var.name_seed}-admin-subnet"
  network_id      = openstack_networking_network_v2.admin.id
  cidr            = var.admin_cidr
  gateway_ip      = cidrhost(var.admin_cidr, 1)
  ip_version      = 4
  enable_dhcp     = true
  dns_nameservers = ["1.1.1.1", "8.8.8.8"]
  tags            = local.tags
}

resource "openstack_networking_router_v2" "admin" {
  name                = "${var.name_seed}-admin-router"
  external_network_id = data.openstack_networking_network_v2.external.id
  enable_snat         = true
  tags                = local.tags

  timeouts {
    create = "10m"
    delete = "10m"
  }
}

resource "openstack_networking_router_interface_v2" "admin" {
  router_id = openstack_networking_router_v2.admin.id
  subnet_id = openstack_networking_subnet_v2.admin.id
}

resource "openstack_networking_secgroup_v2" "jump" {
  name                 = "${var.name_seed}-jump-sg"
  description          = "Restricted SSH to the only public entry host"
  delete_default_rules = true
  tags                 = local.tags
}

resource "openstack_networking_secgroup_rule_v2" "jump_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.allowed_ssh_cidr
  security_group_id = openstack_networking_secgroup_v2.jump.id
}

resource "openstack_networking_secgroup_rule_v2" "jump_egress" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.jump.id
}

resource "openstack_networking_secgroup_v2" "lead" {
  name                 = "${var.name_seed}-lead-sg"
  description          = "Lead SSH from the shared administration subnet"
  delete_default_rules = true
  tags                 = local.tags
}

resource "openstack_networking_secgroup_rule_v2" "lead_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.admin_cidr
  security_group_id = openstack_networking_secgroup_v2.lead.id
}

resource "openstack_networking_secgroup_rule_v2" "lead_egress" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.lead.id
}

resource "openstack_networking_port_v2" "jump" {
  name               = "${var.name_seed}-jump-port"
  network_id         = openstack_networking_network_v2.admin.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.jump.id]
  tags               = local.tags

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.admin.id
    ip_address = cidrhost(var.admin_cidr, 10)
  }
}

resource "openstack_networking_port_v2" "lead" {
  name               = "${var.name_seed}-lead-port"
  network_id         = openstack_networking_network_v2.admin.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.lead.id]
  tags               = local.tags

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.admin.id
    ip_address = cidrhost(var.admin_cidr, 20)
  }
}

resource "openstack_compute_keypair_v2" "lead" {
  name       = "${var.name_seed}-lead"
  public_key = var.lead_ssh_public_key
}

resource "openstack_compute_instance_v2" "jump" {
  name         = "${var.name_seed}-jump"
  image_id     = var.image_id
  flavor_id    = var.flavor_id
  key_pair     = openstack_compute_keypair_v2.lead.name
  config_drive = true
  user_data    = local.jump_user_data
  metadata     = merge(local.metadata, { tier = "entry" })
  tags         = local.tags

  network {
    port = openstack_networking_port_v2.jump.id
  }

  timeouts {
    create = "30m"
    delete = "30m"
  }
}

resource "openstack_compute_instance_v2" "lead" {
  name         = "${var.name_seed}-lead"
  image_id     = var.image_id
  flavor_id    = var.flavor_id
  key_pair     = openstack_compute_keypair_v2.lead.name
  config_drive = true
  user_data    = local.lead_user_data
  metadata     = merge(local.metadata, { tier = "administration" })
  tags         = local.tags

  network {
    port = openstack_networking_port_v2.lead.id
  }

  timeouts {
    create = "30m"
    delete = "30m"
  }
}

resource "openstack_networking_floatingip_v2" "jump" {
  pool        = var.external_network_name
  description = "Only public address in this deployment"
  tags        = local.tags
}

resource "openstack_networking_floatingip_associate_v2" "jump" {
  floating_ip = openstack_networking_floatingip_v2.jump.address
  port_id     = openstack_networking_port_v2.jump.id

  depends_on = [openstack_networking_router_interface_v2.admin]
}
