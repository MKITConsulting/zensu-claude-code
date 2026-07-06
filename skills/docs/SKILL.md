---
name: docs
description: >
  Author genuine, code-grounded documentation for a tracked Zensu feature — or a
  whole product/component in one batch — so the feature honestly clears the
  hardened `docs_complete` release gate. For each feature it reads the REAL linked
  source, writes ONE feature-specific doc of the correct type (derived from the
  feature's `feature_scope`), publishes it as a Zensu wiki page (default) or a
  per-feature repo markdown file, links it with `zensu link docs` so the docs
  score recomputes, and verifies the gate flipped. It produces one doc PER feature
  — never a shared README linked across many features (the exact false-green the
  gate now rejects) — and forbids placeholder / metadata-dump stubs: content must
  describe what THIS feature actually does, citing real code. Batchable across
  parallel read-only authoring agents; idempotent (skips features already
  `docs_complete`); logs every feature skipped or failed (no silent truncation).
  Use whenever the user wants to document a feature, "write the docs", "generate
  feature documentation", "clear the docs gate", "backfill missing docs" across a
  product/component, make a feature release-ready on the docs axis, or the slash
  command /zensu:docs.
---

# /zensu:docs

Author **genuine, code-grounded documentation** for a tracked Zensu feature (or a
whole product/component in one batch) and link it so the feature clears the
`docs_complete` release gate — one honest doc per feature, grounded in the real
source, never a shared README.

> This is the documentation stage of the Zensu feature lifecycle — the sibling of
> `/zensu:implement` (build), `/zensu:security-review` (harden), and
> `/zensu:ghost-scan` (discover). It is the ONLY lifecycle stage that authors NEW
> feature docs. `/zensu:ghost-scan` links **existing** repo docs it finds; this
> skill **writes** the docs a feature is missing.

## When to Use

- A feature is `released`-blocked on docs (its `docs_complete` gate is false).
- Backfilling missing documentation across a product or a single component.
- Refreshing a doc that CI marked `is_outdated` after a code change.
- Right after `/zensu:implement` when the feature shipped without a linked doc.

**Not this skill?** No feature tracked yet → `/zensu:ghost-scan` (brownfield) or
`/zensu:bootstrap` (greenfield) first. Implementing code → `/zensu:implement`.

## Prerequisites

- Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`) and on `PATH`.
- Authenticated: `zensu auth login` (check with `zensu auth status`). If any
  command fails with an auth error (`invalid_grant`, expired/invalid token, `401`,
  not authenticated), run `zensu auth login` and retry.
- A target: a feature ID in **KEY-N** form (e.g. `ZEN-42`) or a UUID for a single
  run, OR a product/component for a batch run.
- The feature's source files are linked (via `/zensu:ghost-scan` or
  `/zensu:implement`). A doc grounded in code needs code to read — a feature with
  zero linked source can only yield a stub, which this skill refuses to publish.

Every command accepts `--json` for machine-readable output; run
`zensu <noun> <verb> --help` for the full flag set. This skill is credential-blind
and host-agnostic — it never hardcodes a SaaS URL and never prints a token.

## Arguments

Slash form: `/zensu:docs [<target>] [--flag=value ...]`.

| Arg | Required | Default | Notes |
|---|---|---|---|
| `<target>` | no | asks | A feature id (`ZEN-42` / UUID) for a single run, or a product id for a batch. |
| `--product=<id>` | for batch | — | Batch over a whole product's features. |
| `--component=<slug>` | no | all | Batch-scope to one component (filtered client-side from the product's feature list). |
| `--status=<s>` | no | all | Filter the batch by status (`planned\|in-progress\|testing\|released`). |
| `--repo-file` | no | off (wiki) | Author the doc as a per-feature repo markdown file instead of a Zensu wiki page. |
| `--force` | no | off | Re-author even for features already `docs_complete` (default skips them). |

## The `docs_complete` contract (read this first)

The release gate (`DocsStrictness`, zensu-monorepo) satisfies a required
`doc_type` for a feature **only** with a live doc that is ALL of:

1. **Fresh** — not `is_outdated`. CI flips `is_outdated` when the feature's code
   changes, so a stale doc no longer counts. (`require_fresh = true`.)
2. **Feature-specific** — about ONE feature, not a component README shared across
   many features.
3. **Not over-shared** — its `file_path`/`external_url` is linked by **≤ 3
   features** (`shared_doc_max = 3`, product-scoped, archived docs excluded).

A per-feature repo file or an external URL counts on its own — a wiki page is NOT
required (`require_feature_page = false`, i.e. wiki-only is opt-in).

**What this forces the skill to do — three hard rules:**

- **Rule 1 — one doc PER feature.** Never link one shared README across many
  features. Wiki mode satisfies this structurally (each `zensu link docs`
  authors a fresh page for its one feature). Repo-file mode satisfies it by
  writing a unique per-feature path (`docs/features/<KEY-N>-<slug>.md`) — never a
  shared component README. This is the precise false-green the gate now rejects.
- **Rule 2 — correct `doc_type`** derived from the feature's `feature_scope` (see
  the table below).
- **Rule 3 — grounded in real code, never a stub.** The scorer cannot see content
  (the content-length lever was deliberately dropped), so quality is a
  **discipline gate**, not a mechanical one: every doc must describe what THIS
  feature actually does and cite its real source. Placeholder, boilerplate, or
  metadata-dump docs are forbidden by the Definition of Done below.

## Doc type by feature scope

Derive the required `doc_type`(s) from the feature's `feature_scope` (read it in
Phase 2). Author one doc per required type.

| `feature_scope` | Required `doc_type`(s) | Audience |
|---|---|---|
| `default` | `user_facing` | `end_user` |
| `api` | `api_reference` | `developer` |
| `internal_only` | `adr` | `internal` |
| `public_facing` | `user_facing` — **plus** `tutorial` when `estimated_effort` ∈ {L, XL} | `end_user` / `developer` |

If `feature_scope` is absent (an older backend), default to `user_facing` and say
so. When a `public_facing` feature's `estimated_effort` is unknown, author the
`user_facing` doc and note that the `tutorial` was skipped for lack of an effort
signal — do not guess. The eight canonical doc types and their required focus live
in `docs/documentation-guide.md`.

## Workflow

**Workflow gate (first + last action).** As the VERY FIRST action, run
`bash "$(cat "$HOME/.zensu/plugin-root")/hooks/lib/zensu-log.sh" --workflow-begin --tools "link_docs,create_wiki_page,update_wiki_page"`.
This marks the Zensu product workflow active so the CLI write-gate
(`hooks.mcpGate`, default-on) recognizes this skill's `zensu link docs` /
`zensu wiki create` / `zensu wiki update` commands as workflow-driven rather than
freelance and does not block them. As the VERY LAST action (after the final phase,
or on early exit), run
`bash "$(cat "$HOME/.zensu/plugin-root")/hooks/lib/zensu-log.sh" --workflow-end`.

All Zensu **mutations** (`zensu link docs`, `zensu wiki create/update`) run in
**this main thread** under that marker. The Phase 3 authoring fan-out uses
read-only `Explore` agents that cannot mutate — the exact invariant
`/zensu:ghost-scan` follows (fan out to read, consolidate + write in the main
thread).

### Phase 1 — Scope & target selection

1. **Single feature:** the `<target>` is a feature id. Skip to Phase 2.
2. **Batch (product or component):**
   1. Load the feature set: `zensu features list --product <product-id> --json`
      (add `--status <s>` when `--status` was given). `--component` is filtered
      **client-side** — the list command scopes by product, so select the
      component's features from the JSON yourself; do not pass a `--component`
      flag the CLI does not have.
   2. **Idempotency — skip what is already done.** For each feature read
      `docs_complete`. Skip every feature already `docs_complete` unless `--force`
      is set. `log` the skipped count and ids: a skipped feature must read
      "already complete," never be silently dropped.
   3. Present the work list (features to document, features skipped) and the
      per-feature target `doc_type`(s). For a large batch, state the wave plan.

### Phase 2 — Load feature context (the map)

For each feature to document:

1. `zensu features get <feature-id> --json` — read `feature_scope`,
   `estimated_effort` (may live on the latest revision), `slug`, the KEY-N key,
   `product_id`, and `docs_complete`. Derive the required `doc_type`(s) from the
   table above.
2. `zensu doc gen-context <feature-id> --doc-type <type>` — the aggregated
   authoring **context map**: linked source-file paths, symbols, subfeatures,
   security posture, tiers, journeys, existing docs. Per
   `docs/documentation-guide.md`, this is the **map, not the territory** — it lists
   *which* files matter and *what* constraints apply; it does NOT contain the
   source code.
3. If gen-context reports zero linked source files, STOP for that feature: a
   code-grounded doc needs code. Report it as blocked (recommend `/zensu:implement`
   or `/zensu:ghost-scan` to link source) rather than publishing a stub.

### Phase 3 — Author code-grounded docs (read the territory)

**Read `docs/documentation-guide.md` before authoring** — it is the code-grounding
source of truth. The failure it exists to prevent is the **metadata dump**:
condensing gen-context metadata straight into `## Purpose / ## Source files /
## Security / ## Notes` sections without opening a single source file. That is the
feature record reformatted, not documentation. Never publish it.

**Single feature (in this thread):**

1. **Read the real source files** gen-context named (Read / Grep) — actual
   signatures, endpoints, request/response shapes, config keys, error codes, data
   flow.
2. Author Markdown grounded in that code, matched to the `doc_type`'s focus and
   audience (see the guide's focus table). Cite real symbols; if you did not see
   it in the source, do not claim it.

**Batch (parallel authoring fan-out — model on `/zensu:ghost-scan` Phase 2b):**

1. Spawn authoring agents in ONE parallel batch with the `Agent` tool,
   `subagent_type: Explore` (read-only — they cannot mutate Zensu or write repo
   files, so every mutation stays in the main thread under the workflow marker).
2. Each agent authors exactly ONE feature's doc. It receives: the feature id,
   title, the target `doc_type`(s) + audience, and this instruction — run
   `zensu doc gen-context <id> --doc-type <type>` (a read, ungated), **Read the
   real source files it names**, author code-grounded Markdown per
   `docs/documentation-guide.md`, and return `{feature_id, doc_type, title,
   audience, markdown}`. It performs NO Zensu writes.
3. **Cap concurrency (~8–12 agents) and wave through large batches.** A
   256-feature product is many waves — `log` wave progress and never silently cap:
   a trimmed batch must read as "capped on purpose," not "covered everything."
4. Collect the returned markdown; the main thread does the linking in Phase 4.

### Phase 4 — Publish & link (recompute the score)

Do this in the main thread, per feature, under the workflow marker.

**Wiki mode (default — keeps docs in-Zensu, no repo pollution).** One call authors
the feature-linked wiki page AND recomputes the score:

```
zensu link docs <feature-id> \
  --doc-type <type> --title "<title>" --audience <audience> \
  --content "<authored-markdown>"
```

`--content` creates (or updates) the wiki page linked to this one feature;
`--publish-to-wiki` defaults true; the call **automatically updates the feature's
docs score**. To inspect or refresh an existing page instead of re-creating it,
use `zensu wiki list --entity-type feature --entity-id <feature-uuid> --json` and
`zensu wiki update <page-id> --content "<markdown>"`, then re-run `zensu link docs`
to recompute. For a `public_facing` L/XL feature, run `zensu link docs` once per
required type (`user_facing` and `tutorial`).

**Repo-file mode (`--repo-file`).** Write a **unique per-feature** file, then link
it:

```
# Write docs/features/<KEY-N>-<slug>.md   (one file per feature — never a shared README)
zensu link docs <feature-id> \
  --doc-type <type> --title "<title>" \
  --file docs/features/<KEY-N>-<slug>.md --publish-to-wiki=false
```

The per-feature path guarantees exactly one feature links it, satisfying the
over-share rule (≤ 3 features). **Never** link a shared component README to many
features — that is the false-green the gate rejects.

> Doc-link auto-fires the per-feature score recompute; the CLI exposes no
> standalone product-scoped recompute verb (the server-side `RecomputeDocsScore`
> is not a CLI command), so the per-feature `zensu link docs` recompute in this
> phase is the mechanism for the whole batch.

### Phase 5 — Verify the gate flipped

Per feature, `zensu features get <feature-id> --json` and confirm
`docs_complete` is now `true`. If it is still false, the doc did not satisfy a
required type — diagnose against the contract and fix:

- **Wrong/missing type** → author the missing `doc_type` (Phase 3–4).
- **`is_outdated`** → re-author (refresh) so the doc is fresh again.
- **Over-shared `file_path`** (linked by > 3 features) → switch that feature to a
  unique per-feature file or a wiki page.

If the backend predates the docs gate and returns no `docs_complete` field, report
that the recompute ran but the gate field is absent — do not claim a flip you
cannot observe.

### Phase 6 — Batch summary (no silent truncation)

Report three explicit buckets:

- **Documented** — feature, `doc_type`(s), wiki page / file path, `docs_complete`
  now true.
- **Skipped** — already `docs_complete` (or `--force` not set).
- **Failed / blocked** — zero linked source, an unmet gate after linking, or a
  command error — with the reason. Never let a failed feature vanish from the
  count.

## Definition of Done

A discipline gate — the scorer cannot see content, so the skill enforces quality:

- [ ] **Read `docs/documentation-guide.md`** and opened the real linked source
      files — not just their gen-context paths.
- [ ] Every doc **describes what THIS feature actually does** and cites real
      signatures / endpoints / config / behavior from its source.
- [ ] It is **not** the metadata-dump anti-pattern (a reformatted feature record).
- [ ] **One doc per feature**, correct `doc_type` from `feature_scope`, fresh, and
      not over-shared (unique per-feature `file_path`, or a wiki page).
- [ ] `docs_complete` verified `true` per feature (Phase 5).
- [ ] Every batch feature is accounted for as documented / skipped / failed — no
      silent truncation.
- [ ] English-only; no hardcoded SaaS URL; no token printed.

A feature whose only available doc would be a placeholder is reported **blocked**,
never published green.

## CLI Commands Used

| Command | Phase | Purpose |
|---|---|---|
| `zensu features list` | 1 | Load the batch feature set (scope by product; filter component/status client-side) |
| `zensu features get` | 2, 5 | Read `feature_scope` / `estimated_effort` / `docs_complete`; verify the gate flipped |
| `zensu doc gen-context` | 2, 3 | Aggregated authoring context map (paths + posture, not source) |
| `zensu link docs` | 4 | Publish (via `--content`) + link the doc; auto-recomputes the docs score |
| `zensu wiki list` | 4 | Inspect existing feature-linked wiki pages (idempotency / refresh) |
| `zensu wiki update` | 4 | Refresh an existing wiki page's content |
| `zensu wiki create` | 4 | Author a standalone wiki page when not using the `link docs --content` one-call path |

## Agents & Skills Used

| Component | Type | Phase | Purpose |
|---|---|---|---|
| `Explore` | subagent (read-only) | 3 | Parallel per-feature authoring fan-out — reads source + gen-context, returns markdown, never mutates |
| `docs/documentation-guide.md` | reference | 3 | The code-grounding source of truth (doc types, focus, anti-pattern, checklist) |
