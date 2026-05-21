#!/bin/bash
set -e

# Test: scripts/status.js — status dashboard reporter.
# Usage: bash tests/test_status.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/status.js"
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

# Read JSON from stdin and print the value at a dotted path.
json_path() {
  node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{let o=JSON.parse(d); for (const k of '$1'.split('.')) o = o?.[k]; process.stdout.write(String(o))})"
}

# Create a fresh vault: temp dir, git init, scaffolded .state/sources.yaml.
# Args: $1 = name. Echoes the absolute path.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state"
  cat > "$v/wiki/.state/sources.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
  cat > "$v/wiki/.state/frontmatter-contract.yaml" <<'YAML'
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
  tags: { type: list[string], may_be_empty: true }
  sources: { type: list[string], may_be_empty: false }
  created: { type: date, format: YYYY-MM-DD }
  updated: { type: date, format: YYYY-MM-DD }
unknown_keys: allowed
YAML
  (cd "$v" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
  echo "$v"
}

echo "=== Test: status.js ==="

# Test 10: outside any vault → exit 2 with helpful message.
echo ""
echo "Test 10: outside any vault → exit 2"
OUTSIDE_DIR="$TEST_DIR/not-a-vault"
mkdir -p "$OUTSIDE_DIR"
set +e
OUT=$( (cd "$OUTSIDE_DIR" && node "$SCRIPT" 2>&1) )
EXIT=$?
set -e
assert_eq "exit code 2"                    "2" "$EXIT"
case "$OUT" in
  *"not in a second-brain vault"*)
    echo "  PASS: stderr names the problem"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not say 'not in a second-brain vault' — got: $OUT"
    FAIL=$((FAIL + 1));;
esac

# Test 1: fresh vault → --json returns stable schema with all-zero sections.
echo ""
echo "Test 1: fresh vault → stable JSON schema"
V1=$(make_vault vault1)
OUT=$( (cd "$V1" && node "$SCRIPT" --json) )
assert_eq "sources.new === 0"                  "0"     "$(echo "$OUT" | json_path 'sources.new')"
assert_eq "sources.changed === 0"              "0"     "$(echo "$OUT" | json_path 'sources.changed')"
assert_eq "sources.deleted === 0"              "0"     "$(echo "$OUT" | json_path 'sources.deleted')"
assert_eq "lint.errors === 0"                  "0"     "$(echo "$OUT" | json_path 'lint.errors')"
assert_eq "lint.warnings === 0"                "0"     "$(echo "$OUT" | json_path 'lint.warnings')"
assert_eq "contradictions.unresolved === 0"    "0"     "$(echo "$OUT" | json_path 'contradictions.unresolved')"
assert_eq "contradictions.present === false"   "false" "$(echo "$OUT" | json_path 'contradictions.present')"
assert_eq "staleness.unresolved_high === 0"    "0"     "$(echo "$OUT" | json_path 'staleness.unresolved_high')"
assert_eq "staleness.unresolved_medium === 0"  "0"     "$(echo "$OUT" | json_path 'staleness.unresolved_medium')"
assert_eq "staleness.present === false"        "false" "$(echo "$OUT" | json_path 'staleness.present')"
assert_eq "since_review.change_count === 0"    "0"     "$(echo "$OUT" | json_path 'since_review.change_count')"
assert_eq "since_review.last_accepted_at null" "null"  "$(echo "$OUT" | json_path 'since_review.last_accepted_at')"
assert_eq "vault.name is vault1"               "vault1" "$(echo "$OUT" | json_path 'vault.name')"

# Test 2: three new files in raw/ → sources.new === 3.
echo ""
echo "Test 2: sources counted from state-sources.js diff"
V2=$(make_vault vault2)
echo "one"   > "$V2/raw/one.md"
echo "two"   > "$V2/raw/two.md"
echo "three" > "$V2/raw/three.md"
OUT=$( (cd "$V2" && node "$SCRIPT" --json) )
assert_eq "sources.new === 3"     "3" "$(echo "$OUT" | json_path 'sources.new')"
assert_eq "sources.changed === 0" "0" "$(echo "$OUT" | json_path 'sources.changed')"
assert_eq "sources.deleted === 0" "0" "$(echo "$OUT" | json_path 'sources.deleted')"

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
