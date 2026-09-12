output "shared_project_id" {
  description = "ID of the shared control-plane project. Feed this into the provider (tenant_id / OS_PROJECT_ID) used to instantiate modules/platform."
  value       = openstack_identity_project_v3.project["shared"].id
}

output "developer_project_ids" {
  description = "Developer project IDs keyed by CSV slug. Feed into modules/platform (developers map) and into the provider used to instantiate modules/workspace per slug."
  value       = { for slug, project in openstack_identity_project_v3.project : slug => project.id if slug != "shared" }
}

output "project_ids" {
  description = "All project IDs (shared plus every developer) keyed by slug, with \"shared\" as the shared project's key."
  value       = { for slug, project in openstack_identity_project_v3.project : slug => project.id }
}

output "lead_slug" {
  description = "The single validated devops_lead slug from var.users."
  value       = local.lead_slug
}

output "name_seed" {
  description = "Canonical deployment-wide name seed consumed by every downstream root."
  value       = var.name_seed
}

output "developer_network_slots" {
  description = "Deterministic private-network slots keyed by developer slug."
  value       = local.developer_network_slots
}

output "flavor_ids" {
  description = "Flavor IDs keyed by logical role (\"shared\", \"app\", \"database\")."
  value       = { for key, flavor in openstack_compute_flavor_v2.flavor : key => flavor.id }
}

output "flavor_names" {
  description = "Flavor names keyed by logical role, exactly as created."
  value       = { for key, flavor in openstack_compute_flavor_v2.flavor : key => flavor.name }
}

output "credentials" {
  description = "Per-user OpenStack credentials keyed by CSV slug: username, password, default project ID, and role."
  sensitive   = true
  value = {
    for slug, user in openstack_identity_user_v3.user : slug => {
      username   = user.name
      password   = random_password.human[slug].result
      project_id = user.default_project_id
      role       = var.users[slug].role
    }
  }
}

output "usernames" {
  description = "Human OpenStack usernames keyed by CSV slug."
  value       = { for slug, user in openstack_identity_user_v3.user : slug => user.name }
}

output "user_passwords" {
  description = "Sensitive human OpenStack passwords keyed by CSV slug."
  sensitive   = true
  value       = { for slug, password in random_password.human : slug => password.result }
}

output "database_passwords" {
  description = "Sensitive per-developer Moodle database passwords keyed by CSV slug."
  sensitive   = true
  value       = { for slug, password in random_password.database : slug => password.result }
}
