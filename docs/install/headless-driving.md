# Headless driving with cron

`/second-brain:status` exposes a stable JSON shape via `--json`. Cron jobs can
read it, decide what to do, and fire headless Claude Code invocations. This
keeps the user out of the loop for routine work and surfaces only what truly
needs human judgment via `/second-brain:status`.

## The pattern

```bash
STATUS=$("$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
COND=$(echo "$STATUS" | jq '<predicate>')
[ "$COND" -gt 0 ] && claude --headless -p "/second-brain:<skill>"
```

The script is read-only and exits non-zero only on a broken vault. Cron's
default mail-on-failure semantics give you a free monitoring channel.

## Recommended cadence

| Job | Cadence | Rationale |
|---|---|---|
| Ingest new sources | Hourly | Sources arrive in bursts (paste-clip-drop). Hourly catches them while their context is still fresh in the user's mind. |
| Headless judge passes (`reconcile --judge-only`, `refresh --judge-only`) | Daily | Judging is LLM-heavy. Hourly would burn API quota for marginal latency win. |
| Lint sweep | Weekly | Lint surfaces orphan pages and structural drift — slow signals. |

These are starting points; tune to vault size and ingest volume.

## Worked crontab

```bash
# Hourly: pick up new sources, then judge what came in.
0 * * * * cd /path/to/vault && {
  STATUS=$("$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
  NEW=$(echo "$STATUS" | jq '.sources.new + .sources.changed')
  if [ "$NEW" -gt 0 ]; then
    claude --headless -p "/second-brain:ingest" >> .claude/headless.log 2>&1
  fi
  STATUS=$("$CLAUDE_PLUGIN_ROOT/scripts/status.js" --json)
  [ "$(echo "$STATUS" | jq '.contradictions.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:status reconcile --judge-only" >> .claude/headless.log 2>&1
  [ "$(echo "$STATUS" | jq '.staleness.unjudged_candidates')" -gt 0 ] \
    && claude --headless -p "/second-brain:status refresh --judge-only" >> .claude/headless.log 2>&1
}
```

The `reconcile --judge-only` call is live; CR-007's judge pass runs against
any `status: unjudged` entries in `wiki/.state/contradictions.yaml` and
writes verdicts back. The `refresh --judge-only` call is still a no-op
until CR-008 lands.

## The `.claude/headless.log` convention

All headless invocations append to `.claude/headless.log`. This gives you a
single tail-able file for "what has cron been doing":

```bash
tail -f .claude/headless.log
```

The log is gitignored by convention — it is per-machine operational, not part
of the vault's content.

## Auditing what cron did

`scripts/review-log.js` records every automatable skill's success. To see what
ran since you last looked:

```bash
/second-brain:status review
```

When you have audited the changes (via the wiki itself, `git log wiki/`, or the
review output), acknowledge them:

```bash
/second-brain:status accept
```

This clears the inbox and bumps the `last_accepted_at` timestamp. The
`change_count` in the next `/second-brain:status` dashboard goes back to zero.

## Why not push notifications

Push notifications, Slack DMs, email digests — all out of scope. The user
opted for "I'll check the dashboard when I sit down to work" over
"automation paging me." `wiki/.state/since-review.yaml` is the durable inbox;
the dashboard is the morning check.
