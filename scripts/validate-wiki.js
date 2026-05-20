#!/usr/bin/env node
'use strict';

/**
 * scripts/validate-wiki.js — wiki structural validator.
 *
 * Subcommands: frontmatter | wikilinks | index | all
 * Each subcommand supports --json for machine consumers.
 *
 * Exit codes (shared across subcommands):
 *   0 = clean
 *   1 = warnings (broken link, orphan page, missing index row)
 *   2 = structural error (frontmatter invalid, dead index row, contract mismatch)
 *
 * Vault detection: walks up from CLAUDE_PROJECT_DIR (or cwd) for a directory
 * containing both `.git/` and `wiki/.state/sources.yaml`. If none found, exits
 * 0 silently — this is how the universally-fired Stop hook self-gates outside
 * second-brain vaults.
 *
 * `all` honors `stop_hook_active: true` on stdin per Claude Code hook docs.
 */

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const SUBCOMMANDS = ['frontmatter', 'wikilinks', 'index', 'all'];

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

function parseArgs(argv) {
  const cmd = argv[0];
  let json = false;
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === '--json') json = true;
    else die(`unknown argument: ${argv[i]}`);
  }
  return { cmd, json };
}

// Read stdin synchronously and return a parsed JSON object, or {} if nothing
// was piped. Only called from `all` to honor the stop_hook_active guard.
function readStdinJson() {
  if (process.stdin.isTTY) return {};
  try {
    const raw = fs.readFileSync(0, 'utf8');
    if (!raw.trim()) return {};
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

// Walk a directory recursively and yield .md files (POSIX-style vault-relative paths).
function* walkMarkdown(vault, subdir) {
  const abs = path.join(vault, subdir);
  if (!fs.existsSync(abs)) return;
  for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const child = path.join(subdir, entry.name);
    if (entry.isDirectory()) {
      yield* walkMarkdown(vault, child);
    } else if (entry.isFile() && entry.name.endsWith('.md')) {
      yield child.split(path.sep).join('/');
    }
  }
}

// Read the first ---fenced YAML block at the top of a markdown file.
// Returns { ok: true, data } on parse, { ok: false, problem } on error.
//
// We load with CORE_SCHEMA so YAML timestamps stay as plain strings. The default
// schema parses `2026-05-20` into a JS Date, which silently rolls over invalid
// values (e.g. `2026-13-45` becomes `2027-02-14`), and the validator would then
// never see the bogus source text. CORE_SCHEMA keeps booleans/ints/floats native.
function readFrontmatter(absPath) {
  let text;
  try { text = fs.readFileSync(absPath, 'utf8'); }
  catch (err) { return { ok: false, problem: `read failed: ${err.message}` }; }
  // Match a leading `---` line, then content, then a closing `---` line.
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!m) return { ok: false, problem: 'no frontmatter block (expected leading `---` fence)' };
  let data;
  try { data = yaml.load(m[1], { schema: yaml.CORE_SCHEMA }); }
  catch (err) { return { ok: false, problem: `yaml parse error: ${err.message}` }; }
  if (data === null || typeof data !== 'object') {
    return { ok: false, problem: 'frontmatter is not a mapping' };
  }
  return { ok: true, data };
}

function loadContract(vault) {
  const p = path.join(vault, 'wiki', '.state', 'frontmatter-contract.yaml');
  if (!fs.existsSync(p)) {
    die(`frontmatter contract missing: ${p}; re-run /second-brain:onboard to scaffold it`, 2);
  }
  let doc;
  try { doc = yaml.load(fs.readFileSync(p, 'utf8')); }
  catch (err) { die(`failed to parse frontmatter contract: ${err.message}`, 2); }
  if (!doc || doc.schema_version !== 1) {
    die(`frontmatter contract has unknown schema_version (${doc && doc.schema_version}); ` +
        `validator understands version 1 — upgrade the plugin or re-scaffold the vault`, 2);
  }
  return doc;
}

// Resolve the contract's `targets` globs to a flat list of vault-relative .md paths,
// excluding anything listed in `exempt`. Our globs are restricted to the documented
// shape `wiki/<subdir>/**/*.md`, so we can implement them as a recursive walk under
// each `wiki/<subdir>/` rather than pulling in a full glob library.
function expandTargets(vault, contract) {
  const exempt = new Set(contract.exempt || []);
  const out = [];
  for (const glob of contract.targets || []) {
    const m = glob.match(/^wiki\/([^/]+)\/\*\*\/\*\.md$/);
    if (!m) {
      die(`frontmatter contract target glob not supported: ${glob}; ` +
          `use the form 'wiki/<subdir>/**/*.md'`, 2);
    }
    const subdir = `wiki/${m[1]}`;
    for (const p of walkMarkdown(vault, subdir)) {
      if (!exempt.has(p)) out.push(p);
    }
  }
  return out;
}

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

// Strict YYYY-MM-DD check: must match the literal pattern AND the components
// must form a real calendar date (no month=13, no day=45, leap-year aware).
// We round-trip through Date and compare the parts to reject rollovers.
function isValidDateString(s) {
  if (typeof s !== 'string') return false;
  const m = s.match(DATE_RE);
  if (!m) return false;
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const d = new Date(Date.UTC(year, month - 1, day));
  return d.getUTCFullYear() === year
    && d.getUTCMonth() === month - 1
    && d.getUTCDate() === day;
}

function validateKey(value, spec) {
  if (spec.type === 'list[string]') {
    if (!Array.isArray(value)) return 'expected a list of strings';
    if (!value.every(x => typeof x === 'string')) return 'list contains non-string entries';
    if (!spec.may_be_empty && value.length === 0) return 'list must not be empty';
    return null;
  }
  if (spec.type === 'date') {
    // readFrontmatter uses CORE_SCHEMA, so YAML dates stay as plain strings.
    // The contract requires the literal source text to be YYYY-MM-DD AND
    // a real calendar date — `2026-13-45` matches the shape but is invalid.
    if (isValidDateString(value)) return null;
    return `expected ${spec.format || 'YYYY-MM-DD'} date`;
  }
  return `unknown contract type: ${spec.type}`;
}

// Match every [[...]] occurrence. Allow only target + optional `|alias` within
// the brackets; pipe-aliases keep just the target. Reject patterns with
// embedded newlines.
const WIKILINK_RE = /\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]/g;

function extractWikilinks(absPath) {
  let text;
  try { text = fs.readFileSync(absPath, 'utf8'); }
  catch { return []; }
  const out = [];
  let m;
  WIKILINK_RE.lastIndex = 0;
  while ((m = WIKILINK_RE.exec(text)) !== null) {
    const t = m[1].trim();
    if (t) out.push(t);  // skip [[ ]] and other whitespace-only matches
  }
  return out;
}

// Resolve a wikilink target against the three rules. Returns the resolved
// vault-relative path (e.g. 'wiki/concepts/foo.md') or null if unresolved.
function resolveWikilink(target, vault, bareIndex) {
  // Rule 2: wiki path — `wiki/...` (no extension).
  if (target.startsWith('wiki/')) {
    const abs = path.join(vault, target + '.md');
    if (fs.existsSync(abs)) return target + '.md';
    return null;
  }
  // Rule 3: documentation path — `src/documentation/...` (no extension).
  if (target.startsWith('src/documentation/')) {
    const abs = path.join(vault, target + '.md');
    if (fs.existsSync(abs)) return target + '.md';
    return null;
  }
  // Rule 1: bare name (case-insensitive basename match anywhere under wiki/).
  const hit = bareIndex.get(target.toLowerCase());
  if (hit) return hit;
  return null;
}

// Subdirs of wiki/ whose pages should be checked for inbound links. Top-level
// wiki/index.md and wiki/log.md are not in scope for the orphan check.
const ORPHAN_ROOTS = ['wiki/sources', 'wiki/entities', 'wiki/concepts', 'wiki/synthesis'];

function isOrphanCandidate(rel) {
  return ORPHAN_ROOTS.some(root => rel === root + '.md' || rel.startsWith(root + '/'));
}

// Parse `wiki/index.md` and return the list of wikilink targets it contains.
// We deliberately treat every [[target]] anywhere in the file as a row entry;
// the doc-section structure is for humans, not for the validator.
function readIndexTargets(vault) {
  const abs = path.join(vault, 'wiki', 'index.md');
  if (!fs.existsSync(abs)) return [];
  return extractWikilinks(abs); // already trimmed
}

const INDEXED_ROOTS = ['wiki/sources', 'wiki/entities', 'wiki/concepts', 'wiki/synthesis'];

function runAll(_vault, _json) {
  // Stub — Task 7 fills this in by composing the three subcommands.
  return { code: 0, output: '' };
}

function runFrontmatter(vault, json) {
  const contract = loadContract(vault);
  const targets = expandTargets(vault, contract);
  const errors = [];
  for (const rel of targets) {
    const abs = path.join(vault, rel);
    const fm = readFrontmatter(abs);
    if (!fm.ok) {
      errors.push({ path: rel, key: null, problem: fm.problem });
      continue;
    }
    for (const [key, spec] of Object.entries(contract.required || {})) {
      if (!(key in fm.data)) {
        errors.push({ path: rel, key, problem: `missing required key '${key}'` });
        continue;
      }
      const problem = validateKey(fm.data[key], spec);
      if (problem) errors.push({ path: rel, key, problem });
    }
  }
  const code = errors.length > 0 ? 2 : 0;
  if (json) {
    return { code, output: JSON.stringify({ errors, warnings: [] }, null, 2) + '\n' };
  }
  if (errors.length === 0) return { code: 0, output: '' };
  // Human summary on stderr, no stdout.
  for (const e of errors) {
    process.stderr.write(`frontmatter: ${e.path} ${e.problem}\n`);
  }
  return { code, output: '' };
}

function runWikilinks(vault, json) {
  // Walk wiki/ once; derive both the page list and the case-insensitive
  // bare-name index from the same traversal.
  const pages = [...walkMarkdown(vault, 'wiki')];
  const bareIndex = new Map();
  for (const rel of pages) {
    bareIndex.set(path.basename(rel, '.md').toLowerCase(), rel);
  }
  const broken = [];
  const inbound = new Map(); // resolved-target-path -> count
  for (const rel of pages) {
    const abs = path.join(vault, rel);
    for (const target of extractWikilinks(abs)) {
      const resolved = resolveWikilink(target, vault, bareIndex);
      if (!resolved) {
        broken.push({ from: rel, target });
      } else if (resolved !== rel) {
        // Self-links do not count toward inbound — an orphan that mentions itself
        // is still an orphan from the graph's perspective.
        inbound.set(resolved, (inbound.get(resolved) || 0) + 1);
      }
    }
  }
  const orphans = [];
  for (const rel of pages) {
    if (!isOrphanCandidate(rel)) continue;
    if ((inbound.get(rel) || 0) === 0) orphans.push({ path: rel });
  }
  const code = (broken.length > 0 || orphans.length > 0) ? 1 : 0;
  if (json) {
    return { code, output: JSON.stringify({ broken, orphans }, null, 2) + '\n' };
  }
  if (code === 0) return { code: 0, output: '' };
  process.stderr.write(`wikilinks: ${broken.length} broken, ${orphans.length} orphan\n`);
  return { code, output: '' };
}

function runIndex(vault, json) {
  // Build the bare-name index inline (same pattern as runWikilinks).
  const pages = [...walkMarkdown(vault, 'wiki')];
  const bareIndex = new Map();
  for (const rel of pages) {
    bareIndex.set(path.basename(rel, '.md').toLowerCase(), rel);
  }
  const indexTargets = readIndexTargets(vault);

  // Set of resolved vault-relative paths the index covers.
  const covered = new Set();
  const deadRows = [];
  for (const target of indexTargets) {
    const resolved = resolveWikilink(target, vault, bareIndex);
    if (resolved) covered.add(resolved);
    else deadRows.push({ target });
  }

  // Every .md file under the indexed roots must be covered.
  const missingRows = [];
  for (const root of INDEXED_ROOTS) {
    for (const rel of walkMarkdown(vault, root)) {
      if (!covered.has(rel)) missingRows.push(rel);
    }
  }

  let code = 0;
  if (deadRows.length > 0) code = 2;
  else if (missingRows.length > 0) code = 1;

  if (json) {
    return {
      code,
      output: JSON.stringify({ missing_rows: missingRows, dead_rows: deadRows }, null, 2) + '\n',
    };
  }
  if (code === 0) return { code: 0, output: '' };
  if (deadRows.length > 0) {
    for (const d of deadRows) process.stderr.write(`index: dead row -> ${d.target}\n`);
  }
  if (missingRows.length > 0) {
    process.stderr.write(`index: ${missingRows.length} missing row(s); run sync-index.js to fix\n`);
  }
  return { code, output: '' };
}

function emit(result) {
  if (result.output) process.stdout.write(result.output);
  process.exit(result.code);
}

function main() {
  const { cmd, json } = parseArgs(process.argv.slice(2));
  if (!SUBCOMMANDS.includes(cmd)) {
    die(`unknown subcommand: ${cmd}; expected one of ${SUBCOMMANDS.join(', ')}`, 1);
  }

  const startDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const vault = findVaultRoot(startDir);
  if (!vault) {
    // Not a second-brain vault — exit 0 silently. This is the Stop hook
    // self-gate: the hook fires globally, but no work happens outside a vault.
    process.exit(0);
  }

  if (cmd === 'all') {
    const stdin = readStdinJson();
    if (stdin.stop_hook_active === true) process.exit(0);
    return emit(runAll(vault, json));
  }
  if (cmd === 'frontmatter') return emit(runFrontmatter(vault, json));
  if (cmd === 'wikilinks') return emit(runWikilinks(vault, json));
  if (cmd === 'index') return emit(runIndex(vault, json));
}

main();
