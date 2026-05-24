#!/usr/bin/env node
'use strict';

/**
 * scripts/contradictions.js — owner of wiki/.state/contradictions.yaml.
 *
 * Subcommands:
 *   candidates --scope <dir-or-page-list> [--json]
 *   list [--status <comma-list>] [--json]
 *   judge --id <id> --verdict <real-contradiction|not-a-contradiction> --data <json>
 *   resolve --id <id> --kind defer
 *   apply-pick --id <id> --winning-page <vault-path> --rewrite <tmpfile>
 *   apply-accept --id <id>
 *
 * Exit codes:
 *   0 = clean
 *   2 = vault not found / malformed yaml / missing required arg / malformed --data /
 *       validate-wiki post-check failure after auto-revert / unsupported subcommand or kind
 *   3 = invariant refusal (invalid lifecycle transition, substring not unique, etc.) —
 *       no mutation occurred
 *
 * Vault detection: walks up for both .git/ and wiki/.state/sources.yaml,
 * matching status.js / validate-wiki.js / review-log.js.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const yaml = require('js-yaml');

const SCHEMA_VERSION = 1;
const GENERATED_BY = 'scripts/contradictions.js';
const STATE_FILE = 'wiki/.state/contradictions.yaml';

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

// Parse `--flag=value`, `--flag value`, and `--flag` (boolean). Returns
// { _: positional[], <flag>: <value> }. Open-world: unknown flags are
// accumulated into the result so each subcommand can validate its own
// arg set after parsing.
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      if (eq > 0) {
        out[a.slice(2, eq)] = a.slice(eq + 1);
      } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
        out[a.slice(2)] = argv[++i];
      } else {
        out[a.slice(2)] = true;
      }
    } else {
      out._.push(a);
    }
  }
  return out;
}

function readState(vault) {
  const abs = path.join(vault, STATE_FILE);
  if (!fs.existsSync(abs)) return null;
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch (err) { die(`${STATE_FILE} unreadable: ${err.message}`, 2); }
  let doc;
  try { doc = yaml.load(text, { schema: yaml.CORE_SCHEMA }); }
  catch (err) { die(`${STATE_FILE} malformed: ${err.message}`, 2); }
  if (!doc || typeof doc !== 'object') die(`${STATE_FILE} malformed: not a YAML mapping`, 2);
  if (doc.schema_version !== SCHEMA_VERSION) {
    die(`${STATE_FILE} schema_version=${doc.schema_version}, expected ${SCHEMA_VERSION}`, 2);
  }
  if (!Array.isArray(doc.contradictions)) doc.contradictions = [];
  return doc;
}

function emptyState() {
  return {
    schema_version: SCHEMA_VERSION,
    generated_by: GENERATED_BY,
    contradictions: [],
  };
}

function cmdList(vault, args) {
  const doc = readState(vault) || emptyState();
  let entries = doc.contradictions;
  if (args.status) {
    const wanted = String(args.status).split(',').map(s => s.trim()).filter(Boolean);
    entries = entries.filter(e => wanted.includes(e.status));
  }
  if (args.json) {
    const out = Object.assign({}, doc, { contradictions: entries });
    process.stdout.write(JSON.stringify(out, null, 2) + '\n');
    return;
  }
  if (entries.length === 0) {
    const msg = args.status
      ? 'No contradictions matching filter.\n'
      : 'No contradictions.\n';
    process.stdout.write(msg);
    return;
  }
  // Group by status for the human summary.
  const groups = new Map();
  for (const e of entries) {
    const k = e.status || '(unknown)';
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(e);
  }
  const lines = [];
  lines.push(`${entries.length} entries across ${groups.size} statuses`);
  lines.push('');
  for (const [status, list] of groups) {
    lines.push(`${status} (${list.length}):`);
    for (const e of list) {
      const claim = e.judgment?.claim || '(unjudged)';
      const pages = Array.isArray(e.pages) ? e.pages.join(' ⟷ ') : '(unknown pages)';
      lines.push(`  ${e.id}  ${pages}  — ${claim}`);
    }
    lines.push('');
  }
  process.stdout.write(lines.join('\n'));
}

function nowIso() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

function todayDate() {
  return new Date().toISOString().slice(0, 10);
}

// Read the YAML frontmatter block at the top of a markdown file. Returns the
// parsed object, or null if no fenced block.
function readFrontmatter(absPath) {
  let text;
  try { text = fs.readFileSync(absPath, 'utf8'); }
  catch { return null; }
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!m) return null;
  try { return yaml.load(m[1], { schema: yaml.CORE_SCHEMA }); }
  catch { return null; }
}

// Walk wiki/ and return vault-relative .md paths under the four content dirs.
function* walkWikiMarkdown(vault) {
  const root = path.join(vault, 'wiki');
  const subdirs = ['entities', 'concepts', 'synthesis', 'sources'];
  for (const sub of subdirs) {
    const dir = path.join(root, sub);
    if (!fs.existsSync(dir)) continue;
    const stack = [dir];
    while (stack.length) {
      const d = stack.pop();
      for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
        if (ent.name.startsWith('.')) continue;
        const full = path.join(d, ent.name);
        if (ent.isDirectory()) stack.push(full);
        else if (ent.isFile() && ent.name.endsWith('.md')) {
          yield path.relative(vault, full).split(path.sep).join('/');
        }
      }
    }
  }
}

// Allocate the next ID for today's date. Reads existing entries, finds the
// highest NNN for today, returns max+1 zero-padded to 3 digits.
function allocateId(doc) {
  const today = todayDate();
  const prefix = `${today}-`;
  let maxN = 0;
  for (const e of doc.contradictions) {
    if (typeof e.id === 'string' && e.id.startsWith(prefix)) {
      const n = parseInt(e.id.slice(prefix.length), 10);
      if (Number.isInteger(n) && n > maxN) maxN = n;
    }
  }
  const next = String(maxN + 1).padStart(3, '0');
  return `${today}-${next}`;
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

const SHARED_LINK_THRESHOLD = 5;

// Extract all [[wikilink]] tokens from body prose (excluding the frontmatter
// fence). Returns vault-relative `.md` paths, resolved under the bare-name
// (entities/concepts/synthesis/sources) and `wiki/...` rules.
function extractBodyWikilinks(vault, page) {
  const abs = path.join(vault, page);
  let text;
  try { text = fs.readFileSync(abs, 'utf8'); }
  catch { return new Set(); }
  // Strip leading frontmatter block, if any.
  const body = text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '');
  const out = new Set();
  // Match [[target]] or [[target|alias]]; capture target.
  const re = /\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]/g;
  let m;
  while ((m = re.exec(body))) {
    const raw = m[1].trim();
    const resolved = resolveWikilinkTarget(vault, raw);
    if (resolved) out.add(resolved);
  }
  return out;
}

// Resolve a wikilink token to a vault-relative .md path under the same three
// rules validate-wiki.js wikilinks uses: bare name (search the four content
// dirs), `wiki/...` path, `src/documentation/...` path.
function resolveWikilinkTarget(vault, token) {
  // Strip a trailing .md to normalise.
  const t = token.endsWith('.md') ? token.slice(0, -3) : token;
  // wiki/... and src/documentation/... paths land directly.
  if (t.startsWith('wiki/') || t.startsWith('src/documentation/')) {
    const candidate = t + '.md';
    if (fs.existsSync(path.join(vault, candidate))) return candidate;
    return null;
  }
  // Bare-name: search the four content dirs in order.
  for (const sub of ['entities', 'concepts', 'synthesis', 'sources']) {
    const candidate = `wiki/${sub}/${t}.md`;
    if (fs.existsSync(path.join(vault, candidate))) return candidate;
  }
  return null;
}

function signalSharedEntityProse(vault, pagesInScope) {
  const linkCache = new Map(); // page → Set<resolved>
  for (const p of pagesInScope) {
    linkCache.set(p, extractBodyWikilinks(vault, p));
  }
  const candidates = [];
  const sortedPages = [...pagesInScope].sort();
  for (let i = 0; i < sortedPages.length; i++) {
    const a = sortedPages[i];
    const linksA = linkCache.get(a);
    if (!linksA || linksA.size === 0) continue;
    for (let j = i + 1; j < sortedPages.length; j++) {
      const b = sortedPages[j];
      const linksB = linkCache.get(b);
      if (!linksB || linksB.size === 0) continue;
      const shared = [...linksA].filter(t => linksB.has(t));
      if (shared.length < SHARED_LINK_THRESHOLD) continue;
      const sharedEntities = shared.filter(t => t.startsWith('wiki/entities/')).sort();
      if (sharedEntities.length === 0) continue;
      // Emit one candidate per shared entity.
      for (const entity of sharedEntities) {
        candidates.push({
          pages: [a, b], // already sorted
          signal: 'shared-entity-prose',
          signal_data: {
            entity,
            shared_links: shared.length,
          },
        });
      }
    }
  }
  return candidates;
}

// Compute Signal 1 candidates: pairs of pages sharing a relations.<R> key,
// where their value lists partly overlap and partly diverge.
// Returns array of { pages: [a, b], signal: 'conflicting-relations', signal_data }.
function signalConflictingRelations(vault, pagesInScope) {
  const fmCache = new Map(); // page → relations dict
  for (const p of pagesInScope) {
    const fm = readFrontmatter(path.join(vault, p));
    const relations = (fm && typeof fm.relations === 'object' && fm.relations) || null;
    fmCache.set(p, relations);
  }
  const candidates = [];
  const sortedPages = [...pagesInScope].sort();
  for (let i = 0; i < sortedPages.length; i++) {
    const a = sortedPages[i];
    const relA = fmCache.get(a);
    if (!relA) continue;
    for (let j = i + 1; j < sortedPages.length; j++) {
      const b = sortedPages[j];
      const relB = fmCache.get(b);
      if (!relB) continue;
      for (const key of Object.keys(relA)) {
        if (!Array.isArray(relA[key]) || !Array.isArray(relB[key])) continue;
        const setA = new Set(relA[key]);
        const setB = new Set(relB[key]);
        const shared = [...setA].filter(t => setB.has(t)).sort();
        const aOnly  = [...setA].filter(t => !setB.has(t)).sort();
        const bOnly  = [...setB].filter(t => !setA.has(t)).sort();
        if (shared.length > 0 && (aOnly.length > 0 || bOnly.length > 0)) {
          candidates.push({
            pages: [a, b], // already sorted (a < b)
            signal: 'conflicting-relations',
            signal_data: {
              relation: key,
              shared_targets: shared,
              a_only_targets: aOnly,
              b_only_targets: bOnly,
            },
          });
        }
      }
    }
  }
  return candidates;
}

// Canonical dedupe key for a candidate: (pages-sorted, signal, signal_data-sorted-json).
function candidateKey(c) {
  // signal_data lists were already sorted at emission time, but be defensive.
  const sd = JSON.parse(JSON.stringify(c.signal_data));
  for (const k of Object.keys(sd)) {
    if (Array.isArray(sd[k])) sd[k] = [...sd[k]].sort();
  }
  return JSON.stringify([c.pages, c.signal, sd]);
}

const NEIGHBOUR_CAP = 50;

// Given a set of seed pages, expand by one hop through outbound wikilinks
// (body prose) and frontmatter relations targets. Cap at NEIGHBOUR_CAP total
// pages (seeds + neighbours). Returns the capped page set + a `truncated` bool.
function expandOneHop(vault, seeds) {
  const out = new Set(seeds);
  const visited = new Set();
  let truncated = false;
  for (const seed of seeds) {
    if (visited.has(seed)) continue;
    visited.add(seed);
    const links = extractBodyWikilinks(vault, seed);
    const fm = readFrontmatter(path.join(vault, seed));
    if (fm && typeof fm.relations === 'object' && fm.relations) {
      for (const targets of Object.values(fm.relations)) {
        if (!Array.isArray(targets)) continue;
        for (const t of targets) {
          if (typeof t !== 'string') continue;
          const r = resolveWikilinkTarget(vault, t);
          if (r) links.add(r);
        }
      }
    }
    for (const link of links) {
      if (out.size >= NEIGHBOUR_CAP) {
        truncated = true;
        break;
      }
      out.add(link);
    }
    if (truncated) break;
  }
  return { pages: [...out], truncated };
}

function cmdCandidates(vault, args) {
  const scope = args.scope || 'wiki/';
  let pages;
  let truncated = false;
  if (scope.endsWith('.md') || scope.includes(',')) {
    // Page-list scope: comma-separated vault-relative .md paths.
    const seeds = scope.split(',').map(s => s.trim()).filter(Boolean);
    for (const s of seeds) {
      if (!s.endsWith('.md') || !fs.existsSync(path.join(vault, s))) {
        die(`candidates: page not found in vault: ${s}`, 3);
      }
    }
    const exp = expandOneHop(vault, seeds);
    pages = exp.pages;
    truncated = exp.truncated;
  } else {
    // Directory scope: walk wiki/ content dirs.
    pages = [...walkWikiMarkdown(vault)];
  }
  if (truncated) {
    process.stderr.write(`warning: neighbour expansion truncated at K=${NEIGHBOUR_CAP}\n`);
  }
  const fresh = [
    ...signalConflictingRelations(vault, pages),
    ...signalSharedEntityProse(vault, pages),
  ];
  if (args.json) {
    process.stdout.write(JSON.stringify({ candidates: fresh }, null, 2) + '\n');
    return;
  }
  const doc = readState(vault) || emptyState();
  const existing = new Set(doc.contradictions.map(e =>
    candidateKey({ pages: e.pages, signal: e.signal, signal_data: e.signal_data })
  ));
  let added = 0, skipped = 0;
  for (const c of fresh) {
    const key = candidateKey(c);
    if (existing.has(key)) { skipped += 1; continue; }
    existing.add(key);
    const id = allocateId(doc);
    doc.contradictions.push({
      id,
      detected_at: nowIso(),
      pages: c.pages,
      signal: c.signal,
      signal_data: c.signal_data,
      status: 'unjudged',
    });
    added += 1;
  }
  if (added > 0) writeState(vault, doc);
  process.stdout.write(`enqueued ${added} new, skipped ${skipped} already-known\n`);
}

function findEntry(doc, id) {
  return doc.contradictions.find(e => e.id === id) || null;
}

function cmdJudge(vault, args) {
  if (!args.id) die('judge: --id is required', 2);
  if (!args.verdict) die('judge: --verdict is required', 2);
  if (!args.data) die('judge: --data is required', 2);
  if (args.verdict !== 'real-contradiction' && args.verdict !== 'not-a-contradiction') {
    die(`judge: --verdict must be 'real-contradiction' or 'not-a-contradiction', got ${args.verdict}`, 2);
  }
  let payload;
  try { payload = JSON.parse(args.data); }
  catch (err) { die(`judge: --data is not valid JSON: ${err.message}`, 2); }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    die('judge: --data must be a JSON object', 2);
  }
  const doc = readState(vault);
  if (!doc) die(`judge: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`judge: id ${args.id} not found`, 3);
  if (entry.status !== 'unjudged') {
    die(`judge: entry ${args.id} status is ${entry.status}, expected unjudged`, 3);
  }
  // Validate payload shape per verdict.
  const judgment = { verdict: args.verdict, at: nowIso() };
  if (args.verdict === 'real-contradiction') {
    if (typeof payload.claim !== 'string' || !payload.claim) {
      die('judge: --data.claim must be a non-empty string', 2);
    }
    if (!Array.isArray(payload.assertions) || payload.assertions.length === 0) {
      die('judge: --data.assertions must be a non-empty array', 2);
    }
    if (typeof payload.rationale !== 'string' || !payload.rationale) {
      die('judge: --data.rationale must be a non-empty string', 2);
    }
    judgment.claim = payload.claim;
    judgment.assertions = payload.assertions;
    judgment.rationale = payload.rationale;
    entry.status = 'unresolved';
  } else {
    if (typeof payload.rationale !== 'string' || !payload.rationale) {
      die('judge: --data.rationale must be a non-empty string', 2);
    }
    judgment.rationale = payload.rationale;
    entry.status = 'not-a-contradiction';
  }
  entry.judgment = judgment;
  writeState(vault, doc);
  process.stdout.write(`${args.id}: ${entry.status}\n`);
}

// Split a page's body (everything after the frontmatter fence) into
// paragraphs by double-newline. Returns { head, paragraphs, sep } where
// head is the frontmatter fence + leading blank line, paragraphs is the
// array of body paragraphs (no trailing newlines), and sep is the
// paragraph separator (always `\n\n`).
function splitPageBody(text) {
  const m = text.match(/^(---\r?\n[\s\S]*?\r?\n---\r?\n\r?\n?)([\s\S]*)$/);
  if (!m) return { head: '', paragraphs: text.split(/\r?\n\r?\n/), sep: '\n\n' };
  return {
    head: m[1],
    paragraphs: m[2].split(/\r?\n\r?\n/),
    sep: '\n\n',
  };
}

// Find the paragraph index in `paragraphs` that contains `needle` as a
// substring. Returns the (singular) index, or { error: 'zero' | 'multi', count }.
function locateAssertionParagraph(paragraphs, needle) {
  const matches = [];
  for (let i = 0; i < paragraphs.length; i++) {
    if (paragraphs[i].includes(needle)) matches.push(i);
  }
  if (matches.length === 0) return { error: 'zero', count: 0 };
  if (matches.length > 1)  return { error: 'multi', count: matches.length };
  return { index: matches[0] };
}

// Re-serialise frontmatter + body. Mutates the parsed frontmatter via `mutate`,
// then writes the new file content. Preserves the exact head shape (---\n...---\n)
// and uses CORE_SCHEMA dumping to keep quoting predictable.
function updateFrontmatter(absPath, mutate) {
  const text = fs.readFileSync(absPath, 'utf8');
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/);
  if (!m) throw new Error(`no frontmatter in ${absPath}`);
  const fm = yaml.load(m[1], { schema: yaml.CORE_SCHEMA }) || {};
  mutate(fm);
  const dumped = yaml.dump(fm, { indent: 2, sortKeys: false, lineWidth: -1 }).trimEnd();
  fs.writeFileSync(absPath, `---\n${dumped}\n---\n${m[2]}`);
}

// Run a child process synchronously in `vault`. Returns { status, stdout, stderr }.
function run(vault, cmd, args) {
  const r = spawnSync(cmd, args, { cwd: vault, encoding: 'utf8' });
  if (r.error) die(`${cmd} failed to spawn: ${r.error.message}`, 2);
  return { status: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

function gitHeadSha(vault) {
  const r = run(vault, 'git', ['rev-parse', 'HEAD']);
  if (r.status !== 0) die(`git rev-parse HEAD failed: ${r.stderr}`, 2);
  return r.stdout.trim();
}

function validateWikiAll(vault) {
  const validate = path.join(__dirname, 'validate-wiki.js');
  return run(vault, 'node', [validate, 'all']);
}

function revertHead(vault) {
  const r = run(vault, 'git', ['revert', '--no-edit', 'HEAD']);
  if (r.status !== 0) die(`git revert failed: ${r.stderr}`, 2);
}

function cmdApplyPick(vault, args) {
  if (!args.id) die('apply-pick: --id is required', 2);
  if (!args['winning-page']) die('apply-pick: --winning-page is required', 2);
  if (!args.rewrite) die('apply-pick: --rewrite is required', 2);
  const winning = args['winning-page'];
  const rewritePath = args.rewrite;
  if (!fs.existsSync(rewritePath)) die(`apply-pick: --rewrite tmpfile not found: ${rewritePath}`, 2);

  const doc = readState(vault);
  if (!doc) die(`apply-pick: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-pick: id ${args.id} not found`, 3);
  if (entry.status !== 'unresolved' && entry.status !== 'deferred') {
    die(`apply-pick: entry ${args.id} status is ${entry.status}, expected unresolved or deferred`, 3);
  }
  if (!entry.pages.includes(winning)) {
    die(`apply-pick: --winning-page ${winning} is not in entry pages ${JSON.stringify(entry.pages)}`, 3);
  }
  const losing = entry.pages.find(p => p !== winning);
  // Index of winning in entry.pages decides pick-a vs pick-b.
  const winningIdx = entry.pages.indexOf(winning);
  const verdictKind = winningIdx === 0 ? 'resolved-pick-a' : 'resolved-pick-b';

  const losingAbs = path.join(vault, losing);
  if (!fs.existsSync(losingAbs)) die(`apply-pick: losing page not found on disk: ${losing}`, 3);

  // Locate the assertion paragraph in the losing page.
  const losingAssertion = (entry.judgment?.assertions || []).find(a => a.page === losing);
  if (!losingAssertion) die(`apply-pick: judgment.assertions has no entry for losing page ${losing}`, 3);
  const losingText = fs.readFileSync(losingAbs, 'utf8');
  const split = splitPageBody(losingText);
  const located = locateAssertionParagraph(split.paragraphs, losingAssertion.text);
  if (located.error === 'zero')  die(`apply-pick: assertion substring matched 0 paragraphs in ${losing}`, 3);
  if (located.error === 'multi') die(`apply-pick: assertion substring matched ${located.count} paragraphs in ${losing}`, 3);

  // Swap the matched paragraph with the rewrite content (trim trailing newlines).
  const newPara = fs.readFileSync(rewritePath, 'utf8').replace(/\r?\n+$/, '');
  split.paragraphs[located.index] = newPara;
  const newBody = split.paragraphs.join(split.sep);
  fs.writeFileSync(losingAbs, split.head + newBody);

  // Sources dedup: append winning's sources to losing's, dedupe, bump updated.
  const winningAbs = path.join(vault, winning);
  const winningFm = readFrontmatter(winningAbs) || {};
  const winningSources = Array.isArray(winningFm.sources) ? winningFm.sources : [];
  const appended = [];
  updateFrontmatter(losingAbs, (fm) => {
    fm.sources = Array.isArray(fm.sources) ? [...fm.sources] : [];
    for (const s of winningSources) {
      if (!fm.sources.includes(s)) {
        fm.sources.push(s);
        appended.push(s);
      }
    }
    fm.updated = todayDate();
  });

  // Commit.
  const claim = entry.judgment?.claim || '(unknown)';
  const commitMsg = `reconcile: pick ${winning} over ${losing} on ${claim}`;
  const add = run(vault, 'git', ['add', losing]);
  if (add.status !== 0) die(`git add failed: ${add.stderr}`, 2);
  const commit = run(vault, 'git', ['commit', '-m', commitMsg]);
  if (commit.status !== 0) die(`git commit failed: ${commit.stderr}`, 2);

  // Post-check.
  const check = validateWikiAll(vault);
  if (check.status === 2) {
    revertHead(vault);
    process.stderr.write(`apply-pick: validate-wiki structural failure — reverted\n${check.stderr}`);
    process.exit(2);
  }
  const sha = gitHeadSha(vault);

  // Yaml update: transition + resolution block.
  entry.status = verdictKind;
  entry.resolution = {
    at: nowIso(),
    picked_page: winning,
    edited_page: losing,
    commit: sha,
    sources_appended_to_edited: appended,
  };
  writeState(vault, doc);

  process.stdout.write(`${sha}\n`);
}

function addContradictsRelation(absPath, otherPage) {
  let appended = false;
  updateFrontmatter(absPath, (fm) => {
    if (!fm.relations || typeof fm.relations !== 'object') fm.relations = {};
    const list = Array.isArray(fm.relations.contradicts) ? [...fm.relations.contradicts] : [];
    if (!list.includes(otherPage)) {
      list.push(otherPage);
      appended = true;
    }
    fm.relations.contradicts = list;
    fm.updated = todayDate();
  });
  return appended;
}

function cmdApplyAccept(vault, args) {
  if (!args.id) die('apply-accept: --id is required', 2);
  const doc = readState(vault);
  if (!doc) die(`apply-accept: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`apply-accept: id ${args.id} not found`, 3);
  if (entry.status !== 'unresolved' && entry.status !== 'deferred') {
    die(`apply-accept: entry ${args.id} status is ${entry.status}, expected unresolved or deferred`, 3);
  }
  const [a, b] = entry.pages;
  const aAbs = path.join(vault, a);
  const bAbs = path.join(vault, b);
  if (!fs.existsSync(aAbs)) die(`apply-accept: page not found: ${a}`, 3);
  if (!fs.existsSync(bAbs)) die(`apply-accept: page not found: ${b}`, 3);

  addContradictsRelation(aAbs, b);
  addContradictsRelation(bAbs, a);

  const claim = entry.judgment?.claim || '(unknown)';
  const commitMsg = `reconcile: accept-disagreement on ${claim}`;
  const add = run(vault, 'git', ['add', a, b]);
  if (add.status !== 0) die(`git add failed: ${add.stderr}`, 2);
  const commit = run(vault, 'git', ['commit', '-m', commitMsg]);
  if (commit.status !== 0) die(`git commit failed: ${commit.stderr}`, 2);

  const check = validateWikiAll(vault);
  if (check.status === 2) {
    revertHead(vault);
    process.stderr.write(`apply-accept: validate-wiki structural failure — reverted\n${check.stderr}`);
    process.exit(2);
  }
  const sha = gitHeadSha(vault);

  entry.status = 'accepted-disagreement';
  entry.resolution = {
    at: nowIso(),
    commit: sha,
  };
  writeState(vault, doc);
  process.stdout.write(`${sha}\n`);
}

function cmdResolve(vault, args) {
  if (!args.id) die('resolve: --id is required', 2);
  if (!args.kind) die('resolve: --kind is required', 2);
  if (args.kind !== 'defer') {
    die(`resolve: unsupported --kind ${args.kind} (v1 only supports defer; picks flow through apply-pick / apply-accept)`, 2);
  }
  const doc = readState(vault);
  if (!doc) die(`resolve: ${STATE_FILE} not found`, 3);
  const entry = findEntry(doc, args.id);
  if (!entry) die(`resolve: id ${args.id} not found`, 3);
  if (entry.status !== 'unresolved' && entry.status !== 'deferred') {
    die(`resolve: entry ${args.id} status is ${entry.status}, expected unresolved or deferred`, 3);
  }
  entry.status = 'deferred';
  entry.deferred_at = nowIso();
  writeState(vault, doc);
  process.stdout.write(`${args.id}: deferred\n`);
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) die('usage: contradictions.js <subcommand> [args]', 2);
  const cmd = argv[0];
  const args = parseArgs(argv.slice(1));
  const vault = findVaultRoot(process.cwd());
  if (!vault) die('not in a second-brain vault (run /second-brain:onboard first)', 2);
  switch (cmd) {
    case 'candidates':   return cmdCandidates(vault, args);
    case 'list':         return cmdList(vault, args);
    case 'judge':        return cmdJudge(vault, args);
    case 'resolve':      return cmdResolve(vault, args);
    case 'apply-pick':   return cmdApplyPick(vault, args);
    case 'apply-accept': return cmdApplyAccept(vault, args);
    default:             die(`unknown subcommand: ${cmd}`, 2);
  }
}

main();
