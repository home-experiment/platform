variable "project_id" {
  description = "GCP project shared by all apps"
  type        = string
  default     = "pytsekas"
}

variable "region" {
  description = "Region; e2-micro is only free in us-west1, us-central1 and us-east1. Changing it replaces the subnet, the static IP and the VM (README \"Moving to another region\")"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone of the VM; defaults to <region>-a"
  type        = string
  default     = null
}

variable "storage_location" {
  description = "Location of the releases and backups buckets, independent of region so a region move keeps them. Changing it recreates the buckets and deletes their objects"
  type        = string
  default     = "US-CENTRAL1"
}

variable "vm_deletion_protection" {
  description = "Set to false only for the apply that moves or deletes the VM"
  type        = bool
  default     = true
}

locals {
  zone = coalesce(var.zone, "${var.region}-a")
}

variable "machine_type" {
  description = "VM size; e2-micro is free, e2-small (2 GB) costs about $12-13 a month. Changing it restarts the VM"
  type        = string
  default     = "e2-micro"
}

variable "github_owner" {
  description = "GitHub organisation whose repositories may deploy (each app's deploy account is further limited to its own repository)"
  type        = string
  default     = "home-experiment"
}

variable "github_owner_id" {
  description = "Numeric id of github_owner (gh api orgs/<owner> --jq .id); unlike the name it is never reused"
  type        = string
  default     = "348538226"
}

variable "billing_account_id" {
  description = "Billing account for the budget alert, e.g. 012345-6789AB-CDEF01"
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget for the whole project in the billing account's currency; alerts at 50 % and 100 %"
  type        = number
  default     = 10
}

variable "alert_email" {
  description = "Where budget alerts go"
  type        = string
}
