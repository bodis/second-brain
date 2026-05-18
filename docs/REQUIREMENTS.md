# Second Brain — Blueprint

> This is the genesis document for this project. It describes the pattern, the requirements, and how we implemented it. You can use this as a blueprint to build your own version from scratch, or just install our implementation as a Claude Code plugin (see README.md).

## ORIGIN

Andrej Karpathy posted a thread about using LLMs to build personal knowledge bases — dump raw source material into a folder, let the LLM compile it into a structured wiki, and use Obsidian to browse the whole thing.

https://x.com/karpathy/status/2039805659525644595

A few days later he extended the theory to include a pattern via an idea file that is intentionally vague to allow creativity. The idea file is available here: https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f and also stored locally in `llm-wiki.md`.

---

## THE PATTERN

You end up with three folders:

- **raw/** is your inbox. Articles, papers, notes, transcripts — you dump them here and never think about organizing them.
- **wiki/** is what the LLM builds for you. It reads everything in raw, writes articles, creates topic folders, links concepts together, and maintains an index. You barely touch this folder.
- **output/** is where reports and query results go.

Once it's running, you can ask the LLM questions against your wiki and it'll navigate the files, pull in the relevant material, and answer. No fancy RAG setup needed — just markdown files and a good prompt.

The magic is in the agent config file (CLAUDE.md, AGENTS.md, etc.) at the root of the vault. That's where you tell the LLM how to behave as your librarian — the architecture, operations, page format, and rules it must follow.

---

## WHAT YOU NEED TO BUILD THIS

**Obsidian** — the frontend. It's a markdown editor that treats a folder of .md files like a wiki, with backlinks and a graph view.
> Download it from obsidian.md.

**An AI coding agent** — the LLM that reads sources, writes wiki pages, and maintains everything. Any agent that can read/write files works. You tell it the rules via a config file at the vault root:
- Claude Code → `CLAUDE.md`
- OpenAI Codex → `AGENTS.md`
- Cursor → `.cursor/rules/*.mdc`
- Gemini CLI → `GEMINI.md`

**Obsidian Web Clipper** — a browser extension that saves web articles as clean markdown files directly into your vault's `raw/` folder. This is the primary way to feed source material in.
> https://chromewebstore.google.com/detail/obsidian-web-clipper/cnjifjpddelmedmihgijeibhnjfabmlf

---

## FOUR OPERATIONS

Whether you build this yourself or use our skills, the system has four operations:

**Onboarding** — scaffold the vault structure and generate the agent config file. Create `raw/`, `wiki/` (with subdirectories for sources, entities, concepts, synthesis), and `output/`. Bootstrap `wiki/index.md` and `wiki/log.md`.

**Ingest** — process a raw source into wiki pages. Read the source, create a summary in `wiki/sources/`, create or update entity and concept pages, add wikilinks between related pages, update the index and log. A single source typically touches 10-15 wiki pages.

**Query** — answer questions against the wiki. Read the index to find relevant pages, synthesize an answer with wikilink citations, offer to save valuable results as synthesis pages.

**Lint** — health-check the wiki. Scan for broken wikilinks, orphan pages, contradictions, stale claims, missing cross-references, and data gaps. Report by severity and offer fixes.

---

## THE AGENT CONFIG FILE

The agent config is the brain of the system. It tells the LLM exactly how to behave. The key sections:

- **Architecture** — three directories (raw, wiki, output), wiki subdirectories (sources, entities, concepts, synthesis), two special files (index.md, log.md)
- **Page format** — YAML frontmatter (tags, sources, created, updated) + wikilink syntax
- **Operations** — step-by-step workflows for ingest, query, and lint
- **Rules** — 10 rules governing the LLM's behavior (never modify raw, always update index, etc.)

You can write this by hand (see `llm-wiki.md` for the conceptual foundation) or let our onboarding wizard generate it. The canonical rules live in `skills/onboard/references/wiki-schema.md`.

---

## MULTI-AGENT SUPPORT

The wiki pattern itself is agent-agnostic — it's just markdown files and conventions, and the same rules work in any agent config file. This fork, however, ships as a Claude Code plugin and removes the Codex / Cursor / Gemini config templates that the upstream project carried. If you want to drive the same vault with a different agent, the wiki schema in `skills/onboard/references/wiki-schema.md` is reusable; you'd hand-author the equivalent `AGENTS.md` / `.cursor/rules` / `GEMINI.md` from it.

---

## OPTIONAL TOOLS

These extend what the LLM can do. None are required, but all are recommended as the wiki grows.

**summarize** — summarize links, files, and media from the CLI or Chrome Side Panel. Supports local, paid, and free models.
> `npm i -g @steipete/summarize`

**qmd** — local search engine for markdown files with hybrid BM25/vector search and LLM re-ranking, all on-device. Becomes important as the wiki grows past ~100 pages.
> `npm i -g @tobilu/qmd`

**agent-browser** — browser automation CLI for AI agents. Fast native Rust CLI. Use for web research when native web_search or web_fetch fail.
> `npm i -g agent-browser && agent-browser install`

### Related Projects

**llm-wiki-compiler** — an independent project that compiles raw sources into an interlinked markdown wiki. Early alpha. Listed here for reference and inspiration.
> https://github.com/atomicmemory/llm-wiki-compiler/tree/main

---

## HOW IT ALL FITS TOGETHER

Karpathy's pattern: dump raw sources, let the LLM compile a wiki, browse it in Obsidian.

| Concept | Implementation |
|---|---|
| "Dump raw sources" | `raw/` directory + Obsidian Web Clipper |
| "LLM compiles a wiki" | Ingest operation — reads sources, creates/updates wiki pages, maintains index and log |
| "Browse in Obsidian" | Obsidian reads `wiki/` with backlinks and graph view |
| "Ask questions" | Query operation — searches wiki, synthesizes answers with citations |
| "Maintain quality" | Lint operation — audits for contradictions, orphans, stale claims |
| "Set it up" | Onboarding operation — interactive wizard scaffolds everything |
| "The prompt" | Agent config file generated from wiki-schema rules |

The idea file (`llm-wiki.md`) is the creative seed. This document is the blueprint. The `skills/` directory is the executable implementation — but you could build your own from this blueprint using any LLM and any tooling you prefer.
