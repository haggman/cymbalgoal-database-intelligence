provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

# ⚠️ Used by exactly one resource: google_alloydb_instance.primary. See the note
# in versions.tf — observability_config does not exist in the GA provider at
# 7.35.0, and Lab 3 cannot provision its own subject matter without it.
provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}
