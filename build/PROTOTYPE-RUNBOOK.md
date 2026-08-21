# mkt015 Prototype Runbook

**Standalone.** Work top to bottom in a fresh Qwiklabs project. Assumes nothing except a
browser and Cloud Shell.

**The one rule:** this is a prototype session. Nothing here produces lab prose. Every phase
ends in a recorded number or a ruling, and a phase that can't produce one is itself the
finding. Lab 1 rewrote two of six tasks because prose came before measurement; Lab 2 rewrote
none.

**Set this once per Cloud Shell tab**, and every command below works as written:

```bash
export PROJECT=$(gcloud config get-value project)
export REGION=us-central1
export INST="projects/${PROJECT}/locations/${REGION}/clusters/cymbalgoal-cluster/instances/cymbalgoal-primary"
```

**Keep a scratch file open.** Several phases need a wall-clock time recorded, and the gap
between two of them is the measurement.

---

## Phase 0 — before you destroy the old project

Skip if the old lab has already expired. If it's still alive, it's worth five minutes: an
overnight project is the one thing a fresh project cannot give us.

Database Center can lag up to 24 hours (shared-conventions §7 item 18). Last night it showed
nothing query-related in a project ninety minutes old. A project that has now been running
overnight tells us whether that was lag or whether Database Center simply doesn't carry that
information — and those two answers send Task 1 in completely different directions.

1. Open **Database Center**. Record: does `cymbalgoal-cluster` appear in the inventory at all?
   What panels are populated? Is there a "last updated" or freshness stamp anywhere on the
   page? Screenshot it.
2. Open **Query Insights** on `cymbalgoal-primary`. Record whether the tags appear now, and
   which ones.
3. Then tear it down.

---

## Phase 1 — Start Lab, and prove the provisioning

**WHERE:** the Qwiklabs lab page, then Cloud Shell.

Start the lab and wait for Terraform. Expect roughly ten minutes; the cluster and instance
create dominates it.

### 1.1 Read the observability block off the API

The Terraform output echoes what we asked for. This reads what the instance actually settled
on, which is the number that counts.

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://alloydb.googleapis.com/v1beta/${INST}" \
  | python3 -m json.tool | grep -A14 -i observability
```

**Expect** (measured 2026-08-21, one clean run — a second run confirms it wasn't luck):

```
"enabled": true, "preserveComments": true, "trackWaitEvents": true,
"trackWaitEventTypes": true, "maxQueryStringLength": 20000,
"recordApplicationTags": true, "queryPlansPerMinute": 20,
"trackActiveQueries": true, "trackClientAddress": true,
"assistiveExperiencesEnabled": false
```

`assistiveExperiencesEnabled` **must** be false. True fails the instance create outright —
"assistive experiences cannot be enabled without enabling Gemini Cloud Assist" — and takes the
whole apply with it.

**Decision this drives:** if `enabled` or `trackActiveQueries` comes back false, enhanced query
insights is entitlement-gated, Task 2 falls back to standard Query Insights and Task 4 loses
wait events. Stop and say so before running anything else.

---

## Phase 2 — load the corpus

**WHERE:** Cloud Shell.

```bash
git clone https://github.com/haggman/cymbalgoal-database-intelligence.git
cd cymbalgoal-database-intelligence
bash setup/lab3-setup.sh
tail -f ~/cymbalgoal-setup.log
```

It backgrounds itself and takes about three minutes. When it finishes it starts the workload
automatically.

**⏱ RECORD:** the wall-clock time the line `### Starting the deadline-day workload ###`
appears. Call this **T0**. Several later measurements are "how long after T0."

**Baseline from the 2026-08-21 run**, for comparison:

| | |
| :-- | --: |
| Total | 162 s |
| Pass 1, eight tables | 103.4 s |
| Pass 2, profiles and embeddings | 21.2 s |
| Six baseline indexes | 1.1 s |
| Schema apply | 0.2 s |

**New this run — check the extensions block.** It now tries `pg_stat_statements` and reports
one of three outcomes: readable with a statement count, creatable but unreadable (the library
isn't preloaded), or not creatable at all. Phase 3's primary method depends on which.

Two known-good facts to confirm rather than assume: `google_db_advisor 1.1` and `hypopg 1.3.2`
should both appear in the extension list. They're what Task 3 runs on, and they need no
provisioning step.

### 2.1 Data API — check it *after* the load, not during

The setup script fires the `dataApiAccess` PATCH asynchronously and then reports on it too
early; a `<ABSENT>` reading at the end of the log is expected, not a failure. The PATCH takes
about 134 seconds. Once the load is done:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://alloydb.googleapis.com/v1/${INST}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('dataApiAccess','<ABSENT>'))"
```

Want `ENABLED`. **Open question, not a blocker:** this is inherited from mkt014 and it isn't
yet known whether Lab 3 needs it at all. If Phase 7's MCP server works without it, it comes out
of the lab along with a permission and 134 seconds.

---

### 2.2 🔴 THE COLUMNAR CHECK — do this before anything else

The first prototype cycle was spent measuring a database that had silently
solved its own problem. `enable_auto_columnarization` defaults **on**, so with the
engine enabled AlloyDB columnarized `appearances` on its own and the lab's central
slow query ran in 3.5 ms. The Index Advisor correctly found nothing.

The Terraform now sets `google_columnar_engine.enable_auto_columnarization = "off"`.
**Confirm it took.** In AlloyDB Studio on `cymbalgoal`:

```sql
SHOW google_columnar_engine.enabled;                  -- expect on
SHOW google_columnar_engine.enable_auto_columnarization;  -- expect off

EXPLAIN SELECT COUNT(*), SUM(goals), SUM(assists), SUM(minutes_played)
  FROM appearances
 WHERE appearance_date >= (SELECT max(appearance_date) FROM appearances) - INTERVAL '3 days';
```

**Want to see `Seq Scan on appearances`.** If the plan says
`Custom Scan (columnar scan)` the flag did not take, and everything measured after
this point is worthless — stop and say so.

---

## Phase 3 — is the workload actually slow? (the gate)

This is the phase that decides whether Lab 3 has a subject. Everything downstream assumes the
database is under genuine pressure.

**Don't use the console for this.** Console surfaces lag, and "is it slow" and "how long until
the console says so" are two different questions that are easy to collapse into one. Ask the
database directly.

**WHERE:** AlloyDB Studio in the console — AlloyDB → `cymbalgoal-cluster` → **AlloyDB Studio**,
database `cymbalgoal`, user is your lab account. Studio works without the Data API PATCH.

### 3.1 The primary method — `pg_stat_statements`

```sql
SELECT substring(query from '/\*.*?\*/')        AS tag,
       calls,
       round(mean_exec_time::numeric, 1)        AS mean_ms,
       round(max_exec_time::numeric, 1)         AS max_ms,
       round(total_exec_time::numeric / 1000, 1) AS total_s
FROM pg_stat_statements
WHERE query LIKE '%cymbalgoal-deadline-day%'
ORDER BY total_exec_time DESC
LIMIT 20;
```

**The criterion is `calls`, not elapsed time.** Wait until every tag has **100+ calls**, then
the percentiles mean something. That should take a couple of minutes, not ten. Re-run the query
until it does.

If Phase 2 reported `pg_stat_statements` as unusable, skip to 3.2.

### 3.2 The fallback — the generator's own timings

```bash
bash workload/deadline-day.sh report
```

Client-side samples, so it includes network round-trip from Cloud Shell, which
`pg_stat_statements` doesn't. Both are useful; the server-side numbers are the honest ones for
"is the database slow" and the client-side ones are closer to what a user would feel.

### 3.3 What to do with the answer

The eight tags, and the access pattern each one is meant to punish:

| Tag | Weight | Unindexed column it hits |
| :-- | --: | :-- |
| `transfer-ticker` | 30 | `transfers.transfer_date` |
| `squad-view` | 20 | `players.current_club_id` |
| `contract-watch` | 15 | `players.contract_expiration_date` |
| `form-window` | 15 | `appearances.appearance_date` |
| `player-timeline` | 12 | `game_events.player_id` |
| `scout-search` | 5 | — |
| `league-table` | 3 | `clubs.domestic_competition_id` |
| `deadline-rollup` | heavy lane | long-running, for Active Queries |

**Send me the table.** The ruling, and what follows from it:

- **Several tags in the hundreds of ms or worse** → the honest corpus is enough. Nothing
  changes, and the lab never has to admit to sabotage.
- **Everything under ~200 ms** → the corpus is too small to hurt through volume. The whole
  database is about 493 MB against roughly 64 GB of RAM on an 8-vCPU instance, so it's fully
  cached and there is no I/O to be slow. Levers in order: raise concurrency in the workload,
  then drop `cpu_count` to 4 in the Terraform (which also provisions faster), and only then
  `CG_SYNTHETIC`. Editing `work_mem` down is the last resort and, if used, the lab has to say
  out loud that it's set low and why.

### 3.4 One assumption to test while you're in Studio

`players` is 225 MB for 13,439 rows — about 17 KB a row, which is the 3072-dimension embedding
at roughly 12 KB. A value that size is over the TOAST threshold, so it's probably stored
out-of-line, which would mean a scan of `players` that never reads `profile_embedding` doesn't
touch those bytes at all and is far cheaper than the size suggests.

```sql
SELECT relname,
       pg_size_pretty(pg_relation_size(c.oid))       AS heap,
       pg_size_pretty(pg_total_relation_size(c.oid)
                      - pg_relation_size(c.oid))     AS toast_and_indexes,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;
```

If `players` heap is small and the bulk is TOAST, then `squad-view` and `contract-watch` are
cheaper than I assumed and the weights need rebalancing toward `appearances`.

---

## Phase 4 — the console surfaces, in order, with timestamps

Only start this once Phase 3 says the workload is genuinely slow. Watching a fast database
through a lagging console teaches nothing.

For each surface below, record **how long after T0** you first saw real data. Those gaps are
what Task 1 and Task 2's pacing are built on, and they're the numbers a self-study student two
weeks later will live or die by.

### 4.1 Database Center

**WHERE:** console → Database Center (it's a fleet-level surface, not under the AlloyDB
instance).

Record, specifically:

- Does `cymbalgoal-cluster` appear in the inventory, and how long after T0?
- Which panels have content — health, availability, data protection, security findings?
- Is there **any** query-level information at all?
- Is there a freshness or "last updated" stamp?

**Why this matters more than it looks.** Task 1 currently opens the lab with Database Center.
If it carries no query information, Task 1 can't be "find the slow query here" — and the honest
replacement is better: Database Center tells you *which instance is unhappy* and pointedly not
*which query*, which is exactly why the next click is Query Insights. The handoff between
surfaces becomes the lesson. But that has to be measured before it's written (S-37), and P-15
already says to frame Task 1 so a sparse view still counts as success.

If it's still empty after an hour, Task 1 moves out of first position. Say so.

### 4.2 Query Insights

**WHERE:** AlloyDB → `cymbalgoal-primary` → Query Insights.

- How long after T0 does anything appear?
- **Do the sqlcommenter tags show up?** Look for a TAGS view or an application/controller
  dimension carrying `cymbalgoal-deadline-day` and the individual tags. The emitted format is
  `/*application='cymbalgoal-deadline-day',controller='transfer-ticker',framework='psycopg-lite'*/`
  and **it is unverified against this view.** If the tags don't appear, suspect the comment
  format before suspecting the observability config — `preserveComments` and
  `recordApplicationTags` both read true.
- Can you drill from a slow statement into a plan? Screenshot one.
- Does the top-by-total-time list match what `pg_stat_statements` said in Phase 3? A
  disagreement is interesting and worth reporting.

**Decision this drives:** whether Task 2 can promise attribution by *part of the app*, or has to
settle for attribution by statement. Those are different tasks.

### 4.3 System Insights

Same instance, System Insights tab. Is there visible CPU or memory pressure, and does it line
up with the workload? Task 4 pairs this with Active Queries.

---

## Phase 5 — Active Queries

**WHERE:** AlloyDB → `cymbalgoal-primary` → Query Insights → Active Queries.

`trackActiveQueries` is on, so this should have content. The heavy lane runs the
`deadline-rollup` statement specifically so there's something long enough to catch in the act.

- Is the view populated, and are wait events visible?
- Can you see `deadline-rollup` while it's running?
- What wait event types actually appear? Name them.

**Decision this drives:** Tasks 2 and 4 risk being the same console page twice. The split that
justifies both is *which queries cost the most over time* against *what is running right now
and what is it waiting on*. That only works if this view genuinely shows something Query
Insights doesn't. If it doesn't, the two tasks merge and the lab gets shorter.

---

## Phase 6 — the Index Advisor

**WHERE:** AlloyDB Studio, database `cymbalgoal`.

Don't run this early. The advisor needs accumulated workload before it has an opinion, and
asking too soon gives a false negative on the most important task in the lab. Give it **at
least 30 minutes** past T0, and note how long it actually took.

```sql
SELECT current_user, session_user;
SELECT rolname FROM pg_roles
WHERE pg_has_role(current_user, oid, 'member') ORDER BY 1;
```

**Confirm `alloydbsuperuser` is in that list before reading anything into the result.** This is
the quiet failure in Lab 3: the advisor returns an *empty result set* to a caller without the
role, and an empty result is indistinguishable from an advisor that has nothing to say. Task
3's verification step will have to assert the role rather than the row count.

### 6.1 Run it on demand — this is Task 3's real mechanism

🔴 **Do not wait for the console's Recommendations column.** Measured 2026-08-21: it was empty in a
twelve-hour-old project, and the reason is `google_db_advisor.auto_advisor_schedule`, which defaults
to **`'EVERY 24 HOURS'`**. A 2–3 hour lab never reaches the first automated analysis. The advisor is
already enabled — `google_db_advisor.enabled` and `google_db_advisor.enable_auto_advisor` both
default **on** — so there is nothing to switch on and no API to enable. It simply has not run yet.

The on-demand function ignores the schedule and analyses now:

```sql
-- Has the advisor actually SEEN the workload? Ask this FIRST.
SELECT count(*) FROM google_db_advisor_workload_statements;

-- Run the analysis on demand.
SELECT * FROM google_db_advisor_recommend_indexes();

-- The recommendations, with estimated storage.
SELECT * FROM google_db_advisor_recommended_indexes;

-- Which query each recommendation came from — the teaching table.
SELECT * FROM google_db_advisor_workload_report;
```

`google_db_advisor_reset()` clears tracked queries if a clean second run is wanted.

**`workload_statements` is the step that kills the quiet failure.** An empty recommendation set means
either "the advisor saw your workload and has nothing to say" or "the advisor saw nothing" — and
those are indistinguishable until you count the statements it tracked. Task 3's verification will be
built on this, alongside the `alloydbsuperuser` check above.

Record:

- Does `workload_statements` show the deadline-day queries, and are the sqlcommenter tags intact?
- Which of the unindexed columns from the Phase 3 table does it name?
- How long after T0 before the on-demand call produced anything?
- Are the `CREATE INDEX` statements runnable verbatim?
- Apply one, wait, re-run the Phase 3 query — does that tag's `mean_ms` visibly drop?

That last one is Task 3's payoff and it needs a real before-and-after pair of numbers.

### 6.2 Optional — make the console column populate too

`google_db_advisor.auto_advisor_schedule` takes `'EVERY N HOURS'` and needs no restart. Setting it to
`'EVERY 1 HOURS'` gives a student who started the workload in Task 0 a chance of seeing the console
column fill by Task 3.

⚠️ **A bonus, never a step.** One hour is the floor and the lab cannot promise it. And ⚠️ **verify
the flag name against `supportedDatabaseFlags` before it goes anywhere near the Terraform** — an
unknown flag name fails the entire instance create for the whole room:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://alloydb.googleapis.com/v1beta/projects/${PROJECT}/locations/${REGION}/supportedDatabaseFlags" \
  | python3 -c "import json,sys; [print(f['flagName']) for f in json.load(sys.stdin).get('supportedDatabaseFlags',[]) if 'db_advisor' in f['flagName']]"
```

Also worth knowing while you are there: `google_db_advisor.enable_vector_index_advisor` defaults
**on**, so the advisor may recommend a ScaNN index on `profile_embedding` even though no Lab 3 query
does vector search. If that shows up as noise in the recommendation list, turn it off.

---

## Phase 7 — the Database Insights MCP server

The least-known surface in the lab. Establish, in order:

1. Does the server exist and what's its endpoint?
2. What does `tools/list` return — **verbatim**. Do not take a tool list from a docs page; that
   error already cost mkt014 two shipped claims (P-58).
3. Does it authenticate from Cloud Shell with ADC?
4. Does it need the Data API PATCH from Phase 2.1?
5. Can it answer the same questions Phases 4 through 6 answered in the console? That's the whole
   premise of Task 5.

If building an ADK agent turns out to be the right shape for Task 5, lift Lab 2's proven
pattern rather than rediscovering it: `adk create --model gemini-3.7-flash --region global`,
`McpToolset` with `tool_filter` on the toolset, `adk web` through Web Preview, and
`export PATH="$HOME/.local/bin:$PATH"` before `adk web` or it reports command-not-found.
**Hard-code the cluster region as its own constant** — `GOOGLE_CLOUD_LOCATION` will be `global`
for the model, and an agent that builds its instance path from it produces
`locations/global/clusters/…`, which doesn't exist.

---

## Phase 8 — two flags that must end as decisions

Both are set in the Terraform right now with no task using them. They came across from mkt014
as a standing open question and Lab 3 is where it closes, in one direction or the other.

### 8.1 `google_columnar_engine.enabled`

Candidate material: a columnar scan is a genuinely different repair from an index, which would
give the lab three kinds of fix instead of two. `ce116` in the content repo is prior art.

Test: take the slowest analytical tag from Phase 3, add its columns to the columnar engine,
re-measure. If the improvement is real and explicable in a sentence, it's a task. If not, pull
the flag.

### 8.2 `google_ml_integration.enable_cost_optimized_ai_functions`

Everything about proxy models is already measured — see `cymbalgoal-proxy-models-to-lab3.md`,
including the 470× figure and the confusion-matrix caveat. The only open question is fit.

**The gate, sharpened:** rule it in only if an `ai.*` call appears in Query Insights as an
attributable statement with its own latency, **and** the repair is visible in that same surface.
Both halves. If either fails, it comes out, and Lab 3's story doesn't get bent to keep it.

Ruling it OUT has a bonus: `ai.if()` is the only thing that needs `players.profile_embedding`,
so dropping it lets pass 2 of the load go, which is 21 seconds and 225 MB. The loader already
has `CG_PROFILES=0` for exactly that.

---

## What to send back

1. The setup log, including the new `pg_stat_statements` line.
2. The Phase 3 tag table — the gate.
3. The Phase 3.4 heap-vs-TOAST breakdown.
4. T0, and the lag to each console surface.
5. Whether the sqlcommenter tags reached Query Insights.
6. What Database Center actually shows, panel by panel.
7. The Index Advisor's recommendations, and one before/after pair.
8. The MCP `tools/list` output, verbatim.
9. Rulings on both flags.

Timings for anything open-ended, throughout. If a phase can't be completed, that's a finding
too — write down what blocked it rather than working around it quietly.
