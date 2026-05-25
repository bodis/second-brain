# CR-005 Reorganize Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/second-brain:reorganize <direction>` — a user-triggered skill that proposes structural improvements to the wiki (merge fragmented concepts, recategorize drifted pages, mark superseded source-summaries, introduce parent pages, type relations) and applies the user-confirmed subset with per-move git commits, per-move `validate-wiki.js` checks, and an automatic revert on structural failure.

**Architecture:** A new skill-private script `skills/reorganize/scripts/reorganize.js` (single file, ~700 LOC, same shape as `skills/ingest/scripts/state-sources.js`) owns all mechanical work — file renames, link rewrites, frontmatter edits, index sync, per-move commits, and revert. Five "apply" subcommands (`move-page`, `merge-page`, `mark-covered`, `parent-create`, `relations-add`), one shortlist subcommand with five `--kind`s (`candidates --kind <merge|recategorize|cover|parent|relations>`), one baseline subcommand (`begin`), and one validation gate (`validate-or-revert`). The SKILL prompt orchestrates Propose → Confirm → Apply, owns judgment, writes merged-body and parent-body tmpfiles when needed, and parses the user's pick list. One additive frontmatter contract change: a new optional `relations:` map (kebab-case relation name → list of wikilink targets), validated structurally by `validate-wiki.js frontmatter` and resolved as wikilinks by `validate-wiki.js wikilinks`.

**Tech Stack:** Same as CR-004 — Node 18+ (CommonJS), `js-yaml` 4.x (already a dep), `git` shelled via `child_process.spawnSync`. No new packages. Bash test harness modeled on `tests/test_state_sources.sh` (programmatic vault construction) and `tests/test_validate_wiki.sh` (fixture-based for validator changes).

**Reference spec:** [`docs/superpowers/specs/2026-05-20-cr-005-reorganize-skill-design.md`](../specs/2026-05-20-cr-005-reorganize-skill-design.md). CR: [`docs/cr/CR-005-reorganize-skill.md`](../../cr/CR-005-reorganize-skill.md).

---

## File Structure

**Create:**
- `skills/reorganize/SKILL.md` — Propose/Confirm/Apply prompt; ~150 lines; mirrors `skills/lint/SKILL.md` shape.
- `skills/reorganize/scripts/reorganize.js` — main script; subcommands `begin | candidates | move-page | merge-page | mark-covered | parent-create | relations-add | validate-or-revert`.
- `tests/test_reorganize.sh` — bash test harness; programmatic vault construction.
- `tests/fixtures/validate-wiki/relations-valid/` — fixture: page with a valid `relations:` map (used by Task 1).
- `tests/fixtures/validate-wiki/relations-bad-shape/` — fixture: page where `relations:` is not a map-of-list-of-strings (Task 1).
- `tests/fixtures/validate-wiki/relations-broken-target/` — fixture: page with a `relations:` target that does not resolve (Task 2).

**Modify:**
- `scripts/validate-wiki.js` — add `relations:` structural check to `frontmatter` subcommand; extend `wikilinks` subcommand to also resolve `relations:` targets; add `source` field to `broken[]` entries.
- `skills/onboard/scripts/onboarding.sh` — extend the contract heredoc with one new `optional:` block declaring `relations:`.
- `tests/test_onboarding.sh` — assert the contract file now contains the `optional:` block with `relations:`.
- `tests/test_validate_wiki.sh` — three new test cases (cases 12, 13, and 14 per spec §10.1): structural relations validation, target resolution, optional-key acceptance.

No schema bump on either `wiki/.state/sources.yaml` (stays `1`) or `wiki/.state/frontmatter-contract.yaml` (stays `1`; the change is additive).

---

## Task 1: Frontmatter contract — add optional `relations:` key + structural validation

**Files:**
- Modify: `scripts/validate-wiki.js`
- Modify: `skills/onboard/scripts/onboarding.sh`
- Modify: `tests/test_onboarding.sh`
- Create: `tests/fixtures/validate-wiki/relations-valid/`
- Create: `tests/fixtures/validate-wiki/relations-bad-shape/`
- Modify: `tests/test_validate_wiki.sh`

This task makes `relations:` an optional, structurally-validated frontmatter key. It does **not** yet resolve relations targets as wikilinks — Task 2 does that.

- [ ] **Step 1: Create the `relations-valid` fixture**

Make these files (mirror the layout of `tests/fixtures/validate-wiki/clean/` — same `.state/` structure):

`tests/fixtures/validate-wiki/relations-valid/wiki/.state/sources.yaml`:
```yaml
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
```

`tests/fixtures/validate-wiki/relations-valid/wiki/.state/frontmatter-contract.yaml`:
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
optional:
  relations:
    type: map[string,list[string]]
unknown_keys: allowed
```

`tests/fixtures/validate-wiki/relations-valid/wiki/index.md`:
```markdown
# Index

## Sources

- [[wiki/sources/example-source]]

## Entities

## Concepts

## Synthesis
```

`tests/fixtures/validate-wiki/relations-valid/wiki/log.md`:
```markdown
# Log
```

`tests/fixtures/validate-wiki/relations-valid/wiki/sources/example-source.md`:
```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
relations:
  refines: [wiki/sources/example-source]
  see-also: []
---

# Example Source

Body.
```

`tests/fixtures/validate-wiki/relations-valid/raw/example.md`:
```markdown
example
```

(The `relations:` value lists a self-reference and an empty list — both are structurally valid; target resolution is Task 2's concern.)

- [ ] **Step 2: Create the `relations-bad-shape` fixture**

Same files as above, except the page frontmatter has a malformed `relations:`:

`tests/fixtures/validate-wiki/relations-bad-shape/wiki/sources/example-source.md`:
```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
relations:
  refines: "wiki/sources/example-source"
---

# Example Source

Body.
```

(`refines:` is a bare string, not a list — that violates `type: map[string,list[string]]`.)

All other files are identical to the `relations-valid` fixture.

- [ ] **Step 3: Add fixture-using test cases to `tests/test_validate_wiki.sh`**

Open `tests/test_validate_wiki.sh`. Find the last numbered test (`Test N: …`) at the end of the file, just before the `echo "=== Summary ==="` block. Append two new tests right before that summary:

```bash
# Test: frontmatter accepts a valid relations: map (CR-005)
echo ""
echo "Test: relations-valid fixture passes frontmatter check"
V=$(prepare_vault relations-valid)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "relations-valid frontmatter exit code"  "0" "$RC"
ERR_COUNT=$(echo "$OUT" | jq_get "errors.length")
assert_eq "relations-valid: 0 errors"              "0" "$ERR_COUNT"

# Test: frontmatter rejects a malformed relations: map (CR-005)
echo ""
echo "Test: relations-bad-shape fixture fails frontmatter check"
V=$(prepare_vault relations-bad-shape)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "relations-bad-shape frontmatter exit code"  "2" "$RC"
ERR_COUNT=$(echo "$OUT" | jq_get "errors.length")
assert_eq "relations-bad-shape: 1 error"               "1" "$ERR_COUNT"
ERR_KEY=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).errors[0].key))")
assert_eq "relations-bad-shape: error key is 'relations'"  "relations" "$ERR_KEY"
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `bash tests/test_validate_wiki.sh`
Expected: the two new tests FAIL — the current validator does not load `contract.optional` and does not recognize `type: map[string,list[string]]`. `relations-valid` may still pass by accident (the validator only checks required keys), but `relations-bad-shape` will be wrongly accepted (exit 0 instead of 2).

- [ ] **Step 5: Add the `optional:` reader and `map[string,list[string]]` type to the validator**

Open `scripts/validate-wiki.js`.

Find the `validateKey` function (currently handles `list[string]` and `date`). Add a new branch above the trailing `return 'unknown contract type'` line:

```javascript
  if (spec.type === 'map[string,list[string]]') {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      return 'expected a map of string keys to lists of strings';
    }
    for (const [k, v] of Object.entries(value)) {
      if (typeof k !== 'string') return `relation name '${k}' must be a string`;
      if (!Array.isArray(v)) return `relation '${k}' must be a list of strings`;
      if (!v.every(x => typeof x === 'string')) return `relation '${k}' has non-string entries`;
    }
    return null;
  }
```

Then find `runFrontmatter` and locate the `for (const [key, spec] of Object.entries(contract.required || {}))` loop. Right after that loop (still inside the outer `for (const rel of targets)` loop), add a second loop for `optional`:

```javascript
    for (const [key, spec] of Object.entries(contract.optional || {})) {
      if (!(key in fm.data)) continue;  // optional — skip if absent
      const problem = validateKey(fm.data[key], spec);
      if (problem) errors.push({ path: rel, key, problem });
    }
```

- [ ] **Step 6: Run validator tests to verify they pass**

Run: `bash tests/test_validate_wiki.sh`
Expected: both new tests PASS. All existing tests still PASS.

- [ ] **Step 7: Add the `optional:` block to the onboarding scaffold**

Open `skills/onboard/scripts/onboarding.sh`. Find the contract heredoc (starts with `cat > "$VAULT_ROOT/wiki/.state/frontmatter-contract.yaml" << 'EOF'`). Inside the YAML body, between the `required:` block (ends with the `updated:` entry's `format: YYYY-MM-DD` line) and the final `unknown_keys: allowed` line, insert:

```yaml
optional:
  relations:
    type: map[string,list[string]]
```

The block placement matters: it must appear after `required:` and before `unknown_keys:` to keep the file readable.

- [ ] **Step 8: Update the onboarding test to assert the new block**

Open `tests/test_onboarding.sh`. Find the existing Test 3.5 (`# Test 3.5: frontmatter contract scaffolded`). Append two more assertions to that block, after the existing `assert_contains` for `sources:`:

```bash
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "optional:"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "relations:"
```

- [ ] **Step 9: Run the onboarding test to verify it passes**

Run: `bash tests/test_onboarding.sh`
Expected: all assertions PASS, including the two new ones.

- [ ] **Step 10: Commit**

```bash
git add scripts/validate-wiki.js skills/onboard/scripts/onboarding.sh \
        tests/test_onboarding.sh tests/test_validate_wiki.sh \
        tests/fixtures/validate-wiki/relations-valid \
        tests/fixtures/validate-wiki/relations-bad-shape
git commit -m "feat(validator): structurally validate optional relations: map"
```

---

## Task 2: Wikilinks validator — resolve `relations:` targets

**Files:**
- Modify: `scripts/validate-wiki.js`
- Create: `tests/fixtures/validate-wiki/relations-broken-target/`
- Modify: `tests/test_validate_wiki.sh`

The `wikilinks` subcommand currently emits `broken[]` entries `{from, target}` for unresolved `[[wikilinks]]`. This task adds: every value in every page's `relations:` map is also resolved against the same three-rule resolver, and unresolved entries are added to `broken[]` with a new `source: "relation"` field. Existing wikilink entries gain `source: "wikilink"`.

- [ ] **Step 1: Create the `relations-broken-target` fixture**

Identical to `relations-valid` from Task 1, except the page frontmatter contains an unresolved target:

`tests/fixtures/validate-wiki/relations-broken-target/wiki/sources/example-source.md`:
```markdown
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
relations:
  refines: [wiki/concepts/does-not-exist]
---

# Example Source

Body referring to [[example-source]] so it isn't orphan.
```

All other files identical to `relations-valid`.

- [ ] **Step 2: Add test cases for relation-target resolution**

Open `tests/test_validate_wiki.sh`. After the two tests added in Task 1, append:

```bash
# Test: wikilinks flags unresolved relations: targets (CR-005 §10.1.12)
echo ""
echo "Test: relations-broken-target fixture flags broken relation target"
V=$(prepare_vault relations-broken-target)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
assert_eq "relations-broken-target wikilinks exit code" "1" "$RC"
BROKEN_COUNT=$(echo "$OUT" | jq_get "broken.length")
assert_eq "relations-broken-target: 1 broken entry"     "1" "$BROKEN_COUNT"
BROKEN_SOURCE=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).broken[0].source))")
assert_eq "relations-broken-target: source is 'relation'" "relation" "$BROKEN_SOURCE"
BROKEN_TARGET=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).broken[0].target))")
assert_eq "relations-broken-target: target matches" "wiki/concepts/does-not-exist" "$BROKEN_TARGET"

# Test: existing prose wikilink broken entries now carry source: "wikilink"
echo ""
echo "Test: wikilink-broken fixture now reports source: wikilink"
V=$(prepare_vault wikilink-broken)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
assert_eq "wikilink-broken exit code" "1" "$RC"
BROKEN_SOURCE=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).broken[0].source))")
assert_eq "wikilink-broken: source is 'wikilink'" "wikilink" "$BROKEN_SOURCE"
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/test_validate_wiki.sh`
Expected: the three new assertions FAIL — the wikilinks subcommand does not look at `relations:` yet, and `broken[]` entries do not have a `source` field.

- [ ] **Step 4: Extend `runWikilinks` to scan `relations:`**

Open `scripts/validate-wiki.js`. Find `runWikilinks`. Currently the inner loop is:

```javascript
  for (const rel of pages) {
    const abs = path.join(vault, rel);
    for (const target of extractWikilinks(abs)) {
      const resolved = resolveWikilink(target, vault, bareIndex);
      if (!resolved) {
        broken.push({ from: rel, target });
      } else if (resolved !== rel) {
        inbound.set(resolved, (inbound.get(resolved) || 0) + 1);
      }
    }
  }
```

Replace it with:

```javascript
  for (const rel of pages) {
    const abs = path.join(vault, rel);
    // Prose wikilinks: existing behaviour, but tagged with source: "wikilink".
    for (const target of extractWikilinks(abs)) {
      const resolved = resolveWikilink(target, vault, bareIndex);
      if (!resolved) {
        broken.push({ from: rel, target, source: 'wikilink' });
      } else if (resolved !== rel) {
        inbound.set(resolved, (inbound.get(resolved) || 0) + 1);
      }
    }
    // Frontmatter relations: targets are resolved the same three ways and
    // contribute the same broken/inbound bookkeeping. CR-005 §4.4.
    const fm = readFrontmatter(abs);
    if (fm.ok && fm.data && fm.data.relations && typeof fm.data.relations === 'object') {
      for (const targets of Object.values(fm.data.relations)) {
        if (!Array.isArray(targets)) continue;  // structural problem caught by `frontmatter`
        for (const target of targets) {
          if (typeof target !== 'string') continue;
          const resolved = resolveWikilink(target, vault, bareIndex);
          if (!resolved) {
            broken.push({ from: rel, target, source: 'relation' });
          } else if (resolved !== rel) {
            inbound.set(resolved, (inbound.get(resolved) || 0) + 1);
          }
        }
      }
    }
  }
```

`readFrontmatter` is already imported (it's defined in the same file). Reading frontmatter twice per page (once here, once in `runFrontmatter`) is cheap and avoids cross-subcommand coupling.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test_validate_wiki.sh`
Expected: all tests PASS — both the three new ones and every existing one (including the `wikilink-broken` fixture, which now gets a `source: "wikilink"` field on its broken entries; tests that don't read that field are unaffected).

- [ ] **Step 6: Commit**

```bash
git add scripts/validate-wiki.js tests/test_validate_wiki.sh \
        tests/fixtures/validate-wiki/relations-broken-target
git commit -m "feat(validator): resolve relations: targets as wikilinks"
```

---

## Task 3: `reorganize.js` skeleton + `begin` subcommand

**Files:**
- Create: `skills/reorganize/scripts/reorganize.js`
- Create: `tests/test_reorganize.sh`

This task lands the entry point: arg parsing, vault detection, the `begin` subcommand (`pre-reorganize baseline` commit when `wiki/` is dirty; no-op when clean; always reports a SHA on stdout). All other subcommands are stubbed to `die('not implemented yet', 1)` — Tasks 4–9 fill them in one at a time.

- [ ] **Step 1: Create the test harness with `begin` cases**

Create `tests/test_reorganize.sh`:

```bash
#!/bin/bash
set -e

# Test: skills/reorganize/scripts/reorganize.js
# Usage: bash tests/test_reorganize.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/reorganize/scripts/reorganize.js"
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

# Make a vault with minimum CR-002+CR-004 scaffolding so reorganize.js's
# findVaultRoot finds it: .git/, wiki/.state/sources.yaml, wiki/index.md,
# wiki/log.md, and the frontmatter contract.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state" "$v/wiki/sources" "$v/wiki/concepts" "$v/wiki/synthesis"
  cat > "$v/wiki/.state/sources.yaml" <<'YEOF'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YEOF
  cat > "$v/wiki/.state/frontmatter-contract.yaml" <<'YEOF'
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
optional:
  relations:
    type: map[string,list[string]]
unknown_keys: allowed
YEOF
  cat > "$v/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

## Synthesis
IEOF
  echo "# Log" > "$v/wiki/log.md"
  (cd "$v" \
    && git init -q \
    && git config user.email "t@t" \
    && git config user.name "t" \
    && git config commit.gpgsign false \
    && git add . \
    && git commit -qm "init")
  echo "$v"
}

commit_count() { (cd "$1" && git rev-list --count HEAD); }
last_msg()     { (cd "$1" && git log -1 --pretty=%s); }
head_sha()     { (cd "$1" && git rev-parse --short=7 HEAD); }

echo "=== Test: reorganize.js ==="

# Test 1: begin on clean tree → no new commit; reports current HEAD SHA.
echo ""
echo "Test 1: begin on clean tree"
V=$(make_vault clean)
BEFORE_SHA=$(head_sha "$V")
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" begin) )
AFTER_CT=$(commit_count "$V")
assert_eq "no new commit"           "$BEFORE_CT" "$AFTER_CT"
assert_eq "stdout reports SHA"      "$BEFORE_SHA" "$OUT"

# Test 2: begin on dirty wiki/ tree → one baseline commit; reports new HEAD SHA.
echo ""
echo "Test 2: begin on dirty wiki/ tree"
V=$(make_vault dirty)
echo "scratch" > "$V/wiki/concepts/scratch.md"
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" begin) )
AFTER_CT=$(commit_count "$V")
AFTER_SHA=$(head_sha "$V")
assert_eq "one new commit"               "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg is baseline"       "reorganize: pre-reorganize baseline" "$(last_msg "$V")"
assert_eq "stdout reports new HEAD SHA"  "$AFTER_SHA" "$OUT"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
```

Make it executable:

```bash
chmod +x tests/test_reorganize.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_reorganize.sh`
Expected: FAIL — `skills/reorganize/scripts/reorganize.js` does not exist.

- [ ] **Step 3: Create the script skeleton**

Create `skills/reorganize/scripts/reorganize.js`:

```javascript
#!/usr/bin/env node
'use strict';

/**
 * skills/reorganize/scripts/reorganize.js — mechanical worker for /second-brain:reorganize.
 *
 * Subcommands:
 *   begin
 *   candidates --kind <merge|recategorize|cover|parent|relations> [--scope <wiki-subdir>] --json
 *   move-page --from <vault-path> --to <vault-path>
 *   merge-page --from <vault-path> --into <vault-path> --merged-body <tmpfile>
 *   mark-covered --page <vault-path> --by <wikilink-target>
 *   parent-create --page <vault-path> --body <tmpfile> --children <p1,p2,...>
 *   relations-add --page <vault-path> --relation <name> --targets <t1,t2,...>
 *   validate-or-revert
 *
 * Exit codes:
 *   0 clean
 *   1 warning
 *   2 structural error after a move; the just-applied commit has been reverted
 *   3 invariant refusal (scope outside wiki/, merged body too short, etc.); no commit
 *   6 uncommitted non-wiki changes; SKILL re-runs `begin` and retries
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const yaml = require('js-yaml');

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
    if (parent === dir) die('not a second-brain vault (no .git/ + wiki/.state/sources.yaml above cwd)', 2);
    dir = parent;
  }
}

function git(args, vault) {
  const r = spawnSync('git', args, { cwd: vault, encoding: 'utf8' });
  if (r.status !== 0) {
    process.stderr.write(r.stderr || '');
    process.exit(3);
  }
  return r.stdout;
}

function gitStatusPorcelain(vault, paths) {
  const args = ['status', '--porcelain', '-uall'];
  if (paths.length > 0) args.push('--', ...paths);
  return git(args, vault).split('\n').filter(Boolean);
}

function headSha(vault) {
  return git(['rev-parse', '--short=7', 'HEAD'], vault).trim();
}

function cmdBegin(vault) {
  const dirty = gitStatusPorcelain(vault, ['wiki/']);
  if (dirty.length === 0) {
    process.stdout.write(headSha(vault));
    return;
  }
  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', 'reorganize: pre-reorganize baseline'], vault);
  process.stdout.write(headSha(vault));
}

function parseArgs(argv) {
  // Returns { cmd, args }. Subcommand-specific flag parsing happens in handlers.
  const cmd = argv[0];
  const args = {};
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        args[key] = true;
      } else {
        args[key] = next;
        i++;
      }
    } else {
      die(`unexpected positional argument: ${a}`);
    }
  }
  return { cmd, args };
}

function main() {
  const { cmd, args } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (cmd === 'begin') return cmdBegin(vault);
  if (cmd === 'candidates') return die('candidates: not implemented yet', 1);
  if (cmd === 'move-page') return die('move-page: not implemented yet', 1);
  if (cmd === 'merge-page') return die('merge-page: not implemented yet', 1);
  if (cmd === 'mark-covered') return die('mark-covered: not implemented yet', 1);
  if (cmd === 'parent-create') return die('parent-create: not implemented yet', 1);
  if (cmd === 'relations-add') return die('relations-add: not implemented yet', 1);
  if (cmd === 'validate-or-revert') return die('validate-or-revert: not implemented yet', 1);
  die(`unknown subcommand: ${cmd}`);
}

main();
```

Make it executable:

```bash
chmod +x skills/reorganize/scripts/reorganize.js
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): script skeleton and begin subcommand"
```

---

## Task 4: link-rewrite helper + `move-page` subcommand

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

This task adds the internal `linkRewrite` helper (rewrites both prose wikilinks and frontmatter `relations:` targets across all `wiki/` pages except `wiki/index.md`) and exposes it through `move-page`. `move-page` also updates the index row's target, bumps the moved page's `updated:` date, and makes exactly one commit.

- [ ] **Step 1: Add `move-page` test cases**

Open `tests/test_reorganize.sh`. Before the `echo "=== Summary"` block, append:

```bash
# Test 3: move-page renames the file, rewrites prose+relations links,
# updates the index row, bumps `updated:`, and makes one commit.
echo ""
echo "Test 3: move-page happy path"
V=$(make_vault move)
# Set up: two concept pages, one referencing the other in prose AND in relations.
cat > "$V/wiki/concepts/old.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---

# Old

Body.
MEOF
cat > "$V/wiki/concepts/holder.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
relations:
  see-also: [wiki/concepts/old]
---

# Holder

Mentions [[old]] and also [[wiki/concepts/old|the old one]].
MEOF
# Add a row for `old` and `holder` to the index.
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/old]] — original summary
- [[wiki/concepts/holder]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")

BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" move-page --from wiki/concepts/old.md --to wiki/concepts/new.md) )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"            "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names move"     "reorganize: move wiki/concepts/old.md → wiki/concepts/new.md" "$(last_msg "$V")"
# File renamed.
[ ! -f "$V/wiki/concepts/old.md" ] && echo "  PASS: old.md is gone" && PASS=$((PASS+1)) \
                                   || (echo "  FAIL: old.md still present"; FAIL=$((FAIL+1)))
[ -f "$V/wiki/concepts/new.md" ]   && echo "  PASS: new.md exists"  && PASS=$((PASS+1)) \
                                   || (echo "  FAIL: new.md missing"; FAIL=$((FAIL+1)))
# Prose wikilink rewritten in both bare and path form (and alias preserved).
HOLDER=$(cat "$V/wiki/concepts/holder.md")
echo "$HOLDER" | grep -q '\[\[new\]\]'                       && echo "  PASS: bare wikilink rewritten" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: bare wikilink not rewritten"; FAIL=$((FAIL+1)))
echo "$HOLDER" | grep -q '\[\[wiki/concepts/new|the old one\]\]' \
                                                              && echo "  PASS: alias path link rewritten" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: alias path link not rewritten"; FAIL=$((FAIL+1)))
# Frontmatter relations target rewritten.
echo "$HOLDER" | grep -q 'see-also:.*wiki/concepts/new'       && echo "  PASS: relations target rewritten" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: relations target not rewritten"; FAIL=$((FAIL+1)))
# Index row rewritten, summary preserved.
IDX=$(cat "$V/wiki/index.md")
echo "$IDX" | grep -q '\[\[wiki/concepts/new\]\] — original summary' \
                                                              && echo "  PASS: index row rewritten, summary kept" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: index row not rewritten"; FAIL=$((FAIL+1)))
# `updated:` bumped on the moved page.
TODAY=$(date -u +%Y-%m-%d)
NEW=$(cat "$V/wiki/concepts/new.md")
echo "$NEW" | grep -q "updated: $TODAY"                       && echo "  PASS: updated date bumped" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: updated date not bumped"; FAIL=$((FAIL+1)))
# Working tree clean.
LEFTOVER=$( (cd "$V" && git status --porcelain) )
assert_eq "working tree clean"        ""                  "$LEFTOVER"

# Test 4: move-page refuses paths outside wiki/ (scope guard).
echo ""
echo "Test 4: move-page rejects out-of-scope --from"
V=$(make_vault scope-guard)
set +e
ERR=$( (cd "$V" && node "$SCRIPT" move-page --from raw/x.md --to wiki/concepts/y.md) 2>&1 1>/dev/null )
RC=$?
set -e
assert_eq "exit code 3"               "3" "$RC"
echo "$ERR" | grep -q "reorganize only operates on wiki/" \
  && echo "  PASS: scope error message" && PASS=$((PASS+1)) \
  || (echo "  FAIL: scope error wording"; FAIL=$((FAIL+1)))

# Test 5: link-rewrite does NOT touch values inside frontmatter `sources:`.
echo ""
echo "Test 5: link-rewrite leaves sources: alone"
V=$(make_vault sources-untouched)
cat > "$V/wiki/concepts/old.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# Old
MEOF
cat > "$V/wiki/concepts/other.md" <<'MEOF'
---
tags: [demo]
sources: [wiki/concepts/old]
created: 2026-05-01
updated: 2026-05-01
---
# Other
MEOF
(cd "$V" && git add . && git commit -qm "setup")
(cd "$V" && node "$SCRIPT" move-page --from wiki/concepts/old.md --to wiki/concepts/new.md) >/dev/null
OTHER=$(cat "$V/wiki/concepts/other.md")
echo "$OTHER" | grep -q 'sources: \[wiki/concepts/old\]'  && echo "  PASS: sources: untouched" && PASS=$((PASS+1)) \
                                                          || (echo "  FAIL: sources: was rewritten"; FAIL=$((FAIL+1)))
```

- [ ] **Step 2: Run the test to verify the new cases fail**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–2 still PASS; tests 3, 4, 5 FAIL because `move-page` is still a stub.

- [ ] **Step 3: Implement scope-guard, link-rewrite, frontmatter helpers, and `move-page`**

Open `skills/reorganize/scripts/reorganize.js`.

Near the top, after `function findVaultRoot(...) { ... }`, add:

```javascript
// Refuse any path that isn't inside wiki/. Spec §5.4.
function requireWikiPath(label, vaultPath) {
  if (!vaultPath || !vaultPath.startsWith('wiki/')) {
    die(`reorganize only operates on wiki/, got ${label}=${vaultPath}`, 3);
  }
}

function todayUtc() {
  return new Date().toISOString().slice(0, 10);
}

// Read a markdown file's frontmatter block plus the body that follows.
// Returns { frontmatter: object, body: string, raw: string } or throws if
// no leading `---` block. Uses CORE_SCHEMA so dates stay as strings — same
// rule as scripts/validate-wiki.js.
function readPage(absPath) {
  const text = fs.readFileSync(absPath, 'utf8');
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/);
  if (!m) throw new Error(`no frontmatter in ${absPath}`);
  const fm = yaml.load(m[1], { schema: yaml.CORE_SCHEMA }) || {};
  return { frontmatter: fm, body: m[2], raw: text };
}

// Write a markdown file by serialising frontmatter through js-yaml.dump and
// concatenating the body verbatim. Preserves the frontmatter's existing key
// order because js-yaml preserves insertion order.
//
// `flowLevel: 2` keeps lists at depth 2 inline (`tags: [demo]`,
// `sources: [raw/x.md]`) so a move that only touches one relation does not
// re-flow every other key into block style. The visual cost is that the
// `relations:` map also collapses to one line (`relations: {see-also: [...]}`)
// rather than the multi-line layout in CR-005 §4.1 — functionally identical
// and revalidates cleanly.
function writePage(absPath, page) {
  const dump = yaml.dump(page.frontmatter, { lineWidth: -1, sortKeys: false, flowLevel: 2 });
  fs.writeFileSync(absPath, `---\n${dump}---\n${page.body}`);
}

// Walk wiki/ once and return vault-relative .md paths.
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

// Drop the `.md` suffix from a vault path (`wiki/concepts/foo.md` → `wiki/concepts/foo`).
function stripMd(vaultPath) {
  return vaultPath.endsWith('.md') ? vaultPath.slice(0, -3) : vaultPath;
}

// Rewrite every wikilink and every `relations:` target in every wiki/*.md
// (except wiki/index.md) that resolves to `fromPath` so it points at `toPath`.
// `fromPath` and `toPath` are both vault-relative `.md` paths.
//
// Three rewrite forms handled:
//   1. `[[basename]]` (and `[[basename|alias]]`) — rewritten only when the
//      basename uniquely resolves to fromPath under the validator's resolver.
//      We avoid false positives by recomputing the bare-name index AFTER each
//      rewrite call's filesystem effects are in place; callers do the rename
//      THEN call linkRewrite.
//   2. `[[wiki/path/to/page]]` (and `[[wiki/path/to/page|alias]]`) — rewritten
//      when the embedded path equals stripMd(fromPath).
//   3. Frontmatter `relations: { rel: [...targets] }` — each target string is
//      treated the same way as (2) when it starts with `wiki/`, or as (1)
//      when it's a bare name.
//
// Does NOT touch frontmatter `sources:` — those are filename identities, not
// wikilink references (spec §6.2, test §10.1.4).
const WIKILINK_RE = /\[\[([^\]\n|]+)(\|[^\]\n]*)?\]\]/g;

function linkRewrite(vault, fromPath, toPath) {
  const fromStripped = stripMd(fromPath);
  const toStripped = stripMd(toPath);
  const fromBasename = path.basename(fromStripped).toLowerCase();
  const toBasename = path.basename(toStripped);

  // Build a bare-name → resolved-path map so we only rewrite bare names
  // that uniquely resolve to fromPath. This protects against basename
  // collisions in other folders.
  const bareIndex = new Map();
  for (const rel of walkMarkdown(vault, 'wiki')) {
    bareIndex.set(path.basename(rel, '.md').toLowerCase(), rel);
  }
  const bareIsAmbiguous = bareIndex.get(fromBasename) !== fromPath;

  function rewriteTarget(target) {
    const trimmed = target.trim();
    if (trimmed.startsWith('wiki/')) {
      // Path form: exact match against stripMd(fromPath).
      if (trimmed === fromStripped) return toStripped;
      return target;
    }
    if (trimmed.startsWith('src/documentation/')) return target;
    // Bare form: only rewrite if the basename resolves to fromPath.
    if (!bareIsAmbiguous && trimmed.toLowerCase() === fromBasename) return toBasename;
    return target;
  }

  for (const rel of walkMarkdown(vault, 'wiki')) {
    if (rel === 'wiki/index.md') continue;          // index handled per-subcommand
    if (rel === toPath) continue;                   // skip the moved file itself if it already lives at toPath
    const abs = path.join(vault, rel);
    let page;
    try { page = readPage(abs); }
    catch { continue; }                              // files without frontmatter (e.g. wiki/log.md) — skip
    let changed = false;

    // 1) Rewrite prose wikilinks in the body.
    const newBody = page.body.replace(WIKILINK_RE, (full, target, aliasPart) => {
      const rewritten = rewriteTarget(target);
      if (rewritten === target) return full;
      changed = true;
      return `[[${rewritten}${aliasPart || ''}]]`;
    });
    page.body = newBody;

    // 2) Rewrite `relations:` targets in the frontmatter, if present.
    if (page.frontmatter && page.frontmatter.relations && typeof page.frontmatter.relations === 'object') {
      for (const [key, targets] of Object.entries(page.frontmatter.relations)) {
        if (!Array.isArray(targets)) continue;
        const next = targets.map(t => (typeof t === 'string' ? rewriteTarget(t) : t));
        if (next.some((v, i) => v !== targets[i])) {
          page.frontmatter.relations[key] = next;
          changed = true;
        }
      }
    }

    if (changed) writePage(abs, page);
  }
}

// Rewrite the row for `[[fromTarget]]` in wiki/index.md to point at `toTarget`.
// Preserves any "— summary" suffix. No-op if no row matches.
function indexRewriteRow(vault, fromTarget, toTarget) {
  const idxPath = path.join(vault, 'wiki', 'index.md');
  if (!fs.existsSync(idxPath)) return;
  const lines = fs.readFileSync(idxPath, 'utf8').split(/\r?\n/);
  const fromRe = new RegExp(`\\[\\[${escapeRegex(fromTarget)}(\\|[^\\]]*)?\\]\\]`);
  let changed = false;
  for (let i = 0; i < lines.length; i++) {
    if (fromRe.test(lines[i])) {
      lines[i] = lines[i].replace(fromRe, `[[${toTarget}]]`);
      changed = true;
    }
  }
  if (changed) fs.writeFileSync(idxPath, lines.join('\n'));
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function cmdMovePage(vault, args) {
  requireWikiPath('--from', args.from);
  requireWikiPath('--to', args.to);
  const fromAbs = path.join(vault, args.from);
  const toAbs = path.join(vault, args.to);
  if (!fs.existsSync(fromAbs)) die(`--from does not exist: ${args.from}`, 3);
  if (fs.existsSync(toAbs)) die(`--to already exists: ${args.to}`, 3);

  // Rewrite inbound references BEFORE the rename. linkRewrite builds its
  // bare-name resolver from the current filesystem; if we rename first the
  // resolver can no longer find fromPath and would skip every `[[basename]]`
  // rewrite.
  linkRewrite(vault, args.from, args.to);

  // Bump `updated:` on the source page, then rename.
  const moved = readPage(fromAbs);
  moved.frontmatter.updated = todayUtc();
  writePage(fromAbs, moved);
  fs.mkdirSync(path.dirname(toAbs), { recursive: true });
  fs.renameSync(fromAbs, toAbs);

  // Update the index row.
  indexRewriteRow(vault, stripMd(args.from), stripMd(args.to));

  // Commit.
  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: move ${args.from} → ${args.to}`], vault);
}
```

Wire `move-page` in `main()`: replace `if (cmd === 'move-page') return die(...)` with `if (cmd === 'move-page') return cmdMovePage(vault, args);`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–5 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): move-page and shared link-rewrite helper"
```

---

## Task 5: `merge-page` subcommand + body-length sanity check

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

`merge-page` replaces `--into`'s body with the content of `--merged-body` (a tmpfile provided by the SKILL/LLM), deletes `--from`, rewrites every reference to `[[from]]` (and path form, and aliases) to point at `[[into]]`, drops the dead row from `wiki/index.md`, and makes one commit. Refuses with exit 3 if the merged body is below `max(len(body(from)), len(body(into))) × 0.5`.

- [ ] **Step 1: Add `merge-page` test cases**

Open `tests/test_reorganize.sh`. Before the summary block, append:

```bash
# Test 6: merge-page absorbs body, deletes from, rewrites refs, drops index row.
echo ""
echo "Test 6: merge-page happy path"
V=$(make_vault merge)
cat > "$V/wiki/concepts/alignment.md" <<'MEOF'
---
tags: [ai]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---

# Alignment

Original body for alignment. Has multiple paragraphs.
More content. More content. More content.
MEOF
cat > "$V/wiki/concepts/ai-alignment.md" <<'MEOF'
---
tags: [ai]
sources: [raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---

# AI Alignment

Body for ai-alignment. Several paragraphs of overlapping content.
More. More. More.
MEOF
cat > "$V/wiki/concepts/other.md" <<'MEOF'
---
tags: [ai]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
relations:
  see-also: [wiki/concepts/alignment]
---

# Other

See [[alignment]] for context.
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/alignment]] — earlier page
- [[wiki/concepts/ai-alignment]] — survivor
- [[wiki/concepts/other]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")
# Provide a merged body roughly the size of the larger original — passes the
# sanity check.
MERGED=$(mktemp)
cat > "$MERGED" <<'BEOF'
# AI Alignment

Combined body. Lots of content carried over from both originals.
More. More. More. More. More.
BEOF
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" merge-page --from wiki/concepts/alignment.md --into wiki/concepts/ai-alignment.md --merged-body "$MERGED") )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"            "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names merge"    "reorganize: merge wiki/concepts/alignment.md into wiki/concepts/ai-alignment.md" "$(last_msg "$V")"
[ ! -f "$V/wiki/concepts/alignment.md" ] && echo "  PASS: alignment.md deleted" && PASS=$((PASS+1)) \
                                         || (echo "  FAIL: alignment.md not deleted"; FAIL=$((FAIL+1)))
# Inbound prose link rewritten.
OTH=$(cat "$V/wiki/concepts/other.md")
echo "$OTH" | grep -q '\[\[ai-alignment\]\]'           && echo "  PASS: prose rewritten" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: prose not rewritten"; FAIL=$((FAIL+1)))
# Inbound relations target rewritten.
echo "$OTH" | grep -q 'see-also:.*wiki/concepts/ai-alignment' \
                                                        && echo "  PASS: relations rewritten" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: relations not rewritten"; FAIL=$((FAIL+1)))
# Index row dropped, survivor row preserved.
IDX=$(cat "$V/wiki/index.md")
echo "$IDX" | grep -q 'wiki/concepts/alignment\]\]'    && (echo "  FAIL: dead row still in index"; FAIL=$((FAIL+1))) \
                                                        || (echo "  PASS: dead row removed" && PASS=$((PASS+1)))
echo "$IDX" | grep -q 'wiki/concepts/ai-alignment\]\] — survivor' \
                                                        && echo "  PASS: survivor row preserved" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: survivor row clobbered"; FAIL=$((FAIL+1)))
# Survivor body equals the merged body.
SURV=$(cat "$V/wiki/concepts/ai-alignment.md")
echo "$SURV" | grep -q "Combined body"                  && echo "  PASS: survivor body absorbed" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: survivor body not updated"; FAIL=$((FAIL+1)))
# `updated:` bumped on the survivor.
TODAY=$(date -u +%Y-%m-%d)
echo "$SURV" | grep -q "updated: $TODAY"                && echo "  PASS: updated date bumped" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: updated date not bumped"; FAIL=$((FAIL+1)))
rm -f "$MERGED"

# Test 7: merge-page refuses when merged body is below the sanity floor.
echo ""
echo "Test 7: merge-page refuses suspiciously short merged body"
V=$(make_vault merge-short)
cat > "$V/wiki/concepts/a.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---

# A

$(printf 'a%.0s' {1..200})
MEOF
cat > "$V/wiki/concepts/b.md" <<'MEOF'
---
tags: [t]
sources: [raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---

# B

$(printf 'b%.0s' {1..200})
MEOF
(cd "$V" && git add . && git commit -qm "setup")
SHORT=$(mktemp)
echo "tiny" > "$SHORT"
BEFORE_CT=$(commit_count "$V")
set +e
ERR=$( (cd "$V" && node "$SCRIPT" merge-page --from wiki/concepts/a.md --into wiki/concepts/b.md --merged-body "$SHORT") 2>&1 1>/dev/null )
RC=$?
set -e
AFTER_CT=$(commit_count "$V")
assert_eq "exit code 3"             "3"  "$RC"
assert_eq "no commit made"          "$BEFORE_CT" "$AFTER_CT"
echo "$ERR" | grep -q "merged body suspiciously short" \
  && echo "  PASS: refusal message" && PASS=$((PASS+1)) \
  || (echo "  FAIL: refusal message wording"; FAIL=$((FAIL+1)))
# from page must still exist after refusal.
[ -f "$V/wiki/concepts/a.md" ] && echo "  PASS: from page survived" && PASS=$((PASS+1)) \
                               || (echo "  FAIL: from page got deleted despite refusal"; FAIL=$((FAIL+1)))
rm -f "$SHORT"
```

- [ ] **Step 2: Run the test to verify the new cases fail**

Run: `bash tests/test_reorganize.sh`
Expected: tests 6 and 7 FAIL — `merge-page` is still a stub.

- [ ] **Step 3: Implement `merge-page`**

Open `skills/reorganize/scripts/reorganize.js`. After `cmdMovePage`, add:

```javascript
function indexDropRow(vault, target) {
  const idxPath = path.join(vault, 'wiki', 'index.md');
  if (!fs.existsSync(idxPath)) return;
  const lines = fs.readFileSync(idxPath, 'utf8').split(/\r?\n/);
  const re = new RegExp(`\\[\\[${escapeRegex(target)}(\\|[^\\]]*)?\\]\\]`);
  const kept = lines.filter(line => !re.test(line));
  if (kept.length !== lines.length) {
    fs.writeFileSync(idxPath, kept.join('\n'));
  }
}

function cmdMergePage(vault, args) {
  requireWikiPath('--from', args.from);
  requireWikiPath('--into', args.into);
  if (!args['merged-body']) die('--merged-body is required', 1);
  const fromAbs = path.join(vault, args.from);
  const intoAbs = path.join(vault, args.into);
  if (!fs.existsSync(fromAbs)) die(`--from does not exist: ${args.from}`, 3);
  if (!fs.existsSync(intoAbs)) die(`--into does not exist: ${args.into}`, 3);
  const tmp = args['merged-body'];
  if (!fs.existsSync(tmp)) die(`--merged-body file does not exist: ${tmp}`, 3);

  // Body-length sanity. Compare body lengths (not whole files) so frontmatter
  // does not skew the threshold. Do this BEFORE any mutations so the measured
  // lengths are the originals.
  const fromBody = readPage(fromAbs).body;
  const intoBodyPre = readPage(intoAbs).body;
  const mergedBody = fs.readFileSync(tmp, 'utf8');
  const floor = Math.floor(Math.max(fromBody.length, intoBodyPre.length) * 0.5);
  if (mergedBody.length < floor) {
    die(`merged body suspiciously short — refusing merge (got ${mergedBody.length} bytes, expected ≥ ${floor})`, 3);
  }

  // Replace into's body, bump `updated:`.
  const into = readPage(intoAbs);
  into.body = mergedBody;
  into.frontmatter.updated = todayUtc();
  writePage(intoAbs, into);

  // Rewrite inbound references BEFORE deleting `from`. linkRewrite's bare-name
  // resolver walks the current filesystem; if we delete `from` first the
  // resolver can no longer find it and `[[fromBasename]]` rewrites silently
  // skip.
  linkRewrite(vault, args.from, args.into);

  // Delete from.
  fs.unlinkSync(fromAbs);

  // Drop the dead index row.
  indexDropRow(vault, stripMd(args.from));

  // Commit.
  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: merge ${args.from} into ${args.into}`], vault);
}
```

Wire `merge-page` in `main()`: replace its stub with `if (cmd === 'merge-page') return cmdMergePage(vault, args);`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–7 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): merge-page with body-length sanity check"
```

---

## Task 6: `mark-covered` subcommand

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

`mark-covered` appends a single block to a page (`> **Covered by [[<by>]]** — see that page for current synthesis.`), bumps `updated:`, makes one commit. Touches only the page passed via `--page` — never deletes, never touches the `by` target.

- [ ] **Step 1: Add `mark-covered` test cases**

Open `tests/test_reorganize.sh`. Before the summary block, append:

```bash
# Test 8: mark-covered appends a covered-by block, bumps updated, makes one commit.
echo ""
echo "Test 8: mark-covered happy path"
V=$(make_vault mark)
cat > "$V/wiki/sources/old-summary.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---

# Old Summary

Original body of the summary.
MEOF
cat > "$V/wiki/synthesis/big-idea.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md, raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---

# Big Idea

The synthesis page covering the topic.
MEOF
(cd "$V" && git add . && git commit -qm "setup")
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" mark-covered --page wiki/sources/old-summary.md --by wiki/synthesis/big-idea) )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"            "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names mark"     "reorganize: mark wiki/sources/old-summary.md covered by wiki/synthesis/big-idea" "$(last_msg "$V")"
# Block appended to the page.
OLD=$(cat "$V/wiki/sources/old-summary.md")
echo "$OLD" | grep -q '> \*\*Covered by \[\[wiki/synthesis/big-idea\]\]\*\*' \
  && echo "  PASS: covered-by block appended" && PASS=$((PASS+1)) \
  || (echo "  FAIL: covered-by block missing"; FAIL=$((FAIL+1)))
# Original body preserved.
echo "$OLD" | grep -q "Original body of the summary" \
  && echo "  PASS: original body preserved" && PASS=$((PASS+1)) \
  || (echo "  FAIL: original body changed"; FAIL=$((FAIL+1)))
# `updated:` bumped.
TODAY=$(date -u +%Y-%m-%d)
echo "$OLD" | grep -q "updated: $TODAY" \
  && echo "  PASS: updated date bumped" && PASS=$((PASS+1)) \
  || (echo "  FAIL: updated date not bumped"; FAIL=$((FAIL+1)))
# `by` target file untouched.
BY=$(cat "$V/wiki/synthesis/big-idea.md")
echo "$BY" | grep -q "updated: 2026-05-01" \
  && echo "  PASS: by target untouched" && PASS=$((PASS+1)) \
  || (echo "  FAIL: by target was modified"; FAIL=$((FAIL+1)))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_reorganize.sh`
Expected: test 8 FAILs — `mark-covered` is still a stub.

- [ ] **Step 3: Implement `mark-covered`**

Open `skills/reorganize/scripts/reorganize.js`. After `cmdMergePage`, add:

```javascript
function cmdMarkCovered(vault, args) {
  requireWikiPath('--page', args.page);
  if (!args.by) die('--by is required', 1);
  requireWikiPath('--by', args.by);
  const abs = path.join(vault, args.page);
  if (!fs.existsSync(abs)) die(`--page does not exist: ${args.page}`, 3);

  const page = readPage(abs);
  page.frontmatter.updated = todayUtc();
  const note = `\n> **Covered by [[${args.by}]]** — see that page for current synthesis.\n`;
  page.body = page.body.endsWith('\n') ? page.body + note : page.body + '\n' + note;
  writePage(abs, page);

  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: mark ${args.page} covered by ${args.by}`], vault);
}
```

Wire in `main()`: replace the stub with `if (cmd === 'mark-covered') return cmdMarkCovered(vault, args);`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–8 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): mark-covered subcommand"
```

---

## Task 7: `parent-create` subcommand

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

`parent-create` writes a brand-new parent page from `--body <tmpfile>`, appends a `## Children` section listing the `--children` cluster, adds a row to the appropriate index section (derived from the parent's path: `wiki/concepts/...` → `## Concepts`), makes one commit. Does not move the children — they keep their existing paths. Spec §6 & §6.2.

- [ ] **Step 1: Add `parent-create` test cases**

Append to `tests/test_reorganize.sh` (before summary):

```bash
# Test 9: parent-create writes parent file, appends Children, adds index row.
echo ""
echo "Test 9: parent-create happy path"
V=$(make_vault parent)
cat > "$V/wiki/concepts/p1.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p1
MEOF
cat > "$V/wiki/concepts/p2.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p2
MEOF
cat > "$V/wiki/concepts/p3.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p3
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/p1]]
- [[wiki/concepts/p2]]
- [[wiki/concepts/p3]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")
BODY=$(mktemp)
cat > "$BODY" <<'PEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-20
updated: 2026-05-20
---

# Programming Languages

Parent concept covering p1, p2, p3.
PEOF
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" parent-create --page wiki/concepts/programming-languages.md --body "$BODY" --children "wiki/concepts/p1,wiki/concepts/p2,wiki/concepts/p3") )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"             "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names parent"    "reorganize: introduce parent wiki/concepts/programming-languages.md" "$(last_msg "$V")"
# Parent file written with `## Children` section listing all three children.
PAR=$(cat "$V/wiki/concepts/programming-languages.md")
echo "$PAR" | grep -q "## Children"                        && echo "  PASS: ## Children section present" && PASS=$((PASS+1)) \
                                                            || (echo "  FAIL: ## Children section missing"; FAIL=$((FAIL+1)))
echo "$PAR" | grep -q '\[\[wiki/concepts/p1\]\]'           && echo "  PASS: child p1 listed" && PASS=$((PASS+1)) || (echo "  FAIL: p1 missing"; FAIL=$((FAIL+1)))
echo "$PAR" | grep -q '\[\[wiki/concepts/p2\]\]'           && echo "  PASS: child p2 listed" && PASS=$((PASS+1)) || (echo "  FAIL: p2 missing"; FAIL=$((FAIL+1)))
echo "$PAR" | grep -q '\[\[wiki/concepts/p3\]\]'           && echo "  PASS: child p3 listed" && PASS=$((PASS+1)) || (echo "  FAIL: p3 missing"; FAIL=$((FAIL+1)))
# Index gained a row under `## Concepts`.
IDX=$(cat "$V/wiki/index.md")
echo "$IDX" | grep -q 'wiki/concepts/programming-languages' \
  && echo "  PASS: index row added" && PASS=$((PASS+1)) \
  || (echo "  FAIL: index row missing"; FAIL=$((FAIL+1)))
# Children files untouched (no `updated:` bump).
for c in p1 p2 p3; do
  CONT=$(cat "$V/wiki/concepts/$c.md")
  echo "$CONT" | grep -q "updated: 2026-05-01" \
    && echo "  PASS: child $c untouched" && PASS=$((PASS+1)) \
    || (echo "  FAIL: child $c modified"; FAIL=$((FAIL+1)))
done
rm -f "$BODY"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_reorganize.sh`
Expected: test 9 FAILs — `parent-create` is still a stub.

- [ ] **Step 3: Implement `parent-create`**

Open `skills/reorganize/scripts/reorganize.js`. After `cmdMarkCovered`, add:

```javascript
// Map a wiki-path prefix to the index section header it belongs under.
function indexSectionFor(vaultPath) {
  if (vaultPath.startsWith('wiki/sources/'))    return '## Sources';
  if (vaultPath.startsWith('wiki/entities/'))   return '## Entities';
  if (vaultPath.startsWith('wiki/concepts/'))   return '## Concepts';
  if (vaultPath.startsWith('wiki/synthesis/'))  return '## Synthesis';
  return null;
}

// Append a row line to wiki/index.md under the section matching `header`.
// The row is inserted immediately after the section header (and any blank
// line that follows it), before the next section header or end-of-file.
function indexAppendRow(vault, header, row) {
  const idxPath = path.join(vault, 'wiki', 'index.md');
  if (!fs.existsSync(idxPath)) die(`wiki/index.md missing`, 2);
  const lines = fs.readFileSync(idxPath, 'utf8').split(/\r?\n/);
  const start = lines.findIndex(l => l.trim() === header);
  if (start === -1) die(`index missing section ${header}`, 2);
  // Find the end of this section: next `## ` header or end-of-file.
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##\s/.test(lines[i])) { end = i; break; }
  }
  // Insert just before the section's end; keep one blank line between the
  // section's last row (if any) and the next header.
  let insertAt = end;
  while (insertAt > start + 1 && lines[insertAt - 1].trim() === '') insertAt--;
  lines.splice(insertAt, 0, row);
  fs.writeFileSync(idxPath, lines.join('\n'));
}

function cmdParentCreate(vault, args) {
  requireWikiPath('--page', args.page);
  if (!args.body) die('--body is required', 1);
  if (!args.children) die('--children is required', 1);
  const abs = path.join(vault, args.page);
  if (fs.existsSync(abs)) die(`--page already exists: ${args.page}`, 3);
  if (!fs.existsSync(args.body)) die(`--body file does not exist: ${args.body}`, 3);

  const children = args.children.split(',').map(s => s.trim()).filter(Boolean);
  for (const c of children) requireWikiPath('--children entry', c);

  // Read provided body, append `## Children`.
  const bodyText = fs.readFileSync(args.body, 'utf8');
  const childrenSection = `\n## Children\n\n` +
    children.map(c => `- [[${c}]]`).join('\n') + '\n';
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, bodyText.endsWith('\n') ? bodyText + childrenSection : bodyText + '\n' + childrenSection);

  // Add an index row under the matching section.
  const section = indexSectionFor(args.page);
  if (!section) die(`cannot derive index section from ${args.page}`, 3);
  indexAppendRow(vault, section, `- [[${stripMd(args.page)}]]`);

  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: introduce parent ${args.page}`], vault);
}
```

Wire in `main()`: replace the stub with `if (cmd === 'parent-create') return cmdParentCreate(vault, args);`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–9 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): parent-create subcommand"
```

---

## Task 8: `relations-add` subcommand

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

`relations-add` adds/merges a single relation entry into the `relations:` map of a page's frontmatter. If the `relations:` key is absent, create it. If the named relation exists, append targets while deduping. Bumps `updated:`. One commit.

- [ ] **Step 1: Add `relations-add` test cases**

Append to `tests/test_reorganize.sh`:

```bash
# Test 10: relations-add creates the relations: key when absent.
echo ""
echo "Test 10: relations-add when relations: is absent"
V=$(make_vault rel-add-create)
cat > "$V/wiki/concepts/oauth.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# OAuth
MEOF
(cd "$V" && git add . && git commit -qm "setup")
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" relations-add --page wiki/concepts/oauth.md --relation defined-by --targets "src/documentation/foo/auth.md,wiki/concepts/jwt") )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"               "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names relations"   "reorganize: type relations on wiki/concepts/oauth.md" "$(last_msg "$V")"
P=$(cat "$V/wiki/concepts/oauth.md")
echo "$P" | grep -q "relations:"                                && echo "  PASS: relations: key added" && PASS=$((PASS+1)) || (echo "  FAIL: relations: missing"; FAIL=$((FAIL+1)))
echo "$P" | grep -q "defined-by:"                               && echo "  PASS: relation name added" && PASS=$((PASS+1)) || (echo "  FAIL: relation name missing"; FAIL=$((FAIL+1)))
echo "$P" | grep -q "src/documentation/foo/auth.md"             && echo "  PASS: first target listed"  && PASS=$((PASS+1)) || (echo "  FAIL: first target missing"; FAIL=$((FAIL+1)))
echo "$P" | grep -q "wiki/concepts/jwt"                         && echo "  PASS: second target listed" && PASS=$((PASS+1)) || (echo "  FAIL: second target missing"; FAIL=$((FAIL+1)))
TODAY=$(date -u +%Y-%m-%d)
echo "$P" | grep -q "updated: $TODAY"                           && echo "  PASS: updated bumped" && PASS=$((PASS+1)) || (echo "  FAIL: updated not bumped"; FAIL=$((FAIL+1)))

# Test 11: relations-add merges with existing relations: map and dedupes.
echo ""
echo "Test 11: relations-add merges and dedupes"
V=$(make_vault rel-add-merge)
cat > "$V/wiki/concepts/oauth.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
relations:
  defined-by: [src/documentation/foo/auth.md]
  see-also: [wiki/concepts/jwt]
---
# OAuth
MEOF
(cd "$V" && git add . && git commit -qm "setup")
(cd "$V" && node "$SCRIPT" relations-add --page wiki/concepts/oauth.md --relation defined-by --targets "src/documentation/foo/auth.md,wiki/concepts/oidc") >/dev/null
P=$(cat "$V/wiki/concepts/oauth.md")
# defined-by should contain both the original and the new target — exactly once each.
COUNT=$(echo "$P" | grep -c "src/documentation/foo/auth.md")
assert_eq "auth.md appears once (deduped)"      "1" "$COUNT"
echo "$P" | grep -q "wiki/concepts/oidc"  && echo "  PASS: new target appended" && PASS=$((PASS+1)) || (echo "  FAIL: new target missing"; FAIL=$((FAIL+1)))
# see-also untouched.
echo "$P" | grep -q "see-also:"           && echo "  PASS: see-also preserved"   && PASS=$((PASS+1)) || (echo "  FAIL: see-also dropped"; FAIL=$((FAIL+1)))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_reorganize.sh`
Expected: tests 10 and 11 FAIL.

- [ ] **Step 3: Implement `relations-add`**

Open `skills/reorganize/scripts/reorganize.js`. After `cmdParentCreate`, add:

```javascript
function cmdRelationsAdd(vault, args) {
  requireWikiPath('--page', args.page);
  if (!args.relation) die('--relation is required', 1);
  if (!args.targets) die('--targets is required', 1);
  const abs = path.join(vault, args.page);
  if (!fs.existsSync(abs)) die(`--page does not exist: ${args.page}`, 3);

  const newTargets = args.targets.split(',').map(s => s.trim()).filter(Boolean);

  const page = readPage(abs);
  if (!page.frontmatter.relations || typeof page.frontmatter.relations !== 'object') {
    page.frontmatter.relations = {};
  }
  const existing = Array.isArray(page.frontmatter.relations[args.relation])
    ? page.frontmatter.relations[args.relation] : [];
  const seen = new Set(existing);
  const merged = [...existing];
  for (const t of newTargets) {
    if (!seen.has(t)) { merged.push(t); seen.add(t); }
  }
  page.frontmatter.relations[args.relation] = merged;
  page.frontmatter.updated = todayUtc();
  writePage(abs, page);

  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: type relations on ${args.page}`], vault);
}
```

Wire in `main()`: replace the stub with `if (cmd === 'relations-add') return cmdRelationsAdd(vault, args);`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–11 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): relations-add subcommand"
```

---

## Task 9: `validate-or-revert` subcommand

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

`validate-or-revert` runs `node scripts/validate-wiki.js all`. Exit 0 → pass through 0. Exit 1 (warning) → pass through 1, no revert. Exit 2 (structural error) → `git revert HEAD --no-edit` + exit 2.

- [ ] **Step 1: Add `validate-or-revert` test cases**

Append to `tests/test_reorganize.sh`:

```bash
# Test 12: validate-or-revert exits 0 when validator is clean.
echo ""
echo "Test 12: validate-or-revert pass-through on clean tree"
V=$(make_vault val-clean)
cat > "$V/wiki/concepts/p.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/p]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")
BEFORE_CT=$(commit_count "$V")
set +e
(cd "$V" && node "$SCRIPT" validate-or-revert)
RC=$?
set -e
AFTER_CT=$(commit_count "$V")
assert_eq "exit 0 on clean"        "0" "$RC"
assert_eq "no revert commit"       "$BEFORE_CT" "$AFTER_CT"

# Test 13: validate-or-revert reverts HEAD and exits 2 when validator finds structural error.
echo ""
echo "Test 13: validate-or-revert reverts on structural error"
V=$(make_vault val-revert)
cat > "$V/wiki/concepts/p.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/p]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")
# Now make a bad commit: a page with broken frontmatter (missing `sources`).
cat > "$V/wiki/concepts/bad.md" <<'MEOF'
---
tags: [t]
created: 2026-05-01
updated: 2026-05-01
---
# Bad
MEOF
(cd "$V" && git add . && git commit -qm "bad commit")
BEFORE_CT=$(commit_count "$V")
set +e
(cd "$V" && node "$SCRIPT" validate-or-revert)
RC=$?
set -e
AFTER_CT=$(commit_count "$V")
assert_eq "exit 2 on structural"           "2" "$RC"
assert_eq "one revert commit added"        "$((BEFORE_CT + 1))" "$AFTER_CT"
LAST=$( (cd "$V" && git log -1 --pretty=%s) )
case "$LAST" in
  Revert*) echo "  PASS: revert commit on top" && PASS=$((PASS+1)) ;;
  *)       echo "  FAIL: top commit is '$LAST'" && FAIL=$((FAIL+1)) ;;
esac
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_reorganize.sh`
Expected: tests 12 and 13 FAIL.

- [ ] **Step 3: Implement `validate-or-revert`**

Open `skills/reorganize/scripts/reorganize.js`. After `cmdRelationsAdd`, add:

```javascript
function cmdValidateOrRevert(vault) {
  // Resolve the validator path relative to this script's location so it
  // works whether invoked via $CLAUDE_PLUGIN_ROOT or from a worktree.
  const validator = path.resolve(__dirname, '..', '..', '..', 'scripts', 'validate-wiki.js');
  const r = spawnSync('node', [validator, 'all'], { cwd: vault, encoding: 'utf8' });
  // The validator writes its own diagnostics to stderr; surface them.
  if (r.stderr) process.stderr.write(r.stderr);
  if (r.stdout) process.stdout.write(r.stdout);
  const code = r.status;
  if (code === 0) return process.exit(0);
  if (code === 1) return process.exit(1);
  if (code === 2) {
    git(['revert', 'HEAD', '--no-edit'], vault);
    return process.exit(2);
  }
  return process.exit(code || 1);
}
```

Wire in `main()`: replace the stub with `if (cmd === 'validate-or-revert') return cmdValidateOrRevert(vault);`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–13 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): validate-or-revert subcommand"
```

---

## Task 10: `candidates --kind merge` and `--kind parent`

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

This task implements two related shortlist kinds. Both compute pairs/clusters from a shared metric: how many wikilinks two pages have in common, plus shared tags. Output is JSON only; never writes the filesystem.

`merge` returns `pairs[]`: `{a, b, shared_wikilinks, shared_tags}` for page pairs where `shared_wikilinks ≥ 5`. Sorted by `shared_wikilinks` descending.

`parent` returns `clusters[]`: `{members, shared_wikilinks, shared_tag}` for groups of three+ pages that all share a tag AND have pairwise `shared_wikilinks ≥ 3`.

Thresholds are constants inside the script — not exposed via CLI. Spec §6.1.

- [ ] **Step 1: Add `candidates --kind merge` and `--kind parent` test cases**

Append to `tests/test_reorganize.sh`:

```bash
# Test 14: candidates --kind merge returns pairs[] sorted by shared_wikilinks.
echo ""
echo "Test 14: candidates --kind merge"
V=$(make_vault cand-merge)
cat > "$V/wiki/concepts/alpha.md" <<'MEOF'
---
tags: [ai-safety]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# Alpha

[[shared-a]] [[shared-b]] [[shared-c]] [[shared-d]] [[shared-e]]
MEOF
cat > "$V/wiki/concepts/beta.md" <<'MEOF'
---
tags: [ai-safety]
sources: [raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---
# Beta

[[shared-a]] [[shared-b]] [[shared-c]] [[shared-d]] [[shared-e]] [[unique]]
MEOF
# Five dummy target pages so the wikilinks resolve and count.
for s in shared-a shared-b shared-c shared-d shared-e unique; do
  cat > "$V/wiki/concepts/$s.md" <<EOF
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# $s
EOF
done
(cd "$V" && git add . && git commit -qm "setup")

OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind merge --json) )
PAIR_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).pairs.length)))")
# alpha/beta share five wikilinks above the threshold → 1 pair surfaced.
[ "$PAIR_COUNT" -ge 1 ] && echo "  PASS: at least one pair returned ($PAIR_COUNT)" && PASS=$((PASS+1)) \
                        || (echo "  FAIL: expected ≥1 pair, got $PAIR_COUNT"; FAIL=$((FAIL+1)))
SHARED=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).pairs[0].shared_wikilinks)))")
assert_eq "top pair shared_wikilinks ≥ 5"   "5" "$SHARED"

# Test 15: candidates --kind parent groups ≥3 pages with a shared tag and overlapping links.
echo ""
echo "Test 15: candidates --kind parent"
V=$(make_vault cand-parent)
for n in p1 p2 p3; do
  cat > "$V/wiki/concepts/$n.md" <<EOF
---
tags: [programming-languages]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# $n

[[shared-a]] [[shared-b]] [[shared-c]]
EOF
done
for s in shared-a shared-b shared-c; do
  cat > "$V/wiki/concepts/$s.md" <<EOF
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# $s
EOF
done
(cd "$V" && git add . && git commit -qm "setup")
OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind parent --json) )
CL_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).clusters.length)))")
[ "$CL_COUNT" -ge 1 ] && echo "  PASS: at least one cluster ($CL_COUNT)" && PASS=$((PASS+1)) \
                      || (echo "  FAIL: expected ≥1 cluster, got $CL_COUNT"; FAIL=$((FAIL+1)))
M_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).clusters[0].members.length)))")
[ "$M_COUNT" -ge 3 ] && echo "  PASS: cluster has 3+ members ($M_COUNT)" && PASS=$((PASS+1)) \
                     || (echo "  FAIL: cluster has $M_COUNT members"; FAIL=$((FAIL+1)))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_reorganize.sh`
Expected: tests 14 and 15 FAIL.

- [ ] **Step 3: Implement the shared metric helpers and the two kinds**

Open `skills/reorganize/scripts/reorganize.js`. After `cmdValidateOrRevert`, add:

```javascript
// ---------- candidates: shared helpers ----------

// Per-page summary used by every kind:
// { path, tags: Set<string>, outgoing: Set<string> (resolved vault-rel paths) }
function summariseScope(vault, scope) {
  const pages = [...walkMarkdown(vault, scope)];
  // Build a bare-name → resolved-path map for outgoing-link resolution.
  const bareIndex = new Map();
  for (const rel of walkMarkdown(vault, 'wiki')) {
    bareIndex.set(path.basename(rel, '.md').toLowerCase(), rel);
  }
  function resolveTarget(target) {
    if (target.startsWith('wiki/')) {
      return fs.existsSync(path.join(vault, target + '.md')) ? target + '.md' : null;
    }
    if (target.startsWith('src/documentation/')) {
      return fs.existsSync(path.join(vault, target + '.md')) ? target + '.md' : null;
    }
    return bareIndex.get(target.toLowerCase()) || null;
  }
  const out = [];
  for (const rel of pages) {
    const abs = path.join(vault, rel);
    let page;
    try { page = readPage(abs); }
    catch { continue; }
    const tags = new Set(Array.isArray(page.frontmatter.tags) ? page.frontmatter.tags : []);
    const outgoing = new Set();
    const text = page.body;
    let m;
    WIKILINK_RE.lastIndex = 0;
    while ((m = WIKILINK_RE.exec(text)) !== null) {
      const target = m[1].trim();
      const resolved = resolveTarget(target);
      if (resolved && resolved !== rel) outgoing.add(resolved);
    }
    out.push({ path: rel, tags, outgoing });
  }
  return out;
}

function setIntersectionSize(a, b) {
  let n = 0;
  for (const x of a) if (b.has(x)) n++;
  return n;
}

// ---------- candidates: merge ----------

const MERGE_SHARED_WIKILINKS_THRESHOLD = 5;

function candidatesMerge(vault, scope) {
  const pages = summariseScope(vault, scope);
  const pairs = [];
  for (let i = 0; i < pages.length; i++) {
    for (let j = i + 1; j < pages.length; j++) {
      const a = pages[i], b = pages[j];
      const shared = setIntersectionSize(a.outgoing, b.outgoing);
      if (shared < MERGE_SHARED_WIKILINKS_THRESHOLD) continue;
      const sharedTags = setIntersectionSize(a.tags, b.tags);
      pairs.push({
        a: a.path,
        b: b.path,
        shared_wikilinks: shared,
        shared_tags: sharedTags,
      });
    }
  }
  pairs.sort((x, y) => y.shared_wikilinks - x.shared_wikilinks);
  return { pairs };
}

// ---------- candidates: parent ----------

const PARENT_PAIR_THRESHOLD = 3;

function candidatesParent(vault, scope) {
  const pages = summariseScope(vault, scope);
  // Group by tag (each page can be in multiple tag groups).
  const byTag = new Map();
  for (const p of pages) {
    for (const tag of p.tags) {
      if (!byTag.has(tag)) byTag.set(tag, []);
      byTag.get(tag).push(p);
    }
  }
  const clusters = [];
  for (const [tag, members] of byTag) {
    if (members.length < 3) continue;
    // All-pairs check: every pair must hit the threshold.
    let allOk = true;
    let totalShared = 0;
    for (let i = 0; i < members.length && allOk; i++) {
      for (let j = i + 1; j < members.length && allOk; j++) {
        const shared = setIntersectionSize(members[i].outgoing, members[j].outgoing);
        if (shared < PARENT_PAIR_THRESHOLD) { allOk = false; break; }
        totalShared += shared;
      }
    }
    if (!allOk) continue;
    clusters.push({
      members: members.map(m => m.path),
      shared_wikilinks: totalShared,
      shared_tag: tag,
    });
  }
  clusters.sort((x, y) => y.shared_wikilinks - x.shared_wikilinks);
  return { clusters };
}

// ---------- candidates dispatcher ----------

function cmdCandidates(vault, args) {
  if (!args.kind) die('--kind is required', 1);
  if (args.json !== true) die('--json is required (machine-only output)', 1);
  const scope = args.scope || 'wiki';
  if (!scope.startsWith('wiki')) die(`--scope must be inside wiki/, got ${scope}`, 3);

  let result;
  if (args.kind === 'merge')        result = candidatesMerge(vault, scope);
  else if (args.kind === 'parent')  result = candidatesParent(vault, scope);
  else die(`unknown --kind: ${args.kind}`, 1);   // recategorize/cover/relations land in later tasks
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
}
```

Wire in `main()`: replace the `candidates` stub with `if (cmd === 'candidates') return cmdCandidates(vault, args);`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–15 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): candidates --kind merge and --kind parent"
```

---

## Task 11: `candidates --kind recategorize` and `--kind cover`

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

`recategorize` returns `pages[]` of `{path, current_dir, signals: {sources_count, synthesises_others}}` for pages whose signals suggest a different category folder:
- Pages under `wiki/concepts/` with `sources_count ≥ 3` AND outgoing wikilinks to ≥2 other `wiki/concepts/` pages (synthesising) → suggest moving to `wiki/synthesis/`.

`cover` returns `summaries[]` of `{path, candidate_covers, shared_wikilinks}` for `wiki/sources/` pages whose outgoing wikilinks overlap heavily with a `wiki/synthesis/` page's outgoing wikilinks (`shared_wikilinks ≥ 5`).

- [ ] **Step 1: Add `recategorize` and `cover` test cases**

Append to `tests/test_reorganize.sh`:

```bash
# Test 16: candidates --kind recategorize flags synthesising concept pages.
echo ""
echo "Test 16: candidates --kind recategorize"
V=$(make_vault cand-recat)
cat > "$V/wiki/concepts/synthesiser.md" <<'MEOF'
---
tags: [t]
sources: [raw/a.md, raw/b.md, raw/c.md]
created: 2026-05-01
updated: 2026-05-01
---
# Synthesiser

[[wiki/concepts/sub-1]] [[wiki/concepts/sub-2]] [[wiki/concepts/sub-3]]
MEOF
for n in sub-1 sub-2 sub-3; do
  cat > "$V/wiki/concepts/$n.md" <<EOF
---
tags: [t]
sources: [raw/a.md]
created: 2026-05-01
updated: 2026-05-01
---
# $n
EOF
done
(cd "$V" && git add . && git commit -qm "setup")
OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind recategorize --json) )
PG_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).pages.length)))")
[ "$PG_COUNT" -ge 1 ] && echo "  PASS: at least one recategorize candidate ($PG_COUNT)" && PASS=$((PASS+1)) \
                      || (echo "  FAIL: expected ≥1 candidate, got $PG_COUNT"; FAIL=$((FAIL+1)))
SYNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).pages[0].signals.synthesises_others?'true':'false'))")
assert_eq "first candidate is synthesising"  "true" "$SYNT"

# Test 17: candidates --kind cover surfaces a source-summary covered by a synthesis page.
echo ""
echo "Test 17: candidates --kind cover"
V=$(make_vault cand-cover)
cat > "$V/wiki/sources/old.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---
# Old

[[shared-a]] [[shared-b]] [[shared-c]] [[shared-d]] [[shared-e]]
MEOF
cat > "$V/wiki/synthesis/big.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md, raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---
# Big

[[shared-a]] [[shared-b]] [[shared-c]] [[shared-d]] [[shared-e]]
MEOF
for s in shared-a shared-b shared-c shared-d shared-e; do
  cat > "$V/wiki/concepts/$s.md" <<EOF
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# $s
EOF
done
(cd "$V" && git add . && git commit -qm "setup")
OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind cover --json) )
S_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).summaries.length)))")
[ "$S_COUNT" -ge 1 ] && echo "  PASS: at least one cover candidate ($S_COUNT)" && PASS=$((PASS+1)) \
                     || (echo "  FAIL: expected ≥1 candidate, got $S_COUNT"; FAIL=$((FAIL+1)))
PATH_=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).summaries[0].path))")
assert_eq "summary path"      "wiki/sources/old.md" "$PATH_"
COV=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).summaries[0].candidate_covers[0]))")
assert_eq "candidate cover"   "wiki/synthesis/big.md" "$COV"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_reorganize.sh`
Expected: tests 16 and 17 FAIL.

- [ ] **Step 3: Implement `recategorize` and `cover`**

Open `skills/reorganize/scripts/reorganize.js`. After `candidatesParent`, add:

```javascript
// ---------- candidates: recategorize ----------

const RECAT_SOURCES_THRESHOLD = 3;
const RECAT_CONCEPT_OUTLINKS_THRESHOLD = 2;

function candidatesRecategorize(vault, scope) {
  const pages = summariseScope(vault, scope);
  const out = [];
  for (const p of pages) {
    if (!p.path.startsWith('wiki/concepts/')) continue;
    const abs = path.join(vault, p.path);
    const page = readPage(abs);
    const sources = Array.isArray(page.frontmatter.sources) ? page.frontmatter.sources : [];
    if (sources.length < RECAT_SOURCES_THRESHOLD) continue;
    // Count outgoing links to other wiki/concepts/ pages.
    let conceptOut = 0;
    for (const r of p.outgoing) {
      if (r.startsWith('wiki/concepts/') && r !== p.path) conceptOut++;
    }
    if (conceptOut < RECAT_CONCEPT_OUTLINKS_THRESHOLD) continue;
    out.push({
      path: p.path,
      current_dir: 'concepts',
      signals: { sources_count: sources.length, synthesises_others: true },
    });
  }
  out.sort((a, b) => b.signals.sources_count - a.signals.sources_count);
  return { pages: out };
}

// ---------- candidates: cover ----------

const COVER_SHARED_WIKILINKS_THRESHOLD = 5;

function candidatesCover(vault, scope) {
  const pages = summariseScope(vault, scope);
  const sources = pages.filter(p => p.path.startsWith('wiki/sources/'));
  const synths  = pages.filter(p => p.path.startsWith('wiki/synthesis/'));
  const out = [];
  for (const s of sources) {
    const covers = [];
    let topShared = 0;
    for (const y of synths) {
      const shared = setIntersectionSize(s.outgoing, y.outgoing);
      if (shared >= COVER_SHARED_WIKILINKS_THRESHOLD) {
        covers.push({ path: y.path, shared });
      }
    }
    if (covers.length === 0) continue;
    covers.sort((a, b) => b.shared - a.shared);
    topShared = covers[0].shared;
    out.push({
      path: s.path,
      candidate_covers: covers.map(c => c.path),
      shared_wikilinks: topShared,
    });
  }
  out.sort((a, b) => b.shared_wikilinks - a.shared_wikilinks);
  return { summaries: out };
}
```

Extend `cmdCandidates`'s dispatch:

```javascript
  else if (args.kind === 'recategorize') result = candidatesRecategorize(vault, scope);
  else if (args.kind === 'cover')        result = candidatesCover(vault, scope);
```

(Insert these two `else if` branches between the `parent` branch and the `else die(...)` line.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–17 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): candidates --kind recategorize and --kind cover"
```

---

## Task 12: `candidates --kind relations`

**Files:**
- Modify: `skills/reorganize/scripts/reorganize.js`
- Modify: `tests/test_reorganize.sh`

`relations` returns `pages[]` of `{path, outgoing_pattern: [{target, occurrences_in_prose, suggested_relation}]}` for pages where the same wikilink target is referenced ≥3 times in prose. The suggested relation name is a heuristic: if the target is under `src/documentation/`, suggest `defined-by`; otherwise suggest `see-also`.

- [ ] **Step 1: Add `candidates --kind relations` test case**

Append to `tests/test_reorganize.sh`:

```bash
# Test 18: candidates --kind relations flags repeated outgoing wikilinks.
echo ""
echo "Test 18: candidates --kind relations"
V=$(make_vault cand-rel)
cat > "$V/wiki/concepts/oauth.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# OAuth

See [[src/documentation/foo/auth]] for the canonical definition.
Again [[src/documentation/foo/auth]] for the flow diagram.
And once more [[src/documentation/foo/auth]] for examples.
MEOF
mkdir -p "$V/src/documentation/foo"
cat > "$V/src/documentation/foo/auth.md" <<'MEOF'
---
tags: [t]
sources: [src/documentation/foo/auth.md]
created: 2026-05-01
updated: 2026-05-01
---
# auth
MEOF
(cd "$V" && git add . && git commit -qm "setup")
OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind relations --json) )
P_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).pages.length)))")
[ "$P_COUNT" -ge 1 ] && echo "  PASS: at least one relations candidate ($P_COUNT)" && PASS=$((PASS+1)) \
                     || (echo "  FAIL: expected ≥1 candidate, got $P_COUNT"; FAIL=$((FAIL+1)))
OCC=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).pages[0].outgoing_pattern[0].occurrences_in_prose)))")
[ "$OCC" -ge 3 ] && echo "  PASS: occurrences_in_prose ≥3 ($OCC)" && PASS=$((PASS+1)) \
                 || (echo "  FAIL: occurrences_in_prose is $OCC"; FAIL=$((FAIL+1)))
SUGG=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).pages[0].outgoing_pattern[0].suggested_relation))")
assert_eq "suggested_relation"  "defined-by" "$SUGG"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_reorganize.sh`
Expected: test 18 FAILs.

- [ ] **Step 3: Implement `relations`**

Open `skills/reorganize/scripts/reorganize.js`. After `candidatesCover`, add:

```javascript
// ---------- candidates: relations ----------

const RELATIONS_OCCURRENCE_THRESHOLD = 3;

function candidatesRelations(vault, scope) {
  const pages = [...walkMarkdown(vault, scope)];
  // We need raw prose occurrence counts (linkRewrite uses a Set; here we count).
  const out = [];
  for (const rel of pages) {
    const abs = path.join(vault, rel);
    let page;
    try { page = readPage(abs); }
    catch { continue; }
    const counts = new Map();
    let m;
    WIKILINK_RE.lastIndex = 0;
    while ((m = WIKILINK_RE.exec(page.body)) !== null) {
      const target = m[1].trim();
      counts.set(target, (counts.get(target) || 0) + 1);
    }
    const pattern = [];
    for (const [target, n] of counts) {
      if (n < RELATIONS_OCCURRENCE_THRESHOLD) continue;
      let suggested = 'see-also';
      if (target.startsWith('src/documentation/')) suggested = 'defined-by';
      pattern.push({ target, occurrences_in_prose: n, suggested_relation: suggested });
    }
    if (pattern.length === 0) continue;
    pattern.sort((a, b) => b.occurrences_in_prose - a.occurrences_in_prose);
    out.push({ path: rel, outgoing_pattern: pattern });
  }
  return { pages: out };
}
```

Extend `cmdCandidates`'s dispatch:

```javascript
  else if (args.kind === 'relations') result = candidatesRelations(vault, scope);
```

(Insert before the trailing `else die(...)`.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_reorganize.sh`
Expected: tests 1–18 all PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/reorganize/scripts/reorganize.js tests/test_reorganize.sh
git commit -m "feat(reorganize): candidates --kind relations"
```

---

## Task 13: SKILL.md for `/second-brain:reorganize`

**Files:**
- Create: `skills/reorganize/SKILL.md`

This task drops the prompt that orchestrates Propose → Confirm → Apply. The prompt is the only file the LLM reads at invocation; everything mechanical is delegated to `reorganize.js`. Mirror the shape of `skills/lint/SKILL.md` and `skills/ingest/SKILL.md`.

- [ ] **Step 1: Create `skills/reorganize/SKILL.md`**

```markdown
---
name: reorganize
description: >
  Propose structural improvements to the wiki — merging fragmented concept
  pages, recategorizing drifted pages, typing relations, marking superseded
  source-summaries, introducing parent concepts. Use when the user says
  "reorganize", "consolidate", "restructure", "audit structure",
  "merge concepts", "introduce a parent for X", or "type the relations on Y".
allowed-tools: Bash Read Write Edit Glob Grep
---

# Second Brain — Reorganize

Take a user-supplied direction (e.g. "consolidate AI-safety", "audit redundant source-summaries") and run a guided structural reorganization pass over the wiki. Three phases: **Propose** (no filesystem change), **Confirm** (user picks moves), **Apply** (one git commit per move with per-move validation and auto-revert on structural error).

## Tooling

All mechanical work goes through `skills/reorganize/scripts/reorganize.js`. Never hand-edit wiki files for moves; the script owns file renames, link rewrites, frontmatter edits, and index sync.

```bash
node "$CLAUDE_PLUGIN_ROOT/skills/reorganize/scripts/reorganize.js" <subcommand> [args]
```

The script resolves the vault root the same way `state-sources.js` and `validate-wiki.js` do.

## Source types

Reorganize only touches `wiki/`. `raw/` and `src/documentation/` are immutable here — the script enforces this via a scope guard that rejects out-of-scope paths with exit 3.

## Input

The user provides a free-text **direction** (required). Optionally `--scope <wiki-subdir>`. Default scope: `wiki/`. Anything outside `wiki/` is rejected.

## Phase 1 — Propose

1. **Baseline.** Run:
   ```bash
   node "$CLAUDE_PLUGIN_ROOT/skills/reorganize/scripts/reorganize.js" begin
   ```
   Capture the SHA on stdout. Report it to the user — `git reset --hard <sha>` undoes the entire run.

2. **Pick relevant candidate kinds.** Based on the direction:
   - "consolidate X" / "merge X" → `merge`, `parent`
   - "audit redundant source-summaries" / "source coverage" → `cover`
   - "type relations" / "link types" → `relations`
   - "categories drifted" / "wrong folder" → `recategorize`
   When in doubt, run more than one kind.

3. **Fetch shortlists.** For each picked kind:
   ```bash
   node "$CLAUDE_PLUGIN_ROOT/skills/reorganize/scripts/reorganize.js" candidates --kind <kind> [--scope <dir>] --json
   ```
   Parse the JSON (shapes documented in the spec §6.1).

4. **Layer judgment.** Discard candidates that don't fit the direction. Group related ones. Write a one-line rationale per surviving candidate citing the deterministic signal (`shared wikilinks: N`, `signals: synthesises 4 sources`, etc.).

5. **Present a numbered list.** Example:

   ```
   Baseline: abc1234

   Proposed moves:
    1. MERGE  wiki/concepts/alignment → wiki/concepts/ai-alignment
             shared wikilinks: 14, shared tag: ai-safety
    2. RECATEGORIZE  wiki/concepts/rlhf-incident → wiki/synthesis/
             signals: synthesises 4 sources
    3. ADD RELATIONS to wiki/concepts/oauth
             3 outbound wikilinks consistently in defined-by context

   Apply which? (e.g. "all", "1,3", or "none")
   ```

## Phase 2 — Confirm

Parse the user's reply:
- `none` or empty → log "no moves applied" and stop.
- `all` → all proposed moves.
- Comma-separated indices → that subset.
- Anything else → ask again.

## Phase 3 — Apply

For each picked move, in order:

1. **Generate any tmpfiles required.**
   - `merge-page`: write the reconciled merged body to `/tmp/reorganize-merge-<sha>.md`. Include carry-over content from both pages — the script refuses a body shorter than `max(len(body(from)), len(body(into))) × 0.5`.
   - `parent-create`: write the parent body (frontmatter + intro prose, NO `## Children` section — the script appends that) to `/tmp/reorganize-parent-<sha>.md`.

2. **Invoke the subcommand.** Examples:
   ```bash
   node ".../reorganize.js" move-page --from wiki/concepts/old.md --to wiki/concepts/new.md
   node ".../reorganize.js" merge-page --from wiki/concepts/a.md --into wiki/concepts/b.md --merged-body /tmp/reorganize-merge-X.md
   node ".../reorganize.js" mark-covered --page wiki/sources/old-summary.md --by wiki/synthesis/big-idea
   node ".../reorganize.js" parent-create --page wiki/concepts/parent.md --body /tmp/reorganize-parent-X.md --children "wiki/concepts/c1,wiki/concepts/c2"
   node ".../reorganize.js" relations-add --page wiki/concepts/oauth.md --relation defined-by --targets "src/documentation/foo/auth.md"
   ```

3. **Validate.** Always run immediately after each move:
   ```bash
   node ".../reorganize.js" validate-or-revert
   ```
   - Exit 0 → record move as "applied" and continue.
   - Exit 1 → record as "applied with warnings" and continue.
   - Exit 2 → the just-applied commit has already been reverted by the script; record as "reverted: <reason>" and **stop the run**.
   - Exit 3 from the move subcommand itself (invariant refusal — e.g. merged body too short) → no commit was made; record as "refused: <reason>" and continue with the next picked move.

4. **Clean up tmpfiles.**

## Relation vocabulary

The starter relation names — suggested, not enforced:
- `defined-by` — typically points at a `src/documentation/...` target.
- `contradicts` — opposing claim about the same topic.
- `refines` — strengthens / narrows the target.
- `example-of` — instance of a more general concept.
- `see-also` — generic "related" pointer.

You may introduce new relation names when justified by repeated patterns observed during a run. Keep them kebab-case.

## Logging

After all moves are processed (whether stopped early or run to completion), append one entry to `wiki/log.md`:

```
## [YYYY-MM-DD] reorganize | <direction>

Baseline: <sha>. Applied: <N>. Skipped: <M>. Reverted: <K> (<reason if any>).
- merge wiki/concepts/alignment → wiki/concepts/ai-alignment (applied)
- recategorize wiki/concepts/rlhf-incident → wiki/synthesis/ (applied)
- add relations to wiki/concepts/oauth (skipped)
```

`wiki/log.md` is informational only — git history is the state of record.

## When to reorganize

- **Monthly at minimum**, or any time structural debt is noticed.
- Reorganize is judgment-heavy; the user runs it deliberately, not on a schedule. No hook fires it.
- It composes with lint: lint catches correctness issues; reorganize catches structural debt.

## Related Skills

- `/second-brain:lint` — health-check the wiki for contradictions, orphans, broken links.
- `/second-brain:query` — ask questions against the wiki.
- `/second-brain:ingest` — process new sources into wiki pages.
```

- [ ] **Step 2: Sanity-check the SKILL.md frontmatter loads**

Run: `node -e "const y=require('js-yaml');const fs=require('fs');const t=fs.readFileSync('skills/reorganize/SKILL.md','utf8');const m=t.match(/^---\n([\s\S]*?)\n---/);console.log(JSON.stringify(y.load(m[1])))"`
Expected: a one-line JSON object with `name`, `description`, `allowed-tools`. No YAML parse error.

- [ ] **Step 3: Commit**

```bash
git add skills/reorganize/SKILL.md
git commit -m "feat(reorganize): SKILL prompt for Propose/Confirm/Apply"
```

---

## Task 14: End-to-end integration test

**Files:**
- Modify: `tests/test_reorganize.sh`

The 18 existing test cases each exercise one subcommand in isolation. This task adds one integration test that walks through a full Apply phase: baseline → move → validate → another move → validate → final commit log assertion. Spec §10.1.14.

- [ ] **Step 1: Add the integration test**

Open `tests/test_reorganize.sh`. Before the summary block, append:

```bash
# Test 19: End-to-end. Three concept pages → merge two → mark third covered →
# assert filesystem, link state, index state, and commit log.
echo ""
echo "Test 19: end-to-end Propose/Apply walkthrough"
V=$(make_vault e2e)
cat > "$V/wiki/concepts/a.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---

# A

Body content paragraph one.
Body content paragraph two.
Body content paragraph three.
MEOF
cat > "$V/wiki/concepts/b.md" <<'MEOF'
---
tags: [demo]
sources: [raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---

# B

Body content paragraph one.
Body content paragraph two.
Body content paragraph three.
MEOF
cat > "$V/wiki/synthesis/big.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md, raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---

# Big

Synthesis page covering the topic.
MEOF
cat > "$V/wiki/sources/old.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---

# Old

Some original summary content here.
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

- [[wiki/sources/old]] — older summary

## Entities

## Concepts

- [[wiki/concepts/a]]
- [[wiki/concepts/b]] — survivor

## Synthesis

- [[wiki/synthesis/big]]
IEOF
(cd "$V" && git add . && git commit -qm "setup")
BASELINE_CT=$(commit_count "$V")
BASELINE_SHA=$( (cd "$V" && node "$SCRIPT" begin) )
[ -n "$BASELINE_SHA" ] && echo "  PASS: baseline SHA reported" && PASS=$((PASS+1)) \
                       || (echo "  FAIL: no baseline SHA"; FAIL=$((FAIL+1)))

# Move 1: merge a into b.
MERGED=$(mktemp)
cat > "$MERGED" <<'BEOF'
# B

Body content paragraph one.
Body content paragraph two.
Body content paragraph three.
Body content paragraph four (merged in).
BEOF
(cd "$V" && node "$SCRIPT" merge-page --from wiki/concepts/a.md --into wiki/concepts/b.md --merged-body "$MERGED") >/dev/null
set +e
(cd "$V" && node "$SCRIPT" validate-or-revert) >/dev/null 2>&1
RC=$?
set -e
assert_eq "validate-or-revert after merge exits 0/1"  "0" "$RC"
rm -f "$MERGED"

# Move 2: mark old as covered by big.
(cd "$V" && node "$SCRIPT" mark-covered --page wiki/sources/old.md --by wiki/synthesis/big) >/dev/null
set +e
(cd "$V" && node "$SCRIPT" validate-or-revert) >/dev/null 2>&1
RC=$?
set -e
assert_eq "validate-or-revert after mark exits 0/1"   "0" "$RC"

# Filesystem assertions.
[ ! -f "$V/wiki/concepts/a.md" ] && echo "  PASS: a.md absorbed" && PASS=$((PASS+1)) || (echo "  FAIL: a.md still present"; FAIL=$((FAIL+1)))
[ -f "$V/wiki/concepts/b.md" ]   && echo "  PASS: b.md survived" && PASS=$((PASS+1)) || (echo "  FAIL: b.md missing"; FAIL=$((FAIL+1)))
grep -q "Covered by \[\[wiki/synthesis/big\]\]" "$V/wiki/sources/old.md" \
  && echo "  PASS: old.md has covered-by block" && PASS=$((PASS+1)) \
  || (echo "  FAIL: covered-by block missing"; FAIL=$((FAIL+1)))

# Index assertions.
IDX=$(cat "$V/wiki/index.md")
echo "$IDX" | grep -q "wiki/concepts/a\]\]" && (echo "  FAIL: a still in index" ; FAIL=$((FAIL+1))) || (echo "  PASS: a dropped from index" && PASS=$((PASS+1)))
echo "$IDX" | grep -q "wiki/concepts/b\]\] — survivor" && echo "  PASS: b survivor row kept" && PASS=$((PASS+1)) || (echo "  FAIL: b survivor row lost"; FAIL=$((FAIL+1)))

# Commit log assertions.
COMMITS_AFTER=$(commit_count "$V")
[ "$COMMITS_AFTER" -ge "$((BASELINE_CT + 2))" ] && echo "  PASS: ≥2 reorganize commits ($COMMITS_AFTER from $BASELINE_CT)" && PASS=$((PASS+1)) \
                                                || (echo "  FAIL: expected ≥2 new commits, got $((COMMITS_AFTER - BASELINE_CT))"; FAIL=$((FAIL+1)))
LOG=$( (cd "$V" && git log --pretty=%s | head -10) )
echo "$LOG" | grep -q "merge wiki/concepts/a.md into wiki/concepts/b.md" \
  && echo "  PASS: merge commit present" && PASS=$((PASS+1)) \
  || (echo "  FAIL: merge commit missing"; FAIL=$((FAIL+1)))
echo "$LOG" | grep -q "mark wiki/sources/old.md covered by wiki/synthesis/big" \
  && echo "  PASS: mark commit present" && PASS=$((PASS+1)) \
  || (echo "  FAIL: mark commit missing"; FAIL=$((FAIL+1)))

# Baseline escape hatch still works: git reset --hard to BASELINE_SHA restores the vault.
(cd "$V" && git reset --hard "$BASELINE_SHA") >/dev/null
[ -f "$V/wiki/concepts/a.md" ] && echo "  PASS: baseline reset restored a.md" && PASS=$((PASS+1)) \
                               || (echo "  FAIL: baseline reset did not restore a.md"; FAIL=$((FAIL+1)))
```

- [ ] **Step 2: Run the test to verify everything passes**

Run: `bash tests/test_reorganize.sh`
Expected: all 19 tests PASS.

- [ ] **Step 3: Smoke-test the full validator suite still passes**

Run: `bash tests/test_validate_wiki.sh && bash tests/test_onboarding.sh && bash tests/test_sync_index.sh && bash tests/test_state_sources.sh`
Expected: every suite reports 0 failures. No regressions from Tasks 1–2 of this CR.

- [ ] **Step 4: Commit**

```bash
git add tests/test_reorganize.sh
git commit -m "test(reorganize): end-to-end Propose/Apply integration test"
```

---

## Verification (after all tasks land)

- `bash tests/test_reorganize.sh` → 0 failures, 19+ test cases pass.
- `bash tests/test_validate_wiki.sh` → 0 failures (existing + the three CR-005 cases).
- `bash tests/test_onboarding.sh` → 0 failures (contract now includes `optional:` and `relations:`).
- `bash tests/test_sync_index.sh` and `bash tests/test_state_sources.sh` → 0 failures (no regression).
- Manual smoke: in a real second-brain vault, run `/second-brain:reorganize "consolidate test-cluster"`; confirm Propose shows candidates with rationale, Confirm accepts `none` cleanly, baseline SHA can `git reset --hard` the run.
