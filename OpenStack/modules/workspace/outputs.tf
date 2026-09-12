output "project_id" {
  description = "Developer project ID supplied by the caller/provider scope."
  value       = var.project_id
}

output "developer_slug" {
  description = "Stable developer slug bound to this tenant."
  value       = var.developer_slug
}

output "name_seed" {
  description = "Canonical deployment-wide name seed used by this tenant."
  value       = var.name_seed
}

output "network_id" {
  description = "ID of the developer private network."
  value       = openstack_networking_network_v2.developer.id
}

output "subnet_id" {
  description = "ID of the developer private subnet."
  value       = openstack_networking_subnet_v2.developer.id
}

output "tenant_cidr" {
  description = "CIDR of the developer private subnet."
  value       = local.tenant_cidr
}

output "subnet_cidr" {
  description = "Compatibility alias for tenant_cidr."
  value       = local.tenant_cidr
}

output "app_ips" {
  description = "Fixed app IPs in app01/app02 order."
  value       = local.app_ips
}

output "app_port_ids" {
  description = "App port IDs in app01/app02 order."
  value       = openstack_networking_port_v2.app[*].id
}

output "lb_id" {
  description = "Developer-scoped OVN load balancer ID."
  value       = openstack_lb_loadbalancer_v2.developer.id
}

output "listener_id" {
  description = "Developer-scoped TCP/80 listener ID."
  value       = openstack_lb_listener_v2.tcp.id
}

output "pool_id" {
  description = "Developer-scoped TCP SOURCE_IP_PORT pool ID."
  value       = openstack_lb_pool_v2.tcp.id
}

output "member_ids" {
  description = "Developer-scoped TCP pool member IDs in app01/app02 order."
  value       = openstack_lb_member_v2.app[*].id
}

output "vip_address" {
  description = "Developer-scoped OVN load balancer VIP."
  value       = cidrhost(local.tenant_cidr, 50)
}

output "db_ip" {
  description = "Fixed IP of the standalone database VM."
  value       = local.db_ip
}

output "server_ids" {
  description = "Instance IDs keyed by database and app names."
  value = {
    db   = try(openstack_compute_instance_v2.db.id, null)
    app1 = try(openstack_compute_instance_v2.app[0].id, null)
    app2 = try(openstack_compute_instance_v2.app[1].id, null)
  }
}

output "volume_ids" {
  description = "The database and app local-cache Cinder volume IDs keyed by db, app01, and app02."
  value       = { for key, volume in openstack_blockstorage_volume_v3.data : key => volume.id }
}

output "dataroot_volume_ids" {
  description = "Independent app Moodle dataroot Cinder volume IDs keyed by app01 and app02."
  value       = { for key, volume in openstack_blockstorage_volume_v3.dataroot : key => volume.id }
}
