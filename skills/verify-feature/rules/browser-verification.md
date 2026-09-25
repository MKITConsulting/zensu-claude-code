# Browser verification rules

These rules are the self-contained browser loop for `/zensu:verify-feature`. They replace
the source skill's dependency on a personal `/test-feature` command.

## 0. The command set on a `zensu-verify` session

Every call names the session the run-config helper printed, literally:
`playwright-cli -s=<session> <command> [args] [flags]`. Run each call as its own plain Bash
command on the main thread: exactly one `playwright-cli` call per Bash command, with no other
command, operator, pipe, substitution, wrapper or package launcher around it. Quote an argument
that carries `?`, `*`, `[` or `{`, or that starts with `~` or `=`. Single-quote an argument that
carries `$`: double quotes do not help, because the gate reads every `$` outside single quotes
that whitespace or the end of the command does not follow as an expansion it cannot judge, so a
`fill` value such as `"$12"` is denied and `'$12'` is not. The browser consent gate admits
exactly these commands on a `zensu-verify` session, each with only the flags listed:

| Purpose | Commands | Flags |
|---|---|---|
| Session | `open [url]`, `close`, `list` | `open`: `--config=<abs path>` (required), `--headed`, `--device`, `--mobile`, `--idle-timeout`, `--browser` (Chromium channels only); `list`: `--all` |
| Navigation | `goto <url>`, `go-back`, `go-forward`, `reload`, `tab-new [url]`, `tab-list`, `tab-select <n>`, `tab-close [n]` | none |
| Observation | `snapshot [target]`, `find [text]`, `screenshot [target]`, `console [level]`, `requests` | `snapshot`: `--depth`, `--boxes`; `find`: `--regex`; `screenshot`: `--type`, `--full-page`, `--hires`; `console`: `--clear`; `requests`: `--static`, `--filter`, `--clear` |
| Interaction | `click`, `dblclick`, `fill`, `type`, `press`, `keydown`, `keyup`, `hover`, `drag`, `select`, `check`, `uncheck`, `dialog-accept`, `dialog-dismiss`, `resize`, `mousemove`, `mousedown`, `mouseup`, `mousewheel` | `click`/`dblclick`: `--modifiers` (once per call); `fill`/`type`: `--submit` |
| Emulation | `set-color-scheme`, `set-reduced-motion`, `set-forced-colors`, `set-contrast`, `set-media`, and the matching `clear-*` commands | none |

`--json`, `--raw`, `--help` and `--version` are accepted on every command. Everything else is
denied on a `zensu-verify` session, and that denial is final: `eval`, `run-code`, every cookie,
local/session-storage and state command, `delete-data`, `route` and its siblings, `request`,
`request-*` and `response-*`, `network-state-set`, `upload`, `drop`, `pdf`, recording,
tracing and video, `attach`, `detach`, `install`, `install-browser`, `close-all`, `kill-all`,
and the flags `--filename`, `--persistent` and `--profile`. A flag given twice is denied too.
Never re-issue a denied call under another spelling, another session name, or through another
program — with one exception, the shape denial below. A command or flag that is not available,
an origin outside the run config or the navigation policy, a refused or unanswerable consent
prompt, and a call from a subagent are final. A shape denial objects only to how the call is
spelled, and the gate ends its text with the note `(shape denial: re-issue this call once as one
plain playwright-cli call with single-quoted literal arguments; a second denial is final)`; no
other denial carries it. Its reason asks for exactly one plain `playwright-cli` call
(`NOT_PLAIN`), for literal arguments (`ARGUMENT_UNEXPANDED`), for the session exactly as the
run-config helper printed it or named literally (`SESSION_UNRESOLVED`, `SESSION_UNEXPANDED`), or
for the bare name `playwright-cli` (`CLI_NOT_BARE`), or it refuses a wrapper, a package launcher
or an environment assignment (`WRAPPER`, `LAUNCHER`, `ENV_ASSIGNMENT`). Answer a shape denial
once: re-issue the same call as one plain call with single-quoted literal arguments. The gate
judges the retry exactly as it judged the first call, so no boundary loosens, and a second
denial of that call is final.

`screenshot` writes its image beneath the run directory's `browser/` folder and prints its
path; open that file with the Read tool to inspect it. `snapshot` prints the accessibility tree
with element refs such as `e21`; target elements by those refs. Every navigating call prints a
`Page URL` line.

## 1. Establish the observation baseline

0. Before navigating to protected content, validate the checked-in recipe's
   `validate.evidenceSafety` block under `../../autopilot/rules/config.md`: exact route coverage
   must prove synthetic/pre-classified non-sensitive data. Contract v1 supports only
   `declared-safe`; there is no trusted redaction-driver path. Because `open` and `goto` print
   the page title and write a snapshot of the page, enforce this fail-closed boundary before navigation,
   authentication restore, or screenshots. Without a valid covering declaration, do not open
   the protected route and report PARTIAL.
   In POLICY mode the gate admits only the policy's targets, and navigation commands only to
   its declared routes; the policy must bind the same exact page route to the same origin with
   `evidenceMode: declared-safe`. In consent mode (the preflight printed `consent`) the ORIGIN
   half of that boundary holds with the user in the loop instead of the policy: the gate
   admits literal loopback origins only and opens the host's permission prompt once per new
   loopback origin. The ROUTE half does NOT hold — nothing enforces routes in consent mode,
   because the human consented to the whole origin — so binding a page route to its evidence is
   a prose obligation on you here, not a boundary anything checks. Wait for the user's answer;
   a refused prompt makes that origin's rows PARTIAL.
   Never re-issue a refused navigation and never try another spelling of the same target to avoid the prompt.
   The session consent memory named in SKILL.md is yours to READ for the report and never to
   write, edit or delete: a record you place there skips the human's prompt for that origin.
1. Open the run-config session at the resolved base URL and route only after that declaration
   and the policy preflight pass.
2. Read the `Page URL` line of every navigating call. An origin outside the run config means a
   server redirect left the approved set: stop driving that page, collect no evidence from it,
   and report the scenario PARTIAL.
3. Take a `snapshot` before interacting. Confirm the URL, title/heading, authentication state,
   and that the page is not a generic error or login wall.
4. Apply the pre-model evidence boundary below, then run `console` and `requests` to establish
   the baseline only when direct inspection is safe. Mark pre-existing unrelated noise
   separately; do not use it to hide a new feature error.

The accessibility snapshot is the primary source for structure and actionable element refs.
Use screenshot pixels for appearance. Use network/console evidence for runtime behavior.
None of these substitutes for the others.

## 2. Interact in small observable steps

For each scenario:

1. Put the app in the matrix row's declared setup state through real UI or repository-owned
   fixture paths.
2. Take a fresh `snapshot` and select the next action from the current refs.
3. Perform one meaningful interaction: `click`, `fill`, `type`, `select`, `press`, or a dialog
   response.
4. Confirm a specific UI or request condition with a fresh `snapshot` or `find`, not an
   arbitrary delay.
5. Record the changed state, and repeat the `Page URL` check when the action navigated.
6. Repeat until the scenario reaches its assertion checkpoint.

Do not reuse stale snapshot refs after navigation or a material re-render. Never run
`playwright-cli eval` or `run-code`, including for read-only inspection: the gate denies both
on a `zensu-verify` session because page evaluation can read authenticated DOM/storage and
bypass the navigation boundary. If snapshots cannot expose a required value, report that
evidence plane PARTIAL. The gate also denies file upload. Report an upload-dependent scenario
PARTIAL instead of working around the gate.

## 3. Assert three evidence planes

Every acceptance criterion needs the applicable evidence below.

### DOM and data

- Assert visible names, values, rows, validation messages, enabled/disabled state, focus, and
  route changes against the post-action snapshot.
- For mutations, prove the persisted result by reloading or revisiting through the real UI.
- For loading/error/empty paths, prove both the transient/failure state and the recovery when
  the scenario requires it.

### Visual

At every matrix checkpoint, run `screenshot` and **inspect the image file it names** with the
Read tool. Write a concrete observation covering:

- no overlap, clipping, off-screen controls, or broken stacking;
- readable text and correct visual hierarchy;
- expected placement, spacing, and applied styling rather than an unstyled shell;
- the specific open/selected/error/loading state the scenario claims;
- narrow and wide layouts when responsive behavior is relevant (`resize`, `--device`,
  `--mobile`), and the color scheme when theming is touched (`set-color-scheme`).

A screenshot filename without a description is not evidence. DOM-correct but visually
uninspected is PARTIAL.

### Runtime signals

After each scenario, inspect console and network activity scoped to its actions, subject to
this boundary: raw `console` and `requests` output reaches the model before final-report
redaction. Direct inspection is permitted only for a proven unauthenticated, synthetic,
secret-free target. Contract v1 has no trusted model-visible sanitizer for authenticated
runtime signals; skip that plane and report PARTIAL instead of running those commands. Use
`console --clear` and `requests --clear` to scope the next scenario.

- Feature-related uncaught errors, failed resource loads, or unexpected warnings fail the
  scenario unless explicitly expected by the criterion. Record only a bounded, sanitized
  error class/message and source path. Redact tokens, cookies, authorization values, signed
  URLs, query/fragment values, headers, bodies, personal data, and secret-shaped strings;
  never quote raw console output.
- Missing expected calls, request failures, and unexpected 4xx/5xx responses fail the
  scenario. Record method, path without query/fragment, and status only; never include
  headers, bodies, credentials, tokens, or personal data. The gate denies the request-detail
  commands for that reason.
- A deliberately tested error response passes only when both the response and the rendered
  recovery/error UI match the expectation.

## 4. Scenario isolation and safety

- Use unique fixture names containing the run identifier.
- Reset filters, navigation, and record state between rows. When cookies, local storage or
  cached app state would contaminate the next row, `close` the session and `open` it again with
  the same run config, which starts an isolated browser.
- Never restore browser state or accept an auth artifact. Re-authenticate visibly when a fresh
  browser is required; otherwise report the row PARTIAL.
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

Run `playwright-cli -s=<session> close` even after a failed assertion or cancelled login. The
parent skill owns the remaining process, container, and temp-dir cleanup.
