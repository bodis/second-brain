# CR-003 — Add structured `src/documentation/` source type alongside generic `raw/`

**Depends on:** CR-002.

## Problem

Today the vault has a single `raw/` folder. Every file is treated identically. That works for clipped articles, where neighboring files in the folder are unrelated. It does **not** work for documentation exports (Confluence, GitHub wiki, internal docs sites) where:

- The directory structure encodes topic relationships (`src/documentation/confluence/api/auth.md` is part of an "API auth" section).
- Neighbor files share context.
- The whole tree gets re-scraped occasionally and may change in bulk.
- The original files are more authoritative than generic-raw ones, because they were already structured by someone.

## Motivation

The user wants to seed each vault with structured documentation that acts as **base knowledge**, then layer their own clipped articles + notes on top via `raw/`. Mixing both in `raw/` loses the structural signal and risks the LLM treating an authoritative doc as just another article.

## Proposed approach

Layout (also in [conventions.md §6](./conventions.md)):

```
vault/
├── raw/                                    # kind=generic
└── src/
    └── documentation/
        └── <system>/                       # confluence, github-wiki, internal-docs
            └── ...arbitrary nested dirs.../*.md
```

State changes (CR-002 schema already accommodates this):

- Each entry in `wiki/.state/sources.yaml` carries `kind: generic | structured`.
- `structured` entries also have `system: <system-name>` and preserve the relative path under `src/documentation/<system>/...`.

SKILL changes:

- **Ingest** (`ingest/SKILL.md`):
  - Generic sources: today's flow — write a per-source summary, extract entities/concepts, cross-link.
  - Structured sources: TBD during plan. Two candidate handlings to pick from:
    1. **Light-touch.** Don't write a `wiki/sources/<...>.md` page; instead extract entities/concepts and link them to the original `src/documentation/...` path via wikilinks. The source IS the wiki page.
    2. **Symmetric.** Write the same per-source summary, but tag it with `kind: structured` so lint/reorganize treat it as derivative of an authoritative source.
- **Query** (`query/SKILL.md`): prefer citing `src/documentation/` paths over summary pages for structured-doc questions (the original is more accurate than our summary).
- **Onboard** (`onboard/SKILL.md`): create `src/documentation/` during scaffold. Don't pre-seed any `<system>/` subfolder — leave that to the user.
- **State script** (`state-sources.sh` from CR-002): extend `scan` and `diff` to walk both `raw/` and `src/documentation/`.

## Open questions

- **Light-touch vs symmetric handling** (above). Light-touch is simpler and preserves the "original is more relevant" principle, but it bifurcates the wiki structure. Symmetric is uniform but produces redundant summaries of already-good docs.
- Does `src/documentation/<system>/` need its own per-system metadata (e.g. `src/documentation/confluence/.meta.yaml` describing the source URL, last scrape time)? Probably yes — let CR-003's plan answer it.
- Where does the auto-scraper live? Not in this CR. This CR only handles *storage* + *ingest awareness*. The scraper is a separate future CR.
- If a structured doc's content moves between paths between scrapes, hash-only detection sees "deleted + new" instead of "moved". Acceptable for now? Recommend: yes.

## Out of scope

- Auto-scraper implementation.
- Reorganizing the wiki because structured docs introduced new concepts (CR-005).
- A `src/` subdirectory other than `documentation/` (we're not pre-defining other source kinds).
