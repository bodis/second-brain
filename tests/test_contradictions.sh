#!/bin/bash
set -e

# Test: scripts/contradictions.js — contradictions state-owner.
# Usage: bash tests/test_contradictions.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/contradictions.js"
VALIDATE="$REPO_ROOT/scripts/validate-wiki.js"
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

# Make a minimal vault: git-init, sources.yaml, frontmatter-contract.yaml.
# Args: $1 = name. Echoes the absolute path.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state" "$v/wiki/entities" "$v/wiki/concepts"
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
  cat > "$v/wiki/index.md" <<'MD'
# Index
MD
  cat > "$v/wiki/log.md" <<'MD'
# Log
MD
  (cd "$v" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
  echo "$v"
}

echo "=== Test: contradictions.js ==="

# Test: outside any vault → exit 2 with helpful message.
echo ""
echo "Test: outside any vault → exit 2"
OUTSIDE_DIR="$TEST_DIR/not-a-vault"
mkdir -p "$OUTSIDE_DIR"
set +e
OUT=$( (cd "$OUTSIDE_DIR" && node "$SCRIPT" list 2>&1) )
EXIT=$?
set -e
assert_eq "exit code 2" "2" "$EXIT"
case "$OUT" in
  *"not in a second-brain vault"*)
    echo "  PASS: stderr names the problem"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not say 'not in a second-brain vault' — got: $OUT"
    FAIL=$((FAIL + 1));;
esac

# Test: unknown subcommand → exit 2.
echo ""
echo "Test: unknown subcommand → exit 2"
V0=$(make_vault vault0)
set +e
OUT=$( (cd "$V0" && node "$SCRIPT" nonsense 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on unknown subcommand" "2" "$EXIT"
case "$OUT" in
  *"unknown subcommand: nonsense"*)
    echo "  PASS: stderr names the subcommand"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not say 'unknown subcommand: nonsense' — got: $OUT"
    FAIL=$((FAIL + 1));;
esac

# Test: list on missing file → empty output, exit 0.
echo ""
echo "Test: list on missing file → empty output"
V_LIST_EMPTY=$(make_vault vault-list-empty)
set +e
OUT=$( (cd "$V_LIST_EMPTY" && node "$SCRIPT" list 2>&1) )
EXIT=$?
set -e
assert_eq "exit 0 when state file absent" "0" "$EXIT"

# Test: list --json on missing file → empty contradictions array, exit 0.
echo ""
echo "Test: list --json on missing file → empty array"
OUT=$( (cd "$V_LIST_EMPTY" && node "$SCRIPT" list --json 2>&1) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "list --json returns empty array" "0" "$COUNT"

# Test: list --json on populated file → returns entries.
echo ""
echo "Test: list --json on populated file"
V_LIST=$(make_vault vault-list)
cat > "$V_LIST/wiki/.state/contradictions.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  - id: 2026-05-19-001
    detected_at: 2026-05-19T10:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [foo], a_only_targets: [], b_only_targets: [bar] }
    status: unjudged
  - id: 2026-05-18-007
    detected_at: 2026-05-18T03:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [foo], a_only_targets: [], b_only_targets: [bar] }
    status: unresolved
    judgment:
      verdict: real-contradiction
      at: 2026-05-18T04:00:00Z
      claim: "Acquirer of Foo"
      assertions: []
      rationale: "..."
YAML
OUT=$( (cd "$V_LIST" && node "$SCRIPT" list --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "list --json on populated returns 2 entries" "2" "$COUNT"

# Test: list --status=unjudged → filters to single entry.
echo ""
echo "Test: list --status filter"
OUT=$( (cd "$V_LIST" && node "$SCRIPT" list --status=unjudged --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "list --status=unjudged returns 1 entry" "1" "$COUNT"

# Test: list --status with comma-list → union filter.
OUT=$( (cd "$V_LIST" && node "$SCRIPT" list --status=unjudged,unresolved --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "list --status comma-list returns 2 entries" "2" "$COUNT"

# Test: Signal 1 conflicting-relations on a fixture vault.
echo ""
echo "Test: Signal 1 conflicting-relations"
V_S1=$(make_vault vault-signal-1)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$V_S1/wiki/concepts/"
(cd "$V_S1" && git add . && git commit -qm "fixture content")
(cd "$V_S1" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
OUT=$( (cd "$V_S1" && node "$SCRIPT" list --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "Signal 1 enqueues one candidate" "1" "$COUNT"
SIGNAL=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].signal)})")
assert_eq "signal === conflicting-relations" "conflicting-relations" "$SIGNAL"
RELATION=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].signal_data.relation)})")
assert_eq "signal_data.relation === refines" "refines" "$RELATION"
SHARED=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].signal_data.shared_targets.join(','))})")
assert_eq "shared_targets includes ethics" "wiki/concepts/ethics.md" "$SHARED"
STATUS=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].status)})")
assert_eq "status === unjudged" "unjudged" "$STATUS"

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
