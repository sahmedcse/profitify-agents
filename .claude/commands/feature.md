---
description: Plan, implement, review and open PRs for a feature across the Profitify repos.
argument-hint: "<feature description>" | <existing run-id to resume>
---

Orchestrate a feature end to end: architect → approval → implement → gate → review → PRs.

Input: `$ARGUMENTS`

# Your role

You are the orchestrator. You call subagents and scripts; you do **not** write product code and you
do **not** judge whether anything passes. Every pass/fail decision in this command comes from a
script's exit code or a `jq` query against a file a script wrote. If a subagent tells you its tests
pass, that claim carries no weight — only `gate.sh` does.

## Command hygiene (this matters)

Permission rules match commands **as literally written**. Therefore:

- Always use absolute paths: `/Users/sadatahmed/Personal/Profitify/scripts/gate.sh ...`
- Never `cd` first, never chain with `&&` or `;`, one command per Bash call.

Shorthand below: `$R` = `/Users/sadatahmed/Personal/Profitify`, `$RUN` = `$R/.runs/<RUN_ID>`.

---

# Step 0 — Resume or initialise

If `$ARGUMENTS` matches `^[0-9]{8}-[0-9]{6}-`, treat it as a RUN_ID: read `$RUN/run.json`, report
the current state, and continue from `.phase`. Skip to that step; do not re-plan.

Otherwise start a new run:

- `RUN_ID` = `<UTC yyyymmdd-HHMMSS>-<slug>`; `slug` is kebab-case from the description, 3–32 chars,
  `[a-z0-9-]` only.
- Run `$R/scripts/worktree.sh doctor` and deal with anything it reports before continuing.
- Create `$RUN/` and write `run.json`:

```json
{ "run_id": "...", "slug": "...", "branch": "feature/<slug>", "phase": "plan",
  "max_iterations": 3, "max_impl_calls": 9, "impl_calls_used": 0,
  "repos": {}, "status": "running" }
```

# Step 1 — Architect

Launch the `feature-architect` subagent. Give it the feature description, the RUN_ID, and the two
output paths (`$RUN/plan.md`, `$RUN/contract.json`). It is read-only and will not touch any repo.

When it returns, validate:

- `jq -e '.schema == "profitify.contract.v1"' $RUN/contract.json`
- every entry in `.repos` is one of `backend`, `web`, `ops` — **never** `backend-services`
- `.merge_order` covers exactly the same set as `.repos`

If validation fails, send it back once with the specific problem.

# Step 2 — Approval gate (the one place you stop)

Show the user: the affected repos and why, the contract in plain language, the merge order with its
reasoning, and the biggest risk. Then use **AskUserQuestion**: *approve* / *revise* / *cancel*.

- **revise** → pass their notes back to the architect, re-render, ask again.
- **cancel** → set `status: "cancelled"`, stop.
- **approve** → set `planApproved: true`, `phase: "implement"`, and seed `.repos` with one entry per
  affected repo: `{path, iteration: 0, gate: null, review: null, pr: null, status: "in_progress"}`.

**Nothing is written to any repo before approval.**

# Step 3 — Worktrees

One call, all repos, so a late collision cannot leave a half-created run:

```
$R/scripts/worktree.sh create <RUN_ID> <repo>...
```

If it fails, report why and stop — usually a branch name already in use.

Then warm up dependencies in the background (they take minutes and nothing depends on them yet):
for `web`, clone `node_modules` with `cp -c -R` from the main checkout and run
`pnpm install --frozen-lockfile` only if `pnpm-lock.yaml` differs from `origin/main`; for `ops`,
clone only when `package-lock.json` is unchanged, otherwise `npm ci` (which deletes `node_modules`
anyway).

# Step 4 — The loop

`active` = the affected repos. Repeat until `active` is empty:

### 4a. Advance the counter

For each repo in `active`: `$R/scripts/iter.sh next <RUN_ID> <repo>`

**A non-zero exit means that repo is terminally blocked.** Drop it from `active`, mark
`status: "blocked"`, and do not create its PR. Do not retry it and do not reason your way past this.

### 4b. Implement — in parallel

For each active repo, build the brief with `$R/scripts/brief.sh <RUN_ID> <repo> <iter>` and launch
the matching subagent — `backend-implementer`, `web-implementer`, `infra-implementer` — passing the
brief as the prompt. **Send all of them in a single message** so they run concurrently.

Record each agent's `files_changed` into `$RUN/impl/<repo>.iter<N>.json`.

### 4c. Gate — serially, backend first

```
$R/scripts/gate.sh <repo> $R/.worktrees/<RUN_ID>/<repo> <RUN_ID> <iter>
```

Run these **one at a time**, never in parallel — they contend for CPU and Docker, and a starved
`go test -race` produces timeout flakes the loop would misread as code failures.

Run `backend` first. **If the backend gate fails, skip the other gates this iteration** — backend
produces the contract, so web and ops would be validating a moving target.

Interpret the exit code exactly:

- **0** — passed.
- **1** — failed. The iteration is consumed. Add to next round.
- **2** — infra error (Docker down, port race, registry hiccup). **Roll the iteration back** with a
  `jq` edit decrementing `.repos[<repo>].iteration` and `.impl_calls_used`, then retry the gate
  once. A flaky laptop must not eat the user's budget.

If any repo failed, set `active` to just those repos and go back to 4a.

### 4d. Review — in parallel

Only when every active repo's gate passed. Launch `change-reviewer` per repo (single message),
telling each its repo, worktree, iteration, and output path `$RUN/review/<repo>.iter<N>.json`.

Validate each file: `jq -e '.schema == "profitify.review.v1"'`. On failure, re-invoke that reviewer
**once** saying its previous output was not valid `profitify.review.v1`. If it fails again, write a
synthetic blocking finding ("reviewer produced unparseable output") and escalate to the user —
**never** treat an unparseable review as an approval.

### 4e. Route

```
jq '[.findings[]|select(.severity=="blocking")]|length' $RUN/review/<repo>.iter<N>.json
```

Greater than zero → back to 4a with those repos. Zero → that repo is done; mark `status: "ready"`.
Ignore the reviewer's own `verdict` field; this count is authoritative.

# Step 5 — Pre-flight, both blocking

```
$R/scripts/contract-check.sh <RUN_ID>
$R/scripts/verify-gate.sh <RUN_ID> <repo> $R/.worktrees/<RUN_ID>/<repo>
```

`contract-check.sh` also inspects repos **not** in this run, at their `origin/main`. If it reports a
mismatch in a repo you did not touch, **stop and ask the user** — do not silently pull another repo
into the run.

`verify-gate.sh` catches a tree that changed after its gate passed. If it fails, re-run the gate;
do not push.

# Step 6 — Commit, push, open PRs

The implementers commit their own work in small, phased commits as they go, so by now each
worktree already has a commit series. **Do not squash it and do not amend it** — that history is
part of what the user reviews.

Per ready repo:

1. Check for anything left uncommitted:

```
git -C $R/.worktrees/<RUN_ID>/<repo> status --porcelain
```

If it is non-empty, commit the remainder yourself with a conventional message describing it. If it
is empty, commit nothing — the implementer already did the work.

2. Confirm the series looks sane and every declared file actually landed:

```
git -C $R/.worktrees/<RUN_ID>/<repo> log --oneline origin/main..HEAD
git -C $R/.worktrees/<RUN_ID>/<repo> diff --name-only origin/main
```

Every path in the implementers' `files_changed` must appear in that **diff against
`origin/main`** — not in `git show HEAD`, which with a commit series only reveals the last commit.
A missing path means the file was silently gitignored (ops ignores `*.js` and `*.d.ts` globally).

3. Push the series:

```
git -C $R/.worktrees/<RUN_ID>/<repo> push -u origin feature/<slug>
```

**Pass 1** — create the PRs. `gh pr create` cannot reference PRs that do not exist yet:

```
$R/scripts/pr-body.sh <RUN_ID> <repo> > $RUN/pr/<repo>.md
gh pr create --repo sahmedcse/profitify-<repo> --base main --head feature/<slug> --title "<title>" --body-file $RUN/pr/<repo>.md --assignee @me
```

Record each PR number and URL in `run.json`.

**Pass 2** — re-render with sibling links and update:

```
$R/scripts/pr-body.sh <RUN_ID> <repo> --with-links > $RUN/pr/<repo>.md
gh pr edit <url> --repo sahmedcse/profitify-<repo> --body-file $RUN/pr/<repo>.md
```

**PRs open ready for review**, not as drafts. `gh pr merge` is denied to you, so the PR stops
with the user: merging is what deploys to production in all three repos, and that decision is
theirs. Say so in your final report.

# Step 7 — Finish

- `gh pr checks <url> --repo <repo> --watch` per PR, capped at ~10 minutes. Record the outcome.
  This is where the local↔CI divergences surface (golangci-lint 2.4.0 vs v2.11; Node 24 vs 22).
- `$R/scripts/worktree.sh cleanup <RUN_ID>` — but **only** if every repo produced a PR. If anything
  was blocked, leave the worktrees in place and print their paths.
- Set `status: "complete"` (or `"failed"`).

Report to the user: the PR URLs **in merge order**, what each one does, any advisory review findings,
any repo that was blocked and why, and the reminder that merging deploys to production. Print the
merge sequence as text — do not run it.

# If something goes wrong

Never force, never widen scope to get unstuck, never disable a check to make a gate pass. If you are
blocked, say exactly what failed, where the log is (`$RUN/gate/<repo>.iter<N>.log`), and what the
user's options are. A run that stops early with a clear explanation is a good outcome; a run that
pushes unverified code is not.
