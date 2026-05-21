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

const STATE_SOURCES_JS = path.join(__dirname, '..', 'skills', 'ingest', 'scripts', 'state-sources.js');
const VALIDATE_WIKI_JS = path.join(__dirname, 'validate-wiki.js');

function readSources(vault) {
  const r = spawnSync('node', [STATE_SOURCES_JS, 'diff'], { cwd: vault, encoding: 'utf8' });
  if (r.status !== 0) {
    process.stderr.write(r.stderr || '');
    die(`state-sources.js diff failed (exit ${r.status})`, 2);
  }
  let parsed;
  try { parsed = JSON.parse(r.stdout); }
  catch (err) { die(`state-sources.js diff produced invalid JSON: ${err.message}`, 2); }
  return {
    new:     parsed.new.length,
    changed: parsed.changed.length,
    deleted: parsed.deleted.length,
  };
}
function readLint(vault) {
  const r = spawnSync('node', [VALIDATE_WIKI_JS, 'all', '--json'], { cwd: vault, encoding: 'utf8' });
  // Per spec §5.4: validate-wiki non-zero is acceptable; status.js is a reporter.
  // Only invalid/empty stdout is a problem.
  let parsed;
  try { parsed = JSON.parse(r.stdout || '{}'); }
  catch (err) { die(`validate-wiki.js all --json produced invalid JSON: ${err.message}`, 2); }
  const fmErrors    = (parsed.frontmatter?.errors    || []).length;
  const wlBroken    = (parsed.wikilinks?.broken      || []).length;
  const wlOrphans   = (parsed.wikilinks?.orphans     || []).length;
  const ixDead      = (parsed.index?.dead_rows       || []).length;
  const ixMissing   = (parsed.index?.missing_rows    || []).length;
  return {
    errors:   fmErrors + wlBroken + ixDead,
    warnings: wlOrphans + ixMissing,
  };
}
function readContradictions(vault) {
  const doc = readStateYaml(vault, 'contradictions.yaml');
  if (!doc) return { unjudged_candidates: 0, unresolved: 0, present: false };
  const entries = Array.isArray(doc.contradictions) ? doc.contradictions : [];
  let unresolved = 0;
  for (const e of entries) {
    if (e && e.status === 'unresolved') unresolved += 1;
  }
  return { unjudged_candidates: 0, unresolved, present: true };
}
function readStaleness(vault) {
  const doc = readStateYaml(vault, 'staleness.yaml');
  if (!doc) return {
    unjudged_candidates: 0,
    unresolved_high: 0,
    unresolved_medium: 0,
    present: false,
  };
  const entries = Array.isArray(doc.pages) ? doc.pages : [];
  let unresolved_high = 0, unresolved_medium = 0;
  for (const e of entries) {
    if (!e || e.status !== 'unreviewed') continue;
    if (e.signal === 'high')   unresolved_high   += 1;
    if (e.signal === 'medium') unresolved_medium += 1;
  }
  return { unjudged_candidates: 0, unresolved_high, unresolved_medium, present: true };
}
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
