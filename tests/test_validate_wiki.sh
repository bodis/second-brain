#!/bin/bash
set -e

# Test: scripts/validate-wiki.js — wiki structural validator.
# Usage: bash tests/test_validate_wiki.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/validate-wiki.js"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/validate-wiki"
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

# Copy a fixture into the tmp dir and git-init it as a real vault.
# Args: $1 = fixture name (under tests/fixtures/validate-wiki/)
# Echoes the absolute path of the materialized vault.
prepare_vault() {
  local fixture="$1"
  local dest="$TEST_DIR/$fixture-$RANDOM"
  cp -R "$FIXTURE_DIR/$fixture" "$dest"
  if [ -d "$dest/wiki/.state" ]; then
    (cd "$dest" \
      && git init -q \
      && git config user.email "t@t" \
      && git config user.name "t" \
      && git config commit.gpgsign false \
      && git add . \
      && git commit -qm "init" >/dev/null)
  fi
  echo "$dest"
}

# Read JSON from stdin and print the value at a dotted path (e.g. "frontmatter.errors.length").
# Uses node -e to keep parity with the test_state_sources.sh pattern.
jq_get() {
  local path="$1"
  node -e "
    let d='';
    process.stdin.on('data', c => d += c);
    process.stdin.on('end', () => {
      let v = JSON.parse(d);
      for (const p of '$path'.split('.')) {
        if (p === 'length') v = v.length;
        else v = v[p];
      }
      process.stdout.write(String(v));
    });
  "
}

echo "=== Test: validate-wiki.js ==="

# Test 1: not-a-vault → all subcommands exit 0 silently.
echo ""
echo "Test 1: not-a-vault self-gates"
V=$(prepare_vault not-a-vault)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" all) 2>&1 )
RC=$?
set -e
assert_eq "not-a-vault exit code 0" "0" "$RC"
assert_eq "not-a-vault produces no output" "" "$OUT"

# Test 2: stop_hook_active in stdin makes `all` exit 0 silently.
echo ""
echo "Test 2: stop_hook_active guard"
V=$(prepare_vault clean)
set +e
OUT=$(echo '{"stop_hook_active": true}' | (cd "$V" && node "$SCRIPT" all) 2>&1)
RC=$?
set -e
assert_eq "stop_hook_active exit code 0" "0" "$RC"
assert_eq "stop_hook_active produces no output" "" "$OUT"

# Test 3: unknown subcommand exits nonzero with a helpful error.
echo ""
echo "Test 3: unknown subcommand"
V=$(prepare_vault clean)
set +e
ERR=$( (cd "$V" && node "$SCRIPT" bogus) 2>&1 1>/dev/null )
RC=$?
set -e
[ "$RC" -ne 0 ] && echo "  PASS: unknown subcommand exits nonzero ($RC)" && PASS=$((PASS + 1)) \
                || (echo "  FAIL: unknown subcommand exit code"; echo "    actual: $RC"; FAIL=$((FAIL + 1)))
echo "$ERR" | grep -q "unknown subcommand" \
  && echo "  PASS: unknown subcommand stderr names the problem" && PASS=$((PASS + 1)) \
  || (echo "  FAIL: unknown subcommand stderr"; echo "    actual: $ERR"; FAIL=$((FAIL + 1)))

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
