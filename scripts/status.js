#!/usr/bin/env node
'use strict';

/**
 * scripts/status.js — vault status dashboard reporter.
 *
 * Reads wiki/.state/*.yaml and runs cheap fresh comparisons to report what
 * the vault needs the user to act on. Default: human-readable dashboard.
 * --json: stable schema for cron consumers (see references/status-json-schema.md).
 *
 * Reporter only — never mutates. Mutations flow through scripts/review-log.js.
 *
 * Exit codes:
 *   0 = dashboard printed cleanly (validate-wiki non-zero is OK; counts still populated)
 *   2 = vault root not found, or a state-file YAML is malformed, or a child script failed
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const yaml = require('js-yaml');

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

function parseArgs(argv) {
  const args = { json: false };
  for (const a of argv) {
    if (a === '--json') args.json = true;
    else die(`unknown argument: ${a}`, 2);
  }
  return args;
}

// Read a YAML file under wiki/.state/. Returns parsed object or null if absent.
// Calls die() and exits with code 2 on read or parse errors.
function readStateYaml(vault, relname) {
  const abs = path.join(vault, 'wiki', '.state', relname);
  if (!fs.existsSync(abs)) return null;
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch (err) { die(`wiki/.state/${relname} unreadable: ${err.message}`, 2); }
  try { return yaml.load(text); }
  catch (err) { die(`wiki/.state/${relname} malformed: ${err.message}`, 2); }
}

function readSources(vault)        { return { new: 0, changed: 0, deleted: 0 }; }
function readLint(vault)           { return { errors: 0, warnings: 0 }; }
function readContradictions(vault) { return { unjudged_candidates: 0, unresolved: 0, present: false }; }
function readStaleness(vault)      { return { unjudged_candidates: 0, unresolved_high: 0, unresolved_medium: 0, present: false }; }
function readSinceReview(vault)    { return { change_count: 0, last_accepted_at: null }; }

function buildDashboard(vault) {
  return {
    vault:          { root: vault, name: path.basename(vault) },
    sources:        readSources(vault),
    lint:           readLint(vault),
    contradictions: readContradictions(vault),
    staleness:      readStaleness(vault),
    since_review:   readSinceReview(vault),
  };
}

function emitJson(dash) {
  process.stdout.write(JSON.stringify(dash, null, 2) + '\n');
}

function emitHuman(dash) {
  // Filled in by Task 8.
  process.stdout.write(JSON.stringify(dash, null, 2) + '\n');
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  const dash = buildDashboard(vault);
  if (args.json) emitJson(dash);
  else emitHuman(dash);
}

main();
