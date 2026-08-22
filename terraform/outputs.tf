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

# ---------------------------------------------------------------------------
# 🔴 REMOVED 2026-08-22: output "data_api_patch_command"
# ---------------------------------------------------------------------------
# It existed so an instructor could re-fire the dataApiAccess PATCH by hand if
# the setup script's attempt failed. The setup script no longer PATCHes at all —
# enabling the Data API restarts the instance and resets pg_stat_statements, and
# no Lab 3 task needs it. Full reasoning in main.tf, under "WHAT THIS FILE
# DELIBERATELY DOES NOT DO". mkt014 still has the working command if it is ever
# needed again.
# ---------------------------------------------------------------------------

output "instructor_preflight" {
  description = "Run after the setup script. Expect 13439 players / 796 clubs / 832193 appearances."
  value       = "SELECT * FROM provisioning_status;"
}
