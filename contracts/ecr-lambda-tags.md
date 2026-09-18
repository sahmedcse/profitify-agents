# Contract: ECR Lambda tags (backend ↔ ops)

`profitify-ops` deploys eight Docker-image Lambdas whose images come from a shared ECR
repository, referenced by **mutable tag**. `profitify-backend`'s CD workflow builds
and pushes those tags. Neither repo tests the pairing, so a rename in one silently breaks the other's
next deploy with `Image ID cannot be found`.

## The eight tags

```
fetch-tickers  start-pipeline  ingest-ohlcv  fetch-technicals
fetch-fundamentals  enrich-ticker  compute-stats  close-pipeline
```

## The six places they must agree

| Set | Repo | Location | Shape |
|---|---|---|---|
| A | backend | `.github/workflows/cd.yml` | `strategy.matrix.function` list items |
| B | backend | `cmd/lambda-<tag>/` | one directory per tag |
| C | backend | `build/lambda-<tag>.Dockerfile` | one Dockerfile per tag |
| D | ops | `lib/constructs/pipeline-lambdas.ts` | `code: imageCode('<tag>')` |
| E | ops | `lib/constructs/pipeline-lambdas.ts` | ``functionName: `${envName}-<tag>` `` |
| F | run | `.runs/<id>/contract.json` | `lambda_functions[].tag` where `action != "removed"` |

`scripts/contract-check.sh` derives all six mechanically and diffs them.

## Rules for changes

- **Adding a Lambda** touches all of A–E plus `Makefile` (`build-lambda-<tag>` target and `.PHONY`)
  and `ci.yml`'s bootstrap assertion. Merge order: backend first (so the tag exists in ECR), then ops.
- **Removing a Lambda** inverts the merge order: **ops first**, so nothing references the tag before
  the image disappears.
- **Renaming** is an add plus a remove. Do not treat it as a single atomic edit across repos.

## Known drift (as of 2026-09-18)

`profitify-backend/.github/workflows/ci.yml` asserts only **six** bootstraps in its `build` job —
`start-pipeline` and `close-pipeline` are missing. That is a gap in CI coverage, not a deploy break:
`make build` does build all eight. `contract-check.sh` reports it as an advisory finding.
