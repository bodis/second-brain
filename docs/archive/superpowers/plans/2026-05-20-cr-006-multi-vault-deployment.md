# CR-006 Multi-Vault Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach `/second-brain:onboard` an "in-place mode" so it scaffolds the four existing sibling Obsidian vaults (`yettel`, `personal`, `otp`, `nitrowise`) without trying to create a new directory under `~/Documents/`, then ship a copy-paste runbook for rolling the plugin out into each vault.

**Architecture:** One narrow behavior change to `skills/onboard/scripts/onboarding.sh` (two abort guards at the top, runs identically for greenfield otherwise), plus prose changes to `skills/onboard/SKILL.md` (a detection preamble, a reframed Step 1, a skipped Step 2, a Step 4 hint, a Step 8 summary tweak). Plus a new `docs/cr/CR-006-runbook.md` capturing pre-flight + per-vault sequence + troubleshooting. No new scripts, no new tests harness — extend `tests/test_onboarding.sh` with three cases (in-place happy, abort-already-onboarded, abort-orphaned-scaffold) and drop the now-invalid idempotency case.

**Tech Stack:** Same as the rest of the plugin — bash + Node 18+. No new dependencies. The pre-existing `register-plugin.js` is idempotent and unchanged.

**Reference spec:** [`docs/superpowers/specs/2026-05-20-cr-006-multi-vault-deployment-design.md`](../specs/2026-05-20-cr-006-multi-vault-deployment-design.md). CR: [`docs/cr/CR-006-multi-vault-deployment.md`](../../cr/CR-006-multi-vault-deployment.md).

---

## File Structure

**Create:**
- `docs/cr/CR-006-runbook.md` — pre-flight install + per-vault block × 4 + troubleshooting. Committed as part of this CR.

**Modify:**
- `skills/onboard/scripts/onboarding.sh` — add two abort guards at the top (already-onboarded; orphaned-scaffold) before any filesystem mutation. Greenfield + in-place happy paths are unchanged.
- `skills/onboard/SKILL.md` — add a Detection preamble before Step 1, reframe Step 1 / skip Step 2 / hint Step 4 / tweak Step 8 when in-place.
- `tests/test_onboarding.sh` — replace the legacy "idempotency" case (Test 4) with three new cases: in-place happy, abort already onboarded, abort orphaned scaffold.

**Decisions locked in:**
- **Guard placement:** the script (`onboarding.sh`), not just SKILL.md prose. Reasons: testable mechanically, defense-in-depth against a buggy or out-of-date LLM detection, and a single source of truth for the four-cell truth table. SKILL.md still mirrors the same detection so the wizard *announces* the abort instead of crashing into it, but the script is authoritative.
- **Test file shape:** extend the existing `tests/test_onboarding.sh` rather than a sibling `test_onboarding_inplace.sh`. The new cases reuse the same `assert_dir` / `assert_file` / `assert_contains` helpers; a sibling file would duplicate them.
- **`/plugin install` syntax:** verified against `/Users/bodist/work/ai/doc-downloader/docs/claude-code/plugin-distribution/plugin-marketplaces.md` (lines 220-231) and `tools-and-plugins/discover-plugins.md` (lines 33-36). There is no `/plugin install <local-path>` form. The documented pre-flight is:
  ```
  /plugin marketplace add /Users/bodist/work/contexts/second-brain
  /plugin install second-brain@second-brain
  ```
  This relies on the existing `.claude-plugin/marketplace.json` (already in the repo). The runbook uses this exact pair.

---

## Task 1: Add abort guard — "already onboarded"

**Files:**
- Modify: `tests/test_onboarding.sh`
- Modify: `skills/onboard/scripts/onboarding.sh`

This task adds the first of two abort guards. Spec §4.1 row 4: when both `.obsidian/` and `wiki/` exist, the scaffold must refuse to run and not touch the filesystem. We add a failing test first, then the guard.

- [ ] **Step 1: Add the "abort: already onboarded" test case to `tests/test_onboarding.sh`**

Append this block at the end of `tests/test_onboarding.sh`, **before** the final `=== Results ===` print and exit:

```bash
echo ""

# Test 6: Abort — vault already onboarded (.obsidian/ + wiki/ both present)
echo "Test 6: Abort — already onboarded"
ABORT_VAULT="$TEST_DIR/abort-already"
mkdir -p "$ABORT_VAULT/.obsidian" "$ABORT_VAULT/wiki"
set +e
ABORT_OUT=$(bash "$ONBOARDING" "$ABORT_VAULT" 2>&1 >/dev/null)
ABORT_EXIT=$?
set -e
if [ "$ABORT_EXIT" != "0" ]; then
  echo "  PASS: script exited non-zero on already-onboarded vault (exit=$ABORT_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script exited 0 on already-onboarded vault (expected non-zero)"
  FAIL=$((FAIL + 1))
fi
if echo "$ABORT_OUT" | grep -q "already onboarded"; then
  echo "  PASS: error message mentions 'already onboarded'"
  PASS=$((PASS + 1))
else
  echo "  FAIL: error message did not mention 'already onboarded' — got: $ABORT_OUT"
  FAIL=$((FAIL + 1))
fi
if [ ! -d "$ABORT_VAULT/raw" ] && [ ! -d "$ABORT_VAULT/wiki/sources" ]; then
  echo "  PASS: no scaffold directories were created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: scaffold directories were created despite abort"
  FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Run the test to verify the new case fails**

Run: `bash tests/test_onboarding.sh`

Expected: the new "Test 6: Abort — already onboarded" reports 3 FAILs (script exits 0, no `already onboarded` message, scaffold directories *are* created). Earlier tests still pass. Overall exit code 1.

- [ ] **Step 3: Add the abort guard to `skills/onboard/scripts/onboarding.sh`**

Insert this block immediately after the `VAULT_ROOT="${1:-.}"` line (currently around line 10), before any `echo "=== Second Brain Onboarding ==="`:

```bash
# CR-006: refuse to scaffold if the vault is already onboarded.
# Truth table (spec §4.1):
#   .obsidian/ present + wiki/ present  -> abort (already onboarded)
#   .obsidian/ absent  + wiki/ present  -> abort (orphaned scaffold, added in Task 2)
#   .obsidian/ present + wiki/ absent   -> in-place mode (proceed)
#   .obsidian/ absent  + wiki/ absent   -> greenfield mode (proceed)
if [ -d "$VAULT_ROOT/.obsidian" ] && [ -d "$VAULT_ROOT/wiki" ]; then
  echo "error: vault already onboarded — both .obsidian/ and wiki/ exist at $VAULT_ROOT" >&2
  echo "Re-running /second-brain:onboard is not supported. Use /second-brain:lint to check health." >&2
  exit 2
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_onboarding.sh`

Expected: all "Test 6" assertions PASS. Earlier tests still pass; Test 4 (legacy idempotency) may now FAIL because of the second guard we have *not* added yet — that is expected and fixed in Task 2. If Test 4 fails with an exit-non-zero on a `wiki/`-only re-run, leave it; do not patch around it.

- [ ] **Step 5: Commit**

```bash
git add skills/onboard/scripts/onboarding.sh tests/test_onboarding.sh
git commit -m "$(cat <<'EOF'
feat(onboard): abort scaffold when vault already onboarded

Refuse to re-scaffold a vault that already has both .obsidian/ and wiki/.
Surfaces a clear error instead of clobbering existing state. Test extends
tests/test_onboarding.sh.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add abort guard — "orphaned scaffold"

**Files:**
- Modify: `tests/test_onboarding.sh`
- Modify: `skills/onboard/scripts/onboarding.sh`

Spec §4.1 row 3: when `wiki/` is present but `.obsidian/` is absent, abort. This is the case the legacy "idempotency" test exercised (re-running on a `wiki/`-only dir). After this task, the legacy Test 4 is invalid — Task 3 removes it.

- [ ] **Step 1: Add the "abort: orphaned scaffold" test case**

Append below the Test 6 block from Task 1, before the final results line:

```bash
echo ""

# Test 7: Abort — orphaned scaffold (wiki/ present, .obsidian/ absent)
echo "Test 7: Abort — orphaned scaffold"
ORPHAN_VAULT="$TEST_DIR/abort-orphan"
mkdir -p "$ORPHAN_VAULT/wiki"
set +e
ORPHAN_OUT=$(bash "$ONBOARDING" "$ORPHAN_VAULT" 2>&1 >/dev/null)
ORPHAN_EXIT=$?
set -e
if [ "$ORPHAN_EXIT" != "0" ]; then
  echo "  PASS: script exited non-zero on orphaned scaffold (exit=$ORPHAN_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script exited 0 on orphaned scaffold (expected non-zero)"
  FAIL=$((FAIL + 1))
fi
if echo "$ORPHAN_OUT" | grep -q "orphaned scaffold"; then
  echo "  PASS: error message mentions 'orphaned scaffold'"
  PASS=$((PASS + 1))
else
  echo "  FAIL: error message did not mention 'orphaned scaffold' — got: $ORPHAN_OUT"
  FAIL=$((FAIL + 1))
fi
if [ ! -d "$ORPHAN_VAULT/raw" ] && [ ! -d "$ORPHAN_VAULT/wiki/sources" ]; then
  echo "  PASS: no scaffold directories were created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: scaffold directories were created despite abort"
  FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Run the test to verify the new case fails**

Run: `bash tests/test_onboarding.sh`

Expected: "Test 7" reports 3 FAILs (script proceeds, no `orphaned scaffold` message, `raw/` gets created). Test 6 still passes.

- [ ] **Step 3: Extend the abort guard in `skills/onboard/scripts/onboarding.sh`**

Right below the first guard added in Task 1, add the second:

```bash
if [ -d "$VAULT_ROOT/wiki" ] && [ ! -d "$VAULT_ROOT/.obsidian" ]; then
  echo "error: orphaned scaffold — wiki/ exists at $VAULT_ROOT but .obsidian/ does not" >&2
  echo "Open the directory in Obsidian first to create .obsidian/, then re-run /second-brain:onboard." >&2
  exit 3
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_onboarding.sh`

Expected: Test 7 PASSes. Test 4 (legacy idempotency) now FAILs because re-running on a `wiki/`-only vault exits non-zero. Task 3 deletes that legacy case.

- [ ] **Step 5: Commit**

```bash
git add skills/onboard/scripts/onboarding.sh tests/test_onboarding.sh
git commit -m "$(cat <<'EOF'
feat(onboard): abort scaffold on orphaned wiki/ without .obsidian/

Second of two CR-006 abort guards: if wiki/ exists but .obsidian/ is missing,
the vault was never opened in Obsidian — refuse to scaffold and point the
user at the fix.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Replace legacy idempotency test with in-place happy path

**Files:**
- Modify: `tests/test_onboarding.sh`

Task 2 made the legacy "Test 4: Idempotency" invalid — it re-runs the scaffold on a `wiki/`-only dir, which now aborts as orphaned. We replace it with the in-place happy path (the case the wizard will most commonly hit during CR-006 rollout).

- [ ] **Step 1: Delete the existing Test 4 block**

In `tests/test_onboarding.sh`, find this block (currently around lines 99-104):

```bash
# Test 4: Idempotent — running again doesn't overwrite existing files
echo "Test 4: Idempotency"
echo "# Custom content" >> "$TEST_VAULT/wiki/index.md"
bash "$ONBOARDING" "$TEST_VAULT" 2>/dev/null
assert_contains "$TEST_VAULT/wiki/index.md" "# Custom content"
```

Delete it (those six lines plus the blank line above them). Keep the surrounding `echo ""` separator.

- [ ] **Step 2: Insert the new "in-place happy path" test in its place**

Where Test 4 used to be (between Test 3.5 and Test 5), insert:

```bash
# Test 4: In-place happy path — .obsidian/ exists, wiki/ does not (spec §4.1 row 2)
echo "Test 4: In-place happy path"
INPLACE_VAULT="$TEST_DIR/inplace-vault"
mkdir -p "$INPLACE_VAULT/.obsidian"
# Drop a sentinel file so we can prove .obsidian/ is not touched.
echo "sentinel" > "$INPLACE_VAULT/.obsidian/marker.txt"
bash "$ONBOARDING" "$INPLACE_VAULT" 2>/dev/null

assert_dir "$INPLACE_VAULT/raw"
assert_dir "$INPLACE_VAULT/raw/assets"
assert_dir "$INPLACE_VAULT/wiki"
assert_dir "$INPLACE_VAULT/wiki/sources"
assert_dir "$INPLACE_VAULT/wiki/entities"
assert_dir "$INPLACE_VAULT/wiki/concepts"
assert_dir "$INPLACE_VAULT/wiki/synthesis"
assert_dir "$INPLACE_VAULT/output"
assert_dir "$INPLACE_VAULT/src/documentation"
assert_file "$INPLACE_VAULT/wiki/index.md"
assert_file "$INPLACE_VAULT/wiki/log.md"
assert_file "$INPLACE_VAULT/wiki/.state/frontmatter-contract.yaml"

# .obsidian/ must be untouched
assert_dir "$INPLACE_VAULT/.obsidian"
assert_file "$INPLACE_VAULT/.obsidian/marker.txt"
assert_contains "$INPLACE_VAULT/.obsidian/marker.txt" "sentinel"
```

- [ ] **Step 3: Run the full test suite**

Run: `bash tests/test_onboarding.sh`

Expected: every assertion PASSes. Tests 1, 2, 3, 3.5, 4 (new in-place), 5, 6, 7 all green. Final line: `=== Results: N passed, 0 failed ===` with exit 0.

- [ ] **Step 4: Commit**

```bash
git add tests/test_onboarding.sh
git commit -m "$(cat <<'EOF'
test(onboard): replace legacy idempotency case with in-place happy path

The pre-CR-006 "Test 4: Idempotency" re-ran the scaffold on a wiki/-only
vault — that path now aborts as orphaned. Swap it for the in-place case the
wizard will actually hit (.obsidian/ present, wiki/ absent) and verify
.obsidian/ is untouched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Teach `SKILL.md` to detect mode and reframe the wizard

**Files:**
- Modify: `skills/onboard/SKILL.md`

The script-side guards from Tasks 1–2 are the safety net. This task makes the wizard *announce* the mode before any question so the user gets the right prompts (skipped Step 2, reframed Step 1, hinted Step 4, tweaked Step 8) rather than the wizard stumbling into a guard.

No automated test — SKILL.md is LLM-driven prose. Verified by the manual smoke in the runbook (Task 5).

- [ ] **Step 1: Insert the Detection preamble before "### Step 1: Vault Name"**

In `skills/onboard/SKILL.md`, find the heading `## Wizard Flow` (currently around line 25) and the paragraph beneath it. Immediately *after* that paragraph and *before* `### Step 1: Vault Name`, insert:

````markdown
### Step 0: Detect Mode (before any question)

Inspect the current working directory **before asking anything**. The mode determines what Steps 1–4 look like.

```bash
HAS_OBSIDIAN=0; HAS_WIKI=0
[ -d ".obsidian" ] && HAS_OBSIDIAN=1
[ -d "wiki" ] && HAS_WIKI=1
```

Truth table:

| `.obsidian/` | `wiki/` | Mode | What to do |
|---|---|---|---|
| absent | absent | **greenfield** | run Steps 1–5 as written below |
| present | absent | **in-place** | follow the in-place overrides flagged in each step |
| absent | present | **abort** | print *"Vault scaffold exists but no Obsidian config. Open the directory in Obsidian first to create `.obsidian/`, then re-run."* and stop. Do not invoke the scaffold script. |
| present | present | **abort** | print *"This vault appears already onboarded. Re-running `/second-brain:onboard` is not supported. Use `/second-brain:lint` to check health."* and stop. |

The scaffold script (`scripts/onboarding.sh`) also enforces these abort cases (exits 2 or 3) as defense in depth — but you should announce the abort *before* invoking it so the user sees a wizard-style message, not a stderr dump.
````

- [ ] **Step 2: Reframe Step 1 for in-place mode**

Find `### Step 1: Vault Name` and the question/default beneath it. Append this block immediately after the existing Step 1 content, before `### Step 2: Vault Location`:

```markdown
**In-place override:** If mode is **in-place**, change the prompt to:

> "What title should I use for this knowledge base in CLAUDE.md?"
> Default: `<basename of cwd>` (e.g. `yettel`)

The title is used only as the display name in the generated `CLAUDE.md`. It does not create a directory and is not transformed (no lowercasing, no title-casing).
```

- [ ] **Step 3: Skip Step 2 in in-place mode**

Find `### Step 2: Vault Location` and append, before `### Step 3: Domain / Topic`:

```markdown
**In-place override:** Skip this step entirely. Set `VAULT_PATH=$(pwd)`.
```

- [ ] **Step 4: Add the hint to Step 4**

Find `### Step 4: Settings Scope`, locate the existing options block ending with the `(c) Skip` line, and append before `### Step 5: Optional CLI Tools`:

```markdown
**In-place hint:** If mode is **in-place**, after presenting the options add this nudge:

> *"You're onboarding into an existing dir. If you plan to onboard multiple vaults (yettel, personal, etc.), `(b) All my projects` registers the plugin once for all of them. Default `(a)` still works — pick it per vault if you want fine-grained control."*

The default stays `(a)`. The hint nudges; it does not change the default.
```

- [ ] **Step 5: Tweak the Step 8 summary for in-place mode**

Find `### 8. Print summary` and its third bullet `**How to start** — open the vault folder in Obsidian, then either:`. Append, at the end of the entire Step 8 block (after the closing `Then run `/second-brain:ingest`.` line):

```markdown
**In-place override:** If mode was **in-place**, drop the "open the vault folder in Obsidian" instruction — `.obsidian/` proves Obsidian is already pointed at the vault. Replace it with:

> *"Obsidian may need a manual refresh (File → Reload app) to see the new `wiki/`, `raw/`, `src/`, and `output/` folders."*
```

- [ ] **Step 6: Verify the file still parses as Markdown**

Run: `grep -c '^###' /Users/bodist/work/contexts/second-brain/skills/onboard/SKILL.md`

Expected: a higher number than before (we added one new `###` heading for Step 0). No errors. The file is not parsed by any script in this repo — visual inspection is enough.

- [ ] **Step 7: Commit**

```bash
git add skills/onboard/SKILL.md
git commit -m "$(cat <<'EOF'
feat(onboard): in-place mode for existing vaults

Add a Step 0 mode-detection preamble to SKILL.md plus per-step overrides
for in-place onboarding (reframed Step 1, skipped Step 2, Step 4 multi-vault
hint, tweaked Step 8 summary). Mirrors the abort truth table the scaffold
script now enforces. Greenfield flow unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Author the CR-006 rollout runbook

**Files:**
- Create: `docs/cr/CR-006-runbook.md`

Deliverable per spec §5. Copy-paste-ready pre-flight + per-vault block × 4 + troubleshooting. The runbook is what the user actually executes; the design + plan documents are reference material.

- [ ] **Step 1: Write the runbook**

Create `docs/cr/CR-006-runbook.md` with this exact content (verbatim — no improvisation, no extra sections):

````markdown
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
- `git log --oneline` shows at least one commit — but note: `onboarding.sh` does not commit on your behalf, so the only commit you'll see is whatever you make. (The "Vault initialized" entry in `wiki/log.md` is unstaged.)

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
````

- [ ] **Step 2: Sanity-check the runbook renders**

Run: `wc -l docs/cr/CR-006-runbook.md`

Expected: roughly 70-90 lines. No automated test.

Run: `grep -c '^##' docs/cr/CR-006-runbook.md`

Expected: 3 (Pre-flight, Per-vault block, Troubleshooting).

- [ ] **Step 3: Commit**

```bash
git add docs/cr/CR-006-runbook.md
git commit -m "$(cat <<'EOF'
docs(cr): add CR-006 rollout runbook

Copy-paste sequence for installing the plugin and onboarding the four
sibling vaults (yettel, personal, otp, nitrowise) using the new in-place
mode. Verified plugin-install syntax against
docs/claude-code/plugin-distribution/plugin-marketplaces.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Full-suite regression run

**Files:**
- (none — verification only)

This is a TDD-discipline gate. Before declaring CR-006 done, re-run the whole test suite for the plugin to catch any drift the targeted CR-006 changes might have caused.

- [ ] **Step 1: Run every test in `tests/`**

Run:

```bash
for t in /Users/bodist/work/contexts/second-brain/tests/test_*.sh; do
  echo "=== $(basename "$t") ==="
  bash "$t" || { echo "FAILED: $t"; exit 1; }
done
echo "=== ALL GREEN ==="
```

Expected: every test file exits 0. Final line `=== ALL GREEN ===`. If anything fails, stop and diagnose — do not move on to manual smoke.

- [ ] **Step 2: Manual smoke (out-of-band, not committable)**

This is the user's job, not the agent's, but flag it in the final summary:

1. Run pre-flight per the runbook.
2. Run `/second-brain:onboard` in `yettel`. Confirm wizard skips Step 2, accepts the title default `yettel`, scaffolds in place, leaves `.obsidian/` untouched.
3. Run `/second-brain:lint` in `yettel`. Confirm clean.
4. Repeat for `personal`, `otp`, `nitrowise` only if `yettel` succeeded.

- [ ] **Step 3: No commit**

There's nothing to commit. If the manual smoke surfaces a real issue, that's a new fix in a follow-up commit, not part of this task.

---

## Self-review notes

Coverage of spec sections:

- §1 Problem, §2 Goals — addressed by Tasks 1–4 (in-place mode + abort guards) and Task 5 (runbook).
- §3 Non-goals — respected: no content ingestion, no auto-scraper, no new skills, no `--force` flag, no `.obsidian/` writes, no marketplace publish.
- §4.1 Detection truth table — enforced in the script (Tasks 1–2) AND mirrored in SKILL.md prose (Task 4 Step 1). All four rows accounted for.
- §4.2 Wizard changes — Task 4 Steps 2–4.
- §4.3 Post-wizard changes — Task 4 Step 5 (Step 8 summary tweak); Steps 1–7 of post-wizard are unchanged by design.
- §5 Runbook — Task 5.
- §6.1 Automated tests — four cases:
  - Greenfield (regression): existing Test 1–3.5 + 5 unchanged.
  - In-place happy path: Task 3 Step 2.
  - Abort already onboarded: Task 1 Step 1.
  - Abort orphaned scaffold: Task 2 Step 1.
- §6.2 Manual smoke — Task 6 Step 2.
- §7 Risks — all addressed:
  - `.obsidian/` settings drift: Task 3 Step 2 asserts `.obsidian/` is untouched via sentinel file.
  - `CLAUDE_PLUGIN_ROOT` resolution: troubleshooting entry in the runbook.
  - User-scope plugin registration written multiple times: pre-existing `register-plugin.js` is idempotent (covered by `tests/test_register_plugin.sh`); no plan-level change needed.
  - Empty `src/documentation/` for yettel: handled by existing `.gitkeep` logic in `onboarding.sh`.
  - Rollout-order recovery: runbook says "stop on failure, fix forward".
- §9 Open questions for the plan — decided:
  - Plugin install syntax: documented as `/plugin marketplace add <dir>` + `/plugin install second-brain@second-brain`, verified against the local docs mirror.
  - Guard placement: script (with SKILL.md prose mirror).
  - Test file shape: extend `tests/test_onboarding.sh`.

Placeholder scan: every step shows the actual diff or command. No TBDs, no "add appropriate error handling", no "similar to Task N".

Type consistency: all paths (`VAULT_ROOT`, `INPLACE_VAULT`, `ABORT_VAULT`, `ORPHAN_VAULT`) are local to their tasks; the only shared identifier is `$ONBOARDING` from the existing test file, which we don't redefine.
