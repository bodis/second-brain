# CR-009 Design — `/second-brain:status` dashboard + review-log + headless contract

**Status:** Draft, pending user review
**Date:** 2026-05-21
**CR:** [CR-009](../../cr/CR-009-status-dashboard.md)
**Conventions:** [docs/cr/conventions.md](../../cr/conventions.md)
**Depends on:** CR-002 (landed; `wiki/.state/sources.yaml` + `state-sources.js diff`), CR-004 (landed; `scripts/validate-wiki.js all --json` produces the lint counts)
**Used by (forward contracts only):** CR-007 (will add `/status reconcile` body + `kind: contradiction-judged` appends), CR-008 (will add `/status refresh` body + `kind: staleness-judged` appends).

## 1. Problem

The project is gaining concerns the user has to act on — sources to ingest, contradictions to resolve, stale pages to triage, lint warnings, reorganize candidates. Each new concern threatens to spawn another slash-command, which the user is explicit they will not memorise. Three needs converge:

1. **One thing the user remembers.** A single command that surfaces every pending concern and routes to sub-flows for human-only work.
2. **A machine-readable surface.** Cron jobs need to ask "what state is this vault in?" in JSON, decide what to fire headless, and stay quiet when nothing is pending.
3. **Visibility into automatic work.** When automation acts unsupervised, the user needs a digestible "since last review" view, with an explicit accept that resets the window.

CR-007 and CR-008 both reference CR-009 as a hard dependency: they consume its `/status` entry point and its `since-review.yaml` review-log contract. CR-009 must land before either of them.

## 2. Goals

- A single registered skill at `skills/status/SKILL.md`, invoked as `/second-brain:status [sub-arg]`. All future user-facing dashboard concerns route through here as sub-args.
- A `scripts/status.js` that reads existing `wiki/.state/*.yaml`, runs cheap fresh comparisons (`state-sources.js diff`, `validate-wiki.js all`), and prints either a human dashboard or a stable JSON shape.
- A `scripts/review-log.js` that owns `wiki/.state/since-review.yaml` with `append` / `show` / `accept` subcommands. Append schema is intentionally loose so future CRs can invent kinds without amending CR-009.
- A documented headless contract: `claude --headless -p "/second-brain:status <sub-arg> --judge-only"` is the shape CR-007/008 will fulfill.
- One-line integration in `/second-brain:ingest`: after each successfully ingested source, append `kind: ingest` to the review log.
- Reference docs: stable JSON schema (`skills/status/references/status-json-schema.md`) and a cron example (`docs/install/headless-driving.md`).

## 3. Non-goals

- **CR-007 / CR-008 implementation.** `/status reconcile` and `/status refresh` ship in CR-009 as placeholder responses pointing at the owning CRs. The routing shape is locked here; the loop bodies land later.
- **Lint `--autofix` integration.** Lint has no autofix mode in v1; when it grows one, that change adds its own `kind: lint-autofix` append. CR-009 does not modify `skills/lint/SKILL.md`.
- **Web UI, notifications, multi-user auth, templated cron entries.** All explicitly out per CR-009.
- **Roll-up entries in the review log.** Per [[scripts-and-hooks-over-llm]] and the low-touch UX preference, trust the user to accept periodically. If real overflow happens, a follow-up CR adds soft-cap roll-ups.
- **Cached lint state.** `validate-wiki.js all` runs each dashboard invocation. Cost is O(wiki-file-count); fast enough for v1, cacheable later if it bites.
- **State-file-health footer in dashboard.** "sources.yaml: 142 entries, last scanned 5min ago" is a nice-to-have, deferred.
- **Auto-accept after N days.** Accept stays deliberate.
- **A bare `/status` slash command.** Per conventions §5 all skill invocations are namespaced; the skill is always `/second-brain:status`. The CR's `/status` shorthand is shorthand only.

## 4. Architecture

Three deliverables, plus two reference docs and one minimal skill modification:

| Deliverable | Path | Owner |
|---|---|---|
| Dashboard script | `scripts/status.js` | new |
| Review-log script | `scripts/review-log.js` | new |
| Status skill | `skills/status/SKILL.md` | new |
| JSON schema reference | `skills/status/references/status-json-schema.md` | new |
| Headless-driving doc | `docs/install/headless-driving.md` | new |
| Ingest skill update | `skills/ingest/SKILL.md` | one-line addition |

`since-review.yaml` is created lazily by the first `review-log.js append` call. `onboard` does not scaffold it.

## 5. `scripts/status.js`

### 5.1 Invocation

```
node "$CLAUDE_PLUGIN_ROOT/scripts/status.js" [--json]
```

Resolves the vault root by walking up to the nearest directory containing both `.git/` and `wiki/.state/sources.yaml`, matching `validate-wiki.js`'s convention. Outside a vault → exit 2 with `error: not in a second-brain vault (run /second-brain:onboard first)`.

### 5.2 JSON output (stable schema, all sections always present)

```json
{
  "vault":           { "root": "/path/to/vault", "name": "client-x" },
  "sources":         { "new": 5, "changed": 2, "deleted": 0 },
  "lint":            { "errors": 0, "warnings": 3 },
  "contradictions":  { "unjudged_candidates": 0, "unresolved": 0, "present": false },
  "staleness":       { "unjudged_candidates": 0, "unresolved_high": 0, "unresolved_medium": 0, "present": false },
  "since_review":    { "change_count": 0, "last_accepted_at": null }
}
```

- `vault.name` is the basename of the vault root.
- `sources.{new,changed,deleted}` come from `state-sources.js diff --json` (filesystem vs YAML, hashes-based).
- `lint.{errors,warnings}` derive from `validate-wiki.js all --json` regardless of its exit code (status.js is a reporter, not a gatekeeper).
- `contradictions` / `staleness`: counts are `0` and `present: false` until CR-007 / CR-008 land their state files. When the state file exists, status.js parses it directly (no helper script needed for read-only access). The **counting predicates** (what exactly is "unjudged" vs "unresolved", what differentiates `unresolved_high` from `unresolved_medium`) are owned by CR-007 / CR-008 specs respectively; CR-009 locks the JSON key shape and the "absent state file → zero" behaviour, not the per-entry logic.
- `unjudged_candidates` may always be `0` in CR-007 / CR-008 if those CRs choose to compute candidates on-demand rather than persist them. The key stays in the schema either way so cron consumers can rely on it.
- `since_review.change_count` is `len(changes)` from `since-review.yaml`; `last_accepted_at` is the top-level key, or `null` if file absent.

### 5.3 Human output (default)

Sections with zero counts are **omitted** to reduce noise. On a fresh vault with nothing pending, output is:

```
Second Brain — vault: client-x
─────────────────────────────────────────────
Nothing pending.
```

A populated vault:

```
Second Brain — vault: client-x
─────────────────────────────────────────────
Needs you:
  Contradictions     3 unresolved      (/second-brain:status reconcile)
  Stale pages        5 high + 2 medium (/second-brain:status refresh)

Awaiting review:
  12 changes since 2026-05-12         (/second-brain:status review)

Automation could pick up:
  Sources            5 new in raw/, 2 changed
                     hint: claude --headless -p "/second-brain:ingest"

Lint: 0 errors, 3 warnings           (/second-brain:lint)
```

The three categorisation headers (`Needs you:`, `Awaiting review:`, `Automation could pick up:`) are a rendering concern only; the JSON shape never pre-categorises so cron consumers can route on their own.

### 5.4 Exit codes

| Situation | Exit |
|---|---|
| Clean run, dashboard printed | 0 |
| Optional state file (`contradictions.yaml`, `staleness.yaml`, `since-review.yaml`) absent | 0 |
| Vault root not found | 2 |
| Any YAML file under `wiki/.state/` malformed | 2, stderr names the file |
| `state-sources.js diff` errors | 2, propagate stderr |
| `validate-wiki.js all` exits non-zero | 0 (counts still populated) |

## 6. `scripts/review-log.js`

### 6.1 Schema for `wiki/.state/since-review.yaml`

```yaml
schema_version: 1
generated_by: scripts/review-log.js
last_accepted_at: 2026-05-12T08:00:00Z   # null until first accept
changes:
  - at: 2026-05-13T03:00:00Z
    kind: ingest
    source: raw/some-article.md
    wrote: [wiki/sources/some-article.md, wiki/entities/foo.md]
  - at: 2026-05-14T03:00:00Z
    kind: contradiction-judged
    pair: [wiki/entities/foo.md, wiki/concepts/acquisitions.md]
    verdict: real-contradiction
  - at: 2026-05-15T03:00:00Z
    kind: lint-autofix
    note: "removed broken link [[old-page]] from wiki/concepts/foo.md"
```

- `kind` is a free string. CR-007 / CR-008 / future CRs own their own kinds and payload shapes.
- Per-kind payload is freeform JSON merged into the entry (everything in `--data` lives alongside `at` and `kind`). No per-kind validation in `review-log.js`.
- Top-level `schema_version: 1` and `generated_by: scripts/review-log.js` per conventions §3.
- File is committed (no `.gitignore`), travels with the vault across clones.

### 6.2 Subcommands

| Subcommand | Behavior |
|---|---|
| `append --kind=<kind> --data=<json>` | Parse `--data` as JSON. Merge with `{at: <now-iso>, kind: <kind>}`. Append to `changes[]`. Atomic write (tmpfile + rename). Creates file lazily with `last_accepted_at: null` if absent. |
| `show [--json]` | Default: print grouped-by-kind summary (count per kind, then last 20 entries per kind with `... and N more` truncation hint). `--json`: dump full file. Missing file → empty state, exit 0. |
| `accept` | Set `changes: []`, bump `last_accepted_at` to now-iso. Atomic write. Print `accepted N changes since <prev_last_accepted_at>`. Missing file → create empty with `last_accepted_at: <now-iso>`, print `accepted 0 changes`. |

### 6.3 Exit codes

| Situation | Exit |
|---|---|
| `append` / `show` / `accept` succeeds | 0 |
| `append --data` malformed JSON | 2 |
| `since-review.yaml` exists but malformed | 2, stderr names file |
| Unknown subcommand or missing required flag | 2 |

### 6.4 Concurrency

Atomic write (`fs.writeFileSync` to a tmpfile then `fs.renameSync`) is the only contention mitigation. Two crons firing in the same second could in theory race; single-machine, single-user, sub-second windows make this acceptable. Not worth a lock file in v1.

## 7. `skills/status/SKILL.md`

### 7.1 Frontmatter

```markdown
---
name: status
description: >
  Show what the second-brain vault needs — pending contradictions to resolve,
  stale pages to triage, changes awaiting review, sources ready for ingest,
  lint warnings. Use when the user says "status", "what's pending", "dashboard",
  "what changed", "review changes", or asks what they should do next in the vault.
allowed-tools: Bash Read
---
```

`Bash` for invoking scripts. `Read` only for displaying `wiki/log.md` excerpts on demand. No `Write` / `Edit` — all mutation flows through `review-log.js accept`.

### 7.2 Sections

1. **Tooling.** Pin to `scripts/status.js` and `scripts/review-log.js`. Never hand-read state YAML; always call the scripts. (Mirrors the discipline of ingest's `state-sources.js` pin.)
2. **Default invocation (`/second-brain:status`).** Run `node "$CLAUDE_PLUGIN_ROOT/scripts/status.js"`. Print stdout verbatim. Done.
3. **`/second-brain:status review`.** Run `node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" show`. After printing, read `last_accepted_at` from `--json` mode and append the hint: `For file-level diffs since last accept: git log --since=<last_accepted_at> wiki/`.
4. **`/second-brain:status accept`.** Run `node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" accept`. Silent — no confirmation prompt (user-initiated, recoverable via git, matches low-touch UX preference per [[second-brain-low-touch-ux]]).
5. **`/second-brain:status reconcile`** *(placeholder until CR-007)*. Print:
   ```
   /status reconcile is not yet available. CR-007 will implement contradiction
   detection. Until then, /second-brain:lint flags candidate contradictions
   in its report.
   ```
6. **`/second-brain:status refresh`** *(placeholder until CR-008)*. Same shape, points at CR-008.
7. **Headless mode.** A short note documenting the contract: future judge passes (`/second-brain:status reconcile --judge-only`, `/second-brain:status refresh --judge-only`) will be invokable headless via `claude --headless -p "..."`. Locked here so CR-007/008 just implement the bodies.
8. **Related skills.** `/second-brain:ingest`, `/second-brain:lint`, `/second-brain:onboard`.

### 7.3 What's deliberately not in this skill

- The candidate-detection scripts (CR-007 / CR-008 own them).
- The judge logic (CR-007 / CR-008 own it).
- The interactive resolve loops (CR-007 / CR-008 own them, slotted into sub-flow placeholders here).

## 8. Integration with `/second-brain:ingest`

One-line addition to `skills/ingest/SKILL.md`. After the existing "ingested source → write wiki pages" step, the SKILL prompt instructs:

> After each successfully ingested source, append a review-log entry:
> ```bash
> node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" append \
>   --kind=ingest \
>   --data="{\"source\":\"<source-path>\",\"wrote\":[<wiki-page-paths>]}"
> ```

Idempotent at the ingest level: ingest already skips unchanged sources per CR-002's diff, so re-running doesn't produce spurious appends. `review-log.js` itself does not dedupe — that's the caller's contract.

The "auto-skills always append" simplification (no "am I headless?" detection) is deliberate: interactive ingest also benefits from the inbox view since the user may not remember tomorrow what they ingested today, and the cost is negligible.

## 9. Reference docs

### 9.1 `skills/status/references/status-json-schema.md`

Documents the JSON shape from §5.2, field-by-field:

- Every key, its type, semantic meaning, and default when the underlying state is absent.
- The `present: false` flag for not-yet-implemented sections (`contradictions`, `staleness`).
- Stability commitment: `schema_version: 1` implied by file format; field additions require schema-version bump and a migration note in CR docs.
- Worked examples: fresh vault output, populated vault output.

### 9.2 `docs/install/headless-driving.md`

Concrete cron example matching the CR-009 sketch:

```bash
# Hourly: pick up new sources, then judge what came in.
0 * * * * cd /path/to/vault && {
  STATUS=$("$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
  NEW=$(echo "$STATUS" | jq '.sources.new + .sources.changed')
  if [ "$NEW" -gt 0 ]; then
    claude --headless -p "/second-brain:ingest" >> .claude/headless.log 2>&1
  fi
  STATUS=$("$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
  [ "$(echo "$STATUS" | jq '.contradictions.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:status reconcile --judge-only" >> .claude/headless.log 2>&1
  [ "$(echo "$STATUS" | jq '.staleness.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:status refresh --judge-only" >> .claude/headless.log 2>&1
}
```

Plus a short "recommended cadence" paragraph (hourly for ingest is plenty; judge passes daily) and the `.claude/headless.log` convention. Notes that the `reconcile` and `refresh` headless invocations are no-ops until CR-007 / CR-008 land but the cron shape can be set up now.

## 10. Tests

### 10.1 `tests/test_status.sh`

Mirrors `tests/test_state_sources.sh` (numbered cases, fixture vault under `tests/fixtures/status/<case>/`, assertions on exit code + stdout JSON shape).

1. Fresh vault (only `sources.yaml` + `frontmatter-contract.yaml`) → `--json` returns stable schema with `contradictions.present === false`, `staleness.present === false`, `since_review.last_accepted_at === null`, `change_count === 0`. Exit 0.
2. Vault with three new files in `raw/` → `sources.new === 3`, JSON unchanged shape otherwise.
3. Vault with a broken wikilink → `lint.errors >= 1`. (Lint count derived from `validate-wiki.js all --json` even when it exits non-zero.)
4. Fixture vault with a hand-written `contradictions.yaml` containing 3 `status: unresolved` entries → `contradictions.unresolved === 3`, `contradictions.present === true`. *(Tests CR-009's reader against the schema CR-007 sketches in its CR doc. If CR-007's plan refines the schema, this test's fixture and the reader update together.)*
5. Fixture vault with a hand-written `staleness.yaml` (3 `signal: high`, 2 `signal: medium`, all `status: unreviewed`) → `staleness.unresolved_high === 3`, `staleness.unresolved_medium === 2`, `present === true`. *(Same caveat as case 4 — fixture follows CR-008's sketched schema.)*
6. Vault with malformed `sources.yaml` → exit 2, stderr contains `wiki/.state/sources.yaml malformed`.
7. Vault with malformed `since-review.yaml` → exit 2, stderr contains `wiki/.state/since-review.yaml malformed`.
8. Vault with `since-review.yaml` containing 5 changes → human output includes `Awaiting review:` line with `5 changes`. JSON `since_review.change_count === 5`.
9. Human mode on fresh vault omits zero-count sections — only prints `Nothing pending.` after the header.
10. Outside any vault (run from `/tmp`) → exit 2 with `not in a second-brain vault` message.
11. JSON mode is byte-stable across runs when state hasn't changed (no timestamp jitter inside the dashboard payload beyond what state files contain).

### 10.2 `tests/test_review_log.sh`

1. `show` on missing file → empty output, exit 0.
2. `accept` on missing file → creates file with `last_accepted_at: <iso>`, `changes: []`, exit 0; stdout `accepted 0 changes since (none)`.
3. `append --kind=ingest --data='{"source":"raw/x.md","wrote":["wiki/sources/x.md"]}'` → file gains one entry with `at`, `kind: ingest`, and the payload fields merged in.
4. Two `append` calls accumulate; `show` (default) groups by kind, lists both entries; `show --json` dumps the full file.
5. `accept` after appends → `changes: []`, `last_accepted_at` updated, stdout reports cleared count.
6. `append --data` with malformed JSON (`--data='{not json'`) → exit 2, stderr names the parse error.
7. `append --kind=my-custom --data='{"foo":"bar"}'` succeeds (kind is free-string per contract); entry includes the custom field.
8. Two rapid `append` calls (simulating concurrent crons) both land in the file via atomic-rename semantics (no torn writes; ordering may vary).
9. Reading a `since-review.yaml` written by an older `schema_version` (fixture with `schema_version: 0`) → exit 2 with a clear message (forward-only; no migration in v1).

### 10.3 Manual smoke checklist

1. Fresh vault → `/second-brain:status` prints only the header + `Nothing pending.`
2. Drop two files into `raw/` → `/second-brain:status` shows `Sources 2 new`.
3. Run `/second-brain:ingest` → afterward `/second-brain:status review` shows the two ingest entries grouped under `kind: ingest`.
4. `/second-brain:status accept` → review count clears; `/second-brain:status review` shows empty.
5. `/second-brain:status reconcile` → prints the placeholder message pointing at CR-007.
6. `/second-brain:status refresh` → prints the placeholder message pointing at CR-008.
7. From a non-vault directory: `node scripts/status.js` → exit 2 with helpful error.
8. Headless invocation: `claude --headless -p "/second-brain:status"` → returns the human dashboard captured to log.

## 11. Risks and tradeoffs

- **`validate-wiki.js all` on every `/status` call.** Cost is O(wiki-file-count). Fast enough for v1; if it bites in the thousands of pages, cache in `wiki/.state/lint.yaml` with a TTL.
- **Stable JSON schema is a forward commitment.** Once cron jobs depend on `contradictions.unresolved` being a number, we can't change the shape lightly. Mitigated by `present: false` letting "section not yet implemented" be expressible without a schema break.
- **`kind: <free-string>` payloads are unstructured.** `/status review`'s human formatter must handle unknown kinds gracefully (fallback: print `kind` + JSON-dump the payload). Cost: variable formatting per kind. Benefit: CR-007 / CR-008 / future CRs don't have to amend CR-009 to invent new kinds.
- **No concurrent-write protection beyond atomic rename.** Sub-second races between two crons could in theory occur; on a single-machine single-user setup the window is tiny. No lock file in v1.
- **Routing all sub-flows through one skill keeps the registry small, but `skills/status/SKILL.md` will grow.** CR-007 and CR-008 will each add a sub-flow body here. Mitigation: keep each sub-flow self-contained as an `## N. /status <verb>` section; consider extracting to `references/` sub-files if SKILL.md exceeds ~400 lines.
- **`since-review.yaml` is never garbage-collected.** A user who never accepts accumulates entries indefinitely. Per the resolved overflow question, trust the user; if needed, follow-up CR adds roll-up.
- **Lint integration deferred.** Until lint grows `--autofix`, autofixes can't reach the review log. Acceptable — there are no autofixes today.

## 12. Open questions deferred

- **State-file health footer in dashboard.** `sources.yaml: 142 entries, last scanned 5min ago` would let the user catch silent breakage. Low priority; defer.
- **Auto-accept after N days?** Probably not — accept should stay deliberate.
- **Unified "log this event" contract** writing to both `wiki/log.md` (permanent narrative) and `since-review.yaml` (ephemeral inbox). Defer until at least one more producer (CR-007 or CR-008) is in flight and the boilerplate is visible.
- **Cached lint state** if `validate-wiki.js all` becomes a bottleneck on large vaults.
- **`since-review.yaml` schema migration story** when `schema_version` bumps. v1 fails fast on unknown versions; long-term may want a forward-migration helper, but premature to design now.

## 13. Out of scope (carried from CR-009)

- CR-007 / CR-008 implementation (placeholder responses only in CR-009).
- Lint `--autofix` mode and its review-log integration.
- Web UI; push / email / Slack notifications when work is pending.
- Auth, multi-user, multi-machine cron coordination.
- Templated cron entries per vault (one example doc is enough; the user wires their own).
- Rollback for auto-changes (git is the rollback).
- Roll-up entries in the review log.
- Cross-vault status (vaults are isolated by design per [[second-brain-primary-consumer]]).
