# What the lab platform surfaces, and what an instructor needs to verify a
# pre-warmed cluster before students arrive.
#
# ⚠️ These are Terraform outputs, NOT student_visible_outputs. The four things
# students actually see are declared in qwiklabs.yaml. Everything here is for
# whoever is looking at a provisioning log.

output "alloydb_cluster" {
  description = "Cluster ID."
  value       = google_alloydb_cluster.main.cluster_id
}

output "alloydb_instance" {
  description = "Primary instance ID."
  value       = google_alloydb_instance.primary.instance_id
}

output "alloydb_public_ip" {
  description = "Reached by the AlloyDB Python Connector with IAM auth — no password, no authorized networks."
  value       = google_alloydb_instance.primary.public_ip_address
}

output "student_db_user" {
  description = "IAM database user holding alloydbsuperuser. Required for CREATE EXTENSION in setup, and for the Index Advisor to return anything at all."
  value       = google_alloydb_user.student.user_id
}

output "instance_path" {
  description = "Fully-qualified instance path, for any MCP or Data API caller."
  value       = local.instance_path
}

# ---------------------------------------------------------------------------
# NEW FOR LAB 3 — the provisioning log should be able to answer "is the lab's
# subject matter actually turned on?" without anyone opening the console.
# ---------------------------------------------------------------------------
# 🔴 THIS IS THE ONE INSTRUCTORS SHOULD READ. If enhanced query insights is
# entitlement-gated and the API quietly declines to enable it, the apply can
# still SUCCEED with these coming back false — at which point Task 2 has
# reduced data and Task 4 has none, and nobody finds out until minute 40.
# Echoing the settled values makes that visible in the provisioning log.
output "observability" {
  description = "What the instance ACTUALLY settled on. If enabled or track_active_queries is false, Tasks 2 and 4 are degraded — do not start the event."
  value = {
    enabled                = try(google_alloydb_instance.primary.observability_config[0].enabled, null)
    track_active_queries   = try(google_alloydb_instance.primary.observability_config[0].track_active_queries, null)
    track_wait_events      = try(google_alloydb_instance.primary.observability_config[0].track_wait_events, null)
    preserve_comments      = try(google_alloydb_instance.primary.observability_config[0].preserve_comments, null)
    assistive_experiences  = try(google_alloydb_instance.primary.observability_config[0].assistive_experiences_enabled, null)
  }
}

# The PATCH that has no Terraform surface. Emitted so that if the Task 0 setup
# script is ever skipped, the exact command is one `terraform output` away.
#
# ⚠️ BOTH DETAILS MEASURED 2026-08-18, not copied from the docs: /v1/ works, so
# nothing here is pinned to an alpha surface; and "ENABLED" is the only accepted
# spelling — ALLOW_DATA_API returns HTTP 400 INVALID_ARGUMENT. It returns a
# long-running operation that takes ~134 SECONDS. Anyone running it by hand
# needs to know that or they will conclude it hung.
output "data_api_patch_command" {
  description = "Manual fallback if the setup script did not run. Requires alloydb.instances.update. Takes ~134s to settle."
  value       = <<-EOT
    curl -sS -X PATCH \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://alloydb.googleapis.com/v1/${local.instance_path}?updateMask=dataApiAccess" \
      -d '{"dataApiAccess":"ENABLED"}'
  EOT
}

output "instructor_preflight" {
  description = "Run after the setup script. Expect 13439 players / 796 clubs / 832193 appearances."
  value       = "SELECT * FROM provisioning_status;"
}
