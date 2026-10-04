# Critical-Only Fix Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** By default the `/zensu:tdd` auto-fix loop fixes only CRITICAL findings, parks IMPORTANT findings for `/zensu:self-review`, and allows two fix rounds.

**Architecture:** A new config accessor `zensu_autofix_severity` resolves `hooks.autoFixSeverity` (`critical` | `important` | `all`, legacy `autoFixIncludeSuggestions: true` = `all`). `hooks/post-review-tdd-delegate.sh` gains a third, hand-parallel directive arm for `critical`; the two existing arms render byte-for-byte as before under `important` and `all`. `critical` falls back to `important` when `hooks.selfReview` or `hooks.reviewConvergence` is off. `zensu_autofix_max_rounds` defaults to `2`.

**Tech Stack:** bash 3.2-compatible shell, inline node one-liners, the repository's shell test harnesses.

**Spec:** `docs/superpowers/specs/2026-10-04-critical-only-fix-loop-design.md`

## Global Constraints

- English only in code, docs, tests, commit messages and the PR (`.claude/rules/language.md`).
- No new comments. Existing comment lines may be reworded where they would become false.
- Conventional commits, no AI attribution.
- `skills/tdd/SKILL.md` stays at most 433 lines (`R24` in `tests/structure/test-review-convergence.sh`).
- macOS `/bin/bash` 3.2: every `case` pattern inside `$( … )` uses the leading paren form.
- Never edit `hooks/`, `agents/`, `skills/`, `docs/`, `templates/` or `scripts/` while a suite runs.
- Local runs only for the suites this change touches; the full suite runs in CI on the pull request.
- Worktree: `.worktrees/zensu-claude-code/feat/critical-only-fix-loop`, branch `feat/critical-only-fix-loop`, base `main` at `039f16e8`.

---

### Task 1: Severity accessor and the two-round default

**Files:**
- Modify: `hooks/lib/zensu-config.sh:491-496` (replace `zensu_autofix_include_suggestions`), `hooks/lib/zensu-config.sh:569` (default)
- Modify: `config.example.json:9-10`
- Modify: `docs/configuration.md:58` (the `autoFixMaxRounds` row)
- Test: `evals/config-gate/test-helper-autofix-flags.sh`, `evals/config-gate/test-config-merge.sh`, `tests/structure/test-review-convergence.sh` (LC1, LC1b, LC1c, new LC4 to LC4c)

**Interfaces:**
- Produces: `zensu_autofix_severity` prints exactly one of `critical`, `important`, `all` and returns 0. `zensu_autofix_max_rounds` prints `2` without a valid config value. `zensu_autofix_include_suggestions` no longer exists.

- [ ] **Step 1: Rewrite the accessor checks in `evals/config-gate/test-helper-autofix-flags.sh`.** Replace the section from `# --- zensu_autofix_include_suggestions ---` up to, not including, `# --- zensu_autofix_max_rounds ---` with:

```bash
# --- zensu_autofix_severity ---

export ZENSU_CONFIG="$TMP_CFG"
severity_case() {
  local label="$1" json="$2" want="$3" val
  printf '%s\n' "$json" > "$TMP_CFG"
  val=$(zensu_autofix_severity)
  if [ "$val" = "$want" ]; then check "severity: $label echoes $want" PASS
  else check "severity: $label echoes $want (got '$val')" FAIL; fi
}
severity_case "absent key" '{"hooks": {"autoFix": true}}' critical
severity_case "explicit critical" '{"hooks": {"autoFixSeverity": "critical"}}' critical
severity_case "explicit important" '{"hooks": {"autoFixSeverity": "important"}}' important
severity_case "explicit all" '{"hooks": {"autoFixSeverity": "all"}}' all
severity_case "legacy autoFixIncludeSuggestions true" '{"hooks": {"autoFixIncludeSuggestions": true}}' all
severity_case "legacy autoFixIncludeSuggestions false" '{"hooks": {"autoFixIncludeSuggestions": false}}' critical
severity_case "legacy string 'true' (strict ===)" '{"hooks": {"autoFixIncludeSuggestions": "true"}}' critical
severity_case "explicit critical beats legacy true" '{"hooks": {"autoFixSeverity": "critical", "autoFixIncludeSuggestions": true}}' critical
severity_case "unknown value falls back to legacy true" '{"hooks": {"autoFixSeverity": "blocker", "autoFixIncludeSuggestions": true}}' all
severity_case "unknown value alone" '{"hooks": {"autoFixSeverity": "blocker"}}' critical
severity_case "malformed JSON" '{this is not json' critical

MISSING_CFG="/tmp/zensu-autofix-flags-missing-$$.json"
rm -f "$MISSING_CFG"
export ZENSU_CONFIG="$MISSING_CFG"
val=$(zensu_autofix_severity)
if [ "$val" = "critical" ]; then check "severity: missing config echoes critical" PASS
else check "severity: missing config echoes critical (got '$val')" FAIL; fi
export ZENSU_CONFIG="$TMP_CFG"
```

- [ ] **Step 2: Move the max-rounds default checks to 2.** In the same file, in the `zensu_autofix_max_rounds` section, change every `[ "$val" = "1" ]` and its two labels to `2` for: absent flag (`absent flag echoes default 1`), `0 out of range`, `100 out of range`, `non-int 'five'`, `non-integer 1.5`, `malformed JSON`, `missing config`. Keep `explicit 1 (lower bound) echoes 1` unchanged. Inside the hidden-node block, after the `combined_summary` check and before `export PATH="$ORIG_PATH"`, add:

```bash
if [ "$(zensu_autofix_severity)" = "critical" ]; then
  check "severity: node missing on PATH echoes critical" PASS
else
  check "severity: node missing on PATH echoes critical" FAIL
fi
```

- [ ] **Step 3: Rewrite the merge probes in `evals/config-gate/test-config-merge.sh`.** Replace each of the four `if zensu_autofix_include_suggestions; then` lines with `if [ "$(zensu_autofix_severity)" = "all" ]; then`. In block (e) change `= "1"` to `= "2"` and both labels `default 1` to `default 2`, and rename the two labels `(e) no config -> autofix suggestions disabled (default)` to `(e) no config -> autofix severity is not all (default critical)`.

- [ ] **Step 4: Pin the defaults in `tests/structure/test-review-convergence.sh`.** Replace LC1, LC1b and LC1c with:

```bash
check "LC1 the default auto-fix budget is two fix rounds" "$(grep_ok "$ROOT/hooks/lib/zensu-config.sh" '_zensu_config_bounded_int autoFixMaxRounds 2 1 99')"
check "LC1b configuration.md documents the default of two fix rounds" "$(grep_ok "$CONFIG_DOC" 'Integer loop guard (default `2`')"
check "LC1c config.example.json ships two fix rounds" "$(node -e 'process.stdout.write(require(process.argv[1]).hooks.autoFixMaxRounds===2?"PASS":"FAIL")' "$CONFIG_EX")"
check "LC4 the severity getter defaults to critical" "$(bash -c 'source "$1/hooks/lib/zensu-config.sh"; ZENSU_CONFIG=/nonexistent zensu_autofix_severity' _ "$ROOT" | grep -qx critical && echo PASS || echo FAIL)"
check "LC4b config.example.json ships the critical threshold" "$(node -e 'process.stdout.write(require(process.argv[1]).hooks.autoFixSeverity==="critical"?"PASS":"FAIL")' "$CONFIG_EX")"
check "LC4c the old suggestions getter is gone" "$(grep_absent "$ROOT/hooks/lib/zensu-config.sh" 'zensu_autofix_include_suggestions')"
```

- [ ] **Step 5: Run and confirm the failures.**

Run: `bash evals/config-gate/test-helper-autofix-flags.sh; bash evals/config-gate/test-config-merge.sh; bash tests/structure/test-review-convergence.sh 2>&1 | grep -E 'FAIL|PASS / '`
Expected: FAIL on every severity case (`zensu_autofix_severity: command not found`), on the default-2 checks, and on LC1 to LC4c.

- [ ] **Step 6: Implement.** In `hooks/lib/zensu-config.sh` replace the function `zensu_autofix_include_suggestions` with:

```bash
zensu_autofix_severity() {
  command -v node >/dev/null 2>&1 || { printf 'critical'; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var h=(j&&j.hooks)||{};var s=h.autoFixSeverity;process.stdout.write(s==="critical"||s==="important"||s==="all"?s:(h.autoFixIncludeSuggestions===true?"all":"critical"))' 2>/dev/null)
  [ -z "$val" ] && val="critical"
  printf '%s' "$val"
}
```

and change the round default:

```bash
zensu_autofix_max_rounds()        { _zensu_config_bounded_int autoFixMaxRounds 2 1 99; }
```

In `config.example.json` replace lines 9 and 10 with:

```json
    "autoFixSeverity": "critical",
    "autoFixIncludeSuggestions": false,
    "autoFixMaxRounds": 2,
```

In `docs/configuration.md`, in the `autoFixMaxRounds` row, replace `(default \`1\`, valid range \`1..99\`)` with `(default \`2\`, valid range \`1..99\`)`, replace `One fix round is followed by one verification review and the self-review stage; set \`5\` to restore the earlier loop of up to five fix rounds.` with `Up to two fix rounds, each followed by a verification review, then the self-review stage; under the default \`autoFixSeverity: critical\` the second round opens only when the verification review finds a Critical finding that /zensu:tdd step 4c stage 3 reproduced. Set \`1\` for a single fix round or \`5\` to restore the earlier loop of up to five fix rounds.`, and replace `so the default lets it nudge four times instead of eight` with `so the default lets it nudge five times instead of eight`.

- [ ] **Step 7: Run and confirm green.** Same command as Step 5. Expected: `test-helper-autofix-flags: N PASS / 0 FAIL`, `test-config-merge: N PASS / 0 FAIL`, and every LC check PASS. The delegate still calls the removed getter until Task 2, so do not run delegate suites yet.

- [ ] **Step 8: Commit** (together with Task 2, because the delegate calls the removed getter): no commit here.

### Task 2: The `critical` arm in the delegate

**Files:**
- Modify: `hooks/post-review-tdd-delegate.sh` (header lines 9-11, after line 344, the convergence block at lines 380-385, the arm split at lines 503-507, the comment that names "the two hand-parallel arms")
- Test: `evals/config-gate/test-review-convergence-directive.sh`, `evals/config-gate/test-autofix-suggestions-off.sh`, `tests/structure/test-review-convergence.sh` (R15, R16b, LC3c, LC3d), `tests/structure/test-incremental-review-rounds.sh` (I17), `tests/structure/test-finding-verification.sh` (P3b), `tests/structure/test-stop-enforcer-self-review-routing.sh` (T40)

**Interfaces:**
- Consumes: `zensu_autofix_severity` from Task 1.
- Produces: rendered status lines `'Fixing critical findings in-thread, then re-reviewing (round N/M)' (case C)`, `'No critical findings — important findings parked for /zensu:self-review' (case B)`, `'No critical/important findings — suggestions only' (case B, nothing parked)`; the ledger form `'FINDING LEDGER — R<k>-F<n> parked IMPORTANT <path>:<line> | <paraphrase>'`.

- [ ] **Step 1: Extend the directive eval.** In `evals/config-gate/test-review-convergence-directive.sh`:
  - change `render_rounds` to take an optional round count: `local name="$1" config="$2" rounds="${3:-2}"` and loop `for round in $(seq 1 "$rounds"); do`;
  - pin the important arm: `render_rounds on-default '{"hooks":{"autoFix":true,"autoFixSeverity":"important","autoFixMaxRounds":5}}'`;
  - render the default budget over three reviews: `render_rounds one-round '{"hooks":{"autoFix":true}}' 3`;
  - add `render_rounds sev-all '{"hooks":{"autoFix":true,"autoFixSeverity":"all","autoFixMaxRounds":5}}'` and `render_rounds sev-crit-legacy '{"hooks":{"autoFix":true,"autoFixSeverity":"critical","autoFixIncludeSuggestions":true}}'`;
  - replace RP0b and RP2 with checks on round 3:

```bash
ONE3="$(context_of "$TMP_DIR/one-round/round-3.json")"
check "RP0b the default budget routes a second fix round" "$(has "$ONE2" "'Fixing critical findings in-thread, then re-reviewing (round 2/2)' (case C)")"
check "RP0c the default budget hands the third review over at max rounds" "$(has "$ONE3" 'max 2 rounds reached')"
check "RP2 the default hand-off names the reproduction rule for self-review" "$(has "$ONE3" 'is a self-review must-fix only when its FINDING REPRODUCTION line reads REPRODUCED')"
```

  - append the severity checks before `echo "----"`:

```bash
SEVALL1="$(context_of "$TMP_DIR/sev-all/round-1.json")"
SEVCL1="$(context_of "$TMP_DIR/sev-crit-legacy/round-1.json")"
check "SV1 the default threshold is critical" "$(has "$ONE1" 'hooks.autoFixSeverity is critical: this loop fixes only Critical findings')"
check "SV2 case B parks IMPORTANT findings under the round's ids" "$(has "$ONE1" "exactly in the form 'FINDING LEDGER — R1-F<n> parked IMPORTANT <path>:<line> | <paraphrase>'")"
check "SV3 the clause form admits the parked state" "$(has "$ONE1" "'FINDING LEDGER — R1-F<n> <routed|deferred|neutralized|parked>")"
check "SV4 case C parks every IMPORTANT finding it leaves unfixed" "$(has "$ONE1" "'parked' for every IMPORTANT finding you leave unfixed, 'deferred' for every other finding you leave unfixed")"
check "SV5 a re-review never keeps an IMPORTANT finding routable" "$(has "$ONE1" 'An IMPORTANT finding never stays routable, because hooks.autoFixSeverity is critical')"
check "SV6 the judge exceptions are absent under critical" "$(lacks "$ONE1" 'An IMPORTANT finding stays routable only when')"
check "SV7 case C names the critical status line" "$(has "$ONE1" "'Fixing critical findings in-thread, then re-reviewing (round 1/2)' (case C)")"
check "SV8 case B names the parked status line" "$(has "$ONE1" "'No critical findings — important findings parked for /zensu:self-review' (case B)")"
check "SV9 case C lists only Critical findings" "$(has "$ONE1" 'List ONLY Critical findings. EXCLUDE all Important findings')"
check "SV10 an unavailable convergence fixes IMPORTANT findings too" "$(has "$ONE1" 'fixing its IMPORTANT findings with its CRITICAL ones because no ledger carries a parked finding to /zensu:self-review')"
check "SV11 the important arm keeps its own wording" "$(has "$DEF1" "'Fixing critical+important findings in-thread, then re-reviewing (round 1/5)' (case C)")"
check "SV12 the important arm carries no critical sentence" "$(lacks "$DEF1" 'hooks.autoFixSeverity is critical')"
check "SV13 convergence off falls back to the important arm" "$(has "$OFFD1" 'Fixing critical+important findings in-thread')"
check "SV14 selfReview off falls back to the important arm" "$(has "$SUM1" 'Fixing critical+important findings in-thread')"
check "SV15 autoFixSeverity all renders the suggestions arm" "$(has "$SEVALL1" 'Fixing all findings in-thread')"
check "SV16 an explicit critical beats the legacy key" "$(has "$SEVCL1" 'hooks.autoFixSeverity is critical')"
PARK_LOG="$TMP_DIR/park.log"
node -e '
  const m = /exactly in the form \x27(FINDING LEDGER — R1-F<n> parked[^\x27]*)\x27/.exec(process.argv[1]);
  if (!m) process.exit(1);
  const line = m[1].replace("<n>", "1").replace("<path>:<line>", "src/a.ts:3").replace("<paraphrase>", "filled from the park template");
  require("fs").writeFileSync(process.argv[2], line + "\n");
' "$ONE1" "$PARK_LOG" && PARK_OUT="$(node "$LEDGER_LIB" --log "$PARK_LOG" 2>&1)" || PARK_OUT=""
check "SV17 a parked line written from the rendered template parses as an open ledger entry" "$(has "$PARK_OUT" 'entry R1-F1 parked IMPORTANT src/a.ts:3')"
```

- [ ] **Step 2: Update the suggestions-off eval.** In `evals/config-gate/test-autofix-suggestions-off.sh`, the flag-absent render is now the `critical` arm: replace the pattern `*"Fixing critical+important findings in-thread, then re-reviewing"*` with `*"Fixing critical findings in-thread, then re-reviewing"*` and both labels with `flag absent: 'Fixing critical findings in-thread' status line (default autoFixSeverity critical)`.

- [ ] **Step 3: Count three arms in the source-count checks.**
  - `tests/structure/test-review-convergence.sh`: R15 `[ "$n" -eq 3 ]`, labels `every severity arm interpolates the clause (${n}x)` and `(${n}x, want 3)`; R16b `-eq 3`, labels `every arm prescribes …` and `want 3`; LC3c and LC3d `-eq 3`.
  - `tests/structure/test-incremental-review-rounds.sh`: I17 `[ "$n" -eq 3 ]`, labels `every delegate arm carries [$needle] (${n}x)` and `(${n}x, want 3)`; reword the comment above the loop to `The three delegate arms are verbatim-identical by contract, so every needle must` / `appear THREE times — a one-sided edit is the failure this counts rather than greps.`
  - `tests/structure/test-finding-verification.sh`: P3b `-eq 3`, label `P3b EVERY post-review directive re-runs the gate before re-verifying`.
  - `tests/structure/test-stop-enforcer-self-review-routing.sh`: T40 registers render sites, so raise `[ "$IN_SCOPE_CLAUSE_DELEGATE" = "2" ]` to `"3"` and reword the comment `since the delegate's two arms sit on single mega-lines` to `since the delegate's arms sit on single mega-lines`.
  - `evals/config-gate/test-review-convergence-directive.sh`: relabel RP0 to `RP0 the default budget routes a fix round after the first review`.

- [ ] **Step 4: Run and confirm the failures.**

Run: `bash evals/config-gate/test-review-convergence-directive.sh 2>&1 | grep -E 'FAIL|PASS / '`
Expected: FAIL for RP0b, RP0c, RP2, SV1 to SV10, SV16, SV17 and every check on the delegate, because the delegate still calls the removed getter.

- [ ] **Step 5: Implement the delegate.**
  1. Header lines 9 to 11 become:

```bash
#   hooks.autoFixSeverity=critical|important|all -> route Critical only (default), Critical+Important, or ALL severities
#   hooks.autoFixIncludeSuggestions=true          -> legacy spelling of autoFixSeverity=all
#   hooks.autoFixMaxRounds=<int 1..99>            -> loop guard (default 2)
```

  2. After `PANEL="$(zensu_review_panel)"` insert:

```bash
SEVERITY="$(zensu_autofix_severity)"
if [ "$SEVERITY" = "critical" ] && { [ "$SELF_REVIEW_ON" != "1" ] || [ "$CONVERGENCE_ON" != "1" ]; }; then
  SEVERITY="important"
fi
```

  3. In the convergence block: add `PARK_CLAUSE=""` next to `CONVERGENCE_CLAUSE=""`. After the two existing `IMPORTANT_RULE` lines insert:

```bash
  LEDGER_STATES="routed|deferred|neutralized"
  UNFIXED_STATES="'deferred' for every other finding you leave unfixed"
  UNAVAILABLE_ROUTE="route that review as before"
  if [ "$SEVERITY" = "critical" ]; then
    IMPORTANT_RULE="An IMPORTANT finding never stays routable, because hooks.autoFixSeverity is critical and /zensu:self-review fixes it once at the end of the chain."
    LEDGER_STATES="routed|deferred|neutralized|parked"
    UNFIXED_STATES="'parked' for every IMPORTANT finding you leave unfixed, 'deferred' for every other finding you leave unfixed"
    UNAVAILABLE_ROUTE="route that review as before, fixing its IMPORTANT findings with its CRITICAL ones because no ledger carries a parked finding to /zensu:self-review,"
  fi
```

  Move the clause text from `Append every FINDING LEDGER line of this chain` through `ZENSU_SECRET_SCAN=off.` verbatim into `LEDGER_WRITE_RULES="…"` on its own line before `CONVERGENCE_CLAUSE=`, and in the clause line replace that span with `${LEDGER_WRITE_RULES}`, `<routed|deferred|neutralized>` with `<${LEDGER_STATES}>`, `'deferred' for every other finding you leave unfixed` with `${UNFIXED_STATES}`, and `route that review as before and log` with `${UNAVAILABLE_ROUTE} and log`. After the clause line, still inside the block, add:

```bash
  if [ "$SEVERITY" = "critical" ]; then
    PARK_CLAUSE=" Park every IMPORTANT finding of this review that has no ledger line yet: append one run-log line for it, in merged order, exactly in the form 'FINDING LEDGER — R${NEXT}-F<n> parked IMPORTANT <path>:<line> | <paraphrase>'. ${LEDGER_WRITE_RULES}"
  fi
```

  4. Replace `if zensu_autofix_include_suggestions; then` with `if [ "$SEVERITY" = "all" ]; then`, and the `else` before the default arm with `elif [ "$SEVERITY" = "important" ]; then`. Add an `else` arm whose `MSG` is a copy of the `important` arm line with exactly these five replacements, applied once each:

| Find in the copy | Replace with |
|---|---|
| `Classify its findings by severity, then act:\n\n(A)` | `Classify its findings by severity, then act. hooks.autoFixSeverity is critical: this loop fixes only Critical findings, and /zensu:self-review fixes every Important finding once at the end of the chain, so park each Important finding instead of fixing it. The one exception is a review you logged 'CONVERGENCE UNAVAILABLE' for: no ledger carries its findings to /zensu:self-review, so treat its Important findings like Critical ones.\n\n(A)` |
| `(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT fix. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim` | `(B) No Critical findings (only Important findings, Suggestions, Minor or Nits) — do NOT fix.${PARK_CLAUSE} Reply with the status line 'No critical findings — important findings parked for /zensu:self-review' when you parked any, otherwise 'No critical/important findings — suggestions only', followed by the parked Important findings under the heading '### Important (parked for /zensu:self-review)' and the bullet list of Suggestions verbatim` |
| `(C) ANY Critical OR Important findings present` | `(C) ANY Critical findings present` |
| `List ONLY Critical and Important findings. EXCLUDE all Suggestions / Minor / Nits` | `List ONLY Critical findings. EXCLUDE all Important findings, which you park through the ledger below, and EXCLUDE all Suggestions / Minor / Nits` |
| `'Fixing critical+important findings in-thread, then re-reviewing (round ${NEXT}/${MAX_ROUNDS})' (case C) \| 'No critical/important findings — suggestions only' (case B)` | `'Fixing critical findings in-thread, then re-reviewing (round ${NEXT}/${MAX_ROUNDS})' (case C) \| 'No critical findings — important findings parked for /zensu:self-review' (case B) \| 'No critical/important findings — suggestions only' (case B, nothing parked)` |

  5. Reword the comment line `# Resolved ONCE, above the severity split, so the two hand-parallel arms cannot` to `# Resolved ONCE, above the severity split, so the hand-parallel arms cannot`.

- [ ] **Step 6: Syntax and byte-identity checks.**

Run: `/bin/bash -n hooks/post-review-tdd-delegate.sh && bash -n hooks/lib/zensu-config.sh && echo syntax-ok`
Expected: `syntax-ok`.

Then render round 1 and round 2 on `main` (`git worktree add --detach <scratch>/main-wt origin/main`) and on this branch with the harness of `test-review-convergence-directive.sh`, for `{"hooks":{"autoFix":true,"autoFixMaxRounds":5}}` on main against `{"hooks":{"autoFix":true,"autoFixSeverity":"important","autoFixMaxRounds":5}}` here, and for `{"hooks":{"autoFix":true,"autoFixIncludeSuggestions":true,"autoFixMaxRounds":5}}` on both. Replace the plugin root path and the review ticket with fixed tokens, then `diff`.
Expected: no difference in either pair. Remove the scratch worktree afterwards.

- [ ] **Step 7: Run the touched suites.**

Run each and expect `0 FAIL`: `evals/config-gate/test-review-convergence-directive.sh`, `evals/config-gate/test-autofix-suggestions-off.sh`, `evals/config-gate/test-autofix-suggestions-on.sh`, `evals/config-gate/test-autofix-rounds-convergence.sh`, `evals/tdd-review-chain/assert-severity-routing.sh`, `evals/config-gate/test-helper-autofix-flags.sh`, `evals/config-gate/test-config-merge.sh`, `tests/structure/test-review-convergence.sh`, `tests/structure/test-incremental-review-rounds.sh`, `tests/structure/test-finding-verification.sh`, `tests/structure/test-stop-enforcer-self-review-routing.sh`.

- [ ] **Step 8: Commit.**

```bash
git add hooks/lib/zensu-config.sh hooks/post-review-tdd-delegate.sh config.example.json docs/configuration.md evals/config-gate/test-helper-autofix-flags.sh evals/config-gate/test-config-merge.sh evals/config-gate/test-review-convergence-directive.sh evals/config-gate/test-autofix-suggestions-off.sh tests/structure/test-review-convergence.sh tests/structure/test-incremental-review-rounds.sh tests/structure/test-finding-verification.sh tests/structure/test-stop-enforcer-self-review-routing.sh
git commit -m "feat(review): fix only critical findings in the loop by default"
```

### Task 3: Docs, skills and the upgrade note

**Files:**
- Modify: `docs/configuration.md` (rows at lines 26, 56, 57, 80, 128 and a new `autoFixSeverity` row), `docs/review-severity.md:8-17`, `docs/architecture.md:249`, `docs/tdd-manager-workflow.md:455-457`, `skills/tdd/SKILL.md:433`, `skills/setup/SKILL.md:59`, `skills/zensu-help/SKILL.md:75`, `CHANGELOG.md` (`## [Unreleased]` → `### Upgrade notes`)
- Test: `tests/structure/test-edit-landing-audit.sh:650`, `tests/structure/test-review-convergence.sh` (new LC4d, LC4e)

- [ ] **Step 1: Write the failing doc checks.** In `tests/structure/test-edit-landing-audit.sh` line 650 replace `'On Critical/Important findings'` with `'On routed findings'`. In `tests/structure/test-review-convergence.sh` after LC4c add:

```bash
check "LC4d configuration.md documents autoFixSeverity" "$(grep_ok "$CONFIG_DOC" '| `autoFixSeverity` |')"
check "LC4e the rubric doc states the critical default" "$(grep_ok "$RUBRIC_DOC" 'By default (`hooks.autoFixSeverity: critical`) only CRITICAL findings route')"
```

Run: `bash tests/structure/test-edit-landing-audit.sh 2>&1 | grep -E 'P2|PASS / '; bash tests/structure/test-review-convergence.sh 2>&1 | grep -E 'LC4[de]'`
Expected: P2, LC4d and LC4e FAIL.

- [ ] **Step 2: `docs/configuration.md`.**
  - Line 26: `` `autoFix` (+ `autoFixIncludeSuggestions`, `` → `` `autoFix` (+ `autoFixSeverity`, `autoFixIncludeSuggestions`, ``.
  - Line 56: `Skips auto-routing of Critical/Important findings into the main-thread fix loop` → `Skips auto-routing of review findings into the main-thread fix loop`.
  - Insert before the `autoFixIncludeSuggestions` row:

```markdown
| `autoFixSeverity` | `post-review-tdd-delegate.sh` | Which severities the auto-fix loop routes into a main-thread fix round: `critical` (default) routes only Critical findings, `important` routes Critical and Important findings, and `all` routes every severity. Under `critical` every review, the first one included, parks its Important findings: it retitles them `[Deferred — do not fix]`, ledgers them `parked`, and `/zensu:self-review` fixes each one the code still supports in its single fix round. A review without a Critical finding opens no fix round and hands the chain to the self-review. `critical` needs `hooks.selfReview` and `hooks.reviewConvergence`: with either off, or on a re-review that logs `CONVERGENCE UNAVAILABLE`, Important findings route as under `important`, because no later stage would pick a parked finding up. An unrecognised value falls back to `autoFixIncludeSuggestions` and then to `critical`. **Requires `autoFix:true`.** |
```

  - `autoFixIncludeSuggestions` row: replace its description with `Legacy spelling of \`autoFixSeverity: all\`. When \`true\` and \`autoFixSeverity\` is unset or unrecognised, the auto-fix hook routes ALL severities (Critical, Important, Suggestion, Minor, Nit) into the main-thread fix loop; a recognised \`autoFixSeverity\` wins. While \`hooks.reviewConvergence\` is enabled (the default), that holds for the first review only: every re-review defers its suggestions instead of opening another round (see \`reviewConvergence\` below). Default \`false\`. **Requires \`autoFix:true\`** — if \`autoFix\` is \`false\`, the entire auto-fix hook short-circuits and this flag has no effect.`
  - Line 80: after `or it cites code the previous fix pass edited` insert ` (never under the default \`autoFixSeverity: critical\`, which parks every IMPORTANT finding)`.
  - Line 128: `required for \`autoFixIncludeSuggestions\` and \`autoFixMaxRounds\`` → `required for \`autoFixSeverity\`, \`autoFixIncludeSuggestions\` and \`autoFixMaxRounds\``.

- [ ] **Step 3: `docs/review-severity.md` lines 8 to 17.** Replace the paragraph with:

```markdown
The scale decides what the auto-fix loop routes. By default (`hooks.autoFixSeverity: critical`) only CRITICAL findings route;
every IMPORTANT finding is parked, and `/zensu:self-review` fixes it once at the end of the chain. `important` routes
CRITICAL and IMPORTANT findings, and `all`, or the legacy `hooks.autoFixIncludeSuggestions`, routes SUGGESTION findings
too. Under `important` and `all`, while `hooks.reviewConvergence` is enabled (the default), every re-review routes only
CRITICAL findings and the IMPORTANT findings the judge raised, tagged `[NOT FIXED]` or cited on code the previous fix pass
edited, and defers everything else; with `hooks.selfReview` off every IMPORTANT finding stays routable, under `critical`
as well (see [configuration.md](configuration.md)). While `hooks.criticalReproduction` is enabled (the default),
a CRITICAL finding of a re-review routes only when a failing test reproduces it; see `/zensu:tdd`
step 4c stage 3. An undefined scale let every reviewer promote its own
taste to IMPORTANT, and every such finding opened another full review round.
```

  Keep `a CRITICAL finding of a re-review routes only when a failing test reproduces it` verbatim (LC2f).

- [ ] **Step 4: `docs/architecture.md` line 249.** Replace `Critical/Important findings fixed in-thread, then re-reviewed, capped at autoFixMaxRounds;` with `Critical findings fixed in-thread (Important ones too under hooks.autoFixSeverity important or all, otherwise parked for the self-review), then re-reviewed, capped at autoFixMaxRounds;`.

- [ ] **Step 5: `docs/tdd-manager-workflow.md`.**
  - Line 455: replace `` `hooks.autoFixIncludeSuggestions` also fixes suggestions; while `hooks.reviewConvergence` is enabled it does so in the first review only. `` with `` By default (`hooks.autoFixSeverity: critical`) the loop fixes only CRITICAL findings and parks every IMPORTANT finding for the terminal self-review; `important` fixes IMPORTANT findings too, and `all`, or the legacy `hooks.autoFixIncludeSuggestions`, also fixes suggestions, in the first review only while `hooks.reviewConvergence` is enabled. ``
  - Line 457: `Auto-fix loop runs one fix round by default` → `Auto-fix loop runs up to two fix rounds by default`; `and every re-review routes only CRITICAL findings plus` → `and under \`important\` or \`all\` every re-review routes only CRITICAL findings plus`; `The review that completes after the 5th fix round takes the max-rounds branch` → `The review that completes after the last allowed fix round takes the max-rounds branch`. Keep `the IMPORTANT findings the judge raised, tagged \`[NOT FIXED]\` or cited on code the previous fix pass edited` and ``ledgered `parked` when it is IMPORTANT`` verbatim (R35c, R35d).

- [ ] **Step 6: Skills.**
  - `skills/tdd/SKILL.md` line 433: `On Critical/Important findings:` → `On routed findings (only Critical ones under the default \`hooks.autoFixSeverity: critical\`):`. No new line.
  - `skills/setup/SKILL.md` line 59: `| Auto-fix round budget | \`hooks.autoFixMaxRounds\` | int 1–99 | \`1\` |` → the same row ending in `` `2` ``.
  - `skills/zensu-help/SKILL.md` line 75: `` `autoFix`, `autoFixIncludeSuggestions`, `` → `` `autoFix`, `autoFixSeverity`, `autoFixIncludeSuggestions`, ``.

- [ ] **Step 7: Upgrade note.** In `CHANGELOG.md` under `## [Unreleased]` → `### Upgrade notes`, add as the first bullet:

```markdown
- **review loop**: the `/zensu:tdd` auto-fix loop now fixes only CRITICAL findings by default
  (`hooks.autoFixSeverity: critical`). Every IMPORTANT finding is parked, and `/zensu:self-review`
  fixes it once at the end of the chain; `"autoFixSeverity": "important"` restores the earlier
  routing, and `hooks.autoFixIncludeSuggestions: true` still routes every severity. The loop allows
  two fix rounds by default (`hooks.autoFixMaxRounds`, 5 in 0.23.0), a re-review spawns only the
  `correctness` perspective (`hooks.reviewPanel: full` restores five perspectives and the judge), and
  a re-review CRITICAL routes only when a failing test reproduces it (`hooks.criticalReproduction`).
  The Stop chain guard releases after `autoFixMaxRounds + 3` nudges, so 5 by default.
```

- [ ] **Step 8: Run and commit.**

Run: `wc -l < skills/tdd/SKILL.md; bash tests/structure/test-edit-landing-audit.sh 2>&1 | tail -1; bash tests/structure/test-review-convergence.sh 2>&1 | tail -1; bash evals/config-gate/test-readme-coverage.sh 2>&1 | tail -1; bash evals/config-gate/test-changelog-coverage.sh 2>&1 | tail -1`
Expected: `433`, then `0 FAIL` for each suite.

```bash
git add docs/configuration.md docs/review-severity.md docs/architecture.md docs/tdd-manager-workflow.md skills/tdd/SKILL.md skills/setup/SKILL.md skills/zensu-help/SKILL.md CHANGELOG.md tests/structure/test-edit-landing-audit.sh tests/structure/test-review-convergence.sh
git commit -m "docs(review): document the critical-only fix loop"
```

### Task 4: Pull request

- [ ] **Step 1:** Commit this plan with the spec's branch: `git add docs/superpowers/plans/2026-10-04-critical-only-fix-loop.md && git commit -m "docs(plan): plan the critical-only fix loop"` (before Task 1).
- [ ] **Step 2:** Ask the user before pushing. Then `git push -u origin feat/critical-only-fix-loop` and confirm with `git ls-remote --heads origin feat/critical-only-fix-loop`.
- [ ] **Step 3:** Write the PR body from `templates/pr-body.md` with one acceptance-criteria row per spec decision (D6, D7, D8), the local results of Task 2 Step 7 and Task 3 Step 8, "not run locally: the full suite; CI runs it", version minor (released with #372), and the gate note. Open it with `gh pr create --base main --title "feat(review): fix only critical findings in the loop by default" --body-file <scratchpad>/pr-c-body.md`.
- [ ] **Step 4:** Read the PR's CI once with `gh pr view <n> --json statusCheckRollup`; leave watching to the app's monitor and offer Auto-fix.
