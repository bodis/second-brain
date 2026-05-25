#!/usr/bin/env node
'use strict';

/**
 * scripts/staleness.js — owner of wiki/.state/staleness.yaml.
 *
 * Subcommands:
 *   candidates [--scope <dir|page-list>] [--json]
 *   list [--status <comma-list>] [--signal <comma-list>] [--json]
 *   judge --id <id> --verdict <stale|drifting|fresh-but-isolated|false-positive> --data <json>
 *   resolve --id <id> --kind defer
 *   apply-refresh --id <id> --rewrite <tmpfile>
 *   apply-archive --id <id>
 *   apply-historical --id <id> [--since <YYYY-MM>]
 *   check --pages <comma-list> [--json]
 *
 * Exit codes:
 *   0 = clean
 *   2 = vault not found / malformed yaml / missing required arg / malformed --data /
 *       validate-wiki post-check failure after auto-revert / unsupported subcommand or kind
 *   3 = invariant refusal (invalid lifecycle transition, id not found, etc.) —
 *       no mutation occurred
 *
 * Vault detection: walks up for both .git/ and wiki/.state/sources.yaml,
 * matching contradictions.js / status.js / validate-wiki.js / review-log.js.
 */

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/staleness.js';
const STATE_FILE = 'wiki/.state/staleness.yaml';

function die(msg, code = 2) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(code);
}

function findVaultRoot(start) {
  let dir = path.resolve(start);
  while (true) {
    if (
      fs.existsSync(path.join(dir, '.git')) &&
      fs.existsSync(path.join(dir, 'wiki/.state/sources.yaml'))
    ) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// Lightweight CLI parser: --key value, --key=value, or boolean --flag.
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) {
      out._.push(a);
      continue;
    }
    if (a.includes('=')) {
      const [k, v] = a.slice(2).split('=');
      out[k] = v;
    } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      out[a.slice(2)] = argv[++i];
    } else {
      out[a.slice(2)] = true;
    }
  }
  return out;
}

function cmdCandidates() { die('candidates: not implemented yet', 2); }
function cmdList()       { die('list: not implemented yet', 2); }
function cmdJudge()      { die('judge: not implemented yet', 2); }
function cmdResolve()    { die('resolve: not implemented yet', 2); }
function cmdApplyRefresh(){die('apply-refresh: not implemented yet', 2); }
function cmdApplyArchive(){die('apply-archive: not implemented yet', 2); }
function cmdApplyHistorical(){die('apply-historical: not implemented yet', 2); }
function cmdCheck()      { die('check: not implemented yet', 2); }

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) die('usage: staleness.js <subcommand> [args]', 2);
  const cmd = argv[0];
  const args = parseArgs(argv.slice(1));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  switch (cmd) {
    case 'candidates':       return cmdCandidates(vault, args);
    case 'list':             return cmdList(vault, args);
    case 'judge':            return cmdJudge(vault, args);
    case 'resolve':          return cmdResolve(vault, args);
    case 'apply-refresh':    return cmdApplyRefresh(vault, args);
    case 'apply-archive':    return cmdApplyArchive(vault, args);
    case 'apply-historical': return cmdApplyHistorical(vault, args);
    case 'check':            return cmdCheck(vault, args);
    default:                 die(`unknown subcommand: ${cmd}`, 2);
  }
}

main();
