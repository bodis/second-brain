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
