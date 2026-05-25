#!/bin/bash
set -e

# Test: scripts/staleness.js — staleness state-owner.
# Usage: bash tests/test_staleness.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/staleness.js"
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

# Make a minimal vault: git-init, sources.yaml, frontmatter-contract.yaml,
# index.md, log.md. Args: $1 = name. Echoes the absolute path.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state" "$v/wiki/entities" "$v/wiki/concepts" "$v/wiki/synthesis" "$v/wiki/sources"
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
unknown_keys: allowed
YAML
  cat > "$v/wiki/index.md" <<'MD'
# Index
MD
  cat > "$v/wiki/log.md" <<'MD'
# Log
MD
  ( cd "$v" && git init -q && git add -A && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm init )
  echo "$v"
}

echo "=== Test: staleness.js ==="

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
OUT=$( (cd "$V0" && node "$SCRIPT" totally-fake 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on unknown subcommand" "2" "$EXIT"
case "$OUT" in
  *"unknown subcommand: totally-fake"*)
    echo "  PASS: stderr names the subcommand"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not say 'unknown subcommand' — got: $OUT"
    FAIL=$((FAIL + 1));;
esac

echo "==> Schema mismatch on read → exit 2"
V=$(make_vault schema-mismatch-vault)
cp "$REPO_ROOT/tests/fixtures/staleness/schema-mismatch/wiki/.state/staleness.yaml" "$V/wiki/.state/"
cd "$V"
set +e
output=$(node "$SCRIPT" list 2>&1)
rc=$?
set -e
assert_eq "exit code" "2" "$rc"
case "$output" in
  *"schema_version is 0"*) assert_eq "error mentions schema_version" "ok" "ok" ;;
  *) assert_eq "error mentions schema_version" "expected 'schema_version is 0'" "$output" ;;
esac

echo "==> list --status=unjudged returns only unjudged entries"
V=$(make_vault list-status)
cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    status: unjudged
  - id: 2026-05-25-002
    path: wiki/concepts/b.md
    signal: high
    status: unreviewed
  - id: 2026-05-25-003
    path: wiki/concepts/c.md
    signal: medium
    status: resolved
    resolution: refreshed
YAML
cd "$V"
output=$(node "$SCRIPT" list --status=unjudged --json)
count=$(echo "$output" | grep -c '"id":')
assert_eq "unjudged count" "1" "$count"
case "$output" in
  *2026-05-25-001*) assert_eq "id 001 present" "ok" "ok" ;;
  *) assert_eq "id 001 present" "expected 2026-05-25-001 in output" "$output" ;;
esac

echo "==> list --signal=high returns only high-tier entries"
V=$(make_vault list-signal)
cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    status: unreviewed
  - id: 2026-05-25-002
    path: wiki/concepts/b.md
    signal: medium
    status: unreviewed
  - id: 2026-05-25-003
    path: wiki/concepts/c.md
    signal: low
    status: unjudged
YAML
cd "$V"
output=$(node "$SCRIPT" list --signal=high --json)
count=$(echo "$output" | grep -c '"id":')
assert_eq "high count" "1" "$count"

echo "==> list default human output"
V=$(make_vault list-human)
cat > "$V/wiki/.state/staleness.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/staleness.js
pages:
  - id: 2026-05-25-001
    path: wiki/concepts/a.md
    signal: high
    status: unreviewed
YAML
cd "$V"
output=$(node "$SCRIPT" list)
case "$output" in
  *"2026-05-25-001"*"wiki/concepts/a.md"*"unreviewed"*"high"*) assert_eq "human format" "ok" "ok" ;;
  *) assert_eq "human format" "id path status signal on one line" "$output" ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
