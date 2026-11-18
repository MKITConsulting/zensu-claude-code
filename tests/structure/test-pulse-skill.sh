#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_DIR/skills/pulse/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
has() { [ -f "$1" ] && grep -qF -- "$2" "$1" && echo PASS || echo FAIL; }
lacks() { [ -f "$1" ] && ! grep -qF -- "$2" "$1" && echo PASS || echo FAIL; }
section_block() {
  awk -v heading="$2" -v nth="$3" '
    index($0, heading) == 1 { on = 1; next }
    on && /^## / { exit }
    on && /^   ```bash$/ { seen++; inblock = (seen == nth); next }
    on && inblock && /^   ```$/ { exit }
    on && inblock { sub(/^   /, ""); print }
  ' "$1"
}
in_order() {
  local block="$1" previous=0 line number
  shift
  for line in "$@"; do
    number="$(printf '%s\n' "$block" | grep -nxF -- "$line" | head -1 | cut -d: -f1)"
    [ -n "$number" ] && [ "$number" -gt "$previous" ] || { echo FAIL; return; }
    previous="$number"
  done
  echo PASS
}
all_in() {
  local text="$1" needle
  shift
  for needle in "$@"; do
    printf '%s' "$text" | grep -qF -- "$needle" || { echo FAIL; return; }
  done
  echo PASS
}

if [ ! -f "$SKILL" ]; then
  check "PS1 skills/pulse/SKILL.md exists" FAIL
  echo "----"; echo "test-pulse-skill: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "PS1 skills/pulse/SKILL.md exists" PASS

START_BLOCK="$(section_block "$SKILL" "## Phase 1: Session Start" 2)"
RECORD_BLOCK="$(section_block "$SKILL" "## Phase 1: Session Start" 3)"
END_BLOCK="$(section_block "$SKILL" "## Phase 3: Session End & Review" 1)"
NORMALIZED="$(tr -s '[:space:]' ' ' < "$SKILL")"

check "PS2 Phase 1 reads the start commit in a call of its own" "$(has "$SKILL" "git rev-parse --verify 'HEAD^{commit}'")"
check "PS3 Phase 1 starts the session with --minimal-json and quoted repository values" "$(in_order "$START_BLOCK" \
  "start_sha='<start-sha>'" \
  'branch="$(git branch --show-current)"' \
  'top="$(git rev-parse --show-toplevel)" || exit 1' \
  'zensu pulse start --minimal-json --head-sha "$start_sha" --branch "$branch" --project "$top"')"
check "PS3b Phase 1 records the start commit under the session id in the git directory and keeps the first record" "$(in_order "$RECORD_BLOCK" \
  "session_id='<session-id>'" \
  "start_sha='<start-sha>'" \
  'd="$(git rev-parse --absolute-git-dir)/zensu-pulse" || exit 1' \
  'mkdir -p "$d" || exit 1' \
  "[ -e \"\$d/\$session_id\" ] || printf '%s\\n' \"\$start_sha\" > \"\$d/\$session_id\"")"
check "PS4 a tracking_disabled start is a clean no-op: no end, no summary, no retry" "$(all_in "$NORMALIZED" \
  '- `"status": "tracking_disabled"`: Pulse tracking is off in the user'"'"'s Zensu privacy settings.' \
  'no `pulse end`, no `pulse summary`, no retry')"
if [ "$(all_in "$NORMALIZED" \
    '`--minimal-json` prints one indented JSON object and nothing else, as the example flow below shows.' \
    '- `"id": "<uuid>"`: the session runs. Keep the id as `<session-id>` and record the session in step 4.')" = PASS ] \
  && ! grep -qF -- '{"id"' "$SKILL" && ! grep -qF -- '{"status"' "$SKILL"; then
  check "PS4b the skill writes the --minimal-json answer as the indented object the CLI prints, one member per case" PASS
else
  check "PS4b the skill writes the --minimal-json answer as the indented object the CLI prints, one member per case" FAIL
fi
check "PS5 Phase 3 runs only after a start that returned a session id" "$(has "$SKILL" 'Run this phase only when Phase 1 kept a `<session-id>`.')"
check "PS5b a lost session id is asked for, never guessed, and the start commit never comes from a later HEAD" "$(all_in "$NORMALIZED" \
  'When the `<session-id>` is no longer in your context, never guess it: list the `zensu-pulse` directory inside `git rev-parse --absolute-git-dir`' \
  'show the names to the user and ask which session to end.' \
  'Never take the start commit from the current HEAD, from a `zensu: pulse context` line or from a parent commit: the call below reads it from the record.')"
check "PS6 Phase 3 reads the start commit from the record, lists the paths, skips directory entries and untracked files older than the record, counts, stops above 1000 and on unconfirmed commits of others, then ends and drops the record" "$(in_order "$END_BLOCK" \
  "session_id='<session-id>'" \
  "include_other_commits='no'" \
  'top="$(git rev-parse --show-toplevel)" || exit 1' \
  'mark="$(git -C "$top" rev-parse --absolute-git-dir)/zensu-pulse/$session_id"' \
  'start_sha="$(cat "$mark")" || exit 1' \
  't="$(mktemp)" || exit 1' \
  'u="$(mktemp)" || { rm -f "$t"; exit 1; }' \
  "trap 'rm -f \"\$t\" \"\$u\"' EXIT" \
  'git -C "$top" diff -z --name-only --no-renames "$start_sha" -- >| "$t" || exit 1' \
  'git -C "$top" ls-files -z --others --exclude-standard >| "$u" || exit 1' \
  'changed=()' \
  "while IFS= read -r -d '' p; do changed+=(--changed-file \"\$p\"); done < \"\$t\"" \
  "while IFS= read -r -d '' p; do [ \"\${p%/}\" = \"\$p\" ] && [ \"\$top/\$p\" -nt \"\$mark\" ] && changed+=(--changed-file \"\$p\"); done < \"\$u\"" \
  'n=$(( ${#changed[@]} / 2 ))' \
  'echo "changed paths: $n"' \
  '[ "$n" -le 1000 ] || exit 1' \
  "others=''" \
  "git -C \"\$top\" merge-base --is-ancestor \"\$start_sha\" HEAD || others='the start commit is no longer in the history of HEAD'" \
  'me="$(git -C "$top" config user.email)"' \
  'a="$(git -C "$top" log --format=%ae "$start_sha"..HEAD | grep -vixF -- "$me" | sort -u | paste -sd , -)"' \
  "[ -z \"\$a\" ] || others=\"\${others:+\$others; }commits since the start name \$a, and git config user.email is '\$me'\"" \
  '[ -z "$others" ] || [ "$include_other_commits" = yes ] || { echo "other commits: $others"; exit 1; }' \
  'zensu pulse end "$session_id" --minimal-json "${changed[@]}" && rm -f "$mark"')"
if [ "$(printf '%s\n' "$END_BLOCK" | tail -1)" = 'zensu pulse end "$session_id" --minimal-json "${changed[@]}" && rm -f "$mark"' ] \
  && ! printf '%s\n' "$END_BLOCK" | grep -qF -- "<start-sha>"; then
  check "PS7 pulse end is the last command of the Phase 3 block, which takes the start commit only from the record" PASS
else
  check "PS7 pulse end is the last command of the Phase 3 block, which takes the start commit only from the record" FAIL
fi
SYNTAX_BAD=""
syntax_of() {
  [ -n "$2" ] || { SYNTAX_BAD="$SYNTAX_BAD missing:$1"; return; }
  printf '%s\n' "$2" | bash -n 2>/dev/null || SYNTAX_BAD="$SYNTAX_BAD bash:$1"
  if command -v zsh >/dev/null 2>&1; then
    printf '%s\n' "$2" | zsh -n 2>/dev/null || SYNTAX_BAD="$SYNTAX_BAD zsh:$1"
  fi
}
syntax_of start "$START_BLOCK"
syntax_of record "$RECORD_BLOCK"
syntax_of end "$END_BLOCK"
[ -z "$SYNTAX_BAD" ] && check "PS8 the start, record and end blocks parse under bash -n, and under zsh -n where zsh exists" PASS \
  || check "PS8 a block is missing or does not parse:$SYNTAX_BAD" FAIL
check "PS9 a tracking_disabled end skips the summary" "$(all_in "$NORMALIZED" \
  '`"status": "tracking_disabled"`: Pulse tracking was switched off during the session, so nothing was recorded; tell the user in one sentence and skip the summary.' \
  'Unless step 2 answered `tracking_disabled`, run `zensu pulse summary <session-id>`')"
check "PS10 Phase 3 names the limits of a session end" "$(has "$SKILL" 'Zensu takes at most 1000 paths, each relative to the repository root, at most 500 bytes long, without a backslash and without control or invisible formatting characters.')"
LEGACY=""
for legacy in '--changed-files' 'HEAD~1' '--json'; do
  grep -qF -- "$legacy" "$SKILL" && LEGACY="$LEGACY $legacy"
done
[ -z "$LEGACY" ] && check "PS11 the skill keeps no legacy --changed-files, no HEAD~1 base and no raw --json" PASS \
  || check "PS11 the skill keeps a legacy form:$LEGACY" FAIL
check "PS12 Phase 3 bounds the untracked files to the session, skips nested repositories and names the paths other commits bring in" "$(all_in "$NORMALIZED" \
  'It skips each entry that ends in `/`, the form in which the untracked listing shows a nested repository or worktree, because Zensu refuses such a path.' \
  'A pull, merge, rebase or branch switch during the session adds every path its commits changed, which is why the call stops when the start commit left the history or a commit since it names an author other than `git config user.email`.' \
  'An untracked file counts only when its modification time is later than the record'"'"'s, so a file that stayed untouched since before the session is never sent.')"
check "PS13 a failed end leaves the session open and names what to do for the count, other commits, a refused command line, a missing record and a request error" "$(all_in "$NORMALIZED" \
  'When the call fails, the session stays open:' \
  '- It printed `changed paths:` with more than 1000: tell the user the count, and drop paths only when they ask you to.' \
  '- It printed `other commits:`: tell the user what it printed and that the paths may include changes they did not make themselves; their own amend, reset or rebase of the start commit, or their own commits under another address, bring in none. Run the call again with `include_other_commits='"'"'yes'"'"'` only when they confirm.' \
  '- The shell reported the argument list as too long: the operating system refused the command line before anything reached Zensu. A Windows command line holds at most 32,767 characters and each path takes its length plus 16, so this can happen there well below 1000 paths.' \
  '- The record is missing: Phase 1 did not record this session, so tell the user and end nothing.' \
  '- `Pulse request failed` or `invalid Pulse response`: run `zensu auth status`; when it shows no valid login, run `zensu auth login` and run the call again. Otherwise run the call once more with `--minimal-json` removed, which prints the detailed error')"
if [ "$(all_in "$NORMALIZED" \
    'It records only while Pulse tracking is on in your Zensu privacy settings, and new accounts start with it off.' \
    'Tracking runs only while Pulse tracking is on in the user'"'"'s Zensu privacy settings, and new accounts start with it off;' \
    '**Tracking**: Only while Pulse tracking is on in your Zensu privacy settings; new accounts start with it off')" = PASS ] \
  && [ "$(lacks "$SKILL" 'Off until you turn it on')" = PASS ] \
  && [ "$(lacks "$SKILL" 'has turned it on')" = PASS ] \
  && [ "$(lacks "$SKILL" 'the user turned tracking off')" = PASS ]; then
  check "PS14 the skill says new accounts start with tracking off and never that every user turned it on or off" PASS
else
  check "PS14 the skill says new accounts start with tracking off and never that every user turned it on or off" FAIL
fi

HOOK="$PLUGIN_DIR/hooks/session-start-pulse.sh"
SETUP="$PLUGIN_DIR/skills/setup/SKILL.md"
CONFIG="$PLUGIN_DIR/docs/configuration.md"
README="$PLUGIN_DIR/README.md"
if [ "$(has "$HOOK" 'echo "zensu: pulse context — HEAD=$HEAD branch=$BRANCH"')" = PASS ] \
  && [ "$(has "$HOOK" 'echo "zensu: no commit yet, pulse context skipped"')" = PASS ] \
  && [ "$(has "$HOOK" 'echo "zensu: not a git repository, pulse context skipped"')" = PASS ] \
  && [ "$(lacks "$HOOK" 'pulse session')" = PASS ]; then
  check "PC1 the SessionStart hook prints a pulse context line, names a repository without a commit apart from no repository, and never claims a session" PASS
else
  check "PC1 the SessionStart hook prints a pulse context line, names a repository without a commit apart from no repository, and never claims a session" FAIL
fi
if [ "$(has "$SETUP" '| SessionStart pulse context line | `hooks.pulseSession` | bool | `true` |')" = PASS ] \
  && tr -s '[:space:]' ' ' < "$SETUP" | grep -qF -- '`hooks.pulseSession` controls only the `zensu: pulse context — HEAD=… branch=…` line the SessionStart hook prints. Pulse tracking itself is the tracking setting in the user'"'"'s Zensu privacy settings: this key neither turns it on nor off, and `/zensu:pulse` does not read it.' \
  && [ "$(lacks "$SETUP" 'Pulse telemetry')" = PASS ]; then
  check "PC2 /zensu:setup labels hooks.pulseSession as the context line and says it never controls Pulse tracking" PASS
else
  check "PC2 /zensu:setup labels hooks.pulseSession as the context line and says it never controls Pulse tracking" FAIL
fi
if [ "$(has "$CONFIG" '| `session-start-pulse.sh` | SessionStart | `pulseSession` | Prints the `zensu: pulse context — HEAD=… branch=…` line whenever a session starts, resumes, is cleared or is compacted, with the HEAD of that moment. It starts no Pulse session and runs no `zensu` command. |')" = PASS ] \
  && [ "$(has "$CONFIG" '| `pulseSession` | `session-start-pulse.sh` | Skips the `zensu: pulse context — HEAD=… branch=…` line at session start. It controls only that line, never Pulse tracking,')" = PASS ]; then
  check "PC3 docs/configuration.md describes the hook and hooks.pulseSession as the context line only, printed at every session start" PASS
else
  check "PC3 docs/configuration.md describes the hook and hooks.pulseSession as the context line only, printed at every session start" FAIL
fi
if [ "$(has "$README" '| `/zensu:pulse` | HEAD SHA, branch, **the absolute path of your project root**, an optional product id and, at the end, the paths of the tracked files that differ from the start commit, those that other authors'"'"' commits brought in only after you confirm them, and **of the untracked, non-ignored files created or changed during the session** |')" = PASS ] \
  && [ "$(lacks "$README" 'pulse banner')" = PASS ] \
  && [ "$(lacks "$CONFIG" 'pulse banner')" = PASS ]; then
  check "PC4 the README privacy row names the session-bound untracked paths, and no doc keeps the pulse banner name" PASS
else
  check "PC4 the README privacy row names the session-bound untracked paths, and no doc keeps the pulse banner name" FAIL
fi

echo "----"
echo "test-pulse-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
