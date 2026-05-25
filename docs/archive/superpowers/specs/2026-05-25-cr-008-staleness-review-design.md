# CR-008 — Staleness review across wiki pages

**Status:** design
**CR:** [CR-008](../../cr/CR-008-staleness-review.md)
**Depends on:** CR-002 (landed; `wiki/.state/sources.yaml`), CR-004 (landed; `validate-wiki.js` + Stop hook), CR-005 (landed; `relations:` frontmatter mechanism), CR-007 (landed; `scripts/contradictions.js` shape sets the pattern this CR mirrors), CR-009 (landed; `/second-brain:status` entry point, `since-review.yaml` review-log contract, status JSON keys for `staleness.*`)
**Mirrors:** [CR-007 spec](./2026-05-24-cr-007-contradiction-detection-design.md) — same candidate / judge / resolve pipeline, same single-script-per-concern shape, same exit-code conventions.

## 1. Problem

Wiki pages rot. A page written from a 2024 source isn't *wrong* yet, but if a dozen newer sources have since been ingested touching the same topic — and the original page has never been re-linked, re-edited, or referenced — it's likely drifted out of current frame. Today nothing flags it.

Agents reading the vault treat every page with equal authority. There is no signal saying "this page is fresh and reinforced by recent ingests" vs. "this page is a 2-year-old snapshot nothing has touched since."

CR-008 ([../../cr/CR-008-staleness-review.md](../../cr/CR-008-staleness-review.md)) establishes that staleness is a distinct, orthogonal concern from lint (correctness), reorganize (structure), and reconcile (contradiction). It is the closest honest translation of `abmind`'s "fading memory" into a deliberate, file-based wiki: not background decay, but periodic triage triggered by deterministic signals.

## 2. Goals

- A single state-owning script `scripts/staleness.js` that maintains `wiki/.state/staleness.yaml` through the entry lifecycle (candidate → judged → resolved).
- A deterministic, vault-relative scoring model (two signals, AND-composed, percentile-based) that auto-scales across vault sizes and produces a tight default-scope list.
- A low-touch interactive flow at `/second-brain:status refresh` that walks only `signal: high` + `verdict: stale` entries by default, batches them, and pre-computes rewrite tmpfiles so each user decision is one keypress.
- A cron-safe headless judge at `/second-brain:refresh --judge-only` that drains `unjudged` entries into one of four verdict buckets, draining the human-facing list without human input.
- An auto-defer rule that prevents the same page from re-surfacing across scans unless its score materially worsens.
- A unified `lifecycle:` frontmatter convention (`historical | superseded | archived`) that this CR owns and the `validate-wiki.js` validator enforces.
- A `/second-brain:query` warning when answers cite lifecycle'd or high-stale pages.

## 3. Non-goals

- **No automatic refresh.** Refresh is always user-confirmed via the interactive flow. Same principle as CR-007: judgment is the user's.
- **No deletion.** Archive, never delete. Same principle as CR-005 ("do not prune useful concepts").
- **No embedding integration.** Vector-store coupling is part of any future embeddings CR.
- **No cross-vault staleness.** Vaults are isolated by design ([[second-brain-primary-consumer]]).
- **No staleness in `raw/` or `src/`.** Sources are not the wiki; their freshness is the source system's problem.
- **No incremental scan on ingest.** Staleness shifts on a months timescale; a per-ingest scan is wasted work and re-flickers signals as one new source arrives. Diverges intentionally from CR-007's per-ingest scan (which detects contradictions that *should* surface immediately).

## 4. Architecture

Three-stage candidate / judge / resolve pipeline, mirroring CR-007:

| Stage | Owner | What |
|---|---|---|
| **Candidate** | `scripts/staleness.js candidates` | Compute deterministic signals per page; assign composite tier; write/refresh `staleness.yaml`. |
| **Judge** | LLM in `/second-brain:refresh --judge-only`, persisted via `scripts/staleness.js judge` | Read flagged page + sampled neighbors; emit a verdict (stale / drifting / fresh-but-isolated / false-positive). |
| **Resolve** | User in `/second-brain:status refresh`, persisted via `apply-refresh` / `apply-archive` / `apply-historical` / `resolve --kind defer` | For each `unreviewed` entry: refresh / archive / mark historical / defer. |

**One script, one state file.** `scripts/staleness.js` is the sole owner of `wiki/.state/staleness.yaml`. Same atomic-write pattern as `contradictions.js` (tmpfile + rename). Same vault-detection helper. Same exit codes (`0` clean / `2` bad input or post-check failure with revert / `3` invariant refusal with no mutation).

**No standalone skill.** All user-visible flow lives under `/second-brain:status refresh` (CR-009 already routes there and prints "not yet available" — CR-008 fills the body). The headless judge runs via `/second-brain:refresh --judge-only` per the CR-009 review-log contract.

**Three external touches** beyond CR-008's own files:
- `scripts/validate-wiki.js` gains a `lifecycle` rule (shape-check the new frontmatter block).
- `skills/lint/SKILL.md` §3 swaps prose-based stale-detection for `staleness.js candidates`.
- `skills/query/SKILL.md` adds a `staleness.js check` lookup before assembling the answer.

## 5. Signals and composite tier

Two signals ship in v1. CR-007's lesson: pick the cheapest signals that catch most real cases. The CR-008 doc listed four; two reduce cleanly to one, and one (`isolated`) is better modelled as a judge verdict than a numeric signal.

| Signal | Definition | Cost |
|---|---|---|
| `age` | This page's `mtime` percentile in the wiki (older = higher). | one `stat` per page |
| `moved_past` | Count of `sources.yaml` entries ingested *after* this page's mtime, whose ingested wiki pages share ≥1 entity wikilink with this page. Higher = more recent sources touched the same topic. | one pass through `sources.yaml` + wikilink set intersection |

The doc's `inbound_reinforcement_gap` is subsumed by `moved_past` (sources are upstream of wiki pages). The doc's `isolated` flag is not a staleness signal — it predicts orphan-ness; the LLM judge emits it as the verdict `fresh-but-isolated`.

**Per-signal cutoffs (vault-relative):**

```
strong  = page is in the top quartile (≥ p75) for this signal
present = page is in the upper half  (≥ p50) for this signal
weak    = below p50
```

**Composite tier (AND of signals — both must agree):**

```
high    = both signals strong
medium  = one strong AND the other present
low     = anything else (not surfaced by default)
```

The AND-shape is load-bearing. Being old alone isn't stale (could be foundational). Being moved-past alone isn't stale (could be a newer page heavily referenced by even newer sources). Stale = both old AND moved-past.

**Composite signal score** (used by auto-defer, section 7):

```
score = age_percentile × moved_past_percentile     # in [0, 1]
```

**Tiny-vault guard.** If `vault_page_count < 20`, `candidates` writes `pages: []` and logs a one-line warning. Percentiles aren't meaningful below that threshold.

**Snapshot semantics.** Each `candidates` run recomputes percentiles fresh against the current vault state and rewrites the whole `staleness.yaml`. No incremental partial updates. Predictable, testable, matches CR-007's full-scope scan replacing state.

## 6. `wiki/.state/staleness.yaml`

```yaml
schema_version: 1
generated_by: scripts/staleness.js
scanned_at: 2026-05-25T10:00:00Z         # whole-vault snapshot time
vault_page_count: 142                     # used by tiny-vault guard
pages:
  - id: 2026-05-25-001                    # YYYY-MM-DD-NNN, matches CR-007
    path: wiki/concepts/gpt-4-capabilities.md
    signal: high                          # high | medium | low
    factors:
      age_months: 24
      age_percentile: 0.92
      newer_overlapping_sources: 12
      moved_past_percentile: 0.88
    last_reviewed_signal_score: 0.71      # written by judge / resolve / apply-*
    status: unreviewed                    # see enum below
    judgment:                             # null when status: unjudged
      verdict: stale                      # stale | drifting | fresh-but-isolated | false-positive
      reason: "newer sources reframe this around tool-use rather than context windows"
      neighbors_examined:
        - wiki/concepts/tool-use.md
        - wiki/sources/2026-llm-survey.md
      judged_at: 2026-05-25T10:05:00Z
    resolution: null                      # filled on resolved: refreshed | archived | historical
    resolved_at: null
    deferred_at: null
```

### Status enum

| Status | Meaning | `status.js` bucket |
|---|---|---|
| `unjudged` | Script flagged; LLM judge hasn't run yet. | `unjudged_candidates` |
| `unreviewed` | Judge verdict is `stale` or `drifting` — user needs to act. | `unresolved_high` / `unresolved_medium` (by signal) |
| `resolved` | User acted; `resolution` field sub-types it: `refreshed` \| `archived` \| `historical`. | not surfaced |
| `deferred` | User chose "not now". | not surfaced |
| `dismissed` | Judge verdict was `false-positive` or `fresh-but-isolated`. | not surfaced |

### Transitions

```
                ┌─ candidates ─→ unjudged
                │                    │
                │              judge ─┤
                │                    │
                │                    ├─→ unreviewed ─ apply-refresh ──→ resolved (refreshed)
                │                    │       │
                │                    │       ├─ apply-archive   ─→ resolved (archived)
                │                    │       ├─ apply-historical─→ resolved (historical)
                │                    │       └─ resolve defer   ─→ deferred
                │                    │
                │                    └─→ dismissed   (false-positive | fresh-but-isolated)
                │
                └─ re-surface: deferred or dismissed → unjudged
                   ONLY if (new score) > (last_reviewed_signal_score + 0.1)
```

`resolved` is terminal (audit trail; never deleted). Same posture as CR-007's `resolved`.

### Auto-defer (low-touch wedge)

A page that was judged `false-positive`, judged `fresh-but-isolated`, or user-deferred won't re-surface on the next scan unless its composite score is *materially higher* than `last_reviewed_signal_score`. Threshold: Δ > 0.1 (rough one-tier bump). Without this, the same handful of "yes I know this is old" pages reappear every lint run, which violates [[second-brain-low-touch-ux]].

## 7. `scripts/staleness.js`

Single Node.js file under `scripts/` per conventions §7. Mirrors `scripts/contradictions.js` shape: shared helpers (`findVaultRoot`, `readState`, `writeState`, `parseArgs`, `die`), one function per subcommand, single `main()` switch.

### Subcommands

```
candidates [--scope <dir|page-list>] [--json]
list [--status <comma-list>] [--signal <comma-list>] [--json]
judge --id <id> --verdict <stale|drifting|fresh-but-isolated|false-positive> --data <json>
resolve --id <id> --kind defer
apply-refresh --id <id> --rewrite <tmpfile>
apply-archive --id <id>
apply-historical --id <id> [--since <YYYY-MM>]
check --pages <p1>,<p2>,... [--json]
```

### Exit codes

Identical to `contradictions.js`:

- `0` = clean
- `2` = vault not found / malformed yaml / missing required arg / malformed `--data` / `validate-wiki` post-check failure after auto-revert / unsupported subcommand or kind
- `3` = invariant refusal (invalid lifecycle transition, id not found, etc.) — no mutation occurred

### Subcommand behaviour

**`candidates`** — full-vault scan. Read every `.md` under `wiki/{entities,concepts,synthesis,sources}/` (excluding `wiki/archive/**`), compute `age` percentile from mtimes, compute `moved_past` percentile from `sources.yaml` cross-reference, assign composite tier. Merge with existing `staleness.yaml`:
- Entries with `status: unjudged` are dropped and recomputed from this scan.
- Entries in any other status (`unreviewed`, `resolved`, `deferred`, `dismissed`) are preserved as-is — only the auto-defer rule can re-surface `deferred`/`dismissed` to `unjudged`, and `unreviewed`/`resolved` are user-owned until the user acts on them.
- Pages that newly cross the threshold are appended as `unjudged` entries with fresh ids.
- Pages whose composite tier dropped below `medium` since the last scan are left in place if they're in `unreviewed` (the user can still resolve them); they are dropped if they were `unjudged` (never reviewed, no longer interesting).

Write atomically. With `--scope` (a dir or comma-separated page list), restrict the scan but still use vault-wide percentiles.

**`list`** — read-only query, returns entries filtered by `--status` and/or `--signal`. `--json` dumps the raw filtered entries; default emits a one-line-per-entry human format.

**`judge`** — transition `status: unjudged` → `unreviewed` (verdicts `stale`, `drifting`) or `dismissed` (verdicts `fresh-but-isolated`, `false-positive`). Refuses (exit 3) if the entry is not in `unjudged`. `--data` is a JSON blob with `reason` and `neighbors_examined`. Updates `last_reviewed_signal_score`.

**`resolve --kind defer`** — transition `status: unreviewed` → `deferred`. Refuses (exit 3) if not in `unreviewed`. Updates `last_reviewed_signal_score` and `deferred_at`.

**`apply-refresh`** — atomic-replace the page body with the contents of `--rewrite` tmpfile. Run `validate-wiki.js all --page <path>` post-check; on failure, restore original and exit 2 (entry stays `unreviewed`). On success, set `status: resolved`, `resolution: refreshed`, `resolved_at: now`, `last_reviewed_signal_score: <current>`.

**`apply-archive`** — three-part operation:
1. Move `wiki/<X>/<Y>.md` → `wiki/archive/<year>/<X>/<Y>.md` (year from page mtime). Add `lifecycle: { state: archived, original: wiki/<X>/<Y>.md }` to the moved file's frontmatter so an agent reading it directly knows it is a frozen snapshot.
2. Write a stub at the original path with frontmatter:
   - `lifecycle: { state: superseded, by: wiki/archive/<year>/<X>/<Y>.md }`
   - the standard required keys (`tags`, `created`, `updated`) carried over from the archived page
   - `sources: []` (empty, exempt under the new validator rule — see §12)
   The body is a single line: `See [[wiki/archive/<year>/<X>/<Y>]] for the original content.`

Run `validate-wiki.js all`; on failure, restore both files and exit 2. On success, set `status: resolved`, `resolution: archived`.

**`apply-historical`** — edit page frontmatter in place to add `lifecycle: { state: historical, since: <YYYY-MM> }`. Defaults `--since` to the current year-month. No body change. Run `validate-wiki.js all`; on failure, revert and exit 2. On success, set `status: resolved`, `resolution: historical`.

**`check`** — read-only query for `/second-brain:query`. Takes a list of page paths; returns warnings for paths with `lifecycle.state` set in frontmatter OR with `status: unreviewed AND signal: high` in `staleness.yaml`. Output shape:

```json
{
  "warnings": [
    { "path": "wiki/concepts/foo.md", "kind": "historical", "since": "2024-05" },
    { "path": "wiki/concepts/bar.md", "kind": "stale-high", "factors": { "age_months": 24 } }
  ]
}
```

`kind` values: `historical | superseded | archived | stale-high`. Stale `medium`/`low` is not warned (too noisy).

## 8. `skills/status/SKILL.md` modifications

CR-009 currently prints, at the `/status refresh` entry point: *"refresh is not yet available. CR-008 will implement staleness review."* CR-008 replaces that body with the interactive walk.

### Default scope (low-touch)

```
status     == unreviewed
verdict    == stale
signal     == high
```

Hidden by default: `drifting` verdicts, `medium` signal, `dismissed` and `deferred` entries. `/status refresh --all` expands to `signal in {high, medium} AND verdict in {stale, drifting}`. `--include-deferred` adds those back (rarely needed).

### Pre-compute rewrites

Before printing the list, for each in-scope entry the SKILL asks the LLM to write a rewrite proposal to a tmpfile (read page + judge's recorded neighbors + newer overlapping sources). These tmpfiles are cached so the user's `R` keypress is instant.

### Walk

Print a numbered list, one line per entry, with the verdict reason inline:

```
[1] wiki/concepts/gpt-4-capabilities.md  (age 24mo, 12 newer sources)
    stale: newer sources reframe around tool-use, not context windows
[2] wiki/synthesis/ai-team-roles.md      (age 19mo, 7 newer sources)
    stale: superseded by [[ai-collab-patterns]]
...
```

For each entry, prompt one key: `R / A / H / D / S` (refresh / archive / historical / defer / skip).

- `R` → `staleness.js apply-refresh --id <id> --rewrite <tmpfile>`
- `A` → `staleness.js apply-archive --id <id>`
- `H` → ask for `since:` date inline (default current year-month) → `staleness.js apply-historical --id <id> --since <YYYY-MM>`
- `D` → `staleness.js resolve --id <id> --kind defer`
- `S` → no script call; entry stays untouched, no `last_reviewed_signal_score` update

### Wiki log

Single end-of-session entry to `wiki/log.md`:

```
## 2026-05-25 refresh | 2 refreshed, 1 archived, 1 historical, 1 deferred
```

No `since-review.yaml` entry — the user was present (per CR-009 review-log contract: interactive resolutions don't append).

### Allowed tools

`skills/status/SKILL.md` frontmatter currently is `allowed-tools: Bash Read`. The refresh walk needs `Write` for the rewrite tmpfile (the wiki page edit itself flows through `apply-refresh`, never directly from the LLM). Expand to `allowed-tools: Bash Read Write` — same expansion CR-007 made for the reconcile sub-flow.

## 9. `/second-brain:status refresh --judge-only` (headless)

Per the CR-009 review-log contract, this is a cron-safe entry point. No prompts; drains `status: unjudged` into one of four verdict buckets.

**Live convention.** CR-007 shipped the headless reconcile pass as a sub-flow of `/second-brain:status` (`/second-brain:status reconcile --judge-only`), not as a top-level `/second-brain:reconcile`. CR-008 follows the same pattern: `/second-brain:status refresh --judge-only` lives entirely inside `skills/status/SKILL.md`. No new skill file is created — the existing status skill recognises both the interactive `refresh` invocation and the headless `refresh --judge-only` invocation. CR-009's narrative table (which sketched `/second-brain:refresh --judge-only` as a separate skill) is superseded by the shipped reality; the cron example in `docs/install/headless-driving.md` already uses the `/status refresh --judge-only` form.

```
1. Read all status: unjudged entries from staleness.yaml.
2. For each entry, in order:
   a. Sample neighbors: up to K=5 wiki pages whose mtime > this page's
      AND that share ≥1 entity wikilink. One hop only. If <K candidates
      after filter, take what's available. If 0, judge with just the page
      (the moved_past signal must have come from somewhere — likely
      false-positive or fresh-but-isolated).
   b. LLM reads: page body + neighbor bodies + the entry's `factors` block.
   c. LLM emits: { verdict, reason, neighbors_examined }.
   d. Call `staleness.js judge --id <id> --verdict <v> --data '<json>'`.
   e. Call `review-log.js append --kind staleness-judged --data '<json>'`.
3. Exit. No wiki/log.md entry (no human action happened).
```

This is not a separate SKILL file — it's the existing `skills/status/SKILL.md` recognising the `refresh --judge-only` invocation pattern (or a top-level alias resolving to the same body, decided at plan time alongside CR-007's `reconcile --judge-only`).

## 10. `skills/lint/SKILL.md` modification

§3 ("Stale claims") is currently prose-based — it instructs the LLM to "Cross-reference source dates with wiki content. Flag when [list]." This violates conventions §4 (LLM doing deterministic work). Rewrite to match the §2 pattern that CR-007 introduced for contradictions:

```
### 3. Stale claims

Staleness-finding flows through `scripts/staleness.js`. Lint performs
the full-vault candidate scan (enqueueing newly-flagged pages into
`wiki/.state/staleness.yaml` as `status: unjudged`) and reports the
lifecycle counts back to the user.

  node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" candidates --scope=wiki/

  node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" list \
    --status=unjudged,unreviewed,deferred --json

Tally counts by status; surface under "Warnings":

  Staleness: N unjudged, M unreviewed (P high, Q medium), K deferred.
  Run /second-brain:status refresh (interactive) or schedule
  --judge-only via cron.

Do NOT read pages for staleness in this step — the script narrows
deterministically and the judge pass does prose-level filtering.
```

## 11. `skills/query/SKILL.md` modification

Insert a new step between current step 3 ("Read relevant pages") and step 4 ("Check originals"):

```
### 3a. Check lifecycle and staleness

Before composing the answer, check whether any cited page is marked
historical/superseded/archived or flagged as high-signal stale:

  node "$CLAUDE_PLUGIN_ROOT/scripts/staleness.js" check \
    --pages <comma-separated paths> --json

If `warnings` is non-empty, prepend a one-line callout to the answer
summarising the affected pages by kind. Example:

  > Note: this answer cites 1 historical page (2024-05) and
  > 1 page flagged stale-high. Newer information may exist.

Do not block the answer; the user still gets the synthesis, but with
the freshness caveat.
```

## 12. `scripts/validate-wiki.js` modification

Add a new rule family `lifecycle`. Wired into the existing `all` group so the Stop hook (CR-004) picks it up.

```
lifecycle.state must be one of: historical | superseded | archived

If state == historical:
  - `since` required, format YYYY-MM
If state == superseded:
  - `by` required, must resolve as a wikilink target (existing wikilink resolver)
If state == archived:
  - `original` required, must point to wiki/archive/<year>/...

Stub-redirect pages (lifecycle.state == superseded) are exempt from
the `sources: may_be_empty: false` rule in frontmatter-contract.yaml —
they inherit sources from the archived target at apply-archive time,
but the validator must allow the inherited (or empty) shape.
```

Frontmatter-contract.yaml itself doesn't change (it already has `unknown_keys: allowed`); the lifecycle rule is a separate validator step.

## 13. `scripts/status.js` modification

Two-line fix. `readStaleness()` currently hardcodes `unjudged_candidates: 0`. Replace with a real count:

```js
function readStaleness(vault) {
  const doc = readStateYaml(vault, 'staleness.yaml');
  if (!doc) return { unjudged_candidates: 0, unresolved_high: 0, unresolved_medium: 0, present: false };
  const entries = Array.isArray(doc.pages) ? doc.pages : [];
  let unjudged = 0, unresolved_high = 0, unresolved_medium = 0;
  for (const e of entries) {
    if (!e) continue;
    if (e.status === 'unjudged') unjudged += 1;
    else if (e.status === 'unreviewed') {
      if (e.signal === 'high')   unresolved_high   += 1;
      if (e.signal === 'medium') unresolved_medium += 1;
    }
  }
  return { unjudged_candidates: unjudged, unresolved_high, unresolved_medium, present: true };
}
```

Status-script JSON schema (`skills/status/references/status-json-schema.md`) doesn't change — the keys were already declared; CR-008 just makes `unjudged_candidates` non-zero.

## 14. Reference doc updates

- `docs/install/headless-driving.md` — the cron example already includes `/second-brain:status refresh --judge-only` but notes it is a no-op. Update the surrounding prose to mark the call live; the example block itself doesn't change.
- `skills/status/references/status-json-schema.md` — the *staleness* section text mentions CR-008 as the future owner. Update to "owned by CR-008" → "implemented in CR-008" or similar acknowledgement of liveness.
- `docs/cr/CR-008-staleness-review.md` — append a status line under the header noting that CR-008 is implemented as of this spec's plan landing.

## 15. Tests

Mirror CR-007 testing layout: bash test scripts at `tests/test_staleness.sh`, fixture vaults at `tests/fixtures/staleness/<scenario>/`. Every subcommand and every lifecycle transition gets a fixture.

### `tests/test_staleness.sh` scenarios

```
candidates/
  empty-vault/                       → exits 0, writes pages: []
  tiny-vault/                        → <20 pages, exits 0 with warning, pages: []
  age-only/                          → high age, no moved_past → composite stays low
  moved-past-only/                   → newer sources but recent page → composite stays low
  both-signals-high/                 → composite: high
  both-signals-medium/               → composite: medium
  dedupe-existing-entries/           → re-run preserves status of resolved/deferred entries
  auto-defer-no-material-change/     → deferred entry stays deferred when score unchanged
  auto-defer-score-bumped/           → deferred entry returns to unjudged when score Δ > 0.1
list/
  filter-by-status/                  → --status=unjudged returns only unjudged entries
  filter-by-signal/                  → --signal=high returns only high-tier entries
  json-output/                       → --json structure check
judge/
  verdict-stale/                     → unjudged → unreviewed
  verdict-drifting/                  → unjudged → unreviewed
  verdict-fresh-but-isolated/        → unjudged → dismissed
  verdict-false-positive/            → unjudged → dismissed
  invalid-transition/                → judging an already-judged entry → exit 3, no mutation
  schema-mismatch/                   → exit 2
resolve/
  defer-from-unreviewed/             → status: deferred
  defer-invalid-status/              → exit 3
apply-refresh/
  clean-rewrite/                     → page updated, status: resolved, resolution: refreshed
  validate-wiki-failure-reverts/     → tmpfile with broken wikilink → original restored, exit 2
apply-archive/
  moves-and-stubs/                   → file at wiki/archive/<year>/<path>, stub with lifecycle.state: superseded
  inbound-wikilinks-still-resolve/   → stub redirect preserves link integrity (validate-wiki passes)
  validate-wiki-failure-reverts/     → restore both files on failure
apply-historical/
  adds-frontmatter/                  → page gains lifecycle: { state: historical, since: YYYY-MM }
  default-since/                     → omitting --since defaults to current year-month
check/
  no-warnings/                       → all-clean pages → warnings: []
  historical-page/                   → returns kind: historical
  superseded-page/                   → returns kind: superseded
  stale-high-page/                   → returns kind: stale-high
  medium-not-warned/                 → signal:medium does NOT appear in warnings
schema-mismatch/                     → wrong schema_version → exit 2
```

### `tests/test_validate_wiki.sh` additions

```
lifecycle-historical-valid/          → passes
lifecycle-superseded-valid/          → passes (stub redirect)
lifecycle-archived-valid/            → passes (moved page)
lifecycle-bad-state/                 → state: bogus → exit 2
lifecycle-historical-missing-since/  → exit 2
lifecycle-superseded-broken-by/      → `by:` target doesn't resolve → exit 2
lifecycle-stub-sources-empty-ok/     → stub with empty sources passes the may_be_empty rule
```

### `tests/test_status.sh` additions

```
staleness-unjudged-counted/          → unjudged_candidates reflects new status enum
staleness-mixed-statuses/            → only status:unreviewed entries surface in unresolved counts
```

The existing `staleness-populated` fixture is rewritten to use the new status taxonomy (`unjudged | unreviewed | resolved | deferred | dismissed`) — the legacy `reviewed` value goes away.

### Out of scope for tests

- LLM judge call itself (invoked from skill, not script — covered indirectly via the recorded `judgment` field).
- Interactive `/status refresh` walk (skill, not script — covered by ingesting a populated fixture and asserting state transitions via the subcommands the skill calls).
- Cron integration (calls the same `--judge-only` and `apply-*` subcommands).

## 16. Risks and tradeoffs

- **Percentile thresholds shift as the vault grows.** A page that was top-quartile last month may not be next month, purely because new pages arrived. Mitigation: `last_reviewed_signal_score` + the Δ > 0.1 auto-defer rule means the user only re-sees pages whose absolute score actually got worse. Documented in the test fixture `auto-defer-no-material-change`.
- **Single-quartile cutoffs are coarse.** A 0.74 vs 0.76 percentile page lands on different sides of "strong" with no real difference. Acceptable for v1 — the composite AND-shape and the auto-defer rule absorb most of the noise. Revisit if false-positive rate is high in practice.
- **Whole-page rewrite is opaque.** A single diff is hard to review for subtle drift. Mitigation: the user can always `S`kip and edit by hand, and the page stays `unreviewed` so it'll come back next time. We chose whole-page rewrites over paragraph-by-paragraph for pacing reasons; flagged as a watch-item.
- **CR-005 `relations: { contradicts: [...] }` and CR-008 `lifecycle:` are sibling top-level conventions.** They don't conflict — `contradicts` is a relation, `lifecycle` is a page state. But future frontmatter additions need to check both. Documented in CR-008's validator rule.
- **`apply-archive` git-rename is a structural change.** If a downstream tool watches for specific wiki paths, archiving moves the file out from under them. Mitigation: stub redirect at the original path means wikilink-based consumers (the only kind in this project) still resolve.

## 17. Open questions deferred

- **Should the score Δ for auto-defer be tunable per vault?** v1 hard-codes 0.1 as a constant in the script. If real usage shows it's wrong for some vaults, promote to a config knob (no `staleness-config.yaml` proposed now; conventions §3 would need updating).
- **Should `staleness.js candidates` accept `--exclude-archive` by default?** Pages under `wiki/archive/` shouldn't be scored. v1 hard-excludes `wiki/archive/**` from the candidate scope; revisit if users want to flag archives as having drifted further.
- **Cluster-level staleness.** Pages judged `fresh-but-isolated` are individually fine but reveal a connectivity gap. A future CR could roll those into a connectivity-pass suggesting wikilink additions. Out of scope for CR-008.
- **`drifting` verdict triage.** v1 hides `drifting` from the default `/status refresh` walk (only `stale` surfaces). If `drifting` accumulates and users want a separate sweep, add `/status refresh --drifting` as a follow-up.

## 18. Out of scope (carried from CR-008 doc)

- **Automatic refresh** (LLM rewrites pages without user confirmation).
- **Embedding the staleness flag** into a vector store.
- **Cross-vault staleness.**
- **Staleness in `raw/` or `src/`.**
- **Deletion of stale pages.** Archive, never delete.
