#!/usr/bin/env bash
# Assembles an implementer prompt from files on disk — never from conversation memory.
#
#   brief.sh <run-id> <repo> <iteration>
#
# Iteration 1 is plan + contract. Iteration N>1 additionally splices in the previous gate log
# tail and the previous review's blocking findings, verbatim. The orchestrator never
# paraphrases a failure; paraphrasing is how "compute-stats" becomes "computeStats".
set -euo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"
RUN_ID="${1:?usage: brief.sh <run-id> <repo> <iteration>}"
REPO="${2:?missing repo}"; ITER="${3:?missing iteration}"
RUN="$ROOT/.runs/$RUN_ID"
WT="$ROOT/.worktrees/$RUN_ID/$REPO"

cat <<EOF
# Implementation task — repo: $REPO, iteration: $ITER

## Your one writable location

    $WT

This is a git worktree on branch feature/${RUN_ID#*-*-}.
Everything you write goes here. You MUST NOT touch $ROOT/profitify-$REPO or any sibling
checkout — those hold the user's uncommitted work and are denied at the permission layer.

Before your first edit, run this and confirm the output matches the path above:

    git -C $WT rev-parse --show-toplevel

## Hard rules

- Write the test first, then the implementation.
- Do NOT run the verification gate yourself and do NOT report whether tests pass. A separate
  script decides that. Your summary must describe what you changed, not whether it works.
- Never add t.Skip, .skip(, eslint-disable, @ts-ignore, @ts-expect-error, //nolint, or
  --no-verify. Never delete assertions to make a suite green. The gate fails on all of these.
- Read $ROOT/CLAUDE.md and $ROOT/profitify-$REPO/CLAUDE.md before starting.

## Your slice of the plan

$(sed -n "/^## repo: $REPO\$/,/^## repo: /p" "$RUN/plan.md" | sed '$ {/^## repo: /d;}')

## The cross-repo contract — implement against this EXACTLY

Field names, route paths, ECR tags and resource names below are shared with the other repos
in this run. Re-read the file if you need it again: $RUN/contract.json

\`\`\`json
$(cat "$RUN/contract.json")
\`\`\`
EOF

PREV=$((ITER - 1))
if [ "$ITER" -gt 1 ]; then
  echo ""
  echo "## What failed on iteration $PREV"
  GLOG="$RUN/gate/$REPO.iter$PREV.log"
  GJSON="$RUN/gate/$REPO.iter$PREV.json"
  if [ -f "$GJSON" ]; then
    echo ""
    echo "Gate status: $(jq -r '.status' "$GJSON"), first failed step: $(jq -r '.first_failed_step' "$GJSON")"
  fi
  if [ -f "$GLOG" ]; then
    echo ""
    echo '```'
    tail -n 120 "$GLOG"
    echo '```'
  fi
  RJSON="$RUN/review/$REPO.iter$PREV.json"
  if [ -f "$RJSON" ]; then
    COUNT=$(jq '[.findings[]|select(.severity=="blocking")]|length' "$RJSON")
    if [ "$COUNT" -gt 0 ]; then
      echo ""
      echo "## Blocking review findings you must resolve ($COUNT)"
      echo ""
      jq -r '.findings[] | select(.severity=="blocking")
             | "### \(.id) — \(.file):\(.line)\n\n**Problem:** \(.problem)\n\n**Required change:** \(.required_change)\n\n**Evidence:** `\(.evidence // "n/a")`\n"' "$RJSON"
    fi
  fi
fi
