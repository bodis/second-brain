---
name: reorganize
description: >
  Propose structural improvements to the wiki — merging fragmented concept
  pages, recategorizing drifted pages, typing relations, marking superseded
  source-summaries, introducing parent concepts. Use when the user says
  "reorganize", "consolidate", "restructure", "audit structure",
  "merge concepts", "introduce a parent for X", or "type the relations on Y".
allowed-tools: Bash Read Write Edit Glob Grep
---

# Second Brain — Reorganize

Take a user-supplied direction (e.g. "consolidate AI-safety", "audit redundant source-summaries") and run a guided structural reorganization pass over the wiki. Three phases: **Propose** (no filesystem change), **Confirm** (user picks moves), **Apply** (one git commit per move with per-move validation and auto-revert on structural error).

## Tooling

All mechanical work goes through `skills/reorganize/scripts/reorganize.js`. Never hand-edit wiki files for moves; the script owns file renames, link rewrites, frontmatter edits, and index sync.

```bash
node "$CLAUDE_PLUGIN_ROOT/skills/reorganize/scripts/reorganize.js" <subcommand> [args]
```

The script resolves the vault root the same way `state-sources.js` and `validate-wiki.js` do.

## Source types

Reorganize only touches `wiki/`. `raw/` and `src/documentation/` are immutable here — the script enforces this via a scope guard that rejects out-of-scope paths with exit 3.

## Input

The user provides a free-text **direction** (required). Optionally `--scope <wiki-subdir>`. Default scope: `wiki/`. Anything outside `wiki/` is rejected.

## Phase 1 — Propose

1. **Baseline.** Run:
   ```bash
   node "$CLAUDE_PLUGIN_ROOT/skills/reorganize/scripts/reorganize.js" begin
   ```
   Capture the SHA on stdout. Report it to the user — `git reset --hard <sha>` undoes the entire run.

2. **Pick relevant candidate kinds.** Based on the direction:
   - "consolidate X" / "merge X" → `merge`, `parent`
   - "audit redundant source-summaries" / "source coverage" → `cover`
   - "type relations" / "link types" → `relations`
   - "categories drifted" / "wrong folder" → `recategorize`
   When in doubt, run more than one kind.

3. **Fetch shortlists.** For each picked kind:
   ```bash
   node "$CLAUDE_PLUGIN_ROOT/skills/reorganize/scripts/reorganize.js" candidates --kind <kind> [--scope <dir>] --json
   ```
   Parse the JSON (shapes documented in the spec §6.1).

4. **Layer judgment.** Discard candidates that don't fit the direction. Group related ones. Write a one-line rationale per surviving candidate citing the deterministic signal (`shared wikilinks: N`, `signals: synthesises 4 sources`, etc.).

5. **Present a numbered list.** Example:

   ```
   Baseline: abc1234

   Proposed moves:
    1. MERGE  wiki/concepts/alignment → wiki/concepts/ai-alignment
             shared wikilinks: 14, shared tag: ai-safety
    2. RECATEGORIZE  wiki/concepts/rlhf-incident → wiki/synthesis/
             signals: synthesises 4 sources
    3. ADD RELATIONS to wiki/concepts/oauth
             3 outbound wikilinks consistently in defined-by context

   Apply which? (e.g. "all", "1,3", or "none")
   ```

## Phase 2 — Confirm

Parse the user's reply:
- `none` or empty → log "no moves applied" and stop.
- `all` → all proposed moves.
- Comma-separated indices → that subset.
- Anything else → ask again.

## Phase 3 — Apply

For each picked move, in order:

1. **Generate any tmpfiles required.**
   - `merge-page`: write the reconciled merged body to `/tmp/reorganize-merge-<sha>.md`. Include carry-over content from both pages — the script refuses a body shorter than `max(len(body(from)), len(body(into))) × 0.5`.
   - `parent-create`: write the parent body (frontmatter + intro prose, NO `## Children` section — the script appends that) to `/tmp/reorganize-parent-<sha>.md`.

2. **Invoke the subcommand.** Examples:
   ```bash
   node ".../reorganize.js" move-page --from wiki/concepts/old.md --to wiki/concepts/new.md
   node ".../reorganize.js" merge-page --from wiki/concepts/a.md --into wiki/concepts/b.md --merged-body /tmp/reorganize-merge-X.md
   node ".../reorganize.js" mark-covered --page wiki/sources/old-summary.md --by wiki/synthesis/big-idea
   node ".../reorganize.js" parent-create --page wiki/concepts/parent.md --body /tmp/reorganize-parent-X.md --children "wiki/concepts/c1,wiki/concepts/c2"
   node ".../reorganize.js" relations-add --page wiki/concepts/oauth.md --relation defined-by --targets "src/documentation/foo/auth.md"
   ```

3. **Validate.** Always run immediately after each move:
   ```bash
   node ".../reorganize.js" validate-or-revert
   ```
   - Exit 0 → record move as "applied" and continue.
   - Exit 1 → record as "applied with warnings" and continue.
   - Exit 2 → the just-applied commit has already been reverted by the script; record as "reverted: <reason>" and **stop the run**.
   - Exit 3 from the move subcommand itself (invariant refusal — e.g. merged body too short) → no commit was made; record as "refused: <reason>" and continue with the next picked move.

4. **Clean up tmpfiles.**

## Relation vocabulary

The starter relation names — suggested, not enforced:
- `defined-by` — typically points at a `src/documentation/...` target.
- `contradicts` — opposing claim about the same topic.
- `refines` — strengthens / narrows the target.
- `example-of` — instance of a more general concept.
- `see-also` — generic "related" pointer.

You may introduce new relation names when justified by repeated patterns observed during a run. Keep them kebab-case.

## Logging

After all moves are processed (whether stopped early or run to completion), append one entry to `wiki/log.md`:

```
## [YYYY-MM-DD] reorganize | <direction>

Baseline: <sha>. Applied: <N>. Skipped: <M>. Reverted: <K> (<reason if any>).
- merge wiki/concepts/alignment → wiki/concepts/ai-alignment (applied)
- recategorize wiki/concepts/rlhf-incident → wiki/synthesis/ (applied)
- add relations to wiki/concepts/oauth (skipped)
```

`wiki/log.md` is informational only — git history is the state of record.

## When to reorganize

- **Monthly at minimum**, or any time structural debt is noticed.
- Reorganize is judgment-heavy; the user runs it deliberately, not on a schedule. No hook fires it.
- It composes with lint: lint catches correctness issues; reorganize catches structural debt.

## Related Skills

- `/second-brain:lint` — health-check the wiki for contradictions, orphans, broken links.
- `/second-brain:query` — ask questions against the wiki.
- `/second-brain:ingest` — process new sources into wiki pages.
