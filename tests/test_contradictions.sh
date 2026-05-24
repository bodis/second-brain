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

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
