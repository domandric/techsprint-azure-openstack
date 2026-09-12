output "shared_project_id" {
  value = module.platform.shared_project_id
}

output "name_seed" {
  description = "Canonical deployment-wide name seed from bootstrap state."
  value       = module.platform.name_seed
}

output "external_network_name" {
  description = "Existing external/provider network name for developer router gateways."
  value       = module.platform.external_network_name
}

output "admin_network_id" {
  value = module.platform.admin_network_id
}

output "admin_subnet_id" {
  value = module.platform.admin_subnet_id
}

output "admin_router_id" {
  value = module.platform.admin_router_id
}

output "admin_cidr" {
  value = module.platform.admin_cidr
}

output "keypair_name" {
  value = module.platform.keypair_name
}

output "lead_ssh_public_key" {
  description = "Lead public key retained for developer VM administration."
  value       = module.platform.lead_ssh_public_key
}

output "jump_fip" {
  value = module.platform.jump_fip
}

output "jump_server_id" {
  description = "Existing shared-project Jump server ID for later interface attachments."
  value       = module.platform.jump_server_id
}

output "jump_security_group_id" {
  description = "Shared-project Jump security group ID for direct management ports."
  value       = module.platform.jump_security_group_id
}
