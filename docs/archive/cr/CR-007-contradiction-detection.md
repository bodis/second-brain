# CR-007 — Contradiction detection across wiki pages

**Depends on:** CR-002 (state YAML), CR-004 (hooks + scripts framework), [CR-009](./CR-009-status-dashboard.md) (status dashboard + review-log contract — owns the user-facing surface).

## Problem

The wiki is the consolidated, agent-facing memory layer. When two pages disagree about the same fact — or when a new ingest writes claims that contradict existing pages — nothing flags it. An agent reading the vault has no way to tell which assertion to trust, and silently picks one.

Concrete cases:

1. **Intra-wiki disagreement.** `wiki/entities/foo.md` says "Foo was acquired by Bar in 2023"; `wiki/concepts/acquisitions.md` says "Foo was acquired by Baz in 2024." Both were written from different sources, neither knows about the other.
2. **Ingest-time clash.** A new source contradicts existing wiki content. Today `/ingest` happily writes the new claim into a new (or overwritten) page; the old claim survives elsewhere.
3. **Legitimate disagreement.** Two sources genuinely disagree (competing frameworks, contested data). The wiki has no way to *mark* this as intentional rather than as a bug.

Lint catches **structural** problems (broken links, index drift). It does not catch **semantic disagreement**.

## Motivation

- **Agent trust.** The whole project's value depends on agents being able to consume the wiki as authoritative memory. Silent contradictions undermine that.
- **Blocks any future RAG layer.** Embedding contradictory wiki content into a vector store just gives the agent a faster way to retrieve disagreeing claims. Contradiction resolution must precede embeddings.
- **Distinct from reorganize (CR-005).** Reorganize fixes *structural* debt (too-fine pages, missing sub-typing). Contradictions are about *factual* disagreement. Different work, different skill.

## Proposed approach

Hooks-first split per [conventions.md §4](./conventions.md):

| Work | Owner |
|---|---|
| Find *candidate* contradiction pairs (shared entities, overlapping claims) | Script: `scripts/contradictions-candidates.sh` |
| Judge whether a candidate pair is a real contradiction | LLM (skill) |
| Persist confirmed contradictions + their state | Script writing `wiki/.state/contradictions.yaml` |
| Resolve a contradiction (edit pages, supersede, accept-disagreement) | LLM (skill), with deterministic post-checks |

### State file

New file `wiki/.state/contradictions.yaml`, same family as `sources.yaml` (CR-002):

```yaml
schema_version: 1
generated_by: scripts/contradictions.sh
contradictions:
  - id: 2026-05-19-001
    detected_at: 2026-05-19T10:00:00Z
    pages:
      - wiki/entities/foo.md
      - wiki/concepts/acquisitions.md
    claim: "Acquirer of Foo"
    assertions:
      - page: wiki/entities/foo.md
        text: "Foo was acquired by Bar in 2023"
        source: wiki/sources/article-a.md
      - page: wiki/concepts/acquisitions.md
        text: "Foo was acquired by Baz in 2024"
        source: wiki/sources/article-b.md
    status: unresolved          # unresolved | resolved | accepted-disagreement
    resolution: null             # filled when resolved
```

### Candidate detection (deterministic, cheap)

`scripts/contradictions-candidates.sh` looks for *signals*, not contradictions:

- Pages that reference the same entity wikilink and contain conflicting frontmatter fields (e.g. two pages with `relations.acquired-by:` set to different targets for the same entity).
- Pages with overlapping wikilink sets above a threshold but whose summary frontmatter (`summary:` field, if added in plan) differs by more than a similarity threshold.
- Pages that link to the same source but make claims with disjoint key entities.

These are **filters**, not judgments. They narrow the input set the LLM has to consider from "all pages" to "plausible suspects."

### Skill flow

Not a standalone skill. Exposed via [CR-009](./CR-009-status-dashboard.md)'s `/second-brain:status`:

- **Headless judge** — `/second-brain:reconcile --judge-only` (steps 1–2 below). Cron-safe: a script narrows, an LLM filters, no user prompts. Per CR-009's review-log contract, each judged pair appends one `kind: contradiction-judged` entry to `since-review.yaml`.
- **Interactive resolve** — `/second-brain:status reconcile` (steps 3–5 below). Walks unresolved entries; never runs headless. Does *not* append to the review log — the user just made the call.

1. **Scan.** Run `contradictions-candidates.sh` to get candidate pairs. Print count.
2. **Judge.** For each candidate, the LLM reads both pages and decides: real contradiction / not / accepted-disagreement. Output goes to `contradictions.yaml` via `scripts/contradictions.sh add`.
3. **Walk unresolved.** For each `status: unresolved` entry, present the conflicting assertions side-by-side. User picks:
   - **Pick A** — edit page B to align with page A. Record source preference for future weighting.
   - **Pick B** — symmetric.
   - **Accept disagreement** — mark `status: accepted-disagreement`, annotate both pages with a frontmatter `disagreements:` block linking to the contradiction id. Agents reading either page see the disagreement explicitly.
   - **Defer** — leave `unresolved`, no edits.
4. **Apply.** Edits run through CR-004 validation (link integrity, frontmatter parse). On failure: rollback the edit, keep entry `unresolved`, log it.
5. **Log.** Append a single `## [date] reconcile | N resolved, M accepted, K deferred` entry to `wiki/log.md`.

### Integration with `/second-brain:ingest`

After ingest writes new/updated wiki pages, it calls `contradictions-candidates.sh --scope <changed-pages>` to do an *incremental* scan against just those pages + their wikilink neighbors. New candidates land in `contradictions.yaml` as unresolved. Ingest does **not** block on resolution — the user runs `/second-brain:reconcile` when they want to triage. This keeps ingest fast and the user in the loop on judgment.

### Integration with `/second-brain:lint`

`lint` runs the full-scope candidate scan periodically. It does not auto-judge; it reports counts: "12 candidate contradictions, 4 unresolved (run `/second-brain:reconcile`)."

## Open questions

- **Frontmatter conventions.** Need a frontmatter shape for `disagreements:` and `superseded-by:`. Sketch in plan; should align with the `relations:` shape proposed in CR-005.
- **Candidate signals.** The list above is a starting point. The plan should pick 2–3 *cheap* signals that hit most real cases, not all of them. Risk of false-positive flood otherwise.
- **Source weighting.** If the user repeatedly picks `src/documentation/` sources over `raw/` ones, should the system learn that preference (e.g. surface `structured > generic` as a default tiebreaker)? Probably yes, but defer to a follow-up; CR-007 ships without learned weighting.
- **Scope of "claim."** Do we require the LLM to extract a structured `claim` field, or is freeform text fine? Freeform is simpler; structured enables future RAG filtering. Probably freeform now, structured later.
- **Cross-vault contradictions.** Out of scope — vaults are isolated by design ([[second-brain-primary-consumer]]); contradictions are per-vault only.

## Out of scope

- **Embeddings / RAG.** A separate future CR (CR-008 candidate) cites CR-007 as a hard dependency: do not embed wiki content until contradiction-resolution exists.
- **Auto-resolution.** No silent edits. Resolution is always user-confirmed; the skill proposes, the user picks.
- **Touching `raw/` or `src/`.** Read-only. Contradictions are wiki-level; sources are immutable.
- **Staleness / decay metrics.** Decided not to make this its own system. If it becomes a real signal, fold it into CR-005 (reorganize) — last-touched timestamps + cross-reference recency are a metric, not an architecture.
- **Inter-source disagreement reports.** We don't try to call out that `raw/article-a.md` and `raw/article-b.md` disagree as raw documents. We only care about disagreement after consolidation into the wiki.
