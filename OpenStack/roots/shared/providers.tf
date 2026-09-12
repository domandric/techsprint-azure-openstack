provider "openstack" {
  cloud     = var.cloud != "" ? var.cloud : null
  region    = var.region
  tenant_id = data.terraform_remote_state.bootstrap.outputs.shared_project_id
}
