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

variable "inbox_bucket" {
  description = "GCS bucket whose top-level files platform-inbox copies to the VM for the app; null for none. The app's own Terraform must grant roles/storage.objectViewer and roles/storage.legacyBucketReader (gcloud storage rsync needs storage.buckets.get) on the bucket to the platform VM service account, otherwise every run fails with a 403"
  type        = string
  default     = null
  validation {
    condition     = var.inbox_bucket == null ? true : can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.inbox_bucket))
    error_message = "inbox_bucket: a bucket name of 3-63 lowercase letters, digits, dots, hyphens and underscores, starting and ending with a letter or digit."
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
