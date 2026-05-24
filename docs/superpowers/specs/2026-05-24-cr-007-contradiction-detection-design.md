# CR-007 Design — Contradiction detection across wiki pages

**Status:** Draft, pending user review
**Date:** 2026-05-24
**CR:** [CR-007](../../cr/CR-007-contradiction-detection.md)
**Conventions:** [docs/cr/conventions.md](../../cr/conventions.md)
**Depends on:** CR-002 (landed; `wiki/.state/sources.yaml` family), CR-004 (landed; `validate-wiki.js`), CR-005 (landed; `relations:` frontmatter mechanism + `validate-wiki.js` relations rule), CR-009 (landed; `/second-brain:status` entry point, `since-review.yaml` review-log contract, JSON keys for `contradictions.*`)

## 1. Problem

The wiki is the consolidated, agent-facing memory layer. When two pages disagree about the same fact — or when a new ingest writes claims that contradict existing pages — nothing flags it. An agent reading the vault has no way to tell which assertion to trust, and silently picks one. CR-007 introduces deterministic candidate detection, an LLM-driven judging pass, and an interactive user-resolution loop, all surfaced through `/second-brain:status`.

CR-009 already locked the user-facing contract: `/second-brain:status reconcile` (interactive) and `/second-brain:status reconcile --judge-only` (headless) are the entry points, and the JSON dashboard reports `contradictions.{unjudged_candidates,unresolved,present}`. CR-007 implements the bodies behind those routes.

## 2. Goals

- A single state-owning script `scripts/contradictions.js` that maintains `wiki/.state/contradictions.yaml` through the entry lifecycle (candidate → judged → resolved).
- Two deterministic candidate signals, both cheap, no LLM calls: `conflicting-relations` and `shared-entity-prose`.
- LLM-driven judge pass behind `/second-brain:status reconcile --judge-only`, cron-safe, appending one `kind: contradiction-judged` entry per pair to `since-review.yaml`.
- Interactive resolution loop behind `/second-brain:status reconcile`, with four user options (Pick A / Pick B / Accept disagreement / Defer) and a per-resolution git commit.
- Scoped paragraph rewrite for Pick A/B via a tmpfile, applied through the script, validated via `validate-wiki.js`, auto-reverted on structural failure.
- Accepted disagreements annotated on both pages via CR-005's `relations: { contradicts: [...] }` mechanism — no new top-level frontmatter key.
- Ingest integration: after writing wiki pages, scan just-touched pages plus one-hop wikilink neighbours for new candidates. Ingest does not block on judging.
- Lint integration: full-vault candidate scan; reports counts; subsumes the prose-only "contradictions" step lint currently has.
- Tests under `tests/test_contradictions.sh` mirroring the existing fixture-based pattern.

## 3. Non-goals

- **Automatic resolution.** Pick A/B and Accept-disagreement are user-initiated, always. The LLM judge produces a verdict, not a resolution.
- **Source-preference learning.** Out of scope per CR-007 open question — defer to a follow-up CR once there is real resolution data to fit weights against.
- **Structured `claim` schema.** Freeform text per CR-007 open question — keeps the judge prompt simple; structured filtering can be a future RAG concern.
- **Cross-vault contradictions.** Vaults are isolated by design per [[second-brain-primary-consumer]].
- **Embeddings / RAG.** CR-007 is a hard dependency for any future embeddings CR, not the other way around.
- **`superseded-by:` frontmatter.** That concept belongs to CR-008 (archive flow). CR-007 only needs `relations: { contradicts: [...] }`.
- **Touching `raw/` or `src/`.** Read-only. Contradictions live in the wiki layer.
- **Re-judging known pairs.** Once judged (real or not), an entry is terminal until it changes state. The candidate scan dedupes against any existing entry, regardless of status.
- **Compaction of `contradictions.yaml`.** Trust the user to accept the growth; if real overflow happens, follow-up CR adds a pruning step. Same stance as CR-009 took on `since-review.yaml`.
- **Continuous full-vault scans on every ingest.** Ingest scopes to just-touched pages plus one-hop neighbours. Full-vault is the lint pass.

## 4. Architecture

Three deliverables plus two skill touches. All consumers call one script.

| Deliverable | Path | Owner |
|---|---|---|
| Contradictions script | `scripts/contradictions.js` | new |
| Status skill sub-flow bodies | `skills/status/SKILL.md` (modify) | edit — replace CR-009 placeholders for `reconcile` |
| Ingest scan call | `skills/ingest/SKILL.md` (modify) | edit — one new step |
| Lint integration | `skills/lint/SKILL.md` (modify) | edit — replace prose §2 |

`contradictions.yaml` is created lazily by the first `candidates` enqueue call. `onboard` does not scaffold it.

Three consumers, one script: ingest (`candidates --scope=<touched-pages>`), lint (`candidates --scope=wiki/` + `list --json`), status reconcile flows (`list`, `judge`, `apply-pick`, `apply-accept`, `resolve`). Top-level `scripts/` location per conventions §7 — single-file shape with subcommands.

## 5. `wiki/.state/contradictions.yaml`

### 5.1 Schema

```yaml
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  # 1) Pre-judge: candidate detected by the script, not yet seen by LLM.
  - id: 2026-05-19-001
    detected_at: 2026-05-19T10:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]   # lexically sorted
    signal: conflicting-relations
    signal_data:
      relation: acquired-by
      entity: wiki/entities/foo.md
      values: [wiki/entities/bar.md, wiki/entities/baz.md]
    status: unjudged

  # 2) Post-judge, real contradiction. Awaits user.
  - id: 2026-05-18-007
    detected_at: 2026-05-18T03:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: acquired-by, entity: wiki/entities/foo.md, values: [wiki/entities/bar.md, wiki/entities/baz.md] }
    status: unresolved
    judgment:
      verdict: real-contradiction
      at: 2026-05-18T04:00:00Z
      claim: "Acquirer of Foo"
      assertions:
        - page: wiki/entities/foo.md
          text: "Foo was acquired by Bar in 2023"
          source: src/documentation/news/article-a.md
        - page: wiki/concepts/acquisitions.md
          text: "Foo was acquired by Baz in 2024"
          source: raw/article-b.md
      rationale: "Both pages assert different acquirers for Foo on different dates from independent sources."

  # 3) Post-judge, false positive. Kept so re-scan doesn't re-enqueue.
  - id: 2026-05-17-002
    status: not-a-contradiction
    judgment:
      verdict: not-a-contradiction
      at: 2026-05-17T03:00:00Z
      rationale: "Pages discuss different physical phenomena; the shared cosmology link is incidental."
    # detected_at, pages, signal, signal_data also persist; abbreviated here.

  # 4) User-resolved: picked side A; scoped rewrite applied to B.
  - id: 2026-05-15-003
    status: resolved-pick-a
    judgment: { ... }
    resolution:
      at: 2026-05-15T11:00:00Z
      picked_page: wiki/entities/foo.md
      edited_page: wiki/concepts/acquisitions.md
      commit: 7a3b1c9
      sources_appended_to_edited: [src/documentation/news/article-a.md]

  # 5) Accepted disagreement: both pages get `relations: { contradicts: [other] }`.
  - id: 2026-05-14-004
    status: accepted-disagreement
    judgment: { ... }
    resolution: { at: 2026-05-14T..., commit: <sha> }

  # 6) Deferred: re-enters next interactive walk.
  - id: 2026-05-13-005
    status: deferred
    judgment: { ... }
    deferred_at: 2026-05-13T08:00:00Z
```

### 5.2 Field rules

- `id` format: `YYYY-MM-DD-NNN`. `NNN` is a 3-digit counter per day, starting at `001`. Allocated by `candidates` at enqueue time; stable across the entry's lifetime.
- `pages` is always **lexically sorted** so the same pair produces the same dedupe key regardless of which page the scan visited first. Two pages exactly; not a triple.
- `signal` is one of `conflicting-relations` | `shared-entity-prose`. Open to extension; existing values must remain stable.
- `signal_data` shape varies by signal; `conflicting-relations` carries `{relation, entity, values[]}`, `shared-entity-prose` carries `{entity, shared_links}`. The candidate scan and the judge prompt both read it.
- `status` is one of: `unjudged`, `not-a-contradiction`, `unresolved`, `resolved-pick-a`, `resolved-pick-b`, `accepted-disagreement`, `deferred`. Lifecycle transitions are enforced by the script (§6.3).
- `judgment` is added when `status` becomes `not-a-contradiction` or `unresolved`. Once written, never rewritten — re-judging is not supported in v1.
- `resolution` is added when `status` becomes a `resolved-*` or `accepted-disagreement`. Once written, never rewritten.
- `deferred_at` is added on defer; cleared (set null) on re-judgment is not supported — defer is terminal-with-re-entry, not a re-judge.
- Top-level `schema_version: 1` and `generated_by: scripts/contradictions.js` per conventions §3.
- File is committed (no `.gitignore`), travels with the vault.

### 5.3 Lifecycle transitions

```
unjudged ──(judge real-contradiction)──> unresolved
unjudged ──(judge not-a-contradiction)─> not-a-contradiction   [terminal]

unresolved ──(apply-pick A)─> resolved-pick-a                  [terminal]
unresolved ──(apply-pick B)─> resolved-pick-b                  [terminal]
unresolved ──(apply-accept)─> accepted-disagreement            [terminal]
unresolved ──(defer)──────> deferred                           [re-enterable]

deferred   ──(apply-pick A)─> resolved-pick-a                  [terminal]
deferred   ──(apply-pick B)─> resolved-pick-b                  [terminal]
deferred   ──(apply-accept)─> accepted-disagreement            [terminal]
deferred   ──(defer)──────> deferred                           [no-op state, updates deferred_at]
```

Any other transition (e.g. `judge` on an entry already in a terminal state) is a script invariant violation — exit code 3, no mutation.

### 5.4 JSON counting predicates (locked from CR-009 §5.2)

- `contradictions.unjudged_candidates` = count of entries with `status: unjudged`.
- `contradictions.unresolved` = count of entries with `status: unresolved` OR `status: deferred` (both surface in the interactive walk).
- `contradictions.present` = `true` if the file exists, `false` otherwise.

Both `not-a-contradiction` and `resolved-*` / `accepted-disagreement` count toward neither — they are not actionable.

## 6. `scripts/contradictions.js`

### 6.1 Invocation

```
node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" <subcommand> [args]
```

Vault detection: walks up for `.git/` + `wiki/.state/sources.yaml`, matching `validate-wiki.js`, `status.js`, `review-log.js`. Outside a vault → exit 2 with `error: not in a second-brain vault`.

### 6.2 Subcommands

| Subcommand | Args | Behaviour |
|---|---|---|
| `candidates` | `--scope <wiki/-relative-path or comma-list>` (default `wiki/`); `--json` |  Without `--json`: scan in scope (plus one-hop wikilink neighbours when scope is a page list, not a directory), dedupe against existing entries (any status), atomic-append new entries with `status: unjudged`. Prints `enqueued N new, skipped M already-known`. With `--json`: emit candidate set without mutation, used by lint's report-only path. |
| `judge` | `--id <id>` (required); `--verdict <real-contradiction\|not-a-contradiction>`; `--data <json>` |  `--data` for `real-contradiction` is `{claim, assertions, rationale}`; for `not-a-contradiction` is `{rationale}`. Transitions `unjudged → unresolved` or `unjudged → not-a-contradiction`. Writes `judgment` block. Exit 3 if entry not `unjudged`. |
| `apply-pick` | `--id <id>`; `--winning-page <vault-path>` (one of the entry's `pages`); `--rewrite <tmpfile>` |  Verify entry is `unresolved` or `deferred`. The `--losing-page` is the other page in `pages`. Read tmpfile; locate the assertion paragraph in the losing page by substring-matching `judgment.assertions[<losing-page>].text` against page body. **Match must be unique**: zero matches or multiple matches → exit 3 with `error: assertion substring matched <N> paragraphs in <losing-page>`, no mutation. Swap the matched paragraph; deduped-append the winning page's `sources:` entries onto the losing page's `sources:`; bump losing page's `updated:`; one git commit (`reconcile: pick <winning> over <losing> on <claim>`); run `validate-wiki.js all` — on exit 2, auto-revert the commit, leave the yaml entry unchanged, and exit 2 (entry stays `unresolved`/`deferred`). **On success**: update the entry to `status: resolved-pick-a` or `resolved-pick-b` (whichever page was picked), write the `resolution` block (with `at`, `picked_page`, `edited_page`, `commit`, `sources_appended_to_edited`), atomic file rename. Print the commit sha to stdout. |
| `apply-accept` | `--id <id>` |  Verify entry is `unresolved` or `deferred`. Add `relations: { contradicts: [other-page] }` to both `pages`, deduped if the relation key already exists. Bump `updated:` on both. One git commit (`reconcile: accept-disagreement on <claim>`). Run `validate-wiki.js all` — on exit 2, auto-revert, leave the yaml entry unchanged, exit 2. **On success**: update the entry to `status: accepted-disagreement`, write the `resolution` block (with `at`, `commit`), atomic file rename. Print the commit sha to stdout. |
| `resolve` | `--id <id>`; `--kind defer` |  v1's only `resolve` kind is `defer`. Sets `status: deferred`, populates `deferred_at`. No commit, no edits. Exit 3 if the entry's current `status` isn't `unresolved` or `deferred`. (Picks and accepts flow through `apply-pick` / `apply-accept`, which own the full transaction.) |
| `list` | `[--status <comma-list>]`; `[--json]` |  Filter by `status` (default: all). `--json` dumps matching entries; default prints a grouped-by-status summary suitable for the SKILL prompt. |

The state-file mutation in `judge`, `apply-pick`, `apply-accept`, `resolve` is atomic (tmpfile + rename, same as `review-log.js`); it is not atomic with the git commit step in `apply-pick` / `apply-accept`. If a process crashes between the git commit and the yaml update, the commit lands but the entry stays `unresolved`. The user re-runs the interactive flow; the LLM will rewrite the same paragraph, but `apply-pick` will find zero substring matches (the rewrite already replaced the original assertion) and exit 3. Recovery is manual in v1: the user inspects `git log`, identifies the commit, and calls `resolve --kind=defer` (or hand-edits the yaml). This is an accepted limitation — the crash window is sub-second on single-machine use; revisit if it bites.

### 6.3 Exit codes

| Code | Meaning |
|---|---|
| 0 | clean |
| 2 | vault not found, malformed YAML, missing required arg, malformed `--data`, `validate-wiki.js all` failure after auto-revert |
| 3 | invariant refusal — invalid transition for current status, candidate scan attempted outside `wiki/`, etc. No mutation occurred. |

### 6.4 Signal implementations

Both signals are pure file-scanning passes — no LLM calls — and run in deterministic time on the in-scope set.

#### Signal 1: `conflicting-relations`

For each page in scope:
1. Read frontmatter (already cached by `validate-wiki.js`-style reader; if reused, factor that helper).
2. For each key in `relations:`, for each target in the value list, emit `(relation-name, target) → (page, target)`.

After scanning, group by `(relation-name, entity)` where any frontmatter `relations` entry has another page asserting the same `(relation-name, entity)` with a different value — that's the candidate. The signal applies when:
- two or more in-scope pages set `relations.<R>` for the same entity to disjoint targets, OR
- one in-scope page and one out-of-scope page do the same (incremental scope still surfaces cross-vault overlap).

`signal_data` captures `{relation, entity, values[]}`. Cheap; the only cost is frontmatter parsing.

#### Signal 2: `shared-entity-prose`

For each pair of pages in scope:
1. Parse body prose, extract `[[wikilink]]` tokens.
2. Compute the set intersection of their entity-style wikilinks (anything that resolves under the three-rule resolver to a page in `wiki/entities/`).
3. If at least one shared entity exists AND the total shared wikilink count (entities + concepts + sources) is ≥ `N` (start with `N = 5`; tunable in plan), emit one candidate per shared entity.

`signal_data` captures `{entity, shared_links}` — the entity that anchors the suspected disagreement and the total shared-link count.

Quadratic-pair scan worst case, but the entity-shared filter prunes aggressively. For the incremental ingest scope (changed pages + one-hop neighbours), the pair set is small. For lint full-scope, the worst case is `O(wiki_pages^2)` — acceptable in the thousand-page range; cacheable later if it bites.

### 6.5 Candidate dedupe rule

Before enqueueing a new candidate, the script reads `contradictions.yaml` and checks whether any existing entry has the same `(pages, signal, signal_data)` triple. Match → skip. Pair-canonicalisation (lexical sort) handles direction-order; signal_data canonicalisation (sort `values` lists) handles internal field order.

Two different signals on the same page pair produce two different entries — they capture different aspects of the disagreement.

### 6.6 Atomic write

`fs.writeFileSync` to a tmpfile sibling, then `fs.renameSync` into place. Same shape as `review-log.js`. Single-machine, single-user, sub-second concurrent-write window is acceptable per CR-009 §6.4.

## 7. `skills/status/SKILL.md` modifications

CR-009 left two placeholders. CR-007 fills `## /second-brain:status reconcile` and adds a sibling section for `--judge-only`.

### 7.1 `/second-brain:status reconcile --judge-only` (headless)

Cron-safe. No prompts. Walks `status: unjudged`.

1. `node scripts/contradictions.js list --status=unjudged --json`. If empty → print `no unjudged candidates` and exit 0.
2. For each entry, the LLM reads both pages (using `Read`), reasons, and emits a verdict via `judge`:
   - real-contradiction → `--data='{"claim":"...","assertions":[{"page":"...","text":"...","source":"..."},{...}],"rationale":"..."}'`
   - not-a-contradiction → `--data='{"rationale":"..."}'`
3. After each successful `judge`, append a review-log entry:
   ```bash
   node scripts/review-log.js append --kind=contradiction-judged \
     --data='{"id":"<id>","pages":[...],"verdict":"<verdict>"}'
   ```
4. Print a one-line summary per judgment as it lands; do not batch (cron logs stay readable).
5. On any `judge` exit 3 (concurrent run already advanced the entry), log + continue, do not abort the pass.

The SKILL prompt instructs the LLM to identify the conflicting assertion in each page by **quoting the relevant text** (not by paragraph index) so the resolution step can locate it later via substring match.

### 7.2 `/second-brain:status reconcile` (interactive)

User-driven. Walks `status: unresolved` and `status: deferred`.

1. `node scripts/contradictions.js list --status=unresolved,deferred`. If empty → print `nothing to reconcile` and stop.
2. For each entry, print:
   - `claim` line
   - Both `assertions` side-by-side: page path, quoted text, backing source
   - One-line LLM rationale
3. Ask the user: `(a) Pick A`  ·  `(b) Pick B`  ·  `(c) Accept disagreement`  ·  `(d) Defer`  ·  `(s) Stop walking`. Free text `skip` is treated as defer.
4. **On Pick A or Pick B:**
   - LLM rewrites the affected paragraph(s) of the losing page to a tmpfile at `/tmp/reconcile-<id>.md`. The scope is the paragraph(s) containing the assertion text in `judgment.assertions[losing-page].text` — found by substring match — *not* the entire page.
   - `node scripts/contradictions.js apply-pick --id=<id> --winning-page=<path> --rewrite=<tmpfile>`. The script does the file edit, the commit, the post-check, and (on success) writes the resolution block to `contradictions.yaml`. Prints commit sha to stdout.
   - On script exit 3 (substring not found / matched multiple paragraphs): print the script's stderr to the user, ask whether to defer the entry or re-attempt with a tighter LLM rewrite. Default: defer via `resolve --id=<id> --kind=defer` and continue.
   - On script exit 2 (auto-revert): print the failure reason, defer via `resolve --id=<id> --kind=defer`, continue with the next entry. Entry stays in the queue; user can retry later.
5. **On Accept disagreement:**
   - `node scripts/contradictions.js apply-accept --id=<id>`. Script edits both pages, commits, post-checks, writes the resolution block. Print sha.
   - On script exit 2 (auto-revert): defer via `resolve --id=<id> --kind=defer`, continue.
6. **On Defer:** `node scripts/contradictions.js resolve --id=<id> --kind=defer`. No edits, no commit.
7. **On Stop:** break the walk. Any entries already resolved in this pass keep their `resolved-*` status.
8. After the walk, append one line to `wiki/log.md`:
   ```
   ## [YYYY-MM-DD] reconcile | N resolved (A pick-a, B pick-b), C accepted-disagreement, D deferred
   ```

### 7.3 `allowed-tools` change

`skills/status/SKILL.md` frontmatter currently is `allowed-tools: Bash Read`. The interactive `reconcile` flow needs the LLM to write tmpfiles for the rewrite — so the frontmatter expands to `allowed-tools: Bash Read Write` (Write is for the tmpfile, not for wiki pages — wiki pages flow through `apply-pick` exclusively).

`Edit` stays out. The SKILL never edits wiki pages directly. This keeps the discipline matching CR-005's reorganize.

## 8. `skills/ingest/SKILL.md` modification

One new step after the existing "write wiki pages → append review-log" block:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" candidates \
  --scope=<comma-separated list of just-written page paths>
```

The script handles one-hop wikilink neighbour expansion internally. The SKILL just passes the touched pages.

**Cap on neighbour expansion**: the script caps total scope after expansion at `K = 50` pages. If a touched page is a hub with > K outbound links, expansion truncates; the script prints a warning to stderr but exits 0. Hub overflow is a lint concern, not an ingest concern.

Ingest does not block on judging — candidates land as `unjudged`; cron picks them up on the next `--judge-only` pass. Per CR-009's contract, ingest's existing `kind: ingest` review-log entry is unchanged; CR-007 adds no review-log entry from the candidate scan (deterministic side-effect, not a review-able event).

## 9. `skills/lint/SKILL.md` modification

Lint's existing §2 ("Contradictions") is prose-only — LLM scans pages for disagreement. Replace with deterministic script calls:

```bash
# Full-vault candidate scan: enqueues any newly-detected candidates.
node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" candidates --scope=wiki/

# Report counts across the lifecycle.
node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" list \
  --status=unjudged,unresolved,deferred --json
```

The first call mutates `contradictions.yaml` (enqueues new pairs). The second call is read-only — feeds the lint report.

Lint's report format adds one line under the existing structure:

```
Contradictions: N unjudged, M unresolved, K deferred.
Run /second-brain:status reconcile (interactive) or schedule --judge-only via cron.
```

The narrative "look for opposing claims" lint instruction is removed. The script + judge pipeline subsumes it.

## 10. Reference doc updates

### 10.1 `skills/status/references/status-json-schema.md`

Update the `contradictions` section: replace the `present: false` example with the populated shape and the locked counting predicates from §5.4. Note that `unresolved` includes `deferred` entries.

### 10.2 `docs/install/headless-driving.md`

Already sketches the `--judge-only` invocation in the CR-009 example. CR-007 doesn't need a new doc — the existing cron snippet just works once the body lands. Verify the line and update the trailing comment from "no-op until CR-007 lands" to "judges new contradiction candidates."

## 11. Tests

### 11.1 `tests/test_contradictions.sh`

Numbered cases, fixture vault under `tests/fixtures/contradictions/<case>/`, assertions on file state + exit code + git history.

1. **Empty vault** → `candidates --scope=wiki/` enqueues 0; exit 0. `list --json` returns `{contradictions: []}`.
2. **Signal 1: conflicting-relations** → fixture: `wiki/entities/foo.md` and `wiki/concepts/acquisitions.md` both set `relations.acquired-by` for `[[foo]]` to different targets → `candidates` enqueues exactly one entry with `signal: conflicting-relations`, correct `signal_data`, `status: unjudged`.
3. **Signal 2: shared-entity-prose** → fixture: two pages share an entity wikilink in body + ≥5 other wikilinks → enqueues exactly one entry with `signal: shared-entity-prose`, correct `signal_data`.
4. **Pair canonicalisation** → fixture pages `b.md` and `a.md`; `pages` field always lexically sorted to `[a.md, b.md]` regardless of scan order.
5. **Dedupe on re-scan** → re-run `candidates` after entries exist → no duplicate ids; printed summary reports `skipped M`.
6. **`judge --verdict=real-contradiction`** → transitions `unjudged → unresolved`; `judgment` block populated with claim, assertions, rationale.
7. **`judge --verdict=not-a-contradiction`** → transitions `unjudged → not-a-contradiction`; entry remains in file.
8. **`judge` on already-judged entry** → exit 3, no mutation.
9. **`apply-pick` success** → fixture two-page vault; tmpfile body swap on losing page; one git commit (`reconcile: pick ... over ... on ...`); `sources:` deduped append; `updated:` bumped on losing page only; entry transitions to `status: resolved-pick-a` (or `-b`) with a populated `resolution` block; commit sha printed to stdout.
10. **`apply-pick` post-check revert** → tmpfile breaks a wikilink → `validate-wiki.js all` exits 2 → script auto-reverts the commit; script exits 2; entry stays `unresolved`; yaml entry unchanged.
10a. **`apply-pick` substring not found** → tmpfile is fine but the assertion text in the judgment block doesn't appear in the losing page → exit 3, no commit, no yaml mutation, stderr names the page.
10b. **`apply-pick` substring matches multiple paragraphs** → assertion text appears twice in the losing page → exit 3 with a clear `matched N paragraphs` message, no commit, no yaml mutation.
11. **`apply-accept` success** → both pages gain `relations: { contradicts: [other] }` (deduped if the relation key already exists), `updated:` bumped on both, one commit, entry transitions to `status: accepted-disagreement` with a populated `resolution` block, sha printed.
12. **`apply-accept` post-check revert** → if frontmatter edit breaks the wikilinks rule (e.g. malformed relations target) → revert + exit 2, yaml entry unchanged.
13. **`resolve --kind=defer`** from `unresolved` → `status` transitions to `deferred`, `deferred_at` populated. `unresolved` count in `list --json` includes the entry (per §5.4 predicate).
13a. **`resolve --kind=defer`** from `deferred` → idempotent re-defer, `deferred_at` updates to now, no other state changes.
14. **`resolve` invalid transition** → calling `resolve --kind=defer` on a `status: unjudged` or terminal-resolved entry → exit 3, no mutation.
14a. **`resolve` unsupported kind** → calling `resolve --kind=pick-a` → exit 2 with `unsupported kind` (v1 only supports `--kind=defer`; picks flow through `apply-pick`).
15. **`list --status` filter** → filtering by multiple statuses returns the union; default returns everything.
16. **JSON predicates via `status.js`** → fixture with 2 `unjudged`, 1 `unresolved`, 1 `deferred`, 1 `not-a-contradiction`, 1 `resolved-pick-a` → `status.js --json` shows `contradictions.unjudged_candidates === 2`, `contradictions.unresolved === 2` (unresolved + deferred), `contradictions.present === true`.
17. **Lint integration** → fixture vault with one in-scope candidate → lint's report includes the count line.
18. **One-hop neighbour expansion** → `candidates --scope=<one-page>` expands to include pages that share wikilinks with the scoped page, surfacing candidates that span the scope boundary.
19. **Neighbour expansion cap** → fixture page with 100 outbound links → expansion truncates at K=50, stderr warning, exit 0.
20. **Schema version mismatch** → fixture `contradictions.yaml` with `schema_version: 0` → exit 2, stderr names the file and the expected version.

### 11.2 Manual smoke

1. Drop two `raw/` articles into a fresh vault that mention the same entity differently → `/second-brain:ingest` → `/second-brain:status` shows `Contradictions: N unjudged_candidates` under "Automation could pick up."
2. `claude --headless -p "/second-brain:status reconcile --judge-only"` → judgments land; `/status review` shows `kind: contradiction-judged` entries.
3. `/second-brain:status reconcile` (interactive) → walk one entry, Pick A → assert losing page rewritten in the scoped paragraph, single commit, `sources:` deduped, `wiki/log.md` got the reconcile line.
4. Force a break in the rewrite (manually include a `[[broken-link]]` in the tmpfile via instruction) → `apply-pick` reverts; entry stays `unresolved`; user can retry.
5. Accept-disagreement path: both pages gain `relations: { contradicts: [other] }`, one commit, lifecycle entry shows `accepted-disagreement`.
6. `/second-brain:status reconcile` on a vault with no `unresolved` or `deferred` → exits cleanly with "nothing to reconcile."
7. Defer + re-enter: defer entry → next `reconcile` invocation shows it again.

## 12. Risks and tradeoffs

- **`shared-entity-prose` false-positive rate.** Signal 2 will surface unrelated overlapping pages until the LLM filters them out. Mitigation: `not-a-contradiction` entries persist, so the same pair never gets re-judged. If volume floods the judge pass, threshold the shared-link count upward in a follow-up (parameter is centralised in the script).
- **Scoped rewrite quality.** The LLM rewrites prose paragraph-by-paragraph. The judgment block captures the assertion as text, so the script locates it by substring match — robust to whitespace and line-number drift, fragile to the LLM choosing an imprecise quote. Risk: ambiguous substring match locates the wrong paragraph. Mitigation: `apply-pick` exits 3 if the substring matches zero or multiple times — no commit, no mutation; the interactive SKILL surfaces the error and defaults to deferring the entry, so the user can retry later (often after the LLM picks a more precise quote).
- **Crash recovery between commit and yaml.** `apply-pick` / `apply-accept` perform the commit before writing the yaml update. A crash in that sub-second window leaves a successful commit and an entry still in `unresolved` status. On retry, the next interactive walk reaches the entry, the LLM rewrites, and the script will find zero substring matches (the original assertion is no longer in the file). The SKILL surfaces the exit-3 error and defaults to defer; recovery is manual (inspect `git log` for the existing `reconcile:` commit, then either hand-edit the yaml or accept the deferred state). Accepted for v1; revisit if the window matters in practice.
- **`contradictions.yaml` grows unbounded.** Per-pair entries (including false positives) persist forever. On a thousand-page wiki with dense linking this could grow to thousands of entries over years. Acceptable for v1; if it bites, follow-up CR adds a periodic compaction step. Same stance as CR-009 took on `since-review.yaml`.
- **`apply-pick`'s paragraph scope can miss the conflict.** If the LLM's judgment block quotes a sentence that spans paragraph boundaries, "the paragraph containing the substring" may include unrelated prose. Mitigation: the rewrite captures everything the substring touches; LLM is instructed to include surrounding context in its rewrite if needed.
- **Two consumers writing to `contradictions.yaml` concurrently.** Atomic rename handles single-write contention; if `ingest` and `lint` both fire `candidates` at the same second, one read may not see the other's append. Acceptable — both would converge on the next scan via dedupe. No lock file in v1.
- **Lint becomes a mutator.** Lint was read-only; CR-007 makes its full-vault `candidates` call append to `contradictions.yaml`. The mutation is queue-like (only adds candidates); the alternative of a separate full-scope invocation path adds a third entry point users would have to remember. The "low-touch UX" preference [[second-brain-low-touch-ux]] argues for fold-into-lint.
- **Crash between git commit and state-file update.** §6.2 covers this: the commit is the user-visible mutation; the YAML lags. User re-runs `reconcile`, picks again; git produces no-op commit; YAML converges. Acceptable.
- **CR-007's accept-disagreement frontmatter uses `relations: { contradicts: [...] }`.** This relies on CR-005's `relations:` mechanism being landed (confirmed: `validate-wiki.js` recognises `relations:`, `frontmatter-contract.yaml` allows unknown keys). If CR-005 ever bumps the schema in a way that breaks the relation-name vocabulary, CR-007's `contradicts` value goes with it. Mitigation: CR-005 lists `contradicts` in its starter vocabulary — coordinated.
- **One-hop neighbour expansion cost.** For ingest's incremental scope, expansion can balloon if a touched page is a hub. K=50 cap is a heuristic. If hub-touching becomes common (e.g. ingesting things that mention `wiki/index.md`), the cap will be felt; raise it or surface the warning in `/status`. v1 accepts the cap.

## 13. Open questions deferred

- **Source-preference learning.** Per CR-007 open question — defer to a follow-up CR once there is real resolution data to fit.
- **Structured `claim` field.** Freeform in v1; could become structured if a future RAG layer needs claim-level filtering.
- **Compaction of `contradictions.yaml`.** TTL or scheduled prune for `not-a-contradiction` entries. Defer until file size is a real problem.
- **Re-judging when a page changes substantially after an entry was filed.** Currently, judged entries are terminal. If a page is rewritten so the contradicting prose disappears, the entry doesn't auto-update — user manually defers/resolves. Could grow a "page changed since judgment" signal in a follow-up.
- **Multi-page contradictions** (three or more pages disagreeing). v1 only models pairs. Multi-way disagreements would be modelled as multiple pair entries with a shared `claim`. Possibly worth a `cluster_id` field in a follow-up.

## 14. Out of scope (carried from CR-007)

- Embeddings / RAG — CR-007 is a hard precursor.
- Auto-resolution — judgment proposes, user picks.
- Touching `raw/` or `src/` — read-only.
- Staleness / decay metrics — CR-008.
- Inter-source disagreement reports — only post-consolidation contradictions matter.
