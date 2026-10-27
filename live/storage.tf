# Bucket purpose => days before objects are deleted. Releases live under
# <app>/, backups under <app>/. The names predate the platform.
locals {
  buckets = {
    releases = 30
    backups  = 30
  }
}

resource "google_storage_bucket" "bucket" {
  for_each                    = local.buckets
  name                        = "${var.project_id}-film-picker-${each.key}"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = each.value
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.this]
}
