---

## Task 2. Find the expensive queries, and the feature behind them

Database Center told you *this instance is unhappy, and it's about queries.* That's the end of what a fleet view can do. **Query Insights** is where the same question gets a specific answer, and it's current to the minute rather than to the refresh cycle.

You're looking for two things. Which statements are costing you the most, and—much more useful when you're the one who has to go fix something—**which part of the CymbalGoal application is issuing them.**

### Task 2.1: Open Query Insights and read the load chart

1. **In the Google Cloud console**, open **AlloyDB**, click **cymbalgoal-cluster**, and choose **Query insights** in the left-hand navigation.

    It opens on the **Executed Queries** tab with the time range set to **1 hour**. Leave both alone for now.

    <ql-warningbox>
    <strong>Ignore the "AI assisted troubleshooting" banner at the top of the page</strong>, and don't spend time on its <strong>Enable</strong> button. It asks for a configuration this lab environment can't grant, and it will keep telling you Gemini Cloud Assist isn't enabled no matter how many times you enable it. Close the banner with the <strong>X</strong> and carry on—nothing in this lab needs it.
    </ql-warningbox>

2. Look at **Database Load by execution time**, the chart filling the top half of the page. The dropdown beside its title is set to **Wait event types**.

    You should see a solid band of load that starts a little while after you began generating traffic and then holds steady. Underneath the chart is the legend, and **the legend is the interesting part**:

    ```
    Client: 0    CPU: 31.48s    Internal wait event: 0    IO: 0s
    IPC: 1.74s   LWLock: 0s     Timeout: 0
    ```

    Your seconds will differ. The shape almost certainly won't.

3. Read that legend as a diagnosis, because it rules out two entire families of problem in about five seconds.

    | If this dominated | It would mean |
    | :---- | :---- |
    | **IO** | The database is waiting on disk. Working set too big for memory, or storage too slow |
    | **LWLock** or **Lock** | Queries are queueing behind each other for the same rows or internal structures. A contention problem |
    | **Client** | The database is waiting on *you*—the application isn't reading results fast enough |
    | **CPU** | The server is genuinely working. Doing too much, or doing it inefficiently |

    Yours is **CPU**, overwhelmingly, with a sliver of **IPC**—processes coordinating with each other, which is what parallel query workers do. IO is a flat zero.

    So the database isn't stuck waiting for anything. It's busy computing, which means somebody is asking it to do more work than it should have to. **That's a query problem, and it's about to have a name.**

    <ql-infobox>
    <strong>Why zero I/O, on 1.6 million rows?</strong> The CymbalGoal corpus is around 500 MB and the instance has tens of gigabytes of RAM, so after a few minutes of traffic the entire database is sitting in memory. Nothing ever waits for disk. That's realistic for a great many production databases—people are often surprised how much of their data fits in RAM—and it's a useful thing to establish early, because it means every millisecond you're about to hunt down is CPU spent on rows that were already in memory. Reading rows you didn't need to read is the expensive habit here, not fetching them.
    </ql-infobox>

### Task 2.2: The table that names names

4. Scroll down to **Top dimensions by database load** and make sure the **Queries** tab is selected.

    Six tabs sit across the top of this panel—**Queries**, **Wait event types**, **Wait events**, **Databases**, **Users**, **Tags**—and they're six different ways to slice the same load. Queries is where you start.

5. Look at the column the table is already sorted by: **Total execution time (ms)**, descending.

    **That default is correct, and it's worth knowing why.** A database's problem is never the query with the worst single run. It's the query that consumes the most time *in aggregate*, which is `calls × duration`. A statement running in 8 milliseconds a hundred thousand times an hour will hurt you more than a five-second report that runs twice. Total execution time is the only column that captures both, and sorting by it is the difference between fixing your morning and fixing something you noticed.

6. Now read the top four rows. Yours will carry different numbers and possibly a different order past the first row, but the shape will be recognizable:

    | Query (truncated) | Avg execution time (ms) | Total execution time (ms) |
    | :---- | --: | --: |
    | `controller='form-window'` | 507 | **34,612,767** |
    | `controller='player-timeline'` | 262 | 11,127,779 |
    | `controller='scout-search'` | 603 | 6,540,793 |
    | `controller='deadline-rollup'` | **7,009** | 4,647,357 |

    **`form-window` is the answer.** It costs roughly three times the total database time of the next query down, and more than all three of the others put together.

7. Then look at what the two columns disagree about, because this is the whole skill.

    **`deadline-rollup` is by far the slowest query on the instance**—seven seconds a run, fourteen times slower per call than `form-window`. It's also **last** of these four by total cost, consuming roughly a seventh of what `form-window` does. It runs occasionally; `form-window` runs constantly.

    If you'd sorted by **Avg execution time** and started work at the top, you'd have spent your morning optimizing the report nobody's waiting on, and the ticker would still be slow. **Slowest and most expensive are different questions.** The console defaults to the right one; plenty of tools don't, and plenty of engineers reach for the wrong one under pressure.

    Remember the question Task 0 left open, comparing `form-window` at hundreds of milliseconds against `scout-search` at rather more? There's the answer. `scout-search` is slower per call and `form-window` runs so much more often that it wins the total by five times over. Chase `form-window` first.

### Task 2.3: Why you can read a feature name at all

8. Look at the **Query** column properly. Every row begins with something like this:

    ```
    /*application='cymbalgoal-deadline-day',controller='form-window',framework='psycopg'*/ SELECT ...
    ```

    That prefix is a **sqlcommenter** tag—a structured SQL comment the application attaches to every statement it sends, naming the app, the feature and the driver. It isn't a Google invention; it's an open convention that most modern ORMs and frameworks can emit with a configuration flag or two.

9. Understand what it just bought you, because it changed the sentence you get to say.

    Without it, the top row of that table is a `SELECT` against `appearances` joined to `players`, and finding out which part of CymbalGoal issues it means grepping a codebase during an incident. With it, the answer is **the form window feature is consuming half your database**, which is a sentence you can say to a product owner and act on in the same minute.

    <ql-infobox>
    <strong>This is a real AlloyDB differentiator, and it's easy to miss.</strong> PostgreSQL records a statement's identity starting <em>after</em> any leading comment—so the open-source <code>pg_stat_statements</code> view, running on this very instance, has stored these same queries with the prefix <strong>stripped off</strong>. Same database, same statements, two pipelines: AlloyDB's Query Insights preserves the tag, and the standard tooling throws it away. If you've ever wondered why your own query stats are anonymous SQL with no idea which service sent them, this is usually why.
    </ql-infobox>

10. Click through the other tabs in this panel for a moment—**Wait event types**, **Databases**, **Users**, **Tags**—to see the same load sliced other ways. On a multi-tenant instance the **Users** and **Databases** views are how you find out *whose* workload is the problem, which is a political question as much as a technical one.

### Task 2.4: What the console won't hand you yet

11. Look at the **Recommendations** column in the Queries table.

    It's empty, or nearly so. That column is where AlloyDB's Index Advisor publishes its findings, and it runs on a schedule—the same class of delay that left Database Center's performance card silent. On a young cluster it has usually not yet spoken.

12. That's not a dead end. **You don't have to wait for the advisor's schedule—you can ask it directly, on demand, and get an answer in seconds.** Which is the next task.

    Before you go, note what you now know that you didn't fifteen minutes ago: the load is CPU rather than I/O or locking, the single most expensive statement on the instance belongs to the **form window**, and the slowest query on the instance is not the one to fix first. That's a diagnosis. What's missing is a repair.

You've got a name. Time to get a fix.

<ql-infobox>
<strong>Business translation.</strong> Two habits to take back. The first is <em>tag your queries</em>: if your ORM or driver can emit sqlcommenter comments, turning that on costs an afternoon and permanently changes incident conversations from "a query is slow" to "checkout is slow." The second is <em>sort by total, not by worst</em>. Every performance tool you'll ever use offers both columns, they disagree constantly, and the one that feels alarming is rarely the one costing you money. The seven-second report is the one people complain about in meetings; the 500-millisecond query running ten thousand times an hour is the one paying for your instance.
</ql-infobox>

### What you learned

| | |
| :---- | :---- |
| **Diagnosed** | The load is CPU-bound—not I/O, not locking—readable from one chart legend |
| **Found** | `form-window` is the single most expensive statement on the instance |
| **Learned** | Why total execution time is the right sort, and what sorting by average would have cost you |
| **Saw** | A sqlcommenter tag survive into the console, naming the feature rather than the SQL |

**Coming up:** you know which query. You don't yet know what to do about it—and the tool that answers that is sitting one page away, waiting to be asked rather than waiting for its schedule.

---
