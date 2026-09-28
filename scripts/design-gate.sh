#!/usr/bin/env bash
# The interactive approval gates: the user annotates a page in the browser and decides there,
# without coming back to the terminal to say they're done. Used for the design gate (the
# designer's mockup.html) and the plan gate (plan.html, rendered by plan-html.sh).
#
#   design-gate.sh inject <run-id> [--doc design|plan]
#                                    add the annotation layer to mockup.html (default) or
#                                    plan.html. Re-run after every revision or re-render; prints
#                                    the new revision id
#   design-gate.sh serve  <run-id>   serve the run dir on 127.0.0.1 (run in the background; prints
#                                    and writes the base URL to gate.url; open <url>mockup.html
#                                    or <url>plan.html)
#   design-gate.sh wait   <run-id>   block until the user clicks "Send notes" or "Approve design"
#                                    in the page (run under Monitor)
#
# inject is idempotent: it strips any previous layer between the pfa:begin/pfa:end markers first,
# so the designer never has to preserve it. The revision id is a hash of the mockup without the
# layer; notes are keyed by it, so an earlier revision's pins never reappear, and a decision
# posted from a stale tab is set aside rather than acted on.
#
# Nothing leaves the machine: the server binds to loopback and the page makes no other requests.
#
# Exit codes (wait): 0 a decision was made, printed as one line
#                      "DECISION: <approve|revise> rev=<rev> notes=<n>"
#                    1 the server is not responding — fall back to "Copy notes" in the terminal
# Exit codes (all):  2 bad arguments or missing run artifacts.
set -euo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"
USAGE="usage: design-gate.sh inject|serve|wait <run-id> [--doc design|plan]"
CMD="${1:-}"; RUN_ID="${2:-}"; DOC=design
if [ "${3:-}" = "--doc" ]; then DOC="${4:-}"; fi
case "$DOC" in
  design) PAGE=mockup.html; APPROVE="Approve design" ;;
  plan)   PAGE=plan.html;   APPROVE="Approve plan" ;;
  *) echo "design-gate: --doc must be design or plan" >&2; exit 2 ;;
esac
[ -n "$CMD" ] && [ -n "$RUN_ID" ] || { echo "$USAGE" >&2; exit 2; }
RUN="$ROOT/.runs/$RUN_ID"
[ -d "$RUN" ] || { echo "design-gate: no run dir at $RUN" >&2; exit 2; }

case "$CMD" in
  inject)
    [ -f "$RUN/$PAGE" ] || { echo "design-gate: no $PAGE in $RUN" >&2; exit 2; }
    # Keep the previous round's notes as a record of what was asked for.
    if [ -f "$RUN/notes.json" ]; then
      OLD=$(jq -r '.rev // "unknown"' "$RUN/notes.json" 2>/dev/null || echo unknown)
      mv "$RUN/notes.json" "$RUN/notes.$OLD.json"
    fi
    python3 - "$RUN" "$RUN_ID" "$ROOT/scripts/annotate.js" "$PAGE" "$APPROVE" <<'PY'
import hashlib, json, re, sys
run, run_id, js_path, page, approve = sys.argv[1:6]
path = f"{run}/{page}"
html = open(path, encoding="utf-8").read()
html = re.sub(r"<!-- pfa:begin -->.*?<!-- pfa:end -->\n?", "", html, flags=re.S)
if html.count("</body>") != 1:
    sys.exit(f"design-gate: {page} must contain exactly one </body>")
rev = hashlib.sha256(html.encode()).hexdigest()[:10]
js = open(js_path, encoding="utf-8").read()
block = ("<!-- pfa:begin -->\n<script>window.PFA_RUN = %s; window.PFA_REV = %s; "
         "window.PFA_APPROVE_LABEL = %s;</script>\n<script>\n%s</script>\n<!-- pfa:end -->\n") % (
    json.dumps(run_id), json.dumps(rev), json.dumps(approve), js)
open(path, "w", encoding="utf-8").write(html.replace("</body>", block + "</body>"))
open(f"{run}/gate.rev", "w").write(rev + "\n")
print(rev)
PY
    ;;

  serve)
    rm -f "$RUN/gate.url"
    exec python3 "$ROOT/scripts/design-gate-server.py" "$RUN"
    ;;

  wait)
    [ -f "$RUN/gate.rev" ] || { echo "design-gate: run inject first" >&2; exit 2; }
    REV=$(cat "$RUN/gate.rev")
    for _ in $(seq 1 20); do [ -f "$RUN/gate.url" ] && break; sleep 0.5; done
    [ -f "$RUN/gate.url" ] || { echo "SERVER DOWN: no gate.url — did serve start?"; exit 1; }
    URL=$(cat "$RUN/gate.url")
    while true; do
      if jq -e '.done == true' "$RUN/notes.json" >/dev/null 2>&1; then
        GOT=$(jq -r '.rev // ""' "$RUN/notes.json")
        if [ "$GOT" != "$REV" ]; then
          # A tab still open on an older revision decided. Set it aside and keep waiting.
          mv "$RUN/notes.json" "$RUN/notes.stale-$GOT.json"
          echo "STALE: ignored a decision from an older mockup revision ($GOT); still waiting on $REV"
          continue
        fi
        echo "DECISION: $(jq -r '.decision // "none"' "$RUN/notes.json") rev=$REV notes=$(jq '.notes | length' "$RUN/notes.json")"
        exit 0
      fi
      curl -s -o /dev/null --max-time 2 "$URL" || { echo "SERVER DOWN: $URL not responding"; exit 1; }
      sleep 2
    done
    ;;

  *) echo "$USAGE" >&2; exit 2 ;;
esac
