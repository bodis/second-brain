# Second Brain — User Guide

A personal knowledge base where you curate raw material and the LLM compiles it into an interlinked wiki.

> **Compatibility.** Second Brain v1.0 is a **Claude Code plugin**. It only runs under Claude Code (Anthropic's official CLI / desktop / web client / IDE extensions). Other agents (OpenAI Codex, Cursor, Gemini CLI, etc.) are not supported — porting would require rewriting the skill manifests and hook bindings for that agent's plugin format.
> The resulting **vault**, on the other hand, is just a folder of markdown — once it's populated, any tool that reads markdown can use it (see Level 1 below).

For how the system is built or how to extend it, see [ARCHITECTURE.md](./ARCHITECTURE.md).

---

## Pick your level

| Level | Read time | What you'll be able to do |
|---|---|---|
| **[Level 1 — Just use it](#level-1--just-use-it)** | ~1 minute | Install, drop in articles, browse the resulting wiki in Obsidian or query it from any agent |
| **[Level 2 — Live with it](#level-2--live-with-it)** | ~5 minutes | Add structured doc exports, use the dashboard, resolve contradictions, run health checks |
| **[Level 3 — All the features](#level-3--all-the-features)** | ~15 minutes | Stale-page refresh, structural reorganisation, headless cron mode, freshness warnings, MCP setup |

Most people stop at Level 1 or 2. Level 3 unlocks scale (hundreds of sources, unattended operation), but you don't need any of it to get value.

---

## Level 1 — Just use it

> The 60-second version. Capture articles, let the LLM compile a wiki, browse the result.

### Install (one time)

You need [Claude Code](https://claude.ai/code), [Obsidian](https://obsidian.md), and `git`.

From inside the folder that will become your vault:

```bash
git clone https://github.com/bodis/second-brain.git .claude/plugins/second-brain
(cd .claude/plugins/second-brain && npm install --omit=dev)
claude --plugin-dir .claude/plugins/second-brain
```

Then in the Claude Code session that opens:

```
/second-brain:onboard
```

The wizard asks a handful of questions (vault name, location, topic, install scope) and scaffolds the directories. After it finishes, future sessions in this folder auto-load the plugin — just `cd <vault> && claude`.

(Alternative: install once into your home dir so any project picks it up. See [README.md](../README.md) for that option.)

### Use it

1. **Clip articles** into the vault's `raw/` folder. The easiest way is the [Obsidian Web Clipper](https://chromewebstore.google.com/detail/obsidian-web-clipper/cnjifjpddelmedmihgijeibhnjfabmlf) — point it at your vault's `raw/` folder and clipping is two clicks.
2. **Ingest** by running:
   ```
   /second-brain:ingest
   ```
   The LLM reads the new files, discusses the key takeaways with you, and writes structured wiki pages with cross-references. Each source typically produces 10–15 linked pages.
3. **Browse** in Obsidian. Open the vault folder as an Obsidian vault and explore `wiki/`. Follow `[[wikilinks]]`, open the graph view, read `wiki/index.md` as a table of contents.

That's the whole loop. Clip → ingest → browse. Do it 100 times and you have a real knowledge base.

### What you end up with

Just markdown. The vault is portable:

- **Open it in Obsidian.** Browse, search, follow links, use the graph view. This is the default.
- **Read the files with any tool.** Spotlight, `grep`, VS Code, your favourite text editor — `wiki/` is plain `.md`.
- **Attach an MCP server to it.** The vault is a folder of markdown, which is exactly what markdown-aware MCP servers (e.g. [qmd](https://github.com/tobi/qmd)) expose to other agents. Once an MCP is pointed at your vault, any MCP-capable client (Claude Desktop, other Claude Code sessions, third-party agents) can search and read your wiki without going through this plugin. See [Level 3](#mcp-access) for setup.

That's the design: the plugin's job is to *build* and *maintain* the wiki. Once it's built, the wiki belongs to you and works without the plugin.

→ Want to go further? Read **[Level 2](#level-2--live-with-it)**.

---

## Level 2 — Live with it

> When your vault has dozens of sources, you'll want: a way to add structured doc exports, a single morning check, and a way to resolve the inevitable contradictions.

Everything from Level 1 still applies. Level 2 adds three things.

### 1. Two kinds of sources

Second Brain treats two source folders differently:

| Folder | What goes here | How it's ingested |
|---|---|---|
| `raw/` | Articles, papers, transcripts, notes, podcasts. One-off material. | LLM produces a `wiki/sources/<name>.md` summary AND extracts entities/concepts into separate pages. |
| `src/documentation/<system>/` | Structured exports — Confluence, GitHub Wiki, internal docs sites, etc. | LLM treats the original as authoritative — **no** summary page is created. It extracts entities/concepts and cites back to the source path. |

So if you have a 200-page Confluence export from work, drop the whole tree under `src/documentation/confluence/...` and `/second-brain:ingest` will extract entities and concepts without duplicating the documentation. Combine this with clipped articles in `raw/` to layer your own notes on top of authoritative base knowledge.

External scrapers can write directly into `src/documentation/<system>/` — bulk re-scrapes are handled fine; ingest processes each changed file individually for a clean audit trail.

### 2. The morning check — `/second-brain:status`

One dashboard for everything pending:

```
sources:        5 new, 2 changed → run /second-brain:ingest
contradictions: 3 unresolved      → run /second-brain:status reconcile
lint:           0 errors, 3 warnings
review:         12 changes since last accept → /second-brain:status review
```

You don't need to remember the other skills — `/second-brain:status` tells you which one is needed next. This becomes the only command you reach for routinely.

### 3. Resolving contradictions — `/second-brain:status reconcile`

When two sources disagree, second-brain doesn't pick a winner silently. It surfaces the pair to you with both excerpts and rationale, and you decide:

```
[c-0042] Claim: <one-line claim>
  A. wiki/concepts/foo.md
     "exact quote from page A"
     source: article-2024-03.md
  B. wiki/concepts/bar.md
     "exact quote from page B"
     source: paper-2025-08.md
  Rationale: <one-line rationale from the judge pass>
Pick (a) A · (b) B · (c) Accept disagreement · (d) Defer · (s) Stop walking
```

Pick A, pick B, accept that both are valid, or defer. Each choice produces one git commit; the losing page gets rewritten in place to match the winning assertion. The pipeline is two stages — a cheap deterministic scan finds candidate pairs; an LLM judge filters real conflicts from coincidental adjacency — so by the time you see something, it's worth your attention.

### 4. Health check — `/second-brain:lint`

Run this every ~10 ingests or monthly. It:

- finds broken `[[wikilinks]]` and orphan pages,
- enqueues any new contradiction candidates for the next judge pass,
- enqueues any newly-stale pages for the next judge pass (Level 3),
- reports missing pages and suggested cross-references,
- offers to fix index inconsistencies.

The deterministic part also runs automatically at the end of every Claude Code session (via a `Stop` hook), so structural breakage is caught for free without you running `lint`.

### 5. Asking questions — `/second-brain:query`

```
/second-brain:query "what does my wiki say about X?"
```

The LLM reads the index, drills into relevant pages, follows wikilinks, and answers with `[[wikilink]]` citations. If the answer produces something reusable (a comparison, an analysis, a new connection), it offers to save the result as `wiki/synthesis/<topic>.md` so it compounds back into the knowledge base.

### Level 2 cadence

| Cadence | Action |
|---|---|
| Whenever you've captured something | `/second-brain:ingest` |
| Once a morning | `/second-brain:status` |
| As needed | `/second-brain:query` |
| When the dashboard has contradictions | `/second-brain:status reconcile` |
| Every ~10 ingests or monthly | `/second-brain:lint` |

→ Want to go further? Read **[Level 3](#level-3--all-the-features)**.

---

## Level 3 — All the features

> Stale-page review, structural reorganisation, hands-off cron operation, freshness warnings on queries, MCP access. Use these when the vault grows beyond a few hundred sources or when you want it to run mostly unattended.

### Stale-page review — `/second-brain:status refresh`

Pages from 2 years ago that newer sources have moved past show up under `staleness:` on the dashboard. Walk them with:

```
/second-brain:status refresh
```

For each flagged page, pick one:

- **(R) Refresh** — the LLM has already drafted a rewrite based on newer sources; this swaps the page in atomically with post-write validation and auto-revert on failure.
- **(A) Archive** — move the page to `archive/`; leave a stub redirect.
- **(H) Historical** — keep the page; mark it as a snapshot of a moment with a `since:` date. Future queries will warn that this page is historical.
- **(D) Defer** — park for later.
- **(S) Skip** — make no change; move on.

Same two-stage architecture as contradictions: a cheap deterministic scan (age + count of newer overlapping sources) flags candidates; an LLM judge pass classifies them as `stale` / `drifting` / `fresh-but-isolated` / `false-positive`; the user only sees real stale or drifting pages.

### Freshness warnings on `/second-brain:query`

When you ask a question, the query skill checks each cited page against the staleness state and any `lifecycle:` frontmatter. If anything's flagged, you get a one-line callout:

> Note: this answer cites 1 historical page (2024-05) and 1 page flagged stale-high. Newer information may exist.

You still get the answer — just with the freshness caveat in front, so you know to dig deeper if it matters.

### Structural reorganisation — `/second-brain:reorganize`

When the wiki has grown lumpy (same topic in three places, drifted categories, missing parent concepts), run a guided refactor:

```
/second-brain:reorganize "consolidate AI-safety pages"
/second-brain:reorganize "audit redundant source-summaries"
/second-brain:reorganize "type the relations on these concept pages"
/second-brain:reorganize "recategorise drifted pages"
```

Three phases:

1. **Propose** — no file changes. The script returns candidates with deterministic rationale (shared wikilinks, synthesised-by-N-sources, etc.); the LLM filters by your direction; you see a numbered list.
2. **Confirm** — reply `all`, `1,3`, `none`, etc. The script makes a baseline commit you can `git reset --hard` back to.
3. **Apply** — one git commit per move, with per-move `validate-wiki` and auto-revert on structural failure. File renames, link rewrites, frontmatter edits, and index sync are all mechanised.

Cadence: monthly at minimum, or any time you notice structural debt. Judgment-heavy — never on a schedule.

### Headless mode (cron)

For unattended operation. The pattern:

```bash
# Hourly: ingest new sources, judge anything new.
0 * * * * cd /path/to/vault && {
  STATUS=$(node "$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
  NEW=$(echo "$STATUS" | jq '.sources.new + .sources.changed')
  if [ "$NEW" -gt 0 ]; then
    claude --headless -p "/second-brain:ingest"
  fi
  [ "$(echo "$STATUS" | jq '.contradictions.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:status reconcile --judge-only"
  [ "$(echo "$STATUS" | jq '.staleness.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:status refresh --judge-only"
}
```

What runs headless:

- **Ingest** — new sources get processed without you in the loop (no discussion phase).
- **`--judge-only` passes** — drain `unjudged` candidates into verdicts (an LLM verdict is not a user action).

What stays interactive:

- Picking a side on a contradiction.
- Deciding what to do with a stale page.
- Reorganising structure.

So the morning ritual collapses to: `/second-brain:status`, walk whichever queue has items, `/second-brain:status accept` to clear the inbox.

Full setup with logging, the `accept` flow, and the `since-review.yaml` durable inbox: [install/headless-driving.md](./install/headless-driving.md).

### MCP access

The vault is a folder of markdown. Any markdown-aware MCP server can expose it to other agents:

- **[qmd](https://github.com/tobi/qmd)** — local search engine with hybrid BM25/vector search and LLM re-ranking, fully on-device. Ships both a CLI (`qmd search ...`) and an MCP server. The onboarding wizard offers to install it; `/second-brain:query` uses it automatically when present.
- **Generic markdown MCP servers** (mcp-obsidian, etc.) — point at the vault folder and any MCP-capable client (Claude Desktop, third-party agents) can search and read your wiki.

Setup details depend on the MCP server and the client; check the server's own docs for the exact configuration block to add to your client's MCP settings.

The key point: **the wiki's value is decoupled from this plugin.** The plugin builds and maintains the vault; once built, you can query it from anywhere markdown can be read.

### Tips, image handling, and edge cases

- **Images.** In Obsidian → Settings → Files and links → Attachment folder path: `raw/assets/`. After clipping an article, run "Download attachments for current file" to localise images. The LLM can then read images directly when ingesting.
- **`qmd` for large vaults.** Past ~100 wiki pages, install qmd (`npm i -g @tobilu/qmd`) — `/second-brain:query` switches to it automatically.
- **The graph view is your best diagnostic.** Hub pages, orphans, clusters — you'll see structural problems in Obsidian's graph view before lint does.
- **Save good queries as synthesis.** The skill prompts you; say yes. This is what makes the wiki *compound*.
- **External scrapers and `src/documentation/`.** If you have a scraper that periodically re-pulls a Confluence space, just write into `src/documentation/<system>/`. Bulk re-scrapes are fine — ingest processes each changed file individually.
- **Re-running onboard.** Safe — it aborts cleanly if the vault is already scaffolded. For a fresh start, delete the vault folder and re-run.
- **Broken wikilinks after renames.** Use `/second-brain:reorganize` (option `move-page`) — it rewrites every inbound link atomically. Hand-renaming files in Obsidian and then running `/second-brain:lint` works too.

### Full skill reference

For completeness:

| Skill | Sub-flows | Owns |
|---|---|---|
| `/second-brain:onboard` | greenfield / in-place | vault scaffolding, agent config, plugin registration |
| `/second-brain:ingest` | (interactive or headless) | turns raw + structured sources into wiki pages |
| `/second-brain:query` | (interactive) | answers questions with citations; freshness warnings |
| `/second-brain:lint` | (interactive) | deep audit; triggers contradiction + staleness candidate scans |
| `/second-brain:reorganize` | propose / confirm / apply | structural moves with per-move auto-revert |
| `/second-brain:status` | (default), `review`, `accept`, `reconcile [--judge-only]`, `refresh [--judge-only]` | dashboard + inbox + interactive walks + cron entry points |

---

## Going beyond

- The architecture, state files, and how to extend: [ARCHITECTURE.md](./ARCHITECTURE.md)
- The conceptual seed (Karpathy's LLM-wiki pattern): [llm-wiki.md](./llm-wiki.md)
- Origin story and blueprint: [REQUIREMENTS.md](./REQUIREMENTS.md)
- Cron / headless setup: [install/headless-driving.md](./install/headless-driving.md)
- Pre-1.0 design history (CRs, plans, specs): [archive/](./archive/)
