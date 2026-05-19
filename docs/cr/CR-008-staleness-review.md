# CR-008 — Staleness review across wiki pages

**Depends on:** CR-002 (state YAML), CR-004 (hooks + scripts), CR-005 (reorganize — shares conventions for frontmatter + log entries), [CR-009](./CR-009-status-dashboard.md) (status dashboard + review-log contract — owns the user-facing surface).

## Problem

Wiki pages rot. A page written from a 2024 source isn't *wrong* yet, but if a dozen newer sources have since been ingested touching the same topic — and the original page has never been re-linked, re-edited, or referenced — it's likely drifted out of current frame. Today nothing flags it.

Agents reading the vault treat every page with equal authority. There is no signal saying "this page is fresh and reinforced by recent ingests" vs. "this page is a 2-year-old snapshot nothing has touched since."

Distinct from existing concerns:

- **Lint** = correctness (broken links, index drift). A stale page can be perfectly correct.
- **Reorganize** (CR-005) = structural debt (too-fine pages, missing sub-typing). A stale page can be structurally fine.
- **Reconcile** (CR-007) = factual disagreement between current pages. A stale page may have no contradiction — it's just *old* and unreinforced.

So: a fourth orthogonal concern, fit for the same candidate / judge / resolve pattern as CR-007.

## Motivation

- **Agents consume the vault as authoritative memory.** Without a freshness signal, they can't down-weight stale claims or warn the reader.
- **Manual rot-checking doesn't scale** past a few dozen pages. The script can do the boring narrowing; the LLM filters noise; the user makes the call.
- **Staleness is the closest honest translation of abmind's "fading memory"** into a deliberate, file-based wiki: not background decay, but periodic triage triggered by deterministic signals.

## Proposed approach

Same three-stage role split as CR-007 ([conventions.md §4](./conventions.md)):

| Stage | Owner | What |
|---|---|---|
| Candidate | Script: `scripts/staleness-candidates.sh` | Compute deterministic staleness signals per page. Flag pages above thresholds. |
| Judge | LLM (skill) | Read flagged page + a few neighbors. Decide: `stale` / `drifting` / `fresh-but-isolated` / `false-positive`. |
| Resolve | **User** | For each judged-stale page: refresh / archive / mark historical / defer. |

### Candidate signals (deterministic, cheap)

`scripts/staleness-candidates.sh` computes per page:

- **Age:** `mtime` vs. wiki-wide median mtime.
- **Inbound reinforcement gap:** count of inbound wikilinks where the *source* page has an mtime newer than this page's. High count = "neighbors keep talking about this, but this page itself hasn't been updated."
- **Topic-overlap freshness:** count of `sources.yaml` entries (CR-002) ingested after this page's last edit, whose ingested wiki pages share ≥N entity wikilinks with this page. High count = "newer sources touched the same topic, this page didn't get refreshed."
- **Isolation flag:** zero inbound + zero outbound wikilink updates in the last K months — possibly orphaned content.

Each page gets a composite `signal: low|medium|high` and the contributing factors. These are **filters**, not judgments.

### State file

New `wiki/.state/staleness.yaml`, same family as `sources.yaml` and (CR-007's) `contradictions.yaml`:

```yaml
schema_version: 1
generated_by: scripts/staleness.sh
pages:
  - path: wiki/concepts/gpt-4-capabilities.md
    scanned_at: 2026-05-19T10:00:00Z
    signal: high
    factors:
      age_months: 24
      inbound_updates_since_edit: 8
      newer_overlapping_sources: 12
      isolated: false
    status: unreviewed        # unreviewed | reviewed | refreshed | archived | historical | deferred
    judgment: null             # filled by LLM in judge stage
    notes: null                # filled at resolve
```

### Skill flow

Not a standalone skill. Exposed via [CR-009](./CR-009-status-dashboard.md)'s `/second-brain:status`:

- **Headless judge** — `/second-brain:refresh --judge-only` (steps 1–2 below). Cron-safe: script narrows by deterministic signals, LLM filters into stale / drifting / fresh-but-isolated / false-positive, no user prompts. Per CR-009's review-log contract, each judged page appends one `kind: staleness-judged` entry to `since-review.yaml`.
- **Interactive resolve** — `/second-brain:status refresh` (steps 3–5 below). Walks reviewable entries; never runs headless. Does *not* append to the review log — the user just made the call.

1. **Scan.** Run `staleness-candidates.sh` (or read its existing output). Print: "N pages signal=high, M medium." User picks scope (high only / all / a specific subdir).
2. **Judge.** For each in-scope page, LLM reads it + a sampled set of neighbor pages (by wikilink), writes a judgment to `staleness.yaml` via `scripts/staleness.sh judge`. Judgments:
   - `stale` — content is likely no longer accurate; refresh recommended.
   - `drifting` — content is accurate but the topic vocabulary/frame has moved on (newer sources use different terms).
   - `fresh-but-isolated` — content is still right, just nobody links to it; consider whether to integrate.
   - `false-positive` — script flagged it, LLM disagrees; mark `status: reviewed` with no further action.
3. **Walk reviewable.** For each judged-not-false-positive entry, present the page + the judgment + a 2-line summary of *why* (which factors triggered it, what neighbors are newer). User picks:
   - **Refresh** — kick off an in-skill rewrite pass: LLM rewrites the page from current sources, user reviews diff, accepts/rejects.
   - **Archive** — move page to `wiki/archive/<year>/<original-relative-path>`, leave a stub redirect at the original path with a `superseded-by:` frontmatter.
   - **Mark historical** — frontmatter `historical: <YYYY-MM>` saying "this is intentionally a snapshot, not current state." Agents reading the page see this and know to treat it as historical.
   - **Defer** — `status: deferred`, no edits, hide from default skill scope until next scan.
4. **Apply.** Edits run through CR-004 validation. Failures → rollback, entry stays `unreviewed`.
5. **Log.** Single `## [date] refresh | N refreshed, M archived, K historical, J deferred` to `wiki/log.md`.

### Integration with other skills

- **`/second-brain:ingest`:** does *not* trigger staleness scans. Staleness accumulates slowly; doing it per-ingest is wasted work.
- **`/second-brain:lint`:** includes a full-scope `staleness-candidates.sh` run, reports counts only ("12 pages signal=high — run `/refresh`").
- **`/second-brain:query`:** if a query answer lands on a page with `status: archived` or `historical: <date>` set, the query skill surfaces it: "this answer comes from a page marked historical (2024-05); newer pages may have refreshed information."

### Interaction with CR-007

If a page is *both* stale-candidate and a contradiction party, **reconcile wins**: resolve the contradiction first, because the staleness judgment may become moot (the refresh from current sources is the resolution).

## Open questions

- **Concrete thresholds** for `signal: low|medium|high`. Picked deterministically (e.g. `high = age_months > 18 AND newer_overlapping_sources > 5`)? Or relative percentile across the wiki? Probably relative — absolute thresholds break in small vaults.
- **Archive directory layout.** `wiki/archive/<year>/<original-path>` is the proposal. Mirror-original-path keeps git diffs sensible; year-bucketing keeps the archive browsable. Confirm in plan.
- **`historical:` frontmatter convention.** Aligns with `disagreements:` and `superseded-by:` from CR-007 — all three should share a single frontmatter shape decided once. Probably a `lifecycle:` map.
- **Refresh-mode rewriting.** Does the skill rewrite the page in one shot, or propose a diff and ask the user paragraph-by-paragraph? Latter is safer but slower; former matches the rest of the project's pace. Pick in plan.
- **Surface staleness in `/query`.** Above proposal touches the query skill. Confirm we want that coupling, or whether it's a follow-up CR.

## Out of scope

- **Automatic refresh** (LLM rewrites pages without user confirmation). Same principle as CR-007: judgment is the user's.
- **Embedding the staleness flag** into a vector store. Part of any future embeddings CR.
- **Cross-vault staleness.** Vaults are isolated by design ([[second-brain-primary-consumer]]).
- **Staleness in `raw/` or `src/`.** Sources are not the wiki; their freshness is the source system's problem, not ours.
- **Deletion of stale pages.** Archive, never delete. Same principle as CR-005 ("do not prune useful concepts").
