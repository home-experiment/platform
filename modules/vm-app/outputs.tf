output "deploy_service_account" {
  description = "GitHub repository variable GCP_DEPLOY_SA"
  value       = module.deployer.email
}

output "secret_id" {
  description = "Secret Manager secret holding the app's config file"
  value       = google_secret_manager_secret.env.secret_id
}
