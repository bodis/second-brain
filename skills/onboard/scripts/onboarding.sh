#!/bin/bash
set -e

# Second Brain — Onboarding Script
# Scaffolds vault directory structure and verifies CLI tooling.
#
# Usage: bash onboarding.sh <vault-path>
# Output: JSON summary to stdout. Progress messages to stderr.

VAULT_ROOT="${1:-.}"

echo "=== Second Brain Onboarding ===" >&2

# 1. Create directory structure
echo "Creating directory structure..." >&2
mkdir -p "$VAULT_ROOT/raw/assets"
mkdir -p "$VAULT_ROOT/wiki/sources"
mkdir -p "$VAULT_ROOT/wiki/entities"
mkdir -p "$VAULT_ROOT/wiki/concepts"
mkdir -p "$VAULT_ROOT/wiki/synthesis"
mkdir -p "$VAULT_ROOT/wiki/.state"
mkdir -p "$VAULT_ROOT/output"
mkdir -p "$VAULT_ROOT/src/documentation"

# CR-002: the state directory must exist as a tracked dir from day one so the
# first ingest's commit doesn't fight with .gitignore semantics on empty dirs.
if [ ! -f "$VAULT_ROOT/wiki/.state/.gitkeep" ]; then
  : > "$VAULT_ROOT/wiki/.state/.gitkeep"
fi

# CR-003: src/documentation/ must exist as a tracked-but-empty directory from
# day one so the first structured ingest doesn't have to create the tree.
if [ ! -f "$VAULT_ROOT/src/documentation/.gitkeep" ]; then
  : > "$VAULT_ROOT/src/documentation/.gitkeep"
fi

# 2. Create wiki/index.md if it doesn't exist
if [ ! -f "$VAULT_ROOT/wiki/index.md" ]; then
  cat > "$VAULT_ROOT/wiki/index.md" << 'EOF'
# Index

Master catalog of all wiki pages. Updated on every ingest.

## Sources

## Entities

## Concepts

## Synthesis
EOF
  echo "Created wiki/index.md" >&2
else
  echo "wiki/index.md already exists, skipping" >&2
fi

# 3. Create wiki/log.md if it doesn't exist
if [ ! -f "$VAULT_ROOT/wiki/log.md" ]; then
  cat > "$VAULT_ROOT/wiki/log.md" << 'EOF'
# Log

Chronological record of all operations.

EOF
  echo "Created wiki/log.md" >&2
else
  echo "wiki/log.md already exists, skipping" >&2
fi

# 4. Check tooling
echo "" >&2
echo "Checking tooling..." >&2

TOOLS_JSON="[]"

check_tool() {
  local name="$1"
  local cmd="$2"
  local install_cmd="$3"
  local status="missing"

  if command -v "$cmd" &> /dev/null; then
    status="installed"
    echo "  [ok] $name" >&2
  else
    echo "  [missing] $name — install with: $install_cmd" >&2
  fi

  TOOLS_JSON=$(echo "$TOOLS_JSON" | python3 -c "
import sys, json
tools = json.load(sys.stdin)
tools.append({'name': '$name', 'status': '$status', 'install': '$install_cmd'})
print(json.dumps(tools))
" 2>/dev/null || echo "$TOOLS_JSON")
}

check_tool "summarize" "summarize" "npm i -g @steipete/summarize"
check_tool "qmd" "qmd" "npm i -g @tobilu/qmd"
check_tool "agent-browser" "agent-browser" "npm i -g agent-browser && agent-browser install"

echo "" >&2
echo "Onboarding complete." >&2

# 5. Output JSON result to stdout
VAULT_ABS=$(cd "$VAULT_ROOT" && pwd)
cat << JSONEOF
{
  "status": "complete",
  "vault_root": "$VAULT_ABS",
  "directories": [
    "raw/",
    "raw/assets/",
    "src/documentation/",
    "wiki/",
    "wiki/sources/",
    "wiki/entities/",
    "wiki/concepts/",
    "wiki/synthesis/",
    "output/"
  ],
  "files": [
    "wiki/index.md",
    "wiki/log.md"
  ],
  "tools": $TOOLS_JSON
}
JSONEOF
