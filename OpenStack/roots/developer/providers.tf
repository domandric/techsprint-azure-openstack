# This root configures one provider for one developer project; its ID comes
# from bootstrap state rather than an unscoped caller value.
provider "openstack" {
  cloud     = var.cloud != "" ? var.cloud : null
  region    = var.region
  tenant_id = data.terraform_remote_state.bootstrap.outputs.developer_project_ids[var.developer.slug]
}
