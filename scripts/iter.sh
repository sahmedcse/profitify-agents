#!/usr/bin/env bash
# The loop bound. The iteration counter lives in a file, not in a model's head.
#
#   iter.sh next <run-id> <repo>   advance and print the new iteration; EXIT 3 past the max
#   iter.sh get  <run-id> <repo>   print the current iteration
#
# A non-zero exit from `next` means that repo is terminally blocked: do not retry it,
# do not create its PR. This is the only mechanism that advances an iteration.
set -euo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"
CMD="${1:?usage: iter.sh <next|get> <run-id> <repo>}"
RUN_ID="${2:?missing run-id}"
REPO="${3:?missing repo}"

RUN_JSON="$ROOT/.runs/$RUN_ID/run.json"
[ -f "$RUN_JSON" ] || { echo "iter.sh: no run.json at $RUN_JSON" >&2; exit 2; }

MAX=$(jq -r '.max_iterations // 3' "$RUN_JSON")
CUR=$(jq -r --arg r "$REPO" '.repos[$r].iteration // 0' "$RUN_JSON")

case "$CMD" in
  get)
    echo "$CUR"
    ;;
  next)
    # Second, orthogonal bound: catches loop-structure bugs that reset per-repo counters.
    USED=$(jq -r '.impl_calls_used // 0' "$RUN_JSON")
    CAP=$(jq -r '.max_impl_calls // 9' "$RUN_JSON")
    if [ "$USED" -ge "$CAP" ]; then
      echo "iter.sh: total implementer calls ($USED) reached cap ($CAP) for run $RUN_ID" >&2
      exit 3
    fi

    NEXT=$((CUR + 1))
    if [ "$NEXT" -gt "$MAX" ]; then
      echo "iter.sh: MAX_ITERATIONS($MAX) exhausted for $REPO in run $RUN_ID" >&2
      exit 3
    fi

    tmp=$(mktemp)
    jq --arg r "$REPO" --argjson n "$NEXT" \
       '.repos[$r].iteration = $n | .impl_calls_used = ((.impl_calls_used // 0) + 1)' \
       "$RUN_JSON" > "$tmp" && mv "$tmp" "$RUN_JSON"
    echo "$NEXT"
    ;;
  *)
    echo "iter.sh: unknown command '$CMD'" >&2; exit 2 ;;
esac
