output "developer_group_ids" {
  value = { for slug, group in azuread_group.developer : slug => group.object_id }
}

output "lead_group_id" {
  value = azuread_group.leads.object_id
}

output "user_object_ids" {
  value = local.user_object_ids
}
