#!/usr/bin/env python3
"""
CymbalGoal Lab 3 (mkt015) — the deadline-day workload generator.

⚠️ FIRST CUT, UNMEASURED. Written during the Lab 3 prototype session so there is
something to measure. Every weight, every worker count and every query in the
catalogue below is a hypothesis until the prototype has run it against a live
instance. Do not treat this file as settled.

WHAT IT IS FOR. Lab 3's story is an incident: transfer deadline day, load up,
response times creeping. That story needs a database that is actually under
load, and it needs the load to be legible from four different console surfaces —
Database Center, Query Insights, the Index Advisor, and Active Queries. Each of
those has to have something DIFFERENT to say, or the lab is one finding told
four times.

THE THREE DESIGN CONSTRAINTS, and they pull against each other:

  1. IT HAS TO RUN FROM CLOUD SHELL. There is no VM in this series. P-55
     measured the COPY path as client-CPU-bound, and Cloud Shell is the weak
     end of it. So this generator makes the SERVER work hard while the CLIENT
     does almost nothing: every statement returns an AGGREGATE, never rows.
     Reading 832,000 rows to return one number costs the client a single int.

  2. IT HAS TO BE ATTRIBUTABLE. Every statement carries a sqlcommenter comment
     naming the part of the app that issued it. That is what turns Task 2 from
     "this query is slow" into "the transfer ticker is slow", which is the
     sentence an on-call developer actually needs to say. It depends on
     preserve_comments and record_application_tags in the instance's
     observability config — see the Terraform.

  3. IT HAS TO BE HONEST. Every slow query here is slow because of a real gap
     in the shipped schema, not because it was written to be slow. The six
     baseline indexes serve the SEARCH application CymbalGoal used to be.
     Deadline day introduces access patterns nobody indexed for. That is a
     thing that happens to real systems, and it is why the Index Advisor is
     being asked a genuine question.

USAGE
    python3 deadline_day.py                 # run until stopped
    python3 deadline_day.py --seconds 600   # run for ten minutes
    python3 deadline_day.py --report        # percentiles from the last run

    touch workload/.stop                    # graceful stop
"""

import argparse
import json
import os
import random
import statistics
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STOP = os.path.join(HERE, ".stop")
OUT = os.path.join(HERE, "out")
SAMPLES = os.path.join(OUT, "samples.jsonl")

DB_NAME = os.environ.get("CG_DB", "cymbalgoal")

# ---------------------------------------------------------------------------
# THE QUERY CATALOGUE
# ---------------------------------------------------------------------------
# Each entry is (tag, weight, sql-builder). `tag` becomes the sqlcommenter
# controller value, so it is what shows up in Query Insights' TAGS view — keep
# the names in the language of the app, not the database.
#
# ⚠️ THE COLUMN IN EACH WHERE CLAUSE IS THE POINT. Annotated per query. If any
# of these columns ever gets an index in setup/lab3-setup.py's BASELINE_INDEXES,
# the corresponding query stops being interesting and Task 3 loses a finding.

def q_transfer_ticker(rnd):
    """Deadline-day ticker: what has moved in the last N days.

    UNINDEXED: transfers.transfer_date. The schema indexes transfers by
    player_id, because the search app looked up one player's history. Nobody
    ever asked "what happened today" until today.
    """
    days = rnd.choice([1, 3, 7, 14, 30])
    return f"""
        SELECT count(*), sum(transfer_fee), max(transfer_fee)
          FROM transfers
         WHERE transfer_date >= DATE '2025-01-01' - INTERVAL '{days} days'
           AND transfer_fee IS NOT NULL"""


def q_contract_watch(rnd):
    """Who is out of contract and therefore a free-agent target.

    UNINDEXED: players.contract_expiration_date.
    """
    m = rnd.choice([3, 6, 12, 18])
    return f"""
        SELECT main_position, count(*), avg(market_value_in_eur)::BIGINT
          FROM players
         WHERE contract_expiration_date IS NOT NULL
           AND contract_expiration_date < DATE '2025-01-01' + INTERVAL '{m} months'
         GROUP BY main_position"""


def q_squad_view(rnd):
    """One club's current squad.

    UNINDEXED: players.current_club_id. It is a foreign key, and PostgreSQL
    does not index foreign keys automatically — the single most common index
    gap in any schema, and it is sitting in this one honestly.
    """
    club = rnd.randint(1, 60000)
    return f"""
        SELECT count(*), avg(height_in_cm), sum(market_value_in_eur)
          FROM players
         WHERE current_club_id = {club}"""


def q_form_window(rnd):
    """Form over a date window — the heaviest of the routine queries.

    UNINDEXED: appearances.appearance_date, over 832,193 rows.
    """
    days = rnd.choice([7, 14, 30, 60])
    return f"""
        SELECT count(*), sum(goals), sum(assists), sum(minutes_played)
          FROM appearances
         WHERE appearance_date >= DATE '2025-01-01' - INTERVAL '{days} days'"""


def q_player_timeline(rnd):
    """Every event for one player.

    UNINDEXED: game_events.player_id, over 417,617 rows. The schema indexes
    game_events by game_id — the search app rendered a match, not a career.
    """
    pid = rnd.randint(1, 1200000)
    return f"""
        SELECT event_type, count(*)
          FROM game_events
         WHERE player_id = {pid}
         GROUP BY event_type"""


def q_scout_search(rnd):
    """Free-text scan of the scouting profiles.

    NO TEXT INDEX AT ALL in Lab 3 — no BM25, no trigram. This is a sequential
    scan across ~13,400 profiles of roughly 250 words each, which is a lot more
    bytes than the row count suggests. Included because it is the query most
    likely to make the instance's CPU visible in System Insights.
    """
    term = rnd.choice(["left-footed", "pressing", "set-piece", "loan",
                       "academy", "injury", "captain", "counter-attack"])
    return f"""
        SELECT count(*)
          FROM players
         WHERE profile_text ILIKE '%{term}%'"""


def q_league_table(rnd):
    """The dashboard aggregate. Big join, real work, no gimmick."""
    season = rnd.choice([2021, 2022, 2023, 2024])
    return f"""
        SELECT a.player_club_id, sum(a.goals) AS goals, count(*) AS apps
          FROM appearances a
          JOIN games g ON g.game_id = a.game_id
         WHERE g.season = {season}
         GROUP BY a.player_club_id
         ORDER BY goals DESC
         LIMIT 20"""


def q_heavy_rollup(rnd):
    """The long-runner. Its job is to still be running when someone looks.

    Task 4 reads the Active Queries view, and a view of actively running
    queries is empty unless something is actively running. Everything else in
    this catalogue finishes too fast to be caught. This one does not.
    """
    return """
        SELECT p.country_of_citizenship,
               count(DISTINCT a.player_id)  AS players,
               sum(a.goals)                 AS goals,
               sum(a.minutes_played)        AS minutes
          FROM appearances a
          JOIN players p ON p.player_id = a.player_id
          JOIN games   g ON g.game_id   = a.game_id
         WHERE a.appearance_date IS NOT NULL
         GROUP BY p.country_of_citizenship
         ORDER BY goals DESC NULLS LAST"""


# (tag, weight, builder). Weights are relative and UNMEASURED.
CATALOGUE = [
    ("transfer-ticker", 30, q_transfer_ticker),
    ("contract-watch",  15, q_contract_watch),
    ("squad-view",      20, q_squad_view),
    ("form-window",     15, q_form_window),
    ("player-timeline", 12, q_player_timeline),
    ("scout-search",     5, q_scout_search),
    ("league-table",     3, q_league_table),
]

HEAVY = ("deadline-rollup", q_heavy_rollup)

APP = "cymbalgoal-deadline-day"


def tagged(tag, sql):
    """sqlcommenter prefix.

    ⚠️ FORMAT IS A GUESS AND IS A PROTOTYPE ITEM. This is the shape
    sqlcommenter emits and the shape AlloyDB's TAGS view is documented to read,
    but it has not been verified end to end on this instance. If the TAGS view
    comes up empty, this line is the first suspect, not the observability
    config.
    """
    return f"/*application='{APP}',controller='{tag}',framework='psycopg-lite'*/ {sql}"


# ---------------------------------------------------------------------------
def make_connect():
    """One Connector, one connection per worker.

    Same public-IP + IAM path the loader uses. Do not "simplify" to psql:
    Cloud Shell's egress IP is dynamic, which would force 0.0.0.0/0 on the
    instance's authorized networks.
    """
    import subprocess
    from google.cloud.alloydb.connector import Connector, IPTypes

    def sh(c):
        return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()

    project = sh("gcloud config get-value project")
    user = sh("gcloud config get-value account")
    clusters = json.loads(sh("gcloud alloydb clusters list --format=json") or "[]")
    if not clusters:
        sys.exit("FATAL: no AlloyDB cluster in this project.")
    name = clusters[0]["name"]
    cluster = name.split("/")[-1]
    region = name.split("/locations/")[1].split("/")[0]
    instances = json.loads(sh(
        f"gcloud alloydb instances list --cluster={cluster} --region={region} --format=json") or "[]")
    primary = [i for i in instances if i.get("instanceType") == "PRIMARY"][0]
    instance = primary["name"].split("/")[-1]
    uri = f"projects/{project}/locations/{region}/clusters/{cluster}/instances/{instance}"

    connector = Connector()

    def connect():
        c = connector.connect(uri, "pg8000", user=user, db=DB_NAME,
                              enable_iam_auth=True, ip_type=IPTypes.PUBLIC)
        c.autocommit = True
        return c

    return uri, user, connect


def worker(wid, connect, catalogue, stop_at, results, lock, think_ms):
    rnd = random.Random(wid * 7919)
    tags = [t for t, w, _ in catalogue for _ in range(w)]
    conn = connect()
    while not os.path.exists(STOP) and time.time() < stop_at:
        tag = rnd.choice(tags)
        build = dict((t, f) for t, _, f in catalogue)[tag]
        sql = tagged(tag, build(rnd))
        t0 = time.time()
        try:
            cur = conn.cursor()
            cur.execute(sql)
            cur.fetchall()          # aggregates only — a handful of rows at most
            cur.close()
            ok = True
        except Exception as e:                                     # noqa: BLE001
            ok = False
            # A dropped connection mid-run is expected over a long workload.
            try:
                conn = connect()
            except Exception:                                      # noqa: BLE001
                time.sleep(1.0)
            sys.stderr.write(f"[w{wid}] {tag}: {type(e).__name__}: {e}\n")
        ms = (time.time() - t0) * 1000.0
        with lock:
            results.append({"t": time.time(), "tag": tag, "ms": ms, "ok": ok})
        if think_ms:
            time.sleep(rnd.uniform(0, think_ms) / 1000.0)


def heavy_worker(wid, connect, stop_at, results, lock, gap_s):
    rnd = random.Random(9999 + wid)
    tag, build = HEAVY
    conn = connect()
    while not os.path.exists(STOP) and time.time() < stop_at:
        sql = tagged(tag, build(rnd))
        t0 = time.time()
        try:
            cur = conn.cursor()
            cur.execute(sql)
            cur.fetchall()
            cur.close()
            ok = True
        except Exception as e:                                     # noqa: BLE001
            ok = False
            try:
                conn = connect()
            except Exception:                                      # noqa: BLE001
                time.sleep(1.0)
            sys.stderr.write(f"[h{wid}] {tag}: {type(e).__name__}: {e}\n")
        with lock:
            results.append({"t": time.time(), "tag": tag,
                            "ms": (time.time() - t0) * 1000.0, "ok": ok})
        time.sleep(gap_s)


def flusher(results, lock, stop_at):
    os.makedirs(OUT, exist_ok=True)
    seen = 0
    while not os.path.exists(STOP) and time.time() < stop_at:
        time.sleep(10)
        with lock:
            batch = results[seen:]
            seen = len(results)
        if batch:
            with open(SAMPLES, "a") as fh:
                for r in batch:
                    fh.write(json.dumps(r) + "\n")
            summarize(batch, prefix="  last 10s ")


def pct(xs, p):
    if not xs:
        return 0.0
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round((p / 100.0) * (len(xs) - 1)))))
    return xs[k]


def summarize(batch, prefix=""):
    by = {}
    for r in batch:
        by.setdefault(r["tag"], []).append(r["ms"])
    line = []
    for tag in sorted(by):
        v = by[tag]
        line.append(f"{tag} n={len(v)} p50={statistics.median(v):.0f} p95={pct(v,95):.0f}")
    print(prefix + " | ".join(line), flush=True)


def report():
    if not os.path.exists(SAMPLES):
        sys.exit(f"no samples at {SAMPLES}")
    batch = [json.loads(l) for l in open(SAMPLES)]
    print(f"{len(batch):,} samples over "
          f"{(batch[-1]['t'] - batch[0]['t'])/60:.1f} minutes\n")
    by = {}
    for r in batch:
        by.setdefault(r["tag"], []).append(r["ms"])
    print(f"{'tag':20s} {'n':>7s} {'p50 ms':>9s} {'p95 ms':>9s} {'p99 ms':>9s} {'max ms':>9s}")
    for tag in sorted(by, key=lambda t: -statistics.median(by[t])):
        v = by[tag]
        print(f"{tag:20s} {len(v):>7,} {statistics.median(v):>9.0f} "
              f"{pct(v,95):>9.0f} {pct(v,99):>9.0f} {max(v):>9.0f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=12,
                    help="routine-query connections. UNMEASURED default.")
    ap.add_argument("--heavy", type=int, default=2,
                    help="long-runner connections. Task 4 needs at least one.")
    ap.add_argument("--heavy-gap", type=float, default=15.0,
                    help="seconds between long-runner starts")
    ap.add_argument("--think-ms", type=float, default=250.0,
                    help="upper bound on per-worker pause. 0 is a stress test, not a workload.")
    ap.add_argument("--seconds", type=float, default=0.0, help="0 = until stopped")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    if args.report:
        return report()

    if os.path.exists(STOP):
        os.remove(STOP)
    uri, user, connect = make_connect()
    stop_at = time.time() + args.seconds if args.seconds else time.time() + 86400

    print(f"target   {uri}")
    print(f"as       {user}")
    print(f"workers  {args.workers} routine + {args.heavy} heavy")
    print(f"stop     touch {STOP}")
    print()

    results, lock, threads = [], threading.Lock(), []
    for i in range(args.workers):
        t = threading.Thread(target=worker, daemon=True,
                             args=(i, connect, CATALOGUE, stop_at, results, lock, args.think_ms))
        t.start()
        threads.append(t)
        time.sleep(0.15)          # stagger, so connection setup is not a thundering herd
    for i in range(args.heavy):
        t = threading.Thread(target=heavy_worker, daemon=True,
                             args=(i, connect, stop_at, results, lock, args.heavy_gap))
        t.start()
        threads.append(t)
    f = threading.Thread(target=flusher, daemon=True, args=(results, lock, stop_at))
    f.start()

    try:
        while any(t.is_alive() for t in threads):
            time.sleep(1)
    except KeyboardInterrupt:
        open(STOP, "w").close()
    print("\nstopped.")
    summarize(results, prefix="session  ")


if __name__ == "__main__":
    main()
