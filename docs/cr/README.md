# Change Requests

Backlog for upgrading the second-brain skills. Each CR is a self-contained intake doc: problem, motivation, proposed approach, open questions, dependencies. Plan + implementation happen per-CR.

Shared decisions for all CRs live in [conventions.md](./conventions.md). Reference it instead of re-deciding things like file paths, YAML schemas, or the hooks-vs-LLM split.

## Backlog

| ID | Title | Depends on |
|---|---|---|
| [CR-001](./CR-001-claude-code-plugin.md) | Convert repo to a Claude Code plugin (drop multi-agent) | — |
| [CR-002](./CR-002-source-state-yaml.md) | Replace log-grep ingest detection with a YAML source-state store | CR-001 |
| [CR-003](./CR-003-two-source-types.md) | Add structured `src/documentation/` source type alongside generic `raw/` | CR-002 |
| [CR-004](./CR-004-hooks-and-scripts.md) | Deterministic hooks + validation scripts framework | CR-002 |
| [CR-005](./CR-005-reorganize-skill.md) | New `/second-brain:reorganize` skill for wiki self-improvement | CR-004 |
| [CR-006](./CR-006-multi-vault-deployment.md) | Roll plugin out to yettel + sibling vaults | CR-001..CR-005 |

## Workflow

1. Pick the next unblocked CR.
2. Plan it (separate session).
3. Implement + review.
4. Update the dependency column above as things land.

## Notes

- Open questions inside each CR are intentional — answer them during plan, not now.
- CR scope is deliberately narrow. Don't grow a CR; spawn a follow-up CR.
- This file is the only top-level index — keep it accurate when adding/removing CRs.
