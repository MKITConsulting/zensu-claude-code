# /zensu:ghost-scan

Scan an existing repository to discover undocumented features, then review and import them into Zensu as tracked features with linked tests, docs, and source files.

## When to Use

- Importing an existing codebase into Zensu for the first time
- Discovering undocumented features in a repository
- Linking tests, docs, and source files to newly created features

## Prerequisites

- Zensu MCP Server connected (plugin auto-configures via `ZENSU_MCP_URL`)
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
5. **For large repos (>500 files):** Scan only top-level modules, max 3 directory levels deep. Ask the user if a deeper subdirectory scan is desired.
6. Filter candidates against existing features from Phase 1 to avoid duplicates
7. If a candidate matches an existing feature slug, **reuse the exact existing slug** — this enables enrichment during apply
8. Present candidates to the user as a table — do NOT submit yet, let the user review first
9. The user can edit, remove, or add candidates before submission

#### Candidate Quality Rules

**Feature-level, not function-level:**
- Prefer domain-level grouping: `authentication` instead of `auth-login`, `auth-register`, `auth-logout`
- If multiple packages share a domain concept, propose one feature, not several
- Minimum 3 source files for a feature (otherwise likely a utility)
- When in doubt, fewer and broader features — the user can split later with `split_feature`

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

1. Call `ghost_scan` with product_id, candidates array, repo_url, and branch
2. Output: "Scan created with {n} candidates ({x} high, {y} medium, {z} low confidence). Ready for review."

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

3. Offer batch operations:
   - "Approve all high confidence" — approve all >= 0.7
   - "Reject all low confidence" — reject all < 0.4
   - "Reject specific: #13, #18" — reject individually
   - "Approve all" / "Reject all"
   - "Tell me more about #13" — detail view for individual decision
4. Execute `ghost_batch_review` with `approve_ids` and `reject_ids` arrays to process all decisions in a single call. Optionally provide `reject_reason` for rejected candidates.
5. If at least 1 approved: call `ghost_apply` with `enrich_existing=true` if the product already has features (check Phase 1 feature list). Use `enrich_existing=false` only for the very first scan on an empty product.
6. Summary: "{n} features created, {e} features enriched, {m} components created, {t} tests linked, {d} docs linked, {s} source files linked"

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
