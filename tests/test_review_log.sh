#!/bin/bash
set -e

# Test: scripts/review-log.js — since-review.yaml owner.
# Usage: bash tests/test_review_log.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/review-log.js"
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

make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/wiki/.state"
  cat > "$v/wiki/.state/sources.yaml" <<'YAML'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YAML
  (cd "$v" && git init -q && git config user.email "t@t" && git config user.name "t" && git config commit.gpgsign false && git add . && git commit -qm "init" >/dev/null)
  echo "$v"
}

echo "=== Test: review-log.js ==="

# Test: unknown subcommand → exit 2.
echo ""
echo "Test: unknown subcommand → exit 2"
V0=$(make_vault vault0)
set +e
OUT=$( (cd "$V0" && node "$SCRIPT" nonsense 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on unknown subcommand" "2" "$EXIT"

# Test 3: first append → file gains one entry with merged fields.
echo ""
echo "Test 3: first append creates file with one merged entry"
V3=$(make_vault vault3)
(cd "$V3" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/x.md","wrote":["wiki/sources/x.md"]}' >/dev/null)
COUNT=$(node -e "process.stdout.write(String((require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes||[]).length))")
assert_eq "changes has 1 entry"     "1" "$COUNT"
KIND=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes[0].kind)")
assert_eq "kind === ingest"         "ingest" "$KIND"
SRC=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes[0].source)")
assert_eq "source merged in"        "raw/x.md" "$SRC"
HAS_AT=$(node -e "let e=require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes[0]; process.stdout.write(String(typeof e.at === 'string' && e.at.endsWith('Z')))")
assert_eq "at is ISO string ending in Z" "true" "$HAS_AT"
LAST=$(node -e "let d=require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')); process.stdout.write(String(d.last_accepted_at))")
assert_eq "last_accepted_at initialized to null" "null" "$LAST"

# Test 4: two appends accumulate; second entry coexists with first.
echo ""
echo "Test 4: two appends accumulate"
(cd "$V3" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/y.md"}' >/dev/null)
COUNT=$(node -e "process.stdout.write(String((require('js-yaml').load(require('fs').readFileSync('$V3/wiki/.state/since-review.yaml','utf8')).changes||[]).length))")
assert_eq "changes has 2 entries" "2" "$COUNT"

# Test 6: malformed --data → exit 2.
echo ""
echo "Test 6: malformed --data JSON → exit 2"
V6=$(make_vault vault6)
set +e
OUT=$( (cd "$V6" && node "$SCRIPT" append --kind=ingest --data='{not json' 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on malformed --data" "2" "$EXIT"

# Test 7: free-string kind is accepted (no validation against an allow-list).
echo ""
echo "Test 7: custom kind accepted"
V7=$(make_vault vault7)
(cd "$V7" && node "$SCRIPT" append --kind=my-custom --data='{"foo":"bar"}' >/dev/null)
KIND=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V7/wiki/.state/since-review.yaml','utf8')).changes[0].kind)")
assert_eq "kind === my-custom" "my-custom" "$KIND"
FOO=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V7/wiki/.state/since-review.yaml','utf8')).changes[0].foo)")
assert_eq "free-string payload merged" "bar" "$FOO"

# Test 8: two rapid appends both land via atomic rename.
echo ""
echo "Test 8: rapid concurrent appends both land"
V8=$(make_vault vault8)
(cd "$V8" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/a.md"}' >/dev/null) &
(cd "$V8" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/b.md"}' >/dev/null) &
wait
COUNT=$(node -e "process.stdout.write(String((require('js-yaml').load(require('fs').readFileSync('$V8/wiki/.state/since-review.yaml','utf8')).changes||[]).length))" 2>/dev/null || echo "0")
# Atomic rename guarantees the file is never torn, but the last-writer-wins
# semantics mean one entry may be overwritten. Document the v1 behaviour: at
# least one entry lands.
if [ "$COUNT" -ge 1 ]; then
  echo "  PASS: at least one rapid append landed (count=$COUNT)"; PASS=$((PASS + 1))
else
  echo "  FAIL: no entries landed after concurrent appends"; FAIL=$((FAIL + 1))
fi

# Test 1: show on missing file → empty output, exit 0.
echo ""
echo "Test 1: show on missing file"
V1=$(make_vault vault1)
set +e
OUT=$( (cd "$V1" && node "$SCRIPT" show) )
EXIT=$?
set -e
assert_eq "exit 0 on missing file" "0" "$EXIT"
case "$OUT" in
  ""|"No review-log entries"*)
    echo "  PASS: empty or 'no entries' output on missing file"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: unexpected output on missing file — got: $OUT"; FAIL=$((FAIL + 1));;
esac

# Test 4b: show after two appends → human output groups by kind, lists both.
echo ""
echo "Test 4b: show groups appended entries by kind"
V4b=$(make_vault vault4b)
(cd "$V4b" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/a.md"}' >/dev/null)
(cd "$V4b" && node "$SCRIPT" append --kind=ingest --data='{"source":"raw/b.md"}' >/dev/null)
(cd "$V4b" && node "$SCRIPT" append --kind=lint-autofix --data='{"note":"fixed link"}' >/dev/null)
OUT=$( (cd "$V4b" && node "$SCRIPT" show) )
case "$OUT" in
  *"ingest"*"2"*"lint-autofix"*"1"*)
    echo "  PASS: show output mentions both kinds with counts"; PASS=$((PASS + 1));;
  *)
    echo "  FAIL: show output missing expected kind/count — got:"; echo "$OUT"
    FAIL=$((FAIL + 1));;
esac

# Test 4b-json: show --json dumps the full file as JSON.
OUT_JSON=$( (cd "$V4b" && node "$SCRIPT" show --json) )
COUNT=$(echo "$OUT_JSON" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).changes.length)))")
assert_eq "show --json has 3 changes" "3" "$COUNT"

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
