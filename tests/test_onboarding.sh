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

# Test 3.5: frontmatter contract scaffolded (CR-004)
echo "Test 3.5: wiki/.state/frontmatter-contract.yaml"
assert_file "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "schema_version: 1"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "generated_by: scripts/validate-wiki.js"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "sources:"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "optional:"
assert_contains "$TEST_VAULT/wiki/.state/frontmatter-contract.yaml" "relations:"

echo ""

# Test 4: Idempotent — running again doesn't overwrite existing files
# temporary: Test 4 is removed in Task 3 of CR-006. The re-run now exits 3 due
# to the orphan-scaffold guard (no .obsidian/ in $TEST_VAULT), so we bracket
# the invocation with set +e / set -e to let the suite continue.
echo "Test 4: Idempotency"
echo "# Custom content" >> "$TEST_VAULT/wiki/index.md"
set +e
bash "$ONBOARDING" "$TEST_VAULT" 2>/dev/null
set -e
assert_contains "$TEST_VAULT/wiki/index.md" "# Custom content"

echo ""

# Test 5: Script outputs valid JSON
# temporary: Test 5 also re-runs on $TEST_VAULT which now lacks .obsidian/, so
# the orphan-scaffold guard makes this exit non-zero. Bracket with set +e/-e
# so the suite reaches Test 6 and Test 7. Removed alongside Test 4 in Task 3.
echo "Test 5: JSON output"
set +e
OUTPUT=$(bash "$ONBOARDING" "$TEST_VAULT" 2>/dev/null)
set -e
if echo "$OUTPUT" | python3 -m json.tool > /dev/null 2>&1; then
  echo "  PASS: output is valid JSON"
  PASS=$((PASS + 1))
else
  echo "  FAIL: output is not valid JSON"
  FAIL=$((FAIL + 1))
fi

echo ""

# Test 6: Abort — vault already onboarded (.obsidian/ + wiki/ both present)
echo "Test 6: Abort — already onboarded"
ABORT_VAULT="$TEST_DIR/abort-already"
mkdir -p "$ABORT_VAULT/.obsidian" "$ABORT_VAULT/wiki"
set +e
ABORT_OUT=$(bash "$ONBOARDING" "$ABORT_VAULT" 2>&1 >/dev/null)
ABORT_EXIT=$?
set -e
if [ "$ABORT_EXIT" != "0" ]; then
  echo "  PASS: script exited non-zero on already-onboarded vault (exit=$ABORT_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script exited 0 on already-onboarded vault (expected non-zero)"
  FAIL=$((FAIL + 1))
fi
if echo "$ABORT_OUT" | grep -q "already onboarded"; then
  echo "  PASS: error message mentions 'already onboarded'"
  PASS=$((PASS + 1))
else
  echo "  FAIL: error message did not mention 'already onboarded' — got: $ABORT_OUT"
  FAIL=$((FAIL + 1))
fi
if [ ! -d "$ABORT_VAULT/raw" ] && [ ! -d "$ABORT_VAULT/wiki/sources" ]; then
  echo "  PASS: no scaffold directories were created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: scaffold directories were created despite abort"
  FAIL=$((FAIL + 1))
fi

echo ""

# Test 7: Abort — orphaned scaffold (wiki/ present, .obsidian/ absent)
echo "Test 7: Abort — orphaned scaffold"
ORPHAN_VAULT="$TEST_DIR/abort-orphan"
mkdir -p "$ORPHAN_VAULT/wiki"
set +e
ORPHAN_OUT=$(bash "$ONBOARDING" "$ORPHAN_VAULT" 2>&1 >/dev/null)
ORPHAN_EXIT=$?
set -e
if [ "$ORPHAN_EXIT" != "0" ]; then
  echo "  PASS: script exited non-zero on orphaned scaffold (exit=$ORPHAN_EXIT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: script exited 0 on orphaned scaffold (expected non-zero)"
  FAIL=$((FAIL + 1))
fi
if echo "$ORPHAN_OUT" | grep -q "orphaned scaffold"; then
  echo "  PASS: error message mentions 'orphaned scaffold'"
  PASS=$((PASS + 1))
else
  echo "  FAIL: error message did not mention 'orphaned scaffold' — got: $ORPHAN_OUT"
  FAIL=$((FAIL + 1))
fi
if [ ! -d "$ORPHAN_VAULT/raw" ] && [ ! -d "$ORPHAN_VAULT/wiki/sources" ]; then
  echo "  PASS: no scaffold directories were created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: scaffold directories were created despite abort"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
