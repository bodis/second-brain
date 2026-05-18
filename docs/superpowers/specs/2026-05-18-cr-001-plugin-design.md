# CR-001 Design — Convert repo to a Claude Code plugin

**Status:** Approved, ready for implementation planning
**Date:** 2026-05-18
**CR:** [CR-001](../../cr/CR-001-claude-code-plugin.md)
**Conventions:** [docs/cr/conventions.md](../../cr/conventions.md)

## 1. Problem

The repo distributes itself via `npx skills add NicholasSpisak/second-brain` — a third-party tool that copies `skills/*` into whichever agent skill folder is present. It is not a Claude Code plugin: no manifest, bare (non-namespaced) skill names, templates for four agents the user doesn't use, and a wrong upstream slug in the README install command.

The user only uses Claude Code. Carrying Codex, Cursor, and Gemini support costs maintenance with zero benefit, and no manifest means no access to the Claude Code plugin system that later CRs (especially CR-004's hook framework) depend on.

## 2. Goals

- Repo is loadable as a Claude Code plugin (`.claude-plugin/plugin.json` + `marketplace.json` at root).
- Skills are namespaced: `/second-brain:onboard`, `/second-brain:ingest`, `/second-brain:query`, `/second-brain:lint`.
- Support **both** install modes via the standard Claude Code settings mechanism:
  - **Project-only** install: plugin source lives in `<vault>/.claude/plugins/second-brain/`, registered in `<vault>/.claude/settings.json`.
  - **User-wide** install: plugin source lives in `~/.claude/plugins/second-brain/` (or any home path), registered in `~/.claude/settings.json`.
- Non-Claude-Code support is removed (templates, wizard branches, README copy).
- Onboarding wizard still works end-to-end and, by default, writes a project-scope settings file so the new vault auto-loads the plugin next session.
- Existing onboarding test (`tests/test_onboarding.sh`) continues to pass after the rename.

## 3. Non-goals

Carried verbatim from CR-001, plus a few explicit additions:

- No new skills (CR-005 owns the reorganize skill).
- No vault schema changes (CR-002, CR-003).
- No hooks wiring (CR-004); `plugin.json` does not declare hooks yet.
- No public marketplace, no GitHub Releases workflow, no auto-update strategy.
- No automation for keeping multiple vault copies of the plugin in sync (CR-006).
- No restructuring of `references/`, `docs/`, or skill internals beyond what is needed for the rename.

## 4. Target architecture

```
second-brain/                              # repo root = plugin root
├── .claude-plugin/
│   ├── plugin.json                        # NEW: plugin manifest
│   └── marketplace.json                   # NEW: single-plugin catalog (self-reference)
├── skills/
│   ├── onboard/
│   │   ├── SKILL.md                       # was skills/second-brain/SKILL.md
│   │   ├── references/
│   │   │   ├── wiki-schema.md
│   │   │   ├── tooling.md
│   │   │   └── agent-configs/
│   │   │       └── claude-code.md         # only template left
│   │   └── scripts/
│   │       └── onboarding.sh
│   ├── ingest/SKILL.md                    # was skills/second-brain-ingest/
│   ├── query/SKILL.md                     # was skills/second-brain-query/
│   └── lint/SKILL.md                      # was skills/second-brain-lint/
├── tests/
│   └── test_onboarding.sh                 # path inside updated
├── docs/
│   ├── install/
│   │   └── user-home-settings.json        # NEW: copy-paste snippet for Mode U
│   ├── cr/                                # unchanged
│   ├── superpowers/                       # unchanged
│   ├── assets/                            # unchanged
│   ├── llm-wiki.md                        # unchanged
│   └── REQUIREMENTS.md                    # multi-agent section trimmed
├── README.md                              # install section rewritten
└── .gitignore
```

### 4.1 Skill rename map

| Before | After | Invocation after |
|---|---|---|
| `skills/second-brain/` | `skills/onboard/` | `/second-brain:onboard` |
| `skills/second-brain-ingest/` | `skills/ingest/` | `/second-brain:ingest` |
| `skills/second-brain-query/` | `skills/query/` | `/second-brain:query` |
| `skills/second-brain-lint/` | `skills/lint/` | `/second-brain:lint` |

Skill `name:` frontmatter inside each `SKILL.md` is updated to match the new directory name (Claude Code uses the directory name for the namespaced slash command; the `name:` field should agree to avoid confusion).

### 4.2 Files to delete

- `skills/second-brain/references/agent-configs/codex.md`
- `skills/second-brain/references/agent-configs/cursor.md`
- `skills/second-brain/references/agent-configs/gemini.md`

### 4.3 Content edits in `skills/onboard/SKILL.md`

- Remove the entire "Step 4: Agent Config" subsection (the agent-detection question AND the multi-agent selection prompt).
- Insert a **new** Step 4: settings scope (see §6.4 below). The wizard step count stays at 5: vault-name → vault-location → domain → settings-scope → tools.
- In the post-wizard scaffolding section, replace the multi-agent generation logic with a single deterministic action: generate `CLAUDE.md` from `references/agent-configs/claude-code.md`. State this up front as a non-question status line.
- Trim the "Generate agent config file(s)" table to keep only the Claude Code row.
- Remove the "Agent detection logic" block.
- Update the "Reference Files" table to list only `agent-configs/claude-code.md`.
- All in-prose references to `/second-brain-ingest`, `/second-brain-query`, `/second-brain-lint` become their `/second-brain:<name>` equivalents.

### 4.4 Content edits in `skills/ingest/SKILL.md`, `skills/query/SKILL.md`, `skills/lint/SKILL.md`

- `name:` frontmatter updated to the new directory name (`ingest`, `query`, `lint`).
- Any internal cross-references to other skills use the namespaced form (`/second-brain:ingest` etc.).

### 4.5 Edits in `docs/REQUIREMENTS.md`

- Replace the "Multi-Agent Support" section with a one-paragraph note: the wiki pattern itself is agent-agnostic, but this fork ships as a Claude Code plugin and removes the Codex / Cursor / Gemini config templates.
- Remove mentions of `npx skills add`.

### 4.6 Edits in `README.md`

- Prerequisites: drop "or any agent that supports Agent Skills"; keep Obsidian + Claude Code only.
- Install: replace `npx skills add` with the two-mode install (§5).
- Skill table uses namespaced names.
- Remove the FAQ entry "Can I use this with multiple AI agents?" or rewrite it to one sentence pointing at upstream.
- Reframe the Node.js prerequisite: not required for installing the plugin itself, only for the optional CLI tools (`summarize`, `qmd`, `agent-browser`). Move it from "Prerequisites" to the "Optional Tools" section.

## 5. Manifests

### 5.1 `.claude-plugin/plugin.json`

```json
{
  "name": "second-brain",
  "version": "0.1.0",
  "description": "LLM-maintained personal knowledge base for Obsidian. Drop raw sources into a folder; the librarian compiles them into a structured wiki.",
  "author": { "name": "Tamás Bódis" },
  "homepage": "https://github.com/bodis/second-brain",
  "repository": "https://github.com/bodis/second-brain"
}
```

No `hooks` field — CR-004 adds it.

### 5.2 `.claude-plugin/marketplace.json`

A minimal single-plugin catalog so the repo can be registered as a `source: directory` marketplace by `extraKnownMarketplaces`:

```json
{
  "name": "second-brain",
  "owner": { "name": "Tamás Bódis" },
  "plugins": [
    {
      "name": "second-brain",
      "source": "."
    }
  ]
}
```

The `source: "."` entry tells the marketplace that the single listed plugin lives at the marketplace root (i.e., the plugin and the marketplace are the same directory).

### 5.3 Versioning policy

- Start at `0.1.0`.
- Each subsequent CR that ships user-visible behavior bumps the minor version. Bugfix-only CRs bump the patch version.
- CR-006 (first multi-vault rollout) is the natural `1.0.0` cut.
- The explicit `version` field is used instead of relying on the git commit SHA, so users only see "update available" when an intentional release happens.

## 6. Install modes

Both modes use the same plugin source; they differ in (a) where the source is cloned, and (b) which `settings.json` registers it.

### 6.1 Mode P — Project-only

- **Source location:** `<vault>/.claude/plugins/second-brain/`
- **Settings file:** `<vault>/.claude/settings.json`
- **Scope:** plugin loads only when `claude` runs inside that vault
- **Default for new vaults created by the onboard wizard**

### 6.2 Mode U — User-wide

- **Source location:** `~/.claude/plugins/second-brain/` (the path is not enforced — any path the user keeps stable will do)
- **Settings file:** `~/.claude/settings.json`
- **Scope:** plugin loads in every Claude Code session, regardless of cwd

### 6.3 Settings block (shared structure)

Both modes write the same JSON shape into the appropriate `settings.json`. Only the absolute `path` field differs.

```json
{
  "extraKnownMarketplaces": {
    "second-brain": {
      "source": { "source": "directory", "path": "<absolute path to plugin source>" }
    }
  },
  "enabledPlugins": {
    "second-brain@second-brain": true
  }
}
```

### 6.4 Wizard handling of install modes

The onboard wizard adds one question (Step 4):

> Where should I register this plugin so it auto-loads next time?
> (a) Just this vault → writes `<vault>/.claude/settings.json` *(default)*
> (b) All my projects → merges into `~/.claude/settings.json`
> (c) Skip — I'll handle this manually

Implementation notes for the wizard:

- The wizard resolves the plugin source's own absolute path from the skill execution context. That path is what goes into the `path:` field — no user input required.
- Merge semantics for both (a) and (b): if the target `settings.json` already exists, parse it as JSON, set exactly these two keys (`extraKnownMarketplaces.second-brain` and `enabledPlugins["second-brain@second-brain"]`), and write the file back. Existing values for those two keys are overwritten (this is the right behavior — the user is re-registering this plugin). Every other key in the file is left untouched. If the file doesn't exist, create it with just these two keys. If parsing fails (malformed JSON), abort the write and tell the user; do not attempt repair.
- For option (c), the wizard prints both possible snippets (project-scope and user-home) with their destination paths, so the user can pick after the wizard exits.

### 6.5 Where the user-home install snippet lives in the repo

A ready-made copy/paste file at `docs/install/user-home-settings.json` so users following README Option B don't have to hand-construct the JSON. The README links to this file.

## 7. Data flow

Nothing in the runtime behavior of ingest / query / lint changes. The only delta is **how the four skills become discoverable**: via Claude Code's plugin loader instead of the npx skill-copying tool. After CR-001:

1. User clones the repo (per Mode P or Mode U).
2. Claude Code reads `extraKnownMarketplaces` + `enabledPlugins` from the relevant `settings.json`.
3. Claude Code loads `.claude-plugin/marketplace.json`, resolves `second-brain` to the local directory, then loads `.claude-plugin/plugin.json` and the `skills/` tree.
4. Slash commands `/second-brain:onboard`, `/second-brain:ingest`, `/second-brain:query`, `/second-brain:lint` are now available.

Manifest-load errors surface in Claude Code's init message and are visible during the smoke test (§9).

## 8. README install rewrite

Replace the current "Install" section with two clearly-labeled options.

### Option A — Per-vault install (project-scope)

```bash
# 1. From inside the directory that will become your vault:
git clone https://github.com/bodis/second-brain.git .claude/plugins/second-brain

# 2. One-time bootstrap to launch the wizard:
claude --plugin-dir .claude/plugins/second-brain
# Then in the Claude Code session, run:
/second-brain:onboard

# 3. The wizard scaffolds the vault AND writes .claude/settings.json so
#    future sessions auto-load the plugin. From then on, just:
cd <vault> && claude
```

### Option B — User-wide install

```bash
# 1. Clone once to your home dir:
git clone https://github.com/bodis/second-brain.git ~/.claude/plugins/second-brain

# 2. Merge the snippet from docs/install/user-home-settings.json into
#    ~/.claude/settings.json (adjust the "path" field to your absolute path).

# 3. From any directory:
claude
/second-brain:onboard
```

## 9. Tests

### 9.1 Automated

- `tests/test_onboarding.sh` — update internal path from `skills/second-brain/scripts/onboarding.sh` to `skills/onboard/scripts/onboarding.sh`. No other changes required for CR-001. The test must still pass after the rename.

### 9.2 Manual smoke checklist (run once before merging)

1. **Plugin loads.** From a clean temp directory, run `claude --plugin-dir <repo>` and confirm `/help` lists the four `second-brain:*` skills.
2. **Mode P bootstrap.** In an empty temp directory, run `claude --plugin-dir <repo>` then `/second-brain:onboard` with all defaults. Confirm:
   - `raw/`, `wiki/`, `output/`, `wiki/index.md`, `wiki/log.md`, `CLAUDE.md` exist.
   - `.claude/settings.json` is written and contains `extraKnownMarketplaces.second-brain` + `enabledPlugins["second-brain@second-brain"]: true`.
3. **Mode P auto-load.** Exit Claude Code, `cd` back into the temp vault, run `claude` (no `--plugin-dir` flag). Confirm `/second-brain:*` skills are available.
4. **Mode U merge.** Pre-populate `~/.claude/settings.json` with an unrelated key, run the wizard with option (b), and confirm only the two plugin keys are added (the unrelated key is untouched).
5. **Mode U auto-load.** From a directory with no `.claude/settings.json`, confirm the plugin still loads.
6. **No stale references.** `grep -r '/second-brain-' .` in the repo finds nothing in user-facing docs (README, SKILL.md files, REQUIREMENTS.md, CR docs).

## 10. Risks and tradeoffs

- **N copies of the plugin (Mode P).** Each vault holds its own clone, so updates require `git pull` in each one. The user has explicitly accepted this tradeoff for vault self-containment. CR-006 may automate the multi-vault pull.
- **Vault size grows.** Plugin repo is small (single-digit MB) — negligible vs. typical vault content.
- **Out-of-sync vaults.** Different vaults can run different plugin versions. Acceptable for personal use; documented in the README.
- **`directory` marketplace source is documented as "for development only."** This is the official source type for local-filesystem plugins. It works for production use in our context (single-user, local-only), but it is worth noting that the upstream framing assumes developer iteration rather than long-lived install. Not blocking.
- **Settings.json merge correctness (Mode U).** Wizard logic must merge JSON instead of overwriting. Risk is low (one file, two well-known keys), but the merge implementation has to be careful with existing whitespace/comments — Claude Code's `settings.json` is plain JSON (no comments), so a parse-and-rewrite is safe.

## 11. Open questions deferred to plan / later CRs

- Should the wizard offer to **also** install a one-line shell alias so `cd <vault> && claude` is replaced by something even shorter? — Out of scope; revisit if needed.
- Multi-vault update automation. — CR-006.
- Public marketplace publication. — Not planned; revisit only if the project goes public.

## 12. Out of scope (carried from CR-001)

- New skills (CR-005).
- Schema changes inside vaults (CR-002, CR-003).
- Hooks framework (CR-004) — only referenced from `plugin.json` after CR-004 lands.
