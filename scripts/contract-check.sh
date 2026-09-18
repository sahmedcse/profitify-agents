#!/usr/bin/env bash
# Cross-repo contract verification.
#
#   contract-check.sh [run-id]
#
# Derives the eight ECR Lambda tags from six independent sources and diffs them. For a repo
# NOT in the current run, sources are read from its origin/main — a backend-only run that
# renames a Lambda is exactly the hazard, and it is invisible to any check that only looks
# at the run's own worktrees.
set -euo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"
RUN_ID="${1:-}"
FAIL=0; ADVISORY=0

# Resolve a repo to a worktree if it is in the run, else fall back to origin/main reads.
wt_or_main() {  # wt_or_main <repo-key>  -> prints worktree path, or empty for "use origin/main"
  local r="$1"
  [ -n "$RUN_ID" ] && [ -d "$ROOT/.worktrees/$RUN_ID/$r" ] && { echo "$ROOT/.worktrees/$RUN_ID/$r"; return; }
  echo ""
}
read_file() {  # read_file <repo-key> <path-in-repo>
  local r="$1" p="$2" wt; wt=$(wt_or_main "$r")
  if [ -n "$wt" ]; then cat "$wt/$p"
  else
    case "$r" in
      backend) git -C "$ROOT/profitify-backend" show "origin/main:$p" ;;
      ops)     git -C "$ROOT/profitify-ops"     show "origin/main:$p" ;;
    esac
  fi
}
list_dir() {  # list_dir <repo-key> <glob-prefix>  -> newline-separated paths
  local r="$1" pat="$2" wt; wt=$(wt_or_main "$r")
  if [ -n "$wt" ]; then ( cd "$wt" && git ls-files "$pat" )
  else git -C "$ROOT/profitify-${r}" ls-tree -r --name-only origin/main | grep -E "^${pat//\*/.*}$" || true
  fi
}

# A: backend CD matrix
A=$(read_file backend .github/workflows/cd.yml \
    | awk '/^ *function:$/{f=1;next} f&&/^ *- /{sub(/^ *- /,"");print;next} f{exit}' | sort -u)
# B: backend entrypoints
B=$(list_dir backend 'cmd/lambda-*' | sed -n 's|^cmd/lambda-\([^/]*\)/.*|\1|p' | sort -u)
# C: backend dockerfiles
C=$(list_dir backend 'build/lambda-*.Dockerfile' | sed 's|build/lambda-||;s|\.Dockerfile$||' | sort -u)
# D + E: ops
OPS_SRC=$(read_file ops lib/constructs/pipeline-lambdas.ts)
D=$(grep -o "imageCode('[a-z0-9-]*')" <<<"$OPS_SRC" | sed "s/imageCode('//;s/')//" | sort -u)
E=$(grep -o 'functionName: `${envName}-[a-z0-9-]*`' <<<"$OPS_SRC" | sed 's/.*envName}-//;s/`//' | sort -u)

cmp_set() {  # cmp_set <label> <value>
  if ! diff -q <(echo "$A") <(echo "$2") >/dev/null; then
    echo "CONTRACT MISMATCH — set A (backend cd.yml matrix) vs $1:"
    diff <(echo "$A") <(echo "$2") | sed 's/^/    /'
    FAIL=1
  fi
}
cmp_set "B (backend cmd/lambda-*/)"          "$B"
cmp_set "C (backend build/lambda-*.Dockerfile)" "$C"
cmp_set "D (ops imageCode tags)"             "$D"
cmp_set "E (ops functionName suffixes)"      "$E"

# F: the architect's declared intent, when a run is active
CONTRACT="$ROOT/.runs/$RUN_ID/contract.json"
if [ -n "$RUN_ID" ] && [ -f "$CONTRACT" ]; then
  F=$(jq -r '.lambda_functions[]? | select(.action != "removed") | .tag' "$CONTRACT" | sort -u)
  [ -n "$F" ] && cmp_set "F (contract.json lambda_functions)" "$F"
fi

# Advisory: CI's build job should assert every bootstrap it builds.
CI=$(read_file backend .github/workflows/ci.yml)
for t in $A; do
  grep -q "bin/lambda-$t/bootstrap" <<<"$CI" || {
    echo "ADVISORY: ci.yml build job does not assert bin/lambda-$t/bootstrap"; ADVISORY=1; }
done

if [ "$FAIL" = 1 ]; then
  echo ""
  echo "The eight ECR tags must agree across backend and ops. See contracts/ecr-lambda-tags.md."
  echo "If the mismatch is in a repo NOT in this run, STOP and ask the user — do not expand scope."
  exit 1
fi
echo "contract-check: ECR tags agree across all sources ($(wc -w <<<"$A" | tr -d ' ') tags)"
[ "$ADVISORY" = 1 ] && echo "contract-check: advisories above are non-blocking"
exit 0
