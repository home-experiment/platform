# Adopted from film-picker's infra/ state when the platform was created
# (2026-10). film-picker's root forgets them with removed blocks. IAM members,
# APIs, the budget and the WIF pool are created here instead of imported
# (creating an existing IAM member or API changes nothing). Delete this file
# once the import has been applied.
import {
  to = google_compute_network.vpc
  id = "projects/${var.project_id}/global/networks/film-picker-vpc"
}

import {
  to = google_compute_subnetwork.subnet
  id = "projects/${var.project_id}/regions/${var.region}/subnetworks/film-picker-subnet"
}

import {
  to = google_compute_firewall.web
  id = "projects/${var.project_id}/global/firewalls/film-picker-allow-web"
}

import {
  to = google_compute_firewall.iap_ssh
  id = "projects/${var.project_id}/global/firewalls/film-picker-allow-iap-ssh"
}

import {
  to = google_compute_address.ip
  id = "projects/${var.project_id}/regions/${var.region}/addresses/film-picker-ip"
}

import {
  to = google_compute_instance.vm
  id = "projects/${var.project_id}/zones/${var.zone}/instances/film-picker-vm"
}

import {
  to = google_service_account.vm
  id = "projects/${var.project_id}/serviceAccounts/film-picker-vm@${var.project_id}.iam.gserviceaccount.com"
}

import {
  to = google_storage_bucket.bucket["releases"]
  id = "${var.project_id}-film-picker-releases"
}

import {
  to = google_storage_bucket.bucket["backups"]
  id = "${var.project_id}-film-picker-backups"
}
