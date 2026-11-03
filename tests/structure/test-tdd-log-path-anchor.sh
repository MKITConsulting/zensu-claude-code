#!/bin/bash
set -u

# Pins the narrative-log path convention: the /zensu:build narrative log MUST be
# anchored to the bound project root (`zensu-log.sh --project-root`) so appends are cwd-independent.
# Guards against regression of the relative-path bug where an append issued from a
# subdirectory failed with: no such file or directory: .zensu/logs/..._build-....log

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$PLUGIN_DIR/tests/structure/lib-skill-text.sh"
SKILL="$(skill_text_file "$PLUGIN_DIR/skills/build")"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL" ]; then
  check "L0 skills/build/SKILL.md exists" FAIL
  echo "----"; echo "test-tdd-log-path-anchor: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "L0 skills/build/SKILL.md exists" PASS

# L1: the Phase 2 create mkdir is anchored to the bound project root
if grep -Fq 'mkdir -p "{project_root}/.zensu/logs"' "$SKILL"; then
  check "L1 Phase 2 mkdir anchored to {project_root}" PASS
else
  check "L1 Phase 2 mkdir anchored to {project_root}" FAIL
fi

# L2: {log_file} is defined as the anchored absolute path
if grep -Fq '`{log_file}` denotes `"{project_root}/.zensu/logs/{SESSION_TS}_build-{slug}.log"`' "$SKILL"; then
  check "L2 {log_file} defined as anchored absolute path" PASS
else
  check "L2 {log_file} defined as anchored absolute path" FAIL
fi

# L3 (negative): no redirect (> or >>) targets a bare relative .zensu/logs/ path.
# Anchored redirects go to {log_file} or "{project_root}/..." and are exempt.
if grep -Eq '>>?[[:space:]]*"?\.zensu/logs/' "$SKILL"; then
  check "L3 no bare-relative .zensu/logs redirect remains" FAIL
else
  check "L3 no bare-relative .zensu/logs redirect remains" PASS
fi

if grep -Fq '`{plan_file}` its sibling `"{project_root}/.zensu/plans/{SESSION_TS}_build-{slug}.md"`' "$SKILL"; then
  check "L4 {plan_file} defined as the anchored absolute sibling" PASS
else
  check "L4 {plan_file} defined as the anchored absolute sibling" FAIL
fi

PHASE0="$(awk '/^## Phase 0: Pre-flight$/{f=1;next} f&&/^## /{exit} f' "$SKILL")"
if printf '%s' "$PHASE0" | grep -Fq 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --project-root` prints it' \
  && printf '%s' "$PHASE0" | grep -Fq 'Keep the printed absolute path as `{project_root}`' \
  && printf '%s' "$PHASE0" | grep -Fq 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-work-tree)"' \
  && printf '%s' "$PHASE0" | grep -Fq 'Keep the printed path as `{work_tree}`' \
  && printf '%s' "$PHASE0" | grep -Fq 'BASELINE_SHA=$(git -C "{work_tree}" rev-parse --verify --quiet HEAD)' \
  && ! printf '%s' "$PHASE0" | grep -Fq 'BASELINE_SHA=$(git -C "{project_root}"'; then
  check "L5 Phase 0 reads {project_root} from --project-root, {work_tree} from --chain-work-tree, and takes the baseline from the work tree" PASS
else
  check "L5 Phase 0 reads {project_root} from --project-root, {work_tree} from --chain-work-tree, and takes the baseline from the work tree" FAIL
fi

if grep -Fq 'CLAUDE_PROJECT_DIR="{project_root}" CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" append --truncate --log {log_file}' "$SKILL"; then
  check "L6 the Phase 2 --truncate binds its destructive write to {project_root}" PASS
else
  check "L6 the Phase 2 --truncate binds its destructive write to {project_root}" FAIL
fi

if grep -Fq 'zensu-edit-landing.sh" --log {log_file} --project "{project_root}"' "$SKILL" \
  && grep -Fq 'it must name a plan inside `{project_root}/.zensu/plans/`' "$SKILL" \
  && grep -Fq 'TOP="$(git -C "{project_root}" rev-parse --show-toplevel)"' "$SKILL"; then
  check "L7 the edit-landing audit, the step 10.1 plan bound and TOP all derive from {project_root}" PASS
else
  check "L7 the edit-landing audit, the step 10.1 plan bound and TOP all derive from {project_root}" FAIL
fi

SELF_REVIEW="$PLUGIN_DIR/skills/self-review/SKILL.md"
if grep -Fq 'PROJECT_ROOT="$(CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "$ROOT/hooks/lib/zensu-log.sh" --project-root)"' "$SELF_REVIEW" \
  && grep -Fq 'TOP="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel)"' "$SELF_REVIEW" \
  && grep -Fq '[ -n "$PROJECT_ROOT" ] && [ -n "$TOP" ] && [ -d "$TOP" ]' "$SELF_REVIEW" \
  && grep -Fq -- '--report --log <run-log> --root "$TOP"' "$SELF_REVIEW"; then
  check "L9 /zensu:self-review derives TOP and its ledger root from --project-root behind a three-part guard" PASS
else
  check "L9 /zensu:self-review derives TOP and its ledger root from --project-root behind a three-part guard" FAIL
fi

SELF_REVIEW_FIX="$(awk '/^## Phase 4: Fix Round or Finalize$/{f=1;next} f&&/^## /{exit} f' "$SELF_REVIEW")"
SELF_REVIEW_FIX_FLAT="$(printf '%s' "$SELF_REVIEW_FIX" | tr '\n' ' ' | sed 's/  */ /g')"
if printf '%s' "$SELF_REVIEW_FIX_FLAT" | grep -Fq '`cd "<project dir>" && <command>`, where `<project dir>` is what the Phase 1 `--chain-work-tree` call prints with `--project-dir` added' \
  && ! printf '%s' "$SELF_REVIEW_FIX_FLAT" | grep -Fq 'cd "<project root>"'; then
  check "L9b the /zensu:self-review fix round runs its project commands in the directory --chain-work-tree --project-dir prints" PASS
else
  check "L9b the /zensu:self-review fix round runs its project commands in the directory --chain-work-tree --project-dir prints" FAIL
fi

CONVERGE_PHASE0="$(awk '/^## Phase 0: Locate the plan$/{f=1;next} f&&/^## /{exit} f' "$PLUGIN_DIR/skills/converge/SKILL.md")"
if printf '%s' "$CONVERGE_PHASE0" | grep -Fq '`"<project root>"/.zensu/plans/*_build-*.md`' \
  && printf '%s' "$CONVERGE_PHASE0" | grep -Fq '`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --project-root`' \
  && printf '%s' "$CONVERGE_PHASE0" | grep -Fq 'ask for the plan path rather than'; then
  check "L10 /zensu:converge discovers plans under the --project-root path and asks rather than guessing" PASS
else
  check "L10 /zensu:converge discovers plans under the --project-root path and asks rather than guessing" FAIL
fi

if grep -Fq 'as `cd "{project_dir}" && <command>`, where `{project_dir}` is the path `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" --chain-work-tree --project-dir` prints' "$SKILL" \
  && ! grep -Fq 'cd "{project_root}" &&' "$SKILL" \
  && ! grep -Fq 'cd -- "{project_root}"' "$SKILL" \
  && ! grep -Fq 'cd -- "{project_dir}"' "$SKILL" \
  && grep -Fq '(the Phase 4 test runs, the build, `{coverage_cmd}` and the step 5 `stat`)' "$SKILL"; then
  check "L11 /zensu:build runs every project command it prescribes in the directory --chain-work-tree --project-dir prints" PASS
else
  check "L11 /zensu:build runs every project command it prescribes in the directory --chain-work-tree --project-dir prints" FAIL
fi

VERIFY="$PLUGIN_DIR/skills/verify-feature/SKILL.md"
if grep -Fq '`ANCHOR="$(CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --project-root)" && [ -n "$ANCHOR" ] && GIT_ROOT="$(git -C "$ANCHOR" rev-parse --show-toplevel)"`' "$VERIFY" \
  && grep -Fq 'as `cd "<that root>" && …`' "$VERIFY" \
  && ! grep -Fq 'cd -- "<that root>"' "$VERIFY" \
  && grep -Fq 'that `cd` is the one prefix a recorded `down` may carry' "$VERIFY" \
  && grep -Fq 'the `cd "<that root>" &&` prefix of Chain mode point 9 is the one exception' "$VERIFY"; then
  check "L12 /zensu:verify-feature --chain resolves its git root from --project-root and runs its commands there" PASS
else
  check "L12 /zensu:verify-feature --chain resolves its git root from --project-root and runs its commands there" FAIL
fi

if grep -Fq '`"{project_root}"/.zensu/plans/*_build-*.md`' "$SKILL" \
  && ! grep -Fq '`{project_root}/.zensu/plans/*_build-*.md`' "$SKILL" \
  && grep -Fq '`"<project root>"/.zensu/plans/*_build-*.md`' "$PLUGIN_DIR/skills/converge/SKILL.md" \
  && ! grep -Fq '`<project root>/.zensu/plans/*_build-*.md`' "$PLUGIN_DIR/skills/converge/SKILL.md"; then
  check "L13 the plan globs of /zensu:build and /zensu:converge keep the pasted root inside double quotes" PASS
else
  check "L13 the plan globs of /zensu:build and /zensu:converge keep the pasted root inside double quotes" FAIL
fi

AMBIENT="$(grep -lF '${CLAUDE_PROJECT_DIR:-.}' "$PLUGIN_DIR"/skills/*/SKILL.md "$PLUGIN_DIR"/skills/*/references/*.md 2>/dev/null)"
SKILL_COUNT="$(ls "$PLUGIN_DIR"/skills/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
if [ -z "$AMBIENT" ] && [ "${SKILL_COUNT:-0}" -gt 1 ]; then
  check "L8 no skill anchors a path on \${CLAUDE_PROJECT_DIR:-.} ($SKILL_COUNT skills scanned)" PASS
else
  check "L8 no skill anchors a path on \${CLAUDE_PROJECT_DIR:-.} (found: ${AMBIENT:-none}; scanned: ${SKILL_COUNT:-0})" FAIL
fi

rm -f "$SKILL"
echo "----"
echo "test-tdd-log-path-anchor: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
