#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const PLUGIN_NAME = 'second-brain';
const MARKETPLACE_NAME = 'second-brain';
const ENABLED_KEY = `${PLUGIN_NAME}@${MARKETPLACE_NAME}`;

function die(msg) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const opts = { scope: null, vault: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--scope') opts.scope = argv[++i];
    else if (a === '--vault') opts.vault = argv[++i];
    else die(`unknown argument: ${a}`);
  }
  if (opts.scope !== 'project' && opts.scope !== 'user') {
    die(`--scope must be 'project' or 'user'`);
  }
  if (opts.scope === 'project' && !opts.vault) {
    die(`--vault is required when --scope=project`);
  }
  return opts;
}

function findPluginRoot(start) {
  let dir = start;
  while (true) {
    if (fs.existsSync(path.join(dir, '.claude-plugin', 'plugin.json'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) die(`could not find .claude-plugin/plugin.json walking up from ${start}`);
    dir = parent;
  }
}

function targetSettingsPath(scope, vault) {
  if (scope === 'project') {
    return path.join(path.resolve(vault), '.claude', 'settings.json');
  }
  return path.join(process.env.HOME || os.homedir(), '.claude', 'settings.json');
}

function loadExisting(filePath) {
  if (!fs.existsSync(filePath)) return {};
  const raw = fs.readFileSync(filePath, 'utf8');
  let data;
  try { data = JSON.parse(raw); }
  catch (err) { die(`${filePath} is not valid JSON: ${err.message}`); }
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    die(`${filePath} top-level value must be a JSON object`);
  }
  return data;
}

function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === 'object') {
    return Object.keys(value).sort().reduce((acc, k) => {
      acc[k] = sortKeys(value[k]);
      return acc;
    }, {});
  }
  return value;
}

function merge(settings, pluginPath) {
  if (!settings.extraKnownMarketplaces || typeof settings.extraKnownMarketplaces !== 'object') {
    settings.extraKnownMarketplaces = {};
  }
  settings.extraKnownMarketplaces[MARKETPLACE_NAME] = {
    source: { source: 'directory', path: pluginPath },
  };
  if (!settings.enabledPlugins || typeof settings.enabledPlugins !== 'object') {
    settings.enabledPlugins = {};
  }
  settings.enabledPlugins[ENABLED_KEY] = true;
  return settings;
}

function writeAtomically(filePath, data) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.tmp`;
  const sorted = sortKeys(data);
  fs.writeFileSync(tmp, JSON.stringify(sorted, null, 2) + '\n');
  fs.renameSync(tmp, filePath);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const pluginRoot = findPluginRoot(path.dirname(fs.realpathSync(__filename)));
  const target = targetSettingsPath(args.scope, args.vault);
  const existing = loadExisting(target);
  const merged = merge(existing, pluginRoot);
  writeAtomically(target, merged);
  process.stderr.write(`wrote ${target}\n`);
}

main();
