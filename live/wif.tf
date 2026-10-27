# GitHub Actions authenticates with its OIDC token. Only push events on main of
# repositories owned by var.github_owner get through; each app's deploy account
# (modules/github-deployer) trusts only its own repository.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub"
  depends_on                = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
  }
  attribute_condition = "assertion.repository_owner == \"${var.github_owner}\" && assertion.ref == \"refs/heads/main\" && assertion.event_name == \"push\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}
