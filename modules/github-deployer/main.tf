# A deploy identity for one GitHub repository. The platform's WIF provider
# admits only pushes to main in the platform's GitHub organisation; this
# binding narrows it to one repository. Role grants are up to the caller.
resource "google_service_account" "this" {
  account_id   = "${var.name}-deploy"
  display_name = "${var.name} deploy from GitHub Actions"
}

resource "google_service_account_iam_member" "wif" {
  service_account_id = google_service_account.this.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${var.wif_pool_name}/attribute.repository/${var.github_repo}"
}
