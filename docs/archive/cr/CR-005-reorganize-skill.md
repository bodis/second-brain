# CR-005 — New `/second-brain:reorganize` skill for wiki self-improvement

**Depends on:** CR-004.

## Problem

`lint` finds broken things. It doesn't suggest **structural** improvements: "these three concept pages should be merged into one with sub-pages", "these four links from concept→entity should all be typed `defined-by` instead of plain wikilinks", "this source-summary's content is now better-covered by a synthesis page; the summary can be slimmed". The user wants a skill that takes general direction ("I think we have too many fragmented AI-safety concepts; consolidate") and runs a guided reorganization pass.

The user was explicit: **do not** prune useful concepts/connections. The goal is generalization, sub-typing, and updating outdated structure — not deletion.

## Motivation

Over time, an LLM-maintained wiki accumulates structural debt the same way code does — too-fine-grained pages, parallel concept names, flat link sets. Lint doesn't address this because lint is correctness-only. Without a dedicated skill, this debt either gets ignored or the user has to drive it manually.

## Proposed approach

New skill at `skills/reorganize/SKILL.md`, invoked as `/second-brain:reorganize <direction>`.

Inputs:
- A user-provided **direction** in natural language (e.g. "consolidate the AI-safety cluster", "introduce sub-typed link relations under wiki/concepts/programming-languages/", "audit which source summaries are now redundant given recent synthesis pages").
- Optionally a scope (a wiki subdirectory). Default: full wiki.

Flow:
1. **Propose.** Use the validation scripts from CR-004 to load current state. Identify candidate reorganization moves matching the direction. Present them as a numbered list with rationale. Don't change anything yet.
2. **Confirm.** User picks which moves to apply (all, some, none).
3. **Apply.** Execute the picked moves: rename/move pages, merge pages, rewrite links, add link-typing (frontmatter convention), update index. After each move, re-run CR-004 validation; rollback if validation fails.
4. **Log.** Append a single `## [date] reorganize | <direction>` entry to `wiki/log.md` with what changed.

Candidate move types (initial list, expandable during plan):
- Merge two concept pages whose content overlaps above a threshold; add a redirect note in the index.
- Promote a recurring tag-sequence into a sub-typed link convention (e.g. frontmatter `relations: {defined-by: [...], contradicts: [...]}`).
- Move a page to a different category folder if its content has drifted (`concepts/` → `synthesis/`).
- Mark a source-summary as "covered by synthesis page X" without deleting the summary.
- Introduce a parent concept page where several siblings should be sub-pages.

## Open questions

- **Reorganize vs `lint --rewrite` mode.** Reorganize takes a direction; lint runs autonomously. Different enough to be different skills. Confirm during plan.
- Sub-typed link relations: encode as a frontmatter map (`relations:`) or as inline syntax (`[[Page|relation]]` — Obsidian supports aliases but not relation types natively)? Frontmatter map is portable. Decide during plan.
- Rollback: do we need git-level safety (skill commits before applying, reverts on failure), or is CR-004 validation enough? Probably both — easy to add.
- Should reorganize touch `src/documentation/` (CR-003)? **No** — those are immutable like `raw/`. Reorganize only touches `wiki/`.
- What's the threshold for "content overlap >X" when proposing a merge — LLM judgment, or a deterministic metric (shared wikilinks, shared tags)? Probably both, with the deterministic metric narrowing the candidate set.

## Out of scope

- Automatic continuous reorganization (no daemon, no cron).
- Anything that prunes content (delete pages, drop links).
- Touching raw sources or structured documentation.
