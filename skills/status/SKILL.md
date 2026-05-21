---
name: status
description: >
  Show what the second-brain vault needs — pending contradictions to resolve,
  stale pages to triage, changes awaiting review, sources ready for ingest,
  lint warnings. Use when the user says "status", "what's pending", "dashboard",
  "what changed", "review changes", or asks what they should do next in the vault.
allowed-tools: Bash Read
---

# Second Brain — Status

One entry point for every pending vault concern. Default prints the dashboard;
sub-args route to inbox review, accept, and (once CR-007/008 land) interactive
contradiction and staleness resolution loops.

## Tooling

This SKILL drives all state queries through two scripts. Never hand-read
`wiki/.state/*.yaml`. Never compute counts in the LLM — call the script.

- `scripts/status.js` — read-only dashboard reporter.
- `scripts/review-log.js` — owner of `wiki/.state/since-review.yaml`.

Both resolve the vault root by walking up for both `.git/` and
`wiki/.state/sources.yaml`. Outside a vault they exit 2 with a pointer to
`/second-brain:onboard`.

## Default invocation: `/second-brain:status`

Print the dashboard. Run:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/status.js"
```

Echo stdout verbatim. Do not summarise or reformat — the script's output is
the contract.

## `/second-brain:status review`

Print the since-review changelog grouped by kind:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" show
```

Then read the last-accepted timestamp from JSON mode and emit a hint pointing
the user at `git log` for file-level diffs:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" show --json
```

From the JSON, extract `last_accepted_at`. If it is non-null, append:

```
For file-level diffs since last accept: git log --since=<last_accepted_at> wiki/
```

If it is null, append:

```
For file-level diffs since vault init: git log wiki/
```

## `/second-brain:status accept`

Clear the inbox. Run:

```bash
node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" accept
```

Echo stdout verbatim. No confirmation prompt — accept is user-initiated and
recoverable via git.

## `/second-brain:status reconcile`

Placeholder until CR-007 lands. Print:

```
/status reconcile is not yet available. CR-007 will implement contradiction
detection. Until then, /second-brain:lint flags candidate contradictions
in its report.
```

## `/second-brain:status refresh`

Placeholder until CR-008 lands. Print:

```
/status refresh is not yet available. CR-008 will implement staleness review.
Until then, /second-brain:lint flags candidate stale pages in its report.
```

## Headless mode

`scripts/status.js --json` is the contract for cron-driven workflows. See
`docs/install/headless-driving.md` for an hourly cron example.

When CR-007 and CR-008 land, `/second-brain:status reconcile --judge-only`
and `/second-brain:status refresh --judge-only` become cron-safe headless
entry points. Their bodies live in those CRs; the routing shape is locked
here.

## Related skills

- `/second-brain:ingest` — process raw sources. Appends `kind: ingest` to the
  review log on each successful source ingest.
- `/second-brain:lint` — health-check the wiki. Read-only counts surface via
  the dashboard's `lint.{errors,warnings}` fields.
- `/second-brain:onboard` — scaffold a new vault. Must run before
  `/second-brain:status` works at all.

## JSON schema

See `references/status-json-schema.md` for the stable JSON shape, default
values, and the `present: false` flag on not-yet-implemented sections.
