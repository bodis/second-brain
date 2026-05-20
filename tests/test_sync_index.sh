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
