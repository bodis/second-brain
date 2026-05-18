#!/usr/bin/env python3
"""Register the second-brain plugin into a Claude Code settings.json.

The script is self-locating: it walks up from its own __file__ to find the
plugin root (the directory containing .claude-plugin/plugin.json) and uses
that absolute path as the `directory` source.

Usage:
    register-plugin.py --scope project --vault <abs-path-to-vault>
    register-plugin.py --scope user

For --scope project, writes/merges <vault>/.claude/settings.json.
For --scope user,    writes/merges $HOME/.claude/settings.json.

Existing values for `extraKnownMarketplaces.second-brain` and
`enabledPlugins["second-brain@second-brain"]` are overwritten. Every other
key in the file is preserved. Malformed JSON in the target file is a fatal
error — the script exits non-zero and does NOT touch the file.
"""

import argparse
import json
import os
import sys
from pathlib import Path

PLUGIN_NAME = "second-brain"
MARKETPLACE_NAME = "second-brain"
ENABLED_KEY = f"{PLUGIN_NAME}@{MARKETPLACE_NAME}"


def find_plugin_root(start: Path) -> Path:
    for candidate in [start, *start.parents]:
        if (candidate / ".claude-plugin" / "plugin.json").is_file():
            return candidate
    sys.exit(
        f"error: could not find .claude-plugin/plugin.json walking up from {start}"
    )


def target_settings_path(scope: str, vault: str | None) -> Path:
    if scope == "project":
        if not vault:
            sys.exit("error: --vault is required when --scope=project")
        return Path(vault).expanduser().resolve() / ".claude" / "settings.json"
    if scope == "user":
        return Path(os.environ.get("HOME", str(Path.home()))) / ".claude" / "settings.json"
    sys.exit(f"error: unknown scope {scope!r}")


def load_existing(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with path.open("r") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        sys.exit(f"error: {path} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        sys.exit(f"error: {path} top-level value must be a JSON object")
    return data


def merge(settings: dict, plugin_path: Path) -> dict:
    mkts = settings.setdefault("extraKnownMarketplaces", {})
    mkts[MARKETPLACE_NAME] = {
        "source": {"source": "directory", "path": str(plugin_path)}
    }
    enabled = settings.setdefault("enabledPlugins", {})
    enabled[ENABLED_KEY] = True
    return settings


def write_atomically(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=["project", "user"], required=True)
    parser.add_argument("--vault", help="vault root (required when --scope=project)")
    args = parser.parse_args()

    plugin_root = find_plugin_root(Path(__file__).resolve())
    target = target_settings_path(args.scope, args.vault)
    settings = load_existing(target)
    merged = merge(settings, plugin_root)
    write_atomically(target, merged)
    print(f"wrote {target}", file=sys.stderr)


if __name__ == "__main__":
    main()
