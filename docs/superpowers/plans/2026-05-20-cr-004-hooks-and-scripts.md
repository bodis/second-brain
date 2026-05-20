# CR-004 Hooks and Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace LLM-prosed structural checks in `lint/SKILL.md` with two deterministic Node scripts (`scripts/validate-wiki.js`, `scripts/sync-index.js`), wire a self-gating Stop hook that runs the validator, and lift the frontmatter contract into a versioned YAML file owned by `onboard`.

**Architecture:** Shared, plugin-wide scripts at `scripts/` (not under any one skill) because lint, `/reorganize` (CR-005), the Stop hook, and `/status` (CR-009) all consume them. `validate-wiki.js` is a single Node file with four subcommands (`frontmatter`, `wikilinks`, `index`, `all`); each subcommand has a documented JSON shape and exit-code semantics (0 clean / 1 warning / 2 structural error). `sync-index.js` is the only opt-in fixer; it is never wired to a hook. Vault detection (requiring **both** `.git/` and `wiki/.state/sources.yaml`) self-gates the universally-fired Stop hook outside second-brain vaults. A new `wiki/.state/frontmatter-contract.yaml` (`schema_version: 1`) declares which keys are required on which paths; `onboard` scaffolds it on every new vault.

**Tech Stack:** Same as CR-002/003 — Node 18+ (CommonJS), `js-yaml` 4.x, `git`, bash test harness using `node -e` for JSON assertions (same pattern as `tests/test_state_sources.sh`). No new dependencies. Schema version starts at `1`.

**Reference spec:** [`docs/cr/CR-004-hooks-and-scripts.md`](../../cr/CR-004-hooks-and-scripts.md)

---

## File Structure

**Create:**
- `scripts/validate-wiki.js` — main validator binary; four subcommands; single file (~400 LOC), same shape as `skills/ingest/scripts/state-sources.js`.
- `scripts/sync-index.js` — opt-in index fixer; single file (~150 LOC).
- `tests/test_validate_wiki.sh` — bash test harness; scaffolds tmp vaults from checked-in fixtures.
- `tests/test_sync_index.sh` — bash test harness for the fixer.
- `tests/fixtures/validate-wiki/clean/` — all-checks-pass fixture (vault skeleton with one valid page).
- `tests/fixtures/validate-wiki/frontmatter-missing-key/` — page missing required `sources` key.
- `tests/fixtures/validate-wiki/frontmatter-bad-date/` — page with malformed `updated` date.
- `tests/fixtures/validate-wiki/wikilink-broken/` — page with a `[[Nonexistent]]` link.
- `tests/fixtures/validate-wiki/wikilink-orphan/` — page with zero inbound links.
- `tests/fixtures/validate-wiki/index-missing-row/` — page on disk but absent from index.
- `tests/fixtures/validate-wiki/index-dead-row/` — index row pointing to a deleted page.
- `tests/fixtures/validate-wiki/not-a-vault/` — directory without `.git/` and without `wiki/.state/sources.yaml`.
- `tests/fixtures/sync-index/drifted/` — fixture for sync-index round-trip test.

**Modify:**
- `.claude-plugin/plugin.json` — add top-level `hooks` block with one `Stop` entry.
- `skills/lint/SKILL.md` — replace §§1, 2, 7 (deterministic checks) with script calls; keep §§3, 4, 5, 6, 8 as LLM-judgment prose.
- `skills/onboard/scripts/onboarding.sh` — scaffold `wiki/.state/frontmatter-contract.yaml`; add to JSON `files` output.
- `tests/test_onboarding.sh` — assert `wiki/.state/frontmatter-contract.yaml` is created.
- `skills/ingest/SKILL.md` — replace the inline frontmatter block in the source-summary template with a one-line pointer to the contract; same for the entity/concept template if present.
- `docs/cr/conventions.md` — add §7 "Script runtime" pinning Node 18+ / `js-yaml`.

No schema bump on `wiki/.state/sources.yaml` (CR-002 schema stays at `1`). The new `frontmatter-contract.yaml` introduces its own `schema_version: 1`.

---

## Task 1: Frontmatter contract file + onboarding scaffolds it

**Files:**
- Modify: `skills/onboard/scripts/onboarding.sh`
- Modify: `tests/test_onboarding.sh`
- Modify: `skills/ingest/SKILL.md`

This task ships the frontmatter contract without yet wiring any reader. The validator (Task 4) will consume it.

- [ ] **Step 1: Add the assertion to `tests/test_onboarding.sh`**

`tests/test_onboarding.sh` uses helpers `assert_file` and `assert_contains` and the variable `$TEST_VAULT` for the materialized vault. Match that style.

Find the existing Test 3 block (`# Test 3: wiki/log.md created with header`) — it ends with `assert_contains "$TEST_VAULT/wiki/log.md" "# Log"` followed by a blank `echo ""`. Insert a new Test 3.5 block right before the existing `# Test 4: Idempotent` line:

```bash
# Test 3.5: frontmatter contract scaffolded (CR-004)
echo "Test 3.5: wiki/.state/frontmatter-contract.yaml"
assert_file "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "schema_version: 1"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "generated_by: scripts/validate-wiki.js"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "sources:"

echo ""
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_onboarding.sh`
Expected: the two new assertions FAIL — `wiki/.state/frontmatter-contract.yaml not created`.

- [ ] **Step 3: Extend `onboarding.sh` to drop the contract file**

Open `skills/onboard/scripts/onboarding.sh`. Find the block that creates `wiki/.state/.gitkeep` (it starts with the comment `# CR-002: the state directory must exist`). Right after that `fi`, append:

```bash
# CR-004: scaffold the frontmatter contract. Versioned; scripts/validate-wiki.js
# treats it as authoritative for which keys are required on which paths.
if [ ! -f "$VAULT_ROOT/wiki/.state/frontmatter-contract.yaml" ]; then
  cat > "$VAULT_ROOT/wiki/.state/frontmatter-contract.yaml" << 'EOF'
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
EOF
  echo "Created wiki/.state/frontmatter-contract.yaml" >&2
else
  echo "wiki/.state/frontmatter-contract.yaml already exists, skipping" >&2
fi
```

Then find the JSON output block at the bottom of `onboarding.sh` (the `cat << JSONEOF` block). In its `"files"` array, add `"wiki/.state/frontmatter-contract.yaml"`. The updated `"files"` array should look like:

```json
  "files": [
    "wiki/index.md",
    "wiki/log.md",
    "wiki/.state/frontmatter-contract.yaml"
  ],
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_onboarding.sh`
Expected: both new assertions PASS. All existing tests still PASS.

- [ ] **Step 5: Update `skills/ingest/SKILL.md` to point at the contract**

Open `skills/ingest/SKILL.md`. Find the frontmatter block inside the "Create source summary page" section (around line 90-96, the block starting with `    ---` and listing `tags:`, `sources:`, `created:`, `updated:`). Add a single sentence above the block:

```markdown
The frontmatter contract (`wiki/.state/frontmatter-contract.yaml`, owned by `scripts/validate-wiki.js`) is the source of truth for required keys; the example below is illustrative.
```

Do not delete the example block — keep it for readability. Just add the pointer sentence above it.

- [ ] **Step 6: Commit**

```bash
git add skills/onboard/scripts/onboarding.sh tests/test_onboarding.sh skills/ingest/SKILL.md
git commit -m "feat(onboard): scaffold frontmatter contract on new vaults"
```

---

## Task 2: Pin script runtime in conventions

**Files:**
- Modify: `docs/cr/conventions.md`

- [ ] **Step 1: Add §7 "Script runtime" to conventions**

Open `docs/cr/conventions.md`. After §6 (Vault layout, ending with the closing backticks of the layout block), append:

```markdown

## 7. Script runtime

All shared scripts under `scripts/` and under any `skills/*/scripts/` directory run on **Node ≥18** with **`js-yaml` 4.x** as the only YAML dependency. Both are declared in the top-level `package.json` (`engines.node`, `dependencies.js-yaml`).

- New CRs that need scripting use the same runtime. Do not introduce Python, Deno, or a different YAML library without amending this convention.
- Scripts are invoked via `node "$CLAUDE_PLUGIN_ROOT/scripts/<name>.js"` from SKILL prompts and hooks, or `node "$CLAUDE_PLUGIN_ROOT/skills/<skill>/scripts/<name>.js"` for skill-private scripts.
- Single-file shape is preferred (see `skills/ingest/scripts/state-sources.js`); split into a `lib/` directory only after a third consumer appears.
```

- [ ] **Step 2: Commit**

```bash
git add docs/cr/conventions.md
git commit -m "docs(conventions): pin script runtime to Node 18 + js-yaml"
```

---

## Task 3: Validator skeleton — arg parsing, vault detection, stop_hook_active guard

**Files:**
- Create: `scripts/validate-wiki.js`
- Create: `tests/test_validate_wiki.sh`
- Create: `tests/fixtures/validate-wiki/not-a-vault/` (empty placeholder dir)
- Create: `tests/fixtures/validate-wiki/clean/` (minimal valid vault skeleton)

This task lands the binary's skeleton: it can parse `all|frontmatter|wikilinks|index` subcommands, detect a vault, honor `stop_hook_active`, and exit `0` from each subcommand as a stub. Subsequent tasks fill in subcommand bodies.

- [ ] **Step 1: Create the `not-a-vault` fixture**

```bash
mkdir -p tests/fixtures/validate-wiki/not-a-vault
echo "# placeholder so the dir is tracked" > tests/fixtures/validate-wiki/not-a-vault/.gitkeep
```

The fixture is deliberately empty of `.git/` and `wiki/.state/sources.yaml` — the validator should refuse to operate on it.

- [ ] **Step 2: Create the `clean` fixture skeleton**

Create these files under `tests/fixtures/validate-wiki/clean/`:

`tests/fixtures/validate-wiki/clean/wiki/.state/sources.yaml`:

```yaml
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
```

`tests/fixtures/validate-wiki/clean/wiki/.state/frontmatter-contract.yaml`:

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

`tests/fixtures/validate-wiki/clean/wiki/index.md`:

```markdown
# Index

## Sources

- [[wiki/sources/example-source]] — example summary

## Entities

## Concepts

## Synthesis
```

`tests/fixtures/validate-wiki/clean/wiki/sources/example-source.md`:

```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Example Source

Body.
```

`tests/fixtures/validate-wiki/clean/wiki/log.md`:

```markdown
# Log
```

`tests/fixtures/validate-wiki/clean/raw/example.md`:

```markdown
example content
```

Add a `.gitkeep` under `tests/fixtures/validate-wiki/clean/wiki/.state/` if needed to ensure git tracks empty dirs; the files above should already be enough.

- [ ] **Step 3: Write the failing test harness**

Create `tests/test_validate_wiki.sh`:

```bash
#!/bin/bash
set -e

# Test: scripts/validate-wiki.js — wiki structural validator.
# Usage: bash tests/test_validate_wiki.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/validate-wiki.js"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/validate-wiki"
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

# Copy a fixture into the tmp dir and git-init it as a real vault.
# Args: $1 = fixture name (under tests/fixtures/validate-wiki/)
# Echoes the absolute path of the materialized vault.
prepare_vault() {
  local fixture="$1"
  local dest="$TEST_DIR/$fixture-$RANDOM"
  cp -R "$FIXTURE_DIR/$fixture" "$dest"
  if [ -d "$dest/wiki/.state" ]; then
    (cd "$dest" \
      && git init -q \
      && git config user.email "t@t" \
      && git config user.name "t" \
      && git config commit.gpgsign false \
      && git add . \
      && git commit -qm "init" >/dev/null)
  fi
  echo "$dest"
}

# Read JSON from stdin and print the value at a dotted path (e.g. "frontmatter.errors.length").
# Uses node -e to keep parity with the test_state_sources.sh pattern.
jq_get() {
  local path="$1"
  node -e "
    let d='';
    process.stdin.on('data', c => d += c);
    process.stdin.on('end', () => {
      let v = JSON.parse(d);
      for (const p of '$path'.split('.')) {
        if (p === 'length') v = v.length;
        else v = v[p];
      }
      process.stdout.write(String(v));
    });
  "
}

echo "=== Test: validate-wiki.js ==="

# Test 1: not-a-vault → all subcommands exit 0 silently.
echo ""
echo "Test 1: not-a-vault self-gates"
V=$(prepare_vault not-a-vault)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" all) 2>&1 )
RC=$?
set -e
assert_eq "not-a-vault exit code 0" "0" "$RC"
assert_eq "not-a-vault produces no output" "" "$OUT"

# Test 2: stop_hook_active in stdin makes `all` exit 0 silently.
echo ""
echo "Test 2: stop_hook_active guard"
V=$(prepare_vault clean)
set +e
OUT=$(echo '{"stop_hook_active": true}' | (cd "$V" && node "$SCRIPT" all) 2>&1)
RC=$?
set -e
assert_eq "stop_hook_active exit code 0" "0" "$RC"
assert_eq "stop_hook_active produces no output" "" "$OUT"

# Test 3: unknown subcommand exits nonzero with a helpful error.
echo ""
echo "Test 3: unknown subcommand"
V=$(prepare_vault clean)
set +e
ERR=$( (cd "$V" && node "$SCRIPT" bogus) 2>&1 1>/dev/null )
RC=$?
set -e
[ "$RC" -ne 0 ] && echo "  PASS: unknown subcommand exits nonzero ($RC)" && PASS=$((PASS + 1)) \
                || (echo "  FAIL: unknown subcommand exit code"; echo "    actual: $RC"; FAIL=$((FAIL + 1)))
echo "$ERR" | grep -q "unknown subcommand" \
  && echo "  PASS: unknown subcommand stderr names the problem" && PASS=$((PASS + 1)) \
  || (echo "  FAIL: unknown subcommand stderr"; echo "    actual: $ERR"; FAIL=$((FAIL + 1)))

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
```

Make it executable:

```bash
chmod +x tests/test_validate_wiki.sh
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bash tests/test_validate_wiki.sh`
Expected: every test FAILs because `scripts/validate-wiki.js` does not exist yet (node errors out).

- [ ] **Step 5: Create the validator skeleton**

Create `scripts/validate-wiki.js`:

```javascript
#!/usr/bin/env node
'use strict';

/**
 * scripts/validate-wiki.js — wiki structural validator.
 *
 * Subcommands: frontmatter | wikilinks | index | all
 * Each subcommand supports --json for machine consumers.
 *
 * Exit codes (shared across subcommands):
 *   0 = clean
 *   1 = warnings (broken link, orphan page, missing index row)
 *   2 = structural error (frontmatter invalid, dead index row, contract mismatch)
 *
 * Vault detection: walks up from CLAUDE_PROJECT_DIR (or cwd) for a directory
 * containing both `.git/` and `wiki/.state/sources.yaml`. If none found, exits
 * 0 silently — this is how the universally-fired Stop hook self-gates outside
 * second-brain vaults.
 *
 * `all` honors `stop_hook_active: true` on stdin per Claude Code hook docs.
 */

const fs = require('fs');
const path = require('path');

const SUBCOMMANDS = ['frontmatter', 'wikilinks', 'index', 'all'];

function die(msg, code = 1) {
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
  const cmd = argv[0];
  let json = false;
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === '--json') json = true;
    else die(`unknown argument: ${argv[i]}`);
  }
  return { cmd, json };
}

// Read stdin synchronously and return a parsed JSON object, or {} if nothing
// was piped. Only called from `all` to honor the stop_hook_active guard.
function readStdinJson() {
  if (process.stdin.isTTY) return {};
  try {
    const raw = fs.readFileSync(0, 'utf8');
    if (!raw.trim()) return {};
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function runAll(_vault, _json) {
  // Stub — Task 7 fills this in by composing the three subcommands.
  return { code: 0, output: '' };
}

function runFrontmatter(_vault, _json) {
  // Stub — Task 4 fills this in.
  return { code: 0, output: '' };
}

function runWikilinks(_vault, _json) {
  // Stub — Task 5 fills this in.
  return { code: 0, output: '' };
}

function runIndex(_vault, _json) {
  // Stub — Task 6 fills this in.
  return { code: 0, output: '' };
}

function emit(result) {
  if (result.output) process.stdout.write(result.output);
  process.exit(result.code);
}

function main() {
  const { cmd, json } = parseArgs(process.argv.slice(2));
  if (!SUBCOMMANDS.includes(cmd)) {
    die(`unknown subcommand: ${cmd}; expected one of ${SUBCOMMANDS.join(', ')}`, 1);
  }

  const startDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const vault = findVaultRoot(startDir);
  if (!vault) {
    // Not a second-brain vault — exit 0 silently. This is the Stop hook
    // self-gate: the hook fires globally, but no work happens outside a vault.
    process.exit(0);
  }

  if (cmd === 'all') {
    const stdin = readStdinJson();
    if (stdin.stop_hook_active === true) process.exit(0);
    return emit(runAll(vault, json));
  }
  if (cmd === 'frontmatter') return emit(runFrontmatter(vault, json));
  if (cmd === 'wikilinks') return emit(runWikilinks(vault, json));
  if (cmd === 'index') return emit(runIndex(vault, json));
}

main();
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/test_validate_wiki.sh`
Expected: all 3 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/validate-wiki.js tests/test_validate_wiki.sh tests/fixtures/validate-wiki/
git commit -m "feat(scripts): scaffold validate-wiki.js with vault detection and stop_hook_active guard"
```

---

## Task 4: `frontmatter` subcommand

**Files:**
- Modify: `scripts/validate-wiki.js` (replace the `runFrontmatter` stub)
- Modify: `tests/test_validate_wiki.sh` (add tests 4–7)
- Create: `tests/fixtures/validate-wiki/frontmatter-missing-key/`
- Create: `tests/fixtures/validate-wiki/frontmatter-bad-date/`

- [ ] **Step 1: Create the `frontmatter-missing-key` fixture**

Copy the `clean/` fixture as a starting point, then break it:

```bash
cp -R tests/fixtures/validate-wiki/clean tests/fixtures/validate-wiki/frontmatter-missing-key
```

Then overwrite `tests/fixtures/validate-wiki/frontmatter-missing-key/wiki/sources/example-source.md` with:

```markdown
---
tags: [example]
created: 2026-05-20
updated: 2026-05-20
---

# Example Source

Body — missing the required `sources` key.
```

(The required `sources` key is absent.)

- [ ] **Step 2: Create the `frontmatter-bad-date` fixture**

```bash
cp -R tests/fixtures/validate-wiki/clean tests/fixtures/validate-wiki/frontmatter-bad-date
```

Overwrite `tests/fixtures/validate-wiki/frontmatter-bad-date/wiki/sources/example-source.md` with:

```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: not-a-date
---

# Example Source

Body — `updated` is not a YYYY-MM-DD date.
```

- [ ] **Step 3: Add Tests 4–7 to `tests/test_validate_wiki.sh`**

Find the line `echo ""` immediately before `echo "=== Results: $PASS passed, $FAIL failed ==="` and insert above it:

```bash
# Test 4: clean fixture → frontmatter exits 0 with empty errors.
echo ""
echo "Test 4: frontmatter on clean fixture"
V=$(prepare_vault clean)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "clean exit code 0" "0" "$RC"
assert_eq "clean errors length 0" "0" "$(echo "$OUT" | jq_get errors.length)"

# Test 5: missing required key → exit 2, errors[].key === 'sources'.
echo ""
echo "Test 5: frontmatter missing required key"
V=$(prepare_vault frontmatter-missing-key)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "missing-key exit code 2" "2" "$RC"
assert_eq "errors[0].key is sources" "sources" "$(echo "$OUT" | jq_get errors.0.key)"

# Test 6: bad-date → exit 2, errors[].key === 'updated', errors[].problem mentions date.
echo ""
echo "Test 6: frontmatter bad date"
V=$(prepare_vault frontmatter-bad-date)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "bad-date exit code 2" "2" "$RC"
assert_eq "errors[0].key is updated" "updated" "$(echo "$OUT" | jq_get errors.0.key)"

# Test 7: human-readable summary on stderr when --json absent.
echo ""
echo "Test 7: frontmatter human summary on stderr"
V=$(prepare_vault frontmatter-missing-key)
set +e
ERR=$( (cd "$V" && node "$SCRIPT" frontmatter) 2>&1 1>/dev/null )
RC=$?
set -e
assert_eq "no-json exit code 2" "2" "$RC"
echo "$ERR" | grep -q "missing required key 'sources'" \
  && echo "  PASS: stderr names missing key" && PASS=$((PASS + 1)) \
  || (echo "  FAIL: stderr did not name missing key"; echo "    actual: $ERR"; FAIL=$((FAIL + 1)))
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bash tests/test_validate_wiki.sh`
Expected: Tests 4–7 FAIL (the stub returns code 0 with empty output).

- [ ] **Step 5: Implement `runFrontmatter` in `scripts/validate-wiki.js`**

At the top of `scripts/validate-wiki.js`, just below the existing `const path = require('path');`, add:

```javascript
const yaml = require('js-yaml');
```

Below the `parseArgs` function, add these helpers (private to the file — same pattern as `state-sources.js`):

```javascript
// Walk a directory recursively and yield .md files (POSIX-style vault-relative paths).
function* walkMarkdown(vault, subdir) {
  const abs = path.join(vault, subdir);
  if (!fs.existsSync(abs)) return;
  for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const child = path.join(subdir, entry.name);
    if (entry.isDirectory()) {
      yield* walkMarkdown(vault, child);
    } else if (entry.isFile() && entry.name.endsWith('.md')) {
      yield child.split(path.sep).join('/');
    }
  }
}

// Read the first ---fenced YAML block at the top of a markdown file.
// Returns { ok: true, data, raw } on parse, { ok: false, problem } on error.
function readFrontmatter(absPath) {
  let text;
  try { text = fs.readFileSync(absPath, 'utf8'); }
  catch (err) { return { ok: false, problem: `read failed: ${err.message}` }; }
  // Match a leading `---` line, then content, then a closing `---` line.
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!m) return { ok: false, problem: 'no frontmatter block (expected leading `---` fence)' };
  let data;
  try { data = yaml.load(m[1]); }
  catch (err) { return { ok: false, problem: `yaml parse error: ${err.message}` }; }
  if (data === null || typeof data !== 'object') {
    return { ok: false, problem: 'frontmatter is not a mapping' };
  }
  return { ok: true, data, raw: m[1] };
}

function loadContract(vault) {
  const p = path.join(vault, 'wiki', '.state', 'frontmatter-contract.yaml');
  if (!fs.existsSync(p)) {
    die(`frontmatter contract missing: ${p}; re-run /second-brain:onboard to scaffold it`, 2);
  }
  let doc;
  try { doc = yaml.load(fs.readFileSync(p, 'utf8')); }
  catch (err) { die(`failed to parse frontmatter contract: ${err.message}`, 2); }
  if (!doc || doc.schema_version !== 1) {
    die(`frontmatter contract has unknown schema_version (${doc && doc.schema_version}); ` +
        `validator understands version 1 — upgrade the plugin or re-scaffold the vault`, 2);
  }
  return doc;
}

// Resolve the contract's `targets` globs to a flat list of vault-relative .md paths,
// excluding anything listed in `exempt`. Our globs are restricted to the documented
// shape `wiki/<subdir>/**/*.md`, so we can implement them as a recursive walk under
// each `wiki/<subdir>/` rather than pulling in a full glob library.
function expandTargets(vault, contract) {
  const exempt = new Set(contract.exempt || []);
  const out = [];
  for (const glob of contract.targets || []) {
    const m = glob.match(/^wiki\/([^/]+)\/\*\*\/\*\.md$/);
    if (!m) {
      die(`frontmatter contract target glob not supported: ${glob}; ` +
          `use the form 'wiki/<subdir>/**/*.md'`, 2);
    }
    const subdir = `wiki/${m[1]}`;
    for (const p of walkMarkdown(vault, subdir)) {
      if (!exempt.has(p)) out.push(p);
    }
  }
  return out;
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function validateKey(value, spec) {
  if (spec.type === 'list[string]') {
    if (!Array.isArray(value)) return 'expected a list of strings';
    if (!value.every(x => typeof x === 'string')) return 'list contains non-string entries';
    if (!spec.may_be_empty && value.length === 0) return 'list must not be empty';
    return null;
  }
  if (spec.type === 'date') {
    // js-yaml parses YAML-native dates into Date objects. The contract requires
    // the source text to be YYYY-MM-DD, so re-render and re-check.
    if (value instanceof Date) {
      const iso = value.toISOString().slice(0, 10);
      return DATE_RE.test(iso) ? null : `date does not match ${spec.format || 'YYYY-MM-DD'}`;
    }
    if (typeof value === 'string' && DATE_RE.test(value)) return null;
    return `expected ${spec.format || 'YYYY-MM-DD'} date`;
  }
  return `unknown contract type: ${spec.type}`;
}
```

Then replace the `runFrontmatter` stub with:

```javascript
function runFrontmatter(vault, json) {
  const contract = loadContract(vault);
  const targets = expandTargets(vault, contract);
  const errors = [];
  for (const rel of targets) {
    const abs = path.join(vault, rel);
    const fm = readFrontmatter(abs);
    if (!fm.ok) {
      errors.push({ path: rel, key: null, problem: fm.problem });
      continue;
    }
    for (const [key, spec] of Object.entries(contract.required || {})) {
      if (!(key in fm.data)) {
        errors.push({ path: rel, key, problem: `missing required key '${key}'` });
        continue;
      }
      const problem = validateKey(fm.data[key], spec);
      if (problem) errors.push({ path: rel, key, problem });
    }
  }
  const code = errors.length > 0 ? 2 : 0;
  if (json) {
    return { code, output: JSON.stringify({ errors, warnings: [] }, null, 2) + '\n' };
  }
  if (errors.length === 0) return { code: 0, output: '' };
  // Human summary on stderr, no stdout.
  for (const e of errors) {
    process.stderr.write(`frontmatter: ${e.path} ${e.problem}\n`);
  }
  return { code, output: '' };
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_validate_wiki.sh`
Expected: all tests (1–7) PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/validate-wiki.js tests/test_validate_wiki.sh tests/fixtures/validate-wiki/frontmatter-missing-key tests/fixtures/validate-wiki/frontmatter-bad-date
git commit -m "feat(validate-wiki): implement frontmatter subcommand with versioned contract"
```

---

## Task 5: `wikilinks` subcommand

**Files:**
- Modify: `scripts/validate-wiki.js` (replace the `runWikilinks` stub)
- Modify: `tests/test_validate_wiki.sh` (add tests 8–11)
- Create: `tests/fixtures/validate-wiki/wikilink-broken/`
- Create: `tests/fixtures/validate-wiki/wikilink-orphan/`

Resolution rules (per the spec):
1. Bare name `[[Concept Name]]` — case-insensitive basename match anywhere under `wiki/`.
2. Wiki path `[[wiki/concepts/concept-name]]` — file must exist under `wiki/`.
3. Documentation path `[[src/documentation/confluence/api/auth]]` — file must exist under `src/documentation/`.

Anything else is broken.

- [ ] **Step 1: Create the `wikilink-broken` fixture**

```bash
cp -R tests/fixtures/validate-wiki/clean tests/fixtures/validate-wiki/wikilink-broken
```

Overwrite `tests/fixtures/validate-wiki/wikilink-broken/wiki/sources/example-source.md` with:

```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Example Source

This page links to [[Nonexistent Concept]] which does not exist.
```

- [ ] **Step 2: Create the `wikilink-orphan` fixture**

```bash
cp -R tests/fixtures/validate-wiki/clean tests/fixtures/validate-wiki/wikilink-orphan
```

Add a second source page that nothing links to:

`tests/fixtures/validate-wiki/wikilink-orphan/wiki/sources/lonely.md`:

```markdown
---
tags: [example]
sources: [raw/lonely.md]
created: 2026-05-20
updated: 2026-05-20
---

# Lonely

Nothing links here.
```

`tests/fixtures/validate-wiki/wikilink-orphan/raw/lonely.md`:

```markdown
lonely content
```

The existing `wiki/index.md` does have `[[wiki/sources/example-source]]` (which counts as an inbound link to `example-source.md`), but nothing references `lonely.md`. To make `lonely.md` a true orphan, also remove any reference to it from `wiki/index.md` (don't add one). Confirm by reading the file.

- [ ] **Step 3: Add Tests 8–11 to `tests/test_validate_wiki.sh`**

Find the position right before `echo "=== Results"` and insert:

```bash
# Test 8: clean fixture → wikilinks exits 0.
echo ""
echo "Test 8: wikilinks on clean fixture"
V=$(prepare_vault clean)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
assert_eq "clean wikilinks exit 0" "0" "$RC"
assert_eq "clean broken length 0" "0" "$(echo "$OUT" | jq_get broken.length)"
assert_eq "clean orphans length 0" "0" "$(echo "$OUT" | jq_get orphans.length)"

# Test 9: broken link → exit 1, broken[].target names the unresolved link.
echo ""
echo "Test 9: wikilinks broken link"
V=$(prepare_vault wikilink-broken)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
assert_eq "broken exit 1" "1" "$RC"
assert_eq "broken[0].target is Nonexistent Concept" "Nonexistent Concept" "$(echo "$OUT" | jq_get broken.0.target)"
assert_eq "broken[0].from is example source" "wiki/sources/example-source.md" "$(echo "$OUT" | jq_get broken.0.from)"

# Test 10: orphan page → exit 1, orphans[].path names the lonely page, broken empty.
echo ""
echo "Test 10: wikilinks orphan page"
V=$(prepare_vault wikilink-orphan)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
assert_eq "orphan exit 1" "1" "$RC"
assert_eq "orphan broken length 0" "0" "$(echo "$OUT" | jq_get broken.length)"
assert_eq "orphan orphans[0].path is lonely" "wiki/sources/lonely.md" "$(echo "$OUT" | jq_get orphans.0.path)"

# Test 11: bare-name wikilink resolves case-insensitively.
echo ""
echo "Test 11: bare-name resolution is case-insensitive"
V=$(prepare_vault clean)
# Add a concept page and link to it from a new source with mixed case.
mkdir -p "$V/wiki/concepts"
cat > "$V/wiki/concepts/widget.md" <<'EOF'
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Widget
EOF
cat > "$V/wiki/sources/has-link.md" <<'EOF'
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Has Link

See [[WIDGET]] for details.
EOF
(cd "$V" && git add . && git commit -qm "add widget+link" >/dev/null)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
# Widget is no longer orphan because has-link.md → WIDGET resolves to widget.md.
# example-source.md may or may not be orphan depending on index.md. We assert
# the broken list is empty and `wiki/concepts/widget.md` is not in orphans.
assert_eq "case-insensitive broken length 0" "0" "$(echo "$OUT" | jq_get broken.length)"
echo "$OUT" | grep -q '"wiki/concepts/widget.md"' \
  && (echo "  FAIL: widget should not be orphan after WIDGET link"; FAIL=$((FAIL + 1))) \
  || (echo "  PASS: widget resolved via case-insensitive bare-name match"; PASS=$((PASS + 1)))
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bash tests/test_validate_wiki.sh`
Expected: Tests 8–11 FAIL (the stub returns `code: 0, output: ''` so `jq_get broken.length` fails to parse).

- [ ] **Step 5: Implement `runWikilinks`**

In `scripts/validate-wiki.js`, just below the `validateKey` helper added in Task 4, add:

```javascript
// Match every [[...]] occurrence. Allow only target + optional `|alias` within
// the brackets; pipe-aliases keep just the target. Reject patterns with
// embedded newlines.
const WIKILINK_RE = /\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]/g;

function extractWikilinks(absPath) {
  let text;
  try { text = fs.readFileSync(absPath, 'utf8'); }
  catch { return []; }
  const out = [];
  let m;
  WIKILINK_RE.lastIndex = 0;
  while ((m = WIKILINK_RE.exec(text)) !== null) {
    out.push(m[1].trim());
  }
  return out;
}

// Build a case-insensitive index of basename → vault-relative path for every
// .md file under wiki/. Returns Map<lowercased-basename, vault-relative-path>.
function buildBareNameIndex(vault) {
  const idx = new Map();
  for (const rel of walkMarkdown(vault, 'wiki')) {
    const base = path.basename(rel, '.md').toLowerCase();
    // Last writer wins is fine — bare-name collisions are a vault problem the
    // user should resolve, and the wikilinks check is not the place to flag it.
    idx.set(base, rel);
  }
  return idx;
}

// Resolve a wikilink target against the three rules. Returns the resolved
// vault-relative path (e.g. 'wiki/concepts/foo.md') or null if unresolved.
function resolveWikilink(target, vault, bareIndex) {
  // Rule 2: wiki path — `wiki/...` (no extension).
  if (target.startsWith('wiki/')) {
    const abs = path.join(vault, target + '.md');
    if (fs.existsSync(abs)) return target + '.md';
    return null;
  }
  // Rule 3: documentation path — `src/documentation/...` (no extension).
  if (target.startsWith('src/documentation/')) {
    const abs = path.join(vault, target + '.md');
    if (fs.existsSync(abs)) return target + '.md';
    return null;
  }
  // Rule 1: bare name (case-insensitive basename match anywhere under wiki/).
  const hit = bareIndex.get(target.toLowerCase());
  if (hit) return hit;
  return null;
}

// Subdirs of wiki/ whose pages should be checked for inbound links. Top-level
// wiki/index.md and wiki/log.md are not in scope for the orphan check.
const ORPHAN_ROOTS = ['wiki/sources', 'wiki/entities', 'wiki/concepts', 'wiki/synthesis'];

function isOrphanCandidate(rel) {
  return ORPHAN_ROOTS.some(root => rel === root + '.md' || rel.startsWith(root + '/'));
}
```

Then replace the `runWikilinks` stub with:

```javascript
function runWikilinks(vault, json) {
  const bareIndex = buildBareNameIndex(vault);
  // Walk every page under wiki/ (including index.md and log.md — links from
  // them count as inbound to the target).
  const pages = [...walkMarkdown(vault, 'wiki')];
  const broken = [];
  const inbound = new Map(); // resolved-target-path -> count
  for (const rel of pages) {
    const abs = path.join(vault, rel);
    for (const target of extractWikilinks(abs)) {
      const resolved = resolveWikilink(target, vault, bareIndex);
      if (!resolved) {
        broken.push({ from: rel, target });
      } else {
        inbound.set(resolved, (inbound.get(resolved) || 0) + 1);
      }
    }
  }
  const orphans = [];
  for (const rel of pages) {
    if (!isOrphanCandidate(rel)) continue;
    if ((inbound.get(rel) || 0) === 0) orphans.push({ path: rel });
  }
  const code = (broken.length > 0 || orphans.length > 0) ? 1 : 0;
  if (json) {
    return { code, output: JSON.stringify({ broken, orphans }, null, 2) + '\n' };
  }
  if (code === 0) return { code: 0, output: '' };
  process.stderr.write(`wikilinks: ${broken.length} broken, ${orphans.length} orphan\n`);
  return { code, output: '' };
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_validate_wiki.sh`
Expected: all tests (1–11) PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/validate-wiki.js tests/test_validate_wiki.sh tests/fixtures/validate-wiki/wikilink-broken tests/fixtures/validate-wiki/wikilink-orphan
git commit -m "feat(validate-wiki): implement wikilinks subcommand with three-form resolution"
```

---

## Task 6: `index` subcommand

**Files:**
- Modify: `scripts/validate-wiki.js` (replace the `runIndex` stub)
- Modify: `tests/test_validate_wiki.sh` (add tests 12–14)
- Create: `tests/fixtures/validate-wiki/index-missing-row/`
- Create: `tests/fixtures/validate-wiki/index-dead-row/`

`index` semantics (per the spec):
- Every `.md` file under `wiki/{sources,entities,concepts,synthesis}/**` must have a row in `wiki/index.md`.
- No row may point to a file that does not resolve.
- Exit `0` clean, `1` missing rows only, `2` dead rows (with or without missing rows).

- [ ] **Step 1: Create the `index-missing-row` fixture**

```bash
cp -R tests/fixtures/validate-wiki/clean tests/fixtures/validate-wiki/index-missing-row
```

Add a concept page that is NOT in `wiki/index.md`:

`tests/fixtures/validate-wiki/index-missing-row/wiki/concepts/widget.md`:

```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Widget

A concept page with no index row.
```

Confirm `tests/fixtures/validate-wiki/index-missing-row/wiki/index.md` is unchanged from the clean fixture (only has the example-source row).

- [ ] **Step 2: Create the `index-dead-row` fixture**

```bash
cp -R tests/fixtures/validate-wiki/clean tests/fixtures/validate-wiki/index-dead-row
```

Overwrite `tests/fixtures/validate-wiki/index-dead-row/wiki/index.md` with:

```markdown
# Index

## Sources

- [[wiki/sources/example-source]] — example summary
- [[wiki/sources/deleted-page]] — points to a page that does not exist

## Entities

## Concepts

## Synthesis
```

- [ ] **Step 3: Add Tests 12–14 to `tests/test_validate_wiki.sh`**

Insert before the `=== Results` line:

```bash
# Test 12: clean fixture → index exits 0.
echo ""
echo "Test 12: index on clean fixture"
V=$(prepare_vault clean)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" index --json) )
RC=$?
set -e
assert_eq "clean index exit 0" "0" "$RC"
assert_eq "clean missing_rows length 0" "0" "$(echo "$OUT" | jq_get missing_rows.length)"
assert_eq "clean dead_rows length 0" "0" "$(echo "$OUT" | jq_get dead_rows.length)"

# Test 13: missing row → exit 1, missing_rows[] includes the orphaned file path.
echo ""
echo "Test 13: index missing row"
V=$(prepare_vault index-missing-row)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" index --json) )
RC=$?
set -e
assert_eq "missing-row exit 1" "1" "$RC"
assert_eq "missing_rows[0] is widget" "wiki/concepts/widget.md" "$(echo "$OUT" | jq_get missing_rows.0)"
assert_eq "missing-row dead_rows length 0" "0" "$(echo "$OUT" | jq_get dead_rows.length)"

# Test 14: dead row → exit 2, dead_rows[].target names the unresolved target.
echo ""
echo "Test 14: index dead row"
V=$(prepare_vault index-dead-row)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" index --json) )
RC=$?
set -e
assert_eq "dead-row exit 2" "2" "$RC"
assert_eq "dead_rows[0].target names deleted-page" "wiki/sources/deleted-page" "$(echo "$OUT" | jq_get dead_rows.0.target)"
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bash tests/test_validate_wiki.sh`
Expected: Tests 12–14 FAIL.

- [ ] **Step 5: Implement `runIndex`**

In `scripts/validate-wiki.js`, below the helpers added in Task 5, add:

```javascript
// Parse `wiki/index.md` and return the list of wikilink targets it contains.
// We deliberately treat every [[target]] anywhere in the file as a row entry;
// the doc-section structure is for humans, not for the validator.
function readIndexTargets(vault) {
  const abs = path.join(vault, 'wiki', 'index.md');
  if (!fs.existsSync(abs)) return [];
  return extractWikilinks(abs); // already trimmed
}

const INDEXED_ROOTS = ['wiki/sources', 'wiki/entities', 'wiki/concepts', 'wiki/synthesis'];
```

Then replace the `runIndex` stub with:

```javascript
function runIndex(vault, json) {
  const bareIndex = buildBareNameIndex(vault);
  const indexTargets = readIndexTargets(vault);

  // Set of resolved vault-relative paths the index covers.
  const covered = new Set();
  const deadRows = [];
  for (const target of indexTargets) {
    const resolved = resolveWikilink(target, vault, bareIndex);
    if (resolved) covered.add(resolved);
    else deadRows.push({ target });
  }

  // Every .md file under the indexed roots must be covered.
  const missingRows = [];
  for (const root of INDEXED_ROOTS) {
    for (const rel of walkMarkdown(vault, root)) {
      if (!covered.has(rel)) missingRows.push(rel);
    }
  }

  let code = 0;
  if (deadRows.length > 0) code = 2;
  else if (missingRows.length > 0) code = 1;

  if (json) {
    return {
      code,
      output: JSON.stringify({ missing_rows: missingRows, dead_rows: deadRows }, null, 2) + '\n',
    };
  }
  if (code === 0) return { code: 0, output: '' };
  if (deadRows.length > 0) {
    for (const d of deadRows) process.stderr.write(`index: dead row -> ${d.target}\n`);
  }
  if (missingRows.length > 0) {
    process.stderr.write(`index: ${missingRows.length} missing row(s); run sync-index.js to fix\n`);
  }
  return { code, output: '' };
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_validate_wiki.sh`
Expected: all tests (1–14) PASS.

- [ ] **Step 7: Commit**

```bash
git add scripts/validate-wiki.js tests/test_validate_wiki.sh tests/fixtures/validate-wiki/index-missing-row tests/fixtures/validate-wiki/index-dead-row
git commit -m "feat(validate-wiki): implement index subcommand"
```

---

## Task 7: `all` aggregator

**Files:**
- Modify: `scripts/validate-wiki.js` (replace the `runAll` stub)
- Modify: `tests/test_validate_wiki.sh` (add tests 15–16)

- [ ] **Step 1: Add Tests 15–16**

Insert before the `=== Results` line:

```bash
# Test 15: all on clean fixture → exit 0, aggregated JSON has all three keys.
echo ""
echo "Test 15: all on clean fixture"
V=$(prepare_vault clean)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" all --json) )
RC=$?
set -e
assert_eq "all clean exit 0" "0" "$RC"
assert_eq "all clean frontmatter.errors length 0" "0" "$(echo "$OUT" | jq_get frontmatter.errors.length)"
assert_eq "all clean wikilinks.broken length 0" "0" "$(echo "$OUT" | jq_get wikilinks.broken.length)"
assert_eq "all clean index.missing_rows length 0" "0" "$(echo "$OUT" | jq_get index.missing_rows.length)"

# Test 16: all returns max of child exit codes (frontmatter=2 wins).
echo ""
echo "Test 16: all aggregates worst exit code"
V=$(prepare_vault frontmatter-missing-key)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" all --json) )
RC=$?
set -e
assert_eq "all worst-code exit 2" "2" "$RC"
assert_eq "all frontmatter errors > 0" "1" "$(echo "$OUT" | jq_get frontmatter.errors.length)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_validate_wiki.sh`
Expected: Tests 15–16 FAIL (the stub returns `code: 0, output: ''`).

- [ ] **Step 3: Implement `runAll`**

Replace the `runAll` stub with:

```javascript
function runAll(vault, json) {
  // Each child returns {code, output}. We re-run them in JSON mode regardless
  // of the outer --json flag so we can compose the result.
  const fm = runFrontmatter(vault, true);
  const wl = runWikilinks(vault, true);
  const ix = runIndex(vault, true);

  const parsed = {
    frontmatter: JSON.parse(fm.output || '{"errors":[],"warnings":[]}'),
    wikilinks: JSON.parse(wl.output || '{"broken":[],"orphans":[]}'),
    index: JSON.parse(ix.output || '{"missing_rows":[],"dead_rows":[]}'),
  };
  const code = Math.max(fm.code, wl.code, ix.code);

  if (json) {
    return { code, output: JSON.stringify(parsed, null, 2) + '\n' };
  }
  if (code === 0) return { code: 0, output: '' };
  // Human summary on stderr — one line per child with non-zero exit.
  if (fm.code !== 0) {
    for (const e of parsed.frontmatter.errors) {
      process.stderr.write(`frontmatter: ${e.path} ${e.problem}\n`);
    }
  }
  if (wl.code !== 0) {
    process.stderr.write(
      `wikilinks: ${parsed.wikilinks.broken.length} broken, ` +
      `${parsed.wikilinks.orphans.length} orphan\n`
    );
  }
  if (ix.code !== 0) {
    if (parsed.index.dead_rows.length > 0) {
      for (const d of parsed.index.dead_rows) {
        process.stderr.write(`index: dead row -> ${d.target}\n`);
      }
    }
    if (parsed.index.missing_rows.length > 0) {
      process.stderr.write(
        `index: ${parsed.index.missing_rows.length} missing row(s); run sync-index.js to fix\n`
      );
    }
  }
  return { code, output: '' };
}
```

Note: `runAll` calls the child runners with `json=true` and parses their output. The children's `process.stderr.write` calls would fire too — that's harmless here because the parent re-prints the summary. To suppress the double-print, the children should not write to stderr when called from `all`. Wrap the existing `process.stderr.write` calls in `runFrontmatter`, `runWikilinks`, and `runIndex` so that they only fire when the caller asked for human output. The cleanest way: pass a third arg `quiet`.

Update the three runners to accept `(vault, json, quiet = false)` and gate every `process.stderr.write(...)` line on `if (!quiet)`. Then in `runAll`, change the three calls to:

```javascript
const fm = runFrontmatter(vault, true, true);
const wl = runWikilinks(vault, true, true);
const ix = runIndex(vault, true, true);
```

Also update the top-level `main()` callers to pass `false` (or omit the arg, since the default is `false`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_validate_wiki.sh`
Expected: all tests (1–16) PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/validate-wiki.js tests/test_validate_wiki.sh
git commit -m "feat(validate-wiki): implement all aggregator subcommand"
```

---

## Task 8: `sync-index.js` opt-in fixer

**Files:**
- Create: `scripts/sync-index.js`
- Create: `tests/test_sync_index.sh`
- Create: `tests/fixtures/sync-index/drifted/`

Behavior (per the spec):
- Reads filesystem reality under `wiki/{sources,entities,concepts,synthesis}/`.
- Rewrites `wiki/index.md` so every page has a row and no row is dead.
- Preserves existing row text where the row still resolves to a real page.
- Adds a minimal row `- [[wiki/<subdir>/<slug>]]` for pages that have no row.
- Removes dead rows.
- Sorts rows alphabetically under each section.
- Idempotent: running twice produces no change.
- Exit 0 always (no failure case besides system errors).

Section mapping: `wiki/sources/**` → "## Sources", `wiki/entities/**` → "## Entities", `wiki/concepts/**` → "## Concepts", `wiki/synthesis/**` → "## Synthesis".

- [ ] **Step 1: Create the `drifted` fixture**

Use `tests/fixtures/sync-index/drifted/` (new top-level dir under `tests/fixtures/`).

Files to create:

`tests/fixtures/sync-index/drifted/wiki/.state/sources.yaml`:

```yaml
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
```

`tests/fixtures/sync-index/drifted/wiki/.state/frontmatter-contract.yaml`:

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
  tags: { type: list[string], may_be_empty: true }
  sources: { type: list[string], may_be_empty: false }
  created: { type: date, format: YYYY-MM-DD }
  updated: { type: date, format: YYYY-MM-DD }
unknown_keys: allowed
```

`tests/fixtures/sync-index/drifted/wiki/index.md` (intentionally drifted — has a dead row and missing rows):

```markdown
# Index

## Sources

- [[wiki/sources/existing]] — kept summary
- [[wiki/sources/deleted-page]] — dead row, target does not exist

## Entities

## Concepts

## Synthesis
```

`tests/fixtures/sync-index/drifted/wiki/sources/existing.md`:

```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Existing
```

`tests/fixtures/sync-index/drifted/wiki/concepts/widget.md` (no row in index → must be added):

```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Widget
```

`tests/fixtures/sync-index/drifted/raw/example.md`:

```markdown
example
```

`tests/fixtures/sync-index/drifted/wiki/log.md`:

```markdown
# Log
```

- [ ] **Step 2: Write the failing test harness**

Create `tests/test_sync_index.sh`:

```bash
#!/bin/bash
set -e

# Test: scripts/sync-index.js — opt-in wiki/index.md fixer.
# Usage: bash tests/test_sync_index.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/sync-index.js"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/sync-index"
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

prepare_vault() {
  local fixture="$1"
  local dest="$TEST_DIR/$fixture-$RANDOM"
  cp -R "$FIXTURE_DIR/$fixture" "$dest"
  (cd "$dest" \
    && git init -q \
    && git config user.email "t@t" \
    && git config user.name "t" \
    && git config commit.gpgsign false \
    && git add . \
    && git commit -qm "init" >/dev/null)
  echo "$dest"
}

echo "=== Test: sync-index.js ==="

# Test 1: drifted vault → first run rewrites index; second run is a no-op.
echo ""
echo "Test 1: drifted → first run fixes, second run is a no-op"
V=$(prepare_vault drifted)
# First run: should rewrite. Exit 0.
set +e
OUT1=$( (cd "$V" && node "$SCRIPT") )
RC1=$?
set -e
assert_eq "first run exit 0" "0" "$RC1"
INDEX_AFTER_FIRST=$(cat "$V/wiki/index.md")
grep -q "widget" "$V/wiki/index.md" \
  && echo "  PASS: widget row added" && PASS=$((PASS + 1)) \
  || (echo "  FAIL: widget row not added"; echo "    index: $INDEX_AFTER_FIRST"; FAIL=$((FAIL + 1)))
grep -q "deleted-page" "$V/wiki/index.md" \
  && (echo "  FAIL: dead row not removed"; FAIL=$((FAIL + 1))) \
  || (echo "  PASS: dead row removed"; PASS=$((PASS + 1)))
grep -q "kept summary" "$V/wiki/index.md" \
  && echo "  PASS: existing row preserved" && PASS=$((PASS + 1)) \
  || (echo "  FAIL: existing row dropped"; FAIL=$((FAIL + 1)))

# Second run: must be idempotent.
set +e
OUT2=$( (cd "$V" && node "$SCRIPT") )
RC2=$?
set -e
assert_eq "second run exit 0" "0" "$RC2"
INDEX_AFTER_SECOND=$(cat "$V/wiki/index.md")
assert_eq "second run produces identical index" "$INDEX_AFTER_FIRST" "$INDEX_AFTER_SECOND"

# Test 2: after sync, validate-wiki.js index reports clean.
echo ""
echo "Test 2: validate-wiki.js index clean after sync"
set +e
RC=$( (cd "$V" && node "$REPO_ROOT/scripts/validate-wiki.js" index --json) >/dev/null 2>&1; echo $? )
set -e
assert_eq "validate-wiki index exit 0 after sync" "0" "$RC"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
```

Make it executable:

```bash
chmod +x tests/test_sync_index.sh
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test_sync_index.sh`
Expected: every test FAILs because `scripts/sync-index.js` does not exist.

- [ ] **Step 4: Create `scripts/sync-index.js`**

```javascript
#!/usr/bin/env node
'use strict';

/**
 * scripts/sync-index.js — opt-in fixer for wiki/index.md.
 *
 * Reads filesystem reality under wiki/{sources,entities,concepts,synthesis}/
 * and rewrites wiki/index.md so that:
 *   - every .md file in those subdirs has a row,
 *   - no row points to a non-existent file,
 *   - existing row text (e.g. one-line summaries) is preserved where the row
 *     still resolves,
 *   - rows are sorted alphabetically under each section header.
 *
 * Idempotent: a second consecutive run produces no changes.
 * Never invoked by a hook — only by lint when the user opts in.
 */

const fs = require('fs');
const path = require('path');

function die(msg, code = 1) {
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

function* walkMarkdown(vault, subdir) {
  const abs = path.join(vault, subdir);
  if (!fs.existsSync(abs)) return;
  for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const child = path.join(subdir, entry.name);
    if (entry.isDirectory()) yield* walkMarkdown(vault, child);
    else if (entry.isFile() && entry.name.endsWith('.md'))
      yield child.split(path.sep).join('/');
  }
}

const SECTIONS = [
  { header: '## Sources', root: 'wiki/sources' },
  { header: '## Entities', root: 'wiki/entities' },
  { header: '## Concepts', root: 'wiki/concepts' },
  { header: '## Synthesis', root: 'wiki/synthesis' },
];

const WIKILINK_RE = /\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]/g;

// Parse the existing wiki/index.md into a map: section-header -> array of
// raw row lines (each starting with `- `). Anything outside a known section
// header (like the title line `# Index`) is preserved as a preamble.
function parseIndex(text) {
  const lines = text.split(/\r?\n/);
  const result = { preamble: [], sections: {} };
  for (const s of SECTIONS) result.sections[s.header] = [];
  let currentHeader = null;
  for (const line of lines) {
    if (SECTIONS.some(s => s.header === line.trim())) {
      currentHeader = line.trim();
      continue;
    }
    if (currentHeader === null) {
      result.preamble.push(line);
    } else {
      if (line.startsWith('- ')) result.sections[currentHeader].push(line);
      // Drop blank lines and other prose between rows — sync regenerates them.
    }
  }
  return result;
}

// For a given row text, return the first wikilink target, or null.
function targetOfRow(row) {
  WIKILINK_RE.lastIndex = 0;
  const m = WIKILINK_RE.exec(row);
  return m ? m[1].trim() : null;
}

// Resolve a target against the vault. Returns vault-relative .md path or null.
// Bare names are matched case-insensitively against all .md basenames under wiki/.
function resolveTarget(target, vault, bareIndex) {
  if (target.startsWith('wiki/')) {
    return fs.existsSync(path.join(vault, target + '.md')) ? target + '.md' : null;
  }
  if (target.startsWith('src/documentation/')) {
    return fs.existsSync(path.join(vault, target + '.md')) ? target + '.md' : null;
  }
  return bareIndex.get(target.toLowerCase()) || null;
}

function buildBareIndex(vault) {
  const idx = new Map();
  for (const rel of walkMarkdown(vault, 'wiki')) {
    idx.set(path.basename(rel, '.md').toLowerCase(), rel);
  }
  return idx;
}

function main() {
  const startDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const vault = findVaultRoot(startDir);
  if (!vault) die('not a second-brain vault (no .git/ + wiki/.state/sources.yaml above cwd)', 2);

  const indexPath = path.join(vault, 'wiki', 'index.md');
  const original = fs.existsSync(indexPath) ? fs.readFileSync(indexPath, 'utf8') : '';
  const parsed = parseIndex(original);
  const bareIndex = buildBareIndex(vault);

  // Build the desired state per section.
  const out = [];
  if (parsed.preamble.length > 0) {
    // Strip trailing blank lines from preamble for canonical formatting.
    while (parsed.preamble.length > 0 && parsed.preamble[parsed.preamble.length - 1] === '') {
      parsed.preamble.pop();
    }
    out.push(...parsed.preamble);
  } else {
    out.push('# Index');
  }
  out.push('');

  for (const s of SECTIONS) {
    out.push(s.header);
    out.push('');

    // Map: covered file path -> existing row text (to preserve summaries).
    const covered = new Map();
    for (const row of parsed.sections[s.header]) {
      const target = targetOfRow(row);
      if (!target) continue;
      const resolved = resolveTarget(target, vault, bareIndex);
      if (resolved && resolved.startsWith(s.root + '/')) covered.set(resolved, row);
      // Dead rows (resolved === null) are dropped.
      // Rows that resolve into a different section are dropped (canonical form).
    }

    // Find every .md under this section's root.
    const onDisk = [...walkMarkdown(vault, s.root)].sort();
    for (const rel of onDisk) {
      if (covered.has(rel)) {
        out.push(covered.get(rel));
      } else {
        const slug = rel.slice(s.root.length + 1, -3); // strip `<root>/` and `.md`
        out.push(`- [[${s.root}/${slug}]]`);
      }
    }
    out.push('');
  }

  // Trim trailing blank lines and finish with one newline.
  while (out.length > 0 && out[out.length - 1] === '') out.pop();
  const result = out.join('\n') + '\n';

  if (result !== original) {
    fs.writeFileSync(indexPath, result);
    process.stdout.write('updated wiki/index.md\n');
  } else {
    process.stdout.write('no changes\n');
  }
}

main();
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_sync_index.sh`
Expected: all tests PASS, including the idempotency assertion and the post-sync `validate-wiki.js index` clean check.

- [ ] **Step 6: Commit**

```bash
git add scripts/sync-index.js tests/test_sync_index.sh tests/fixtures/sync-index
git commit -m "feat(scripts): add opt-in sync-index.js fixer"
```

---

## Task 9: Wire Stop hook in plugin manifest

**Files:**
- Modify: `.claude-plugin/plugin.json`

The current `.claude-plugin/plugin.json` is:

```json
{
  "name": "second-brain",
  "version": "0.2.0",
  "description": "LLM-maintained personal knowledge base for Obsidian. Drop raw sources into a folder; the librarian compiles them into a structured wiki.",
  "author": { "name": "Tamás Bódis" },
  "homepage": "https://github.com/bodist/second-brain",
  "repository": "https://github.com/bodist/second-brain"
}
```

- [ ] **Step 1: Bump version and add hooks block**

Replace the contents of `.claude-plugin/plugin.json` with:

```json
{
  "name": "second-brain",
  "version": "0.3.0",
  "description": "LLM-maintained personal knowledge base for Obsidian. Drop raw sources into a folder; the librarian compiles them into a structured wiki.",
  "author": { "name": "Tamás Bódis" },
  "homepage": "https://github.com/bodist/second-brain",
  "repository": "https://github.com/bodist/second-brain",
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

- [ ] **Step 2: Bump matching version in `package.json`**

Open `package.json` and bump `"version": "0.2.0"` → `"version": "0.3.0"` so the two manifests stay in lockstep (CR-001 convention — both file headers point at the same `0.x.0` series).

- [ ] **Step 3: Smoke-test the hook command manually**

The harness can't reliably end-to-end test a Claude Code Stop hook, so verify the wired command runs by hand:

```bash
# Inside a real vault root (the project itself qualifies if wiki/.state/sources.yaml is present
# — otherwise the validator silently exits 0):
CLAUDE_PLUGIN_ROOT="$PWD" node "$CLAUDE_PLUGIN_ROOT/scripts/validate-wiki.js" all
echo "exit=$?"
```

Expected: exit code `0`, `1`, or `2` depending on vault state — no node tracebacks, no missing-file errors. If the validator dies because `wiki/.state/sources.yaml` is missing in the working directory, that's expected (`findVaultRoot` returns null → exit 0 silently). Re-test inside a fixture if needed:

```bash
T=$(mktemp -d) && cp -R tests/fixtures/validate-wiki/clean/* "$T/" \
  && (cd "$T" && git init -q && git add . && git commit -qm init) \
  && CLAUDE_PLUGIN_ROOT="$PWD" node "$PWD/scripts/validate-wiki.js" all
echo "exit=$?"
```

Expected: prints nothing, exit `0`.

- [ ] **Step 4: Re-run the full validator test suite**

Run: `bash tests/test_validate_wiki.sh && bash tests/test_sync_index.sh && bash tests/test_state_sources.sh && bash tests/test_onboarding.sh`
Expected: all tests PASS — version bumps and JSON manifest edits must not regress earlier work.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json package.json
git commit -m "feat(plugin): wire Stop hook to validate-wiki.js all"
```

---

## Task 10: Refactor `skills/lint/SKILL.md` to call scripts

**Files:**
- Modify: `skills/lint/SKILL.md`

The deterministic checks (§1 broken wikilinks, §2 orphans, §7 index consistency) become two script calls. The judgment checks (§3 contradictions, §4 stale claims, §5 missing pages, §6 missing x-refs, §8 data gaps) stay as prose. CR-007/008 will lift some of those into their own skills later; not in scope here.

- [ ] **Step 1: Rewrite §1 (broken wikilinks)**

In `skills/lint/SKILL.md`, replace the entire `### 1. Broken wikilinks` block (lines 18–28 in the original — the prose plus the `grep -roh` code block) with:

```markdown
### 1. Broken wikilinks and orphan pages

Run the validator and report what it finds:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/validate-wiki.js" wikilinks --json
```

The JSON has two keys:
- `broken[]` — `{from, target}` entries where `[[target]]` does not resolve under any of the three rules (bare name, `wiki/...` path, `src/documentation/...` path).
- `orphans[]` — `{path}` entries for pages under `wiki/{sources,entities,concepts,synthesis}/` with zero inbound `[[…]]` links.

Present both arrays grouped together. For each `broken` entry, suggest either fixing the link or creating the target page (treat as a "Missing pages" candidate — see §5). For each `orphan`, judge whether it's intentionally standalone or should be linked from somewhere thematically related.
```
````

- [ ] **Step 2: Delete §2 (orphan pages)**

The old `### 2. Orphan pages` block (lines 30–37) is now folded into §1's output. Delete the entire section. Re-number subsequent sections so §3 becomes §2, §4 becomes §3, etc. Result:

- §1 broken wikilinks + orphans (new combined section above)
- §2 contradictions (was §3)
- §3 stale claims (was §4)
- §4 missing pages (was §5)
- §5 missing cross-references (was §6)
- §6 index consistency (was §7 — rewritten below)
- §7 data gaps (was §8)

When renumbering, update only the numeric prefixes in section headers; do not touch the prose unless the section is being rewritten.

- [ ] **Step 3: Rewrite the new §6 (index consistency)**

Replace the prose under the new `### 6. Index consistency` heading with:

```markdown
### 6. Index consistency

Run the validator:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/validate-wiki.js" index --json
```

The JSON has two keys:
- `missing_rows[]` — vault-relative paths of pages on disk that have no row in `wiki/index.md`.
- `dead_rows[]` — `{target}` entries from `wiki/index.md` whose wikilink does not resolve.

If `missing_rows` is non-empty, offer to run the fixer:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/sync-index.js"
```

`sync-index.js` adds a placeholder row for each missing page (`- [[wiki/<subdir>/<slug>]]`) and removes dead rows. It preserves existing row summaries. Idempotent. After it runs, ask the user whether to flesh out the placeholder rows with one-line summaries.

If `dead_rows` is non-empty, treat it as a structural error: the index references pages that don't exist. Confirm with the user whether the pages were deleted (then remove the rows) or moved (then update the rows).
```
````

- [ ] **Step 4: Update the "Errors" subsection of the Report Format**

The original `### Errors (must fix)` list mentions "Index entries pointing to missing pages". That stays — it now corresponds to `dead_rows`. Also keep "Broken wikilinks" since some broken wikilinks point at pages that were renamed/deleted, which is still an error. Update the wording to reference the validator's terminology so the LLM cross-references the JSON keys when composing the report.

Find the `### Errors (must fix)` list and replace it with:

```markdown
### Errors (must fix)
- Frontmatter structural problems (`validate-wiki.js frontmatter` exit 2)
- Index entries pointing to non-existent pages (`index.dead_rows`)
- Contradictions between pages
```

- [ ] **Step 5: Mention the Stop hook in "When to Lint"**

At the bottom of the file, find `### When to Lint` and prepend a bullet so it reads:

```markdown
## When to Lint

- **Implicit**: the Stop hook runs `validate-wiki.js all` at the end of every session and flags structural errors automatically. Lint as a deliberate pass is for the judgment-heavy items below (contradictions, stale claims, suggested cross-references).
- **After every 10 ingests** — catches cross-reference gaps while they're fresh
- **Monthly at minimum** — catches stale claims and orphan pages over time
- **Before major queries** — ensures the wiki is healthy before you rely on it for analysis
```

- [ ] **Step 6: Commit**

```bash
git add skills/lint/SKILL.md
git commit -m "refactor(lint): replace prose checks with validate-wiki.js calls"
```

---

## Task 11: Final sweep — README + spec status

**Files:**
- Modify: `README.md` (only if it documents the lint surface)
- Modify: `docs/cr/CR-004-hooks-and-scripts.md` (mark resolved if the spec has a status section; otherwise skip)

- [ ] **Step 1: Sanity-check README references**

Grep the top-level `README.md` for any mention of `lint`, `audit`, `validate`, or hook behavior:

```bash
grep -n -E "lint|audit|validate|hook" README.md
```

If any line still describes the old prose-driven lint surface (e.g. "the LLM scans for broken wikilinks"), update that sentence to reference the validator and the Stop hook. If the README is silent on these topics, skip — do not invent new prose.

- [ ] **Step 2: Update CR status note (if applicable)**

If `docs/cr/CR-004-hooks-and-scripts.md` has a frontmatter or trailing "Status" line, append:

```markdown
**Status:** Implemented in plan `docs/superpowers/plans/2026-05-20-cr-004-hooks-and-scripts.md`.
```

If no Status line exists, skip — do not add new sections.

- [ ] **Step 3: Final full test run**

```bash
bash tests/test_state_sources.sh
bash tests/test_onboarding.sh
bash tests/test_register_plugin.sh
bash tests/test_validate_wiki.sh
bash tests/test_sync_index.sh
```

Expected: every script ends with `=== Results: N passed, 0 failed ===` (or equivalent green output for the existing tests).

- [ ] **Step 4: Commit**

```bash
# Only stage files that actually changed in steps 1–2.
git add README.md docs/cr/CR-004-hooks-and-scripts.md 2>/dev/null || true
# If nothing changed, this commit is empty and should be skipped.
git diff --cached --quiet || git commit -m "docs: cross-reference CR-004 implementation"
```
