#!/usr/bin/env node
'use strict';

/**
 * scripts/sync-index.js — opt-in fixer for wiki/index.md.
 *
 * Reads filesystem reality under wiki/{sources,entities,concepts,synthesis}/
 * and rewrites wiki/index.md so that:
 *   - every .md file in those subdirs has a row,
 *   - no row points to a non-existent file,
 *   - existing row text (e.g. one-line summaries) is preserved where the row
 *     still resolves,
 *   - rows are sorted alphabetically under each section header.
 *
 * Idempotent: a second consecutive run produces no changes.
 * Never invoked by a hook — only by lint when the user opts in.
 */

const fs = require('fs');
const path = require('path');

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
    if (parent === dir) return null;
    dir = parent;
  }
}

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

const SECTIONS = [
  { header: '## Sources', root: 'wiki/sources' },
  { header: '## Entities', root: 'wiki/entities' },
  { header: '## Concepts', root: 'wiki/concepts' },
  { header: '## Synthesis', root: 'wiki/synthesis' },
];

const WIKILINK_RE = /\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]/g;

// Parse the existing wiki/index.md into a map: section-header -> array of
// raw row lines (each starting with `- `). Anything outside a known section
// header (like the title line `# Index`) is preserved as a preamble.
function parseIndex(text) {
  const lines = text.split(/\r?\n/);
  const result = { preamble: [], sections: {} };
  for (const s of SECTIONS) result.sections[s.header] = [];
  let currentHeader = null;
  for (const line of lines) {
    if (SECTIONS.some(s => s.header === line.trim())) {
      currentHeader = line.trim();
      continue;
    }
    if (currentHeader === null) {
      result.preamble.push(line);
    } else {
      if (line.startsWith('- ')) result.sections[currentHeader].push(line);
      // Drop blank lines and other prose between rows — sync regenerates them.
    }
  }
  return result;
}

// For a given row text, return the first wikilink target, or null.
function targetOfRow(row) {
  WIKILINK_RE.lastIndex = 0;
  const m = WIKILINK_RE.exec(row);
  return m ? m[1].trim() : null;
}

// Resolve a target against the vault. Returns vault-relative .md path or null.
// Bare names are matched case-insensitively against all .md basenames under wiki/.
function resolveTarget(target, vault, bareIndex) {
  if (target.startsWith('wiki/')) {
    return fs.existsSync(path.join(vault, target + '.md')) ? target + '.md' : null;
  }
  if (target.startsWith('src/documentation/')) {
    return fs.existsSync(path.join(vault, target + '.md')) ? target + '.md' : null;
  }
  return bareIndex.get(target.toLowerCase()) || null;
}

function buildBareIndex(vault) {
  const idx = new Map();
  for (const rel of walkMarkdown(vault, 'wiki')) {
    idx.set(path.basename(rel, '.md').toLowerCase(), rel);
  }
  return idx;
}

function main() {
  const startDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const vault = findVaultRoot(startDir);
  if (!vault) die('not a second-brain vault (no .git/ + wiki/.state/sources.yaml above cwd)', 2);

  const indexPath = path.join(vault, 'wiki', 'index.md');
  const original = fs.existsSync(indexPath) ? fs.readFileSync(indexPath, 'utf8') : '';
  const parsed = parseIndex(original);
  const bareIndex = buildBareIndex(vault);

  // Build the desired state per section.
  const out = [];
  if (parsed.preamble.length > 0) {
    // Strip trailing blank lines from preamble for canonical formatting.
    while (parsed.preamble.length > 0 && parsed.preamble[parsed.preamble.length - 1] === '') {
      parsed.preamble.pop();
    }
    out.push(...parsed.preamble);
  } else {
    out.push('# Index');
  }
  out.push('');

  for (const s of SECTIONS) {
    out.push(s.header);
    out.push('');

    // Map: covered file path -> existing row text (to preserve summaries).
    const covered = new Map();
    for (const row of parsed.sections[s.header]) {
      const target = targetOfRow(row);
      if (!target) continue;
      const resolved = resolveTarget(target, vault, bareIndex);
      if (resolved && resolved.startsWith(s.root + '/')) covered.set(resolved, row);
      // Dead rows (resolved === null) are dropped.
      // Rows that resolve into a different section are dropped (canonical form).
    }

    // Find every .md under this section's root.
    const onDisk = [...walkMarkdown(vault, s.root)].sort();
    for (const rel of onDisk) {
      if (covered.has(rel)) {
        out.push(covered.get(rel));
      } else {
        const slug = rel.slice(s.root.length + 1, -3); // strip `<root>/` and `.md`
        out.push(`- [[${s.root}/${slug}]]`);
      }
    }
    out.push('');
  }

  // Trim trailing blank lines and finish with one newline.
  while (out.length > 0 && out[out.length - 1] === '') out.pop();
  const result = out.join('\n') + '\n';

  if (result !== original) {
    fs.writeFileSync(indexPath, result);
    process.stdout.write('updated wiki/index.md\n');
  } else {
    process.stdout.write('no changes\n');
  }
}

main();
