#!/usr/bin/env bash
# Renders a run's plan.md + contract.json into one self-contained HTML page for the
# Step 2 approval gate.
#
#   plan-html.sh <run-id> [--open]
#
# Writes .runs/<run-id>/plan.html and prints its path. With --open, opens it in the
# default browser.
#
# The page is a LOCAL FILE and is never uploaded. The approval gate is a decision the
# user makes now, not a deliverable to share, and a plan names route paths, table names
# and ECR tags — so the default is that none of it leaves the machine.
#
# Rendering is mechanical on purpose: the architect writes markdown only, and this gives
# every run identical styling for no model tokens. Markdown is converted by pandoc rather
# than a hand-rolled parser, because plan.md contains GFM tables and several hundred
# inline code spans that a regex renderer would mangle.
#
# Exit codes: 0 rendered. 1 bad arguments or missing run artifacts. 3 pandoc is not
# installed — the caller should fall back to the terminal-only gate rather than block,
# since a missing renderer must never stop a run from being approvable.
set -euo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"
RUN_ID="${1:?usage: plan-html.sh <run-id> [--open]}"
OPEN="${2:-}"
RUN="$ROOT/.runs/$RUN_ID"
MD="$RUN/plan.md"
CONTRACT="$RUN/contract.json"
OUT="$RUN/plan.html"

[ -f "$MD" ] || { echo "plan-html: no plan.md at $MD" >&2; exit 1; }

if ! command -v pandoc >/dev/null 2>&1; then
  echo "plan-html: pandoc not installed (brew install pandoc); fall back to the terminal gate" >&2
  exit 3
fi

# --- facts for the header strip, straight from the contract ---------------------
REPOS="?"; MERGE_ORDER="?"
if [ -f "$CONTRACT" ]; then
  REPOS=$(jq -r '[.repos[]] | join(", ")' "$CONTRACT" 2>/dev/null || echo "?")
  MERGE_ORDER=$(jq -r '.merge_order | join(" → ")' "$CONTRACT" 2>/dev/null || echo "?")
fi
SLUG=$(jq -r '.slug // "?"' "$RUN/run.json" 2>/dev/null || echo "?")
BRANCH=$(jq -r '.branch // "?"' "$RUN/run.json" 2>/dev/null || echo "?")

BODY=$(pandoc --from=gfm --to=html5 "$MD")

# Single-quoted heredoc: the CSS is full of braces and # that must not be expanded.
cat > "$OUT" <<'HTMLHEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Plan — approval gate</title>
<style>
  :root {
    --bg: #fbfaf8; --panel: #ffffff; --ink: #1a1a1a; --ink-soft: #55534e;
    --rule: #e3e0da; --accent: #8a5a2b; --warn-bg: #fdf6e8; --warn-rule: #e0c68a;
    --code-bg: #f4f2ee;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #17171a; --panel: #1e1e22; --ink: #eceae6; --ink-soft: #a8a49c;
      --rule: #32323a; --accent: #d9a05b; --warn-bg: #2a2418; --warn-rule: #5c4a24;
      --code-bg: #26262b;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 860px; margin: 0 auto; padding: 40px 24px 96px; }
  .gate {
    background: var(--warn-bg); border: 1px solid var(--warn-rule);
    border-radius: 10px; padding: 16px 20px; margin-bottom: 32px;
  }
  .gate h1 { margin: 0 0 6px; font-size: 17px; letter-spacing: -0.01em; }
  .gate p { margin: 0; font-size: 14px; color: var(--ink-soft); }
  dl.facts {
    display: grid; grid-template-columns: max-content 1fr; gap: 6px 18px;
    margin: 0 0 36px; padding: 18px 20px;
    background: var(--panel); border: 1px solid var(--rule); border-radius: 10px;
    font-size: 14px;
  }
  dl.facts dt { color: var(--ink-soft); }
  dl.facts dd { margin: 0; font-variant-numeric: tabular-nums; }
  h1, h2, h3, h4 { line-height: 1.25; letter-spacing: -0.015em; }
  h1 { font-size: 30px; margin: 0 0 18px; }
  h2 {
    font-size: 22px; margin: 44px 0 14px;
    padding-bottom: 7px; border-bottom: 1px solid var(--rule);
  }
  h3 { font-size: 17px; margin: 30px 0 10px; }
  h4 { font-size: 15px; margin: 22px 0 8px; color: var(--ink-soft); }
  p, li { overflow-wrap: break-word; }
  a { color: var(--accent); }
  code {
    background: var(--code-bg); padding: 0.12em 0.36em; border-radius: 4px;
    font: 0.875em/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  pre {
    background: var(--code-bg); border: 1px solid var(--rule); border-radius: 8px;
    padding: 14px 16px; overflow-x: auto;
  }
  pre code { background: none; padding: 0; font-size: 13px; }
  /* Wide tables scroll inside their own box; the page itself never scrolls sideways. */
  .tw { overflow-x: auto; margin: 18px 0; border: 1px solid var(--rule); border-radius: 8px; }
  table { border-collapse: collapse; width: 100%; font-size: 14px; }
  th, td { text-align: left; padding: 9px 13px; border-bottom: 1px solid var(--rule); vertical-align: top; }
  th { background: var(--panel); font-weight: 600; white-space: nowrap; }
  tr:last-child td { border-bottom: none; }
  blockquote {
    margin: 18px 0; padding: 2px 0 2px 16px;
    border-left: 3px solid var(--rule); color: var(--ink-soft);
  }
  ul, ol { padding-left: 24px; }
  li { margin: 5px 0; }
  hr { border: none; border-top: 1px solid var(--rule); margin: 36px 0; }
  .foot { margin-top: 56px; padding-top: 16px; border-top: 1px solid var(--rule);
          font-size: 13px; color: var(--ink-soft); }
  @media print { .gate { border-color: #999; } body { background: #fff; } }
</style>
</head>
<body><div class="wrap">
HTMLHEAD

{
  printf '<div class="gate"><h1>Approval gate — nothing has been written to any repo</h1>'
  printf '<p>Read this, then answer approve / revise / cancel in the terminal. '
  printf 'Worktrees are created only after approval.</p></div>\n'
  printf '<dl class="facts">'
  printf '<dt>run</dt><dd><code>%s</code></dd>' "$RUN_ID"
  printf '<dt>slug</dt><dd><code>%s</code></dd>' "$SLUG"
  printf '<dt>branch</dt><dd><code>%s</code></dd>' "$BRANCH"
  printf '<dt>repos</dt><dd>%s</dd>' "$REPOS"
  printf '<dt>merge order</dt><dd>%s</dd>' "$MERGE_ORDER"
  printf '</dl>\n'
  # Wrap pandoc's tables so wide ones scroll in place.
  printf '%s\n' "$BODY" | sed -e 's|<table>|<div class="tw"><table>|g' -e 's|</table>|</table></div>|g'
  printf '<p class="foot">Rendered by <code>scripts/plan-html.sh</code> from <code>plan.md</code>. '
  printf 'Local file — not uploaded anywhere. Merging the resulting PRs deploys to production.</p>\n'
  printf '</div></body></html>\n'
} >> "$OUT"

echo "$OUT"
if [ "$OPEN" = "--open" ]; then
  command -v open >/dev/null 2>&1 && open "$OUT"
fi
