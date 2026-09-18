#!/usr/bin/env bash
# PreToolUse(Bash) guard.
#
# The Edit/Write deny rules in settings.json cannot see shell redirects, so
# `echo x > /path/profitify-web/src/y.ts` would slip past them. This blocks
# write-shaped Bash commands that target a main checkout.
#
# Reads is deliberately allowed: agents legitimately `cat` a repo's CLAUDE.md.
# Worktree paths (/Profitify/.worktrees/...) never contain "profitify-<name>/",
# so they can't match here.
#
# exit 0 = allow, exit 2 = block (stderr is shown to the model)
set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$CMD" ] && exit 0

MAIN='Profitify/profitify-[a-z-]+'
block() { echo "BLOCKED: $1" >&2
  echo "Main checkouts hold the user's uncommitted work and are read-only to agents." >&2
  echo "Write to the run's worktree under /Users/sadatahmed/Personal/Profitify/.worktrees/ instead." >&2
  exit 2; }

# 1. Redirection whose TARGET is inside a main checkout (2>/dev/null etc. won't match).
grep -qE ">>?[[:space:]]*['\"]?[^[:space:]'\"]*${MAIN}/" <<<"$CMD" \
  && block "shell redirect into a main checkout"

# 2. tee / sed -i into a main checkout.
grep -qE "tee([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^|;&]*${MAIN}/" <<<"$CMD" \
  && block "tee into a main checkout"
grep -qE "sed[[:space:]]+(-[^[:space:]]*[[:space:]]+)*-i" <<<"$CMD" \
  && grep -qE "$MAIN" <<<"$CMD" && block "in-place sed on a main checkout"

# 3. Filesystem mutation targeting a main checkout.
grep -qE "(^|[;&|[:space:]])(rm|mv|cp|touch|truncate|dd|ln|install|patch|rmdir|chmod|chown)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^;&|]*${MAIN}/" <<<"$CMD" \
  && block "filesystem mutation inside a main checkout"

# 4. Mutating git operations against a main checkout.
grep -qE "git[[:space:]]+(-C[[:space:]]+)?[^[:space:];&|]*${MAIN}[^[:space:];&|]*[[:space:]]+(add|commit|checkout|switch|reset|clean|stash|apply|rm|mv|restore|merge|rebase|pull|push)" <<<"$CMD" \
  && block "mutating git command against a main checkout"

exit 0
