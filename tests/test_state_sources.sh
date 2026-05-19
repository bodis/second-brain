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

# Test 19: commit refuses a path under src/documentation/ that lacks a
# <system>/ subdirectory. Distinct die branch from Test 18 — different
# stderr message, same exit code 1, same no-state guarantee.
echo ""
echo "Test 19: commit rejects src/documentation/ paths without a system subdir"
V19a=$(make_vault vault19a)
mkdir -p "$V19a/src/documentation" "$V19a/wiki/entities"
echo "stray" > "$V19a/src/documentation/loose.md"
echo "out" > "$V19a/wiki/entities/foo.md"
set +e
ERR=$( (cd "$V19a" && node "$SCRIPT" commit --source src/documentation/loose.md) 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "exit code 1 on missing system" "1" "$RC"
assert_eq "stderr names the missing system" "True" "$(echo "$ERR" | grep -q 'missing a <system>/ subdirectory' && echo True || echo False)"
assert_eq "no sources.yaml written"        "no" "$([ -f "$V19a/wiki/.state/sources.yaml" ] && echo yes || echo no)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
