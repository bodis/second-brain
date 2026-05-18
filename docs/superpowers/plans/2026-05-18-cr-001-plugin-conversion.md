# CR-001 Plugin Conversion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert this repo from an npx-skills package into a Claude Code plugin: add manifests, rename the four skills under a single namespace, drop non-Claude-Code agent support, and teach the onboard wizard to register the plugin in `settings.json` so future sessions auto-load it.

**Architecture:** The repo root becomes the plugin root. A minimal `.claude-plugin/{plugin.json,marketplace.json}` pair makes it loadable via `--plugin-dir` and registrable through `extraKnownMarketplaces` (directory source). The four skill folders are renamed (`second-brain` → `onboard`, `second-brain-{ingest,query,lint}` → `{ingest,query,lint}`) so Claude Code namespaces them as `/second-brain:<name>`. A new deterministic Python script (`skills/onboard/scripts/register-plugin.py`) does the `settings.json` JSON merge for both project-scope and user-scope installs; the wizard calls it instead of hand-editing JSON in prose. Three agent-config templates (codex, cursor, gemini) and the agent-detection branch in the wizard are deleted.

**Tech Stack:** Bash + Python 3 (for the existing `onboarding.sh` and the new `register-plugin.py`), Markdown SKILL.md files with YAML frontmatter, JSON for plugin manifests and Claude Code settings.

**Spec:** [docs/superpowers/specs/2026-05-18-cr-001-plugin-design.md](../specs/2026-05-18-cr-001-plugin-design.md)
**Conventions:** [docs/cr/conventions.md](../../cr/conventions.md)

---

## File Map

**Create:**
- `.claude-plugin/plugin.json` — plugin manifest
- `.claude-plugin/marketplace.json` — single-plugin self-referential catalog
- `docs/install/user-home-settings.json` — copy-paste snippet for Mode U install
- `skills/onboard/scripts/register-plugin.py` — merges plugin keys into a `settings.json`
- `tests/test_register_plugin.sh` — covers the script's merge, idempotency, and error paths

**Rename (git mv):**
- `skills/second-brain/` → `skills/onboard/`
- `skills/second-brain-ingest/` → `skills/ingest/`
- `skills/second-brain-query/` → `skills/query/`
- `skills/second-brain-lint/` → `skills/lint/`

**Delete:**
- `skills/onboard/references/agent-configs/codex.md` (after rename)
- `skills/onboard/references/agent-configs/cursor.md` (after rename)
- `skills/onboard/references/agent-configs/gemini.md` (after rename)

**Modify:**
- `skills/onboard/SKILL.md` — frontmatter `name:`, drop old Step 4, add new Step 4 (settings scope), trim agent-config table to Claude Code only, wire `register-plugin.py` into post-wizard scaffolding, update all `/second-brain-*` slash-command references
- `skills/ingest/SKILL.md` — frontmatter `name: ingest`, namespaced cross-refs
- `skills/query/SKILL.md` — frontmatter `name: query`, namespaced cross-refs
- `skills/lint/SKILL.md` — frontmatter `name: lint`, namespaced cross-refs
- `tests/test_onboarding.sh` — path to onboarding.sh under new skill folder
- `README.md` — Prerequisites, Install section (two modes), skill table, FAQ
- `docs/REQUIREMENTS.md` — drop "Multi-Agent Support" section, drop `npx skills add` mentions
- `.gitignore` — drop the npx-skills install-artifact ignore block (no longer relevant)

---

## Task ordering rationale

1. Manifests first — small, low-risk, lets us smoke-test `claude --plugin-dir .` before any rename.
2. Renames next — single atomic commit; existing tests continue to pass.
3. Touch the three "simple" SKILL.md files (ingest/query/lint) — only frontmatter + a few cross-refs.
4. Delete the three non-Claude-Code templates.
5. Edit `onboard/SKILL.md` body (remove old Step 4, trim references).
6. Add the user-home settings snippet.
7. TDD the `register-plugin.py` script (tests first, then implementation).
8. Wire the script into `onboard/SKILL.md` (new Step 4 + post-wizard step).
9. Rewrite the README install section.
10. Trim `docs/REQUIREMENTS.md`.
11. Final cleanup: drop the obsolete `.gitignore` block, grep for stale references.

---

### Task 1: Add plugin manifest

**Files:**
- Create: `.claude-plugin/plugin.json`

- [ ] **Step 1: Create `.claude-plugin/plugin.json`**

```json
{
  "name": "second-brain",
  "version": "0.1.0",
  "description": "LLM-maintained personal knowledge base for Obsidian. Drop raw sources into a folder; the librarian compiles them into a structured wiki.",
  "author": { "name": "Tamás Bódis" },
  "homepage": "https://github.com/bodis/second-brain",
  "repository": "https://github.com/bodist/second-brain"
}
```

- [ ] **Step 2: Validate the JSON parses**

Run: `python3 -c 'import json; json.load(open(".claude-plugin/plugin.json"))' && echo ok`
Expected: `ok` and no error.

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "feat(plugin): add Claude Code plugin manifest"
```

---

### Task 2: Add marketplace catalog

**Files:**
- Create: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Create `.claude-plugin/marketplace.json`**

```json
{
  "name": "second-brain",
  "owner": { "name": "Tamás Bódis" },
  "plugins": [
    {
      "name": "second-brain",
      "source": "."
    }
  ]
}
```

The `"source": "."` entry means the listed plugin lives at the marketplace root — i.e., the marketplace and the plugin are the same directory.

- [ ] **Step 2: Validate the JSON parses**

Run: `python3 -c 'import json; json.load(open(".claude-plugin/marketplace.json"))' && echo ok`
Expected: `ok`.

- [ ] **Step 3: Smoke-test plugin loads via `--plugin-dir`**

Run: `claude --plugin-dir "$(pwd)" -p '/help' 2>&1 | grep -E 'second-brain' || true`
Expected: at least one line referencing `second-brain` — confirms Claude Code discovered the manifest. (If `claude` isn't on PATH or this is being run by an agent that can't drive an interactive session, skip this step and rely on the manual smoke checklist at the end of the plan.)

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/marketplace.json
git commit -m "feat(plugin): add self-referential marketplace catalog"
```

---

### Task 3: Rename skill directories

We do the four renames in a single commit so the tree is never half-renamed.

**Files:**
- Rename: `skills/second-brain/` → `skills/onboard/`
- Rename: `skills/second-brain-ingest/` → `skills/ingest/`
- Rename: `skills/second-brain-query/` → `skills/query/`
- Rename: `skills/second-brain-lint/` → `skills/lint/`
- Modify: `tests/test_onboarding.sh:9` (the `ONBOARDING=` line)

- [ ] **Step 1: Rename the four skill folders**

```bash
git mv skills/second-brain skills/onboard
git mv skills/second-brain-ingest skills/ingest
git mv skills/second-brain-query skills/query
git mv skills/second-brain-lint skills/lint
```

- [ ] **Step 2: Update the onboarding-test path**

Edit `tests/test_onboarding.sh` line 9. Change:

```bash
ONBOARDING="$REPO_ROOT/skills/second-brain/scripts/onboarding.sh"
```

to:

```bash
ONBOARDING="$REPO_ROOT/skills/onboard/scripts/onboarding.sh"
```

- [ ] **Step 3: Run the existing test, expect pass**

Run: `bash tests/test_onboarding.sh`
Expected: ends with `Results: N passed, 0 failed` and exit 0. Nothing else in this task should have broken it.

- [ ] **Step 4: Commit**

```bash
git add skills tests/test_onboarding.sh
git commit -m "refactor(skills): rename skill dirs to plugin namespace layout"
```

---

### Task 4: Update `ingest/SKILL.md`, `query/SKILL.md`, `lint/SKILL.md`

Three near-identical edits per file: bump `name:` frontmatter, and replace bare `/second-brain-*` slash-command mentions with namespaced `/second-brain:*` form. Onboard's bigger rewrite gets its own task.

**Files:**
- Modify: `skills/ingest/SKILL.md` (frontmatter line 2; in-prose references to other skills)
- Modify: `skills/query/SKILL.md` (frontmatter line 2; in-prose references to other skills)
- Modify: `skills/lint/SKILL.md` (frontmatter line 2; in-prose references to other skills)

- [ ] **Step 1: Edit `skills/ingest/SKILL.md` frontmatter**

Change line 2 from `name: second-brain-ingest` to `name: ingest`.

- [ ] **Step 2: Update slash-command references in `skills/ingest/SKILL.md`**

In the "What's Next" section near the end, replace:
- `/second-brain-query` → `/second-brain:query`
- `/second-brain-lint` → `/second-brain:lint`
- `/second-brain-ingest` (if it appears) → `/second-brain:ingest`

- [ ] **Step 3: Edit `skills/query/SKILL.md` frontmatter**

Change line 2 from `name: second-brain-query` to `name: query`.

- [ ] **Step 4: Update slash-command references in `skills/query/SKILL.md`**

In the "Related Skills" section, replace:
- `/second-brain-ingest` → `/second-brain:ingest`
- `/second-brain-lint` → `/second-brain:lint`

- [ ] **Step 5: Edit `skills/lint/SKILL.md` frontmatter**

Change line 2 from `name: second-brain-lint` to `name: lint`.

- [ ] **Step 6: Update slash-command references in `skills/lint/SKILL.md`**

In the "Related Skills" section, replace:
- `/second-brain-ingest` → `/second-brain:ingest`
- `/second-brain-query` → `/second-brain:query`

- [ ] **Step 7: Verify no `/second-brain-*` bare references remain in those three files**

Run: `grep -nE '/second-brain-(ingest|query|lint)\b' skills/ingest/SKILL.md skills/query/SKILL.md skills/lint/SKILL.md || echo clean`
Expected: `clean`.

- [ ] **Step 8: Commit**

```bash
git add skills/ingest/SKILL.md skills/query/SKILL.md skills/lint/SKILL.md
git commit -m "refactor(skills): rename ingest/query/lint to plugin namespace"
```

---

### Task 5: Delete non-Claude-Code agent config templates

**Files:**
- Delete: `skills/onboard/references/agent-configs/codex.md`
- Delete: `skills/onboard/references/agent-configs/cursor.md`
- Delete: `skills/onboard/references/agent-configs/gemini.md`

- [ ] **Step 1: Delete the three template files**

```bash
git rm skills/onboard/references/agent-configs/codex.md \
       skills/onboard/references/agent-configs/cursor.md \
       skills/onboard/references/agent-configs/gemini.md
```

- [ ] **Step 2: Confirm only `claude-code.md` remains**

Run: `ls skills/onboard/references/agent-configs/`
Expected: `claude-code.md` (only).

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(plugin): drop non-Claude-Code agent config templates"
```

---

### Task 6: First-pass edit of `onboard/SKILL.md` — frontmatter, agent-config removal, namespaced references

This task removes the *old* Step 4 (agent config) and trims the post-wizard scaffolding. Task 9 inserts the *new* Step 4 (settings scope) and the `register-plugin.py` invocation; we split it because the script doesn't exist yet.

**Files:**
- Modify: `skills/onboard/SKILL.md` (whole file)

- [ ] **Step 1: Update frontmatter `name`**

Change line 2 from `name: second-brain` to `name: onboard`.

- [ ] **Step 2: Replace the "Wizard Flow" intro**

The existing intro says "Guide the user through these 5 steps." Keep that sentence — the step count is unchanged after Task 9. No edit needed in this step, just confirm the surrounding text still reads correctly after later edits.

- [ ] **Step 3: Delete the entire `### Step 4: Agent Config` subsection**

Delete from the line `### Step 4: Agent Config` through the end of the "Agent detection logic:" bullet list (currently lines 47–61). Replace it with a temporary placeholder line so the step numbering still flows:

```markdown
### Step 4: (settings scope — added in Task 9)
```

We replace this placeholder with the real Step 4 content in Task 9.

- [ ] **Step 4: Trim the "Generate agent config file(s)" table to Claude Code only**

Under the post-wizard "### 2. Generate agent config file(s)" section, replace the four-row table with a single deterministic instruction:

```markdown
### 2. Generate the agent config file

Read the template at `<skill-directory>/references/agent-configs/claude-code.md` and write the generated config to `<vault>/CLAUDE.md`.

Replace these placeholders:

- `{{VAULT_NAME}}` — the vault name from Step 1
- `{{DOMAIN_DESCRIPTION}}` — a one-line description derived from Step 3
- `{{DOMAIN_TAGS}}` — generate 5–8 domain-relevant tags as a bullet list based on the domain from Step 3
- `{{WIKI_SCHEMA}}` — read `<skill-directory>/references/wiki-schema.md` and insert everything from `## Architecture` onward
```

State this as a non-question status line; no prompt to pick agents.

- [ ] **Step 5: Trim the "Reference Files" listing**

Replace the four-line agent-configs sub-list with a single line:

```markdown
- `agent-configs/claude-code.md` — CLAUDE.md template
```

Keep the `wiki-schema.md` and `tooling.md` entries unchanged.

- [ ] **Step 6: Update all in-prose slash-command references**

Replace every `/second-brain-ingest`, `/second-brain-query`, `/second-brain-lint`, and `/second-brain` mention in `onboard/SKILL.md` with its namespaced equivalent:
- `/second-brain-ingest` → `/second-brain:ingest`
- `/second-brain-query` → `/second-brain:query`
- `/second-brain-lint` → `/second-brain:lint`
- bare `/second-brain` (if it refers to the onboarding wizard) → `/second-brain:onboard`

- [ ] **Step 7: Verify no stale slash-command tokens remain**

Run: `grep -nE '/second-brain-(ingest|query|lint)\b' skills/onboard/SKILL.md || echo clean`
Expected: `clean`.

- [ ] **Step 8: Commit**

```bash
git add skills/onboard/SKILL.md
git commit -m "refactor(onboard): drop agent-config branch, namespace slash commands"
```

---

### Task 7: Add user-home settings snippet

**Files:**
- Create: `docs/install/user-home-settings.json`

- [ ] **Step 1: Create the snippet file**

```json
{
  "extraKnownMarketplaces": {
    "second-brain": {
      "source": {
        "source": "directory",
        "path": "/absolute/path/to/second-brain"
      }
    }
  },
  "enabledPlugins": {
    "second-brain@second-brain": true
  }
}
```

The README points users at this file and tells them to replace `/absolute/path/to/second-brain` with the actual clone path.

- [ ] **Step 2: Validate the JSON parses**

Run: `python3 -c 'import json; json.load(open("docs/install/user-home-settings.json"))' && echo ok`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add docs/install/user-home-settings.json
git commit -m "docs(install): add user-home settings.json snippet for Mode U"
```

---

### Task 8: Write failing tests for `register-plugin.py`

The script (Task 9) merges two well-known keys (`extraKnownMarketplaces.second-brain` and `enabledPlugins["second-brain@second-brain"]`) into a target `settings.json`. Test-first.

**Files:**
- Create: `tests/test_register_plugin.sh`

- [ ] **Step 1: Create the test harness**

```bash
#!/bin/bash
set -e

# Test: register-plugin.py merges plugin registration into settings.json correctly.
# Usage: bash tests/test_register_plugin.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTER="$REPO_ROOT/skills/onboard/scripts/register-plugin.py"
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

json_get() {
  # $1 = file, $2 = python expression on `d`
  python3 -c "import json,sys; d=json.load(open('$1')); print($2)"
}

echo "=== Test: register-plugin.py ==="

# Test 1: Fresh write — target file and parent dir don't exist yet.
echo ""
echo "Test 1: Fresh write into nonexistent target"
VAULT1="$TEST_DIR/vault1"
mkdir -p "$VAULT1"
python3 "$REGISTER" --scope project --vault "$VAULT1"
assert_eq "settings.json exists"            "yes" "$([ -f "$VAULT1/.claude/settings.json" ] && echo yes || echo no)"
assert_eq "enabledPlugins flag is true"     "True" "$(json_get "$VAULT1/.claude/settings.json" "d['enabledPlugins']['second-brain@second-brain']")"
assert_eq "source type is directory"        "directory" "$(json_get "$VAULT1/.claude/settings.json" "d['extraKnownMarketplaces']['second-brain']['source']['source']")"
assert_eq "path is absolute"                "True" "$(json_get "$VAULT1/.claude/settings.json" "str(d['extraKnownMarketplaces']['second-brain']['source']['path'].startswith('/'))")"

# Test 2: Merge — preserves unrelated keys.
echo ""
echo "Test 2: Merge preserves unrelated keys"
VAULT2="$TEST_DIR/vault2"
mkdir -p "$VAULT2/.claude"
cat > "$VAULT2/.claude/settings.json" <<EOF
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "enabledPlugins": { "other-plugin@other-mkt": true }
}
EOF
python3 "$REGISTER" --scope project --vault "$VAULT2"
assert_eq "unrelated permissions preserved"   "True" "$(json_get "$VAULT2/.claude/settings.json" "d['permissions']['allow'] == ['Bash(ls:*)']")"
assert_eq "other-plugin still enabled"        "True" "$(json_get "$VAULT2/.claude/settings.json" "d['enabledPlugins']['other-plugin@other-mkt']")"
assert_eq "second-brain plugin added"         "True" "$(json_get "$VAULT2/.claude/settings.json" "d['enabledPlugins']['second-brain@second-brain']")"

# Test 3: Idempotent — running twice produces identical content.
echo ""
echo "Test 3: Idempotency"
VAULT3="$TEST_DIR/vault3"
mkdir -p "$VAULT3"
python3 "$REGISTER" --scope project --vault "$VAULT3"
HASH1=$(shasum "$VAULT3/.claude/settings.json" | cut -d' ' -f1)
python3 "$REGISTER" --scope project --vault "$VAULT3"
HASH2=$(shasum "$VAULT3/.claude/settings.json" | cut -d' ' -f1)
assert_eq "two runs produce same file"       "$HASH1" "$HASH2"

# Test 4: Malformed JSON — exits non-zero and does NOT overwrite the file.
echo ""
echo "Test 4: Malformed JSON aborts cleanly"
VAULT4="$TEST_DIR/vault4"
mkdir -p "$VAULT4/.claude"
echo "{ this is not json" > "$VAULT4/.claude/settings.json"
ORIG_CONTENT=$(cat "$VAULT4/.claude/settings.json")
set +e
python3 "$REGISTER" --scope project --vault "$VAULT4" 2>/dev/null
EXITCODE=$?
set -e
NEW_CONTENT=$(cat "$VAULT4/.claude/settings.json")
assert_eq "script exited non-zero"           "True" "$([ "$EXITCODE" -ne 0 ] && echo True || echo False)"
assert_eq "file content untouched"           "$ORIG_CONTENT" "$NEW_CONTENT"

# Test 5: User scope — writes to ~/.claude/settings.json via overridden HOME.
echo ""
echo "Test 5: User-scope writes under \$HOME/.claude/settings.json"
FAKE_HOME="$TEST_DIR/fakehome"
mkdir -p "$FAKE_HOME"
HOME="$FAKE_HOME" python3 "$REGISTER" --scope user
assert_eq "user settings.json exists"        "yes" "$([ -f "$FAKE_HOME/.claude/settings.json" ] && echo yes || echo no)"
assert_eq "user-scope enabledPlugins set"    "True" "$(json_get "$FAKE_HOME/.claude/settings.json" "d['enabledPlugins']['second-brain@second-brain']")"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/test_register_plugin.sh
```

- [ ] **Step 3: Run the tests — expect failure (script doesn't exist yet)**

Run: `bash tests/test_register_plugin.sh`
Expected: every test fails (likely with "No such file or directory" for the script). Confirm the failures come from the script being missing, not from a bug in the test harness itself.

- [ ] **Step 4: Commit the failing test**

```bash
git add tests/test_register_plugin.sh
git commit -m "test(register-plugin): add failing tests for settings.json merge"
```

---

### Task 9: Implement `register-plugin.py`

**Files:**
- Create: `skills/onboard/scripts/register-plugin.py`

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/env python3
"""Register the second-brain plugin into a Claude Code settings.json.

The script is self-locating: it walks up from its own __file__ to find the
plugin root (the directory containing .claude-plugin/plugin.json) and uses
that absolute path as the `directory` source.

Usage:
    register-plugin.py --scope project --vault <abs-path-to-vault>
    register-plugin.py --scope user

For --scope project, writes/merges <vault>/.claude/settings.json.
For --scope user,    writes/merges $HOME/.claude/settings.json.

Existing values for `extraKnownMarketplaces.second-brain` and
`enabledPlugins["second-brain@second-brain"]` are overwritten. Every other
key in the file is preserved. Malformed JSON in the target file is a fatal
error — the script exits non-zero and does NOT touch the file.
"""

import argparse
import json
import os
import sys
from pathlib import Path

PLUGIN_NAME = "second-brain"
MARKETPLACE_NAME = "second-brain"
ENABLED_KEY = f"{PLUGIN_NAME}@{MARKETPLACE_NAME}"


def find_plugin_root(start: Path) -> Path:
    for candidate in [start, *start.parents]:
        if (candidate / ".claude-plugin" / "plugin.json").is_file():
            return candidate
    sys.exit(
        f"error: could not find .claude-plugin/plugin.json walking up from {start}"
    )


def target_settings_path(scope: str, vault: str | None) -> Path:
    if scope == "project":
        if not vault:
            sys.exit("error: --vault is required when --scope=project")
        return Path(vault).expanduser().resolve() / ".claude" / "settings.json"
    if scope == "user":
        return Path(os.environ.get("HOME", str(Path.home()))) / ".claude" / "settings.json"
    sys.exit(f"error: unknown scope {scope!r}")


def load_existing(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with path.open("r") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        sys.exit(f"error: {path} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        sys.exit(f"error: {path} top-level value must be a JSON object")
    return data


def merge(settings: dict, plugin_path: Path) -> dict:
    mkts = settings.setdefault("extraKnownMarketplaces", {})
    mkts[MARKETPLACE_NAME] = {
        "source": {"source": "directory", "path": str(plugin_path)}
    }
    enabled = settings.setdefault("enabledPlugins", {})
    enabled[ENABLED_KEY] = True
    return settings


def write_atomically(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=["project", "user"], required=True)
    parser.add_argument("--vault", help="vault root (required when --scope=project)")
    args = parser.parse_args()

    plugin_root = find_plugin_root(Path(__file__).resolve())
    target = target_settings_path(args.scope, args.vault)
    settings = load_existing(target)
    merged = merge(settings, plugin_root)
    write_atomically(target, merged)
    print(f"wrote {target}", file=sys.stderr)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x skills/onboard/scripts/register-plugin.py
```

- [ ] **Step 3: Run the tests — expect pass**

Run: `bash tests/test_register_plugin.sh`
Expected: every test passes, ending with `Results: N passed, 0 failed` and exit 0.

- [ ] **Step 4: Commit**

```bash
git add skills/onboard/scripts/register-plugin.py
git commit -m "feat(onboard): add register-plugin.py for settings.json merge"
```

---

### Task 10: Insert new Step 4 (settings scope) into `onboard/SKILL.md`

Now that `register-plugin.py` exists and is tested, wire the wizard to it.

**Files:**
- Modify: `skills/onboard/SKILL.md` (replace the temporary Step 4 placeholder; add a post-wizard call to the script)

- [ ] **Step 1: Replace the Step 4 placeholder with the real step**

Find the line inserted in Task 6 (`### Step 4: (settings scope — added in Task 9)`) and replace it with:

```markdown
### Step 4: Settings Scope

Ask:
> "Where should I register this plugin so it auto-loads next time?"
>
> (a) Just this vault → writes `<vault>/.claude/settings.json` *(default)*
> (b) All my projects → merges into `~/.claude/settings.json`
> (c) Skip — I'll handle this manually
```

- [ ] **Step 2: Add a new post-wizard scaffolding subsection that runs the script**

In the "Post-Wizard: Scaffold the Vault" section, after the existing "### 1. Create directory structure" and "### 2. Generate the agent config file", insert a new subsection (and renumber the rest):

```markdown
### 3. Register the plugin in settings.json

Use the user's answer from Step 4:

- If (a) Just this vault — run:
  `python3 <skill-directory>/scripts/register-plugin.py --scope project --vault <vault-path>`
- If (b) All my projects — run:
  `python3 <skill-directory>/scripts/register-plugin.py --scope user`
- If (c) Skip — print the two snippets below so the user can register manually later:
  - Project-scope: contents of the registration block with the plugin's absolute path filled in, to be merged into `<vault>/.claude/settings.json`
  - User-scope: the contents of `docs/install/user-home-settings.json` (point them at the file path)

The script is idempotent — running it again on a future onboarding pass is safe.
```

- [ ] **Step 3: Renumber the remaining post-wizard subsections**

The current "### 3. Update wiki/log.md", "### 4. Install CLI tools (if selected)", "### 5. Print summary" become 4, 5, 6 respectively. Update the headings and any internal cross-references (e.g., "in Step 5" if it appears).

- [ ] **Step 4: Add the new script to the "Reference Files" listing**

Under the "Reference Files" section, add an entry for the script (so future readers know it ships with the skill):

```markdown
- `scripts/register-plugin.py` — merges plugin registration into a Claude Code settings.json (used by Step 4)
```

- [ ] **Step 5: Manual sanity-check the SKILL.md reads end-to-end**

Re-read `skills/onboard/SKILL.md` top to bottom. Look for: dangling placeholder lines, broken section numbering, references to removed templates. Fix any inline.

- [ ] **Step 6: Commit**

```bash
git add skills/onboard/SKILL.md
git commit -m "feat(onboard): wire wizard to register-plugin.py for settings scope"
```

---

### Task 11: Rewrite `README.md`

The README install section is the user's entry point. Replace `npx skills add` with the two-mode plugin install, update prerequisites and the skill table, and trim the multi-agent FAQ entry.

**Files:**
- Modify: `README.md` (Prerequisites, Install, skill table, Quick Start step 2, FAQ)

- [ ] **Step 1: Update Prerequisites**

Replace lines 13–17 with:

```markdown
## Prerequisites

- **[Obsidian](https://obsidian.md)** — the markdown editor you'll browse your wiki in
- **[Claude Code](https://claude.ai/code)** — the AI coding agent that reads sources and maintains the wiki
```

Drop the Node.js bullet — Node is only needed for the optional CLI tools (`summarize`, `qmd`, `agent-browser`), not the plugin itself. The Optional Tools section already documents that.

- [ ] **Step 2: Replace the Install section**

Replace lines 19–33 (the `npx skills add` block and the skill table) with:

````markdown
## Install

Two install modes — pick whichever fits.

### Option A — Per-vault install (project-scope)

```bash
# 1. From inside the directory that will become your vault:
git clone https://github.com/bodist/second-brain.git .claude/plugins/second-brain

# 2. One-time bootstrap to launch the wizard:
claude --plugin-dir .claude/plugins/second-brain
# Then in the Claude Code session, run:
/second-brain:onboard

# 3. The wizard scaffolds the vault AND writes .claude/settings.json so
#    future sessions auto-load the plugin. From then on, just:
cd <vault> && claude
```

### Option B — User-wide install

```bash
# 1. Clone once to your home dir:
git clone https://github.com/bodist/second-brain.git ~/.claude/plugins/second-brain

# 2. Merge the snippet from docs/install/user-home-settings.json into
#    ~/.claude/settings.json (adjust the "path" field to your absolute path).

# 3. From any directory:
claude
/second-brain:onboard
```

This installs four skills under the `second-brain:` namespace:

| Skill | What it does |
|---|---|
| `/second-brain:onboard` | Set up a new vault (guided wizard) |
| `/second-brain:ingest` | Process raw sources into wiki pages |
| `/second-brain:query` | Ask questions against your wiki |
| `/second-brain:lint` | Health-check the wiki |
````

- [ ] **Step 3: Update Quick Start step 2 and step 5**

In the Quick Start section, replace:
- Step 2 `/second-brain` → `/second-brain:onboard`
- Step 5 `/second-brain-ingest` → `/second-brain:ingest`
- Step 7 `/second-brain-query` → `/second-brain:query`; `/second-brain-lint` → `/second-brain:lint`

- [ ] **Step 4: Update the FAQ**

In the FAQ section:
- Replace `Run /second-brain again` with `Run /second-brain:onboard again`.
- Replace `Run /second-brain-lint` (two occurrences) with `Run /second-brain:lint`.
- Delete the entire "Can I use this with multiple AI agents?" Q&A. Its content (multi-agent support) was removed in this CR.

- [ ] **Step 5: Verify the README has no stale slash-command references**

Run: `grep -nE '/second-brain-(ingest|query|lint)\b|/second-brain\b(?!:)' README.md || echo clean`
(The `(?!:)` is a perl-style negative lookahead; if your `grep` lacks `-P`, run two passes: one for the hyphenated forms, one to manually eyeball `/second-brain ` mentions.)
Expected: `clean` after both passes.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs(readme): rewrite install for plugin modes, namespace skills"
```

---

### Task 12: Trim `docs/REQUIREMENTS.md`

**Files:**
- Modify: `docs/REQUIREMENTS.md` (Multi-Agent Support section; npx mentions)

- [ ] **Step 1: Replace the "MULTI-AGENT SUPPORT" section**

Replace lines 72–78 (the `## MULTI-AGENT SUPPORT` heading and its body) with:

```markdown
## MULTI-AGENT SUPPORT

The wiki pattern itself is agent-agnostic — it's just markdown files and conventions, and the same rules work in any agent config file. This fork, however, ships as a Claude Code plugin and removes the Codex / Cursor / Gemini config templates that the upstream project carried. If you want to drive the same vault with a different agent, the wiki schema in `skills/onboard/references/wiki-schema.md` is reusable; you'd hand-author the equivalent `AGENTS.md` / `.cursor/rules` / `GEMINI.md` from it.
```

- [ ] **Step 2: Remove the `npx skills add` mention**

In the opening paragraph (line 3), replace:
> just install our implementation via `npx skills add` (see README.md)

with:
> just install our implementation as a Claude Code plugin (see README.md)

- [ ] **Step 3: Update the skill-references path**

On line 68 (or wherever the file references the skill folder), update `skills/second-brain/references/wiki-schema.md` to `skills/onboard/references/wiki-schema.md`.

- [ ] **Step 4: Final grep — no stale skill paths in REQUIREMENTS.md**

Run: `grep -nE 'skills/second-brain(-ingest|-query|-lint)?\b|npx skills add' docs/REQUIREMENTS.md || echo clean`
Expected: `clean`.

- [ ] **Step 5: Commit**

```bash
git add docs/REQUIREMENTS.md
git commit -m "docs(requirements): drop multi-agent support, update skill paths"
```

---

### Task 13: Drop obsolete `.gitignore` block and run final cross-repo grep

The current `.gitignore` ignores a large block of agent skill folders left behind by `npx skills add` installs (`.codex/`, `.cursor/`, etc.). Since the install path is no longer `npx`, that block is dead weight.

**Files:**
- Modify: `.gitignore` (remove the npx-skills install-artifacts block + `skills-lock.json`)

- [ ] **Step 1: Edit `.gitignore`**

Open `.gitignore` and delete the entire block starting with the comment `# npx skills install artifacts` through and including the `skills-lock.json` line. Keep the generic ignores (`.DS_Store`, `node_modules/`, `*.swp`, `*.swo`, `*~`, `.env*`, `*.pem`, `*.key`, `credentials*`).

Keep `.claude/` in the ignore list **only if** the project doesn't want its own `.claude/` settings tracked at the repo root. Since CR-001 doesn't ship any repo-root `.claude/` files, the `.claude/` line can stay ignored — but make sure it's *not* ignoring `.claude-plugin/` (different path, different file globbing semantics — `.gitignore` matches a leading dot literally).

- [ ] **Step 2: Verify `.claude-plugin/` is NOT ignored**

Run: `git check-ignore -v .claude-plugin/plugin.json || echo not-ignored`
Expected: `not-ignored`. (If git reports an ignore rule, the `.gitignore` edit needs to be more specific — make the rule `.claude` exact, not a prefix match.)

- [ ] **Step 3: Final repo-wide grep for stale references**

Run:

```bash
grep -rnE '/second-brain-(ingest|query|lint)\b|npx skills add|second-brain-(ingest|query|lint)\b' \
  --include='*.md' --include='*.sh' --include='*.json' . \
  | grep -v '^docs/cr/' \
  | grep -v '^docs/superpowers/' \
  || echo clean
```

(We exclude `docs/cr/` and `docs/superpowers/` because the CR backlog docs and the spec/plan archive intentionally contain historical references — they document the migration.)

Expected: `clean`. Anything else is a stale reference to fix before committing.

- [ ] **Step 4: Run the full test suite**

```bash
bash tests/test_onboarding.sh
bash tests/test_register_plugin.sh
```

Expected: both end with `Results: N passed, 0 failed` and exit 0.

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: drop npx-skills install-artifact ignores"
```

---

## Manual smoke checklist (run once before merging)

These cannot be automated from inside the plan; the implementing engineer (or user) runs them by hand from a real terminal after Task 13 commits.

1. **Plugin loads.** From a clean temp directory, run `claude --plugin-dir <repo>` and confirm `/help` lists the four `second-brain:*` skills.
2. **Mode P bootstrap.** In an empty temp directory, run `claude --plugin-dir <repo>` then `/second-brain:onboard` with all defaults. Confirm:
   - `raw/`, `wiki/`, `output/`, `wiki/index.md`, `wiki/log.md`, `CLAUDE.md` exist.
   - `.claude/settings.json` is written and contains `extraKnownMarketplaces.second-brain` + `enabledPlugins["second-brain@second-brain"]: true`.
3. **Mode P auto-load.** Exit Claude Code, `cd` back into the temp vault, run `claude` (no `--plugin-dir` flag). Confirm `/second-brain:*` skills are available.
4. **Mode U merge.** Pre-populate `~/.claude/settings.json` with an unrelated key (in a backup-and-restore wrapper to avoid clobbering the user's real config!), run the wizard with option (b), and confirm only the two plugin keys are added; the unrelated key is untouched. **Strongly recommended:** do this test with `HOME=$(mktemp -d)` set so a real `~/.claude/settings.json` is never at risk.
5. **Mode U auto-load.** From a directory with no `.claude/settings.json`, confirm the plugin still loads (skip if the previous Mode U test was done with a fake `HOME`; in that case manually wire a real one-off install to verify).
6. **No stale references.** Re-run the final grep from Task 13 step 3 and confirm it still prints `clean`.

---

## Self-review summary

**Spec coverage:**
- §4 Target architecture — Tasks 1, 2, 3, 5, 7 + final renumber.
- §4.1 Skill rename map — Task 3.
- §4.2 Files to delete — Task 5.
- §4.3 onboard SKILL.md edits — Tasks 6 and 10 (split because the script doesn't exist yet in Task 6).
- §4.4 ingest/query/lint frontmatter edits — Task 4.
- §4.5 REQUIREMENTS.md edits — Task 12.
- §4.6 README.md edits — Task 11.
- §5 Manifests — Tasks 1, 2.
- §6 Install modes — Tasks 7 (snippet), 9 (script), 10 (wizard wiring).
- §7 Data flow — no change in runtime behavior; covered by smoke checklist.
- §8 README install rewrite — Task 11.
- §9.1 Automated tests — Task 3 (onboarding test still passes), Tasks 8+9 (register-plugin tests).
- §9.2 Manual smoke checklist — listed verbatim at the end.
- §10 Risks — informational; nothing to implement.

**Placeholder scan:** I re-read every step. The only intentional "placeholder" is the Step 4 marker inserted in Task 6 step 3 (`### Step 4: (settings scope — added in Task 9)`) which Task 10 step 1 replaces. No TBDs, no `add appropriate error handling`, every code/JSON block is complete.

**Type / name consistency:**
- `register-plugin.py` argument names (`--scope`, `--vault`) match between Task 8 tests and Task 9 implementation.
- `extraKnownMarketplaces.second-brain` and `enabledPlugins["second-brain@second-brain"]` are spelled identically in the snippet (Task 7), the script (Task 9), and the smoke checklist.
- Skill folder names `onboard`, `ingest`, `query`, `lint` agree everywhere — including the `name:` frontmatter (Tasks 4 & 6) and the slash-command examples in README/SKILL.md.
- Plugin name in `plugin.json` (`second-brain`) matches the namespace used in every `/second-brain:<skill>` reference.
