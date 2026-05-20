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

# Test 4: clean fixture → frontmatter exits 0 with empty errors.
echo ""
echo "Test 4: frontmatter on clean fixture"
V=$(prepare_vault clean)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "clean exit code 0" "0" "$RC"
assert_eq "clean errors length 0" "0" "$(echo "$OUT" | jq_get errors.length)"

# Test 5: missing required key → exit 2, errors[].key === 'sources'.
echo ""
echo "Test 5: frontmatter missing required key"
V=$(prepare_vault frontmatter-missing-key)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "missing-key exit code 2" "2" "$RC"
assert_eq "errors[0].key is sources" "sources" "$(echo "$OUT" | jq_get errors.0.key)"

# Test 6: bad-date → exit 2, errors[].key === 'updated', errors[].problem mentions date.
echo ""
echo "Test 6: frontmatter bad date"
V=$(prepare_vault frontmatter-bad-date)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "bad-date exit code 2" "2" "$RC"
assert_eq "errors[0].key is updated" "updated" "$(echo "$OUT" | jq_get errors.0.key)"

# Test 6b: overflow date → exit 2, errors[0].key === 'updated'.
echo ""
echo "Test 6b: frontmatter overflow date (regression for js-yaml Date rollover)"
V=$(prepare_vault frontmatter-overflow-date)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "overflow-date exit code 2" "2" "$RC"
assert_eq "overflow errors[0].key is updated" "updated" "$(echo "$OUT" | jq_get errors.0.key)"

# Test 7: human-readable summary on stderr when --json absent.
echo ""
echo "Test 7: frontmatter human summary on stderr"
V=$(prepare_vault frontmatter-missing-key)
set +e
ERR=$( (cd "$V" && node "$SCRIPT" frontmatter) 2>&1 1>/dev/null )
RC=$?
set -e
assert_eq "no-json exit code 2" "2" "$RC"
echo "$ERR" | grep -q "missing required key 'sources'" \
  && echo "  PASS: stderr names missing key" && PASS=$((PASS + 1)) \
  || (echo "  FAIL: stderr did not name missing key"; echo "    actual: $ERR"; FAIL=$((FAIL + 1)))

# Test 8: clean fixture → wikilinks exits 0.
echo ""
echo "Test 8: wikilinks on clean fixture"
V=$(prepare_vault clean)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
assert_eq "clean wikilinks exit 0" "0" "$RC"
assert_eq "clean broken length 0" "0" "$(echo "$OUT" | jq_get broken.length)"
assert_eq "clean orphans length 0" "0" "$(echo "$OUT" | jq_get orphans.length)"

# Test 9: broken link → exit 1, broken[].target names the unresolved link.
echo ""
echo "Test 9: wikilinks broken link"
V=$(prepare_vault wikilink-broken)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
assert_eq "broken exit 1" "1" "$RC"
assert_eq "broken[0].target is Nonexistent Concept" "Nonexistent Concept" "$(echo "$OUT" | jq_get broken.0.target)"
assert_eq "broken[0].from is example source" "wiki/sources/example-source.md" "$(echo "$OUT" | jq_get broken.0.from)"

# Test 10: orphan page → exit 1, orphans[].path names the lonely page, broken empty.
echo ""
echo "Test 10: wikilinks orphan page"
V=$(prepare_vault wikilink-orphan)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
assert_eq "orphan exit 1" "1" "$RC"
assert_eq "orphan broken length 0" "0" "$(echo "$OUT" | jq_get broken.length)"
assert_eq "orphan orphans[0].path is lonely" "wiki/sources/lonely.md" "$(echo "$OUT" | jq_get orphans.0.path)"

# Test 11: bare-name wikilink resolves case-insensitively.
echo ""
echo "Test 11: bare-name resolution is case-insensitive"
V=$(prepare_vault clean)
# Add a concept page and link to it from a new source with mixed case.
mkdir -p "$V/wiki/concepts"
cat > "$V/wiki/concepts/widget.md" <<'EOF'
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Widget
EOF
cat > "$V/wiki/sources/has-link.md" <<'EOF'
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Has Link

See [[WIDGET]] for details.
EOF
(cd "$V" && git add . && git commit -qm "add widget+link" >/dev/null)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
# Widget is no longer orphan because has-link.md → WIDGET resolves to widget.md.
# example-source.md may or may not be orphan depending on index.md. We assert
# the broken list is empty and `wiki/concepts/widget.md` is not in orphans.
assert_eq "case-insensitive broken length 0" "0" "$(echo "$OUT" | jq_get broken.length)"
echo "$OUT" | grep -q '"wiki/concepts/widget.md"' \
  && (echo "  FAIL: widget should not be orphan after WIDGET link"; FAIL=$((FAIL + 1))) \
  || (echo "  PASS: widget resolved via case-insensitive bare-name match"; PASS=$((PASS + 1)))

# Test 11b: a page that only links to itself is still orphan.
echo ""
echo "Test 11b: self-link does not rescue orphan"
V=$(prepare_vault clean)
mkdir -p "$V/wiki/concepts"
cat > "$V/wiki/concepts/self-loop.md" <<'EOF'
---
tags: [example]
sources: [raw/example.md]
created: 2026-05-20
updated: 2026-05-20
---

# Self Loop

See [[Self Loop]] for itself.
EOF
(cd "$V" && git add . && git commit -qm "add self-loop" >/dev/null)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" wikilinks --json) )
RC=$?
set -e
echo "$OUT" | grep -q '"wiki/concepts/self-loop.md"' \
  && echo "  PASS: self-link page is still orphan" && PASS=$((PASS + 1)) \
  || (echo "  FAIL: self-link page should be orphan"; echo "    actual: $OUT"; FAIL=$((FAIL + 1)))

# Test 12: clean fixture → index exits 0.
echo ""
echo "Test 12: index on clean fixture"
V=$(prepare_vault clean)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" index --json) )
RC=$?
set -e
assert_eq "clean index exit 0" "0" "$RC"
assert_eq "clean missing_rows length 0" "0" "$(echo "$OUT" | jq_get missing_rows.length)"
assert_eq "clean dead_rows length 0" "0" "$(echo "$OUT" | jq_get dead_rows.length)"

# Test 13: missing row → exit 1, missing_rows[] includes the orphaned file path.
echo ""
echo "Test 13: index missing row"
V=$(prepare_vault index-missing-row)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" index --json) )
RC=$?
set -e
assert_eq "missing-row exit 1" "1" "$RC"
assert_eq "missing_rows[0] is widget" "wiki/concepts/widget.md" "$(echo "$OUT" | jq_get missing_rows.0)"
assert_eq "missing-row dead_rows length 0" "0" "$(echo "$OUT" | jq_get dead_rows.length)"

# Test 14: dead row → exit 2, dead_rows[].target names the unresolved target.
echo ""
echo "Test 14: index dead row"
V=$(prepare_vault index-dead-row)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" index --json) )
RC=$?
set -e
assert_eq "dead-row exit 2" "2" "$RC"
assert_eq "dead_rows[0].target names deleted-page" "wiki/sources/deleted-page" "$(echo "$OUT" | jq_get dead_rows.0.target)"

# Test 15: all on clean fixture → exit 0, aggregated JSON has all three keys.
echo ""
echo "Test 15: all on clean fixture"
V=$(prepare_vault clean)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" all --json) )
RC=$?
set -e
assert_eq "all clean exit 0" "0" "$RC"
assert_eq "all clean frontmatter.errors length 0" "0" "$(echo "$OUT" | jq_get frontmatter.errors.length)"
assert_eq "all clean wikilinks.broken length 0" "0" "$(echo "$OUT" | jq_get wikilinks.broken.length)"
assert_eq "all clean index.missing_rows length 0" "0" "$(echo "$OUT" | jq_get index.missing_rows.length)"

# Test 16: all returns max of child exit codes (frontmatter=2 wins).
echo ""
echo "Test 16: all aggregates worst exit code"
V=$(prepare_vault frontmatter-missing-key)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" all --json) )
RC=$?
set -e
assert_eq "all worst-code exit 2" "2" "$RC"
assert_eq "all frontmatter errors > 0" "1" "$(echo "$OUT" | jq_get frontmatter.errors.length)"

# Test: frontmatter accepts a valid relations: map (CR-005)
echo ""
echo "Test: relations-valid fixture passes frontmatter check"
V=$(prepare_vault relations-valid)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "relations-valid frontmatter exit code"  "0" "$RC"
ERR_COUNT=$(echo "$OUT" | jq_get "errors.length")
assert_eq "relations-valid: 0 errors"              "0" "$ERR_COUNT"

# Test: frontmatter rejects a malformed relations: map (CR-005)
echo ""
echo "Test: relations-bad-shape fixture fails frontmatter check"
V=$(prepare_vault relations-bad-shape)
set +e
OUT=$( (cd "$V" && node "$SCRIPT" frontmatter --json) )
RC=$?
set -e
assert_eq "relations-bad-shape frontmatter exit code"  "2" "$RC"
ERR_COUNT=$(echo "$OUT" | jq_get "errors.length")
assert_eq "relations-bad-shape: 1 error"               "1" "$ERR_COUNT"
ERR_KEY=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).errors[0].key))")
assert_eq "relations-bad-shape: error key is 'relations'"  "relations" "$ERR_KEY"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
