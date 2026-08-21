# =============================================================================
# CymbalGoal Lab 3 — Agentic Operations: Database Intelligence. Provisioning.
# =============================================================================
# FORKED FROM mkt014, which is proven at Start Lab. Everything mkt013 and mkt014
# got right is carried over verbatim and is NOT re-derived here — read the
# comments in mkt013/terraform/main.tf for ZONAL, the public IP, the username
# handling and the service-agent IAM bindings.
#
# ⚠️ DELTA FROM mkt014 — every difference listed so a diff is legible:
#   1. NEW  observability_config on the instance, via the google-beta provider.
#           This is Lab 3's entire subject matter and the GA provider cannot
#           set it. See versions.tf.
#   2. NEW  query_insights_config on the instance, explicit rather than default.
#   3. NEW  monitoring.googleapis.com
#   4. GONE geminidataanalytics, dataplex, discoveryengine APIs
#   5. GONE roles/discoveryengine.viewer on the AlloyDB service agent
#   6. GONE roles/geminidataanalytics.queryDataUser on the student
#   7. HELD google_ml_integration.enable_cost_optimized_ai_functions and
#           google_columnar_engine.enabled — both PENDING a prototype ruling.
#           They are here so the ruling can be MEASURED. If either comes back
#           NO, delete it rather than leaving it as an oversight. That is the
#           standing open question mkt014 left behind; do not inherit it.
#
# WHAT THIS FILE PROVISIONS: cluster, instance, APIs, IAM, and the observability
# configuration. Nothing else. It cannot run SQL — the Terraform runner sits
# outside the VPC and there is no google_alloydb_database resource.
#
# WHAT IT DOES NOT DO, AND WHO DOES IT INSTEAD:
#   * Create the `cymbalgoal` database, extensions, schema, load the corpus,
#     build the baseline indexes   ->  setup/lab3-setup.py in the student repo,
#     backgrounded by the student in Task 0.
#   * Start the deadline-day workload  ->  workload/deadline-day.sh, also Task 0.
#     The workload has to be running BEFORE Task 2, because Query Insights shows
#     history and history takes time to accumulate.
#   * PATCH dataApiAccess  ->  same setup script. No Terraform surface exists.
# =============================================================================

locals {
  cluster_id  = "cymbalgoal-cluster"
  instance_id = "cymbalgoal-primary"
  network     = "cymbalgoal-network"

  # Append the domain ONLY if it is not already there. user_0.username and
  # user_0.local_username are DIFFERENT VALUES and qwiklabs.yaml decides which
  # arrives. Tolerating both is what turns a dead room into a working one.
  student_email = can(regex("@", var.username)) ? var.username : "${var.username}@${var.student_email_domain}"

  # Fully-qualified instance path. The MCP surface in Task 5 wants it verbatim,
  # and hand-assembling a five-segment path from four console pages is a pure-tax
  # minute plus a silent 404 when it goes wrong.
  instance_path = "projects/${var.gcp_project_id}/locations/${var.gcp_region}/clusters/${local.cluster_id}/instances/${local.instance_id}"
}

data "google_project" "current" {
  project_id = var.gcp_project_id
}

# -----------------------------------------------------------------------------
# APIs
# -----------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    # ---- carried from mkt013/mkt014, unchanged -------------------------------
    "alloydb.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",

    # Kept even though no Lab 3 task is confirmed to call Vertex yet. If the
    # cost-optimized AI function ruling comes back YES, ai.if() needs it, and
    # so does the aiplatform.user binding below. Cheap to leave, room-wide
    # failure to have left out.
    "aiplatform.googleapis.com",

    # ---- NEW FOR LAB 3 -------------------------------------------------------

    # System Insights and the Database Center both read Cloud Monitoring
    # metrics. In most projects this is already enabled by default, which is
    # exactly why it is easy to forget in the one project where it is not.
    "monitoring.googleapis.com",

    # AlloyDB Studio's Gemini panel, and the "assistive experiences" flag on
    # observability_config below. Same INFERRED status it had in mkt014 —
    # Google's AlloyDB pages never name this service string; it is deduced from
    # the two permissions the Studio doc does list.
    "cloudaicompanion.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false

  # ⚠️ UNRESOLVED, and a prototype item rather than a guess. Database Center is
  # a fleet-level console surface and it is NOT KNOWN whether it needs an API
  # enabled in the project it is reporting on. Candidates, in order of
  # plausibility: none at all (it reads the AlloyDB control plane directly),
  # cloudasset.googleapis.com, securitycenter.googleapis.com.
  #
  # Do NOT add one of these on a hunch. A service string that does not exist
  # halts the apply for the whole room — the single most expensive way to be
  # wrong in this file. The prototype answers it by watching what Database
  # Center shows in a project with only the list above enabled.
}

# -----------------------------------------------------------------------------
# Network — identical to mkt013 and mkt014
# -----------------------------------------------------------------------------
# AlloyDB is VPC-native and requires Private Service Access even when reached
# over its public IP. No subnet, NAT, router or firewall rules: nothing in Lab 3
# runs inside the VPC. Cloud Shell reaches the instance over the public IP with
# the AlloyDB Python Connector and IAM auth, and NO authorized networks.
resource "google_compute_network" "main" {
  name                    = local.network
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_global_address" "psa" {
  name          = "cymbalgoal-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
  depends_on    = [google_project_service.apis]
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
  depends_on              = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
resource "random_password" "initial" {
  length           = 24
  special          = true
  override_special = "-_=+"
}

resource "google_alloydb_cluster" "main" {
  cluster_id       = local.cluster_id
  location         = var.gcp_region
  database_version = "POSTGRES_18"

  network_config {
    network = google_compute_network.main.id
  }

  initial_user {
    user     = "postgres"
    password = random_password.initial.result
  }

  depends_on = [google_service_networking_connection.psa]
}

# -----------------------------------------------------------------------------
# Primary instance — ON THE BETA PROVIDER
# -----------------------------------------------------------------------------
resource "google_alloydb_instance" "primary" {
  # ⚠️ THE ONE RESOURCE IN THIS FILE THAT IS NOT ON THE GA PROVIDER, and the
  # reason is observability_config below. See versions.tf for the source-read
  # that settled it.
  provider = google-beta

  cluster       = google_alloydb_cluster.main.name
  instance_id   = local.instance_id
  instance_type = "PRIMARY"

  # ⚠️ NOT the default, and do NOT add gce_zone. A PRIMARY defaults to REGIONAL,
  # which is an HA pair and doubles the capacity request — 600 nodes instead of
  # 300 at a 300-person event, in one region, at the same moment. Measured
  # failure: Error code 9, "Location us-central1 does not have enough
  # resources" (P-48).
  availability_type = "ZONAL"

  machine_config {
    # ⚠️ See variables.tf. In Lab 3 this is also the cheapest lever on "is the
    # database actually slow", and it moves provisioning time in the direction
    # we want at the same time. Measure at 8 first so the number is comparable
    # with the other two labs.
    cpu_count = var.cpu_count
  }

  network_config {
    enable_public_ip = true
  }

  # ---------------------------------------------------------------------------
  # STANDARD QUERY INSIGHTS
  # ---------------------------------------------------------------------------
  # Field names read from hashicorp/terraform-provider-google v7.35.0 source,
  # 2026-08-21 — query_plans_per_minute, query_string_length,
  # record_application_tags, record_client_address. That is the complete set.
  #
  # Set explicitly rather than left to default because Task 2's whole story is
  # attribution: the student sees a slow statement and needs to know WHICH part
  # of the deadline-day app issued it. That works through sqlcommenter tags in
  # the query text, which is what record_application_tags surfaces. It defaults
  # on — say so out loud anyway, because a silent default is a thing that can
  # change under you between events.
  query_insights_config {
    record_application_tags = true
    record_client_address   = true

    # Default 5, max 20 on this block. The workload runs many statements per
    # minute; capturing more plans gives Task 2 more to drill into.
    query_plans_per_minute = 20

    # Default 1024, max 4500. The workload's statements carry a leading
    # sqlcommenter comment, so a short truncation limit eats the tag before the
    # SQL. Room to breathe.
    query_string_length = 4500
  }

  # ---------------------------------------------------------------------------
  # ENHANCED QUERY INSIGHTS — the reason this resource is on google-beta
  # ---------------------------------------------------------------------------
  # Field names read from hashicorp/terraform-provider-google-beta v7.35.0
  # source, 2026-08-21. The complete set is: enabled, preserve_comments,
  # track_wait_events, track_wait_event_types, max_query_string_length,
  # record_application_tags, query_plans_per_minute, track_active_queries,
  # track_client_address, assistive_experiences_enabled.
  #
  # 🔴 THE FINDING THAT MATTERS MOST HERE: track_active_queries DEFAULTS TO OFF.
  # The provider's own description says so — 'Track actively running queries.
  # If not set, default value is "off".' Task 4 is built on the Active Queries
  # view. Ship without this line and Task 4 has no data, on every cluster in
  # the room, and it will look like the workload is not running.
  #
  # ⚠️ WHETHER THIS BLOCK IS ACCEPTED AT ALL IS THE #1 PROTOTYPE QUESTION.
  # Enhanced query insights is the Advanced tier of Database Insights and may
  # be entitlement-gated the way Cloud Assist investigations are (P-02). If the
  # apply fails or the fields come back false, Task 2 falls back to standard
  # Query Insights and Task 4 loses wait events — which reshapes two tasks, so
  # it gets answered before any prose is written.
  observability_config {
    enabled = true

    # Wait events are the difference between "this query was slow" and "this
    # query was slow because it was waiting on a lock / on I/O / on a buffer
    # pin". That distinction is Task 4's entire teaching payload.
    track_wait_events      = true
    track_wait_event_types = true

    # Task 4. Off by default. See above.
    track_active_queries = true

    # ⚠️ LOAD-BEARING FOR THE STORY, not for the mechanics. Query Insights
    # normalizes statements; preserving comments is what keeps the sqlcommenter
    # tag attached, so the student can say "it is the transfer ticker" instead
    # of "it is a query". The workload generator tags every statement it issues.
    preserve_comments       = true
    record_application_tags = true

    # Who is calling. In a lab there is exactly one client, so this is cheap;
    # in the business-translation moment it is how you find the noisy service.
    track_client_address = true

    # 200 max on this block, against 20 on the standard one.
    query_plans_per_minute = 20

    # Default 10240. The tagged statements are long-ish; leave headroom.
    max_query_string_length = 20000

    # ⚠️ UNVERIFIED WHAT THIS ACTUALLY TURNS ON. The provider describes it as
    # "Whether assistive experiences are enabled for this AlloyDB instance" and
    # says nothing more. Best guess: the Gemini-assisted panels in the AlloyDB
    # console, which is adjacent to Task 5. Left ON so the prototype can see
    # what appears; if it turns out to be Cloud Assist and therefore
    # support-gated (P-02), take it out.
    assistive_experiences_enabled = true
  }

  # ⚠️ EVERY NAME VERIFIED against
  #   GET .../locations/{region}/supportedDatabaseFlags
  # AlloyDB rejects the ENTIRE instance create if one flag name is unknown — no
  # warning, no partial apply, every student gets a cluster with no instance.
  # Never add an unchecked name.
  database_flags = {
    # MANDATORY with public IP. AlloyDB refuses the request without it.
    "password.enforce_complexity" = "on"

    # Required for enable_iam_auth. google_alloydb_user creates the principal;
    # this flag is what lets it authenticate.
    "alloydb.iam_authentication" = "on"

    # ---- HELD PENDING A PROTOTYPE RULING -------------------------------------
    #
    # These two are inherited from mkt014, where NO TASK USED EITHER. That is a
    # standing open question in the build plan and Lab 3 is where it gets
    # closed, in one direction or the other.
    #
    # google_columnar_engine.enabled
    #   Candidate Lab 3 material: a columnar scan is a genuinely DIFFERENT fix
    #   from an index, which would give the lab three distinct repairs instead
    #   of two. ce116 in this repo is prior art. Rule it in or take it out.
    #
    # google_ml_integration.enable_cost_optimized_ai_functions
    #   The D-36 gate. Measured in full already — see
    #   cymbalgoal-proxy-models-to-lab3.md — and the ONLY open question is
    #   whether Lab 3's workload honestly calls a model from SQL. If it does
    #   not, this comes out and the story is not bent to keep it.
    #
    # enable_preview_ai_functions rides along with the AI-function ruling; it
    # is what gates the preview ai.* surface the other flag operates on.
    "google_columnar_engine.enabled"                           = "on"
    "google_ml_integration.enable_preview_ai_functions"        = "on"
    "google_ml_integration.enable_cost_optimized_ai_functions" = "on"

    # ⚠️ PROTOTYPE ITEM, deliberately NOT set yet. Turning work_mem down is a
    # legitimate way to push sorts and hashes to disk and make the workload
    # hurt on a small corpus. It is also a way to make a lab that teaches
    # nothing except that someone sabotaged the instance. Measure the honest
    # workload first; reach for this only if the corpus genuinely cannot be
    # made slow, and if it is used, the lab must SAY it is set low and why.
  }

  depends_on = [google_service_networking_connection.psa]
}

# -----------------------------------------------------------------------------
# Service-agent binding
# -----------------------------------------------------------------------------
# The AlloyDB service agent does not exist until the cluster does, so binding
# earlier fails. This depends_on is not decoration.
#
# ⚠️ PROJECT NUMBER, NOT PROJECT ID. One Google doc page writes the placeholder
# as service-PROJECT_ID@... and then shows a project number in its own worked
# example. The number is correct.
#
# Kept from mkt014 on the same conditional as aiplatform.googleapis.com: needed
# only if the AI-function ruling comes back YES, free to leave in place, and a
# room-wide failure to have left out.
#
# ⚠️ roles/discoveryengine.viewer is GONE, deliberately. It existed for
# ai.rank()'s reranker form. No Lab 3 task reranks anything. If one ever does,
# put it back — and remember the role name is counterintuitive: viewer has
# rankingConfigs.rank and user does not.
resource "google_project_iam_member" "alloydb_vertex" {
  project    = var.gcp_project_id
  role       = "roles/aiplatform.user"
  member     = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-alloydb.iam.gserviceaccount.com"
  depends_on = [google_alloydb_cluster.main]
}

# -----------------------------------------------------------------------------
# Student database user
# -----------------------------------------------------------------------------
# ⚠️ alloydbsuperuser is MORE load-bearing in Lab 3 than in either earlier lab,
# and it fails differently. Labs 1 and 2 needed it for CREATE EXTENSION, which
# denies loudly. Lab 3 needs it for the Index Advisor, which returns an EMPTY
# RESULT SET to a caller that does not hold it (shared-conventions §7 items
# 6-7). An empty advisor result is indistinguishable from an advisor that has
# nothing to recommend. Task 3's verification has to assert the role, not the
# row count.
resource "google_alloydb_user" "student" {
  cluster   = google_alloydb_cluster.main.id
  user_id   = local.student_email
  user_type = "ALLOYDB_IAM_USER"

  # ⚠️ TWO traps, both of which only appear on the SECOND apply:
  #   1. alloydbiamuser is NOT optional — database_roles declares the COMPLETE
  #      set, so omitting it reads as "revoke alloydbiamuser" and errors.
  #   2. ORDER MATTERS. It is a LIST and AlloyDB returns the roles sorted, so
  #      any other order is a permanent diff. Keep this ALPHABETICAL.
  database_roles = ["alloydbiamuser", "alloydbsuperuser"]

  depends_on = [google_alloydb_instance.primary]
}

# -----------------------------------------------------------------------------
# Student project-level IAM
# -----------------------------------------------------------------------------
# qwiklabs.yaml already grants roles/owner, so these look redundant. Grant them
# anyway: Google has been carving newly-minted permissions OUT of the basic
# roles, and a permission that postdates the basic-role definitions is not
# automatically in roles/owner.
#
# ⚠️ roles/geminidataanalytics.queryDataUser is GONE — that was QueryData, and
# Lab 3 builds no context set.
#
# ⚠️ VERIFY BOTH NAMES AT THE KEYBOARD before the first event:
#   gcloud iam roles describe roles/alloydb.databaseUser
#   gcloud iam roles describe roles/serviceusage.serviceUsageConsumer
# A role name that does not exist fails the apply for every student at once.
resource "google_project_iam_member" "student_roles" {
  for_each = toset([
    # alloydb.instances.executeSql — how Studio, the Data API and any MCP
    # surface actually run a statement. Also the IAM half of the two-layer
    # grant; the cluster-level database user above is the other half.
    "roles/alloydb.databaseUser",

    # Consuming a service on behalf of a project. Needed by anything the
    # student runs from Cloud Shell that calls a Google API as themselves.
    "roles/serviceusage.serviceUsageConsumer",
  ])
  project    = var.gcp_project_id
  role       = each.value
  member     = "user:${local.student_email}"
  depends_on = [google_alloydb_cluster.main]
}

# =============================================================================
# ⚠️ WHAT THIS FILE DELIBERATELY DOES NOT DO
# =============================================================================
# dataApiAccess. There is no Terraform attribute and no gcloud flag — verified
# 2026-08-18 against the google and google-beta providers, magic-modules, and
# both gcloud surfaces, with nothing queued. The enum is "ENABLED"; Google's
# prose says ALLOW_DATA_API directly above a curl block that sends ENABLED, and
# that is a docs bug. The PATCH takes ~134 s, so the setup script fires it and
# confirms later rather than blocking on it.
#
# Whether Lab 3 needs it at all depends on what Task 5's natural-language
# surface turns out to be. If it executes SQL through the AlloyDB MCP server,
# it does. The setup script does it either way — it is async and free.
#
# ---------------------------------------------------------------------------
# Read pool: DELIBERATELY ABSENT (D-32), same as mkt013 and mkt014.
# ---------------------------------------------------------------------------
# ⚠️ If one is ever added for Lab 3 — and an ops lab is the most plausible place
# in the series for that to be tempting — remember that database_flags AND
# observability_config are INSTANCE-level. Every setting above must be repeated
# on the pool verbatim or it silently behaves differently, which in an
# observability lab means the student reads the wrong instance's numbers.
# =============================================================================
