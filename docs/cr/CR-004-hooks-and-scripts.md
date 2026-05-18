# CR-004 — Deterministic hooks + validation scripts framework

**Depends on:** CR-002. (Needs the YAML state store to exist before hooks can act on it.)

## Problem

Every check in `lint/SKILL.md` is LLM prose: "Scan all wiki pages for `[[wikilink]]` references. For each link, verify the target page exists." The LLM has to remember to run the check, do it correctly, and not skim. Same for index consistency, frontmatter validation, orphan detection. These are deterministic operations that scripts can do faster and verifiably.

## Motivation

[Conventions §4](./conventions.md) says: hooks-first, LLM-last for verifiable work. This CR establishes the framework — what hooks fire, what scripts exist, what they output — so subsequent CRs (lint refactor, reorganize) can rely on it rather than re-implementing in prose.

## Proposed approach

### Scripts (deterministic)

Add a `scripts/` directory at the plugin root:

| Script | Purpose | Used by |
|---|---|---|
| `state-sources.sh` | Hash store CRUD (delivered by CR-002). | ingest |
| `validate-frontmatter.sh` | Parse every `wiki/**/*.md`. Fail if YAML frontmatter is missing/malformed or required keys absent. | post-ingest hook, lint |
| `validate-wikilinks.sh` | Extract all `[[...]]` and verify targets exist. Output JSON: `{broken: [...], orphans: [...]}`. | post-ingest hook, lint |
| `validate-index.sh` | Diff `wiki/index.md` entries against actual files in `wiki/{sources,entities,concepts,synthesis}/`. | post-ingest hook, lint |
| `sync-index.sh` | Auto-fix `wiki/index.md` entries from filesystem reality. Idempotent. | optional post-ingest hook |

All scripts:
- Run from any cwd; resolve vault root by walking up to find `wiki/`.
- Exit nonzero on failure with structured stderr.
- Have a `--json` mode for machine consumption.
- Are pure bash + (where needed) `python3` with `PyYAML`.

### Hooks (Claude Code event handlers)

Declared in `.claude-plugin/plugin.json`. Use the events documented in `<claude-code-docs>/automation/`. Initial set:

| Event | Script | Why |
|---|---|---|
| PostToolUse on `Write`/`Edit` targeting `wiki/**` | `validate-frontmatter.sh --json` | Catch malformed frontmatter the LLM just wrote, before it cascades. |
| PostToolUse on `Write`/`Edit` targeting `wiki/index.md` | `validate-index.sh --json` | Catch index drift instantly. |
| Stop (end of ingest/lint/reorganize) | `validate-wikilinks.sh --json` | Final pass before handing back to the user. |

Hooks emit errors on stderr; Claude Code surfaces them in-session so the LLM can fix the problem before the user sees the result.

### SKILL updates

After this CR, `lint/SKILL.md` shrinks dramatically:
- Steps that today say "scan for X" become "run `validate-X.sh --json` and present its output".
- The LLM keeps responsibility for **judgment** items: contradictions, stale claims, missing pages worth creating, suggestions for new sources to ingest.

## Open questions

- Hook execution location: hooks declared in a plugin run in the user's machine context. Path resolution for scripts inside the plugin? Plugin root is reachable via env var per Claude Code docs — verify in plan.
- Which hooks block vs warn? Frontmatter validation probably blocks; wikilink validation probably warns (false positives possible with concepts not yet written).
- Auto-fix vs report-only: `sync-index.sh` could run automatically post-ingest. Tempting but risky if the LLM was mid-write. Default: report-only; user opts into auto-fix.
- Cost of hooks firing on every Write — could be noisy if the LLM does 15 writes per ingest. Maybe debounce or only fire on `Stop`.
- Hook output verbosity: full JSON, or one-line summary with "details on request"? Probably summary by default.

## Out of scope

- The `/reorganize` skill (CR-005) — uses these scripts but is its own CR.
- Auto-fix automation beyond `sync-index.sh`.
- Pre-commit git hooks for the user's vault — Claude Code hooks only.
