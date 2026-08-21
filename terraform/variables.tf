# Variables the Qwiklabs runtime injects at Start Lab time.
#
# ⚠️ RULE: every variable here must be one the platform actually supplies, under
# the exact name the platform uses. A required variable the runtime does not
# know about fails the apply — for every student in the room, at once.
#
# MEASURED, from a live Start Lab log (2026-08-18), the ENTIRE command line is:
#   terraform apply -var gcp_project_id=... -var gcp_zone=... -var gcp_region=... -auto-approve
# Three variables. Everything else arrives only because qwiklabs.yaml declares
# it under startup_script.custom_properties.

variable "gcp_project_id" {
  description = "Project the lab platform provisions for the student."
  type        = string
}

variable "gcp_region" {
  description = <<-EOT
    Deployment region. Constrained to us-central1 or us-east1 — but for FEWER
    reasons than mkt013 and mkt014 had, and the difference matters if anyone
    ever wants to widen it:

      GONE:  QueryData context sets (four regions worldwide). Lab 3 builds none.
      GONE:  ai.rank()'s reranker resolving to Discovery Engine's global. Lab 3
             does no reranking.
      LIVE:  google_ml.embedding() and the ai.* family call Vertex from the
             cluster's own region — but only if the prototype rules the
             cost-optimized AI functions IN (D-36 gate).
      UNKNOWN: Database Insights / Advanced Query Insights regional
             availability. Never measured. This is the one to settle before
             widening anything.
  EOT
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-central1", "us-east1"], var.gcp_region)
    error_message = "Region must be us-central1 or us-east1 until AQI regional availability is measured."
  }
}

variable "gcp_zone" {
  description = <<-EOT
    Zone within gcp_region. Nothing consumes it — there is no startup VM in this
    lab either — but Qwiklabs injects it and it costs nothing to declare.
    ⚠️ Do NOT wire it into the AlloyDB instance as gce_zone. Pinning a zone
    re-creates the capacity failure ZONAL just fixed (P-48).
  EOT
  type        = string
  default     = "us-central1-a"
}

# -----------------------------------------------------------------------------
# ⚠️ THE VARIABLE MOST LIKELY TO KILL START LAB — and in Lab 3 it fails QUIETLY
# -----------------------------------------------------------------------------
# `username` carries the LOCAL PART ONLY — "student-03-abc123", no domain — when
# qwiklabs.yaml passes user_0.local_username, and the FULL ADDRESS when it passes
# user_0.username. Measured on a live run; the two references are different values:
#
#   user_0.username        -> "student-03-5f4bdd24d19c@qwiklabs.net"   FULL EMAIL
#   user_0.local_username  -> "student-03-5f4bdd24d19c"                LOCAL PART
#
# main.tf appends the domain only when it is absent, so either reference works.
#
# ⚠️ WHAT IS DIFFERENT ABOUT LAB 3. In Labs 1 and 2 a wrong value here produced a
# loud failure — CREATE EXTENSION denied, or a 403. Lab 3 has a SILENT one. The
# Index Advisor returns an EMPTY result set to a caller that is not
# alloydbsuperuser (shared-conventions §7 items 6-7). Task 3 would then show a
# student "no recommendations", which is a perfectly plausible thing for an
# advisor to say, and they would believe it.
#
# So the Task 3 verification step must not be "did you get rows back". It has to
# assert the ROLE first. Note that for the build session.
# -----------------------------------------------------------------------------
variable "username" {
  description = <<-EOT
    The student's lab username. EITHER "student-03-abc123" (local part, what
    user_0.local_username gives) OR "student-03-abc123@qwiklabs.net" (full address,
    what user_0.username gives). main.tf appends the domain only when it is absent.

    ⚠️ NOT injected automatically. Arrives ONLY because qwiklabs.yaml declares it
    under startup_script.custom_properties.

    Do NOT use data.google_client_openid_userinfo — that returns the Terraform
    runner's identity, not the student's.
  EOT
  type        = string

  validation {
    condition     = length(regexall("@", var.username)) <= 1
    error_message = "username must be either the local part (student-03-abc123) or one full address (student-03-abc123@qwiklabs.net)."
  }

  validation {
    condition     = length(trimspace(var.username)) > 0
    error_message = "username is empty. Without it the student gets no alloydbsuperuser, and the Index Advisor silently returns nothing."
  }
}

# ---------------------------------------------------------------------------
# Tunables — not injected by the platform, defaults are the shipped values.
# ---------------------------------------------------------------------------

variable "cpu_count" {
  description = <<-EOT
    Primary instance vCPUs.

    ⚠️ IN LAB 3 THIS IS NOT ONLY A COST AND PROVISIONING-TIME KNOB. It is the
    cheapest lever on the lab's central problem: making the database genuinely
    slow. The CymbalGoal corpus is ~1.6M rows, and its largest table
    (appearances, 832,193 rows) fits comfortably in an 8-vCPU instance's cache.
    Halving the vCPUs makes every sequential scan hurt more AND provisions
    faster — both directions we want.

    Left at 8 for the FIRST Start Lab run so that provisioning time stays
    comparable with mkt013 and mkt014 and any difference is attributable. The
    prototype measures the workload at 8 first, then at 4. Do not change this
    before there is a measurement to compare against.
  EOT
  type        = number
  default     = 8
}

variable "student_email_domain" {
  description = <<-EOT
    Domain appended to var.username. Qwiklabs issues qwiklabs.net addresses; this is a
    variable only so the same config can be applied by hand in a personal project.
  EOT
  type        = string
  default     = "qwiklabs.net"
}
