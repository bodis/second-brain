# CR-002 Source-State YAML Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace log-grep ingest detection with a deterministic `wiki/.state/sources.yaml` store managed by a Node CLI (`scripts/state-sources.js`), with per-source git commits as the audit trail.

**Architecture:** Single-file Node 18+ CLI (`skills/ingest/scripts/state-sources.js`) with three subcommands (`begin`, `diff`, `commit`). Git is a hard runtime dependency: `begin` creates a clean baseline commit, `diff` outputs JSON describing `new`/`changed`/`deleted` sources, `commit` auto-detects produced wiki pages via `git status --porcelain` and writes one commit per source. State file is YAML for git diffability; wire-format I/O is JSON. Ingest SKILL is rewritten to drive this tool instead of grepping `log.md`.

**Tech Stack:** Node 18+ (CommonJS, no build step), `js-yaml` 4.x for YAML I/O, `git` for commits and change detection, bash test harness following the `tests/test_register_plugin.sh` precedent.

**Reference spec:** [`docs/superpowers/specs/2026-05-18-cr-002-source-state-yaml-design.md`](../specs/2026-05-18-cr-002-source-state-yaml-design.md)

---

## File Structure

**Create:**
- `package.json` (repo root) — declares `js-yaml` runtime dep and Node engine.
- `skills/ingest/scripts/state-sources.js` — the CLI tool.
- `tests/test_state_sources.sh` — integration tests against a temp git repo.

**Modify:**
- `.claude-plugin/plugin.json` — version bump `0.1.0` → `0.2.0`.
- `skills/ingest/SKILL.md` — rewrite ingest detection + per-source loop to use `state-sources`.
- `skills/onboard/SKILL.md` — add git + npm prerequisites; run `git init` and `npm install` during scaffold.
- `skills/onboard/scripts/onboarding.sh` — create `wiki/.state/` directory.
- `README.md` — add git to prerequisites; add `npm install --omit=dev` step.
- `docs/REQUIREMENTS.md` — add git runtime requirement.
- `.gitignore` — ignore `node_modules/`.

---

## Task 1: Repo-root package.json + .gitignore + plugin version bump

**Files:**
- Create: `package.json`
- Modify: `.gitignore`
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Read existing `.gitignore` and `plugin.json`**

```bash
cat .gitignore
cat .claude-plugin/plugin.json
```

- [ ] **Step 2: Create `package.json` at repo root**

Write `package.json`:

```json
{
  "name": "second-brain-plugin",
  "version": "0.2.0",
  "private": true,
  "description": "LLM-maintained personal knowledge base for Obsidian (Claude Code plugin).",
  "engines": { "node": ">=18" },
  "dependencies": { "js-yaml": "^4.1.0" }
}
```

- [ ] **Step 3: Append `node_modules/` to `.gitignore`**

Append a new line `node_modules/` if not already present.

- [ ] **Step 4: Bump plugin version**

Edit `.claude-plugin/plugin.json`: change `"version": "0.1.0"` to `"version": "0.2.0"`. No other fields change.

- [ ] **Step 5: Install the dep**

Run: `npm install --omit=dev`
Expected: creates `node_modules/js-yaml` and `package-lock.json` with exit 0.

- [ ] **Step 6: Verify js-yaml loads**

Run: `node -e "console.log(require('js-yaml').dump({hello: 'world'}))"`
Expected: `hello: world` to stdout.

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json .gitignore .claude-plugin/plugin.json
git commit -m "chore(deps): add js-yaml; bump plugin to 0.2.0"
```

---

## Task 2: Test harness + first failing test (`begin` on clean tree)

**Files:**
- Create: `tests/test_state_sources.sh`

- [ ] **Step 1: Write the test harness with the first test case**

Write `tests/test_state_sources.sh`:

```bash
#!/bin/bash
set -e

# Test: state-sources.js — source-state YAML store CLI.
# Usage: bash tests/test_state_sources.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/ingest/scripts/state-sources.js"
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

# Create a fresh vault: temp dir, git init, deterministic identity.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state"
  (cd "$v" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false)
  # Seed an initial commit so HEAD exists.
  touch "$v/.gitkeep"
  (cd "$v" && git add . && git commit -qm "init")
  echo "$v"
}

# Count commits on HEAD.
commit_count() {
  (cd "$1" && git rev-list --count HEAD)
}

# Get the last commit message.
last_msg() {
  (cd "$1" && git log -1 --pretty=%s)
}

echo "=== Test: state-sources.js ==="

# Test 1: begin on clean tree → no new commit.
echo ""
echo "Test 1: begin on clean tree"
V1=$(make_vault vault1)
BEFORE=$(commit_count "$V1")
OUT=$( (cd "$V1" && node "$SCRIPT" begin) )
AFTER=$(commit_count "$V1")
assert_eq "begin reports clean baseline" "clean baseline" "$OUT"
assert_eq "no new commit created"        "$BEFORE" "$AFTER"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Make the test executable and run — expect failure (script does not exist)**

```bash
chmod +x tests/test_state_sources.sh
bash tests/test_state_sources.sh
```

Expected: FAIL — node will error with `Cannot find module '.../state-sources.js'`, the test exits with a non-zero status.

- [ ] **Step 3: Create the minimal script to pass test 1**

Create `skills/ingest/scripts/state-sources.js`:

```javascript
#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function die(msg, code = 1) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(code);
}

function findVaultRoot(start) {
  let dir = path.resolve(start);
  while (true) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) die('not in a git repo (no .git/ found walking up)', 2);
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
  const args = ['status', '--porcelain'];
  if (paths.length > 0) args.push('--', ...paths);
  return git(args, vault).split('\n').filter(Boolean);
}

function cmdBegin(vault) {
  const status = gitStatusPorcelain(vault, ['wiki/', 'wiki/.state/']);
  if (status.length === 0) {
    process.stdout.write('clean baseline\n');
    return;
  }
  git(['add', '--', 'wiki/', 'wiki/.state/'], vault);
  git(['commit', '-m', 'ingest: pre-run baseline'], vault);
  process.stdout.write(`committed pre-run baseline (${status.length} files)\n`);
}

function parseArgs(argv) {
  const cmd = argv[0];
  return { cmd };
}

function main() {
  const { cmd } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (cmd === 'begin') return cmdBegin(vault);
  die(`unknown subcommand: ${cmd}`);
}

main();
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: `=== Results: 2 passed, 0 failed ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/test_state_sources.sh skills/ingest/scripts/state-sources.js
git commit -m "feat(state-sources): scaffold CLI with begin on clean tree"
```

---

## Task 3: `begin` on dirty tree creates baseline commit

**Files:**
- Modify: `tests/test_state_sources.sh`
- (No script changes — `cmdBegin` already handles this; we just need to test it.)

- [ ] **Step 1: Add the dirty-tree test before the final results line**

Insert after Test 1, before the `=== Results ===` echo:

```bash
# Test 2: begin on dirty tree → makes pre-run baseline commit.
echo ""
echo "Test 2: begin with uncommitted wiki changes"
V2=$(make_vault vault2)
mkdir -p "$V2/wiki"
echo "hand edit" > "$V2/wiki/scratch.md"
(cd "$V2" && git add wiki/scratch.md)  # staged but not committed
BEFORE=$(commit_count "$V2")
OUT=$( (cd "$V2" && node "$SCRIPT" begin) )
AFTER=$(commit_count "$V2")
assert_eq "baseline commit created" "$((BEFORE + 1))" "$AFTER"
assert_eq "commit message matches"  "ingest: pre-run baseline" "$(last_msg "$V2")"
assert_eq "output names file count" "committed pre-run baseline (1 files)" "$OUT"

# Test 3: begin is idempotent (second run on now-clean tree).
echo ""
echo "Test 3: begin idempotent on now-clean tree"
OUT=$( (cd "$V2" && node "$SCRIPT" begin) )
AFTER2=$(commit_count "$V2")
assert_eq "no new commit on second run" "$AFTER" "$AFTER2"
assert_eq "reports clean baseline"      "clean baseline" "$OUT"
```

- [ ] **Step 2: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: 7 passed, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_state_sources.sh
git commit -m "test(state-sources): cover begin on dirty + idempotent tree"
```

---

## Task 4: `diff` with no manifest — everything is `new`

**Files:**
- Modify: `tests/test_state_sources.sh`
- Modify: `skills/ingest/scripts/state-sources.js`

- [ ] **Step 1: Add the failing test**

Insert before the `=== Results ===` line:

```bash
# Test 4: diff with no sources.yaml lists every raw file as new.
echo ""
echo "Test 4: diff with no manifest"
V4=$(make_vault vault4)
echo "article one" > "$V4/raw/one.md"
echo "article two" > "$V4/raw/two.md"
OUT=$( (cd "$V4" && node "$SCRIPT" diff) )
assert_eq "new count is 2"          "2" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new.length)))")"
assert_eq "changed count is 0"      "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).changed.length)))")"
assert_eq "deleted count is 0"      "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).deleted.length)))")"
assert_eq "first new path is one"   "raw/one.md" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new[0].path))")"
assert_eq "first new kind is generic" "generic" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new[0].kind))")"
assert_eq "sha256 is 64 hex chars"  "64" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new[0].sha256.length)))")"
```

- [ ] **Step 2: Run the test, expect failure**

Run: `bash tests/test_state_sources.sh`
Expected: Test 4 fails — `unknown subcommand: diff`.

- [ ] **Step 3: Add `diff` to the script**

Edit `skills/ingest/scripts/state-sources.js`. Add `crypto` and `js-yaml` requires at the top:

```javascript
const crypto = require('crypto');
const yaml = require('js-yaml');
```

Add these constants and helpers above `cmdBegin`:

```javascript
const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/state-sources.js';
const DEFAULT_EXCLUDES = ['raw/assets/'];

function readSourcesYaml(vault) {
  const p = path.join(vault, 'wiki/.state/sources.yaml');
  if (!fs.existsSync(p)) {
    return {
      schema_version: SCHEMA_VERSION,
      generated_by: GENERATED_BY,
      excludes: [...DEFAULT_EXCLUDES],
      sources: [],
    };
  }
  const doc = yaml.load(fs.readFileSync(p, 'utf8')) || {};
  if (!doc.schema_version) doc.schema_version = SCHEMA_VERSION;
  if (!doc.generated_by) doc.generated_by = GENERATED_BY;
  if (!Array.isArray(doc.excludes)) doc.excludes = [...DEFAULT_EXCLUDES];
  if (!Array.isArray(doc.sources)) doc.sources = [];
  return doc;
}

function sha256File(absPath) {
  const h = crypto.createHash('sha256');
  h.update(fs.readFileSync(absPath));
  return h.digest('hex');
}

function utcStamp(ms) {
  return new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z');
}

function isExcluded(relPath, excludes) {
  return excludes.some(e => relPath === e.replace(/\/$/, '') || relPath.startsWith(e));
}

function walkSources(vault, excludes) {
  const rawDir = path.join(vault, 'raw');
  if (!fs.existsSync(rawDir)) return [];
  const out = [];
  function recurse(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const abs = path.join(dir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join('/');
      if (e.isDirectory()) {
        if (isExcluded(rel + '/', excludes)) continue;
        recurse(abs);
        continue;
      }
      if (isExcluded(rel, excludes)) continue;
      let stat;
      try { stat = fs.statSync(abs); }
      catch (err) {
        process.stderr.write(`info: skipping ${rel}: ${err.message}\n`);
        continue;
      }
      if (!stat.isFile()) continue;
      out.push({
        path: rel,
        kind: 'generic',
        sha256: sha256File(abs),
        bytes: stat.size,
        mtime: utcStamp(stat.mtimeMs),
      });
    }
  }
  recurse(rawDir);
  return out;
}

function cmdDiff(vault) {
  const doc = readSourcesYaml(vault);
  const fsFiles = walkSources(vault, doc.excludes);
  const yamlByPath = new Map(doc.sources.map(s => [s.path, s]));
  const fsByPath = new Map(fsFiles.map(s => [s.path, s]));

  const newList = [];
  const changedList = [];
  for (const f of fsFiles) {
    const y = yamlByPath.get(f.path);
    if (!y) {
      newList.push({ path: f.path, kind: f.kind, sha256: f.sha256, bytes: f.bytes, mtime: f.mtime });
    } else if (y.sha256 !== f.sha256) {
      changedList.push({
        path: f.path,
        kind: y.kind || 'generic',
        sha256: f.sha256,
        bytes: f.bytes,
        mtime: f.mtime,
        previous_sha256: y.sha256,
        previous_wiki_pages: Array.isArray(y.wiki_pages) ? y.wiki_pages : [],
      });
    }
  }

  const deletedList = [];
  for (const y of doc.sources) {
    if (!fsByPath.has(y.path)) {
      deletedList.push({
        path: y.path,
        previous_wiki_pages: Array.isArray(y.wiki_pages) ? y.wiki_pages : [],
      });
    }
  }

  const byPath = (a, b) => a.path.localeCompare(b.path);
  newList.sort(byPath); changedList.sort(byPath); deletedList.sort(byPath);

  process.stdout.write(JSON.stringify({ new: newList, changed: changedList, deleted: deletedList }, null, 2) + '\n');
}
```

Wire it into `main()`:

```javascript
function main() {
  const { cmd } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (cmd === 'begin') return cmdBegin(vault);
  if (cmd === 'diff') return cmdDiff(vault);
  die(`unknown subcommand: ${cmd}`);
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: 13 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add tests/test_state_sources.sh skills/ingest/scripts/state-sources.js
git commit -m "feat(state-sources): add diff subcommand for new sources"
```

---

## Task 5: `diff` honors `excludes` (`raw/assets/`)

**Files:**
- Modify: `tests/test_state_sources.sh`
- (No script changes — `walkSources` already honors `excludes`; we test the default.)

- [ ] **Step 1: Add the test**

Insert before `=== Results ===`:

```bash
# Test 5: diff excludes raw/assets/ by default.
echo ""
echo "Test 5: diff honors excludes"
V5=$(make_vault vault5)
echo "article" > "$V5/raw/one.md"
mkdir -p "$V5/raw/assets"
echo "img bytes" > "$V5/raw/assets/cover.png"
OUT=$( (cd "$V5" && node "$SCRIPT" diff) )
assert_eq "only one file counted as new" "1" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new.length)))")"
assert_eq "the new file is one.md"       "raw/one.md" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new[0].path))")"
```

- [ ] **Step 2: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: 15 passed, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_state_sources.sh
git commit -m "test(state-sources): diff excludes raw/assets/"
```

---

## Task 6: `commit` happy path — auto-detect wiki pages, update YAML, make commit

**Files:**
- Modify: `tests/test_state_sources.sh`
- Modify: `skills/ingest/scripts/state-sources.js`

- [ ] **Step 1: Add the test**

Insert before `=== Results ===`:

```bash
# Test 6: commit --source happy path. Auto-detects wiki pages from git status.
echo ""
echo "Test 6: commit happy path"
V6=$(make_vault vault6)
mkdir -p "$V6/raw" "$V6/wiki/sources" "$V6/wiki/entities"
echo "source body" > "$V6/raw/foo.md"
# Simulate LLM ingest: produce two wiki pages.
echo "summary" > "$V6/wiki/sources/foo.md"
echo "entity"  > "$V6/wiki/entities/bar.md"
BEFORE=$(commit_count "$V6")
OUT=$( (cd "$V6" && node "$SCRIPT" commit --source raw/foo.md) )
AFTER=$(commit_count "$V6")
assert_eq "one new commit created"     "$((BEFORE + 1))" "$AFTER"
assert_eq "commit msg names 2 pages"   "ingest: raw/foo.md → 2 pages" "$(last_msg "$V6")"
assert_eq "sources.yaml exists"        "yes" "$([ -f "$V6/wiki/.state/sources.yaml" ] && echo yes || echo no)"

YAML="$V6/wiki/.state/sources.yaml"
get_yaml() {
  # $1 = file, $2 = JS expression on `d` (parsed YAML).
  node -e "
    const y = require('js-yaml');
    const d = y.load(require('fs').readFileSync('$1', 'utf8'));
    const v = ($2);
    process.stdout.write(typeof v === 'boolean' ? (v ? 'True' : 'False') : String(v));
  "
}
assert_eq "schema_version is 1"        "1" "$(get_yaml "$YAML" "d.schema_version")"
assert_eq "one source recorded"        "1" "$(get_yaml "$YAML" "d.sources.length")"
assert_eq "source path"                "raw/foo.md" "$(get_yaml "$YAML" "d.sources[0].path")"
assert_eq "source kind"                "generic"    "$(get_yaml "$YAML" "d.sources[0].kind")"
assert_eq "wiki_pages contains 2"      "2"          "$(get_yaml "$YAML" "d.sources[0].wiki_pages.length")"
assert_eq "wiki_pages sorted"          "wiki/entities/bar.md,wiki/sources/foo.md" "$(get_yaml "$YAML" "d.sources[0].wiki_pages.join(',')")"
assert_eq "ingested_at present"        "True"       "$(get_yaml "$YAML" "typeof d.sources[0].ingested_at === 'string' && d.sources[0].ingested_at.endsWith('Z')")"
# Working tree clean after commit:
LEFTOVER=$( (cd "$V6" && git status --porcelain) )
assert_eq "working tree clean after commit" "" "$LEFTOVER"
```

- [ ] **Step 2: Run the test, expect failure**

Run: `bash tests/test_state_sources.sh`
Expected: Test 6 fails — `unknown subcommand: commit` or unknown argument `--source`.

- [ ] **Step 3: Extend the script with `commit`**

Edit `skills/ingest/scripts/state-sources.js`:

(a) Replace `parseArgs` with the multi-arg version:

```javascript
function parseArgs(argv) {
  const cmd = argv[0];
  const args = { source: null, allowEmpty: false, deleted: false };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--source') args.source = argv[++i];
    else if (a === '--allow-empty') args.allowEmpty = true;
    else if (a === '--deleted') args.deleted = true;
    else die(`unknown argument: ${a}`);
  }
  return { cmd, args };
}
```

(b) Add `writeSourcesYaml` near the other YAML helpers:

```javascript
function writeSourcesYaml(vault, doc) {
  doc.sources.sort((a, b) => a.path.localeCompare(b.path));
  const stateDir = path.join(vault, 'wiki/.state');
  fs.mkdirSync(stateDir, { recursive: true });
  const out = yaml.dump(doc, { indent: 2, sortKeys: false, lineWidth: -1 });
  fs.writeFileSync(path.join(stateDir, 'sources.yaml'), out);
}
```

(c) Add `parsePorcelainWikiPages`:

```javascript
// Parse `git status --porcelain -- wiki/` output. Returns the wiki .md files to
// record in wiki_pages (added/modified, NOT deleted) and the full list of paths
// to stage (so deletions are reflected in the commit).
function parsePorcelainWikiPages(lines) {
  const wikiPages = new Set();
  const toStage = new Set();
  for (const line of lines) {
    const code = line.slice(0, 2);
    const rest = line.slice(3);
    let oldPath = null, newPath = rest;
    if (code.startsWith('R') || code.startsWith('C')) {
      const arrow = rest.indexOf(' -> ');
      if (arrow > -1) {
        oldPath = rest.slice(0, arrow);
        newPath = rest.slice(arrow + 4);
      }
    }
    if (oldPath) toStage.add(oldPath);
    toStage.add(newPath);
    if (!newPath.endsWith('.md')) continue;
    // If the file is gone from disk (any 'D' in either status slot — ' D',
    // 'D ', 'AD', 'MD', etc.), stage the deletion but do not record in
    // wiki_pages.
    if (code.includes('D')) continue;
    wikiPages.add(newPath);
  }
  return {
    wikiPages: [...wikiPages].sort(),
    toStage: [...toStage].sort(),
  };
}
```

(d) Add `cmdCommit`:

```javascript
function cmdCommit(vault, args) {
  if (!args.source) die('--source is required', 1);

  if (args.deleted) {
    const doc = readSourcesYaml(vault);
    doc.sources = doc.sources.filter(s => s.path !== args.source);
    writeSourcesYaml(vault, doc);
    git(['add', '--', 'wiki/.state/sources.yaml'], vault);
    git(['commit', '-m', `ingest: remove ${args.source} from state`], vault);
    process.stdout.write(`ingest: remove ${args.source} from state\n`);
    return;
  }

  // Exit 6: any uncommitted change outside wiki/ blocks commit.
  const allChanges = gitStatusPorcelain(vault, []);
  const nonWiki = allChanges.filter(line => {
    const rest = line.slice(3);
    const arrow = rest.indexOf(' -> ');
    const left = arrow > -1 ? rest.slice(0, arrow) : rest;
    const right = arrow > -1 ? rest.slice(arrow + 4) : rest;
    return !(left.startsWith('wiki/') || right.startsWith('wiki/'));
  });
  if (nonWiki.length > 0) {
    die('working tree has uncommitted non-wiki changes; run `state-sources begin` first', 6);
  }

  const abs = path.join(vault, args.source);
  if (!fs.existsSync(abs)) {
    die(`source path does not exist: ${args.source} (use --deleted to remove from state)`, 5);
  }

  const wikiStatus = gitStatusPorcelain(vault, ['wiki/']);
  const { wikiPages, toStage } = parsePorcelainWikiPages(wikiStatus);

  if (wikiPages.length === 0 && !args.allowEmpty) {
    die(`source "${args.source}" produced no wiki changes; re-run with --allow-empty if intentional`, 4);
  }

  const stat = fs.statSync(abs);
  const entry = {
    path: args.source,
    kind: 'generic',
    sha256: sha256File(abs),
    bytes: stat.size,
    mtime: utcStamp(stat.mtimeMs),
    ingested_at: utcStamp(Date.now()),
    wiki_pages: wikiPages,
  };

  const doc = readSourcesYaml(vault);
  doc.sources = doc.sources.filter(s => s.path !== args.source);
  doc.sources.push(entry);
  writeSourcesYaml(vault, doc);

  const staged = ['wiki/.state/sources.yaml', ...toStage];
  git(['add', '--', ...staged], vault);
  const msg = wikiPages.length === 0
    ? `ingest: ${args.source} → no output (allow-empty)`
    : `ingest: ${args.source} → ${wikiPages.length} pages`;
  git(['commit', '-m', msg], vault);
  process.stdout.write(`${msg}\n`);
}
```

(e) Wire `commit` into `main`:

```javascript
function main() {
  const { cmd, args } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (cmd === 'begin') return cmdBegin(vault);
  if (cmd === 'diff') return cmdDiff(vault);
  if (cmd === 'commit') return cmdCommit(vault, args);
  die(`unknown subcommand: ${cmd}`);
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: 26 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add tests/test_state_sources.sh skills/ingest/scripts/state-sources.js
git commit -m "feat(state-sources): add commit subcommand with git auto-detection"
```

---

## Task 7: `diff` after `commit` — round-trip through `changed` and `deleted`

**Files:**
- Modify: `tests/test_state_sources.sh`

- [ ] **Step 1: Add the test**

Insert before `=== Results ===`:

```bash
# Test 7: After commit, diff reports nothing new; modifying the source surfaces
# it as `changed` with previous_sha256 + previous_wiki_pages; deleting it
# surfaces as `deleted` with previous_wiki_pages.
echo ""
echo "Test 7: diff after commit (changed + deleted)"
V7=$(make_vault vault7)
mkdir -p "$V7/raw" "$V7/wiki/sources"
echo "v1" > "$V7/raw/article.md"
echo "summary v1" > "$V7/wiki/sources/article.md"
(cd "$V7" && node "$SCRIPT" commit --source raw/article.md >/dev/null)

# (a) Nothing pending.
OUT=$( (cd "$V7" && node "$SCRIPT" diff) )
assert_eq "after commit, no new"     "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new.length)))")"
assert_eq "after commit, no changed" "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).changed.length)))")"
assert_eq "after commit, no deleted" "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).deleted.length)))")"

# (b) Modify the source. It must surface as changed and carry previous state.
echo "v2 - more content" > "$V7/raw/article.md"
OUT=$( (cd "$V7" && node "$SCRIPT" diff) )
assert_eq "changed count is 1"                "1" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).changed.length)))")"
assert_eq "changed has previous_sha256"       "True" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(typeof JSON.parse(d).changed[0].previous_sha256 === 'string' ? 'True' : 'False'))")"
assert_eq "changed lists prev wiki page"      "wiki/sources/article.md" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).changed[0].previous_wiki_pages[0]))")"
assert_eq "changed sha differs from previous" "True" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const c=JSON.parse(d).changed[0]; process.stdout.write(c.sha256 !== c.previous_sha256 ? 'True' : 'False')})")"

# (c) Delete the source. It must surface as deleted and carry previous_wiki_pages.
rm "$V7/raw/article.md"
OUT=$( (cd "$V7" && node "$SCRIPT" diff) )
assert_eq "deleted count is 1"             "1" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).deleted.length)))")"
assert_eq "deleted carries wiki page list" "wiki/sources/article.md" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).deleted[0].previous_wiki_pages[0]))")"
```

- [ ] **Step 2: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: 35 passed, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_state_sources.sh
git commit -m "test(state-sources): diff covers changed + deleted after commit"
```

---

## Task 8: `commit --allow-empty` records a source with no wiki pages

**Files:**
- Modify: `tests/test_state_sources.sh`

- [ ] **Step 1: Add the tests**

Insert before `=== Results ===`:

```bash
# Test 8: commit on a source that produced no wiki output:
#   (a) without --allow-empty → exit 4, state unchanged.
#   (b) with --allow-empty   → entry recorded with wiki_pages: [], commit happens.
echo ""
echo "Test 8: commit on source with no wiki changes"
V8=$(make_vault vault8)
echo "rubbish" > "$V8/raw/junk.md"

# (a) Without flag: must fail with exit 4 and not touch state.
set +e
(cd "$V8" && node "$SCRIPT" commit --source raw/junk.md >/dev/null 2>&1)
RC=$?
set -e
assert_eq "exit code is 4 without --allow-empty" "4" "$RC"
assert_eq "no sources.yaml created"               "no" "$([ -f "$V8/wiki/.state/sources.yaml" ] && echo yes || echo no)"

# (b) With flag: succeeds, records entry with empty wiki_pages.
BEFORE=$(commit_count "$V8")
OUT=$( (cd "$V8" && node "$SCRIPT" commit --source raw/junk.md --allow-empty) )
AFTER=$(commit_count "$V8")
assert_eq "commit count incremented"  "$((BEFORE + 1))" "$AFTER"
assert_eq "commit message reflects empty" "ingest: raw/junk.md → no output (allow-empty)" "$(last_msg "$V8")"
YAML="$V8/wiki/.state/sources.yaml"
assert_eq "wiki_pages is empty"       "0" "$(get_yaml "$YAML" "d.sources[0].wiki_pages.length")"

# Subsequent diff must not see the file as new.
OUT=$( (cd "$V8" && node "$SCRIPT" diff) )
assert_eq "diff no longer sees junk.md as new" "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new.length)))")"
```

- [ ] **Step 2: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: 41 passed, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_state_sources.sh
git commit -m "test(state-sources): commit --allow-empty path"
```

---

## Task 9: `commit` rejects uncommitted non-wiki changes (exit 6)

**Files:**
- Modify: `tests/test_state_sources.sh`

- [ ] **Step 1: Add the test**

Insert before `=== Results ===`:

```bash
# Test 9: commit must refuse to run if the working tree has uncommitted changes
# outside of wiki/. Forces the user to run `begin` first so attribution is clean.
echo ""
echo "Test 9: commit fails on uncommitted non-wiki changes"
V9=$(make_vault vault9)
mkdir -p "$V9/raw" "$V9/wiki/sources"
echo "src" > "$V9/raw/x.md"
echo "out" > "$V9/wiki/sources/x.md"
# Create an unrelated dirty file outside wiki/.
echo "drift" > "$V9/raw/handedit.md"
set +e
ERR=$( (cd "$V9" && node "$SCRIPT" commit --source raw/x.md) 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "exit code 6 on dirty non-wiki tree" "6" "$RC"
assert_eq "stderr names begin"                  "True" "$(echo "$ERR" | grep -q 'state-sources begin' && echo True || echo False)"
# State must be untouched.
assert_eq "no sources.yaml written"             "no" "$([ -f "$V9/wiki/.state/sources.yaml" ] && echo yes || echo no)"
```

- [ ] **Step 2: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: 44 passed, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_state_sources.sh
git commit -m "test(state-sources): commit refuses dirty non-wiki tree"
```

---

## Task 10: `commit --deleted` removes an entry from state

**Files:**
- Modify: `tests/test_state_sources.sh`

- [ ] **Step 1: Add the test**

Insert before `=== Results ===`:

```bash
# Test 10: commit --deleted drops the entry from sources.yaml and commits.
echo ""
echo "Test 10: commit --deleted"
V10=$(make_vault vault10)
mkdir -p "$V10/raw" "$V10/wiki/sources"
echo "doomed" > "$V10/raw/doomed.md"
echo "summary" > "$V10/wiki/sources/doomed.md"
(cd "$V10" && node "$SCRIPT" commit --source raw/doomed.md >/dev/null)
# Now manually delete the source on disk.
rm "$V10/raw/doomed.md"
BEFORE=$(commit_count "$V10")
OUT=$( (cd "$V10" && node "$SCRIPT" commit --source raw/doomed.md --deleted) )
AFTER=$(commit_count "$V10")
assert_eq "one new commit for removal" "$((BEFORE + 1))" "$AFTER"
assert_eq "removal message matches"    "ingest: remove raw/doomed.md from state" "$(last_msg "$V10")"
YAML="$V10/wiki/.state/sources.yaml"
assert_eq "sources list is now empty"  "0" "$(get_yaml "$YAML" "d.sources.length")"
# Diff must not surface the now-removed source.
OUT=$( (cd "$V10" && node "$SCRIPT" diff) )
assert_eq "diff has no deleted entry"  "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).deleted.length)))")"

# Test 10b: commit on a missing source WITHOUT --deleted → exit 5.
echo ""
echo "Test 10b: commit fails (exit 5) when source path does not exist"
V10b=$(make_vault vault10b)
set +e
ERR=$( (cd "$V10b" && node "$SCRIPT" commit --source raw/never-was.md) 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "exit code 5 on missing source"  "5" "$RC"
assert_eq "stderr suggests --deleted flag" "True" "$(echo "$ERR" | grep -q -- '--deleted' && echo True || echo False)"
```

- [ ] **Step 2: Run the test, verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: 50 passed, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_state_sources.sh
git commit -m "test(state-sources): commit --deleted removes from state"
```

---

## Task 11: `diff` output is deterministic

**Files:**
- Modify: `tests/test_state_sources.sh`

- [ ] **Step 1: Add the test**

Insert before `=== Results ===`:

```bash
# Test 11: running diff twice on identical state produces byte-identical output.
echo ""
echo "Test 11: diff is deterministic"
V11=$(make_vault vault11)
mkdir -p "$V11/raw"
echo "a" > "$V11/raw/a.md"
echo "b" > "$V11/raw/b.md"
echo "c" > "$V11/raw/c.md"
OUT1=$( (cd "$V11" && node "$SCRIPT" diff) )
OUT2=$( (cd "$V11" && node "$SCRIPT" diff) )
H1=$(echo "$OUT1" | shasum | cut -d' ' -f1)
H2=$(echo "$OUT2" | shasum | cut -d' ' -f1)
assert_eq "two diff runs produce identical output" "$H1" "$H2"
# And entries are sorted by path.
FIRST=$(echo "$OUT1" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new.map(s=>s.path).join(',')))")
assert_eq "new entries sorted by path" "raw/a.md,raw/b.md,raw/c.md" "$FIRST"
```

- [ ] **Step 2: Run the full test suite**

Run: `bash tests/test_state_sources.sh`
Expected: 52 passed, 0 failed.

- [ ] **Step 3: Commit**

```bash
git add tests/test_state_sources.sh
git commit -m "test(state-sources): diff output is deterministic"
```

---

## Task 12: Rewrite ingest SKILL to drive `state-sources`

**Files:**
- Modify: `skills/ingest/SKILL.md`

This task is content-only — no script changes — so there's no failing-test step. The post-change validation is the manual smoke checklist in Task 16.

- [ ] **Step 1: Replace "Identify Sources to Process" section**

Open `skills/ingest/SKILL.md`. Replace the entire `## Identify Sources to Process` section (the block starting at line 15 ending before `## Process Each Source`) with:

```markdown
## Tooling

This SKILL drives all source-state operations through `scripts/state-sources.js`. Never hand-edit `wiki/.state/sources.yaml`. Never grep `wiki/log.md` to figure out what's been ingested — `log.md` is a human-readable narrative, not a source of truth.

The tool resolves the vault root by walking up to the nearest `.git/`. Invoke it with the vault as `cwd`:

```bash
node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" <subcommand> [args]
```

## Identify Sources to Process

Determine which files need ingestion:

1. If the user specified one or more files, use those.

2. Otherwise, establish a clean baseline:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" begin
   ```

   This makes a `pre-run baseline` commit if there are uncommitted changes under `wiki/` (typically hand edits the user made between runs). It is a no-op on a clean tree.

3. Ask the tool what changed since the last ingest:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" diff
   ```

   Parse the JSON output. It has three lists:
   - `new`: sources never ingested. Path + content hash.
   - `changed`: sources whose content hash differs from last ingest. Includes `previous_sha256` and `previous_wiki_pages` (the wiki pages this source previously produced, so you can update them in place).
   - `deleted`: sources that were in state but are no longer on disk. Includes `previous_wiki_pages`.

4. For `deleted` entries, surface them to the user with their `previous_wiki_pages` and ask whether to:
   - keep the wiki pages and drop the source from state (`commit --source <path> --deleted`), or
   - delete the wiki pages too (then `commit --source <path> --deleted`).
   Do not auto-prune wiki pages.

5. If `new`, `changed`, and `deleted` are all empty, tell the user there's nothing to do and stop.
```

- [ ] **Step 2: Replace "Process Each Source" preamble**

Just below the new "Identify Sources to Process" section, locate `## Process Each Source` and the text `For each source file, follow this workflow:`. Replace that one line with:

```markdown
For each entry in `new` and `changed`, follow this workflow. If the entry is `changed`, before step 1 read each path in `previous_wiki_pages` — the goal is to **update** those existing pages, not create new ones.
```

- [ ] **Step 3: Replace step 7 (`Update wiki/log.md`) wording**

Find the `### 7. Update wiki/log.md` section. Leave the heading and the existing example block as-is, but insert this paragraph immediately under the heading and above the existing example:

```markdown
`wiki/log.md` is the human-readable narrative. It is no longer parsed for ingest detection — the state file (`wiki/.state/sources.yaml`) is the source of truth. Still append a paragraph per source so the user has a readable trail.
```

- [ ] **Step 4: Insert a new step 8 between current step 7 and step 8**

Renumber the current "### 8. Report results" to "### 9. Report results". Insert this new step 8 in its place:

```markdown
### 8. Commit the source

Run:

```bash
node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" commit --source <relative-source-path>
```

The tool auto-detects which wiki pages this source's ingest touched (via `git status --porcelain -- wiki/`), updates `wiki/.state/sources.yaml`, stages everything, and makes one git commit named `ingest: <path> → N pages`.

If the source legitimately produced no wiki output (it turned out to be empty / nonsensical / already covered elsewhere), pass `--allow-empty` so it is still recorded and won't appear as `new` next run:

```bash
node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" commit --source <path> --allow-empty
```

If the tool exits with code 6 ("uncommitted non-wiki changes"), it means something outside `wiki/` is dirty (e.g., a user edit to a source file mid-run). Run `state-sources begin` again to roll that into a baseline commit, then retry.
```

- [ ] **Step 5: Verify no stale log-grep references remain**

Run: `grep -n 'wiki/log.md' skills/ingest/SKILL.md`
Expected: only the references inside step 7 (the narrative log). No mention of using `log.md` to detect ingested files.

Run: `grep -n 'previously ingested' skills/ingest/SKILL.md`
Expected: empty (no output).

- [ ] **Step 6: Commit**

```bash
git add skills/ingest/SKILL.md
git commit -m "feat(ingest): drive ingest detection through state-sources"
```

---

## Task 13: Update onboarding to scaffold `wiki/.state/`, `git init`, and `npm install`

**Files:**
- Modify: `skills/onboard/scripts/onboarding.sh`
- Modify: `skills/onboard/SKILL.md`

- [ ] **Step 1: Add `wiki/.state/` to the directory scaffold**

Edit `skills/onboard/scripts/onboarding.sh`. Find the block that creates directories (the `mkdir -p` lines near the top). Add this line right after `mkdir -p "$VAULT_ROOT/wiki/synthesis"`:

```bash
mkdir -p "$VAULT_ROOT/wiki/.state"
```

Then, immediately after the `mkdir -p` block, add:

```bash
# CR-002: the state directory must exist as a tracked dir from day one so the
# first ingest's commit doesn't fight with .gitignore semantics on empty dirs.
if [ ! -f "$VAULT_ROOT/wiki/.state/.gitkeep" ]; then
  : > "$VAULT_ROOT/wiki/.state/.gitkeep"
fi
```

- [ ] **Step 2: Update prerequisites wording in `skills/onboard/SKILL.md`**

Edit `skills/onboard/SKILL.md`. Find the `# Second Brain — Onboarding Wizard` heading at the top. Insert a new section immediately under the existing intro paragraph (the one ending "maintaining it over time."):

```markdown
## Prerequisites

Verify before starting the wizard:

- `git --version` succeeds (required at runtime — the vault is a git repo).
- `node --version` reports v18 or newer.
- `npm --version` succeeds (used once during scaffold to install the plugin's runtime dep).

If any check fails, stop and ask the user to install the missing tool.
```

- [ ] **Step 3: Add `git init` + `npm install` to the post-wizard scaffold**

Edit `skills/onboard/SKILL.md`. Find the `## Post-Wizard: Scaffold the Vault` section. Insert these two new steps **before** the current step `### 1. Create directory structure` (and renumber subsequent ones; the existing list is `1. Create directory structure`, `2. Generate the agent config file`, `3. Register the plugin in settings.json` — they become 3, 4, 5):

```markdown
### 1. Initialize git in the vault

If the vault directory is not already a git repo, run:

```bash
(cd "$VAULT_PATH" && git init -q)
```

The vault must be a git repo because the state tooling (`state-sources`) uses git to detect ingest changes. If `git init` fails, stop and report the error.

### 2. Install the plugin's runtime dependency

The plugin needs `js-yaml` (declared in the plugin's repo-root `package.json`). Resolve `$CLAUDE_PLUGIN_ROOT` and run:

```bash
(cd "$CLAUDE_PLUGIN_ROOT" && [ -d node_modules/js-yaml ] || npm install --omit=dev)
```

This is a one-time bootstrap. If it fails because npm is missing, fall back to telling the user how to install manually: `cd <plugin-root> && npm install --omit=dev`.
```

The existing step "Create directory structure" becomes step 3, "Generate the agent config file" becomes step 4, "Register the plugin in settings.json" becomes step 5. Re-number the numbered headers accordingly.

- [ ] **Step 4: Run the onboarding test to ensure nothing broke**

Run: `bash tests/test_onboarding.sh`
Expected: all existing assertions still pass. (The scaffold change adds a directory; the existing test should not break.)

- [ ] **Step 5: Commit**

```bash
git add skills/onboard/scripts/onboarding.sh skills/onboard/SKILL.md
git commit -m "feat(onboard): scaffold wiki/.state/, git init, npm install"
```

---

## Task 14: README + REQUIREMENTS updates

**Files:**
- Modify: `README.md`
- Modify: `docs/REQUIREMENTS.md`

- [ ] **Step 1: Add `git` and `npm install` to README install paths**

Edit `README.md`. In the **Prerequisites** section, add a bullet for git:

```markdown
- **git** — required at runtime. The vault is a git repo; the ingest tool depends on it.
```

In the **Option A — Per-vault install** code block, add one line after the `git clone` step:

```bash
(cd .claude/plugins/second-brain && npm install --omit=dev)
```

In the **Option B — User-wide install** code block, add one line after the `git clone` step:

```bash
(cd ~/.claude/plugins/second-brain && npm install --omit=dev)
```

- [ ] **Step 2: Add git to `docs/REQUIREMENTS.md`**

Edit `docs/REQUIREMENTS.md`. Find the runtime / prerequisites section (look for the line listing Obsidian + Claude Code). Add a bullet:

```markdown
- **git** — the vault is a git repo; ingest state tracking depends on git commits.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/REQUIREMENTS.md
git commit -m "docs: document git runtime requirement and npm install step"
```

---

## Task 15: Add `state-sources` test to onboarding test runner (if there is one)

**Files:**
- (no changes if there is no aggregated test runner)

- [ ] **Step 1: Check for an aggregated test runner**

Run: `ls tests/`
If there's only `test_onboarding.sh`, `test_register_plugin.sh`, `test_state_sources.sh`, there is no aggregator — skip the remaining steps.

If there is a `run_all.sh` or similar:

- [ ] **Step 2: Add `bash tests/test_state_sources.sh` to it**

Append the new test invocation in the same style as the others.

- [ ] **Step 3: Run the aggregated runner end-to-end**

Run: `bash tests/run_all.sh` (or whatever the runner is named).
Expected: all three suites pass.

- [ ] **Step 4: Commit**

```bash
git add tests/run_all.sh
git commit -m "test: include state-sources suite in aggregate runner"
```

---

## Task 16: Manual smoke checklist

Run these by hand before declaring the CR done. None of them are automated.

**Setup:** in a scratch directory, clone the plugin and complete the per-vault install (Option A). Run `/second-brain:onboard` to create a fresh vault.

- [ ] **1. Fresh vault has `wiki/.state/`** — confirm the directory exists and `.gitkeep` is tracked.

- [ ] **2. First ingest.** Drop a single short file into `raw/foo.md`. Run `/second-brain:ingest`.
  - Confirm exactly one new git commit lands in the vault, with message `ingest: raw/foo.md → N pages`.
  - Confirm `wiki/.state/sources.yaml` exists and lists `raw/foo.md` with the wiki pages produced.
  - Confirm the produced wiki pages are inside that commit (not staged separately).

- [ ] **3. Re-ingest with no changes.** Run `/second-brain:ingest` again.
  - SKILL reports "nothing to do" without prompting for sources.

- [ ] **4. Change detection.** Edit one byte of `raw/foo.md`. Re-run ingest.
  - SKILL detects `changed`, reads `previous_wiki_pages`, updates them in place rather than creating new ones.
  - One new git commit lands.

- [ ] **5. Orphan flow.** Delete `raw/foo.md`. Re-run ingest.
  - SKILL surfaces `deleted` with `previous_wiki_pages` and asks the user how to proceed.
  - On user's choice, runs `commit --source raw/foo.md --deleted`. One commit lands removing the entry.

- [ ] **6. Rubbish source.** Drop `raw/bad.md` containing a single garbage line. Run ingest.
  - SKILL determines there's nothing useful to write, runs `commit --allow-empty`.
  - Future ingest runs do not list `bad.md` as `new`.

- [ ] **7. Pre-run baseline.** Hand-edit `wiki/index.md` outside of an ingest run. Run ingest.
  - First commit in the run is `ingest: pre-run baseline`, containing the hand edit.
  - Subsequent per-source commits do NOT include the hand edit.

If any step fails: file the regression as a follow-up task; do not block the CR unless the failure is a correctness issue (exit codes, state file corruption, attribution).

---

## Final verification

- [ ] **Run all tests**

```bash
bash tests/test_state_sources.sh
bash tests/test_onboarding.sh
bash tests/test_register_plugin.sh
```

Expected: each script exits 0, no `FAIL:` lines.

- [ ] **Confirm no stale log-grep references in user-facing docs**

```bash
grep -rn 'wiki/log.md' skills/ README.md docs/cr/ docs/superpowers/
```

Expected: matches only narrative references (the spec, the SKILL's step 7 paragraph). No "grep log.md to find ingested files" instructions remain.

- [ ] **Confirm the plugin still loads end-to-end**

In a clean temp directory:

```bash
claude --plugin-dir <repo>
```

Then in the Claude Code session: `/help` — confirm the four `/second-brain:*` skills are listed.
