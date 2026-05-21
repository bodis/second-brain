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

function main() {
  const args = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  // Filled in by Task 2.
}

main();
