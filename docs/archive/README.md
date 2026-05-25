# Archive — pre-1.0 history

This directory is **frozen as of v1.0** (2026-05-25). Nothing here is current documentation; nothing here should be edited.

It is kept because the reasoning, alternatives considered, and open-question discussions inside these documents may be useful when designing v1.x+ work that touches the same areas.

## What's here

- **`cr/`** — Change Requests CR-001 through CR-009. Each CR is a self-contained intake doc: problem, motivation, proposed approach, open questions, dependencies. `cr/conventions.md` is the cross-cutting decisions doc. `cr/README.md` is the original index.
- **`superpowers/plans/`** — per-CR implementation plans (Superpowers format). One plan per CR.
- **`superpowers/specs/`** — per-CR design specs (Superpowers format). Almost every plan has a sibling spec; the ones that don't (CR-004, CR-008 plans pre-spec) were absorbed into the implementing CR's body.

## Mapping to shipped artefacts

| CR | What landed in v1.0 |
|---|---|
| CR-001 | `.claude-plugin/plugin.json`, `package.json`, plugin-mode install paths in `README.md` |
| CR-002 | `skills/ingest/scripts/state-sources.js`, `wiki/.state/sources.yaml` schema |
| CR-003 | `src/documentation/` source kind in `state-sources.js`; ingest/query behaviour split in those skills |
| CR-004 | `scripts/validate-wiki.js`, the `Stop` hook in `plugin.json`, the frontmatter-contract.yaml machinery |
| CR-005 | `skills/reorganize/`, `skills/reorganize/scripts/reorganize.js` |
| CR-006 | `cr/CR-006-runbook.md` is the only artefact — rollout doc, no code |
| CR-007 | `scripts/contradictions.js`, `wiki/.state/contradictions.yaml`, `/second-brain:status reconcile` flows |
| CR-008 | `scripts/staleness.js`, `wiki/.state/staleness.yaml`, `/second-brain:status refresh` flows |
| CR-009 | `scripts/status.js`, `scripts/review-log.js`, `skills/status/`, `wiki/.state/since-review.yaml` |

## Where current documentation lives

- [`docs/USER-GUIDE.md`](../USER-GUIDE.md) — how to use the system
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) — how the system is built, how to extend it
- [`docs/REQUIREMENTS.md`](../REQUIREMENTS.md) — origin / blueprint
- [`docs/llm-wiki.md`](../llm-wiki.md) — the Karpathy seed doc

For v1.1+ work, write new design docs in a fresh `docs/design/` (or similar) — don't add to this archive.
