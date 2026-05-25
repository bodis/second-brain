# CR-006 Runbook — Roll second-brain into yettel + sibling vaults

Copy-paste sequence to install the plugin and scaffold each of the four sibling vaults. Run **pre-flight once**, then the per-vault block once for each vault in the listed order.

**Targets** (in rollout order): `yettel` → `personal` → `otp` → `nitrowise`.

Order rationale: `yettel` first per CR (it's the payoff target). `personal` second because the user knows the domain best — easiest dry-run for the new in-place flow before committing to the work vaults. If `yettel` fails, **stop**. Fix forward — do not bulk-rollout.

---

## Pre-flight (one-time)

Add the local marketplace and install the plugin at user scope so `/second-brain:onboard` is discoverable in every directory.

```
/plugin marketplace add /Users/bodist/work/contexts/second-brain
/plugin install second-brain@second-brain
```

Verify:

```
/plugin
```

Expect to see `second-brain` listed as installed. Then in a fresh prompt, confirm the slash command is discoverable: typing `/second-brain:` should auto-complete to the five skill names (`onboard`, `ingest`, `query`, `lint`, `reorganize`).

If `/plugin install` errors with "marketplace not found", run `/plugin marketplace update second-brain` and retry.

---

## Per-vault block (run once per vault)

Substitute `<name>` with `yettel`, `personal`, `otp`, `nitrowise` in order.

```
cd /Users/bodist/work/contexts/<name>
/second-brain:onboard
```

The wizard will:

1. Detect in-place mode (`.obsidian/` present, `wiki/` absent).
2. **Skip the location question** and set `VAULT_PATH=$(pwd)`.
3. Ask for the **title** (default = `<name>`, accept it).
4. Ask for the **domain** — answer per vault, e.g. *"Yettel API integrations"*, *"personal health and projects"*, *"OTP banking research"*, *"nitrowise notes"*.
5. Ask **settings scope**. Default `(a) Just this vault` is fine; the hint suggests `(b) All my projects` for one-shot multi-vault registration. Pick whichever — pre-flight already user-scope-registered the plugin, so both are functionally fine.
6. Ask **optional CLI tools**. Skip on the first vault; revisit if you want them later.

After the wizard prints its summary, verify (3 commands):

```
ls wiki/index.md wiki/log.md CLAUDE.md
node /Users/bodist/work/contexts/second-brain/scripts/validate-wiki.js all
git -C . log --oneline
```

Expectations:

- `ls` shows all three files.
- `validate-wiki.js all` exits 0 and reports clean (no broken links, no orphan pages, empty index is fine).
- `git log --oneline` may be empty. `onboarding.sh` does not commit on your behalf; the "Vault initialized" entry in `wiki/log.md` is unstaged. Stage and commit when you're ready.

Obsidian: switch to it and `File → Reload app` (or restart) to pick up the new `wiki/`, `raw/`, `src/`, `output/` folders alongside `.obsidian/`.

---

## Troubleshooting

- **`npm install` fails during scaffold Step 2:** the plugin's runtime dep (`js-yaml`) didn't install. Run manually: `cd /Users/bodist/work/contexts/second-brain && npm install --omit=dev`, then re-run `/second-brain:onboard`.

- **`register-plugin.js` reports a `settings.json` conflict:** the script is idempotent across vaults; re-run the same command. If it still errors, the target `settings.json` is not valid JSON — hand-fix it and verify with `/plugin`.

- **`git init` permission error:** the vault dir is not owned by you. Don't `sudo` — investigate ownership (`ls -la /Users/bodist/work/contexts/<name>`) and fix permissions first.

- **Obsidian doesn't see the new folders:** `File → Reload app`, or restart Obsidian. The plugin scaffolds siblings of `.obsidian/`; Obsidian needs a refresh to index them.

- **`validate-wiki.js all` reports failures on a fresh empty vault:** that's a bug. File an issue. The expected output is clean (empty index, no orphans, no broken links).

- **Wizard refuses with "already onboarded" or "orphaned scaffold":** the in-place abort guards (CR-006) tripped. "Already onboarded" means `.obsidian/` and `wiki/` both exist — use `/second-brain:lint` instead. "Orphaned scaffold" means `wiki/` exists but `.obsidian/` does not — open the dir in Obsidian first.

- **`CLAUDE_PLUGIN_ROOT` unset during scaffold:** local-path-installed plugins should have it set automatically. If they don't, run `cd /Users/bodist/work/contexts/second-brain && npm install --omit=dev` manually (the post-wizard scaffold script will skip that step on the next run because `node_modules/js-yaml` already exists).

- **Rollout halt:** if any vault fails, stop the per-vault loop. Fix the failure in that vault before moving on — do not skip ahead.
