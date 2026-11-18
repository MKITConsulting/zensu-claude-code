# Documentation Guide

How to generate feature/component documentation in Zensu so it is **grounded in
the actual source code**, correctly typed, and useful — not a restatement of
feature metadata.

This is the single source of truth referenced by `agents/zensu-plm.md`,
`skills/implement/SKILL.md`, and `skills/ghost-scan/SKILL.md`. Read it before
creating any wiki page or linked doc.

## What a Zensu doc IS

A Zensu doc explains **real behavior, read from the real source files** — actual
endpoints, function signatures, request/response shapes, config keys, error
codes, data flow. It is written for a specific **audience** and a specific
**doc type** (see below).

`zensu doc gen-context <feature-id> --doc-type <type>` returns the
**map, not the territory**: the feature title, description, `detectedSourceFiles`
paths, security posture, tiers, journeys, and symbol metadata. It tells you
*which* files matter and *what* security/tier constraints apply. It does **not**
contain the source code. You must open and read those files yourself before
writing.

The agent has filesystem access. Reading the real source produces docs that are
*better* than the backend's frontend-only generator (which sees only extracted
symbol metadata, never full source).

## Anti-pattern (forbidden): the metadata dump

The failure this guide exists to prevent: condensing the
`zensu doc gen-context` metadata straight into Markdown without reading any
source. It produces generic, templated pages that just re-list feature
attributes — e.g.:

```
## Purpose
<feature.description verbatim>
## Source files
<detectedSourceFiles paths, nothing about what they do>
## Security
Classification: confidential · Security score: 5.5
## Notes / Integrations
Priority high, status planned. Reference docs: …/README.md
```

This is **not documentation** — it is the feature record reformatted. Never
publish it. If you have not opened the source files, you are not ready to write.

## Doc types

Canonical set (8). The **Focus** column is the authoritative description of what
each type must contain — it mirrors the backend doc generator verbatim.

| `doc_type`      | audience            | Focus |
|-----------------|---------------------|-------|
| `user_facing`   | `end_user`          | How end users interact with this feature. Usage examples, prerequisites, step-by-step instructions. |
| `api_reference` | `developer`         | API endpoints, request/response formats, authentication, error codes, integration examples. |
| `tutorial`      | `developer`         | Step-by-step instructions through a concrete task. Prerequisites, expected outcomes, troubleshooting tips. |
| `adr`           | `internal`          | The architectural decision, context, alternatives considered, consequences. ADR format: Status, Context, Decision, Consequences. |
| `release_notes` | `end_user`          | What changed: new features, improvements, bug fixes, breaking changes, migration steps. |
| `internal`      | `internal`          | Architecture decisions, data flow, component interactions, configuration, dependencies, known limitations. |
| `migration_guide` | `developer`       | Breaking changes, step-by-step migration, database migrations, rollback procedures, verification steps. |
| `overview`      | `developer`         | High-level overview of the component/feature: responsibilities, contained features, architecture, API surface. |

Audiences: `end_user`, `developer`, `admin`, `internal`.

Pick the type by what the reader needs. A confidential backend feature usually
warrants `internal` (+ `api_reference` if it exposes endpoints); a user-visible
capability warrants `user_facing`; an architectural choice warrants `adr`.

## Procedure (read-source-first)

1. **Get the map.** Run `zensu doc gen-context <feature-id> --doc-type <type>`
   with the target doc type. Note the `detectedSourceFiles`, symbols, security
   posture, tiers, and journeys.
2. **Read the territory.** Open the source files named in the context (Read /
   Grep). For `api_reference`, find the real route definitions and DTOs; for
   `internal`, trace the data flow across the files; for `user_facing`, find the
   real entry points and config the user touches.
3. **Author, grounded in code.** Write Markdown that cites real symbols,
   signatures, endpoints, and behavior — matched to the doc type's Focus and the
   audience. No invented APIs; if you did not see it in the source, do not claim
   it.
4. **Publish, updating a page that already exists.** A re-run changes the page it
   published before; it never creates a second one. Look the page up first: the
   context's `existingDocs` entry for the `doc_type` carries the linked page's
   `wikiPageId`, and `zensu wiki list --product <id> --json` returns every page
   with its `id` and `path`. A feature-linked page lives at
   `/features/<feature slug>/<doc_type>`, an unlinked one at
   `/custom/<slug of the title>`.
   - **The page exists:** `zensu wiki update <page-id> --content-file <path>
     --change-summary <text>` replaces its markdown with the file's.
   - **No page yet:** `zensu wiki create --product <id> --title <title> --content-file
     <path> --entity-type feature --entity-id <feature-id> --doc-type <type>
     --audience <audience>`. Create never changes an existing page: when a page
     already exists at the new page's path, it fails, names that page's id and
     path, and leaves it unchanged. Update the page it names. Never retry the
     create under another title to get past the error; that leaves the old page
     stale beside a duplicate. zensu-cli sends this create-only request
     (`createOnly`) from 0.12.0 on, so every zensu-cli the plugin supports sends it.
     A zensu-cli before 0.12.0, or a Zensu backend before v0.89.2 or wiki before
     v0.15.1, does not refuse: create then updates the existing page and still
     reports a created one, which is why the lookup comes first.

   Then `zensu link docs <feature-id> --doc-type <type>` updates the feature's
   docs score. Use `zensu link docs` alone (no wiki page) only for docs that
   already live in the repo or at an external URL (`--file <path>` or
   `--external-url <url>`).

   *CLI one-call form.* For a feature that has no page for the `doc_type` yet,
   `zensu link docs <feature-id> --doc-type <type> --content-file <path>` folds
   these two steps into one — `--content-file` creates the feature-linked wiki page
   and recomputes the score. It never changes an existing page, so a re-run updates
   the page as above and then runs `zensu link docs` without `--content-file`. The
   `/zensu:docs` skill uses this form under the same rule; the two-step
   `zensu wiki create` + `zensu link docs` above stays valid when you want
   explicit control over the page. Every `--content-file` names a file of
   markdown: write it through a heredoc with a quoted delimiter as `/zensu:docs`
   does, and never type the markdown into a double-quoted argument, where the shell
   runs its backtick spans and expands its `$` names. zensu-cli reads the file
   itself and refuses a missing, empty, blank or non-UTF-8 file before it sends
   anything.

## CLI commands

| Command | Role |
|---------|------|
| `zensu doc gen-context <feature-id> --doc-type <type>` | Fetch the context (the map). Read the named source before writing. |
| `zensu wiki list --product <id> --json` | List a product's wiki pages with their `id` and `path`, to find the page a re-run updates. |
| `zensu wiki create` / `zensu wiki update <page-id>` | Publish authored markdown to the wiki (`--content-file` names the file that holds the full markdown). Create a new page with `zensu wiki create`; change a page that already exists with `zensu wiki update`. |
| `zensu link docs <feature-id> --doc-type <type>` | Register a doc against a feature and update the docs score. With `--content-file <path>` it also creates the linked wiki page when the feature has none for that doc type yet, and never changes an existing one; `--file` / `--external-url` register a repo or external doc. |

The rich `POST /api/features/{id}/docs/generate` streaming LLM path is
**frontend-only** — no `zensu` command calls it. Agents do not call it;
they self-author from real source per the procedure above.

## Quality checklist

Before publishing, confirm:

- [ ] I opened and read the `detectedSourceFiles` — not just their paths.
- [ ] Content cites real signatures / endpoints / config / behavior from those files.
- [ ] It matches the doc type's Focus and is written for the stated audience.
- [ ] It is not the anti-pattern (a reformatted feature record).
- [ ] `doc_type` and `audience` are from the canonical sets above.
