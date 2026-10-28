# Names and the "film-picker" tag predate the platform; renaming would recreate
# the VM, and the database lives on its boot disk.
resource "google_compute_address" "ip" {
  name       = "film-picker-ip"
  region     = var.region
  depends_on = [google_project_service.this]
}

resource "google_compute_instance" "vm" {
  name                      = "film-picker-vm"
  machine_type              = var.machine_type
  zone                      = local.zone
  tags                      = ["film-picker"]
  allow_stopping_for_update = true
  deletion_protection       = var.vm_deletion_protection # the database lives on the boot disk

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-13"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      nat_ip = google_compute_address.ip.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  # startup-script in metadata (not metadata_startup_script) so edits update
  # the VM in place instead of replacing it; it runs again on the next boot or
  # with: sudo google_metadata_script_runner startup
  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("${path.module}/startup.sh", {
      releases_bucket  = google_storage_bucket.bucket["releases"].name
      backups_bucket   = google_storage_bucket.bucket["backups"].name
      platform_common  = file("${path.module}/../scripts/platform-common.sh")
      platform_sync    = file("${path.module}/../scripts/platform-sync.sh")
      platform_deploy  = file("${path.module}/../scripts/platform-deploy.sh")
      platform_backup  = file("${path.module}/../scripts/platform-backup.sh")
      platform_restore = file("${path.module}/../scripts/platform-restore.sh")
    })
  }

  lifecycle {
    # A newer debian-13 image must not replace the VM (and its database).
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }
}
