data "terraform_remote_state" "shared" {
  backend = "s3"
  config = merge(local.state_backend_config, {
    key = "shared.tfstate"
  })
}

data "terraform_remote_state" "developer" {
  for_each = var.developer_slugs

  backend   = "s3"
  workspace = each.key
  config = merge(local.state_backend_config, {
    key                  = "developer.tfstate"
    workspace_key_prefix = "developer"
  })
}

locals {
  state_backend_config = {
    bucket                      = var.state_bucket
    region                      = var.state_region
    endpoints                   = { s3 = var.state_s3_endpoint }
    use_path_style              = var.state_use_path_style
    skip_credentials_validation = var.state_skip_credentials_validation
    skip_region_validation      = var.state_skip_region_validation
    skip_requesting_account_id  = var.state_skip_requesting_account_id
    skip_metadata_api_check     = var.state_skip_metadata_api_check
    skip_s3_checksum            = var.state_skip_s3_checksum
  }
}

resource "terraform_data" "workspace_guard" {
  input = terraform.workspace

  lifecycle {
    precondition {
      condition     = terraform.workspace == "default"
      error_message = "The shared-reconcile root uses the fixed shared-reconcile.tfstate object and must run in the default workspace."
    }
  }
}

locals {
  tenants = {
    for slug, state in data.terraform_remote_state.developer : slug => state.outputs.tenant
  }
}

module "access_links" {
  source = "../../modules/access-links"

  depends_on = [terraform_data.workspace_guard]

  name_seed              = data.terraform_remote_state.shared.outputs.name_seed
  shared_project_id      = data.terraform_remote_state.shared.outputs.shared_project_id
  jump_server_id         = data.terraform_remote_state.shared.outputs.jump_server_id
  jump_security_group_id = data.terraform_remote_state.shared.outputs.jump_security_group_id
  tenants                = local.tenants
}
