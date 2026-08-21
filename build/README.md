# build/ — not student-facing

Prototype and verification scripts for mkt015. These answer "does this product
actually behave the way the docs say" questions before any lab text is written.

Nothing in here ships to a student, and nothing in here is referenced by the
lab instructions.

Populated during the Lab 3 prototype session. Expected contents:

| Script | Question it answers |
| :-- | :-- |
| `lab3-01-observability-probe.sh` | Did `observability_config` actually settle to what Terraform asked for, or is enhanced query insights entitlement-gated? |
| `lab3-02-database-center.md` | What Database Center shows in a project this young, and how stale it is |
| `lab3-03-index-advisor.py` | Index Advisor on demand: the real function signature from `pg_proc`, the role requirement, and the warm-up window |
| `lab3-04-insights-lag.py` | Workload start to visible-in-Query-Insights, measured |
| `lab3-05-active-queries.py` | What Active Queries shows under concurrency, with and without a deliberate lock wait |
| `lab3-06-mcp-probe.sh` | What the Task 5 natural-language surface actually is, tool list read from `tools/list` and not from a docs page (P-58) |
| `lab3-07-ai-function-fit.py` | The D-36 gate: does an `ai.*` call appear in Query Insights as an attributable statement, and is the fix visible in the same view |
| `lab3-08-columnar.py` | Whether the columnar engine is a second, genuinely different fix or a distraction |
