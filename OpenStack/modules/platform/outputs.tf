output "shared_project_id" {
  description = "Shared Keystone project ID."
  value       = var.shared_project_id
}

output "name_seed" {
  description = "Canonical deployment-wide resource name seed."
  value       = var.name_seed
}

output "external_network_name" {
  description = "Existing external/provider network name used by shared and developer routers."
  value       = var.external_network_name
}

output "admin_network_id" {
  description = "Shared administration network ID."
  value       = openstack_networking_network_v2.admin.id
}

output "admin_subnet_id" {
  description = "Shared administration subnet ID."
  value       = openstack_networking_subnet_v2.admin.id
}

output "admin_router_id" {
  description = "Shared administration router ID."
  value       = openstack_networking_router_v2.admin.id
}

output "admin_cidr" {
  description = "Shared administration subnet CIDR."
  value       = var.admin_cidr
}

output "keypair_name" {
  description = "Jump and Lead Nova keypair name."
  value       = openstack_compute_keypair_v2.lead.name
}

output "lead_ssh_public_key" {
  description = "Lead public key retained for developer VM administration."
  value       = nonsensitive(var.lead_ssh_public_key)
}

output "jump_fip" {
  description = "Jump floating IP."
  value       = openstack_networking_floatingip_v2.jump.address
}

output "jump_server_id" {
  description = "Existing shared-project Jump server ID for later interface attachments."
  value       = openstack_compute_instance_v2.jump.id
}

output "jump_security_group_id" {
  description = "Shared-project Jump security group ID for direct management ports."
  value       = openstack_networking_secgroup_v2.jump.id
}
