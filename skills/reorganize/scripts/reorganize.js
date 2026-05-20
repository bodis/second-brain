#!/usr/bin/env node
'use strict';

/**
 * skills/reorganize/scripts/reorganize.js — mechanical worker for /second-brain:reorganize.
 *
 * Subcommands:
 *   begin
 *   candidates --kind <merge|recategorize|cover|parent|relations> [--scope <wiki-subdir>] --json
 *   move-page --from <vault-path> --to <vault-path>
 *   merge-page --from <vault-path> --into <vault-path> --merged-body <tmpfile>
 *   mark-covered --page <vault-path> --by <wikilink-target>
 *   parent-create --page <vault-path> --body <tmpfile> --children <p1,p2,...>
 *   relations-add --page <vault-path> --relation <name> --targets <t1,t2,...>
 *   validate-or-revert
 *
 * Exit codes:
 *   0 clean
 *   1 warning
 *   2 structural error after a move; the just-applied commit has been reverted
 *   3 invariant refusal (scope outside wiki/, merged body too short, etc.); no commit
 *   6 uncommitted non-wiki changes; SKILL re-runs `begin` and retries
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const yaml = require('js-yaml');

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
    if (parent === dir) die('not a second-brain vault (no .git/ + wiki/.state/sources.yaml above cwd)', 2);
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
  const args = ['status', '--porcelain', '-uall'];
  if (paths.length > 0) args.push('--', ...paths);
  return git(args, vault).split('\n').filter(Boolean);
}

function headSha(vault) {
  return git(['rev-parse', '--short=7', 'HEAD'], vault).trim();
}

function cmdBegin(vault) {
  const dirty = gitStatusPorcelain(vault, ['wiki/']);
  if (dirty.length === 0) {
    process.stdout.write(headSha(vault));
    return;
  }
  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', 'reorganize: pre-reorganize baseline'], vault);
  process.stdout.write(headSha(vault));
}

function parseArgs(argv) {
  // Returns { cmd, args }. Subcommand-specific flag parsing happens in handlers.
  const cmd = argv[0];
  const args = {};
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        args[key] = true;
      } else {
        args[key] = next;
        i++;
      }
    } else {
      die(`unexpected positional argument: ${a}`);
    }
  }
  return { cmd, args };
}

function main() {
  const { cmd, args } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (cmd === 'begin') return cmdBegin(vault);
  if (cmd === 'candidates') return die('candidates: not implemented yet', 1);
  if (cmd === 'move-page') return die('move-page: not implemented yet', 1);
  if (cmd === 'merge-page') return die('merge-page: not implemented yet', 1);
  if (cmd === 'mark-covered') return die('mark-covered: not implemented yet', 1);
  if (cmd === 'parent-create') return die('parent-create: not implemented yet', 1);
  if (cmd === 'relations-add') return die('relations-add: not implemented yet', 1);
  if (cmd === 'validate-or-revert') return die('validate-or-revert: not implemented yet', 1);
  die(`unknown subcommand: ${cmd}`);
}

main();
