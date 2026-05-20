#!/usr/bin/env node
'use strict';

/**
 * scripts/validate-wiki.js — wiki structural validator.
 *
 * Subcommands: frontmatter | wikilinks | index | all
 * Each subcommand supports --json for machine consumers.
 *
 * Exit codes (shared across subcommands):
 *   0 = clean
 *   1 = warnings (broken link, orphan page, missing index row)
 *   2 = structural error (frontmatter invalid, dead index row, contract mismatch)
 *
 * Vault detection: walks up from CLAUDE_PROJECT_DIR (or cwd) for a directory
 * containing both `.git/` and `wiki/.state/sources.yaml`. If none found, exits
 * 0 silently — this is how the universally-fired Stop hook self-gates outside
 * second-brain vaults.
 *
 * `all` honors `stop_hook_active: true` on stdin per Claude Code hook docs.
 */

const fs = require('fs');
const path = require('path');

const SUBCOMMANDS = ['frontmatter', 'wikilinks', 'index', 'all'];

function die(msg, code = 1) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(code);
}

function findVaultRoot(start) {
  let dir = path.resolve(start);
  while (true) {
    const hasGit = fs.existsSync(path.join(dir, '.git'));
    const hasState = fs.existsSync(path.join(dir, 'wiki', '.state', 'sources.yaml'));
    if (hasGit && hasState) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function parseArgs(argv) {
  const cmd = argv[0];
  let json = false;
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === '--json') json = true;
    else die(`unknown argument: ${argv[i]}`);
  }
  return { cmd, json };
}

// Read stdin synchronously and return a parsed JSON object, or {} if nothing
// was piped. Only called from `all` to honor the stop_hook_active guard.
function readStdinJson() {
  if (process.stdin.isTTY) return {};
  try {
    const raw = fs.readFileSync(0, 'utf8');
    if (!raw.trim()) return {};
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function runAll(_vault, _json) {
  // Stub — Task 7 fills this in by composing the three subcommands.
  return { code: 0, output: '' };
}

function runFrontmatter(_vault, _json) {
  // Stub — Task 4 fills this in.
  return { code: 0, output: '' };
}

function runWikilinks(_vault, _json) {
  // Stub — Task 5 fills this in.
  return { code: 0, output: '' };
}

function runIndex(_vault, _json) {
  // Stub — Task 6 fills this in.
  return { code: 0, output: '' };
}

function emit(result) {
  if (result.output) process.stdout.write(result.output);
  process.exit(result.code);
}

function main() {
  const { cmd, json } = parseArgs(process.argv.slice(2));
  if (!SUBCOMMANDS.includes(cmd)) {
    die(`unknown subcommand: ${cmd}; expected one of ${SUBCOMMANDS.join(', ')}`, 1);
  }

  const startDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const vault = findVaultRoot(startDir);
  if (!vault) {
    // Not a second-brain vault — exit 0 silently. This is the Stop hook
    // self-gate: the hook fires globally, but no work happens outside a vault.
    process.exit(0);
  }

  if (cmd === 'all') {
    const stdin = readStdinJson();
    if (stdin.stop_hook_active === true) process.exit(0);
    return emit(runAll(vault, json));
  }
  if (cmd === 'frontmatter') return emit(runFrontmatter(vault, json));
  if (cmd === 'wikilinks') return emit(runWikilinks(vault, json));
  if (cmd === 'index') return emit(runIndex(vault, json));
}

main();
