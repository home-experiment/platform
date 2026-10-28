output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = local.zone
}

output "vm_name" {
  value = google_compute_instance.vm.name
}

output "vm_service_account_name" {
  description = "Full resource name, for IAM on the service account"
  value       = google_service_account.vm.name
}

output "vm_service_account_email" {
  value = google_service_account.vm.email
}

output "static_ip" {
  description = "Point every app hostname's A record here"
  value       = google_compute_address.ip.address
}

output "releases_bucket" {
  value = google_storage_bucket.bucket["releases"].name
}

output "backups_bucket" {
  value = google_storage_bucket.bucket["backups"].name
}

output "wif_pool_name" {
  value = google_iam_workload_identity_pool.github.name
}

output "wif_provider_name" {
  description = "GitHub repository variable GCP_WIF_PROVIDER for every deploying repository"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.vm.name} --zone ${local.zone} --project ${var.project_id} --tunnel-through-iap"
}

output "db_tunnel_command" {
  description = "Forwards local port 3306 to MariaDB on the VM"
  value       = "gcloud compute ssh ${google_compute_instance.vm.name} --zone ${local.zone} --project ${var.project_id} --tunnel-through-iap -- -N -L 3306:127.0.0.1:3306"
}
