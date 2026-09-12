data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = merge(local.state_backend_config, {
    key = "bootstrap.tfstate"
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
  templates_dir = var.templates_dir != "" ? var.templates_dir : abspath("${path.root}/../../templates")
  lead          = data.terraform_remote_state.bootstrap.outputs.credentials[data.terraform_remote_state.bootstrap.outputs.lead_slug]
  project_ids   = concat([data.terraform_remote_state.bootstrap.outputs.shared_project_id], values(data.terraform_remote_state.bootstrap.outputs.developer_project_ids))
}

resource "terraform_data" "workspace_guard" {
  input = terraform.workspace

  lifecycle {
    precondition {
      condition     = terraform.workspace == "default"
      error_message = "The shared root uses the fixed shared.tfstate object and must run in the default workspace."
    }
  }
}

module "platform" {
  source = "../../modules/platform"

  depends_on = [terraform_data.workspace_guard]

  name_seed                 = data.terraform_remote_state.bootstrap.outputs.name_seed
  shared_project_id         = data.terraform_remote_state.bootstrap.outputs.shared_project_id
  project_ids               = local.project_ids
  region                    = var.region
  admin_cidr                = "10.200.0.0/24"
  external_network_name     = var.external_network_name
  image_id                  = var.image_id
  flavor_id                 = data.terraform_remote_state.bootstrap.outputs.flavor_ids.shared
  allowed_ssh_cidr          = var.allowed_ssh_cidr
  templates_dir             = local.templates_dir
  lead_slug                 = data.terraform_remote_state.bootstrap.outputs.lead_slug
  lead_ssh_public_key       = var.lead_ssh_public_key
  developer_ssh_public_keys = var.developer_ssh_public_keys
  lead_ssh_private_key      = var.lead_ssh_private_key
  auth_url                  = var.auth_url
  domain_id                 = var.domain_id
  lead_username             = local.lead.username
  lead_password             = local.lead.password
}
