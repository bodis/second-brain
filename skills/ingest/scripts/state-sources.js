#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const crypto = require('crypto');
const yaml = require('js-yaml');

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

const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/state-sources.js';
const DEFAULT_EXCLUDES = ['raw/assets/'];

function readSourcesYaml(vault) {
  const p = path.join(vault, 'wiki/.state/sources.yaml');
  if (!fs.existsSync(p)) {
    return {
      schema_version: SCHEMA_VERSION,
      generated_by: GENERATED_BY,
      excludes: [...DEFAULT_EXCLUDES],
      sources: [],
    };
  }
  const doc = yaml.load(fs.readFileSync(p, 'utf8')) || {};
  if (!doc.schema_version) doc.schema_version = SCHEMA_VERSION;
  if (!doc.generated_by) doc.generated_by = GENERATED_BY;
  if (!Array.isArray(doc.excludes)) doc.excludes = [...DEFAULT_EXCLUDES];
  if (!Array.isArray(doc.sources)) doc.sources = [];
  return doc;
}

function sha256File(absPath) {
  const h = crypto.createHash('sha256');
  h.update(fs.readFileSync(absPath));
  return h.digest('hex');
}

function utcStamp(ms) {
  return new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z');
}

function isExcluded(relPath, excludes) {
  return excludes.some(e => relPath === e.replace(/\/$/, '') || relPath.startsWith(e));
}

function walkSources(vault, excludes) {
  const rawDir = path.join(vault, 'raw');
  if (!fs.existsSync(rawDir)) return [];
  const out = [];
  function recurse(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const abs = path.join(dir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join('/');
      if (e.isDirectory()) {
        if (isExcluded(rel + '/', excludes)) continue;
        recurse(abs);
        continue;
      }
      if (isExcluded(rel, excludes)) continue;
      let stat;
      try { stat = fs.statSync(abs); }
      catch (err) {
        process.stderr.write(`info: skipping ${rel}: ${err.message}\n`);
        continue;
      }
      if (!stat.isFile()) continue;
      out.push({
        path: rel,
        kind: 'generic',
        sha256: sha256File(abs),
        bytes: stat.size,
        mtime: utcStamp(stat.mtimeMs),
      });
    }
  }
  recurse(rawDir);
  return out;
}

function cmdDiff(vault) {
  const doc = readSourcesYaml(vault);
  const fsFiles = walkSources(vault, doc.excludes);
  const yamlByPath = new Map(doc.sources.map(s => [s.path, s]));
  const fsByPath = new Map(fsFiles.map(s => [s.path, s]));

  const newList = [];
  const changedList = [];
  for (const f of fsFiles) {
    const y = yamlByPath.get(f.path);
    if (!y) {
      newList.push({ path: f.path, kind: f.kind, sha256: f.sha256, bytes: f.bytes, mtime: f.mtime });
    } else if (y.sha256 !== f.sha256) {
      changedList.push({
        path: f.path,
        kind: y.kind || 'generic',
        sha256: f.sha256,
        bytes: f.bytes,
        mtime: f.mtime,
        previous_sha256: y.sha256,
        previous_wiki_pages: Array.isArray(y.wiki_pages) ? y.wiki_pages : [],
      });
    }
  }

  const deletedList = [];
  for (const y of doc.sources) {
    if (!fsByPath.has(y.path)) {
      deletedList.push({
        path: y.path,
        previous_wiki_pages: Array.isArray(y.wiki_pages) ? y.wiki_pages : [],
      });
    }
  }

  const byPath = (a, b) => a.path.localeCompare(b.path);
  newList.sort(byPath); changedList.sort(byPath); deletedList.sort(byPath);

  process.stdout.write(JSON.stringify({ new: newList, changed: changedList, deleted: deletedList }, null, 2) + '\n');
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
  if (cmd === 'diff') return cmdDiff(vault);
  die(`unknown subcommand: ${cmd}`);
}

main();
