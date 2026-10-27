variable "name" {
  description = "App name: /srv/<name>, secret <name>-env, metadata key vm-app-<name>, releases under <name>/"
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}$", var.name))
    error_message = "name: lowercase letters, digits and dashes, 2-23 characters, starting with a letter."
  }
}

variable "github_repo" {
  description = "owner/name of the repository that deploys this app"
  type        = string
}

variable "port" {
  description = "Local port Caddy forwards to and the health check calls"
  type        = number
  validation {
    condition     = var.port >= 1024 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number from 1024 to 65535."
  }
}

variable "domains" {
  description = "Host names Caddy serves over HTTPS for this app; each A record points at the platform's static IP"
  type        = list(string)
  validation {
    condition     = length(var.domains) > 0 && alltrue([for d in var.domains : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", d))])
    error_message = "domains must be a non-empty list of lowercase host names."
  }
}

variable "db" {
  description = "MariaDB database platform-sync creates and platform-backup dumps; null for none"
  type        = string
  default     = null
  validation {
    condition     = var.db == null ? true : can(regex("^[a-z][a-z0-9_]{1,63}$", var.db))
    error_message = "db: lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "health_path" {
  description = "Path the deploy health check requests on the app's port"
  type        = string
  default     = "/"
  validation {
    condition     = can(regex("^/[A-Za-z0-9._~/-]*$", var.health_path))
    error_message = "health_path must start with / and contain only URL-safe characters."
  }
}

variable "platform" {
  description = "Outputs of the platform's live root (terraform_remote_state, prefix platform)"
  type = object({
    project_id               = string
    zone                     = string
    vm_name                  = string
    vm_service_account_name  = string
    vm_service_account_email = string
    releases_bucket          = string
    wif_pool_name            = string
  })
}
