---
name: onboard
description: >
  Set up a new Obsidian knowledge base with the LLM Wiki pattern. Use when
  the user wants to create a second brain, initialize a vault, set up a
  personal knowledge base, or says "onboard". Guides through an interactive
  wizard to configure vault name, location, domain, and tooling.
allowed-tools: Bash Read Write Glob Grep
---

# Second Brain — Onboarding Wizard

Set up a new Obsidian knowledge base using the LLM Wiki pattern. The LLM acts as librarian — reading raw sources, compiling them into a structured interlinked wiki, and maintaining it over time.

## Prerequisites

Verify before starting the wizard:

- `git --version` succeeds (required at runtime — the vault is a git repo).
- `node --version` reports v18 or newer.
- `npm --version` succeeds (used once during scaffold to install the plugin's runtime dep).

If any check fails, stop and ask the user to install the missing tool.

## Wizard Flow

Guide the user through these 5 steps. Ask ONE question at a time. Each step has a sensible default — the user can accept it or provide their own value.

### Step 1: Vault Name

Ask:
> "What would you like to name your knowledge base? This will be the folder name."
> Default: `second-brain`

Accept any user-provided name. This becomes the folder name and the title in the agent config.

### Step 2: Vault Location

Ask:
> "Where should I create it? Give me a path, or I'll use the default."
> Default: `~/Documents/`

Accept any absolute or relative path. Resolve `~` to the user's home directory. The final vault path is `{location}/{vault-name}/`.

### Step 3: Domain / Topic

Ask:
> "What's this knowledge base about? This helps me set up relevant tags and describe the vault's purpose."
>
> Examples: "AI research", "competitive intelligence on fintech startups", "personal health and fitness"

Accept free text. Use this to:
- Write a one-line domain description for the agent config
- Generate 5-8 suggested domain-specific tags

### Step 4: Settings Scope

Ask:
> "Where should I register this plugin so it auto-loads next time?"
>
> (a) Just this vault → writes `<vault>/.claude/settings.json` *(default)*
> (b) All my projects → merges into `~/.claude/settings.json`
> (c) Skip — I'll handle this manually

### Step 5: Optional CLI Tools

Ask:
> "These tools extend what the LLM can do with your vault. All optional but recommended:"
>
> 1. **summarize** — summarize links, files, and media from the CLI
> 2. **qmd** — local search engine for your wiki (helpful as it grows)
> 3. **agent-browser** — browser automation for web research
>
> "Install all, pick specific ones (e.g. '1 and 3'), or skip?"

## Post-Wizard: Scaffold the Vault

After collecting all answers, execute these steps in order:

### 1. Initialize git in the vault

If the vault directory is not already a git repo, run:

```bash
(cd "$VAULT_PATH" && git init -q)
```

The vault must be a git repo because the state tooling (`state-sources`) uses git to detect ingest changes. If `git init` fails, stop and report the error.

### 2. Install the plugin's runtime dependency

The plugin needs `js-yaml` (declared in the plugin's repo-root `package.json`). Resolve `$CLAUDE_PLUGIN_ROOT` and run:

```bash
(cd "$CLAUDE_PLUGIN_ROOT" && [ -d node_modules/js-yaml ] || npm install --omit=dev)
```

This is a one-time bootstrap. If it fails because npm is missing, fall back to telling the user how to install manually: `cd <plugin-root> && npm install --omit=dev`.

### 3. Create directory structure

Run the onboarding script, passing the full vault path:

```
bash <skill-directory>/scripts/onboarding.sh <vault-path>
```

This creates all directories and the initial `wiki/index.md` and `wiki/log.md` files.

The vault gets two source roots: `raw/` for one-off clipped articles (generic sources) and `src/documentation/` for authoritative tree-shaped docs (structured sources, e.g. confluence or github-wiki exports). Both are scaffolded empty; the user (or an external scraper like `doc-downloader`) drops files in later under `src/documentation/<system>/...`.

### 4. Generate the agent config file

Read the template at `<skill-directory>/references/agent-configs/claude-code.md` and write the generated config to `<vault>/CLAUDE.md`.

Replace these placeholders:

- `{{VAULT_NAME}}` — the vault name from Step 1
- `{{DOMAIN_DESCRIPTION}}` — a one-line description derived from Step 3
- `{{DOMAIN_TAGS}}` — generate 5–8 domain-relevant tags as a bullet list based on the domain from Step 3
- `{{WIKI_SCHEMA}}` — read `<skill-directory>/references/wiki-schema.md` and insert everything from `## Architecture` onward

### 5. Register the plugin in settings.json

Use the user's answer from Step 4:

- If (a) Just this vault — run:
  `node <skill-directory>/scripts/register-plugin.js --scope project --vault <vault-path>`
- If (b) All my projects — run:
  `node <skill-directory>/scripts/register-plugin.js --scope user`
- If (c) Skip — print the two snippets below so the user can register manually later:
  - Project-scope: contents of the registration block with the plugin's absolute path filled in, to be merged into `<vault>/.claude/settings.json`
  - User-scope: the contents of `docs/install/user-home-settings.json` (point them at the file path)

The script is idempotent — running it again on a future onboarding pass is safe.

### 6. Update wiki/log.md

Append the setup entry:

```
## [YYYY-MM-DD] setup | Vault initialized
Created vault "{{VAULT_NAME}}" for {{DOMAIN_DESCRIPTION}}.
Agent config: CLAUDE.md.
```

### 7. Install CLI tools (if selected)

For each tool the user selected in Step 5, run the install command:

- summarize: `npm i -g @steipete/summarize`
- qmd: `npm i -g @tobilu/qmd`
- agent-browser: `npm i -g agent-browser && agent-browser install`

After each install, verify with `<tool> --version`. Report success or failure for each.

### 8. Print summary

Show the user:

1. **What was created** — directory tree and config files
2. **Required next step** — install the Obsidian Web Clipper browser extension:
   > Install the Obsidian Web Clipper to easily save web articles into your vault:
   > https://chromewebstore.google.com/detail/obsidian-web-clipper/cnjifjpddelmedmihgijeibhnjfabmlf
3. **How to start** — open the vault folder in Obsidian, then either:
   - Clip an article to `raw/` (generic one-off sources), or
   - Drop a tree of `.md` files under `src/documentation/<system>/...` (structured docs from confluence, github-wiki, etc.)

   Then run `/second-brain:ingest`.

## Reference Files

These files are bundled with this skill and available under `<skill-directory>/`:

- `wiki-schema.md` — canonical wiki rules (single source of truth for all agent configs)
- `tooling.md` — CLI tool details, install commands, and verification steps
- `agent-configs/claude-code.md` — CLAUDE.md template
- `scripts/register-plugin.js` — merges plugin registration into a Claude Code settings.json (used by post-wizard Step 3)

## Next Steps

After setup is complete, the user's workflow is:

1. **Clip articles** to `raw/` using the Obsidian Web Clipper
2. **Ingest sources** with `/second-brain:ingest` — processes raw files into wiki pages
3. **Ask questions** with `/second-brain:query` — searches and synthesizes from the wiki
4. **Health-check** with `/second-brain:lint` — run after every 10 ingests or monthly
