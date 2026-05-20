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

# Test 6: merge-page absorbs body, deletes from, rewrites refs, drops index row.
echo ""
echo "Test 6: merge-page happy path"
V=$(make_vault merge)
cat > "$V/wiki/concepts/alignment.md" <<'MEOF'
---
tags: [ai]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---

# Alignment

Original body for alignment. Has multiple paragraphs.
More content. More content. More content.
MEOF
cat > "$V/wiki/concepts/ai-alignment.md" <<'MEOF'
---
tags: [ai]
sources: [raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---

# AI Alignment

Body for ai-alignment. Several paragraphs of overlapping content.
More. More. More.
MEOF
cat > "$V/wiki/concepts/other.md" <<'MEOF'
---
tags: [ai]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
relations:
  see-also: [wiki/concepts/alignment]
---

# Other

See [[alignment]] for context.
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/alignment]] — earlier page
- [[wiki/concepts/ai-alignment]] — survivor
- [[wiki/concepts/other]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")
# Provide a merged body roughly the size of the larger original — passes the
# sanity check.
MERGED=$(mktemp)
cat > "$MERGED" <<'BEOF'
# AI Alignment

Combined body. Lots of content carried over from both originals.
More. More. More. More. More.
BEOF
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" merge-page --from wiki/concepts/alignment.md --into wiki/concepts/ai-alignment.md --merged-body "$MERGED") )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"            "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names merge"    "reorganize: merge wiki/concepts/alignment.md into wiki/concepts/ai-alignment.md" "$(last_msg "$V")"
[ ! -f "$V/wiki/concepts/alignment.md" ] && echo "  PASS: alignment.md deleted" && PASS=$((PASS+1)) \
                                         || (echo "  FAIL: alignment.md not deleted"; FAIL=$((FAIL+1)))
# Inbound prose link rewritten.
OTH=$(cat "$V/wiki/concepts/other.md")
echo "$OTH" | grep -q '\[\[ai-alignment\]\]'           && echo "  PASS: prose rewritten" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: prose not rewritten"; FAIL=$((FAIL+1)))
# Inbound relations target rewritten.
echo "$OTH" | grep -q 'see-also:.*wiki/concepts/ai-alignment' \
                                                        && echo "  PASS: relations rewritten" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: relations not rewritten"; FAIL=$((FAIL+1)))
# Index row dropped, survivor row preserved.
IDX=$(cat "$V/wiki/index.md")
echo "$IDX" | grep -q 'wiki/concepts/alignment\]\]'    && (echo "  FAIL: dead row still in index"; FAIL=$((FAIL+1))) \
                                                        || (echo "  PASS: dead row removed" && PASS=$((PASS+1)))
echo "$IDX" | grep -q 'wiki/concepts/ai-alignment\]\] — survivor' \
                                                        && echo "  PASS: survivor row preserved" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: survivor row clobbered"; FAIL=$((FAIL+1)))
# Survivor body equals the merged body.
SURV=$(cat "$V/wiki/concepts/ai-alignment.md")
echo "$SURV" | grep -q "Combined body"                  && echo "  PASS: survivor body absorbed" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: survivor body not updated"; FAIL=$((FAIL+1)))
# `updated:` bumped on the survivor.
TODAY=$(date -u +%Y-%m-%d)
echo "$SURV" | grep -q "updated: $TODAY"                && echo "  PASS: updated date bumped" && PASS=$((PASS+1)) \
                                                        || (echo "  FAIL: updated date not bumped"; FAIL=$((FAIL+1)))
rm -f "$MERGED"

# Test 7: merge-page refuses when merged body is below the sanity floor.
echo ""
echo "Test 7: merge-page refuses suspiciously short merged body"
V=$(make_vault merge-short)
cat > "$V/wiki/concepts/a.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---

# A

$(printf 'a%.0s' {1..200})
MEOF
cat > "$V/wiki/concepts/b.md" <<'MEOF'
---
tags: [t]
sources: [raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---

# B

$(printf 'b%.0s' {1..200})
MEOF
(cd "$V" && git add . && git commit -qm "setup")
SHORT=$(mktemp)
echo "tiny" > "$SHORT"
BEFORE_CT=$(commit_count "$V")
set +e
ERR=$( (cd "$V" && node "$SCRIPT" merge-page --from wiki/concepts/a.md --into wiki/concepts/b.md --merged-body "$SHORT") 2>&1 1>/dev/null )
RC=$?
set -e
AFTER_CT=$(commit_count "$V")
assert_eq "exit code 3"             "3"  "$RC"
assert_eq "no commit made"          "$BEFORE_CT" "$AFTER_CT"
echo "$ERR" | grep -q "merged body suspiciously short" \
  && echo "  PASS: refusal message" && PASS=$((PASS+1)) \
  || (echo "  FAIL: refusal message wording"; FAIL=$((FAIL+1)))
# from page must still exist after refusal.
[ -f "$V/wiki/concepts/a.md" ] && echo "  PASS: from page survived" && PASS=$((PASS+1)) \
                               || (echo "  FAIL: from page got deleted despite refusal"; FAIL=$((FAIL+1)))
rm -f "$SHORT"

# Test 8: mark-covered appends a covered-by block, bumps updated, makes one commit.
echo ""
echo "Test 8: mark-covered happy path"
V=$(make_vault mark)
cat > "$V/wiki/sources/old-summary.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---

# Old Summary

Original body of the summary.
MEOF
cat > "$V/wiki/synthesis/big-idea.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md, raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---

# Big Idea

The synthesis page covering the topic.
MEOF
(cd "$V" && git add . && git commit -qm "setup")
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" mark-covered --page wiki/sources/old-summary.md --by wiki/synthesis/big-idea) )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"            "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names mark"     "reorganize: mark wiki/sources/old-summary.md covered by wiki/synthesis/big-idea" "$(last_msg "$V")"
# Block appended to the page.
OLD=$(cat "$V/wiki/sources/old-summary.md")
echo "$OLD" | grep -q '> \*\*Covered by \[\[wiki/synthesis/big-idea\]\]\*\*' \
  && echo "  PASS: covered-by block appended" && PASS=$((PASS+1)) \
  || (echo "  FAIL: covered-by block missing"; FAIL=$((FAIL+1)))
# Original body preserved.
echo "$OLD" | grep -q "Original body of the summary" \
  && echo "  PASS: original body preserved" && PASS=$((PASS+1)) \
  || (echo "  FAIL: original body changed"; FAIL=$((FAIL+1)))
# `updated:` bumped.
TODAY=$(date -u +%Y-%m-%d)
echo "$OLD" | grep -q "updated: $TODAY" \
  && echo "  PASS: updated date bumped" && PASS=$((PASS+1)) \
  || (echo "  FAIL: updated date not bumped"; FAIL=$((FAIL+1)))
# `by` target file untouched.
BY=$(cat "$V/wiki/synthesis/big-idea.md")
echo "$BY" | grep -q "updated: 2026-05-01" \
  && echo "  PASS: by target untouched" && PASS=$((PASS+1)) \
  || (echo "  FAIL: by target was modified"; FAIL=$((FAIL+1)))

# Test 9: parent-create writes parent file, appends Children, adds index row.
echo ""
echo "Test 9: parent-create happy path"
V=$(make_vault parent)
cat > "$V/wiki/concepts/p1.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p1
MEOF
cat > "$V/wiki/concepts/p2.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p2
MEOF
cat > "$V/wiki/concepts/p3.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p3
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/p1]]
- [[wiki/concepts/p2]]
- [[wiki/concepts/p3]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")
BODY=$(mktemp)
cat > "$BODY" <<'PEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-20
updated: 2026-05-20
---

# Programming Languages

Parent concept covering p1, p2, p3.
PEOF
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" parent-create --page wiki/concepts/programming-languages.md --body "$BODY" --children "wiki/concepts/p1,wiki/concepts/p2,wiki/concepts/p3") )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"             "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names parent"    "reorganize: introduce parent wiki/concepts/programming-languages.md" "$(last_msg "$V")"
# Parent file written with `## Children` section listing all three children.
PAR=$(cat "$V/wiki/concepts/programming-languages.md")
echo "$PAR" | grep -q "## Children"                        && echo "  PASS: ## Children section present" && PASS=$((PASS+1)) \
                                                            || (echo "  FAIL: ## Children section missing"; FAIL=$((FAIL+1)))
echo "$PAR" | grep -q '\[\[wiki/concepts/p1\]\]'           && echo "  PASS: child p1 listed" && PASS=$((PASS+1)) || (echo "  FAIL: p1 missing"; FAIL=$((FAIL+1)))
echo "$PAR" | grep -q '\[\[wiki/concepts/p2\]\]'           && echo "  PASS: child p2 listed" && PASS=$((PASS+1)) || (echo "  FAIL: p2 missing"; FAIL=$((FAIL+1)))
echo "$PAR" | grep -q '\[\[wiki/concepts/p3\]\]'           && echo "  PASS: child p3 listed" && PASS=$((PASS+1)) || (echo "  FAIL: p3 missing"; FAIL=$((FAIL+1)))
# Index gained a row under `## Concepts`.
IDX=$(cat "$V/wiki/index.md")
echo "$IDX" | grep -q 'wiki/concepts/programming-languages' \
  && echo "  PASS: index row added" && PASS=$((PASS+1)) \
  || (echo "  FAIL: index row missing"; FAIL=$((FAIL+1)))
# Children files untouched (no `updated:` bump).
for c in p1 p2 p3; do
  CONT=$(cat "$V/wiki/concepts/$c.md")
  echo "$CONT" | grep -q "updated: 2026-05-01" \
    && echo "  PASS: child $c untouched" && PASS=$((PASS+1)) \
    || (echo "  FAIL: child $c modified"; FAIL=$((FAIL+1)))
done
rm -f "$BODY"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
