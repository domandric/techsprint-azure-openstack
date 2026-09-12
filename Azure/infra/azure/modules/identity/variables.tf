variable "entra_mode" {
  description = "existing looks up the supplied UPNs; create creates users only when directory permissions and sensitive initial passwords are supplied."
  type        = string
  default     = "existing"

  validation {
    condition     = contains(["existing", "create"], var.entra_mode)
    error_message = "entra_mode must be existing or create."
  }
}

variable "users" {
  description = "Users keyed by their stable lower-case slug."
  type = map(object({
    slug = string
    upn  = string
    role = string
  }))

  validation {
    condition     = alltrue([for user in values(var.users) : contains(["developer", "devops_lead"], user.role)])
    error_message = "Every identity user must have role developer or devops_lead."
  }
}

variable "initial_passwords" {
  description = "Sensitive create-mode passwords keyed by slug. Never output or logged. Not used in existing mode."
  type        = map(string)
  default     = {}
  sensitive   = true
}
