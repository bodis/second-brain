# CR-007 Contradiction Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the contradiction-detection pipeline that fills the `/second-brain:status reconcile` placeholder CR-009 left behind. Deterministic candidate scan + LLM judge pass + interactive user-resolution loop, persisted in `wiki/.state/contradictions.yaml`.

**Architecture:** One new state-owning script at `scripts/contradictions.js` with six subcommands (`candidates`, `list`, `judge`, `resolve`, `apply-pick`, `apply-accept`). Two deterministic signals — `conflicting-relations` (frontmatter overlap-divergence) and `shared-entity-prose` (body wikilink overlap). Three skill touches: status (sub-flow bodies), ingest (incremental candidate scan), lint (full-vault scan + count reporter). No new dependencies; reuses `js-yaml` 4.x.

**Tech Stack:** Node ≥18 (CommonJS, no build step), `js-yaml` 4.x with CORE_SCHEMA for YAML I/O, bash test harness matching `tests/test_status.sh` / `tests/test_review_log.sh`.

**Reference spec:** [`docs/superpowers/specs/2026-05-24-cr-007-contradiction-detection-design.md`](../specs/2026-05-24-cr-007-contradiction-detection-design.md). CR: [`docs/cr/CR-007-contradiction-detection.md`](../../cr/CR-007-contradiction-detection.md). Conventions: [`docs/cr/conventions.md`](../../cr/conventions.md).

---

## File Structure

**Create:**
- `scripts/contradictions.js` — state-owning script for `wiki/.state/contradictions.yaml`. ~600 lines. Subcommands: `candidates`, `list`, `judge`, `resolve` (defer-only), `apply-pick`, `apply-accept`. Atomic writes (tmpfile + rename). Shells out to `git` and `scripts/validate-wiki.js`.
- `tests/test_contradictions.sh` — integration tests, ~24 cases mirroring `tests/test_review_log.sh` shape.
- `tests/fixtures/contradictions/signal-1-conflicting-relations/` — fixture with two pages whose `relations.refines:` lists overlap and diverge.
- `tests/fixtures/contradictions/signal-2-shared-entity-prose/` — fixture with two concept pages sharing entity wikilinks in body prose.
- `tests/fixtures/contradictions/dedupe/` — fixture used to test re-scan dedup against an existing yaml.
- `tests/fixtures/contradictions/judge-input/` — minimal vault with one unjudged entry, used for judge / list-filter tests.
- `tests/fixtures/contradictions/apply-pick-input/` — vault with one `unresolved` entry, two pages, and one quoted-assertion that the rewrite swaps.
- `tests/fixtures/contradictions/apply-accept-input/` — vault with one `unresolved` entry; tests that both pages gain `relations.contradicts`.
- `tests/fixtures/contradictions/schema-mismatch/` — vault with `contradictions.yaml` carrying `schema_version: 0`.

**Modify:**
- `scripts/status.js` — update `readContradictions()` to count `status: unjudged` as `unjudged_candidates` and `unresolved + deferred` as `unresolved`.
- `skills/status/SKILL.md` — replace the `/status reconcile` placeholder with the interactive sub-flow body; add the `--judge-only` headless body; bump `allowed-tools` to include `Write` (for tmpfiles).
- `skills/ingest/SKILL.md` — insert a new step "10. Scan for contradiction candidates" after the existing step 9 ("Append a review-log entry"); renumber old step 10 ("Report results") to 11.
- `skills/lint/SKILL.md` — replace §2 ("Contradictions") prose with deterministic script calls.
- `skills/status/references/status-json-schema.md` — update the `contradictions` section: drop the "always 0 in CR-009" / "until CR-007 lands" caveats; document the lifecycle predicates (`unjudged_candidates` = `unjudged`; `unresolved` = `unresolved + deferred`).
- `docs/install/headless-driving.md` — change "no-ops until CR-007/008 land" to "no-ops until CR-008 lands; CR-007 is live."

**Decisions locked in:**

- **Signal 1 algorithm is "overlap-divergence on shared relation key."** The spec §6.4 sketch was ambiguous because CR-005's `relations:` describes outgoing edges from the page itself (not third-party claims). The implementable cheap interpretation: two pages where the same `relations.<R>` key has partly-overlapping, partly-diverging value lists. Captures near-duplicate pages making slightly different typed claims. LLM filters the always-noisy ones. The spec example's `signal_data` shape adjusts to `{relation, shared_targets, a_only_targets, b_only_targets}`.
- **Signal 2 threshold N=5 total shared wikilinks.** Plan-time choice per spec §6.4; tunable in code if shortlists prove too noisy.
- **One ID counter per day.** `YYYY-MM-DD-NNN`. The script reads existing entries, finds the max NNN for today's date string, allocates `max+1` zero-padded to 3 digits. Tomorrow restarts at 001.
- **Atomic YAML write only — no lock file.** Same as `review-log.js`. Single-machine, single-user; sub-second concurrent-write window is acceptable per CR-009 §6.4.
- **`apply-pick` / `apply-accept` own the full transaction.** File edit → git commit → `validate-wiki.js all` → on success, atomic yaml update. On post-check exit 2, auto-revert the commit and leave the yaml unchanged (entry stays `unresolved`/`deferred`). On precondition or substring-invariant failure, exit 3 with no mutation. The SKILL is prompt-only — never touches wiki files directly.
- **K=50 neighbour-expansion cap.** Hard cap in `candidates --scope=<page-list>` for ingest's incremental scope. Above K, expansion truncates and stderr-warns (exit 0). Hub-touching is a lint concern, not an ingest concern.
- **CORE_SCHEMA for YAML reads.** All yaml loads use `{schema: yaml.CORE_SCHEMA}` to match the project-wide convention from `validate-wiki.js`/`review-log.js`.
- **`apply-pick`'s commit message includes the claim text.** `reconcile: pick <winning> over <losing> on <claim>` — gives a readable git log without needing to dereference `contradictions.yaml`. `apply-accept`'s message is `reconcile: accept-disagreement on <claim>`.
- **Lint becomes a (small) state mutator.** Lint's full-vault `candidates` call enqueues new pairs into `contradictions.yaml`. The single-source-of-truth queue stays consistent; the spec §12 risks calls this out and the user opted in during brainstorm.

---

## Task 1: `scripts/contradictions.js` skeleton + test harness + outside-vault test

**Files:**
- Create: `scripts/contradictions.js`
- Create: `tests/test_contradictions.sh`

Get the script callable, the test harness running, and the outside-vault and unknown-subcommand tests green. No subcommand logic yet — main() dispatches but every subcommand throws.

- [ ] **Step 1: Create `tests/test_contradictions.sh` with the harness + first two cases**

```bash
#!/bin/bash
set -e

# Test: scripts/contradictions.js — contradictions state-owner.
# Usage: bash tests/test_contradictions.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/contradictions.js"
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

# Make a minimal vault: git-init, sources.yaml, frontmatter-contract.yaml.
# Args: $1 = name. Echoes the absolute path.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state" "$v/wiki/entities" "$v/wiki/concepts"
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
  (cd "$v" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
  echo "$v"
}

echo "=== Test: contradictions.js ==="

# Test: outside any vault → exit 2 with helpful message.
echo ""
echo "Test: outside any vault → exit 2"
OUTSIDE_DIR="$TEST_DIR/not-a-vault"
mkdir -p "$OUTSIDE_DIR"
set +e
OUT=$( (cd "$OUTSIDE_DIR" && node "$SCRIPT" list 2>&1) )
EXIT=$?
set -e
assert_eq "exit code 2" "2" "$EXIT"
case "$OUT" in
  *"not in a second-brain vault"*)
    echo "  PASS: stderr names the problem"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not say 'not in a second-brain vault' — got: $OUT"
    FAIL=$((FAIL + 1));;
esac

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
chmod +x tests/test_contradictions.sh
bash tests/test_contradictions.sh
```

Expected: FAIL with "Cannot find module" (the script doesn't exist yet).

- [ ] **Step 3: Create `scripts/contradictions.js` skeleton**

```javascript
#!/usr/bin/env node
'use strict';

/**
 * scripts/contradictions.js — owner of wiki/.state/contradictions.yaml.
 *
 * Subcommands:
 *   candidates --scope <dir-or-page-list> [--json]
 *   list [--status <comma-list>] [--json]
 *   judge --id <id> --verdict <real-contradiction|not-a-contradiction> --data <json>
 *   resolve --id <id> --kind defer
 *   apply-pick --id <id> --winning-page <vault-path> --rewrite <tmpfile>
 *   apply-accept --id <id>
 *
 * Exit codes:
 *   0 = clean
 *   2 = vault not found / malformed yaml / missing required arg / malformed --data /
 *       validate-wiki post-check failure after auto-revert / unsupported subcommand or kind
 *   3 = invariant refusal (invalid lifecycle transition, substring not unique, etc.) —
 *       no mutation occurred
 *
 * Vault detection: walks up for both .git/ and wiki/.state/sources.yaml,
 * matching status.js / validate-wiki.js / review-log.js.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const yaml = require('js-yaml');

const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/contradictions.js';
const STATE_FILE = 'wiki/.state/contradictions.yaml';

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

// Parse `--flag=value`, `--flag value`, and `--flag` (boolean). Returns
// { _: positional[], <flag>: <value> }. Unknown args cause exit 2.
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      if (eq > 0) {
        out[a.slice(2, eq)] = a.slice(eq + 1);
      } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
        out[a.slice(2)] = argv[++i];
      } else {
        out[a.slice(2)] = true;
      }
    } else {
      out._.push(a);
    }
  }
  return out;
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) die('usage: contradictions.js <subcommand> [args]', 2);
  const cmd = argv[0];
  const args = parseArgs(argv.slice(1));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  switch (cmd) {
    case 'candidates':   die('candidates: not implemented yet', 2);
    case 'list':         die('list: not implemented yet', 2);
    case 'judge':        die('judge: not implemented yet', 2);
    case 'resolve':      die('resolve: not implemented yet', 2);
    case 'apply-pick':   die('apply-pick: not implemented yet', 2);
    case 'apply-accept': die('apply-accept: not implemented yet', 2);
    default:             die(`unknown subcommand: ${cmd}`, 2);
  }
}

main();
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: 3 PASS, 0 FAIL.

- [ ] **Step 5: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh
git commit -m "$(cat <<'EOF'
feat(contradictions): scaffold contradictions.js with vault detection

Adds scripts/contradictions.js with subcommand dispatch and vault
resolution matching status.js / review-log.js. All subcommands stub to
exit 2 ("not implemented yet"); the next tasks wire them up one by one.

tests/test_contradictions.sh follows the test_review_log.sh shape (temp
dir, inline assertions, make_vault helper). Outside-vault and
unknown-subcommand cases land first; remaining cases follow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `list` subcommand

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`

The `list` subcommand reads `contradictions.yaml`, applies an optional `--status` filter, and emits either a grouped human summary (default) or the full file as JSON (`--json`). Missing file → empty output, exit 0.

- [ ] **Step 1: Add tests for `list` (empty, populated, filter, --json)**

Insert these blocks before the final `=== Results ===` print in `tests/test_contradictions.sh`:

```bash
# Test: list on missing file → empty output, exit 0.
echo ""
echo "Test: list on missing file → empty output"
V_LIST_EMPTY=$(make_vault vault-list-empty)
set +e
OUT=$( (cd "$V_LIST_EMPTY" && node "$SCRIPT" list 2>&1) )
EXIT=$?
set -e
assert_eq "exit 0 when state file absent" "0" "$EXIT"

# Test: list --json on missing file → empty contradictions array, exit 0.
echo ""
echo "Test: list --json on missing file → empty array"
OUT=$( (cd "$V_LIST_EMPTY" && node "$SCRIPT" list --json 2>&1) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "list --json returns empty array" "0" "$COUNT"

# Test: list --json on populated file → returns entries.
echo ""
echo "Test: list --json on populated file"
V_LIST=$(make_vault vault-list)
cat > "$V_LIST/wiki/.state/contradictions.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  - id: 2026-05-19-001
    detected_at: 2026-05-19T10:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [foo], a_only_targets: [], b_only_targets: [bar] }
    status: unjudged
  - id: 2026-05-18-007
    detected_at: 2026-05-18T03:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [foo], a_only_targets: [], b_only_targets: [bar] }
    status: unresolved
    judgment:
      verdict: real-contradiction
      at: 2026-05-18T04:00:00Z
      claim: "Acquirer of Foo"
      assertions: []
      rationale: "..."
YAML
OUT=$( (cd "$V_LIST" && node "$SCRIPT" list --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "list --json on populated returns 2 entries" "2" "$COUNT"

# Test: list --status=unjudged → filters to single entry.
echo ""
echo "Test: list --status filter"
OUT=$( (cd "$V_LIST" && node "$SCRIPT" list --status=unjudged --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "list --status=unjudged returns 1 entry" "1" "$COUNT"

# Test: list --status with comma-list → union filter.
OUT=$( (cd "$V_LIST" && node "$SCRIPT" list --status=unjudged,unresolved --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "list --status comma-list returns 2 entries" "2" "$COUNT"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: list tests FAIL with "list: not implemented yet" exit 2.

- [ ] **Step 3: Implement readState() and cmdList()**

Replace the stub for `list` in `scripts/contradictions.js`. Add `readState()`, `emptyState()`, and `cmdList()` above `main()`:

```javascript
function readState(vault) {
  const abs = path.join(vault, STATE_FILE);
  if (!fs.existsSync(abs)) return null;
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch (err) { die(`${STATE_FILE} unreadable: ${err.message}`, 2); }
  let doc;
  try { doc = yaml.load(text, { schema: yaml.CORE_SCHEMA }); }
  catch (err) { die(`${STATE_FILE} malformed: ${err.message}`, 2); }
  if (!doc || typeof doc !== 'object') die(`${STATE_FILE} malformed: not a YAML mapping`, 2);
  if (doc.schema_version !== SCHEMA_VERSION) {
    die(`${STATE_FILE} schema_version=${doc.schema_version}, expected ${SCHEMA_VERSION}`, 2);
  }
  if (!Array.isArray(doc.contradictions)) doc.contradictions = [];
  return doc;
}

function emptyState() {
  return {
    schema_version: SCHEMA_VERSION,
    generated_by: GENERATED_BY,
    contradictions: [],
  };
}

function cmdList(vault, args) {
  const doc = readState(vault) || emptyState();
  let entries = doc.contradictions;
  if (args.status) {
    const wanted = String(args.status).split(',').map(s => s.trim()).filter(Boolean);
    entries = entries.filter(e => wanted.includes(e.status));
  }
  if (args.json) {
    const out = Object.assign({}, doc, { contradictions: entries });
    process.stdout.write(JSON.stringify(out, null, 2) + '\n');
    return;
  }
  if (entries.length === 0) {
    process.stdout.write('No contradictions matching filter.\n');
    return;
  }
  // Group by status for the human summary.
  const groups = new Map();
  for (const e of entries) {
    const k = e.status || '(unknown)';
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(e);
  }
  const lines = [];
  lines.push(`${entries.length} entries across ${groups.size} statuses`);
  lines.push('');
  for (const [status, list] of groups) {
    lines.push(`${status} (${list.length}):`);
    for (const e of list) {
      const claim = e.judgment?.claim || '(unjudged)';
      lines.push(`  ${e.id}  ${e.pages.join(' ⟷ ')}  — ${claim}`);
    }
    lines.push('');
  }
  process.stdout.write(lines.join('\n'));
}
```

Update the `switch` in `main()`:

```javascript
    case 'list':         return cmdList(vault, args);
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: all `list` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh
git commit -m "$(cat <<'EOF'
feat(contradictions): list subcommand with status filter

Adds list [--status comma-list] [--json] for reading
wiki/.state/contradictions.yaml. Missing file → empty result, exit 0.
schema_version mismatch → exit 2. JSON mode dumps filtered entries with
the schema_version + generated_by envelope preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `candidates` Signal 1 — `conflicting-relations`

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`
- Create: `tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/alignment.md`
- Create: `tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/ai-alignment.md`

Implement signal 1: two pages whose same `relations.<R>` key has partly-overlapping, partly-diverging target lists. Enqueues a candidate per (pair, relation-key) tuple.

- [ ] **Step 1: Create the fixture vault**

Create `tests/fixtures/contradictions/signal-1-conflicting-relations/`. Mirror the harness vault shape:

```bash
mkdir -p tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/.state
mkdir -p tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts
mkdir -p tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/entities
mkdir -p tests/fixtures/contradictions/signal-1-conflicting-relations/raw
```

Create `tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/.state/sources.yaml`:

```yaml
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
```

Create `tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/.state/frontmatter-contract.yaml`:

```yaml
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
```

Create `tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/alignment.md`:

```markdown
---
tags: [ai-safety]
sources: [raw/source-a.md]
created: 2026-04-01
updated: 2026-04-01
relations:
  refines: [wiki/concepts/ethics.md, wiki/concepts/rlhf.md]
---

# Alignment

Body content referencing [[ethics]] and [[rlhf]].
```

Create `tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/ai-alignment.md`:

```markdown
---
tags: [ai-safety]
sources: [raw/source-b.md]
created: 2026-04-15
updated: 2026-04-15
relations:
  refines: [wiki/concepts/ethics.md, wiki/concepts/ai-safety.md]
---

# AI Alignment

Body content referencing [[ethics]] and [[ai-safety]].
```

Create the target stubs so wiki resolves (these don't need full content):

```bash
cat > tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/ethics.md <<'MD'
---
tags: []
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---
# Ethics
MD
cat > tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/rlhf.md <<'MD'
---
tags: []
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---
# RLHF
MD
cat > tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/ai-safety.md <<'MD'
---
tags: []
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---
# AI Safety
MD
cat > tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/index.md <<'MD'
# Index
MD
cat > tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/log.md <<'MD'
# Log
MD
```

- [ ] **Step 2: Add the Signal 1 test**

Append to `tests/test_contradictions.sh` before `=== Results ===`:

```bash
# Test: Signal 1 conflicting-relations on a fixture vault.
echo ""
echo "Test: Signal 1 conflicting-relations"
V_S1=$(make_vault vault-signal-1)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$V_S1/wiki/concepts/"
(cd "$V_S1" && git add . && git commit -qm "fixture content")
(cd "$V_S1" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
OUT=$( (cd "$V_S1" && node "$SCRIPT" list --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "Signal 1 enqueues one candidate" "1" "$COUNT"
SIGNAL=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].signal)})")
assert_eq "signal === conflicting-relations" "conflicting-relations" "$SIGNAL"
RELATION=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].signal_data.relation)})")
assert_eq "signal_data.relation === refines" "refines" "$RELATION"
SHARED=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].signal_data.shared_targets.join(','))})")
assert_eq "shared_targets includes ethics" "wiki/concepts/ethics.md" "$SHARED"
STATUS=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].status)})")
assert_eq "status === unjudged" "unjudged" "$STATUS"
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: Signal 1 case FAILs with "candidates: not implemented yet".

- [ ] **Step 4: Implement `candidates` for Signal 1**

Add helpers + `cmdCandidates()` to `scripts/contradictions.js` (insert above `main()`):

```javascript
function nowIso() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

function todayDate() {
  return new Date().toISOString().slice(0, 10);
}

// Read the YAML frontmatter block at the top of a markdown file. Returns the
// parsed object, or null if no fenced block.
function readFrontmatter(absPath) {
  let text;
  try { text = fs.readFileSync(absPath, 'utf8'); }
  catch { return null; }
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!m) return null;
  try { return yaml.load(m[1], { schema: yaml.CORE_SCHEMA }); }
  catch { return null; }
}

// Walk wiki/ and return vault-relative .md paths under the four content dirs.
function* walkWikiMarkdown(vault) {
  const root = path.join(vault, 'wiki');
  const subdirs = ['entities', 'concepts', 'synthesis', 'sources'];
  for (const sub of subdirs) {
    const dir = path.join(root, sub);
    if (!fs.existsSync(dir)) continue;
    const stack = [dir];
    while (stack.length) {
      const d = stack.pop();
      for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
        if (ent.name.startsWith('.')) continue;
        const full = path.join(d, ent.name);
        if (ent.isDirectory()) stack.push(full);
        else if (ent.isFile() && ent.name.endsWith('.md')) {
          yield path.relative(vault, full).split(path.sep).join('/');
        }
      }
    }
  }
}

// Return the lexically-sorted pair [a, b] (a < b).
function pairKey(a, b) {
  return a < b ? [a, b] : [b, a];
}

// Allocate the next ID for today's date. Reads existing entries, finds the
// highest NNN for today, returns max+1 zero-padded to 3 digits.
function allocateId(doc) {
  const today = todayDate();
  const prefix = `${today}-`;
  let maxN = 0;
  for (const e of doc.contradictions) {
    if (typeof e.id === 'string' && e.id.startsWith(prefix)) {
      const n = parseInt(e.id.slice(prefix.length), 10);
      if (Number.isInteger(n) && n > maxN) maxN = n;
    }
  }
  const next = String(maxN + 1).padStart(3, '0');
  return `${today}-${next}`;
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

// Compute Signal 1 candidates: pairs of pages sharing a relations.<R> key,
// where their value lists partly overlap and partly diverge.
// Returns array of { pages: [a, b], signal: 'conflicting-relations', signal_data }.
function signalConflictingRelations(vault, pagesInScope) {
  const fmCache = new Map(); // page → relations dict
  for (const p of pagesInScope) {
    const fm = readFrontmatter(path.join(vault, p));
    const relations = (fm && typeof fm.relations === 'object' && fm.relations) || null;
    fmCache.set(p, relations);
  }
  const candidates = [];
  const sortedPages = [...pagesInScope].sort();
  for (let i = 0; i < sortedPages.length; i++) {
    const a = sortedPages[i];
    const relA = fmCache.get(a);
    if (!relA) continue;
    for (let j = i + 1; j < sortedPages.length; j++) {
      const b = sortedPages[j];
      const relB = fmCache.get(b);
      if (!relB) continue;
      for (const key of Object.keys(relA)) {
        if (!Array.isArray(relA[key]) || !Array.isArray(relB[key])) continue;
        const setA = new Set(relA[key]);
        const setB = new Set(relB[key]);
        const shared = [...setA].filter(t => setB.has(t)).sort();
        const aOnly  = [...setA].filter(t => !setB.has(t)).sort();
        const bOnly  = [...setB].filter(t => !setA.has(t)).sort();
        if (shared.length > 0 && (aOnly.length > 0 || bOnly.length > 0)) {
          candidates.push({
            pages: [a, b], // already sorted (a < b)
            signal: 'conflicting-relations',
            signal_data: {
              relation: key,
              shared_targets: shared,
              a_only_targets: aOnly,
              b_only_targets: bOnly,
            },
          });
        }
      }
    }
  }
  return candidates;
}

function cmdCandidates(vault, args) {
  const scope = args.scope || 'wiki/';
  // For now (Task 3): only support directory scope; page-list + neighbour
  // expansion lands in Task 6.
  if (scope.includes(',') || scope.endsWith('.md')) {
    die('candidates: page-list scope not implemented yet (Task 6)', 2);
  }
  const pages = [...walkWikiMarkdown(vault)];
  const candidates = signalConflictingRelations(vault, pages);
  // Enqueue: add each candidate as a new entry with status: unjudged.
  // (Dedup against existing entries is Task 5.)
  const doc = readState(vault) || emptyState();
  let added = 0;
  for (const c of candidates) {
    const id = allocateId(doc);
    doc.contradictions.push({
      id,
      detected_at: nowIso(),
      pages: c.pages,
      signal: c.signal,
      signal_data: c.signal_data,
      status: 'unjudged',
    });
    added += 1;
  }
  if (added > 0) writeState(vault, doc);
  process.stdout.write(`enqueued ${added} new\n`);
}
```

Update the `switch` in `main()`:

```javascript
    case 'candidates':   return cmdCandidates(vault, args);
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: Signal 1 test PASSes.

- [ ] **Step 6: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh tests/fixtures/contradictions/signal-1-conflicting-relations
git commit -m "$(cat <<'EOF'
feat(contradictions): signal 1 (conflicting-relations)

Adds candidates --scope=wiki/ enqueueing for the relations
overlap-divergence signal: two pages with the same relations.<R> key
whose value lists share at least one target but diverge on at least one
other. Stores signal_data { relation, shared_targets, a_only_targets,
b_only_targets } for the LLM judge to read later.

Signal 2 (shared-entity-prose) and the dedup + canonicalisation paths
land in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `candidates` Signal 2 — `shared-entity-prose`

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`
- Create: `tests/fixtures/contradictions/signal-2-shared-entity-prose/...`

Implement signal 2: pairs of pages whose body prose links to a common entity AND share ≥5 total wikilinks. One candidate emitted per shared entity.

- [ ] **Step 1: Create the Signal 2 fixture vault**

```bash
mkdir -p tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/.state
mkdir -p tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/concepts
mkdir -p tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/entities
```

Copy the standard `sources.yaml` and `frontmatter-contract.yaml` from Task 3 into the new fixture's `wiki/.state/` directory.

Create `tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/concepts/page-a.md`:

```markdown
---
tags: []
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---

# Page A

Body mentions [[foo]], [[bar]], [[baz]], [[qux]], [[xyzzy]], and [[plugh]].
```

Create `tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/concepts/page-b.md`:

```markdown
---
tags: []
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---

# Page B

Body mentions [[foo]], [[bar]], [[baz]], [[qux]], [[plugh]], and [[corge]].
```

Stub entity pages so wikilinks resolve:

```bash
for name in foo bar baz qux xyzzy plugh corge; do
  cat > "tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/entities/$name.md" <<MD
---
tags: []
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---
# $name
MD
done
echo "# Index" > tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/index.md
echo "# Log"   > tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/log.md
```

Both pages share entities `foo`, `bar`, `baz`, `qux`, `plugh` — 5 shared total links, all entities. Signal fires; expect one candidate per shared entity (5 candidates).

- [ ] **Step 2: Add the Signal 2 test**

Append to `tests/test_contradictions.sh`:

```bash
# Test: Signal 2 shared-entity-prose on a fixture vault.
echo ""
echo "Test: Signal 2 shared-entity-prose"
V_S2=$(make_vault vault-signal-2)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/concepts/." "$V_S2/wiki/concepts/"
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/entities/." "$V_S2/wiki/entities/"
(cd "$V_S2" && git add . && git commit -qm "fixture content")
(cd "$V_S2" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
OUT=$( (cd "$V_S2" && node "$SCRIPT" list --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "Signal 2 enqueues 5 candidates (one per shared entity)" "5" "$COUNT"
SIGNAL=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].signal)})")
assert_eq "signal === shared-entity-prose" "shared-entity-prose" "$SIGNAL"
ENTITY=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{let e=JSON.parse(d).contradictions[0]; process.stdout.write(e.signal_data.entity)})")
case "$ENTITY" in
  wiki/entities/*.md)
    echo "  PASS: signal_data.entity points at an entity page"
    PASS=$((PASS + 1));;
  *)
    echo "  FAIL: signal_data.entity malformed: $ENTITY"
    FAIL=$((FAIL + 1));;
esac
SHARED=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions[0].signal_data.shared_links))})")
assert_eq "shared_links === 5" "5" "$SHARED"
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: Signal 2 case FAILs (current count is 0 because only Signal 1 is implemented).

- [ ] **Step 4: Implement Signal 2 in `scripts/contradictions.js`**

Add `signalSharedEntityProse()` and call it from `cmdCandidates()`. Place above `cmdCandidates()`:

```javascript
const SHARED_LINK_THRESHOLD = 5;

// Extract all [[wikilink]] tokens from body prose (excluding the frontmatter
// fence). Returns vault-relative `.md` paths, resolved under the bare-name
// (entities/concepts/synthesis/sources) and `wiki/...` rules.
function extractBodyWikilinks(vault, page) {
  const abs = path.join(vault, page);
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch { return new Set(); }
  // Strip leading frontmatter block, if any.
  const body = text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '');
  const out = new Set();
  // Match [[target]] or [[target|alias]]; capture target.
  const re = /\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]/g;
  let m;
  while ((m = re.exec(body))) {
    const raw = m[1].trim();
    const resolved = resolveWikilinkTarget(vault, raw);
    if (resolved) out.add(resolved);
  }
  return out;
}

// Resolve a wikilink token to a vault-relative .md path under the same three
// rules validate-wiki.js wikilinks uses: bare name (search the four content
// dirs), `wiki/...` path, `src/documentation/...` path.
function resolveWikilinkTarget(vault, token) {
  // Strip a trailing .md to normalise.
  const t = token.endsWith('.md') ? token.slice(0, -3) : token;
  // wiki/... and src/documentation/... paths land directly.
  if (t.startsWith('wiki/') || t.startsWith('src/documentation/')) {
    const candidate = t + '.md';
    if (fs.existsSync(path.join(vault, candidate))) return candidate;
    return null;
  }
  // Bare-name: search the four content dirs in order.
  for (const sub of ['entities', 'concepts', 'synthesis', 'sources']) {
    const candidate = `wiki/${sub}/${t}.md`;
    if (fs.existsSync(path.join(vault, candidate))) return candidate;
  }
  return null;
}

function signalSharedEntityProse(vault, pagesInScope) {
  const linkCache = new Map(); // page → Set<resolved>
  for (const p of pagesInScope) {
    linkCache.set(p, extractBodyWikilinks(vault, p));
  }
  const candidates = [];
  const sortedPages = [...pagesInScope].sort();
  for (let i = 0; i < sortedPages.length; i++) {
    const a = sortedPages[i];
    const linksA = linkCache.get(a);
    if (!linksA || linksA.size === 0) continue;
    for (let j = i + 1; j < sortedPages.length; j++) {
      const b = sortedPages[j];
      const linksB = linkCache.get(b);
      if (!linksB || linksB.size === 0) continue;
      const shared = [...linksA].filter(t => linksB.has(t));
      if (shared.length < SHARED_LINK_THRESHOLD) continue;
      const sharedEntities = shared.filter(t => t.startsWith('wiki/entities/')).sort();
      if (sharedEntities.length === 0) continue;
      // Emit one candidate per shared entity.
      for (const entity of sharedEntities) {
        candidates.push({
          pages: [a, b], // already sorted
          signal: 'shared-entity-prose',
          signal_data: {
            entity,
            shared_links: shared.length,
          },
        });
      }
    }
  }
  return candidates;
}
```

Update `cmdCandidates()` to call both signals:

```javascript
function cmdCandidates(vault, args) {
  const scope = args.scope || 'wiki/';
  if (scope.includes(',') || scope.endsWith('.md')) {
    die('candidates: page-list scope not implemented yet (Task 6)', 2);
  }
  const pages = [...walkWikiMarkdown(vault)];
  const candidates = [
    ...signalConflictingRelations(vault, pages),
    ...signalSharedEntityProse(vault, pages),
  ];
  const doc = readState(vault) || emptyState();
  let added = 0;
  for (const c of candidates) {
    const id = allocateId(doc);
    doc.contradictions.push({
      id,
      detected_at: nowIso(),
      pages: c.pages,
      signal: c.signal,
      signal_data: c.signal_data,
      status: 'unjudged',
    });
    added += 1;
  }
  if (added > 0) writeState(vault, doc);
  process.stdout.write(`enqueued ${added} new\n`);
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: Signal 2 test PASSes.

- [ ] **Step 6: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh tests/fixtures/contradictions/signal-2-shared-entity-prose
git commit -m "$(cat <<'EOF'
feat(contradictions): signal 2 (shared-entity-prose)

Adds the second deterministic signal: pairs of pages whose body prose
links to a common entity AND share at least N=5 wikilinks total. One
candidate emitted per shared entity. The LLM judge filters
false-positives; the signal threshold lives in code (SHARED_LINK_THRESHOLD)
and is tunable if shortlists prove too noisy.

Dedup + pair canonicalisation land in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Candidate dedupe + pair canonicalisation

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`

Re-running `candidates` must not produce duplicate entries for pairs already in the file (any status). Pair canonicalisation (lexical sort of `pages`) handles direction; `signal_data` canonicalisation handles list-internal order.

- [ ] **Step 1: Add the dedupe test**

Append to `tests/test_contradictions.sh`:

```bash
# Test: re-run candidates on the same fixture → no duplicate entries.
echo ""
echo "Test: candidates dedupe on re-scan"
V_DEDUP=$(make_vault vault-dedupe)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$V_DEDUP/wiki/concepts/"
(cd "$V_DEDUP" && git add . && git commit -qm "fixture content")
(cd "$V_DEDUP" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
COUNT1=$(node -e "process.stdout.write(String(require('js-yaml').load(require('fs').readFileSync('$V_DEDUP/wiki/.state/contradictions.yaml','utf8')).contradictions.length))")
(cd "$V_DEDUP" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
COUNT2=$(node -e "process.stdout.write(String(require('js-yaml').load(require('fs').readFileSync('$V_DEDUP/wiki/.state/contradictions.yaml','utf8')).contradictions.length))")
assert_eq "second scan does not duplicate"  "$COUNT1" "$COUNT2"

# Test: pair canonicalisation — `pages` is always lexically sorted.
echo ""
echo "Test: pages field is lexically sorted"
PAGES=$(node -e "process.stdout.write(JSON.stringify(require('js-yaml').load(require('fs').readFileSync('$V_DEDUP/wiki/.state/contradictions.yaml','utf8')).contradictions[0].pages))")
SORTED=$(node -e "let p=$PAGES; process.stdout.write(JSON.stringify([...p].sort()))")
assert_eq "pages array is sorted" "$SORTED" "$PAGES"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: dedupe test FAILs — second scan doubles the entry count.

- [ ] **Step 3: Implement dedupe in `cmdCandidates()`**

Add a `candidateKey()` helper above `cmdCandidates()`:

```javascript
// Canonical dedupe key for a candidate: (pages-sorted, signal, signal_data-sorted-json).
function candidateKey(c) {
  // signal_data lists were already sorted at emission time, but be defensive.
  const sd = JSON.parse(JSON.stringify(c.signal_data));
  for (const k of Object.keys(sd)) {
    if (Array.isArray(sd[k])) sd[k] = [...sd[k]].sort();
  }
  return JSON.stringify([c.pages, c.signal, sd]);
}
```

Update `cmdCandidates()` to dedupe before enqueueing:

```javascript
function cmdCandidates(vault, args) {
  const scope = args.scope || 'wiki/';
  if (scope.includes(',') || scope.endsWith('.md')) {
    die('candidates: page-list scope not implemented yet (Task 6)', 2);
  }
  const pages = [...walkWikiMarkdown(vault)];
  const fresh = [
    ...signalConflictingRelations(vault, pages),
    ...signalSharedEntityProse(vault, pages),
  ];
  const doc = readState(vault) || emptyState();
  const existing = new Set(doc.contradictions.map(e =>
    candidateKey({ pages: e.pages, signal: e.signal, signal_data: e.signal_data })
  ));
  let added = 0, skipped = 0;
  for (const c of fresh) {
    const key = candidateKey(c);
    if (existing.has(key)) { skipped += 1; continue; }
    existing.add(key);
    const id = allocateId(doc);
    doc.contradictions.push({
      id,
      detected_at: nowIso(),
      pages: c.pages,
      signal: c.signal,
      signal_data: c.signal_data,
      status: 'unjudged',
    });
    added += 1;
  }
  if (added > 0) writeState(vault, doc);
  process.stdout.write(`enqueued ${added} new, skipped ${skipped} already-known\n`);
}
```

Note: `signalConflictingRelations` already emits `pages` lexically sorted (because it iterates `i < j` over the sorted page list and writes `[a, b]` with `a < b`). Same for `signalSharedEntityProse`. The dedupe key is robust regardless.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: dedupe + canonicalisation tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh
git commit -m "$(cat <<'EOF'
feat(contradictions): dedupe candidates against existing entries

Computes a canonical (pages, signal, signal_data) key per candidate;
skips when an entry with the same key already exists in
contradictions.yaml — regardless of that entry's status (a
not-a-contradiction verdict is enough to skip re-judging the same pair).

`pages` is always lexically sorted at signal emission, so the same pair
in either direction collapses to one key. signal_data list values are
sorted at dedupe time too, so internal order doesn't matter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `candidates --scope=<page-list>` + one-hop neighbour expansion + K=50 cap

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`

Add the page-list scope path used by ingest: comma-separated vault-relative `.md` paths, expanded one hop through outbound wikilinks, capped at K=50. Signals run only on the expanded set.

- [ ] **Step 1: Add tests for page-list scope + cap**

Append to `tests/test_contradictions.sh`:

```bash
# Test: --scope=<single-page> expands one hop and surfaces a candidate
# that spans the scope boundary.
echo ""
echo "Test: page-list scope with one-hop expansion"
V_SCOPE=$(make_vault vault-scope)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$V_SCOPE/wiki/concepts/"
(cd "$V_SCOPE" && git add . && git commit -qm "fixture content")
# Scope only one of the two pages; the other should be picked up via the
# shared `refines: ethics` neighbour link.
(cd "$V_SCOPE" && node "$SCRIPT" candidates --scope=wiki/concepts/alignment.md >/dev/null)
COUNT=$(node -e "process.stdout.write(String(require('js-yaml').load(require('fs').readFileSync('$V_SCOPE/wiki/.state/contradictions.yaml','utf8')).contradictions.length))")
assert_eq "scoped-with-expansion enqueues 1 candidate" "1" "$COUNT"

# Test: neighbour expansion cap (K=50).
echo ""
echo "Test: neighbour expansion cap"
V_CAP=$(make_vault vault-cap)
# Build a hub page with 60 outbound wikilinks; expansion must cap at K=50
# and emit a warning to stderr (still exit 0).
node -e '
const fs=require("fs"); const path=require("path"); const v=process.argv[1];
const lines=["---","tags: []","sources: [raw/x.md]","created: 2026-04-01","updated: 2026-04-01","---","# Hub",""];
for (let i=0;i<60;i++) {
  const slug = `e${String(i).padStart(3,"0")}`;
  lines.push(`Link to [[${slug}]].`);
  fs.writeFileSync(path.join(v,`wiki/entities/${slug}.md`),
    `---\ntags: []\nsources: [raw/x.md]\ncreated: 2026-04-01\nupdated: 2026-04-01\n---\n# ${slug}\n`);
}
fs.writeFileSync(path.join(v,"wiki/concepts/hub.md"), lines.join("\n")+"\n");
' "$V_CAP"
(cd "$V_CAP" && git add . && git commit -qm "hub fixture")
set +e
ERR=$( (cd "$V_CAP" && node "$SCRIPT" candidates --scope=wiki/concepts/hub.md 2>&1 >/dev/null) )
EXIT=$?
set -e
assert_eq "exit 0 even when cap is hit" "0" "$EXIT"
case "$ERR" in
  *"truncated"*|*"cap"*|*"K=50"*)
    echo "  PASS: stderr mentions the cap"
    PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not mention cap — got: $ERR"
    FAIL=$((FAIL + 1));;
esac
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: scope test FAILs with "page-list scope not implemented yet".

- [ ] **Step 3: Implement page-list scope + expansion**

Add a `NEIGHBOUR_CAP` constant and `expandOneHop()` helper above `cmdCandidates()`:

```javascript
const NEIGHBOUR_CAP = 50;

// Given a set of seed pages, expand by one hop through outbound wikilinks
// (body prose) and frontmatter relations targets. Cap at NEIGHBOUR_CAP total
// pages (seeds + neighbours). Returns the capped page set + a `truncated` bool.
function expandOneHop(vault, seeds) {
  const out = new Set(seeds);
  const visited = new Set();
  let truncated = false;
  for (const seed of seeds) {
    if (visited.has(seed)) continue;
    visited.add(seed);
    const links = extractBodyWikilinks(vault, seed);
    const fm = readFrontmatter(path.join(vault, seed));
    if (fm && typeof fm.relations === 'object' && fm.relations) {
      for (const targets of Object.values(fm.relations)) {
        if (!Array.isArray(targets)) continue;
        for (const t of targets) {
          if (typeof t !== 'string') continue;
          const r = resolveWikilinkTarget(vault, t);
          if (r) links.add(r);
        }
      }
    }
    for (const link of links) {
      if (out.size >= NEIGHBOUR_CAP) {
        truncated = true;
        break;
      }
      out.add(link);
    }
    if (truncated) break;
  }
  return { pages: [...out], truncated };
}
```

Replace `cmdCandidates()` to handle both scope shapes:

```javascript
function cmdCandidates(vault, args) {
  const scope = args.scope || 'wiki/';
  let pages;
  let truncated = false;
  if (scope.endsWith('.md') || scope.includes(',')) {
    // Page-list scope: comma-separated vault-relative .md paths.
    const seeds = scope.split(',').map(s => s.trim()).filter(Boolean);
    for (const s of seeds) {
      if (!s.endsWith('.md') || !fs.existsSync(path.join(vault, s))) {
        die(`candidates: page not found in vault: ${s}`, 3);
      }
    }
    const exp = expandOneHop(vault, seeds);
    pages = exp.pages;
    truncated = exp.truncated;
  } else {
    // Directory scope: walk wiki/ content dirs.
    pages = [...walkWikiMarkdown(vault)];
  }
  if (truncated) {
    process.stderr.write(`warning: neighbour expansion truncated at K=${NEIGHBOUR_CAP}\n`);
  }
  const fresh = [
    ...signalConflictingRelations(vault, pages),
    ...signalSharedEntityProse(vault, pages),
  ];
  const doc = readState(vault) || emptyState();
  const existing = new Set(doc.contradictions.map(e =>
    candidateKey({ pages: e.pages, signal: e.signal, signal_data: e.signal_data })
  ));
  let added = 0, skipped = 0;
  for (const c of fresh) {
    const key = candidateKey(c);
    if (existing.has(key)) { skipped += 1; continue; }
    existing.add(key);
    const id = allocateId(doc);
    doc.contradictions.push({
      id,
      detected_at: nowIso(),
      pages: c.pages,
      signal: c.signal,
      signal_data: c.signal_data,
      status: 'unjudged',
    });
    added += 1;
  }
  if (added > 0) writeState(vault, doc);
  process.stdout.write(`enqueued ${added} new, skipped ${skipped} already-known\n`);
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: scope + cap tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh
git commit -m "$(cat <<'EOF'
feat(contradictions): page-list scope with one-hop expansion + K=50 cap

candidates --scope=<comma-separated .md paths> walks outbound wikilinks
(body prose + frontmatter relations targets) one hop out, then runs both
signals on the expanded set. Cap at K=50 total pages; on overflow,
expansion stops, stderr warns, exit stays 0. Used by ingest's
incremental scan.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `candidates --json` (read-only mode)

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`

`--json` emits the candidate set as JSON without mutating `contradictions.yaml`. Used by lint's read-only count path.

- [ ] **Step 1: Add the `--json` test**

Append to `tests/test_contradictions.sh`:

```bash
# Test: candidates --json is read-only (no yaml mutation, prints JSON).
echo ""
echo "Test: candidates --json is read-only"
V_JSON=$(make_vault vault-json)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$V_JSON/wiki/concepts/"
(cd "$V_JSON" && git add . && git commit -qm "fixture content")
OUT=$( (cd "$V_JSON" && node "$SCRIPT" candidates --scope=wiki/ --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).candidates.length))})")
assert_eq "candidates --json reports 1 candidate" "1" "$COUNT"
HAS_FILE="no"
[ -f "$V_JSON/wiki/.state/contradictions.yaml" ] && HAS_FILE="yes"
assert_eq "yaml not created in --json mode" "no" "$HAS_FILE"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: case FAILs — current implementation enqueues even with `--json`.

- [ ] **Step 3: Wire `--json` into `cmdCandidates()`**

Modify `cmdCandidates()` to branch on `--json`:

```javascript
function cmdCandidates(vault, args) {
  const scope = args.scope || 'wiki/';
  let pages;
  let truncated = false;
  if (scope.endsWith('.md') || scope.includes(',')) {
    const seeds = scope.split(',').map(s => s.trim()).filter(Boolean);
    for (const s of seeds) {
      if (!s.endsWith('.md') || !fs.existsSync(path.join(vault, s))) {
        die(`candidates: page not found in vault: ${s}`, 3);
      }
    }
    const exp = expandOneHop(vault, seeds);
    pages = exp.pages;
    truncated = exp.truncated;
  } else {
    pages = [...walkWikiMarkdown(vault)];
  }
  if (truncated) {
    process.stderr.write(`warning: neighbour expansion truncated at K=${NEIGHBOUR_CAP}\n`);
  }
  const fresh = [
    ...signalConflictingRelations(vault, pages),
    ...signalSharedEntityProse(vault, pages),
  ];
  if (args.json) {
    process.stdout.write(JSON.stringify({ candidates: fresh }, null, 2) + '\n');
    return;
  }
  // Enqueue path: dedup + write.
  const doc = readState(vault) || emptyState();
  const existing = new Set(doc.contradictions.map(e =>
    candidateKey({ pages: e.pages, signal: e.signal, signal_data: e.signal_data })
  ));
  let added = 0, skipped = 0;
  for (const c of fresh) {
    const key = candidateKey(c);
    if (existing.has(key)) { skipped += 1; continue; }
    existing.add(key);
    const id = allocateId(doc);
    doc.contradictions.push({
      id,
      detected_at: nowIso(),
      pages: c.pages,
      signal: c.signal,
      signal_data: c.signal_data,
      status: 'unjudged',
    });
    added += 1;
  }
  if (added > 0) writeState(vault, doc);
  process.stdout.write(`enqueued ${added} new, skipped ${skipped} already-known\n`);
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: `--json` test PASSes.

- [ ] **Step 5: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh
git commit -m "$(cat <<'EOF'
feat(contradictions): candidates --json read-only mode

candidates --json emits the candidate set as JSON without enqueueing
anything to contradictions.yaml. Used by lint's read-only count path so
the dashboard can surface candidate counts without lint forcing a
write.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `judge` subcommand (both verdicts + invalid-transition)

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`

`judge --id <id> --verdict <real-contradiction|not-a-contradiction> --data <json>` transitions `unjudged → unresolved | not-a-contradiction`, writes the `judgment` block. Already-judged entries exit 3.

- [ ] **Step 1: Add judge tests**

Append to `tests/test_contradictions.sh`:

```bash
# Helper: seed a vault with one `unjudged` entry and echo its id.
seed_unjudged() {
  local v="$1"
  cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$v/wiki/concepts/"
  (cd "$v" && git add . && git commit -qm "fixture content")
  (cd "$v" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
  node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$v/wiki/.state/contradictions.yaml','utf8')).contradictions[0].id)"
}

# Test: judge --verdict=real-contradiction transitions unjudged → unresolved.
echo ""
echo "Test: judge real-contradiction"
V_JR=$(make_vault vault-judge-real)
ID=$(seed_unjudged "$V_JR")
(cd "$V_JR" && node "$SCRIPT" judge --id="$ID" --verdict=real-contradiction \
  --data='{"claim":"Acquirer of foo","assertions":[{"page":"wiki/concepts/alignment.md","text":"first claim","source":"raw/source-a.md"},{"page":"wiki/concepts/ai-alignment.md","text":"second claim","source":"raw/source-b.md"}],"rationale":"Both pages take different positions."}' >/dev/null)
STATUS=$(node -e "let d=require('js-yaml').load(require('fs').readFileSync('$V_JR/wiki/.state/contradictions.yaml','utf8')); process.stdout.write(d.contradictions[0].status)")
assert_eq "status === unresolved" "unresolved" "$STATUS"
CLAIM=$(node -e "let d=require('js-yaml').load(require('fs').readFileSync('$V_JR/wiki/.state/contradictions.yaml','utf8')); process.stdout.write(d.contradictions[0].judgment.claim)")
assert_eq "claim populated" "Acquirer of foo" "$CLAIM"

# Test: judge --verdict=not-a-contradiction.
echo ""
echo "Test: judge not-a-contradiction"
V_JN=$(make_vault vault-judge-not)
ID=$(seed_unjudged "$V_JN")
(cd "$V_JN" && node "$SCRIPT" judge --id="$ID" --verdict=not-a-contradiction \
  --data='{"rationale":"Both pages are just listing common parents."}' >/dev/null)
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_JN/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status === not-a-contradiction" "not-a-contradiction" "$STATUS"

# Test: judge on already-judged entry → exit 3.
echo ""
echo "Test: judge on already-judged → exit 3"
set +e
(cd "$V_JN" && node "$SCRIPT" judge --id="$ID" --verdict=real-contradiction \
  --data='{"claim":"x","assertions":[{"page":"a","text":"b","source":"c"}],"rationale":"r"}' >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 3 on second judge" "3" "$EXIT"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: all three judge cases FAIL.

- [ ] **Step 3: Implement `cmdJudge()`**

Add `findEntry()` and `cmdJudge()` above `main()` in `scripts/contradictions.js`:

```javascript
function findEntry(doc, id) {
  return doc.contradictions.find(e => e.id === id) || null;
}

function cmdJudge(vault, args) {
  if (!args.id) die('judge: --id is required', 2);
  if (!args.verdict) die('judge: --verdict is required', 2);
  if (!args.data) die('judge: --data is required', 2);
  if (args.verdict !== 'real-contradiction' && args.verdict !== 'not-a-contradiction') {
    die(`judge: --verdict must be 'real-contradiction' or 'not-a-contradiction', got ${args.verdict}`, 2);
  }
  let payload;
  try { payload = JSON.parse(args.data); }
  catch (err) { die(`judge: --data is not valid JSON: ${err.message}`, 2); }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    die('judge: --data must be a JSON object', 2);
  }
  const doc = readState(vault);
  if (!doc) die(`judge: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`judge: id ${args.id} not found`, 3);
  if (entry.status !== 'unjudged') {
    die(`judge: entry ${args.id} status is ${entry.status}, expected unjudged`, 3);
  }
  // Validate payload shape per verdict.
  const judgment = { verdict: args.verdict, at: nowIso() };
  if (args.verdict === 'real-contradiction') {
    if (typeof payload.claim !== 'string' || !payload.claim) {
      die('judge: --data.claim must be a non-empty string', 2);
    }
    if (!Array.isArray(payload.assertions) || payload.assertions.length === 0) {
      die('judge: --data.assertions must be a non-empty array', 2);
    }
    if (typeof payload.rationale !== 'string' || !payload.rationale) {
      die('judge: --data.rationale must be a non-empty string', 2);
    }
    judgment.claim = payload.claim;
    judgment.assertions = payload.assertions;
    judgment.rationale = payload.rationale;
    entry.status = 'unresolved';
  } else {
    if (typeof payload.rationale !== 'string' || !payload.rationale) {
      die('judge: --data.rationale must be a non-empty string', 2);
    }
    judgment.rationale = payload.rationale;
    entry.status = 'not-a-contradiction';
  }
  entry.judgment = judgment;
  writeState(vault, doc);
  process.stdout.write(`${args.id}: ${entry.status}\n`);
}
```

Update the `switch` in `main()`:

```javascript
    case 'judge':        return cmdJudge(vault, args);
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: all three judge tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh
git commit -m "$(cat <<'EOF'
feat(contradictions): judge subcommand

judge --id --verdict --data writes the judgment block and transitions
unjudged → unresolved (real-contradiction) or unjudged →
not-a-contradiction. Payload validation enforces the minimal shape
real-contradiction = {claim, assertions[], rationale};
not-a-contradiction = {rationale}.

Already-judged entries exit 3 with no mutation — re-judging is not
supported in v1 and the dedup layer skips re-enqueueing the same pair
anyway.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `resolve --kind=defer` (idempotent + invalid transition + unsupported kind)

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`

`resolve --kind=defer` is v1's only `resolve` kind. It transitions `unresolved → deferred` or `deferred → deferred` (idempotent — `deferred_at` refreshes). Calling on other statuses → exit 3. Any other `--kind` → exit 2.

- [ ] **Step 1: Add resolve tests**

Append to `tests/test_contradictions.sh`:

```bash
# Helper: seed a vault with one `unresolved` entry and echo its id.
seed_unresolved() {
  local v="$1"
  local id=$(seed_unjudged "$v")
  (cd "$v" && node "$SCRIPT" judge --id="$id" --verdict=real-contradiction \
    --data='{"claim":"c","assertions":[{"page":"wiki/concepts/alignment.md","text":"t","source":"s"}],"rationale":"r"}' >/dev/null)
  echo "$id"
}

# Test: resolve --kind=defer on unresolved → deferred.
echo ""
echo "Test: resolve defer from unresolved"
V_RD=$(make_vault vault-resolve-defer)
ID=$(seed_unresolved "$V_RD")
(cd "$V_RD" && node "$SCRIPT" resolve --id="$ID" --kind=defer >/dev/null)
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status === deferred" "deferred" "$STATUS"
HAS_AT=$(node -e "let e=require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0]; process.stdout.write(String(typeof e.deferred_at === 'string'))")
assert_eq "deferred_at populated" "true" "$HAS_AT"

# Test: idempotent re-defer updates deferred_at.
echo ""
echo "Test: re-defer is idempotent"
FIRST_AT=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0].deferred_at)")
sleep 1
(cd "$V_RD" && node "$SCRIPT" resolve --id="$ID" --kind=defer >/dev/null)
SECOND_AT=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0].deferred_at)")
case "$FIRST_AT" in
  "$SECOND_AT")
    echo "  FAIL: deferred_at did not update on re-defer"
    FAIL=$((FAIL + 1));;
  *)
    echo "  PASS: deferred_at updated on re-defer"
    PASS=$((PASS + 1));;
esac
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status stays deferred" "deferred" "$STATUS"

# Test: resolve --kind=defer on unjudged → exit 3.
echo ""
echo "Test: resolve defer on unjudged → exit 3"
V_RU=$(make_vault vault-resolve-unjudged)
ID=$(seed_unjudged "$V_RU")
set +e
(cd "$V_RU" && node "$SCRIPT" resolve --id="$ID" --kind=defer >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 3 on invalid transition" "3" "$EXIT"

# Test: resolve --kind=pick-a → exit 2 (unsupported kind).
echo ""
echo "Test: resolve unsupported kind → exit 2"
set +e
(cd "$V_RU" && node "$SCRIPT" resolve --id="$ID" --kind=pick-a >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 2 on unsupported kind" "2" "$EXIT"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: all four resolve tests FAIL.

- [ ] **Step 3: Implement `cmdResolve()`**

Add `cmdResolve()` above `main()` in `scripts/contradictions.js`:

```javascript
function cmdResolve(vault, args) {
  if (!args.id) die('resolve: --id is required', 2);
  if (!args.kind) die('resolve: --kind is required', 2);
  if (args.kind !== 'defer') {
    die(`resolve: unsupported --kind ${args.kind} (v1 only supports defer; picks flow through apply-pick / apply-accept)`, 2);
  }
  const doc = readState(vault);
  if (!doc) die(`resolve: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`resolve: id ${args.id} not found`, 3);
  if (entry.status !== 'unresolved' && entry.status !== 'deferred') {
    die(`resolve: entry ${args.id} status is ${entry.status}, expected unresolved or deferred`, 3);
  }
  entry.status = 'deferred';
  entry.deferred_at = nowIso();
  writeState(vault, doc);
  process.stdout.write(`${args.id}: deferred\n`);
}
```

Update the `switch` in `main()`:

```javascript
    case 'resolve':      return cmdResolve(vault, args);
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: all four resolve tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh
git commit -m "$(cat <<'EOF'
feat(contradictions): resolve defer subcommand

resolve --kind=defer is v1's only resolve kind. Transitions
unresolved → deferred or deferred → deferred (deferred_at refreshes).
Any other status → exit 3. Any other --kind → exit 2. Pick-a / pick-b /
accept-disagreement transitions flow through apply-pick / apply-accept,
which own the full file-edit + commit + yaml-update transaction.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `apply-pick` — substring invariants + happy path + post-check revert

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`
- Create: `tests/fixtures/contradictions/apply-pick-input/...`

`apply-pick --id --winning-page --rewrite` is the heaviest subcommand. It:
1. Verifies entry status is `unresolved` or `deferred` (exit 3 otherwise).
2. Locates the losing page's assertion paragraph by substring-matching `judgment.assertions[<losing>].text`. Exactly one match required (zero or multiple → exit 3, no mutation).
3. Swaps the matched paragraph with the tmpfile content.
4. Appends the winning page's `sources:` entries to the losing page (deduped).
5. Bumps the losing page's `updated:` to today.
6. Makes one git commit `reconcile: pick <winning> over <losing> on <claim>`.
7. Runs `scripts/validate-wiki.js all`. Exit 2 → auto-revert the commit, leave yaml untouched, exit 2. Exit 0 or 1 → proceed.
8. Writes the resolution block to `contradictions.yaml` (`status: resolved-pick-a` or `-b` based on which page in `pages` matched `--winning-page`).
9. Prints the commit sha to stdout.

- [ ] **Step 1: Create the apply-pick fixture**

```bash
mkdir -p tests/fixtures/contradictions/apply-pick-input/wiki/.state
mkdir -p tests/fixtures/contradictions/apply-pick-input/wiki/entities
mkdir -p tests/fixtures/contradictions/apply-pick-input/wiki/concepts
```

Copy `sources.yaml` + `frontmatter-contract.yaml` from Task 3's fixture.

Create `tests/fixtures/contradictions/apply-pick-input/wiki/entities/foo.md`:

```markdown
---
tags: [companies]
sources: [raw/article-a.md]
created: 2026-04-01
updated: 2026-04-01
---

# Foo

Foo was acquired by Bar in 2023.

Other content about Foo.
```

Create `tests/fixtures/contradictions/apply-pick-input/wiki/concepts/acquisitions.md`:

```markdown
---
tags: [m-and-a]
sources: [raw/article-b.md]
created: 2026-04-15
updated: 2026-04-15
---

# Acquisitions

Foo was acquired by Baz in 2024.

Other content about acquisitions.
```

Stub the entity targets so wikilinks resolve (just two empty entity pages):

```bash
for name in bar baz; do
  cat > "tests/fixtures/contradictions/apply-pick-input/wiki/entities/$name.md" <<MD
---
tags: []
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---
# $name
MD
done
echo "# Index" > tests/fixtures/contradictions/apply-pick-input/wiki/index.md
echo "# Log"   > tests/fixtures/contradictions/apply-pick-input/wiki/log.md
```

- [ ] **Step 2: Add apply-pick tests**

Append to `tests/test_contradictions.sh`:

```bash
# Helper: seed a vault for apply-pick — fixture + one unresolved entry with
# a populated judgment block that quotes one paragraph from each page.
# Echoes the entry id.
seed_apply_pick() {
  local v="$1"
  cp -a "$REPO_ROOT/tests/fixtures/contradictions/apply-pick-input/wiki/." "$v/wiki/"
  (cd "$v" && git add . && git commit -qm "fixture content")
  # Hand-craft contradictions.yaml so we control the assertion text exactly.
  cat > "$v/wiki/.state/contradictions.yaml" <<YAML
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  - id: 2026-05-24-001
    detected_at: 2026-05-24T10:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [foo], a_only_targets: [], b_only_targets: [bar] }
    status: unresolved
    judgment:
      verdict: real-contradiction
      at: 2026-05-24T11:00:00Z
      claim: "Acquirer of Foo"
      assertions:
        - page: wiki/entities/foo.md
          text: "Foo was acquired by Bar in 2023."
          source: raw/article-a.md
        - page: wiki/concepts/acquisitions.md
          text: "Foo was acquired by Baz in 2024."
          source: raw/article-b.md
      rationale: "Two pages, different acquirers."
YAML
  (cd "$v" && git add wiki/.state/contradictions.yaml && git commit -qm "seed contradiction")
  echo "2026-05-24-001"
}

# Test: apply-pick happy path — pick foo, rewrite acquisitions, single commit,
# yaml entry transitions to resolved-pick-b (acquisitions is b in lexical sort).
echo ""
echo "Test: apply-pick happy path"
V_AP=$(make_vault vault-apply-pick)
ID=$(seed_apply_pick "$V_AP")
TMP=$(mktemp)
cat > "$TMP" <<'MD'
Foo was acquired by Bar in 2023.
MD
(cd "$V_AP" && node "$SCRIPT" apply-pick --id="$ID" --winning-page=wiki/entities/foo.md --rewrite="$TMP" >/dev/null)
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_AP/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
# foo.md sorts before acquisitions.md? No — alphabetical: acquisitions.md < entities/foo.md.
# Lexical-sorted pages = [wiki/concepts/acquisitions.md, wiki/entities/foo.md].
# Winning is wiki/entities/foo.md → that's index 1 → pick-b.
assert_eq "status === resolved-pick-b" "resolved-pick-b" "$STATUS"
LOSING_TEXT=$(grep -c "Baz in 2024" "$V_AP/wiki/concepts/acquisitions.md" || true)
assert_eq "Baz claim removed from acquisitions.md" "0" "$LOSING_TEXT"
BAR_REPLACED=$(grep -c "Foo was acquired by Bar in 2023" "$V_AP/wiki/concepts/acquisitions.md" || true)
assert_eq "Bar claim swapped into acquisitions.md" "1" "$BAR_REPLACED"
# Sources dedup: acquisitions.md should now include both article-a and article-b.
HAS_A=$(grep -c "article-a.md" "$V_AP/wiki/concepts/acquisitions.md" || true)
HAS_B=$(grep -c "article-b.md" "$V_AP/wiki/concepts/acquisitions.md" || true)
assert_eq "acquisitions.md sources include article-a.md" "1" "$HAS_A"
assert_eq "acquisitions.md sources include article-b.md" "1" "$HAS_B"
# Exactly one commit was made.
COMMIT_COUNT=$(cd "$V_AP" && git log --grep "reconcile: pick" --oneline | wc -l | tr -d ' ')
assert_eq "exactly one reconcile commit" "1" "$COMMIT_COUNT"
rm -f "$TMP"

# Test: apply-pick substring not found → exit 3, no mutation.
echo ""
echo "Test: apply-pick substring not found → exit 3"
V_NF=$(make_vault vault-apply-notfound)
ID=$(seed_apply_pick "$V_NF")
# Hand-rewrite the judgment to quote a string that doesn't exist in either page.
node -e "
const fs=require('fs'), yaml=require('js-yaml');
const p='$V_NF/wiki/.state/contradictions.yaml';
const d=yaml.load(fs.readFileSync(p,'utf8'),{schema:yaml.CORE_SCHEMA});
d.contradictions[0].judgment.assertions[1].text='No such sentence ever appears';
fs.writeFileSync(p,yaml.dump(d,{indent:2,sortKeys:false,lineWidth:-1}));
"
TMP=$(mktemp); echo "anything" > "$TMP"
set +e
(cd "$V_NF" && node "$SCRIPT" apply-pick --id="$ID" --winning-page=wiki/entities/foo.md --rewrite="$TMP" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 3 on zero-match substring" "3" "$EXIT"
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_NF/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status unchanged after zero-match" "unresolved" "$STATUS"
rm -f "$TMP"

# Test: apply-pick substring matches multiple paragraphs → exit 3.
echo ""
echo "Test: apply-pick substring matches multiple paragraphs → exit 3"
V_MM=$(make_vault vault-apply-multi)
ID=$(seed_apply_pick "$V_MM")
# Append the same assertion text as a second paragraph in the losing page.
cat >> "$V_MM/wiki/concepts/acquisitions.md" <<'MD'

Foo was acquired by Baz in 2024.
MD
(cd "$V_MM" && git add wiki/concepts/acquisitions.md && git commit -qm "duplicate paragraph")
TMP=$(mktemp); echo "anything" > "$TMP"
set +e
(cd "$V_MM" && node "$SCRIPT" apply-pick --id="$ID" --winning-page=wiki/entities/foo.md --rewrite="$TMP" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 3 on multiple-match substring" "3" "$EXIT"
rm -f "$TMP"

# Test: apply-pick post-check revert — pre-stage a dead index row that makes
# validate-wiki exit 2 on every run.  apply-pick's commit triggers the
# post-check, which fails, and the script auto-reverts.
#
# (Broken wikilinks in the rewrite would only trigger validate-wiki exit 1,
# which is a warning per CR-005 conventions — not a revert trigger. Lint will
# surface those later. We test the structural-failure revert path explicitly.)
echo ""
echo "Test: apply-pick post-check auto-revert"
V_RV=$(make_vault vault-apply-revert)
ID=$(seed_apply_pick "$V_RV")
echo "- [[wiki/concepts/nonexistent]]" >> "$V_RV/wiki/index.md"
(cd "$V_RV" && git add wiki/index.md && git commit -qm "stage dead index row")
TMP=$(mktemp)
cat > "$TMP" <<'MD'
Foo was acquired by Bar in 2023.
MD
set +e
(cd "$V_RV" && node "$SCRIPT" apply-pick --id="$ID" --winning-page=wiki/entities/foo.md --rewrite="$TMP" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 2 on post-check structural failure" "2" "$EXIT"
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RV/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status unchanged after revert" "unresolved" "$STATUS"
HEAD_MSG=$(cd "$V_RV" && git log -1 --format=%s)
case "$HEAD_MSG" in
  *"Revert"*"reconcile: pick"*) echo "  PASS: revert commit present"; PASS=$((PASS+1));;
  *"reconcile: pick"*)          echo "  FAIL: reconcile commit not reverted"; FAIL=$((FAIL+1));;
  *)                            echo "  FAIL: unexpected HEAD: $HEAD_MSG"; FAIL=$((FAIL+1));;
esac
rm -f "$TMP"
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: all apply-pick cases FAIL with "apply-pick: not implemented yet".

- [ ] **Step 4: Implement `cmdApplyPick()`**

Add the helpers and `cmdApplyPick()` above `main()`:

```javascript
// Split a page's body (everything after the frontmatter fence) into
// paragraphs by double-newline. Returns { head, paragraphs, sep } where
// head is the frontmatter fence + leading blank line, paragraphs is the
// array of body paragraphs (no trailing newlines), and sep is the
// paragraph separator (always `\n\n`).
function splitPageBody(text) {
  const m = text.match(/^(---\r?\n[\s\S]*?\r?\n---\r?\n\r?\n?)([\s\S]*)$/);
  if (!m) return { head: '', paragraphs: text.split(/\r?\n\r?\n/), sep: '\n\n' };
  return {
    head: m[1],
    paragraphs: m[2].split(/\r?\n\r?\n/),
    sep: '\n\n',
  };
}

// Find the paragraph index in `paragraphs` that contains `needle` as a
// substring. Returns the (singular) index, or { error: 'zero' | 'multi', count }.
function locateAssertionParagraph(paragraphs, needle) {
  const matches = [];
  for (let i = 0; i < paragraphs.length; i++) {
    if (paragraphs[i].includes(needle)) matches.push(i);
  }
  if (matches.length === 0) return { error: 'zero', count: 0 };
  if (matches.length > 1)  return { error: 'multi', count: matches.length };
  return { index: matches[0] };
}

// Re-serialise frontmatter + body. Mutates the parsed frontmatter via `mutate`,
// then writes the new file content. Preserves the exact head shape (---\n...---\n)
// and uses CORE_SCHEMA dumping to keep quoting predictable.
function updateFrontmatter(absPath, mutate) {
  const text = fs.readFileSync(absPath, 'utf8');
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/);
  if (!m) throw new Error(`no frontmatter in ${absPath}`);
  const fm = yaml.load(m[1], { schema: yaml.CORE_SCHEMA }) || {};
  mutate(fm);
  const dumped = yaml.dump(fm, { indent: 2, sortKeys: false, lineWidth: -1 }).trimEnd();
  fs.writeFileSync(absPath, `---\n${dumped}\n---\n${m[2]}`);
}

// Run a child process synchronously in `vault`. Returns { status, stdout, stderr }.
function run(vault, cmd, args) {
  const r = spawnSync(cmd, args, { cwd: vault, encoding: 'utf8' });
  if (r.error) die(`${cmd} failed to spawn: ${r.error.message}`, 2);
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

function gitHeadSha(vault) {
  const r = run(vault, 'git', ['rev-parse', 'HEAD']);
  if (r.status !== 0) die(`git rev-parse HEAD failed: ${r.stderr}`, 2);
  return r.stdout.trim();
}

function validateWikiAll(vault) {
  const validate = path.join(__dirname, 'validate-wiki.js');
  return run(vault, 'node', [validate, 'all']);
}

function revertHead(vault) {
  const r = run(vault, 'git', ['revert', '--no-edit', 'HEAD']);
  if (r.status !== 0) die(`git revert failed: ${r.stderr}`, 2);
}

function cmdApplyPick(vault, args) {
  if (!args.id) die('apply-pick: --id is required', 2);
  if (!args['winning-page']) die('apply-pick: --winning-page is required', 2);
  if (!args.rewrite) die('apply-pick: --rewrite is required', 2);
  const winning = args['winning-page'];
  const rewritePath = args.rewrite;
  if (!fs.existsSync(rewritePath)) die(`apply-pick: --rewrite tmpfile not found: ${rewritePath}`, 2);

  const doc = readState(vault);
  if (!doc) die(`apply-pick: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-pick: id ${args.id} not found`, 3);
  if (entry.status !== 'unresolved' && entry.status !== 'deferred') {
    die(`apply-pick: entry ${args.id} status is ${entry.status}, expected unresolved or deferred`, 3);
  }
  if (!entry.pages.includes(winning)) {
    die(`apply-pick: --winning-page ${winning} is not in entry pages ${JSON.stringify(entry.pages)}`, 3);
  }
  const losing = entry.pages.find(p => p !== winning);
  // Index of winning in entry.pages decides pick-a vs pick-b.
  const winningIdx = entry.pages.indexOf(winning);
  const verdictKind = winningIdx === 0 ? 'resolved-pick-a' : 'resolved-pick-b';

  const losingAbs = path.join(vault, losing);
  if (!fs.existsSync(losingAbs)) die(`apply-pick: losing page not found on disk: ${losing}`, 3);

  // Locate the assertion paragraph in the losing page.
  const losingAssertion = (entry.judgment?.assertions || []).find(a => a.page === losing);
  if (!losingAssertion) die(`apply-pick: judgment.assertions has no entry for losing page ${losing}`, 3);
  const losingText = fs.readFileSync(losingAbs, 'utf8');
  const split = splitPageBody(losingText);
  const located = locateAssertionParagraph(split.paragraphs, losingAssertion.text);
  if (located.error === 'zero')  die(`apply-pick: assertion substring matched 0 paragraphs in ${losing}`, 3);
  if (located.error === 'multi') die(`apply-pick: assertion substring matched ${located.count} paragraphs in ${losing}`, 3);

  // Swap the matched paragraph with the rewrite content (trim trailing newlines).
  const newPara = fs.readFileSync(rewritePath, 'utf8').replace(/\r?\n+$/, '');
  split.paragraphs[located.index] = newPara;
  const newBody = split.paragraphs.join(split.sep);
  fs.writeFileSync(losingAbs, split.head + newBody);

  // Sources dedup: append winning's sources to losing's, dedupe, bump updated.
  const winningAbs = path.join(vault, winning);
  const winningFm = readFrontmatter(winningAbs) || {};
  const winningSources = Array.isArray(winningFm.sources) ? winningFm.sources : [];
  const appended = [];
  updateFrontmatter(losingAbs, (fm) => {
    fm.sources = Array.isArray(fm.sources) ? [...fm.sources] : [];
    for (const s of winningSources) {
      if (!fm.sources.includes(s)) {
        fm.sources.push(s);
        appended.push(s);
      }
    }
    fm.updated = todayDate();
  });

  // Commit.
  const claim = entry.judgment?.claim || '(unknown)';
  const commitMsg = `reconcile: pick ${winning} over ${losing} on ${claim}`;
  const add = run(vault, 'git', ['add', losing]);
  if (add.status !== 0) die(`git add failed: ${add.stderr}`, 2);
  const commit = run(vault, 'git', ['commit', '-m', commitMsg]);
  if (commit.status !== 0) die(`git commit failed: ${commit.stderr}`, 2);

  // Post-check.
  const check = validateWikiAll(vault);
  if (check.status === 2) {
    revertHead(vault);
    process.stderr.write(`apply-pick: validate-wiki structural failure — reverted\n${check.stderr}`);
    process.exit(2);
  }
  const sha = gitHeadSha(vault);

  // Yaml update: transition + resolution block.
  entry.status = verdictKind;
  entry.resolution = {
    at: nowIso(),
    picked_page: winning,
    edited_page: losing,
    commit: sha,
    sources_appended_to_edited: appended,
  };
  writeState(vault, doc);

  process.stdout.write(`${sha}\n`);
}
```

Update the `switch` in `main()`:

```javascript
    case 'apply-pick':   return cmdApplyPick(vault, args);
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: all four apply-pick tests PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh tests/fixtures/contradictions/apply-pick-input
git commit -m "$(cat <<'EOF'
feat(contradictions): apply-pick subcommand

apply-pick --id --winning-page --rewrite owns the full transaction for
picking a winning page during /status reconcile:

1. Verifies the entry is unresolved or deferred (exit 3 otherwise).
2. Substring-matches judgment.assertions[<losing>].text against the
   losing page's paragraphs. Zero matches → exit 3; multiple matches →
   exit 3. No mutation in either case.
3. Swaps the matched paragraph with the --rewrite tmpfile content.
4. Deduped-appends the winning page's sources: into the losing page.
5. Bumps the losing page's updated: to today.
6. One git commit (reconcile: pick <w> over <l> on <claim>).
7. Runs validate-wiki.js all; on exit 2, git revert HEAD --no-edit and
   exit 2 (yaml entry stays unresolved/deferred).
8. On success, writes the resolution block to contradictions.yaml with
   status = resolved-pick-a or -b (based on winning page's index in
   entry.pages) and prints the commit sha to stdout.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `apply-accept` — happy path + post-check revert

**Files:**
- Modify: `scripts/contradictions.js`
- Modify: `tests/test_contradictions.sh`
- Create: `tests/fixtures/contradictions/apply-accept-input/...`

`apply-accept --id` annotates both pages with `relations: { contradicts: [other-page] }` (deduped if the relation key already exists), bumps `updated:` on both, makes one git commit, runs `validate-wiki.js all`, and on success transitions the entry to `status: accepted-disagreement`.

- [ ] **Step 1: Create the apply-accept fixture (reuse apply-pick's structure)**

```bash
cp -a tests/fixtures/contradictions/apply-pick-input tests/fixtures/contradictions/apply-accept-input
```

The fixture pages are identical; only the seed yaml differs (created by the test helper below).

- [ ] **Step 2: Add apply-accept tests**

Append to `tests/test_contradictions.sh`:

```bash
# Helper: seed a vault for apply-accept — fixture + one unresolved entry,
# pages [acquisitions, foo].
seed_apply_accept() {
  local v="$1"
  cp -a "$REPO_ROOT/tests/fixtures/contradictions/apply-accept-input/wiki/." "$v/wiki/"
  (cd "$v" && git add . && git commit -qm "fixture content")
  cat > "$v/wiki/.state/contradictions.yaml" <<YAML
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  - id: 2026-05-24-001
    detected_at: 2026-05-24T10:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [foo], a_only_targets: [], b_only_targets: [bar] }
    status: unresolved
    judgment:
      verdict: real-contradiction
      at: 2026-05-24T11:00:00Z
      claim: "Acquirer of Foo"
      assertions:
        - page: wiki/entities/foo.md
          text: "Foo was acquired by Bar in 2023."
          source: raw/article-a.md
        - page: wiki/concepts/acquisitions.md
          text: "Foo was acquired by Baz in 2024."
          source: raw/article-b.md
      rationale: "Two pages, different acquirers."
YAML
  (cd "$v" && git add wiki/.state/contradictions.yaml && git commit -qm "seed contradiction")
  echo "2026-05-24-001"
}

# Test: apply-accept happy path — both pages gain relations.contradicts,
# entry transitions to accepted-disagreement, one commit.
echo ""
echo "Test: apply-accept happy path"
V_AA=$(make_vault vault-apply-accept)
ID=$(seed_apply_accept "$V_AA")
(cd "$V_AA" && node "$SCRIPT" apply-accept --id="$ID" >/dev/null)
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_AA/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status === accepted-disagreement" "accepted-disagreement" "$STATUS"
# Both pages got relations.contradicts.
FOO_CONTRADICTS=$(node -e "let fm=require('js-yaml').load(require('fs').readFileSync('$V_AA/wiki/entities/foo.md','utf8').match(/^---\n([\s\S]*?)\n---/)[1]); process.stdout.write(JSON.stringify(fm.relations?.contradicts || []))")
case "$FOO_CONTRADICTS" in
  *"wiki/concepts/acquisitions.md"*) echo "  PASS: foo.md gained relations.contradicts"; PASS=$((PASS+1));;
  *) echo "  FAIL: foo.md relations.contradicts: $FOO_CONTRADICTS"; FAIL=$((FAIL+1));;
esac
ACQ_CONTRADICTS=$(node -e "let fm=require('js-yaml').load(require('fs').readFileSync('$V_AA/wiki/concepts/acquisitions.md','utf8').match(/^---\n([\s\S]*?)\n---/)[1]); process.stdout.write(JSON.stringify(fm.relations?.contradicts || []))")
case "$ACQ_CONTRADICTS" in
  *"wiki/entities/foo.md"*) echo "  PASS: acquisitions.md gained relations.contradicts"; PASS=$((PASS+1));;
  *) echo "  FAIL: acquisitions.md relations.contradicts: $ACQ_CONTRADICTS"; FAIL=$((FAIL+1));;
esac
COMMIT_COUNT=$(cd "$V_AA" && git log --grep "reconcile: accept-disagreement" --oneline | wc -l | tr -d ' ')
assert_eq "exactly one accept commit" "1" "$COMMIT_COUNT"

# Test: apply-accept idempotent — re-running adds no duplicate target.
echo ""
echo "Test: apply-accept second call is a no-op on the same entry → exit 3"
set +e
(cd "$V_AA" && node "$SCRIPT" apply-accept --id="$ID" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "second apply-accept exits 3 (entry already accepted-disagreement)" "3" "$EXIT"

# Test: apply-accept post-check revert — same pattern as apply-pick:
# pre-stage a dead index row to force validate-wiki exit 2.
echo ""
echo "Test: apply-accept post-check revert"
V_AR=$(make_vault vault-apply-accept-revert)
ID=$(seed_apply_accept "$V_AR")
echo "- [[wiki/concepts/nonexistent]]" >> "$V_AR/wiki/index.md"
(cd "$V_AR" && git add wiki/index.md && git commit -qm "stage dead index row")
set +e
(cd "$V_AR" && node "$SCRIPT" apply-accept --id="$ID" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 2 on post-check structural failure" "2" "$EXIT"
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_AR/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status unchanged after revert" "unresolved" "$STATUS"
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test_contradictions.sh
```

Expected: apply-accept cases FAIL with "apply-accept: not implemented yet".

- [ ] **Step 4: Implement `cmdApplyAccept()`**

Add `cmdApplyAccept()` above `main()`:

```javascript
function addContradictsRelation(absPath, otherPage) {
  let appended = false;
  updateFrontmatter(absPath, (fm) => {
    if (!fm.relations || typeof fm.relations !== 'object') fm.relations = {};
    const list = Array.isArray(fm.relations.contradicts) ? [...fm.relations.contradicts] : [];
    if (!list.includes(otherPage)) {
      list.push(otherPage);
      appended = true;
    }
    fm.relations.contradicts = list;
    fm.updated = todayDate();
  });
  return appended;
}

function cmdApplyAccept(vault, args) {
  if (!args.id) die('apply-accept: --id is required', 2);
  const doc = readState(vault);
  if (!doc) die(`apply-accept: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-accept: id ${args.id} not found`, 3);
  if (entry.status !== 'unresolved' && entry.status !== 'deferred') {
    die(`apply-accept: entry ${args.id} status is ${entry.status}, expected unresolved or deferred`, 3);
  }
  const [a, b] = entry.pages;
  const aAbs = path.join(vault, a);
  const bAbs = path.join(vault, b);
  if (!fs.existsSync(aAbs)) die(`apply-accept: page not found: ${a}`, 3);
  if (!fs.existsSync(bAbs)) die(`apply-accept: page not found: ${b}`, 3);

  addContradictsRelation(aAbs, b);
  addContradictsRelation(bAbs, a);

  const claim = entry.judgment?.claim || '(unknown)';
  const commitMsg = `reconcile: accept-disagreement on ${claim}`;
  const add = run(vault, 'git', ['add', a, b]);
  if (add.status !== 0) die(`git add failed: ${add.stderr}`, 2);
  const commit = run(vault, 'git', ['commit', '-m', commitMsg]);
  if (commit.status !== 0) die(`git commit failed: ${commit.stderr}`, 2);

  const check = validateWikiAll(vault);
  if (check.status === 2) {
    revertHead(vault);
    process.stderr.write(`apply-accept: validate-wiki structural failure — reverted\n${check.stderr}`);
    process.exit(2);
  }
  const sha = gitHeadSha(vault);

  entry.status = 'accepted-disagreement';
  entry.resolution = {
    at: nowIso(),
    commit: sha,
  };
  writeState(vault, doc);
  process.stdout.write(`${sha}\n`);
}
```

Update the `switch` in `main()`:

```javascript
    case 'apply-accept': return cmdApplyAccept(vault, args);
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: all apply-accept tests PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/contradictions.js tests/test_contradictions.sh tests/fixtures/contradictions/apply-accept-input
git commit -m "$(cat <<'EOF'
feat(contradictions): apply-accept subcommand

apply-accept --id annotates both pages with
relations: { contradicts: [other-page] } (deduped), bumps both pages'
updated:, makes one git commit (reconcile: accept-disagreement on <claim>),
runs validate-wiki.js all, and on success transitions the entry to
status: accepted-disagreement with a populated resolution block.

Same auto-revert semantics as apply-pick: on post-check exit 2, the
commit is reverted and the yaml entry stays unresolved/deferred.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Schema-version mismatch test

**Files:**
- Modify: `tests/test_contradictions.sh`
- Create: `tests/fixtures/contradictions/schema-mismatch/...`

`readState()` already enforces `schema_version === 1`. Verify the exit-2 path.

- [ ] **Step 1: Create the schema-mismatch fixture**

```bash
mkdir -p tests/fixtures/contradictions/schema-mismatch/wiki/.state
cat > tests/fixtures/contradictions/schema-mismatch/wiki/.state/contradictions.yaml <<'YAML'
schema_version: 0
generated_by: scripts/contradictions.js
contradictions: []
YAML
```

- [ ] **Step 2: Add the test**

Append to `tests/test_contradictions.sh`:

```bash
# Test: schema_version mismatch → exit 2 with helpful message.
echo ""
echo "Test: schema_version mismatch"
V_SV=$(make_vault vault-schema)
cp "$REPO_ROOT/tests/fixtures/contradictions/schema-mismatch/wiki/.state/contradictions.yaml" "$V_SV/wiki/.state/contradictions.yaml"
set +e
ERR=$( (cd "$V_SV" && node "$SCRIPT" list 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on schema_version mismatch" "2" "$EXIT"
case "$ERR" in
  *"schema_version"*) echo "  PASS: stderr names schema_version"; PASS=$((PASS+1));;
  *) echo "  FAIL: stderr did not mention schema_version: $ERR"; FAIL=$((FAIL+1));;
esac
```

- [ ] **Step 3: Run the test to verify it passes**

```bash
bash tests/test_contradictions.sh
```

Expected: schema-version test PASSes (no implementation change needed — `readState()` already enforces this).

- [ ] **Step 4: Commit**

```bash
git add tests/test_contradictions.sh tests/fixtures/contradictions/schema-mismatch
git commit -m "$(cat <<'EOF'
test(contradictions): assert schema_version mismatch exits 2

readState() already enforces SCHEMA_VERSION === 1 on file load; this
adds the fixture and test case that locks the contract in for future
contributors. Forward-only — v1 fails fast on unknown versions, no
migration path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Update `scripts/status.js` `readContradictions()`

**Files:**
- Modify: `scripts/status.js`
- Modify: `tests/test_status.sh`
- Create: `tests/fixtures/status/contradictions-lifecycle/wiki/.state/contradictions.yaml`

`status.js` currently counts only `status: unresolved` and reports `unjudged_candidates: 0`. Update the predicate to:
- `unjudged_candidates` = count of `status: unjudged`
- `unresolved` = count of `status: unresolved` + `status: deferred` (per spec §5.4)

- [ ] **Step 1: Create the lifecycle-coverage fixture and harness vault**

```bash
mkdir -p tests/fixtures/status/contradictions-lifecycle/wiki/.state
cp tests/fixtures/status/contradictions-populated/wiki/.state/frontmatter-contract.yaml \
   tests/fixtures/status/contradictions-lifecycle/wiki/.state/frontmatter-contract.yaml
cat > tests/fixtures/status/contradictions-lifecycle/wiki/.state/contradictions.yaml <<'YAML'
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  - id: 2026-05-24-001
    pages: [wiki/concepts/a.md, wiki/concepts/b.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [], a_only_targets: [], b_only_targets: [] }
    status: unjudged
  - id: 2026-05-24-002
    pages: [wiki/concepts/c.md, wiki/concepts/d.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [], a_only_targets: [], b_only_targets: [] }
    status: unjudged
  - id: 2026-05-24-003
    pages: [wiki/concepts/e.md, wiki/concepts/f.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [], a_only_targets: [], b_only_targets: [] }
    status: unresolved
  - id: 2026-05-24-004
    pages: [wiki/concepts/g.md, wiki/concepts/h.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [], a_only_targets: [], b_only_targets: [] }
    status: deferred
  - id: 2026-05-24-005
    pages: [wiki/concepts/i.md, wiki/concepts/j.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [], a_only_targets: [], b_only_targets: [] }
    status: not-a-contradiction
  - id: 2026-05-24-006
    pages: [wiki/concepts/k.md, wiki/concepts/l.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [], a_only_targets: [], b_only_targets: [] }
    status: resolved-pick-a
YAML
```

- [ ] **Step 2: Add the lifecycle-counting test to `tests/test_status.sh`**

Insert before `=== Results ===`:

```bash
# Test: status.js counts unjudged + (unresolved + deferred) correctly.
echo ""
echo "Test: status.js contradictions lifecycle predicates"
V_LC=$(make_vault vault-lifecycle)
cp "$REPO_ROOT/tests/fixtures/status/contradictions-lifecycle/wiki/.state/contradictions.yaml" \
   "$V_LC/wiki/.state/contradictions.yaml"
OUT=$( (cd "$V_LC" && node "$REPO_ROOT/scripts/status.js" --json) )
assert_eq "unjudged_candidates === 2" "2" "$(echo "$OUT" | json_path 'contradictions.unjudged_candidates')"
assert_eq "unresolved === 2 (1 unresolved + 1 deferred)" "2" "$(echo "$OUT" | json_path 'contradictions.unresolved')"
assert_eq "contradictions.present === true" "true" "$(echo "$OUT" | json_path 'contradictions.present')"
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test_status.sh
```

Expected: unjudged_candidates assertion FAILs (current value 0); unresolved FAILs (current value 1).

- [ ] **Step 4: Update `readContradictions()` in `scripts/status.js`**

Replace the existing function with:

```javascript
function readContradictions(vault) {
  const doc = readStateYaml(vault, 'contradictions.yaml');
  if (!doc) return { unjudged_candidates: 0, unresolved: 0, present: false };
  const entries = Array.isArray(doc.contradictions) ? doc.contradictions : [];
  let unjudged = 0, unresolved = 0;
  for (const e of entries) {
    if (!e) continue;
    if (e.status === 'unjudged') unjudged += 1;
    else if (e.status === 'unresolved' || e.status === 'deferred') unresolved += 1;
  }
  return { unjudged_candidates: unjudged, unresolved, present: true };
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/test_status.sh
```

Expected: all status tests pass, including the new lifecycle case.

- [ ] **Step 6: Commit**

```bash
git add scripts/status.js tests/test_status.sh tests/fixtures/status/contradictions-lifecycle
git commit -m "$(cat <<'EOF'
feat(status): count contradictions across the CR-007 lifecycle

readContradictions() now counts status: unjudged into unjudged_candidates
and (status: unresolved + status: deferred) into unresolved, per the
CR-007 spec §5.4 predicates. not-a-contradiction and resolved-* entries
count toward neither (they're not actionable).

Locks the JSON contract that the headless cron in
docs/install/headless-driving.md already calls.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Replace `/status reconcile` placeholder in `skills/status/SKILL.md`

**Files:**
- Modify: `skills/status/SKILL.md`

Replace the two-line CR-007 placeholder with the actual `--judge-only` and interactive sub-flow bodies. Bump `allowed-tools` to include `Write` (needed for the rewrite tmpfile).

- [ ] **Step 1: Update the frontmatter `allowed-tools`**

In `skills/status/SKILL.md`, change:

```markdown
allowed-tools: Bash Read
```

to:

```markdown
allowed-tools: Bash Read Write
```

- [ ] **Step 2: Replace the `## /second-brain:status reconcile` section**

In `skills/status/SKILL.md`, find this block:

```markdown
## `/second-brain:status reconcile`

Placeholder until CR-007 lands. Print:

```
/status reconcile is not yet available. CR-007 will implement contradiction
detection. Until then, /second-brain:lint flags candidate contradictions
in its report.
```
```

Replace it with:

```markdown
## `/second-brain:status reconcile` (interactive)

Walk `unresolved` and `deferred` entries; ask the user to pick A, pick B,
accept the disagreement, defer, or stop.

1. List actionable entries:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" list \
     --status=unresolved,deferred --json
   ```

   If `contradictions` is empty, print `nothing to reconcile` and stop.

2. For each entry, print this block to the user:

   ```
   [<id>] Claim: <judgment.claim>
     A. <judgment.assertions[0].page>
        "<judgment.assertions[0].text>"
        source: <judgment.assertions[0].source>
     B. <judgment.assertions[1].page>
        "<judgment.assertions[1].text>"
        source: <judgment.assertions[1].source>
     Rationale: <judgment.rationale>
   Pick (a) A · (b) B · (c) Accept disagreement · (d) Defer · (s) Stop walking
   ```

3. On the user's answer:

   - **`a` or `b` (Pick A / Pick B):**
     - The "winning" page is `judgment.assertions[<choice>].page`; the "losing"
       page is the other one in the entry's `pages` list.
     - Write the rewrite tmpfile at `/tmp/reconcile-<id>.md`. The tmpfile content
       must be the **scoped paragraph(s) that replace the losing page's
       assertion paragraph** — exact prose only, no markdown frontmatter, no
       page-level wrapping. Use the winning assertion's text as the canonical
       claim; preserve any surrounding context from the losing paragraph that
       isn't part of the conflicting assertion.
     - Run:

       ```bash
       node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" apply-pick \
         --id=<id> --winning-page=<winning-page-path> --rewrite=/tmp/reconcile-<id>.md
       ```

     - On script exit 0: capture the printed sha; report success to the user.
     - On script exit 3 (substring matched zero or multiple paragraphs):
       print the script's stderr; defer the entry via
       `node scripts/contradictions.js resolve --id=<id> --kind=defer`;
       continue with the next entry.
     - On script exit 2 (post-check auto-revert): print the stderr; defer the
       entry; continue.

   - **`c` (Accept disagreement):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" apply-accept --id=<id>
     ```

     Same revert-then-defer pattern on exit 2; report sha on success.

   - **`d` (Defer):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" resolve --id=<id> --kind=defer
     ```

   - **`s` (Stop):** break the walk. Any entries already resolved in this pass
     keep their `resolved-*` / `accepted-disagreement` status.

4. After the walk, append one paragraph to `wiki/log.md`:

   ```
   ## [YYYY-MM-DD] reconcile | N resolved (A pick-a, B pick-b), C accepted-disagreement, D deferred
   ```

   Use today's date and the actual counts from the walk.

## `/second-brain:status reconcile --judge-only` (headless)

Cron-safe. Walks `status: unjudged` entries, asks the LLM for a verdict per
pair, writes the result via `contradictions.js judge`, and appends one
`kind: contradiction-judged` entry per pair to `since-review.yaml`.

1. List unjudged entries:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" list --status=unjudged --json
   ```

   If `contradictions` is empty, print `no unjudged candidates` and exit 0.

2. For each entry, read both pages in `pages`. Reason about whether the two
   pages make a real conflicting claim. Two verdicts:

   - **`real-contradiction`** — the pages make conflicting assertions a reader
     should resolve. Produce a freeform `claim` (one short sentence), two
     `assertions` (one per page) with `text` quoting the exact prose substring
     of the conflicting claim plus the `source` from the page's `sources:`
     frontmatter, and a one-line `rationale`. Call:

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" judge \
       --id=<id> --verdict=real-contradiction \
       --data='{"claim":"...","assertions":[{"page":"...","text":"...","source":"..."},{...}],"rationale":"..."}'
     ```

   - **`not-a-contradiction`** — the pages co-exist without conflict (often
     true for shared-entity-prose candidates that are just topically adjacent).
     One-line `rationale`. Call:

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" judge \
       --id=<id> --verdict=not-a-contradiction \
       --data='{"rationale":"..."}'
     ```

3. After each successful `judge`, append a review-log entry so the user can
   audit the headless work later:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" append --kind=contradiction-judged \
     --data='{"id":"<id>","pages":[...],"verdict":"<verdict>"}'
   ```

4. Print a one-line summary per judgment as it lands (no batching — cron logs
   stay readable).

5. On any `judge` exit 3 (e.g. a concurrent run already advanced the entry),
   log + continue; do not abort the pass.

**Crucial:** when producing assertion `text` for the `real-contradiction`
verdict, quote the **exact substring** that appears in the page body. The
interactive `/status reconcile` resolution flow locates the paragraph to
rewrite via this substring; imprecise quotes will cause `apply-pick` to
exit 3 and force a deferral.
```

- [ ] **Step 3: Replace the `## /second-brain:status refresh` placeholder** — only the trailing line needs adjusting, since CR-008 hasn't landed yet. Find:

```markdown
## `/second-brain:status refresh`

Placeholder until CR-008 lands. Print:

```
/status refresh is not yet available. CR-008 will implement staleness review.
Until then, /second-brain:lint flags candidate stale pages in its report.
```
```

Leave this section as-is (CR-008 owns it). No change required for CR-007.

- [ ] **Step 4: Manual smoke check**

Run `/second-brain:status` in a vault with one `unresolved` entry and confirm:

```bash
# Manual: in a fresh vault, seed one unresolved contradiction entry, then:
node "$CLAUDE_PLUGIN_ROOT/scripts/status.js"
# Should report: Contradictions  1 unresolved  (/second-brain:status reconcile)
```

- [ ] **Step 5: Commit**

```bash
git add skills/status/SKILL.md
git commit -m "$(cat <<'EOF'
feat(status): wire CR-007 reconcile sub-flow bodies

Replaces the CR-007 placeholder in /second-brain:status reconcile with:

- Interactive walk over status=unresolved,deferred entries with a-b-c-d-s
  picker, calling apply-pick / apply-accept / resolve --kind=defer for the
  mechanical work. SKILL is prompt-only; never edits wiki files directly.
- --judge-only headless body for cron, calling judge per pair and
  appending kind: contradiction-judged to since-review.yaml.

Bumps allowed-tools to include Write (for the rewrite tmpfile under /tmp/).
Edit stays out — wiki page mutations all flow through contradictions.js.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Add candidates call to `skills/ingest/SKILL.md`

**Files:**
- Modify: `skills/ingest/SKILL.md`

After the existing step 9 ("Append a review-log entry"), insert a new step 10 that scans for contradiction candidates limited to the just-written pages. Renumber the old step 10 ("Report results") to step 11.

- [ ] **Step 1: Locate the insertion point**

In `skills/ingest/SKILL.md`, find the heading `### 10. Report results`. Immediately above it, insert a new section.

- [ ] **Step 2: Insert the new step 10**

Insert this block between step 9 ("Append a review-log entry") and the (current) step 10 ("Report results"):

```markdown
### 10. Scan for contradiction candidates

Now that this source's wiki pages exist, run the cheap candidate scan limited
to just the pages touched, plus their one-hop wikilink neighbours. New
candidates land in `wiki/.state/contradictions.yaml` as `status: unjudged`;
the next `/second-brain:status reconcile --judge-only` cron will judge them.

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" candidates \
  --scope=<comma-separated list of wiki page paths just written>
```

The `--scope` argument is the same `wiki_pages` array `state-sources commit`
recorded into `sources.yaml`. The script handles one-hop neighbour expansion
internally (and caps at 50 pages — hub overflow truncates with a stderr
warning, exit stays 0).

This step does not block ingest and does not append a review-log entry —
candidate enqueueing is a deterministic side-effect, not a user-reviewable
event. Only `judge` and interactive `reconcile` resolutions produce
review-log entries.
```

- [ ] **Step 3: Renumber the old step 10**

Change:

```markdown
### 10. Report results
```

to:

```markdown
### 11. Report results
```

- [ ] **Step 4: Update any cross-references**

Search the rest of the file for "step 10" or `### 10`. There are none in the current version, so this is a no-op confirmation step.

```bash
grep -n "step 10\|### 10" skills/ingest/SKILL.md
```

Expected: no matches.

- [ ] **Step 5: Manual smoke check**

```bash
# In a vault: drop two raw/ files that share an entity, run /second-brain:ingest,
# then check that contradictions.yaml gained candidate entries.
ls -la wiki/.state/contradictions.yaml
node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" list --json | jq '.contradictions | length'
```

Expected: file exists; one or more candidates enqueued.

- [ ] **Step 6: Commit**

```bash
git add skills/ingest/SKILL.md
git commit -m "$(cat <<'EOF'
feat(ingest): scan for contradiction candidates after each source

After step 9 (review-log append), step 10 calls contradictions.js
candidates --scope=<just-written-pages>. The script expands one hop
through wikilink neighbours (capped at 50 pages) and enqueues newly-
detected candidates as status: unjudged. Cron picks them up on the next
/second-brain:status reconcile --judge-only pass.

Ingest does not block on judging; the user sees pending counts on the
dashboard.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Replace `skills/lint/SKILL.md` §2 prose with script calls

**Files:**
- Modify: `skills/lint/SKILL.md`

Lint's existing §2 ("Contradictions") is LLM prose. Replace with deterministic script calls that (a) full-vault scan + enqueue, and (b) report counts.

- [ ] **Step 1: Find the existing §2**

Open `skills/lint/SKILL.md`. The existing §2 reads:

```markdown
### 2. Contradictions

Read pages that share entities or concepts and look for conflicting claims. Flag when:
- Two source summaries make opposing claims about the same topic
- An entity page contains information that conflicts with a source summary
- Dates, figures, or factual claims differ between pages
```

- [ ] **Step 2: Replace it with script calls**

Replace the section with:

```markdown
### 2. Contradictions

Contradiction-finding now flows through `scripts/contradictions.js`. Lint
performs the full-vault candidate scan (enqueueing any new pairs into
`wiki/.state/contradictions.yaml` as `status: unjudged`) and reports the
lifecycle counts back to the user.

```bash
# Full-vault scan: enqueue any newly-detected candidate pairs.
node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" candidates --scope=wiki/
```

```bash
# Report counts across the lifecycle.
node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" list \
  --status=unjudged,unresolved,deferred --json
```

Tally the counts by `status` and surface them under "Warnings" in the
report:

```
Contradictions: N unjudged, M unresolved, K deferred.
Run /second-brain:status reconcile (interactive) or schedule --judge-only via cron.
```

Do **not** read pages to look for prose contradictions in this step — the
script narrows candidates deterministically and the LLM judge pass
(`/second-brain:status reconcile --judge-only`) does the prose-level
filtering. Lint is the trigger for the full-vault scan; the judge pass
is asynchronous.
```

- [ ] **Step 3: Manual smoke check**

```bash
# In a vault with a known candidate pair, run /second-brain:lint and confirm
# the contradictions line appears in the report.
```

- [ ] **Step 4: Commit**

```bash
git add skills/lint/SKILL.md
git commit -m "$(cat <<'EOF'
feat(lint): swap prose §2 for contradictions script calls

Lint's "Contradictions" step was LLM prose ("look for opposing claims").
Replace with deterministic script calls:
- contradictions.js candidates --scope=wiki/ (full-vault enqueue)
- contradictions.js list --status=unjudged,unresolved,deferred --json
  (count reporter)

Lint becomes a small state mutator (it adds new unjudged candidates),
but this consolidates the single-source-of-truth queue and removes a
redundant prose-level scan that the CR-007 pipeline already covers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Update `skills/status/references/status-json-schema.md`

**Files:**
- Modify: `skills/status/references/status-json-schema.md`

Replace the "always 0 in CR-009 / until CR-007 lands" caveats in the `contradictions` section with the lifecycle predicates that CR-007 just locked.

- [ ] **Step 1: Find and replace the `contradictions` section**

Find:

```markdown
### `contradictions`
Read directly from `wiki/.state/contradictions.yaml` (owned by CR-007).
- **`present`** (boolean): `true` if the state file exists; `false` until
  CR-007 lands.
- **`unjudged_candidates`** (integer): always `0` in CR-009. CR-007 may compute
  candidates on-demand rather than persist them; either way the key stays for
  cron-consumer forward compatibility.
- **`unresolved`** (integer): count of entries with `status: unresolved`. CR-007
  owns the per-entry semantics; CR-009 only counts.
```

Replace with:

```markdown
### `contradictions`
Read directly from `wiki/.state/contradictions.yaml` (owned by CR-007).
- **`present`** (boolean): `true` once the state file exists. The file is
  created lazily by the first `contradictions.js candidates` enqueue.
- **`unjudged_candidates`** (integer): count of entries with
  `status: unjudged` — candidates detected by the script but not yet seen by
  the LLM judge. Cron triggers `/second-brain:status reconcile --judge-only`
  when this is > 0.
- **`unresolved`** (integer): count of entries with `status: unresolved` OR
  `status: deferred` — both surface in the interactive `/status reconcile`
  walk. `not-a-contradiction` and `resolved-*` entries count toward neither
  (they are not actionable).
```

- [ ] **Step 2: Commit**

```bash
git add skills/status/references/status-json-schema.md
git commit -m "$(cat <<'EOF'
docs(status): document CR-007 lifecycle predicates in JSON schema

Replaces the CR-009-era "always 0 until CR-007 lands" caveats on
contradictions.{unjudged_candidates,unresolved} with the actual lifecycle
predicates: unjudged_candidates counts status: unjudged, and unresolved
counts (unresolved + deferred). not-a-contradiction and resolved-* are
not counted (not actionable).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: Update `docs/install/headless-driving.md` cron note

**Files:**
- Modify: `docs/install/headless-driving.md`

Change the trailing "no-ops until CR-007 and CR-008 land" note to reflect that CR-007 is live.

- [ ] **Step 1: Find and replace the trailing note**

Find:

```markdown
The `reconcile --judge-only` and `refresh --judge-only` calls are no-ops until
CR-007 and CR-008 land — but the cron shape can be set up now and will start
doing work as soon as those CRs ship.
```

Replace with:

```markdown
The `reconcile --judge-only` call is live; CR-007's judge pass runs against
any `status: unjudged` entries in `wiki/.state/contradictions.yaml` and
writes verdicts back. The `refresh --judge-only` call is still a no-op
until CR-008 lands.
```

- [ ] **Step 2: Commit**

```bash
git add docs/install/headless-driving.md
git commit -m "$(cat <<'EOF'
docs(install): note CR-007 reconcile --judge-only is live

The cron example's trailing caveat said both reconcile and refresh
--judge-only are no-ops. With CR-007 landed, reconcile --judge-only now
runs the candidate-judging pass over status: unjudged entries.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

After all tasks land, the spec requirements should be fully covered. Quick mapping:

| Spec section | Implemented by |
|---|---|
| §4 architecture (contradictions.js + 3 skill touches) | Tasks 1–11, 14–16 |
| §5 contradictions.yaml schema (lifecycle, id format, pages canonicalisation) | Tasks 1–11, 13 |
| §5.4 JSON counting predicates | Task 13 (status.js update) + Task 17 (schema docs) |
| §6 contradictions.js subcommands | Tasks 1–11 (one per subcommand, with apply-pick/apply-accept TDD'd through invariants) |
| §6.4 signal 1 (conflicting-relations) | Task 3 (algorithm concretised in "Decisions locked in") |
| §6.4 signal 2 (shared-entity-prose) | Task 4 (threshold N=5 locked) |
| §6.5 candidate dedupe rule | Task 5 |
| §6.6 atomic write | Tasks 3 onward (writeState helper) |
| §7.1 reconcile --judge-only body | Task 14 |
| §7.2 reconcile interactive body | Task 14 |
| §7.3 allowed-tools bump | Task 14 |
| §8 ingest integration | Task 15 |
| §9 lint integration | Task 16 |
| §10.1 / §10.2 reference doc updates | Tasks 17, 18 |
| §11.1 automated tests (20 numbered cases) | Spread across Tasks 1–13 in the TDD step of each task |
| §12 risks | Behaviourally encoded by the tests (substring invariants, post-check revert, schema mismatch) |

**Type / signature consistency check:**

- `findEntry(doc, id)`, `nowIso()`, `todayDate()`, `pairKey`, `allocateId(doc)`, `writeState(vault, doc)`, `readState(vault)`, `emptyState()`, `readFrontmatter(absPath)`, `walkWikiMarkdown(vault)`, `extractBodyWikilinks(vault, page)`, `resolveWikilinkTarget(vault, token)`, `expandOneHop(vault, seeds)`, `candidateKey(c)`, `signalConflictingRelations(vault, pages)`, `signalSharedEntityProse(vault, pages)`, `splitPageBody(text)`, `locateAssertionParagraph(paragraphs, needle)`, `updateFrontmatter(absPath, mutate)`, `run(vault, cmd, args)`, `gitHeadSha(vault)`, `validateWikiAll(vault)`, `revertHead(vault)`, `addContradictsRelation(absPath, otherPage)` — each defined once, called consistently across tasks.
- Constants: `SCHEMA_VERSION = 1`, `GENERATED_BY = 'scripts/contradictions.js'`, `STATE_FILE = 'wiki/.state/contradictions.yaml'`, `SHARED_LINK_THRESHOLD = 5`, `NEIGHBOUR_CAP = 50`.
- Exit-code semantics: 0 clean, 2 = wrong args / malformed yaml / spawn or git failure / post-check structural failure, 3 = invariant refusal (transition, missing entry, substring miss). Consistent across all subcommands.

**Placeholder scan:** no TODO / TBD / FIXME / "implement later" / "similar to Task N" patterns in the plan text.

**Scope:** focused on one CR. No unrelated refactors (e.g. did not touch `state-sources.js`, `validate-wiki.js`, or `review-log.js` beyond what the integration tests require — both already-landed scripts are consumed via subprocess and not modified).

Plan is complete and ready for execution.
