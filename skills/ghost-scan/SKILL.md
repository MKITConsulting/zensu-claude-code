# /zensu:ghost-scan

Scan an existing repository to discover undocumented features, then review and import them into Zensu as tracked features with linked tests, docs, and source files.

## When to Use

- Importing an existing codebase into Zensu for the first time
- Discovering undocumented features in a repository
- Linking tests, docs, and source files to newly created features

## Prerequisites

- Zensu MCP Server connected (plugin auto-configures via `.mcp.json`)
- `ZENSU_API_KEY` environment variable set
- Product ID known (create one first with `/zensu:bootstrap` if needed)
- Working in the repository root (or a subdirectory)

## Workflow

Execute these phases in order. Present results to the user after each phase and wait for confirmation before proceeding.

### Phase 1: Setup & Context

1. Confirm the product ID via `list_products`
2. Call `list_features` with `product_id` and `view=compact` to load existing feature slugs
3. Show existing features to the user: "These features already exist and will not be suggested again"
4. **Resume check:** Call `ghost_get_candidates` to check for open scans. If a scan in "review" status exists, ask the user whether to resume or start a new scan
5. Confirm the repo path and branch

### Phase 2: Repo Analysis & Candidate Extraction

1. Walk the file tree with periodic feedback: "Analyzing auth/ (15 files)... Analyzing users/ (8 files)..."
2. Skip these directories: `vendor/`, `node_modules/`, `dist/`, `.git/`, `__pycache__/`, `.next/`, `build/`, `target/`
3. Identify file types:
   - **Test files:** `*_test.go`, `*.test.ts`, `*.test.tsx`, `test_*.py`, `*_spec.rb`, `*.spec.ts`
   - **Source files:** `*.go`, `*.ts`, `*.tsx`, `*.py`, `*.java`, `*.rs` (excluding test files)
   - **Doc files:** `README*`, `docs/**/*.md`, `*.rst`, `CHANGELOG*`
4. Group files by module/package and extract feature candidates
5. **Populate each candidate's three detection arrays — `detectedSourceFiles`, `detectedTestFiles`, `detectedDocFiles`.** These arrays are the *only* data `ghost_apply` uses to link artifacts — it links exactly what you pass, so an empty array links zero. Never leave `detectedTestFiles` empty by omission: an empty array must mean "globbed and found none," not "skipped."
6. **Tests are co-located — glob them per candidate.** Tests live in the same directories as a feature's source files. For each candidate, after collecting `detectedSourceFiles`, glob the test-file patterns from step 3 within those same directories *and* their sibling test dirs (`test/`, `tests/`, `__tests__/`, `spec/`, `specs/`), and assign every match to that candidate's `detectedTestFiles`. A capability feature spanning multiple modules collects tests from all of its source dirs.
7. **For large repos (>500 files):** Scan only top-level modules, max 3 directory levels deep. Ask the user if a deeper subdirectory scan is desired. Still glob the test dirs at each scanned level — capping breadth must not silently drop tests.
8. Filter candidates against existing features from Phase 1 to avoid duplicates
9. If a candidate matches an existing feature slug, **reuse the exact existing slug** — this enables enrichment during apply
10. Present candidates to the user as a table — do NOT submit yet, let the user review first
11. The user can edit, remove, or add candidates before submission

#### Candidate Quality Rules

**Feature-level, not function-level:**
- Prefer domain-level grouping: `authentication` instead of `auth-login`, `auth-register`, `auth-logout`
- If multiple packages share a domain concept, propose one feature, not several
- Minimum 3 source files for a feature (otherwise likely a utility)
- When in doubt, fewer and broader features — the user can split later with `split_feature`

**Test-file completeness (treat like the source-file rule, not a bonus):**
- Every candidate that has source files MUST have its co-located tests detected (Phase 2, step 6). Populate `detectedTestFiles` with the same rigor as `detectedSourceFiles`.
- An empty `detectedTestFiles` is acceptable ONLY after globbing the candidate's source dirs confirms genuinely zero tests — never as a default for "didn't look."
- Shared/helper tests that map to no single feature (e.g. `app.controller.spec.ts`, `helpers/*.spec.ts`) may stay unlinked or attach to a shell/account feature — do not force them onto an unrelated candidate.

**Never create candidates for:**
- CI/CD configuration (`.github/`, `.gitlab-ci.yml`, `Jenkinsfile`)
- Build tooling (`Makefile`, `Dockerfile`, `docker-compose.yml`)
- Linting/formatting (`.eslintrc`, `.prettierrc`, `golangci.yml`)
- IDE settings (`.vscode/`, `.idea/`)
- Package manager locks (`go.sum`, `package-lock.json`, `yarn.lock`)
- Vendor/dependencies (`vendor/`, `node_modules/`)

#### Confidence Score Heuristic

Confidence scores are heuristic estimates, not ML predictions. Use them to prioritize review, not as ground truth.

| Tier | Range | Criteria |
|------|-------|----------|
| High | >= 0.7 | Dedicated tests + clear module boundary (own package) |
| Medium | 0.4-0.7 | Either tests OR docs present, or clear boundary without tests |
| Low | < 0.4 | No tests, no docs, unclear boundary |

Building blocks:
- Dedicated test files: +0.3
- Documentation present: +0.2
- Clear directory boundary (own package/module, >= 3 source files): +0.3
- README mention or config reference: +0.2
- Single file / unclear boundary: -0.2
- Utils/helpers/infrastructure code: -0.3

#### Security Classification Heuristic

Suggest a classification for each candidate (user verifies):
- `restricted`: auth/, crypto/, keys/, secrets/, certs/
- `confidential`: billing/, payment/, admin/
- `internal`: default for all others
- `public`: only when user explicitly confirms

### Phase 3: Create Ghost Scan

1. Call `ghost_scan` with `product_id`, the `candidates` array, `repo_url`, and `branch`. Each candidate carries its three detection arrays — populate all of them, and never omit `detectedTestFiles`:

   ```json
   {
     "slug": "authentication",
     "title": "Authentication",
     "componentSlug": "auth",
     "confidenceScore": 0.8,
     "detectedSourceFiles": ["src/auth/login.ts", "src/auth/session.ts"],
     "detectedTestFiles": ["src/auth/login.test.ts", "src/auth/session.spec.ts"],
     "detectedDocFiles": ["docs/auth.md"],
     "securityClassification": "restricted"
   }
   ```

2. **Pre-submit self-check.** Sum `detectedTestFiles` across all candidates. If the Phase 2 walk surfaced test files but the sum is 0 — or far below what you saw — the per-candidate mapping is broken: STOP and re-glob each candidate's source dirs (step 6) before submitting. Importing source without its tests understates real test maturity and skews release gates.
3. Output: "Scan created with {n} candidates ({x} high, {y} medium, {z} low confidence), {t} tests mapped across candidates. Ready for review."

### Phase 4: Batch Review & Apply

1. Call `ghost_get_candidates` to load all candidates
2. Present candidates as a confidence-grouped table:

```
### High Confidence (>= 0.7) — 12 candidates
 # | Slug              | Component  | Tests | Docs | Source
 1 | auth-login        | auth       | 3     | 1    | 5
 2 | user-profile      | users      | 2     | 1    | 3

### Medium Confidence (0.4-0.7) — 5 candidates
13 | api-middleware     | middleware | 0     | 0    | 4

### Low Confidence (< 0.4) — 3 candidates
18 | config-loader     | infra      | 0     | 0    | 1
```

   **Scan the Tests column before approving.** If it reads 0 for candidates that clearly own source files, the scan missed test detection — do not approve blindly. Return to Phase 2 step 6, re-glob, and re-create the scan. An all-zero Tests column on a repo that has tests is a detection bug, not a property of the code.

3. Offer batch operations:
   - "Approve all high confidence" — approve all >= 0.7
   - "Reject all low confidence" — reject all < 0.4
   - "Reject specific: #13, #18" — reject individually
   - "Approve all" / "Reject all"
   - "Tell me more about #13" — detail view for individual decision
4. Execute `ghost_batch_review` with `approve_ids` and `reject_ids` arrays to process all decisions in a single call. Optionally provide `reject_reason` for rejected candidates.
5. If at least 1 approved: call `ghost_apply` with `enrich_existing=true` if the product already has features (check Phase 1 feature list). Use `enrich_existing=false` only for the very first scan on an empty product.
6. Summary: "{n} features created, {e} features enriched, {m} components created, {t} tests linked, {d} docs linked, {s} source files linked"
7. **Backfilling a scan that missed tests.** If features were already created with zero linked tests, do NOT re-create them. Re-run Phase 2 with co-located test globbing, create a fresh scan that **reuses the exact existing slugs**, approve, and call `ghost_apply` with `enrich_existing=true` — apply matches by slug and attaches the newly detected tests to the existing features, no duplicates. This costs ~2 calls per module (scan + apply) instead of one `link_test` per test file.

### Phase 5: Summary & Next Steps

1. List created features via `list_features` with `product_id` and `view=compact`
2. Recommend next steps:
   - `/zensu:implement` for feature implementation
   - `/zensu:security-review` for security classification
   - `generate_claude_md` for an updated CLAUDE.md

## MCP Tools Used

| Tool | Phase | Purpose |
|------|-------|---------|
| `list_products` | 1 | Validate product |
| `list_features` | 1, 5 | Load existing features (dedup) |
| `ghost_scan` | 3 | Create scan with candidates |
| `ghost_get_candidates` | 1 (resume), 4 | Load candidates |
| `ghost_batch_review` | 4 | Batch approve/reject candidates in one call |
| `ghost_apply` | 4 | Apply approved candidates (use `enrich_existing=true` if product has features) |
| `generate_claude_md` | 5 | Update CLAUDE.md (optional) |
