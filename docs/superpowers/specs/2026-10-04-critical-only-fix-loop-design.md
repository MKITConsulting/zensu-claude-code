# Critical-Only Fix Loop — Design

Status: approved in chat on 2026-10-04.
Target repository: `zensu-claude-code` (base `main` at `039f16e8`, after #362 and #372, which shipped in 0.24.0 on 2026-10-04).
Follows: `docs/superpowers/specs/2026-09-28-review-cost-levers-design.md` (D1 to D5); the decisions below continue its numbering.

## 1. Problem

Since #372 the `/zensu:tdd` auto-fix loop routes every CRITICAL and IMPORTANT finding of a first review into a fix round,
and every fix round is followed by a verification review. By the rubric in `docs/review-severity.md`, an IMPORTANT
finding should land before the merge but does not block it: a robustness gap, a missing test for changed behavior, or a
maintainability defect the change introduces. Routing it through the loop buys a full fix-and-review cycle for a defect
that one later fix pass can handle, and the re-review of that fix can raise findings of its own.

The maintainer decided on 2026-10-04 that the loop exists for blockers only, that IMPORTANT findings are fixed once at
the end of the chain, and that the loop allows two fix rounds. The same decision dropped the measurement gate of the
earlier plan (Task C2), so this change ships without a benchmark run.

## 2. Goals and non-goals

Goals:

- By default only CRITICAL findings open a fix round.
- IMPORTANT findings are fixed once, in the fix round of `/zensu:self-review`, through the existing `parked` ledger state.
- The routing before this change stays one setting away.
- At most two fix rounds by default.

Non-goals:

- No change to the severity rubric, the review panel, the judge, the Finding Verification Gate or its reproduction
  stage (D2).
- No change to `/zensu:self-review`: a `parked` entry the code still supports is already a must-fix there.
- No measurement gate.

## 3. Decisions

### D6 — A severity threshold for the fix loop

- New key `hooks.autoFixSeverity` with three values:
  - `critical` (default): only CRITICAL findings route.
  - `important`: CRITICAL and IMPORTANT findings route, which is the routing before this change.
  - `all`: every severity routes, which is what `autoFixIncludeSuggestions: true` does today.
- Resolution: a recognised `autoFixSeverity` value wins. Otherwise `autoFixIncludeSuggestions: true` reads as `all`,
  and otherwise the value is `critical`. An unrecognised value therefore falls through to the legacy key and then to the
  default, so a project overlay that sets `autoFixIncludeSuggestions: true` keeps routing every severity.
- `autoFixIncludeSuggestions` stays supported as the legacy spelling of `all`, and `docs/configuration.md` says so.
- A new accessor `zensu_autofix_severity` in `hooks/lib/zensu-config.sh` prints the resolved value and replaces the
  `zensu_autofix_include_suggestions` call in `hooks/post-review-tdd-delegate.sh`. Without `node` it prints `critical`.

### D7 — IMPORTANT findings go to the self-review

In `critical` mode, while `hooks.selfReview` and `hooks.reviewConvergence` are both enabled:

- Every review, the first one included, retitles each IMPORTANT finding `[Deferred — do not fix]`, keeps its original
  severity in its text, sets it to SUGGESTION, and appends a `parked` ledger line for it with the severity IMPORTANT.
  Today only the fix case of the delegate directive tells a first review to write ledger lines; in `critical` mode the
  case without a fix round writes them as well.
- A review without a CRITICAL finding opens no fix round. It parks its IMPORTANT findings, lists its suggestions as
  today, and closes the loop, so the chain hands off to `/zensu:self-review`. Its status line names the parked findings.
- A review with a CRITICAL finding fixes only the CRITICAL findings and parks the IMPORTANT ones.
- `/zensu:self-review` fixes every parked entry the code still supports in its one fix round, as it already does for the
  entries a re-review parks (`skills/self-review/SKILL.md`, ledger paragraph).
- A re-review keeps D2: a CRITICAL finding routes only when stage 3 reproduced it. The exceptions that keep an IMPORTANT
  finding routable on a re-review (raised by the judge, tagged `[NOT FIXED]`, or citing code the fix pass edited) apply
  only in `important` mode.

Fallback: when `hooks.selfReview` or `hooks.reviewConvergence` is off, no later stage can pick a parked finding up, so
`critical` routes like `important`. A re-review whose ledger helpers do not both answer `status=ok` already routes "as
before" and logs `CONVERGENCE UNAVAILABLE`; in `critical` mode that review routes like `important` as well.
`docs/configuration.md` states the fallback.

### D8 — Two fix rounds by default (amends D1)

- `hooks.autoFixMaxRounds` defaults to `2`, and the range stays `1..99`. `1` restores the default of #372, and `5`
  restores the loop before it.
- With `critical` routing, the second round opens only when the verification review finds a CRITICAL finding that
  stage 3 reproduced. Before `hooks.reviewConvergence` existed, 5 % of the review rounds after the first carried a
  CRITICAL finding (`docs/configuration.md`, `reviewConvergence` row).
- The Stop chain guard releases after `autoFixMaxRounds + 3` nudges, so the default cap rises from 4 to 5, and
  `docs/configuration.md` states the new number.

## 4. Delivery

- One pull request from `main` on the branch `feat/critical-only-fix-loop`.
- Version: minor, like #372, because changed defaults change behavior. #362 and #372 shipped in 0.24.0 while this
  change was in progress, so it ships in the release after it.
- Texts that state which severities route and change with this design: `hooks/post-review-tdd-delegate.sh` (its
  directive arms and its header), `hooks/lib/zensu-config.sh`, `config.example.json`, `docs/configuration.md`,
  `docs/review-severity.md`, `docs/architecture.md` and `skills/tdd/SKILL.md`.

## 5. Risks

- IMPORTANT fixes land in the single fix round of the self-review, and no review round re-reads them. The self-review
  reads each cited region before it fixes, `## Open` keeps what stays unfixed, and `autoFixSeverity: important` restores
  the loop.
- The fix round of the self-review grows, because every IMPORTANT finding of the chain arrives there at once. An entry
  it cannot fix in that round stays in `## Open` under the named blocker "the one fix round already spent".
- Configurations with `hooks.selfReview` or `hooks.reviewConvergence` off keep routing IMPORTANT findings through the
  fallback, so the change does not reach them.
- The second default round lifts the Stop guard cap from 4 to 5 nudges.

## 6. Testing

- Accessor: `zensu_autofix_severity` prints `critical` without a config, the value of a recognised `autoFixSeverity`,
  `all` for `autoFixIncludeSuggestions: true` without `autoFixSeverity`, the explicit value when both keys are set, the
  legacy or default value for an unrecognised `autoFixSeverity`, and `critical` without `node`.
- Delegate directives, rendered like `evals/config-gate/test-review-convergence-directive.sh` renders them: `critical`
  fixes only CRITICAL findings, parks IMPORTANT findings in both the fix and the no-fix case, and renders the new status
  lines; `important` renders the default directive before this change; `all` renders the suggestions directive before
  this change; with `selfReview` off, with `reviewConvergence` off, and on `CONVERGENCE UNAVAILABLE`, `critical` routes
  IMPORTANT findings.
- Defaults: `autoFixMaxRounds` is `2` and `autoFixSeverity` is `critical` in `hooks/lib/zensu-config.sh`,
  `config.example.json` and `docs/configuration.md`.
- Suites that drive several reviews through one session or assert IMPORTANT routing pin `autoFixSeverity: important` or
  `autoFixMaxRounds` explicitly, as #372 did for the round count.
- The full suite runs in CI on the pull request.
