#!/usr/bin/env bash
# Merges the two split reviewers into the canonical profitify.review.v1 file.
#
#   merge-review.sh <run-id> <repo> <iteration>
#
# Reads:   .runs/<run>/review/<repo>.iter<N>.spec.json     (spec-reviewer, all blocking)
#          .runs/<run>/review/<repo>.iter<N>.quality.json  (quality-reviewer, all advisory)
# Writes:  .runs/<run>/review/<repo>.iter<N>.json          (canonical — brief.sh and pr-body.sh
#                                                           already read this and need no change)
#
# Policy lives here rather than in agent prose, so it is mechanical:
#   - spec findings are blocking; the first 5 survive, the rest are demoted to advisory
#   - quality findings are advisory, except escalate:true which are promoted to blocking
#   - escalations are counted against the same cap of 5, and are ordered first
#   - verdict is derived from the final blocking count, never from an agent's opinion
#
# Exit codes: 0 merged. 1 spec review missing or unparseable (orchestrator must escalate —
# never treat this as an approval). A missing or unparseable quality review is degraded to a
# visible advisory finding and does not fail the merge, because it cannot block by construction.
set -euo pipefail
ROOT="${PROFITIFY_ROOT:-/Users/sadatahmed/Personal/Profitify}"
RUN_ID="${1:?usage: merge-review.sh <run-id> <repo> <iteration>}"
REPO="${2:?missing repo}"; ITER="${3:?missing iteration}"
RUN="$ROOT/.runs/$RUN_ID"
DIR="$RUN/review"
SPEC="$DIR/$REPO.iter$ITER.spec.json"
QUAL="$DIR/$REPO.iter$ITER.quality.json"
OUT="$DIR/$REPO.iter$ITER.json"
CAP="${REVIEW_BLOCKING_CAP:-5}"

# --- spec review is mandatory -------------------------------------------------
if [ ! -f "$SPEC" ]; then
  echo "merge-review: spec review missing: $SPEC" >&2
  exit 1
fi
if ! jq -e '.schema == "profitify.review.spec.v1"' "$SPEC" >/dev/null 2>&1; then
  echo "merge-review: $SPEC is not valid profitify.review.spec.v1" >&2
  exit 1
fi
# Every spec finding must name one of the six criteria. An unnumbered finding means taste leaked
# into the blocking lane, which is the exact failure this split exists to prevent.
if ! jq -e '[.findings[] | select((.criterion|type) != "number" or .criterion < 1 or .criterion > 6)] | length == 0' \
     "$SPEC" >/dev/null 2>&1; then
  echo "merge-review: $SPEC has a finding with no valid criterion (1-6)" >&2
  exit 1
fi

# --- quality review is best-effort -------------------------------------------
QUAL_OK=1
if [ ! -f "$QUAL" ] || ! jq -e '.schema == "profitify.review.quality.v1"' "$QUAL" >/dev/null 2>&1; then
  QUAL_OK=0
fi
if [ "$QUAL_OK" -eq 0 ]; then
  QUAL=$(mktemp)
  # shellcheck disable=SC2064  # expand now: the path must be fixed at trap time
  trap "rm -f '$QUAL'" EXIT
  cat > "$QUAL" <<'FALLBACK'
{
  "schema": "profitify.review.quality.v1",
  "findings": [
    {
      "category": "idiom",
      "file": "-",
      "line": 0,
      "problem": "Quality review is missing or was not valid profitify.review.quality.v1; advisory findings are absent from this PR body.",
      "required_change": "Re-run the quality reviewer for this iteration if the advisory pass matters.",
      "evidence": "merge-review.sh fallback"
    }
  ],
  "notes": "quality review unavailable"
}
FALLBACK
fi

TREE_SHA=$(jq -r '.tree_sha // ""' "$SPEC")
if [ -z "$TREE_SHA" ] || [ "$TREE_SHA" = "null" ]; then
  GJSON="$RUN/gate/$REPO.iter$ITER.json"
  [ -f "$GJSON" ] && TREE_SHA=$(jq -r '.tree_sha // ""' "$GJSON")
fi

jq -n \
  --arg run "$RUN_ID" --arg repo "$REPO" --argjson iter "$ITER" \
  --arg tree "$TREE_SHA" --argjson cap "$CAP" --argjson qual_ok "$QUAL_OK" \
  --slurpfile spec "$SPEC" --slurpfile qual "$QUAL" '
  ($spec[0]) as $s | ($qual[0]) as $q

  # Escalated quality findings rank above spec findings: they are security or test-integrity
  # problems the spec pass missed, so they must not be the ones the cap discards.
  | ([ $q.findings[] | select(.escalate == true)
       | { severity: "blocking", category: (.category // "security"),
           file, line, problem, required_change, evidence,
           origin: "quality-escalated" } ]) as $esc

  | ([ $s.findings[]
       | { severity: "blocking", category: (.category // "spec"), criterion,
           file, line, problem, required_change, evidence,
           origin: "spec" } ]) as $spc

  | ([ $q.findings[] | select(.escalate != true)
       | { severity: "advisory", category: (.category // "quality"),
           file, line, problem, required_change, evidence,
           origin: "quality" } ]) as $adv

  | ($esc + $spc) as $candidates
  | ($candidates[:$cap]) as $kept
  | ([ $candidates[$cap:][] | .severity = "advisory" | .demoted = true ]) as $demoted

  # Number within each lane and emit blocking first, so brief.sh renders the list the
  # implementer must fix in order, and the advisory ids in the PR body read independently.
  | ($kept + $demoted + $adv) as $all
  | ([ $all[] | select(.severity == "blocking") ]
     | to_entries | map(.value + { id: "B\(.key + 1)" })) as $blocking
  | ([ $all[] | select(.severity == "advisory") ]
     | to_entries | map(.value + { id: "A\(.key + 1)" })) as $advisory
  | ($blocking + $advisory) as $findings

  | ($blocking | length) as $nblock
  | ($demoted | length) as $ndemoted

  | {
      schema: "profitify.review.v1",
      run_id: $run,
      repo: $repo,
      iteration: $iter,
      tree_sha: $tree,
      verdict: (if $nblock > 0 then "request_changes" else "approve" end),
      # NOT ($s.contract_ok // true): the jq // operator treats false as absent, so an explicit
      # false would silently become true — the one value that matters here.
      contract_ok: (if ($s | has("contract_ok")) then $s.contract_ok else true end),
      findings: $findings,
      notes: ([
        ($s.notes // empty),
        ($q.notes // empty),
        (if $ndemoted > 0 then "\($ndemoted) blocking finding(s) beyond the cap of \($cap) were demoted to advisory." else empty end),
        (if ($esc | length) > 0 then "\($esc | length) quality finding(s) were escalated to blocking." else empty end),
        (if $qual_ok == 0 then "Quality review was unavailable; see the advisory placeholder." else empty end)
      ] | join(" "))
    }
' > "$OUT.tmp"

mv "$OUT.tmp" "$OUT"

BLOCKING=$(jq '[.findings[]|select(.severity=="blocking")]|length' "$OUT")
ADVISORY=$(jq '[.findings[]|select(.severity=="advisory")]|length' "$OUT")
echo "merge-review: $OUT — $BLOCKING blocking, $ADVISORY advisory, verdict $(jq -r .verdict "$OUT")"
