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
  if (cmd === 'move-page') return cmdMovePage(vault, args);
  if (cmd === 'merge-page') return cmdMergePage(vault, args);
  if (cmd === 'mark-covered') return cmdMarkCovered(vault, args);
  if (cmd === 'parent-create') return cmdParentCreate(vault, args);
  if (cmd === 'relations-add') return die('relations-add: not implemented yet', 1);
  if (cmd === 'validate-or-revert') return die('validate-or-revert: not implemented yet', 1);
  die(`unknown subcommand: ${cmd}`);
}

main();
