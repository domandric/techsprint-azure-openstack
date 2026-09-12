locals {
  developers = {
    for slug, user in var.users : slug => user if user.role == "developer"
  }
  leads = {
    for slug, user in var.users : slug => user if user.role == "devops_lead"
  }
}

resource "terraform_data" "guardrails" {
  input = var.entra_mode

  lifecycle {
    precondition {
      condition     = length(local.leads) == 1
      error_message = "Azure requires exactly one devops_lead."
    }

    precondition {
      condition     = alltrue([for user in values(var.users) : length(trimspace(user.upn)) > 0])
      error_message = "Entra UPNs are required before identity resources are planned."
    }

    precondition {
      condition     = var.entra_mode != "create" || length(setsubtract(toset(keys(var.users)), toset(keys(nonsensitive(var.initial_passwords))))) == 0
      error_message = "create mode requires a sensitive initial password for every user."
    }
  }
}

data "azuread_user" "existing" {
  for_each = var.entra_mode == "existing" ? var.users : {}

  user_principal_name = each.value.upn

  depends_on = [terraform_data.guardrails]
}

resource "azuread_user" "created" {
  for_each = var.entra_mode == "create" ? var.users : {}

  user_principal_name   = each.value.upn
  display_name          = each.value.slug
  mail_nickname         = substr(replace(each.value.slug, "-", ""), 0, 60)
  password              = var.initial_passwords[each.key]
  force_password_change = true

  depends_on = [terraform_data.guardrails]
}

locals {
  user_object_ids = var.entra_mode == "existing" ? {
    for slug, user in data.azuread_user.existing : slug => user.object_id
    } : {
    for slug, user in azuread_user.created : slug => user.object_id
  }
}

resource "azuread_group" "developer" {
  for_each = local.developers

  display_name     = "grp-ts-dev-${each.key}"
  description      = "Azure developer group scoped to ${each.key}'s resource group."
  security_enabled = true
  mail_enabled     = false
  mail_nickname    = substr("tsdev${replace(each.key, "-", "")}", 0, 64)
}

resource "azuread_group" "leads" {
  display_name     = "grp-ts-devops-leads"
  description      = "Azure DevOps lead group scoped to developer resource groups."
  security_enabled = true
  mail_enabled     = false
  mail_nickname    = "tsdevopsleads"
}

resource "azuread_group_member" "developer" {
  for_each = local.developers

  group_object_id  = azuread_group.developer[each.key].object_id
  member_object_id = local.user_object_ids[each.key]
}

resource "azuread_group_member" "lead" {
  for_each = local.leads

  group_object_id  = azuread_group.leads.object_id
  member_object_id = local.user_object_ids[each.key]
}
