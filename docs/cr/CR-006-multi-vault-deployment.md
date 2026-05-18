# CR-006 — Roll plugin out to yettel + sibling vaults

**Depends on:** CR-001 (must be a plugin). Best after CR-002..CR-005 (so vaults start on the upgraded schema), but partial rollout is possible after CR-001 alone.

## Problem

Four empty Obsidian vault directories exist as siblings of this repo:

- `/Users/bodist/work/contexts/yettel/`   ← first target
- `/Users/bodist/work/contexts/nitrowise/`
- `/Users/bodist/work/contexts/otp/`
- `/Users/bodist/work/contexts/personal/`

Each contains only `.obsidian/`. None has `raw/`, `wiki/`, `CLAUDE.md`, or anything else the plugin produces. The user wants to install the upgraded second-brain plugin into each, starting with `yettel`.

## Motivation

This is the payoff for CR-001..CR-005. Once the plugin is upgraded, each vault gets a one-command install + scaffold + agent-config.

## Proposed approach

1. Install the plugin from the local path:
   ```
   claude /plugin install /Users/bodist/work/contexts/second-brain
   ```
   (Exact syntax per CR-001's `plugin.json`; verify against `<claude-code-docs>/customize-behavior/plugins.md` during plan.)

2. For each vault directory, run:
   ```
   cd /Users/bodist/work/contexts/<name>
   /second-brain:onboard
   ```
   The onboard skill (post-CR-001) handles scaffold + `CLAUDE.md`.

3. For `yettel` specifically: also seed initial structured documentation under `src/documentation/<system>/` if the user has any exports ready. (The exports themselves are out of scope of this CR.)

4. Capture exact commands + per-vault verification in `docs/cr/CR-006-runbook.md` (created during implementation, not now).

## Open questions

- Should the onboard skill detect that `.obsidian/` already exists and skip Obsidian-related setup? Probably yes — the user already opened the folder in Obsidian.
- Per-vault domain/tags differ (yettel ≠ personal). The onboard wizard collects these per vault — no shared config to worry about.
- Plugin updates: when CR-002..CR-005 land *after* a vault was already onboarded with CR-001 only, does the plugin update flow handle schema migration? Depends on what CR-002's `state-sources.sh` does on a vault with no existing state file. Recommend: scripts treat missing state as "all sources are new" and let user re-ingest if desired.
- Initial git state per vault: do we `git init` each vault during onboarding? Probably yes (vaults benefit from git history); confirm during plan.

## Out of scope

- Actually ingesting content into each vault.
- The auto-scraper for structured docs.
- Any new skills beyond what CR-001..CR-005 deliver.
- Sharing concepts/entities between vaults — each vault is independent.
