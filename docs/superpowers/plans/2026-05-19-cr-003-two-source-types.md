# CR-003 Structured Source Type Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second source kind `structured` (under `src/documentation/<system>/...`) alongside today's `generic` (under `raw/`). The state tool walks both trees, records `kind` + `system` per source, and the ingest SKILL applies light-touch handling (no per-source summary page) to structured docs.

**Architecture:** Extend the existing `state-sources.js` walker to also recurse into `src/documentation/<system>/`. Each entry gains a `kind` field (`generic` or `structured`); structured entries also carry a `system` field derived from the first path segment under `documentation/`. The diff JSON shape stays the same except entries are now uniformly tagged with `kind` (and, for structured, `system`). `cmdCommit` derives `kind`/`system` from the source path. The ingest SKILL gains a "Source types" section and branches the per-source loop: for structured sources, skip the `wiki/sources/` summary step and cite the original `src/documentation/...` path. The query SKILL is updated to prefer citing structured originals over wiki summaries. Onboarding scaffolds an empty `src/documentation/` tracked via `.gitkeep`. The state schema stays at `schema_version: 1` — CR-002 already reserved these fields.

**Tech Stack:** Same as CR-002 — Node 18+ (CommonJS), `js-yaml` 4.x, `git`, bash test harness. No new deps. No schema bump.

**Reference spec:** [`docs/superpowers/specs/2026-05-19-cr-003-two-source-types-design.md`](../specs/2026-05-19-cr-003-two-source-types-design.md)

---

## File Structure

**Create:** none. All changes are edits.

**Modify:**
- `skills/ingest/scripts/state-sources.js` — walker, commit-entry builder, diff output enrichment, JSDoc typedefs.
- `tests/test_state_sources.sh` — add tests 12–20 (9 new cases).
- `skills/onboard/scripts/onboarding.sh` — scaffold `src/documentation/` with `.gitkeep`; add `src/documentation/` to JSON output.
- `tests/test_onboarding.sh` — assert `src/documentation/.gitkeep` is created.
- `skills/ingest/SKILL.md` — add "Source types" section; branch per-source loop on `kind`; add citation format note.
- `skills/query/SKILL.md` — rewrite step 4 to prefer structured originals over wiki summaries.
- `skills/onboard/SKILL.md` — note `src/documentation/` purpose in post-scaffold step 3.

No version bump. Schema version stays `1`.

---

## Task 1: Walker discovers structured docs under `src/documentation/<system>/`

**Files:**
- Modify: `skills/ingest/scripts/state-sources.js` (JSDoc + `walkSources`)
- Test: `tests/test_state_sources.sh` (add Tests 12–16)

- [ ] **Step 1: Extend the JSDoc typedef for `Source`**

In `skills/ingest/scripts/state-sources.js`, find the `@typedef {Object} Source` block at the top of the file (lines 4–13) and add a `system` property line right after the `kind` line. The new typedef block should look like:

```javascript
/**
 * @typedef {Object} Source
 * @property {string} path             POSIX-style vault-relative path.
 * @property {'generic'|'structured'}  kind  Source classification. Generic: under raw/. Structured: under src/documentation/<system>/.
 * @property {string} [system]         For structured sources only: first path segment under src/documentation/ (e.g. "confluence").
 * @property {string} sha256           Content hash, hex lowercase, 64 chars.
 * @property {number} bytes            File size in bytes.
 * @property {string} mtime            ISO 8601 UTC timestamp ending in `Z`.
 * @property {string} [ingested_at]    ISO 8601 UTC; set by `commit`, absent before then.
 * @property {string[]} [wiki_pages]   POSIX-style vault-relative paths of wiki pages this source's ingest touched.
 */
```

Also extend the `@typedef {Object} DiffEntry` block (lines 15–24) to include `system`:

```javascript
/**
 * @typedef {Object} DiffEntry
 * @property {string} path
 * @property {'generic'|'structured'} [kind]
 * @property {string} [system]                 Set only when kind === 'structured'.
 * @property {string} [sha256]
 * @property {number} [bytes]
 * @property {string} [mtime]
 * @property {string} [previous_sha256]
 * @property {string[]} [previous_wiki_pages]
 */
```

- [ ] **Step 2: Add Test 12 — walker discovers a structured doc**

Append to `tests/test_state_sources.sh`, after the existing Test 11 block (right before the final `echo "=== Results"` lines):

```bash
# Test 12: walker finds a file under src/documentation/<system>/ and tags it
# with kind=structured, system=<system>.
echo ""
echo "Test 12: walker discovers structured docs"
V12=$(make_vault vault12)
mkdir -p "$V12/src/documentation/confluence/api"
echo "auth doc" > "$V12/src/documentation/confluence/api/auth.md"
OUT=$( (cd "$V12" && node "$SCRIPT" diff) )
assert_eq "new count is 1"                "1" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new.length)))")"
assert_eq "new path is full structured"   "src/documentation/confluence/api/auth.md" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new[0].path))")"
assert_eq "new kind is structured"        "structured" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new[0].kind))")"
assert_eq "new system is confluence"      "confluence" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new[0].system))")"
```

- [ ] **Step 3: Run Test 12 to verify it fails**

Run: `bash tests/test_state_sources.sh`
Expected: Test 12 reports `FAIL: new count is 1` (today's walker only looks at `raw/`, so `new.length` is 0).

- [ ] **Step 4: Extend `walkSources` to recurse into `src/documentation/<system>/`**

In `skills/ingest/scripts/state-sources.js`, replace the entire `walkSources` function (lines 113–146) with:

```javascript
function walkSources(vault, excludes) {
  const out = [];

  function pushFile(abs, rel, kind, system) {
    let stat;
    try { stat = fs.statSync(abs); }
    catch (err) {
      process.stderr.write(`info: skipping ${rel}: ${err.message}\n`);
      return;
    }
    if (!stat.isFile()) return;
    const entry = {
      path: rel,
      kind,
      sha256: sha256File(abs),
      bytes: stat.size,
      mtime: utcStamp(stat.mtimeMs),
    };
    if (system) entry.system = system;
    out.push(entry);
  }

  function recurseGeneric(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const abs = path.join(dir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join('/');
      if (e.isDirectory()) {
        if (isExcluded(rel + '/', excludes)) continue;
        recurseGeneric(abs);
        continue;
      }
      if (isExcluded(rel, excludes)) continue;
      pushFile(abs, rel, 'generic', null);
    }
  }

  function recurseStructured(dir, system) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const abs = path.join(dir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join('/');
      if (e.isDirectory()) {
        if (isExcluded(rel + '/', excludes)) continue;
        recurseStructured(abs, system);
        continue;
      }
      if (isExcluded(rel, excludes)) continue;
      pushFile(abs, rel, 'structured', system);
    }
  }

  const rawDir = path.join(vault, 'raw');
  if (fs.existsSync(rawDir)) recurseGeneric(rawDir);

  const docDir = path.join(vault, 'src/documentation');
  if (fs.existsSync(docDir)) {
    for (const e of fs.readdirSync(docDir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const abs = path.join(docDir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join('/');
      if (!e.isDirectory()) {
        process.stderr.write(`info: skipping ${rel}: no <system>/ subdirectory\n`);
        continue;
      }
      if (isExcluded(rel + '/', excludes)) continue;
      recurseStructured(abs, e.name);
    }
  }

  return out;
}
```

- [ ] **Step 5: Run Test 12 to verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: Test 12 reports 4 PASS lines (count, path, kind, system). Tests 1–11 still pass.

- [ ] **Step 6: Add Tests 13–16 — nested paths, mixed trees, loose-file skip, non-documentation skip**

Append to `tests/test_state_sources.sh` after Test 12:

```bash
# Test 13: nested structured paths get the first segment under documentation/
# as their system, not a deeper segment.
echo ""
echo "Test 13: walker handles deeply nested structured paths"
V13=$(make_vault vault13)
mkdir -p "$V13/src/documentation/confluence/space/team"
echo "page" > "$V13/src/documentation/confluence/space/team/page.md"
OUT=$( (cd "$V13" && node "$SCRIPT" diff) )
assert_eq "deep new system is confluence"  "confluence" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new[0].system))")"
assert_eq "deep new path preserved"        "src/documentation/confluence/space/team/page.md" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).new[0].path))")"

# Test 14: walker finds both raw/ and src/documentation/ files, each tagged
# correctly. `new` is sorted by path so raw/ comes after src/.
echo ""
echo "Test 14: walker mixes raw and structured"
V14=$(make_vault vault14)
mkdir -p "$V14/src/documentation/conf"
echo "raw" > "$V14/raw/x.md"
echo "structured" > "$V14/src/documentation/conf/y.md"
OUT=$( (cd "$V14" && node "$SCRIPT" diff) )
assert_eq "two new entries"               "2" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new.length)))")"
assert_eq "raw entry kind is generic"      "generic" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).new.find(n=>n.path==='raw/x.md'); process.stdout.write(e.kind)})")"
assert_eq "raw entry has no system"        "undefined" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).new.find(n=>n.path==='raw/x.md'); process.stdout.write(String(e.system))})")"
assert_eq "structured entry kind"          "structured" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).new.find(n=>n.path==='src/documentation/conf/y.md'); process.stdout.write(e.kind)})")"
assert_eq "structured entry system"        "conf" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).new.find(n=>n.path==='src/documentation/conf/y.md'); process.stdout.write(e.system)})")"

# Test 15: a file directly under src/documentation/ (no <system>/ parent) is
# skipped and produces an info-level stderr log.
echo ""
echo "Test 15: walker skips loose files directly under src/documentation/"
V15=$(make_vault vault15)
mkdir -p "$V15/src/documentation"
echo "lonely" > "$V15/src/documentation/loose.md"
OUT=$( (cd "$V15" && node "$SCRIPT" diff 2>/tmp/cr3_t15_stderr) )
ERR=$(cat /tmp/cr3_t15_stderr); rm -f /tmp/cr3_t15_stderr
assert_eq "loose file not in new"          "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new.length)))")"
assert_eq "stderr names the loose file"    "True" "$(echo "$ERR" | grep -q 'src/documentation/loose.md' && echo True || echo False)"
assert_eq "stderr explains why"            "True" "$(echo "$ERR" | grep -q 'no <system>/ subdirectory' && echo True || echo False)"

# Test 16: anything under src/ that is NOT documentation/ is invisible to the
# walker. (Per CR-003 non-goals — only src/documentation/ is recognized.)
echo ""
echo "Test 16: walker ignores non-documentation src/ content"
V16=$(make_vault vault16)
mkdir -p "$V16/src/notes"
echo "note" > "$V16/src/notes/foo.md"
OUT=$( (cd "$V16" && node "$SCRIPT" diff) )
assert_eq "src/notes/ file not in new"     "0" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).new.length)))")"
```

- [ ] **Step 7: Run Tests 13–16 to verify all pass**

Run: `bash tests/test_state_sources.sh`
Expected: Tests 12–16 all PASS (4 + 2 + 5 + 3 + 1 = 15 new PASS lines).

- [ ] **Step 8: Commit**

```bash
git add skills/ingest/scripts/state-sources.js tests/test_state_sources.sh
git commit -m "feat(state-sources): walker discovers structured docs under src/documentation/"
```

---

## Task 2: `commit` records `kind` and `system` for structured sources

**Files:**
- Modify: `skills/ingest/scripts/state-sources.js` (`cmdCommit`)
- Test: `tests/test_state_sources.sh` (add Tests 17–18)

- [ ] **Step 1: Add Test 17 — commit on a structured source records kind + system**

Append to `tests/test_state_sources.sh` after Test 16:

```bash
# Test 17: commit on a file under src/documentation/<system>/ records the
# entry with kind=structured and system=<first segment>.
echo ""
echo "Test 17: commit on a structured source records kind + system"
V17=$(make_vault vault17)
mkdir -p "$V17/src/documentation/conf/api" "$V17/wiki/entities"
echo "auth doc" > "$V17/src/documentation/conf/api/auth.md"
echo "oauth entity" > "$V17/wiki/entities/oauth.md"
(cd "$V17" && node "$SCRIPT" commit --source src/documentation/conf/api/auth.md >/dev/null)
YAML="$V17/wiki/.state/sources.yaml"
assert_eq "one source recorded"        "1"                                          "$(get_yaml "$YAML" "d.sources.length")"
assert_eq "structured source path"     "src/documentation/conf/api/auth.md"         "$(get_yaml "$YAML" "d.sources[0].path")"
assert_eq "structured kind recorded"   "structured"                                 "$(get_yaml "$YAML" "d.sources[0].kind")"
assert_eq "structured system recorded" "conf"                                       "$(get_yaml "$YAML" "d.sources[0].system")"
assert_eq "wiki_pages auto-detected"   "wiki/entities/oauth.md"                     "$(get_yaml "$YAML" "d.sources[0].wiki_pages[0]")"
```

- [ ] **Step 2: Run Test 17 to verify it fails**

Run: `bash tests/test_state_sources.sh`
Expected: Test 17 reports `FAIL: structured kind recorded` (today's `cmdCommit` hard-codes `kind: 'generic'`).

- [ ] **Step 3: Update `cmdCommit` to derive `kind` and `system` from the source path**

In `skills/ingest/scripts/state-sources.js`, find the `cmdCommit` function. Locate the block that builds `entry` (around lines 274–283 — the `const stat = ...` then `const entry = { path: args.source, kind: 'generic', ... }`).

Replace just that `const entry = { ... }` assignment (and add a small classification block above it) with:

```javascript
  const stat = fs.statSync(abs);

  let kind, system;
  if (args.source.startsWith('raw/')) {
    kind = 'generic';
    system = null;
  } else if (args.source.startsWith('src/documentation/')) {
    const segs = args.source.split('/');
    // segs = ['src', 'documentation', '<system>', '<...rest>']
    if (segs.length < 4 || segs[2] === '') {
      die(`source path "${args.source}" is under src/documentation/ but missing a <system>/ subdirectory`, 1);
    }
    kind = 'structured';
    system = segs[2];
  } else {
    die(`source path "${args.source}" is not under raw/ or src/documentation/`, 1);
  }

  const entry = {
    path: args.source,
    kind,
    sha256: sha256File(abs),
    bytes: stat.size,
    mtime: utcStamp(stat.mtimeMs),
    ingested_at: utcStamp(Date.now()),
    wiki_pages: wikiPages,
  };
  if (system) entry.system = system;
```

Note: `entry.system` is inserted before `sha256` for human readability when YAML-dumped — but the order in the JS object literal does not match the dump order anyway since we re-build via `if`. That's fine; the YAML dump is keyed by insertion order. To keep `system` adjacent to `kind` in the file, instead build the entry with `system` set right after `kind`:

```javascript
  const entry = { path: args.source, kind };
  if (system) entry.system = system;
  entry.sha256 = sha256File(abs);
  entry.bytes = stat.size;
  entry.mtime = utcStamp(stat.mtimeMs);
  entry.ingested_at = utcStamp(Date.now());
  entry.wiki_pages = wikiPages;
```

Use the second form (system right after kind) — replaces just the entry-construction block. The exit-1 `die` calls go above it as shown.

- [ ] **Step 4: Run Test 17 to verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: Test 17 all PASS. Tests 1–16 still pass (raw/ paths still classified as `generic`).

- [ ] **Step 5: Add Test 18 — commit rejects paths outside both trees**

Append after Test 17:

```bash
# Test 18: commit refuses a source path that is not under raw/ or
# src/documentation/. Exits 1 and does NOT write state.
echo ""
echo "Test 18: commit rejects paths outside raw/ and src/documentation/"
V18=$(make_vault vault18)
mkdir -p "$V18/notes" "$V18/wiki/entities"
echo "stray" > "$V18/notes/foo.md"
echo "out" > "$V18/wiki/entities/bar.md"
set +e
ERR=$( (cd "$V18" && node "$SCRIPT" commit --source notes/foo.md) 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "exit code 1 on foreign path"  "1" "$RC"
assert_eq "stderr names the problem"     "True" "$(echo "$ERR" | grep -q 'not under raw/ or src/documentation/' && echo True || echo False)"
assert_eq "no sources.yaml written"      "no" "$([ -f "$V18/wiki/.state/sources.yaml" ] && echo yes || echo no)"
```

- [ ] **Step 6: Run Test 18 to verify it passes**

Run: `bash tests/test_state_sources.sh`
Expected: Test 18 reports 3 PASS lines. Step 3 already implemented the rejection.

- [ ] **Step 7: Commit**

```bash
git add skills/ingest/scripts/state-sources.js tests/test_state_sources.sh
git commit -m "feat(state-sources): commit derives kind + system from source path"
```

---

## Task 3: `diff` enriches `changed` and `deleted` with `kind` and `system`

**Files:**
- Modify: `skills/ingest/scripts/state-sources.js` (`cmdDiff`)
- Test: `tests/test_state_sources.sh` (add Tests 19–20)

- [ ] **Step 1: Add Test 19 — structured source re-scrape surfaces as `changed` with kind + system**

Append to `tests/test_state_sources.sh` after Test 18:

```bash
# Test 19: a structured source whose content changes after a previous commit
# surfaces in diff.changed with kind, system, previous_sha256, and
# previous_wiki_pages.
echo ""
echo "Test 19: changed structured entry carries kind + system + previous state"
V19=$(make_vault vault19)
mkdir -p "$V19/src/documentation/conf/api" "$V19/wiki/concepts"
echo "v1 auth doc" > "$V19/src/documentation/conf/api/auth.md"
echo "concept v1"  > "$V19/wiki/concepts/api-auth.md"
(cd "$V19" && node "$SCRIPT" commit --source src/documentation/conf/api/auth.md >/dev/null)
# Modify the structured doc.
echo "v2 auth doc with more content" > "$V19/src/documentation/conf/api/auth.md"
OUT=$( (cd "$V19" && node "$SCRIPT" diff) )
assert_eq "changed count is 1"             "1" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).changed.length)))")"
assert_eq "changed kind is structured"     "structured" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).changed[0].kind))")"
assert_eq "changed system is conf"         "conf" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).changed[0].system))")"
assert_eq "changed previous_sha256 present" "True" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(typeof JSON.parse(d).changed[0].previous_sha256 === 'string' ? 'True' : 'False'))")"
assert_eq "changed prev wiki page"         "wiki/concepts/api-auth.md" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).changed[0].previous_wiki_pages[0]))")"
```

- [ ] **Step 2: Add Test 20 — deleted structured entry carries kind + system**

Append after Test 19:

```bash
# Test 20: deleting a previously-ingested structured source surfaces it as
# deleted with kind, system, and previous_wiki_pages from the old yaml entry.
# Also: a deleted generic source now carries kind=generic (uniformity).
echo ""
echo "Test 20: deleted entries carry kind + system from prior yaml"
V20=$(make_vault vault20)
mkdir -p "$V20/raw" "$V20/src/documentation/conf/api" "$V20/wiki/sources" "$V20/wiki/entities"
echo "gen body" > "$V20/raw/gen.md"
echo "gen summary" > "$V20/wiki/sources/gen.md"
(cd "$V20" && node "$SCRIPT" commit --source raw/gen.md >/dev/null)
echo "str body" > "$V20/src/documentation/conf/api/old.md"
echo "str entity" > "$V20/wiki/entities/old-api.md"
(cd "$V20" && node "$SCRIPT" commit --source src/documentation/conf/api/old.md >/dev/null)
# Delete both on disk.
rm "$V20/raw/gen.md" "$V20/src/documentation/conf/api/old.md"
OUT=$( (cd "$V20" && node "$SCRIPT" diff) )
assert_eq "deleted count is 2"                "2" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).deleted.length)))")"
assert_eq "generic delete carries kind"        "generic" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).deleted.find(x=>x.path==='raw/gen.md'); process.stdout.write(e.kind)})")"
assert_eq "generic delete has no system"       "undefined" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).deleted.find(x=>x.path==='raw/gen.md'); process.stdout.write(String(e.system))})")"
assert_eq "structured delete kind"             "structured" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).deleted.find(x=>x.path==='src/documentation/conf/api/old.md'); process.stdout.write(e.kind)})")"
assert_eq "structured delete system"           "conf" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).deleted.find(x=>x.path==='src/documentation/conf/api/old.md'); process.stdout.write(e.system)})")"
assert_eq "structured delete prev wiki page"   "wiki/entities/old-api.md" "$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{const e=JSON.parse(d).deleted.find(x=>x.path==='src/documentation/conf/api/old.md'); process.stdout.write(e.previous_wiki_pages[0])})")"
```

- [ ] **Step 3: Run Tests 19–20 to verify they fail**

Run: `bash tests/test_state_sources.sh`
Expected:
- Test 19 fails on `changed system is conf` (today's `changed` entries do not emit `system`).
- Test 20 fails on `generic delete carries kind` (today's `deleted` entries omit `kind` entirely).

- [ ] **Step 4: Update `cmdDiff` to emit `system` on `changed` and `kind`+`system` on `deleted`**

In `skills/ingest/scripts/state-sources.js`, replace the `cmdDiff` function (lines 180–219) with:

```javascript
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
      const entry = { path: f.path, kind: f.kind };
      if (f.system) entry.system = f.system;
      entry.sha256 = f.sha256;
      entry.bytes = f.bytes;
      entry.mtime = f.mtime;
      newList.push(entry);
    } else if (y.sha256 !== f.sha256) {
      const kind = y.kind || 'generic';
      const entry = { path: f.path, kind };
      const system = y.system || f.system;
      if (kind === 'structured' && system) entry.system = system;
      entry.sha256 = f.sha256;
      entry.bytes = f.bytes;
      entry.mtime = f.mtime;
      entry.previous_sha256 = y.sha256;
      entry.previous_wiki_pages = Array.isArray(y.wiki_pages) ? y.wiki_pages : [];
      changedList.push(entry);
    }
  }

  const deletedList = [];
  for (const y of doc.sources) {
    if (!fsByPath.has(y.path)) {
      const kind = y.kind || 'generic';
      const entry = { path: y.path, kind };
      if (kind === 'structured' && y.system) entry.system = y.system;
      entry.previous_wiki_pages = Array.isArray(y.wiki_pages) ? y.wiki_pages : [];
      deletedList.push(entry);
    }
  }

  const byPath = (a, b) => a.path.localeCompare(b.path);
  newList.sort(byPath); changedList.sort(byPath); deletedList.sort(byPath);

  process.stdout.write(JSON.stringify({ new: newList, changed: changedList, deleted: deletedList }, null, 2) + '\n');
}
```

Behavior notes:
- `new`: `kind` came from the walker (already correct); now `system` from the walker is also forwarded for structured entries.
- `changed`: `kind` comes from yaml (preserves the recorded value); `system` comes from yaml first, then walker as a fallback (defensive — yaml should always carry it for structured).
- `deleted`: `kind` and `system` come from yaml. `kind` defaults to `generic` for any old entry written before this change (uniformity).

- [ ] **Step 5: Run Tests 19–20 to verify they pass**

Run: `bash tests/test_state_sources.sh`
Expected: Tests 19 and 20 all PASS. Tests 1–18 still pass (raw-only flows unaffected; generic entries unchanged except `deleted` now carries `kind: 'generic'`, which the existing tests don't check on the negative side).

- [ ] **Step 6: Run the full test suite once more to confirm no regressions**

Run: `bash tests/test_state_sources.sh`
Expected: Final line `=== Results: N passed, 0 failed ===` with all tests green.

- [ ] **Step 7: Commit**

```bash
git add skills/ingest/scripts/state-sources.js tests/test_state_sources.sh
git commit -m "feat(state-sources): diff emits kind + system on changed/deleted"
```

---

## Task 4: Onboarding scaffolds `src/documentation/`

**Files:**
- Modify: `skills/onboard/scripts/onboarding.sh`
- Test: `tests/test_onboarding.sh`

- [ ] **Step 1: Add the failing test assertion in `test_onboarding.sh`**

In `tests/test_onboarding.sh`, locate Test 1 (the block under `# Test 1: Script runs successfully on a new directory`, around lines 54–66). Append two new assertions right before the blank line that ends Test 1, after `assert_dir "$TEST_VAULT/output"`:

```bash
assert_dir "$TEST_VAULT/src/documentation"
assert_file "$TEST_VAULT/src/documentation/.gitkeep"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_onboarding.sh`
Expected:
- `FAIL: directory missing — .../src/documentation`
- `FAIL: file missing — .../src/documentation/.gitkeep`

- [ ] **Step 3: Update `onboarding.sh` to scaffold `src/documentation/` with `.gitkeep`**

In `skills/onboard/scripts/onboarding.sh`, find the directory-creation block (around lines 14–22, beginning `# 1. Create directory structure`). After the existing `mkdir -p` lines (just after `mkdir -p "$VAULT_ROOT/output"`), add:

```bash
mkdir -p "$VAULT_ROOT/src/documentation"
```

Then, immediately after the existing `wiki/.state/.gitkeep` block (the `if [ ! -f "$VAULT_ROOT/wiki/.state/.gitkeep" ]; then ... fi` around lines 26–28), add the matching pattern for `src/documentation`:

```bash
# CR-003: src/documentation/ must exist as a tracked-but-empty directory from
# day one so the first structured ingest doesn't have to create the tree.
if [ ! -f "$VAULT_ROOT/src/documentation/.gitkeep" ]; then
  : > "$VAULT_ROOT/src/documentation/.gitkeep"
fi
```

Finally, update the JSON summary at the bottom of the file. Find the `"directories"` array (around lines 103–112) and add `"src/documentation/"` after `"output/"`:

```bash
  "directories": [
    "raw/",
    "raw/assets/",
    "src/documentation/",
    "wiki/",
    "wiki/sources/",
    "wiki/entities/",
    "wiki/concepts/",
    "wiki/synthesis/",
    "output/"
  ],
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_onboarding.sh`
Expected: Two new PASS lines for `src/documentation` and `src/documentation/.gitkeep`. All other tests still pass.

- [ ] **Step 5: Commit**

```bash
git add skills/onboard/scripts/onboarding.sh tests/test_onboarding.sh
git commit -m "feat(onboard): scaffold src/documentation/ with .gitkeep"
```

---

## Task 5: Ingest SKILL — add Source types section and per-source branching

**Files:**
- Modify: `skills/ingest/SKILL.md`

No automated tests — this is prose. The manual smoke checklist in §12.2 of the spec covers acceptance.

- [ ] **Step 1: Insert a new "Source types" section after Tooling and before "Identify Sources to Process"**

In `skills/ingest/SKILL.md`, find the existing `## Tooling` section (lines 15–24). It ends with the bash code block on line 23 and a closing fence on line 24. Right after that closing fence and the blank line that follows it, insert this new section before the next heading `## Identify Sources to Process` (which is at line 25):

```markdown
## Source types

The state tool reports two source kinds in its `diff` output:

- **`kind: generic`** — files under `raw/`. One-off articles, transcripts, notes. **Treatment:** produce a `wiki/sources/<name>.md` summary page AND extract entities/concepts.
- **`kind: structured`** — files under `src/documentation/<system>/...`. Authoritative exported docs (e.g. confluence, github-wiki, internal-docs). The author already structured the content. **Treatment:** light-touch — DO NOT produce a `wiki/sources/<...>.md` summary page. The original IS the canonical source. Extract entities/concepts mentioned in it and cite back to the original path.

Structured-source entries in `diff` output also carry a `system` field (the first segment under `src/documentation/`, e.g. `confluence`). Use it to disambiguate when prompting the user about deletions or large changes.

```

(Keep the trailing blank line before `## Identify Sources to Process`.)

- [ ] **Step 2: Update the "Process Each Source" preamble to branch on `kind`**

In `skills/ingest/SKILL.md`, find the `## Process Each Source` heading (line 57 today, but it will have shifted after Step 1) and its first paragraph:

```markdown
For each entry in `new` and `changed`, follow this workflow. If the entry is `changed`, before step 1 read each path in `previous_wiki_pages` — the goal is to **update** those existing pages, not create new ones.
```

Replace that paragraph (just the paragraph, not the heading) with:

```markdown
For each entry in `new` and `changed`, follow this workflow. The flow branches on `kind`:

- **`generic`**: full workflow — create a `wiki/sources/<name>.md` summary AND entity/concept pages. All nine steps below apply.
- **`structured`**: light-touch — SKIP step 3 ("Create source summary page"). The original `src/documentation/...` file is the canonical page. Steps 1–2 and 4–9 still apply; every reference to the source uses its full vault-relative path.

If the entry is `changed`, before step 1 read each path in `previous_wiki_pages` — the goal is to **update** those existing pages, not create new ones.

When `diff` lists many `changed` entries with the same `system` (e.g. a bulk re-scrape of 50 confluence pages), still process them one at a time per the steps below. The per-source commits are the audit trail; do not batch.
```

- [ ] **Step 3: Add citation-format guidance to step 4 ("Update entity and concept pages")**

In `skills/ingest/SKILL.md`, find the `### 4. Update entity and concept pages` heading and its current body. After the `**If no wiki page exists:**` sub-bullet block ends (i.e. after the final `- Write a focused summary...` line of step 4), append a new paragraph before `### 5. Add wikilinks`:

```markdown

**Citation format:**

- **Generic source** (`kind: generic`): use just the filename in frontmatter, e.g. `sources: [original-filename.md]`. In prose, use `[[Source - Original Title]]`.
- **Structured source** (`kind: structured`): use the **full vault-relative path** in frontmatter, e.g. `sources: [src/documentation/confluence/api/auth.md]`. This matches the path key in `sources.yaml`. In prose, use a path-form wikilink: `[[src/documentation/confluence/api/auth]]` (Obsidian resolves these).

```

- [ ] **Step 4: Add a note in step 8 about `--allow-empty` for structured re-scrapes**

In `skills/ingest/SKILL.md`, find the `### 8. Commit the source` block. After the existing `--allow-empty` paragraph (the second code-block in step 8, which currently ends with `node "$CLAUDE_PLUGIN_ROOT/skills/ingest/scripts/state-sources.js" commit --source <path> --allow-empty`), append one sentence after that code block, before the existing `If the tool exits with code 6...` paragraph:

```markdown

Use `--allow-empty` for a structured re-scrape that produced only whitespace or formatting changes — the state advances without polluting the wiki.

```

- [ ] **Step 5: Spot-check the edited file**

Run: `grep -n "kind: structured" skills/ingest/SKILL.md | head`
Expected: two or three matches in the new "Source types" section, the "Process Each Source" preamble, and the citation-format note.

Run: `grep -n "^### " skills/ingest/SKILL.md`
Expected: nine `### N.` headers (1 through 9) under the per-source loop, unchanged.

- [ ] **Step 6: Commit**

```bash
git add skills/ingest/SKILL.md
git commit -m "docs(ingest): document structured source type and light-touch loop"
```

---

## Task 6: Query SKILL — prefer structured originals over wiki summaries

**Files:**
- Modify: `skills/query/SKILL.md`

- [ ] **Step 1: Replace step 4 of the search strategy**

In `skills/query/SKILL.md`, find the section `### 4. Check raw sources if needed` (lines 35–37 today) — its body is:

```markdown
If the wiki pages don't fully answer the question, check relevant source summaries in `wiki/sources/` for additional detail. Only go to files in `raw/` as a last resort.
```

Replace the heading AND that body with:

```markdown
### 4. Check originals for verification or depth

If the wiki pages don't fully answer the question, or you need exact wording, go to the originals — but the choice depends on the source kind recorded in `wiki/.state/sources.yaml`:

- **Structured sources** (`src/documentation/<system>/...`, recorded with `kind: structured`): these are authoritative — the author already structured them. Read them directly when you need precise facts or quotes. Cite them by full vault-relative path: `[[src/documentation/confluence/api/auth]]`.
- **Generic sources** (`raw/...`, recorded with `kind: generic`): prefer the `wiki/sources/<name>.md` summary when the user wants the gist. Only go to the original `raw/` file if the summary lacks detail. Cite either form.
```

- [ ] **Step 2: Update the "Search the wiki first" convention to reflect the structured-original preference**

In `skills/query/SKILL.md`, find the `## Conventions` section. The first bullet today is:

```markdown
- **Search the wiki first.** Only go to raw sources if the wiki doesn't have the answer.
```

Replace just that bullet with:

```markdown
- **Search the wiki first.** Order: `wiki/index.md` → wiki pages → originals. For originals, prefer `src/documentation/` for facts (authoritative); fall back to `raw/` only when wiki summaries are insufficient.
```

- [ ] **Step 3: Commit**

```bash
git add skills/query/SKILL.md
git commit -m "docs(query): prefer structured originals over wiki summaries for facts"
```

---

## Task 7: Onboard SKILL — note `src/documentation/` purpose

**Files:**
- Modify: `skills/onboard/SKILL.md`

- [ ] **Step 1: Add a note to "Create directory structure" (post-wizard step 3)**

In `skills/onboard/SKILL.md`, find the `### 3. Create directory structure` section. Today its body is:

```markdown
Run the onboarding script, passing the full vault path:

```
bash <skill-directory>/scripts/onboarding.sh <vault-path>
```

This creates all directories and the initial `wiki/index.md` and `wiki/log.md` files.
```

Append two lines to that body, after the existing "This creates all directories..." sentence:

```markdown

The vault gets two source roots: `raw/` for one-off clipped articles (generic sources) and `src/documentation/` for authoritative tree-shaped docs (structured sources, e.g. confluence or github-wiki exports). Both are scaffolded empty; the user (or an external scraper like `doc-downloader`) drops files in later under `src/documentation/<system>/...`.
```

- [ ] **Step 2: Commit**

```bash
git add skills/onboard/SKILL.md
git commit -m "docs(onboard): explain raw/ vs src/documentation/ source roots"
```

---

## Task 8: Final verification — run all tests and exercise manual smoke

**Files:**
- None. Verification only.

- [ ] **Step 1: Run the state-sources test suite**

Run: `bash tests/test_state_sources.sh`
Expected: `=== Results: N passed, 0 failed ===` (N = today's count + 18 new PASS assertions across Tests 12–20).

- [ ] **Step 2: Run the onboarding test suite**

Run: `bash tests/test_onboarding.sh`
Expected: `=== Results: N passed, 0 failed ===` (N = today's count + 2).

- [ ] **Step 3: Run the register-plugin test suite (regression check)**

Run: `bash tests/test_register_plugin.sh`
Expected: all green. (Unchanged by CR-003 but run to confirm no incidental breakage.)

- [ ] **Step 4: Manual smoke — fresh vault has `src/documentation/`**

Pick a scratch path (e.g. `/tmp/smoke-cr3`). Run:

```bash
rm -rf /tmp/smoke-cr3 && mkdir -p /tmp/smoke-cr3
bash skills/onboard/scripts/onboarding.sh /tmp/smoke-cr3 2>/dev/null
ls -la /tmp/smoke-cr3/src/documentation/
```

Expected: directory exists, contains `.gitkeep`.

- [ ] **Step 5: Manual smoke — walker diff sees a structured doc**

```bash
cd /tmp/smoke-cr3 && git init -q && git add . && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm init
mkdir -p src/documentation/confluence/api
echo "auth doc body" > src/documentation/confluence/api/auth.md
node "$OLDPWD/skills/ingest/scripts/state-sources.js" diff
```

Expected: JSON output with one entry in `new`:
```json
{ "path": "src/documentation/confluence/api/auth.md", "kind": "structured", "system": "confluence", ... }
```

Clean up: `rm -rf /tmp/smoke-cr3`.

- [ ] **Step 6: Final commit (only if any uncommitted files remain)**

Run: `git status`
Expected: clean working tree (all task commits already landed).

If anything is dirty, investigate before deciding what to commit. No catch-all commit.

---

## Out of scope reminder

Per the spec (§3 Non-goals and §15 Out of scope), this plan does NOT:
- Implement an auto-scraper. That's the separate `doc-downloader` project.
- Add per-system `.meta.yaml` files.
- Bump the `sources.yaml` schema_version (stays at `1` — CR-002 reserved the fields).
- Detect renames between scrapes (rename = `deleted + new`, acceptable).
- Recognize other `src/` subdirectories beyond `documentation/`.
- Modify lint (no false positives surface — light-touch means no missing `wiki/sources/` page for structured entries).
- Add a "Documentation" category to `wiki/index.md` (deferred — they're navigable via Obsidian's file tree).
