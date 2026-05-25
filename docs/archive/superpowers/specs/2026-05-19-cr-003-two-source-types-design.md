# CR-003 Design — Add structured `src/documentation/` source type

**Status:** Draft, pending user review
**Date:** 2026-05-19
**CR:** [CR-003](../../cr/CR-003-two-source-types.md)
**Conventions:** [docs/cr/conventions.md](../../cr/conventions.md)
**Depends on:** CR-002 (landed; sources.yaml schema already reserves `kind` and `system`)

## 1. Problem

The vault has a single `raw/` folder for all sources. That works for one-off clipped articles. It does not work for structured documentation exports (Confluence, GitHub wiki, internal-docs sites) where:

- The directory structure encodes topic relationships.
- The whole tree gets re-scraped occasionally and may change in bulk.
- The original files are authoritative — already structured by a human.

The user wants structured docs to seed each vault as **base knowledge**, with `raw/` clippings layered on top. Mixing both in `raw/` loses the structural signal and risks the LLM treating an authoritative doc as just another article.

## 2. Goals

- A second source type, `kind: structured`, lives under `src/documentation/<system>/**/*.md`.
- The state-sources tool walks both `raw/` and `src/documentation/` and emits `kind` + (for structured) `system` per entry.
- Ingest applies **light-touch handling** to structured sources: no `wiki/sources/<...>.md` summary page; only entity/concept pages are created/updated and they cite the original `src/documentation/` path via wikilink.
- Query prefers citing the original `src/documentation/` path for structured-doc questions.
- Onboarding scaffolds `src/documentation/` as a tracked-but-empty directory.

## 3. Non-goals

- Auto-scraper. The user already runs an external `doc-downloader` project that drops files into `src/documentation/<system>/`. The vault has zero scraping responsibility.
- Per-system metadata files (`src/documentation/<system>/.meta.yaml`). YAGNI — the only stated consumer (scraper) lives outside this codebase.
- Schema bump. `sources.yaml schema_version` stays at `1`. The `kind` and `system` fields were reserved at v1; CR-003 just starts populating them.
- Move detection. Renames between scrapes appear as `deleted + new`. Acceptable.
- Other `src/` subdirectories. Only `src/documentation/` is recognized. Other folders under `src/` (or files directly under `src/documentation/` without a system subdir) are silently ignored.
- Section-aware ingest (treating a docs subtree as a topical group). Out of scope; future CR-005 reorganize concern if needed.
- Updates to lint. The existing checks work fine with light-touch — no `wiki/sources/` page for structured means the "every wiki/sources/ file is indexed" check has no false positive.

## 4. State schema (no version change)

Existing `wiki/.state/sources.yaml` schema stays at `schema_version: 1`. CR-003 starts populating two existing fields:

```yaml
schema_version: 1
generated_by: scripts/state-sources.js
excludes:
  - raw/assets/
sources:
  - path: raw/some-article.md
    kind: generic
    sha256: 6f1d...
    bytes: 4231
    mtime: 2026-05-19T10:23:11Z
    ingested_at: 2026-05-19T10:25:00Z
    wiki_pages:
      - wiki/sources/some-article.md
      - wiki/entities/foo.md
  - path: src/documentation/confluence/api/auth.md
    kind: structured
    system: confluence                  # only set when kind=structured
    sha256: 9b4a...
    bytes: 1822
    mtime: 2026-05-19T09:00:00Z
    ingested_at: 2026-05-19T11:00:00Z
    wiki_pages:
      - wiki/entities/oauth.md
      - wiki/concepts/api-authentication.md
```

Field rules update:

- `sources[].system` — required when `kind: structured`, absent when `kind: generic`. Derived from the first path segment under `src/documentation/`.
- `sources[].wiki_pages` — for structured sources, this list will typically NOT contain a `wiki/sources/<...>.md` entry (light-touch). It will contain only the entity/concept pages the ingest touched.

The two helpers `readSourcesYaml` and `writeSourcesYaml` in `state-sources.js` already preserve unknown fields, so no code change is needed to support `system`. The constructors that build entries (in `cmdCommit` and `walkSources`) need to populate `kind` and conditionally `system`.

## 5. Walker changes

### 5.1 New walk targets

`walkSources(vault, excludes)` in `skills/ingest/scripts/state-sources.js` currently walks only `raw/`. It will be extended to also walk `src/documentation/<system>/**/*` with the following rules:

- For each immediate subdirectory of `src/documentation/` (e.g., `confluence`, `github-wiki`), recurse into it. The subdirectory name becomes the `system` value for every entry produced from that subtree.
- Files directly under `src/documentation/` (no `<system>/` parent) are **skipped with an info-level stderr log**: `info: skipping src/documentation/<file>: no <system>/ subdirectory`.
- Hidden files (`.startsWith('.')`) and broken stats are skipped (same as the current `raw/` walker).
- `src/documentation/` may not exist (vault never received any structured docs) — that's a no-op, not an error.
- Anywhere under `src/` outside `documentation/` is ignored (per Non-goals).

### 5.2 Entry shape from the walker

The walker emits `Source`-shaped objects with `kind` and (when applicable) `system`:

```javascript
// raw/ entry
{ path: 'raw/foo.md', kind: 'generic', sha256, bytes, mtime }
// src/documentation/ entry
{ path: 'src/documentation/confluence/api/auth.md', kind: 'structured', system: 'confluence', sha256, bytes, mtime }
```

The `system` field is omitted for generic entries (cleaner than always emitting `null`).

### 5.3 Excludes semantics

The existing `excludes:` config in `sources.yaml` already filters by path prefix. CR-003 changes nothing here. A user can add structured-tree excludes manually if needed (e.g., `excludes: ["raw/assets/", "src/documentation/internal-docs/drafts/"]`).

The default `excludes:` list stays as `["raw/assets/"]`. No automatic exclude is added for structured trees — if a system wants its own assets folder, the user adds it explicitly.

## 6. `diff` output enrichment

The JSON shape gains an optional `system` field on entries where `kind === 'structured'`:

```json
{
  "new": [
    { "path": "raw/x.md", "kind": "generic", "sha256": "...", "bytes": 123, "mtime": "..." },
    { "path": "src/documentation/confluence/api/auth.md", "kind": "structured", "system": "confluence", "sha256": "...", "bytes": 1822, "mtime": "..." }
  ],
  "changed": [
    {
      "path": "src/documentation/github-wiki/setup.md", "kind": "structured", "system": "github-wiki",
      "sha256": "...", "bytes": 456, "mtime": "...",
      "previous_sha256": "...", "previous_wiki_pages": ["wiki/concepts/setup.md"]
    }
  ],
  "deleted": [
    { "path": "src/documentation/confluence/api/old.md", "kind": "structured", "system": "confluence",
      "previous_wiki_pages": ["wiki/entities/old-api.md"] }
  ]
}
```

Two additions:
- `new` and `changed` entries for structured sources carry `kind: structured` and `system: <name>`.
- `deleted` entries gain `kind` and (for structured) `system`, derived from the prior `sources.yaml` entry. This lets the SKILL prompt the user with system context ("delete entries from confluence/api?").

For generic entries, the `kind: generic` is now also emitted on `deleted` (today it's only on `new`/`changed`). That's a small uniformity improvement — same field on all three lists.

## 7. `commit` changes

`cmdCommit` builds an entry record from the source path's prefix:

- Path starts with `raw/` → `kind: 'generic'`, no `system`.
- Path starts with `src/documentation/<system>/` → `kind: 'structured'`, `system: <first segment>`.
- Anything else → error out with exit code 1, message `source path "X" is not under raw/ or src/documentation/`.

The rest of `cmdCommit` is unchanged: same git-status auto-detection of wiki pages, same per-source commit, same exit codes.

The commit message stays `ingest: <path> → N pages` regardless of kind.

## 8. Ingest SKILL changes (light-touch)

`skills/ingest/SKILL.md` gains a new section explaining the two source types and how the per-source loop branches.

### 8.1 New section: "Source types"

Insert after the existing `## Tooling` section, before `## Identify Sources to Process`:

```markdown
## Source types

The state tool reports two source kinds in its `diff` output:

- **`kind: generic`** — files under `raw/`. One-off articles, transcripts, notes. The author is usually anonymous or one-off. **Treatment:** produce a `wiki/sources/<name>.md` summary page AND extract entities/concepts.
- **`kind: structured`** — files under `src/documentation/<system>/...`. Authoritative exported docs (Confluence, GitHub wiki, internal-docs). The author already structured the content. **Treatment:** light-touch — DO NOT produce a `wiki/sources/<...>.md` summary page. The original IS the canonical source. Extract entities/concepts mentioned in it and cite back to the original path.
```

### 8.2 Per-source loop branching

Today's per-source loop has eight steps (1-8) that create `wiki/sources/`, update entities/concepts, link, update index, log, commit. For structured sources, skip the `wiki/sources/` step and adjust the citation format.

Update the section heading `## Process Each Source` and its preamble to:

```markdown
## Process Each Source

For each entry in `new` and `changed`, follow this workflow. The flow branches on `kind`:

- **`generic`**: full workflow — create a `wiki/sources/<name>.md` summary AND entity/concept pages.
- **`structured`**: light-touch — SKIP step 3 ("Create source summary page"). The original `src/documentation/...` file is the canonical page. Steps 1–2 and 4–9 still apply, but every reference to the source uses its full vault-relative path.

If the entry is `changed`, before step 1 read each path in `previous_wiki_pages` — the goal is to **update** those existing pages, not create new ones.
```

### 8.3 Citation format

In the existing "Create source summary page" step (step 3), the source frontmatter is:

```yaml
sources: [original-filename.md]
```

For structured sources, when an entity/concept page cites the source in its frontmatter, the value is the **full vault-relative path**:

```yaml
sources: [src/documentation/confluence/api/auth.md]
```

This matches the path key in `sources.yaml`. In prose, the SKILL writes wikilinks against the original file: `[[src/documentation/confluence/api/auth]]` (Obsidian resolves path-style wikilinks).

Add this clarifier to step 4 ("Update entity and concept pages"):

```markdown
**Citation format:**
- Generic source: `sources: [original-filename.md]` (just the filename, matches today's behavior).
- Structured source: `sources: [src/documentation/<system>/.../file.md]` (full vault-relative path).
- In prose, both forms use wikilink syntax against the source's name or path.
```

### 8.4 Allow-empty for structured

A re-scraped structured doc might change only formatting (e.g., whitespace) with no real new information. The ingest LLM is allowed to decide "nothing to update" and run `commit --source <path> --allow-empty` to advance the state without changing the wiki. Same flow as for rubbish generic sources.

### 8.5 Bulk re-scrape note

When the diff output lists many `changed` structured entries from the same `system` (e.g., 50 confluence pages re-scraped), the SKILL should still process them one at a time per the existing loop. Avoid the temptation to batch — the per-source git commits remain the audit trail. A short note in the SKILL acknowledges this is normal and not a bug.

## 9. Query SKILL changes

`skills/query/SKILL.md` today says:

> Only go to files in `raw/` as a last resort.

Replace that with:

```markdown
### 4. Check originals for verification or depth

If the wiki pages don't fully answer the question or you need exact wording:

- **Structured sources** (`src/documentation/<system>/...`): these are authoritative. Read them directly when you need precise facts or quotes. Cite them by full vault-relative path: `[[src/documentation/confluence/api/auth]]`.
- **Generic sources** (`raw/...`): prefer the `wiki/sources/<name>.md` summary when the user wants the gist. Only go to the original `raw/` file if the summary lacks detail. Cite either form.
```

The "Search the wiki first" convention stays. The order is: index → wiki pages → originals (structured first for facts, raw only when summary is insufficient).

## 10. Onboarding changes

`skills/onboard/scripts/onboarding.sh` gains one new directory scaffold:

```bash
mkdir -p "$VAULT_ROOT/src/documentation"
if [ ! -f "$VAULT_ROOT/src/documentation/.gitkeep" ]; then
  : > "$VAULT_ROOT/src/documentation/.gitkeep"
fi
```

Match the `wiki/.state/.gitkeep` pattern added in CR-002. The wizard does NOT prompt for system names. Users (or doc-downloader) drop files in later.

A brief note is added to `skills/onboard/SKILL.md` post-scaffold step 3 (Create directory structure) explaining what `src/documentation/` is for: "Structured docs from external sources (e.g., the doc-downloader project). Drop trees of `.md` files under `src/documentation/<system>/...` and they'll be ingested with `kind: structured`."

## 11. CR-002 update markers

CR-002 already reserved `kind` and `system` in the v1 schema, so no migration is needed. Existing entries that have only `kind: generic` (no `system`) are valid as-is. No backfill script. Future ingests on the same vault simply add structured entries alongside the existing generic ones.

## 12. Tests

### 12.1 Automated

Extend `tests/test_state_sources.sh` with these new cases (numbering continues from the existing 11):

12. **Walker discovers structured docs.** A vault with `src/documentation/confluence/api/auth.md` produces a `new` entry with `kind: structured`, `system: 'confluence'`.
13. **Walker handles nested structured paths.** A file at `src/documentation/confluence/space/team/page.md` is found and gets `system: 'confluence'` (first segment under `documentation/`, not deeper).
14. **Walker mixes raw and structured.** Both `raw/x.md` and `src/documentation/conf/y.md` appear in `new`, each with the correct `kind`.
15. **Walker skips files directly under `src/documentation/`.** A file at `src/documentation/loose.md` (no system subdir) is NOT included in `diff`'s output and produces an info stderr message.
16. **Walker ignores non-documentation `src/` content.** A file at `src/notes/foo.md` is NOT included in `diff`'s output (only `src/documentation/` is recognized).
17. **Commit on a structured source records `kind` and `system`.** After `commit --source src/documentation/conf/api/auth.md`, the YAML entry has `kind: structured` and `system: conf`.
18. **Commit rejects paths outside `raw/` and `src/documentation/`.** Calling `commit --source notes/foo.md` exits with code 1.
19. **Re-scrape detection (changed).** A structured source whose content changes surfaces in `diff.changed` with `kind`, `system`, `previous_sha256`, `previous_wiki_pages`.
20. **Deleted structured entry carries `kind` and `system`.** A removed structured source appears in `diff.deleted` with the prior `kind` and `system` values.

The existing `tests/test_onboarding.sh` gains one assertion: `src/documentation/.gitkeep` is created.

### 12.2 Manual smoke checklist (in addition to CR-002's)

1. **Fresh vault has `src/documentation/`.** Onboard a vault. Confirm `src/documentation/.gitkeep` is committed.
2. **First structured ingest.** Create `src/documentation/confluence/api/auth.md` with a few paragraphs. Run `/second-brain:ingest`. Confirm:
   - Diff lists it as `new` with `kind: structured, system: confluence`.
   - SKILL does NOT create `wiki/sources/auth.md`.
   - SKILL creates entity/concept pages whose frontmatter cites `sources: [src/documentation/confluence/api/auth.md]`.
   - One git commit lands: `ingest: src/documentation/confluence/api/auth.md → N pages`.
3. **Re-scrape.** Edit one byte of the same file. Re-run ingest. Confirm SKILL detects `changed`, updates the cited entity/concept pages, no new summary page appears.
4. **Mixed batch.** Drop one `raw/article.md` and one `src/documentation/github-wiki/intro.md`. Run ingest. Confirm both are processed: article gets a `wiki/sources/article.md` summary, the github-wiki page does NOT.
5. **Query prefers structured.** Ask a question that should be answered by the confluence doc. Confirm query SKILL cites `[[src/documentation/confluence/api/auth]]` directly.

## 13. Risks and tradeoffs

- **Wiki structure asymmetry.** Generic sources have summary pages; structured don't. Users who like browsing `wiki/sources/` for everything will see only generic entries. Mitigation: index already lists entities/concepts produced by structured sources, so they ARE discoverable — just not via a per-source landing page.
- **Path-form wikilinks for structured citations.** `[[src/documentation/confluence/api/auth]]` is verbose. Obsidian also supports short forms (`[[auth]]` resolves to the file by name if unique). The SKILL prompt will write full paths for clarity; users can collapse them when editing.
- **Bulk re-scrapes producing many `changed` entries.** A 50-file confluence re-scrape creates 50 commits and 50 trips through the per-source loop. Each commit is small, so this is acceptable. CR-004 might add a "batch commit" hook later, but that's out of scope here.
- **Move detection blind spot.** If doc-downloader renames a structured doc between scrapes (same content, new path), CR-002's hash-based diff sees it as `deleted + new`. The SKILL will dutifully re-ingest and prompt the user about the orphan. Acceptable for now; doc-downloader is unlikely to rename frequently.
- **Files directly under `src/documentation/` silently ignored.** Users could be confused if they drop `src/documentation/notes.md` and nothing happens. The info-level stderr log helps debugging but is not visible to a user running the SKILL. CR-004's hooks could surface it; for now, the SKILL's behavior is the documentation.

## 14. Open questions deferred

- Should structured docs themselves appear in `wiki/index.md` under a new "Documentation" category? Not in CR-003. They already live under `src/documentation/` and are navigable via Obsidian's file tree. Lint won't flag them as orphans because lint's orphan check scans `wiki/` only.
- Section-level synthesis (treat `src/documentation/confluence/api/` as a topic group). Reserved for CR-005 reorganize.
- Per-system `.meta.yaml` files. Reserved until a concrete use case emerges (likely never inside this codebase given doc-downloader is external).

## 15. Out of scope (carried from CR-003)

- Auto-scraper. Lives in the separate `doc-downloader` project.
- Reorganization workflows that span structured + generic (CR-005).
- Other `src/` subdirectories beyond `documentation/`.
