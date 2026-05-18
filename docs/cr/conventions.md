# CR Conventions

Cross-cutting decisions that all CRs reference. Don't re-litigate these inside individual CRs — change them here.

## 1. Target agent: Claude Code only

This project drops support for Codex, Cursor, and Gemini CLI. The `skills/second-brain/references/agent-configs/{codex,cursor,gemini}.md` templates are removed in CR-001. Anything that doesn't apply to Claude Code is out of scope.

## 2. Claude Code documentation reference

The canonical, locally mirrored Claude Code docs live at:

```
/Users/bodist/work/ai/doc-downloader/docs/claude-code/
```

When a CR references "the Claude Code docs", it means this directory. Useful sub-paths:

- `customize-behavior/plugins.md`, `customize-behavior/skills.md`, `customize-behavior/slash-commands.md` — plugin + skill + slash command authoring
- `tools-and-plugins/plugins.md`, `tools-and-plugins/skills.md` — distribution and discovery
- `plugin-distribution/plugin-marketplaces.md`, `plugin-distribution/plugin-dependencies.md` — marketplace + dependency model
- `automation/` — hook event model

Read from here instead of the web — it's already pinned to a known version.

## 3. State files use YAML, owned by scripts

State that the system reasons about (what sources exist, what's been ingested, what's changed) lives in **versioned YAML files** under `wiki/.state/`. Not SQLite, not JSON, not the human-readable `wiki/log.md`. Properties:

- One file per concern (e.g. `sources.yaml`, `ingest-runs.yaml`).
- **Scripts read and write these files.** SKILL.md prompts must not instruct the LLM to hand-edit YAML; they instruct the LLM to call the script.
- Schema versioned via a top-level `schema_version: <int>` so scripts can migrate.
- Generator pinned via `generated_by: <script-path>` so it's clear what owns the file.
- File is committed (no `.gitignore`), so it travels with the vault across clones.

Reference schema for `wiki/.state/sources.yaml` (CR-002 owns this):

```yaml
schema_version: 1
generated_by: scripts/state-sources.sh
sources:
  - path: raw/some-article.md           # relative to vault root
    kind: generic                       # generic | structured
    sha256: 6f1d...
    bytes: 4231
    mtime: 2026-05-18T10:23:11Z
    ingested_at: 2026-05-18T10:25:00Z
    wiki_pages:
      - wiki/sources/some-article.md
      - wiki/entities/foo.md
  - path: src/documentation/confluence/api/auth.md
    kind: structured
    system: confluence                  # only set when kind=structured
    sha256: 9b4a...
    bytes: 1822
    mtime: 2026-05-18T09:00:00Z
    ingested_at: 2026-05-15T11:00:00Z
    wiki_pages:
      - wiki/sources/confluence-api-auth.md
```

A diff script (`scripts/state-sources.sh diff`) compares filesystem reality to `sources.yaml` and outputs three lists: `new`, `changed` (sha mismatch), `deleted`. The ingest SKILL reads that output and operates on it. The LLM does not scan logs to figure out what's new.

`wiki/log.md` stays. It's the **human-readable** record of operations (ingest titles, lint summaries, etc.). It's no longer a source of truth for ingest detection — it's a narrative.

## 4. Hooks-first, LLM-last for verifiable work

Default split for any new operation:

| Work | Owner |
|---|---|
| Deterministic checks (wikilink target exists, YAML frontmatter parses, index entry matches file) | Script invoked by a hook |
| Filesystem state tracking (hashes, timestamps, indexes) | Script |
| Reading content + writing prose + judgment (summaries, cross-references, sub-typing connections) | LLM |

A SKILL must not re-implement in prose what a script can verify. If a check can be expressed as a grep or a YAML diff, it goes in a script that a hook calls, not in the SKILL's instructions.

Hooks framework details — which events, which scripts — live in CR-004.

## 5. Skill namespacing

After CR-001 lands, the plugin is named `second-brain`. Skill invocations are namespaced:

- `/second-brain:onboard`
- `/second-brain:ingest`
- `/second-brain:query`
- `/second-brain:lint`
- `/second-brain:reorganize` (CR-005)

Update all docs and READMEs in any CR that touches user-facing examples.

## 6. Vault layout (target)

```
your-vault/
├── raw/                          # generic sources (clipped articles, transcripts, notes)
│   └── assets/
├── src/                          # structured documentation exports (CR-003)
│   └── documentation/
│       └── <system>/             # e.g. confluence, github-wiki
│           └── ...arbitrary depth of .md...
├── wiki/                         # LLM-maintained
│   ├── sources/
│   ├── entities/
│   ├── concepts/
│   ├── synthesis/
│   ├── index.md
│   ├── log.md
│   └── .state/                   # CR-002, YAML-only
│       └── sources.yaml
├── output/
└── CLAUDE.md
```
