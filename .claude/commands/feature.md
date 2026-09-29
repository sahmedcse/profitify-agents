---
description: Plan, implement, review and open PRs for a feature across the Profitify repos.
argument-hint: "<feature description>" | <existing run-id to resume>
---

Orchestrate a feature end to end: designer → design approval (UI only) → architect → plan approval
→ implement → gate → review → PRs.

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
{ "run_id": "...", "slug": "...", "branch": "feature/<slug>", "phase": "design",
  "designApproved": null,
  "max_iterations": 3, "max_impl_calls": 9, "impl_calls_used": 0,
  "repos": {}, "status": "running" }
```

`.phase` maps to steps as follows: `design` → Step 1 (or Step 2 if `$RUN/design.json` already
exists and `designApproved` is still `null`), `plan` → Step 3 (or Step 4 if `plan.md` and
`contract.json` already exist and `planApproved` is not `true`), `implement` → Step 5. A run with
`status: "paused"` resumes at its gate; read its `paused` note first.

# Step 1 — Designer

Launch the `ui-designer` subagent **for every run**. It triages the feature itself, so do not
decide on its behalf whether the feature has UI. Give it the feature description, the RUN_ID, and
the three output paths (`$RUN/design.json`, `$RUN/design.md`, `$RUN/mockup.html`). It is read-only
and will not touch any repo.

When it returns, validate:

- `jq -e '.schema == "profitify.design.v1" and (.ui_required | type == "boolean")' $RUN/design.json`
- when `.ui_required` is `true`: `design.md` and `mockup.html` both exist and are non-empty, and
  `.screens` is non-empty

If validation fails, send it back once with the specific problem.

Then route on the file, not on the designer's prose:

- `jq -r '.ui_required' $RUN/design.json` is `false` → print one line,
  `designer: no UI — <.reason>`, set `phase: "plan"`, and go to Step 3. There is no design gate.
- `true` → Step 2.

# Step 2 — Design gate (UI features only)

The user judges a design by **looking at the mockup**, and decides in the browser, not here.

1. Add the annotation layer to the mockup and start the loopback server **in the background**:

```
$R/scripts/design-gate.sh inject <RUN_ID>
$R/scripts/design-gate.sh serve <RUN_ID>
```

`serve` prints the base URL (also in `$RUN/gate.url`). Open `<url>mockup.html` — the **mockup
itself**, not the spec page. `plan-html.sh <RUN_ID> --doc design` still renders `design.html` as a
secondary reference; re-run it after every revision so it is never stale.

2. Wait for the decision under **Monitor** (30-minute cap; re-arm on expiry — notes persist):

```
$R/scripts/design-gate.sh wait <RUN_ID>
```

3. In the terminal keep it short: what the user is looking at, which components are new and which
are reused, any data the designer says does not exist yet, and anything it was **unsure** about. Tell
the user they can pin notes on the mockup and then click **Send notes — revise** or **Approve
design** in the page's Notes panel; you pick either up without them returning to the terminal. Do
**not** also ask approve/revise with AskUserQuestion while waiting.

Route on `wait`'s output line, never on anything else:

- `DECISION: revise` → send the notes from `$RUN/notes.json` to the designer **verbatim** (label,
  pinned text and note — the same no-paraphrase rule as `brief.sh`). Continue the **same** designer
  agent with SendMessage so it keeps its context, rather than launching a new one. When it returns:
  validate as in Step 1, re-run `inject` (it archives the old notes and gives the revision a new
  id), re-render `design.html`, reopen the URL and `wait` again. The server keeps running.
- `DECISION: approve` → set `designApproved: true`, `phase: "plan"`, and stop the server.
- `STALE:` → a tab on an older revision decided; it was set aside. Keep waiting.
- `SERVER DOWN` (exit 1) → restart `serve` once. If it fails again, fall back: the user clicks **Copy
  notes** in the page (works from a file too) and pastes the notes into the terminal.
- The user typing in the terminal — for example **cancel** — always wins over the page. On cancel,
  set `status: "cancelled"`, stop the server, stop.

After approval, the designer's open questions remain. Many are already settled by the approved
mockup — do not re-ask those. Ask only the ones that change **what this run builds** (slice size,
deletions, backfills) with one AskUserQuestion, and pass the answers to the architect as scope
decisions that override the design's own slice list.

If the designer contradicts something in your brief (a font, a logo, a data claim), check the repo
before accepting either version. It was right once when the brief was wrong.

The design is approved before the architect runs, so a revised design never throws away a plan.

# Step 3 — Architect

Launch the `feature-architect` subagent. Give it the feature description, the RUN_ID, and the two
output paths (`$RUN/plan.md`, `$RUN/contract.json`). When `design.json` has `ui_required: true`,
also give it `$RUN/design.md` and `$RUN/design.json` and say the design is **approved**, so it
plans against the design rather than re-deciding it. It is read-only and will not touch any repo.

When it returns, validate:

- `jq -e '.schema == "profitify.contract.v1"' $RUN/contract.json`
- every entry in `.repos` is one of `backend`, `web`, `ops` — **never** `backend-services`
- `.merge_order` covers exactly the same set as `.repos`
- if `design.json` has `ui_required: true`, `.repos` contains `web`

If validation fails, send it back once with the specific problem.

# Step 4 — Plan approval gate

Render the plan, add the annotation layer, and serve it — the same browser flow as the design gate:

```
$R/scripts/plan-html.sh <RUN_ID>
$R/scripts/design-gate.sh inject <RUN_ID> --doc plan
$R/scripts/design-gate.sh serve <RUN_ID>
```

Run `serve` in the background (if it is still up from the design gate, reuse it), open
`<url>plan.html`, and wait under Monitor with `$R/scripts/design-gate.sh wait <RUN_ID>`. **Exit 3
from `plan-html.sh` means pandoc is not installed** — that is not a failure: fall back to a
terminal-only gate with AskUserQuestion *approve* / *revise* / *cancel*, and mention
`brew install pandoc` once. The page is served on loopback only; a plan names route paths, table
names and ECR tags, so none of it leaves the machine.

In the terminal keep it short, because the page carries the detail: the affected repos, the merge
order, the single biggest risk, and anything the architect said it was **unsure** about. Tell the
user to pin notes on the plan and click **Send notes — revise** or **Approve plan** in the page.

- `DECISION: revise` → pass the notes in `$RUN/notes.json` to the architect **verbatim**, then
  re-run `plan-html.sh` **and** `inject --doc plan` (re-rendering wipes the layer) and `wait` again.
  A stale page is worse than no page.
- `DECISION: approve` → stop the server. If the architect raised a decision only the user can make
  (for example, a production dependency that does not exist yet), ask it now with one
  AskUserQuestion before going on. Then set `planApproved: true`, `phase: "implement"`, and seed
  `.repos` with one entry per affected repo:
  `{path, iteration: 0, gate: null, review: null, pr: null, status: "in_progress"}`.
- `STALE:` / `SERVER DOWN` / a message typed in the terminal → as in Step 2. On **cancel**, set
  `status: "cancelled"` and stop. If the user wants to stop for now but keep the plan, set
  `status: "paused"` with a note of where to resume — `/feature <RUN_ID>` picks it up at this gate
  without re-running the architect.

A **revise** here goes to the architect only. If the notes are really about the UI, say so and ask
whether to reopen the design gate (back to Step 2, then re-run the architect) rather than letting
the architect quietly change an approved design.

**Nothing is written to any repo before approval.**

# Step 5 — Worktrees

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

# Step 6 — The loop

`active` = the affected repos. Repeat until `active` is empty:

### 6a. Advance the counter

For each repo in `active`: `$R/scripts/iter.sh next <RUN_ID> <repo>`

**A non-zero exit means that repo is terminally blocked.** Drop it from `active`, mark
`status: "blocked"`, and do not create its PR. Do not retry it and do not reason your way past this.

### 6b. Implement — in parallel

For each active repo, build the brief with `$R/scripts/brief.sh <RUN_ID> <repo> <iter>` and launch
the matching subagent — `backend-implementer`, `web-implementer`, `infra-implementer` — passing the
brief as the prompt. **Send all of them in a single message** so they run concurrently.

Record each agent's `files_changed` into `$RUN/impl/<repo>.iter<N>.json`.

### 6c. Gate — serially, backend first

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

If any repo failed, set `active` to just those repos and go back to 6a.

### 6d. Review — two reviewers per repo, in parallel

Only when every active repo's gate passed. For each repo launch **both** reviewers — send every agent
for every repo in a **single message**:

- `spec-reviewer` → `$RUN/review/<repo>.iter<N>.spec.json`
- `quality-reviewer` → `$RUN/review/<repo>.iter<N>.quality.json`

Tell each its repo, worktree, iteration, and its own output path. They are independent: the spec
reviewer owns the six blocking criteria, the quality reviewer owns everything else and cannot send
work back around the loop.

Then merge, per repo:

```
$R/scripts/merge-review.sh <RUN_ID> <repo> <iter>
```

That writes the canonical `$RUN/review/<repo>.iter<N>.json` which 6e, `brief.sh` and `pr-body.sh`
read. It assigns severities and ids, enforces the cap of 5 blocking findings by demoting the overflow
to advisory, promotes any `escalate: true` quality finding to blocking, and derives `verdict` from the
final count. Do not second-guess it: the cap and the verdict are its decisions, not yours.

**A non-zero exit means the spec review was missing, unparseable, or carried a finding with no
`criterion`.** Re-invoke that spec reviewer **once**, saying exactly which of those it was. If it
fails again, write a synthetic blocking finding ("spec reviewer produced unparseable output") and
escalate to the user — **never** treat an unparseable review as an approval.

A missing or unparseable **quality** review does not fail the merge. It lands as a visible advisory
placeholder, because a reviewer that cannot block is not worth stopping a run for.

### 6e. Route

```
jq '[.findings[]|select(.severity=="blocking")]|length' $RUN/review/<repo>.iter<N>.json
```

Greater than zero → back to 6a with those repos. Zero → that repo is done; mark `status: "ready"`.
Ignore the reviewer's own `verdict` field; this count is authoritative.

# Step 7 — Pre-flight, both blocking

```
$R/scripts/contract-check.sh <RUN_ID>
$R/scripts/verify-gate.sh <RUN_ID> <repo> $R/.worktrees/<RUN_ID>/<repo>
```

`contract-check.sh` also inspects repos **not** in this run, at their `origin/main`. If it reports a
mismatch in a repo you did not touch, **stop and ask the user** — do not silently pull another repo
into the run.

`verify-gate.sh` catches a tree that changed after its gate passed. If it fails, re-run the gate;
do not push.

# Step 8 — Commit, push, open PRs

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

# Step 9 — Finish

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
