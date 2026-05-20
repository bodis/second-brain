# CR-005 Design — `/second-brain:reorganize` skill for wiki self-improvement

**Status:** Draft, pending user review
**Date:** 2026-05-20
**CR:** [CR-005](../../cr/CR-005-reorganize-skill.md)
**Conventions:** [docs/cr/conventions.md](../../cr/conventions.md)
**Depends on:** CR-004 (landed; `scripts/validate-wiki.js` is the validator this skill leans on)

## 1. Problem

`/second-brain:lint` finds broken things. It does not propose **structural** improvements — merging fragmented concept pages, recategorizing pages whose content has drifted, typing the relation between two strongly-linked pages, marking a source-summary as superseded by a synthesis page. Over time an LLM-maintained wiki accumulates this structural debt the same way code does, and there is no skill to address it without the user driving every move by hand.

The user is explicit: **do not prune useful content**. The goal is consolidation, sub-typing, and recategorization — not deletion.

## 2. Goals

- A new skill at `skills/reorganize/SKILL.md`, invoked as `/second-brain:reorganize <direction>`.
- The skill takes a natural-language direction (e.g. "consolidate AI-safety", "audit redundant source-summaries") and an optional `--scope <wiki-subdir>`.
- Three phases: **Propose** (no filesystem change), **Confirm** (user picks moves), **Apply** (one git commit per move with per-move validation and auto-revert on structural error).
- Five move types in v1: **merge**, **recategorize**, **mark-covered**, **parent-create**, **relations-add**.
- One additive frontmatter contract change: a new optional `relations:` key (map of relation-name → list of wikilink targets), validated by `validate-wiki.js`.
- All mechanical work (link rewriting, file renames, frontmatter edits, index sync) lives in a single skill-private script `skills/reorganize/scripts/reorganize.js`. The LLM owns judgment (which moves to propose, content reconciliation during merge, parent-page body, choosing which plain wikilinks to type).
- A pre-run baseline commit gives the user a one-command escape hatch (`git reset --hard <sha>`) if a run is unwanted.

## 3. Non-goals

- **Continuous reorganization.** No daemon, no cron. The skill is user-triggered.
- **Content deletion.** No page is deleted except the source side of a merge (its content has already been absorbed into the survivor). No tags dropped. No links dropped during mark-covered's prose edit.
- **Touching `raw/` or `src/documentation/`.** Hard-enforced by `reorganize.js`'s scope flag.
- **Move detection across re-scrapes** (CR-003 already covers this: rename surfaces as `deleted + new`).
- **Cross-vault reorganization.** A run only sees the current vault.
- **Inline relation syntax** (`[[target|relation]]`). CR-005 rejected this — Obsidian's pipe is for display aliases, not relation typing.
- **Auto-applying lint findings.** Lint and reorganize stay separate. Different trigger, different cadence, different concerns (correctness vs structural improvement).
- **Schema-version bump of `frontmatter-contract.yaml`.** The existing contract format supports optional keys; `relations:` is additive.
- **Per-relation metadata** (e.g. `since:`, `confidence:`). Reserved for a future CR if a real use case emerges.
- **Dry-run mode separate from Propose.** Propose IS the dry-run — it lists every candidate move without touching the filesystem.

## 4. Frontmatter contract change: `relations:`

The only wiki schema change in CR-005. Additive, optional.

### 4.1 Schema

```yaml
relations:
  <relation-name>: [<wikilink-target>, ...]
```

- `<relation-name>` is any kebab-case string. Open vocabulary, like `tags:`.
- `<wikilink-target>` resolves under the three rules `validate-wiki.js wikilinks` already enforces (bare name, `wiki/...` path, `src/documentation/...` path).
- The key is **optional**. Pages without it remain valid.

Example:

```yaml
---
tags: [ai-safety]
relations:
  defined-by: [src/documentation/anthropic/papers/sleeper-agents.md]
  contradicts: [wiki/concepts/myopic-rlhf]
  refines: [wiki/concepts/ai-alignment]
  example-of: [wiki/concepts/scalable-oversight]
sources: [src/documentation/anthropic/papers/sleeper-agents.md]
created: 2026-04-12
updated: 2026-05-20
---
```

### 4.2 Starter vocabulary

The SKILL prompt suggests but does not enforce: `defined-by`, `contradicts`, `refines`, `example-of`, `see-also`. The LLM may introduce new relation names when justified by repeated patterns observed during a run.

### 4.3 Contract file update

`wiki/.state/frontmatter-contract.yaml` (owned by `scripts/validate-wiki.js`, scaffolded by `/second-brain:onboard`) gains one optional-key declaration for `relations:`. Existing vaults pick this up the next time onboarding or validation runs.

Schema version stays the same. No migration script. Existing pages without `relations:` are already valid.

### 4.4 Validator change

`validate-wiki.js frontmatter` accepts pages with or without `relations:`. When present, it must be a map of string → list-of-strings; structural mismatch is exit code 2.

`validate-wiki.js wikilinks` gains one rule: if `relations:` is present, every target in every list must resolve under the same three-form resolution as wikilinks. Unresolved targets are reported in the same `broken[]` array as broken `[[wikilinks]]`, distinguished by a `source` field (`"wikilink"` vs `"relation"`).

## 5. Skill invocation and CLI shape

### 5.1 User-facing invocation

```
/second-brain:reorganize "<direction>"
/second-brain:reorganize "<direction>" --scope wiki/concepts/programming-languages/
```

`<direction>` is required free text. `--scope` is a vault-relative subdirectory under `wiki/`; defaults to `wiki/`. Anything outside `wiki/` is rejected with an error.

### 5.2 Script invocation

```
node "$CLAUDE_PLUGIN_ROOT/skills/reorganize/scripts/reorganize.js" <subcommand> [args]
```

The script resolves the vault root by walking up to the nearest directory containing both `.git/` and `wiki/.state/sources.yaml`, matching `validate-wiki.js`'s convention.

### 5.3 Exit codes (shared)

- `0` clean
- `1` warning (e.g. validation produced warnings on the move just applied)
- `2` structural error encountered after a move; commit was reverted; the SKILL stops the run
- `3` refused due to an invariant check (e.g. merged body below sanity threshold, scope outside `wiki/`). No commit was made. The SKILL reports the reason and continues with the next move.
- `6` uncommitted non-wiki changes — same semantics as `state-sources.js`. SKILL re-runs `begin` and retries.

### 5.4 Scope guard

`reorganize.js` only writes inside `wiki/`. Any subcommand that receives a `--from`, `--to`, `--page`, `--by`, or `--children` path outside `wiki/` exits 3 with `error: reorganize only operates on wiki/, got <path>`. This is enforced in the script, not the SKILL prompt.

## 6. Subcommands of `reorganize.js`

| Subcommand | Side effects | Purpose |
|---|---|---|
| `begin` | One git commit (`pre-reorganize baseline`) if `wiki/` is dirty; no-op otherwise. Prints the baseline SHA (or the current HEAD SHA if no-op) to stdout. | Establish a clean baseline so per-move reverts are safe. |
| `candidates --kind <merge\|recategorize\|cover\|parent\|relations> [--scope <dir>] --json` | None | Deterministic shortlist for the LLM to judge. |
| `move-page --from <vault-path> --to <vault-path>` | One commit: `reorganize: move <from> → <to>` | Rename within `wiki/`; internally rewrites every `[[from]]` and `[[from\|alias]]` to point at the new path (aliases preserved); updates the index row; bumps frontmatter `updated:`. |
| `merge-page --from <vault-path> --into <vault-path> --merged-body <tmpfile>` | One commit: `reorganize: merge <from> into <into>` | Replace `--into`'s body with the file at `--merged-body`; delete `--from`; internally rewrite all `[[from]]` references to `[[into]]`; clean dead row from `wiki/index.md`. |
| `mark-covered --page <vault-path> --by <target>` | One commit: `reorganize: mark <page> covered by <by>` | Append a `> **Covered by [[<by>]]** — see that page for current synthesis.` block to the page; bump `updated:`. |
| `parent-create --page <vault-path> --body <tmpfile> --children <p1,p2,...>` | One commit: `reorganize: introduce parent <page>` | Create the parent file from the LLM-provided body; append a `## Children` section listing the cluster; add an index row. Does not move children — they remain where they are. If you also want typed parent/child relations, follow up with `relations-add` on each child. |
| `relations-add --page <vault-path> --relation <name> --targets <t1,t2,...>` | One commit: `reorganize: type relations on <page>` | Merge into the page's `relations:` map: create the key if absent, append targets while deduping; bump `updated:`. |
| `validate-or-revert` | Maybe one revert commit (`Revert "reorganize: …"`) | Run `validate-wiki.js all`. Exit 2 → `git revert HEAD --no-edit`, exit 2. Exit 1 → exit 1 (warnings reported but no revert). Exit 0 → exit 0. |

The link-rewrite logic is shared internal helper used by `move-page` and `merge-page` — not a public subcommand in v1. It rewrites both inline prose wikilinks and target lists in the frontmatter `relations:` map. It does not touch `sources:` (those are filename identities, not wikilink references).

### 6.1 `candidates` JSON shapes (per kind)

```json
// --kind merge
{
  "pairs": [
    {"a": "wiki/concepts/alignment.md", "b": "wiki/concepts/ai-alignment.md",
     "shared_wikilinks": 14, "shared_tags": 3}
  ]
}
// --kind recategorize
{
  "pages": [
    {"path": "wiki/concepts/rlhf-incident.md", "current_dir": "concepts",
     "signals": {"sources_count": 4, "synthesises_others": true}}
  ]
}
// --kind cover
{
  "summaries": [
    {"path": "wiki/sources/old-thing.md",
     "candidate_covers": ["wiki/synthesis/big-idea.md"],
     "shared_wikilinks": 9}
  ]
}
// --kind parent
{
  "clusters": [
    {"members": ["wiki/concepts/p1.md", "wiki/concepts/p2.md", "wiki/concepts/p3.md"],
     "shared_wikilinks": 11, "shared_tag": "programming-languages"}
  ]
}
// --kind relations
{
  "pages": [
    {"path": "wiki/concepts/oauth.md",
     "outgoing_pattern": [
       {"target": "src/documentation/anthropic/papers/foo.md",
        "occurrences_in_prose": 3, "suggested_relation": "defined-by"}
     ]}
  ]
}
```

Thresholds (`shared_wikilinks ≥ N`, `sources_count ≥ K`, etc.) are fixed sensible defaults inside `reorganize.js`. Not exposed via CLI in v1 — tunable in code if shortlists prove too noisy.

### 6.2 No-content-loss invariants enforced in the script

- `merge-page` refuses if the merged-body tmpfile is shorter than `max(len(from), len(into)) × 0.5`. Exit 3 with `error: merged body suspiciously short — refusing merge`. Sanity check against "LLM produced a one-paragraph merge of two long pages".
- `mark-covered` never edits anything except the page passed via `--page`. Never deletes.
- `move-page` and `merge-page` only rewrite links via `link-rewrite`'s deterministic regex pass; they do not edit prose for sense.
- `parent-create` does not move children. Children become children-of-parent only via the parent's `## Children` listing.

## 7. Propose / Confirm / Apply flow

### 7.1 Propose

The SKILL prompt orchestrates:

1. Run `reorganize.js begin` to bake any uncommitted `wiki/` edits into a baseline commit. Capture the baseline SHA from the commit output and report it to the user.
2. Based on the user's `<direction>` and `--scope`, decide which `candidates --kind` calls are relevant. ("Consolidate AI-safety" → `merge` and `parent` are most relevant. "Audit redundant source-summaries" → `cover`. "Type the programming-languages cluster" → `relations`.) Run each relevant call, capturing JSON.
3. Layer LLM judgment on the deterministic shortlists: discard candidates that don't fit the direction, group related candidates, write a one-line rationale per surviving candidate citing the deterministic signals.
4. Present a numbered list to the user, e.g.:
   ```
   Baseline: abc1234

   Proposed moves:
    1. MERGE  wiki/concepts/alignment → wiki/concepts/ai-alignment
             shared wikilinks: 14, shared tag: ai-safety
    2. RECATEGORIZE  wiki/concepts/rlhf-incident → wiki/synthesis/
             signals: synthesises 4 sources, content drifted toward synthesis
    3. ADD RELATIONS to wiki/concepts/oauth
             3 outbound wikilinks consistently in defined-by context

   Apply which? (e.g. "all", "1,3", or "none")
   ```

### 7.2 Confirm

The SKILL parses the user response:

- `none` or empty → log "no moves applied" and stop.
- `all` → all proposed moves.
- A comma-separated list of indices → that subset.
- Anything else → ask again.

### 7.3 Apply

For each picked move, in order:

1. **Generate any tmpfiles required.** For `merge-page`, the LLM writes the merged body (reconciling content from both pages) to a tmpfile under `/tmp/reorganize-merge-<sha>.md`. For `parent-create`, the LLM writes the parent body to `/tmp/reorganize-parent-<sha>.md`.
2. **Invoke the subcommand.** The script does file ops, link rewrites, index sync, frontmatter edits, then makes one commit.
3. **Invoke `validate-or-revert`.** If it exits 2, the just-applied commit is already reverted; record the move as "reverted: <reason>" and **stop the run**. If it exits 1, record the move as "applied with warnings" and continue. If it exits 0, record as "applied" and continue. If the subcommand itself exited 3 (invariant refusal), no commit was made; record the move as "refused: <reason>" and continue with the next picked move.
4. **Clean up tmpfiles.**

### 7.4 Logging

After all moves are processed (whether stopped early or run to completion), append one entry to `wiki/log.md`:

```
## [YYYY-MM-DD] reorganize | <direction>

Baseline: <sha>. Applied: <N>. Skipped: <M>. Reverted: <K> (<reason if any>).
- merge wiki/concepts/alignment → wiki/concepts/ai-alignment (applied)
- recategorize wiki/concepts/rlhf-incident → wiki/synthesis/ (applied)
- add relations to wiki/concepts/oauth (skipped)
```

The log entry is informational only. State of record for "what changed" is the per-move git commits and `wiki/.state/sources.yaml` (untouched by reorganize — reorganize doesn't add or remove sources).

## 8. Guardrails

Three safety layers, in order:

1. **Pre-run baseline.** `reorganize.js begin` makes a `pre-reorganize baseline` commit if `wiki/` is dirty. The SHA is reported to the user. `git reset --hard <sha>` undoes the entire run.
2. **Per-move validation + auto-revert.** Each move's commit is followed by `validate-wiki.js all`. Exit code 2 (structural error) → `git revert HEAD --no-edit` + stop the run. Exit code 1 (warning) → report + continue.
3. **No-content-loss invariants in scripts.** Merge sanity-checks merged body length. Mark-covered never deletes. Parent-create never absorbs child content. (Spelled out in §6.2.)

### 8.1 Failure modes considered

- *LLM proposes a wrong merge.* User catches it during Confirm. If it slips through, the per-move commit is bisectable and revertible by hand.
- *Validator passes but the move is semantically bad.* Out of scope for reorganize. That's what `/second-brain:lint` and the human curator are for.
- *External process mutates the wiki mid-run.* The pre-run baseline captures the entry state; the per-move commits are sequential. No defense against concurrent edits, but second-brain has no other processes.
- *Mass run leaves the wiki worse than it started.* The baseline SHA is the escape hatch.

## 9. SKILL.md structure

`skills/reorganize/SKILL.md` mirrors the shape of `skills/lint/SKILL.md` and `skills/ingest/SKILL.md`.

### 9.1 Frontmatter

```markdown
---
name: reorganize
description: >
  Propose structural improvements to the wiki — merging fragmented concept pages,
  recategorizing drifted pages, typing relations, marking superseded
  source-summaries, introducing parent concepts. Use when the user says
  "reorganize", "consolidate", "restructure", "audit structure",
  "merge concepts", "introduce a parent for X", or "type the relations on Y".
allowed-tools: Bash Read Write Edit Glob Grep
---
```

### 9.2 Sections

1. **Tooling.** Pin to `reorganize.js`. Never hand-edit wiki files for moves; the script owns mechanical rewrites.
2. **Source types.** Reorganize only touches `wiki/`. `raw/` and `src/documentation/` are immutable.
3. **Phase 1 — Propose.** For each relevant `candidates --kind` call, fetch the JSON, layer judgment, print the numbered list.
4. **Phase 2 — Confirm.** Parse user input (`all`, `1,3,5`, `none`).
5. **Phase 3 — Apply.** Per-move loop with tmpfile generation, subcommand invocation, `validate-or-revert`, abort-on-stop.
6. **Logging.** Append the run paragraph to `wiki/log.md`.
7. **When to reorganize.** Suggested cadence (monthly, or any time structural debt is noticed). Reorganize is judgment-heavy; the user runs it deliberately, not on a schedule.
8. **Related Skills.** `/second-brain:lint`, `/second-brain:query`, `/second-brain:ingest`.

## 10. Tests

### 10.1 Automated (`tests/test_reorganize.sh`)

Mirrors `tests/test_state_sources.sh` structure (numbered cases, fixture vault, assertions on commits + files).

1. `begin` is a no-op on a clean tree.
2. `begin` makes a `pre-reorganize baseline` commit when `wiki/` is dirty; reports the SHA on stdout.
3. `candidates --kind merge` on a vault with two overlapping concept pages returns a `pairs[]` shortlist with stable scores.
4. The internal link-rewrite helper, exercised through `move-page`, rewrites `[[X]]`, `[[X|alias]]`, links inside list items, and target values in the frontmatter `relations:` map. Does NOT rewrite values in `sources:` (those are filename identities, not wikilink references). Does not touch unrelated links.
5. `move-page` renames file, rewrites all inbound links, updates the index row, bumps `updated:`, makes exactly one commit.
6. `merge-page` absorbs merged body, rewrites links, deletes source file, cleans the dead index row, makes exactly one commit.
7. `merge-page` refuses with exit 3 when the merged-body tmpfile is below the sanity-check threshold. No commit is made.
8. `mark-covered` appends the covered note block, bumps `updated:`, makes one commit. Original page content is otherwise unchanged.
9. `parent-create` writes parent body, appends the `## Children` section, adds an index row, makes one commit. Children are not moved.
10. `relations-add` creates the `relations:` key when absent; merges with an existing map when present; dedupes targets; makes one commit.
11. `validate-or-revert` reverts on exit code 2 (structural) and exits 2. Passes through on exit 0. Passes through and reports on exit 1.
12. `validate-wiki.js wikilinks` flags unresolved `relations:` targets in the same `broken[]` array as broken `[[wikilinks]]`, with `source: "relation"`.
13. `wiki/.state/frontmatter-contract.yaml` declares `relations:` as an optional map; `validate-wiki.js frontmatter` accepts pages with and without it.
14. End-to-end: fixture vault with three concept pages → run a merge subcommand → assert resulting file tree, link state, index state, and commit log.

### 10.2 Manual smoke checklist

1. Fresh vault, run `/second-brain:reorganize "consolidate AI-safety"`. Confirm Propose phase lists candidates with rationale; Confirm phase accepts `none` and exits cleanly with no commits.
2. Same vault, pick `all`. Confirm one commit per move; `wiki/log.md` gains one entry; baseline SHA still resets the vault if needed.
3. Force a structural error mid-run (e.g. break a frontmatter file between moves). Confirm the next move's `validate-or-revert` reverts the commit, the run stops, and the baseline still reverts the rest by hand.
4. Add a `relations:` block with a typo target. Confirm `validate-wiki.js wikilinks` flags it on the next run.
5. Run on a vault with no candidates matching the direction. Confirm the SKILL reports "no candidates" and exits without a baseline commit (or with a no-op `begin`).

## 11. Risks and tradeoffs

- **LLM judgment is the weakest link.** The deterministic candidates narrow the search; the LLM still picks which to surface and writes merged bodies. Mitigation: per-move commits, validate-or-revert, baseline SHA. The user can also stop the run at Confirm by picking a strict subset.
- **Open-vocabulary relation names invite drift.** A user could end up with `defined-by` on some pages and `defined_by` on others. Mitigation: SKILL prompt lists the starter set; `/second-brain:lint` could grow a future check for relation-name typos (out of scope here).
- **Per-move commits create commit-log noise.** A 20-move run is 20 commits. Acceptable per the Confirm phase — the user opts in. The commit messages are uniformly prefixed `reorganize:` so they're easy to filter.
- **Merged content is LLM-generated prose.** The script enforces a length floor but cannot judge meaning. The user is expected to read the merged body in the resulting commit and follow up with edits if needed. Reorganize's commit is the audit trail.
- **`relations:` resolver overlap with wikilinks.** `validate-wiki.js wikilinks` now scans two structures in the same file. Cost is small (parsing frontmatter is already happening). Risk: if the validator gets confused, both checks could break together. Mitigation: separate test cases for each (§10.1 cases 4 and 12).
- **Tmpfiles under `/tmp`.** A killed run could leave them around. Acceptable — they're under 100 KB each, and `/tmp` is purged routinely.

## 12. Open questions deferred

- **Should reorganize learn from past runs?** A "patterns I keep proposing" memory could narrow future candidates. Out of scope. The wiki itself is the memory.
- **Should `mark-covered` ever evolve into deleting the source-summary?** Not in CR-005. The user was explicit about no pruning.
- **Should relation-name consistency be a lint rule?** Probably yes eventually. Spawn a follow-up CR once we have real `relations:` data to look at.
- **Should `parent-create` optionally move children into a new subdir?** Maybe. Would require a path-rewrite pass that's a superset of `move-page`. Deferred to a follow-up CR if users ask.

## 13. Out of scope (carried from CR-005)

- Automatic continuous reorganization.
- Anything that prunes content (delete pages, drop links, drop tags).
- Touching raw sources or structured documentation.
- Inline-syntax relation typing (`[[target|relation]]`).
- Auto-applying lint findings.
- Cross-vault reorganization.
- Per-relation metadata fields beyond the target list.
- Schema-version bump of `frontmatter-contract.yaml`.
