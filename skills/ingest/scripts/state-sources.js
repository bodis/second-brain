#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function die(msg, code = 1) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(code);
}

function findVaultRoot(start) {
  let dir = path.resolve(start);
  while (true) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) die('not in a git repo (no .git/ found walking up)', 2);
    dir = parent;
  }
}

function git(args, vault) {
  const r = spawnSync('git', args, { cwd: vault, encoding: 'utf8' });
  if (r.status !== 0) {
    process.stderr.write(r.stderr || '');
    process.exit(3);
  }
  return r.stdout;
}

function gitStatusPorcelain(vault, paths) {
  const args = ['status', '--porcelain'];
  if (paths.length > 0) args.push('--', ...paths);
  return git(args, vault).split('\n').filter(Boolean);
}

function cmdBegin(vault) {
  const status = gitStatusPorcelain(vault, ['wiki/', 'wiki/.state/']);
  if (status.length === 0) {
    process.stdout.write('clean baseline\n');
    return;
  }
  git(['add', '--', 'wiki/', 'wiki/.state/'], vault);
  git(['commit', '-m', 'ingest: pre-run baseline'], vault);
  process.stdout.write(`committed pre-run baseline (${status.length} files)\n`);
}

function parseArgs(argv) {
  const cmd = argv[0];
  return { cmd };
}

function main() {
  const { cmd } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (cmd === 'begin') return cmdBegin(vault);
  die(`unknown subcommand: ${cmd}`);
}

main();
