terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # The bucket was created by hand for film-picker and is shared by every root,
  # one prefix each: terraform init -backend-config=bucket=pytsekas-film-picker-tfstate
  backend "gcs" {
    prefix = "platform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = local.zone

  # The billing budget API needs a quota project when run with user credentials.
  user_project_override = true
  billing_project       = var.project_id
}
