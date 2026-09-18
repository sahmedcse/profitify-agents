# profitify-agents

Control plane for the Profitify project. This repo holds agent definitions, the `/feature`
orchestration command, and the verification scripts that gate it. It contains **no product code**.

The four product repos are checked out as sibling directories and are gitignored here. Each has its
own `CLAUDE.md` with repo-local conventions — read it before working in that repo.

## Repo map

| Dir | Stack | Deploys on merge to `main` |
|---|---|---|
| `profitify-backend/` | Go 1.25, Chi, pgx/v5, TimescaleDB, 8 arm64 Lambdas | Pushes 8 ECR images, `aws lambda update-function-code` on all 8 `prod-*` functions |
| `profitify-web/` | Next.js 16, React 19, TS strict, Tailwind v4, TanStack Query, **pnpm** | `s3 sync --delete` + full CloudFront invalidation. **No `paths-ignore`** — even a docs-only merge redeploys |
| `profitify-ops/` | AWS CDK, TypeScript, **npm** | Deploys every CDK stack with no approval prompt |
| `profitify-backend-services/` | Go, Polygon.io, DynamoDB | **Dormant.** Last commit 2025-09-06, superseded by `profitify-backend`, referenced by nothing. Out of scope. |

**Merging any PR is a production deploy.** PRs open ready for review, but `gh pr merge` is denied
to agents: the merge is always a human decision.

## How the repos couple

### The ECR tag contract (backend ↔ ops)

`profitify-ops` references backend Lambda images by **eight mutable tags** in a shared ECR
repository. That repository is *imported* rather than CDK-managed, because backend CD must push
images before the Lambdas can deploy. The repository name is a deployment variable, not a literal
in either repo — read it from `profitify-ops/lib/constructs/` when you need it.

```
fetch-tickers  start-pipeline  ingest-ohlcv  fetch-technicals
fetch-fundamentals  enrich-ticker  compute-stats  close-pipeline
```

These same eight strings appear in six places that must agree. Renaming a Lambda in backend without
the matching ops change breaks the next ops deploy with `Image ID cannot be found`. Nothing in either
repo's tests catches it — `scripts/contract-check.sh` is what catches it. See
`contracts/ecr-lambda-tags.md`.

### The API contract (backend ↔ web)

`profitify-web` is a static export that calls the Go API at `NEXT_PUBLIC_API_URL`. All fetching goes
through `src/lib/api-client.ts`; response types live in `src/types/api.ts` and must match the Go
handlers' JSON tags exactly. There is no OpenAPI spec, so the architect declares the shape in
`contract.json` and both sides implement against that text.

### Deploy ordering

Default merge order is **backend → ops → web**: CD must push the ECR tags before ops can reference
them, and the API must be live before the frontend calls it. This **inverts when a Lambda is
removed** — ops must stop referencing the tag first. Order is data in `contract.json.merge_order`,
never assumed.

## Shared conventions

- Branches: `feature/`, `bug/`, `hotfix/`, `chore/`. Commits: Conventional Commits.
- All PRs require review; no direct pushes to `main`.
- One `/feature` run uses the **same branch name in every affected repo** — that is how sibling PRs
  are found mechanically (`gh pr list --head feature/<slug>`).

## Environment notes that bite

- **`profitify-db` runs persistently** on port 5432 with your dev data. The backend integration tests
  call `truncateAll` (`DELETE FROM tickers`, …), and `make test-integration` hardcodes
  `localhost:5432`. Never point a gate at it — `scripts/gate.sh` spins an ephemeral, port-randomised
  database instead. See `scripts/compose.gate.yml`.
- `profitify-ops/.gitignore` ignores `*.js` and `*.d.ts` **globally**. Generated JS is invisible to
  git; only `.ts` sources count as a change.
- Package managers differ: web is **pnpm**, ops is **npm**. Never cross them.
- Local `golangci-lint` is 2.4.0; backend CI pins v2.11. Local lint is advisory, not authoritative.
- Local Node is 24; ops CI uses Node 22.
- macOS has no `flock(1)` — locking uses atomic `mkdir`.

## Known upstream bugs (not yet fixed)

- `profitify-backend/CLAUDE.md` claims CI enforces >90% coverage. **It does not** — the coverage job
  only renders a sticky PR comment; nothing exits non-zero.
- `profitify-backend/CLAUDE.md` says Go 1.23+ (actual: 1.25) and omits `indicator/`, `pipeline/`,
  `queue/`, `signal/`, `stats/`, `testutil/` from its directory listing.
- `profitify-backend/.github/workflows/ci.yml` asserts only **6 of 8** lambda bootstraps —
  `start-pipeline` and `close-pipeline` are missing.
