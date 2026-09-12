provider "openstack" {
  cloud     = var.cloud != "" ? var.cloud : null
  region    = var.region
  tenant_id = data.terraform_remote_state.shared.outputs.shared_project_id
}
