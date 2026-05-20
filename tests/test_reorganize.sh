#!/bin/bash
set -e

# Test: skills/reorganize/scripts/reorganize.js
# Usage: bash tests/test_reorganize.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/reorganize/scripts/reorganize.js"
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

# Make a vault with minimum CR-002+CR-004 scaffolding so reorganize.js's
# findVaultRoot finds it: .git/, wiki/.state/sources.yaml, wiki/index.md,
# wiki/log.md, and the frontmatter contract.
make_vault() {
  local name="$1"
  local v="$TEST_DIR/$name"
  mkdir -p "$v/raw" "$v/wiki/.state" "$v/wiki/sources" "$v/wiki/concepts" "$v/wiki/synthesis"
  cat > "$v/wiki/.state/sources.yaml" <<'YEOF'
schema_version: 1
generated_by: scripts/state-sources.js
excludes: []
sources: []
YEOF
  cat > "$v/wiki/.state/frontmatter-contract.yaml" <<'YEOF'
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
optional:
  relations:
    type: map[string,list[string]]
unknown_keys: allowed
YEOF
  cat > "$v/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

## Synthesis
IEOF
  echo "# Log" > "$v/wiki/log.md"
  (cd "$v" \
    && git init -q \
    && git config user.email "t@t" \
    && git config user.name "t" \
    && git config commit.gpgsign false \
    && git add . \
    && git commit -qm "init")
  echo "$v"
}

commit_count() { (cd "$1" && git rev-list --count HEAD); }
last_msg()     { (cd "$1" && git log -1 --pretty=%s); }
head_sha()     { (cd "$1" && git rev-parse --short=7 HEAD); }

echo "=== Test: reorganize.js ==="

# Test 1: begin on clean tree → no new commit; reports current HEAD SHA.
echo ""
echo "Test 1: begin on clean tree"
V=$(make_vault clean)
BEFORE_SHA=$(head_sha "$V")
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" begin) )
AFTER_CT=$(commit_count "$V")
assert_eq "no new commit"           "$BEFORE_CT" "$AFTER_CT"
assert_eq "stdout reports SHA"      "$BEFORE_SHA" "$OUT"

# Test 2: begin on dirty wiki/ tree → one baseline commit; reports new HEAD SHA.
echo ""
echo "Test 2: begin on dirty wiki/ tree"
V=$(make_vault dirty)
echo "scratch" > "$V/wiki/concepts/scratch.md"
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" begin) )
AFTER_CT=$(commit_count "$V")
AFTER_SHA=$(head_sha "$V")
assert_eq "one new commit"               "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg is baseline"       "reorganize: pre-reorganize baseline" "$(last_msg "$V")"
assert_eq "stdout reports new HEAD SHA"  "$AFTER_SHA" "$OUT"

# Test 3: move-page renames the file, rewrites prose+relations links,
# updates the index row, bumps `updated:`, and makes one commit.
echo ""
echo "Test 3: move-page happy path"
V=$(make_vault move)
# Set up: two concept pages, one referencing the other in prose AND in relations.
cat > "$V/wiki/concepts/old.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---

# Old

Body.
MEOF
cat > "$V/wiki/concepts/holder.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
relations:
  see-also: [wiki/concepts/old]
---

# Holder

Mentions [[old]] and also [[wiki/concepts/old|the old one]].
MEOF
# Add a row for `old` and `holder` to the index.
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/old]] — original summary
- [[wiki/concepts/holder]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")

BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" move-page --from wiki/concepts/old.md --to wiki/concepts/new.md) )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"            "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names move"     "reorganize: move wiki/concepts/old.md → wiki/concepts/new.md" "$(last_msg "$V")"
# File renamed.
[ ! -f "$V/wiki/concepts/old.md" ] && echo "  PASS: old.md is gone" && PASS=$((PASS+1)) \
                                   || (echo "  FAIL: old.md still present"; FAIL=$((FAIL+1)))
[ -f "$V/wiki/concepts/new.md" ]   && echo "  PASS: new.md exists"  && PASS=$((PASS+1)) \
                                   || (echo "  FAIL: new.md missing"; FAIL=$((FAIL+1)))
# Prose wikilink rewritten in both bare and path form (and alias preserved).
HOLDER=$(cat "$V/wiki/concepts/holder.md")
echo "$HOLDER" | grep -q '\[\[new\]\]'                       && echo "  PASS: bare wikilink rewritten" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: bare wikilink not rewritten"; FAIL=$((FAIL+1)))
echo "$HOLDER" | grep -q '\[\[wiki/concepts/new|the old one\]\]' \
                                                              && echo "  PASS: alias path link rewritten" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: alias path link not rewritten"; FAIL=$((FAIL+1)))
# Frontmatter relations target rewritten.
echo "$HOLDER" | grep -q 'see-also:.*wiki/concepts/new'       && echo "  PASS: relations target rewritten" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: relations target not rewritten"; FAIL=$((FAIL+1)))
# Index row rewritten, summary preserved.
IDX=$(cat "$V/wiki/index.md")
echo "$IDX" | grep -q '\[\[wiki/concepts/new\]\] — original summary' \
                                                              && echo "  PASS: index row rewritten, summary kept" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: index row not rewritten"; FAIL=$((FAIL+1)))
# `updated:` bumped on the moved page.
TODAY=$(date -u +%Y-%m-%d)
NEW=$(cat "$V/wiki/concepts/new.md")
echo "$NEW" | grep -q "updated: $TODAY"                       && echo "  PASS: updated date bumped" && PASS=$((PASS+1)) \
                                                              || (echo "  FAIL: updated date not bumped"; FAIL=$((FAIL+1)))
# Working tree clean.
LEFTOVER=$( (cd "$V" && git status --porcelain) )
assert_eq "working tree clean"        ""                  "$LEFTOVER"

# Test 4: move-page refuses paths outside wiki/ (scope guard).
echo ""
echo "Test 4: move-page rejects out-of-scope --from"
V=$(make_vault scope-guard)
set +e
ERR=$( (cd "$V" && node "$SCRIPT" move-page --from raw/x.md --to wiki/concepts/y.md) 2>&1 1>/dev/null )
RC=$?
set -e
assert_eq "exit code 3"               "3" "$RC"
echo "$ERR" | grep -q "reorganize only operates on wiki/" \
  && echo "  PASS: scope error message" && PASS=$((PASS+1)) \
  || (echo "  FAIL: scope error wording"; FAIL=$((FAIL+1)))

# Test 5: link-rewrite does NOT touch values inside frontmatter `sources:`.
echo ""
echo "Test 5: link-rewrite leaves sources: alone"
V=$(make_vault sources-untouched)
cat > "$V/wiki/concepts/old.md" <<'MEOF'
---
tags: [demo]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# Old
MEOF
cat > "$V/wiki/concepts/other.md" <<'MEOF'
---
tags: [demo]
sources: [wiki/concepts/old]
created: 2026-05-01
updated: 2026-05-01
---
# Other
MEOF
(cd "$V" && git add . && git commit -qm "setup")
(cd "$V" && node "$SCRIPT" move-page --from wiki/concepts/old.md --to wiki/concepts/new.md) >/dev/null
OTHER=$(cat "$V/wiki/concepts/other.md")
echo "$OTHER" | grep -q 'sources: \[wiki/concepts/old\]'  && echo "  PASS: sources: untouched" && PASS=$((PASS+1)) \
                                                          || (echo "  FAIL: sources: was rewritten"; FAIL=$((FAIL+1)))

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
