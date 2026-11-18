# /zensu:change command table

One row per change this skill runs. The **Tool** column is the canonical name the CLI write-gate maps the command to, and the window of `/zensu:change` declares every one of them. The **Convention** column says what Step 3 or Step 4 of the skill applies before the command:

- `duplicate check: <read>` — run that read and compare titles and slugs first (Step 3).
- `confirm: <consequence>` — ask with AskUserQuestion, naming the entity and this consequence (Step 4).
- anything else — a note for that command, applied in Step 6.

A merge and a split create features and replace tracked data, so their rows carry both: the duplicate check first, then `; confirm:` and the consequence.

Placeholders in angle brackets are values you resolve in Step 2. `"$(cat "$f")"` is the free-text file form of Step 6. Run `zensu <group> <command> --help` when a flag is unclear.

## Features

| Change | Command | Tool | Convention |
|---|---|---|---|
| Track a new feature | `zensu features create --product <product-id> --component <component-id> --title "<title>" --status planned` | `create_feature` | duplicate check: `zensu features list --product <product-id> --json`; then the follow-ups of Step 6 (priority, description, classification) |
| Change a title, priority or description | `zensu features update <feature-id> --title "<title>" --priority <priority> --description "$(cat "$f")"`, each flag only when it changes | `update_feature` | the CLI sends only the flags you pass |
| Move a feature to another status | `zensu features status <feature-id> <new-status>` | `update_feature` | a move to `released` goes through `/zensu:pilot`, which checks the release gates first |
| Record a new revision (build-out stage) | `zensu features revision <feature-id> --scope-summary "$(cat "$f")"` | `create_revision` | duplicate check: `zensu features history <feature-id> --json`, compared by scope summary |
| Deprecate a feature | `zensu features deprecate <feature-id> --reason "$(cat "$f")"`, with `--replacement <feature-id>` and `--removal-planned-at <rfc3339>` when the user names them | `deprecate_feature` | confirm: the feature is marked deprecated; it stays tracked, and a replacement, when given, is linked to it |
| Merge features | `zensu features merge <feature-id> --source "$(cat "$f")" --title "<title>" --slug <slug>`; the file holds the JSON array of source feature UUIDs | `merge_features` | duplicate check: `zensu features list --product <product-id> --json`, compared with the merged feature's `--title` and `--slug`; confirm: every source feature is marked merged into the new feature that `--title` and `--slug` name |
| Split a feature | `zensu features split <feature-id> --children "$(cat "$f")"`; the file holds the JSON array of children, each with `title` and `slug` | `split_feature` | duplicate check: `zensu features list --product <product-id> --json`, compared with each child's `title` and `slug`; confirm: the original feature is marked split, and one new feature is created per child |

## Subfeatures

| Change | Command | Tool | Convention |
|---|---|---|---|
| Add a subfeature | `zensu subfeatures add <feature-id> --title "<title>" --priority <priority> --description "$(cat "$f")"` | `add_subfeature` | duplicate check: `zensu subfeatures list <feature-id> --json` |
| Promote a subfeature to a feature | `zensu subfeatures promote <feature-id> <subfeature-id>` | `promote_subfeature` | confirm: the link to the parent feature is removed, and the subfeature becomes a top-level feature |

## Roadmaps and milestones

| Change | Command | Tool | Convention |
|---|---|---|---|
| Create a roadmap | `zensu roadmap create --product <product-id> --title "<title>" --period <period> --description "$(cat "$f")"` | `create_roadmap` | duplicate check: `zensu roadmap list --product <product-id> --json`; one roadmap spans many periods, so an existing roadmap usually takes the feature instead |
| Change a roadmap | `zensu roadmap update <roadmap-id> --title "<title>"`, plus the flags that change | `update_roadmap` | `--title` is required: pass the current title from `zensu roadmap get <roadmap-id>` when it does not change |
| Delete a roadmap | `zensu roadmap delete <roadmap-id>` | `delete_roadmap` | confirm: the roadmap and every feature's membership in it are deleted; the features themselves stay |
| Put a feature on a roadmap | `zensu roadmap add-feature <roadmap-id> --feature <feature-id> --start-period <period> --end-period <period>` | `add_feature_to_roadmap` | adding it again only updates its periods and sort order |
| Take a feature off a roadmap | `zensu roadmap remove-feature <roadmap-id> <feature-id>` | `remove_feature_from_roadmap` | the feature itself stays |
| Add a milestone | `zensu roadmap milestone-create <roadmap-id> --title "<title>" --period <period>` | `create_milestone` | duplicate check: `zensu roadmap milestone-list <roadmap-id> --json` |
| Delete a milestone | `zensu roadmap milestone-delete <roadmap-id> <milestone-id>` | `delete_milestone` | confirm: the milestone marker is deleted from the roadmap |

## Tiers

| Change | Command | Tool | Convention |
|---|---|---|---|
| Create a pricing tier | `zensu tiers create --product <product-id> --name "<name>" --slug <slug> --tier-order <order>` | `create_tier` | duplicate check: `zensu tiers list --product <product-id> --json`, compared by name and slug |
| Set the tiers of a feature | `zensu tiers set-feature <feature-id> --tiers "$(cat "$f")"`; the file holds the JSON array of tier entries | `set_feature_tiers` | confirm: when the new list drops a tier the feature has today or changes the gating type or limits of one it keeps, because the command replaces every tier assignment of the feature; read `zensu tiers matrix --product <product-id>` first and copy every kept entry unchanged |

## Security

| Change | Command | Tool | Convention |
|---|---|---|---|
| Classify a feature | `zensu security classify <feature-id> --classification <level>`, plus the attributes the evidence supports | `set_security_classification` | read `zensu security analyze <feature-id>` first: a feature that already has a classification goes to `/zensu:security-review`, which reviews the change; otherwise the evidence rule of Step 6 applies |
| Link a security test | `zensu security add-test <feature-id> --type <type> --file <path>` | `add_security_test` | the test file must exist in the repository |

## Journeys

| Change | Command | Tool | Convention |
|---|---|---|---|
| Create a user journey | `zensu journeys create --product <product-id> --title "<title>" --type <type> --description "$(cat "$f")"` | `create_user_journey` | duplicate check: `zensu journeys list --product <product-id> --json` |
| Add a journey step | `zensu journeys step <journey-id> --product <product-id> --title "<title>" --step-order <order> --feature <feature-id>` | `create_journey_step` | duplicate check: `zensu journeys steps <journey-id> --product <product-id> --json` |
| Change a journey step | `zensu journeys step-update <journey-id> <step-id> --product <product-id>`, plus the flags that change | `update_journey_step` | the CLI reads the step and writes it back whole, so pass only the fields that change |
| Delete a journey step | `zensu journeys step-delete <journey-id> <step-id> --product <product-id>` | `delete_journey_step` | confirm: the step is deleted, and the remaining steps keep their order numbers, so a gap stays until they are reordered |

## Mocks

| Change | Command | Tool | Convention |
|---|---|---|---|
| Upload a design mock | `zensu mocks create <feature-id> <file> --title "<title>"` | `create_mock` | duplicate check: `zensu mocks list <feature-id> --json`, compared by title and file name |

## Links

| Change | Command | Tool | Convention |
|---|---|---|---|
| Link a test file | `zensu link test <feature-id> --file <path> --test-type <type>` | `link_test` | the file must exist in the repository |
| Link a document | `zensu link docs <feature-id> --doc-type <type> --file <path>` | `link_docs` | writing the document itself is `/zensu:docs` |
| Map source files | `zensu link source <feature-id> --file <path>`, one `--file` per file | `link_source_files` | each file must exist in the repository |

## Ghost candidates

| Change | Command | Tool | Convention |
|---|---|---|---|
| Approve one candidate | `zensu ghost approve <scan-id> <candidate-id> --product <product-id>` | `ghost_approve_candidate` | read `zensu ghost candidates <scan-id> --product <product-id>` first; turning approved candidates into features stays with `/zensu:ghost-scan` |
| Reject one candidate | `zensu ghost reject <scan-id> <candidate-id> --product <product-id> --reason "$(cat "$f")"` | `ghost_reject_candidate` | read the candidate first, the same way |

## Wiki

| Change | Command | Tool | Convention |
|---|---|---|---|
| Create a wiki page | `zensu wiki create --product <product-id> --title "<title>" --content "$(cat "$f")"` | `create_wiki_page` | duplicate check: `zensu wiki list --product <product-id> --json`, compared by title and path; a page the CLI reports at the new path is a match too: ask as Step 3 says, and change that page only on that explicit answer |
| Change a wiki page | `zensu wiki update <page-id> --content "$(cat "$f")" --change-summary "<summary>"` | `update_wiki_page` | the CLI changes only the fields you pass |
| Upload a wiki image | `zensu wiki images upload --product <product-id> --file <path>` | `upload_wiki_image` | read `zensu wiki images policy --product <product-id>` for the limits first; an upload never publishes, so put the returned `wiki-asset:<uuid>` reference into a page and save the page |

## Products

| Change | Command | Tool | Convention |
|---|---|---|---|
| Import a repository into a product | `zensu products import <product-id> --repo-url <url> --repo-type <type>` | `import_repo` | the user names the repository URL |
