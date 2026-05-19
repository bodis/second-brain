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

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
