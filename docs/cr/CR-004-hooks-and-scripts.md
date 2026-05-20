# CR-004 — Deterministic structural checks + hook framework

**Depends on:** CR-002. (Needs the YAML state store and the `wiki/.state/` convention to exist.)

**Related (downstream):** CR-005 (`/reorganize` consumes these scripts), CR-007 (contradictions), CR-008 (staleness), CR-009 (`/status` consumes the JSON output).

## Problem

`lint/SKILL.md` today asks the LLM to "scan all wiki pages for `[[wikilink]]` references and verify the target page exists", to diff `wiki/index.md` against the filesystem, and to spot-check frontmatter. These are deterministic graph and parse operations. The LLM has to remember to do them, do them correctly, and not skim — and the work isn't reproducible across runs. Scripts can do all of this faster and verifiably, leaving the LLM free for the judgment items (contradictions, staleness, suggested cross-references) where it actually adds value.

## Motivation

[Conventions §4](./conventions.md) says: hooks-first, LLM-last for verifiable work. This CR establishes the framework — what scripts exist, what they output, when hooks fire — so `lint/SKILL.md` can shrink to prose plus script calls, and CR-005/007/008/009 can build on the same plumbing rather than reimplementing it.

## Scope

In scope:

- One Node validator binary (`scripts/validate-wiki.js`) with three subcommands: `frontmatter`, `wikilinks`, `index`, plus an `all` aggregator.
- One opt-in fixer (`scripts/sync-index.js`).
- A versioned **frontmatter contract** file at `wiki/.state/frontmatter-contract.yaml`.
- One **Stop hook** declared in `.claude-plugin/plugin.json` that runs `validate-wiki.js all`.
- Tests under `tests/` following CR-002's shell-test pattern.
- A refactor of `lint/SKILL.md` to call the scripts instead of prosing about the checks.

Out of scope:

- `/reorganize` (CR-005).
- Auto-fix automation beyond `sync-index.js`.
- Pre-commit git hooks for the user's vault — Claude Code hooks only.
- Contradiction detection, staleness review, missing-page suggestions, data-gap analysis (CR-007/008/009).
- Migrating `state-sources.js` from `skills/ingest/scripts/` to the shared `scripts/` directory. Defer to a future cleanup CR.
- Building the `/status` dashboard. CR-004 only ensures `--json` output is consumable.

## Runtime alignment

CR-004's original draft said "pure bash + python3 with PyYAML." Reality from CR-002: the plugin runs on **Node ≥18 with `js-yaml`** (declared in `package.json`). All new scripts in CR-004 use the same runtime. No new dependencies.

This should also be noted in `conventions.md` so future CRs don't repeat the mistake — either by amending §3 or adding a §7 "Script runtime".

## Layout

```
plugin-root/
├── scripts/                              # NEW — shared, plugin-wide.
│   ├── validate-wiki.js                  # NEW.
│   └── sync-index.js                     # NEW.
├── skills/
│   ├── ingest/scripts/state-sources.js   # unchanged (CR-002).
│   ├── lint/SKILL.md                     # refactored (smaller).
│   └── onboard/scripts/…                 # unchanged.
├── tests/
│   ├── test_validate_wiki.sh             # NEW.
│   ├── test_sync_index.sh                # NEW.
│   └── fixtures/validate-wiki/           # NEW — tmp-vault fixtures.
└── .claude-plugin/plugin.json            # gains a "hooks" block.
```

Shared scripts live at the plugin root because they have multiple consumers (lint, `/reorganize`, the Stop hook, and CR-009's `/status`). Keeping them out of `skills/lint/scripts/` avoids making lint a de-facto utility owner.

## Frontmatter contract

The required-key contract is a top-level fact about the wiki, not a detail buried in `ingest/SKILL.md`'s template prose. Lift it into a versioned file:

```
wiki/.state/frontmatter-contract.yaml
```

Initial contents (schema_version 1):

```yaml
schema_version: 1
generated_by: scripts/validate-wiki.js   # convention §3; identifies the validator that owns this contract's schema
targets:
  - wiki/sources/**/*.md
  - wiki/entities/**/*.md
  - wiki/concepts/**/*.md
  - wiki/synthesis/**/*.md
exempt:
  - wiki/index.md
  - wiki/log.md
required:
  tags:
    type: list[string]
    may_be_empty: true
  sources:
    type: list[string]
    may_be_empty: false
  created:
    type: date
    format: YYYY-MM-DD
  updated:
    type: date
    format: YYYY-MM-DD
unknown_keys: allowed
```

Properties:

- **Forward-compatible.** `unknown_keys: allowed` means adding new optional fields (e.g., Obsidian's `aliases:`) does not break older vaults.
- **Versioned.** Bumping `schema_version` is the explicit signal that the contract changed; the validator can refuse to operate on an unknown version and prompt the user to upgrade.
- **Single source of truth.** `ingest/SKILL.md` gets a one-line pointer to the contract instead of duplicating the field list in its template. The contract file becomes the only place to edit when the shape changes.

`onboard` creates this file as part of vault scaffolding. CR-001 has already shipped, so the scaffolding update happens in CR-004's implementation plan — likely a small edit to `skills/onboard/scripts/onboarding.sh` (or wherever `wiki/.state/` is initialized) to also drop in `frontmatter-contract.yaml`.

## `validate-wiki.js` contract

One binary, four subcommands, mirroring `state-sources.js`. Each subcommand supports `--json` for machine consumption and prints a human summary otherwise.

| Subcommand | Checks | `--json` output | Exit code |
|---|---|---|---|
| `frontmatter` | YAML parses; required keys present with correct type; dates well-formed per the contract. Skips files matching `exempt:`. | `{errors: [{path, key, problem}], warnings: []}` | `0` clean, `2` structural error |
| `wikilinks` | Every `[[target]]` in a `wiki/**/*.md` page resolves to a real file (`wiki/**` for bare-name and `wiki/**`-form path links; `src/documentation/**` for documentation-path-form links — see Wikilink parsing). Lists orphans (pages with zero inbound `[[…]]`). | `{broken: [{from, target}], orphans: [{path}]}` | `0` clean, `1` warnings present (broken or orphan), never `2` |
| `index` | Every `wiki/{sources,entities,concepts,synthesis}/**/*.md` has a row in `wiki/index.md`; no rows point to non-existent files. | `{missing_rows: [path…], dead_rows: [entry…]}` | `0` clean, `1` missing rows only, `2` dead row (structural) |
| `all` | Runs the three above; aggregates output and exit code. | `{frontmatter: {…}, wikilinks: {…}, index: {…}}` | `max(child exit codes)` |

**Exit-code semantics — shared across all subcommands:**

- `0` clean. Hook stays silent.
- `1` warnings. Things the LLM could improve but doesn't need to fix mid-session (broken `[[Unwritten Concept]]` link, orphan page that might be intentional, missing index row that `sync-index.js` can fix).
- `2` structural error. Things that break the vault's invariants (frontmatter doesn't parse, required key missing, dead index entry). The Stop hook returns nonzero on `2`, forcing the LLM to fix before handing back.

**Shared utilities** (vault-root lookup, YAML helpers, glob walking) live as private functions inside `validate-wiki.js`. No `lib/` directory — same single-file shape as `state-sources.js`. Re-evaluate if a third validator appears.

**Vault detection** (used by all subcommands): walk up from `CLAUDE_PROJECT_DIR` (env var set by Claude Code, falling back to `process.cwd()`) until finding a directory that contains both `.git/` and `wiki/.state/sources.yaml`. If none found, exit `0` silently — this is how the universally-fired Stop hook self-gates outside second-brain vaults.

**Wikilink parsing.** Accept three target forms, all of which ingest writes per `ingest/SKILL.md` §4:

1. **Bare name** — `[[Concept Name]]`. Resolved by Obsidian's filename-match rule: search all of `wiki/` for a `.md` whose basename (without extension) equals the target, case-insensitive. Hit = link resolves.
2. **Wiki path** — `[[wiki/concepts/concept-name]]`. Resolved against vault root + `.md` extension. The file must exist under `wiki/`.
3. **Documentation path** — `[[src/documentation/confluence/api/auth]]`. Resolved against vault root + `.md`. The file must exist under `src/documentation/`. This is the documented citation form for structured sources.

Any wikilink whose target does not resolve under one of the three rules is reported as broken. Aliases (`aliases:` frontmatter — Obsidian-native) are not considered in v1; see Open questions.

## `sync-index.js` — opt-in fixer

Separate script, separate UX. Reads filesystem reality under `wiki/{sources,entities,concepts,synthesis}/` and rewrites `wiki/index.md` to match. Idempotent: running twice in a row produces no change. **Never invoked by a hook** — only by lint when the user opts in, because auto-fixing the index mid-session could step on an LLM that is partway through a write.

Output: `0` clean, prints the diff it applied (or "no changes" if already in sync).

## Hook surface

In `.claude-plugin/plugin.json`, add one Stop hook:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"${CLAUDE_PLUGIN_ROOT}/scripts/validate-wiki.js\" all"
          }
        ]
      }
    ]
  }
}
```

Notes on the shape:

- **No skill-scoped matcher exists** for `Stop` per the Claude Code docs (`reference/hooks.md`, `automation/hooks-guide.md`). The hook fires at the end of every Claude Code session that includes this plugin. The validator self-gates: outside a second-brain vault, it exits `0` immediately (see vault detection above), so the cost outside the intended scope is one Node startup with a few `fs.existsSync` calls.
- **`stop_hook_active` guard.** Per the docs' "Stop hook runs forever" guidance, the validator reads its stdin JSON and, if `stop_hook_active` is `true`, exits `0` without doing work. This prevents the loop where the LLM fixes the error, tries to stop again, and the hook flags new issues forever.
- **Exit code routing.** Exit code `2` is the documented way to block stop and surface stderr to the LLM. Exit code `1` is "warnings" — hook writes summary to stderr but exits `0` so Claude can stop.
- **`${CLAUDE_PLUGIN_ROOT}`** is the documented variable for referencing plugin-shipped scripts and is exported as an env var to hook processes (`reference/plugins-reference.md`).

**No PostToolUse or PreToolUse hooks.** Rationale: every alternative considered (PostToolUse on `wiki/**`, on `wiki/index.md` only, etc.) violates the project's low-touch UX preference and creates noise during ingest's 10-15-write cycles. Stop is the right point: the LLM has finished, the hook gets one chance to flag issues, the LLM either fixes and re-stops or hands back. Revisit only if Stop-only proves insufficient in practice.

## Output and visibility

Hook output is the user-visible surface for the validator. Defaults:

- Exit `0`: silent. Nothing written to stderr.
- Exit `1`: single-line summary per category to stderr — e.g., `wikilinks: 3 broken, 1 orphan`. No file lists by default; the LLM (or `/status`, CR-009) requests `--json` for details.
- Exit `2`: structural summary to stderr — e.g., `frontmatter: wiki/entities/foo.md missing required key 'sources'`. Enough for the LLM to know which file to open and fix.

The `--json` mode is for machine consumers (CR-009's `/status` aggregator, future tooling). It is never the default — humans don't want JSON dumped into the transcript on a normal Stop.

## `lint/SKILL.md` refactor (deliverable of this CR)

After CR-004 ships, `lint/SKILL.md` is restructured:

- §1 broken wikilinks → "run `node \"${CLAUDE_PLUGIN_ROOT}/scripts/validate-wiki.js\" wikilinks --json` and present its `broken` array."
- §2 orphan pages → folded into the wikilinks output (`orphans:` key). Drop the separate §2.
- §7 index consistency → "run `validate-wiki.js index --json`. If `missing_rows` is non-empty, offer to run `sync-index.js`."
- §3 contradictions, §4 stale claims, §5 missing pages, §6 missing x-refs, §8 data gaps → **stay as LLM-judgment prose.** CR-007/008 will move some of these into their own skills later; CR-004 does not touch them.

Net effect: lint's deterministic surface goes from 3 prose checks to 2 script calls, and the remaining 5 prose items are unambiguously about judgment, not verification.

## Testing

Follow the `tests/test_state_sources.sh` pattern: bash scripts that scaffold a tmp vault, invoke the validator, and assert on exit codes and `--json` output via `jq`.

Fixture vaults under `tests/fixtures/validate-wiki/`:

| Fixture | Asserts |
|---|---|
| `clean/` | All three subcommands exit `0`. |
| `frontmatter-missing-key/` | `frontmatter` exits `2`; JSON `errors[0].key === 'sources'`. |
| `frontmatter-bad-date/` | `frontmatter` exits `2`; JSON identifies malformed `updated`. |
| `wikilink-broken/` | `wikilinks` exits `1`; JSON `broken[]` includes the offender. |
| `wikilink-orphan/` | `wikilinks` exits `1`; JSON `orphans[]` includes the page; `broken[]` empty. |
| `index-missing-row/` | `index` exits `1`; JSON `missing_rows[]` includes the new page. |
| `index-dead-row/` | `index` exits `2`; JSON `dead_rows[]` includes the stale entry. |
| `not-a-vault/` | All subcommands exit `0` silently — vault detection rejects the dir. |

`sync-index.js` gets its own tests: round-trip a drifted vault back to clean; verify the second run is a no-op.

## Resolved open questions (from the original CR-004 draft)

| Original question | Resolution |
|---|---|
| Hook execution location / path resolution | `${CLAUDE_PLUGIN_ROOT}` per docs. Validated against `reference/plugins-reference.md`. |
| Which hooks block vs warn | Structural errors (`2`) block; broken-link / orphan / missing-row warnings (`1`) do not. Detail in **Exit-code semantics**. |
| Auto-fix vs report-only | `sync-index.js` is opt-in only; never wired to a hook. |
| Hook firing cost / noise | Solved by Stop-only + self-gating vault detection. No PostToolUse. |
| Output verbosity | Silent on `0`; one-line summary on `1`/`2`; `--json` opt-in for machine consumers. |

## Open questions

- **Plugin Stop hook scope.** Confirm during implementation that a plugin-declared Stop hook in `.claude-plugin/plugin.json` fires for sessions in any cwd (it should, per the docs), so that self-gating in the script is the right strategy. If it turns out plugin hooks only fire in plugin-managed contexts, the design simplifies (no self-gate needed) — but the validator's vault-detection logic stays harmless either way.
- **Obsidian alias resolution.** If a user defines `aliases:` on a page (Obsidian-native, currently outside our contract), bare-name wikilinks may resolve via alias. Initial version ignores aliases — `[[Alias]]` to a page whose filename differs will be reported as broken. Acceptable for v1; revisit if it generates noise.
- **`schema_version` mismatch behavior.** When `frontmatter-contract.yaml`'s `schema_version` is higher than what the script knows, the script exits `2` with a clear stderr message ("contract is newer than the validator; upgrade the plugin"). Confirm exact wording during the plan. A lower `schema_version` than the script understands is also exit `2` — the user needs to re-scaffold or the validator needs a migration helper, not a silent guess.
