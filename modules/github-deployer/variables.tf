variable "name" {
  description = "App name; the service account is <name>-deploy"
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.name))
    error_message = "name: lowercase letters, digits and dashes, 2-23 characters, starting with a letter."
  }
}

variable "github_repo" {
  description = "owner/name of the only repository allowed to act as this account"
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}

variable "wif_pool_name" {
  description = "Full name of the platform's GitHub WIF pool (platform output wif_pool_name)"
  type        = string
}
