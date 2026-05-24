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

# Test: Signal 2 shared-entity-prose on a fixture vault.
echo ""
echo "Test: Signal 2 shared-entity-prose"
V_S2=$(make_vault vault-signal-2)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/concepts/." "$V_S2/wiki/concepts/"
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-2-shared-entity-prose/wiki/entities/." "$V_S2/wiki/entities/"
(cd "$V_S2" && git add . && git commit -qm "fixture content")
(cd "$V_S2" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
OUT=$( (cd "$V_S2" && node "$SCRIPT" list --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions.length))})")
assert_eq "Signal 2 enqueues 5 candidates (one per shared entity)" "5" "$COUNT"
SIGNAL=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(JSON.parse(d).contradictions[0].signal)})")
assert_eq "signal === shared-entity-prose" "shared-entity-prose" "$SIGNAL"
ENTITY=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{let e=JSON.parse(d).contradictions[0]; process.stdout.write(e.signal_data.entity)})")
case "$ENTITY" in
  wiki/entities/*.md)
    echo "  PASS: signal_data.entity points at an entity page"
    PASS=$((PASS + 1));;
  *)
    echo "  FAIL: signal_data.entity malformed: $ENTITY"
    FAIL=$((FAIL + 1));;
esac
SHARED=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).contradictions[0].signal_data.shared_links))})")
assert_eq "shared_links === 5" "5" "$SHARED"

# Test: re-run candidates on the same fixture → no duplicate entries.
echo ""
echo "Test: candidates dedupe on re-scan"
V_DEDUP=$(make_vault vault-dedupe)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$V_DEDUP/wiki/concepts/"
(cd "$V_DEDUP" && git add . && git commit -qm "fixture content")
(cd "$V_DEDUP" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
COUNT1=$(node -e "process.stdout.write(String(require('js-yaml').load(require('fs').readFileSync('$V_DEDUP/wiki/.state/contradictions.yaml','utf8')).contradictions.length))")
(cd "$V_DEDUP" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
COUNT2=$(node -e "process.stdout.write(String(require('js-yaml').load(require('fs').readFileSync('$V_DEDUP/wiki/.state/contradictions.yaml','utf8')).contradictions.length))")
assert_eq "second scan does not duplicate"  "$COUNT1" "$COUNT2"

# Test: pair canonicalisation — `pages` is always lexically sorted.
echo ""
echo "Test: pages field is lexically sorted"
PAGES=$(node -e "process.stdout.write(JSON.stringify(require('js-yaml').load(require('fs').readFileSync('$V_DEDUP/wiki/.state/contradictions.yaml','utf8')).contradictions[0].pages))")
SORTED=$(node -e "let p=$PAGES; process.stdout.write(JSON.stringify([...p].sort()))")
assert_eq "pages array is sorted" "$SORTED" "$PAGES"

# Test: --scope=<single-page> expands one hop and surfaces a candidate
# that spans the scope boundary.
echo ""
echo "Test: page-list scope with one-hop expansion"
V_SCOPE=$(make_vault vault-scope)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$V_SCOPE/wiki/concepts/"
(cd "$V_SCOPE" && git add . && git commit -qm "fixture content")
# Scope only one of the two pages; the other should be picked up via the
# direct `[[ai-alignment]]` body wikilink in alignment.md.
(cd "$V_SCOPE" && node "$SCRIPT" candidates --scope=wiki/concepts/alignment.md >/dev/null)
COUNT=$(node -e "process.stdout.write(String(require('js-yaml').load(require('fs').readFileSync('$V_SCOPE/wiki/.state/contradictions.yaml','utf8')).contradictions.length))")
assert_eq "scoped-with-expansion enqueues 1 candidate" "1" "$COUNT"

# Test: neighbour expansion cap (K=50).
echo ""
echo "Test: neighbour expansion cap"
V_CAP=$(make_vault vault-cap)
# Build a hub page with 60 outbound wikilinks; expansion must cap at K=50
# and emit a warning to stderr (still exit 0).
node -e '
const fs=require("fs"); const path=require("path"); const v=process.argv[1];
const lines=["---","tags: []","sources: [raw/x.md]","created: 2026-04-01","updated: 2026-04-01","---","# Hub",""];
for (let i=0;i<60;i++) {
  const slug = `e${String(i).padStart(3,"0")}`;
  lines.push(`Link to [[${slug}]].`);
  fs.writeFileSync(path.join(v,`wiki/entities/${slug}.md`),
    `---\ntags: []\nsources: [raw/x.md]\ncreated: 2026-04-01\nupdated: 2026-04-01\n---\n# ${slug}\n`);
}
fs.writeFileSync(path.join(v,"wiki/concepts/hub.md"), lines.join("\n")+"\n");
' "$V_CAP"
(cd "$V_CAP" && git add . && git commit -qm "hub fixture")
set +e
ERR=$( (cd "$V_CAP" && node "$SCRIPT" candidates --scope=wiki/concepts/hub.md 2>&1 >/dev/null) )
EXIT=$?
set -e
assert_eq "exit 0 even when cap is hit" "0" "$EXIT"
case "$ERR" in
  *"truncated"*|*"cap"*|*"K=50"*)
    echo "  PASS: stderr mentions the cap"
    PASS=$((PASS + 1));;
  *)
    echo "  FAIL: stderr did not mention cap — got: $ERR"
    FAIL=$((FAIL + 1));;
esac

# Test: candidates --json is read-only (no yaml mutation, prints JSON).
echo ""
echo "Test: candidates --json is read-only"
V_JSON=$(make_vault vault-json)
cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$V_JSON/wiki/concepts/"
(cd "$V_JSON" && git add . && git commit -qm "fixture content")
OUT=$( (cd "$V_JSON" && node "$SCRIPT" candidates --scope=wiki/ --json) )
COUNT=$(echo "$OUT" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{process.stdout.write(String(JSON.parse(d).candidates.length))})")
assert_eq "candidates --json reports 1 candidate" "1" "$COUNT"
HAS_FILE="no"
[ -f "$V_JSON/wiki/.state/contradictions.yaml" ] && HAS_FILE="yes"
assert_eq "yaml not created in --json mode" "no" "$HAS_FILE"

# Helper: seed a vault with one `unjudged` entry and echo its id.
seed_unjudged() {
  local v="$1"
  cp -a "$REPO_ROOT/tests/fixtures/contradictions/signal-1-conflicting-relations/wiki/concepts/." "$v/wiki/concepts/"
  (cd "$v" && git add . && git commit -qm "fixture content")
  (cd "$v" && node "$SCRIPT" candidates --scope=wiki/ >/dev/null)
  node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$v/wiki/.state/contradictions.yaml','utf8')).contradictions[0].id)"
}

# Test: judge --verdict=real-contradiction transitions unjudged → unresolved.
echo ""
echo "Test: judge real-contradiction"
V_JR=$(make_vault vault-judge-real)
ID=$(seed_unjudged "$V_JR")
(cd "$V_JR" && node "$SCRIPT" judge --id="$ID" --verdict=real-contradiction \
  --data='{"claim":"Acquirer of foo","assertions":[{"page":"wiki/concepts/alignment.md","text":"first claim","source":"raw/source-a.md"},{"page":"wiki/concepts/ai-alignment.md","text":"second claim","source":"raw/source-b.md"}],"rationale":"Both pages take different positions."}' >/dev/null)
STATUS=$(node -e "let d=require('js-yaml').load(require('fs').readFileSync('$V_JR/wiki/.state/contradictions.yaml','utf8')); process.stdout.write(d.contradictions[0].status)")
assert_eq "status === unresolved" "unresolved" "$STATUS"
CLAIM=$(node -e "let d=require('js-yaml').load(require('fs').readFileSync('$V_JR/wiki/.state/contradictions.yaml','utf8')); process.stdout.write(d.contradictions[0].judgment.claim)")
assert_eq "claim populated" "Acquirer of foo" "$CLAIM"

# Test: judge --verdict=not-a-contradiction.
echo ""
echo "Test: judge not-a-contradiction"
V_JN=$(make_vault vault-judge-not)
ID=$(seed_unjudged "$V_JN")
(cd "$V_JN" && node "$SCRIPT" judge --id="$ID" --verdict=not-a-contradiction \
  --data='{"rationale":"Both pages are just listing common parents."}' >/dev/null)
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_JN/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status === not-a-contradiction" "not-a-contradiction" "$STATUS"

# Test: judge on already-judged entry → exit 3.
echo ""
echo "Test: judge on already-judged → exit 3"
set +e
(cd "$V_JN" && node "$SCRIPT" judge --id="$ID" --verdict=real-contradiction \
  --data='{"claim":"x","assertions":[{"page":"a","text":"b","source":"c"}],"rationale":"r"}' >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 3 on second judge" "3" "$EXIT"

# Helper: seed a vault with one `unresolved` entry and echo its id.
seed_unresolved() {
  local v="$1"
  local id=$(seed_unjudged "$v")
  (cd "$v" && node "$SCRIPT" judge --id="$id" --verdict=real-contradiction \
    --data='{"claim":"c","assertions":[{"page":"wiki/concepts/alignment.md","text":"t","source":"s"}],"rationale":"r"}' >/dev/null)
  echo "$id"
}

# Test: resolve --kind=defer on unresolved → deferred.
echo ""
echo "Test: resolve defer from unresolved"
V_RD=$(make_vault vault-resolve-defer)
ID=$(seed_unresolved "$V_RD")
(cd "$V_RD" && node "$SCRIPT" resolve --id="$ID" --kind=defer >/dev/null)
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status === deferred" "deferred" "$STATUS"
HAS_AT=$(node -e "let e=require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0]; process.stdout.write(String(typeof e.deferred_at === 'string'))")
assert_eq "deferred_at populated" "true" "$HAS_AT"

# Test: idempotent re-defer updates deferred_at.
echo ""
echo "Test: re-defer is idempotent"
FIRST_AT=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0].deferred_at)")
sleep 1
(cd "$V_RD" && node "$SCRIPT" resolve --id="$ID" --kind=defer >/dev/null)
SECOND_AT=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0].deferred_at)")
case "$FIRST_AT" in
  "$SECOND_AT")
    echo "  FAIL: deferred_at did not update on re-defer"
    FAIL=$((FAIL + 1));;
  *)
    echo "  PASS: deferred_at updated on re-defer"
    PASS=$((PASS + 1));;
esac
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RD/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status stays deferred" "deferred" "$STATUS"

# Test: resolve --kind=defer on unjudged → exit 3.
echo ""
echo "Test: resolve defer on unjudged → exit 3"
V_RU=$(make_vault vault-resolve-unjudged)
ID=$(seed_unjudged "$V_RU")
set +e
(cd "$V_RU" && node "$SCRIPT" resolve --id="$ID" --kind=defer >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 3 on invalid transition" "3" "$EXIT"

# Test: resolve --kind=pick-a → exit 2 (unsupported kind).
echo ""
echo "Test: resolve unsupported kind → exit 2"
set +e
(cd "$V_RU" && node "$SCRIPT" resolve --id="$ID" --kind=pick-a >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 2 on unsupported kind" "2" "$EXIT"

# Helper: seed a vault for apply-pick — fixture + one unresolved entry with
# a populated judgment block that quotes one paragraph from each page.
# Echoes the entry id.
seed_apply_pick() {
  local v="$1"
  cp -a "$REPO_ROOT/tests/fixtures/contradictions/apply-pick-input/wiki/." "$v/wiki/"
  (cd "$v" && git add . && git commit -qm "fixture content")
  # Hand-craft contradictions.yaml so we control the assertion text exactly.
  cat > "$v/wiki/.state/contradictions.yaml" <<YAML
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  - id: 2026-05-24-001
    detected_at: 2026-05-24T10:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [foo], a_only_targets: [], b_only_targets: [bar] }
    status: unresolved
    judgment:
      verdict: real-contradiction
      at: 2026-05-24T11:00:00Z
      claim: "Acquirer of Foo"
      assertions:
        - page: wiki/entities/foo.md
          text: "Foo was acquired by Bar in 2023."
          source: raw/article-a.md
        - page: wiki/concepts/acquisitions.md
          text: "Foo was acquired by Baz in 2024."
          source: raw/article-b.md
      rationale: "Two pages, different acquirers."
YAML
  (cd "$v" && git add wiki/.state/contradictions.yaml && git commit -qm "seed contradiction")
  echo "2026-05-24-001"
}

# Test: apply-pick happy path — pick foo, rewrite acquisitions, single commit,
# yaml entry transitions to resolved-pick-b. Lexically sorted pages are
# [acquisitions (a), foo (b)]; winning is foo (b) → resolved-pick-b.
echo ""
echo "Test: apply-pick happy path"
V_AP=$(make_vault vault-apply-pick)
ID=$(seed_apply_pick "$V_AP")
TMP=$(mktemp)
cat > "$TMP" <<'MD'
Foo was acquired by Bar in 2023.
MD
(cd "$V_AP" && node "$SCRIPT" apply-pick --id="$ID" --winning-page=wiki/entities/foo.md --rewrite="$TMP" >/dev/null)
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_AP/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status === resolved-pick-b" "resolved-pick-b" "$STATUS"
LOSING_TEXT=$(grep -c "Baz in 2024" "$V_AP/wiki/concepts/acquisitions.md" || true)
assert_eq "Baz claim removed from acquisitions.md" "0" "$LOSING_TEXT"
BAR_REPLACED=$(grep -c "Foo was acquired by Bar in 2023" "$V_AP/wiki/concepts/acquisitions.md" || true)
assert_eq "Bar claim swapped into acquisitions.md" "1" "$BAR_REPLACED"
HAS_A=$(grep -c "article-a.md" "$V_AP/wiki/concepts/acquisitions.md" || true)
HAS_B=$(grep -c "article-b.md" "$V_AP/wiki/concepts/acquisitions.md" || true)
assert_eq "acquisitions.md sources include article-a.md" "1" "$HAS_A"
assert_eq "acquisitions.md sources include article-b.md" "1" "$HAS_B"
COMMIT_COUNT=$(cd "$V_AP" && git log --grep "reconcile: pick" --oneline | wc -l | tr -d ' ')
assert_eq "exactly one reconcile commit" "1" "$COMMIT_COUNT"
rm -f "$TMP"

# Test: apply-pick substring not found → exit 3, no mutation.
echo ""
echo "Test: apply-pick substring not found → exit 3"
V_NF=$(make_vault vault-apply-notfound)
ID=$(seed_apply_pick "$V_NF")
node -e "
const fs=require('fs'), yaml=require('js-yaml');
const p='$V_NF/wiki/.state/contradictions.yaml';
const d=yaml.load(fs.readFileSync(p,'utf8'),{schema:yaml.CORE_SCHEMA});
d.contradictions[0].judgment.assertions[1].text='No such sentence ever appears';
fs.writeFileSync(p,yaml.dump(d,{indent:2,sortKeys:false,lineWidth:-1}));
"
TMP=$(mktemp); echo "anything" > "$TMP"
set +e
(cd "$V_NF" && node "$SCRIPT" apply-pick --id="$ID" --winning-page=wiki/entities/foo.md --rewrite="$TMP" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 3 on zero-match substring" "3" "$EXIT"
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_NF/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status unchanged after zero-match" "unresolved" "$STATUS"
rm -f "$TMP"

# Test: apply-pick substring matches multiple paragraphs → exit 3.
echo ""
echo "Test: apply-pick substring matches multiple paragraphs → exit 3"
V_MM=$(make_vault vault-apply-multi)
ID=$(seed_apply_pick "$V_MM")
cat >> "$V_MM/wiki/concepts/acquisitions.md" <<'MD'

Foo was acquired by Baz in 2024.
MD
(cd "$V_MM" && git add wiki/concepts/acquisitions.md && git commit -qm "duplicate paragraph")
TMP=$(mktemp); echo "anything" > "$TMP"
set +e
(cd "$V_MM" && node "$SCRIPT" apply-pick --id="$ID" --winning-page=wiki/entities/foo.md --rewrite="$TMP" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 3 on multiple-match substring" "3" "$EXIT"
rm -f "$TMP"

# Test: apply-pick post-check revert — pre-stage a dead index row that makes
# validate-wiki exit 2 on every run.  apply-pick's commit triggers the
# post-check, which fails, and the script auto-reverts.
#
# (Broken wikilinks in the rewrite would only trigger validate-wiki exit 1,
# which is a warning per CR-005 conventions — not a revert trigger. Lint will
# surface those later. We test the structural-failure revert path explicitly.)
echo ""
echo "Test: apply-pick post-check auto-revert"
V_RV=$(make_vault vault-apply-revert)
ID=$(seed_apply_pick "$V_RV")
echo "- [[wiki/concepts/nonexistent]]" >> "$V_RV/wiki/index.md"
(cd "$V_RV" && git add wiki/index.md && git commit -qm "stage dead index row")
TMP=$(mktemp)
cat > "$TMP" <<'MD'
Foo was acquired by Bar in 2023.
MD
set +e
(cd "$V_RV" && node "$SCRIPT" apply-pick --id="$ID" --winning-page=wiki/entities/foo.md --rewrite="$TMP" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 2 on post-check structural failure" "2" "$EXIT"
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_RV/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status unchanged after revert" "unresolved" "$STATUS"
HEAD_MSG=$(cd "$V_RV" && git log -1 --format=%s)
case "$HEAD_MSG" in
  *"Revert"*"reconcile: pick"*) echo "  PASS: revert commit present"; PASS=$((PASS+1));;
  *"reconcile: pick"*)          echo "  FAIL: reconcile commit not reverted"; FAIL=$((FAIL+1));;
  *)                            echo "  FAIL: unexpected HEAD: $HEAD_MSG"; FAIL=$((FAIL+1));;
esac
rm -f "$TMP"

# Helper: seed a vault for apply-accept — fixture + one unresolved entry,
# pages [acquisitions, foo].
seed_apply_accept() {
  local v="$1"
  cp -a "$REPO_ROOT/tests/fixtures/contradictions/apply-accept-input/wiki/." "$v/wiki/"
  (cd "$v" && git add . && git commit -qm "fixture content")
  cat > "$v/wiki/.state/contradictions.yaml" <<YAML
schema_version: 1
generated_by: scripts/contradictions.js
contradictions:
  - id: 2026-05-24-001
    detected_at: 2026-05-24T10:00:00Z
    pages: [wiki/concepts/acquisitions.md, wiki/entities/foo.md]
    signal: conflicting-relations
    signal_data: { relation: refines, shared_targets: [foo], a_only_targets: [], b_only_targets: [bar] }
    status: unresolved
    judgment:
      verdict: real-contradiction
      at: 2026-05-24T11:00:00Z
      claim: "Acquirer of Foo"
      assertions:
        - page: wiki/entities/foo.md
          text: "Foo was acquired by Bar in 2023."
          source: raw/article-a.md
        - page: wiki/concepts/acquisitions.md
          text: "Foo was acquired by Baz in 2024."
          source: raw/article-b.md
      rationale: "Two pages, different acquirers."
YAML
  (cd "$v" && git add wiki/.state/contradictions.yaml && git commit -qm "seed contradiction")
  echo "2026-05-24-001"
}

# Test: apply-accept happy path — both pages gain relations.contradicts,
# entry transitions to accepted-disagreement, one commit.
echo ""
echo "Test: apply-accept happy path"
V_AA=$(make_vault vault-apply-accept)
ID=$(seed_apply_accept "$V_AA")
(cd "$V_AA" && node "$SCRIPT" apply-accept --id="$ID" >/dev/null)
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_AA/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status === accepted-disagreement" "accepted-disagreement" "$STATUS"
# Both pages got relations.contradicts.
FOO_CONTRADICTS=$(node -e "let fm=require('js-yaml').load(require('fs').readFileSync('$V_AA/wiki/entities/foo.md','utf8').match(/^---\n([\s\S]*?)\n---/)[1]); process.stdout.write(JSON.stringify(fm.relations?.contradicts || []))")
case "$FOO_CONTRADICTS" in
  *"wiki/concepts/acquisitions.md"*) echo "  PASS: foo.md gained relations.contradicts"; PASS=$((PASS+1));;
  *) echo "  FAIL: foo.md relations.contradicts: $FOO_CONTRADICTS"; FAIL=$((FAIL+1));;
esac
ACQ_CONTRADICTS=$(node -e "let fm=require('js-yaml').load(require('fs').readFileSync('$V_AA/wiki/concepts/acquisitions.md','utf8').match(/^---\n([\s\S]*?)\n---/)[1]); process.stdout.write(JSON.stringify(fm.relations?.contradicts || []))")
case "$ACQ_CONTRADICTS" in
  *"wiki/entities/foo.md"*) echo "  PASS: acquisitions.md gained relations.contradicts"; PASS=$((PASS+1));;
  *) echo "  FAIL: acquisitions.md relations.contradicts: $ACQ_CONTRADICTS"; FAIL=$((FAIL+1));;
esac
COMMIT_COUNT=$(cd "$V_AA" && git log --grep "reconcile: accept-disagreement" --oneline | wc -l | tr -d ' ')
assert_eq "exactly one accept commit" "1" "$COMMIT_COUNT"

# Test: apply-accept idempotent — re-running adds no duplicate target.
echo ""
echo "Test: apply-accept second call is a no-op on the same entry → exit 3"
set +e
(cd "$V_AA" && node "$SCRIPT" apply-accept --id="$ID" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "second apply-accept exits 3 (entry already accepted-disagreement)" "3" "$EXIT"

# Test: apply-accept post-check revert — same pattern as apply-pick:
# pre-stage a dead index row to force validate-wiki exit 2.
echo ""
echo "Test: apply-accept post-check revert"
V_AR=$(make_vault vault-apply-accept-revert)
ID=$(seed_apply_accept "$V_AR")
echo "- [[wiki/concepts/nonexistent]]" >> "$V_AR/wiki/index.md"
(cd "$V_AR" && git add wiki/index.md && git commit -qm "stage dead index row")
set +e
(cd "$V_AR" && node "$SCRIPT" apply-accept --id="$ID" >/dev/null 2>&1)
EXIT=$?
set -e
assert_eq "exit 2 on post-check structural failure" "2" "$EXIT"
STATUS=$(node -e "process.stdout.write(require('js-yaml').load(require('fs').readFileSync('$V_AR/wiki/.state/contradictions.yaml','utf8')).contradictions[0].status)")
assert_eq "status unchanged after revert" "unresolved" "$STATUS"

# Test: schema_version mismatch → exit 2 with helpful message.
echo ""
echo "Test: schema_version mismatch"
V_SV=$(make_vault vault-schema)
cp "$REPO_ROOT/tests/fixtures/contradictions/schema-mismatch/wiki/.state/contradictions.yaml" "$V_SV/wiki/.state/contradictions.yaml"
set +e
ERR=$( (cd "$V_SV" && node "$SCRIPT" list 2>&1) )
EXIT=$?
set -e
assert_eq "exit 2 on schema_version mismatch" "2" "$EXIT"
case "$ERR" in
  *"schema_version"*) echo "  PASS: stderr names schema_version"; PASS=$((PASS+1));;
  *) echo "  FAIL: stderr did not mention schema_version: $ERR"; FAIL=$((FAIL+1));;
esac

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
