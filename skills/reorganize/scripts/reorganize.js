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

// Refuse any path that isn't inside wiki/. Spec §5.4.
function requireWikiPath(label, vaultPath) {
  if (!vaultPath || !vaultPath.startsWith('wiki/')) {
    die(`reorganize only operates on wiki/, got ${label}=${vaultPath}`, 3);
  }
}

function todayUtc() {
  return new Date().toISOString().slice(0, 10);
}

// Read a markdown file's frontmatter block plus the body that follows.
// Returns { frontmatter: object, body: string, raw: string } or throws if
// no leading `---` block. Uses CORE_SCHEMA so dates stay as strings — same
// rule as scripts/validate-wiki.js.
function readPage(absPath) {
  const text = fs.readFileSync(absPath, 'utf8');
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/);
  if (!m) throw new Error(`no frontmatter in ${absPath}`);
  const fm = yaml.load(m[1], { schema: yaml.CORE_SCHEMA }) || {};
  return { frontmatter: fm, body: m[2], raw: text };
}

// Write a markdown file by serialising frontmatter through js-yaml.dump and
// concatenating the body verbatim. Preserves the frontmatter's existing key
// order because js-yaml preserves insertion order.
//
// `flowLevel: 1` keeps depth-1 lists inline (`tags: [demo]`,
// `sources: [raw/x.md]`) so a move that only touches one relation does not
// re-flow every other key into block style. The visual cost is that the
// `relations:` map also collapses to one line (`relations: {see-also: [...]}`)
// rather than the multi-line layout in CR-005 §4.1 — functionally identical
// and revalidates cleanly.
//
// `schema: CORE_SCHEMA` matches readPage so YAML 1.1-style timestamps like
// `2026-05-20` are treated as plain strings on both sides — without it, dump
// would emit `updated: '2026-05-20'` (quoted) to disambiguate from a YAML
// timestamp, which is functionally identical but visually noisy and trips
// downstream string-equality checks.
function writePage(absPath, page) {
  const dump = yaml.dump(page.frontmatter, { lineWidth: -1, sortKeys: false, flowLevel: 1, schema: yaml.CORE_SCHEMA });
  fs.writeFileSync(absPath, `---\n${dump}---\n${page.body}`);
}

// Walk wiki/ once and return vault-relative .md paths.
function* walkMarkdown(vault, subdir) {
  const abs = path.join(vault, subdir);
  if (!fs.existsSync(abs)) return;
  for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const child = path.join(subdir, entry.name);
    if (entry.isDirectory()) yield* walkMarkdown(vault, child);
    else if (entry.isFile() && entry.name.endsWith('.md'))
      yield child.split(path.sep).join('/');
  }
}

// Drop the `.md` suffix from a vault path (`wiki/concepts/foo.md` → `wiki/concepts/foo`).
function stripMd(vaultPath) {
  return vaultPath.endsWith('.md') ? vaultPath.slice(0, -3) : vaultPath;
}

// Rewrite every wikilink and every `relations:` target in every wiki/*.md
// (except wiki/index.md) that resolves to `fromPath` so it points at `toPath`.
// `fromPath` and `toPath` are both vault-relative `.md` paths.
//
// Three rewrite forms handled:
//   1. `[[basename]]` (and `[[basename|alias]]`) — rewritten only when the
//      basename uniquely resolves to fromPath under the validator's resolver.
//      We avoid false positives by recomputing the bare-name index AFTER each
//      rewrite call's filesystem effects are in place; callers do the rename
//      THEN call linkRewrite.
//   2. `[[wiki/path/to/page]]` (and `[[wiki/path/to/page|alias]]`) — rewritten
//      when the embedded path equals stripMd(fromPath).
//   3. Frontmatter `relations: { rel: [...targets] }` — each target string is
//      treated the same way as (2) when it starts with `wiki/`, or as (1)
//      when it's a bare name.
//
// Does NOT touch frontmatter `sources:` — those are filename identities, not
// wikilink references (spec §6.2, test §10.1.4).
const WIKILINK_RE = /\[\[([^\]\n|]+)(\|[^\]\n]*)?\]\]/g;

function linkRewrite(vault, fromPath, toPath) {
  const fromStripped = stripMd(fromPath);
  const toStripped = stripMd(toPath);
  const fromBasename = path.basename(fromStripped).toLowerCase();
  const toBasename = path.basename(toStripped);

  // Build a bare-name → resolved-path map so we only rewrite bare names
  // that uniquely resolve to fromPath. This protects against basename
  // collisions in other folders.
  const bareIndex = new Map();
  for (const rel of walkMarkdown(vault, 'wiki')) {
    bareIndex.set(path.basename(rel, '.md').toLowerCase(), rel);
  }
  const bareIsAmbiguous = bareIndex.get(fromBasename) !== fromPath;

  function rewriteTarget(target) {
    const trimmed = target.trim();
    if (trimmed.startsWith('wiki/')) {
      // Path form: exact match against stripMd(fromPath).
      if (trimmed === fromStripped) return toStripped;
      return target;
    }
    if (trimmed.startsWith('src/documentation/')) return target;
    // Bare form: only rewrite if the basename resolves to fromPath.
    if (!bareIsAmbiguous && trimmed.toLowerCase() === fromBasename) return toBasename;
    return target;
  }

  for (const rel of walkMarkdown(vault, 'wiki')) {
    if (rel === 'wiki/index.md') continue;          // index handled per-subcommand
    if (rel === toPath) continue;                   // skip the moved file itself if it already lives at toPath
    const abs = path.join(vault, rel);
    let page;
    try { page = readPage(abs); }
    catch { continue; }                              // files without frontmatter (e.g. wiki/log.md) — skip
    let changed = false;

    // 1) Rewrite prose wikilinks in the body.
    const newBody = page.body.replace(WIKILINK_RE, (full, target, aliasPart) => {
      const rewritten = rewriteTarget(target);
      if (rewritten === target) return full;
      changed = true;
      return `[[${rewritten}${aliasPart || ''}]]`;
    });
    page.body = newBody;

    // 2) Rewrite `relations:` targets in the frontmatter, if present.
    if (page.frontmatter && page.frontmatter.relations && typeof page.frontmatter.relations === 'object') {
      for (const [key, targets] of Object.entries(page.frontmatter.relations)) {
        if (!Array.isArray(targets)) continue;
        const next = targets.map(t => (typeof t === 'string' ? rewriteTarget(t) : t));
        if (next.some((v, i) => v !== targets[i])) {
          page.frontmatter.relations[key] = next;
          changed = true;
        }
      }
    }

    if (changed) writePage(abs, page);
  }
}

// Rewrite the row for `[[fromTarget]]` in wiki/index.md to point at `toTarget`.
// Preserves any "— summary" suffix. No-op if no row matches.
function indexRewriteRow(vault, fromTarget, toTarget) {
  const idxPath = path.join(vault, 'wiki', 'index.md');
  if (!fs.existsSync(idxPath)) return;
  const lines = fs.readFileSync(idxPath, 'utf8').split(/\r?\n/);
  const fromRe = new RegExp(`\\[\\[${escapeRegex(fromTarget)}(\\|[^\\]]*)?\\]\\]`);
  let changed = false;
  for (let i = 0; i < lines.length; i++) {
    if (fromRe.test(lines[i])) {
      lines[i] = lines[i].replace(fromRe, `[[${toTarget}]]`);
      changed = true;
    }
  }
  if (changed) fs.writeFileSync(idxPath, lines.join('\n'));
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function cmdMovePage(vault, args) {
  requireWikiPath('--from', args.from);
  requireWikiPath('--to', args.to);
  const fromAbs = path.join(vault, args.from);
  const toAbs = path.join(vault, args.to);
  if (!fs.existsSync(fromAbs)) die(`--from does not exist: ${args.from}`, 3);
  if (fs.existsSync(toAbs)) die(`--to already exists: ${args.to}`, 3);

  // Rewrite inbound references BEFORE the rename. linkRewrite builds its
  // bare-name resolver from the current filesystem; if we rename first the
  // resolver can no longer find fromPath and would skip every `[[basename]]`
  // rewrite.
  linkRewrite(vault, args.from, args.to);

  // Bump `updated:` on the source page, then rename.
  const moved = readPage(fromAbs);
  moved.frontmatter.updated = todayUtc();
  writePage(fromAbs, moved);
  fs.mkdirSync(path.dirname(toAbs), { recursive: true });
  fs.renameSync(fromAbs, toAbs);

  // Update the index row.
  indexRewriteRow(vault, stripMd(args.from), stripMd(args.to));

  // Commit.
  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: move ${args.from} → ${args.to}`], vault);
}

// Drop any row in wiki/index.md whose wikilink target matches `target` (a
// stripped vault path). Used by merge-page to delete the absorbed page's row
// while leaving the survivor's row untouched.
function indexDropRow(vault, target) {
  const idxPath = path.join(vault, 'wiki', 'index.md');
  if (!fs.existsSync(idxPath)) return;
  const lines = fs.readFileSync(idxPath, 'utf8').split(/\r?\n/);
  const re = new RegExp(`\\[\\[${escapeRegex(target)}(\\|[^\\]]*)?\\]\\]`);
  const kept = lines.filter(line => !re.test(line));
  if (kept.length !== lines.length) {
    fs.writeFileSync(idxPath, kept.join('\n'));
  }
}

function cmdMergePage(vault, args) {
  requireWikiPath('--from', args.from);
  requireWikiPath('--into', args.into);
  if (!args['merged-body']) die('--merged-body is required', 1);
  const fromAbs = path.join(vault, args.from);
  const intoAbs = path.join(vault, args.into);
  if (!fs.existsSync(fromAbs)) die(`--from does not exist: ${args.from}`, 3);
  if (!fs.existsSync(intoAbs)) die(`--into does not exist: ${args.into}`, 3);
  const tmp = args['merged-body'];
  if (!fs.existsSync(tmp)) die(`--merged-body file does not exist: ${tmp}`, 3);

  // Body-length sanity. Compare body lengths (not whole files) so frontmatter
  // does not skew the threshold. Do this BEFORE any mutations so the measured
  // lengths are the originals.
  const fromBody = readPage(fromAbs).body;
  const intoBodyPre = readPage(intoAbs).body;
  const mergedBody = fs.readFileSync(tmp, 'utf8');
  const floor = Math.floor(Math.max(fromBody.length, intoBodyPre.length) * 0.5);
  if (mergedBody.length < floor) {
    die(`merged body suspiciously short — refusing merge (got ${mergedBody.length} bytes, expected ≥ ${floor})`, 3);
  }

  // Replace into's body, bump `updated:`.
  const into = readPage(intoAbs);
  into.body = mergedBody;
  into.frontmatter.updated = todayUtc();
  writePage(intoAbs, into);

  // Rewrite inbound references BEFORE deleting `from`. linkRewrite's bare-name
  // resolver walks the current filesystem; if we delete `from` first the
  // resolver can no longer find it and `[[fromBasename]]` rewrites silently
  // skip.
  linkRewrite(vault, args.from, args.into);

  // Delete from.
  fs.unlinkSync(fromAbs);

  // Drop the dead index row.
  indexDropRow(vault, stripMd(args.from));

  // Commit.
  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: merge ${args.from} into ${args.into}`], vault);
}

function cmdMarkCovered(vault, args) {
  requireWikiPath('--page', args.page);
  if (!args.by) die('--by is required', 1);
  requireWikiPath('--by', args.by);
  const abs = path.join(vault, args.page);
  if (!fs.existsSync(abs)) die(`--page does not exist: ${args.page}`, 3);

  const page = readPage(abs);
  page.frontmatter.updated = todayUtc();
  const note = `\n> **Covered by [[${args.by}]]** — see that page for current synthesis.\n`;
  page.body = page.body.endsWith('\n') ? page.body + note : page.body + '\n' + note;
  writePage(abs, page);

  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: mark ${args.page} covered by ${args.by}`], vault);
}

// Map a wiki-path prefix to the index section header it belongs under.
function indexSectionFor(vaultPath) {
  if (vaultPath.startsWith('wiki/sources/'))    return '## Sources';
  if (vaultPath.startsWith('wiki/entities/'))   return '## Entities';
  if (vaultPath.startsWith('wiki/concepts/'))   return '## Concepts';
  if (vaultPath.startsWith('wiki/synthesis/'))  return '## Synthesis';
  return null;
}

// Append a row line to wiki/index.md under the section matching `header`.
// The row is inserted immediately after the section header (and any blank
// line that follows it), before the next section header or end-of-file.
function indexAppendRow(vault, header, row) {
  const idxPath = path.join(vault, 'wiki', 'index.md');
  if (!fs.existsSync(idxPath)) die(`wiki/index.md missing`, 2);
  const lines = fs.readFileSync(idxPath, 'utf8').split(/\r?\n/);
  const start = lines.findIndex(l => l.trim() === header);
  if (start === -1) die(`index missing section ${header}`, 2);
  // Find the end of this section: next `## ` header or end-of-file.
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##\s/.test(lines[i])) { end = i; break; }
  }
  // Insert just before the section's end; keep one blank line between the
  // section's last row (if any) and the next header.
  let insertAt = end;
  while (insertAt > start + 1 && lines[insertAt - 1].trim() === '') insertAt--;
  lines.splice(insertAt, 0, row);
  fs.writeFileSync(idxPath, lines.join('\n'));
}

function cmdParentCreate(vault, args) {
  requireWikiPath('--page', args.page);
  if (!args.body) die('--body is required', 1);
  if (!args.children) die('--children is required', 1);
  const abs = path.join(vault, args.page);
  if (fs.existsSync(abs)) die(`--page already exists: ${args.page}`, 3);
  if (!fs.existsSync(args.body)) die(`--body file does not exist: ${args.body}`, 3);

  const children = args.children.split(',').map(s => s.trim()).filter(Boolean);
  for (const c of children) requireWikiPath('--children entry', c);

  // Read provided body, append `## Children`.
  const bodyText = fs.readFileSync(args.body, 'utf8');
  const childrenSection = `\n## Children\n\n` +
    children.map(c => `- [[${c}]]`).join('\n') + '\n';
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, bodyText.endsWith('\n') ? bodyText + childrenSection : bodyText + '\n' + childrenSection);

  // Add an index row under the matching section.
  const section = indexSectionFor(args.page);
  if (!section) die(`cannot derive index section from ${args.page}`, 3);
  indexAppendRow(vault, section, `- [[${stripMd(args.page)}]]`);

  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: introduce parent ${args.page}`], vault);
}

function cmdRelationsAdd(vault, args) {
  requireWikiPath('--page', args.page);
  if (!args.relation) die('--relation is required', 1);
  if (!args.targets) die('--targets is required', 1);
  const abs = path.join(vault, args.page);
  if (!fs.existsSync(abs)) die(`--page does not exist: ${args.page}`, 3);

  const newTargets = args.targets.split(',').map(s => s.trim()).filter(Boolean);

  const page = readPage(abs);
  if (!page.frontmatter.relations || typeof page.frontmatter.relations !== 'object') {
    page.frontmatter.relations = {};
  }
  const existing = Array.isArray(page.frontmatter.relations[args.relation])
    ? page.frontmatter.relations[args.relation] : [];
  const seen = new Set(existing);
  const merged = [...existing];
  for (const t of newTargets) {
    if (!seen.has(t)) { merged.push(t); seen.add(t); }
  }
  page.frontmatter.relations[args.relation] = merged;
  page.frontmatter.updated = todayUtc();
  writePage(abs, page);

  git(['add', '--', 'wiki/'], vault);
  git(['commit', '-m', `reorganize: type relations on ${args.page}`], vault);
}

function cmdValidateOrRevert(vault) {
  // Resolve the validator path relative to this script's location so it
  // works whether invoked via $CLAUDE_PLUGIN_ROOT or from a worktree.
  const validator = path.resolve(__dirname, '..', '..', '..', 'scripts', 'validate-wiki.js');
  const r = spawnSync('node', [validator, 'all'], { cwd: vault, encoding: 'utf8' });
  // The validator writes its own diagnostics to stderr; surface them.
  if (r.stderr) process.stderr.write(r.stderr);
  if (r.stdout) process.stdout.write(r.stdout);
  const code = r.status;
  if (code === 0) return process.exit(0);
  if (code === 1) return process.exit(1);
  if (code === 2) {
    git(['revert', 'HEAD', '--no-edit'], vault);
    return process.exit(2);
  }
  return process.exit(code || 1);
}

// ---------- candidates: shared helpers ----------

// Per-page summary used by every kind:
// { path, tags: Set<string>, outgoing: Set<string> (resolved vault-rel paths) }
function summariseScope(vault, scope) {
  const pages = [...walkMarkdown(vault, scope)];
  // Build a bare-name → resolved-path map for outgoing-link resolution.
  const bareIndex = new Map();
  for (const rel of walkMarkdown(vault, 'wiki')) {
    bareIndex.set(path.basename(rel, '.md').toLowerCase(), rel);
  }
  function resolveTarget(target) {
    if (target.startsWith('wiki/')) {
      return fs.existsSync(path.join(vault, target + '.md')) ? target + '.md' : null;
    }
    if (target.startsWith('src/documentation/')) {
      return fs.existsSync(path.join(vault, target + '.md')) ? target + '.md' : null;
    }
    return bareIndex.get(target.toLowerCase()) || null;
  }
  const out = [];
  for (const rel of pages) {
    const abs = path.join(vault, rel);
    let page;
    try { page = readPage(abs); }
    catch { continue; }
    const tags = new Set(Array.isArray(page.frontmatter.tags) ? page.frontmatter.tags : []);
    const outgoing = new Set();
    const text = page.body;
    let m;
    WIKILINK_RE.lastIndex = 0;
    while ((m = WIKILINK_RE.exec(text)) !== null) {
      const target = m[1].trim();
      const resolved = resolveTarget(target);
      if (resolved && resolved !== rel) outgoing.add(resolved);
    }
    out.push({ path: rel, tags, outgoing });
  }
  return out;
}

function setIntersectionSize(a, b) {
  let n = 0;
  for (const x of a) if (b.has(x)) n++;
  return n;
}

// ---------- candidates: merge ----------

const MERGE_SHARED_WIKILINKS_THRESHOLD = 5;

function candidatesMerge(vault, scope) {
  const pages = summariseScope(vault, scope);
  const pairs = [];
  for (let i = 0; i < pages.length; i++) {
    for (let j = i + 1; j < pages.length; j++) {
      const a = pages[i], b = pages[j];
      const shared = setIntersectionSize(a.outgoing, b.outgoing);
      if (shared < MERGE_SHARED_WIKILINKS_THRESHOLD) continue;
      const sharedTags = setIntersectionSize(a.tags, b.tags);
      pairs.push({
        a: a.path,
        b: b.path,
        shared_wikilinks: shared,
        shared_tags: sharedTags,
      });
    }
  }
  pairs.sort((x, y) => y.shared_wikilinks - x.shared_wikilinks);
  return { pairs };
}

// ---------- candidates: parent ----------

const PARENT_PAIR_THRESHOLD = 3;
const PARENT_MIN_MEMBERS = 3;

function candidatesParent(vault, scope) {
  const pages = summariseScope(vault, scope);
  // Group by tag (each page can be in multiple tag groups).
  const byTag = new Map();
  for (const p of pages) {
    for (const tag of p.tags) {
      if (!byTag.has(tag)) byTag.set(tag, []);
      byTag.get(tag).push(p);
    }
  }
  const clusters = [];
  for (const [tag, members] of byTag) {
    if (members.length < PARENT_MIN_MEMBERS) continue;
    // All-pairs check: every pair must hit the threshold.
    let allOk = true;
    let totalShared = 0;
    for (let i = 0; i < members.length && allOk; i++) {
      for (let j = i + 1; j < members.length && allOk; j++) {
        const shared = setIntersectionSize(members[i].outgoing, members[j].outgoing);
        if (shared < PARENT_PAIR_THRESHOLD) { allOk = false; break; }
        totalShared += shared;
      }
    }
    if (!allOk) continue;
    clusters.push({
      members: members.map(m => m.path),
      shared_wikilinks: totalShared,
      shared_tag: tag,
    });
  }
  clusters.sort((x, y) => y.shared_wikilinks - x.shared_wikilinks);
  return { clusters };
}

// ---------- candidates: recategorize ----------

const RECAT_SOURCES_THRESHOLD = 3;
const RECAT_CONCEPT_OUTLINKS_THRESHOLD = 2;

function candidatesRecategorize(vault, scope) {
  const pages = summariseScope(vault, scope);
  const out = [];
  for (const p of pages) {
    if (!p.path.startsWith('wiki/concepts/')) continue;
    const abs = path.join(vault, p.path);
    const page = readPage(abs);
    const sources = Array.isArray(page.frontmatter.sources) ? page.frontmatter.sources : [];
    if (sources.length < RECAT_SOURCES_THRESHOLD) continue;
    // Count outgoing links to other wiki/concepts/ pages.
    let conceptOut = 0;
    for (const r of p.outgoing) {
      if (r.startsWith('wiki/concepts/') && r !== p.path) conceptOut++;
    }
    if (conceptOut < RECAT_CONCEPT_OUTLINKS_THRESHOLD) continue;
    out.push({
      path: p.path,
      current_dir: 'concepts',
      signals: { sources_count: sources.length, synthesises_others: true },
    });
  }
  out.sort((a, b) => b.signals.sources_count - a.signals.sources_count);
  return { pages: out };
}

// ---------- candidates: cover ----------

const COVER_SHARED_WIKILINKS_THRESHOLD = 5;

function candidatesCover(vault, scope) {
  const pages = summariseScope(vault, scope);
  const sources = pages.filter(p => p.path.startsWith('wiki/sources/'));
  const synths  = pages.filter(p => p.path.startsWith('wiki/synthesis/'));
  const out = [];
  for (const s of sources) {
    const covers = [];
    let topShared = 0;
    for (const y of synths) {
      const shared = setIntersectionSize(s.outgoing, y.outgoing);
      if (shared >= COVER_SHARED_WIKILINKS_THRESHOLD) {
        covers.push({ path: y.path, shared });
      }
    }
    if (covers.length === 0) continue;
    covers.sort((a, b) => b.shared - a.shared);
    topShared = covers[0].shared;
    out.push({
      path: s.path,
      candidate_covers: covers.map(c => c.path),
      shared_wikilinks: topShared,
    });
  }
  out.sort((a, b) => b.shared_wikilinks - a.shared_wikilinks);
  return { summaries: out };
}

// ---------- candidates dispatcher ----------

function cmdCandidates(vault, args) {
  if (!args.kind) die('--kind is required', 1);
  if (args.json !== true) die('--json is required (machine-only output)', 1);
  const scope = args.scope || 'wiki';
  if (!scope.startsWith('wiki')) die(`--scope must be inside wiki/, got ${scope}`, 3);

  let result;
  if (args.kind === 'merge')             result = candidatesMerge(vault, scope);
  else if (args.kind === 'parent')       result = candidatesParent(vault, scope);
  else if (args.kind === 'recategorize') result = candidatesRecategorize(vault, scope);
  else if (args.kind === 'cover')        result = candidatesCover(vault, scope);
  else die(`unknown --kind: ${args.kind}`, 1);   // relations lands in a later task
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
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
  if (cmd === 'candidates') return cmdCandidates(vault, args);
  if (cmd === 'move-page') return cmdMovePage(vault, args);
  if (cmd === 'merge-page') return cmdMergePage(vault, args);
  if (cmd === 'mark-covered') return cmdMarkCovered(vault, args);
  if (cmd === 'parent-create') return cmdParentCreate(vault, args);
  if (cmd === 'relations-add') return cmdRelationsAdd(vault, args);
  if (cmd === 'validate-or-revert') return cmdValidateOrRevert(vault);
  die(`unknown subcommand: ${cmd}`);
}

main();
