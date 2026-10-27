resource "google_service_account" "vm" {
  account_id   = "film-picker-vm"
  display_name = "film-picker VM"
  depends_on   = [google_project_service.this]
}

locals {
  vm_member = "serviceAccount:${google_service_account.vm.email}"
}

# VM: read releases, write (and read) backups, write logs. Each app's vm-app
# module grants it its own config secret.
resource "google_storage_bucket_iam_member" "vm_releases" {
  bucket = google_storage_bucket.bucket["releases"].name
  role   = "roles/storage.objectViewer"
  member = local.vm_member
}

resource "google_storage_bucket_iam_member" "vm_backups" {
  bucket = google_storage_bucket.bucket["backups"].name
  role   = "roles/storage.objectCreator"
  member = local.vm_member
}

# gcloud storage cp reads the uploaded object back, so the VM also needs read
# access. Neither role can delete or overwrite, so existing backups stay safe.
resource "google_storage_bucket_iam_member" "vm_backups_read" {
  bucket = google_storage_bucket.bucket["backups"].name
  role   = "roles/storage.objectViewer"
  member = local.vm_member
}

resource "google_project_iam_member" "vm_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = local.vm_member
}
