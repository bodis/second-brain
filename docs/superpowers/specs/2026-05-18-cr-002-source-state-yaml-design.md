# CR-002 Design — Replace log-grep ingest detection with a YAML source-state store

**Status:** Draft, pending user review
**Date:** 2026-05-18
**CR:** [CR-002](../../cr/CR-002-source-state-yaml.md)
**Conventions:** [docs/cr/conventions.md](../../cr/conventions.md)
**Depends on:** CR-001 (landed)

## 1. Problem

The ingest SKILL detects unprocessed sources by listing `raw/` and grepping `wiki/log.md` for filenames it has already seen (`skills/ingest/SKILL.md:18-22`). Two failure modes:

- **No change detection.** A re-clipped or re-exported source with the same filename is invisible — the log already names it.
- **Brittle parsing.** `log.md` is human-readable prose. If the LLM phrases an entry slightly differently, detection fails.

CR-003 will introduce structured documentation sources that are explicitly expected to change between re-scrapes. Without content-hashing, those updates would never be seen.

## 2. Goals

- A versioned `wiki/.state/sources.yaml` describes every known source in the vault: relative path, content hash, byte size, mtime, ingest timestamp, and the wiki pages produced from it.
- A single CLI tool, `scripts/state-sources.js`, owns all reads and writes of that file. The ingest SKILL never hand-edits it.
- Three subcommands fully cover the ingest lifecycle: `begin`, `diff`, `commit`.
- Ingest detection becomes: run `state-sources diff`, act on its output, run `state-sources commit` per source. No log parsing.
- Per-source git commits give the vault a browsable ingest history (`git log -- raw/foo.md`).
- The schema reserves the `kind` field (`generic` | `structured`) so CR-003 fills it in without redesigning anything.

## 3. Non-goals

- Two source types (`kind: structured`). CR-003 owns the actual structured-doc handling. CR-002 only reserves the field and walks `raw/`.
- Hooks that auto-run `state-sources diff` on filesystem changes. CR-004.
- A full `ingest-runs.yaml` history file. Per-source git commits give us this for free.
- Orphan wiki page detection. Belongs in `/second-brain:lint`, not in `state-sources commit`.
- Detecting moves vs delete+add. Hash-only detection treats moves as `deleted + new`. Acceptable.
- Migration tooling for vaults that already have an ingest history in `log.md`. The user has no such vaults in flight; new vaults start clean.

## 4. Dependencies

CR-002 makes git a **hard runtime dependency** of the vault. The `state-sources` tool assumes:

- The vault root is a git repo (`.git/` exists).
- `git` is on `PATH`.
- The working tree is in a state `git status --porcelain` can describe.

README and onboarding wizard are updated to state this explicitly (§9.2, §9.3).

Node.js is required (Node 18+, matching the `register-plugin.js` precedent). One new dependency is added: `js-yaml` (MIT, ~50 KB). It is declared in a new repo-root `package.json` so installs are explicit, not implicit (§9.4).

## 5. State file

### 5.1 Location

`<vault>/wiki/.state/sources.yaml`. Committed to git. Created on first `state-sources commit` if absent.

### 5.2 Schema (version 1)

```yaml
schema_version: 1
generated_by: scripts/state-sources.js
excludes:
  - raw/assets/
sources:
  - path: raw/some-article.md           # relative to vault root, POSIX separators
    kind: generic                       # generic | structured
    sha256: 6f1d...                     # hex, lowercase
    bytes: 4231
    mtime: 2026-05-18T10:23:11Z         # source-file mtime at ingest time, UTC ISO 8601
    ingested_at: 2026-05-18T10:25:00Z   # set by `commit`, UTC ISO 8601
    wiki_pages:
      - wiki/sources/some-article.md
      - wiki/entities/foo.md
```

### 5.3 Field rules

- `schema_version: 1` — required, integer. Future migrations will key on this.
- `generated_by: scripts/state-sources.js` — required. Identifies the tool that owns the file.
- `excludes:` — list of path prefixes relative to vault root. Any source path that starts with one of these is ignored by `scan` and `diff`. Default seed: `["raw/assets/"]`. Editable by hand; the tool preserves it.
- `sources:` — list, order is sorted by `path` (deterministic diffs).
- `sources[].path` — POSIX-style relative path from vault root. Required.
- `sources[].kind` — `generic` for everything in CR-002; CR-003 adds `structured`. Required.
- `sources[].sha256` — sha256 of the file's bytes, hex lowercase. Required.
- `sources[].bytes` — size in bytes. Required.
- `sources[].mtime` — file mtime captured at hash time, UTC ISO 8601 with `Z` suffix. Required.
- `sources[].ingested_at` — set by `commit`. UTC ISO 8601. Required. (Every entry reaches `sources.yaml` via `commit`, so this is always present.)
- `sources[].wiki_pages` — list of POSIX-style relative paths from vault root, the wiki `.md` files this source's ingest touched. A page may appear in multiple sources' lists (append-only multi-attribution): if source Y's commit touches a page originally created by source X, the page appears in both X's and Y's `wiki_pages`. This is intentional — orphan detection (in lint) treats a page as orphaned only when no source still claims it. Required (may be empty list — see `--allow-empty` in §6.4).

### 5.4 Why YAML

YAML wins over JSON only for this file because:

- It diffs well in git (one source's hash change shows up as one line).
- Comments are allowed for future human annotations (e.g., notes on the `excludes` block).
- The user reads it occasionally; JSON would be noisier.

All other tool I/O (the `diff` output) is JSON because it is wire format consumed by the LLM, not committed.

## 6. CLI: `scripts/state-sources.js`

### 6.1 Location

`<plugin>/skills/ingest/scripts/state-sources.js`, matching the `onboard/scripts/register-plugin.js` precedent. The ingest SKILL invokes it with an absolute path derived from `$CLAUDE_PROJECT_DIR` plus the plugin path. (Standard Claude Code skill-relative script invocation pattern.)

### 6.2 Implementation language

Plain JavaScript (Node 18+). Type information lives in JSDoc `@typedef` blocks at the top of the file for the two shared shapes: the `Source` record and the `DiffResult`. No TypeScript, no build step.

### 6.3 Subcommands overview

| Subcommand | Inputs | Outputs | Side effects |
|---|---|---|---|
| `begin` | none | stdout: brief status line | If working tree has uncommitted changes in `wiki/` or `wiki/.state/`, makes one git commit (`ingest: pre-run baseline`). No-op if clean. |
| `diff` | reads `sources.yaml`, walks vault | stdout: JSON | None. Read-only. |
| `commit --source <path> [--allow-empty]` | reads `sources.yaml`, runs `git status` | stdout: brief summary line | Updates `sources.yaml`, stages it + the changed wiki files, makes one git commit. |

All subcommands resolve the vault root by walking up from `cwd` to the nearest directory containing `.git/`. They fail loudly if not inside a git repo.

### 6.4 `state-sources begin`

Behavior:

1. Resolve vault root (find `.git/`).
2. Run `git status --porcelain -- wiki/ wiki/.state/`.
3. If output is empty → print `clean baseline` and exit 0.
4. If output is non-empty → `git add wiki/ wiki/.state/`, then `git commit -m "ingest: pre-run baseline"`. Print `committed pre-run baseline (<N> files)` and exit 0.

The commit message is fixed so the ingest SKILL can recognize it on inspection (and so the history is consistent across vaults).

Failure modes:

- Not in a git repo → exit 2, error to stderr.
- Git command fails (e.g., merge in progress, detached HEAD with conflicts) → exit 3, propagate git's stderr.

### 6.5 `state-sources diff`

Behavior:

1. Resolve vault root.
2. Load `wiki/.state/sources.yaml` if it exists; treat absent as empty (`{ schema_version: 1, sources: [] }`).
3. Walk `raw/**/*` (excluding paths matching any `excludes:` prefix and excluding hidden files starting with `.`). For each file, compute `sha256` and capture `mtime`.
4. Build three lists by joining filesystem-set ⨝ yaml-set on `path`:
   - `new` — in filesystem, not in yaml.
   - `changed` — in both, `sha256` differs.
   - `deleted` — in yaml, not in filesystem.
5. Emit JSON to stdout (formatted with 2-space indent for human readability).

Output schema:

```json
{
  "new": [
    { "path": "raw/x.md", "kind": "generic", "sha256": "...", "bytes": 123, "mtime": "2026-05-18T10:23:11Z" }
  ],
  "changed": [
    {
      "path": "raw/y.md", "kind": "generic",
      "sha256": "...", "bytes": 456, "mtime": "2026-05-18T11:00:00Z",
      "previous_sha256": "...", "previous_wiki_pages": ["wiki/sources/y.md", "wiki/entities/foo.md"]
    }
  ],
  "deleted": [
    { "path": "raw/z.md", "previous_wiki_pages": ["wiki/sources/z.md"] }
  ]
}
```

The enrichment on `changed` (`previous_sha256`, `previous_wiki_pages`) gives the ingest LLM the structural context to update existing pages instead of creating duplicates. The enrichment on `deleted` lets the LLM (or the user prompt in the SKILL) decide what to do with pages whose source no longer exists.

Symlinks: followed as if they were regular files. Broken symlinks: ignored (logged to stderr at info level). Non-`.md` files in `raw/`: included (the SKILL today doesn't restrict by extension, and structured docs in CR-003 may include other file types).

For CR-002, `kind` is always `generic`. The walker only descends into `raw/`. `src/documentation/` walking is CR-003 work.

### 6.6 `state-sources commit --source <path> [--allow-empty]`

Behavior:

1. Resolve vault root.
2. Verify `<path>` (relative to vault root) actually exists on disk (or, for the `deleted` case, doesn't exist). Compute its current sha256 + bytes + mtime.
3. Run `git status --porcelain -- wiki/`. Parse the status codes:
   - Added (`A`) and untracked (`??`) `.md` files → recorded in `wiki_pages` and staged for commit.
   - Modified (`M`) `.md` files → recorded in `wiki_pages` and staged for commit.
   - Deleted (`D`) `.md` files → staged for commit (so the commit reflects the deletion) but NOT recorded in `wiki_pages`. The LLM occasionally deletes a wiki page during restructuring; that page should leave the source's list, not enter it.
   - Renamed (`R`) `.md` files → treated as delete-of-old + add-of-new.
4. If the resulting wiki-page list is empty:
   - Without `--allow-empty` → exit 4, error: `source "<path>" produced no wiki changes; re-run with --allow-empty if intentional`. No state mutation.
   - With `--allow-empty` → continue with `wiki_pages: []` and a special commit message suffix.
5. Load `sources.yaml` (or create blank).
6. Upsert the source entry:
   - `path`: the provided path.
   - `kind`: `generic` (CR-002 default; CR-003 adds branching).
   - `sha256`, `bytes`, `mtime`: from step 2.
   - `ingested_at`: now (UTC).
   - `wiki_pages`: list from step 3, sorted.
7. Re-sort `sources:` by `path`. Re-emit the YAML (deterministic key order, 2-space indent).
8. `git add wiki/.state/sources.yaml <wiki pages>` and `git commit -m "ingest: <path> → N pages"` (or `ingest: <path> → no output (allow-empty)` for the empty case).
9. Print the commit hash + summary to stdout.

Edge case — removing a source from state: `commit --source <path> --deleted` drops the entry from `sources.yaml`. Behavior:

- Skip step 2's existence check.
- Skip step 3's `git status` scan (no wiki pages are attributed to a removed source).
- Step 6 becomes "remove the matching entry from `sources:`".
- Step 8 stages only `wiki/.state/sources.yaml` and commits with message `ingest: remove <path> from state`.

This is rare in CR-002 (only happens if the user manually deletes a source from `raw/`); the LLM normally surfaces `deleted` entries from `diff` to the user and then calls `commit --deleted` once the user confirms.

Failure modes:

- Source path doesn't exist on disk and `--deleted` not given → exit 5.
- Working tree has uncommitted non-wiki changes (e.g., source-file edits, plugin code changes) → exit 6, error message instructs running `state-sources begin` first. Rationale: those changes would otherwise be folded into the per-source commit, polluting attribution.
- Git operation fails → exit 3.

### 6.7 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Not in a git repo |
| 3 | Git command failed |
| 4 | Source produced no wiki changes (commit without `--allow-empty`) |
| 5 | Source path doesn't exist and `--deleted` not given |
| 6 | Working tree has uncommitted non-wiki changes; run `begin` first |
| 1 | Other / unexpected |

### 6.8 What got dropped from the CR

The CR mentioned a `scan` subcommand. Dropped. `diff` already handles "no prior `sources.yaml`" as "everything is `new`", and per-source git commits give us the historical record `scan` would have helped with. Adding `scan` later if a real use case shows up is non-breaking.

## 7. Ingest SKILL rewrite

`skills/ingest/SKILL.md` is rewritten to drop log-grep detection and use the new tool. Behaviorally:

### 7.1 Top of the skill

Insert a "Tooling" section near the top stating that the SKILL invokes `scripts/state-sources.js` for all source-state operations and never hand-edits `wiki/.state/sources.yaml` or grepps `wiki/log.md` for ingest history.

### 7.2 "Identify sources to process" step

Replaces the current Step 1 (`skills/ingest/SKILL.md:16-25`). New text:

1. If the user specified files, use those.
2. Otherwise, run `state-sources begin`. (Idempotent. Ensures a clean baseline.)
3. Run `state-sources diff`. Parse the JSON.
4. For each entry in `new` and `changed`: queue it for ingest.
5. For each entry in `deleted`: show the user the orphaned `previous_wiki_pages` and ask whether to keep them or to delete them. Do not auto-delete.
6. If all three lists are empty, tell the user there's nothing to do.

### 7.3 Per-source loop

For each queued source:

1. Read the source file completely.
2. Discuss key takeaways with the user (unchanged from today).
3. If the entry is `changed`: read each path in `previous_wiki_pages` first. The goal is to **update** those pages, not recreate them.
4. Create/update wiki pages per the existing schema (unchanged from today).
5. When ingest of this source is complete, run `state-sources commit --source <path>`. If the source legitimately produced no wiki output (rubbish source), run with `--allow-empty`.

### 7.4 `log.md` handling

`wiki/log.md` stays. It remains the human-readable narrative. The SKILL still appends a paragraph per ingested source (unchanged from today's Step 7 in `skills/ingest/SKILL.md:104-108`). It is no longer parsed by anything.

### 7.5 Final report

Unchanged from today's Step 8.

## 8. Onboarding wizard touch

`skills/onboard/SKILL.md` is updated minimally:

- The scaffolding step that creates `wiki/`, `raw/`, etc. also creates `wiki/.state/` (empty directory with a `.gitkeep`).
- The wizard's "you need" preamble adds `git` (in addition to Claude Code and Obsidian).
- The wizard runs `git init` if the target directory isn't already a git repo. (Vault git-management is the user's responsibility from there.)

No new wizard questions.

## 9. Distribution and docs

### 9.1 README

Add a "Requirements" line: `git` is now required at runtime, not just for installing the plugin.

### 9.2 REQUIREMENTS.md

A one-line bullet under "Runtime requirements": `git` (the vault is a git repo; state tracking depends on it).

### 9.3 Onboarding wizard text

The wizard's prerequisites screen includes git. If `git --version` fails, the wizard aborts with a clear message and a pointer to install.

### 9.4 Repo-root `package.json`

Currently the repo has no top-level `package.json`. CR-002 introduces one:

```json
{
  "name": "second-brain-plugin",
  "version": "0.2.0",
  "private": true,
  "engines": { "node": ">=18" },
  "dependencies": { "js-yaml": "^4.1.0" }
}
```

Bump the plugin's `.claude-plugin/plugin.json` version to `0.2.0` (this CR is the first user-visible behavior change after CR-001's `0.1.0`).

Install instructions in the README add a single step after cloning: `npm install --omit=dev` (or `npm ci` if the user prefers a lockfile workflow). Onboarding wizard runs this automatically as part of scaffolding if `node_modules/js-yaml` is absent.

## 10. Tests

### 10.1 Automated

A new test file `tests/test_state_sources.sh` exercises the CLI end-to-end against a temp git repo. Cases:

1. **`begin` on clean tree** → no commit created, exit 0.
2. **`begin` with uncommitted wiki changes** → one commit created, message matches.
3. **`diff` with no `sources.yaml`** → all files reported as `new`, none `changed` or `deleted`.
4. **`diff` after a `commit`** → previously committed source not reported.
5. **`diff` when source content changes** → reported in `changed` with `previous_sha256` and `previous_wiki_pages`.
6. **`diff` when source file is deleted** → reported in `deleted` with `previous_wiki_pages`.
7. **`commit --source X` happy path** → `sources.yaml` updated, single git commit produced, wiki pages staged.
8. **`commit --source X` with no wiki changes, no flag** → exit 4, state unchanged.
9. **`commit --source X --allow-empty`** → entry recorded with `wiki_pages: []`, commit message reflects empty.
10. **`commit --source X` with uncommitted non-wiki changes** → exit 6.
11. **Excludes honored** → file under `raw/assets/` never appears in `diff` output.
12. **Deterministic output** — running `diff` twice on identical state yields byte-identical JSON.

The test harness uses bash + Node (matching the `tests/test_register_plugin.sh` precedent). No new test framework.

### 10.2 Manual smoke checklist

1. **Fresh vault.** Onboard a new vault. Confirm `wiki/.state/` exists and is git-tracked.
2. **First ingest.** Drop one file into `raw/`, run `/second-brain:ingest`. Confirm one git commit lands with message `ingest: raw/<file> → N pages`, `sources.yaml` lists the source, and the wiki pages are staged inside that commit.
3. **Re-ingest unchanged.** Run `/second-brain:ingest` again. Skill reports "nothing to do".
4. **Change detection.** Edit one byte of an existing source. Re-run ingest. Skill detects `changed`, reads previous wiki pages, updates them, makes one git commit.
5. **Orphan flow.** Delete a source from `raw/`. Re-run ingest. Skill reports the orphaned wiki pages and asks the user.
6. **Rubbish source.** Drop a one-line nonsense file. Run ingest. SKILL detects nothing worth writing, runs `commit --allow-empty`. Future runs no longer see the file as `new`.
7. **Pre-run baseline.** Make a hand edit to a wiki page outside an ingest run. Then run ingest. Confirm the hand edit lands in a `pre-run baseline` commit before the source's commit.

## 11. Risks and tradeoffs

- **Hard git dependency.** Vaults that aren't git-tracked break. Acceptable per the user's explicit decision; documented in README and onboarding.
- **`git status --porcelain` semantics are stable but text-parsed.** The script depends on the porcelain v1 format. Mitigation: pin behavior with the v1 format documented in `git status --help`, write the parser to accept only the documented status codes.
- **Per-source commits add noise to history.** A 20-source batch ingest creates 20+ commits. The user has chosen this over a single "ingest run" commit because per-source granularity makes `git log -- raw/foo.md` useful. If it becomes annoying, CR-004 could add a "squash on push" hook. Out of scope here.
- **Uncommitted non-wiki changes block commit (exit 6).** If the user is mid-edit on a source file or plugin code when they run ingest, they hit a clear error and run `state-sources begin` first. Friction is the point — it prevents attribution pollution.
- **`js-yaml` becomes a runtime dep.** Small, MIT-licensed, ubiquitous. The alternative (hand-writing a YAML emitter for a known schema) is also viable but ships more code to maintain. Net: dep is the right call.
- **Symlink following.** A symlinked source inside `raw/` is hashed by content, so a swap of the symlink target counts as a change. Intended.

## 12. Open questions deferred

- Should `lint` later add an "orphaned wiki pages" check that walks `sources.yaml.wiki_pages` ∪ filesystem? Yes, but that's lint's spec, not this one.
- Whether `state-sources` should grow a `--json` flag on `begin` and `commit` for SKILL parsing of structured results. Not needed yet — those commands' stdout is short status; the SKILL can read it as text.
- Whether to add `scan` later as a debug subcommand. Add it only if a concrete use case shows up.

## 13. Out of scope (carried from CR-002)

- `kind: structured` handling (CR-003).
- Hooks that auto-invoke `state-sources` (CR-004).
- An operation-history YAML beyond what git already provides.
