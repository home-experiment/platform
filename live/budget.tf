data "google_project" "this" {}

resource "google_monitoring_notification_channel" "email" {
  display_name = "pytsekas budget"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.this]
}

resource "google_billing_budget" "budget" {
  billing_account = var.billing_account_id
  display_name    = "pytsekas"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      units = tostring(var.budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
  }

  depends_on = [google_project_service.this]
}
