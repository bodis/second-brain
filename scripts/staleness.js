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

function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function readState(vault) {
  const abs = path.join(vault, STATE_FILE);
  if (!fs.existsSync(abs)) return null;
  let doc;
  try {
    doc = yaml.load(fs.readFileSync(abs, 'utf8'), { schema: yaml.CORE_SCHEMA });
  } catch (e) {
    die(`failed to parse ${STATE_FILE}: ${e.message}`, 2);
  }
  if (!doc || typeof doc !== 'object') die(`${STATE_FILE} is not a YAML mapping`, 2);
  if (doc.schema_version !== SCHEMA_VERSION) {
    die(`${STATE_FILE} schema_version is ${doc.schema_version}, expected ${SCHEMA_VERSION}`, 2);
  }
  if (!Array.isArray(doc.pages)) doc.pages = [];
  return doc;
}

// Atomic write: tmpfile + rename.
function writeState(vault, doc) {
  doc.schema_version = SCHEMA_VERSION;
  doc.generated_by = GENERATED_BY;
  const abs = path.join(vault, STATE_FILE);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  const tmp = `${abs}.tmp.${process.pid}.${Date.now()}`;
  const out = yaml.dump(doc, { indent: 2, sortKeys: false, lineWidth: -1 });
  fs.writeFileSync(tmp, out);
  fs.renameSync(tmp, abs);
}

function todayDateStr() {
  return new Date().toISOString().slice(0, 10);
}

// Allocate the next id for today, given the existing entries (any date).
// Format: YYYY-MM-DD-NNN. NNN zero-padded to 3 digits.
function allocateId(existingEntries) {
  const today = todayDateStr();
  let maxN = 0;
  for (const e of existingEntries) {
    if (!e || !e.id) continue;
    const m = /^(\d{4}-\d{2}-\d{2})-(\d{3})$/.exec(e.id);
    if (!m) continue;
    if (m[1] !== today) continue;
    const n = parseInt(m[2], 10);
    if (n > maxN) maxN = n;
  }
  return `${today}-${String(maxN + 1).padStart(3, '0')}`;
}

function findEntry(doc, id) {
  return (doc.pages || []).find((e) => e && e.id === id) || null;
}

function cmdCandidates() { die('candidates: not implemented yet', 2); }

function parseCommaList(v) {
  if (!v || v === true) return null;
  return String(v).split(',').map((s) => s.trim()).filter(Boolean);
}

function cmdList(vault, args) {
  const doc = readState(vault);
  const all = doc ? (doc.pages || []) : [];
  const statusFilter = parseCommaList(args.status);
  const signalFilter = parseCommaList(args.signal);
  const filtered = all.filter((e) => {
    if (!e) return false;
    if (statusFilter && !statusFilter.includes(e.status)) return false;
    if (signalFilter && !signalFilter.includes(e.signal)) return false;
    return true;
  });
  if (args.json) {
    process.stdout.write(JSON.stringify({ pages: filtered }, null, 2) + '\n');
    return;
  }
  if (filtered.length === 0) {
    process.stdout.write('(no entries)\n');
    return;
  }
  for (const e of filtered) {
    process.stdout.write(`${e.id}\t${e.path}\t${e.status}\t${e.signal}\n`);
  }
}
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
