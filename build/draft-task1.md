<!--
mkt015 — DRAFT 1: Task 1
Written 2026-08-22, Lab 3 build session. Source: claude/cymbalgoal-lab3-database-center-ruling.md.

⚠️ WRITTEN TO SURVIVE BOTH OUTCOMES. The Inefficient queries finding depends on a refresh
cadence measured at roughly two hours (ruling §2). Nothing in this task promises the student
will see it. The two availability findings and the Last refresh stamp are always present, and
they carry the task on their own.

⚠️ SCREENSHOTS NEEDED — see the list handed over with this draft. The Inefficient queries
detail panel is the one that MUST be captured, because it is the shot that teaches the
students who do not get the finding.
-->

## Task 1. Triage: which instance, and is this even my problem?

Your pager went off, the ticker is slow, and you have a console you've never had a reason to open. The instinct is to go hunting for the slow query immediately. Resist it for about five minutes, because the first question on any incident isn't *which query*—it's **which machine**, and after that, *is this actually a database problem at all?*

**Database Center** is where that question gets answered. It's a fleet view: every managed database in your project—AlloyDB, Cloud SQL, Spanner, Bigtable—inventoried, health-scored against a set of standards, and sorted by what needs attention. Today you own one cluster, so the fleet is small. The habits are the same at three databases and at three hundred.

### Task 1.1: Open the fleet view

1. **In the Google Cloud console**, use the search bar at the top to find and open **Database Center**.

    ![The Database Center overview page showing the resource inventory summary and the Fleet Insights cards](img/database-center-overview.png)

2. Look first at the **resource inventory** across the top. You have one AlloyDB cluster running one primary instance, and Database Center knows its engine, its version, its location and how it was created.

    On a real fleet this is the screen that tells you whether the thing your users are complaining about is one of eleven Cloud SQL instances or the AlloyDB cluster somebody stood up last quarter. That sounds trivial until it's 9 a.m. and three teams are all certain it's someone else's database.

3. Below the inventory, find the **Fleet Insights** cards. These are the headline counts—open issues by category, and how that count has moved recently.

### Task 1.2: Read what it's actually flagging

4. Open **Health issues** and select **All issues**. Scroll down if the list isn't immediately visible.

    You'll see at least two findings, both about availability, and both real:

    | Priority | Category | Issue | Recommendation |
    | :---- | :---- | :---- | :---- |
    | Medium | Availability configuration | Resource not failover protected | Enable high availability |
    | Medium | Availability configuration | Not multi-region for disaster recovery | Create a secondary cluster |

5. Read those for meaning rather than ticking them off. Your instance is **zonal**: it lives in one zone of one region. If that zone has a bad day, CymbalGoal's ticker is down until it comes back, and no amount of index tuning changes that. The second finding goes further and asks what happens if the whole *region* has a bad day.

    Neither one is telling you that you did something wrong. They're telling you the trade you made—cost and provisioning speed against blast radius—and asking whether you meant it. On deadline day, with the ticker being the most visible thing the company owns, "did we mean it?" is a fair question to be asked.

    <ql-infobox>
    <strong>The Security tab will also tell you auditing isn't enabled</strong>, which is true and, for a single-tenant analytics app with one application identity, not today's fire. Worth knowing it's there. Not worth chasing at 9 a.m. on deadline day. Part of using a health surface well is being willing to leave findings open on purpose.
    </ql-infobox>

### Task 1.3: The most useful thing on this page is the timestamp

6. Open any finding's detail panel and find the **`Last refresh`** stamp near the top.

    ![The detail panel for a Database Center finding, with the Last refresh timestamp visible near the top of the panel](img/database-center-last-refresh.png)

7. Compare it to the time you started the workload in Task 0.

    There's a good chance the timestamp is **older than your incident**. Database Center evaluates a fleet on a cadence measured in hours, not seconds. Everything on this page was computed from a snapshot of a world that may not have included the problem you're currently having.

    **That's the single most valuable thing to take away from this surface**, and it's why five minutes here is right and forty would be a disaster. A fleet health page is for the standing questions—are we protected, are we compliant, is anything drifting—and those don't change minute to minute. It's the wrong instrument for "what is happening to me right now," and it doesn't announce that about itself. It just answers, confidently, using data from earlier.

8. Scroll the issue list once more. Depending on where your instance falls in that refresh cycle, you **may** also see a **Low** priority finding under **Performance & capacity**, called **Inefficient queries**, recommending that you create indexes.

    If it's there, open it. If it isn't, this is what it holds:

    ![The Inefficient queries detail panel, listing six recommended indexes with DDL and storage estimates, and a Go to Query insights button at the bottom](img/database-center-inefficient-queries.png)

    The panel names the instance, states plainly that it has queries running inefficiently, and lists **six** indexes it thinks would help—each with its `CREATE INDEX` statement, the storage it would cost, and how many queries it would touch. Then, at the bottom, a button labeled **Go to Query insights**.

    That button is the honest summary of this whole task. Database Center will tell you *which instance* is unhappy and *what kind* of unhappy. For *which query*, it hands you off—which is exactly what you're about to do.

9. One more panel is worth thirty seconds. Go to **Performance**, then **Performance metrics**, and find **Fleet performance insights**.

    Under load you'll see an AI-written summary of what's wrong across the fleet, in prose, naming inefficient query patterns against large tables without optimal indexes. Depending on your refresh timing it may instead read **No insights found**. Either way, no extra product and no extra entitlement produced it—it comes with the console.

You've got what this page can give you. Time to go find the actual queries.

<ql-infobox>
<strong>Business translation.</strong> Every dashboard you trust has a refresh cadence, and almost none of them display it as prominently as they display the number. That gap is where bad incident calls come from: someone reads a confident figure, doesn't ask when it was computed, and spends twenty minutes arguing about a graph that describes last hour's world. The habit to steal from this task is asking two questions of any panel before you act on it—<em>what window is this, and when was it last calculated?</em> Database Center answers both, in writing, which is more than most tools do. When you get back to your own monitoring, go and find out whether it does.
</ql-infobox>

### What you learned

| | |
| :---- | :---- |
| **Saw** | The fleet inventory, and why "which instance" comes before "which query" |
| **Read** | Two genuine availability findings, and the blast-radius trade behind them |
| **Learned** | That Database Center is computed on a cadence—and how to check when yours ran |
| **Learned** | Where the surface hands off when you need query-level detail |

**Coming up:** you know the instance is unhappy and you know it's about queries. Now you need to know *which* queries—and, more usefully, which part of CymbalGoal's application is issuing them. Query Insights answers both, and it's current to the minute.

---
