module "deployer" {
  source        = "../github-deployer"
  name          = var.name
  github_repo   = var.github_repo
  wif_pool_name = var.platform.wif_pool_name
}

locals {
  deploy_member = "serviceAccount:${module.deployer.email}"
}

# The app's whole config file. Versions are added by hand
# (gcloud secrets versions add <name>-env --data-file=FILE), so no value ever
# reaches Terraform state. platform-deploy writes it to /srv/<name>/shared/app.env.
resource "google_secret_manager_secret" "env" {
  project   = var.platform.project_id
  secret_id = "${var.name}-env"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "vm_env" {
  project   = var.platform.project_id
  secret_id = google_secret_manager_secret.env.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.platform.vm_service_account_email}"
}

# Deploy: upload releases under <name>/ only.
resource "google_storage_bucket_iam_member" "deploy_releases" {
  bucket = var.platform.releases_bucket
  role   = "roles/storage.objectAdmin"
  member = local.deploy_member

  condition {
    title      = "${var.name}-releases-only"
    expression = "resource.name.startsWith(\"projects/_/buckets/${var.platform.releases_bucket}/objects/${var.name}/\")"
  }
}

# SSH through IAP without admin rights; platform-sync lets the account's OS
# Login user (sa_<unique id>) run only sudo deploy-<name>.
resource "google_compute_instance_iam_member" "deploy_os_login" {
  project       = var.platform.project_id
  zone          = var.platform.zone
  instance_name = var.platform.vm_name
  role          = "roles/compute.osLogin"
  member        = local.deploy_member
}

resource "google_iap_tunnel_instance_iam_member" "deploy_tunnel" {
  project  = var.platform.project_id
  zone     = var.platform.zone
  instance = var.platform.vm_name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = local.deploy_member
}

# gcloud compute ssh reads the instance and project metadata.
resource "google_project_iam_member" "deploy_compute_viewer" {
  project = var.platform.project_id
  role    = "roles/compute.viewer"
  member  = local.deploy_member
}

# OS Login to a VM that runs as a service account requires actAs on it.
resource "google_service_account_iam_member" "deploy_acts_as_vm" {
  service_account_id = var.platform.vm_service_account_name
  role               = "roles/iam.serviceAccountUser"
  member             = local.deploy_member
}

# Read by platform-sync, platform-deploy and platform-backup on the VM.
resource "google_compute_project_metadata_item" "app" {
  project = var.platform.project_id
  key     = "vm-app-${var.name}"
  value = jsonencode({
    name        = var.name
    port        = var.port
    domains     = var.domains
    db          = var.db
    health_path = var.health_path
    deploy_user = "sa_${module.deployer.unique_id}"
  })
}
