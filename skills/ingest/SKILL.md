---
name: ingest
description: >
  Process raw source documents into wiki pages. Use when the user adds
  files to raw/ and wants them ingested, says "process this source",
  "ingest this article", "I added something to raw/", or wants to
  incorporate new material into their knowledge base.
allowed-tools: Bash Read Write Edit Glob Grep
---

# Second Brain — Ingest

Process raw source documents into structured, interlinked wiki pages.

## Tooling

This SKILL drives all source-state operations through `scripts/state-sources.js`. Never hand-edit `wiki/.state/sources.yaml`. Never grep `wiki/log.md` to figure out what's been ingested — `log.md` is a human-readable narrative, not a source of truth.

The tool resolves the vault root by walking up to the nearest `.git/`. Invoke it with the vault as `cwd`:

```bash
node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" <subcommand> [args]
```

## Identify Sources to Process

Determine which files need ingestion:

1. If the user specified one or more files, use those.

2. Otherwise, establish a clean baseline:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" begin
   ```

   This makes a `pre-run baseline` commit if there are uncommitted changes under `wiki/` (typically hand edits the user made between runs). It is a no-op on a clean tree.

3. Ask the tool what changed since the last ingest:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" diff
   ```

   Parse the JSON output. It has three lists:
   - `new`: sources never ingested. Path + content hash.
   - `changed`: sources whose content hash differs from last ingest. Includes `previous_sha256` and `previous_wiki_pages` (the wiki pages this source previously produced, so you can update them in place).
   - `deleted`: sources that were in state but are no longer on disk. Includes `previous_wiki_pages`.

4. For `deleted` entries, surface them to the user with their `previous_wiki_pages` and ask whether to:
   - keep the wiki pages and drop the source from state (`commit --source <path> --deleted`), or
   - delete the wiki pages too (then `commit --source <path> --deleted`).
   Do not auto-prune wiki pages.

5. If `new`, `changed`, and `deleted` are all empty, tell the user there's nothing to do and stop.

## Process Each Source

For each entry in `new` and `changed`, follow this workflow. If the entry is `changed`, before step 1 read each path in `previous_wiki_pages` — the goal is to **update** those existing pages, not create new ones.

### 1. Read the source completely

Read the entire file. If the file contains image references, note them — read the images separately if they contain important information.

### 2. Discuss key takeaways with the user

Before writing anything, share the 3-5 most important takeaways from the source. Ask the user if they want to emphasize any particular aspects or skip any topics. Wait for confirmation before proceeding.

### 3. Create source summary page

Create a new file in `wiki/sources/` named after the source (slugified). Include:

    ---
    tags: [relevant, tags]
    sources: [original-filename.md]
    created: YYYY-MM-DD
    updated: YYYY-MM-DD
    ---

    # Source Title

    **Source:** original-filename.md
    **Date ingested:** YYYY-MM-DD
    **Type:** article | paper | transcript | notes | etc.

    ## Summary

    Structured summary of the source content.

    ## Key Claims

    - Claim 1
    - Claim 2
    - ...

    ## Entities Mentioned

    - [[Entity Name]] — brief context
    - ...

    ## Concepts Covered

    - [[Concept Name]] — brief context
    - ...

### 4. Update entity and concept pages

For each entity (person, organization, product, tool) and concept (idea, framework, theory, pattern) mentioned in the source:

**If a wiki page already exists:**
- Read the existing page
- Add new information from this source
- Add the source to the `sources:` frontmatter list
- Update the `updated:` date
- Note any contradictions with existing content, citing both sources

**If no wiki page exists:**
- Create a new page in the appropriate subdirectory:
  - `wiki/entities/` for people, organizations, products, tools
  - `wiki/concepts/` for ideas, frameworks, theories, patterns
- Include YAML frontmatter with tags, sources, created, and updated fields
- Write a focused summary based on what this source says about the topic

### 5. Add wikilinks

Ensure all related pages link to each other using `[[wikilink]]` syntax. Every mention of an entity or concept that has its own page should be linked.

### 6. Update wiki/index.md

For each new page created, add an entry under the appropriate category header:

    - [[Page Name]] — one-line summary (under 120 characters)

### 7. Update wiki/log.md

`wiki/log.md` is the human-readable narrative. It is no longer parsed for ingest detection — the state file (`wiki/.state/sources.yaml`) is the source of truth. Still append a paragraph per source so the user has a readable trail.

Append:

    ## [YYYY-MM-DD] ingest | Source Title
    Processed source-filename.md. Created N new pages, updated M existing pages.
    New entities: [[Entity1]], [[Entity2]]. New concepts: [[Concept1]].

### 8. Commit the source

Run:

```bash
node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" commit --source <relative-source-path>
```

The tool auto-detects which wiki pages this source's ingest touched (via `git status --porcelain -- wiki/`), updates `wiki/.state/sources.yaml`, stages everything, and makes one git commit named `ingest: <path> → N pages`.

If the source legitimately produced no wiki output (it turned out to be empty / nonsensical / already covered elsewhere), pass `--allow-empty` so it is still recorded and won't appear as `new` next run:

```bash
node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" commit --source <path> --allow-empty
```

If the tool exits with code 6 ("uncommitted non-wiki changes"), it means something outside `wiki/` is dirty (e.g., a user edit to a source file mid-run). Run `state-sources begin` again to roll that into a baseline commit, then retry.

### 9. Report results

Tell the user what was done:
- Pages created (with links)
- Pages updated (with what changed)
- New entities and concepts identified
- Any contradictions found with existing content

## Conventions

- Source summary pages are **factual only**. Save interpretation and synthesis for concept and synthesis pages.
- A single source typically touches **10-15 wiki pages**. This is normal and expected.
- When new information contradicts existing wiki content, **update the wiki page and note the contradiction** with both sources cited.
- **Prefer updating existing pages** over creating new ones. Only create a new page when the topic is distinct enough to warrant its own page.
- Use `[[wikilinks]]` for all internal references. Never use raw file paths.

## What's Next

After ingesting sources, the user can:
- **Ask questions** with `/second-brain:query` to explore what was ingested
- **Ingest more sources** — clip another article and run `/second-brain:ingest` again
- **Health-check** with `/second-brain:lint` after every 10 ingests to catch gaps
