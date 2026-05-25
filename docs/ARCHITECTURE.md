# Second Brain — Architecture

How the system is built. For day-to-day usage, see [USER-GUIDE.md](./USER-GUIDE.md).

This doc is the canonical orientation for developers and AI coding agents asked to extend the project. It should be enough to understand *what fits where* and *what the rules are* without grepping the codebase.

---

## What this is

A Claude Code plugin (`second-brain`) that implements [Karpathy's LLM-wiki pattern](./llm-wiki.md): a personal knowledge base where the human curates raw sources and the LLM compiles & maintains an interlinked markdown wiki. Editing surface is Obsidian; the agent surface is Claude Code.

The vault is a git repo of markdown. The plugin adds skills (`/second-brain:*`) and scripts that the skills shell out to.

### Goal

Make the LLM a *disciplined* librarian — not a generic chatbot pointed at files. Discipline comes from two things:

1. **Deterministic scripts own the state.** The LLM does not grep logs, does not hand-edit YAML, does not compute counts. It calls scripts. The scripts produce JSON; the LLM reasons over JSON.
2. **Stable contracts.** State files have `schema_version`. Scripts have stable subcommands and stable JSON output. Skills compose these like a small CLI ecosystem.

### Non-goals

- Multi-agent support. Claude Code only; Codex / Cursor / Gemini templates were removed. The wiki *schema* is reusable across agents, but the plugin isn't.
- Embedding-based RAG infrastructure. Index file + `qmd` for search is the answer up to the scales this is built for.
- A web UI. Obsidian is the editor; Claude Code is the agent.

---

## Layout

```
second-brain/                              # the plugin repo
├── .claude-plugin/
│   ├── plugin.json                        # plugin manifest + Stop hook
│   └── marketplace.json
├── scripts/                               # plugin-wide scripts
│   ├── validate-wiki.js                   # frontmatter / wikilinks / index / lifecycle checks
│   ├── status.js                          # read-only dashboard reporter
│   ├── review-log.js                      # owns since-review.yaml (append / show / accept)
│   ├── contradictions.js                  # owns contradictions.yaml
│   ├── staleness.js                       # owns staleness.yaml
│   └── sync-index.js                      # repairs wiki/index.md
├── skills/
│   ├── onboard/                           # vault scaffolding wizard
│   ├── ingest/                            # raw → wiki
│   ├── query/                             # ask the wiki
│   ├── lint/                              # deep health check
│   ├── reorganize/                        # structural refactor
│   └── status/                            # dashboard + reconcile + refresh
├── tests/
│   ├── fixtures/                          # mini-vaults pinned per scenario
│   └── test_*.sh                          # one shell test per script (10 files, 486 cases)
├── docs/
│   ├── REQUIREMENTS.md                    # blueprint / origin
│   ├── llm-wiki.md                        # Karpathy's seed doc
│   ├── USER-GUIDE.md                      # how to use it
│   ├── ARCHITECTURE.md                    # this file
│   ├── install/                           # headless-driving, user-home-settings.json
│   └── archive/                           # CRs / plans / specs (v1.0 history)
└── package.json                           # Node ≥18, js-yaml ^4.1
```

A **vault** (what users create with `/second-brain:onboard`) looks like:

```
<vault>/
├── raw/                                   # generic sources (immutable)
│   └── assets/
├── src/
│   └── documentation/
│       └── <system>/                      # structured sources (immutable)
├── wiki/                                  # LLM workspace
│   ├── sources/
│   ├── entities/
│   ├── concepts/
│   ├── synthesis/
│   ├── index.md
│   ├── log.md
│   └── .state/                            # YAML state — owned by scripts
│       ├── sources.yaml
│       ├── contradictions.yaml
│       ├── staleness.yaml
│       ├── since-review.yaml
│       └── frontmatter-contract.yaml
├── output/
├── .claude/settings.json                  # registers the plugin
└── CLAUDE.md                              # agent config (per-vault)
```

The vault is a git repo. `wiki/.state/` is **committed** — state travels with the vault across clones.

---

## The core architectural rule

This is the project's load-bearing decision. Everything else falls out of it.

> **Deterministic work goes in scripts. Judgment goes in the LLM. They communicate via JSON on stdout.**

| Work | Owner |
|---|---|
| Hash sources; diff filesystem vs state | script |
| Resolve wikilinks; detect orphans; index sync | script |
| Detect contradiction *candidates* (relations conflict, shared-entity prose) | script |
| Detect staleness *candidates* (age, newer overlapping sources) | script |
| Page rewrites with post-validation + auto-revert | script |
| "Is this *actually* a contradiction?" (judge pass) | LLM |
| "Is this page *actually* stale?" (judge pass) | LLM |
| Writing summaries, choosing what to merge, picking sides in a conflict | LLM |

A `SKILL.md` prompt must not re-implement in prose anything a script can verify. If the check fits in a `grep` or a YAML diff, it goes in a script invoked from a hook or from the SKILL — not narrated as instructions to the LLM.

**Why this matters for extending the project:** when adding a new capability, the first question is always *what's deterministic, what's judgment?* The deterministic half becomes a script subcommand with a JSON output and a fixture-locked test. The judgment half becomes prose in a SKILL.md that calls the script.

---

## The unjudged → unreviewed → resolved lifecycle

Both the contradiction and staleness pipelines share this lifecycle (and the same script shape: `candidates` / `list` / `judge` / `resolve` / `apply-*`).

```
       enqueue (deterministic)         judge (LLM)               apply (interactive)
candidate ────────────────► unjudged ─────────► unresolved ──────────────► resolved-*
                                       │                        ├──► accepted-disagreement
                                       └─────► not-a-contradiction          (contradictions only)
                                                                ├──► refreshed | archived | historical
                                                                │                  (staleness only)
                                                                └──► deferred ──► (re-promotable)
```

- **`unjudged`** = the deterministic scan flagged it; no LLM has looked yet. Cheap; runs on every ingest (scoped) and every lint (full-vault).
- **`unreviewed`** / **`unresolved`** = the LLM judged it real; awaiting a human decision. Surfaced as actionable on the dashboard.
- **`resolved-*`** = a human acted via `/second-brain:status reconcile` or `refresh`. One git commit per resolution.
- **`deferred`** = parked; still walkable on demand.

This three-stage split is what makes the system viable headless: judging is LLM-heavy and can run on cron (`--judge-only`); resolving is judgment-heavy and only a human should do it. The dashboard reports each stage independently so cron can target the right one.

---

## Scripts

Every script:

- Resolves the vault root by walking up for `.git/` AND `wiki/.state/sources.yaml`. Outside a vault → exit 2 with a pointer to `/second-brain:onboard`.
- Versions its state file with a top-level `schema_version: <int>`. Schema mismatch → exit 2.
- Stamps `generated_by: scripts/<name>.js` so the owning script is obvious from the file.
- Atomic writes (write-temp + rename) — concurrent runs are safe.
- Stable JSON contract on `--json`; stable exit codes (`0` ok, `2` invariant/schema failure, `3` user-correctable refusal).

### Plugin-wide (`scripts/`)

| Script | Owns | Key subcommands |
|---|---|---|
| `validate-wiki.js` | reads `frontmatter-contract.yaml`; never writes | `frontmatter`, `wikilinks`, `index`, `lifecycle`, `all` |
| `status.js` | nothing (aggregator) | default (human dashboard), `--json` |
| `review-log.js` | `since-review.yaml` | `append`, `show`, `accept` |
| `contradictions.js` | `contradictions.yaml` | `candidates`, `list`, `judge`, `apply-pick`, `apply-accept`, `resolve` |
| `staleness.js` | `staleness.yaml` | `candidates`, `list`, `judge`, `apply-refresh`, `apply-archive`, `apply-historical`, `resolve`, `check` |
| `sync-index.js` | repairs `wiki/index.md` | (no subcommands) |

### Skill-private (`skills/<skill>/scripts/`)

| Script | Skill | Owns | Key subcommands |
|---|---|---|---|
| `state-sources.js` | ingest | `sources.yaml` | `begin`, `diff`, `commit` |
| `reorganize.js` | reorganize | nothing persistent; mechanises moves | `begin`, `candidates`, `move-page`, `merge-page`, `mark-covered`, `parent-create`, `relations-add`, `validate-or-revert` |
| `register-plugin.js` | onboard | merges into `settings.json` | `--scope project|user` |
| `onboarding.sh` | onboard | scaffolds vault dirs | bash, takes a path |

---

## State files (`wiki/.state/`)

All state lives here. All YAML. All have `schema_version` + `generated_by`. All are committed.

| File | Owned by | Schema purpose |
|---|---|---|
| `sources.yaml` | `state-sources.js` | content-hash + ingested-at per source; the source-of-truth for "what's been ingested" |
| `contradictions.yaml` | `contradictions.js` | one entry per candidate pair; carries status, judgment, resolution |
| `staleness.yaml` | `staleness.js` | one entry per flagged page; carries status, factors, verdict, judgment.neighbors_examined |
| `since-review.yaml` | `review-log.js` | append-only inbox of headless work; cleared by `accept` |
| `frontmatter-contract.yaml` | hand-authored; read by `validate-wiki.js` | declares required keys per wiki subdirectory |

Reading these files directly from a SKILL.md is a smell — call the owning script instead. JSON-from-script is the boundary.

### `sources.yaml` snippet

```yaml
schema_version: 1
generated_by: skills/ingest/scripts/state-sources.js
sources:
  - path: raw/some-article.md
    kind: generic              # generic | structured
    sha256: 6f1d...
    bytes: 4231
    mtime: 2026-05-18T10:23:11Z
    ingested_at: 2026-05-18T10:25:00Z
    wiki_pages: [wiki/sources/some-article.md, wiki/entities/foo.md]
  - path: src/documentation/confluence/api/auth.md
    kind: structured
    system: confluence          # only set when kind=structured
    sha256: 9b4a...
    ...
```

The two source kinds drive different ingest treatments — see `skills/ingest/SKILL.md` §"Source types".

---

## Skills

Each skill is a `SKILL.md` (Claude Code skill manifest with YAML frontmatter) plus optional `references/` and `scripts/`. The SKILL.md is the LLM's instruction set; it should be heavy on **what subcommands to call when** and light on logic the script already enforces.

| Skill | Entry point | What it owns end-to-end |
|---|---|---|
| `onboard` | wizard prompt | scaffolds vault, generates `CLAUDE.md`, registers the plugin |
| `ingest` | per-source loop | discusses takeaways with user, writes wiki pages, calls `state-sources commit`, calls `review-log append`, calls `contradictions candidates --scope=...` |
| `query` | answer + cite | reads index → reads pages → calls `staleness check --pages=...` for freshness warnings → optionally saves to `wiki/synthesis/` |
| `lint` | full-vault audit | calls `validate-wiki`, `contradictions candidates --scope=wiki/`, `staleness candidates --scope=wiki/`; reports counts |
| `reorganize` | propose / confirm / apply | wraps `reorganize.js` move subcommands with per-move `validate-or-revert` |
| `status` | dashboard + sub-flows | shells `status.js` for dashboard; orchestrates `reconcile` / `refresh` interactive walks and `--judge-only` cron passes |

Two reasons the skill set landed at six (not three, not twenty):

- **`status` exists as the single front door.** The user shouldn't need to remember six skills. `/second-brain:status` is the morning check; it points at whichever specific skill is needed next.
- **`reorganize` is split from `lint`.** Lint is correctness; reorganize is structure. They have different cadences (lint is hookable; reorganize is deliberate human pass), so they're different skills.

---

## Hooks

Defined in `.claude-plugin/plugin.json`:

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{ "type": "command",
                  "command": "node \"${CLAUDE_PLUGIN_ROOT}/scripts/validate-wiki.js\" all" }]
    }]
  }
}
```

The `Stop` hook runs `validate-wiki.js all` at the end of every interactive Claude Code session. It catches structural breakage (broken frontmatter, broken wikilinks, dead index rows, lifecycle violations) before the user moves on. Headless invocations don't fire `Stop` — `--judge-only` passes skip the validator and that's intentional (they don't edit pages).

No other hooks are wired. Future ones go in `plugin.json` and should call existing script subcommands rather than introduce new logic.

---

## Runtime

- **Node ≥ 18.** Single dependency: `js-yaml ^4.1`. Declared in the top-level `package.json` (`engines.node`, `dependencies.js-yaml`). Installed once during onboarding (`npm install --omit=dev` in `$CLAUDE_PLUGIN_ROOT`).
- Scripts are single-file. Split into a `lib/` directory only after a third consumer appears.
- Invocations from SKILL.md or hooks: `node "$CLAUDE_PLUGIN_ROOT/scripts/<name>.js"` or `node "$CLAUDE_PLUGIN_ROOT/skills/<skill>/scripts/<name>.js"`.
- Don't introduce Python, Deno, or another YAML library without amending this convention.

---

## Tests

Every script has a `tests/test_<script>.sh` shell test. Tests use **fixture vaults** under `tests/fixtures/<scenario>/` — fully realised mini-vaults with `.git`, `.state/`, and the pages each test needs.

Convention:

- One fixture per scenario, named for what it tests (`apply-archive-input`, `signal-1-conflicting-relations`, etc.).
- Tests `cp -R` the fixture into a tmpdir, run the script, assert on stdout / exit code / resulting state file.
- Output: `PASS: <case>` / `FAIL: <case>` + a summary line `Results: N passed, M failed`.
- Run all of them: `for t in tests/test_*.sh; do bash "$t"; done` — currently 486 cases across 10 files, all green.

When adding a new script subcommand: write the fixture first, then the assertion, then the code. The fixture *is* the spec.

---

## Headless mode

The plugin's value at scale: the entire system runs unattended except for the irreducible-judgment slices.

- **`scripts/status.js --json`** is the stable contract cron consumes. Schema in `skills/status/references/status-json-schema.md`. Byte-stable across runs with unchanged state — no timestamps in the payload.
- **`/second-brain:ingest`** runs cleanly under `claude --headless` (the discussion-with-user phase is skipped; the LLM commits each source as it goes).
- **`/second-brain:status reconcile --judge-only`** drains contradiction `unjudged` candidates.
- **`/second-brain:status refresh --judge-only`** drains staleness `unjudged` candidates.

`since-review.yaml` is the durable inbox of headless work. The next human session sees it via `/second-brain:status` (count) and walks it via `/second-brain:status review` / `accept`.

See [install/headless-driving.md](./install/headless-driving.md) for the full cron pattern.

---

## How to extend

A typical "add a new capability" lands in this order:

1. **Decide the script/LLM split.** Deterministic enumeration goes in a script; judgment goes in a SKILL.
2. **Design the state file** (if any). YAML, `schema_version: 1`, `generated_by`, atomic writes, exit-2 on schema mismatch, single owner. Add it to `wiki/.state/` and document it in this file.
3. **Pick the lifecycle.** If the new pipeline produces "candidates that need an LLM verdict that needs a human decision", reuse the `unjudged → unreviewed → resolved` shape. Subcommands: `candidates` / `list` / `judge` / `apply-*` / `resolve`. JSON output on `list --json`.
4. **Wire the dashboard.** Add a counts section to `scripts/status.js`. Document the predicate in `skills/status/references/status-json-schema.md`. Mark `present: false` until the state file exists.
5. **Hook the trigger.** Cheap scans go scoped on every ingest (`--scope=<paths-just-touched>`); full-vault scans go in `/second-brain:lint`.
6. **Add the SKILL prose.** Two flows: interactive (under `/second-brain:status <new-flow>`) and `--judge-only` (cron-safe).
7. **Append a `kind: <new>` entry to the review log** from each headless invocation, so accumulated unsupervised work shows up in `/second-brain:status review`.
8. **Test with a fixture.** Mini-vault under `tests/fixtures/<scenario>/`; shell test under `tests/test_<script>.sh`.

The patterns above aren't arbitrary — they're what `contradictions.js` and `staleness.js` look like in real code. Reading those two scripts side-by-side is the fastest way to absorb the shape.

---

## Where to read further

- The lived-in usage view → [USER-GUIDE.md](./USER-GUIDE.md)
- Karpathy's original pattern → [llm-wiki.md](./llm-wiki.md)
- Project blueprint / why this exists → [REQUIREMENTS.md](./REQUIREMENTS.md)
- Per-vault scaffolding → `skills/onboard/SKILL.md` and `skills/onboard/references/wiki-schema.md`
- Cron / headless pattern → [install/headless-driving.md](./install/headless-driving.md)
- `status.js --json` schema → `skills/status/references/status-json-schema.md`
- Pre-1.0 decision history (CRs, plans, specs) → [archive/](./archive/)
