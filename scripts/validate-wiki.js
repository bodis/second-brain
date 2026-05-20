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
// Returns { ok: true, data, raw } on parse, { ok: false, problem } on error.
function readFrontmatter(absPath) {
  let text;
  try { text = fs.readFileSync(absPath, 'utf8'); }
  catch (err) { return { ok: false, problem: `read failed: ${err.message}` }; }
  // Match a leading `---` line, then content, then a closing `---` line.
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!m) return { ok: false, problem: 'no frontmatter block (expected leading `---` fence)' };
  let data;
  try { data = yaml.load(m[1]); }
  catch (err) { return { ok: false, problem: `yaml parse error: ${err.message}` }; }
  if (data === null || typeof data !== 'object') {
    return { ok: false, problem: 'frontmatter is not a mapping' };
  }
  return { ok: true, data, raw: m[1] };
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

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function validateKey(value, spec) {
  if (spec.type === 'list[string]') {
    if (!Array.isArray(value)) return 'expected a list of strings';
    if (!value.every(x => typeof x === 'string')) return 'list contains non-string entries';
    if (!spec.may_be_empty && value.length === 0) return 'list must not be empty';
    return null;
  }
  if (spec.type === 'date') {
    // js-yaml parses YAML-native dates into Date objects. The contract requires
    // the source text to be YYYY-MM-DD, so re-render and re-check.
    if (value instanceof Date) {
      const iso = value.toISOString().slice(0, 10);
      return DATE_RE.test(iso) ? null : `date does not match ${spec.format || 'YYYY-MM-DD'}`;
    }
    if (typeof value === 'string' && DATE_RE.test(value)) return null;
    return `expected ${spec.format || 'YYYY-MM-DD'} date`;
  }
  return `unknown contract type: ${spec.type}`;
}

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

function runWikilinks(_vault, _json) {
  // Stub — Task 5 fills this in.
  return { code: 0, output: '' };
}

function runIndex(_vault, _json) {
  // Stub — Task 6 fills this in.
  return { code: 0, output: '' };
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
