# CR-009 `/second-brain:status` Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a single user-facing entry point (`/second-brain:status`) that reports every pending vault concern in one place, plus a `since-review.yaml` review log that automated skills append to and the user clears via `accept`. Provide a stable JSON shape so cron can drive headless runs.

**Architecture:** Two new node scripts at the top-level `scripts/` directory (`status.js` reports; `review-log.js` owns the inbox file). One new skill at `skills/status/SKILL.md` that pins both scripts and routes sub-args. Two reference docs (JSON schema + headless-driving cron example). One-line addition to `skills/ingest/SKILL.md` so successful ingests append to the review log. No new dependencies; reuses `js-yaml` 4.x and the existing `state-sources.js diff` / `validate-wiki.js all` JSON contracts.

**Tech Stack:** Node ≥18 (CommonJS, no build step), `js-yaml` 4.x for YAML I/O, bash test harness matching `tests/test_state_sources.sh` / `tests/test_validate_wiki.sh`.

**Reference spec:** [`docs/superpowers/specs/2026-05-21-cr-009-status-dashboard-design.md`](../specs/2026-05-21-cr-009-status-dashboard-design.md). CR: [`docs/cr/CR-009-status-dashboard.md`](../../cr/CR-009-status-dashboard.md). Conventions: [`docs/cr/conventions.md`](../../cr/conventions.md).

---

## File Structure

**Create:**
- `scripts/status.js` — dashboard reporter. Single file, ~250 lines. Reads `wiki/.state/*.yaml`, shells out to `state-sources.js diff --json` and `validate-wiki.js all --json`, emits human or `--json` output. Reporter only — never mutates.
- `scripts/review-log.js` — owner of `wiki/.state/since-review.yaml`. Single file, ~180 lines. Three subcommands: `append`, `show`, `accept`. Atomic writes (tmpfile + rename).
- `skills/status/SKILL.md` — thin skill, `Bash Read` only. Pins to both scripts. Routes sub-args (`review`, `accept`, `reconcile`, `refresh`). `reconcile` and `refresh` are placeholders until CR-007 / CR-008 land.
- `skills/status/references/status-json-schema.md` — field-by-field documentation of the `status.js --json` shape, with worked examples (fresh + populated).
- `docs/install/headless-driving.md` — concrete cron example using `status.js --json` + `jq` + `claude --headless`, plus `.claude/headless.log` convention.
- `tests/test_status.sh` — integration tests for `status.js`, 11 cases per spec §10.1.
- `tests/test_review_log.sh` — integration tests for `review-log.js`, 9 cases per spec §10.2.
- `tests/fixtures/status/contradictions-populated/` — fixture vault with hand-written `contradictions.yaml` for test 4.
- `tests/fixtures/status/staleness-populated/` — fixture vault with hand-written `staleness.yaml` for test 5.

**Modify:**
- `skills/ingest/SKILL.md` — insert a new step between current step 8 (commit) and step 9 (report results): "8.5. Log to review inbox" with the `review-log.js append --kind=ingest` invocation. One paragraph.

**Decisions locked in:**
- **Two scripts, top-level `scripts/`, not skill-private.** `status.js` reads state across concerns; `review-log.js` is the mutation point. Both have non-status callers in the long term (cron, other skills), so they live at `scripts/` per CR-001's plugin layout. Skill-private `scripts/` (à la `skills/ingest/scripts/state-sources.js`) is reserved for tools nothing else consumes.
- **Predicate ownership for contradictions/staleness counts.** CR-009 owns the JSON key shape (`unresolved`, `unresolved_high`, `unresolved_medium`, `unjudged_candidates`, `present`). The per-entry "what counts as unresolved" predicate uses the schemas sketched in CR-007 §4 (`status: unresolved` entries) and CR-008 §4 (`signal: high|medium` × `status: unreviewed`). If CR-007 / CR-008 plans refine the schema, the reader and its fixture update together — but CR-009 must ship now without blocking, so we read what's sketched today.
- **No commit from `review-log.js`.** Mutations write the YAML and leave it dirty. The next `state-sources.js begin` will baseline-commit it, or the user commits manually. Keeps the review-log script tool-shaped (a single file mutation per call), avoids fighting `state-sources.js`'s commit semantics.
- **Status skill is the *only* user-facing entry point added.** No bare `/status` shorthand. Per conventions §5 all invocations are `/second-brain:status`. The CR's `/status` shorthand stays prose-only.
- **Lint integration is read-only.** CR-009 does not add an autofix mode to `skills/lint/SKILL.md`. When lint grows autofix later, that CR adds its own `kind: lint-autofix` append. Spec §3 non-goal.

**Status flag for partial sections:** The `present: false` flag on `contradictions` and `staleness` lets cron consumers distinguish "section not yet implemented (CR-007/008 hasn't landed)" from "section landed, counts are zero." Once those CRs ship and write their state files, `present` flips to `true` even when all counts are zero.

---

## Task 1: `status.js` skeleton + vault resolution + outside-vault test

**Files:**
- Create: `scripts/status.js`
- Create: `tests/test_status.sh`

This task gets the script callable, the test harness running, and the spec's case 10 (outside-vault → exit 2) green. No JSON output yet.

- [ ] **Step 1: Create `tests/test_status.sh` with the harness and case 10 (outside vault → exit 2)**

```bash
#!/bin/bash
set -e

# Test: scripts/status.js — status dashboard reporter.
# Usage: bash tests/test_status.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/status.js"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Read JSON from stdin and print the value at a dotted path.
json_path() {
  node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{let o=JSON.parse(d); for (const k of '$1'.split('.')) o = o?.[k]; process.stdout.write(String(o))})"
}

# Create a fresh vault: temp dir, git init, scaffolded .state/sources.yaml.
# Args: $1 = name. Echoes the absolute path.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state"
  cat > "$v/wiki/.state/sources.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
  cat > "$v/wiki/.state/frontmatter-contract.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/validate-wiki.js
targets:
  - wiki/sources/**/*.md
  - wiki/entities/**/*.md
  - wiki/concepts/**/*.md
  - wiki/synthesis/**/*.md
exempt:
  - wiki/index.md
  - wiki/log.md
required:
  tags: { type: list[string], may_be_empty: true }
  sources: { type: list[string], may_be_empty: false }
  created: { type: date, format: YYYY-MM-DD }
  updated: { type: date, format: YYYY-MM-DD }
unknown_keys: allowed
YAML
  (cd "$v" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
  echo "$v"
}

echo "=== Test: status.js ==="

# Test 10: outside any vault → exit 2 with helpful message.
echo ""
echo "Test 10: outside any vault → exit 2"
OUTSIDE_DIR="$TEST_DIR/not-a-vault"
mkdir -p "$OUTSIDE_DIR"
set +e
OUT=$( (cd "$OUTSIDE_DIR" && node "$SCRIPT" 2>&1) )
EXIT=$?
set -e
assert_eq "exit code 2"                    "2" "$EXIT"
case "$OUT" in
  *"not in a second-brain vault"*)
    echo "  PASS: stderr names the problem"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not say 'not in a second-brain vault' — got: $OUT"
    FAIL=$((FAIL + 1));;
esac

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
chmod +x tests/test_status.sh
bash tests/test_status.sh
```

Expected: FAIL with "Cannot find module" or similar (script does not exist yet).

- [ ] **Step 3: Create `scripts/status.js` with vault resolution + the exit-2 path**

```javascript
#!/usr/bin/env node
'use strict';

/**
 * scripts/status.js — vault status dashboard reporter.
 *
 * Reads wiki/.state/*.yaml and runs cheap fresh comparisons to report what
 * the vault needs the user to act on. Default: human-readable dashboard.
 * --json: stable schema for cron consumers (see references/status-json-schema.md).
 *
 * Reporter only — never mutates. Mutations flow through scripts/review-log.js.
 *
 * Exit codes:
 *   0 = dashboard printed cleanly (validate-wiki non-zero is OK; counts still populated)
 *   2 = vault root not found, or a state-file YAML is malformed, or a child script failed
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const yaml = require('js-yaml');

function die(msg, code = 2) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(code);
}

function findVaultRoot(start) {
  let dir = path.resolve(start);
  while (true) {
    const hasGit = fs.existsSync(path.join(dir, '.git'));
    const hasState = fs.existsSync(path.join(dir, 'wiki', '.state', 'sources.yaml'));
    if (hasGit && hasState) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function parseArgs(argv) {
  const args = { json: false };
  for (const a of argv) {
    if (a === '--json') args.json = true;
    else die(`unknown argument: ${a}`, 2);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  // Filled in by Task 2.
}

main();
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_status.sh
```

Expected: `Test 10` reports 2 PASS, overall exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/status.js tests/test_status.sh
git commit -m "$(cat <<'EOF'
feat(status): scaffold status.js with vault detection

Adds scripts/status.js that resolves the vault root by walking up for
both .git/ and wiki/.state/sources.yaml — matching validate-wiki.js's
convention. Outside a vault: exit 2 with a pointer to /second-brain:onboard.

tests/test_status.sh follows the test_state_sources.sh shape (temp dir,
inline assertions, json_path helper for later cases). Test 10 (outside
any vault) is the only case wired so far; remaining cases land alongside
their producing tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Fresh-vault `--json` returns the stable schema

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`

Wire the JSON output path. On a fresh vault (only `sources.yaml` + `frontmatter-contract.yaml`, no raw files, no state for contradictions/staleness/since-review), `--json` must emit every key in the spec §5.2 schema with safe defaults.

- [ ] **Step 1: Add test case 1 (fresh vault → stable schema)**

Insert this block in `tests/test_status.sh` immediately before the final `=== Results ===` print:

```bash
# Test 1: fresh vault → --json returns stable schema with all-zero sections.
echo ""
echo "Test 1: fresh vault → stable JSON schema"
V1=$(make_vault vault1)
OUT=$( (cd "$V1" && node "$SCRIPT" --json) )
assert_eq "sources.new === 0"                  "0"     "$(echo "$OUT" | json_path 'sources.new')"
assert_eq "sources.changed === 0"              "0"     "$(echo "$OUT" | json_path 'sources.changed')"
assert_eq "sources.deleted === 0"              "0"     "$(echo "$OUT" | json_path 'sources.deleted')"
assert_eq "lint.errors === 0"                  "0"     "$(echo "$OUT" | json_path 'lint.errors')"
assert_eq "lint.warnings === 0"                "0"     "$(echo "$OUT" | json_path 'lint.warnings')"
assert_eq "contradictions.unresolved === 0"    "0"     "$(echo "$OUT" | json_path 'contradictions.unresolved')"
assert_eq "contradictions.present === false"   "false" "$(echo "$OUT" | json_path 'contradictions.present')"
assert_eq "staleness.unresolved_high === 0"    "0"     "$(echo "$OUT" | json_path 'staleness.unresolved_high')"
assert_eq "staleness.unresolved_medium === 0"  "0"     "$(echo "$OUT" | json_path 'staleness.unresolved_medium')"
assert_eq "staleness.present === false"        "false" "$(echo "$OUT" | json_path 'staleness.present')"
assert_eq "since_review.change_count === 0"    "0"     "$(echo "$OUT" | json_path 'since_review.change_count')"
assert_eq "since_review.last_accepted_at null" "null"  "$(echo "$OUT" | json_path 'since_review.last_accepted_at')"
assert_eq "vault.name is vault1"               "vault1" "$(echo "$OUT" | json_path 'vault.name')"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_status.sh
```

Expected: every Test 1 assertion FAILs ("Cannot find module" or empty output — the script currently exits silently after `findVaultRoot` returns).

- [ ] **Step 3: Implement the JSON skeleton**

Replace the `main()` function in `scripts/status.js` and add the section helpers:

```javascript
// Read a YAML file under wiki/.state/. Returns parsed object or null if absent.
// Throws on parse errors so the caller can decide exit semantics.
function readStateYaml(vault, relname) {
  const abs = path.join(vault, 'wiki', '.state', relname);
  if (!fs.existsSync(abs)) return null;
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch (err) { die(`wiki/.state/${relname} unreadable: ${err.message}`, 2); }
  try { return yaml.load(text); }
  catch (err) { die(`wiki/.state/${relname} malformed: ${err.message}`, 2); }
}

function readSources(vault)        { return { new: 0, changed: 0, deleted: 0 }; }
function readLint(vault)           { return { errors: 0, warnings: 0 }; }
function readContradictions(vault) { return { unjudged_candidates: 0, unresolved: 0, present: false }; }
function readStaleness(vault)      { return { unjudged_candidates: 0, unresolved_high: 0, unresolved_medium: 0, present: false }; }
function readSinceReview(vault)    { return { change_count: 0, last_accepted_at: null }; }

function buildDashboard(vault) {
  return {
    vault:          { root: vault, name: path.basename(vault) },
    sources:        readSources(vault),
    lint:           readLint(vault),
    contradictions: readContradictions(vault),
    staleness:      readStaleness(vault),
    since_review:   readSinceReview(vault),
  };
}

function emitJson(dash) {
  process.stdout.write(JSON.stringify(dash, null, 2) + '\n');
}

function emitHuman(dash) {
  // Filled in by Task 8.
  process.stdout.write(JSON.stringify(dash, null, 2) + '\n');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  const dash = buildDashboard(vault);
  if (args.json) emitJson(dash);
  else emitHuman(dash);
}

main();
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_status.sh
```

Expected: all Test 1 assertions PASS (13 PASS); Test 10 still PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/status.js tests/test_status.sh
git commit -m "$(cat <<'EOF'
feat(status): emit stable JSON schema on fresh vault

Wires --json output with every section pre-shaped per spec §5.2:
sources/lint as count triples, contradictions/staleness with a
present flag, since_review with change_count + last_accepted_at.
All readers are stubs returning zeros for now; the per-section
implementations land in the following tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Sources section via `state-sources.js diff --json`

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`

Spec §5.2: `sources.{new,changed,deleted}` come from `state-sources.js diff`. The existing tool already emits the right shape (see `skills/ingest/scripts/state-sources.js` `cmdDiff`).

- [ ] **Step 1: Add test case 2 (three new files in `raw/`)**

Insert before `=== Results ===`:

```bash
# Test 2: three new files in raw/ → sources.new === 3.
echo ""
echo "Test 2: sources counted from state-sources.js diff"
V2=$(make_vault vault2)
echo "one"   > "$V2/raw/one.md"
echo "two"   > "$V2/raw/two.md"
echo "three" > "$V2/raw/three.md"
OUT=$( (cd "$V2" && node "$SCRIPT" --json) )
assert_eq "sources.new === 3"     "3" "$(echo "$OUT" | json_path 'sources.new')"
assert_eq "sources.changed === 0" "0" "$(echo "$OUT" | json_path 'sources.changed')"
assert_eq "sources.deleted === 0" "0" "$(echo "$OUT" | json_path 'sources.deleted')"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_status.sh
```

Expected: Test 2 reports 1 FAIL on `sources.new === 3` (got `0`) — earlier tests still pass.

- [ ] **Step 3: Implement `readSources` to shell out**

In `scripts/status.js`, replace the `readSources` stub:

```javascript
const STATE_SOURCES_JS = path.join(__dirname, '..', 'skills', 'ingest', 'scripts', 'state-sources.js');

function readSources(vault) {
  const r = spawnSync('node', [STATE_SOURCES_JS, 'diff'], { cwd: vault, encoding: 'utf8' });
  if (r.status !== 0) {
    process.stderr.write(r.stderr || '');
    die(`state-sources.js diff failed (exit ${r.status})`, 2);
  }
  let parsed;
  try { parsed = JSON.parse(r.stdout); }
  catch (err) { die(`state-sources.js diff produced invalid JSON: ${err.message}`, 2); }
  return {
    new:     parsed.new.length,
    changed: parsed.changed.length,
    deleted: parsed.deleted.length,
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_status.sh
```

Expected: Test 2 all PASS, Tests 1 and 10 still PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/status.js tests/test_status.sh
git commit -m "$(cat <<'EOF'
feat(status): wire sources counts from state-sources.js diff

Shells out to skills/ingest/scripts/state-sources.js diff and counts
its new/changed/deleted lists. Resolves the script path relative to
__dirname so it works regardless of cwd. Propagates non-zero exits
as a status.js exit 2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Lint section via `validate-wiki.js all --json`

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`

Spec §5.2: `lint.{errors,warnings}` come from `validate-wiki.js all --json` regardless of its exit code. Map: `errors = frontmatter.errors + wikilinks.broken + index.dead_rows`; `warnings = wikilinks.orphans + index.missing_rows`.

- [ ] **Step 1: Add test case 3 (broken wikilink → lint.errors ≥ 1)**

Insert before `=== Results ===`:

```bash
# Test 3: vault with a broken wikilink → lint.errors >= 1.
echo ""
echo "Test 3: lint counts derived from validate-wiki.js all --json"
V3=$(make_vault vault3)
mkdir -p "$V3/wiki/sources"
cat > "$V3/wiki/sources/seed.md" <<'EOF'
---
tags: []
sources: [seed.md]
created: 2026-01-01
updated: 2026-01-01
---

# Seed

Points to [[does-not-exist]].
EOF
(cd "$V3" && git add . && git commit -qm "add seed" >/dev/null)
OUT=$( (cd "$V3" && node "$SCRIPT" --json) )
ERRS=$(echo "$OUT" | json_path 'lint.errors')
if [ "$ERRS" -ge 1 ]; then
  echo "  PASS: lint.errors >= 1 (got $ERRS)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: lint.errors expected >= 1, got $ERRS"
  FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_status.sh
```

Expected: Test 3 FAILs with `lint.errors expected >= 1, got 0`.

- [ ] **Step 3: Implement `readLint`**

In `scripts/status.js`, replace the `readLint` stub:

```javascript
const VALIDATE_WIKI_JS = path.join(__dirname, 'validate-wiki.js');

function readLint(vault) {
  const r = spawnSync('node', [VALIDATE_WIKI_JS, 'all', '--json'], { cwd: vault, encoding: 'utf8' });
  // Per spec §5.4: validate-wiki non-zero is acceptable; status.js is a reporter.
  // Only invalid/empty stdout is a problem.
  let parsed;
  try { parsed = JSON.parse(r.stdout || '{}'); }
  catch (err) { die(`validate-wiki.js all --json produced invalid JSON: ${err.message}`, 2); }
  const fmErrors    = (parsed.frontmatter?.errors    || []).length;
  const wlBroken    = (parsed.wikilinks?.broken      || []).length;
  const wlOrphans   = (parsed.wikilinks?.orphans     || []).length;
  const ixDead      = (parsed.index?.dead_rows       || []).length;
  const ixMissing   = (parsed.index?.missing_rows    || []).length;
  return {
    errors:   fmErrors + wlBroken + ixDead,
    warnings: wlOrphans + ixMissing,
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_status.sh
```

Expected: Test 3 PASS; Tests 1, 2, 10 still PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/status.js tests/test_status.sh
git commit -m "$(cat <<'EOF'
feat(status): wire lint counts from validate-wiki.js all --json

Aggregates errors (frontmatter.errors + wikilinks.broken + index.dead_rows)
and warnings (wikilinks.orphans + index.missing_rows) from the existing
validator's JSON output. Treats non-zero exit as acceptable per spec §5.4 —
status.js is a reporter, not a gatekeeper. Only invalid stdout fails.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Contradictions section (read `contradictions.yaml`)

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`
- Create: `tests/fixtures/status/contradictions-populated/wiki/.state/sources.yaml`
- Create: `tests/fixtures/status/contradictions-populated/wiki/.state/frontmatter-contract.yaml`
- Create: `tests/fixtures/status/contradictions-populated/wiki/.state/contradictions.yaml`

Per CR-007 sketched schema (entries with `status: unresolved | resolved | accepted-disagreement`), count `status === 'unresolved'`. Set `present: true` when the file exists, even if all counts are zero. `unjudged_candidates` stays `0` in CR-009 — CR-007 may compute candidates on demand and never persist them, so this key is forward-compatible.

- [ ] **Step 1: Create the fixture vault**

Create directory `tests/fixtures/status/contradictions-populated/wiki/.state/`. Inside it:

`sources.yaml`:
```yaml
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
```

`frontmatter-contract.yaml` (copy from the test harness's `make_vault` helper or from `tests/fixtures/validate-wiki/clean/wiki/.state/frontmatter-contract.yaml`).

`contradictions.yaml`:
```yaml
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  - id: c1
    pair: [wiki/entities/foo.md, wiki/concepts/acquisitions.md]
    status: unresolved
  - id: c2
    pair: [wiki/entities/bar.md, wiki/concepts/launches.md]
    status: unresolved
  - id: c3
    pair: [wiki/entities/baz.md, wiki/concepts/leadership.md]
    status: unresolved
  - id: c4
    pair: [wiki/entities/qux.md, wiki/concepts/policy.md]
    status: resolved
```

- [ ] **Step 2: Add test case 4 (fixture with 3 unresolved → counts = 3, present = true)**

Insert before `=== Results ===`:

```bash
# Test 4: contradictions.yaml with 3 unresolved entries.
echo ""
echo "Test 4: contradictions counts from state file"
V4="$TEST_DIR/contradictions-populated"
cp -R "$REPO_ROOT/tests/fixtures/status/contradictions-populated" "$V4"
(cd "$V4" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
OUT=$( (cd "$V4" && node "$SCRIPT" --json) )
assert_eq "contradictions.unresolved === 3"   "3"    "$(echo "$OUT" | json_path 'contradictions.unresolved')"
assert_eq "contradictions.present === true"   "true" "$(echo "$OUT" | json_path 'contradictions.present')"
assert_eq "contradictions.unjudged_candidates === 0" "0" "$(echo "$OUT" | json_path 'contradictions.unjudged_candidates')"
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test_status.sh
```

Expected: Test 4's `contradictions.unresolved === 3` FAILs (got `0`), `contradictions.present === true` FAILs (got `false`).

- [ ] **Step 4: Implement `readContradictions`**

In `scripts/status.js`, replace the `readContradictions` stub:

```javascript
function readContradictions(vault) {
  const doc = readStateYaml(vault, 'contradictions.yaml');
  if (!doc) return { unjudged_candidates: 0, unresolved: 0, present: false };
  const entries = Array.isArray(doc.contradictions) ? doc.contradictions : [];
  let unresolved = 0;
  for (const e of entries) {
    if (e && e.status === 'unresolved') unresolved += 1;
  }
  return { unjudged_candidates: 0, unresolved, present: true };
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/test_status.sh
```

Expected: Test 4 all PASS. Earlier tests still PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/status.js tests/test_status.sh tests/fixtures/status/contradictions-populated/
git commit -m "$(cat <<'EOF'
feat(status): read contradictions.yaml when present

Counts entries with status: unresolved per CR-007's sketched schema.
Sets present: true once the file lands. unjudged_candidates stays 0
in CR-009 — CR-007 owns the candidate predicate (on-demand or
persisted) and either choice is forward-compatible with the JSON shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Staleness section (read `staleness.yaml`)

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`
- Create: `tests/fixtures/status/staleness-populated/wiki/.state/sources.yaml`
- Create: `tests/fixtures/status/staleness-populated/wiki/.state/frontmatter-contract.yaml`
- Create: `tests/fixtures/status/staleness-populated/wiki/.state/staleness.yaml`

Per CR-008 sketched schema (entries with `signal: low|medium|high` × `status: unreviewed|reviewed|...`), count `status === 'unreviewed' AND signal === 'high'` for `unresolved_high`, similarly for `unresolved_medium`. `low` doesn't surface in CR-009 counts — the dashboard only routes the user to high and medium.

- [ ] **Step 1: Create the fixture vault**

Same `sources.yaml` and `frontmatter-contract.yaml` as Task 5's fixture.

`staleness.yaml`:
```yaml
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - path: wiki/concepts/old-thing-1.md
    signal: high
    status: unreviewed
  - path: wiki/concepts/old-thing-2.md
    signal: high
    status: unreviewed
  - path: wiki/concepts/old-thing-3.md
    signal: high
    status: unreviewed
  - path: wiki/concepts/mid-thing-1.md
    signal: medium
    status: unreviewed
  - path: wiki/concepts/mid-thing-2.md
    signal: medium
    status: unreviewed
  - path: wiki/concepts/low-thing.md
    signal: low
    status: unreviewed
  - path: wiki/concepts/reviewed-high.md
    signal: high
    status: reviewed
```

- [ ] **Step 2: Add test case 5**

Insert before `=== Results ===`:

```bash
# Test 5: staleness.yaml with 3 high-unreviewed + 2 medium-unreviewed.
echo ""
echo "Test 5: staleness counts from state file"
V5="$TEST_DIR/staleness-populated"
cp -R "$REPO_ROOT/tests/fixtures/status/staleness-populated" "$V5"
(cd "$V5" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
OUT=$( (cd "$V5" && node "$SCRIPT" --json) )
assert_eq "staleness.unresolved_high === 3"     "3"    "$(echo "$OUT" | json_path 'staleness.unresolved_high')"
assert_eq "staleness.unresolved_medium === 2"   "2"    "$(echo "$OUT" | json_path 'staleness.unresolved_medium')"
assert_eq "staleness.present === true"          "true" "$(echo "$OUT" | json_path 'staleness.present')"
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test_status.sh
```

Expected: Test 5 FAILs on all three high/medium/present assertions.

- [ ] **Step 4: Implement `readStaleness`**

In `scripts/status.js`, replace the `readStaleness` stub:

```javascript
function readStaleness(vault) {
  const doc = readStateYaml(vault, 'staleness.yaml');
  if (!doc) return {
    unjudged_candidates: 0,
    unresolved_high: 0,
    unresolved_medium: 0,
    present: false,
  };
  const entries = Array.isArray(doc.pages) ? doc.pages : [];
  let unresolved_high = 0, unresolved_medium = 0;
  for (const e of entries) {
    if (!e || e.status !== 'unreviewed') continue;
    if (e.signal === 'high')   unresolved_high   += 1;
    if (e.signal === 'medium') unresolved_medium += 1;
  }
  return { unjudged_candidates: 0, unresolved_high, unresolved_medium, present: true };
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/test_status.sh
```

Expected: Test 5 all PASS. Earlier tests still PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/status.js tests/test_status.sh tests/fixtures/status/staleness-populated/
git commit -m "$(cat <<'EOF'
feat(status): read staleness.yaml when present

Counts unreviewed pages by signal per CR-008's sketched schema:
unresolved_high = signal=high AND status=unreviewed; medium similarly.
signal: low doesn't surface in dashboard counts — the dashboard only
routes the user to high+medium triage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `since_review` section (read `since-review.yaml`)

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`

Direct read — no helper script. `change_count` is `len(changes)`; `last_accepted_at` is the top-level key or `null`. File is committed (no `.gitignore`).

- [ ] **Step 1: Add test case 8 (five changes → change_count === 5)**

Insert before `=== Results ===`:

```bash
# Test 8: since-review.yaml with 5 changes → change_count === 5.
echo ""
echo "Test 8: since_review counts from state file"
V8=$(make_vault vault8)
cat > "$V8/wiki/.state/since-review.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/review-log.js
last_accepted_at: 2026-05-12T08:00:00Z
changes:
  - { at: 2026-05-13T03:00:00Z, kind: ingest, source: raw/a.md }
  - { at: 2026-05-13T03:01:00Z, kind: ingest, source: raw/b.md }
  - { at: 2026-05-14T03:00:00Z, kind: ingest, source: raw/c.md }
  - { at: 2026-05-15T03:00:00Z, kind: ingest, source: raw/d.md }
  - { at: 2026-05-15T03:01:00Z, kind: ingest, source: raw/e.md }
YAML
(cd "$V8" && git add . && git commit -qm "add since-review" >/dev/null)
OUT=$( (cd "$V8" && node "$SCRIPT" --json) )
assert_eq "since_review.change_count === 5"          "5"                    "$(echo "$OUT" | json_path 'since_review.change_count')"
assert_eq "since_review.last_accepted_at present"    "2026-05-12T08:00:00Z" "$(echo "$OUT" | json_path 'since_review.last_accepted_at')"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_status.sh
```

Expected: Test 8 FAILs (`change_count === 5` got `0`, `last_accepted_at` got `null`).

- [ ] **Step 3: Implement `readSinceReview`**

In `scripts/status.js`, replace the `readSinceReview` stub:

```javascript
function readSinceReview(vault) {
  const doc = readStateYaml(vault, 'since-review.yaml');
  if (!doc) return { change_count: 0, last_accepted_at: null };
  const changes = Array.isArray(doc.changes) ? doc.changes : [];
  return {
    change_count: changes.length,
    last_accepted_at: doc.last_accepted_at || null,
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_status.sh
```

Expected: Test 8 all PASS. Earlier tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/status.js tests/test_status.sh
git commit -m "$(cat <<'EOF'
feat(status): read since-review.yaml directly

Direct YAML read — no helper script needed for read-only access.
change_count = len(changes); last_accepted_at = top-level key or null.
File is committed per CR-009 §6.1 (no .gitignore) so it travels with
the vault across clones.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Human output mode (three categorisations + "Nothing pending")

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`

Spec §5.3: default output uses three category headers (`Needs you:`, `Awaiting review:`, `Automation could pick up:`), omits zero-count sections, falls back to "Nothing pending." on a fresh vault. Lint warnings render as a trailing line.

Mapping (which counts go under which header):

| Header | Conditions that contribute a row |
|---|---|
| `Needs you:` | `contradictions.unresolved > 0` → "Contradictions  N unresolved  (/second-brain:status reconcile)"; `staleness.unresolved_high + unresolved_medium > 0` → "Stale pages  H high + M medium  (/second-brain:status refresh)" |
| `Awaiting review:` | `since_review.change_count > 0` → "N changes since <last_accepted_at or 'never'>  (/second-brain:status review)" |
| `Automation could pick up:` | `sources.new + changed > 0` → "Sources  N new in raw/, M changed  hint: claude --headless -p \"/second-brain:ingest\"" |
| (trailing) | `lint.errors > 0 \|\| lint.warnings > 0` → "Lint: E errors, W warnings  (/second-brain:lint)" |

Headers with zero contributing rows are omitted entirely. If every header would be empty AND the trailing lint line is empty, print "Nothing pending.".

- [ ] **Step 1: Add test cases 1b (fresh-vault human output) and 2b (populated human output) and 9 (zero sections omitted)**

Insert before `=== Results ===`:

```bash
# Test 1b: fresh vault → human mode prints "Nothing pending." after header.
echo ""
echo "Test 1b: fresh vault human output"
V1b=$(make_vault vault1b)
OUT=$( (cd "$V1b" && node "$SCRIPT") )
case "$OUT" in
  *"Second Brain — vault: vault1b"*"Nothing pending."*)
    echo "  PASS: fresh-vault output prints header + Nothing pending."; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: fresh-vault output missing header or Nothing pending. — got:"; echo "$OUT"
    FAIL=$((FAIL + 1));;
esac

# Test 2b: populated vault → human output includes sources line + lint line.
echo ""
echo "Test 2b: populated vault human output"
V2b=$(make_vault vault2b)
echo "one"   > "$V2b/raw/one.md"
echo "two"   > "$V2b/raw/two.md"
OUT=$( (cd "$V2b" && node "$SCRIPT") )
case "$OUT" in
  *"Automation could pick up"*"Sources"*"2 new"*)
    echo "  PASS: human output shows 'Automation could pick up' + sources line"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: human output missing automation/sources line — got:"; echo "$OUT"
    FAIL=$((FAIL + 1));;
esac
case "$OUT" in
  *"Nothing pending."*)
    echo "  FAIL: 'Nothing pending.' present despite pending sources"; FAIL=$((FAIL + 1));;
  *)
    echo "  PASS: 'Nothing pending.' is correctly absent"; PASS=$((PASS + 1));;
esac

# Test 9: human mode omits zero-count sections.
echo ""
echo "Test 9: zero sections omitted from human output"
case "$OUT" in
  *"Needs you:"*)
    echo "  FAIL: 'Needs you:' header present despite zero contradictions/staleness"
    FAIL=$((FAIL + 1));;
  *)
    echo "  PASS: 'Needs you:' header omitted on populated-sources-only vault"
    PASS=$((PASS + 1));;
esac
case "$OUT" in
  *"Awaiting review:"*)
    echo "  FAIL: 'Awaiting review:' header present despite zero changes"
    FAIL=$((FAIL + 1));;
  *)
    echo "  PASS: 'Awaiting review:' header omitted"
    PASS=$((PASS + 1));;
esac
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/test_status.sh
```

Expected: Tests 1b and 2b FAIL (human mode currently dumps JSON via Task 2's placeholder), Test 9 may PASS by accident — that's OK, the next step fixes the real issue.

- [ ] **Step 3: Implement `emitHuman`**

In `scripts/status.js`, replace the `emitHuman` placeholder:

```javascript
function emitHuman(dash) {
  const lines = [];
  lines.push(`Second Brain — vault: ${dash.vault.name}`);
  lines.push('─────────────────────────────────────────────');

  const needsYou = [];
  if (dash.contradictions.unresolved > 0) {
    needsYou.push(`  Contradictions     ${dash.contradictions.unresolved} unresolved      (/second-brain:status reconcile)`);
  }
  const high = dash.staleness.unresolved_high;
  const med  = dash.staleness.unresolved_medium;
  if (high + med > 0) {
    needsYou.push(`  Stale pages        ${high} high + ${med} medium (/second-brain:status refresh)`);
  }

  const awaiting = [];
  if (dash.since_review.change_count > 0) {
    const since = dash.since_review.last_accepted_at || 'never';
    awaiting.push(`  ${dash.since_review.change_count} changes since ${since}         (/second-brain:status review)`);
  }

  const automation = [];
  const newSrc = dash.sources.new;
  const chgSrc = dash.sources.changed;
  if (newSrc + chgSrc > 0) {
    automation.push(`  Sources            ${newSrc} new in raw/, ${chgSrc} changed`);
    automation.push(`                     hint: claude --headless -p "/second-brain:ingest"`);
  }

  const lintLine = (dash.lint.errors > 0 || dash.lint.warnings > 0)
    ? `Lint: ${dash.lint.errors} errors, ${dash.lint.warnings} warnings           (/second-brain:lint)`
    : null;

  const anyContent = needsYou.length || awaiting.length || automation.length || lintLine;
  if (!anyContent) {
    lines.push('Nothing pending.');
    process.stdout.write(lines.join('\n') + '\n');
    return;
  }
  if (needsYou.length) {
    lines.push('Needs you:');
    lines.push(...needsYou);
    lines.push('');
  }
  if (awaiting.length) {
    lines.push('Awaiting review:');
    lines.push(...awaiting);
    lines.push('');
  }
  if (automation.length) {
    lines.push('Automation could pick up:');
    lines.push(...automation);
    lines.push('');
  }
  if (lintLine) lines.push(lintLine);
  process.stdout.write(lines.join('\n') + '\n');
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_status.sh
```

Expected: Tests 1b, 2b, 9 all PASS. Earlier tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/status.js tests/test_status.sh
git commit -m "$(cat <<'EOF'
feat(status): human dashboard with three categorisations

Renders Needs you / Awaiting review / Automation could pick up
sections, omitting headers whose rows would all be zero. Falls back
to 'Nothing pending.' when the vault has no pending concerns. Lint
warnings render as a trailing line. The JSON shape stays uncategorised
so cron consumers route on their own.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Malformed state-file handling + JSON stability

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`

Spec §5.4: any YAML file under `wiki/.state/` malformed → exit 2 with stderr naming the file. Also test 11 (JSON byte-stable across runs when state hasn't changed).

The malformed-handling path is already wired in `readStateYaml` from Task 2; this task adds the tests and a `state-sources.js diff` failure propagation test.

- [ ] **Step 1: Add test cases 6, 7, 11**

Insert before `=== Results ===`:

```bash
# Test 6: malformed sources.yaml → exit 2 with helpful stderr.
echo ""
echo "Test 6: malformed sources.yaml"
V6=$(make_vault vault6)
echo "this is: not: valid: yaml: at all: ::" > "$V6/wiki/.state/sources.yaml"
set +e
OUT=$( (cd "$V6" && node "$SCRIPT" --json 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on malformed sources.yaml" "2" "$EXIT"
case "$OUT" in
  *"sources.yaml"*)
    echo "  PASS: stderr names sources.yaml"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not mention sources.yaml — got: $OUT"
    FAIL=$((FAIL + 1));;
esac

# Test 7: malformed since-review.yaml → exit 2 with helpful stderr.
echo ""
echo "Test 7: malformed since-review.yaml"
V7=$(make_vault vault7)
echo "this is: not: valid: yaml: at all: ::" > "$V7/wiki/.state/since-review.yaml"
(cd "$V7" && git add . && git commit -qm "broken" >/dev/null)
set +e
OUT=$( (cd "$V7" && node "$SCRIPT" --json 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on malformed since-review.yaml" "2" "$EXIT"
case "$OUT" in
  *"since-review.yaml"*)
    echo "  PASS: stderr names since-review.yaml"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not mention since-review.yaml — got: $OUT"
    FAIL=$((FAIL + 1));;
esac

# Test 11: JSON byte-stable across two consecutive runs when state is unchanged.
echo ""
echo "Test 11: --json byte-stable across runs"
V11=$(make_vault vault11)
echo "one" > "$V11/raw/one.md"
RUN1=$( (cd "$V11" && node "$SCRIPT" --json) )
RUN2=$( (cd "$V11" && node "$SCRIPT" --json) )
if [ "$RUN1" = "$RUN2" ]; then
  echo "  PASS: two runs produced identical JSON"; PASS=$((PASS + 1))
else
  echo "  FAIL: --json output differed between runs:"
  diff <(echo "$RUN1") <(echo "$RUN2") | head -20
  FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Run the tests to verify they pass (or expose any drift)**

```bash
bash tests/test_status.sh
```

Expected: Tests 6 and 7 should PASS already because `readStateYaml` (Task 2) calls `die(... malformed)` on `yaml.load` errors. If they fail because the error message doesn't include the file path, fix `readStateYaml` in scripts/status.js so the `die` message reads `wiki/.state/${relname} malformed: ...`. Test 11 should PASS because no readers introduce timestamps; if it fails, audit `buildDashboard` for unintended jitter.

- [ ] **Step 3: If any test failed, fix and re-run**

Most likely root cause if Test 11 fails: a section reader put a `new Date()` into its output. Don't. The only timestamp in the dashboard payload is `since_review.last_accepted_at`, which comes from the state file itself, not from `Date.now()`.

- [ ] **Step 4: Commit**

```bash
git add scripts/status.js tests/test_status.sh
git commit -m "$(cat <<'EOF'
test(status): malformed-state and byte-stability cases

Locks the spec §5.4 contract: any wiki/.state/*.yaml malformed → exit 2
with stderr naming the offending file. Also locks the byte-stability
invariant (test 11): two consecutive --json runs on unchanged state
produce identical output, which is what cron consumers depend on.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `review-log.js` skeleton + atomic write + test harness

**Files:**
- Create: `scripts/review-log.js`
- Create: `tests/test_review_log.sh`

Skeleton: vault detection (no `sources.yaml` requirement — `review-log.js` can run before any ingest), parseArgs for `append | show | accept` plus `--kind` / `--data` / `--json`, atomic write helper, `die`. No subcommand implementations yet.

- [ ] **Step 1: Create `tests/test_review_log.sh` skeleton + missing-subcommand test**

```bash
#!/bin/bash
set -e

# Test: scripts/review-log.js — since-review.yaml owner.
# Usage: bash tests/test_review_log.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/review-log.js"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/wiki/.state"
  cat > "$v/wiki/.state/sources.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
  (cd "$v" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
  echo "$v"
}

echo "=== Test: review-log.js ==="

# Test: unknown subcommand → exit 2.
echo ""
echo "Test: unknown subcommand → exit 2"
V0=$(make_vault vault0)
set +e
OUT=$( (cd "$V0" && node "$SCRIPT" nonsense 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on unknown subcommand" "2" "$EXIT"

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
chmod +x tests/test_review_log.sh
bash tests/test_review_log.sh
```

Expected: FAIL with "Cannot find module" (script does not exist yet).

- [ ] **Step 3: Create `scripts/review-log.js` skeleton**

```javascript
#!/usr/bin/env node
'use strict';

/**
 * scripts/review-log.js — owner of wiki/.state/since-review.yaml.
 *
 * Subcommands:
 *   append --kind=<kind> --data=<json>  Append one change entry.
 *   show [--json]                       Print the current inbox (grouped or raw).
 *   accept                              Truncate changes[], bump last_accepted_at.
 *
 * Exit codes:
 *   0 = success
 *   2 = unknown subcommand, missing required flag, malformed --data,
 *       or since-review.yaml exists but malformed / on an unsupported schema_version.
 *
 * Vault detection: walks up for both .git/ and wiki/.state/sources.yaml,
 * matching status.js and validate-wiki.js.
 *
 * Atomic write: write to a sibling tmpfile, then fs.renameSync into place.
 * On a single-machine, single-user setup the sub-second window between
 * concurrent appends is acceptable per spec §6.4 — no lock file in v1.
 */

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/review-log.js';
const STATE_FILE = 'wiki/.state/since-review.yaml';

function die(msg, code = 2) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(code);
}

function findVaultRoot(start) {
  let dir = path.resolve(start);
  while (true) {
    const hasGit = fs.existsSync(path.join(dir, '.git'));
    const hasState = fs.existsSync(path.join(dir, 'wiki', '.state', 'sources.yaml'));
    if (hasGit && hasState) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function nowIso() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

function readState(vault) {
  const abs = path.join(vault, STATE_FILE);
  if (!fs.existsSync(abs)) return null;
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch (err) { die(`${STATE_FILE} unreadable: ${err.message}`, 2); }
  let doc;
  try { doc = yaml.load(text); }
  catch (err) { die(`${STATE_FILE} malformed: ${err.message}`, 2); }
  if (!doc || typeof doc !== 'object') die(`${STATE_FILE} malformed: not a YAML mapping`, 2);
  if (doc.schema_version !== SCHEMA_VERSION) {
    die(`${STATE_FILE} schema_version=${doc.schema_version}, expected ${SCHEMA_VERSION}`, 2);
  }
  if (!Array.isArray(doc.changes)) doc.changes = [];
  return doc;
}

function writeState(vault, doc) {
  doc.schema_version = SCHEMA_VERSION;
  doc.generated_by = GENERATED_BY;
  const abs = path.join(vault, STATE_FILE);
  const dir = path.dirname(abs);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${abs}.tmp.${process.pid}.${Date.now()}`;
  const out = yaml.dump(doc, { indent: 2, sortKeys: false, lineWidth: -1 });
  fs.writeFileSync(tmp, out);
  fs.renameSync(tmp, abs);
}

function emptyState() {
  return {
    schema_version: SCHEMA_VERSION,
    generated_by: GENERATED_BY,
    last_accepted_at: null,
    changes: [],
  };
}

function cmdAppend(vault, args) {
  die('append not yet implemented', 2); // Filled in by Task 11.
}

function cmdShow(vault, args) {
  die('show not yet implemented', 2);   // Filled in by Task 12.
}

function cmdAccept(vault, args) {
  die('accept not yet implemented', 2); // Filled in by Task 13.
}

function parseArgs(argv) {
  const cmd = argv[0];
  const args = { kind: null, data: null, json: false };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--kind=')) args.kind = a.slice('--kind='.length);
    else if (a === '--kind') args.kind = argv[++i];
    else if (a.startsWith('--data=')) args.data = a.slice('--data='.length);
    else if (a === '--data') args.data = argv[++i];
    else if (a === '--json') args.json = true;
    else die(`unknown argument: ${a}`, 2);
  }
  return { cmd, args };
}

function main() {
  const { cmd, args } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  if (cmd === 'append') return cmdAppend(vault, args);
  if (cmd === 'show')   return cmdShow(vault, args);
  if (cmd === 'accept') return cmdAccept(vault, args);
  die(`unknown subcommand: ${cmd}`, 2);
}

main();
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_review_log.sh
```

Expected: PASS on "exit 2 on unknown subcommand".

- [ ] **Step 5: Commit**

```bash
git add scripts/review-log.js tests/test_review_log.sh
git commit -m "$(cat <<'EOF'
feat(review-log): scaffold review-log.js with atomic-write helper

Adds scripts/review-log.js with vault detection, parseArgs for the
three subcommands (append/show/accept) and supporting flags, plus
readState/writeState helpers using atomic tmpfile+rename semantics
per spec §6.4. Subcommand bodies are die() stubs filled in by Tasks
11–13. tests/test_review_log.sh follows the test_state_sources.sh
shape; only the unknown-subcommand case is wired so far.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `review-log.js append`

**Files:**
- Modify: `scripts/review-log.js`
- Modify: `tests/test_review_log.sh`

Spec §6.2: parse `--data` as JSON, merge with `{at: <now-iso>, kind: <kind>}`, append to `changes[]`, atomic write. Lazy-creates the file with `last_accepted_at: null` if absent. Per-kind payload is freeform — no validation beyond JSON parsability.

- [ ] **Step 1: Add tests 3, 4 (first append + accumulate), 6 (malformed JSON), 7 (free-string kind), 8 (concurrent)**

Insert these tests in `tests/test_review_log.sh` before `=== Results ===`. (Numbering follows spec §10.2; the lazy-create cases land in Tasks 12/13.)

```bash
# Test 3: first append → file gains one entry with merged fields.
echo ""
echo "Test 3: first append creates file with one merged entry"
V3=$(make_vault vault3)
(cd "$V3" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/x.md","wrote":["wiki/sources/x.md"]}' >/dev/null)
COUNT=$(node -e "process.stdout.write(String((require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes||[]).length))")
assert_eq "changes has 1 entry"     "1" "$COUNT"
KIND=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes[0].kind)")
assert_eq "kind === ingest"         "ingest" "$KIND"
SRC=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes[0].source)")
assert_eq "source merged in"        "raw/x.md" "$SRC"
HAS_AT=$(node -e "let e=require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes[0]; process.stdout.write(String(typeof e.at === 'string' && e.at.endsWith('Z')))")
assert_eq "at is ISO string ending in Z" "true" "$HAS_AT"
LAST=$(node -e "let d=require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')); process.stdout.write(String(d.last_accepted_at))")
assert_eq "last_accepted_at initialized to null" "null" "$LAST"

# Test 4: two appends accumulate; second entry coexists with first.
echo ""
echo "Test 4: two appends accumulate"
(cd "$V3" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/y.md"}' >/dev/null)
COUNT=$(node -e "process.stdout.write(String((require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes||[]).length))")
assert_eq "changes has 2 entries" "2" "$COUNT"

# Test 6: malformed --data → exit 2.
echo ""
echo "Test 6: malformed --data JSON → exit 2"
V6=$(make_vault vault6)
set +e
OUT=$( (cd "$V6" && node "$SCRIPT" append --kind=ingest --data='{not json' 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on malformed --data" "2" "$EXIT"

# Test 7: free-string kind is accepted (no validation against an allow-list).
echo ""
echo "Test 7: custom kind accepted"
V7=$(make_vault vault7)
(cd "$V7" && node "$SCRIPT" append --kind=my-custom --data='{"foo":"bar"}' >/dev/null)
KIND=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V7/wiki/.state/since-review.yaml','utf8')).changes[0].kind)")
assert_eq "kind === my-custom" "my-custom" "$KIND"
FOO=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V7/wiki/.state/since-review.yaml','utf8')).changes[0].foo)")
assert_eq "free-string payload merged" "bar" "$FOO"

# Test 8: two rapid appends both land via atomic rename.
echo ""
echo "Test 8: rapid concurrent appends both land"
V8=$(make_vault vault8)
(cd "$V8" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/a.md"}' >/dev/null) &
(cd "$V8" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/b.md"}' >/dev/null) &
wait
COUNT=$(node -e "process.stdout.write(String((require('js-yaml').load(require('fs').readFileSync('$V8/wiki/.state/since-review.yaml','utf8')).changes||[]).length))" 2>/dev/null || echo "0")
# Atomic rename guarantees the file is never torn, but the last-writer-wins
# semantics mean one entry may be overwritten. Document the v1 behaviour: at
# least one entry lands.
if [ "$COUNT" -ge 1 ]; then
  echo "  PASS: at least one rapid append landed (count=$COUNT)"; PASS=$((PASS + 1))
else
  echo "  FAIL: no entries landed after concurrent appends"; FAIL=$((FAIL + 1))
fi
```

Note on Test 8: the spec §6.4 ("Two crons firing in the same second could in theory race") accepts last-writer-wins. The test only asserts that at least one entry is present, not both — true concurrency safety needs a lock file (out of scope per spec).

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/test_review_log.sh
```

Expected: every Test 3/4/7 assertion FAILs (append stubbed), Test 6 PASSes (`die` returns exit 2 already), Test 8 FAILs.

- [ ] **Step 3: Implement `cmdAppend`**

In `scripts/review-log.js`, replace the `cmdAppend` stub:

```javascript
function cmdAppend(vault, args) {
  if (!args.kind) die('--kind is required', 2);
  if (!args.data) die('--data is required (use --data=\'{}\' for an empty payload)', 2);
  let payload;
  try { payload = JSON.parse(args.data); }
  catch (err) { die(`--data is not valid JSON: ${err.message}`, 2); }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    die('--data must be a JSON object', 2);
  }
  const doc = readState(vault) || emptyState();
  const entry = Object.assign({ at: nowIso(), kind: args.kind }, payload);
  doc.changes.push(entry);
  writeState(vault, doc);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_review_log.sh
```

Expected: Tests 3, 4, 6, 7, 8 PASS. Unknown-subcommand case still PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-log.js tests/test_review_log.sh
git commit -m "$(cat <<'EOF'
feat(review-log): implement append subcommand

Parses --kind and --data, merges {at, kind} with the JSON payload, and
appends to changes[] via atomic write. Lazy-creates the state file with
last_accepted_at: null on first call. --data must be a JSON object (not
an array or scalar) to keep the merge semantics unambiguous; kinds are
free strings so future CRs can invent payload shapes without amending
CR-009. Concurrent appends use atomic rename — last-writer-wins is
accepted in v1 per spec §6.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: `review-log.js show`

**Files:**
- Modify: `scripts/review-log.js`
- Modify: `tests/test_review_log.sh`

Spec §6.2: default mode prints grouped-by-kind summary (count per kind, then up to 20 entries per kind with `... and N more`). `--json` dumps the full file. Missing file → empty output, exit 0.

- [ ] **Step 1: Add tests 1 (show on missing file) and 4b (show after appends)**

Insert before `=== Results ===`:

```bash
# Test 1: show on missing file → empty output, exit 0.
echo ""
echo "Test 1: show on missing file"
V1=$(make_vault vault1)
set +e
OUT=$( (cd "$V1" && node "$SCRIPT" show) )
EXIT=$?
set -e
assert_eq "exit 0 on missing file" "0" "$EXIT"
case "$OUT" in
  ""|"No review-log entries"*)
    echo "  PASS: empty or 'no entries' output on missing file"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: unexpected output on missing file — got: $OUT"; FAIL=$((FAIL + 1));;
esac

# Test 4b: show after two appends → human output groups by kind, lists both.
echo ""
echo "Test 4b: show groups appended entries by kind"
V4b=$(make_vault vault4b)
(cd "$V4b" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/a.md"}' >/dev/null)
(cd "$V4b" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/b.md"}' >/dev/null)
(cd "$V4b" && node "$SCRIPT" append --kind=lint-autofix --data='{"note":"fixed link"}' >/dev/null)
OUT=$( (cd "$V4b" && node "$SCRIPT" show) )
case "$OUT" in
  *"ingest"*"2"*"lint-autofix"*"1"*)
    echo "  PASS: show output mentions both kinds with counts"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: show output missing expected kind/count — got:"; echo "$OUT"
    FAIL=$((FAIL + 1));;
esac

# Test 4b-json: show --json dumps the full file as JSON.
OUT_JSON=$( (cd "$V4b" && node "$SCRIPT" show --json) )
COUNT=$(echo "$OUT_JSON" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).changes.length)))")
assert_eq "show --json has 3 changes" "3" "$COUNT"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/test_review_log.sh
```

Expected: Tests 1 and 4b FAIL (show stubbed).

- [ ] **Step 3: Implement `cmdShow`**

In `scripts/review-log.js`, replace the `cmdShow` stub:

```javascript
function cmdShow(vault, args) {
  const doc = readState(vault);
  if (!doc || doc.changes.length === 0) {
    if (args.json) {
      process.stdout.write(JSON.stringify(doc || emptyState(), null, 2) + '\n');
      return;
    }
    process.stdout.write('No review-log entries.\n');
    return;
  }
  if (args.json) {
    process.stdout.write(JSON.stringify(doc, null, 2) + '\n');
    return;
  }
  // Group by kind.
  const groups = new Map();
  for (const e of doc.changes) {
    const k = e.kind || '(unknown)';
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(e);
  }
  const lines = [];
  lines.push(`since last accept (${doc.last_accepted_at || 'never'}): ${doc.changes.length} entries across ${groups.size} kinds`);
  lines.push('');
  for (const [kind, entries] of groups) {
    lines.push(`${kind} (${entries.length}):`);
    const shown = entries.slice(-20);
    for (const e of shown) {
      const { at, kind: _k, ...rest } = e;
      lines.push(`  ${at}  ${JSON.stringify(rest)}`);
    }
    if (entries.length > 20) {
      lines.push(`  ... and ${entries.length - 20} more`);
    }
    lines.push('');
  }
  process.stdout.write(lines.join('\n'));
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_review_log.sh
```

Expected: Tests 1, 4b, 4b-json PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-log.js tests/test_review_log.sh
git commit -m "$(cat <<'EOF'
feat(review-log): implement show subcommand

Default mode groups entries by kind and prints up to 20 per group with
a '... and N more' truncation hint; --json dumps the full file. Missing
file → 'No review-log entries.' (or empty-state JSON) with exit 0. Each
entry renders as 'at  {payload}' so the user sees the timestamp + the
free-string payload without forcing per-kind formatting.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: `review-log.js accept`

**Files:**
- Modify: `scripts/review-log.js`
- Modify: `tests/test_review_log.sh`

Spec §6.2: clear `changes[]`, bump `last_accepted_at` to now. Missing file → create empty with `last_accepted_at: <now>`, print `accepted 0 changes since (none)`. Stdout reports cleared count and previous `last_accepted_at`.

- [ ] **Step 1: Add tests 2 (accept on missing file) and 5 (accept after appends)**

Insert before `=== Results ===`:

```bash
# Test 2: accept on missing file → creates file, exit 0, message reports 0 cleared.
echo ""
echo "Test 2: accept on missing file"
V2=$(make_vault vault2)
OUT=$( (cd "$V2" && node "$SCRIPT" accept) )
assert_eq "stdout reports 0 changes" "accepted 0 changes since (none)" "$OUT"
if [ -f "$V2/wiki/.state/since-review.yaml" ]; then
  echo "  PASS: since-review.yaml was created on accept"; PASS=$((PASS + 1))
else
  echo "  FAIL: since-review.yaml was not created"; FAIL=$((FAIL + 1))
fi
COUNT=$(node -e "process.stdout.write(String((require('js-yaml').load(require('fs').readFileSync('$V2/wiki/.state/since-review.yaml','utf8')).changes||[]).length))")
assert_eq "changes is empty"          "0" "$COUNT"
HAS_AT=$(node -e "let d=require('js-yaml').load(require('fs').readFileSync('$V2/wiki/.state/since-review.yaml','utf8')); process.stdout.write(String(typeof d.last_accepted_at === 'string' && d.last_accepted_at.endsWith('Z')))")
assert_eq "last_accepted_at set"      "true" "$HAS_AT"

# Test 5: accept after appends clears changes, bumps last_accepted_at, reports count.
echo ""
echo "Test 5: accept after appends"
V5=$(make_vault vault5)
(cd "$V5" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/a.md"}' >/dev/null)
(cd "$V5" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/b.md"}' >/dev/null)
OUT=$( (cd "$V5" && node "$SCRIPT" accept) )
case "$OUT" in
  "accepted 2 changes since "*)
    echo "  PASS: stdout reports 2 cleared"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: expected 'accepted 2 changes since ...' — got: $OUT"
    FAIL=$((FAIL + 1));;
esac
COUNT=$(node -e "process.stdout.write(String((require('js-yaml').load(require('fs').readFileSync('$V5/wiki/.state/since-review.yaml','utf8')).changes||[]).length))")
assert_eq "changes is empty after accept" "0" "$COUNT"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/test_review_log.sh
```

Expected: Tests 2 and 5 FAIL (accept stubbed).

- [ ] **Step 3: Implement `cmdAccept`**

In `scripts/review-log.js`, replace the `cmdAccept` stub:

```javascript
function cmdAccept(vault, _args) {
  const doc = readState(vault) || emptyState();
  const prevCount = doc.changes.length;
  const prevAt = doc.last_accepted_at || '(none)';
  doc.changes = [];
  doc.last_accepted_at = nowIso();
  writeState(vault, doc);
  process.stdout.write(`accepted ${prevCount} changes since ${prevAt}\n`);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_review_log.sh
```

Expected: Tests 2 and 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-log.js tests/test_review_log.sh
git commit -m "$(cat <<'EOF'
feat(review-log): implement accept subcommand

Truncates changes[] and bumps last_accepted_at to now-iso. Missing file
is lazy-created with empty changes and the new timestamp. Stdout reports
the count cleared and the previous last_accepted_at (or '(none)' on the
first accept) so the user sees what they just acknowledged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: `review-log.js` schema-version validation

**Files:**
- Modify: `tests/test_review_log.sh`

Spec §10.2 case 9: reading a file with `schema_version: 0` → exit 2 with a clear message. The `readState` helper already enforces this from Task 10 (`if (doc.schema_version !== SCHEMA_VERSION) die(...)`). This task just adds the test.

- [ ] **Step 1: Add test 9 (older schema_version → exit 2)**

Insert before `=== Results ===`:

```bash
# Test 9: since-review.yaml with schema_version=0 → exit 2.
echo ""
echo "Test 9: older schema_version rejected"
V9=$(make_vault vault9)
cat > "$V9/wiki/.state/since-review.yaml" <<'YAML'
schema_version: 0
generated_by: legacy
changes: []
YAML
set +e
OUT=$( (cd "$V9" && node "$SCRIPT" show 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on schema_version=0" "2" "$EXIT"
case "$OUT" in
  *"schema_version"*)
    echo "  PASS: stderr mentions schema_version"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not mention schema_version — got: $OUT"
    FAIL=$((FAIL + 1));;
esac
```

- [ ] **Step 2: Run the test to verify it passes**

```bash
bash tests/test_review_log.sh
```

Expected: Test 9 PASS. (The `readState` guard from Task 10 already covers this.)

If it fails, revisit `readState` in `scripts/review-log.js` and confirm the schema_version check is present and the message includes the literal string `schema_version`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_review_log.sh
git commit -m "$(cat <<'EOF'
test(review-log): lock the schema_version=1 forward-only contract

Confirms that a since-review.yaml with schema_version: 0 is rejected
with exit 2 + a stderr message naming the field. v1 fails fast on
unknown versions per spec §10.2; a migration helper is deferred until
a real version bump is needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Create `skills/status/SKILL.md`

**Files:**
- Create: `skills/status/SKILL.md`

Thin skill — never hand-reads state YAML. Default invocation prints `status.js` output verbatim. Sub-args route to `review-log.js` for `review` / `accept`; `reconcile` and `refresh` are placeholders pointing at CR-007 / CR-008.

- [ ] **Step 1: Create `skills/status/SKILL.md`**

```markdown
---
name: status
description: >
  Show what the second-brain vault needs — pending contradictions to resolve,
  stale pages to triage, changes awaiting review, sources ready for ingest,
  lint warnings. Use when the user says "status", "what's pending", "dashboard",
  "what changed", "review changes", or asks what they should do next in the vault.
allowed-tools: Bash Read
---

# Second Brain — Status

One entry point for every pending vault concern. Default prints the dashboard;
sub-args route to inbox review, accept, and (once CR-007/008 land) interactive
contradiction and staleness resolution loops.

## Tooling

This SKILL drives all state queries through two scripts. Never hand-read
`wiki/.state/*.yaml`. Never compute counts in the LLM — call the script.

- `scripts/status.js` — read-only dashboard reporter.
- `scripts/review-log.js` — owner of `wiki/.state/since-review.yaml`.

Both resolve the vault root by walking up for both `.git/` and
`wiki/.state/sources.yaml`. Outside a vault they exit 2 with a pointer to
`/second-brain:onboard`.

## Default invocation: `/second-brain:status`

Print the dashboard. Run:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/status.js"
```

Echo stdout verbatim. Do not summarise or reformat — the script's output is
the contract.

## `/second-brain:status review`

Print the since-review changelog grouped by kind:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" show
```

Then read the last-accepted timestamp from JSON mode and emit a hint pointing
the user at `git log` for file-level diffs:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" show --json
```

From the JSON, extract `last_accepted_at`. If it is non-null, append:

```
For file-level diffs since last accept: git log --since=<last_accepted_at> wiki/
```

If it is null, append:

```
For file-level diffs since vault init: git log wiki/
```

## `/second-brain:status accept`

Clear the inbox. Run:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" accept
```

Echo stdout verbatim. No confirmation prompt — accept is user-initiated and
recoverable via git.

## `/second-brain:status reconcile`

Placeholder until CR-007 lands. Print:

```
/status reconcile is not yet available. CR-007 will implement contradiction
detection. Until then, /second-brain:lint flags candidate contradictions
in its report.
```

## `/second-brain:status refresh`

Placeholder until CR-008 lands. Print:

```
/status refresh is not yet available. CR-008 will implement staleness review.
Until then, /second-brain:lint flags candidate stale pages in its report.
```

## Headless mode

`scripts/status.js --json` is the contract for cron-driven workflows. See
`docs/install/headless-driving.md` for an hourly cron example.

When CR-007 and CR-008 land, `/second-brain:status reconcile --judge-only`
and `/second-brain:status refresh --judge-only` become cron-safe headless
entry points. Their bodies live in those CRs; the routing shape is locked
here.

## Related skills

- `/second-brain:ingest` — process raw sources. Appends `kind: ingest` to the
  review log on each successful source ingest.
- `/second-brain:lint` — health-check the wiki. Read-only counts surface via
  the dashboard's `lint.{errors,warnings}` fields.
- `/second-brain:onboard` — scaffold a new vault. Must run before
  `/second-brain:status` works at all.

## JSON schema

See `references/status-json-schema.md` for the stable JSON shape, default
values, and the `present: false` flag on not-yet-implemented sections.
```

- [ ] **Step 2: Verify the skill is discoverable**

Since skills are auto-discovered from `skills/*/SKILL.md`, no marketplace update is needed. Confirm by listing the directory:

```bash
ls skills/status/
```

Expected: `SKILL.md` is present.

- [ ] **Step 3: Commit**

```bash
git add skills/status/SKILL.md
git commit -m "$(cat <<'EOF'
feat(status): add /second-brain:status skill

Thin skill that pins to scripts/status.js and scripts/review-log.js.
Routes sub-args: review (show + git-log hint), accept (clear inbox),
reconcile/refresh (placeholders until CR-007/008 land). Default prints
the dashboard verbatim — no LLM reformatting.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Create `skills/status/references/status-json-schema.md`

**Files:**
- Create: `skills/status/references/status-json-schema.md`

Field-by-field documentation of the JSON shape from spec §5.2, with worked examples.

- [ ] **Step 1: Create the reference doc**

```markdown
# `status.js --json` Schema (v1)

Stable shape emitted by `node scripts/status.js --json`. Cron consumers depend
on this contract — additions require a `schema_version` bump (currently implied
by file format; once we cross version 2, an explicit top-level key lands).

## Shape

```json
{
  "vault":           { "root": "<absolute-path>", "name": "<basename>" },
  "sources":         { "new": 0, "changed": 0, "deleted": 0 },
  "lint":            { "errors": 0, "warnings": 0 },
  "contradictions":  { "unjudged_candidates": 0, "unresolved": 0, "present": false },
  "staleness":       { "unjudged_candidates": 0, "unresolved_high": 0, "unresolved_medium": 0, "present": false },
  "since_review":    { "change_count": 0, "last_accepted_at": null }
}
```

## Fields

### `vault`
- **`root`** (string): absolute path to the vault root (directory containing
  both `.git/` and `wiki/.state/sources.yaml`).
- **`name`** (string): basename of `vault.root`. Convenience for human output;
  cron consumers should not rely on uniqueness across machines.

### `sources`
Derived from `state-sources.js diff` (filesystem vs `wiki/.state/sources.yaml`,
content-hash based).
- **`new`** (integer): sources on disk but absent from `sources.yaml`.
- **`changed`** (integer): sources whose content hash differs from `sources.yaml`.
- **`deleted`** (integer): sources in `sources.yaml` but no longer on disk.

### `lint`
Derived from `validate-wiki.js all --json` regardless of its exit code.
- **`errors`** (integer): `frontmatter.errors.length` +
  `wikilinks.broken.length` + `index.dead_rows.length`.
- **`warnings`** (integer): `wikilinks.orphans.length` +
  `index.missing_rows.length`.

### `contradictions`
Read directly from `wiki/.state/contradictions.yaml` (owned by CR-007).
- **`present`** (boolean): `true` if the state file exists; `false` until
  CR-007 lands.
- **`unjudged_candidates`** (integer): always `0` in CR-009. CR-007 may compute
  candidates on-demand rather than persist them; either way the key stays for
  cron-consumer forward compatibility.
- **`unresolved`** (integer): count of entries with `status: unresolved`. CR-007
  owns the per-entry semantics; CR-009 only counts.

### `staleness`
Read directly from `wiki/.state/staleness.yaml` (owned by CR-008).
- **`present`** (boolean): `true` if the state file exists; `false` until
  CR-008 lands.
- **`unjudged_candidates`** (integer): always `0` in CR-009 (same forward-
  compatibility reasoning as `contradictions.unjudged_candidates`).
- **`unresolved_high`** (integer): count of entries with `signal: high` AND
  `status: unreviewed`.
- **`unresolved_medium`** (integer): count of entries with `signal: medium` AND
  `status: unreviewed`. `signal: low` is intentionally not surfaced — the
  dashboard routes the user to high+medium triage only.

### `since_review`
Read directly from `wiki/.state/since-review.yaml`.
- **`change_count`** (integer): `len(changes)` from the state file.
- **`last_accepted_at`** (string|null): ISO 8601 UTC timestamp of the last
  `/second-brain:status accept`, or `null` if never accepted (or if the state
  file does not yet exist).

## Stability commitment

- Every key above is **always present** in `--json` output. Sections derived
  from optional state files emit zeros + `present: false` when the file is
  absent, never omit themselves.
- Field additions (new top-level sections, new sub-keys) are non-breaking and
  can land in any CR.
- Field removals or semantic changes are breaking and require bumping
  `schema_version` (and a migration note in the CR that does it).
- The dashboard payload contains no `generated_at` timestamp: byte-stability
  across runs (with unchanged state) is the test-locked contract.

## Worked examples

### Fresh vault

```json
{
  "vault":           { "root": "/Users/u/Documents/personal", "name": "personal" },
  "sources":         { "new": 0, "changed": 0, "deleted": 0 },
  "lint":            { "errors": 0, "warnings": 0 },
  "contradictions":  { "unjudged_candidates": 0, "unresolved": 0, "present": false },
  "staleness":       { "unjudged_candidates": 0, "unresolved_high": 0, "unresolved_medium": 0, "present": false },
  "since_review":    { "change_count": 0, "last_accepted_at": null }
}
```

### Populated vault

```json
{
  "vault":           { "root": "/Users/u/Documents/client-x", "name": "client-x" },
  "sources":         { "new": 5, "changed": 2, "deleted": 0 },
  "lint":            { "errors": 0, "warnings": 3 },
  "contradictions":  { "unjudged_candidates": 0, "unresolved": 3, "present": true },
  "staleness":       { "unjudged_candidates": 0, "unresolved_high": 5, "unresolved_medium": 2, "present": true },
  "since_review":    { "change_count": 12, "last_accepted_at": "2026-05-12T08:00:00Z" }
}
```

## Cron consumer patterns

```bash
# Any pending sources?
STATUS=$(node "$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
if [ "$(echo "$STATUS" | jq '.sources.new + .sources.changed')" -gt 0 ]; then
  claude --headless -p "/second-brain:ingest"
fi

# Any unjudged contradiction candidates?
if [ "$(echo "$STATUS" | jq '.contradictions.unjudged_candidates')" -gt 0 ]; then
  claude --headless -p "/second-brain:status reconcile --judge-only"
fi
```

See `docs/install/headless-driving.md` for a full crontab example.
```

- [ ] **Step 2: Commit**

```bash
mkdir -p skills/status/references
git add skills/status/references/status-json-schema.md
git commit -m "$(cat <<'EOF'
docs(status): document status.js --json schema with examples

Field-by-field reference for cron consumers. Locks: every key always
present, present: false flag for not-yet-implemented sections, no
generated_at timestamp (byte-stability is test-locked), additions are
non-breaking and removals require schema_version bump.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Create `docs/install/headless-driving.md`

**Files:**
- Create: `docs/install/headless-driving.md`

Concrete cron example, recommended cadence, `.claude/headless.log` convention.

- [ ] **Step 1: Check whether `docs/install/` exists**

```bash
ls docs/install/ 2>&1 || echo "missing"
```

If missing, the next step's `git add` will create it.

- [ ] **Step 2: Create the doc**

```markdown
# Headless driving with cron

`/second-brain:status` exposes a stable JSON shape via `--json`. Cron jobs can
read it, decide what to do, and fire headless Claude Code invocations. This
keeps the user out of the loop for routine work and surfaces only what truly
needs human judgment via `/second-brain:status`.

## The pattern

```bash
STATUS=$("$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
COND=$(echo "$STATUS" | jq '<predicate>')
[ "$COND" -gt 0 ] && claude --headless -p "/second-brain:<skill>"
```

The script is read-only and exits non-zero only on a broken vault. Cron's
default mail-on-failure semantics give you a free monitoring channel.

## Recommended cadence

| Job | Cadence | Rationale |
|---|---|---|
| Ingest new sources | Hourly | Sources arrive in bursts (paste-clip-drop). Hourly catches them while their context is still fresh in the user's mind. |
| Headless judge passes (`reconcile --judge-only`, `refresh --judge-only`) | Daily | Judging is LLM-heavy. Hourly would burn API quota for marginal latency win. |
| Lint sweep | Weekly | Lint surfaces orphan pages and structural drift — slow signals. |

These are starting points; tune to vault size and ingest volume.

## Worked crontab

```bash
# Hourly: pick up new sources, then judge what came in.
0 * * * * cd /path/to/vault && {
  STATUS=$("$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
  NEW=$(echo "$STATUS" | jq '.sources.new + .sources.changed')
  if [ "$NEW" -gt 0 ]; then
    claude --headless -p "/second-brain:ingest" >> .claude/headless.log 2>&1
  fi
  STATUS=$("$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
  [ "$(echo "$STATUS" | jq '.contradictions.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:status reconcile --judge-only" >> .claude/headless.log 2>&1
  [ "$(echo "$STATUS" | jq '.staleness.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:status refresh --judge-only" >> .claude/headless.log 2>&1
}
```

The `reconcile --judge-only` and `refresh --judge-only` calls are no-ops until
CR-007 and CR-008 land — but the cron shape can be set up now and will start
doing work as soon as those CRs ship.

## The `.claude/headless.log` convention

All headless invocations append to `.claude/headless.log`. This gives you a
single tail-able file for "what has cron been doing":

```bash
tail -f .claude/headless.log
```

The log is gitignored by convention — it is per-machine operational, not part
of the vault's content.

## Auditing what cron did

`scripts/review-log.js` records every automatable skill's success. To see what
ran since you last looked:

```bash
/second-brain:status review
```

When you have audited the changes (via the wiki itself, `git log wiki/`, or the
review output), acknowledge them:

```bash
/second-brain:status accept
```

This clears the inbox and bumps the `last_accepted_at` timestamp. The
`change_count` in the next `/second-brain:status` dashboard goes back to zero.

## Why not push notifications

Push notifications, Slack DMs, email digests — all out of scope. The user
opted for "I'll check the dashboard when I sit down to work" over
"automation paging me." `wiki/.state/since-review.yaml` is the durable inbox;
the dashboard is the morning check.
```

- [ ] **Step 3: Commit**

```bash
mkdir -p docs/install
git add docs/install/headless-driving.md
git commit -m "$(cat <<'EOF'
docs(install): add headless-driving cron guide

Walks the cron → status.js --json → jq → claude --headless pattern,
recommends cadences (hourly ingest, daily judge passes, weekly lint),
documents the .claude/headless.log convention, and explains how
/second-brain:status review + accept close the audit loop.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: Wire `/second-brain:ingest` review-log integration

**Files:**
- Modify: `skills/ingest/SKILL.md`

Spec §8: after each successful source commit, the ingest skill appends one
`kind: ingest` entry to the review log via `scripts/review-log.js append`.
Idempotent at the ingest level — `state-sources.js diff` already skips
unchanged sources, so re-runs don't produce spurious appends.

- [ ] **Step 1: Insert the new step**

Find this section in `skills/ingest/SKILL.md` (currently the end of step 8
"Commit the source", before "### 9. Report results"):

```markdown
Use `--allow-empty` for a structured re-scrape that produced only whitespace or formatting changes — the state advances without polluting the wiki.

If the tool exits with code 6 ("uncommitted non-wiki changes"), it means something outside `wiki/` is dirty (e.g., a user edit to a source file mid-run). Run `state-sources begin` again to roll that into a baseline commit, then retry.

### 9. Report results
```

Replace it with:

```markdown
Use `--allow-empty` for a structured re-scrape that produced only whitespace or formatting changes — the state advances without polluting the wiki.

If the tool exits with code 6 ("uncommitted non-wiki changes"), it means something outside `wiki/` is dirty (e.g., a user edit to a source file mid-run). Run `state-sources begin` again to roll that into a baseline commit, then retry.

### 9. Append a review-log entry

After each successfully ingested source, record the operation in the review inbox so the user can audit unsupervised work later:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" append \
  --kind=ingest \
  --data="{\"source\":\"<source-path>\",\"wrote\":[<wiki-page-paths>]}"
```

The `--data` payload's `wrote` list is the same `wiki_pages` array that `state-sources commit` recorded into `sources.yaml` — quote each path as a JSON string. The script lazy-creates `wiki/.state/since-review.yaml` on first call and uses an atomic write, so concurrent ingests are safe.

This step runs unconditionally on every successful source commit. Interactive ingest also benefits: the user may not remember tomorrow what they ingested today, and `/second-brain:status review` becomes the durable trail.

### 10. Report results
```

(Renumbers the trailing step from `### 9.` to `### 10.`. The trailing "What's Next" section is unchanged.)

- [ ] **Step 2: Verify the renumber doesn't leave a dangling reference**

```bash
grep -n "step 9\|step 8\|### [0-9]" skills/ingest/SKILL.md
```

Expected: numeric step references match the new numbering; no `step 9` references that should now be `step 10`.

If grep finds a dangling reference (the existing skill text rarely cross-references its own step numbers, but verify), patch it.

- [ ] **Step 3: Commit**

```bash
git add skills/ingest/SKILL.md
git commit -m "$(cat <<'EOF'
feat(ingest): append to review log after each source commit

Adds step 9 to /second-brain:ingest: after state-sources commit succeeds,
append a kind: ingest entry to wiki/.state/since-review.yaml via
scripts/review-log.js. Source path + wiki_pages list are the payload.
state-sources diff already skips unchanged sources, so re-runs are
idempotent. Existing step 9 (Report results) is renumbered to step 10.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 19: Manual smoke verification

**Files:**
- None modified.

Run the spec §10.3 smoke checklist end-to-end against a real vault. This is the only place automation can't verify; the tests cover the script contracts, but the skill prompt → script invocation chain needs human eyes.

- [ ] **Step 1: Set up a smoke vault**

```bash
SMOKE=$(mktemp -d)/smoke-vault
mkdir -p "$SMOKE"
cd "$SMOKE"
# Use the in-place onboarding flow per CR-006.
mkdir -p .obsidian
node "$CLAUDE_PLUGIN_ROOT/skills/onboard/scripts/onboarding.sh" "$SMOKE"  # if onboarding.sh is the entry; otherwise follow CR-006 runbook
```

(Or pick an existing dev vault — the smoke test does not depend on a pristine
filesystem.)

- [ ] **Step 2: Run the eight smoke cases from spec §10.3**

| # | Action | Expected |
|---|---|---|
| 1 | Fresh vault → `/second-brain:status` | Prints header + `Nothing pending.` |
| 2 | Drop two files into `raw/` → `/second-brain:status` | Shows `Automation could pick up: Sources 2 new in raw/, 0 changed` |
| 3 | Run `/second-brain:ingest`, then `/second-brain:status review` | Shows 2 ingest entries grouped under `kind: ingest` |
| 4 | `/second-brain:status accept` → `/second-brain:status review` | Review count clears; show prints `No review-log entries.` |
| 5 | `/second-brain:status reconcile` | Prints placeholder pointing at CR-007 |
| 6 | `/second-brain:status refresh` | Prints placeholder pointing at CR-008 |
| 7 | From a non-vault dir: `node scripts/status.js` | Exit 2 + `not in a second-brain vault` |
| 8 | `claude --headless -p "/second-brain:status"` | Returns the human dashboard captured to log |

For each case, run it and check the output matches. If any case fails, note
the case number and what diverged, then file the fix as a follow-up patch (do
not silently fix and re-commit on this branch — surface the discrepancy).

- [ ] **Step 3: Run the full test suite as a sanity check**

```bash
bash tests/test_status.sh && bash tests/test_review_log.sh
```

Expected: both exit 0.

- [ ] **Step 4: If smoke + tests both pass, this CR is done**

No commit for this task — it is verification only. The CR ships once all
preceding commits are pushed.

---

## Self-Review

Run this against the spec one more time:

**1. Spec coverage:**

| Spec section | Covered by task |
|---|---|
| §4 Architecture (six deliverables) | Tasks 1–9 (status.js), 10–14 (review-log.js), 15 (skill), 16 (JSON ref), 17 (cron doc), 18 (ingest) |
| §5 `scripts/status.js` | Tasks 1–9 |
| §5.4 Exit codes | Task 1 (outside vault), Task 9 (malformed YAML), Task 3 (state-sources fail) |
| §6 `scripts/review-log.js` | Tasks 10–14 |
| §6.3 Exit codes | Task 10 (unknown subcommand), Task 11 (malformed --data), Task 14 (schema_version) |
| §6.4 Concurrency | Task 11 test 8 (concurrent appends) |
| §7 `skills/status/SKILL.md` | Task 15 |
| §8 Ingest integration | Task 18 |
| §9.1 JSON schema reference | Task 16 |
| §9.2 Headless-driving doc | Task 17 |
| §10.1 status.sh tests (11 cases) | Cases 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 across Tasks 1–9 |
| §10.2 review-log.sh tests (9 cases) | Cases 1, 2, 3, 4, 5, 6, 7, 8, 9 across Tasks 10–14 |
| §10.3 Manual smoke | Task 19 |

All sections covered. No gaps.

**2. Placeholder scan:**

- No "TBD", "implement later", "fill in details" in step bodies — every step that changes code shows the code.
- "Filled in by Task N" appears as forward references inside placeholder script bodies, not in plan steps. Those forward references are real code (a `die()` stub) that gets replaced in the named task. Not a placeholder in the plan-failure sense.
- No "similar to Task N" — when a test or implementation pattern repeats, the code is repeated in full.

**3. Type consistency:**

- `findVaultRoot` signature: same in `status.js` and `review-log.js` (single string arg, returns string-or-null). ✓
- `readState` (review-log.js) vs `readStateYaml` (status.js): different names, different contracts. `readState` is review-log-specific (enforces `schema_version === 1`). `readStateYaml` is the generic helper in status.js. Naming distinct on purpose. ✓
- `emptyState` (review-log.js) returns `{schema_version, generated_by, last_accepted_at: null, changes: []}` — consistent across `cmdAppend`, `cmdShow`, `cmdAccept`. ✓
- JSON shape for status.js: every key in spec §5.2 appears in `buildDashboard`. ✓
- `--kind` / `--data` flag names match the spec verbatim. ✓

No issues. Plan is ready for execution.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-21-cr-009-status-dashboard.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
