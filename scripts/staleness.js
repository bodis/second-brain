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
const { spawnSync } = require('child_process');

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

const CANDIDATE_DIRS = ['wiki/entities', 'wiki/concepts', 'wiki/synthesis', 'wiki/sources'];
const ARCHIVE_PREFIX = 'wiki/archive/';
const TINY_VAULT_THRESHOLD = 20;
const STRONG_CUTOFF = 0.75;   // p75
const PRESENT_CUTOFF = 0.50;  // p50
const AUTODEFER_DELTA = 0.10;

// Recursively list .md files under the candidate dirs, vault-relative.
function listCandidatePages(vault) {
  const out = [];
  for (const sub of CANDIDATE_DIRS) {
    const abs = path.join(vault, sub);
    if (!fs.existsSync(abs)) continue;
    walk(abs, vault, out);
  }
  return out;
}
function walk(dir, vault, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    const rel = path.relative(vault, full).split(path.sep).join('/');
    if (rel.startsWith(ARCHIVE_PREFIX)) continue;
    if (entry.isDirectory()) walk(full, vault, out);
    else if (entry.isFile() && entry.name.endsWith('.md')) out.push(rel);
  }
}

function readSourcesYaml(vault) {
  const abs = path.join(vault, 'wiki/.state/sources.yaml');
  if (!fs.existsSync(abs)) return [];
  const doc = yaml.load(fs.readFileSync(abs, 'utf8'), { schema: yaml.CORE_SCHEMA });
  return Array.isArray(doc && doc.sources) ? doc.sources : [];
}

// Extract [[wikilink]] tokens from body prose, return resolved entity targets.
// Only links resolving under wiki/entities/ count.
function extractEntityWikilinks(vault, page) {
  const abs = path.join(vault, page);
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); } catch { return new Set(); }
  const body = text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '');
  const out = new Set();
  const re = /\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]/g;
  let m;
  while ((m = re.exec(body))) {
    const raw = m[1].trim();
    const resolved = resolveEntityTarget(vault, raw);
    if (resolved) out.add(resolved);
  }
  return out;
}

function resolveEntityTarget(vault, raw) {
  const stripped = raw.replace(/\.md$/, '');
  if (stripped.startsWith('wiki/entities/')) {
    const cand = `${stripped}.md`;
    if (fs.existsSync(path.join(vault, cand))) return cand;
    return null;
  }
  const cand = `wiki/entities/${stripped}.md`;
  if (fs.existsSync(path.join(vault, cand))) return cand;
  return null;
}

function buildSourceEntityIndex(vault, sources) {
  const out = new Map();
  for (const s of sources) {
    if (!s || !Array.isArray(s.wiki_pages)) { out.set(s ? s.path : null, new Set()); continue; }
    const ents = new Set();
    for (const wp of s.wiki_pages) {
      for (const e of extractEntityWikilinks(vault, wp)) ents.add(e);
    }
    out.set(s.path, ents);
  }
  return out;
}

function tsMs(v) {
  if (!v) return NaN;
  if (v instanceof Date) return v.getTime();
  const t = Date.parse(String(v));
  return Number.isFinite(t) ? t : NaN;
}

// Returns the fractional rank of x in the sorted-ascending array `sorted`
// (number of values ≤ x divided by length). Returns 0 when sorted is empty.
function fractionalRank(sorted, x) {
  if (sorted.length === 0) return 0;
  let lo = 0, hi = sorted.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (sorted[mid] <= x) lo = mid + 1;
    else hi = mid;
  }
  return lo / sorted.length;
}

function ageMonths(mtimeMs) {
  const ms = Date.now() - mtimeMs;
  return ms / (1000 * 60 * 60 * 24 * 30.4375);
}

function tierFromCutoffs(percentile) {
  if (percentile >= STRONG_CUTOFF) return 'strong';
  if (percentile >= PRESENT_CUTOFF) return 'present';
  return 'weak';
}
function compositeFromTiers(t1, t2) {
  const strongCount = (t1 === 'strong' ? 1 : 0) + (t2 === 'strong' ? 1 : 0);
  const presentCount = (t1 !== 'weak' ? 1 : 0) + (t2 !== 'weak' ? 1 : 0);
  if (strongCount === 2) return 'high';
  if (strongCount === 1 && presentCount === 2) return 'medium';
  return 'low';
}

function parseScope(scope) {
  if (!scope || scope === true) return null;
  return String(scope).split(',').map((s) => s.trim()).filter(Boolean);
}
function inScope(p, scopeList) {
  if (!scopeList) return true;
  for (const s of scopeList) {
    if (p === s) return true;
    if (s.endsWith('/') && p.startsWith(s)) return true;
    if (!s.endsWith('/') && p.startsWith(s + '/')) return true;
  }
  return false;
}

function cmdCandidates(vault, args) {
  const pages = listCandidatePages(vault);
  const existing = readState(vault) || { pages: [] };
  const scopeList = parseScope(args.scope);

  if (pages.length < TINY_VAULT_THRESHOLD) {
    process.stderr.write(`warning: vault has ${pages.length} candidate-eligible pages (<${TINY_VAULT_THRESHOLD}); skipping scan\n`);
    writeState(vault, {
      scanned_at: nowIso(),
      vault_page_count: pages.length,
      pages: existing.pages.filter((e) => e.status !== 'unjudged'),
    });
    return;
  }

  // 1. Stat every page; collect mtimes for percentile computation.
  const mtimes = [];
  const stats = new Map();
  for (const p of pages) {
    const s = fs.statSync(path.join(vault, p));
    stats.set(p, s);
    mtimes.push(s.mtimeMs);
  }
  const sortedMtimes = [...mtimes].sort((a, b) => a - b);

  // 2a. Build source-entity index once.
  const sources = readSourcesYaml(vault);
  const sourceEnts = buildSourceEntityIndex(vault, sources);

  // 2b. Cache each candidate page's entity wikilinks.
  const pageEnts = new Map();
  for (const p of pages) pageEnts.set(p, extractEntityWikilinks(vault, p));

  // 2c. For each page, count sources ingested after the page's mtime
  // whose entity-link set overlaps.
  const rawMovedPast = new Map();
  for (const p of pages) {
    const pageMtime = stats.get(p).mtimeMs;
    const myEnts = pageEnts.get(p);
    let count = 0;
    if (myEnts.size > 0) {
      for (const s of sources) {
        const ts = tsMs(s.ingested_at);
        if (!Number.isFinite(ts) || ts <= pageMtime) continue;
        const ents = sourceEnts.get(s.path) || new Set();
        let overlap = false;
        for (const e of ents) { if (myEnts.has(e)) { overlap = true; break; } }
        if (overlap) count += 1;
      }
    }
    rawMovedPast.set(p, count);
  }
  const sortedMoved = [...rawMovedPast.values()].sort((a, b) => a - b);

  // 2d. Score every page.
  const scored = [];
  for (const p of pages) {
    const s = stats.get(p);
    const ageRank = fractionalRank(sortedMtimes, s.mtimeMs);
    const agePercentile = 1 - ageRank;
    const mpRaw = rawMovedPast.get(p);
    // Zero overlapping sources means the signal is absent; rank only positive counts.
    const movedPastPercentile = mpRaw === 0 ? 0 : fractionalRank(sortedMoved, mpRaw);
    const score = agePercentile * movedPastPercentile;
    const ageTier = tierFromCutoffs(agePercentile);
    const movedTier = tierFromCutoffs(movedPastPercentile);
    const signal = compositeFromTiers(ageTier, movedTier);
    scored.push({
      path: p,
      signal,
      factors: {
        age_months: Number(ageMonths(s.mtimeMs).toFixed(1)),
        age_percentile: Number(agePercentile.toFixed(3)),
        newer_overlapping_sources: mpRaw,
        moved_past_percentile: Number(movedPastPercentile.toFixed(3)),
      },
      score,
    });
  }

  // 3. Merge with existing entries.
  // - Drop existing status:unjudged (will be re-derived from current scan).
  // - Preserve unreviewed/resolved as-is.
  // - For deferred/dismissed: keep status unchanged UNLESS the new score
  //   exceeds last_reviewed_signal_score + AUTODEFER_DELTA; then re-promote
  //   to unjudged with fresh factors.
  const scoreByPath = new Map(scored.map((s) => [s.path, s]));
  const preserved = [];
  for (const e of existing.pages) {
    if (!e || !e.status) continue;
    if (e.status === 'unjudged') continue;
    if ((e.status === 'deferred' || e.status === 'dismissed') && scoreByPath.has(e.path)) {
      const fresh = scoreByPath.get(e.path);
      const baseline = typeof e.last_reviewed_signal_score === 'number' ? e.last_reviewed_signal_score : 0;
      if (fresh.score > baseline + AUTODEFER_DELTA) {
        preserved.push({
          ...e,
          signal: fresh.signal,
          factors: fresh.factors,
          status: 'unjudged',
          judgment: null,
          resolution: null,
          resolved_at: null,
          deferred_at: null,
        });
        continue;
      }
    }
    preserved.push(e);
  }
  const preservedPaths = new Set(preserved.map((e) => e.path));
  const newEntries = [];
  for (const s of scored) {
    if (preservedPaths.has(s.path)) continue;
    if (s.signal === 'low') continue;
    if (!inScope(s.path, scopeList)) continue;
    newEntries.push({
      id: allocateId([...preserved, ...newEntries]),
      path: s.path,
      signal: s.signal,
      factors: s.factors,
      last_reviewed_signal_score: null,
      status: 'unjudged',
      judgment: null,
      resolution: null,
      resolved_at: null,
      deferred_at: null,
    });
  }

  writeState(vault, {
    scanned_at: nowIso(),
    vault_page_count: pages.length,
    pages: [...preserved, ...newEntries],
  });

  if (args.json) {
    process.stdout.write(JSON.stringify({ pages: [...preserved, ...newEntries] }, null, 2) + '\n');
  }
}

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
const VALID_VERDICTS = new Set(['stale', 'drifting', 'fresh-but-isolated', 'false-positive']);

function cmdJudge(vault, args) {
  if (!args.id) die('judge: --id is required', 2);
  if (!args.verdict) die('judge: --verdict is required', 2);
  if (!VALID_VERDICTS.has(args.verdict)) die(`judge: unknown verdict ${args.verdict}`, 2);
  if (!args.data) die('judge: --data is required', 2);
  let data;
  try { data = JSON.parse(args.data); } catch { die('judge: --data is not valid JSON', 2); }
  if (typeof data.reason !== 'string') die('judge: --data.reason must be a string', 2);
  if (!Array.isArray(data.neighbors_examined)) die('judge: --data.neighbors_examined must be an array', 2);

  const doc = readState(vault);
  if (!doc) die(`judge: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`judge: id ${args.id} not found`, 3);
  if (entry.status !== 'unjudged') {
    die(`judge: entry ${args.id} status is ${entry.status}, expected unjudged`, 3);
  }

  const newStatus = (args.verdict === 'stale' || args.verdict === 'drifting') ? 'unreviewed' : 'dismissed';
  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = newStatus;
  entry.judgment = {
    verdict: args.verdict,
    reason: data.reason,
    neighbors_examined: data.neighbors_examined,
    judged_at: nowIso(),
  };
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: ${args.verdict} -> ${newStatus}\n`);
}
function cmdResolve(vault, args) {
  if (!args.id) die('resolve: --id is required', 2);
  if (args.kind !== 'defer') {
    die(`resolve: unsupported --kind ${args.kind} (only 'defer' is handled here; use apply-refresh/archive/historical)`, 2);
  }
  const doc = readState(vault);
  if (!doc) die(`resolve: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`resolve: id ${args.id} not found`, 3);
  if (entry.status !== 'unreviewed') {
    die(`resolve: entry ${args.id} status is ${entry.status}, expected unreviewed`, 3);
  }
  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = 'deferred';
  entry.deferred_at = nowIso();
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: deferred\n`);
}
function runValidateWiki(vault) {
  const validatePath = path.join(__dirname, 'validate-wiki.js');
  const r = spawnSync(process.execPath, [validatePath, 'all'], { cwd: vault, encoding: 'utf8' });
  return { code: r.status, stderr: r.stderr, stdout: r.stdout };
}

function cmdApplyRefresh(vault, args) {
  if (!args.id) die('apply-refresh: --id is required', 2);
  if (!args.rewrite) die('apply-refresh: --rewrite <tmpfile> is required', 2);
  if (!fs.existsSync(args.rewrite)) die(`apply-refresh: tmpfile not found: ${args.rewrite}`, 2);

  const doc = readState(vault);
  if (!doc) die(`apply-refresh: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-refresh: id ${args.id} not found`, 3);
  if (entry.status !== 'unreviewed') {
    die(`apply-refresh: entry ${args.id} status is ${entry.status}, expected unreviewed`, 3);
  }

  const abs = path.join(vault, entry.path);
  if (!fs.existsSync(abs)) die(`apply-refresh: page ${entry.path} no longer exists`, 3);
  const original = fs.readFileSync(abs, 'utf8');
  const rewrite = fs.readFileSync(args.rewrite, 'utf8');

  // Atomic write.
  const tmp = `${abs}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmp, rewrite);
  fs.renameSync(tmp, abs);

  const v = runValidateWiki(vault);
  if (v.code !== 0) {
    fs.writeFileSync(abs, original);
    process.stderr.write(v.stderr || v.stdout || '');
    die(`apply-refresh: validate-wiki failed (exit ${v.code}); reverted ${entry.path}`, 2);
  }

  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = 'resolved';
  entry.resolution = 'refreshed';
  entry.resolved_at = nowIso();
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: refreshed\n`);
}
const FRONTMATTER_RE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/;

function splitFrontmatter(text) {
  const m = FRONTMATTER_RE.exec(text);
  if (!m) return { fm: null, body: text };
  return { fm: m[1], body: m[2] };
}
function joinFrontmatter(fm, body) {
  return `---\n${fm}\n---\n${body}`;
}
function parseFrontmatter(fm) {
  return yaml.load(fm, { schema: yaml.CORE_SCHEMA }) || {};
}
function dumpFrontmatter(obj) {
  return yaml.dump(obj, { indent: 2, sortKeys: false, lineWidth: -1 }).trimEnd();
}

function yearFromMtime(absPath) {
  const s = fs.statSync(absPath);
  const d = new Date(s.mtimeMs);
  return String(d.getFullYear());
}

function cmdApplyArchive(vault, args) {
  if (!args.id) die('apply-archive: --id is required', 2);
  const doc = readState(vault);
  if (!doc) die(`apply-archive: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-archive: id ${args.id} not found`, 3);
  if (entry.status !== 'unreviewed') {
    die(`apply-archive: entry ${args.id} status is ${entry.status}, expected unreviewed`, 3);
  }
  const origRel = entry.path;
  const origAbs = path.join(vault, origRel);
  if (!fs.existsSync(origAbs)) die(`apply-archive: page ${origRel} does not exist`, 3);

  const year = yearFromMtime(origAbs);
  const archiveRel = `wiki/archive/${year}/${origRel.replace(/^wiki\//, '')}`;
  const archiveAbs = path.join(vault, archiveRel);
  if (fs.existsSync(archiveAbs)) die(`apply-archive: archive target already exists: ${archiveRel}`, 3);

  const originalText = fs.readFileSync(origAbs, 'utf8');
  const { fm, body } = splitFrontmatter(originalText);
  const fmObj = fm ? parseFrontmatter(fm) : {};
  const carryTags = Array.isArray(fmObj.tags) ? fmObj.tags : [];
  const carryCreated = fmObj.created || todayDateStr();
  const carryUpdated = todayDateStr();

  // 1. Write archive file (original content + lifecycle: archived).
  fmObj.lifecycle = { state: 'archived', original: origRel };
  const archiveText = joinFrontmatter(dumpFrontmatter(fmObj), body);
  fs.mkdirSync(path.dirname(archiveAbs), { recursive: true });
  const archiveTmp = `${archiveAbs}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(archiveTmp, archiveText);
  fs.renameSync(archiveTmp, archiveAbs);

  // 2. Replace original with stub (lifecycle: superseded + empty sources).
  const stubFm = dumpFrontmatter({
    tags: carryTags,
    sources: [],
    created: carryCreated,
    updated: carryUpdated,
    lifecycle: { state: 'superseded', by: archiveRel },
  });
  const stubBody = `See [[${archiveRel.replace(/\.md$/, '')}]] for the original content.\n`;
  const stubText = joinFrontmatter(stubFm, stubBody);
  const stubTmp = `${origAbs}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(stubTmp, stubText);
  fs.renameSync(stubTmp, origAbs);

  // 3. Validate.
  const v = runValidateWiki(vault);
  if (v.code !== 0) {
    fs.writeFileSync(origAbs, originalText);
    try { fs.unlinkSync(archiveAbs); } catch {}
    process.stderr.write(v.stderr || v.stdout || '');
    die(`apply-archive: validate-wiki failed (exit ${v.code}); reverted`, 2);
  }

  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = 'resolved';
  entry.resolution = 'archived';
  entry.resolved_at = nowIso();
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: archived -> ${archiveRel}\n`);
}
function todayMonthStr() {
  return new Date().toISOString().slice(0, 7);
}

function cmdApplyHistorical(vault, args) {
  if (!args.id) die('apply-historical: --id is required', 2);
  const since = (typeof args.since === 'string') ? args.since : todayMonthStr();
  if (!/^\d{4}-\d{2}$/.test(since)) die(`apply-historical: --since must be YYYY-MM, got ${since}`, 2);

  const doc = readState(vault);
  if (!doc) die(`apply-historical: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-historical: id ${args.id} not found`, 3);
  if (entry.status !== 'unreviewed') {
    die(`apply-historical: entry ${args.id} status is ${entry.status}, expected unreviewed`, 3);
  }
  const abs = path.join(vault, entry.path);
  if (!fs.existsSync(abs)) die(`apply-historical: page ${entry.path} does not exist`, 3);

  const original = fs.readFileSync(abs, 'utf8');
  const { fm, body } = splitFrontmatter(original);
  if (!fm) die(`apply-historical: page ${entry.path} has no frontmatter`, 3);
  const fmObj = parseFrontmatter(fm);
  fmObj.lifecycle = { state: 'historical', since };
  fmObj.updated = todayDateStr();
  const updated = joinFrontmatter(dumpFrontmatter(fmObj), body);

  const tmp = `${abs}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmp, updated);
  fs.renameSync(tmp, abs);

  const v = runValidateWiki(vault);
  if (v.code !== 0) {
    fs.writeFileSync(abs, original);
    process.stderr.write(v.stderr || v.stdout || '');
    die(`apply-historical: validate-wiki failed (exit ${v.code}); reverted`, 2);
  }

  const score = (entry.factors && Number(entry.factors.age_percentile) * Number(entry.factors.moved_past_percentile)) || 0;
  entry.status = 'resolved';
  entry.resolution = 'historical';
  entry.resolved_at = nowIso();
  entry.last_reviewed_signal_score = Number(score.toFixed(3));
  writeState(vault, doc);
  process.stdout.write(`${args.id}: historical (since ${since})\n`);
}
function cmdCheck(vault, args) {
  if (!args.pages) die('check: --pages <comma-list> is required', 2);
  const paths = parseCommaList(args.pages) || [];
  const doc = readState(vault);
  const yamlEntries = doc ? doc.pages : [];

  const warnings = [];
  for (const p of paths) {
    const abs = path.join(vault, p);
    if (fs.existsSync(abs)) {
      const text = fs.readFileSync(abs, 'utf8');
      const { fm } = splitFrontmatter(text);
      if (fm) {
        const fmObj = parseFrontmatter(fm);
        const lc = fmObj && fmObj.lifecycle;
        if (lc && typeof lc === 'object' && lc.state) {
          const w = { path: p, kind: lc.state };
          if (lc.since) w.since = lc.since;
          if (lc.by) w.by = lc.by;
          if (lc.original) w.original = lc.original;
          warnings.push(w);
          continue;
        }
      }
    }
    const entry = yamlEntries.find((e) => e && e.path === p);
    if (entry && entry.status === 'unreviewed' && entry.signal === 'high') {
      warnings.push({ path: p, kind: 'stale-high', factors: entry.factors });
    }
  }

  if (args.json) {
    process.stdout.write(JSON.stringify({ warnings }, null, 2) + '\n');
    return;
  }
  if (warnings.length === 0) {
    process.stdout.write('(no warnings)\n');
    return;
  }
  for (const w of warnings) {
    process.stdout.write(`${w.path}\t${w.kind}${w.since ? `\tsince=${w.since}` : ''}\n`);
  }
}

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
