# Browser verification rules

These rules are the self-contained browser loop for `/zensu:verify-feature`. They replace
the source skill's dependency on a personal `/test-feature` command.

## 1. Establish the observation baseline

0. Before navigating to protected content, validate the checked-in recipe's
   `validate.evidenceSafety` block under `../../autopilot/rules/config.md`: exact route coverage
   must prove synthetic/pre-classified non-sensitive data. Contract v1 supports only
   `declared-safe`; there is no trusted redaction-driver path. Because `browser_navigate` can itself
   return a snapshot, enforce this fail-closed boundary before navigation, authentication
   restore, or screenshots. Without a valid covering declaration, do not open the protected
   route and report PARTIAL.
   Also require the plugin's version-1 navigation broker and exact
   parent-environment policy. It aborts every unapproved request or redirect before response
   evidence reaches the model. Never replace it with navigate-then-check logic. The policy must
   bind the same exact page route to the same origin with `evidenceMode: declared-safe`.
   In consent mode (the preflight printed `consent`) the ORIGIN half of that boundary holds with
   the user in the loop instead of the policy: the broker admits literal loopback origins only,
   and the consent hook opens the host's permission prompt once per new loopback origin. The
   ROUTE half does NOT hold — neither layer enforces routes in consent mode, because the human
   consented to the whole origin — so binding a page route to its evidence is a prose obligation
   on you here, not a boundary anything checks. Wait for the user's answer; a refused prompt makes
   that origin's rows PARTIAL.
   Never re-issue a refused navigation and never try another spelling of the same target to avoid the prompt.
   The session consent memory named in SKILL.md is yours to READ for the report and never to
   write, edit or delete: a record you place there skips the human's prompt for that origin.
1. Navigate to the resolved base URL and route only after that declaration and policy preflight pass.
2. Take `browser_snapshot` before interacting. Confirm the URL, title/heading, authentication
   state, and that the page is not a generic error or login wall.
3. Apply the pre-model evidence boundary below, then read `browser_console_messages` and
   `browser_network_requests` to establish the baseline only when direct inspection is safe.
   Mark pre-existing unrelated noise separately; do not use it to hide a new feature error.

The accessibility snapshot is the primary source for structure and actionable element refs.
Use screenshot pixels for appearance. Use network/console evidence for runtime behavior.
None of these substitutes for the others.

## 2. Interact in small observable steps

For each scenario:

1. Put the app in the matrix row's declared setup state through real UI or repository-owned
   fixture paths.
2. Take a fresh snapshot and select the next action from the current refs.
3. Perform one meaningful interaction: click, type, select, key press, or dialog
   response.
4. Wait for a specific UI or request condition, not an arbitrary delay.
5. Snapshot again and record the changed state.
6. Repeat until the scenario reaches its assertion checkpoint.

Do not reuse stale snapshot refs after navigation or a material re-render. Never invoke
`browser_evaluate`, including for read-only inspection: the Zensu MCP broker does not expose
it because page evaluation can read authenticated DOM/storage and bypass the navigation
boundary. If snapshots cannot expose a required value, report that evidence plane PARTIAL.
The broker also deliberately omits file upload. Report an upload-dependent scenario PARTIAL
instead of bypassing the broker.

## 3. Assert three evidence planes

Every acceptance criterion needs the applicable evidence below.

### DOM and data

- Assert visible names, values, rows, validation messages, enabled/disabled state, focus, and
  route changes against the post-action snapshot.
- For mutations, prove the persisted result by reloading or revisiting through the real UI.
- For loading/error/empty paths, prove both the transient/failure state and the recovery when
  the scenario requires it.

### Visual

At every matrix checkpoint, call `browser_take_screenshot` and **inspect the returned image**.
Write a concrete observation covering:

- no overlap, clipping, off-screen controls, or broken stacking;
- readable text and correct visual hierarchy;
- expected placement, spacing, and applied styling rather than an unstyled shell;
- the specific open/selected/error/loading state the scenario claims;
- narrow and wide layouts when responsive behavior is relevant.

A screenshot filename without a description is not evidence. DOM-correct but visually
uninspected is PARTIAL.

### Runtime signals

After each scenario, inspect console and network activity scoped to its actions, subject to
this boundary: raw MCP results reach the model before final-report redaction. Direct inspection
is permitted only for a proven unauthenticated, synthetic, secret-free target. Contract v1 has
no trusted model-visible sanitizer for authenticated runtime signals; skip that plane and report
PARTIAL instead of invoking raw console/network tools.

- Feature-related uncaught errors, failed resource loads, or unexpected warnings fail the
  scenario unless explicitly expected by the criterion. Record only a bounded, sanitized
  error class/message and source path. Redact tokens, cookies, authorization values, signed
  URLs, query/fragment values, headers, bodies, personal data, and secret-shaped strings;
  never quote raw console output.
- Missing expected calls, request failures, and unexpected 4xx/5xx responses fail the
  scenario. Record method, path without query/fragment, and status only; never include
  headers, bodies, credentials, tokens, or personal data.
- A deliberately tested error response passes only when both the response and the rendered
  recovery/error UI match the expectation.

## 4. Scenario isolation and safety

- Use unique fixture names containing the run identifier.
- Reset filters, navigation, and record state between rows. Create a fresh isolated context
  when cookies/local storage or cached app state would contaminate the next row.
- Never enable the broad Playwright storage capability or accept an auth artifact. Re-authenticate
  visibly when a fresh context is required; otherwise report the row PARTIAL.
- Do not screenshot credentials, tokens, personal data, or unrelated sensitive content.
- In remote mode, stop before irreversible or externally visible mutations unless the user
  explicitly approved that exact action.

## 5. Close with contemporaneous evidence

Maintain the report table while driving. For each row, capture:

- expected and observed behavior;
- semantic snapshot fact;
- screenshot and the actual visual observation;
- relevant console/network signals;
- exact reproduction for a failure.

Call `browser_close` even after a failed assertion or cancelled login. The parent skill owns
the remaining process, container, and temp-dir cleanup.
