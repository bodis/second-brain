---
name: status
description: >
  Show what the second-brain vault needs — pending contradictions to resolve,
  stale pages to triage, changes awaiting review, sources ready for ingest,
  lint warnings. Use when the user says "status", "what's pending", "dashboard",
  "what changed", "review changes", or asks what they should do next in the vault.
allowed-tools: Bash Read Write
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

## `/second-brain:status reconcile` (interactive)

Walk `unresolved` and `deferred` entries; ask the user to pick A, pick B,
accept the disagreement, defer, or stop.

1. List actionable entries:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" list \
     --status=unresolved,deferred --json
   ```

   If `contradictions` is empty, print `nothing to reconcile` and stop.

2. For each entry, print this block to the user:

   ```
   [<id>] Claim: <judgment.claim>
     A. <judgment.assertions[0].page>
        "<judgment.assertions[0].text>"
        source: <judgment.assertions[0].source>
     B. <judgment.assertions[1].page>
        "<judgment.assertions[1].text>"
        source: <judgment.assertions[1].source>
     Rationale: <judgment.rationale>
   Pick (a) A · (b) B · (c) Accept disagreement · (d) Defer · (s) Stop walking
   ```

3. On the user's answer:

   - **`a` or `b` (Pick A / Pick B):**
     - The "winning" page is `judgment.assertions[<choice>].page`; the "losing"
       page is the other one in the entry's `pages` list.
     - Write the rewrite tmpfile at `/tmp/reconcile-<id>.md`. The tmpfile content
       must be the **scoped paragraph(s) that replace the losing page's
       assertion paragraph** — exact prose only, no markdown frontmatter, no
       page-level wrapping. Use the winning assertion's text as the canonical
       claim; preserve any surrounding context from the losing paragraph that
       isn't part of the conflicting assertion.
     - Run:

       ```bash
       node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" apply-pick \
         --id=<id> --winning-page=<winning-page-path> --rewrite=/tmp/reconcile-<id>.md
       ```

     - On script exit 0: capture the printed sha; report success to the user.
     - On script exit 3 (substring matched zero or multiple paragraphs):
       print the script's stderr; defer the entry via
       `node scripts/contradictions.js resolve --id=<id> --kind=defer`;
       continue with the next entry.
     - On script exit 2 (post-check auto-revert): print the stderr; defer the
       entry; continue.

   - **`c` (Accept disagreement):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" apply-accept --id=<id>
     ```

     Same revert-then-defer pattern on exit 2; report sha on success.

   - **`d` (Defer):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" resolve --id=<id> --kind=defer
     ```

   - **`s` (Stop):** break the walk. Any entries already resolved in this pass
     keep their `resolved-*` / `accepted-disagreement` status.

4. After the walk, append one paragraph to `wiki/log.md`:

   ```
   ## [YYYY-MM-DD] reconcile | N resolved (A pick-a, B pick-b), C accepted-disagreement, D deferred
   ```

   Use today's date and the actual counts from the walk.

## `/second-brain:status reconcile --judge-only` (headless)

Cron-safe. Walks `status: unjudged` entries, asks the LLM for a verdict per
pair, writes the result via `contradictions.js judge`, and appends one
`kind: contradiction-judged` entry per pair to `since-review.yaml`.

1. List unjudged entries:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" list --status=unjudged --json
   ```

   If `contradictions` is empty, print `no unjudged candidates` and exit 0.

2. For each entry, read both pages in `pages`. Reason about whether the two
   pages make a real conflicting claim. Two verdicts:

   - **`real-contradiction`** — the pages make conflicting assertions a reader
     should resolve. Produce a freeform `claim` (one short sentence), two
     `assertions` (one per page) with `text` quoting the exact prose substring
     of the conflicting claim plus the `source` from the page's `sources:`
     frontmatter, and a one-line `rationale`. Call:

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" judge \
       --id=<id> --verdict=real-contradiction \
       --data='{"claim":"...","assertions":[{"page":"...","text":"...","source":"..."},{...}],"rationale":"..."}'
     ```

   - **`not-a-contradiction`** — the pages co-exist without conflict (often
     true for shared-entity-prose candidates that are just topically adjacent).
     One-line `rationale`. Call:

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/contradictions.js" judge \
       --id=<id> --verdict=not-a-contradiction \
       --data='{"rationale":"..."}'
     ```

3. After each successful `judge`, append a review-log entry so the user can
   audit the headless work later:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" append --kind=contradiction-judged \
     --data='{"id":"<id>","pages":[...],"verdict":"<verdict>"}'
   ```

4. Print a one-line summary per judgment as it lands (no batching — cron logs
   stay readable).

5. On any `judge` exit 3 (e.g. a concurrent run already advanced the entry),
   log + continue; do not abort the pass.

**Crucial:** when producing assertion `text` for the `real-contradiction`
verdict, quote the **exact substring** that appears in the page body. The
interactive `/status reconcile` resolution flow locates the paragraph to
rewrite via this substring; imprecise quotes will cause `apply-pick` to
exit 3 and force a deferral.

## `/second-brain:status refresh` (interactive)

Walks staleness candidates that the judge pass has marked as needing human action.

1. **Determine scope.** Default filter:

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" list \
     --status=unreviewed --signal=high --json
   ```

   If the user passed `--all` (anywhere on the invocation), expand to `--signal=high,medium` and include `verdict: drifting` entries (these are computed from each entry's `judgment.verdict`). Always exclude `dismissed` and `deferred` from default scope; the user must pass `--include-deferred` to see them.

2. **If the list is empty, print `nothing to refresh` and stop.**

3. **Pre-compute rewrites.** For each in-scope entry, read its `path` and `judgment.neighbors_examined`, plus the entries in `wiki/.state/sources.yaml` that this page's entities show up in (sources newer than the page's `mtime`). Write a rewrite tmpfile at `/tmp/refresh-<id>.md` containing the rewritten page — preserve the page's existing frontmatter exactly (only the body changes), and end with an updated `updated:` date. This tmpfile is what `apply-refresh` will atomically replace the page with.

4. **Walk the entries.** For each in-scope entry, print one display block:

   ```
   [N] wiki/concepts/<path>.md  (age <factors.age_months>mo, <factors.newer_overlapping_sources> newer sources)
       <judgment.verdict>: <judgment.reason>
   ```

   Then prompt the user one of: `R / A / H / D / S` (refresh / archive / historical / defer / skip).

   - **R (refresh):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" apply-refresh \
       --id=<id> --rewrite=/tmp/refresh-<id>.md
     ```

     On exit 2 (validate-wiki failed; auto-reverted), report the validator's error to the user verbatim. The entry stays `unreviewed` and will appear in the next walk.

   - **A (archive):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" apply-archive --id=<id>
     ```

   - **H (historical):** Ask the user inline for `since:` (default current `YYYY-MM`), then:

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" apply-historical \
       --id=<id> --since=<YYYY-MM>
     ```

   - **D (defer):**

     ```bash
     node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" resolve \
       --id=<id> --kind=defer
     ```

   - **S (skip):** make no script call; move to the next entry.

5. **Group git commit at the end of the walk.** After all entries are processed, if any wiki/archive file changed:

   ```bash
   git -C "<vault>" add -A wiki/
   git -C "<vault>" commit -m "refresh: N refreshed, M archived, K historical, J deferred"
   ```

6. **Append one summary line to `wiki/log.md`:**

   ```
   ## YYYY-MM-DD refresh | N refreshed, M archived, K historical, J deferred
   ```

7. **Do NOT append to `since-review.yaml`.** The user was present; per CR-009's review-log contract interactive resolutions are not logged to the inbox.

## `/second-brain:status refresh --judge-only` (headless)

Cron-safe entry. No prompts; drains `status: unjudged` into one of four verdict buckets.

1. **Read all unjudged entries.**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" list --status=unjudged --json
   ```

2. **For each entry, sample up to 5 neighbours.** Find wiki pages whose `mtime` is newer than this page's `mtime` AND that share at least one entity wikilink. One hop only. If fewer than 5 candidates exist, take what is available; if zero, judge with just the page (likely verdict: `false-positive` or `fresh-but-isolated`).

3. **Read the page body + the sampled neighbour bodies + the entry's `factors` block.** Decide a verdict: `stale | drifting | fresh-but-isolated | false-positive`. Compose a one-sentence reason.

4. **Persist the verdict:**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" judge \
     --id=<id> --verdict=<v> \
     --data='{"reason":"<one sentence>","neighbors_examined":["wiki/...","wiki/..."]}'
   ```

5. **Append a review-log entry per CR-009 contract:**

   ```bash
   node "$CLAUDE_PLUGIN_ROOT/scripts/review-log.js" append \
     --kind=staleness-judged \
     --data='{"page":"<path>","verdict":"<v>"}'
   ```

6. **Exit when the list is drained.** No `wiki/log.md` entry (no human action took place). The Stop hook will not run on `--headless` invocations, so no validate-wiki pass is triggered here either.

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
