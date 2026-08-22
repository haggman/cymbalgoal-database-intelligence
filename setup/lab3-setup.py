#!/usr/bin/env python3
"""
CymbalGoal Lab 3 (mkt015) — Task 0 provisioning loader.

Brings a freshly-provisioned mkt015 cluster from "empty PostgreSQL 18 instance"
to "the CymbalGoal database as a transfer-window app would actually have it" —
loaded, analyzed, indexed the way a search-era schema would be indexed, and
NOT indexed for the access patterns deadline day is about to introduce.

WHERE: Cloud Shell. Launched in the FOREGROUND by lab3-setup.sh in Task 0,
which then hands off to the workload in the same tab. See that script for why.

⚠️ PORTED FROM mkt014's setup/lab2-setup.py, NOT REWRITTEN. Every non-obvious
line in the loader was paid for once already — COPY rather than INSERT, the
stream that never touches disk, header detection rather than assumption,
column lists from the manifest rather than positional order, the reconnecting
session. Read mkt014's copy for that reasoning; it is not repeated here.

WHAT IS DIFFERENT IN LAB 3, and why:

  1. NO ScaNN INDEXES. Lab 3 does no vector search. The build was the single
     largest chunk of Lab 2's 212-second load, and skipping it is free time.

  2. THE BASELINE INDEXES ARE ISSUED HERE, BY NAME, AND THE LIST IS SHORT ON
     PURPOSE. This is the most important design decision in the file, so it
     gets the long comment below rather than a shrug.

  3. THE PROFILE PASS IS OPTIONAL. It costs ~22 s and Lab 3 may not need it.
     It stays ON by default for two reasons: profile_text makes `players` a
     genuinely fat table, which is the difference between a sequential scan
     that hurts and one that does not; and ai.if() needs profile_embedding if
     the cost-optimized AI function ruling comes back YES (D-36).
     Turn it off with CG_PROFILES=0.

  4. A SYNTHETIC HIGH-VOLUME TABLE, OFF BY DEFAULT. CG_SYNTHETIC=<millions>
     builds a deadline-day ticker table server-side. This exists so the
     prototype can MEASURE whether the real corpus can be made slow before
     anyone decides to add data to the story. Do not ship it on without a
     measurement that says the real corpus is not enough.

  5. IT REPORTS. Extensions actually present, indexes actually built, table
     sizes actually on disk. Lab 3 is a lab about reading what the database
     tells you; its loader may as well set the example, and the prototype
     needs these numbers anyway.
"""

import csv
import gzip
import io
import json
import os
import subprocess
import sys
import time

GCS = os.environ.get("CG_GCS", "gs://class-demo/alloydb-labs/cymbalgoal")
DB_NAME = os.environ.get("CG_DB", "cymbalgoal")
DO_PROFILES = os.environ.get("CG_PROFILES", "1") != "0"
SYNTHETIC_M = float(os.environ.get("CG_SYNTHETIC", "0"))   # millions of rows

PASS2_COLS = {"profile_text", "profile_embedding"}
ORDER = ["competitions", "clubs", "players", "games",
         "appearances", "game_events", "player_valuations", "transfers"]

EXPECT = {"players": 13439, "clubs": 796, "appearances": 832193}

# ---------------------------------------------------------------------------
# THE BASELINE INDEXES — and the ones deliberately left out
# ---------------------------------------------------------------------------
# The staged schema.sql creates NO indexes (Stage 3 re-emitted it that way);
# indexes.sql carries these six btrees plus two ScaNN indexes. Lab 3 issues the
# btrees itself and never reads indexes.sql, because it wants the btrees and
# does not want ScaNN.
#
# ⚠️ WHY THE LIST IS NOT LONGER, AND WHY THAT IS NOT SABOTAGE.
#
# The temptation in a lab about the Index Advisor is to withhold an index the
# database obviously needs, so the advisor has something to say. That produces
# a lab where the student fixes a problem the lab invented, which teaches the
# tool and nothing else.
#
# There is a better story available for free, because it is what actually
# happened to this schema. These six indexes are the ones a SEARCH application
# needs: join appearances to players, join events to games, walk a valuation
# history. That is the app CymbalGoal had. Deadline day introduces access
# patterns nobody indexed for, because nobody was querying that way when the
# indexes were designed:
#
#   transfers (transfer_date)                 — the ticker, by definition
#   players (contract_expiration_date)        — who is out of contract
#   players (current_club_id)                 — squad views; never indexed
#   appearances (appearance_date)             — form over a date window
#   game_events (player_id)                   — goals/cards for one player
#   clubs (domestic_competition_id)           — league tables
#
# Every one of those is a real gap in the shipped schema, not a manufactured
# one. The workload generator drives exactly these patterns. So the Index
# Advisor is being asked a genuine question, and the lesson generalizes: your
# indexes describe the queries you used to run.
#
# ⚠️ DO NOT ADD ANY OF THE SIX ABOVE TO THIS LIST. If a future change needs one,
# the workload generator has to change too, or Task 3 has nothing to find.
BASELINE_INDEXES = [
    ("idx_appearances_player",
     "CREATE INDEX IF NOT EXISTS idx_appearances_player ON appearances (player_id)"),
    ("idx_appearances_game",
     "CREATE INDEX IF NOT EXISTS idx_appearances_game ON appearances (game_id)"),
    ("idx_game_events_game",
     "CREATE INDEX IF NOT EXISTS idx_game_events_game ON game_events (game_id)"),
    ("idx_player_valuations_player",
     "CREATE INDEX IF NOT EXISTS idx_player_valuations_player ON player_valuations (player_id)"),
    ("idx_transfers_player",
     "CREATE INDEX IF NOT EXISTS idx_transfers_player ON transfers (player_id)"),
    ("idx_games_competition_season",
     "CREATE INDEX IF NOT EXISTS idx_games_competition_season ON games (competition_id, season)"),
]


def log(msg=""):
    print(msg, flush=True)


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------------------
# 0. Discover where we are
# ---------------------------------------------------------------------------
def discover():
    project = sh("gcloud config get-value project")
    user = sh("gcloud config get-value account")
    if not project or project == "(unset)":
        sys.exit("FATAL: no project set. gcloud config set project YOUR_PROJECT_ID")

    clusters = json.loads(sh("gcloud alloydb clusters list --format=json") or "[]")
    if not clusters:
        sys.exit("FATAL: no AlloyDB cluster in this project. Is provisioning still running?")
    name = clusters[0]["name"]
    cluster = name.split("/")[-1]
    region = name.split("/locations/")[1].split("/")[0]

    instances = json.loads(sh(
        f"gcloud alloydb instances list --cluster={cluster} --region={region} --format=json") or "[]")
    primary = [i for i in instances if i.get("instanceType") == "PRIMARY"]
    if not primary:
        sys.exit(f"FATAL: no PRIMARY instance in cluster {cluster}.")
    instance = primary[0]["name"].split("/")[-1]

    uri = f"projects/{project}/locations/{region}/clusters/{cluster}/instances/{instance}"
    log(f"project   {project}")
    log(f"region    {region}")
    log(f"cluster   {cluster}")
    log(f"instance  {instance}")
    log(f"you       {user}")
    log(f"target    {uri}")

    # PROTOTYPE VALUE, and cheap: what did observability_config actually settle
    # to? Terraform asked for enabled + track_active_queries; enhanced query
    # insights may be entitlement-gated, in which case the apply succeeds and
    # the fields come back false. Tasks 2 and 4 both depend on the answer.
    obs = primary[0].get("observabilityConfig")
    log(f"observability  {json.dumps(obs) if obs else '<ABSENT from instances.get>'}")
    log()
    return project, user, region, cluster, instance, uri


# ---------------------------------------------------------------------------
# 1. (removed) Data API PATCH
# ---------------------------------------------------------------------------
# 🔴 CUT 2026-08-22, deliberately, after it was measured doing harm.
#
# It was carried over from mkt014 unchanged, where it IS load-bearing: that
# lab's ADK agent drives the AlloyDB MCP server, whose execute_sql tools reach
# the instance over HTTPS, and the Data API is exactly what permits that.
#
# LAB 3 USES A DIFFERENT SERVER. The Database Insights MCP server
# (databaseinsights.googleapis.com/mcp) exposes seven READ-ONLY observability
# tools — aggregated query stats, wait events, index recommendations. Not one
# of them executes SQL, so nothing here ever wanted what the PATCH unlocks.
# AlloyDB Studio also works without it, measured, which matters because Task 3
# lives in Studio.
#
# WHAT IT COST US, measured 2026-08-22 on a live run:
#   * Enabling it RESTARTS THE INSTANCE. pg_postmaster_start_time() and
#     pg_stat_statements_info.stats_reset came back as the same millisecond.
#   * Every workload connection dropped at once — a wall of
#     "InterfaceError: network error" in the student's terminal.
#   * pg_stat_statements went to zero. That is the table Query Insights renders
#     and the Index Advisor reads. Early in the lab the workload rebuilds it
#     within minutes; late in the lab it would gut Tasks 2 and 3.
#   * It fires async and races other instance updates, so WHEN it lands is not
#     under our control — hence the 6x/20s 409 retry loop that also came out.
#
# So: an instance restart, a scary 409 the lab had to apologise for, an IAM
# permission and ~120 words of warning box, in exchange for a capability no
# task uses.
#
# ⚠️ IF A FUTURE TASK EVER NEEDS SQL-OVER-HTTPS, this comes back — see mkt014's
# setup/lab2-setup.py for the working version, including the /v1/ + "ENABLED"
# details (Google's own docs say ALLOW_DATA_API and are wrong) and the 409
# retry. Do not re-derive it.

# ---------------------------------------------------------------------------
# 2. Connect
# ---------------------------------------------------------------------------
def make_session(uri, user):
    from google.cloud.alloydb.connector import Connector, IPTypes

    connector = Connector()
    state = {"conn": None}

    def connect(db=DB_NAME):
        c = connector.connect(
            uri, "pg8000",
            user=user, db=db,
            enable_iam_auth=True,      # no password anywhere
            ip_type=IPTypes.PUBLIC,    # IAM gates access; the connector carries mTLS
        )
        c.autocommit = True
        return c

    def session():
        if state["conn"] is None:
            state["conn"] = connect()
            return state["conn"]
        try:
            cur = state["conn"].cursor()
            cur.execute("SELECT 1")
            cur.close()
        except Exception:                                          # noqa: BLE001
            state["conn"] = connect()
        return state["conn"]

    return connect, session


def run(session, sql):
    cur = session().cursor()
    cur.execute(sql)
    cur.close()


def scalar(session, sql):
    cur = session().cursor()
    cur.execute(sql)
    v = cur.fetchone()[0]
    cur.close()
    return v


def rows(session, sql):
    cur = session().cursor()
    cur.execute(sql)
    r = cur.fetchall()
    cur.close()
    return r


# ---------------------------------------------------------------------------
# 3. The bulk loader — verbatim from Lab 2
# ---------------------------------------------------------------------------
def copy_table(session, table, cols, gcs_uri):
    peek = subprocess.Popen(["gcloud", "storage", "cat", gcs_uri], stdout=subprocess.PIPE)
    with gzip.GzipFile(fileobj=peek.stdout, mode="rb") as gz:
        first = next(csv.reader(io.TextIOWrapper(gz, encoding="utf-8")))
    peek.stdout.close()
    peek.wait()
    has_header = [c.strip().lower() for c in first] == [c.strip().lower() for c in cols]

    conn = session()
    cur = conn.cursor()
    proc = subprocess.Popen(["gcloud", "storage", "cat", gcs_uri], stdout=subprocess.PIPE)
    try:
        with gzip.GzipFile(fileobj=proc.stdout, mode="rb") as gz:
            cur.execute(
                f'COPY {table} ({", ".join(cols)}) FROM STDIN '
                f'WITH (FORMAT csv, HEADER {"true" if has_header else "false"})',
                stream=gz,
            )
        conn.commit()
    finally:
        cur.close()
        proc.stdout.close()
        proc.wait()


def column_lists():
    manifest = json.loads(sh(f"gcloud storage cat {GCS}/manifest.json"))
    staged = manifest.get("staged_files")
    items = staged.items() if isinstance(staged, dict) else [(f.get("name"), f) for f in staged]
    cols = {}
    for key, meta in items:
        if isinstance(meta, dict) and meta.get("column_order"):
            table = str(key).split("/")[-1].replace(".csv.gz", "").replace(".csv", "")
            cols[table] = [c for c in meta["column_order"] if c not in PASS2_COLS]
    return cols


def preflight(cols):
    for t in ORDER:
        if t not in cols:
            sys.exit(f"FATAL: {t} has no column_order in the manifest. Never guess at this.")
        proc = subprocess.Popen(["gcloud", "storage", "cat", f"{GCS}/{t}.csv.gz"],
                                stdout=subprocess.PIPE)
        with gzip.GzipFile(fileobj=proc.stdout, mode="rb") as gz:
            first = next(csv.reader(io.TextIOWrapper(gz, encoding="utf-8")))
        proc.stdout.close()
        proc.wait()
        if len(first) != len(cols[t]):
            sys.exit(f"FATAL: {t} file has {len(first)} fields, column list has "
                     f"{len(cols[t])}. Refusing to load.")
        log(f"  {t:22s} {len(first):>3} fields  OK")


# ---------------------------------------------------------------------------
# 4. Synthetic volume — OFF by default, and it is an experiment
# ---------------------------------------------------------------------------
def build_synthetic(session, millions):
    """Server-side generated deadline-day ticker table.

    ⚠️ THIS IS A MEASUREMENT INSTRUMENT, NOT A SHIPPED FEATURE. The open
    question it answers: can the real 1.6M-row corpus be made genuinely slow on
    this instance, or does Lab 3 need volume that CymbalGoal does not have?

    Generated with generate_series on the SERVER, so it costs no GCS transfer
    and no Cloud Shell CPU — which matters, because P-55 measured the COPY path
    as client-CPU-bound and Cloud Shell is the weak end of it.

    If the honest workload turns out to be slow enough without this, delete the
    function. If it is not, this table earns its place in the story on its own
    terms — deadline-day traffic against a fan-facing ticker is exactly the kind
    of table that grows fast and gets indexed late.
    """
    n = int(millions * 1_000_000)
    log(f"  generating {n:,} ticker rows server-side")
    run(session, "DROP TABLE IF EXISTS ticker_impressions")
    run(session, """
        CREATE TABLE ticker_impressions (
            impression_id   BIGINT      PRIMARY KEY,
            player_id       INTEGER     NOT NULL,
            club_id         INTEGER,
            surface         TEXT        NOT NULL,
            country_code    TEXT        NOT NULL,
            shown_at        TIMESTAMPTZ NOT NULL,
            dwell_ms        INTEGER     NOT NULL,
            clicked         BOOLEAN     NOT NULL
        )""")
    t0 = time.time()
    # No index beyond the primary key, deliberately — see BASELINE_INDEXES.
    #
    # ⚠️ TWO THINGS THIS DELIBERATELY AVOIDS.
    #
    # 1. NO `%` ANYWHERE. pg8000 uses the "format" paramstyle, so a literal
    #    percent sign in a statement is a live grenade depending on whether the
    #    driver runs its parameter conversion. mod() is unambiguous.
    # 2. NO CORRELATED SUBQUERY PER ROW. Picking a player with a per-row
    #    `(SELECT ... OFFSET ...)` turns an N-row insert into N index walks and
    #    takes longer than the entire rest of the load. The player IDs are
    #    collected ONCE into an array and subscripted, which is O(1) per row.
    run(session, f"""
        INSERT INTO ticker_impressions
        WITH p AS (SELECT array_agg(player_id ORDER BY player_id) AS ids,
                          count(*)::INT                          AS n
                     FROM players)
        SELECT  g,
                p.ids[1 + mod(g * 7919, p.n)],
                NULL,
                (ARRAY['web','ios','android','partner'])[1 + mod(g, 4)],
                (ARRAY['GB','ES','IT','DE','FR','US','BR','JP'])[1 + mod(g, 8)],
                now() - (mod(g, 86400) * INTERVAL '1 second'),
                50 + mod(g, 9950),
                mod(g, 17) = 0
          FROM generate_series(1, {n}) AS g, p""")
    log(f"  ticker_impressions built in {time.time()-t0:.1f}s")


# ---------------------------------------------------------------------------
def main():
    t_start = time.time()
    project, user, region, cluster, instance, uri = discover()

    connect, session = make_session(uri, user)

    # --- database -----------------------------------------------------------
    log("### Database ###")
    c = connect("postgres")
    cur = c.cursor()
    cur.execute("SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = %s",
                (DB_NAME,))
    row = cur.fetchone()
    if row is None:
        cur.execute(f'CREATE DATABASE "{DB_NAME}"')
        log(f"  created {DB_NAME}, owned by {user}")
    elif row[0] == user:
        log(f"  {DB_NAME} already exists and you own it")
    else:
        sys.exit(f"FATAL: {DB_NAME} exists but is owned by '{row[0]}', not {user}.")
    cur.close()
    c.close()

    # --- extensions ---------------------------------------------------------
    # Lab 3's list is SHORT. Gone from Lab 2's: alloydb_scann (no vector
    # search), pg_textsearch (no BM25), pg_trgm (no context set).
    #
    # `vector` stays because schema.sql declares VECTOR(3072) columns and the
    # type has to exist before the DDL will parse — even if nothing queries it.
    #
    # google_ml_integration stays on the AI-function ruling (D-36).
    log("\n### Extensions ###")
    for ext in ("vector", "google_ml_integration"):
        run(session, f"CREATE EXTENSION IF NOT EXISTS {ext}")

    # ⚠️ MEASURE, DO NOT ASSUME. The build plan records google_db_advisor and
    # hypopg as installed by default in a fresh AlloyDB database — which was
    # observed on a virgin CLUSTER, in the postgres database. `cymbalgoal` was
    # just created from template1 and may or may not have inherited them.
    #
    # Task 3 is the Index Advisor. If this is wrong, Task 3 has no product, and
    # the failure mode is the quiet one again: a missing extension makes the
    # advisor function not exist, but a missing GRANT makes it return nothing.
    # Try to create them, report either way, and never fail the load over it.
    for ext in ("google_db_advisor", "hypopg"):
        try:
            run(session, f"CREATE EXTENSION IF NOT EXISTS {ext}")
        except Exception as e:                                     # noqa: BLE001
            log(f"  ⚠️ {ext}: {e}")

    # ⚠️ PROTOTYPE INSTRUMENT, not a lab requirement — and a candidate for
    # removal once the prototype is done.
    #
    # pg_stat_statements is the table Query Insights is built on. Reading it
    # directly answers "is the workload actually slow" with NO console lag at
    # all, which is what lets the prototype separate two questions that are
    # easy to confuse: whether the queries hurt, and how long the console takes
    # to say so.
    #
    # TWO ways this fails and they look nothing alike. The extension may not be
    # creatable at all, or it may create and then error on SELECT because the
    # library is not in shared_preload_libraries. So create it, then actually
    # read from it, and report which of the two happened.
    try:
        run(session, "CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
        n = scalar(session, "SELECT count(*) FROM pg_stat_statements")
        log(f"  pg_stat_statements         readable, {n} statements tracked")
    except Exception as e:                                         # noqa: BLE001
        log(f"  ⚠️ pg_stat_statements unusable: {e}")
        log("     (workload/deadline-day.sh report is the fallback measurement)")

    for name, ver in rows(session, "SELECT extname, extversion FROM pg_extension ORDER BY oid"):
        log(f"  {name:26s} {ver}")

    # --- schema -------------------------------------------------------------
    log("\n### Schema ###")
    schema_sql = sh(f"gcloud storage cat {GCS}/schema.sql")
    if not schema_sql.strip():
        sys.exit("FATAL: could not read schema.sql from Cloud Storage")
    present = scalar(session, f"""
        SELECT count(*) FROM information_schema.tables
        WHERE table_schema='public' AND table_type='BASE TABLE'
          AND table_name IN ({','.join("'" + t + "'" for t in ORDER)})""")
    if present == len(ORDER):
        log("  all 8 tables already exist — skipping (schema.sql is not re-runnable)")
    elif present == 0:
        t0 = time.time()
        run(session, schema_sql)
        log(f"  applied in {time.time()-t0:.1f}s")
    else:
        sys.exit(f"FATAL: {present} of {len(ORDER)} tables exist — a half-built schema. "
                 "Drop the database and re-run.")

    # --- pass 1 -------------------------------------------------------------
    log("\n### Pass 1 — eight relational tables ###")
    cols = column_lists()
    preflight(cols)
    t0 = time.time()
    for t in ORDER:
        n = scalar(session, f"SELECT count(*) FROM {t}")
        if n:
            log(f"  {t:22s} already loaded, {n:>9,} rows")
            continue
        s = time.time()
        copy_table(session, t, cols[t], f"{GCS}/{t}.csv.gz")
        n = scalar(session, f"SELECT count(*) FROM {t}")
        log(f"  {t:22s} {n:>9,} rows  {time.time()-s:>6.1f}s")
    log(f"  pass 1 complete in {time.time()-t0:.1f}s")

    # --- pass 2 -------------------------------------------------------------
    if DO_PROFILES:
        log("\n### Pass 2 — profiles and embeddings ###")
        t0 = time.time()
        # DROP FIRST, not just at the end: a run that dies mid-pass leaves the
        # staging tables behind, and every later inspection of this schema sees
        # a duplicate copy of the profile columns.
        for t in ("_players_profiles", "_clubs_profiles"):
            run(session, f"DROP TABLE IF EXISTS {t}")
        for t, key in (("players", "player_id"), ("clubs", "club_id")):
            run(session, f"""CREATE TABLE IF NOT EXISTS _{t}_profiles (
                                 {key} INTEGER, profile_text TEXT,
                                 profile_embedding VECTOR(3072))""")
            if scalar(session, f"SELECT count(*) FROM _{t}_profiles") == 0:
                copy_table(session, f"_{t}_profiles",
                           [key, "profile_text", "profile_embedding"],
                           f"{GCS}/{t}_profiles.csv.gz")
            run(session, f"""UPDATE {t} tgt
                                SET profile_text = src.profile_text,
                                    profile_embedding = src.profile_embedding
                               FROM _{t}_profiles src
                              WHERE tgt.{key} = src.{key}""")
        n_p = scalar(session, "SELECT count(*) FROM players WHERE profile_embedding IS NOT NULL")
        n_c = scalar(session, "SELECT count(*) FROM clubs   WHERE profile_embedding IS NOT NULL")
        assert n_p == EXPECT["players"], f"expected {EXPECT['players']:,} player profiles, got {n_p:,}"
        assert n_c == EXPECT["clubs"], f"expected {EXPECT['clubs']:,} club profiles, got {n_c:,}"
        for t in ("_players_profiles", "_clubs_profiles"):
            run(session, f"DROP TABLE IF EXISTS {t}")
        log(f"  {n_p:,} player and {n_c:,} club profiles  {time.time()-t0:.1f}s")
        log("  dropped staging tables")
    else:
        log("\n### Pass 2 — SKIPPED (CG_PROFILES=0) ###")

    # --- synthetic volume ---------------------------------------------------
    if SYNTHETIC_M > 0:
        log(f"\n### Synthetic volume — {SYNTHETIC_M}M rows (CG_SYNTHETIC) ###")
        build_synthetic(session, SYNTHETIC_M)
    else:
        log("\n### Synthetic volume — OFF (default) ###")

    # --- baseline indexes ---------------------------------------------------
    # ⚠️ AFTER the load, never before. And read the long comment on
    # BASELINE_INDEXES before adding anything to this list.
    log("\n### Baseline indexes ###")
    t0 = time.time()
    for name, ddl in BASELINE_INDEXES:
        s = time.time()
        run(session, ddl)
        log(f"  {name:32s} {time.time()-s:>5.1f}s")
    log(f"  six baseline indexes in {time.time()-t0:.1f}s")
    log("  ⚠️ deadline-day access patterns are deliberately UNINDEXED — that is Task 3's subject")

    # --- statistics ---------------------------------------------------------
    # Without this the planner is guessing and the Index Advisor has nothing to
    # reason about. Stale statistics are their own realistic ops problem, and a
    # tempting second lesson — but two root causes in one incident is one too
    # many for a 15-minute task. Analyze, and keep the lab's variable single.
    log("\n### ANALYZE ###")
    t0 = time.time()
    run(session, "ANALYZE")
    log(f"  done in {time.time()-t0:.1f}s")

    # --- what we actually built --------------------------------------------
    log("\n### On disk ###")
    for tbl, sz, rowcount in rows(session, """
            SELECT c.relname,
                   pg_size_pretty(pg_total_relation_size(c.oid)),
                   c.reltuples::BIGINT
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND c.relkind = 'r'
             ORDER BY pg_total_relation_size(c.oid) DESC"""):
        log(f"  {tbl:24s} {sz:>10s}  ~{rowcount:,} rows")

    # --- the gate Task 1 reads ---------------------------------------------
    log("\n### provisioning_status ###")
    run(session, """CREATE TABLE IF NOT EXISTS provisioning_status (
                        players INTEGER, clubs INTEGER, appearances INTEGER,
                        completed_at TIMESTAMPTZ DEFAULT now())""")
    run(session, """INSERT INTO provisioning_status (players, clubs, appearances)
                    SELECT (SELECT count(*) FROM players),
                           (SELECT count(*) FROM clubs),
                           (SELECT count(*) FROM appearances)""")

    # Read it back. The section previously printed its header and nothing else,
    # which reads exactly like a step that failed — and `terraform output
    # instructor_preflight` tells an instructor to run
    # `SELECT * FROM provisioning_status;`, so if this table were ever missing
    # the output would be pointing at a relation that does not exist.
    for pl, cl, ap, at in rows(session, """
            SELECT players, clubs, appearances, completed_at
              FROM provisioning_status ORDER BY completed_at DESC LIMIT 1"""):
        log(f"  players {pl:,}  clubs {cl:,}  appearances {ap:,}  at {at}")

    log("\n" + "=" * 62)
    log(f" SETUP COMPLETE in {time.time()-t_start:.0f}s")
    log(f" players {scalar(session, 'SELECT count(*) FROM players'):,}  "
        f"clubs {scalar(session, 'SELECT count(*) FROM clubs'):,}  "
        f"appearances {scalar(session, 'SELECT count(*) FROM appearances'):,}")
    log("=" * 62)


if __name__ == "__main__":
    main()
