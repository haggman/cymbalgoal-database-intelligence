---

## Task 2. Find the expensive queries, and the feature behind them

Database Center told you *this instance is unhappy, and it's about queries.* That's the end of what a fleet view can do. **Query Insights** is where the same question gets a specific answer, and it's current to the minute rather than to the refresh cycle.

You're after two things. Which statements are costing you the most—and, far more useful when you're the one who has to go fix something, **which part of the CymbalGoal application is issuing them.**

### Task 2.1: Read the load chart before you read anything else

1. **In the Google Cloud console**, open **AlloyDB**, click **cymbalgoal-cluster**, and choose **Query insights** in the left-hand navigation.

    It opens on the **Executed Queries** tab with the time range set to **1 hour**. Leave both alone.

    <ql-infobox>
    <strong>If the page says data is unavailable, give it a few minutes.</strong> Query Insights needs a little time after a cluster is created before it starts reporting, and you've been moving quickly. Read on—the explanation below is worth having before the numbers arrive—then come back and refresh.
    </ql-infobox>

2. Look at **Database Load by execution time**, the chart across the top. The dropdown beside its title is set to **Wait event types**, and the legend underneath it is the part that matters:

    ```
    Client: 0    CPU: 33.5s    Internal wait event: 0
    IO: 0s       IPC: 1.6s     LWLock: 0s
    ```

    Your seconds will differ. The shape won't.

3. Read that legend as a diagnosis, because it eliminates two entire families of problem in about five seconds.

    | If this dominated | It would mean |
    | :---- | :---- |
    | **IO** | The database is waiting on disk—working set too big for memory, or storage too slow |
    | **LWLock** or **Lock** | Queries are queueing for the same rows or internal structures. A contention problem |
    | **Client** | The database is waiting on *you*—your application isn't reading results fast enough |
    | **CPU** | The server is genuinely working. Doing too much, or doing it inefficiently |

    Yours is **CPU**, overwhelmingly, with a sliver of **IPC**—processes coordinating with each other, which is what parallel query workers do. IO is a flat zero.

    Nothing here is stuck. The database is busy *computing*, which means somebody is asking it to do more work than it should have to. **That's a query problem, and it's about to have a name.**

    <ql-infobox>
    <strong>Zero I/O, on 1.6 million rows?</strong> The CymbalGoal corpus is around 500 MB and this instance has tens of gigabytes of RAM, so after a few minutes of traffic the whole database is resident in memory and nothing ever waits for disk. That's true of a great many production databases—people are routinely surprised how much of their data fits in RAM—and it's useful to establish early, because every millisecond you're about to chase is CPU spent on rows that were <em>already in memory</em>. Reading rows you didn't need to read is the expensive habit here, not fetching them.
    </ql-infobox>

### Task 2.2: The table that names names

4. Scroll down to **Top dimensions by database load**, with the **Queries** tab selected.

    Six tabs run across the top of this panel—**Queries**, **Wait event types**, **Wait events**, **Databases**, **Users**, **Tags**. Six ways of slicing the same load. Start with Queries.

5. Note the column the table is already sorted by: **Total execution time (ms)**, descending.

    **That default is correct, and knowing why is most of this task.** A database's problem is rarely the query with the worst single run. It's the query consuming the most time *in aggregate*—`calls × duration`. A statement finishing in 30 milliseconds a hundred thousand times an hour will hurt you more than a nine-second report that runs twice. Total execution time is the only column carrying both numbers at once.

6. Scroll the table sideways to bring **Avg execution time**, **Total execution time** and **Times called** into view together, then read all three. Something like this:

    | Feature | Avg (ms) | Total (ms) | Times called |
    | :---- | --: | --: | --: |
    | `form-window` | 658 | **19,645,729** | 29,821 |
    | `player-timeline` | 331 | 6,194,576 | 18,675 |
    | `scout-search` | 969 | 4,580,492 | 4,726 |
    | `deadline-rollup` | **9,084** | 2,643,586 | 291 |
    | `league-table` | 744 | 2,150,749 | 2,888 |
    | `squad-view` | 27 | 513,411 | 18,857 |
    | `contract-watch` | 40 | 463,303 | 11,394 |
    | `transfer-ticker` | 50 | 376,319 | 7,447 |
    | `transfer-desk` | 45 | 45,831 | 1,000 |
    | `COPY appearances …` | **40,667** | 40,667 | **1** |

    Your numbers will be different and the order below the top few may shift. The story won't.

7. **`form-window` is the answer.** Nearly 20 million milliseconds—more than three times the next query down, and over half of all the database time on this instance. One feature, half your morning.

8. Now read the same table for the trap, because two other rows are more interesting than the winner.

    **`deadline-rollup` is the slowest query in the workload**—nine seconds a call, fourteen times slower than `form-window`. It's *fourth* by total cost. It runs 291 times where `form-window` runs 29,821.

    And look at the bottom row. **`COPY appearances` took forty seconds**—the slowest single statement on the entire instance by a factor of four. It ran **once**, returned 832,193 rows, and will never run again. It's the data load you started in Task 0.

    **Sort this table by *Avg execution time* and your top two are a report nobody's waiting on and a load that already finished.** You'd spend deadline-day morning optimizing neither of the things making your users angry. The console defaults to the right column; plenty of tools don't, and plenty of engineers reach for the wrong one under pressure.

    Remember the question Task 0 left hanging, comparing `form-window` against `scout-search`? There's the answer. `scout-search` is slower per call—969 against 658—and `form-window` runs six times as often, so it costs four times as much in total. Chase `form-window`.

### Task 2.3: Why you can read a feature name at all

9. Look at the **Query** column properly. Every row from the workload begins like this:

    ```
    /*application='cymbalgoal-deadline-day',controller='form-window',framework='psycopg-lite'*/ SELECT ...
    ```

    That prefix is a **sqlcommenter** tag—a structured SQL comment the application attaches to every statement, naming the app, the feature and the driver. It isn't a Google invention; it's an open convention most modern ORMs and frameworks can emit with a configuration flag or two.

10. Now click the **Tags** tab, because AlloyDB doesn't just preserve those comments—it parses them.

    ![The Tags tab of Top dimensions by database load, showing one row per CymbalGoal feature with Controller, Application and Framework as separate columns, sorted by Total time per Tag](img/query-insights-tags.png)

    Same load, same ranking, but now **Controller** is a column and each feature is a row. No SQL to read. There's also a **Wait time per Tag** column that the Queries tab doesn't offer—and it confirms what the chart told you. `scout-search` burns millions of milliseconds with about **28 milliseconds** of waiting in total. It isn't blocked on anything. It's just doing an enormous amount of work.

11. Notice the empty columns too—**Action**, **Route**, **DB Driver**. sqlcommenter defines more fields than CymbalGoal's generator bothers to set. A real ORM would fill several of them, and you'd be able to slice database load by HTTP route.

    <ql-infobox>
    <strong>This is a genuine AlloyDB differentiator, and it's easy to walk past.</strong> PostgreSQL records a statement's identity starting <em>after</em> any leading comment—so the open-source <code>pg_stat_statements</code> view, running on this very instance, has stored these same queries with the prefix <strong>stripped off</strong>. Same database, same statements, two pipelines: AlloyDB's Query Insights keeps the tag and gives you a whole tab built on it, while the standard tooling throws it away. If you've ever wondered why your query stats are anonymous SQL with no idea which service sent them, this is usually why.
    </ql-infobox>

### Task 2.4: What the console won't hand you yet

12. Back on the **Queries** tab, look at the **Recommendations** column.

    It's empty. That column is where AlloyDB's Index Advisor publishes findings, and it runs on a schedule measured in hours—the same class of delay that left Database Center's performance card silent. On a cluster this young it hasn't spoken yet.

13. That's not a dead end, because **the advisor will answer on demand.** You don't have to wait for its schedule; you can ask it directly and get an answer in seconds. Which is the next task.

    Note what you know now that you didn't fifteen minutes ago: the load is CPU rather than I/O or locking, the most expensive statement on the instance belongs to the **form window**, and neither the slowest query nor the slowest statement is the one to fix. That's a diagnosis. What's missing is a repair.

You've got a name. Time to get a fix.

<ql-infobox>
<strong>Business translation.</strong> Two habits to take back. First, <em>tag your queries</em>—if your ORM or driver can emit sqlcommenter comments, switching that on costs an afternoon and permanently changes incident conversations from "a query is slow" to "checkout is slow." Second, <em>sort by total, not by worst</em>. Every performance tool offers both columns, they disagree constantly, and the alarming one is rarely the one costing you money. The nine-second report is what people complain about in meetings; the 658-millisecond query running thirty thousand times an hour is what's paying for your instance.
</ql-infobox>

### What you learned

| | |
| :---- | :---- |
| **Diagnosed** | The load is CPU-bound—not I/O, not locking—readable from one chart legend |
| **Found** | `form-window` is over half the database time on this instance |
| **Learned** | Why total execution time is the right sort, and that the two slowest statements are both the wrong thing to fix |
| **Saw** | AlloyDB parse a sqlcommenter tag into a whole dimension, naming features instead of SQL |

**Coming up:** you know which query. You don't yet know what to do about it—and the tool that answers that is one page away, waiting to be asked rather than waiting for its schedule.

---
