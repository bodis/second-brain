# CR-002 — Replace log-grep ingest detection with a YAML source-state store

**Depends on:** CR-001.

## Problem

Today the ingest SKILL detects unprocessed sources by listing files in `raw/`, then grepping `wiki/log.md` for the filenames it's already seen (`second-brain-ingest/SKILL.md:18-22`). Two failure modes:

- **No change detection.** A re-clipped or re-exported source with the same filename is invisible — the log says it was already ingested.
- **Brittle parsing.** The log is human-readable prose; if the LLM phrases an entry slightly differently, the detection fails.

## Motivation

The structured-documentation source type from CR-003 is *expected* to change occasionally (re-scrapes). Without content-hashing, structured-docs ingest would never see updates. Even for generic `raw/`, the user wants reliable "what changed" detection.

## Proposed approach

Introduce `wiki/.state/sources.yaml` per the schema in [conventions.md §3](./conventions.md). Add a single script `scripts/state-sources.sh` with subcommands:

- `state-sources.sh scan` — walk `raw/` and (later, post-CR-003) `src/documentation/`; print proposed YAML to stdout. Does not write the file.
- `state-sources.sh diff` — compare the current `sources.yaml` against the filesystem. Emit JSON or YAML with `new`, `changed`, `deleted` lists.
- `state-sources.sh commit <input>` — after the LLM finishes ingest, update `sources.yaml` with new hashes, `ingested_at` timestamps, and the list of `wiki_pages` produced.

Update the ingest SKILL:

- Step 1: invoke `state-sources.sh diff`. Read the result.
- Step 2+: operate on `new` and `changed` entries only. For `deleted`, prompt the user (don't auto-prune wiki pages).
- Final step: invoke `state-sources.sh commit` with the list of wiki pages produced.

The hash-store knows nothing about generic-vs-structured yet — that's CR-003. The schema reserves the `kind` field so CR-003 is a fill-in, not a redesign.

## Open questions

- Hashing algorithm: sha256 (standard) or blake3 (faster). Sha256 is fine at vault sizes — pick it unless there's a reason not to.
- What does `ingested_at` mean for partially-ingested sources (user stopped halfway)? Probably leave unset until commit.
- Does `wiki/log.md` retain its `## [date] ingest | Title` lines, or move entirely to `wiki/.state/ingest-runs.yaml`? Recommend: keep `log.md` as a human-readable narrative; the YAML is the source of truth. Decide during plan.
- Should `state-sources.sh commit` also detect orphaned wiki pages (pages in `sources.yaml.wiki_pages` for a now-deleted source)? Probably belongs in lint instead.
- PyYAML dependency: assume `python3 -c "import yaml"` works, or bundle a tiny dep? Plan should decide.

## Out of scope

- Two source types (CR-003) — they slot into the `kind` field, but the split itself is its own CR.
- Hooks that auto-run `state-sources.sh diff` (CR-004).
- A `ingest-runs.yaml` for full operation history (future CR if needed).
