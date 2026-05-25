# CR-009 — Unified `/status` dashboard + review-since-checkpoint log + headless driving

**Depends on:** CR-002 (state YAML), CR-004 (hooks + scripts framework).

**Used by:** CR-007 (reconcile sub-flow), CR-008 (refresh sub-flow), and any future automatable skill via the review-log contract.

## Problem

The project is gaining concerns the user has to act on — sources to ingest, contradictions to resolve, stale pages to triage, lint warnings, reorganize candidates. Without coordination, each new concern adds a slash-command the user has to remember. The user has been explicit: this won't work for them. They will not memorize per-concern commands; they drop files and expect things to work, and they want to drive most flows from cron / file-watchers, *not* from inside interactive Claude Code sessions.

Three needs fall out:

1. **One thing the user remembers.** A single command — `/status` — that surfaces every pending concern in one place and routes to sub-flows for human-only work.
2. **A machine-readable surface.** Cron jobs need to ask "what state is this vault in?" in JSON, decide what to fire headless, and quiet down when there's nothing to do.
3. **Visibility into automatic work.** When automation acts unsupervised — auto-ingest, judge passes, lint autofixes — the user needs a digestible "since last review" view, with an explicit `accept` that resets the window. Without this, automation feels opaque and untrustworthy.

## Motivation

- **Cognitive load.** Many commands = forgotten commands = dead features. One entry point compounds; many entry points fragment.
- **Headless-first.** The user plans to drive cron jobs that pipe `claude --headless` for ingest, judge passes, lint autofix. That requires a scriptable contract: "what's the state of this vault, in JSON?"
- **Accountability.** Eventual consistency is fine when there's an audit trail and a checkpoint, not fine when changes pile up invisibly.

## Proposed approach

Three deliverables: a status script, a thin skill, and a cross-cutting contract.

### 1. `scripts/status.sh`

Reads all `wiki/.state/*.yaml` files. One source of truth, two output modes.

```bash
$ scripts/status.sh --json
{
  "sources":         { "new": 5, "changed": 2, "deleted": 0 },
  "contradictions":  { "unjudged_candidates": 0, "unresolved": 3 },
  "staleness":       { "unjudged_candidates": 0, "unresolved_high": 5, "unresolved_medium": 2 },
  "lint":            { "errors": 0, "warnings": 3 },
  "since_review":    { "change_count": 12, "last_accepted_at": "2026-05-12T08:00:00Z" }
}

$ scripts/status.sh            # human view (default)
Second Brain — vault: client-x
─────────────────────────────────────────────
Needs you:
  Contradictions     3 unresolved      (/second-brain:status reconcile)
  Stale pages        5 high + 2 medium (/second-brain:status refresh)

Awaiting review:
  12 changes since 2026-05-12         (/second-brain:status review)

Automation could pick up:
  Sources            5 new in raw/, 2 changed
                     hint: claude --headless -p "/second-brain:ingest"
```

The script never prompts. It exits non-zero if state files are missing or malformed (so cron can detect breakage).

### 2. `scripts/review-log.sh`

Owns `wiki/.state/since-review.yaml`. Three modes:

- `append --kind=<kind> --data=<json>` — called by any auto-skill on success.
- `show` — prints the current `changes:` list grouped by kind.
- `accept` — truncates `changes:` to empty, bumps `last_accepted_at` to now.

Schema:

```yaml
schema_version: 1
generated_by: scripts/review-log.sh
last_accepted_at: 2026-05-12T08:00:00Z
changes:
  - at: 2026-05-13T03:00:00Z
    kind: ingest
    source: raw/some-article.md
    wrote: [wiki/sources/some-article.md, wiki/entities/foo.md]
  - at: 2026-05-14T03:00:00Z
    kind: contradiction-judged
    pair: [wiki/entities/foo.md, wiki/concepts/acquisitions.md]
    verdict: real-contradiction
  - at: 2026-05-15T03:00:00Z
    kind: lint-autofix
    note: "removed broken link [[old-page]] from wiki/concepts/foo.md"
```

This file IS truncated on accept — it's the ephemeral inbox. The permanent narrative still lives in `wiki/log.md`, which is never truncated. Two files, two purposes:

| File | Truncated? | Purpose |
|---|---|---|
| `wiki/.state/since-review.yaml` | On `accept` | "What's accumulated since you last looked" — the inbox. |
| `wiki/log.md` | Never | Permanent human-readable narrative of every operation. |

### 3. `/second-brain:status` skill

Thin skill at `skills/status/SKILL.md`. Default invocation prints the human view of `scripts/status.sh`. Sub-args route to sub-flows:

| Invocation | What it does |
|---|---|
| `/second-brain:status` | Print the dashboard. |
| `/second-brain:status review` | Print the since-review changelog grouped by kind. Suggest `git log --since=<last_accepted_at>` for file-level diffs. |
| `/second-brain:status accept` | Call `review-log.sh accept`. Confirm count cleared. |
| `/second-brain:status reconcile` | Enter the interactive contradiction-resolution loop (CR-007). |
| `/second-brain:status refresh` | Enter the interactive staleness-triage loop (CR-008). |

Resolution loops are **sub-flows of `/status`**, not standalone skills. Skill registry stays small; conceptual surface stays small.

### 4. The review-log contract (cross-cutting)

Any skill that does work *without a human present* (i.e., succeeds in headless mode) must, on success, append a single entry to `since-review.yaml` via `scripts/review-log.sh append`.

| Skill | Contract |
|---|---|
| `/second-brain:ingest` | One entry per ingested source: `kind: ingest`, source path, wiki pages written. |
| `/second-brain:lint --autofix` | One entry per autofix: `kind: lint-autofix`, one-line note. |
| `/second-brain:reconcile --judge-only` (CR-007) | One entry per judged pair: `kind: contradiction-judged`, pair + verdict. |
| `/second-brain:refresh --judge-only` (CR-008) | One entry per judged page: `kind: staleness-judged`, page + verdict. |
| Interactive resolutions (`/status reconcile`, `/status refresh`) | **Do not** append — the user just saw and decided. |

Each skill's SKILL.md gets a one-liner; the actual file mutation goes through the script.

### 5. Headless driving doc

A small doc at `docs/install/headless-driving.md` with concrete examples:

```bash
# Hourly cron: pick up new sources, then judge what came in.
0 * * * * cd /path/to/vault && {
  STATUS=$(/path/to/plugin/scripts/status.sh --json)
  NEW=$(echo "$STATUS" | jq '.sources.new + .sources.changed')
  if [ "$NEW" -gt 0 ]; then
    claude --headless -p "/second-brain:ingest" >> .claude/headless.log 2>&1
  fi
  STATUS=$(/path/to/plugin/scripts/status.sh --json)
  [ "$(echo "$STATUS" | jq '.contradictions.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:reconcile --judge-only" >> .claude/headless.log 2>&1
  [ "$(echo "$STATUS" | jq '.staleness.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:refresh --judge-only" >> .claude/headless.log 2>&1
}
```

The doc establishes recommended cadence (hourly for ingest is plenty; judge passes can be daily) and the convention that all headless invocations log to `.claude/headless.log`.

## Open questions

- **Sub-flow vs. separate skills.** `/status reconcile` and `/status refresh` are sub-arguments here. Alternative: register them as separate skills (`/second-brain:reconcile`, `/second-brain:refresh`) but document `/status` as the entry. Either works; sub-flow keeps the registry minimal. Decide in plan.
- **JSON schema.** Sketch above. Probably worth a `references/status-json-schema.md` so consumers can rely on it without reading the script.
- **Review log overflow.** A user who doesn't `accept` for months will accumulate thousands of entries. Soft cap with a roll-up (`kind: roll-up`, summarizing N older entries into one)? Or trust the user to accept periodically? Plan-time call.
- **`wiki/log.md` vs `since-review.yaml` writes.** Each automatable skill writes to both (permanent narrative + ephemeral inbox). Could be unified into a single "log this event" contract that writes both. Defer.
- **State file health in `/status` output.** Should the dashboard show a footer line like "sources.yaml: 142 entries, last scanned 5min ago" so the user can catch silent breakage? Probably yes, low-priority.
- **Auto-accept after N days?** Probably not — accept is meant to be deliberate. But discuss.

## Out of scope

- Implementing the `--judge-only` flags on reconcile / refresh — CR-007 and CR-008 own those. CR-009 declares the contract; the other CRs implement it.
- Web UI. Vault stays markdown + CLI.
- Notifications (push/email/Slack) when work is pending. The user said they'll check in manually. A future CR can add this if needed.
- Auth / multi-user. Vault is single-user, single-machine; cron runs as the user.
- Templating cron entries per vault. The example doc is enough; the user wires their own.
- Rollback for auto-changes. The user reverts via git or by editing the file directly — we don't reinvent that.
