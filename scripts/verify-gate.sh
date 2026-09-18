#!/usr/bin/env bash
# Stale-gate detector. Run immediately before commit/push.
#
#   verify-gate.sh <run-id> <repo> <worktree>
#
# Recomputes the worktree fingerprint and compares it to the one recorded by the gate that
# passed. A mismatch means the tree changed after the gate ran — so the gate result no longer
# describes what is about to be pushed. Exits non-zero.
set -euo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"
RUN_ID="${1:?usage: verify-gate.sh <run-id> <repo> <worktree>}"
REPO="${2:?missing repo}"; WT="${3:?missing worktree}"

ITER=$(jq -r --arg r "$REPO" '.repos[$r].iteration // 0' "$ROOT/.runs/$RUN_ID/run.json")
JSON="$ROOT/.runs/$RUN_ID/gate/$REPO.iter$ITER.json"
[ -f "$JSON" ] || { echo "verify-gate: no gate result at $JSON" >&2; exit 1; }

STATUS=$(jq -r '.status' "$JSON")
[ "$STATUS" = "pass" ] || { echo "verify-gate: gate status is '$STATUS', not 'pass'" >&2; exit 1; }

RECORDED=$(jq -r '.tree_sha' "$JSON")
ACTUAL=$( { git -C "$WT" diff origin/main; git -C "$WT" status --porcelain; } \
          | shasum -a 256 | cut -d' ' -f1 )

if [ "$RECORDED" != "$ACTUAL" ]; then
  echo "verify-gate: STALE — $REPO changed after gate iter$ITER passed." >&2
  echo "  gate saw : $RECORDED" >&2
  echo "  tree now : $ACTUAL" >&2
  echo "  Re-run the gate before pushing." >&2
  exit 1
fi
echo "verify-gate: $REPO iter$ITER fresh ($ACTUAL)"
