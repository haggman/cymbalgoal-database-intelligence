# Version pins.
#
# Terraform 1.12.1 and google 7.35.0 are carried from mkt013 and mkt014, both
# proven at Start Lab. Do not float them.
#
# ⚠️ NEW IN LAB 3: google-beta.
#
# This is not defensive padding. It was READ FROM THE PROVIDER SOURCE at the
# pinned version, 2026-08-21:
#
#   hashicorp/terraform-provider-google      v7.35.0
#     google/services/alloydb/resource_alloydb_instance.go
#       -> query_insights_config  PRESENT   (standard Query Insights)
#       -> observability_config   ABSENT
#
#   hashicorp/terraform-provider-google-beta v7.35.0
#     google-beta/services/alloydb/resource_alloydb_instance.go
#       -> observability_config   PRESENT   (enhanced / advanced query insights)
#
# observability_config is where track_active_queries, track_wait_events and
# preserve_comments live, and Lab 3's Tasks 2 and 4 are built on all three. The
# GA provider cannot set them. So the INSTANCE resource — and only the instance
# resource — runs on google-beta. Everything else stays on GA.
#
# The alternative was a second async PATCH in the setup script, the way mkt014
# handles dataApiAccess. Rejected: the Data API PATCH exists there because NO
# Terraform surface has the field. Here one does, and reaching for curl when a
# resource attribute exists buries a provisioning requirement in a script.

terraform {
  required_version = ">= 1.12.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.35.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "7.35.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}
