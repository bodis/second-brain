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

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
