---
name: lint
description: >
  Health-check the wiki for contradictions, orphan pages, stale claims,
  and missing cross-references. Use when the user says "audit",
  "health check", "lint", "find problems", or wants to improve wiki quality.
allowed-tools: Bash Read Write Edit Glob Grep
---

# Second Brain — Lint

Health-check the wiki and report issues with actionable fixes.

## Audit Steps

Run all checks below, then present a consolidated report.

### 1. Broken wikilinks and orphan pages

Run the validator and report what it finds:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/validate-wiki.js" wikilinks --json
```

The JSON has two keys:
- `broken[]` — `{from, target}` entries where `[[target]]` does not resolve under any of the three rules (bare name, `wiki/...` path, `src/documentation/...` path).
- `orphans[]` — `{path}` entries for pages under `wiki/{sources,entities,concepts,synthesis}/` with zero inbound `[[…]]` links.

Present both arrays grouped together. For each `broken` entry, suggest either fixing the link or creating the target page (treat as a "Missing pages" candidate — see §4). For each `orphan`, judge whether it's intentionally standalone or should be linked from somewhere thematically related.

### 2. Contradictions

Read pages that share entities or concepts and look for conflicting claims. Flag when:
- Two source summaries make opposing claims about the same topic
- An entity page contains information that conflicts with a source summary
- Dates, figures, or factual claims differ between pages

### 3. Stale claims

Cross-reference source dates with wiki content. Flag when:
- A concept page cites only old sources and newer sources exist on the same topic
- Entity information hasn't been updated despite newer sources mentioning that entity

### 4. Missing pages

Scan for `[[wikilinks]]` that point to pages that don't exist yet. These are topics the wiki mentions but hasn't given their own page. Assess whether they warrant a page.

### 5. Missing cross-references

Find pages that discuss the same topics but don't link to each other. Look for:
- Entity pages that mention concepts without linking them
- Concept pages that mention entities without linking them
- Source summaries that cover the same topic but don't reference each other

### 6. Index consistency

Run the validator:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/validate-wiki.js" index --json
```

The JSON has two keys:
- `missing_rows[]` — vault-relative paths of pages on disk that have no row in `wiki/index.md`.
- `dead_rows[]` — `{target}` entries from `wiki/index.md` whose wikilink does not resolve.

If `missing_rows` is non-empty, offer to run the fixer:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/sync-index.js"
```

`sync-index.js` adds a placeholder row for each missing page (`- [[wiki/<subdir>/<slug>]]`) and removes dead rows. It preserves existing row summaries. Idempotent. After it runs, ask the user whether to flesh out the placeholder rows with one-line summaries.

If `dead_rows` is non-empty, treat it as a structural error: the index references pages that don't exist. Confirm with the user whether the pages were deleted (then remove the rows) or moved (then update the rows).

### 7. Data gaps

Based on the wiki's current coverage, suggest:
- Topics mentioned frequently but lacking depth
- Questions the wiki can't answer well
- Areas where a web search could fill in missing information

## Report Format

Present findings grouped by severity:

### Errors (must fix)
- Frontmatter structural problems (`validate-wiki.js frontmatter` exit 2)
- Index entries pointing to non-existent pages (`index.dead_rows`)
- Contradictions between pages

### Warnings (should fix)
- Orphan pages with no inbound links
- Stale claims from outdated sources
- Missing pages for frequently referenced topics

### Info (nice to fix)
- Potential cross-references to add
- Data gaps that could be filled
- Index entries that could be more descriptive

For each finding, include:
- **What:** description of the issue
- **Where:** the specific file(s) and line(s)
- **Fix:** what to do about it

## After the Report

Ask the user:
> "Found N errors, N warnings, and N info items. Want me to fix any of these?"

If the user agrees, fix issues and report what changed.

## Log the lint pass

Append to `wiki/log.md`:

    ## [YYYY-MM-DD] lint | Health check
    Found N errors, N warnings, N info items. Fixed: [list of fixes applied].

## When to Lint

- **Implicit**: the Stop hook runs `validate-wiki.js all` at the end of every session and flags structural errors automatically. Lint as a deliberate pass is for the judgment-heavy items below (contradictions, stale claims, suggested cross-references).
- **After every 10 ingests** — catches cross-reference gaps while they're fresh
- **Monthly at minimum** — catches stale claims and orphan pages over time
- **Before major queries** — ensures the wiki is healthy before you rely on it for analysis

## Related Skills

- `/second-brain:ingest` — process new sources into wiki pages
- `/second-brain:query` — ask questions against the wiki
