data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = merge(local.state_backend_config, {
    key = "bootstrap.tfstate"
  })
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = merge(local.state_backend_config, {
    key = "shared.tfstate"
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
  db_password           = data.terraform_remote_state.bootstrap.outputs.database_passwords[var.developer.slug]
  name_seed             = data.terraform_remote_state.bootstrap.outputs.name_seed
  network_slot          = data.terraform_remote_state.bootstrap.outputs.developer_network_slots[var.developer.slug]
  templates_dir         = var.templates_dir != "" ? var.templates_dir : abspath("${path.root}/../../templates")
  app_flavor_id         = var.app_flavor_id != "" ? var.app_flavor_id : data.terraform_remote_state.bootstrap.outputs.flavor_ids.shared
  db_flavor_id          = var.db_flavor_id != "" ? var.db_flavor_id : data.terraform_remote_state.bootstrap.outputs.flavor_ids.shared
  shared_project_id     = data.terraform_remote_state.shared.outputs.shared_project_id
  external_network_name = data.terraform_remote_state.shared.outputs.external_network_name
  lead_ssh_public_key   = data.terraform_remote_state.shared.outputs.lead_ssh_public_key
}

resource "terraform_data" "remote_state_contract" {
  input = {
    bootstrap_name_seed      = data.terraform_remote_state.bootstrap.outputs.name_seed
    shared_name_seed         = data.terraform_remote_state.shared.outputs.name_seed
    bootstrap_shared_project = data.terraform_remote_state.bootstrap.outputs.shared_project_id
    shared_shared_project    = data.terraform_remote_state.shared.outputs.shared_project_id
  }

  lifecycle {
    precondition {
      condition     = data.terraform_remote_state.bootstrap.outputs.name_seed == data.terraform_remote_state.shared.outputs.name_seed
      error_message = "Bootstrap and shared remote states must expose the identical name_seed before a developer workspace is created."
    }
    precondition {
      condition     = data.terraform_remote_state.bootstrap.outputs.shared_project_id == data.terraform_remote_state.shared.outputs.shared_project_id
      error_message = "Bootstrap and shared remote states must expose the identical shared_project_id before a developer workspace is created."
    }
  }
}

resource "terraform_data" "workspace_guard" {
  input = terraform.workspace

  lifecycle {
    precondition {
      condition     = terraform.workspace != "default" && terraform.workspace == var.developer.slug
      error_message = "Select the Terraform workspace named exactly ${var.developer.slug}; the default workspace is rejected."
    }
  }
}

module "workspace" {
  source = "../../modules/workspace"

  depends_on = [terraform_data.workspace_guard, terraform_data.remote_state_contract]

  name_seed             = local.name_seed
  project_id            = data.terraform_remote_state.bootstrap.outputs.developer_project_ids[var.developer.slug]
  shared_project_id     = local.shared_project_id
  developer_slug        = var.developer.slug
  network_slot          = local.network_slot
  external_network_name = local.external_network_name
  image_id              = var.image_id
  app_flavor_id         = local.app_flavor_id
  db_flavor_id          = local.db_flavor_id
  keypair_name          = data.terraform_remote_state.shared.outputs.keypair_name
  volume_type           = var.volume_type
  templates_dir         = local.templates_dir
  public_ssh_key        = var.public_ssh_key
  lead_ssh_public_key   = local.lead_ssh_public_key
  db_password           = local.db_password
  moodle_version        = var.moodle_version
  moodle_sha256         = var.moodle_sha256
  base_domain           = var.base_domain
}
