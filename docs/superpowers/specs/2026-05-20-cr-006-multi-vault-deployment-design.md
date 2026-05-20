# CR-006 Design — Roll plugin out to yettel + sibling vaults

**Status:** Draft, pending user review
**Date:** 2026-05-20
**CR:** [CR-006](../../cr/CR-006-multi-vault-deployment.md)
**Conventions:** [docs/cr/conventions.md](../../cr/conventions.md)
**Depends on:** CR-001..CR-005 (all landed). Rollout happens on the upgraded schema, so the "partial rollout" schema-migration concern in CR-006's open questions is moot.

## 1. Problem

Four empty Obsidian vault directories exist as siblings of this repo:

- `/Users/bodist/work/contexts/yettel/`
- `/Users/bodist/work/contexts/nitrowise/`
- `/Users/bodist/work/contexts/otp/`
- `/Users/bodist/work/contexts/personal/`

Each contains only `.obsidian/` — no `raw/`, no `wiki/`, no `CLAUDE.md`. The user wants the upgraded `second-brain` plugin installed and scaffolded into each.

The onboard skill (`skills/onboard/SKILL.md`) already does git-init, scaffold, `CLAUDE.md` generation, plugin registration, log entry, and optional CLI tools. But its wizard Steps 1–2 (Vault Name + Vault Location) **assume the vault directory does not yet exist** and that onboard creates it under `~/Documents/` or a user-supplied path. That assumption breaks for CR-006: the four target dirs already exist and the user wants the scaffold dropped *in place*.

## 2. Goals

- Onboard learns an **in-place mode**, auto-detected from the cwd. When triggered, it skips Steps 1–2 and treats cwd as the vault.
- Greenfield (new-directory) onboarding flow is untouched.
- A runbook at `docs/cr/CR-006-runbook.md`, committed in this CR, gives the user a copy-paste rollout sequence per vault plus verification + troubleshooting.
- Plugin installed from local path (`/Users/bodist/work/contexts/second-brain`), not a marketplace.
- Each vault ends up with: `.git/`, `wiki/` (index + log), `raw/`, `src/documentation/`, `output/`, `CLAUDE.md`, plugin registered in either project- or user-scope settings.

## 3. Non-goals

- **Ingesting content** into any vault. The user drops sources in later; this CR ends at scaffold.
- **Auto-scraper for structured docs** (out of scope per CR-006).
- **Seeding `src/documentation/yettel/...`** with real exports — the empty directory is enough.
- **New skills.** Only an existing-skill behavior change.
- **Marketplace publish.** Local-path install is sufficient; marketplace can be a later CR if needed.
- **Cross-vault sharing** of concepts, entities, or tags. Each vault is independent (CR-006).
- **Re-onboarding support.** If a vault already has `wiki/`, onboard aborts. No `--force` flag.
- **State-schema migration** for vaults that were ever onboarded under CR-001 only. The rollout happens after CR-002..CR-005, so all vaults start on the full schema.
- **Touching `.obsidian/`.** The plugin scaffolds sibling directories; Obsidian picks them up on its next refresh.

## 4. In-place mode for onboard

### 4.1 Detection truth table

At the very start of the wizard, onboard checks `pwd` for two signals:

| `.obsidian/` | `wiki/` | Mode | Behavior |
|---|---|---|---|
| absent | absent | greenfield | current flow: ask name + location, create dir under chosen path |
| **present** | **absent** | **in-place (new)** | cwd is the vault; skip Step 2; reframe Step 1 |
| absent | present | abort | print *"Vault scaffold exists but no Obsidian config. Open the directory in Obsidian first to create `.obsidian/`, then re-run."* |
| present | present | abort | print *"This vault appears already onboarded. Re-running `/second-brain:onboard` is not supported. Use `/second-brain:lint` to check health, or open a CR if a re-scaffold is genuinely needed."* |

Both abort cases stop before any filesystem change. If the guard is implemented in the onboarding script, "stop" means exit non-zero; if it's implemented in `SKILL.md` prose, "stop" means the LLM halts the wizard and prints the message without invoking the scaffold. §9 leaves the placement decision to the plan.

### 4.2 Wizard changes when `IN_PLACE=true`

- **Step 1 — Vault Name** reframed to *"What title should I use for this knowledge base in CLAUDE.md?"* with default = basename of cwd (e.g. `yettel`). The title is used only as the display name in the generated `CLAUDE.md`; it does not create a directory and is not lowercased or title-cased automatically.
- **Step 2 — Vault Location** **skipped**. `VAULT_PATH=$(pwd)`.
- **Step 3 — Domain / Topic** unchanged. Each vault has its own domain (yettel ≠ personal); the wizard collects it per run.
- **Step 4 — Settings Scope** unchanged in defaults, but **adds a hint** when `IN_PLACE=true`:
  > *"You're onboarding into an existing dir. If you plan to onboard multiple vaults (yettel, personal, etc.), `(b) All my projects` registers the plugin once for all of them. Default `(a)` still works — pick it per vault if you want fine-grained control."*

  Default stays `(a) Just this vault`. The hint nudges; it does not override.
- **Step 5 — Optional CLI Tools** unchanged.

### 4.3 Post-wizard scaffold changes when `IN_PLACE=true`

- **Step 1 (git init)** unchanged. `git init -q` is idempotent; safe whether the dir is already a git repo or not.
- **Steps 2–7** unchanged. In particular:
  - `register-plugin.js` is already idempotent (per its own doc); re-running it across four vaults at user-scope merges cleanly.
  - The onboarding script creates `wiki/`, `raw/`, `src/documentation/`, `output/` alongside the pre-existing `.obsidian/` without touching it.
- **Step 8 (summary)** drops the "open the vault folder in Obsidian" instruction (the user is clearly already in Obsidian — `.obsidian/` is the proof). Adds instead:
  > *"Obsidian may need a manual refresh (File → Reload app) to see the new `wiki/`, `raw/`, `src/`, and `output/` folders."*

## 5. Rollout runbook (`docs/cr/CR-006-runbook.md`)

Committed in this CR as a deliverable, not deferred. Sections:

### 5.1 Pre-flight (one-time)

- Plugin install command. The exact syntax must be verified against `<claude-code-docs>/customize-behavior/plugins.md` during the writing-plans pass — the design assumes `/plugin install /Users/bodist/work/contexts/second-brain` but the implementation step is responsible for confirming.
- Verification: `/plugin` (or equivalent) lists `second-brain` as installed; `/second-brain:onboard` is discoverable as a slash command.

### 5.2 Per-vault block (× 4)

One block per vault, in this order: **yettel → personal → otp → nitrowise**. Yettel first per CR. Personal second because the user knows the domain best — easiest dry-run for the new in-place flow before committing to the work vaults.

Each block is copy-paste-ready:

```
cd /Users/bodist/work/contexts/<name>
/second-brain:onboard
# Wizard skips name+location; provide title, domain, settings-scope answer, CLI tools answer.

# Verify (3 lines):
ls wiki/index.md CLAUDE.md
node /Users/bodist/work/contexts/second-brain/scripts/validate-wiki.js all
git -C . log --oneline   # expect "Vault initialized" log entry from onboard
```

### 5.3 Troubleshooting

- `npm install` fails during scaffold Step 2: fall back to `cd <plugin-root> && npm install --omit=dev` manually (onboard SKILL.md already documents this).
- `register-plugin.js` reports a settings.json conflict: re-running is idempotent; if it still fails, hand-edit and re-verify with `/plugin`.
- `git init` permission error: usually a sign the dir isn't owned by the user. Don't `sudo` — investigate ownership first.
- Obsidian doesn't see new folders: File → Reload app, or restart Obsidian.
- Lint reports failures on a fresh empty vault: that's a bug — file an issue. The expectation is clean output (no broken links, no orphan pages, empty index is OK).

## 6. Testing

### 6.1 Automated

Extend the existing `tests/test_onboarding.sh` (or add a sibling `tests/test_onboarding_inplace.sh` — to be decided by the plan, both shapes are fine). Cases:

1. **In-place happy path.** Create tempdir with `.obsidian/`, drive the scaffold path with `IN_PLACE=true` and a fixed title/domain. Assert: `wiki/index.md`, `wiki/log.md`, `raw/`, `src/documentation/`, `output/`, `CLAUDE.md`, `.git/` all exist. `CLAUDE.md` contains the supplied title and domain. `wiki/log.md` contains a "Vault initialized" entry.
2. **Greenfield path** (regression). Existing assertions stand.
3. **Abort: already onboarded.** Tempdir with both `.obsidian/` and `wiki/`. Scaffold path exits non-zero, no filesystem change.
4. **Abort: orphaned scaffold.** Tempdir with `wiki/` but no `.obsidian/`. Same: exits non-zero, no filesystem change.

The detection itself lives in `SKILL.md` prose (the LLM does the check at wizard start), so steps 3–4 may need their assertions expressed at the scaffold-script layer too if the script gets a guard. The plan decides where the guard sits; the spec only requires that the four cases behave as described.

### 6.2 Manual smoke

1. Install the plugin locally per the runbook.
2. Run `/second-brain:onboard` in `yettel`. Confirm wizard skips Steps 1–2's location prompt, confirm scaffold lands, confirm `/second-brain:lint` reports clean.
3. Repeat for the remaining three. If any vault fails, fix before continuing — do not bulk-rollout.

## 7. Risks and edge cases

- **`.obsidian/` settings drift.** Each vault's `.obsidian/` was created by the user; settings may differ. Out of scope — the plugin only writes to siblings of `.obsidian/`, never inside it.
- **`CLAUDE_PLUGIN_ROOT` resolution.** When installed from a local path, Claude Code is expected to point `$CLAUDE_PLUGIN_ROOT` at `/Users/bodist/work/contexts/second-brain/`. Onboard's scripts rely on this for the one-time `npm install --omit=dev`. If a local-path install does *not* set `$CLAUDE_PLUGIN_ROOT`, the plan must surface this and propose a fallback.
- **User-scope plugin registration written four times.** `register-plugin.js` is idempotent per its own doc; this is verified in the existing `tests/test_register_plugin.sh`. No design-level change needed, just a callout for the plan.
- **The yettel vault gets `src/documentation/` scaffolded empty.** CR-006 hints at seeding it with real exports later; this CR creates the empty directory and stops. The user drops files in afterward (or `doc-downloader` does).
- **Rollout-order recovery.** If the in-place flow fails on `yettel`, the runbook stops there. Don't continue to the remaining three. Fix forward.

## 8. Out of scope (reaffirms CR-006)

- Ingesting content into any vault.
- Auto-scraper for structured docs.
- New skills beyond what CR-001..CR-005 deliver.
- Cross-vault sharing of concepts, entities, or tags.
- Marketplace publish of the plugin.
- Re-onboarding / `--force` flag.

## 9. Open questions for the plan (not the spec)

These are deliberately deferred to writing-plans, not decided here:

- Exact `/plugin install` syntax — verify against `<claude-code-docs>/customize-behavior/plugins.md`.
- Whether the in-place guard (abort cases in §4.1) is enforced in `SKILL.md` prose, in the onboarding script, or both. Either is acceptable; the plan picks one.
- Whether the in-place test goes in the existing `tests/test_onboarding.sh` or a sibling file. Both shapes pass the testing requirements in §6.1.
