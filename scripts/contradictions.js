#!/usr/bin/env node
'use strict';

/**
 * scripts/contradictions.js — owner of wiki/.state/contradictions.yaml.
 *
 * Subcommands:
 *   candidates --scope <dir-or-page-list> [--json]
 *   list [--status <comma-list>] [--json]
 *   judge --id <id> --verdict <real-contradiction|not-a-contradiction> --data <json>
 *   resolve --id <id> --kind defer
 *   apply-pick --id <id> --winning-page <vault-path> --rewrite <tmpfile>
 *   apply-accept --id <id>
 *
 * Exit codes:
 *   0 = clean
 *   2 = vault not found / malformed yaml / missing required arg / malformed --data /
 *       validate-wiki post-check failure after auto-revert / unsupported subcommand or kind
 *   3 = invariant refusal (invalid lifecycle transition, substring not unique, etc.) —
 *       no mutation occurred
 *
 * Vault detection: walks up for both .git/ and wiki/.state/sources.yaml,
 * matching status.js / validate-wiki.js / review-log.js.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const yaml = require('js-yaml');

const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/contradictions.js';
const STATE_FILE = 'wiki/.state/contradictions.yaml';

function die(msg, code = 2) {
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

// Parse `--flag=value`, `--flag value`, and `--flag` (boolean). Returns
// { _: positional[], <flag>: <value> }. Open-world: unknown flags are
// accumulated into the result so each subcommand can validate its own
// arg set after parsing.
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      if (eq > 0) {
        out[a.slice(2, eq)] = a.slice(eq + 1);
      } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
        out[a.slice(2)] = argv[++i];
      } else {
        out[a.slice(2)] = true;
      }
    } else {
      out._.push(a);
    }
  }
  return out;
}

function readState(vault) {
  const abs = path.join(vault, STATE_FILE);
  if (!fs.existsSync(abs)) return null;
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch (err) { die(`${STATE_FILE} unreadable: ${err.message}`, 2); }
  let doc;
  try { doc = yaml.load(text, { schema: yaml.CORE_SCHEMA }); }
  catch (err) { die(`${STATE_FILE} malformed: ${err.message}`, 2); }
  if (!doc || typeof doc !== 'object') die(`${STATE_FILE} malformed: not a YAML mapping`, 2);
  if (doc.schema_version !== SCHEMA_VERSION) {
    die(`${STATE_FILE} schema_version=${doc.schema_version}, expected ${SCHEMA_VERSION}`, 2);
  }
  if (!Array.isArray(doc.contradictions)) doc.contradictions = [];
  return doc;
}

function emptyState() {
  return {
    schema_version: SCHEMA_VERSION,
    generated_by: GENERATED_BY,
    contradictions: [],
  };
}

function cmdList(vault, args) {
  const doc = readState(vault) || emptyState();
  let entries = doc.contradictions;
  if (args.status) {
    const wanted = String(args.status).split(',').map(s => s.trim()).filter(Boolean);
    entries = entries.filter(e => wanted.includes(e.status));
  }
  if (args.json) {
    const out = Object.assign({}, doc, { contradictions: entries });
    process.stdout.write(JSON.stringify(out, null, 2) + '\n');
    return;
  }
  if (entries.length === 0) {
    process.stdout.write('No contradictions matching filter.\n');
    return;
  }
  // Group by status for the human summary.
  const groups = new Map();
  for (const e of entries) {
    const k = e.status || '(unknown)';
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(e);
  }
  const lines = [];
  lines.push(`${entries.length} entries across ${groups.size} statuses`);
  lines.push('');
  for (const [status, list] of groups) {
    lines.push(`${status} (${list.length}):`);
    for (const e of list) {
      const claim = e.judgment?.claim || '(unjudged)';
      lines.push(`  ${e.id}  ${e.pages.join(' ⟷ ')}  — ${claim}`);
    }
    lines.push('');
  }
  process.stdout.write(lines.join('\n'));
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) die('usage: contradictions.js <subcommand> [args]', 2);
  const cmd = argv[0];
  const args = parseArgs(argv.slice(1));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  switch (cmd) {
    case 'candidates':   die('candidates: not implemented yet', 2);
    case 'list':         return cmdList(vault, args);
    case 'judge':        die('judge: not implemented yet', 2);
    case 'resolve':      die('resolve: not implemented yet', 2);
    case 'apply-pick':   die('apply-pick: not implemented yet', 2);
    case 'apply-accept': die('apply-accept: not implemented yet', 2);
    default:             die(`unknown subcommand: ${cmd}`, 2);
  }
}

main();
