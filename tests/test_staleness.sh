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

echo "==> candidates: age-only scan writes state file but enqueues nothing (composite low without moved_past)"
V=$(make_vault age-only-vault)
cp "$REPO_ROOT/tests/fixtures/staleness/age-only/wiki/.state/frontmatter-contract.yaml" "$V/wiki/.state/"
# Create 25 pages with mtimes staggered around 2026-05; one (p1) is much older.
for i in $(seq 1 25); do
  f="$V/wiki/concepts/p$i.md"
  cat > "$f" <<'MDEOF'
---
tags: []
sources: [raw/dummy.md]
created: 2024-01-01
updated: 2024-01-01
---
MDEOF
  echo "# P$i" >> "$f"
done
touch -t 202201010000 "$V/wiki/concepts/p1.md"
for i in $(seq 2 25); do touch -t 202605010000 "$V/wiki/concepts/p$i.md"; done
cd "$V"
node "$SCRIPT" candidates >/dev/null
[ -f wiki/.state/staleness.yaml ] && exists=yes || exists=no
assert_eq "staleness.yaml created" "yes" "$exists"
# vault_page_count should be 25.
vpc=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.pages.length))")
# pages: should be empty — all composites are low without moved_past.
assert_eq "no pages enqueued (all low-tier)" "0" "$vpc"
# But the file must contain the scanned_at + vault_page_count meta.
output=$(cat wiki/.state/staleness.yaml)
case "$output" in
  *"vault_page_count: 25"*) assert_eq "vault_page_count meta" "ok" "ok" ;;
  *) assert_eq "vault_page_count meta" "expected vault_page_count: 25" "$output" ;;
esac
case "$output" in
  *"scanned_at:"*) assert_eq "scanned_at meta" "ok" "ok" ;;
  *) assert_eq "scanned_at meta" "expected scanned_at: ..." "$output" ;;
esac

echo "==> candidates: both signals strong → composite high"
V=$(make_vault both-high)
cp -R "$REPO_ROOT/tests/fixtures/staleness/both-signals-high/wiki/." "$V/wiki/"
touch -t 202401010000 "$V/wiki/concepts/stale-page.md"
cd "$V"
node "$SCRIPT" candidates >/dev/null
signal=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/stale-page.md');process.stdout.write(e?e.signal:'(missing)')")
assert_eq "stale-page composite" "high" "$signal"

echo "==> candidates: only moved_past strong → composite not high/medium"
V=$(make_vault moved-only)
cp -R "$REPO_ROOT/tests/fixtures/staleness/moved-past-only/wiki/." "$V/wiki/"
# Set padding pages to old mtime so recent-page is the newest (low age percentile).
for pf in "$V/wiki/concepts/padding-"*.md "$V/wiki/entities/"*.md "$V/wiki/sources/"*.md; do
  touch -t 202401010000 "$pf" 2>/dev/null || true
done
touch -t 202605200000 "$V/wiki/concepts/recent-page.md"
cd "$V"
node "$SCRIPT" candidates >/dev/null
signal=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/recent-page.md');process.stdout.write(e?e.signal:'(missing)')")
case "$signal" in
  high|medium) assert_eq "recent-page must not be high/medium" "low or absent" "$signal" ;;
  *) assert_eq "recent-page composite OK" "ok" "ok" ;;
esac

echo "==> candidates: borderline page gets medium composite"
V=$(make_vault both-medium)
cp -R "$REPO_ROOT/tests/fixtures/staleness/both-signals-medium/wiki/." "$V/wiki/"
# Match the Task 5 pattern: explicit mtimes on padding too, since cp -R does not preserve them on macOS.
for i in $(seq 1 22); do touch -t 202605010000 "$V/wiki/concepts/padding-$i.md"; done
touch -t 202401010000 "$V/wiki/concepts/borderline.md"
cd "$V"
node "$SCRIPT" candidates >/dev/null
signal=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/borderline.md');process.stdout.write(e?e.signal:'(missing)')")
case "$signal" in
  medium|high) assert_eq "borderline signal" "$signal" "$signal" ;;
  *) assert_eq "borderline signal" "medium or high" "$signal" ;;
esac

echo "==> candidates: tiny vault → empty + warning"
V=$(make_vault tiny)
cp -R "$REPO_ROOT/tests/fixtures/staleness/tiny-vault/wiki/." "$V/wiki/"
cd "$V"
set +e
output=$(node "$SCRIPT" candidates 2>&1)
rc=$?
set -e
assert_eq "tiny exit code" "0" "$rc"
case "$output" in
  *"<20"*|*"candidate-eligible"*) assert_eq "tiny warning emitted" "ok" "ok" ;;
  *) assert_eq "tiny warning emitted" "expected '<20' or 'candidate-eligible'" "$output" ;;
esac
pages=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.pages.length))")
assert_eq "tiny: no pages enqueued" "0" "$pages"

echo "==> candidates: empty vault → empty + warning"
V=$(make_vault empty)
cp -R "$REPO_ROOT/tests/fixtures/staleness/empty-vault/wiki/." "$V/wiki/"
cd "$V"
set +e
node "$SCRIPT" candidates >/dev/null 2>&1
rc=$?
set -e
assert_eq "empty exit code" "0" "$rc"
pages=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));process.stdout.write(String(d.pages.length))")
assert_eq "empty: zero pages" "0" "$pages"

echo "==> candidates: dedupe preserves non-unjudged, drops unjudged"
V=$(make_vault dedupe)
cp -R "$REPO_ROOT/tests/fixtures/staleness/dedupe/wiki/." "$V/wiki/"
touch -t 202401010000 "$V/wiki/concepts/old.md"
cd "$V"
node "$SCRIPT" candidates >/dev/null
json=$(node "$SCRIPT" list --json)
resolved_present=$(echo "$json" | grep -c '"id": "2026-05-20-002"' || true)
unjudged_001_present=$(echo "$json" | grep -c '"id": "2026-05-20-001"' || true)
assert_eq "resolved entry preserved" "1" "$resolved_present"
assert_eq "old unjudged entry dropped" "0" "$unjudged_001_present"

echo "==> candidates: deferred entry stays deferred when score unchanged"
V=$(make_vault adef-no-bump)
cp -R "$REPO_ROOT/tests/fixtures/staleness/auto-defer-no-bump/wiki/." "$V/wiki/"
cd "$V"
node "$SCRIPT" candidates >/dev/null
status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/p1.md');process.stdout.write(e?e.status:'(missing)')")
assert_eq "p1 still deferred" "deferred" "$status"

echo "==> candidates: deferred entry returns to unjudged when score bumps"
V=$(make_vault adef-bumped)
cp -R "$REPO_ROOT/tests/fixtures/staleness/auto-defer-bumped/wiki/." "$V/wiki/"
# Padding pages need explicit mtimes (cp -R does not preserve).
for i in $(seq 1 22); do touch -t 202605010000 "$V/wiki/concepts/padding-$i.md"; done
touch -t 202401010000 "$V/wiki/concepts/old.md"
cd "$V"
node "$SCRIPT" candidates >/dev/null
status=$(node "$SCRIPT" list --json | node -e "const d=JSON.parse(require('fs').readFileSync(0));const e=d.pages.find(x=>x.path==='wiki/concepts/old.md');process.stdout.write(e?e.status:'(missing)')")
assert_eq "old re-promoted to unjudged" "unjudged" "$status"

echo "==> candidates --scope: restricts what gets enqueued, not what gets percentile-ranked"
V=$(make_vault scope)
cp -R "$REPO_ROOT/tests/fixtures/staleness/both-signals-high/wiki/." "$V/wiki/"
# Pin padding mtimes for deterministic ranking (cp -R doesn't preserve).
for i in $(seq 1 22); do touch -t 202605010000 "$V/wiki/concepts/padding-$i.md"; done
touch -t 202401010000 "$V/wiki/concepts/stale-page.md"
cd "$V"
node "$SCRIPT" candidates --scope=wiki/concepts/stale-page.md >/dev/null
json=$(node "$SCRIPT" list --json)
stale_present=$(echo "$json" | grep -c '"path": "wiki/concepts/stale-page.md"' || true)
padding_present=$(echo "$json" | grep -c '"path": "wiki/concepts/padding-1.md"' || true)
assert_eq "scoped page present" "1" "$stale_present"
assert_eq "out-of-scope padding absent" "0" "$padding_present"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
