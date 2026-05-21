# `status.js --json` Schema (v1)

Stable shape emitted by `node scripts/status.js --json`. Cron consumers depend
on this contract — additions require a `schema_version` bump (currently implied
by file format; once we cross version 2, an explicit top-level key lands).

## Shape

```json
{
  "vault":           { "root": "<absolute-path>", "name": "<basename>" },
  "sources":         { "new": 0, "changed": 0, "deleted": 0 },
  "lint":            { "errors": 0, "warnings": 0 },
  "contradictions":  { "unjudged_candidates": 0, "unresolved": 0, "present": false },
  "staleness":       { "unjudged_candidates": 0, "unresolved_high": 0, "unresolved_medium": 0, "present": false },
  "since_review":    { "change_count": 0, "last_accepted_at": null }
}
```

## Fields

### `vault`
- **`root`** (string): absolute path to the vault root (directory containing
  both `.git/` and `wiki/.state/sources.yaml`).
- **`name`** (string): basename of `vault.root`. Convenience for human output;
  cron consumers should not rely on uniqueness across machines.

### `sources`
Derived from `state-sources.js diff` (filesystem vs `wiki/.state/sources.yaml`,
content-hash based).
- **`new`** (integer): sources on disk but absent from `sources.yaml`.
- **`changed`** (integer): sources whose content hash differs from `sources.yaml`.
- **`deleted`** (integer): sources in `sources.yaml` but no longer on disk.

### `lint`
Derived from `validate-wiki.js all --json` regardless of its exit code.
- **`errors`** (integer): `frontmatter.errors.length` +
  `wikilinks.broken.length` + `index.dead_rows.length`.
- **`warnings`** (integer): `wikilinks.orphans.length` +
  `index.missing_rows.length`.

### `contradictions`
Read directly from `wiki/.state/contradictions.yaml` (owned by CR-007).
- **`present`** (boolean): `true` if the state file exists; `false` until
  CR-007 lands.
- **`unjudged_candidates`** (integer): always `0` in CR-009. CR-007 may compute
  candidates on-demand rather than persist them; either way the key stays for
  cron-consumer forward compatibility.
- **`unresolved`** (integer): count of entries with `status: unresolved`. CR-007
  owns the per-entry semantics; CR-009 only counts.

### `staleness`
Read directly from `wiki/.state/staleness.yaml` (owned by CR-008).
- **`present`** (boolean): `true` if the state file exists; `false` until
  CR-008 lands.
- **`unjudged_candidates`** (integer): always `0` in CR-009 (same forward-
  compatibility reasoning as `contradictions.unjudged_candidates`).
- **`unresolved_high`** (integer): count of entries with `signal: high` AND
  `status: unreviewed`.
- **`unresolved_medium`** (integer): count of entries with `signal: medium` AND
  `status: unreviewed`. `signal: low` is intentionally not surfaced — the
  dashboard routes the user to high+medium triage only.

### `since_review`
Read directly from `wiki/.state/since-review.yaml`.
- **`change_count`** (integer): `len(changes)` from the state file.
- **`last_accepted_at`** (string|null): ISO 8601 UTC timestamp of the last
  `/second-brain:status accept`, or `null` if never accepted (or if the state
  file does not yet exist).

## Stability commitment

- Every key above is **always present** in `--json` output. Sections derived
  from optional state files emit zeros + `present: false` when the file is
  absent, never omit themselves.
- Field additions (new top-level sections, new sub-keys) are non-breaking and
  can land in any CR.
- Field removals or semantic changes are breaking and require bumping
  `schema_version` (and a migration note in the CR that does it).
- The dashboard payload contains no `generated_at` timestamp: byte-stability
  across runs (with unchanged state) is the test-locked contract.

## Worked examples

### Fresh vault

```json
{
  "vault":           { "root": "/Users/u/Documents/personal", "name": "personal" },
  "sources":         { "new": 0, "changed": 0, "deleted": 0 },
  "lint":            { "errors": 0, "warnings": 0 },
  "contradictions":  { "unjudged_candidates": 0, "unresolved": 0, "present": false },
  "staleness":       { "unjudged_candidates": 0, "unresolved_high": 0, "unresolved_medium": 0, "present": false },
  "since_review":    { "change_count": 0, "last_accepted_at": null }
}
```

### Populated vault

```json
{
  "vault":           { "root": "/Users/u/Documents/client-x", "name": "client-x" },
  "sources":         { "new": 5, "changed": 2, "deleted": 0 },
  "lint":            { "errors": 0, "warnings": 3 },
  "contradictions":  { "unjudged_candidates": 0, "unresolved": 3, "present": true },
  "staleness":       { "unjudged_candidates": 0, "unresolved_high": 5, "unresolved_medium": 2, "present": true },
  "since_review":    { "change_count": 12, "last_accepted_at": "2026-05-12T08:00:00Z" }
}
```

## Cron consumer patterns

```bash
# Any pending sources?
STATUS=$(node "$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
if [ "$(echo "$STATUS" | jq '.sources.new + .sources.changed')" -gt 0 ]; then
  claude --headless -p "/second-brain:ingest"
fi

# Any unjudged contradiction candidates?
if [ "$(echo "$STATUS" | jq '.contradictions.unjudged_candidates')" -gt 0 ]; then
  claude --headless -p "/second-brain:status reconcile --judge-only"
fi
```

See `docs/install/headless-driving.md` for a full crontab example.
