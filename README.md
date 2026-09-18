# profitify-agents

The control plane for [Profitify](https://github.com/sahmedcse?tab=repositories): a multi-agent
pipeline that takes one feature description and produces reviewed, test-gated pull requests across
several repositories.

This repo contains **no product code** — only agent definitions, one orchestration command, and the
verification scripts that gate it.

## The cycle

```
architect → you approve the plan → implement → gate → review → fix → PRs
                                     └──────── up to 3 iterations ────┘
```

1. A read-only **architect** agent plans the change, decides which repos it touches, and writes a
   machine-checkable cross-repo contract.
2. **You approve the plan.** Nothing is written to any repository before that.
3. **Implementers** work in isolated git worktrees, one per repo, in parallel.
4. A **gate script** runs the CI-equivalent checks and decides pass/fail.
5. A **reviewer** agent returns structured findings; blocking ones route back for a fix.
6. PRs open, cross-linked and in merge order. You review and merge.

## The design principle

**The model never judges whether the work passes.** Every control decision in the loop is a shell
exit code or a `jq` query against a file a script wrote:

- The iteration counter lives in a file, and the script that advances it refuses past the maximum.
- Implementer agents have no `status` field to report success with — the schema omits it deliberately.
- A gate records a fingerprint of the tree it tested; pushing is blocked if the tree changed since.
- The gate fails on added `t.Skip` / `eslint-disable` / `@ts-ignore` and on net-deleted test lines,
  because a cornered model's cheapest path to green is silencing the check.

An agent claiming "all tests pass" carries no weight.

## Safety

- Agents cannot deploy. `aws`, `cdk deploy`, `cdk destroy` and `gh pr merge` are denied at the
  permission layer. Merging a PR — the thing that reaches production — stays a human decision.
- Agents cannot touch your working checkouts. Writes are confined to per-run worktrees by both a
  deny rule and a `PreToolUse` hook that catches shell redirects.
- The test gate never touches your development database. It starts an ephemeral, port-randomised
  one, because the integration suite truncates tables.

## Layout

```
.claude/agents/      architect, three implementers, reviewer
.claude/commands/    /feature and /feature-status
.claude/hooks/       PreToolUse guard for the main checkouts
scripts/             gate, worktree, contract-check, verify-gate, iter, brief, pr-body
contracts/           cross-repo interfaces that nothing else tests
```

## Setup

The product repositories are expected as sibling directories and are gitignored here:

```
Profitify/
├── profitify-agents/   ← this repo, and the directory you launch Claude Code from
├── profitify-backend/
├── profitify-web/
└── profitify-ops/
```

Create your local settings from the example — permission rules match commands **literally**, so
the paths must be absolute and must match your own checkout:

```bash
sed "s|/ABSOLUTE/PATH/TO/Profitify|$PWD|g" \
  .claude/example-settings.json > .claude/settings.json
```

`.claude/settings.json` is gitignored for that reason: it is machine-specific. Edit
`example-settings.json` when you change a permission rule, and regenerate.

Requires `gh`, `jq`, Docker, and the toolchains of whichever repos you target.

## License

MIT
