#!/bin/bash
set -e

# Test: register-plugin.js merges plugin registration into settings.json correctly.
# Usage: bash tests/test_register_plugin.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$REPO_ROOT/skills/onboard/scripts/register-plugin.js"
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

json_get() {
  # $1 = file, $2 = python expression on `d`
  python3 -c "import json,sys; d=json.load(open('$1')); print($2)"
}

echo "=== Test: register-plugin.js ==="

# Test 1: Fresh write — target file and parent dir don't exist yet.
echo ""
echo "Test 1: Fresh write into nonexistent target"
VAULT1="$TEST_DIR/vault1"
mkdir -p "$VAULT1"
node "$REGISTER" --scope project --vault "$VAULT1"
assert_eq "settings.json exists"            "yes" "$([ -f "$VAULT1/.claude/settings.json" ] && echo yes || echo no)"
assert_eq "enabledPlugins flag is true"     "True" "$(json_get "$VAULT1/.claude/settings.json" "d['enabledPlugins']['second-brain@second-brain']")"
assert_eq "source type is directory"        "directory" "$(json_get "$VAULT1/.claude/settings.json" "d['extraKnownMarketplaces']['second-brain']['source']['source']")"
assert_eq "path is absolute"                "True" "$(json_get "$VAULT1/.claude/settings.json" "str(d['extraKnownMarketplaces']['second-brain']['source']['path'].startswith('/'))")"

# Test 2: Merge — preserves unrelated keys.
echo ""
echo "Test 2: Merge preserves unrelated keys"
VAULT2="$TEST_DIR/vault2"
mkdir -p "$VAULT2/.claude"
cat > "$VAULT2/.claude/settings.json" <<EOF
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "enabledPlugins": { "other-plugin@other-mkt": true }
}
EOF
node "$REGISTER" --scope project --vault "$VAULT2"
assert_eq "unrelated permissions preserved"   "True" "$(json_get "$VAULT2/.claude/settings.json" "d['permissions']['allow'] == ['Bash(ls:*)']")"
assert_eq "other-plugin still enabled"        "True" "$(json_get "$VAULT2/.claude/settings.json" "d['enabledPlugins']['other-plugin@other-mkt']")"
assert_eq "second-brain plugin added"         "True" "$(json_get "$VAULT2/.claude/settings.json" "d['enabledPlugins']['second-brain@second-brain']")"

# Test 3: Idempotent — running twice produces identical content.
echo ""
echo "Test 3: Idempotency"
VAULT3="$TEST_DIR/vault3"
mkdir -p "$VAULT3"
node "$REGISTER" --scope project --vault "$VAULT3"
HASH1=$(shasum "$VAULT3/.claude/settings.json" | cut -d' ' -f1)
node "$REGISTER" --scope project --vault "$VAULT3"
HASH2=$(shasum "$VAULT3/.claude/settings.json" | cut -d' ' -f1)
assert_eq "two runs produce same file"       "$HASH1" "$HASH2"

# Test 4: Malformed JSON — exits non-zero and does NOT overwrite the file.
echo ""
echo "Test 4: Malformed JSON aborts cleanly"
VAULT4="$TEST_DIR/vault4"
mkdir -p "$VAULT4/.claude"
echo "{ this is not json" > "$VAULT4/.claude/settings.json"
ORIG_CONTENT=$(cat "$VAULT4/.claude/settings.json")
set +e
node "$REGISTER" --scope project --vault "$VAULT4" 2>/dev/null
EXITCODE=$?
set -e
NEW_CONTENT=$(cat "$VAULT4/.claude/settings.json")
assert_eq "script exited non-zero"           "True" "$([ "$EXITCODE" -ne 0 ] && echo True || echo False)"
assert_eq "file content untouched"           "$ORIG_CONTENT" "$NEW_CONTENT"

# Test 5: User scope — writes to ~/.claude/settings.json via overridden HOME.
echo ""
echo "Test 5: User-scope writes under \$HOME/.claude/settings.json"
FAKE_HOME="$TEST_DIR/fakehome"
mkdir -p "$FAKE_HOME"
HOME="$FAKE_HOME" node "$REGISTER" --scope user
assert_eq "user settings.json exists"        "yes" "$([ -f "$FAKE_HOME/.claude/settings.json" ] && echo yes || echo no)"
assert_eq "user-scope enabledPlugins set"    "True" "$(json_get "$FAKE_HOME/.claude/settings.json" "d['enabledPlugins']['second-brain@second-brain']")"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
