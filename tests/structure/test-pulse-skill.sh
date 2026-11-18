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
  awk -v heading="$2" -v nth="$3" -v indent="${4-   }" '
    index($0, heading) == 1 { on = 1; next }
    on && /^## / { exit }
    on && $0 == indent "```bash" { seen++; inblock = (seen == nth); next }
    on && inblock && $0 == indent "```" { exit }
    on && inblock { if (length(indent) > 0 && index($0, indent) == 1) $0 = substr($0, length(indent) + 1); print }
  ' "$1"
}
exact_block() {
  local block="$1" expected
  shift
  expected="$(printf '%s\n' "$@")"
  [ "$block" = "$expected" ] && echo PASS || echo FAIL
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

VERIFY_BLOCK="$(section_block "$SKILL" "## Phase 1: Session Start" 1)"
START_BLOCK="$(section_block "$SKILL" "## Phase 1: Session Start" 2)"
RECORD_BLOCK="$(section_block "$SKILL" "## Phase 1: Session Start" 3)"
LIST_BLOCK="$(section_block "$SKILL" "## Phase 3: Session End & Review" 1 "")"
END_BLOCK="$(section_block "$SKILL" "## Phase 3: Session End & Review" 1)"
NOPATH_BLOCK="$(section_block "$SKILL" "## Phase 3: Session End & Review" 2)"
NORMALIZED="$(tr -s '[:space:]' ' ' < "$SKILL")"

check "PS2 Phase 1 reads the start commit in a call of its own, in exactly this block" "$(exact_block "$VERIFY_BLOCK" \
  "git rev-parse --verify 'HEAD^{commit}'")"
check "PS3 Phase 1 starts the session with --minimal-json and quoted repository values, in exactly this block" "$(exact_block "$START_BLOCK" \
  "start_sha='<start-sha>'" \
  'branch="$(git branch --show-current)"' \
  'top="$(git rev-parse --show-toplevel)" || exit 1' \
  'zensu pulse start --minimal-json --head-sha "$start_sha" --branch "$branch" --project "$top"')"
check "PS3b Phase 1 records the start commit and the starting worktree under the session id in the common git directory and keeps the first record, in exactly this block" "$(exact_block "$RECORD_BLOCK" \
  "session_id='<session-id>'" \
  "start_sha='<start-sha>'" \
  'top="$(git rev-parse --show-toplevel)" || exit 1' \
  'd="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/zensu-pulse" || exit 1' \
  'mkdir -p "$d" || exit 1' \
  "[ -e \"\$d/\$session_id\" ] || printf '%s\\n%s\\n' \"\$start_sha\" \"\$top\" > \"\$d/\$session_id\"")"
check "PS3c the skill says the record lives in the common git directory that every worktree of the repository shares and names the worktree the session started in" "$(all_in "$NORMALIZED" \
  'The record is a file named after the session id in the repository'"'"'s common git directory, which every worktree of the repository shares, so the session can end in another worktree than the one it started in, and no file listing and no commit can include it.' \
  'Its first line is `<start-sha>` and its second line the top level of the worktree the session started in; Phase 3 reads both back, and the record'"'"'s modification time marks the start of the session.')"
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
check "PS5b a lost session id is asked for with each record's worktree, start commit and start time, never guessed, and the start commit never comes from a later HEAD" "$(all_in "$NORMALIZED" \
  'When the `<session-id>` is no longer in your context, never guess it: list the open sessions of this repository in a call of its own:' \
  'The first directory holds one record for each session a worktree of this repository started and did not end. The second is this worktree'"'"'s own git directory, where Zensu 0.40.2 kept the record; it is the same directory in the main worktree.' \
  'Show the user each session with its start time, start commit and worktree, and ask which session to end; when the call prints no record, no session of this repository is open here, so tell the user and end nothing.' \
  'A session whose worktree no longer exists still ends without any path through the second call of step 1.' \
  'Never take the start commit from the current HEAD, from a `zensu: pulse context` line or from a parent commit: the call below reads it from the record.')"
check "PS16 the lost-id call lists every record with its time and lines, in the common git directory and in this worktree's own git directory, in exactly this block" "$(exact_block "$LIST_BLOCK" \
  'c="$(git rev-parse --path-format=absolute --git-common-dir)/zensu-pulse" || exit 1' \
  'g="$(git rev-parse --absolute-git-dir)/zensu-pulse" || exit 1' \
  "[ ! -d \"\$c\" ] || { ls -lt \"\$c\" && grep -r '' \"\$c\"; }" \
  "[ \"\$g\" = \"\$c\" ] || [ ! -d \"\$g\" ] || { ls -lt \"\$g\" && grep -r '' \"\$g\"; }")"
END_LINES=(
  "session_id='<session-id>'"
  "include_other_worktree='no'"
  "include_other_commits='no'"
  'top="$(git rev-parse --show-toplevel)" || exit 1'
  'mark="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/zensu-pulse/$session_id"'
  'own="$(git -C "$top" rev-parse --absolute-git-dir)/zensu-pulse/$session_id"'
  '[ -f "$mark" ] || mark="$own"'
  'start_sha="$(sed -n 1p "$mark")" || exit 1'
  'began="$(sed 1d "$mark")"'
  "[ -n \"\$began\" ] || [ \"\$mark\" = \"\$own\" ] || began=\"\$(git -C \"\$top\" worktree list --porcelain | sed -n '1s/^worktree //p')\""
  "[ -z \"\$began\" ] || [ \"\$began\" = \"\$top\" ] || [ \"\$include_other_worktree\" = yes ] || { echo \"other worktree: the session started in '\$began', and this is '\$top'\"; exit 1; }"
  "others=''"
  "git -C \"\$top\" merge-base --is-ancestor \"\$start_sha\" HEAD || others='the start commit is no longer in the history of HEAD'"
  'me="$(git -C "$top" config user.email)"'
  'a="$(git -C "$top" log --format=%ae "$start_sha"..HEAD | grep -vixF -- "$me" | sort -u | paste -sd , -)"'
  "[ -z \"\$a\" ] || others=\"\${others:+\$others; }commits since the start name \$a, and git config user.email is '\$me'\""
  '[ -z "$others" ] || [ "$include_other_commits" = yes ] || { echo "other commits: $others"; exit 1; }'
  't="$(mktemp)" || exit 1'
  'u="$(mktemp)" || { rm -f "$t"; exit 1; }'
  'v="$(mktemp)" || { rm -f "$t" "$u"; exit 1; }'
  "trap 'rm -f \"\$t\" \"\$u\" \"\$v\"' EXIT"
  'git -C "$top" diff -z --name-only --no-renames "$start_sha" -- >| "$t" || exit 1'
  'git -C "$top" ls-files -z --others --exclude-standard >| "$u" || exit 1'
  "while IFS= read -r -d '' p; do [ \"\${p%/}\" = \"\$p\" ] && printf '%s/%s\\0' \"\$top\" \"\$p\"; done < \"\$u\" | mark=\"\$mark\" xargs -0 sh -c '[ \"\$#\" -gt 0 ] || exit 0; find \"\$@\" -prune -cnewer \"\$mark\" -print0 || true' sh >| \"\$v\" || exit 1"
  'changed=()'
  "while IFS= read -r -d '' p; do changed+=(--changed-file \"\$p\"); done < \"\$t\""
  "while IFS= read -r -d '' p; do changed+=(--changed-file \"\${p#\"\$top/\"}\"); done < \"\$v\""
  'n=$(( ${#changed[@]} / 2 ))'
  'echo "changed paths: $n"'
  '[ "$n" -le 1000 ] || exit 1'
  'zensu pulse end "$session_id" --minimal-json "${changed[@]}" && rm -f "$mark"'
)
check "PS6 Phase 3 reads the record from the common git directory or the 0.40.2 location, takes a 0.40.2 record's worktree from where it lies, stops on an unconfirmed other worktree and on unconfirmed commits of others before it lists anything, lists the paths, skips directory entries, tests the change times of untracked files in batches, counts, stops above 1000, then ends and drops the record, in exactly this block" "$(exact_block "$END_BLOCK" "${END_LINES[@]}")"
EXPECTED_END="$(printf '%s\n' "${END_LINES[@]}")"
OTHERS_STOP='[ -z "$others" ] || [ "$include_other_commits" = yes ] || { echo "other commits: $others"; exit 1; }'
INSERTED_END="$(printf '%s\n' "$EXPECTED_END" | awk -v after="include_other_commits='no'" -v extra="include_other_commits='yes'" '{ print } $0 == after { print extra }')"
DROPPED_END="$(printf '%s\n' "$EXPECTED_END" | awk -v stop="$OTHERS_STOP" '$0 != stop')"
MOVED_END="$(printf '%s\n' "$EXPECTED_END" | awk -v stop="$OTHERS_STOP" '$0 == stop { held = $0; next } { print } held != "" && !done { print held; done = 1 }')"
if [ "$(exact_block "$EXPECTED_END" "${END_LINES[@]}")" = PASS ] \
  && [ "$(exact_block "$INSERTED_END" "${END_LINES[@]}")" = FAIL ] \
  && [ "$(exact_block "$DROPPED_END" "${END_LINES[@]}")" = FAIL ] \
  && [ "$(exact_block "$MOVED_END" "${END_LINES[@]}")" = FAIL ]; then
  check "PS6b the exact block check passes the pinned block and fails it with a line inserted, dropped or moved" PASS
else
  check "PS6b the exact block check passes the pinned block and fails it with a line inserted, dropped or moved" FAIL
fi
if [ "$(printf '%s\n' "$END_BLOCK" | tail -1)" = 'zensu pulse end "$session_id" --minimal-json "${changed[@]}" && rm -f "$mark"' ] \
  && ! printf '%s\n' "$END_BLOCK" | grep -qF -- "<start-sha>"; then
  check "PS7 pulse end is the last command of the Phase 3 block, which takes the start commit only from the record" PASS
else
  check "PS7 pulse end is the last command of the Phase 3 block, which takes the start commit only from the record" FAIL
fi
check "PS15 the second Phase 3 call ends the session without any path once it finds the record where the first call looks, in exactly this block" "$(exact_block "$NOPATH_BLOCK" \
  "session_id='<session-id>'" \
  'top="$(git rev-parse --show-toplevel)" || exit 1' \
  'mark="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/zensu-pulse/$session_id"' \
  '[ -f "$mark" ] || mark="$(git -C "$top" rev-parse --absolute-git-dir)/zensu-pulse/$session_id"' \
  '[ -f "$mark" ] || exit 1' \
  'zensu pulse end "$session_id" --minimal-json && rm -f "$mark"')"
SYNTAX_BAD=""
syntax_of() {
  [ -n "$2" ] || { SYNTAX_BAD="$SYNTAX_BAD missing:$1"; return; }
  printf '%s\n' "$2" | bash -n 2>/dev/null || SYNTAX_BAD="$SYNTAX_BAD bash:$1"
  if command -v zsh >/dev/null 2>&1; then
    printf '%s\n' "$2" | zsh -n 2>/dev/null || SYNTAX_BAD="$SYNTAX_BAD zsh:$1"
  fi
}
syntax_of verify "$VERIFY_BLOCK"
syntax_of start "$START_BLOCK"
syntax_of record "$RECORD_BLOCK"
syntax_of list "$LIST_BLOCK"
syntax_of end "$END_BLOCK"
syntax_of nopath "$NOPATH_BLOCK"
[ -z "$SYNTAX_BAD" ] && check "PS8 the verify, start, record, list, end and no-path blocks parse under bash -n, and under zsh -n where zsh exists" PASS \
  || check "PS8 a block is missing or does not parse:$SYNTAX_BAD" FAIL
check "PS9 a tracking_disabled end skips the summary" "$(all_in "$NORMALIZED" \
  '`"status": "tracking_disabled"`: Pulse tracking was switched off during the session, so nothing was recorded; tell the user in one sentence and skip the summary.' \
  'Unless step 2 answered `tracking_disabled`, run `zensu pulse summary <session-id>`')"
check "PS10 Phase 3 names the limits of a session end" "$(has "$SKILL" 'Zensu takes at most 1000 paths, each relative to the repository root, at most 500 bytes long, without a backslash and without control or invisible formatting characters.')"
LEGACY=""
for legacy in '--changed-files' 'HEAD~1' '--json' '-nt "$mark"' 'find "$top/$p"'; do
  grep -qF -- "$legacy" "$SKILL" && LEGACY="$LEGACY $legacy"
done
[ -z "$LEGACY" ] && check "PS11 the skill keeps no legacy --changed-files, no HEAD~1 base, no raw --json, no modification-time bound and no find per untracked entry" PASS \
  || check "PS11 the skill keeps a legacy form:$LEGACY" FAIL
check "PS12 Phase 3 stops in another worktree and on other commits before it lists, bounds the untracked files by change time in batches, skips nested repositories and names the paths that pass without the stop" "$(all_in "$NORMALIZED" \
  'It reads the record from the common git directory, or from this worktree'"'"'s own git directory, where Zensu 0.40.2 kept it, and first stops when the session started in another worktree, unless the user confirmed ending it here, and when the start commit left the history or a commit since it names another author, unless the user confirmed that. Only then does it list,' \
  'every untracked file that `.gitignore` does not exclude and whose change time is later than the record'"'"'s modification time.' \
  'It skips each entry that ends in `/`, the form in which the untracked listing shows a nested repository or worktree, because Zensu refuses such a path, and it tests the change times with one `find` per batch of paths rather than one per file.' \
  'The worktree stop compares this worktree'"'"'s top level with the one Phase 1 recorded, because both listings describe the worktree the call runs in: ending a session in another worktree sends that worktree'"'"'s changes. A record of Zensu 0.40.2 names no worktree, so the call takes it from where the record lies: one in the common git directory belongs to the main worktree, which `git worktree list` names first, and one in this worktree'"'"'s own git directory belongs to this worktree.' \
  'A pull, merge, rebase or branch switch during the session adds every path its commits changed, which is why the call stops when the start commit left the history or a commit since it names an author other than `git config user.email`.' \
  'Changes that arrive under that address or without a commit, such as a squash merge, a cherry-pick committed as the user'"'"'s own or files checked out from another branch, name no other author, so the call cannot tell them apart and sends their paths without that stop.' \
  'An untracked file counts only when its change time is later than the record'"'"'s modification time. Creating, copying or unpacking a file during the session gives it such a change time even when it keeps an older modification time, and so does moving it in on a file system that updates the change time on a rename, as APFS does. A file that stayed untouched since before the session is never sent, and neither is one that disappears between the listing and its test, for which `find` prints an error.')"
check "PS13 a failed end leaves the session open and names what to do for another worktree, other commits, the count, a refused command line, a missing record and a request error, and the second call ends the session without paths" "$(all_in "$NORMALIZED" \
  'When the call fails, the session stays open:' \
  '- It printed `other worktree:`: the session started in the first worktree it names, and this call would send the changes of the second. Tell the user both paths. Run the call again with `include_other_worktree='"'"'yes'"'"'` only when they confirm that this worktree holds the session'"'"'s work; when they decline, run it from the worktree the session started in, or end the session with the second call below.' \
  '- It printed `other commits:`: tell the user what it printed and that the paths may include changes they did not make themselves; their own amend, reset or rebase of the start commit, or their own commits under another address, bring in none. Run the call again with `include_other_commits='"'"'yes'"'"'` only when they confirm. When they decline, offer the second call below, which ends the session without any path.' \
  '- It printed `changed paths:` with more than 1000: tell the user the count, and drop paths only when they ask you to, or end the session with the second call below when they choose to send no path.' \
  '- The shell reported the argument list as too long: the operating system refused the command line before anything reached Zensu. A Windows command line holds at most 32,767 characters and each path takes its length plus 16, so this can happen there well below 1000 paths. Tell the user the count, and drop paths only when they ask you to, or end the session with the second call below when they choose to send no path.' \
  '- The record is missing: neither the common git directory nor this worktree'"'"'s own git directory holds a record of this session. An earlier end removed it, possibly from another worktree, or the session was recorded in another clone of the repository. Tell the user and end nothing.' \
  'The second call ends the session without sending any path. Zensu accepts the empty list it sends: the session ends and no feature is mapped to it. The call finds the record as the first call does, stops when it is missing, and removes it after a successful end:' \
  '- `Pulse request failed` or `invalid Pulse response`: run `zensu auth status`; when it shows no valid login, run `zensu auth login` and run the call again. Otherwise run the call once more with `--minimal-json` removed, which prints the detailed error' \
  'When the error shows that Zensu refused a path, tell the user which one, and drop it only when they ask you to, or end the session with the second call below when they choose to send no path.')"
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
if [ "$(has "$README" '| `/zensu:pulse` | HEAD SHA, branch, **the absolute path of your project root**, an optional product id and, at the end, the paths of the tracked files that differ from the start commit and **of the untracked, non-ignored files created or changed during the session**. It asks you first when the session ends in another worktree than the one it started in, when the start commit left the history or when a commit since then names another author; changes you bring in under your own address or without a commit, such as a squash merge, are sent without that question. A session can also end without any path |')" = PASS ] \
  && [ "$(lacks "$README" 'only after you confirm them')" = PASS ] \
  && [ "$(lacks "$README" 'pulse banner')" = PASS ] \
  && [ "$(lacks "$CONFIG" 'pulse banner')" = PASS ]; then
  check "PC4 the README privacy row names the session-bound untracked paths, what passes without the question and the end without paths, and no doc keeps the pulse banner name" PASS
else
  check "PC4 the README privacy row names the session-bound untracked paths, what passes without the question and the end without paths, and no doc keeps the pulse banner name" FAIL
fi

echo "----"
echo "test-pulse-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
