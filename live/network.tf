# Names and the "film-picker" network tag predate the platform (film-picker was
# the first app); renaming would recreate the network and the VM.
resource "google_compute_network" "vpc" {
  name                    = "film-picker-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.this]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "film-picker-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_firewall" "web" {
  name          = "film-picker-allow-web"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["film-picker"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

# SSH only through Identity-Aware Proxy TCP forwarding; no public port 22.
resource "google_compute_firewall" "iap_ssh" {
  name          = "film-picker-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["film-picker"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
