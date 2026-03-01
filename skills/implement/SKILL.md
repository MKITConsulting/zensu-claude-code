# /zensu:implement

Implement a tracked Zensu feature end-to-end. Loads feature context, provides security-aware implementation guidance, then links all artifacts (tests, docs, source files) and creates a revision.

## When to Use

- Starting implementation of a planned feature
- Resuming work on an in-progress feature
- Completing a feature with proper artifact linking

## Prerequisites

- Zensu Backend running (`make dev` in `backend/`)
- Zensu MCP Server running (`make mcp` in `backend/`)
- A feature ID (ZEN-xxx format or UUID) to implement

## Workflow

### Step 1: Load Feature Context

1. Ask the user for the feature ID
2. Use `get_feature` to load the full feature details (title, description, status, priority, component, security classification)
3. Use `analyze_feature_security` to load the security context (classification, data sensitivity, OWASP tags, compliance requirements, score)
4. Present a summary to the user:
   - Feature title and description
   - Current status and priority
   - Security classification and constraints
   - Any security requirements that must be addressed during implementation

### Step 2: Implementation Planning

Based on the feature context and security profile, help the user plan the implementation:
- Identify files to create or modify
- Note security constraints from the classification (e.g., input validation required, audit logging needed)
- Consider the OWASP tags and compliance requirements
- Outline the implementation approach

If the feature's security classification is confidential or restricted, emphasize:
- Input validation on all user inputs
- Proper authentication and authorization checks
- Data encryption requirements
- Audit logging for sensitive operations

### Step 3: Implement the Feature

Help the user write the code. During implementation:
- Follow the security constraints identified in Step 1
- Write tests alongside the implementation
- Reference the feature ID (ZEN-xxx) in commit messages using `[ZEN-xxx]` format
- Keep track of all files created or modified

### Step 4: Link Tests

For each test file written, use `link_test` with:
- `feature_id` (required)
- `test_type` (required): unit | integration | e2e | security | performance | accessibility
- `file_path` (required): Path to the test file
- `function_name` (optional): Specific test function
- `last_run_status` (optional): passed | failed | skipped

### Step 5: Link Source Files

Use `link_source_files` to map implementation files to the feature:
- `feature_id` (required)
- `files` (required): Array of objects with:
  - `file_path` (required): Path to the source file
  - `file_type` (optional): source | test | config | migration | docs | generated | other
  - `language` (optional): Programming language
  - `line_count` (optional): Number of lines

For cross-feature file mapping, use `bulk_link_source_files` with a `mappings` array containing `feature_id`, `file_path`, `file_type`, and `language` per entry.

### Step 6: Link Documentation

For any documentation created, use `link_docs` with:
- `feature_id` (required)
- `doc_type` (required): user_facing | api_reference | tutorial | adr | internal | release_notes | migration_guide
- `title` (optional): Document title
- `file_path` (optional): Path to the doc file
- `external_url` (optional): External URL
- `audience` (optional): end_user | developer | admin | internal
- `publication_status` (optional): draft | published | archived

### Step 7: Create Revision

Use `create_revision` to version the implementation:
- `feature_id` (required)
- `scope_summary` (required): Brief summary of what was implemented
- `scope_details` (optional): Detailed scope description
- `estimated_effort` (optional): S | M | L | XL
- `coverage_target` (optional): Target coverage percentage (0-100)
- `docs_required` (optional): Whether docs are required for this revision
- `created_by` (optional): "mcp" for MCP-initiated revisions

### Step 8: Validate

Use `validate_feature_security` to check if the implementation meets all security requirements for release.

Present the validation results:
- Security score
- Release gate status (pass/fail)
- Any remaining violations to address

### Summary

Present a completion summary:
- Feature title and what was implemented
- Files created/modified (source files linked)
- Tests written and linked (with pass/fail status)
- Documentation linked
- Revision created (version number)
- Security validation status

## Important Notes

- The `update_feature` MCP tool does NOT have a `status` field. Status transitions (planned -> in-progress -> testing -> released) are handled via `PATCH /api/features/{id}/status` (Backend REST endpoint, not an MCP tool).
- Always reference the feature ID in commit messages: `feat(component): description [ZEN-xxx]`
- Security classification should be set BEFORE implementation (use `/zensu:security-review` if not yet set)

## MCP Tools Used

| Tool | Step | Purpose |
|------|------|---------|
| `get_feature` | 1 | Load feature details |
| `analyze_feature_security` | 1 | Load security context |
| `link_test` | 4 | Link test files |
| `link_source_files` | 5 | Map source files to feature |
| `bulk_link_source_files` | 5 | Bulk map across features |
| `link_docs` | 6 | Link documentation |
| `create_revision` | 7 | Create feature revision |
| `validate_feature_security` | 8 | Check release readiness |

## MCP Prompts Used

| Prompt | When | Purpose |
|--------|------|---------|
| `implement_with_security` | Step 2 | Get security constraints for implementation guidance |
