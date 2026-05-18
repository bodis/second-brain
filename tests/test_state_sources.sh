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
