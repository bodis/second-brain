# CR-008 Staleness Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the staleness-review pipeline that fills the `/second-brain:status refresh` placeholder CR-009 left behind. Deterministic candidate scan (two percentile signals, AND-composed) + LLM judge pass + interactive user-resolution loop (refresh/archive/historical/defer), persisted in `wiki/.state/staleness.yaml`. Unified `lifecycle:` frontmatter convention with a new `validate-wiki.js` rule.

**Architecture:** One new state-owning script at `scripts/staleness.js` with eight subcommands (`candidates`, `list`, `judge`, `resolve`, `apply-refresh`, `apply-archive`, `apply-historical`, `check`). Two cheap signals: `age` (mtime percentile) and `moved_past` (count of newer `sources.yaml` entries sharing an entity wikilink). Composite tier is `high` only when both signals are in the top quartile. Auto-defer rule (Δ > 0.1 on `last_reviewed_signal_score`) prevents the same page from re-surfacing across scans. Lifecycle frontmatter (`historical | superseded | archived`) shape-checked by a new `validate-wiki.js` rule.

**Tech Stack:** Node ≥18 (CommonJS, no build step), `js-yaml` 4.x with CORE_SCHEMA for YAML I/O, bash test harness matching `tests/test_contradictions.sh`.

**Reference spec:** [`docs/superpowers/specs/2026-05-25-cr-008-staleness-review-design.md`](../specs/2026-05-25-cr-008-staleness-review-design.md). CR: [`docs/cr/CR-008-staleness-review.md`](../../cr/CR-008-staleness-review.md). Conventions: [`docs/cr/conventions.md`](../../cr/conventions.md). Parent pattern: [`docs/superpowers/plans/2026-05-24-cr-007-contradiction-detection.md`](./2026-05-24-cr-007-contradiction-detection.md).

---

## File Structure

**Create:**
- `scripts/staleness.js` — state-owning script for `wiki/.state/staleness.yaml`. ~700 lines. Eight subcommands. Atomic writes (tmpfile + rename). Shells out to `git` and `scripts/validate-wiki.js`. Vault detection matches `contradictions.js` (walks up for `.git/` + `wiki/.state/sources.yaml`).
- `tests/test_staleness.sh` — integration tests, ~30 cases mirroring `tests/test_contradictions.sh` shape.
- `tests/fixtures/staleness/age-only/` — vault with one ancient page but no newer sources touching it. Composite stays `low`.
- `tests/fixtures/staleness/moved-past-only/` — vault with a recent page but many newer sources sharing its entities. Composite stays `low`.
- `tests/fixtures/staleness/both-signals-high/` — vault where one page is in the top quartile for both signals. Composite: `high`.
- `tests/fixtures/staleness/both-signals-medium/` — vault where one page is strong on one signal, present on the other. Composite: `medium`.
- `tests/fixtures/staleness/tiny-vault/` — vault with <20 candidate-eligible pages. `candidates` exits 0, writes `pages: []`, warns to stderr.
- `tests/fixtures/staleness/empty-vault/` — vault with zero candidate-eligible pages.
- `tests/fixtures/staleness/dedupe/` — vault with an existing `staleness.yaml` mixing `unjudged`/`unreviewed`/`resolved`/`deferred`/`dismissed`; re-scan must drop `unjudged`, preserve others.
- `tests/fixtures/staleness/auto-defer-no-bump/` — deferred entry, new scan score within Δ=0.1 of `last_reviewed_signal_score`. Stays deferred.
- `tests/fixtures/staleness/auto-defer-bumped/` — deferred entry, new scan score > `last_reviewed_signal_score + 0.1`. Returns to `unjudged`.
- `tests/fixtures/staleness/judge-input/` — minimal vault with one `unjudged` entry, used for judge / list-filter tests.
- `tests/fixtures/staleness/apply-refresh-input/` — vault with one `unreviewed` entry + a sibling tmpfile path the test points the rewrite at.
- `tests/fixtures/staleness/apply-archive-input/` — vault with one `unreviewed` concept page + sources, plus inbound wikilinks from another page that must continue to resolve via the stub redirect.
- `tests/fixtures/staleness/apply-historical-input/` — vault with one `unreviewed` page, used for the `apply-historical` happy path + the default-`--since` test.
- `tests/fixtures/staleness/check-input/` — vault with a mix of historical / superseded / stale-high pages, plus clean ones.
- `tests/fixtures/staleness/schema-mismatch/` — vault with `staleness.yaml` carrying `schema_version: 0`.
- `tests/fixtures/validate-wiki/lifecycle-historical-valid/` — frontmatter has `lifecycle: { state: historical, since: 2024-05 }`. Passes.
- `tests/fixtures/validate-wiki/lifecycle-superseded-valid/` — stub redirect with `lifecycle: { state: superseded, by: wiki/archive/2024/concepts/foo.md }`. Passes.
- `tests/fixtures/validate-wiki/lifecycle-archived-valid/` — archive file with `lifecycle: { state: archived, original: wiki/concepts/foo.md }`. Passes.
- `tests/fixtures/validate-wiki/lifecycle-bad-state/` — `lifecycle.state: bogus`. Exits 2.
- `tests/fixtures/validate-wiki/lifecycle-historical-missing-since/` — historical state, no `since`. Exits 2.
- `tests/fixtures/validate-wiki/lifecycle-superseded-broken-by/` — `by:` points to a non-existent file. Exits 2.
- `tests/fixtures/validate-wiki/lifecycle-stub-sources-empty-ok/` — stub redirect with empty `sources: []`. Passes (because lifecycle.state==superseded exempts it).
- `tests/fixtures/status/staleness-unjudged-counted/` — staleness.yaml with two `unjudged` entries. Asserts `unjudged_candidates: 2`.
- `tests/fixtures/status/staleness-mixed-statuses/` — staleness.yaml with one of each status. Asserts only `unreviewed` entries reach `unresolved_high/medium` counts.

**Modify:**
- `scripts/status.js` — `readStaleness()` currently hardcodes `unjudged_candidates: 0`. Replace with a real count of `status: unjudged` entries; keep the existing `unresolved_high / unresolved_medium` logic for `status: unreviewed` entries (the legacy code already used the `unreviewed` keyword, which now means "judge ran, awaiting user").
- `scripts/validate-wiki.js` — add a new rule family `lifecycle` wired into the `all` group. Shape-check the `lifecycle:` frontmatter block (three states, required sub-keys, target path resolution for `superseded.by` and `archived.original`). Exempt `lifecycle.state == superseded` pages from the `sources: may_be_empty: false` rule from `frontmatter-contract.yaml`.
- `tests/fixtures/status/staleness-populated/wiki/.state/staleness.yaml` — rewrite using the new status taxonomy (`unjudged | unreviewed | resolved | deferred | dismissed`). Drop the legacy `reviewed` value entirely.
- `tests/test_status.sh` — add cases for the two new fixtures (`staleness-unjudged-counted`, `staleness-mixed-statuses`).
- `tests/test_validate_wiki.sh` — add cases for the seven `lifecycle-*` fixtures.
- `skills/status/SKILL.md` — replace the `/status refresh is not yet available...` placeholder (line 221) with the full interactive sub-flow body and the `--judge-only` headless body. Bump `allowed-tools` to include `Write` (for rewrite tmpfiles). Mirror the `/status reconcile` sections CR-007 already shipped.
- `skills/lint/SKILL.md` — replace §3 ("Stale claims") prose with deterministic `staleness.js candidates` + `list` script calls. Mirror CR-007's §2 rewrite pattern.
- `skills/query/SKILL.md` — insert a new step 3a ("Check lifecycle and staleness") between current steps 3 and 4. Calls `staleness.js check --pages <list> --json`, prepends a one-line warning when `warnings[]` is non-empty.
- `skills/status/references/status-json-schema.md` — `staleness` section currently says "owned by CR-008" and "always 0 in CR-009". Drop the caveats; document the lifecycle predicates (`unjudged_candidates` = `status: unjudged`; `unresolved_high/medium` = `status: unreviewed AND signal: high|medium`).
- `docs/install/headless-driving.md` — the cron example already includes `/second-brain:status refresh --judge-only` but explanatory prose says "still a no-op". Flip to "live".
- `docs/cr/CR-008-staleness-review.md` — append a status line under the header noting CR-008 is implemented as of this plan landing.

**Decisions locked in:**

- **Score formula is multiplicative.** `score = age_percentile × moved_past_percentile`. Spec §5 stated this; locked here. Both factors in [0,1], product in [0,1]. Auto-defer threshold (Δ > 0.1) compares the new product to `last_reviewed_signal_score` stored at last touch.
- **Per-signal cutoffs are p75 (strong) and p50 (present).** Hard-coded constants in the script. Not configurable; CR-008 spec §17 punts vault-level overrides to a follow-up.
- **Tiny-vault threshold is 20 candidate-eligible pages.** Below that, `candidates` writes `pages: []`, exits 0, prints one-line stderr warning. Hard-coded.
- **`wiki/archive/**` is hard-excluded from the candidate scope.** Spec §7 / §17. The script never scores archived files.
- **Candidate scope is `wiki/{entities,concepts,synthesis,sources}/**/*.md`.** `wiki/index.md` and `wiki/log.md` are excluded (they mirror the `frontmatter-contract.yaml` exempt list).
- **`id` format is `YYYY-MM-DD-NNN`.** Same as `contradictions.js`. Scan existing entries, find max NNN for today's date string, allocate `max+1` zero-padded to 3 digits.
- **Atomic YAML write only — no lock file.** Same as `contradictions.js` / `review-log.js`.
- **CORE_SCHEMA for YAML I/O.** `yaml.load(text, {schema: yaml.CORE_SCHEMA})` and `yaml.dump(doc, {indent: 2, sortKeys: false, lineWidth: -1})`. Matches project convention.
- **`apply-*` subcommands own the full transaction.** Edit → `validate-wiki.js all` → on success, atomic yaml update. On post-check exit 2: auto-revert the file edit, leave the yaml entry unchanged (entry stays `unreviewed`), exit 2. On precondition failure: exit 3 with no mutation.
- **`apply-archive` marks both files.** Moved file: `lifecycle: { state: archived, original: <orig-path> }`. Stub at original path: `lifecycle: { state: superseded, by: <archive-path> }` + empty `sources: []` (allowed by the new validator exemption). Stub body is a single line: `See [[wiki/archive/<year>/<X>/<Y>]] for the original content.`
- **`apply-historical` defaults `--since` to current year-month.** Format `YYYY-MM`. Validator's lifecycle rule enforces shape.
- **Wiki commits are made by the SKILL, not the script.** `apply-*` subcommands write files atomically but DO NOT `git add`/`git commit`. The interactive SKILL (or the `--judge-only` headless run) groups multiple actions into one commit at the end. Matches `contradictions.js apply-pick` behaviour (which CR-007 plan §10 also leaves to the SKILL).
- **Sample neighbours for the judge stage: K=5, one hop, mtime > flagged page AND ≥1 shared entity wikilink.** The skill computes the sample (not the script); the script stores `neighbors_examined` for audit.
- **The `--judge-only` headless invocation lives entirely inside `skills/status/SKILL.md`** as a sub-flow alongside the interactive `refresh`. Mirrors how CR-007 shipped `reconcile --judge-only` in the same file.

---

## Task 1: `scripts/staleness.js` skeleton + test harness + outside-vault test

**Files:**
- Create: `scripts/staleness.js`
- Create: `tests/test_staleness.sh`

Get the script callable, the test harness running, and outside-vault + unknown-subcommand tests green. No subcommand logic yet — `main()` dispatches but every subcommand throws.

- [ ] **Step 1: Create `tests/test_staleness.sh` with the harness + first two cases**

```bash
#!/bin/bash
set -e

# Test: scripts/staleness.js — staleness state-owner.
# Usage: bash tests/test_staleness.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/staleness.js"
VALIDATE="$REPO_ROOT/scripts/validate-wiki.js"
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

# Make a minimal vault: git-init, sources.yaml, frontmatter-contract.yaml,
# index.md, log.md. Args: $1 = name. Echoes the absolute path.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state" "$v/wiki/entities" "$v/wiki/concepts" "$v/wiki/synthesis" "$v/wiki/sources"
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
YAML
  cat > "$v/wiki/index.md" <<'MD'
# Index
MD
  cat > "$v/wiki/log.md" <<'MD'
# Log
MD
  ( cd "$v" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
  echo "$v"
}

echo "==> Outside-vault: bare cwd → exit 2"
(
  cd "$TEST_DIR"
  set +e
  output=$(node "$SCRIPT" list 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "2" "$rc"
  case "$output" in
    *"not in a second-brain vault"*) assert_eq "error message" "ok" "ok" ;;
    *) assert_eq "error message" "contains 'not in a second-brain vault'" "$output" ;;
  esac
)

echo "==> Unknown subcommand → exit 2"
(
  V=$(make_vault unknown-sub)
  cd "$V"
  set +e
  output=$(node "$SCRIPT" totally-fake 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "2" "$rc"
  case "$output" in
    *"unknown subcommand"*) assert_eq "error message" "ok" "ok" ;;
    *) assert_eq "error message" "contains 'unknown subcommand'" "$output" ;;
  esac
)

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the harness — should fail because the script does not exist**

Run: `bash tests/test_staleness.sh`
Expected: both cases FAIL with `node: command failed` / `Cannot find module`. Script bails on `[ "$FAIL" -eq 0 ]`.

- [ ] **Step 3: Create `scripts/staleness.js` skeleton**

```js
#!/usr/bin/env node
'use strict';

/**
 * scripts/staleness.js — owner of wiki/.state/staleness.yaml.
 *
 * Subcommands:
 *   candidates [--scope <dir|page-list>] [--json]
 *   list [--status <comma-list>] [--signal <comma-list>] [--json]
 *   judge --id <id> --verdict <stale|drifting|fresh-but-isolated|false-positive> --data <json>
 *   resolve --id <id> --kind defer
 *   apply-refresh --id <id> --rewrite <tmpfile>
 *   apply-archive --id <id>
 *   apply-historical --id <id> [--since <YYYY-MM>]
 *   check --pages <comma-list> [--json]
 *
 * Exit codes:
 *   0 = clean
 *   2 = vault not found / malformed yaml / missing required arg / malformed --data /
 *       validate-wiki post-check failure after auto-revert / unsupported subcommand or kind
 *   3 = invariant refusal (invalid lifecycle transition, id not found, etc.) —
 *       no mutation occurred
 *
 * Vault detection: walks up for both .git/ and wiki/.state/sources.yaml,
 * matching contradictions.js / status.js / validate-wiki.js / review-log.js.
 */

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/staleness.js';
const STATE_FILE = 'wiki/.state/staleness.yaml';

function die(msg, code = 2) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(code);
}

function findVaultRoot(start) {
  let dir = path.resolve(start);
  while (true) {
    if (
      fs.existsSync(path.join(dir, '.git')) &&
      fs.existsSync(path.join(dir, 'wiki/.state/sources.yaml'))
    ) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// Lightweight CLI parser: --key value, --key=value, or boolean --flag.
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    if (a.includes('=')) {
      const [k, v] = a.slice(2).split('=');
      out[k] = v;
    } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      out[a.slice(2)] = argv[++i];
    } else {
      out[a.slice(2)] = true;
    }
  }
  return out;
}

function cmdCandidates() { die('candidates: not implemented yet', 2); }
function cmdList()       { die('list: not implemented yet', 2); }
function cmdJudge()      { die('judge: not implemented yet', 2); }
function cmdResolve()    { die('resolve: not implemented yet', 2); }
function cmdApplyRefresh(){die('apply-refresh: not implemented yet', 2); }
function cmdApplyArchive(){die('apply-archive: not implemented yet', 2); }
function cmdApplyHistorical(){die('apply-historical: not implemented yet', 2); }
function cmdCheck()      { die('check: not implemented yet', 2); }

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) die('usage: staleness.js <subcommand> [args]', 2);
  const cmd = argv[0];
  const args = parseArgs(argv.slice(1));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  switch (cmd) {
    case 'candidates':       return cmdCandidates(vault, args);
    case 'list':             return cmdList(vault, args);
    case 'judge':            return cmdJudge(vault, args);
    case 'resolve':          return cmdResolve(vault, args);
    case 'apply-refresh':    return cmdApplyRefresh(vault, args);
    case 'apply-archive':    return cmdApplyArchive(vault, args);
    case 'apply-historical': return cmdApplyHistorical(vault, args);
    case 'check':            return cmdCheck(vault, args);
    default:                 die(`unknown subcommand: ${cmd}`, 2);
  }
}

main();
```

- [ ] **Step 4: Run the harness — both cases should pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 2 passed, 0 failed`. Exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_staleness.sh
git add scripts/staleness.js tests/test_staleness.sh
git commit -m "feat(staleness): scaffold staleness.js with vault detection"
```

---

## Task 2: Shared helpers — state I/O, id allocation, schema check

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/schema-mismatch/wiki/.state/sources.yaml`
- Create: `tests/fixtures/staleness/schema-mismatch/wiki/.state/staleness.yaml`

Add the helpers every subcommand needs: `readState`/`writeState` (atomic), `nowIso`, `allocateId`. Also wire schema-version checking — wrong `schema_version` exits 2 on any read.

- [ ] **Step 1: Add the schema-mismatch fixture**

```bash
mkdir -p tests/fixtures/staleness/schema-mismatch/wiki/.state
cat > tests/fixtures/staleness/schema-mismatch/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
cat > tests/fixtures/staleness/schema-mismatch/wiki/.state/staleness.yaml <<'YAML'
schema_version: 0
generated_by: scripts/staleness.js
pages: []
YAML
```

- [ ] **Step 2: Add the schema-mismatch test case to `tests/test_staleness.sh` (append before `Results:`)**

```bash
echo "==> Schema mismatch on read → exit 2"
(
  V=$(make_vault schema-mismatch-vault)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/schema-mismatch/wiki/.state/staleness.yaml" "$V/wiki/.state/"
  cd "$V"
  set +e
  output=$(node "$SCRIPT" list 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "2" "$rc"
  case "$output" in
    *"schema_version"*) assert_eq "error mentions schema_version" "ok" "ok" ;;
    *) assert_eq "error mentions schema_version" "yes" "$output" ;;
  esac
)
```

- [ ] **Step 3: Run the harness — schema-mismatch fails (no list impl, no read helper)**

Run: `bash tests/test_staleness.sh`
Expected: existing 2 PASS; `Schema mismatch` FAILs because `list` still throws `not implemented`.

- [ ] **Step 4: Add helpers to `scripts/staleness.js` (after `parseArgs`)**

```js
function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function readState(vault) {
  const abs = path.join(vault, STATE_FILE);
  if (!fs.existsSync(abs)) return null;
  let doc;
  try {
    doc = yaml.load(fs.readFileSync(abs, 'utf8'), { schema: yaml.CORE_SCHEMA });
  } catch (e) {
    die(`failed to parse ${STATE_FILE}: ${e.message}`, 2);
  }
  if (!doc || typeof doc !== 'object') die(`${STATE_FILE} is not a YAML mapping`, 2);
  if (doc.schema_version !== SCHEMA_VERSION) {
    die(`${STATE_FILE} schema_version is ${doc.schema_version}, expected ${SCHEMA_VERSION}`, 2);
  }
  if (!Array.isArray(doc.pages)) doc.pages = [];
  return doc;
}

// Atomic write: tmpfile + rename.
function writeState(vault, doc) {
  doc.schema_version = SCHEMA_VERSION;
  doc.generated_by = GENERATED_BY;
  const abs = path.join(vault, STATE_FILE);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  const tmp = `${abs}.tmp.${process.pid}.${Date.now()}`;
  const out = yaml.dump(doc, { indent: 2, sortKeys: false, lineWidth: -1 });
  fs.writeFileSync(tmp, out);
  fs.renameSync(tmp, abs);
}

function todayDateStr() {
  return new Date().toISOString().slice(0, 10);
}

// Allocate the next id for today, given the existing entries (any date).
// Format: YYYY-MM-DD-NNN. NNN zero-padded to 3 digits.
function allocateId(existingEntries) {
  const today = todayDateStr();
  let maxN = 0;
  for (const e of existingEntries) {
    if (!e || !e.id) continue;
    const m = /^(\d{4}-\d{2}-\d{2})-(\d{3})$/.exec(e.id);
    if (!m) continue;
    if (m[1] !== today) continue;
    const n = parseInt(m[2], 10);
    if (n > maxN) maxN = n;
  }
  return `${today}-${String(maxN + 1).padStart(3, '0')}`;
}

function findEntry(doc, id) {
  return (doc.pages || []).find((e) => e && e.id === id) || null;
}
```

- [ ] **Step 5: Replace `cmdList` body so it exercises `readState` (still mostly a stub but enough for the schema test)**

```js
function cmdList(vault, _args) {
  const doc = readState(vault);
  if (!doc) {
    process.stdout.write(JSON.stringify({ pages: [] }, null, 2) + '\n');
    return;
  }
  process.stdout.write(JSON.stringify({ pages: doc.pages }, null, 2) + '\n');
}
```

- [ ] **Step 6: Run the harness — all 3 cases pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 3 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh tests/fixtures/staleness/schema-mismatch
git commit -m "feat(staleness): add state I/O helpers + schema-mismatch test"
```

---

## Task 3: `list` subcommand — filters + JSON / human output

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`

Flesh out `list` with `--status` (comma-list) and `--signal` (comma-list) filters, plus `--json` toggle. Default output is one human-readable line per entry.

- [ ] **Step 1: Add the `list filter-by-status` test case**

```bash
echo "==> list --status=unjudged returns only unjudged entries"
(
  V=$(make_vault list-status)
  cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    status: unjudged
  - id: 2026-05-25-002
    path: wiki/concepts/b.md
    signal: high
    status: unreviewed
  - id: 2026-05-25-003
    path: wiki/concepts/c.md
    signal: medium
    status: resolved
    resolution: refreshed
YAML
  cd "$V"
  output=$(node "$SCRIPT" list --status=unjudged --json)
  count=$(echo "$output" | grep -c '"id":')
  assert_eq "unjudged count" "1" "$count"
  case "$output" in
    *2026-05-25-001*) assert_eq "id 001 present" "ok" "ok" ;;
    *) assert_eq "id 001 present" "yes" "$output" ;;
  esac
)
```

- [ ] **Step 2: Add the `list filter-by-signal` test case**

```bash
echo "==> list --signal=high returns only high-tier entries"
(
  V=$(make_vault list-signal)
  cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    status: unreviewed
  - id: 2026-05-25-002
    path: wiki/concepts/b.md
    signal: medium
    status: unreviewed
  - id: 2026-05-25-003
    path: wiki/concepts/c.md
    signal: low
    status: unjudged
YAML
  cd "$V"
  output=$(node "$SCRIPT" list --signal=high --json)
  count=$(echo "$output" | grep -c '"id":')
  assert_eq "high count" "1" "$count"
)
```

- [ ] **Step 3: Add the `list human output` test case (default no `--json`)**

```bash
echo "==> list default human output"
(
  V=$(make_vault list-human)
  cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    status: unreviewed
YAML
  cd "$V"
  output=$(node "$SCRIPT" list)
  case "$output" in
    *"2026-05-25-001"*"wiki/concepts/a.md"*"unreviewed"*"high"*) assert_eq "format" "ok" "ok" ;;
    *) assert_eq "human format" "id path status signal on one line" "$output" ;;
  esac
)
```

- [ ] **Step 4: Run the harness — three new cases should FAIL (list returns everything, no filter)**

Run: `bash tests/test_staleness.sh`
Expected: previous 3 PASS; 3 new cases FAIL.

- [ ] **Step 5: Replace `cmdList` with the filter implementation**

```js
function parseCommaList(v) {
  if (!v || v === true) return null;
  return String(v).split(',').map((s) => s.trim()).filter(Boolean);
}

function cmdList(vault, args) {
  const doc = readState(vault);
  const all = doc ? (doc.pages || []) : [];
  const statusFilter = parseCommaList(args.status);
  const signalFilter = parseCommaList(args.signal);
  const filtered = all.filter((e) => {
    if (!e) return false;
    if (statusFilter && !statusFilter.includes(e.status)) return false;
    if (signalFilter && !signalFilter.includes(e.signal)) return false;
    return true;
  });
  if (args.json) {
    process.stdout.write(JSON.stringify({ pages: filtered }, null, 2) + '\n');
    return;
  }
  if (filtered.length === 0) {
    process.stdout.write('(no entries)\n');
    return;
  }
  for (const e of filtered) {
    process.stdout.write(`${e.id}\t${e.path}\t${e.status}\t${e.signal}\n`);
  }
}
```

- [ ] **Step 6: Run the harness — all 6 cases pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 6 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh
git commit -m "feat(staleness): list subcommand with status/signal filters"
```

---

## Task 4: `candidates` — page enumeration + age signal (percentile)

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/age-only/` (vault tree)

Wire the candidate scan's foundation: enumerate eligible pages under `wiki/{entities,concepts,synthesis,sources}/`, exclude `wiki/archive/**`, compute `age` percentile from mtimes. `moved_past` is hard-coded to 0 for this task (signal 2 lands in Task 5). Composite tier always `low` here — the AND-rule needs both signals.

- [ ] **Step 1: Create the `age-only` fixture (5 pages with controlled mtimes)**

```bash
mkdir -p tests/fixtures/staleness/age-only/wiki/.state
mkdir -p tests/fixtures/staleness/age-only/wiki/{entities,concepts,synthesis,sources}
cat > tests/fixtures/staleness/age-only/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
cat > tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml <<'YAML'
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
YAML
cat > tests/fixtures/staleness/age-only/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/age-only/wiki/log.md <<'MD'
# Log
MD
```

Test harness will copy this tree into a fresh vault per case, then `touch -t` mtimes deterministically before running.

- [ ] **Step 2: Add the `candidates age-only` test case**

```bash
echo "==> candidates: age signal scores oldest page in top quartile"
(
  V=$(make_vault age-only-vault)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml" "$V/wiki/.state/"
  # Create 20+ pages with staggered mtimes so percentiles are meaningful.
  for i in $(seq 1 25); do
    f="$V/wiki/concepts/p$i.md"
    cat > "$f" <<EOF
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# P$i
EOF
  done
  # Make p1 the oldest (touch back to 2022); leave others recent.
  touch -t 202201010000 "$V/wiki/concepts/p1.md"
  for i in $(seq 2 25); do touch -t 202605010000 "$V/wiki/concepts/p$i.md"; done
  cd "$V"
  node "$SCRIPT" candidates >/dev/null
  output=$(cat wiki/.state/staleness.yaml)
  case "$output" in
    *"path: wiki/concepts/p1.md"*) assert_eq "p1 present" "ok" "ok" ;;
    *) assert_eq "p1 present" "yes" "$output" ;;
  esac
  # p1's age_percentile should be ~1.0 (oldest) — but composite is low because moved_past is 0.
  node "$SCRIPT" list --json > /tmp/staleness-list.json
  p1_signal=$(node -e "const d=JSON.parse(require('fs').readFileSync('/tmp/staleness-list.json'));const e=d.pages.find(x=>x.path==='wiki/concepts/p1.md');process.stdout.write(e?e.signal:'(missing)')")
  assert_eq "p1 composite signal" "low" "$p1_signal"
)
```

- [ ] **Step 3: Run the harness — fails (candidates is not implemented)**

Run: `bash tests/test_staleness.sh`
Expected: existing 6 PASS; new case errors with `candidates: not implemented yet`.

- [ ] **Step 4: Add the page-enumeration + age-percentile helpers (before `cmdCandidates`)**

```js
const CANDIDATE_DIRS = ['wiki/entities', 'wiki/concepts', 'wiki/synthesis', 'wiki/sources'];
const ARCHIVE_PREFIX = 'wiki/archive/';
const TINY_VAULT_THRESHOLD = 20;
const STRONG_CUTOFF = 0.75;   // p75
const PRESENT_CUTOFF = 0.50;  // p50
const AUTODEFER_DELTA = 0.10;

// Recursively list .md files under the candidate dirs, vault-relative.
function listCandidatePages(vault) {
  const out = [];
  for (const sub of CANDIDATE_DIRS) {
    const abs = path.join(vault, sub);
    if (!fs.existsSync(abs)) continue;
    walk(abs, vault, out);
  }
  return out;
}
function walk(dir, vault, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    const rel = path.relative(vault, full).split(path.sep).join('/');
    if (rel.startsWith(ARCHIVE_PREFIX)) continue;
    if (entry.isDirectory()) walk(full, vault, out);
    else if (entry.isFile() && entry.name.endsWith('.md')) out.push(rel);
  }
}

// Returns the fractional rank of x in the sorted-ascending array `sorted`
// (number of values ≤ x divided by length). Returns 0 when sorted is empty.
function fractionalRank(sorted, x) {
  if (sorted.length === 0) return 0;
  let lo = 0, hi = sorted.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (sorted[mid] <= x) lo = mid + 1;
    else hi = mid;
  }
  return lo / sorted.length;
}

function ageMonths(mtimeMs) {
  const ms = Date.now() - mtimeMs;
  return ms / (1000 * 60 * 60 * 24 * 30.4375);
}

function tierFromCutoffs(percentile) {
  if (percentile >= STRONG_CUTOFF) return 'strong';
  if (percentile >= PRESENT_CUTOFF) return 'present';
  return 'weak';
}
function compositeFromTiers(t1, t2) {
  const strongCount = (t1 === 'strong' ? 1 : 0) + (t2 === 'strong' ? 1 : 0);
  const presentCount = (t1 !== 'weak' ? 1 : 0) + (t2 !== 'weak' ? 1 : 0);
  if (strongCount === 2) return 'high';
  if (strongCount === 1 && presentCount === 2) return 'medium';
  return 'low';
}
```

- [ ] **Step 5: Replace `cmdCandidates` with the age-only implementation**

```js
function cmdCandidates(vault, args) {
  const pages = listCandidatePages(vault);
  const existing = readState(vault) || { pages: [] };

  if (pages.length < TINY_VAULT_THRESHOLD) {
    process.stderr.write(`warning: vault has ${pages.length} candidate-eligible pages (<${TINY_VAULT_THRESHOLD}); skipping scan\n`);
    writeState(vault, {
      scanned_at: nowIso(),
      vault_page_count: pages.length,
      pages: existing.pages.filter((e) => e.status !== 'unjudged'),
    });
    return;
  }

  // 1. Stat every page; collect mtimes for percentile computation.
  const mtimes = [];
  const stats = new Map();
  for (const p of pages) {
    const s = fs.statSync(path.join(vault, p));
    stats.set(p, s);
    mtimes.push(s.mtimeMs);
  }
  const sortedMtimes = [...mtimes].sort((a, b) => a - b);

  // 2. Per-page scoring. Older mtime = higher age_percentile.
  // age_percentile = 1 - fractionalRank(sortedMtimes, this mtime).
  const scored = [];
  for (const p of pages) {
    const s = stats.get(p);
    const rank = fractionalRank(sortedMtimes, s.mtimeMs);
    const agePercentile = 1 - rank;
    const movedPastPercentile = 0;   // implemented in Task 5
    const newerOverlappingSources = 0;
    const score = agePercentile * movedPastPercentile;
    const ageTier = tierFromCutoffs(agePercentile);
    const movedTier = tierFromCutoffs(movedPastPercentile);
    const signal = compositeFromTiers(ageTier, movedTier);
    scored.push({
      path: p,
      signal,
      factors: {
        age_months: Number(ageMonths(s.mtimeMs).toFixed(1)),
        age_percentile: Number(agePercentile.toFixed(3)),
        newer_overlapping_sources: newerOverlappingSources,
        moved_past_percentile: Number(movedPastPercentile.toFixed(3)),
      },
      score,
    });
  }

  // 3. Merge with existing entries. Drop existing `unjudged`; preserve others.
  const preserved = existing.pages.filter((e) => e.status !== 'unjudged');
  const preservedPaths = new Set(preserved.map((e) => e.path));
  const newEntries = [];
  for (const s of scored) {
    if (preservedPaths.has(s.path)) continue;
    // Only enqueue medium-or-high tier as a new candidate. low tier is noise.
    if (s.signal === 'low') continue;
    newEntries.push({
      id: allocateId([...preserved, ...newEntries]),
      path: s.path,
      signal: s.signal,
      factors: s.factors,
      last_reviewed_signal_score: null,
      status: 'unjudged',
      judgment: null,
      resolution: null,
      resolved_at: null,
      deferred_at: null,
    });
  }

  writeState(vault, {
    scanned_at: nowIso(),
    vault_page_count: pages.length,
    pages: [...preserved, ...newEntries],
  });

  if (args.json) {
    process.stdout.write(JSON.stringify({ pages: [...preserved, ...newEntries] }, null, 2) + '\n');
  }
}
```

- [ ] **Step 6: Run the harness — should pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 7 passed, 0 failed`. p1's composite stays `low` because moved_past is hard-coded to 0; signal scores are stored regardless.

- [ ] **Step 7: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh tests/fixtures/staleness/age-only
git commit -m "feat(staleness): candidates age signal + page enumeration"
```

---

## Task 5: `candidates` — `moved_past` signal (sources.yaml cross-reference)

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/both-signals-high/` (vault tree)
- Create: `tests/fixtures/staleness/moved-past-only/` (vault tree)

Compute `moved_past`: for each page, count entries in `sources.yaml` whose `ingested_at` is newer than this page's mtime AND whose `wiki_pages` collectively share at least one entity wikilink with the page. Percentile-rank within the vault.

- [ ] **Step 1: Add the `both-signals-high` fixture (one page is old AND many newer sources touch it)**

```bash
mkdir -p tests/fixtures/staleness/both-signals-high/wiki/{.state,entities,concepts,synthesis,sources}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/both-signals-high/wiki/.state/
cat > tests/fixtures/staleness/both-signals-high/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/both-signals-high/wiki/log.md <<'MD'
# Log
MD
# Entity wikilink target referenced from the stale page.
cat > tests/fixtures/staleness/both-signals-high/wiki/entities/gpt4.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# GPT-4
MD
# The stale page — references [[gpt4]] in its body.
cat > tests/fixtures/staleness/both-signals-high/wiki/concepts/stale-page.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Stale Page
Touches [[gpt4]] a lot.
MD
# Sources.yaml: 8 newer source ingests, all touching [[gpt4]].
cat > tests/fixtures/staleness/both-signals-high/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources:
YAML
for i in $(seq 1 8); do
  cat >> tests/fixtures/staleness/both-signals-high/wiki/.state/sources.yaml <<YAML
  - path: raw/newer-$i.md
    kind: generic
    sha256: aaaa$i
    bytes: 100
    mtime: 2026-04-0${i}T00:00:00Z
    ingested_at: 2026-04-0${i}T01:00:00Z
    wiki_pages:
      - wiki/sources/newer-$i.md
YAML
  # Create the source wiki page that mentions [[gpt4]].
  mkdir -p tests/fixtures/staleness/both-signals-high/wiki/sources
  cat > tests/fixtures/staleness/both-signals-high/wiki/sources/newer-$i.md <<MD
---
tags: []
sources: [raw/newer-$i.md]
created: 2026-04-0$i
updated: 2026-04-0$i
---
# Newer $i
About [[gpt4]].
MD
done
# Padding pages so the vault is over the tiny-vault threshold.
for i in $(seq 1 22); do
  cat > tests/fixtures/staleness/both-signals-high/wiki/concepts/padding-$i.md <<MD
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-01
updated: 2026-05-01
---
# Padding $i
MD
done
```

- [ ] **Step 2: Add the `moved-past-only` fixture (recent page, many newer sources sharing entity → moved_past high but age low)**

```bash
mkdir -p tests/fixtures/staleness/moved-past-only/wiki/{.state,entities,concepts,sources}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/moved-past-only/wiki/.state/
cat > tests/fixtures/staleness/moved-past-only/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/moved-past-only/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/moved-past-only/wiki/entities/topic.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-20
updated: 2026-05-20
---
# Topic
MD
cat > tests/fixtures/staleness/moved-past-only/wiki/concepts/recent-page.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-20
updated: 2026-05-20
---
# Recent Page
References [[topic]].
MD
cat > tests/fixtures/staleness/moved-past-only/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources:
YAML
for i in $(seq 1 8); do
  cat >> tests/fixtures/staleness/moved-past-only/wiki/.state/sources.yaml <<YAML
  - path: raw/x-$i.md
    kind: generic
    sha256: bbbb$i
    bytes: 100
    mtime: 2026-05-21T00:00:00Z
    ingested_at: 2026-05-21T01:00:00Z
    wiki_pages:
      - wiki/sources/x-$i.md
YAML
  cat > tests/fixtures/staleness/moved-past-only/wiki/sources/x-$i.md <<MD
---
tags: []
sources: [raw/x-$i.md]
created: 2026-05-21
updated: 2026-05-21
---
# X $i
About [[topic]].
MD
done
for i in $(seq 1 22); do
  cat > tests/fixtures/staleness/moved-past-only/wiki/concepts/padding-$i.md <<MD
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-01
updated: 2026-05-01
---
# Padding $i
MD
done
```

- [ ] **Step 3: Add the `both-signals-high` test case to `tests/test_staleness.sh`**

```bash
echo "==> candidates: both signals strong → composite high"
(
  V=$(make_vault both-high)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/both-signals-high/wiki/." "$V/wiki/"
  # Make stale-page.md actually old.
  touch -t 202401010000 "$V/wiki/concepts/stale-page.md"
  cd "$V"
  node "$SCRIPT" candidates >/dev/null
  signal=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/stale-page.md');process.stdout.write(e?e.signal:'(missing)')")
  assert_eq "stale-page composite" "high" "$signal"
)
```

- [ ] **Step 4: Add the `moved-past-only` test case**

```bash
echo "==> candidates: only moved_past strong → composite low"
(
  V=$(make_vault moved-only)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/moved-past-only/wiki/." "$V/wiki/"
  touch -t 202605200000 "$V/wiki/concepts/recent-page.md"
  cd "$V"
  node "$SCRIPT" candidates >/dev/null
  signal=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/recent-page.md');process.stdout.write(e?e.signal:'(missing)')")
  # Because score=age*moved=low*high=low product, AND-rule should not fire high.
  # Could be low (not enqueued) or absent. Either way: NOT 'high' or 'medium'.
  case "$signal" in
    high|medium) assert_eq "recent-page must not be high/medium" "low or absent" "$signal" ;;
    *) assert_eq "recent-page composite OK" "ok" "ok" ;;
  esac
)
```

- [ ] **Step 5: Run the harness — both new cases fail (moved_past stuck at 0)**

Run: `bash tests/test_staleness.sh`
Expected: previous 7 PASS; `both-high` FAILs because stale-page comes back `low`.

- [ ] **Step 6: Add the entity-wikilink extractor + sources.yaml reader (after `walk`)**

```js
function readSourcesYaml(vault) {
  const abs = path.join(vault, 'wiki/.state/sources.yaml');
  if (!fs.existsSync(abs)) return [];
  const doc = yaml.load(fs.readFileSync(abs, 'utf8'), { schema: yaml.CORE_SCHEMA });
  return Array.isArray(doc && doc.sources) ? doc.sources : [];
}

// Extract [[wikilink]] tokens from body prose, return resolved entity targets.
// Only links resolving under wiki/entities/ count (the spec's "entity wikilink"
// definition). Returns a Set of vault-relative .md paths.
function extractEntityWikilinks(vault, page) {
  const abs = path.join(vault, page);
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); } catch { return new Set(); }
  const body = text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '');
  const out = new Set();
  const re = /\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]/g;
  let m;
  while ((m = re.exec(body))) {
    const raw = m[1].trim();
    const resolved = resolveEntityTarget(vault, raw);
    if (resolved) out.add(resolved);
  }
  return out;
}

// Resolve [[bare-name]] or [[wiki/entities/bare-name]] to a vault-relative
// path under wiki/entities/. Returns null if it does not resolve to an
// entity page.
function resolveEntityTarget(vault, raw) {
  const stripped = raw.replace(/\.md$/, '');
  // wiki/entities/<name> form
  if (stripped.startsWith('wiki/entities/')) {
    const cand = `${stripped}.md`;
    if (fs.existsSync(path.join(vault, cand))) return cand;
    return null;
  }
  // Bare name → check wiki/entities/<name>.md
  const cand = `wiki/entities/${stripped}.md`;
  if (fs.existsSync(path.join(vault, cand))) return cand;
  return null;
}

// For each source entry in sources.yaml, union the entity wikilinks across
// its wiki_pages. Returns a Map<sourcePath, Set<entityPath>>.
function buildSourceEntityIndex(vault, sources) {
  const out = new Map();
  for (const s of sources) {
    if (!s || !Array.isArray(s.wiki_pages)) { out.set(s ? s.path : null, new Set()); continue; }
    const ents = new Set();
    for (const wp of s.wiki_pages) {
      for (const e of extractEntityWikilinks(vault, wp)) ents.add(e);
    }
    out.set(s.path, ents);
  }
  return out;
}

// Parse ISO-ish timestamp from sources.yaml (may be a JS Date object under
// CORE_SCHEMA, or a string). Returns ms or NaN.
function tsMs(v) {
  if (!v) return NaN;
  if (v instanceof Date) return v.getTime();
  const t = Date.parse(String(v));
  return Number.isFinite(t) ? t : NaN;
}
```

- [ ] **Step 7: Update `cmdCandidates` to compute `moved_past` (replace the moved-past block)**

Replace the `movedPastPercentile = 0` line and surrounding setup with this block that computes moved_past per page. Replace from the comment `// 2. Per-page scoring.` down to (but not including) `// 3. Merge with existing entries.`:

```js
  // 2a. Build source-entity index once.
  const sources = readSourcesYaml(vault);
  const sourceEnts = buildSourceEntityIndex(vault, sources);

  // 2b. Cache each candidate page's entity wikilinks.
  const pageEnts = new Map();
  for (const p of pages) pageEnts.set(p, extractEntityWikilinks(vault, p));

  // 2c. For each page, count sources ingested after the page's mtime
  // whose entity-link set overlaps.
  const rawMovedPast = new Map();
  for (const p of pages) {
    const pageMtime = stats.get(p).mtimeMs;
    const myEnts = pageEnts.get(p);
    let count = 0;
    if (myEnts.size > 0) {
      for (const s of sources) {
        const ts = tsMs(s.ingested_at);
        if (!Number.isFinite(ts) || ts <= pageMtime) continue;
        const ents = sourceEnts.get(s.path) || new Set();
        let overlap = false;
        for (const e of ents) { if (myEnts.has(e)) { overlap = true; break; } }
        if (overlap) count += 1;
      }
    }
    rawMovedPast.set(p, count);
  }
  const sortedMoved = [...rawMovedPast.values()].sort((a, b) => a - b);

  // 2d. Score every page.
  const scored = [];
  for (const p of pages) {
    const s = stats.get(p);
    const ageRank = fractionalRank(sortedMtimes, s.mtimeMs);
    const agePercentile = 1 - ageRank;
    const mpRaw = rawMovedPast.get(p);
    const movedPastPercentile = fractionalRank(sortedMoved, mpRaw);
    const score = agePercentile * movedPastPercentile;
    const ageTier = tierFromCutoffs(agePercentile);
    const movedTier = tierFromCutoffs(movedPastPercentile);
    const signal = compositeFromTiers(ageTier, movedTier);
    scored.push({
      path: p,
      signal,
      factors: {
        age_months: Number(ageMonths(s.mtimeMs).toFixed(1)),
        age_percentile: Number(agePercentile.toFixed(3)),
        newer_overlapping_sources: mpRaw,
        moved_past_percentile: Number(movedPastPercentile.toFixed(3)),
      },
      score,
    });
  }
```

- [ ] **Step 8: Run the harness — all 9 cases pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 9 passed, 0 failed`. `both-signals-high` should now classify `stale-page.md` as `high`; `moved-past-only` should classify `recent-page.md` as low or absent.

- [ ] **Step 9: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh tests/fixtures/staleness/both-signals-high tests/fixtures/staleness/moved-past-only
git commit -m "feat(staleness): moved_past signal via sources.yaml cross-ref"
```

---

## Task 6: `candidates` — composite-tier `medium`, tiny-vault guard, both-low fallthrough

**Files:**
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/both-signals-medium/`
- Create: `tests/fixtures/staleness/tiny-vault/`
- Create: `tests/fixtures/staleness/empty-vault/`

Three remaining edge cases for `candidates`: composite `medium` (one strong + one present), tiny-vault guard (<20 pages → empty + warning), and empty-vault (zero pages → empty + warning).

- [ ] **Step 1: Create `both-signals-medium` fixture (page in top quartile for age, only upper-half for moved_past)**

```bash
mkdir -p tests/fixtures/staleness/both-signals-medium/wiki/{.state,entities,concepts,sources}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/both-signals-medium/wiki/.state/
cat > tests/fixtures/staleness/both-signals-medium/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/both-signals-medium/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/both-signals-medium/wiki/entities/topic.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Topic
MD
cat > tests/fixtures/staleness/both-signals-medium/wiki/concepts/borderline.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Borderline
References [[topic]].
MD
# Only 2 newer sources touching the entity — moderate moved_past.
cat > tests/fixtures/staleness/both-signals-medium/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources:
  - path: raw/y-1.md
    kind: generic
    sha256: cccc1
    bytes: 100
    mtime: 2026-05-21T00:00:00Z
    ingested_at: 2026-05-21T01:00:00Z
    wiki_pages: [wiki/sources/y-1.md]
  - path: raw/y-2.md
    kind: generic
    sha256: cccc2
    bytes: 100
    mtime: 2026-05-21T00:00:00Z
    ingested_at: 2026-05-21T01:00:00Z
    wiki_pages: [wiki/sources/y-2.md]
YAML
for i in 1 2; do
  cat > tests/fixtures/staleness/both-signals-medium/wiki/sources/y-$i.md <<MD
---
tags: []
sources: [raw/y-$i.md]
created: 2026-05-21
updated: 2026-05-21
---
# Y $i
About [[topic]].
MD
done
# Padding so vault is over threshold.
for i in $(seq 1 22); do
  cat > tests/fixtures/staleness/both-signals-medium/wiki/concepts/padding-$i.md <<MD
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-01
updated: 2026-05-01
---
# Padding $i
MD
done
```

- [ ] **Step 2: Create `tiny-vault` fixture (5 pages → below threshold)**

```bash
mkdir -p tests/fixtures/staleness/tiny-vault/wiki/{.state,concepts}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/tiny-vault/wiki/.state/
cat > tests/fixtures/staleness/tiny-vault/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
cat > tests/fixtures/staleness/tiny-vault/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/tiny-vault/wiki/log.md <<'MD'
# Log
MD
for i in 1 2 3 4 5; do
  cat > tests/fixtures/staleness/tiny-vault/wiki/concepts/p$i.md <<MD
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-01
updated: 2026-05-01
---
# P$i
MD
done
```

- [ ] **Step 3: Create `empty-vault` fixture (no candidate pages at all)**

```bash
mkdir -p tests/fixtures/staleness/empty-vault/wiki/.state
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/empty-vault/wiki/.state/
cat > tests/fixtures/staleness/empty-vault/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
cat > tests/fixtures/staleness/empty-vault/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/empty-vault/wiki/log.md <<'MD'
# Log
MD
```

- [ ] **Step 4: Add three test cases**

```bash
echo "==> candidates: borderline page gets medium composite"
(
  V=$(make_vault both-medium)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/both-signals-medium/wiki/." "$V/wiki/"
  touch -t 202401010000 "$V/wiki/concepts/borderline.md"
  cd "$V"
  node "$SCRIPT" candidates >/dev/null
  signal=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/borderline.md');process.stdout.write(e?e.signal:'(missing)')")
  case "$signal" in
    medium|high) assert_eq "borderline signal" "$signal" "$signal" ;;
    *) assert_eq "borderline signal" "medium or high" "$signal" ;;
  esac
)

echo "==> candidates: tiny vault → empty + warning"
(
  V=$(make_vault tiny)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/tiny-vault/wiki/." "$V/wiki/"
  cd "$V"
  set +e
  output=$(node "$SCRIPT" candidates 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "0" "$rc"
  case "$output" in *"<20"*|*"tiny"*|*"candidate-eligible"*) ok=1 ;; *) ok=0 ;; esac
  assert_eq "warns about tiny vault" "1" "$ok"
  pages=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.pages.length))")
  assert_eq "no pages enqueued" "0" "$pages"
)

echo "==> candidates: empty vault → empty + warning"
(
  V=$(make_vault empty)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/empty-vault/wiki/." "$V/wiki/"
  cd "$V"
  set +e
  rc=$(node "$SCRIPT" candidates 2>&1 >/dev/null; echo $?)
  set -e
  assert_eq "exit code" "0" "$rc"
  pages=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.pages.length))")
  assert_eq "zero pages" "0" "$pages"
)
```

- [ ] **Step 5: Run the harness — all 12 cases pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 12 passed, 0 failed`. Composite-medium and both tiny-vault paths use the existing implementation; only new fixtures + assertions land.

- [ ] **Step 6: Commit**

```bash
git add tests/test_staleness.sh tests/fixtures/staleness/both-signals-medium tests/fixtures/staleness/tiny-vault tests/fixtures/staleness/empty-vault
git commit -m "test(staleness): composite-medium + tiny/empty-vault guards"
```

---

## Task 7: `candidates` — dedupe + auto-defer merge policy

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/dedupe/`
- Create: `tests/fixtures/staleness/auto-defer-no-bump/`
- Create: `tests/fixtures/staleness/auto-defer-bumped/`

Apply the merge policy from spec §7 `candidates`: drop existing `unjudged`; preserve every other status; for `deferred` and `dismissed` entries, optionally re-promote to `unjudged` if the new score exceeds `last_reviewed_signal_score + 0.1`.

- [ ] **Step 1: Create `dedupe` fixture (pre-existing staleness.yaml with mixed statuses)**

```bash
mkdir -p tests/fixtures/staleness/dedupe/wiki/{.state,entities,concepts,sources}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/dedupe/wiki/.state/
cat > tests/fixtures/staleness/dedupe/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/dedupe/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/dedupe/wiki/entities/topic.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Topic
MD
cat > tests/fixtures/staleness/dedupe/wiki/concepts/old.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Old
[[topic]]
MD
cat > tests/fixtures/staleness/dedupe/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
for i in $(seq 1 22); do
  cat > tests/fixtures/staleness/dedupe/wiki/concepts/padding-$i.md <<MD
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-01
updated: 2026-05-01
---
# Padding $i
MD
done
cat > tests/fixtures/staleness/dedupe/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
scanned_at: 2026-05-20T10:00:00Z
vault_page_count: 24
pages:
  - id: 2026-05-20-001
    path: wiki/concepts/old.md
    signal: high
    factors: {age_months: 28, age_percentile: 0.95, newer_overlapping_sources: 0, moved_past_percentile: 0.0}
    last_reviewed_signal_score: 0.0
    status: unjudged
    judgment: null
    resolution: null
    resolved_at: null
    deferred_at: null
  - id: 2026-05-20-002
    path: wiki/concepts/padding-1.md
    signal: medium
    factors: {age_months: 1, age_percentile: 0.7, newer_overlapping_sources: 0, moved_past_percentile: 0.6}
    last_reviewed_signal_score: 0.42
    status: resolved
    resolution: refreshed
    judgment: null
    resolved_at: 2026-05-21T10:00:00Z
    deferred_at: null
YAML
```

- [ ] **Step 2: Create `auto-defer-no-bump` fixture (deferred entry; new scan score unchanged)**

```bash
mkdir -p tests/fixtures/staleness/auto-defer-no-bump/wiki/.state
mkdir -p tests/fixtures/staleness/auto-defer-no-bump/wiki/concepts
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/auto-defer-no-bump/wiki/.state/
cat > tests/fixtures/staleness/auto-defer-no-bump/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/auto-defer-no-bump/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/auto-defer-no-bump/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
for i in $(seq 1 25); do
  cat > tests/fixtures/staleness/auto-defer-no-bump/wiki/concepts/p$i.md <<MD
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# P$i
MD
done
cat > tests/fixtures/staleness/auto-defer-no-bump/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
scanned_at: 2026-05-20T10:00:00Z
vault_page_count: 25
pages:
  - id: 2026-05-20-001
    path: wiki/concepts/p1.md
    signal: medium
    factors: {age_months: 28, age_percentile: 0.96, newer_overlapping_sources: 0, moved_past_percentile: 0.5}
    last_reviewed_signal_score: 0.48
    status: deferred
    judgment: null
    resolution: null
    resolved_at: null
    deferred_at: 2026-05-21T10:00:00Z
YAML
```

- [ ] **Step 3: Create `auto-defer-bumped` fixture (deferred entry; new score >> stored + 0.1)**

```bash
mkdir -p tests/fixtures/staleness/auto-defer-bumped/wiki/{.state,entities,concepts,sources}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/auto-defer-bumped/wiki/.state/
cat > tests/fixtures/staleness/auto-defer-bumped/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/auto-defer-bumped/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/auto-defer-bumped/wiki/entities/topic.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Topic
MD
cat > tests/fixtures/staleness/auto-defer-bumped/wiki/concepts/old.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Old
[[topic]]
MD
# Many newer sources sharing the entity — drives moved_past high.
cat > tests/fixtures/staleness/auto-defer-bumped/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources:
YAML
for i in $(seq 1 10); do
  cat >> tests/fixtures/staleness/auto-defer-bumped/wiki/.state/sources.yaml <<YAML
  - path: raw/z-$i.md
    kind: generic
    sha256: dddd$i
    bytes: 100
    mtime: 2026-05-21T00:00:00Z
    ingested_at: 2026-05-21T01:00:00Z
    wiki_pages: [wiki/sources/z-$i.md]
YAML
  cat > tests/fixtures/staleness/auto-defer-bumped/wiki/sources/z-$i.md <<MD
---
tags: []
sources: [raw/z-$i.md]
created: 2026-05-21
updated: 2026-05-21
---
# Z $i
[[topic]]
MD
done
for i in $(seq 1 22); do
  cat > tests/fixtures/staleness/auto-defer-bumped/wiki/concepts/padding-$i.md <<MD
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-01
updated: 2026-05-01
---
# Padding $i
MD
done
cat > tests/fixtures/staleness/auto-defer-bumped/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
scanned_at: 2026-04-01T10:00:00Z
vault_page_count: 24
pages:
  - id: 2026-04-01-001
    path: wiki/concepts/old.md
    signal: medium
    factors: {age_months: 24, age_percentile: 0.95, newer_overlapping_sources: 0, moved_past_percentile: 0.1}
    last_reviewed_signal_score: 0.10
    status: deferred
    judgment: null
    resolution: null
    resolved_at: null
    deferred_at: 2026-04-01T11:00:00Z
YAML
```

- [ ] **Step 4: Add three merge-policy test cases**

```bash
echo "==> candidates: dedupe preserves non-unjudged, drops unjudged"
(
  V=$(make_vault dedupe)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/dedupe/wiki/." "$V/wiki/"
  touch -t 202401010000 "$V/wiki/concepts/old.md"
  cd "$V"
  node "$SCRIPT" candidates >/dev/null
  json=$(node "$SCRIPT" list --json)
  resolved_present=$(echo "$json" | grep -c "id: 2026-05-20-002\|\"id\": \"2026-05-20-002\"" || true)
  unjudged_001_present=$(echo "$json" | grep -c "\"id\": \"2026-05-20-001\"" || true)
  assert_eq "resolved entry preserved" "1" "$resolved_present"
  assert_eq "old unjudged entry dropped" "0" "$unjudged_001_present"
)

echo "==> candidates: deferred entry stays deferred when score unchanged"
(
  V=$(make_vault adef-no-bump)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/auto-defer-no-bump/wiki/." "$V/wiki/"
  cd "$V"
  node "$SCRIPT" candidates >/dev/null
  status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/p1.md');process.stdout.write(e?e.status:'(missing)')")
  assert_eq "p1 still deferred" "deferred" "$status"
)

echo "==> candidates: deferred entry returns to unjudged when score bumps"
(
  V=$(make_vault adef-bumped)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/auto-defer-bumped/wiki/." "$V/wiki/"
  touch -t 202401010000 "$V/wiki/concepts/old.md"
  cd "$V"
  node "$SCRIPT" candidates >/dev/null
  status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/old.md');process.stdout.write(e?e.status:'(missing)')")
  assert_eq "old re-promoted to unjudged" "unjudged" "$status"
)
```

- [ ] **Step 5: Run the harness — dedupe + bumped fail (re-promotion not implemented yet)**

Run: `bash tests/test_staleness.sh`
Expected: existing 12 PASS; `dedupe` passes (current merge already preserves non-unjudged), `auto-defer-no-bump` passes (deferred stays), `auto-defer-bumped` fails (no re-promotion logic).

- [ ] **Step 6: Update `cmdCandidates` merge block to handle auto-defer re-promotion**

Replace the merge section (from `// 3. Merge with existing entries.` through the `writeState(...)` call) with:

```js
  // 3. Merge with existing entries.
  // - Drop existing status:unjudged (will be re-derived from current scan).
  // - Preserve unreviewed/resolved as-is.
  // - For deferred/dismissed: keep status unchanged UNLESS the new score
  //   exceeds last_reviewed_signal_score + AUTODEFER_DELTA; then re-promote
  //   to unjudged with fresh factors.
  const scoreByPath = new Map(scored.map((s) => [s.path, s]));
  const preserved = [];
  const promotedPaths = new Set();
  for (const e of existing.pages) {
    if (!e || !e.status) continue;
    if (e.status === 'unjudged') continue;
    if ((e.status === 'deferred' || e.status === 'dismissed') && scoreByPath.has(e.path)) {
      const fresh = scoreByPath.get(e.path);
      const baseline = typeof e.last_reviewed_signal_score === 'number' ? e.last_reviewed_signal_score : 0;
      if (fresh.score > baseline + AUTODEFER_DELTA) {
        preserved.push({
          ...e,
          signal: fresh.signal,
          factors: fresh.factors,
          status: 'unjudged',
          judgment: null,
          resolution: null,
          resolved_at: null,
          deferred_at: null,
        });
        promotedPaths.add(e.path);
        continue;
      }
    }
    preserved.push(e);
  }
  const preservedPaths = new Set(preserved.map((e) => e.path));
  const newEntries = [];
  for (const s of scored) {
    if (preservedPaths.has(s.path)) continue;
    if (s.signal === 'low') continue;
    newEntries.push({
      id: allocateId([...preserved, ...newEntries]),
      path: s.path,
      signal: s.signal,
      factors: s.factors,
      last_reviewed_signal_score: null,
      status: 'unjudged',
      judgment: null,
      resolution: null,
      resolved_at: null,
      deferred_at: null,
    });
  }

  writeState(vault, {
    scanned_at: nowIso(),
    vault_page_count: pages.length,
    pages: [...preserved, ...newEntries],
  });

  if (args.json) {
    process.stdout.write(JSON.stringify({ pages: [...preserved, ...newEntries] }, null, 2) + '\n');
  }
```

- [ ] **Step 7: Run the harness — all 15 cases pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 15 passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh tests/fixtures/staleness/dedupe tests/fixtures/staleness/auto-defer-no-bump tests/fixtures/staleness/auto-defer-bumped
git commit -m "feat(staleness): merge policy with auto-defer re-promotion"
```

---

## Task 8: `candidates --scope` (dir or page list)

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`

`--scope` restricts the candidate set to a directory prefix or comma-separated page-list, but percentile computation still uses the whole vault. Useful for partial re-scans (today rare; ingest skips, but lint may want it).

- [ ] **Step 1: Add the scope test case**

```bash
echo "==> candidates --scope: restricts what gets enqueued, not what gets percentile-ranked"
(
  V=$(make_vault scope)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/both-signals-high/wiki/." "$V/wiki/"
  touch -t 202401010000 "$V/wiki/concepts/stale-page.md"
  cd "$V"
  node "$SCRIPT" candidates --scope=wiki/concepts/stale-page.md >/dev/null
  json=$(node "$SCRIPT" list --json)
  stale_present=$(echo "$json" | grep -c "wiki/concepts/stale-page.md" || true)
  padding_present=$(echo "$json" | grep -c "wiki/concepts/padding-1.md" || true)
  assert_eq "scoped page present" "1" "$stale_present"
  assert_eq "out-of-scope page absent" "0" "$padding_present"
)
```

- [ ] **Step 2: Update `cmdCandidates` to honour `--scope`**

Modify the `// 2c.` and `// 2d.` blocks to compute scoring across all pages (for percentiles) but only emit enqueueable entries for in-scope pages. Replace `for (const s of scored) {` in the enqueue loop with a scope filter:

Insert near the top of `cmdCandidates`, after `const existing = readState(vault) || { pages: [] };`:

```js
  const scopeList = parseScope(args.scope);
```

Then add the helper above `cmdCandidates`:

```js
function parseScope(scope) {
  if (!scope || scope === true) return null;
  return String(scope).split(',').map((s) => s.trim()).filter(Boolean);
}
function inScope(p, scopeList) {
  if (!scopeList) return true;
  for (const s of scopeList) {
    if (p === s) return true;
    if (s.endsWith('/') && p.startsWith(s)) return true;
    if (!s.endsWith('/') && p.startsWith(s + '/')) return true;
  }
  return false;
}
```

Modify the enqueue loop:

```js
  for (const s of scored) {
    if (preservedPaths.has(s.path)) continue;
    if (s.signal === 'low') continue;
    if (!inScope(s.path, scopeList)) continue;
    newEntries.push({ ... });
  }
```

- [ ] **Step 3: Run the harness — passes**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 16 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh
git commit -m "feat(staleness): candidates --scope filter (page or dir prefix)"
```

---

## Task 9: `judge` subcommand — verdict routing + invalid-transition

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`

Transitions:
- `unjudged` + verdict `stale` → `unreviewed`
- `unjudged` + verdict `drifting` → `unreviewed`
- `unjudged` + verdict `fresh-but-isolated` → `dismissed`
- `unjudged` + verdict `false-positive` → `dismissed`
- Any other source status → exit 3, no mutation.

Updates `last_reviewed_signal_score` to current composite score (recomputed from stored factors).

- [ ] **Step 1: Add the four-verdict happy-path test**

```bash
echo "==> judge: each verdict routes to the correct status"
for verdict in stale:unreviewed drifting:unreviewed fresh-but-isolated:dismissed false-positive:dismissed; do
  v=${verdict%%:*}; expected=${verdict##*:}
  V=$(make_vault "judge-$v")
  cat > "$V/wiki/.state/staleness.yaml" <<YAML
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    factors: {age_months: 24, age_percentile: 0.9, newer_overlapping_sources: 10, moved_past_percentile: 0.9}
    last_reviewed_signal_score: null
    status: unjudged
    judgment: null
    resolution: null
    resolved_at: null
    deferred_at: null
YAML
  ( cd "$V"; node "$SCRIPT" judge --id=2026-05-25-001 --verdict="$v" --data='{"reason":"...","neighbors_examined":[]}' >/dev/null )
  actual=$( cd "$V"; node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].status)" )
  assert_eq "judge $v → $expected" "$expected" "$actual"
  verdict_stored=$( cd "$V"; node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write((d.pages[0].judgment||{}).verdict||'')" )
  assert_eq "judge $v verdict persisted" "$v" "$verdict_stored"
done
```

- [ ] **Step 2: Add the invalid-transition test**

```bash
echo "==> judge: re-judging an already-judged entry → exit 3"
(
  V=$(make_vault judge-invalid)
  cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    factors: {age_months: 24, age_percentile: 0.9, newer_overlapping_sources: 10, moved_past_percentile: 0.9}
    last_reviewed_signal_score: 0.81
    status: unreviewed
    judgment: {verdict: stale, reason: ".", neighbors_examined: [], judged_at: "2026-05-24T00:00:00Z"}
    resolution: null
    resolved_at: null
    deferred_at: null
YAML
  cd "$V"
  set +e
  output=$(node "$SCRIPT" judge --id=2026-05-25-001 --verdict=drifting --data='{"reason":".","neighbors_examined":[]}' 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "3" "$rc"
  case "$output" in *"expected unjudged"*|*"invalid"*|*"status is"*) ok=1 ;; *) ok=0 ;; esac
  assert_eq "error mentions status" "1" "$ok"
)
```

- [ ] **Step 3: Add the missing-id test**

```bash
echo "==> judge: missing id → exit 3"
(
  V=$(make_vault judge-missing)
  cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages: []
YAML
  cd "$V"
  set +e
  output=$(node "$SCRIPT" judge --id=2026-05-25-999 --verdict=stale --data='{"reason":".","neighbors_examined":[]}' 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "3" "$rc"
  case "$output" in *"not found"*) ok=1 ;; *) ok=0 ;; esac
  assert_eq "error mentions not found" "1" "$ok"
)
```

- [ ] **Step 4: Run the harness — all judge cases fail (not implemented)**

Run: `bash tests/test_staleness.sh`
Expected: existing 16 PASS; 6 new cases (4 happy + invalid + missing) FAIL with `judge: not implemented yet`.

- [ ] **Step 5: Replace `cmdJudge` with the implementation**

```js
const VALID_VERDICTS = new Set(['stale', 'drifting', 'fresh-but-isolated', 'false-positive']);

function cmdJudge(vault, args) {
  if (!args.id) die('judge: --id is required', 2);
  if (!args.verdict) die('judge: --verdict is required', 2);
  if (!VALID_VERDICTS.has(args.verdict)) die(`judge: unknown verdict ${args.verdict}`, 2);
  if (!args.data) die('judge: --data is required', 2);
  let data;
  try { data = JSON.parse(args.data); } catch { die('judge: --data is not valid JSON', 2); }
  if (typeof data.reason !== 'string') die('judge: --data.reason must be a string', 2);
  if (!Array.isArray(data.neighbors_examined)) die('judge: --data.neighbors_examined must be an array', 2);

  const doc = readState(vault);
  if (!doc) die(`judge: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`judge: id ${args.id} not found`, 3);
  if (entry.status !== 'unjudged') {
    die(`judge: entry ${args.id} status is ${entry.status}, expected unjudged`, 3);
  }

  const newStatus = (args.verdict === 'stale' || args.verdict === 'drifting') ? 'unreviewed' : 'dismissed';
  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = newStatus;
  entry.judgment = {
    verdict: args.verdict,
    reason: data.reason,
    neighbors_examined: data.neighbors_examined,
    judged_at: nowIso(),
  };
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: ${args.verdict} → ${newStatus}\n`);
}
```

- [ ] **Step 6: Run the harness — all 22 cases pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 22 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh
git commit -m "feat(staleness): judge subcommand with four-verdict routing"
```

---

## Task 10: `resolve --kind defer`

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`

`resolve --id <id> --kind defer` transitions `unreviewed` → `deferred`. Updates `last_reviewed_signal_score` and `deferred_at`. Refuses (exit 3) any other source status. `--kind` must be `defer` (the other resolutions are handled by `apply-refresh` / `apply-archive` / `apply-historical`).

- [ ] **Step 1: Add happy-path + invalid-status + unsupported-kind tests**

```bash
echo "==> resolve defer: unreviewed → deferred"
(
  V=$(make_vault resolve-happy)
  cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    factors: {age_months: 24, age_percentile: 0.9, newer_overlapping_sources: 10, moved_past_percentile: 0.9}
    last_reviewed_signal_score: 0.81
    status: unreviewed
    judgment: {verdict: stale, reason: ".", neighbors_examined: [], judged_at: "2026-05-25T00:00:00Z"}
    resolution: null
    resolved_at: null
    deferred_at: null
YAML
  cd "$V"
  node "$SCRIPT" resolve --id=2026-05-25-001 --kind=defer >/dev/null
  status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].status)")
  assert_eq "status" "deferred" "$status"
)

echo "==> resolve defer: invalid source status → exit 3"
(
  V=$(make_vault resolve-invalid)
  cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    factors: {age_months: 24, age_percentile: 0.9, newer_overlapping_sources: 10, moved_past_percentile: 0.9}
    last_reviewed_signal_score: 0.81
    status: resolved
    resolution: refreshed
    judgment: null
    resolved_at: "2026-05-25T00:00:00Z"
    deferred_at: null
YAML
  cd "$V"
  set +e
  output=$(node "$SCRIPT" resolve --id=2026-05-25-001 --kind=defer 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "3" "$rc"
)

echo "==> resolve --kind=bogus → exit 2"
(
  V=$(make_vault resolve-bogus-kind)
  cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages: []
YAML
  cd "$V"
  set +e
  output=$(node "$SCRIPT" resolve --id=2026-05-25-001 --kind=bogus 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "2" "$rc"
)
```

- [ ] **Step 2: Run the harness — three new cases fail (resolve is a stub)**

Run: `bash tests/test_staleness.sh`
Expected: previous 22 PASS; 3 new FAIL.

- [ ] **Step 3: Replace `cmdResolve` with the implementation**

```js
function cmdResolve(vault, args) {
  if (!args.id) die('resolve: --id is required', 2);
  if (args.kind !== 'defer') {
    die(`resolve: unsupported --kind ${args.kind} (only 'defer' is handled here; use apply-refresh/archive/historical)`, 2);
  }
  const doc = readState(vault);
  if (!doc) die(`resolve: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`resolve: id ${args.id} not found`, 3);
  if (entry.status !== 'unreviewed') {
    die(`resolve: entry ${args.id} status is ${entry.status}, expected unreviewed`, 3);
  }
  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = 'deferred';
  entry.deferred_at = nowIso();
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: deferred\n`);
}
```

- [ ] **Step 4: Run the harness — all 25 pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 25 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh
git commit -m "feat(staleness): resolve --kind defer (unreviewed → deferred)"
```

---

## Task 11: `apply-refresh` — atomic rewrite + validate-wiki revert

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/apply-refresh-input/`

Atomic-replace the page body with the contents of `--rewrite <tmpfile>`. Run `validate-wiki.js all`. On failure restore original + exit 2 (entry stays `unreviewed`). On success set `status: resolved`, `resolution: refreshed`, `resolved_at: now`, `last_reviewed_signal_score: <current>`.

- [ ] **Step 1: Create `apply-refresh-input` fixture**

```bash
mkdir -p tests/fixtures/staleness/apply-refresh-input/wiki/{.state,concepts}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/apply-refresh-input/wiki/.state/
cat > tests/fixtures/staleness/apply-refresh-input/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
cat > tests/fixtures/staleness/apply-refresh-input/wiki/index.md <<'MD'
# Index
- [[wiki/concepts/page]]
MD
cat > tests/fixtures/staleness/apply-refresh-input/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/apply-refresh-input/wiki/concepts/page.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Page
Old content.
MD
cat > tests/fixtures/staleness/apply-refresh-input/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/page.md
    signal: high
    factors: {age_months: 24, age_percentile: 0.9, newer_overlapping_sources: 10, moved_past_percentile: 0.9}
    last_reviewed_signal_score: 0.81
    status: unreviewed
    judgment: {verdict: stale, reason: ".", neighbors_examined: [], judged_at: "2026-05-25T00:00:00Z"}
    resolution: null
    resolved_at: null
    deferred_at: null
YAML
```

- [ ] **Step 2: Add happy-path test**

```bash
echo "==> apply-refresh: clean rewrite → status resolved/refreshed"
(
  V=$(make_vault apply-refresh-happy)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/apply-refresh-input/wiki/." "$V/wiki/"
  TMP=$(mktemp)
  cat > "$TMP" <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2026-05-25
---
# Page
New content reflecting current sources.
MD
  cd "$V"
  node "$SCRIPT" apply-refresh --id=2026-05-25-001 --rewrite="$TMP" >/dev/null
  body=$(cat wiki/concepts/page.md)
  case "$body" in *"New content"*) assert_eq "page updated" "ok" "ok" ;; *) assert_eq "page updated" "yes" "$body" ;; esac
  status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].status)")
  res=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].resolution)")
  assert_eq "status" "resolved" "$status"
  assert_eq "resolution" "refreshed" "$res"
  rm -f "$TMP"
)
```

- [ ] **Step 3: Add validate-failure-reverts test**

```bash
echo "==> apply-refresh: validate failure reverts file + entry stays unreviewed"
(
  V=$(make_vault apply-refresh-revert)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/apply-refresh-input/wiki/." "$V/wiki/"
  TMP=$(mktemp)
  cat > "$TMP" <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2026-05-25
---
# Page
Refers to [[doesnotexist]] which will fail wikilink validation.
MD
  cd "$V"
  set +e
  output=$(node "$SCRIPT" apply-refresh --id=2026-05-25-001 --rewrite="$TMP" 2>&1)
  rc=$?
  set -e
  assert_eq "exit code" "2" "$rc"
  body=$(cat wiki/concepts/page.md)
  case "$body" in *"Old content"*) assert_eq "page reverted" "ok" "ok" ;; *) assert_eq "page reverted" "yes" "$body" ;; esac
  status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].status)")
  assert_eq "entry stays unreviewed" "unreviewed" "$status"
  rm -f "$TMP"
)
```

- [ ] **Step 4: Run the harness — two new cases fail (apply-refresh is a stub)**

Run: `bash tests/test_staleness.sh`
Expected: previous 25 PASS; 2 new FAIL.

- [ ] **Step 5: Implement `cmdApplyRefresh` (replace stub) + add the validate-wiki helper**

```js
const { spawnSync } = require('child_process');

function runValidateWiki(vault) {
  const validatePath = path.join(__dirname, 'validate-wiki.js');
  const r = spawnSync(process.execPath, [validatePath, 'all'], { cwd: vault, encoding: 'utf8' });
  return { code: r.status, stderr: r.stderr, stdout: r.stdout };
}

function cmdApplyRefresh(vault, args) {
  if (!args.id) die('apply-refresh: --id is required', 2);
  if (!args.rewrite) die('apply-refresh: --rewrite <tmpfile> is required', 2);
  if (!fs.existsSync(args.rewrite)) die(`apply-refresh: tmpfile not found: ${args.rewrite}`, 2);

  const doc = readState(vault);
  if (!doc) die(`apply-refresh: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-refresh: id ${args.id} not found`, 3);
  if (entry.status !== 'unreviewed') {
    die(`apply-refresh: entry ${args.id} status is ${entry.status}, expected unreviewed`, 3);
  }

  const abs = path.join(vault, entry.path);
  if (!fs.existsSync(abs)) die(`apply-refresh: page ${entry.path} no longer exists`, 3);
  const original = fs.readFileSync(abs, 'utf8');
  const rewrite = fs.readFileSync(args.rewrite, 'utf8');

  // Atomic write.
  const tmp = `${abs}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmp, rewrite);
  fs.renameSync(tmp, abs);

  const v = runValidateWiki(vault);
  if (v.code !== 0) {
    fs.writeFileSync(abs, original);
    process.stderr.write(v.stderr || v.stdout || '');
    die(`apply-refresh: validate-wiki failed (exit ${v.code}); reverted ${entry.path}`, 2);
  }

  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = 'resolved';
  entry.resolution = 'refreshed';
  entry.resolved_at = nowIso();
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: refreshed\n`);
}
```

- [ ] **Step 6: Run the harness — all 27 pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 27 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh tests/fixtures/staleness/apply-refresh-input
git commit -m "feat(staleness): apply-refresh with validate-wiki revert"
```

---

## Task 12: `apply-archive` — move + dual lifecycle stub + inbound-link integrity

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/apply-archive-input/`

Three-part operation: (a) move file → `wiki/archive/<year>/<original-path>` and add `lifecycle: { state: archived, original: <orig> }` to its frontmatter; (b) write a stub at the original path with `lifecycle: { state: superseded, by: <archive-path> }`, empty `sources: []`, and a single-line body; (c) run `validate-wiki.js all`. On failure restore both sides + exit 2.

(The validator's `lifecycle` rule lands in Task 15; until then it does not exist. For this task we ensure `apply-archive` performs the file ops correctly — the validate-wiki call still runs but does not enforce lifecycle shape. The Task 15 fixtures will additionally cover the dual-frontmatter case.)

- [ ] **Step 1: Create `apply-archive-input` fixture (with an inbound wikilink from a sibling page)**

```bash
mkdir -p tests/fixtures/staleness/apply-archive-input/wiki/{.state,concepts}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/apply-archive-input/wiki/.state/
cat > tests/fixtures/staleness/apply-archive-input/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
cat > tests/fixtures/staleness/apply-archive-input/wiki/index.md <<'MD'
# Index
- [[wiki/concepts/old]]
- [[wiki/concepts/refers]]
MD
cat > tests/fixtures/staleness/apply-archive-input/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/apply-archive-input/wiki/concepts/old.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Old
Original content.
MD
cat > tests/fixtures/staleness/apply-archive-input/wiki/concepts/refers.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Refers
See [[wiki/concepts/old]].
MD
cat > tests/fixtures/staleness/apply-archive-input/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/old.md
    signal: high
    factors: {age_months: 24, age_percentile: 0.9, newer_overlapping_sources: 10, moved_past_percentile: 0.9}
    last_reviewed_signal_score: 0.81
    status: unreviewed
    judgment: {verdict: stale, reason: ".", neighbors_examined: [], judged_at: "2026-05-25T00:00:00Z"}
    resolution: null
    resolved_at: null
    deferred_at: null
YAML
```

- [ ] **Step 2: Add happy-path test**

```bash
echo "==> apply-archive: moves file, writes stub, both have lifecycle frontmatter"
(
  V=$(make_vault apply-archive-happy)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/apply-archive-input/wiki/." "$V/wiki/"
  touch -t 202401010000 "$V/wiki/concepts/old.md"
  cd "$V"
  node "$SCRIPT" apply-archive --id=2026-05-25-001 >/dev/null
  # Archive file present
  [ -f wiki/archive/2024/concepts/old.md ] && assert_eq "archive file exists" "ok" "ok" || assert_eq "archive file exists" "yes" "missing"
  # Stub present at original path
  [ -f wiki/concepts/old.md ] && assert_eq "stub file exists" "ok" "ok" || assert_eq "stub file exists" "yes" "missing"
  archive_fm=$(head -n 12 wiki/archive/2024/concepts/old.md)
  case "$archive_fm" in *"state: archived"*"original: wiki/concepts/old.md"*) assert_eq "archive lifecycle" "ok" "ok" ;; *) assert_eq "archive lifecycle" "state: archived, original:..." "$archive_fm" ;; esac
  stub_fm=$(head -n 12 wiki/concepts/old.md)
  case "$stub_fm" in *"state: superseded"*"by: wiki/archive/2024/concepts/old.md"*) assert_eq "stub lifecycle" "ok" "ok" ;; *) assert_eq "stub lifecycle" "state: superseded, by:..." "$stub_fm" ;; esac
  # Staleness entry: resolved/archived
  status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].status)")
  res=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].resolution)")
  assert_eq "status" "resolved" "$status"
  assert_eq "resolution" "archived" "$res"
)
```

- [ ] **Step 3: Run the harness — fails (apply-archive is a stub)**

Run: `bash tests/test_staleness.sh`
Expected: 1 new FAIL.

- [ ] **Step 4: Add helpers + replace `cmdApplyArchive`**

Add above `cmdApplyArchive`:

```js
const FRONTMATTER_RE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/;

function splitFrontmatter(text) {
  const m = FRONTMATTER_RE.exec(text);
  if (!m) return { fm: null, body: text };
  return { fm: m[1], body: m[2] };
}
function joinFrontmatter(fm, body) {
  return `---\n${fm}\n---\n${body}`;
}
function parseFrontmatter(fm) {
  return yaml.load(fm, { schema: yaml.CORE_SCHEMA }) || {};
}
function dumpFrontmatter(obj) {
  return yaml.dump(obj, { indent: 2, sortKeys: false, lineWidth: -1 }).trimEnd();
}

function yearFromMtime(absPath) {
  const s = fs.statSync(absPath);
  const d = new Date(s.mtimeMs);
  return String(d.getUTCFullYear());
}
```

Replace `cmdApplyArchive`:

```js
function cmdApplyArchive(vault, args) {
  if (!args.id) die('apply-archive: --id is required', 2);
  const doc = readState(vault);
  if (!doc) die(`apply-archive: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-archive: id ${args.id} not found`, 3);
  if (entry.status !== 'unreviewed') {
    die(`apply-archive: entry ${args.id} status is ${entry.status}, expected unreviewed`, 3);
  }
  const origRel = entry.path;
  const origAbs = path.join(vault, origRel);
  if (!fs.existsSync(origAbs)) die(`apply-archive: page ${origRel} does not exist`, 3);

  const year = yearFromMtime(origAbs);
  const archiveRel = `wiki/archive/${year}/${origRel.replace(/^wiki\//, '')}`;
  const archiveAbs = path.join(vault, archiveRel);
  if (fs.existsSync(archiveAbs)) die(`apply-archive: archive target already exists: ${archiveRel}`, 3);

  const originalText = fs.readFileSync(origAbs, 'utf8');
  const { fm, body } = splitFrontmatter(originalText);
  const fmObj = fm ? parseFrontmatter(fm) : {};
  const carryTags = Array.isArray(fmObj.tags) ? fmObj.tags : [];
  const carryCreated = fmObj.created || todayDateStr();
  const carryUpdated = todayDateStr();

  // 1. Write archive file (original content + lifecycle: archived).
  fmObj.lifecycle = { state: 'archived', original: origRel };
  const archiveText = joinFrontmatter(dumpFrontmatter(fmObj), body);
  fs.mkdirSync(path.dirname(archiveAbs), { recursive: true });
  const archiveTmp = `${archiveAbs}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(archiveTmp, archiveText);
  fs.renameSync(archiveTmp, archiveAbs);

  // 2. Replace original with stub (lifecycle: superseded + empty sources).
  const stubFm = dumpFrontmatter({
    tags: carryTags,
    sources: [],
    created: carryCreated,
    updated: carryUpdated,
    lifecycle: { state: 'superseded', by: archiveRel },
  });
  const stubBody = `See [[${archiveRel.replace(/\.md$/, '')}]] for the original content.\n`;
  const stubText = joinFrontmatter(stubFm, stubBody);
  const stubTmp = `${origAbs}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(stubTmp, stubText);
  fs.renameSync(stubTmp, origAbs);

  // 3. Validate.
  const v = runValidateWiki(vault);
  if (v.code !== 0) {
    fs.writeFileSync(origAbs, originalText);
    try { fs.unlinkSync(archiveAbs); } catch {}
    process.stderr.write(v.stderr || v.stdout || '');
    die(`apply-archive: validate-wiki failed (exit ${v.code}); reverted`, 2);
  }

  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = 'resolved';
  entry.resolution = 'archived';
  entry.resolved_at = nowIso();
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: archived → ${archiveRel}\n`);
}
```

- [ ] **Step 5: Run the harness — happy path passes**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 28 passed, 0 failed`. The validate-wiki call will return 0 because the validator does not yet know about `lifecycle:` — that's fine, the file ops are what we're testing here. Inbound-link integrity check lands in Step 6.

- [ ] **Step 6: Add inbound-link-still-resolves test (run AFTER Task 15 lifecycle validator lands; we add it now but expect it to remain green after Task 15)**

```bash
echo "==> apply-archive: inbound wikilinks resolve through the stub"
(
  V=$(make_vault apply-archive-links)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/apply-archive-input/wiki/." "$V/wiki/"
  touch -t 202401010000 "$V/wiki/concepts/old.md"
  cd "$V"
  node "$SCRIPT" apply-archive --id=2026-05-25-001 >/dev/null
  # validate-wiki wikilinks should still pass: refers.md links [[wiki/concepts/old]]
  # which now points at the STUB (which exists at wiki/concepts/old.md).
  set +e
  rc=$(node "$VALIDATE" wikilinks 2>&1 >/dev/null; echo $?)
  set -e
  assert_eq "wikilinks validator exit" "0" "$rc"
)
```

- [ ] **Step 7: Run the harness — all 29 pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 29 passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh tests/fixtures/staleness/apply-archive-input
git commit -m "feat(staleness): apply-archive with dual lifecycle frontmatter + stub redirect"
```

---

## Task 13: `apply-historical` — add `lifecycle: { state: historical, since }` to frontmatter

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/apply-historical-input/`

Edit page frontmatter in place. Default `--since` to current `YYYY-MM`. No body change. Validate; revert on failure.

- [ ] **Step 1: Create the fixture**

```bash
mkdir -p tests/fixtures/staleness/apply-historical-input/wiki/{.state,concepts}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/apply-historical-input/wiki/.state/
cat > tests/fixtures/staleness/apply-historical-input/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
cat > tests/fixtures/staleness/apply-historical-input/wiki/index.md <<'MD'
# Index
- [[wiki/concepts/snapshot]]
MD
cat > tests/fixtures/staleness/apply-historical-input/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/apply-historical-input/wiki/concepts/snapshot.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-05-01
updated: 2024-05-01
---
# Snapshot
Content meant to represent a frozen moment in time.
MD
cat > tests/fixtures/staleness/apply-historical-input/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/snapshot.md
    signal: high
    factors: {age_months: 24, age_percentile: 0.9, newer_overlapping_sources: 10, moved_past_percentile: 0.9}
    last_reviewed_signal_score: 0.81
    status: unreviewed
    judgment: {verdict: stale, reason: ".", neighbors_examined: [], judged_at: "2026-05-25T00:00:00Z"}
    resolution: null
    resolved_at: null
    deferred_at: null
YAML
```

- [ ] **Step 2: Add happy-path + default-since tests**

```bash
echo "==> apply-historical: explicit --since"
(
  V=$(make_vault apply-historical-explicit)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/apply-historical-input/wiki/." "$V/wiki/"
  cd "$V"
  node "$SCRIPT" apply-historical --id=2026-05-25-001 --since=2024-05 >/dev/null
  fm=$(head -n 12 wiki/concepts/snapshot.md)
  case "$fm" in *"state: historical"*"since: 2024-05"*) assert_eq "lifecycle frontmatter present" "ok" "ok" ;; *) assert_eq "lifecycle frontmatter present" "yes" "$fm" ;; esac
  body=$(tail -n 5 wiki/concepts/snapshot.md)
  case "$body" in *"frozen moment"*) assert_eq "body preserved" "ok" "ok" ;; *) assert_eq "body preserved" "yes" "$body" ;; esac
  status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].status)")
  res=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.pages[0].resolution)")
  assert_eq "status" "resolved" "$status"
  assert_eq "resolution" "historical" "$res"
)

echo "==> apply-historical: default --since is current YYYY-MM"
(
  V=$(make_vault apply-historical-default)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/apply-historical-input/wiki/." "$V/wiki/"
  cd "$V"
  node "$SCRIPT" apply-historical --id=2026-05-25-001 >/dev/null
  fm=$(head -n 12 wiki/concepts/snapshot.md)
  expected_since=$(date -u +%Y-%m)
  case "$fm" in *"since: $expected_since"*) assert_eq "default since" "ok" "ok" ;; *) assert_eq "default since" "$expected_since" "$fm" ;; esac
)
```

- [ ] **Step 3: Run the harness — 2 new FAIL**

Run: `bash tests/test_staleness.sh`
Expected: previous 29 PASS; 2 new FAIL.

- [ ] **Step 4: Replace `cmdApplyHistorical`**

```js
function todayMonthStr() {
  return new Date().toISOString().slice(0, 7);
}

function cmdApplyHistorical(vault, args) {
  if (!args.id) die('apply-historical: --id is required', 2);
  const since = (typeof args.since === 'string') ? args.since : todayMonthStr();
  if (!/^\d{4}-\d{2}$/.test(since)) die(`apply-historical: --since must be YYYY-MM, got ${since}`, 2);

  const doc = readState(vault);
  if (!doc) die(`apply-historical: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-historical: id ${args.id} not found`, 3);
  if (entry.status !== 'unreviewed') {
    die(`apply-historical: entry ${args.id} status is ${entry.status}, expected unreviewed`, 3);
  }
  const abs = path.join(vault, entry.path);
  if (!fs.existsSync(abs)) die(`apply-historical: page ${entry.path} does not exist`, 3);

  const original = fs.readFileSync(abs, 'utf8');
  const { fm, body } = splitFrontmatter(original);
  if (!fm) die(`apply-historical: page ${entry.path} has no frontmatter`, 3);
  const fmObj = parseFrontmatter(fm);
  fmObj.lifecycle = { state: 'historical', since };
  fmObj.updated = todayDateStr();
  const updated = joinFrontmatter(dumpFrontmatter(fmObj), body);

  const tmp = `${abs}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmp, updated);
  fs.renameSync(tmp, abs);

  const v = runValidateWiki(vault);
  if (v.code !== 0) {
    fs.writeFileSync(abs, original);
    process.stderr.write(v.stderr || v.stdout || '');
    die(`apply-historical: validate-wiki failed (exit ${v.code}); reverted`, 2);
  }

  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = 'resolved';
  entry.resolution = 'historical';
  entry.resolved_at = nowIso();
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: historical (since ${since})\n`);
}
```

- [ ] **Step 5: Run the harness — all 31 pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 31 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh tests/fixtures/staleness/apply-historical-input
git commit -m "feat(staleness): apply-historical adds lifecycle frontmatter"
```

---

## Task 14: `check` subcommand — lifecycle + stale-high warnings for `/query`

**Files:**
- Modify: `scripts/staleness.js`
- Modify: `tests/test_staleness.sh`
- Create: `tests/fixtures/staleness/check-input/`

`check --pages <comma-list> [--json]`. For each requested path: read its frontmatter for `lifecycle:`; cross-reference `staleness.yaml` for `status: unreviewed AND signal: high`. Emit a JSON `warnings[]` array (or human one-line-per format when `--json` is absent).

- [ ] **Step 1: Create the `check-input` fixture**

```bash
mkdir -p tests/fixtures/staleness/check-input/wiki/{.state,concepts,archive/2024/concepts}
cp tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml tests/fixtures/staleness/check-input/wiki/.state/
cat > tests/fixtures/staleness/check-input/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
cat > tests/fixtures/staleness/check-input/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/staleness/check-input/wiki/log.md <<'MD'
# Log
MD
cat > tests/fixtures/staleness/check-input/wiki/concepts/clean.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2026-05-01
updated: 2026-05-01
---
# Clean
MD
cat > tests/fixtures/staleness/check-input/wiki/concepts/historical.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-05-01
lifecycle:
  state: historical
  since: 2024-05
---
# Historical
MD
cat > tests/fixtures/staleness/check-input/wiki/concepts/superseded-stub.md <<'MD'
---
tags: []
sources: []
created: 2024-01-01
updated: 2026-05-01
lifecycle:
  state: superseded
  by: wiki/archive/2024/concepts/superseded-stub.md
---
See [[wiki/archive/2024/concepts/superseded-stub]] for the original content.
MD
cat > tests/fixtures/staleness/check-input/wiki/archive/2024/concepts/superseded-stub.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
lifecycle:
  state: archived
  original: wiki/concepts/superseded-stub.md
---
# Original
Archived content.
MD
cat > tests/fixtures/staleness/check-input/wiki/concepts/stale-high.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
# Stale High
MD
cat > tests/fixtures/staleness/check-input/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/stale-high.md
    signal: high
    factors: {age_months: 24, age_percentile: 0.9, newer_overlapping_sources: 10, moved_past_percentile: 0.9}
    last_reviewed_signal_score: 0.81
    status: unreviewed
    judgment: {verdict: stale, reason: ".", neighbors_examined: [], judged_at: "2026-05-25T00:00:00Z"}
    resolution: null
    resolved_at: null
    deferred_at: null
  - id: 2026-05-25-002
    path: wiki/concepts/medium-page.md
    signal: medium
    factors: {age_months: 12, age_percentile: 0.6, newer_overlapping_sources: 4, moved_past_percentile: 0.6}
    last_reviewed_signal_score: 0.36
    status: unreviewed
    judgment: {verdict: stale, reason: ".", neighbors_examined: [], judged_at: "2026-05-25T00:00:00Z"}
    resolution: null
    resolved_at: null
    deferred_at: null
YAML
cat > tests/fixtures/staleness/check-input/wiki/concepts/medium-page.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2025-05-01
updated: 2025-05-01
---
# Medium Page
MD
```

- [ ] **Step 2: Add check tests**

```bash
echo "==> check: clean page → no warnings"
(
  V=$(make_vault check-clean)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/check-input/wiki/." "$V/wiki/"
  cd "$V"
  json=$(node "$SCRIPT" check --pages=wiki/concepts/clean.md --json)
  count=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.warnings.length))")
  assert_eq "no warnings" "0" "$count"
)

echo "==> check: historical page → kind: historical"
(
  V=$(make_vault check-historical)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/check-input/wiki/." "$V/wiki/"
  cd "$V"
  json=$(node "$SCRIPT" check --pages=wiki/concepts/historical.md --json)
  kind=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.warnings[0]?d.warnings[0].kind:'')")
  assert_eq "kind" "historical" "$kind"
)

echo "==> check: superseded stub → kind: superseded"
(
  V=$(make_vault check-superseded)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/check-input/wiki/." "$V/wiki/"
  cd "$V"
  json=$(node "$SCRIPT" check --pages=wiki/concepts/superseded-stub.md --json)
  kind=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.warnings[0]?d.warnings[0].kind:'')")
  assert_eq "kind" "superseded" "$kind"
)

echo "==> check: archive file → kind: archived"
(
  V=$(make_vault check-archived)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/check-input/wiki/." "$V/wiki/"
  cd "$V"
  json=$(node "$SCRIPT" check --pages=wiki/archive/2024/concepts/superseded-stub.md --json)
  kind=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.warnings[0]?d.warnings[0].kind:'')")
  assert_eq "kind" "archived" "$kind"
)

echo "==> check: stale-high (yaml) → kind: stale-high"
(
  V=$(make_vault check-stale-high)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/check-input/wiki/." "$V/wiki/"
  cd "$V"
  json=$(node "$SCRIPT" check --pages=wiki/concepts/stale-high.md --json)
  kind=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(d.warnings[0]?d.warnings[0].kind:'')")
  assert_eq "kind" "stale-high" "$kind"
)

echo "==> check: medium-tier stale page → NOT warned"
(
  V=$(make_vault check-medium-quiet)
  cp -R "$REPO_ROOT/tests/fixtures/staleness/check-input/wiki/." "$V/wiki/"
  cd "$V"
  json=$(node "$SCRIPT" check --pages=wiki/concepts/medium-page.md --json)
  count=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.warnings.length))")
  assert_eq "no medium warnings" "0" "$count"
)
```

- [ ] **Step 3: Run the harness — six new cases fail (check is a stub)**

Run: `bash tests/test_staleness.sh`
Expected: previous 31 PASS; 6 new FAIL.

- [ ] **Step 4: Replace `cmdCheck`**

```js
function cmdCheck(vault, args) {
  if (!args.pages) die('check: --pages <comma-list> is required', 2);
  const paths = parseCommaList(args.pages) || [];
  const doc = readState(vault);
  const yamlEntries = doc ? doc.pages : [];

  const warnings = [];
  for (const p of paths) {
    const abs = path.join(vault, p);
    if (fs.existsSync(abs)) {
      const text = fs.readFileSync(abs, 'utf8');
      const { fm } = splitFrontmatter(text);
      if (fm) {
        const fmObj = parseFrontmatter(fm);
        const lc = fmObj && fmObj.lifecycle;
        if (lc && typeof lc === 'object' && lc.state) {
          const w = { path: p, kind: lc.state };
          if (lc.since) w.since = lc.since;
          if (lc.by) w.by = lc.by;
          if (lc.original) w.original = lc.original;
          warnings.push(w);
          continue;
        }
      }
    }
    const entry = yamlEntries.find((e) => e && e.path === p);
    if (entry && entry.status === 'unreviewed' && entry.signal === 'high') {
      warnings.push({ path: p, kind: 'stale-high', factors: entry.factors });
    }
  }

  if (args.json) {
    process.stdout.write(JSON.stringify({ warnings }, null, 2) + '\n');
    return;
  }
  if (warnings.length === 0) {
    process.stdout.write('(no warnings)\n');
    return;
  }
  for (const w of warnings) {
    process.stdout.write(`${w.path}\t${w.kind}${w.since ? `\tsince=${w.since}` : ''}\n`);
  }
}
```

- [ ] **Step 5: Run the harness — all 37 pass**

Run: `bash tests/test_staleness.sh`
Expected: `Results: 37 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add scripts/staleness.js tests/test_staleness.sh tests/fixtures/staleness/check-input
git commit -m "feat(staleness): check subcommand for /query lifecycle warnings"
```

---

## Task 15: `validate-wiki.js` lifecycle rule

**Files:**
- Modify: `scripts/validate-wiki.js`
- Modify: `tests/test_validate_wiki.sh`
- Create: `tests/fixtures/validate-wiki/lifecycle-historical-valid/`
- Create: `tests/fixtures/validate-wiki/lifecycle-superseded-valid/`
- Create: `tests/fixtures/validate-wiki/lifecycle-archived-valid/`
- Create: `tests/fixtures/validate-wiki/lifecycle-bad-state/`
- Create: `tests/fixtures/validate-wiki/lifecycle-historical-missing-since/`
- Create: `tests/fixtures/validate-wiki/lifecycle-superseded-broken-by/`
- Create: `tests/fixtures/validate-wiki/lifecycle-stub-sources-empty-ok/`

Add a `lifecycle` rule family to `validate-wiki.js`. Wired into the `all` group. Shape-check the block; resolve `by` / `original` path targets; exempt `state == superseded` pages from the `sources: may_be_empty: false` rule.

- [ ] **Step 1: Read the existing validate-wiki structure**

```bash
grep -n "case 'all'\|case 'frontmatter'\|case 'wikilinks'\|case 'index'" scripts/validate-wiki.js
```

Expected: a switch on subcommand with `all` dispatching to the other rule functions. Note the helper that loads frontmatter-contract.yaml (e.g. `loadContract`). The new `lifecycle` rule should mount in the same switch and `all` should include it.

- [ ] **Step 2: Create the seven fixtures**

Use this loop to scaffold each (substitute content per case):

```bash
for n in lifecycle-historical-valid lifecycle-superseded-valid lifecycle-archived-valid lifecycle-bad-state lifecycle-historical-missing-since lifecycle-superseded-broken-by lifecycle-stub-sources-empty-ok; do
  mkdir -p tests/fixtures/validate-wiki/$n/wiki/{.state,concepts,archive/2024/concepts}
  cp tests/fixtures/validate-wiki/clean/wiki/.state/frontmatter-contract.yaml tests/fixtures/validate-wiki/$n/wiki/.state/
  cat > tests/fixtures/validate-wiki/$n/wiki/.state/sources.yaml <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
  cat > tests/fixtures/validate-wiki/$n/wiki/index.md <<'MD'
# Index
MD
  cat > tests/fixtures/validate-wiki/$n/wiki/log.md <<'MD'
# Log
MD
done
```

Now fill each fixture's content:

```bash
cat > tests/fixtures/validate-wiki/lifecycle-historical-valid/wiki/concepts/snapshot.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-05-01
updated: 2024-05-01
lifecycle:
  state: historical
  since: 2024-05
---
# Snapshot
MD

cat > tests/fixtures/validate-wiki/lifecycle-superseded-valid/wiki/concepts/stub.md <<'MD'
---
tags: []
sources: []
created: 2024-01-01
updated: 2026-05-01
lifecycle:
  state: superseded
  by: wiki/archive/2024/concepts/stub.md
---
See [[wiki/archive/2024/concepts/stub]] for the original content.
MD
cat > tests/fixtures/validate-wiki/lifecycle-superseded-valid/wiki/archive/2024/concepts/stub.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
lifecycle:
  state: archived
  original: wiki/concepts/stub.md
---
# Original
MD

cat > tests/fixtures/validate-wiki/lifecycle-archived-valid/wiki/archive/2024/concepts/x.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
lifecycle:
  state: archived
  original: wiki/concepts/x.md
---
# X
MD
cat > tests/fixtures/validate-wiki/lifecycle-archived-valid/wiki/concepts/x.md <<'MD'
---
tags: []
sources: []
created: 2024-01-01
updated: 2026-05-01
lifecycle:
  state: superseded
  by: wiki/archive/2024/concepts/x.md
---
See [[wiki/archive/2024/concepts/x]] for the original content.
MD

cat > tests/fixtures/validate-wiki/lifecycle-bad-state/wiki/concepts/bad.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
lifecycle:
  state: bogus
---
# Bad
MD

cat > tests/fixtures/validate-wiki/lifecycle-historical-missing-since/wiki/concepts/missing.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
lifecycle:
  state: historical
---
# Missing since
MD

cat > tests/fixtures/validate-wiki/lifecycle-superseded-broken-by/wiki/concepts/stub.md <<'MD'
---
tags: []
sources: []
created: 2024-01-01
updated: 2026-05-01
lifecycle:
  state: superseded
  by: wiki/archive/2099/concepts/nonexistent.md
---
See [[wiki/archive/2099/concepts/nonexistent]] for the original content.
MD

cat > tests/fixtures/validate-wiki/lifecycle-stub-sources-empty-ok/wiki/concepts/stub.md <<'MD'
---
tags: []
sources: []
created: 2024-01-01
updated: 2026-05-01
lifecycle:
  state: superseded
  by: wiki/archive/2024/concepts/stub.md
---
See [[wiki/archive/2024/concepts/stub]] for the original content.
MD
cat > tests/fixtures/validate-wiki/lifecycle-stub-sources-empty-ok/wiki/archive/2024/concepts/stub.md <<'MD'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
lifecycle:
  state: archived
  original: wiki/concepts/stub.md
---
# Original
MD
```

- [ ] **Step 3: Add test cases to `tests/test_validate_wiki.sh`**

Append after the existing cases (model after the existing pattern in that file):

```bash
echo "==> lifecycle: historical with since → pass"
(
  V=$(setup_vault_from_fixture lifecycle-historical-valid)
  cd "$V"; rc=$(node "$VALIDATE" all 2>&1 >/dev/null; echo $?)
  assert_eq "exit" "0" "$rc"
)

echo "==> lifecycle: superseded stub with valid by-target → pass"
(
  V=$(setup_vault_from_fixture lifecycle-superseded-valid)
  cd "$V"; rc=$(node "$VALIDATE" all 2>&1 >/dev/null; echo $?)
  assert_eq "exit" "0" "$rc"
)

echo "==> lifecycle: archived with valid original → pass"
(
  V=$(setup_vault_from_fixture lifecycle-archived-valid)
  cd "$V"; rc=$(node "$VALIDATE" all 2>&1 >/dev/null; echo $?)
  assert_eq "exit" "0" "$rc"
)

echo "==> lifecycle: bad state → exit 2"
(
  V=$(setup_vault_from_fixture lifecycle-bad-state)
  cd "$V"; rc=$(node "$VALIDATE" all 2>&1 >/dev/null; echo $?)
  assert_eq "exit" "2" "$rc"
)

echo "==> lifecycle: historical missing since → exit 2"
(
  V=$(setup_vault_from_fixture lifecycle-historical-missing-since)
  cd "$V"; rc=$(node "$VALIDATE" all 2>&1 >/dev/null; echo $?)
  assert_eq "exit" "2" "$rc"
)

echo "==> lifecycle: superseded with broken by-target → exit 2"
(
  V=$(setup_vault_from_fixture lifecycle-superseded-broken-by)
  cd "$V"; rc=$(node "$VALIDATE" all 2>&1 >/dev/null; echo $?)
  assert_eq "exit" "2" "$rc"
)

echo "==> lifecycle: stub with empty sources still passes frontmatter rule"
(
  V=$(setup_vault_from_fixture lifecycle-stub-sources-empty-ok)
  cd "$V"; rc=$(node "$VALIDATE" all 2>&1 >/dev/null; echo $?)
  assert_eq "exit" "0" "$rc"
)
```

If the helper `setup_vault_from_fixture` does not already exist in `tests/test_validate_wiki.sh`, copy the pattern used by other test files (`cp -R "$REPO_ROOT/tests/fixtures/validate-wiki/<name>" "$TEST_DIR/<name>"; ( cd ...; git init -q ...; ); echo "$path"`).

- [ ] **Step 4: Run the validate-wiki tests — new cases fail**

Run: `bash tests/test_validate_wiki.sh`
Expected: the four valid + the empty-sources case currently FAIL because the validator doesn't recognize `lifecycle:` shape OR rejects empty `sources:` on the stubs. The three error cases also FAIL because the validator currently passes them (lifecycle shape isn't enforced).

- [ ] **Step 5: Add the lifecycle rule to `scripts/validate-wiki.js`**

Add a new function `validateLifecycle(vault, opts)` modelled after the existing `validateFrontmatter`. Pseudocode (slot into the script's structure; the surrounding `parseFrontmatter`/`loadContract` helpers are reused):

```js
const ALLOWED_LIFECYCLE_STATES = new Set(['historical', 'superseded', 'archived']);

function validateLifecycle(vault, opts) {
  const errors = [];
  const pages = enumerateTargetPages(vault);   // existing helper from frontmatter rule
  for (const rel of pages) {
    const abs = path.join(vault, rel);
    const fm = readFrontmatter(abs);            // existing helper
    if (!fm || !fm.lifecycle) continue;
    const lc = fm.lifecycle;
    if (typeof lc !== 'object' || Array.isArray(lc)) {
      errors.push({ path: rel, msg: 'lifecycle must be a mapping' });
      continue;
    }
    if (!ALLOWED_LIFECYCLE_STATES.has(lc.state)) {
      errors.push({ path: rel, msg: `lifecycle.state must be historical|superseded|archived, got ${JSON.stringify(lc.state)}` });
      continue;
    }
    if (lc.state === 'historical') {
      if (typeof lc.since !== 'string' || !/^\d{4}-\d{2}$/.test(lc.since)) {
        errors.push({ path: rel, msg: 'lifecycle.since must be YYYY-MM when state=historical' });
      }
    } else if (lc.state === 'superseded') {
      if (typeof lc.by !== 'string') {
        errors.push({ path: rel, msg: 'lifecycle.by must be a string when state=superseded' });
      } else if (!fs.existsSync(path.join(vault, lc.by))) {
        errors.push({ path: rel, msg: `lifecycle.by target does not exist: ${lc.by}` });
      }
    } else if (lc.state === 'archived') {
      if (typeof lc.original !== 'string') {
        errors.push({ path: rel, msg: 'lifecycle.original must be a string when state=archived' });
      } else if (!fs.existsSync(path.join(vault, lc.original))) {
        errors.push({ path: rel, msg: `lifecycle.original target does not exist: ${lc.original}` });
      }
    }
  }
  return errors;
}
```

Wire it into the subcommand dispatch:

```js
case 'lifecycle': {
  const errs = validateLifecycle(vault, opts);
  if (opts.json) { process.stdout.write(JSON.stringify({ errors: errs }, null, 2) + '\n'); process.exit(errs.length ? 2 : 0); }
  for (const e of errs) process.stderr.write(`lifecycle: ${e.path}: ${e.msg}\n`);
  process.exit(errs.length ? 2 : 0);
}
```

And include `lifecycle` in the `all` aggregation (run after the existing rules; cumulative exit code).

- [ ] **Step 6: Exempt stub-redirect pages from the `sources: may_be_empty: false` rule**

Locate the frontmatter validator's check on `sources` (likely inside `validateFrontmatter`, where it enforces `may_be_empty: false`). Add a precondition:

```js
// If the page declares lifecycle.state == 'superseded', the may_be_empty rule
// on `sources:` does not apply — the stub inherits its source list from the
// archived target.
if (rule.may_be_empty === false && (!value || value.length === 0)) {
  const lc = fm.lifecycle;
  if (lc && lc.state === 'superseded') {
    // exempt
  } else {
    errors.push({ path: rel, msg: `sources must not be empty` });
  }
}
```

- [ ] **Step 7: Run the validate-wiki tests — all pass**

Run: `bash tests/test_validate_wiki.sh`
Expected: every new case PASSes.

- [ ] **Step 8: Run the full test suite (incl. apply-archive's Task 12 step-6 link integrity test)**

Run: `bash tests/test_staleness.sh && bash tests/test_validate_wiki.sh`
Expected: both green. Task 12's inbound-link check now actually exercises the validator's lifecycle rule against real apply-archive output.

- [ ] **Step 9: Commit**

```bash
git add scripts/validate-wiki.js tests/test_validate_wiki.sh tests/fixtures/validate-wiki/lifecycle-*
git commit -m "feat(validate-wiki): lifecycle rule + sources exemption for stubs"
```

---

## Task 16: Update `scripts/status.js` `readStaleness()`

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`
- Create: `tests/fixtures/status/staleness-unjudged-counted/`
- Create: `tests/fixtures/status/staleness-mixed-statuses/`

Two-line behaviour change: count `status: unjudged` entries into `unjudged_candidates` (currently hardcoded 0); the `unreviewed` → `unresolved_high|medium` logic stays.

- [ ] **Step 1: Create the two new status fixtures**

```bash
mkdir -p tests/fixtures/status/staleness-unjudged-counted/wiki/.state
cp tests/fixtures/status/staleness-populated/wiki/.state/sources.yaml tests/fixtures/status/staleness-unjudged-counted/wiki/.state/
cp tests/fixtures/status/staleness-populated/wiki/.state/frontmatter-contract.yaml tests/fixtures/status/staleness-unjudged-counted/wiki/.state/
cat > tests/fixtures/status/staleness-unjudged-counted/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    status: unjudged
  - id: 2026-05-25-002
    path: wiki/concepts/b.md
    signal: medium
    status: unjudged
YAML

mkdir -p tests/fixtures/status/staleness-mixed-statuses/wiki/.state
cp tests/fixtures/status/staleness-populated/wiki/.state/sources.yaml tests/fixtures/status/staleness-mixed-statuses/wiki/.state/
cp tests/fixtures/status/staleness-populated/wiki/.state/frontmatter-contract.yaml tests/fixtures/status/staleness-mixed-statuses/wiki/.state/
cat > tests/fixtures/status/staleness-mixed-statuses/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    status: unreviewed
  - id: 2026-05-25-002
    path: wiki/concepts/b.md
    signal: medium
    status: unreviewed
  - id: 2026-05-25-003
    path: wiki/concepts/c.md
    signal: high
    status: deferred
  - id: 2026-05-25-004
    path: wiki/concepts/d.md
    signal: high
    status: dismissed
  - id: 2026-05-25-005
    path: wiki/concepts/e.md
    signal: high
    status: resolved
    resolution: refreshed
YAML
```

- [ ] **Step 2: Add the two test cases to `tests/test_status.sh`**

Append following the existing pattern (the file already has a helper for setting up fixtures + reading `--json`):

```bash
echo "==> staleness.unjudged_candidates reflects status: unjudged"
(
  V=$(setup_status_vault staleness-unjudged-counted)
  cd "$V"
  v=$(node "$REPO_ROOT/scripts/status.js" --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.staleness.unjudged_candidates))")
  assert_eq "unjudged_candidates" "2" "$v"
)

echo "==> staleness mixed: only unreviewed surfaces in unresolved counts"
(
  V=$(setup_status_vault staleness-mixed-statuses)
  cd "$V"
  json=$(node "$REPO_ROOT/scripts/status.js" --json)
  high=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.staleness.unresolved_high))")
  med=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.staleness.unresolved_medium))")
  unj=$(echo "$json" | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.staleness.unjudged_candidates))")
  assert_eq "unresolved_high (only unreviewed counts)" "1" "$high"
  assert_eq "unresolved_medium" "1" "$med"
  assert_eq "no unjudged" "0" "$unj"
)
```

- [ ] **Step 3: Run the status tests — first new case fails (unjudged_candidates hardcoded 0)**

Run: `bash tests/test_status.sh`
Expected: `staleness-unjudged-counted` FAILs with `expected 2, actual 0`.

- [ ] **Step 4: Update `scripts/status.js` `readStaleness()` (replace the existing function)**

```js
function readStaleness(vault) {
  const doc = readStateYaml(vault, 'staleness.yaml');
  if (!doc) return {
    unjudged_candidates: 0,
    unresolved_high: 0,
    unresolved_medium: 0,
    present: false,
  };
  const entries = Array.isArray(doc.pages) ? doc.pages : [];
  let unjudged = 0, unresolved_high = 0, unresolved_medium = 0;
  for (const e of entries) {
    if (!e) continue;
    if (e.status === 'unjudged') {
      unjudged += 1;
    } else if (e.status === 'unreviewed') {
      if (e.signal === 'high')   unresolved_high   += 1;
      if (e.signal === 'medium') unresolved_medium += 1;
    }
  }
  return { unjudged_candidates: unjudged, unresolved_high, unresolved_medium, present: true };
}
```

- [ ] **Step 5: Run the status tests — both pass**

Run: `bash tests/test_status.sh`
Expected: green.

- [ ] **Step 6: Commit**

```bash
git add scripts/status.js tests/test_status.sh tests/fixtures/status/staleness-unjudged-counted tests/fixtures/status/staleness-mixed-statuses
git commit -m "feat(status): count staleness.unjudged_candidates from yaml"
```

---

## Task 17: Migrate `tests/fixtures/status/staleness-populated/` to the new status taxonomy

**Files:**
- Modify: `tests/fixtures/status/staleness-populated/wiki/.state/staleness.yaml`

The existing fixture uses the legacy shape (`status: unreviewed | reviewed`, no `judgment`/`resolution`). Rewrite it using the spec's five-status enum so the existing `test_status.sh` cases that read this fixture continue to make sense.

- [ ] **Step 1: Inspect what the existing test asserts about this fixture**

```bash
grep -n "staleness-populated" tests/test_status.sh
```

Note what counts the test expects (`unresolved_high`, `unresolved_medium`, possibly `unjudged_candidates` after Task 16).

- [ ] **Step 2: Rewrite the fixture**

```bash
cat > tests/fixtures/status/staleness-populated/wiki/.state/staleness.yaml <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-20-001
    path: wiki/concepts/old-thing-1.md
    signal: high
    status: unreviewed
  - id: 2026-05-20-002
    path: wiki/concepts/old-thing-2.md
    signal: high
    status: unreviewed
  - id: 2026-05-20-003
    path: wiki/concepts/old-thing-3.md
    signal: high
    status: unreviewed
  - id: 2026-05-20-004
    path: wiki/concepts/mid-thing-1.md
    signal: medium
    status: unreviewed
  - id: 2026-05-20-005
    path: wiki/concepts/mid-thing-2.md
    signal: medium
    status: unreviewed
  - id: 2026-05-20-006
    path: wiki/concepts/low-thing.md
    signal: low
    status: unjudged
  - id: 2026-05-20-007
    path: wiki/concepts/reviewed-high.md
    signal: high
    status: resolved
    resolution: refreshed
YAML
```

Counts match the old expectations: 3 high unreviewed, 2 medium unreviewed. New: 1 unjudged_candidates (the `low-thing`), 1 resolved (replacing `reviewed`).

- [ ] **Step 3: Run the status tests — all pass**

Run: `bash tests/test_status.sh`
Expected: green (Task 16's tests + the existing populated fixture).

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/status/staleness-populated
git commit -m "test(status): migrate staleness-populated fixture to new status taxonomy"
```

---

## Task 18: Replace `/status refresh` placeholder in `skills/status/SKILL.md`

**Files:**
- Modify: `skills/status/SKILL.md`

Replace the current placeholder body (line ~221 — *"/status refresh is not yet available..."*) with two new sections: the interactive sub-flow and the `--judge-only` headless body. Mirror the structure of the `/status reconcile` sections CR-007 already shipped (look at line ~78 and ~157 in the same file for the template). Bump `allowed-tools` if not already including `Write`.

- [ ] **Step 1: Confirm current frontmatter**

```bash
head -n 10 skills/status/SKILL.md
```

If `allowed-tools` does not include `Write`, plan to add it (CR-007 likely already did this for reconcile — verify).

- [ ] **Step 2: Replace the placeholder block with the two new sub-flows**

Open `skills/status/SKILL.md`. Locate the section that begins with the literal text `/status refresh is not yet available. CR-008 will implement staleness review.` Replace that entire section with the following two top-level subsections (mirroring the structure already used by `/second-brain:status reconcile (interactive)` and `/second-brain:status reconcile --judge-only (headless)`):

````markdown
## `/second-brain:status refresh` (interactive)

Walks staleness candidates that the judge pass has marked as needing human action.

1. **Determine scope.** Default filter:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" list \
     --status=unreviewed --signal=high --json
   ```

   If the user passed `--all` (anywhere on the invocation), expand to `--signal=high,medium` and include `verdict: drifting` entries (these are computed from each entry's `judgment.verdict`). Always exclude `dismissed` and `deferred` from default scope; the user must pass `--include-deferred` to see them.

2. **If the list is empty, print `nothing to refresh` and stop.**

3. **Pre-compute rewrites.** For each in-scope entry, read its `path` and `judgment.neighbors_examined`, plus the entries in `wiki/.state/sources.yaml` that this page's entities show up in (sources newer than the page's `mtime`). Write a rewrite tmpfile at `/tmp/refresh-<id>.md` containing the rewritten page — preserve the page's existing frontmatter exactly (only the body changes), and end with an updated `updated:` date. This tmpfile is what `apply-refresh` will atomically replace the page with.

4. **Walk the entries.** For each in-scope entry, print one display block:

   ```
   [N] wiki/concepts/<path>.md  (age <factors.age_months>mo, <factors.newer_overlapping_sources> newer sources)
       <judgment.verdict>: <judgment.reason>
   ```

   Then prompt the user one of: `R / A / H / D / S` (refresh / archive / historical / defer / skip).

   - **R (refresh):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" apply-refresh \
       --id=<id> --rewrite=/tmp/refresh-<id>.md
     ```

     On exit 2 (validate-wiki failed; auto-reverted), report the validator's error to the user verbatim. The entry stays `unreviewed` and will appear in the next walk.

   - **A (archive):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" apply-archive --id=<id>
     ```

   - **H (historical):** Ask the user inline for `since:` (default current `YYYY-MM`), then:

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" apply-historical \
       --id=<id> --since=<YYYY-MM>
     ```

   - **D (defer):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" resolve \
       --id=<id> --kind=defer
     ```

   - **S (skip):** make no script call; move to the next entry.

5. **Group git commit at the end of the walk.** After all entries are processed, if any wiki/archive file changed:

   ```bash
   git -C "<vault>" add -A wiki/
   git -C "<vault>" commit -m "refresh: N refreshed, M archived, K historical, J deferred"
   ```

6. **Append one summary line to `wiki/log.md`:**

   ```
   ## YYYY-MM-DD refresh | N refreshed, M archived, K historical, J deferred
   ```

7. **Do NOT append to `since-review.yaml`.** The user was present; per CR-009's review-log contract interactive resolutions are not logged to the inbox.

## `/second-brain:status refresh --judge-only` (headless)

Cron-safe entry. No prompts; drains `status: unjudged` into one of four verdict buckets.

1. **Read all unjudged entries.**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" list --status=unjudged --json
   ```

2. **For each entry, sample up to 5 neighbours.** Find wiki pages whose `mtime` is newer than this page's `mtime` AND that share at least one entity wikilink. One hop only. If fewer than 5 candidates exist, take what is available; if zero, judge with just the page (likely verdict: `false-positive` or `fresh-but-isolated`).

3. **Read the page body + the sampled neighbour bodies + the entry's `factors` block.** Decide a verdict: `stale | drifting | fresh-but-isolated | false-positive`. Compose a one-sentence reason.

4. **Persist the verdict:**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" judge \
     --id=<id> --verdict=<v> \
     --data='{"reason":"<one sentence>","neighbors_examined":["wiki/...","wiki/..."]}'
   ```

5. **Append a review-log entry per CR-009 contract:**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" append \
     --kind=staleness-judged \
     --data='{"page":"<path>","verdict":"<v>"}'
   ```

6. **Exit when the list is drained.** No `wiki/log.md` entry (no human action took place). The Stop hook will not run on `--headless` invocations, so no validate-wiki pass is triggered here either.
````

- [ ] **Step 3: Commit**

```bash
git add skills/status/SKILL.md
git commit -m "feat(status): /status refresh interactive + --judge-only bodies"
```

(No automated test for SKILL.md content beyond reading the file — the script-level tests Tasks 9–13 already cover every command the SKILL invokes.)

---

## Task 19: Replace `skills/lint/SKILL.md` §3 ("Stale claims") with script calls

**Files:**
- Modify: `skills/lint/SKILL.md`

The current §3 instructs the LLM to do prose-based cross-referencing, which violates conventions §4. Replace with deterministic `staleness.js candidates` + `list` invocations, mirroring how §2 was rewritten for contradictions in CR-007.

- [ ] **Step 1: Locate the current §3**

```bash
grep -n "^### 3\." skills/lint/SKILL.md
```

- [ ] **Step 2: Replace the §3 body**

Replace everything between `### 3. Stale claims` (inclusive of the heading) and the next `### 4.` heading with:

````markdown
### 3. Stale claims

Staleness-finding flows through `scripts/staleness.js`. Lint performs the full-vault candidate scan (enqueueing newly-flagged pages into `wiki/.state/staleness.yaml` as `status: unjudged`) and reports the lifecycle counts back to the user.

```bash
# Full-vault scan: enqueue any newly-detected high/medium-signal pages.
node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" candidates --scope=wiki/
```

```bash
# Report counts across the lifecycle.
node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" list \
  --status=unjudged,unreviewed,deferred --json
```

Tally counts by `status` (and by `signal` for the `unreviewed` slice) and surface them under "Warnings":

```
Staleness: N unjudged, M unreviewed (P high, Q medium), K deferred.
Run /second-brain:status refresh (interactive) or schedule
--judge-only via cron.
```

Do **not** read pages for staleness in this step — the script narrows candidates deterministically and the LLM judge pass (`/second-brain:status refresh --judge-only`) does the prose-level filtering. Lint is the trigger for the full-vault scan; the judge pass is asynchronous.
````

- [ ] **Step 3: Commit**

```bash
git add skills/lint/SKILL.md
git commit -m "feat(lint): swap §3 prose for staleness script calls"
```

---

## Task 20: Insert `/query` step 3a — lifecycle/staleness check

**Files:**
- Modify: `skills/query/SKILL.md`

Insert a new step between current "3. Read relevant pages" and "4. Check originals for verification or depth". The new step calls `staleness.js check` over the cited pages and prepends a warning to the answer when `warnings[]` is non-empty.

- [ ] **Step 1: Locate the insertion point**

```bash
grep -n "^### " skills/query/SKILL.md
```

- [ ] **Step 2: Insert the new step**

Add (between current §3 and §4):

````markdown
### 3a. Check lifecycle and staleness

Before composing the answer, check whether any cited page is marked historical/superseded/archived in its frontmatter, or flagged as `signal: high AND status: unreviewed` in `wiki/.state/staleness.yaml`. The script does the lookup:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" check \
  --pages=<comma-separated vault-relative paths> --json
```

The response shape:

```json
{
  "warnings": [
    { "path": "wiki/concepts/foo.md", "kind": "historical", "since": "2024-05" },
    { "path": "wiki/concepts/bar.md", "kind": "stale-high",
      "factors": { "age_months": 24, "newer_overlapping_sources": 12 } }
  ]
}
```

`kind` values: `historical | superseded | archived | stale-high`. Medium-signal staleness is intentionally not warned (too noisy for query-time).

If `warnings` is non-empty, prepend a single one-line callout to the answer summarising affected pages by kind. Example:

> Note: this answer cites 1 historical page (2024-05) and 1 page flagged stale-high. Newer information may exist.

Do not block the answer — the user still gets the synthesis, only with the freshness caveat in front.
````

- [ ] **Step 3: Commit**

```bash
git add skills/query/SKILL.md
git commit -m "feat(query): lifecycle/staleness warning via staleness.js check"
```

---

## Task 21: Update `skills/status/references/status-json-schema.md`

**Files:**
- Modify: `skills/status/references/status-json-schema.md`

The `staleness` section currently flags the keys as "owned by CR-008" / "always 0 in CR-009". Drop the caveats; document the live predicates.

- [ ] **Step 1: Locate the staleness section**

```bash
grep -n "staleness" skills/status/references/status-json-schema.md
```

- [ ] **Step 2: Replace the staleness section body**

Replace the existing `### \`staleness\`` section with:

````markdown
### `staleness`

Read from `wiki/.state/staleness.yaml` (owned by `scripts/staleness.js`, CR-008).

| Key | Predicate |
|---|---|
| `unjudged_candidates` | Count of `pages[]` entries with `status: unjudged`. The candidate scan has flagged them; the LLM judge has not yet run. |
| `unresolved_high` | Count of `pages[]` entries with `status: unreviewed AND signal: high`. The judge ran with verdict `stale` or `drifting`; the user has not yet acted. |
| `unresolved_medium` | Count of `pages[]` entries with `status: unreviewed AND signal: medium`. |
| `present` | `true` when `staleness.yaml` exists and parses; `false` when missing. |

`status: resolved | deferred | dismissed` entries are not surfaced in any count.

Cron pattern:
- If `unjudged_candidates > 0`, fire `/second-brain:status refresh --judge-only`.
- If `unresolved_high + unresolved_medium > 0`, surface as "needs you" in the human dashboard and leave for the next interactive session.
````

- [ ] **Step 3: Commit**

```bash
git add skills/status/references/status-json-schema.md
git commit -m "docs(status): document live staleness JSON predicates"
```

---

## Task 22: Update `docs/install/headless-driving.md` + `docs/cr/CR-008-staleness-review.md`

**Files:**
- Modify: `docs/install/headless-driving.md`
- Modify: `docs/cr/CR-008-staleness-review.md`

The cron example already includes the `refresh --judge-only` call; the surrounding prose still says it's a no-op. Flip to live. Then add a "Status" note to the CR doc marking it implemented.

- [ ] **Step 1: Locate the no-op note in headless-driving**

```bash
grep -n "no-op\|still a no-op\|CR-008" docs/install/headless-driving.md
```

- [ ] **Step 2: Update the prose**

Replace the sentence(s) that say `refresh --judge-only` is a no-op with:

```
The `refresh --judge-only` call is live; CR-008's judge pass runs against
unjudged candidates and writes verdicts back. Combined with the
`candidates` call wired into `/second-brain:lint`, the headless pipeline
keeps the staleness inbox drained.
```

- [ ] **Step 3: Add a status note to the CR doc**

Insert immediately under the `# CR-008` heading:

```
**Status:** implemented (2026-05-25). Spec: [`docs/superpowers/specs/2026-05-25-cr-008-staleness-review-design.md`](../superpowers/specs/2026-05-25-cr-008-staleness-review-design.md). Plan: [`docs/superpowers/plans/2026-05-25-cr-008-staleness-review.md`](../superpowers/plans/2026-05-25-cr-008-staleness-review.md).
```

- [ ] **Step 4: Commit**

```bash
git add docs/install/headless-driving.md docs/cr/CR-008-staleness-review.md
git commit -m "docs(install): note CR-008 refresh --judge-only is live"
```

---

## Self-review

**Spec coverage check** (cross-referencing the spec):

| Spec section | Plan task(s) |
|---|---|
| §4 architecture (one script, one state file, exit codes) | Task 1, Task 2 |
| §5 signals + thresholds | Tasks 4, 5, 6 |
| §6 state file shape + status enum + transitions | Tasks 2, 9, 10, 11, 12, 13 |
| §6 auto-defer (Δ > 0.1) | Task 7 |
| §7 `candidates` subcommand | Tasks 4, 5, 6, 7, 8 |
| §7 `list` | Task 3 |
| §7 `judge` | Task 9 |
| §7 `resolve --kind defer` | Task 10 |
| §7 `apply-refresh` | Task 11 |
| §7 `apply-archive` (dual lifecycle) | Task 12 |
| §7 `apply-historical` | Task 13 |
| §7 `check` | Task 14 |
| §8 `/status refresh` interactive sub-flow | Task 18 |
| §9 `--judge-only` headless | Task 18 |
| §10 lint §3 rewrite | Task 19 |
| §11 query §3a insertion | Task 20 |
| §12 validate-wiki lifecycle rule + sources exemption | Task 15 |
| §13 `scripts/status.js` two-line fix | Task 16 |
| §14 reference doc updates (headless-driving + status JSON schema + CR doc) | Tasks 21, 22 |
| §15 test scenarios (candidates / list / judge / resolve / apply-* / check / schema-mismatch / lifecycle validator / status JSON) | Tasks 2–17 (one per scenario family) |
| §16 risks — documented in spec, no plan action needed | n/a |
| §17 deferred — explicitly not implemented | n/a |
| §18 out of scope — explicitly not implemented | n/a |

All spec sections covered.

**Placeholder scan:** No `TBD`, `TODO`, `Add appropriate ...`, or "Similar to Task N" references. Every code block is complete.

**Type / signature consistency check:**
- `score` formula is `age_percentile × moved_past_percentile` in every place it is computed (Tasks 4, 7, 9, 10, 11, 12, 13). ✓
- Status enum values used identically across all `cmd*` functions and all tests: `unjudged | unreviewed | resolved | deferred | dismissed`. ✓
- `judgment.verdict` enum used identically: `stale | drifting | fresh-but-isolated | false-positive`. ✓
- `resolution` enum used identically: `refreshed | archived | historical`. ✓
- `lifecycle.state` enum used identically: `historical | superseded | archived`. Required sub-keys match between Task 12 (writes), Task 13 (writes historical), Task 14 (reads), Task 15 (validates). ✓
- `staleness.yaml` schema (`schema_version`, `generated_by`, `scanned_at`, `vault_page_count`, `pages[]`) is consistent across Tasks 2, 4, 7. ✓
- Subcommand surface — Task 1's skeleton declares all 8 subcommands; every later task implements one of them; no extras. ✓
- Exit codes — `2` for input/parse/validate-failure-after-revert, `3` for invariant refusal with no mutation. Tasks 9, 10, 11, 12, 13 all follow. ✓

No issues.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-25-cr-008-staleness-review.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for a 22-task plan because each task is self-contained (tests + impl + commit in one shot) and the spec doesn't require cross-task coordination beyond what's in the file.

2. **Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints for review.

Which approach?

