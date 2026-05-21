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

# Test 3: vault with a broken wikilink → lint.errors >= 1.
echo ""
echo "Test 3: lint counts derived from validate-wiki.js all --json"
V3=$(make_vault vault3)
mkdir -p "$V3/wiki/sources"
cat > "$V3/wiki/sources/seed.md" <<'EOF'
---
tags: []
sources: [seed.md]
created: 2026-01-01
updated: 2026-01-01
---

# Seed

Points to [[does-not-exist]].
EOF
(cd "$V3" && git add . && git commit -qm "add seed" >/dev/null)
OUT=$( (cd "$V3" && node "$SCRIPT" --json) )
ERRS=$(echo "$OUT" | json_path 'lint.errors')
if [ "$ERRS" -ge 1 ]; then
  echo "  PASS: lint.errors >= 1 (got $ERRS)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: lint.errors expected >= 1, got $ERRS"
  FAIL=$((FAIL + 1))
fi

# Test 4: contradictions.yaml with 3 unresolved entries.
echo ""
echo "Test 4: contradictions counts from state file"
V4="$TEST_DIR/contradictions-populated"
cp -R "$REPO_ROOT/tests/fixtures/status/contradictions-populated" "$V4"
(cd "$V4" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
OUT=$( (cd "$V4" && node "$SCRIPT" --json) )
assert_eq "contradictions.unresolved === 3"   "3"    "$(echo "$OUT" | json_path 'contradictions.unresolved')"
assert_eq "contradictions.present === true"   "true" "$(echo "$OUT" | json_path 'contradictions.present')"
assert_eq "contradictions.unjudged_candidates === 0" "0" "$(echo "$OUT" | json_path 'contradictions.unjudged_candidates')"

# Test 5: staleness.yaml with 3 high-unreviewed + 2 medium-unreviewed.
echo ""
echo "Test 5: staleness counts from state file"
V5="$TEST_DIR/staleness-populated"
cp -R "$REPO_ROOT/tests/fixtures/status/staleness-populated" "$V5"
(cd "$V5" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
OUT=$( (cd "$V5" && node "$SCRIPT" --json) )
assert_eq "staleness.unresolved_high === 3"     "3"    "$(echo "$OUT" | json_path 'staleness.unresolved_high')"
assert_eq "staleness.unresolved_medium === 2"   "2"    "$(echo "$OUT" | json_path 'staleness.unresolved_medium')"
assert_eq "staleness.present === true"          "true" "$(echo "$OUT" | json_path 'staleness.present')"

# Test 8: since-review.yaml with 5 changes → change_count === 5.
echo ""
echo "Test 8: since_review counts from state file"
V8=$(make_vault vault8)
cat > "$V8/wiki/.state/since-review.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/review-log.js
last_accepted_at: 2026-05-12T08:00:00Z
changes:
  - { at: 2026-05-13T03:00:00Z, kind: ingest, source: raw/a.md }
  - { at: 2026-05-13T03:01:00Z, kind: ingest, source: raw/b.md }
  - { at: 2026-05-14T03:00:00Z, kind: ingest, source: raw/c.md }
  - { at: 2026-05-15T03:00:00Z, kind: ingest, source: raw/d.md }
  - { at: 2026-05-15T03:01:00Z, kind: ingest, source: raw/e.md }
YAML
(cd "$V8" && git add . && git commit -qm "add since-review" >/dev/null)
OUT=$( (cd "$V8" && node "$SCRIPT" --json) )
assert_eq "since_review.change_count === 5"          "5"                    "$(echo "$OUT" | json_path 'since_review.change_count')"
assert_eq "since_review.last_accepted_at present"    "2026-05-12T08:00:00Z" "$(echo "$OUT" | json_path 'since_review.last_accepted_at')"

# Test 1b: fresh vault → human mode prints "Nothing pending." after header.
echo ""
echo "Test 1b: fresh vault human output"
V1b=$(make_vault vault1b)
OUT=$( (cd "$V1b" && node "$SCRIPT") )
case "$OUT" in
  *"Second Brain — vault: vault1b"*"Nothing pending."*)
    echo "  PASS: fresh-vault output prints header + Nothing pending."; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: fresh-vault output missing header or Nothing pending. — got:"; echo "$OUT"
    FAIL=$((FAIL + 1));;
esac

# Test 2b: populated vault → human output includes sources line + lint line.
echo ""
echo "Test 2b: populated vault human output"
V2b=$(make_vault vault2b)
echo "one"   > "$V2b/raw/one.md"
echo "two"   > "$V2b/raw/two.md"
OUT=$( (cd "$V2b" && node "$SCRIPT") )
case "$OUT" in
  *"Automation could pick up"*"Sources"*"2 new"*)
    echo "  PASS: human output shows 'Automation could pick up' + sources line"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: human output missing automation/sources line — got:"; echo "$OUT"
    FAIL=$((FAIL + 1));;
esac
case "$OUT" in
  *"Nothing pending."*)
    echo "  FAIL: 'Nothing pending.' present despite pending sources"; FAIL=$((FAIL + 1));;
  *)
    echo "  PASS: 'Nothing pending.' is correctly absent"; PASS=$((PASS + 1));;
esac

# Test 9: human mode omits zero-count sections.
echo ""
echo "Test 9: zero sections omitted from human output"
case "$OUT" in
  *"Needs you:"*)
    echo "  FAIL: 'Needs you:' header present despite zero contradictions/staleness"
    FAIL=$((FAIL + 1));;
  *)
    echo "  PASS: 'Needs you:' header omitted on populated-sources-only vault"
    PASS=$((PASS + 1));;
esac
case "$OUT" in
  *"Awaiting review:"*)
    echo "  FAIL: 'Awaiting review:' header present despite zero changes"
    FAIL=$((FAIL + 1));;
  *)
    echo "  PASS: 'Awaiting review:' header omitted"
    PASS=$((PASS + 1));;
esac

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
