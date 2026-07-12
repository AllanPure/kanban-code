---
name: task-orchestrator
description: Decompose a task into a dependency graph of Kanban Code backlog cards. Use when the user gives you a broad task/epic and wants it broken into several tasks (with execution order and/or parallelism), or asks you to "orchestrate", "split into tasks", or "delegate" work on the board. Creates the cards via the `kanban` CLI after the user approves the plan.
---

# Task Orchestrator

You take one broad task and turn it into a **graph of smaller tasks** on the Kanban Code board — each a Backlog card that becomes its own Claude session when launched. You propose the breakdown; the user approves; you create the cards.

## Mental model

- **A card = one task = one future Claude session.** Sub-tasks are created in the **Backlog** column, inert until launched.
- **Dependencies form a DAG** (`dependsOn`). "B depends on A" means B must wait for A to be **Done**.
  - *Sequential*: `B depends on A`.
  - *Parallel*: `C` and `D` both depend on `A` but not on each other → they run side by side once A is Done.
- **Auto-scheduler**: when **all** of a card's dependencies reach **Done**, that card **launches automatically**. Cards with **no** dependencies (the *roots*) are **not** auto-launched — the user starts those by hand to kick off the graph.
- So: design the graph so the roots are the natural starting points, and everything downstream cascades on its own.

## Workflow

1. **Understand the task.** If it's ambiguous, ask 1–3 sharp clarifying questions before decomposing — scope, target project, constraints. Don't guess.
2. **Decompose.** Produce a list of sub-tasks. For each: a short **title**, a **body** (what/why + acceptance criteria — this becomes the card's launch prompt), and its **dependencies** (which other sub-tasks must finish first).
3. **Present the plan and STOP.** Show the graph before creating anything:
   - the ordered list of sub-tasks with their bodies,
   - the dependency edges (who blocks who),
   - which sub-tasks are **roots** (the user will launch these), and which will **auto-launch**.
   Wait for explicit approval. Do **not** create cards unprompted.
4. **Create the cards** (after approval). Create them in **topological order** (dependencies first) so each `--depends-on` can reference an already-created card id. Capture each printed card id.
5. **Report.** List the created card ids, the graph, and tell the user **which roots to launch** to start the cascade.

## CLI reference

```
kanban task create "<title>" --project <path> --body "<description>" [--depends-on <id>...] [--json]
kanban task link   <cardId> --on <dependencyId>     # add an edge to an existing card
kanban task unlink <cardId> --on <dependencyId>     # remove an edge
```

- `--project` defaults to the current directory; pass it explicitly when orchestrating for a specific repo.
- `--body` becomes the launch prompt of the resulting session — write it as a real brief, not a one-liner.
- `--depends-on` takes one or more already-existing card ids (space-separated). Unknown ids are rejected.
- Use `--json` and capture `.id` when scripting a multi-card graph.
- Cycles are rejected (both on `create --depends-on` and `link`), so the auto-scheduler can always resolve an order.

## Example

Task: *"Add CSV export to the reports page."* Proposed graph (after approval):

```
A  Design export format + endpoint contract        (root — user launches)
B  Backend: implement /reports/export.csv          depends on A
C  Frontend: export button + download wiring        depends on A
D  Tests + docs for CSV export                       depends on B, C
```

Create it:

```
A=$(kanban task create "Design CSV export contract" --project ~/app --body "Define columns, encoding, endpoint shape. Acceptance: agreed schema doc." --json | jq -r .id)
B=$(kanban task create "Backend CSV export endpoint" --project ~/app --body "Implement /reports/export.csv per the contract. Acceptance: endpoint returns valid CSV, unit-tested." --depends-on "$A" --json | jq -r .id)
C=$(kanban task create "Frontend export button"       --project ~/app --body "Add export button + download wiring. Acceptance: click downloads the CSV." --depends-on "$A" --json | jq -r .id)
kanban task create "CSV export tests + docs" --project ~/app --body "E2E test + user docs. Acceptance: green CI, README updated." --depends-on "$B" "$C"
```

Then tell the user: *"Launch card A to start — B and C auto-launch when A is Done, D when both B and C are Done."*

## Guardrails

- **Propose before creating.** The plan is reviewed first, always.
- **Keep tasks card-sized** — each should be a coherent chunk one session can own end-to-end. If a sub-task is still huge, decompose it further or note it needs its own orchestration pass.
- **Roots are manual** — never imply a card with no dependencies will start on its own.
- **One graph, no cycles** — dependencies point only backward (toward prerequisites).
