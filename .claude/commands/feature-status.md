---
description: Show the state of a /feature run, or list recent runs.
argument-hint: "[run-id]"
---

Inspect a `/feature` run. Input: `$ARGUMENTS`

With **no argument**, list the last 10 runs under `/Users/sadatahmed/Personal/Profitify/.runs/`,
newest first: run id, status, phase, affected repos, and PR URLs if any.

With a **run id**, report on that run:

- `run.json`: phase, status, iteration and gate/review/PR state per repo.
- For each repo, the latest gate result — status, `first_failed_step`, and the per-step table from
  `jq -r '.steps[] | "\(.name) \(.result)"'`.
- For each repo, the latest review — counts of blocking and advisory findings, and the blocking ones
  in full.
- Whether worktrees still exist under `.worktrees/<run-id>/`, and whether those trees are dirty
  (`git -C <wt> status --short`).
- Any orphaned gate containers: `docker compose ls` filtered to names starting `pfgate-`.

Then say plainly what the run is waiting on and what the user can do: resume it with
`/feature <run-id>`, inspect a failing log at `.runs/<run-id>/gate/<repo>.iter<N>.log`, or clean up
with `scripts/worktree.sh cleanup <run-id>`.

Read-only — do not modify run state, worktrees, or containers.
