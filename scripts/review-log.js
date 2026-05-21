#!/usr/bin/env node
'use strict';

/**
 * scripts/review-log.js — owner of wiki/.state/since-review.yaml.
 *
 * Subcommands:
 *   append --kind=<kind> --data=<json>  Append one change entry.
 *   show [--json]                       Print the current inbox (grouped or raw).
 *   accept                              Truncate changes[], bump last_accepted_at.
 *
 * Exit codes:
 *   0 = success
 *   2 = unknown subcommand, missing required flag, malformed --data,
 *       or since-review.yaml exists but malformed / on an unsupported schema_version.
 *
 * Vault detection: walks up for both .git/ and wiki/.state/sources.yaml,
 * matching status.js and validate-wiki.js.
 *
 * Atomic write: write to a sibling tmpfile, then fs.renameSync into place.
 * On a single-machine, single-user setup the sub-second window between
 * concurrent appends is acceptable per spec §6.4 — no lock file in v1.
 */

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/review-log.js';
const STATE_FILE = 'wiki/.state/since-review.yaml';

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

function nowIso() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

function readState(vault) {
  const abs = path.join(vault, STATE_FILE);
  if (!fs.existsSync(abs)) return null;
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch (err) { die(`${STATE_FILE} unreadable: ${err.message}`, 2); }
  let doc;
  try { doc = yaml.load(text); }
  catch (err) { die(`${STATE_FILE} malformed: ${err.message}`, 2); }
  if (!doc || typeof doc !== 'object') die(`${STATE_FILE} malformed: not a YAML mapping`, 2);
  if (doc.schema_version !== SCHEMA_VERSION) {
    die(`${STATE_FILE} schema_version=${doc.schema_version}, expected ${SCHEMA_VERSION}`, 2);
  }
  if (!Array.isArray(doc.changes)) doc.changes = [];
  return doc;
}

function writeState(vault, doc) {
  doc.schema_version = SCHEMA_VERSION;
  doc.generated_by = GENERATED_BY;
  const abs = path.join(vault, STATE_FILE);
  const dir = path.dirname(abs);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${abs}.tmp.${process.pid}.${Date.now()}`;
  const out = yaml.dump(doc, { indent: 2, sortKeys: false, lineWidth: -1 });
  fs.writeFileSync(tmp, out);
  fs.renameSync(tmp, abs);
}

function emptyState() {
  return {
    schema_version: SCHEMA_VERSION,
    generated_by: GENERATED_BY,
    last_accepted_at: null,
    changes: [],
  };
}

function cmdAppend(vault, args) {
  if (!args.kind) die('--kind is required', 2);
  if (!args.data) die('--data is required (use --data=\'{}\' for an empty payload)', 2);
  let payload;
  try { payload = JSON.parse(args.data); }
  catch (err) { die(`--data is not valid JSON: ${err.message}`, 2); }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    die('--data must be a JSON object', 2);
  }
  const doc = readState(vault) || emptyState();
  const entry = Object.assign({ at: nowIso(), kind: args.kind }, payload);
  doc.changes.push(entry);
  writeState(vault, doc);
}

function cmdShow(vault, args) {
  die('show not yet implemented', 2);   // Filled in by Task 12.
}

function cmdAccept(vault, args) {
  die('accept not yet implemented', 2); // Filled in by Task 13.
}

function parseArgs(argv) {
  const cmd = argv[0];
  const args = { kind: null, data: null, json: false };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--kind=')) args.kind = a.slice('--kind='.length);
    else if (a === '--kind') args.kind = argv[++i];
    else if (a.startsWith('--data=')) args.data = a.slice('--data='.length);
    else if (a === '--data') args.data = argv[++i];
    else if (a === '--json') args.json = true;
    else die(`unknown argument: ${a}`, 2);
  }
  return { cmd, args };
}

function main() {
  const { cmd, args } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  if (cmd === 'append') return cmdAppend(vault, args);
  if (cmd === 'show')   return cmdShow(vault, args);
  if (cmd === 'accept') return cmdAccept(vault, args);
  die(`unknown subcommand: ${cmd}`, 2);
}

main();
