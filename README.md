# CymbalGoal — Agentic Operations: Database Intelligence

Companion repository for the CymbalGoal AlloyDB workshop.

CymbalGoal is a global football fan and analytics platform, running on 13,439 players and 796 clubs
drawn from the Big 5 European leagues plus the Champions and Europa Leagues. It's transfer deadline
day. Traffic is up, the ticker is busy, response times are creeping, and the person on call is a
developer rather than a DBA — which describes most on-call rotations most of the time.

You'll work the incident the way that developer would: triage from the Database Center, find the
expensive queries and the part of the app that issued them, ask the Index Advisor what it would do,
read what the instance is doing right now, and then ask the same questions again in plain English.

**You clone this repository during the lab.** Task 0 runs `setup/lab3-setup.sh` from it, which
creates the `cymbalgoal` database, loads the corpus, and starts the deadline-day workload.
Everything else is provisioned for you when you click **Start Lab** — the AlloyDB cluster, the IAM,
the database flags and the observability configuration.

```bash
git clone https://github.com/haggman/cymbalgoal-database-intelligence.git
```

> ⚠️ **This repository is under construction.** The lab it belongs to is in its prototype phase.
> The workload generator's query mix, worker counts and timings are first-cut hypotheses, not
> measured settings.

---

## What's in here

| Folder | What it is | Do you need it during the lab? |
| :-- | :-- | :-- |
| `setup/` | The Task 0 loader — creates the database, loads the corpus, builds the baseline indexes | **Yes.** |
| `workload/` | The deadline-day workload generator | **Yes.** Started for you by the loader. |
| `terraform/` | The infrastructure that provisions your lab cluster | No. Runs automatically at Start Lab. |
| `build/` | Internal prototype and verification scripts | **No. Not student-facing.** |

### `setup/`

`lab3-setup.sh` installs one client library, backgrounds `lab3-setup.py`, and returns your prompt
immediately. The loader creates the database, enables the extensions, applies the schema, loads
roughly 1.6 million rows across eight tables plus the scouting profiles, builds **six** baseline
indexes, runs `ANALYZE`, and then starts the workload.

**Six is deliberate, and it is the most important thing in this repository.** Those six indexes are
the ones a *search* application needs: join appearances to players, join events to games, walk a
valuation history. That was the app. Deadline day introduces access patterns nobody indexed for —
transfers by date, players by contract expiry, players by current club, events by player — because
nobody was querying that way when the indexes were designed.

Nothing here is sabotaged to give the Index Advisor something to find. The gaps are the ones the
shipped schema really has, which is why the lesson generalizes: **your indexes describe the queries
you used to run.**

### `workload/`

A multi-connection generator that makes the database work while you watch it.

Two properties are worth knowing before you read the code. Every statement returns an **aggregate**,
never rows — so the server does the reading and Cloud Shell stays out of the way. And every
statement carries a **sqlcommenter tag** naming the part of the app that issued it, so the console
can tell you *the transfer ticker is slow* rather than *a query is slow*.

```bash
bash workload/deadline-day.sh start     # background it
bash workload/deadline-day.sh report    # latency percentiles by app tag
bash workload/deadline-day.sh stop
```

`report` before a fix and `report` after it is the cheapest demonstration in the lab, and it works
even when a console surface is still catching up.

### `terraform/`

The cluster you used was built by this Terraform before you typed a single command.

⚠️ **This is a mirror.** The authoritative copy ships with the lab in the content repo at
`labs/mkt015-agentic-operations-database-intelligence/terraform/`. Keep the two in sync; a change
made only here never reaches a student.

Two things in it are worth reading even if you never run Terraform. The instance is the only
resource on the **google-beta** provider, because `observability_config` — where enhanced query
insights, wait-event tracking and comment preservation live — does not exist in the GA provider at
the pinned version. And `track_active_queries` **defaults to off**, which means a lab about reading
what your database is doing right now has to ask for that capability explicitly.

### `build/`

Not student-facing. Prototype scripts that answer "does this product actually behave the way the
docs say" before any lab text gets written.

---

## Rebuilding this in your own project

You'll need a Google Cloud project with billing, Terraform 1.12 or newer, and the `alloydb`,
`compute`, `servicenetworking`, `monitoring` and `aiplatform` APIs enabled.

- **PostgreSQL 18, pinned explicitly.** Never the default.
- **Region `us-central1` or `us-east1`** while enhanced query insights availability is unconfirmed
  elsewhere.

The one thing you cannot copy is the data: the staged corpus lives in a bucket owned by the course.
The source dataset is public and CC0, and the scouting profiles were generated once, offline.

---

## Source data

Football Data from Transfermarkt — <https://github.com/dcaribou/transfermarkt-datasets> — CC0 1.0.
Pinned snapshot, never downloaded live during a lab.

Scope: `GB1`, `ES1`, `IT1`, `L1`, `FR1`, `CL`, `EL`. 13,439 players · 796 clubs · 29,740 games ·
832,193 appearances · 417,617 game events · 297,822 valuations · 65,494 transfers · 65 competitions.
