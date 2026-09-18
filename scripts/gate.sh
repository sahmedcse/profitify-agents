#!/usr/bin/env bash
# The verification gate. This script — not any model — decides whether a change passes.
#
#   gate.sh <backend|web|ops> <worktree> <run-id> <iteration>
#
#   exit 0  pass
#   exit 1  fail        (consumes an iteration)
#   exit 2  infra error (does NOT consume an iteration — Docker down, port race, registry hiccup)
#
# Writes .runs/<run-id>/gate/<repo>.iter<N>.{json,log}
set -Eeuo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"

REPO_KEY="${1:?usage: gate.sh <backend|web|ops> <worktree> <run-id> <iteration>}"
WT="${2:?missing worktree}"; RUN_ID="${3:?missing run-id}"; ITER="${4:?missing iteration}"
[ -d "$WT" ] || { echo "gate.sh: no such worktree: $WT" >&2; exit 2; }

OUT="$ROOT/.runs/$RUN_ID/gate"; mkdir -p "$OUT"
LOG="$OUT/$REPO_KEY.iter$ITER.log"; JSON="$OUT/$REPO_KEY.iter$ITER.json"
: > "$LOG"

STEPS_JSON="[]"; FIRST_FAIL=""; INFRA_ERROR=0
INFRA_SENTINEL="$OUT/.infra-$REPO_KEY-$ITER"; rm -f "$INFRA_SENTINEL"
TREE_SHA=$( { git -C "$WT" diff origin/main; git -C "$WT" status --porcelain; } \
            | shasum -a 256 | cut -d' ' -f1 )

emit() {
  jq -n --arg r "$REPO_KEY" --argjson i "$ITER" --arg s "$1" --arg f "$FIRST_FAIL" \
        --arg t "$TREE_SHA" --arg log "$LOG" --argjson steps "$STEPS_JSON" \
    '{schema:"profitify.gate.v1", repo:$r, iteration:$i, status:$s,
      first_failed_step:$f, tree_sha:$t, log:$log, steps:$steps}' > "$JSON"
}
trap 'emit error; exit 2' ERR

# step <name> <command...>   — records pass/fail/skipped; never trips set -e.
step() {
  local name="$1"; shift
  if [ -n "$FIRST_FAIL" ] || [ "$INFRA_ERROR" = 1 ]; then
    STEPS_JSON=$(jq --arg n "$name" '. + [{name:$n, result:"skipped"}]' <<<"$STEPS_JSON"); return 0
  fi
  printf '\n::: %s\n' "$name" >> "$LOG"
  local t0=$SECONDS rc=0
  ( cd "$WT" && "$@" ) >> "$LOG" 2>&1 || rc=$?
  local result=pass
  if [ "$rc" != 0 ]; then
    if [ -f "$INFRA_SENTINEL" ]; then result=infra; INFRA_ERROR=1
    else result=fail; FIRST_FAIL="$name"; fi
  fi
  STEPS_JSON=$(jq --arg n "$name" --arg r "$result" --argjson d $((SECONDS-t0)) \
               '. + [{name:$n, result:$r, seconds:$d}]' <<<"$STEPS_JSON")
}

# advisory <name> <command...> — recorded, never gates.
advisory() {
  local name="$1"; shift
  printf '\n::: %s (advisory)\n' "$name" >> "$LOG"
  local rc=0; ( cd "$WT" && "$@" ) >> "$LOG" 2>&1 || rc=$?
  local r=pass; [ "$rc" = 0 ] || r=fail
  STEPS_JSON=$(jq --arg n "$name" --arg r "$r" '. + [{name:$n, result:$r, advisory:true}]' <<<"$STEPS_JSON")
}

# ---------------------------------------------------------------- universal checks

# Anti-degeneration: at iteration 3 a cornered model "fixes" tests by silencing them.
check_no_suppressions() {
  local added bad
  added=$(git -C "$WT" diff origin/main --unified=0 | grep '^+' | grep -v '^+++' || true)
  bad=$(grep -nE 't\.Skip\(|it\.skip\(|describe\.skip\(|test\.skip\(|eslint-disable|@ts-ignore|@ts-expect-error|//nolint|--no-verify|t\.Parallel\(\) *// *disabled' <<<"$added" || true)
  [ -z "$bad" ] && return 0
  echo "TEST/LINT SUPPRESSIONS ADDED — fix the code, not the check:"; echo "$bad"; return 1
}

# Deleting assertions is the other way to make a suite pass.
check_no_test_gutting() {
  local stats ins del
  stats=$(git -C "$WT" diff origin/main --numstat -- \
            '*_test.go' '*.test.ts' '*.test.tsx' '*.spec.ts' 'test/*' 2>/dev/null || true)
  [ -z "$stats" ] && return 0
  ins=$(awk '{s+=$1} END{print s+0}' <<<"$stats"); del=$(awk '{s+=$2} END{print s+0}' <<<"$stats")
  [ "$del" -le "$ins" ] && return 0
  echo "TEST FILES NET-DELETED $((del-ins)) LINES (+$ins/-$del). Tests were removed, not added."; return 1
}

# profitify-ops ignores *.js and *.d.ts globally, so a new generated file is invisible to
# git and CI fails on a missing module. Run for all repos — the class of bug is not ops-only.
check_no_ignored_new_files() {
  local bad
  bad=$(git -C "$WT" ls-files --others --ignored --exclude-standard \
        | grep -vE '^(node_modules|cdk\.out|dist|coverage|bin|out|\.next|\.turbo)/' \
        | grep -vE '(\.tsbuildinfo|coverage\.(out|html)|next-env\.d\.ts|\.DS_Store)$' || true)
  [ -z "$bad" ] && return 0
  echo "FILES CREATED BUT GITIGNORED (ops ignores *.js and *.d.ts globally):"; echo "$bad"; return 1
}

# ---------------------------------------------------------------- backend database

GATE_PROJECT=""; COMPOSE=()
LOCK="$ROOT/.runs/.locks/backend-db"
release_lock() { [ -n "${LOCK_HELD:-}" ] && rmdir "$LOCK" 2>/dev/null || true; }
acquire_lock() {
  mkdir -p "$(dirname "$LOCK")"
  local waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    # Steal a lock abandoned by an interrupted run.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null || true; fi
    sleep 2; waited=$((waited+2)); [ "$waited" -gt 600 ] && return 2
  done
  LOCK_HELD=1
}
gate_teardown() {
  [ ${#COMPOSE[@]} -gt 0 ] && "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  release_lock
}

backend_db_and_integration() {
  acquire_lock || { echo "could not acquire backend DB lock"; touch "$INFRA_SENTINEL"; return 1; }
  trap gate_teardown EXIT

  local attempt
  for attempt in 1 2; do
    GATE_PROJECT="pfgate-$(echo "$RUN_ID" | tr '[:upper:]' '[:lower:]')-backend"
    GATE_DB_PORT=$("$ROOT/scripts/freeport.sh")
    export GATE_PROJECT GATE_DB_PORT
    COMPOSE=(docker compose -p "$GATE_PROJECT"
             -f "$WT/docker-compose.yml" -f "$ROOT/scripts/compose.gate.yml")
    echo "gate db: project=$GATE_PROJECT port=$GATE_DB_PORT (attempt $attempt)"
    if "${COMPOSE[@]}" up -d db; then break; fi
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    [ "$attempt" = 2 ] && { echo "compose up failed twice"; touch "$INFRA_SENTINEL"; return 1; }
  done

  "${COMPOSE[@]}" run --rm migrate || { echo "migrations failed"; touch "$INFRA_SENTINEL"; return 1; }

  # Equivalent to `make test-integration`, minus its hardcoded localhost:5432.
  DATABASE_URL="postgres://profitify:profitify@localhost:${GATE_DB_PORT}/profitify?sslmode=disable" \
    go test -count=1 ./...
}

assert_bootstraps() {
  local f missing=""
  for f in fetch-tickers start-pipeline ingest-ohlcv fetch-technicals \
           fetch-fundamentals enrich-ticker compute-stats close-pipeline; do
    [ -f "$WT/bin/lambda-$f/bootstrap" ] || missing="$missing $f"
  done
  [ -z "$missing" ] && return 0
  echo "missing lambda bootstraps:$missing"; return 1
}

# ---------------------------------------------------------------- run

step anti-cheat     check_no_suppressions
step test-integrity check_no_test_gutting
step gitignored     check_no_ignored_new_files

case "$REPO_KEY" in
  backend)
    # Mirrors CI's tidy-check job — a common silent auto-fail.
    step tidy      bash -c 'go mod tidy && git diff --exit-code go.mod go.sum'
    step vet       make vet
    step test-race make test-race
    step build     make build
    step bootstraps assert_bootstraps
    step integration backend_db_and_integration
    # Local golangci-lint is 2.4.0; CI pins v2.11. A local result proves nothing either way.
    advisory lint  bash -c 'command -v golangci-lint >/dev/null && golangci-lint run ./... || true'
    ;;
  web)
    step install   pnpm install --frozen-lockfile
    step lint      pnpm lint
    step format    pnpm format:check
    step types     pnpm type-check
    step test      pnpm test
    step build     env NEXT_PUBLIC_API_URL=https://api.profitify.xyz \
                       NEXT_PUBLIC_SITE_URL=https://profitify.xyz \
                       NEXT_PUBLIC_APP_ENV=production pnpm build
    step artifact  test -f "$WT/out/index.html"
    ;;
  ops)
    step install   npm ci --no-audit --no-fund
    step lint      npm run lint
    step format    npm run format:check
    step build     npm run build
    step test      npm test
    # No `cdk diff` — it needs AWS credentials. CI posts the real infra delta on the PR.
    step synth     npx cdk synth
    ;;
  *) echo "gate.sh: unknown repo '$REPO_KEY'" >&2; exit 2 ;;
esac

trap - ERR
if [ "$INFRA_ERROR" = 1 ]; then emit error; echo "GATE INFRA ERROR ($REPO_KEY)"; exit 2; fi
if [ -n "$FIRST_FAIL" ]; then emit fail; echo "GATE FAIL ($REPO_KEY) at step: $FIRST_FAIL"; exit 1; fi
emit pass; echo "GATE PASS ($REPO_KEY iter $ITER)"; exit 0
