output "tenant" {
  description = "Exact shared-reconcile tenant object for this developer workspace."
  value = {
    project_id     = module.workspace.project_id
    developer_slug = module.workspace.developer_slug
    name_seed      = module.workspace.name_seed
    network_id     = module.workspace.network_id
    subnet_id      = module.workspace.subnet_id
    tenant_cidr    = module.workspace.tenant_cidr
  }
}

output "lb_id" {
  description = "Developer-scoped OVN load balancer ID."
  value       = module.workspace.lb_id
}

output "listener_id" {
  description = "Developer-scoped TCP/80 listener ID."
  value       = module.workspace.listener_id
}

output "pool_id" {
  description = "Developer-scoped TCP SOURCE_IP_PORT pool ID."
  value       = module.workspace.pool_id
}

output "member_ids" {
  description = "Developer-scoped TCP pool member IDs in app01/app02 order."
  value       = module.workspace.member_ids
}

output "vip_address" {
  description = "Developer-scoped OVN load balancer VIP."
  value       = module.workspace.vip_address
}

output "load_balancer" {
  description = "Nonsecret identifiers and VIP for the developer-scoped OVN load balancer."
  value = {
    lb_id       = module.workspace.lb_id
    listener_id = module.workspace.listener_id
    pool_id     = module.workspace.pool_id
    member_ids  = module.workspace.member_ids
    vip_address = module.workspace.vip_address
  }
}

output "server_ids" {
  description = "Developer VM IDs keyed by db, app1, and app2."
  value       = module.workspace.server_ids
}

output "volume_ids" {
  description = "Developer Cinder data volume IDs."
  value       = module.workspace.volume_ids
}

output "dataroot_volume_ids" {
  description = "Independent app Moodle dataroot Cinder volume IDs keyed by app01 and app02."
  value       = module.workspace.dataroot_volume_ids
}
