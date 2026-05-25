# CR-001 — Convert repo to a Claude Code plugin (drop multi-agent)

**Depends on:** none. Blocks everything else.

## Problem

The repo distributes itself via `npx skills add NicholasSpisak/second-brain` — a third-party tool that copies `skills/*` into whatever agent's skill folder happens to be present. It's not a Claude Code plugin:

- No `.claude-plugin/plugin.json`.
- Skill names are bare (`/second-brain-ingest`), not namespaced (`/second-brain:ingest`).
- Templates exist for four different agents (`references/agent-configs/{claude-code,codex,cursor,gemini}.md`) plus auto-detection logic in the onboarding SKILL.
- README install path is wrong for this fork (`NicholasSpisak/second-brain`).

The user only uses Claude Code. Carrying the other three agents costs maintenance with zero benefit.

## Motivation

A proper plugin gives versioned distribution (`/plugin install` via marketplace or local path), clean namespacing, and access to the Claude Code hook system that CR-004 depends on. Without it, every downstream CR either reaches around the SKILL contract or stays limited to in-SKILL prose.

## Proposed approach

1. Add `.claude-plugin/plugin.json` at repo root: `name: second-brain`, `version`, `description`, `author`, `repository`.
2. Rename skill directories from `second-brain-ingest` etc. to `ingest`, `query`, `lint`, `onboard` — plugin namespacing prefixes them with `second-brain:` automatically.
3. Delete the three non-Claude-Code templates and the agent-detection logic in `onboard/SKILL.md`. Drop the `## Step 4: Agent Config` wizard step entirely; always generate `CLAUDE.md`.
4. Replace the README install instructions with `/plugin install ...` flows (local-path + optional marketplace).
5. Update all internal cross-references (skill names in SKILL.md files, README, REQUIREMENTS.md).
6. Keep `tests/test_onboarding.sh` working — the script path moves with the rename.

Reference: Claude Code docs at `customize-behavior/plugins.md` and `tools-and-plugins/plugins.md` (see [conventions.md §2](./conventions.md)).

## Open questions

- Marketplace strategy: publish to a public marketplace, or keep local-install-only? Local-only is simpler for now.
- Where does `plugin.json`'s `version` field live in our release flow? Bump per CR or per group of CRs?
- Does the onboard SKILL still need a wizard, or can plugin install assume the user is already in a vault directory? Probably keep the wizard, but simplify since multi-agent is gone.

## Out of scope

- New skills (CR-005).
- Schema changes inside vaults (CR-002, CR-003).
- Hooks (CR-004) — only referenced from `plugin.json` after CR-004 lands.
