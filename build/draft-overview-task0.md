<!-- ============================================================================
mkt015 — DRAFT 1: Overview + Task 0
Written 2026-08-22, Lab 3 build session. Not yet merged into en.md.

Voice drafted against claude/lab-writing-style-guide.md §1–§4 and checked
against §6. Self-check numbers are at the bottom of this file.

⚠️ TITLE: left at the provisional string on purpose. The change to
"AlloyDB Agentic Operations: From Symptom to Fix" is Patrick's call, and
when it lands it has to move in three places together — qwiklabs.yaml,
this H1, and the main.tf header.

⚠️ Task 0 is written to the DEFERRED runtime ruling: the workload runs in
Cloud Shell (claude/cymbalgoal-lab3-workload-runtime.md). The three
paragraphs that would change if the workload moves to a VM or a Cloud Run
worker pool are marked with an HTML comment so they're easy to find.
========================================================================= -->

# AlloyDB Under Pressure: From Symptom to Fix

## Overview

Somewhere in your company there's a database, and somewhere there's an on-call rotation, and sooner or later the two of them meet at an inconvenient hour. The person holding the pager usually wrote the application rather than the schema. They know what slow looks like from the outside—a graph going amber, a queue backing up, a message that starts with *"is anything going on with…"*—and they're about to open a database console they've had no reason to open before.

That's the seat you're taking today.

You'll work a live performance incident on **AlloyDB**, Google Cloud's PostgreSQL-compatible database, using the operational surfaces it ships with: **Database Center** for fleet triage, **Query Insights** for finding what's actually expensive, the **Index Advisor** for deciding what to change, **Active Queries** for reading what the instance is doing this second, and finally the **Database Insights MCP server**, which lets an AI agent ask all of those same questions on your behalf, in English.

The database will be genuinely busy while you do it. You start the workload yourself in Task 0 and it runs for the rest of the lab, so every number you see is produced by real concurrent traffic rather than a screenshot.

### The CymbalGoal story

**CymbalGoal** is a global football (soccer) fan and analytics platform. Fans follow clubs, track transfers, and argue about form across **13,439 players and 796 clubs** from the Big 5 European leagues plus the Champions and Europa Leagues. The company is fictional; the data is real, drawn from a public CC0 dataset and frozen at a fixed snapshot.

It's **transfer deadline day**, mid-morning. Traffic is up—everyone's watching the ticker—and the app is getting slower in a way nobody can quite pin down. Some pages feel fine. The scouting search is crawling. A support thread is filling up. The engineer on call is you, and you didn't design this schema.

Here's the part that makes this a fair fight rather than a puzzle. CymbalGoal's database is indexed, competently, for the application it used to be: a search product. Deadline day introduced access patterns nobody indexed for—transfers by date, players by contract expiry, events by player—because nobody was querying that way when those indexes were designed. Nothing is sabotaged. **Your indexes describe the queries you used to run**, and that's true of every production database you'll ever inherit.

### Five ways to ask "what's wrong," and what each one can't tell you

The lab walks across these surfaces in order. Each one answers a question the previous one raised, and each one has a hard edge.

| Surface | Answers | Can't tell you |
| :---- | :---- | :---- |
| **Database Center** | Which instance in a fleet is unhealthy, and against which standard | Which *query*—and it's a fleet view, so it isn't current to the minute |
| **Query Insights** | Which statements burned the most database time, and which part of the app issued them | What to change |
| **Index Advisor** | What to change, with an estimated payoff, from the workload it actually observed | Anything a B-tree index can't fix |
| **Active Queries** | What's running right now, and how long it's been running | Anything about the last hour |
| **An agent over the Database Insights MCP server** | All of the above, in plain English, and it'll take a swing at the ones the others refuse | Whether it's right |

That last row is the whole argument of the lab. An agent with read access to your operational data is a remarkable thing to have on deadline-day morning—and the only reason you can trust it is that you already know what the surfaces underneath it say. You'll get a measured demonstration of why: one of the recommendations you're handed in this lab, by a Google recommender, is **wrong**, and you'll have the numbers to prove it.

### Objectives

In this lab, you will learn how to:

* Triage a busy AlloyDB instance from **Database Center**, and recognize what a fleet health surface can and can't tell you mid-incident
* Read **Query Insights** to rank statements by total database time, and use **sqlcommenter application tags** to name the feature responsible rather than the SQL
* Run the **AlloyDB Index Advisor** on demand, read its recommendations critically, and apply one
* Measure a fix under live load instead of trusting an estimate—and tell the difference between query *shape* and query *timing*
* Use **Active Queries** to see what an instance is doing right now, and avoid the classic on-call misdiagnosis it protects you from
* Connect the **Database Insights MCP server** to an AI agent and ask the same operational questions in English
* Recognize the point where an automated recommender stops being able to help, and what to do next

### Prerequisites

* Comfort reading SQL—`SELECT`, `JOIN`, and a `WITH` clause without flinching
* Enough command line to run a script someone hands you
* No DBA experience assumed. If you've ever been paged for something you didn't build, you're the target audience
* Helpful, not required: having once been asked "can you just add an index?" by someone who meant well

### What you'll build

<!-- ⚠️ IMAGE PENDING — Nano Banana prompt supplied in the build conversation. -->
![Architecture: a Cloud Shell session running the CymbalGoal deadline-day workload against an AlloyDB PostgreSQL 18 primary instance, with five observation paths off the instance—Database Center, Query Insights, the Index Advisor, Active Queries, and the Database Insights MCP server feeding an AI agent](img/architecture.png)

Your AlloyDB cluster is **already being created for you** and should be ready by the time you need it. The workload, the indexes, and every diagnosis are yours.

## Setup and requirements

![[/fragments/startqwiklab]]

![[/fragments/gcpconsole]]

---

## Task 0. Start the database load and the deadline-day workload

Your cluster exists and it's empty, and an empty database has no performance problems worth investigating. Filling it takes a little under three minutes, and **none of those three minutes teaches you anything about the products this lab is here to show you.**

So you're going to start the load, walk away from it, and read the rest of this task while it runs. When the load finishes, the same script starts the deadline-day workload for you—which matters more than it sounds, because Query Insights shows *history*, and history takes time to accumulate. Starting the traffic now buys you twenty minutes of it for free.

### Task 0.1: Start the load

1. In the Google Cloud console, click **Activate Cloud Shell** in the top-right toolbar, and click **Continue** if you're prompted to.

    ![Activate Cloud Shell icon in the console toolbar](img/CloudShell.png)

    Cloud Shell gives you a small Linux VM with `gcloud`, Python, `git` and an editor already installed and already authenticated as your lab identity. The first activation takes about thirty seconds.

2. **In the Cloud Shell terminal**, clone the workshop repository and start the load:

    ```bash
    git clone https://github.com/haggman/cymbalgoal-database-intelligence.git
    cd cymbalgoal-database-intelligence
    bash setup/lab3-setup.sh
    ```

    Authorize Cloud Shell to use your credentials if you're asked.

    The script installs one client library, then **hands your prompt back immediately** while the load runs in the background. You should see a process ID and a log path within about twenty seconds.

3. Still in the terminal, watch it work:

    ```bash
    tail -f ~/cymbalgoal-setup.log
    ```

    You'll see it create the `cymbalgoal` database, add a short list of extensions, apply the schema, load roughly 1.6 million rows across eight tables, add the scouting profiles, build six indexes, run `ANALYZE`, and print what it actually found on disk. The last thing it prints is `### Starting the deadline-day workload ###`.

    **Leave this running and read on.** You don't need to watch it, but you do want this terminal doing something—more on that in a moment.

    <ql-warningbox>
    <strong>If you re-run <code>lab3-setup.sh</code></strong>—and it's safe to, every step is guarded by an existence check—you may see a red <code>HTTP 409</code> partway through, complaining that the instance can't accept an update while another operation is in flight. It looks fatal and it isn't. The script retries that call, and the second attempt normally lands.
    </ql-warningbox>

### Task 0.2: Keep the workload alive

<!-- ⚠️ RUNTIME-DEPENDENT. This entire sub-task exists only because the workload
lives in Cloud Shell. If it moves to a VM or a Cloud Run worker pool, 0.2
is deleted outright and Task 0 loses ~200 words. -->

The deadline-day workload runs from this Cloud Shell session, and Cloud Shell reclaims sessions that sit idle. If the session goes away, the traffic goes with it—silently. You'd arrive at Task 3, ask the Index Advisor what it recommends, and get told there's nothing to fix, which is a confusing thing to be told about a database you can see is slow.

Two habits make that a non-event:

1. **Keep a terminal doing something.** Once the load finishes, switch to watching the workload's own log:

    ```bash
    tail -f ~/cymbalgoal-workload.log
    ```

    It prints a summary line every few seconds—queries issued, the slowest tags, current rate. Glancing at it as you work is a decent habit anyway, and later in the lab it becomes the fastest evidence you have that a fix worked.

2. **Know how to restart it.** If the workload ever does stop, this brings it back:

    ```bash
    bash workload/deadline-day.sh start
    ```

    And this tells you whether it's running at all:

    ```bash
    bash workload/deadline-day.sh status
    ```

### Task 0.3: Where you'll be working

You'll bounce between two surfaces constantly today, and the lab names them the same way every time.

- **The Google Cloud console**—Database Center, Query Insights, AlloyDB Studio and Active Queries all live here. It's what filled the browser tab before you activated Cloud Shell.
- **The Cloud Shell terminal**—the command line, where the workload runs and where you'll drive an AI agent in the last task.

By default Cloud Shell opens across the bottom third of the console window, which keeps both visible at once. Clicking **Open in new window** pops it into its own browser tab instead. For this lab the split pane is usually the better choice—you'll be reading a console page and a terminal at the same time more than once—but either works, and **"back in the console" and "back in the Cloud Shell terminal" mean these two surfaces whichever mode you picked.**

![Cloud Shell open in split-pane mode below the Google Cloud console, with the terminal pane docked across the bottom of the window](img/open-terminal.png)

### Task 0.4: What that script just built, and the six indexes that matter

Three things are happening in the background process you started, and one of them is the setup for the rest of the lab.

**It's loading roughly 1.6 million rows across eight tables**, plus a layer Transfermarkt never published: 13,439 player and 796 club **scouting profiles**, about 250 words each, generated once offline and stored as an ordinary `TEXT` column. They're there because a fat text column changes how a table scans, and because deadline day's worst query goes looking through them.

**It's building exactly six indexes, by name.** Not the schema's full index set—six, chosen deliberately:

| Index | Supports |
| :---- | :---- |
| `appearances (player_id)` | A player's match history |
| `appearances (game_id)` | Everyone who played in a given game |
| `game_events (game_id)` | Goals and cards for a game |
| `player_valuations (player_id)` | A player's market-value history |
| `transfers (player_id)` | A player's transfer history |
| `games (competition_id, season)` | A competition's fixtures for a season |

Read that column of purposes and you can reconstruct the product: this is a database indexed to look things up **by player and by game**. That was the app. Deadline day asks it for transfers **by date**, players **by contract expiry**, players **by current club**, events **by player**—and none of those have an index behind them, because nobody was asking those questions when this list was written.

**And it's starting the workload**, a multi-connection generator that makes the server work hard while Cloud Shell stays out of the way. Every statement it issues returns an aggregate rather than rows, and every statement carries a **sqlcommenter tag** naming the part of the app that issued it. That second detail pays off in about fifteen minutes, when Query Insights tells you *the scouting search is slow* instead of *a query is slow*.

<ql-infobox>
<strong>Business translation.</strong> The idea to take back to work is that an index list is a historical document. It records the questions your application asked at the moment somebody last thought about it—and it keeps recording that answer long after the questions change. New feature, new report, new mobile screen, acquisition, seasonal traffic pattern: each one can introduce an access pattern that nobody indexed for, and none of them announce themselves. The database will keep answering. It'll just cost more every time. That's what makes a workload-observing advisor useful rather than a nicety, and it's the tool you'll reach for in Task 3.
</ql-infobox>

### What you learned

| | |
| :---- | :---- |
| **Started** | The CymbalGoal database load and the deadline-day workload, both from one script |
| **Learned** | Why the workload starts now rather than when you need it—Query Insights reports history |
| **Learned** | That CymbalGoal's six indexes describe the app it used to be, not the one running today |
| **Set up** | The two surfaces you'll work from, and how to restart the workload if it stops |

**Coming up:** your pager just went off. The first place an on-call developer looks is the fleet view—so that's where you'll start, and the first thing you'll learn there is what it can't tell you.

---
