#!/bin/bash
# Edit Landing Audit — the Phase 6 backstop for a claimed edit that never landed.
#
# A mechanical or bulk replacement (sed / perl -pi, a codemod script, an Edit with
# replace_all) that matches NOTHING produces no diff. The changed-file list the
# review chain consumes comes from git, so such a claim reaches no reviewer, and
# the suite stays green because it was green before the edit. The failure mode is
# silent by construction: no diff, no reviewer input, no red suite.
#
# This suite pins both halves of the fix:
#   pins:   skills/tdd/SKILL.md carries the named Edit Landing Audit with its
#           failure marker, path normalization, repo-root-anchored enumeration,
#           unborn HEAD branch, baseline-SHA capture, claim-scoping rule,
#           bounded exemptions, no-auto-fix severity, report + chain-end carry,
#           the per-round obligation, the Phase 4 mechanical-replacement re-read
#           rule, and the file-carrying IMPL/WIRED logging forms; the vanilla
#           deltas keep the audit instead of skipping it; the carry reaches
#           skills/self-review/SKILL.md and the post-review directive
#   recipe: a hermetic git fixture proves every documented enumeration rule
#           actually behaves as the skill claims (a wrong recipe fails here, not
#           only missing prose)
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_TDD="$PLUGIN_DIR/skills/tdd/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

# Section extractors. Each is bounded by the NEXT heading of its own kind, never
# by a named sibling — a renamed or reordered neighbour must not silently widen a
# block until unrelated text satisfies its assertions.
audit_block() {
  awk '/^5b\. \*\*Edit Landing Audit\*\*/{inb=1; print; next}
       inb && /^[0-9]+[a-z]?\. \*\*/{exit}
       inb' "$SKILL_TDD"
}
logging_contract_block() {
  awk '/^### Per-Step Logging Contract/{inb=1; next}
       inb && /^#/{exit}
       inb' "$SKILL_TDD"
}
vanilla_phase4_line() { grep -F -- '- Phase 4 replaced:' "$SKILL_TDD" | head -n1; }
vanilla_fixround_line() { grep -F -- '- Review-fix rounds and the self-review fix round are vanilla too' "$SKILL_TDD" | head -n1; }
packet_files_line() { grep -F -- '2. Enumerate changed files' "$SKILL_TDD" | head -n1; }
coverage_collect_line() { grep -F -- 'Collect list of files modified during session' "$SKILL_TDD" | head -n1; }
mtime_collect_line() { grep -F -- 'Resolve the IMPL file list from the' "$SKILL_TDD" | head -n1; }
phase4_rule_line() { grep -F -- 'Mechanical or bulk replacement' "$SKILL_TDD" | head -n1; }
phase0_line() { grep -F -- 'SESSION_EPOCH=$(date +%s)' "$SKILL_TDD" | head -n1; }
fix_routing_line() { grep -F -- 'On Critical/Important findings' "$SKILL_TDD" | head -n1; }
vanilla_phase6_line() { grep -F -- '- Phase 6: only the' "$SKILL_TDD" | head -n1; }
vanilla_survivors_line() { grep -F -- 'Everything not listed below runs EXACTLY as written' "$SKILL_TDD" | head -n1; }

echo "== Pins: Phase 6 Edit Landing Audit =="
BLOCK="$(audit_block)"
if [ -z "$BLOCK" ]; then
  check "A1 SKILL.md carries a named '5b. **Edit Landing Audit**' step" FAIL
  echo "  ---- block not found: the A2-A14 pins below cannot be evaluated (fix A1 first) ----"
  for skipped in \
    "A2 audit block scoping" "A3 both-modes declaration" "A4 EDIT NOT LANDED marker" \
    "A5 Phase 6 incompleteness" "A6 no-auto-fix severity" "A7 claim source literals" \
    "A8 repo-root-relative normalization" "A8b fixed-string whole-line comparison" \
    "A8c malformed WIRED is UNVERIFIED" "A9 resolved-repo-root enumeration" "A10 unborn-HEAD branch" \
    "A11 baseline-SHA range" "A12 membership is not evidence" "A12b audit start marker" \
    "A12c empty baseline SHA guard" "A12d non-git fallback is UNVERIFIED" \
    "A12e directory + basename resolution" "A13 green run is not evidence" \
    "A14 CHAIN-END SUMMARY carry" "A9b repo-root guard" "A17 closing audit line" \
    "A12f PENDING PREDICATE vs UNVERIFIED" "A12g disjoint round labels" \
    "A12h addition predicate" "A12i PENDING PREDICATE carve-out" "A12j literal pathspecs" \
    "A12k unquoted non-ASCII paths" "A12l nested project-dir re-basing"; do
    check "$skipped (unevaluated — audit block missing)" FAIL
  done
else
  check "A1 SKILL.md carries a named '5b. **Edit Landing Audit**' step" PASS
  # The extractor stopped at the next numbered step rather than running to EOF.
  # Pin the literal that actually EXISTS in the file (bold markers included) —
  # a fixed string that matches nothing anywhere would make this pass always,
  # and every other block-scoped pin below depends on this one being real.
  grep -qF '6. **Precondition Drift Audit**' "$SKILL_TDD" \
    && ! printf '%s' "$BLOCK" | grep -qF '6. **Precondition Drift Audit**' \
    && ! printf '%s' "$BLOCK" | grep -qF 'Requirements Coverage Cross-Check'
  check "A2 audit block ends at the next numbered step (scoping intact)" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'runs in BOTH strict and vanilla mode'
  check "A3 audit declares it runs in BOTH strict and vanilla mode" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'EDIT NOT LANDED — {step_id}: claimed {file}, git shows no change'
  check "A4 audit emits the exact EDIT NOT LANDED marker" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'mark Phase 6 NOT complete'
  check "A5 an unlanded claim marks Phase 6 NOT complete" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'Do NOT auto-fix' && printf '%s' "$BLOCK" | grep -qF 'same severity as the Precondition Drift Audit'
  check "A6 audit forbids auto-fix at Precondition-Drift severity" "$(verdict $?)"
  # Claim sources must be pinned by their exact log literals: a bare 'WIRED' would
  # also be satisfied by the exemption text further down the same block.
  printf '%s' "$BLOCK" | grep -qF '{step_id} IMPL completed — files: {list}' \
    && printf '%s' "$BLOCK" | grep -qF '{step_id} WIRED — files: {list} | {description}'
  check "A7 audit sources claims from the exact IMPL + WIRED log literals" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'repo-root-relative' && printf '%s' "$BLOCK" | grep -qF 'bare basename'
  check "A8 audit normalizes claim paths to repo-root-relative before comparison" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'grep -qxF -- "$claim"' && printf '%s' "$BLOCK" | grep -qF 'never as a regex'
  check "A8b claim paths are compared fixed-string and whole-line, never as a regex" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'A `WIRED` entry in neither the `files:` form nor the `(verified, no change)` form'
  check "A8c a legacy or malformed WIRED entry is UNVERIFIED, never passing" "$(verdict $?)"
  # Anchor on the resolved repo ROOT, not on CLAUDE_PROJECT_DIR: that may be a
  # subdirectory (and its `:-.` fallback is the cwd), which would re-base the
  # cwd-scoped ls-files half against a repo-root-relative claim.
  printf '%s' "$BLOCK" | grep -qF 'rev-parse --show-toplevel' \
    && printf '%s' "$BLOCK" | grep -qF 'git -C "$TOP" -c core.quotePath=false diff --name-only HEAD' \
    && printf '%s' "$BLOCK" | grep -qF 'git -C "$TOP" -c core.quotePath=false ls-files --others --exclude-standard' \
    && ! printf '%s' "$BLOCK" | grep -qF 'git -C "${CLAUDE_PROJECT_DIR:-.}" ls-files'
  check "A9 both enumeration commands run from the resolved repo root" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF '[ -n "$TOP" ] && [ -d "$TOP" ]' \
    && printf '%s' "$BLOCK" | grep -qF 'never as an unanchored enumeration'
  check "A9b an unresolvable repo root routes to the no-work-tree branch, not to the cwd" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'unborn HEAD' && printf '%s' "$BLOCK" | grep -qF 'ls-files --cached --others --exclude-standard'
  check "A10 audit carries the unborn-HEAD branch" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF '"$BASELINE_SHA"..HEAD'
  check "A11 audit uses the Phase 0 baseline SHA for the mid-run-commit range" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'Presence in the union is not automatically evidence for the claim' \
    && printf '%s' "$BLOCK" | grep -qF 'predicate re-read shows the replacement did not apply' \
    && printf '%s' "$BLOCK" | grep -qF 'EVERY `fix-{N}` and `self-review` claim, and every claim on a file that more than one step claims'
  check "A12 membership is evidence only under decidable triggers, and a failed re-read is recorded" "$(verdict $?)"
  # The label space must be disjoint from the hook's round numbering, or the
  # Phase 6 pass and the first fix round collide on the same marker.
  printf '%s' "$BLOCK" | grep -qF '`phase6` for this Phase 6 pass' \
    && printf '%s' "$BLOCK" | grep -qF '`fix-{N}`' \
    && printf '%s' "$BLOCK" | grep -qF '`self-review` for the terminal stage' \
    && printf '%s' "$BLOCK" | grep -qF 'a bare number is never a valid label' \
    && printf '%s' "$BLOCK" | grep -qF 'a second marker carrying an existing label is itself a violation'
  check "A12g all three round labels are named and no bare number is sanctioned" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'a pure addition has no `$OLD`' \
    && printf '%s' "$BLOCK" | grep -qF 'it matches every line, failing a healthy claim'
  check "A12h the predicate is defined for a pure addition, not only for a replacement" "$(verdict $?)"
  # Both arms: a passing re-read clears, a failing one still records.
  printf '%s' "$BLOCK" | grep -qF 'not carrying a `PENDING PREDICATE` verdict from (b)' \
    && printf '%s' "$BLOCK" | grep -qF 'a failing one appends `EDIT NOT LANDED' \
    && printf '%s' "$BLOCK" | grep -qF 'PENDING PREDICATE (no session baseline) — {step_id}: {file}'
  check "A12i a PENDING PREDICATE claim is claim-typed, clearable and fail-closed" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'EDIT LANDING AUDIT STARTED — round {n}' \
    && printf '%s' "$BLOCK" | grep -qF 'FIRST append'
  check "A12b the audit writes a start marker before collecting claims" "$(verdict $?)"
  # An empty baseline must neither degenerate to HEAD..HEAD nor widen the union
  # to a whole-repo listing, which would clear every claim on a tracked file.
  printf '%s' "$BLOCK" | grep -qF 'ONLY when `[ -n "$BASELINE_SHA" ]`' \
    && printf '%s' "$BLOCK" | grep -qF 'PENDING PREDICATE (no session baseline)' \
    && printf '%s' "$BLOCK" | grep -qF 'do NOT widen the union at all'
  check "A12c an empty baseline SHA neither degenerates to HEAD..HEAD nor widens the union" "$(verdict $?)"
  # PENDING PREDICATE is clearable; the step (a) UNVERIFIED is terminal. Keeping
  # them distinct is what stops a healthy non-git run from being unfixable.
  printf '%s' "$BLOCK" | grep -qF 'is NOT the terminal `UNVERIFIED` of step (a)' \
    && printf '%s' "$BLOCK" | grep -qF 'EDIT LANDED (predicate re-read) — {file}'
  check "A12f a clearable PENDING PREDICATE verdict is distinct from the terminal UNVERIFIED" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'PENDING PREDICATE (no git work tree)' \
    && printf '%s' "$BLOCK" | grep -qF 'proves only that the file was WRITTEN'
  check "A12d the non-git mtime fallback never reports landed on its own" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'AT LEAST ONE file beneath it' \
    && printf '%s' "$BLOCK" | grep -qF 'ends in `/{basename}`' \
    && printf '%s' "$BLOCK" | grep -qF 'an ambiguous or unresolvable basename is UNVERIFIED'
  check "A12e directory claims and bare basenames have bounded resolution rules, ambiguity included" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF -- '--literal-pathspecs' \
    && printf '%s' "$BLOCK" | grep -qF 'git wildmatches a pathspec by default'
  check "A12j every pathspec is literal, so a bracketed filename is not read as a glob" "$(verdict $?)"
  # git C-quotes non-ASCII paths unless told otherwise, and no fixed-string
  # comparison can match a quoted spelling.
  printf '%s' "$BLOCK" | grep -qF -- '-c core.quotePath=false' \
    && printf '%s' "$BLOCK" | grep -qF 'git C-quotes any non-ASCII path by default'
  check "A12k the enumeration disables path quoting so non-ASCII claims can match" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 're-base a claim logged relative to a nested `CLAUDE_PROJECT_DIR` onto `TOP`'
  check "A12l a claim from a nested project dir is re-based before comparison" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'A green test run is never the evidence for this'
  check "A13 audit states a green run is not the evidence" "$(verdict $?)"
  printf '%s' "$BLOCK" | grep -qF 'CHAIN-END SUMMARY'
  check "A14 an unlanded claim is carried into the CHAIN-END SUMMARY" "$(verdict $?)"
  # A skipped enumeration and a clean one must not look identical in the log.
  # Its own marker, NOT the AUDIT — cmd= schema: that is cross-checked at step 1
  # (already past), needs a byte-exact Bash string, and its failure-marker scan
  # would trip on any changed path containing "Error"/"fail".
  printf '%s' "$BLOCK" | grep -qF 'EDIT LANDING AUDIT — round {n}: {verified}/{claimed} claims verified' \
    && printf '%s' "$BLOCK" | grep -qF 'Do NOT log it through the `AUDIT — cmd=` test-evidence schema' \
    && printf '%s' "$BLOCK" | grep -qF 'UNVERIFIED (no claims logged)'
  check "A17 the audit closes with its own counted marker and cannot pass as 0/0" "$(verdict $?)"
fi
grep -qF 'Edit Landing verdict from step 5b' "$SKILL_TDD" && grep -qF 'all claimed edits landed' "$SKILL_TDD" \
  && grep -qF 'never omit the last two, they are not clean states' "$SKILL_TDD"
check "A15 the final report renders the positive token AND the two non-clean closes" "$(verdict $?)"
# Both terminal summary contracts must carry the same vocabulary as step 9.
grep -qF 'UNVERIFIED (no claims logged)' "$PLUGIN_DIR/skills/self-review/SKILL.md" \
  && grep -qF 'UNVERIFIED (no claims logged)' "$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
check "A15b both CHAIN-END SUMMARY contracts name the non-clean closes too" "$(verdict $?)"

echo "== Pins: bounded exemptions =="
printf '%s' "$BLOCK" | grep -qF 'EDIT LANDED (untracked-by-design)'
check "X1 gitignored-by-design claim has an explicit recorded exemption" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'WIRED (verified, no change)'
check "X2 verification-only integration step has an explicit recorded exemption" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'must be recorded, never assumed' \
  && printf '%s' "$BLOCK" | grep -qF 'Never widen either exemption to a tracked source file'
check "X3 both exemptions are recorded and bounded to non-source claims" "$(verdict $?)"
# Neither exemption may be self-granted after the audit already found the miss.
printf '%s' "$BLOCK" | grep -qF 'git -C "$TOP" check-ignore -q -- "$claim"' \
  && printf '%s' "$BLOCK" | grep -qF '`[ -e "$TOP/$claim" ]` must hold' \
  && printf '%s' "$BLOCK" | grep -qF 'never stats the file'
check "X4 the gitignored exemption is proven from the repo root with a quoted claim and a real existence test" "$(verdict $?)"
# A step cannot both claim a change and claim it verified without changing
# anything — coexistence is the structural block on self-granting the exemption.
# Polarity matters: the two conditions describe when the standing is VALID, so
# framing them as "becomes a violation ONLY IF" inverts the rule.
printf '%s' "$BLOCK" | grep -qF 'That standing is VALID ONLY IF' \
  && printf '%s' "$BLOCK" | grep -qF 'FAILING EITHER, the finding stands as `EDIT NOT LANDED`' \
  && printf '%s' "$BLOCK" | grep -qF 'appears in NO `IMPL completed — files:` or `WIRED — files:` entry of this session' \
  && ! printf '%s' "$BLOCK" | grep -qF 'becomes a violation ONLY IF'
check "X5b the verification-only standing is framed as a validity test, not an inverted violation test" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'marker of the round now grading it' \
  && printf '%s' "$BLOCK" | grep -qF 'appended at audit time to clear a finding IS the violation' \
  && ! printf '%s' "$BLOCK" | grep -qi 'above the first'
check "X5 the exemption anchors to the grading round's marker, so honest round-2 work still qualifies" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'claimed DELETION the predicate inverts' \
  && printf '%s' "$BLOCK" | grep -qiF 'a deletion is exempt from the exemption (i) existence requirement' \
  && printf '%s' "$BLOCK" | grep -qF 'never test bare `ls-files`, which reads the INDEX'
check "X8 a claimed deletion inverts the predicate against the worktree, not the index" "$(verdict $?)"
# The exemption must be conditional on the re-read, not sequenced after it.
printf '%s' "$BLOCK" | grep -qF 'ONLY IF that re-read holds; if it does not, the exemption does not apply'
check "X9 the gitignored exemption is fail-closed on a failing predicate re-read" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'CLAIM WITHDRAWN — {step_id}: {file}' \
  && printf '%s' "$BLOCK" | grep -qF 'Withdrawal is a recorded state change, never an erasure' \
  && printf '%s' "$BLOCK" | grep -qF 'mark that plan step `[!]`' \
  && printf '%s' "$BLOCK" | grep -qF 'Phase-6-NOT-complete state standing'
check "X6 withdrawal carries all three side effects (marker, [!], Phase 6 stays incomplete)" "$(verdict $?)"
# The predicate is the audit's fallback proof — it must be fixed-string, or a
# sed/codemod pattern full of metacharacters gets graded as a regex.
printf '%s' "$(phase4_rule_line)" | grep -qF 'grep -cF -- "$NEW" "$file"' \
  && printf '%s' "$(phase4_rule_line)" | grep -qF 'grep -cF -- "$OLD" "$file"' \
  && printf '%s' "$BLOCK" | grep -qF 'grep -cF -- "$NEW" "$TOP/$file"'
check "X7 the operative predicate is fixed-string at both sites and repo-root-anchored in the audit" "$(verdict $?)"

echo "== Pins: logging contract carries the files the audit reads =="
LC="$(logging_contract_block)"
# Scoping first: both literals below also live inside 5b, so an over-running
# extractor would grade the audit's own quotations instead of the contract.
{ [ -n "$LC" ] && ! printf '%s' "$LC" | grep -qF 'EDIT NOT LANDED' \
  && ! printf '%s' "$LC" | grep -qF 'Per-Step Task Contract'; }
check "L1 Per-Step Logging Contract section extracts and stays inside its own section" "$(verdict $?)"
printf '%s' "$LC" | grep -qF '{step_id} WIRED — files: {list} | {description}'
check "L2 ordinary WIRED entry names the files it changed" "$(verdict $?)"
printf '%s' "$LC" | grep -qF '{step_id} WIRED (verified, no change) — {file}: {what was verified}'
check "L3 verification-only WIRED form is defined in the logging contract itself" "$(verdict $?)"
grep -qF 'WIRED — files: {list} | {description}` per the Per-Step Logging Contract' "$SKILL_TDD" \
  && grep -qF 'WIRED (verified, no change) — {file}: …` form when the step verified' "$SKILL_TDD"
check "L4 Phase 4 Integration Steps points at both file-carrying forms" "$(verdict $?)"
# The IMPL literal the audit collects must be the one the contract emits — three
# sites spelled it two ways before this pin existed.
printf '%s' "$LC" | grep -qF '{step_id} IMPL completed — files: {list}'
check "L5 the contract emits the exact IMPL literal the audit collects" "$(verdict $?)"
printf '%s' "$LC" | grep -qF 'comma-separated list of repo-root-relative paths'
check "L6 the contract types the files list the audit compares against git" "$(verdict $?)"
# Both claim-carrying forms need the same typing AND the same prose delimiter,
# or "read only the files: list" has no mechanical boundary for the IMPL form.
printf '%s' "$LC" | grep -qF 'same typing as the `WIRED` form below' \
  && printf '%s' "$LC" | grep -qF 'any commentary goes after a ` | ` separator'
check "L7 the IMPL form is typed and prose-delimited exactly like the WIRED form" "$(verdict $?)"
printf '%s' "$(coverage_collect_line)" | grep -qF 'never the commentary after ` | `'
check "L8 the coverage collector parses the files list the same way as the audit" "$(verdict $?)"
# The mtime audit hands the same list to stat — it needs the same parse rule.
printf '%s' "$(mtime_collect_line)" | grep -qF 'never the commentary after ` | `'
check "L9 the mtime Discipline Audit parses the files list the same way" "$(verdict $?)"
# The executable consumer of the log grammar must strip the commentary too.
grep -qF 's/ \| .*$//' "$PLUGIN_DIR/evals/tdd-review-chain/assert-tdd-log-compliance.sh"
check "L10 the eval log-compliance parser strips the commentary before splitting" "$(verdict $?)"
# Exercise the strip, don't just quote it: a wrong anchor or a greedy match
# would pass a text pin while silently mangling the file list.
L11_IN='S1 IMPL completed — files: a.ts, b.ts | refactored the | parser'
L11_OUT="$(printf '%s' "$L11_IN" | sed -E "s/^S1 IMPL completed — files: //" | sed -E 's/ \| .*$//')"
[ "$L11_OUT" = "a.ts, b.ts" ]
check "L11 the documented strip yields exactly the files list (got '${L11_OUT}')" "$(verdict $?)"
grep -qF 'S1 IMPL completed — files: src/snorg.sh | uses cat + jq' \
  "$PLUGIN_DIR/evals/tdd-manager-pretool/fixtures/snorg-drift/2026-01-01-0000_tdd-snorg.log"
check "L12 the drift fixture models the delimited form, not inline commentary" "$(verdict $?)"
GOOD_LOG="$PLUGIN_DIR/evals/tdd-review-chain/fixtures/tdd-log-good.log"
grep -qF 'BE-4 WIRED — files: src/main/java/com/example/RequestContext.java | deleted' "$GOOD_LOG" \
  && grep -qF 'BE-1 IMPL completed — files: src/main/java/com/example/TenantContext.java' "$GOOD_LOG"
check "L13 the canonical good log models the typed IMPL + WIRED forms" "$(verdict $?)"
# The only executable change in the delta needs a behavioural guard, not a pin.
grep -qF "resolves paths past ' | ' commentary" "$PLUGIN_DIR/evals/tdd-review-chain/run-self-check.sh" \
  && grep -qF -- '--impl-dir' "$PLUGIN_DIR/evals/tdd-review-chain/run-self-check.sh"
check "L14 the eval self-check exercises the commentary strip through the real script" "$(verdict $?)"

echo "== Pins: Phase 0 baseline capture + per-fix-round obligation =="
printf '%s' "$(phase0_line)" | grep -qF 'BASELINE_SHA=$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --verify --quiet HEAD)'
check "P1 Phase 0 captures the baseline SHA the audit consumes" "$(verdict $?)"
# The obligation must sit AHEAD of the severity branches, or a suggestions-only
# round follows a branch that never mentions the audit.
printf '%s' "$(fix_routing_line)" | grep -qF 'Applies to EVERY routed round before it re-verifies, in every severity mode' \
  && printf '%s' "$(fix_routing_line)" | sed 's/On Critical\/Important findings.*//' | grep -qF 're-run the Phase 6 step 5b Edit Landing Audit'
check "P2 the per-round obligation precedes the severity branches, not inside one" "$(verdict $?)"
# ...and the hook that actually drives each round must order it too.
HOOK_PR="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
# Per-variant, not a file-wide count: every MSG= directive variant must carry it.
HOOK_VARIANTS="$(grep -cF 'MSG="STOP.' "$HOOK_PR")"
# Intersect the sets: the phrase must be ON the variant lines, not merely
# somewhere else in the file.
HOOK_WITH_AUDIT="$(grep -F 'MSG="STOP.' "$HOOK_PR" | grep -cF 're-run the /zensu:tdd Phase 6 step 5b Edit Landing Audit over them')"
{ [ "$HOOK_VARIANTS" -eq 2 ] && [ "$HOOK_WITH_AUDIT" -eq "$HOOK_VARIANTS" ]; }
check "P2b every post-review fix-round directive variant orders the audit re-run" "$(verdict $?)"
# A per-round re-run needs per-round claims: vanilla fix rounds must log them.
printf '%s' "$(vanilla_fixround_line)" | grep -qF '{step_id} IMPL completed — files: {list}` for every fix'
check "P3 vanilla review-fix rounds log the claims the per-round audit grades" "$(verdict $?)"
# The reviewers' input set must not be narrower than what the audit calls landed.
# Reference, not a re-spelled subset: a partial copy would drop 5b's unborn-HEAD
# and mid-run-commit branches at the site that feeds the reviewers.
printf '%s' "$(packet_files_line)" | grep -qF 'Phase 6 step 5b b) enumeration UNCHANGED' \
  && printf '%s' "$(packet_files_line)" | grep -qF 'invisible to every reviewer'
check "P4 the review packet invokes the audit's enumeration unchanged" "$(verdict $?)"
# The verdict must survive into the artifact the user reads last.
# Pin the payload, not the neutral phrase: the marker itself must reach the
# summary, which is the terminal purpose of the whole change.
SR="$PLUGIN_DIR/skills/self-review/SKILL.md"
# One contiguous literal, not three independent file-wide greps: EDIT NOT LANDED
# and "verbatim" each occur twice in this file, so scattered hits must not pass.
grep -qF 'Edit Landing verdict — the step 5b close marker plus any `EDIT NOT LANDED` line,' "$SR"
check "P5 the self-review CHAIN-END SUMMARY carries the close marker and the EDIT NOT LANDED line" "$(verdict $?)"
# The self-review fix round is the LAST edit of the chain — nothing reviews it
# afterwards, so it must log its own claims and grade them.
grep -qF 'Edit Landing Audit' "$SR" \
  && grep -qF 'LAST edit round of the chain and no reviewer runs' "$SR" \
  && grep -qF '{step_id} IMPL completed — files: {list}' "$SR" \
  && grep -qF 'EDIT LANDING AUDIT STARTED — round' "$SR" \
  && grep -qF 'a label disjoint from `phase6` and `fix-{N}`' "$SR" \
  && grep -qF 'Read` it from `${CLAUDE_PLUGIN_ROOT}/skills/tdd/SKILL.md' "$SR"
check "P7 the terminal round logs its claims, labels its marker disjointly, and can resolve the procedure cold" "$(verdict $?)"
# The verdict vocabulary must match the canonical procedure: naming the terminal
# UNVERIFIED here would grade a clearable state as absent.
grep -qF 'PENDING PREDICATE (no session baseline)' "$SR" \
  && ! grep -qF 'UNVERIFIED (no session baseline)' "$SR"
check "P9 self-review names the clearable PENDING PREDICATE branch, not the terminal UNVERIFIED" "$(verdict $?)"
grep -qF 'diff --name-only "$BASELINE_SHA"..HEAD' "$SR"
check "P10 self-review carries the mid-run-commit branch so it cannot self-skip as no-changes" "$(verdict $?)"
grep -qF 'Phase 6 step 5b b) enumeration run UNCHANGED' "$SR"
check "P11 the self-review overview points at the canonical enumeration too" "$(verdict $?)"
grep -qF 'edit landing verdict (the step 5b close marker plus any EDIT NOT LANDED line, verbatim' "$HOOK_PR"
check "P6 the post-review summary directive demands the close marker and the finding verbatim" "$(verdict $?)"
# The packet field is only load-bearing if the CONSUMERS require it — the field
# lists in the agent contracts are what "REVIEW PACKET INVALID" enumerates.
grep -qF 'edit_landing_evidence' "$SKILL_TDD" \
  && grep -qF 'edit_landing_evidence' "$PLUGIN_DIR/agents/review-aspect.md" \
  && grep -qF 'edit_landing_evidence' "$PLUGIN_DIR/agents/review-judge.md" \
  && grep -qF 'edit_landing_evidence' "$PLUGIN_DIR/agents/code-reviewer.md"
check "P12 edit_landing_evidence is produced AND required by all three reviewer contracts" "$(verdict $?)"
# Self-review is the last reader of the changeset — a bare git diff would leave
# new untracked files unreviewed there too.
# The operative Phase 1 site must carry the resolution AND the guard — a bare
# `git -C ""` there would enumerate whatever repo the cwd happens to be.
grep -qF 'git -C "$TOP" -c core.quotePath=false ls-files --others --exclude-standard' "$SR" \
  && grep -qF 'rev-parse --show-toplevel' "$SR" \
  && grep -qF '[ -n "$TOP" ] && [ -d "$TOP" ]' "$SR"
check "P8 self-review resolves and guards TOP before enumerating the same union" "$(verdict $?)"

echo "== Pins: vanilla mode keeps the audit =="
V_SKIP="$(vanilla_phase6_line)"
V_SURV="$(vanilla_survivors_line)"
[ -n "$V_SKIP" ] && [ -n "$V_SURV" ]
check "B1 vanilla deltas expose both the skip list and the surviving-audit sentence" "$(verdict $?)"
printf '%s' "$V_SKIP" | grep -qF 'the Precondition Drift Audit and the Edit Landing Audit still run'
check "B2 vanilla Phase 6 bullet names the Edit Landing Audit as still running" "$(verdict $?)"
printf '%s' "$V_SKIP" | grep -qF 'The Edit Landing Audit is NEVER skipped in vanilla'
check "B3 vanilla bullet states the audit is never skipped there" "$(verdict $?)"
# The skip list is the text strictly between "only the" and "are skipped".
V_SKIPPED_ONLY="$(printf '%s' "$V_SKIP" | sed -n 's/.*only the \(.*\) are skipped.*/\1/p')"
{ [ -n "$V_SKIPPED_ONLY" ] \
  && printf '%s' "$V_SKIPPED_ONLY" | grep -qF 'mtime Discipline Audit' \
  && printf '%s' "$V_SKIPPED_ONLY" | grep -qF 'Cross-Layer Value Flow Audit' \
  && ! printf '%s' "$V_SKIPPED_ONLY" | grep -qF 'Edit Landing'; }
check "B4 vanilla skip list still names exactly the mtime + Cross-Layer audits" "$(verdict $?)"
printf '%s' "$V_SKIP" | grep -qF 'DISCIPLINE AUDIT SKIPPED — vanilla mode'
check "B5 vanilla skip marker literal preserved (cross-pin with test-tdd-vanilla-mode H1)" "$(verdict $?)"
printf '%s' "$V_SURV" | grep -qF 'the Edit Landing Audit'
check "B6 vanilla surviving-audit sentence names the Edit Landing Audit" "$(verdict $?)"

echo "== Pins: Phase 4 mechanical-replacement re-read rule =="
RULE="$(phase4_rule_line)"
printf '%s' "$RULE" | grep -qF 'confirm by RE-READING the result, never by the test run.'
check "C1 Phase 4 B) carries the mechanical-replacement re-read rule" "$(verdict $?)"
printf '%s' "$RULE" | grep -qF 'NEVER evidence that the replacement landed'
check "C2 rule separates 'command ran green' from 'replacement landed'" "$(verdict $?)"
printf '%s' "$RULE" | grep -qF 'replace_all' && printf '%s' "$RULE" | grep -qF 'codemod'
check "C3 the rule line itself enumerates the no-op vectors (codemod / replace_all)" "$(verdict $?)"
printf '%s' "$(vanilla_phase4_line)" | grep -qF 'mechanical-replacement re-read rule'
check "C4 vanilla Phase 4 replacement inherits the rule by name" "$(verdict $?)"

echo "== Pins: workflow doc inventory =="
DOC="$PLUGIN_DIR/docs/tdd-manager-workflow.md"
# Appended as the LAST row: inserting mid-table would recycle patch numbers that
# tracked text already cites (CHANGELOG references "Patch 8").
grep -qF '**10. Phase 6 Edit Landing Audit**' "$DOC" \
  && grep -qF 'EDIT NOT LANDED — {step_id}: claimed {file}, git shows no change' "$DOC" \
  && grep -qF '**8. Hook event mirror**' "$DOC"
check "D1 the audit is appended as the last patch row without recycling existing numbers" "$(verdict $?)"
grep -qF 'Build, coverage, mtime discipline, edit landing, precondition drift' "$DOC" \
  && grep -qF 'mtime discipline, edit landing audit, precondition drift audit' "$DOC"
check "D2 both Phase 6 enumeration rows name the audit" "$(verdict $?)"
grep -qF 'build status, mtime audit verdict, edit landing verdict, coverage status' "$DOC"
check "D3 the CHAIN-END SUMMARY contract row carries the verdict" "$(verdict $?)"
# Contiguous means 1..N with no duplicate AND no gap — compare the sorted row
# numbers against seq, not just their cardinality.
DOC_NUMS="$(grep -o '^| \*\*[0-9]\{1,2\}\.' "$DOC" | tr -cd '0-9\n' | sort -n)"
DOC_COUNT="$(printf '%s\n' "$DOC_NUMS" | grep -c '[0-9]')"
[ "$DOC_COUNT" -gt 0 ] && [ "$(printf '%s\n' "$DOC_NUMS")" = "$(seq 1 "$DOC_COUNT")" ]
check "D4 discipline-patch rows are numbered 1..N with no duplicate and no gap" "$(verdict $?)"
# Derive the expected pointer from the doc so a future row keeps them in sync.
grep -qE "discipline patches 1-$DOC_COUNT([^0-9]|\$)" "$PLUGIN_DIR/README.md"
check "D5 the README pointer is derived from the doc's actual row count" "$(verdict $?)"
grep -qF 'mtime discipline + edit landing + build verification' "$PLUGIN_DIR/README.md"
check "D6 the README audit enumeration names the edit landing audit" "$(verdict $?)"
grep -qF 'repo-root-anchored union' "$DOC" && grep -qF 'repo-root-anchored union' "$PLUGIN_DIR/CHANGELOG.md"
check "D7 doc and changelog describe the repo-root anchor the skill actually mandates" "$(verdict $?)"

echo "== Recipe: hermetic git walk =="
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CEILING_DIRECTORIES \
  GIT_TRACE GIT_TRACE2 GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE 2>/dev/null || true
# Pin the config files to nothing rather than unsetting the pointers, which would
# just restore the real ~/.gitconfig. The -c overrides below are belt-and-braces.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# Trap first, then create — an interrupt between the two mktemp calls must not
# leak, and cleanup is written to tolerate unset variables.
D=""; ND=""
cleanup() { [ -n "${D:-}" ] && rm -rf "$D"; [ -n "${ND:-}" ] && rm -rf "$ND"; return 0; }
trap cleanup EXIT
# An interrupt must stop the run, not delete the fixtures and keep going.
trap 'cleanup; exit 130' INT TERM
D="$(mktemp -d)" || exit 1
ND="$(mktemp -d)" || exit 1
# A failed mktemp would leave the fixture root empty, and `git -C ""` runs in the
# INVOKING repository — which would commit the user's working tree. Refuse.
if [ -z "$D" ] || [ ! -d "$D" ] || [ -z "$ND" ] || [ ! -d "$ND" ]; then
  check "G0 hermetic git fixture has a usable temp root" FAIL
  echo "----"
  echo "test-edit-landing-audit: $PASS PASS / $FAIL FAIL"
  exit 1
fi
# Ambient global git config must not decide this suite's verdict: signing would
# fail the baseline commit, a global hooks path could run arbitrary hooks, and a
# personal core.excludesFile would perturb --exclude-standard.
GIT_HARDENED() {  # $1 = repo root, rest = git args
  local root="$1"; shift
  [ -n "$root" ] && [ -d "$root" ] || return 1
  git -C "$root" -c user.email=t@example.invalid -c user.name=zensu-test \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null -c core.excludesFile=/dev/null "$@"
}
GIT() { GIT_HARDENED "${D:-}" "$@"; }
NDGIT() { GIT_HARDENED "${ND:-}" "$@"; }

git init -q --template= "$D" >/dev/null 2>&1
mkdir -p "$D/src/nested" || exit 1
printf 'v1\n' > "$D/tracked-modified.txt"
printf 'v1\n' > "$D/untouched.txt"
printf 'v1\n' > "$D/src/nested/tracked-sub.txt"
printf 'ignored.txt\n' > "$D/.gitignore"
GIT add -A >/dev/null 2>&1
GIT commit -qm base >/dev/null 2>&1

if ! GIT rev-parse HEAD >/dev/null 2>&1; then
  check "G0 hermetic git fixture committed a baseline" FAIL
  echo "  ---- fixture unusable: the G1-G9 recipe checks below cannot be evaluated ----"
  for skipped in \
    "G1 non-empty union" "G1b non-ASCII path quoting" "G2 tracked modification landed" "G3 repo-root-relative subdirectory path" \
    "G4 new untracked landed" "G5 staged-but-uncommitted via diff half" "G6 unchanged file absent" \
    "G7 gitignored write absent" "G8 unanchored ls-files is cwd-scoped" \
    "G8b cwd-relative vs repo-root-relative path base" "G8c basename component boundary" \
    "G8c2 metacharacter basename" "G8c3 ambiguous basename" \
    "G8d claim normalization" "G8e directory claim resolution" "G9 mid-run commit range"; do
    check "$skipped (unevaluated — fixture unusable)" FAIL
  done
else
  check "G0 hermetic git fixture committed a baseline" PASS

  # Session edits: a real tracked change at the root and in a subdirectory, a new
  # untracked file, a staged-but-uncommitted file, a gitignored write, and one
  # file whose "replacement" matched nothing.
  printf 'v2\n' > "$D/tracked-modified.txt"
  printf 'v2\n' > "$D/src/nested/tracked-sub.txt"
  printf 'new\n' > "$D/new-untracked.txt"
  printf 'staged\n' > "$D/staged-new.txt"
  printf 'ignored\n' > "$D/ignored.txt"
  # Boundary fixture for the documented basename rule: `types.ts` must resolve to
  # src/types.ts and never to src/subtypes.ts.
  printf 'v2\n' > "$D/src/types.ts"
  printf 'v2\n' > "$D/src/subtypes.ts"
  printf 'v2\n' > "$D/src/a+b(1)|c.ts"
  # Glob metacharacters: only a QUOTED case pattern matches these literally, so
  # this arm fails the moment the quoting is dropped.
  printf 'v2\n' > "$D/src/a?c.ts"
  printf 'v2\n' > "$D/src/abc.ts"
  # Non-ASCII: git C-quotes this unless core.quotePath=false is set.
  printf 'v2\n' > "$D/src/äbc.ts"
  mkdir -p "$D/src/v1.2" "$D/a" "$D/b"
  printf 'v2\n' > "$D/src/v1.2/mod.ts"
  printf 'v2\n' > "$D/a/dup.ts"
  printf 'v2\n' > "$D/b/dup.ts"
  GIT add staged-new.txt >/dev/null 2>&1

  UNION="$( { GIT diff --name-only HEAD; GIT ls-files --others --exclude-standard; } 2>/dev/null | sort -u )"
  # Same `-qxF --` form the skill mandates, so the walk exercises the real recipe.
  landed() { printf '%s\n' "$UNION" | grep -qxF -- "$1"; }

  [ -n "$UNION" ]; check "G1 enumeration produced a non-empty union (negative pins below are meaningful)" "$(verdict $?)"
  # The quoting rule the skill mandates, exercised: without core.quotePath=false
  # the same file comes back as "src/\303\244bc.ts" and never matches its claim.
  QUOTED="$(GIT ls-files --others --exclude-standard 2>/dev/null | grep -c '\\3')"
  UNQUOTED="$(GIT -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null | grep -cxF 'src/äbc.ts')"
  { [ "$QUOTED" -ge 1 ] && [ "$UNQUOTED" -eq 1 ]; }
  check "G1b a non-ASCII path is C-quoted by default and plain only with core.quotePath=false" "$(verdict $?)"
  landed "tracked-modified.txt"; check "G2 tracked file with a real change is reported as landed" "$(verdict $?)"
  # git speaks repo-root-relative, never basenames — the normalization rule A8 pins.
  landed "src/nested/tracked-sub.txt" && ! landed "tracked-sub.txt"
  check "G3 a subdirectory change is reported repo-root-relative, not as a basename" "$(verdict $?)"
  landed "new-untracked.txt"; check "G4 new untracked non-ignored file is reported as landed" "$(verdict $?)"
  # Staged-but-uncommitted proves BOTH commands are needed: ls-files --others has
  # dropped it, diff --name-only HEAD still carries it.
  landed "staged-new.txt" && ! GIT ls-files --others --exclude-standard | grep -qxF "staged-new.txt"
  check "G5 staged-but-uncommitted file survives only via the diff half of the union" "$(verdict $?)"
  # Negative pins need a positive control, or a fixture that silently degraded
  # would satisfy them by having produced nothing at all.
  GIT ls-files --error-unmatch untouched.txt >/dev/null 2>&1 && ! landed "untouched.txt"
  check "G6 a tracked, genuinely unchanged file is absent from the union (EDIT NOT LANDED)" "$(verdict $?)"
  [ -f "$D/ignored.txt" ] && GIT check-ignore -q -- ignored.txt && ! landed "ignored.txt"
  check "G7 a written, check-ignore-confirmed file is absent from the union (exemption X1 covers it)" "$(verdict $?)"
  # Unanchored ls-files is cwd-scoped — the reason A9 pins `git -C`. The positive
  # half proves the command actually ran and listed its own directory.
  printf 'sub\n' > "$D/src/nested/sub-untracked.txt"
  CWD_SCOPED="$( cd "$D/src/nested" && git -c core.excludesFile=/dev/null -c core.hooksPath=/dev/null ls-files --others --exclude-standard 2>/dev/null )"
  printf '%s\n' "$CWD_SCOPED" | grep -qxF "sub-untracked.txt" \
    && ! printf '%s\n' "$CWD_SCOPED" | grep -qxF "new-untracked.txt"
  check "G8 unanchored ls-files lists its own directory but misses a root-level new file" "$(verdict $?)"
  # ...and it prints CWD-relative paths, so the same file carries a different
  # spelling than the repo-root-anchored half — the path-base mix the audit's
  # `git -C "$TOP"` rule exists to prevent.
  ROOT_SCOPED="$(GIT ls-files --others --exclude-standard 2>/dev/null)"
  printf '%s\n' "$ROOT_SCOPED" | grep -qxF "src/nested/sub-untracked.txt" \
    && ! printf '%s\n' "$CWD_SCOPED" | grep -qxF "src/nested/sub-untracked.txt"
  check "G8b the same new file is repo-root-relative from the root and cwd-relative from a subdirectory" "$(verdict $?)"
  # The documented claim-resolution rules, exercised rather than only quoted.
  # Fixed-string, exactly as the skill mandates — building an ERE here would
  # both contradict the rule and mis-resolve a claim containing ( ) | + ?.
  resolve_basename() {
    printf '%s\n' "$UNION" | while IFS= read -r l; do
      case "$l" in "$1"|*"/$1") printf '%s\n' "$l";; esac
    done
  }
  [ "$(resolve_basename 'types.ts' | tr '\n' ' ')" = "src/types.ts " ]
  check "G8c a bare basename resolves on a component boundary (types.ts is not subtypes.ts)" "$(verdict $?)"
  # A metacharacter-laden basename must resolve by data, not by pattern.
  [ "$(resolve_basename 'a+b(1)|c.ts' | tr '\n' ' ')" = "src/a+b(1)|c.ts " ] \
    && [ "$(resolve_basename 'a?c.ts' | tr '\n' ' ')" = "src/a?c.ts " ]
  check "G8c2 basenames with regex AND glob metacharacters resolve to themselves only" "$(verdict $?)"
  # Ambiguity is UNVERIFIED, not landed: two matches must not read as resolved.
  [ "$(resolve_basename 'dup.ts' | wc -l | tr -d ' ')" -eq 2 ]
  check "G8c3 an ambiguous basename resolves to more than one line (UNVERIFIED, not landed)" "$(verdict $?)"
  # Both halves of the documented normalization, each with its negative arm.
  # Literal parameter expansion, not sed with an interpolated path.
  normalize_claim() { local c="${1#"$D/"}"; printf '%s' "${c#./}"; }
  { landed "$(normalize_claim './tracked-modified.txt')" \
    && landed "$(normalize_claim "$D/tracked-modified.txt")" \
    && ! landed './tracked-modified.txt' \
    && ! landed "$D/tracked-modified.txt"; }
  check "G8d ./-prefixed and absolute claims land only after normalization" "$(verdict $?)"
  # A directory claim needs AT LEAST ONE file beneath it — with a boundary arm
  # so a naive prefix match (src/nest matching src/nested/...) cannot pass.
  # Fixed-string like its basename sibling — a claim may carry metacharacters.
  resolve_dir() {
    local d="${1%/}" n=0
    printf '%s\n' "$UNION" | while IFS= read -r l; do
      case "$l" in "$d"/*) printf 'x\n';; esac
    done | wc -l | tr -d ' '
  }
  { [ "$(resolve_dir 'src/nested')" -ge 1 ] \
    && [ "$(resolve_dir 'src/nest')" -eq 0 ] \
    && [ "$(resolve_dir 'src/v1.2')" -eq 1 ] \
    && [ "$(resolve_dir 'src/v1x2')" -eq 0 ] \
    && [ "$(resolve_dir 'no/such/dir')" -eq 0 ]; }
  check "G8e a directory claim resolves fixed-string on a path boundary and only when something beneath it changed" "$(verdict $?)"
  # After a mid-run commit only the baseline range still shows the change.
  BASE_SHA="$(GIT rev-parse HEAD)"
  GIT add -A >/dev/null 2>&1
  GIT commit -qm session >/dev/null 2>&1
  POST_WORKTREE="$(GIT diff --name-only HEAD 2>/dev/null)"
  POST_RANGE="$(GIT diff --name-only "$BASE_SHA"..HEAD 2>/dev/null)"
  [ -z "$POST_WORKTREE" ] && printf '%s\n' "$POST_RANGE" | grep -qxF "tracked-modified.txt"
  check "G9 after a mid-run commit only the baseline..HEAD range still shows the change" "$(verdict $?)"
fi

# Unborn HEAD: `diff HEAD` is fatal, which is why the audit documents a branch.
git init -q --template= "$ND" >/dev/null 2>&1
printf 'x\n' > "$ND/fresh.txt"
printf 'y\n' > "$ND/staged-fresh.txt"
NDGIT add staged-fresh.txt >/dev/null 2>&1
if NDGIT rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # The staged file is why the documented form needs --cached: --others alone
  # has already dropped it, and there is no HEAD to diff against.
  ! NDGIT diff --name-only HEAD >/dev/null 2>&1 \
    && NDGIT ls-files --cached --others --exclude-standard 2>/dev/null | grep -qxF "fresh.txt" \
    && NDGIT ls-files --cached --others --exclude-standard 2>/dev/null | grep -qxF "staged-fresh.txt" \
    && ! NDGIT ls-files --others --exclude-standard 2>/dev/null | grep -qxF "staged-fresh.txt"
  check "G10 unborn HEAD: diff HEAD fails while the documented cached+others form works" "$(verdict $?)"
else
  check "G10 unborn HEAD: diff HEAD fails while the documented cached+others form works" FAIL
fi
# The non-git fallback is a pure content pin — it must never be made conditional
# on where TMPDIR happens to live.
printf '%s' "$BLOCK" | grep -qF 'Outside a git work tree' && printf '%s' "$BLOCK" | grep -qF 'SESSION_EPOCH'
check "G11 audit documents the non-git mtime fallback" "$(verdict $?)"

# The two skip-branch label lists are what keep every path at the same total;
# a check added to a success branch without its label silently shrinks coverage.
EXPECTED_CHECKS=104
if [ "$((PASS + FAIL))" -ne "$EXPECTED_CHECKS" ]; then
  check "T1 pre-guard check count is $EXPECTED_CHECKS on every branch (got $((PASS + FAIL)) — update the skip lists)" FAIL
else
  check "T1 pre-guard check count is $EXPECTED_CHECKS on every branch" PASS
fi

echo "----"
echo "test-edit-landing-audit: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
