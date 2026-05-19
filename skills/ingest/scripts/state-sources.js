#!/usr/bin/env node
'use strict';

/**
 * @typedef {Object} Source
 * @property {string} path             POSIX-style vault-relative path.
 * @property {'generic'|'structured'}  kind  Source classification. Generic: under raw/. Structured: under src/documentation/<system>/.
 * @property {string} [system]         For structured sources only: first path segment under src/documentation/ (e.g. "confluence").
 * @property {string} sha256           Content hash, hex lowercase, 64 chars.
 * @property {number} bytes            File size in bytes.
 * @property {string} mtime            ISO 8601 UTC timestamp ending in `Z`.
 * @property {string} [ingested_at]    ISO 8601 UTC; set by `commit`, absent before then.
 * @property {string[]} [wiki_pages]   POSIX-style vault-relative paths of wiki pages this source's ingest touched.
 */

/**
 * @typedef {Object} DiffEntry
 * @property {string} path
 * @property {'generic'|'structured'} [kind]
 * @property {string} [system]                 Set only when kind === 'structured'.
 * @property {string} [sha256]
 * @property {number} [bytes]
 * @property {string} [mtime]
 * @property {string} [previous_sha256]
 * @property {string[]} [previous_wiki_pages]
 */

/**
 * @typedef {Object} DiffResult
 * @property {DiffEntry[]} new      Sources on disk but absent from sources.yaml.
 * @property {DiffEntry[]} changed  Sources whose content hash differs from sources.yaml. Carries previous_sha256 + previous_wiki_pages.
 * @property {DiffEntry[]} deleted  Sources in sources.yaml but no longer on disk. Carries previous_wiki_pages only.
 */

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
  const args = ['status', '--porcelain', '-uall'];
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

function writeSourcesYaml(vault, doc) {
  doc.sources.sort((a, b) => a.path.localeCompare(b.path));
  const stateDir = path.join(vault, 'wiki/.state');
  fs.mkdirSync(stateDir, { recursive: true });
  const out = yaml.dump(doc, { indent: 2, sortKeys: false, lineWidth: -1 });
  fs.writeFileSync(path.join(stateDir, 'sources.yaml'), out);
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
  const out = [];

  function pushFile(abs, rel, kind, system) {
    let stat;
    try { stat = fs.statSync(abs); }
    catch (err) {
      process.stderr.write(`info: skipping ${rel}: ${err.message}\n`);
      return;
    }
    if (!stat.isFile()) return;
    const entry = {
      path: rel,
      kind,
      sha256: sha256File(abs),
      bytes: stat.size,
      mtime: utcStamp(stat.mtimeMs),
    };
    if (system) entry.system = system;
    out.push(entry);
  }

  function recurseGeneric(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const abs = path.join(dir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join('/');
      if (e.isDirectory()) {
        if (isExcluded(rel + '/', excludes)) continue;
        recurseGeneric(abs);
        continue;
      }
      if (isExcluded(rel, excludes)) continue;
      pushFile(abs, rel, 'generic', null);
    }
  }

  function recurseStructured(dir, system) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const abs = path.join(dir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join('/');
      if (e.isDirectory()) {
        if (isExcluded(rel + '/', excludes)) continue;
        recurseStructured(abs, system);
        continue;
      }
      if (isExcluded(rel, excludes)) continue;
      pushFile(abs, rel, 'structured', system);
    }
  }

  const rawDir = path.join(vault, 'raw');
  if (fs.existsSync(rawDir)) recurseGeneric(rawDir);

  const docDir = path.join(vault, 'src/documentation');
  if (fs.existsSync(docDir)) {
    for (const e of fs.readdirSync(docDir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const abs = path.join(docDir, e.name);
      const rel = path.relative(vault, abs).split(path.sep).join('/');
      if (!e.isDirectory()) {
        process.stderr.write(`info: skipping ${rel}: no <system>/ subdirectory\n`);
        continue;
      }
      if (isExcluded(rel + '/', excludes)) continue;
      recurseStructured(abs, e.name);
    }
  }

  return out;
}

// Parse `git status --porcelain -- wiki/` output. Returns the wiki .md files to
// record in wiki_pages (added/modified, NOT deleted) and the full list of paths
// to stage (so deletions are reflected in the commit).
function parsePorcelainWikiPages(lines) {
  const wikiPages = new Set();
  const toStage = new Set();
  for (const line of lines) {
    const code = line.slice(0, 2);
    const rest = line.slice(3);
    let oldPath = null, newPath = rest;
    if (code.startsWith('R') || code.startsWith('C')) {
      const arrow = rest.indexOf(' -> ');
      if (arrow > -1) {
        oldPath = rest.slice(0, arrow);
        newPath = rest.slice(arrow + 4);
      }
    }
    if (oldPath) toStage.add(oldPath);
    toStage.add(newPath);
    if (!newPath.endsWith('.md')) continue;
    // If the file is gone from disk (any 'D' in either status slot — ' D',
    // 'D ', 'AD', 'MD', etc.), stage the deletion but do not record in
    // wiki_pages.
    if (code.includes('D')) continue;
    wikiPages.add(newPath);
  }
  return {
    wikiPages: [...wikiPages].sort(),
    toStage: [...toStage].sort(),
  };
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
      const entry = { path: f.path, kind: f.kind, sha256: f.sha256, bytes: f.bytes, mtime: f.mtime };
      if (f.system) entry.system = f.system;
      newList.push(entry);
    } else if (y.sha256 !== f.sha256) {
      const entry = {
        path: f.path,
        kind: y.kind || 'generic',
        sha256: f.sha256,
        bytes: f.bytes,
        mtime: f.mtime,
        previous_sha256: y.sha256,
        previous_wiki_pages: Array.isArray(y.wiki_pages) ? y.wiki_pages : [],
      };
      if (f.system) entry.system = f.system;
      changedList.push(entry);
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

function cmdCommit(vault, args) {
  if (!args.source) die('--source is required', 1);

  if (args.deleted) {
    const doc = readSourcesYaml(vault);
    doc.sources = doc.sources.filter(s => s.path !== args.source);
    writeSourcesYaml(vault, doc);
    git(['add', '--', 'wiki/.state/sources.yaml'], vault);
    git(['commit', '-m', `ingest: remove ${args.source} from state`], vault);
    process.stdout.write(`ingest: remove ${args.source} from state\n`);
    return;
  }

  // Exit 6: any uncommitted change outside wiki/ blocks commit, unless it's
  // the source being ingested (which is typically untracked or modified at
  // this point — it gets folded into the per-source commit below).
  const allChanges = gitStatusPorcelain(vault, []);
  const nonWiki = allChanges.filter(line => {
    const rest = line.slice(3);
    const arrow = rest.indexOf(' -> ');
    const left = arrow > -1 ? rest.slice(0, arrow) : rest;
    const right = arrow > -1 ? rest.slice(arrow + 4) : rest;
    if (left.startsWith('wiki/') || right.startsWith('wiki/')) return false;
    if (left === args.source || right === args.source) return false;
    return true;
  });
  if (nonWiki.length > 0) {
    die('working tree has uncommitted non-wiki changes; run `state-sources begin` first', 6);
  }

  const abs = path.join(vault, args.source);
  if (!fs.existsSync(abs)) {
    die(`source path does not exist: ${args.source} (use --deleted to remove from state)`, 5);
  }

  const wikiStatus = gitStatusPorcelain(vault, ['wiki/']);
  const { wikiPages, toStage } = parsePorcelainWikiPages(wikiStatus);

  if (wikiPages.length === 0 && !args.allowEmpty) {
    die(`source "${args.source}" produced no wiki changes; re-run with --allow-empty if intentional`, 4);
  }

  const stat = fs.statSync(abs);

  let kind, system;
  if (args.source.startsWith('raw/')) {
    kind = 'generic';
    system = null;
  } else if (args.source.startsWith('src/documentation/')) {
    const segs = args.source.split('/');
    // segs = ['src', 'documentation', '<system>', '<...rest>']
    if (segs.length < 4 || segs[2] === '') {
      die(`source path "${args.source}" is under src/documentation/ but missing a <system>/ subdirectory`, 1);
    }
    kind = 'structured';
    system = segs[2];
  } else {
    die(`source path "${args.source}" is not under raw/ or src/documentation/`, 1);
  }

  const entry = { path: args.source, kind };
  if (system) entry.system = system;
  entry.sha256 = sha256File(abs);
  entry.bytes = stat.size;
  entry.mtime = utcStamp(stat.mtimeMs);
  entry.ingested_at = utcStamp(Date.now());
  entry.wiki_pages = wikiPages;

  const doc = readSourcesYaml(vault);
  doc.sources = doc.sources.filter(s => s.path !== args.source);
  doc.sources.push(entry);
  writeSourcesYaml(vault, doc);

  const staged = [args.source, 'wiki/.state/sources.yaml', ...toStage];
  git(['add', '--', ...staged], vault);
  const msg = wikiPages.length === 0
    ? `ingest: ${args.source} → no output (allow-empty)`
    : `ingest: ${args.source} → ${wikiPages.length} pages`;
  git(['commit', '-m', msg], vault);
  process.stdout.write(`${msg}\n`);
}

function parseArgs(argv) {
  const cmd = argv[0];
  const args = { source: null, allowEmpty: false, deleted: false };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--source') args.source = argv[++i];
    else if (a === '--allow-empty') args.allowEmpty = true;
    else if (a === '--deleted') args.deleted = true;
    else die(`unknown argument: ${a}`);
  }
  return { cmd, args };
}

function main() {
  const { cmd, args } = parseArgs(process.argv.slice(2));
  const vault = findVaultRoot(process.cwd());
  if (cmd === 'begin') return cmdBegin(vault);
  if (cmd === 'diff') return cmdDiff(vault);
  if (cmd === 'commit') return cmdCommit(vault, args);
  die(`unknown subcommand: ${cmd}`);
}

main();
