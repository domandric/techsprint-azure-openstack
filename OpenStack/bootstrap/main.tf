locals {
  developers = {
    for slug, user in var.users : slug => user
    if user.role == "developer"
  }

  developer_network_slots = {
    for slug in keys(local.developers) :
    slug => parseint(substr(sha256(slug), 0, 8), 16) % 64
  }

  lead_slug = one([
    for slug, user in var.users : slug
    if user.role == "devops_lead"
  ])

  project_names = merge(
    { shared = "${var.name_seed}-shared" },
    { for slug, user in local.developers : slug => "${var.name_seed}-${slug}" },
  )

  tags = ["project=iruo", "component=bootstrap"]
}

resource "terraform_data" "network_slot_guard" {
  input = local.developer_network_slots

  lifecycle {
    precondition {
      condition     = length(distinct(values(local.developer_network_slots))) == length(local.developer_network_slots)
      error_message = "Derived developer network slots must be unique; change the colliding slugs before creating any resources."
    }
    precondition {
      condition     = terraform.workspace == "default"
      error_message = "The bootstrap root uses the fixed bootstrap.tfstate object and must run in the default workspace."
    }
  }
}

resource "openstack_identity_project_v3" "project" {
  for_each = local.project_names

  depends_on = [terraform_data.network_slot_guard]

  name        = each.value
  domain_id   = var.domain_id
  description = each.key == "shared" ? "IRUO shared control-plane project" : "IRUO developer project for ${each.key}"
  enabled     = true
  tags        = local.tags
}

# Passwords are exposed only through sensitive outputs.
resource "random_password" "human" {
  for_each = var.users

  depends_on = [terraform_data.network_slot_guard]

  length           = 32
  special          = true
  override_special = "!#$%&*+-=?@^_"

  lifecycle {
    postcondition {
      condition     = !strcontains(self.result, "'")
      error_message = "Generated human passwords must not contain a single quote because they are rendered in the Lead OpenRC."
    }
  }
}

resource "random_password" "database" {
  for_each = local.developers

  depends_on = [terraform_data.network_slot_guard]

  length           = 32
  special          = true
  override_special = "!#$%&*+-=?@^_"

  lifecycle {
    postcondition {
      condition     = !strcontains(self.result, "'")
      error_message = "Generated database passwords must not contain a single quote because they are rendered in SQL cloud-init."
    }
  }
}

resource "openstack_identity_user_v3" "user" {
  for_each = var.users

  depends_on = [terraform_data.network_slot_guard]

  name      = "usr-${var.name_seed}-${each.key}"
  domain_id = var.domain_id
  # Lead uses the shared project; developers use their own projects.
  default_project_id = each.value.role == "devops_lead" ? openstack_identity_project_v3.project["shared"].id : openstack_identity_project_v3.project[each.key].id
  description        = "${each.value.first_name} ${each.value.last_name} (${each.value.role})"
  enabled            = true
  password           = random_password.human[each.key].result
  extra = {
    email = each.value.email
  }
}

resource "openstack_identity_group_v3" "developer" {
  for_each = local.developers

  depends_on = [terraform_data.network_slot_guard]

  name        = "grp-${var.name_seed}-${each.key}"
  domain_id   = var.domain_id
  description = "IRUO developer group for ${each.key}"
}

resource "openstack_identity_group_v3" "lead" {
  depends_on = [terraform_data.network_slot_guard]

  name        = "grp-${var.name_seed}-leads"
  domain_id   = var.domain_id
  description = "IRUO cross-project lead group"
}

resource "openstack_identity_user_membership_v3" "developer" {
  for_each = local.developers

  depends_on = [terraform_data.network_slot_guard]

  user_id  = openstack_identity_user_v3.user[each.key].id
  group_id = openstack_identity_group_v3.developer[each.key].id
}

resource "openstack_identity_user_membership_v3" "lead" {
  depends_on = [terraform_data.network_slot_guard]

  user_id  = openstack_identity_user_v3.user[local.lead_slug].id
  group_id = openstack_identity_group_v3.lead.id
}

# Use standard Keystone roles; no custom role is required.
data "openstack_identity_role_v3" "member" {
  name = var.member_role_name
}

data "openstack_identity_role_v3" "admin" {
  name = var.admin_role_name
}

resource "openstack_identity_role_assignment_v3" "developer_member" {
  for_each = local.developers

  depends_on = [terraform_data.network_slot_guard]

  group_id   = openstack_identity_group_v3.developer[each.key].id
  project_id = openstack_identity_project_v3.project[each.key].id
  role_id    = data.openstack_identity_role_v3.member.id
}

# Grant the lead group cross-project access without a custom role.
resource "openstack_identity_role_assignment_v3" "lead_member" {
  for_each = local.project_names

  depends_on = [terraform_data.network_slot_guard]

  group_id   = openstack_identity_group_v3.lead.id
  project_id = openstack_identity_project_v3.project[each.key].id
  role_id    = data.openstack_identity_role_v3.member.id
}

resource "openstack_identity_role_assignment_v3" "provisioner_admin" {
  for_each = local.project_names

  depends_on = [terraform_data.network_slot_guard]

  user_id    = var.provisioner_user_id
  project_id = openstack_identity_project_v3.project[each.key].id
  role_id    = data.openstack_identity_role_v3.admin.id
}

resource "openstack_compute_flavor_v2" "flavor" {
  for_each = var.flavors

  depends_on = [terraform_data.network_slot_guard]

  name      = each.value.name
  vcpus     = each.value.vcpus
  ram       = each.value.ram_mib
  disk      = each.value.disk_gb
  is_public = true
}
