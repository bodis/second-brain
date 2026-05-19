#!/bin/bash
set -e

# Test: onboarding.sh creates correct vault structure
# Usage: bash tests/test_onboarding.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ONBOARDING="$REPO_ROOT/skills/onboard/scripts/onboarding.sh"
TEST_DIR=$(mktemp -d)
TEST_VAULT="$TEST_DIR/test-vault"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

PASS=0
FAIL=0

assert_dir() {
  if [ -d "$1" ]; then
    echo "  PASS: directory exists — $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: directory missing — $1"
    FAIL=$((FAIL + 1))
  fi
}

assert_file() {
  if [ -f "$1" ]; then
    echo "  PASS: file exists — $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: file missing — $1"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  if grep -q "$2" "$1" 2>/dev/null; then
    echo "  PASS: file contains '$2' — $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: file does not contain '$2' — $1"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Test: onboarding.sh ==="
echo ""

# Test 1: Script runs successfully on a new directory
echo "Test 1: Fresh vault scaffolding"
bash "$ONBOARDING" "$TEST_VAULT" 2>/dev/null

assert_dir "$TEST_VAULT/raw"
assert_dir "$TEST_VAULT/raw/assets"
assert_dir "$TEST_VAULT/wiki"
assert_dir "$TEST_VAULT/wiki/sources"
assert_dir "$TEST_VAULT/wiki/entities"
assert_dir "$TEST_VAULT/wiki/concepts"
assert_dir "$TEST_VAULT/wiki/synthesis"
assert_dir "$TEST_VAULT/output"
assert_dir "$TEST_VAULT/src/documentation"
assert_file "$TEST_VAULT/src/documentation/.gitkeep"

echo ""

# Test 2: wiki/index.md created with correct scaffolding
echo "Test 2: wiki/index.md content"
assert_file "$TEST_VAULT/wiki/index.md"
assert_contains "$TEST_VAULT/wiki/index.md" "## Sources"
assert_contains "$TEST_VAULT/wiki/index.md" "## Entities"
assert_contains "$TEST_VAULT/wiki/index.md" "## Concepts"
assert_contains "$TEST_VAULT/wiki/index.md" "## Synthesis"

echo ""

# Test 3: wiki/log.md created with header
echo "Test 3: wiki/log.md content"
assert_file "$TEST_VAULT/wiki/log.md"
assert_contains "$TEST_VAULT/wiki/log.md" "# Log"

echo ""

# Test 4: Idempotent — running again doesn't overwrite existing files
echo "Test 4: Idempotency"
echo "# Custom content" >> "$TEST_VAULT/wiki/index.md"
bash "$ONBOARDING" "$TEST_VAULT" 2>/dev/null
assert_contains "$TEST_VAULT/wiki/index.md" "# Custom content"

echo ""

# Test 5: Script outputs valid JSON
echo "Test 5: JSON output"
OUTPUT=$(bash "$ONBOARDING" "$TEST_VAULT" 2>/dev/null)
if echo "$OUTPUT" | python3 -m json.tool > /dev/null 2>&1; then
  echo "  PASS: output is valid JSON"
  PASS=$((PASS + 1))
else
  echo "  FAIL: output is not valid JSON"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
