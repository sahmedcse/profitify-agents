#!/usr/bin/env bash
# Per-run git worktrees, one per affected repo.
#
#   worktree.sh create  <run-id> <repo>...   all-or-nothing: preflight every repo, then create
#   worktree.sh cleanup <run-id>             remove this run's worktrees (refuses if dirty)
#   worktree.sh doctor                       prune stale worktrees and report orphaned gate containers
#
# The main checkouts are NEVER modified. The only operation touching them is `git fetch`,
# which is non-destructive. Worktrees are created from origin/main, so uncommitted work in
# the main checkout is irrelevant and untouched.
set -euo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"

die() { echo "worktree.sh: $*" >&2; exit 1; }

repo_dir() {
  case "$1" in
    backend) echo "$ROOT/profitify-backend" ;;
    web)     echo "$ROOT/profitify-web" ;;
    ops)     echo "$ROOT/profitify-ops" ;;
    *) die "unknown repo key '$1' (expected: backend, web, ops)" ;;
  esac
}

slug_of() { echo "${1#*-*-}"; }   # RUN_ID = <yyyymmdd>-<HHMMSS>-<slug>

cmd_create() {
  local run_id="${1:?usage: worktree.sh create <run-id> <repo>...}"; shift
  [ $# -gt 0 ] || die "no repos given"
  local slug; slug=$(slug_of "$run_id")
  local branch="feature/$slug"

  # ---- preflight EVERY repo before creating ANY, so a late collision doesn't
  # ---- leave earlier repos half-created.
  local r dir
  for r in "$@"; do
    dir=$(repo_dir "$r")
    [ -d "$dir/.git" ] || die "$dir is not a git repository"
    git -C "$dir" worktree prune
    git -C "$dir" fetch --prune origin '+refs/heads/main:refs/remotes/origin/main' -q \
      || die "fetch failed for $r"
    git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" \
      && die "$r already has local branch $branch"
    git -C "$dir" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 \
      && die "$r already has remote branch $branch"
    [ -e "$ROOT/.worktrees/$run_id/$r" ] && die "worktree already exists: .worktrees/$run_id/$r"
  done

  # ---- create
  for r in "$@"; do
    dir=$(repo_dir "$r")
    mkdir -p "$ROOT/.worktrees/$run_id"
    git -C "$dir" worktree add -q -b "$branch" "$ROOT/.worktrees/$run_id/$r" origin/main
    echo "created  $ROOT/.worktrees/$run_id/$r  ($branch from origin/main)"
  done
}

cmd_cleanup() {
  local run_id="${1:?usage: worktree.sh cleanup <run-id>}"
  local base="$ROOT/.worktrees/$run_id"
  [ -d "$base" ] || { echo "nothing to clean: $base"; return 0; }
  local r dir
  for r in backend web ops; do
    [ -d "$base/$r" ] || continue
    dir=$(repo_dir "$r")
    # `worktree remove` refuses when the tree is dirty. That refusal is a feature:
    # it stops us destroying agent work that was never committed.
    if git -C "$dir" worktree remove "$base/$r" 2>/dev/null; then
      echo "removed  $base/$r"
    else
      echo "KEPT     $base/$r (dirty or locked — inspect, then remove manually)" >&2
    fi
    git -C "$dir" worktree prune
  done
  rmdir "$base" 2>/dev/null || true
}

cmd_doctor() {
  local r dir
  for r in backend web ops; do
    dir=$(repo_dir "$r")
    git -C "$dir" worktree prune
    echo "== $r"
    git -C "$dir" worktree list
  done
  echo "== worktrees older than 7 days"
  find "$ROOT/.worktrees" -maxdepth 1 -mindepth 1 -type d -mtime +7 2>/dev/null || true
  echo "== orphaned gate compose projects"
  # The startswith("pfgate-") filter is the ONLY thing separating this listing from the
  # developer's own profitify-backend project. Never widen it.
  docker compose ls --format json 2>/dev/null \
    | jq -r '.[] | select(.Name | startswith("pfgate-")) | .Name' || true
}

case "${1:-}" in
  create)  shift; cmd_create  "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  doctor)  shift; cmd_doctor  "$@" ;;
  *) die "usage: worktree.sh <create|cleanup|doctor> ..." ;;
esac
