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

# Test 10: relations-add creates the relations: key when absent.
echo ""
echo "Test 10: relations-add when relations: is absent"
V=$(make_vault rel-add-create)
cat > "$V/wiki/concepts/oauth.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# OAuth
MEOF
(cd "$V" && git add . && git commit -qm "setup")
BEFORE_CT=$(commit_count "$V")
OUT=$( (cd "$V" && node "$SCRIPT" relations-add --page wiki/concepts/oauth.md --relation defined-by --targets "src/documentation/foo/auth.md,wiki/concepts/jwt") )
AFTER_CT=$(commit_count "$V")
assert_eq "one new commit"               "$((BEFORE_CT + 1))" "$AFTER_CT"
assert_eq "commit msg names relations"   "reorganize: type relations on wiki/concepts/oauth.md" "$(last_msg "$V")"
P=$(cat "$V/wiki/concepts/oauth.md")
echo "$P" | grep -q "relations:"                                && echo "  PASS: relations: key added" && PASS=$((PASS+1)) || (echo "  FAIL: relations: missing"; FAIL=$((FAIL+1)))
echo "$P" | grep -q "defined-by:"                               && echo "  PASS: relation name added" && PASS=$((PASS+1)) || (echo "  FAIL: relation name missing"; FAIL=$((FAIL+1)))
echo "$P" | grep -q "src/documentation/foo/auth.md"             && echo "  PASS: first target listed"  && PASS=$((PASS+1)) || (echo "  FAIL: first target missing"; FAIL=$((FAIL+1)))
echo "$P" | grep -q "wiki/concepts/jwt"                         && echo "  PASS: second target listed" && PASS=$((PASS+1)) || (echo "  FAIL: second target missing"; FAIL=$((FAIL+1)))
TODAY=$(date -u +%Y-%m-%d)
echo "$P" | grep -q "updated: $TODAY"                           && echo "  PASS: updated bumped" && PASS=$((PASS+1)) || (echo "  FAIL: updated not bumped"; FAIL=$((FAIL+1)))

# Test 11: relations-add merges with existing relations: map and dedupes.
echo ""
echo "Test 11: relations-add merges and dedupes"
V=$(make_vault rel-add-merge)
cat > "$V/wiki/concepts/oauth.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
relations:
  defined-by: [src/documentation/foo/auth.md]
  see-also: [wiki/concepts/jwt]
---
# OAuth
MEOF
(cd "$V" && git add . && git commit -qm "setup")
(cd "$V" && node "$SCRIPT" relations-add --page wiki/concepts/oauth.md --relation defined-by --targets "src/documentation/foo/auth.md,wiki/concepts/oidc") >/dev/null
P=$(cat "$V/wiki/concepts/oauth.md")
# defined-by should contain both the original and the new target — exactly once each.
COUNT=$(echo "$P" | grep -c "src/documentation/foo/auth.md")
assert_eq "auth.md appears once (deduped)"      "1" "$COUNT"
echo "$P" | grep -q "wiki/concepts/oidc"  && echo "  PASS: new target appended" && PASS=$((PASS+1)) || (echo "  FAIL: new target missing"; FAIL=$((FAIL+1)))
# see-also untouched.
echo "$P" | grep -q "see-also:"           && echo "  PASS: see-also preserved"   && PASS=$((PASS+1)) || (echo "  FAIL: see-also dropped"; FAIL=$((FAIL+1)))

# Test 12: validate-or-revert exits 0 when validator is clean.
echo ""
echo "Test 12: validate-or-revert pass-through on clean tree"
V=$(make_vault val-clean)
cat > "$V/wiki/concepts/p.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/p]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")
BEFORE_CT=$(commit_count "$V")
set +e
(cd "$V" && node "$SCRIPT" validate-or-revert)
RC=$?
set -e
AFTER_CT=$(commit_count "$V")
assert_eq "exit 0 on clean"        "0" "$RC"
assert_eq "no revert commit"       "$BEFORE_CT" "$AFTER_CT"

# Test 13: validate-or-revert reverts HEAD and exits 2 when validator finds structural error.
echo ""
echo "Test 13: validate-or-revert reverts on structural error"
V=$(make_vault val-revert)
cat > "$V/wiki/concepts/p.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# p
MEOF
cat > "$V/wiki/index.md" <<'IEOF'
# Index

## Sources

## Entities

## Concepts

- [[wiki/concepts/p]]

## Synthesis
IEOF
(cd "$V" && git add . && git commit -qm "setup")
# Now make a bad commit: a page with broken frontmatter (missing `sources`).
cat > "$V/wiki/concepts/bad.md" <<'MEOF'
---
tags: [t]
created: 2026-05-01
updated: 2026-05-01
---
# Bad
MEOF
(cd "$V" && git add . && git commit -qm "bad commit")
BEFORE_CT=$(commit_count "$V")
set +e
(cd "$V" && node "$SCRIPT" validate-or-revert)
RC=$?
set -e
AFTER_CT=$(commit_count "$V")
assert_eq "exit 2 on structural"           "2" "$RC"
assert_eq "one revert commit added"        "$((BEFORE_CT + 1))" "$AFTER_CT"
LAST=$( (cd "$V" && git log -1 --pretty=%s) )
case "$LAST" in
  Revert*) echo "  PASS: revert commit on top" && PASS=$((PASS+1)) ;;
  *)       echo "  FAIL: top commit is '$LAST'" && FAIL=$((FAIL+1)) ;;
esac

# Test 14: candidates --kind merge returns pairs[] sorted by shared_wikilinks.
echo ""
echo "Test 14: candidates --kind merge"
V=$(make_vault cand-merge)
cat > "$V/wiki/concepts/alpha.md" <<'MEOF'
---
tags: [ai-safety]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# Alpha

[[shared-a]] [[shared-b]] [[shared-c]] [[shared-d]] [[shared-e]]
MEOF
cat > "$V/wiki/concepts/beta.md" <<'MEOF'
---
tags: [ai-safety]
sources: [raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---
# Beta

[[shared-a]] [[shared-b]] [[shared-c]] [[shared-d]] [[shared-e]] [[unique]]
MEOF
# Five dummy target pages so the wikilinks resolve and count.
for s in shared-a shared-b shared-c shared-d shared-e unique; do
  cat > "$V/wiki/concepts/$s.md" <<EOF
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# $s
EOF
done
(cd "$V" && git add . && git commit -qm "setup")

OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind merge --json) )
PAIR_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).pairs.length)))")
# alpha/beta share five wikilinks above the threshold → 1 pair surfaced.
[ "$PAIR_COUNT" -ge 1 ] && echo "  PASS: at least one pair returned ($PAIR_COUNT)" && PASS=$((PASS+1)) \
                        || (echo "  FAIL: expected ≥1 pair, got $PAIR_COUNT"; FAIL=$((FAIL+1)))
SHARED=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).pairs[0].shared_wikilinks)))")
assert_eq "top pair shared_wikilinks ≥ 5"   "5" "$SHARED"

# Test 15: candidates --kind parent groups ≥3 pages with a shared tag and overlapping links.
echo ""
echo "Test 15: candidates --kind parent"
V=$(make_vault cand-parent)
for n in p1 p2 p3; do
  cat > "$V/wiki/concepts/$n.md" <<EOF
---
tags: [programming-languages]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# $n

[[shared-a]] [[shared-b]] [[shared-c]]
EOF
done
for s in shared-a shared-b shared-c; do
  cat > "$V/wiki/concepts/$s.md" <<EOF
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# $s
EOF
done
(cd "$V" && git add . && git commit -qm "setup")
OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind parent --json) )
CL_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).clusters.length)))")
[ "$CL_COUNT" -ge 1 ] && echo "  PASS: at least one cluster ($CL_COUNT)" && PASS=$((PASS+1)) \
                      || (echo "  FAIL: expected ≥1 cluster, got $CL_COUNT"; FAIL=$((FAIL+1)))
M_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).clusters[0].members.length)))")
[ "$M_COUNT" -ge 3 ] && echo "  PASS: cluster has 3+ members ($M_COUNT)" && PASS=$((PASS+1)) \
                     || (echo "  FAIL: cluster has $M_COUNT members"; FAIL=$((FAIL+1)))

# Test 16: candidates --kind recategorize flags synthesising concept pages.
echo ""
echo "Test 16: candidates --kind recategorize"
V=$(make_vault cand-recat)
cat > "$V/wiki/concepts/synthesiser.md" <<'MEOF'
---
tags: [t]
sources: [raw/a.md, raw/b.md, raw/c.md]
created: 2026-05-01
updated: 2026-05-01
---
# Synthesiser

[[wiki/concepts/sub-1]] [[wiki/concepts/sub-2]] [[wiki/concepts/sub-3]]
MEOF
for n in sub-1 sub-2 sub-3; do
  cat > "$V/wiki/concepts/$n.md" <<EOF
---
tags: [t]
sources: [raw/a.md]
created: 2026-05-01
updated: 2026-05-01
---
# $n
EOF
done
(cd "$V" && git add . && git commit -qm "setup")
OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind recategorize --json) )
PG_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).pages.length)))")
[ "$PG_COUNT" -ge 1 ] && echo "  PASS: at least one recategorize candidate ($PG_COUNT)" && PASS=$((PASS+1)) \
                      || (echo "  FAIL: expected ≥1 candidate, got $PG_COUNT"; FAIL=$((FAIL+1)))
SYNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).pages[0].signals.synthesises_others?'true':'false'))")
assert_eq "first candidate is synthesising"  "true" "$SYNT"

# Test 17: candidates --kind cover surfaces a source-summary covered by a synthesis page.
echo ""
echo "Test 17: candidates --kind cover"
V=$(make_vault cand-cover)
cat > "$V/wiki/sources/old.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md]
created: 2026-04-01
updated: 2026-04-01
---
# Old

[[shared-a]] [[shared-b]] [[shared-c]] [[shared-d]] [[shared-e]]
MEOF
cat > "$V/wiki/synthesis/big.md" <<'MEOF'
---
tags: [t]
sources: [raw/x.md, raw/y.md]
created: 2026-05-01
updated: 2026-05-01
---
# Big

[[shared-a]] [[shared-b]] [[shared-c]] [[shared-d]] [[shared-e]]
MEOF
for s in shared-a shared-b shared-c shared-d shared-e; do
  cat > "$V/wiki/concepts/$s.md" <<EOF
---
tags: [t]
sources: [raw/x.md]
created: 2026-05-01
updated: 2026-05-01
---
# $s
EOF
done
(cd "$V" && git add . && git commit -qm "setup")
OUT=$( (cd "$V" && node "$SCRIPT" candidates --kind cover --json) )
S_COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(String(JSON.parse(d).summaries.length)))")
[ "$S_COUNT" -ge 1 ] && echo "  PASS: at least one cover candidate ($S_COUNT)" && PASS=$((PASS+1)) \
                     || (echo "  FAIL: expected ≥1 candidate, got $S_COUNT"; FAIL=$((FAIL+1)))
PATH_=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).summaries[0].path))")
assert_eq "summary path"      "wiki/sources/old.md" "$PATH_"
COV=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>process.stdout.write(JSON.parse(d).summaries[0].candidate_covers[0]))")
assert_eq "candidate cover"   "wiki/synthesis/big.md" "$COV"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
