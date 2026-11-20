# Evidence report

Loaded by `SKILL.md` Phase 2, Phase 3 and Phase 5. Every run that creates its run directory writes
one evidence report, for PASS, FAIL and PARTIAL alike: a bundle outside the repository with a
versioned `manifest.json`, the captures it names and a static `index.html`
(`<absolute-plugin-root>/docs/verify-feature-evidence-report-spec.md`). It shows what the run
observed and adds no evidence of its own, though a refusal at render can lower the stated verdict
(section 4). It needs no Zensu account, no network and no forge CLI, and nothing in this file
sends it anywhere.

Every verb runs bound to this session and its project root, so it takes no `cd` prefix, in chain
mode either. Copy the report id that `--report-begin` prints literally into every later call. Free
text goes on stdin through a quoted heredoc, never as an argument, and never names the browser
CLI: these commands name the run directory, and the browser consent gate refuses a command whose
text names the CLI beside a run directory or a `zensu-verify-` session. Replace `<hex>` in the
heredoc delimiter with eight random hex digits, new for each call and the same on both lines, so no
line of the text can end the heredoc early. Every line you write for the report is English,
whatever language this conversation is in; only `feature:` keeps the request as given.

## 1. Begin, right after the run directory exists (Phase 2)

Begin before any runtime, fixture or authentication step, so a run that stops during setup still
writes its report. A run that stops before its run directory exists writes none, and so does
`--setup`, which stops once the recipe is written. While a report is begun, run every row in the
run's one lane, never in parallel lanes: a report takes only the files of its own run directory,
and each parallel lane has a run directory of its own (`SKILL.md` Phase 3).

```bash
CLAUDE_PLUGIN_DATA="<absolute-plugin-data>" bash "<absolute-plugin-root>/hooks/lib/zensu-log.sh" --report-begin --run-dir "<run dir>" --mode local --drivers browser,api --recipe .zensu/runtime.yaml <<'REPORT_<hex>'
feature: The request as given, in one or two sentences.
AC-001: The first criterion as Phase 0 stated it.
REPORT_<hex>
```

- `--run-dir` is the run directory's physical path. `--drivers` lists the driver of every matrix
  row from Phase 0 step 6, comma-separated. `--recipe` names the candidate Phase 2 step 1 inspects
  first, the explicit `--config` path, else `.zensu/runtime.yaml`, else `.zensu/autopilot.yaml`,
  as a path relative to the project root; leave it out when none exists or the file lies outside
  the project. When step 1 rejects that candidate, or guided setup writes another recipe, say so in
  a `limitation:` line at render. A remote run passes `--mode remote` and
  `--origin <scheme>://<host>[:<port>]`, the validated origin; an attach run adds `--attach`.
- `feature:` is the request as given, at most 2,000 characters. In matrix mode every criterion
  Phase 0 step 4 stated gets one `AC-###:` line of at most 400 characters, in the order Phase 0
  stated them: a supplied id stays when it reads `AC-` and digits with at most one lowercase
  letter after them, such as `AC-007` or `AC-007b`, and every other criterion, an `FR-###` one
  included, gets the next free `AC-###` id and keeps its own label at the start of its text, so
  the report lists every criterion. The begin line names the criteria it took: compare them with
  the ones Phase 0 stated.
- Chain mode passes `--log <run log>` and no `AC-###:` line: the report reads its criteria from
  the chain's plan.

It prints `zensu evidence report: begun vr1_… | …` and the bundle's path.

- **Exit 0**: begun. A further line saying that `--report-render` will refuse a PASS means the
  working tree could not be fingerprinted; go on, and section 4 answers that refusal.
- **Exit 3**: reports are switched off (`evidence.report.enabled` is false). Run no other report
  verb, and the report to the user carries no location line.
- **A refusal that names a text cap, the secret screen or a stdin line**: begin wrote nothing.
  Shorten or rewrite that field and run the same call once more; when it refuses again, or for
  any other cause, the next outcome applies.
- **Exit 1 or 2**: a refusal or a fault. The run goes on without a report and its verdict does
  not change: name the printed cause and its remedy under Limitations, and write
  `Evidence report: none — <cause>` as the location line. Never edit `.gitignore`,
  `.git/info/exclude` or any other file to satisfy a remedy; applying it is the user's step.

## 2. Add each capture right after you inspected it (Phase 3)

Add a capture right after you opened and inspected it, never in a batch at the end, the way chain
mode records each criterion right after it is observed. Only a file the run wrote beneath its run
directory enters, named by its physical path: a PNG or lossless WebP image, or UTF-8 plain text of
at most 64 KiB without control characters that does not open with `<`. A screenshot that a host
tool returns only to the conversation cannot enter, so a row that relies on one also takes the
file capture its driver names (`rules/browser-verification.md` section 5, `rules/drivers.md`
section 8). What the run keeps out of the conversation stays out of the report too: credentials,
tokens, cookies, personal data, raw console or log lines, the run's signed-in state, and the
console and network output of an authenticated target. The plugin screens text, never pixels, so
add an image only after you inspected it for any of these.

```bash
CLAUDE_PLUGIN_DATA="<absolute-plugin-data>" bash "<absolute-plugin-root>/hooks/lib/zensu-log.sh" --report-add --report <id> --kind image --file "<run dir>/browser/<file>" --viewport 1440x900@1 <<'REPORT_<hex>'
What the image shows: the screen, its state and the detail the row asserts.
REPORT_<hex>
```

```bash
CLAUDE_PLUGIN_DATA="<absolute-plugin-data>" bash "<absolute-plugin-root>/hooks/lib/zensu-log.sh" --report-add --report <id> --kind request --method PUT --path '/api/settings' --status 200
```

- `--kind image` and `--kind text` take `--file` and, on stdin, a caption that says in English what
  the capture shows. In the image block `<file>` is the name of the file the screenshot command
  printed, its `.png` included. `--viewport <width>x<height>@<scale>` records the viewport an image
  was taken at; leave it out where the driver cannot tell. `--plane` defaults to `visual` for an
  image and `state` for text; pass `--plane visual` for a terminal screen captured as text. A log
  never enters as a text file: its signal enters as `--kind signal --source log`. A text capture
  whose first line is a local path is refused, so give it a first line that says what it holds.
- `--kind request` takes `--method`, `--path` without query or fragment, and `--status`; no stdin.
  Single-quote the path, because a request path can hold `$`, `(`, `;` or `&`. A path that holds a
  single quote is not added: the row's `observed:` line names that request instead.
- `--kind signal` takes `--source console`, `network`, `runtime` or `log`, `--class` such as
  `error` or `warning`, and on stdin a bounded, sanitized message, never a raw line.
- `--kind run` takes `--evidence-run er1_…`, the record of a check that
  `--evidence-run --scope acceptance` observed in chain mode; no stdin.

It prints `zensu evidence report: e<N> added to <id> | …`: keep the `e<N>` id for the row. A
refusal that names the secret screen, a local path, a text cap or a file that does not exist
writes nothing: correct the caption or the file path and run the same call once more. Any other
refusal, or a second one: name it under Limitations and go on.

## 3. Write each matrix row when it is finished (Phase 3)

```bash
CLAUDE_PLUGIN_DATA="<absolute-plugin-data>" bash "<absolute-plugin-root>/hooks/lib/zensu-log.sh" --report-step --report <id> --priority P0 --driver browser --result pass --criteria AC-001 --evidence e1,e2 <<'REPORT_<hex>'
title: AC-001 — the Scenario cell of the row
expected: What the row expects, in one sentence.
observed: What the row observed, in one sentence.
REPORT_<hex>
```

- Write one row per matrix row, the undriven ones too, as `--result skip` with `observed:` naming
  why, so the report's counts equal the Coverage line. `--result` is the Result cell: `pass`,
  `fail` or `skip`.
- `--criteria` lists the `AC-###` ids the row proves, only ids `--report-begin` listed or the
  chain's plan holds. `--evidence` lists the row's `e<N>` ids. A `browser`, `mobile` or `desktop`
  row that passes names at least one image, because render refuses a criterion that passed
  through such a driver without one.
- `--authenticated` on a row that ran signed in, through a recipe login or a visible manual
  login, marks the report's run as authenticated.
- `title:` is the Scenario cell, the criterion id first in chain mode, at most 200 characters.
  `expected:` and `observed:` say in English, one or two sentences each and at most 2,000
  characters, what the row expected and what the snapshot, output or request showed, with no
  credential, personal data or raw console line.
- In chain mode a criterion this run skips because it already passes on this tree through
  `browser`, `mobile` or `desktop` still takes one row beside the matrix rows: open the screen its
  record names, take and inspect one screenshot, add it, and write a `pass` row that names the
  criterion and links that image. Record nothing for it, because its acceptance record stands.
  Without that row render refuses the criterion as `criterion.no-image`, and the run ends without
  a report.

## 4. Render before the report to the user (Phase 5)

Render once, after Phase 4 and before you write the report to the user. Rendering needs no run
directory: every capture was copied into the report's store when it was added.

```bash
CLAUDE_PLUGIN_DATA="<absolute-plugin-data>" bash "<absolute-plugin-root>/hooks/lib/zensu-log.sh" --report-render --report <id> --verdict PASS --console clean --network clean <<'REPORT_<hex>'
limitation: One line per entry under Limitations.
resource: One line per teardown line of the run-resource helper.
consent: http://127.0.0.1:5173 /settings asked
REPORT_<hex>
```

- `--verdict` is the verdict the Phase 5 rules give this run, and the report to the user states
  the same one.
- `--console` and `--network` are `clean`, `issues` or `not-checked`, as the Console and Network
  lines say: `not-checked` where that plane was not inspected.
- stdin holds one `limitation:` line per Limitations entry, one `resource:` line per teardown line,
  each of them at most 500 characters, and one
  `consent: <origin> <route> <asked|remembered|policy-mode>` line per Consent record.
- Chain mode passes `--log <run log>`: each criterion's state is read from the acceptance records
  at render time, so render after the last `--acceptance-record` and `--acceptance-status`.

It prints `Evidence report: <path>/index.html`. Copy that line as printed onto the line right above
the final verdict line.

A refusal prints one `REPORT REFUSED — <code> … | remedy: …` line per fault and writes nothing:

- `verdict.contradiction`, `verdict.empty` or `verdict.tree-changed`: the stated verdict does not
  follow from the rows recorded during the run. When the fault names a criterion or a P0 row that
  the run did verify, the row that proves it is missing or names another id: write that row with
  `--report-step` and render again with the verdict the Phase 5 rules give. Otherwise render
  again with the verdict that opens the remedy (`state FAIL` or `state PARTIAL`), state that
  verdict in the report to the user too, and name the cause under Limitations.
- `criterion.no-image`: a criterion passed through a UI driver, and no row that names it links an
  image. When the report holds an image you inspected that shows it, write one more row for that
  criterion that names the image. Otherwise, in matrix mode, write a `skip` row for it whose
  `observed:` says no image was captured, which leaves it partial, and render PARTIAL, the verdict
  the report to the user states too. In chain mode, where a row does not change a criterion's
  state, name the code under Limitations and write `Evidence report: none — criterion.no-image`
  as the location line.
- Any other refusal: name each code under Limitations and write `Evidence report: none — <code>`
  as the location line. The verdict stays as the Phase 5 rules give it.

A refusal without a `REPORT REFUSED` line writes nothing either. When it names a text cap, the
secret screen or a malformed stdin line, rewrite that line and render once more. When it refuses
again, or names any other cause, name the cause under Limitations and write
`Evidence report: none — <cause>` as the location line; the verdict stays as the Phase 5 rules give
it.

## 5. The report to the user

Use this format:

**Verdict: PASS | FAIL | PARTIAL**

| Scenario | Driver | Pri | Expected | Observed | Evidence | Result |
|---|---|---|---|---|---|---|
| ... | ... | P0 | ... | ... | screenshot / snapshot / request | ✅ / ❌ / ⏭ |

- **Target:** mode, base URL, worktree/branch/SHA or deployed identity.
- **Coverage:** `N/N P0`, `N/N P1`, `N/N P2`; name every undriven row.
- **Console:** sanitized error class and bounded message, or `clean`. Redact credentials,
  tokens, cookies, authorization data, signed/query URLs, personal data, headers, and bodies;
  never copy raw console output into the report.
- **Network:** failed, missing, 4xx, or 5xx requests with method/path/status, or `clean`.
  Strip query strings/fragments and never report headers, bodies, credentials, or personal
  data.
- **Visual:** what each screenshot actually showed about layout, clipping, overlap,
  responsiveness, styling, and legibility. “Screenshot taken” is not an observation.
- **Reproduction:** exact steps and captured signal for each failure.
- **Consent:** one line per `(origin, route, decidedBy)` record the session's consent memory
  holds after the run, where `decidedBy` is `asked` (the host raised a consent prompt for this
  origin — the recorder cannot observe how the human answered, only that the navigation then
  executed), `remembered` (any route on an origin already present in the memory — the route is
  never tested), or `policy-mode` (a parent-environment policy the gate accepts authorized
  it). In consent mode also name every prompt the user refused.
- **Limitations:** environment, fixture, auth, or deployment-identity gaps.
- **Other drivers:** the lines `rules/drivers.md` section 8 adds.

The location line, `Evidence report: <path>/index.html` as section 4 printed it or
`Evidence report: none — <cause>`, stands right above the final verdict line, which follows the
`SKILL.md` Phase 5 rules. A run whose reports are switched off has no location line.

## 6. Earlier reports

Only when the user asks: `--report-list [--limit <n>]` lists this repository's reports, newest
first, with their state, verdict and location, and `--report-export --report <id>` writes one
shareable `export.html` into a rendered report, every image inlined. Neither reads stdin.
