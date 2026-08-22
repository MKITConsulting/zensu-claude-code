#!/bin/bash
set -u

# Pins the publication-safety contract for the two .zensu run artifacts that
# consuming repos commit as an audit trail: the narrative log
# .zensu/logs/{ts}_tdd-{slug}.log and the plan .zensu/plans/{ts}_tdd-{slug}.md.
#
# Neither artifact had a writer-side chokepoint before this suite existed:
# zensu-log.sh only ever returned the timestamp PREFIX, and the model appended
# the line itself with `printf >>`; the plan is written with the Write tool. The
# leak this closes is absolute developer paths — a scan of ~27k committed log
# lines across four consuming repos found ~436 lines carrying /Users/<name>/...,
# entering mostly through the cmd="..." field of CHECKPOINT/AUDIT lines, which
# quotes a shell command that routinely begins with `cd "<absolute worktree>"`.
#
# Two properties are easy to pin VACUOUSLY and are therefore pinned twice here.
# A "clean" assertion is satisfied by an EMPTY file, so every end-to-end arm is
# paired with a content assertion that fails if the writer destroyed the
# artifact instead of redacting it. And a refusal is satisfied by a writer that
# never wrote for an unrelated reason, so every guard check asserts the exit
# status AND that the on-disk shape the guard protects still holds.
#
# R8 is the regression the whole design exists to avoid: the narrative log's
# cmd="..." claims are matched BY EQUALITY against the witness log by
# hooks/lib/zensu-evidence-crosscheck.js, so redacting one side only — or
# redacting them differently — would turn every Phase-6 claim into an
# EVIDENCE GAP and wedge the workflow.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_HELPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
REDACT="$PLUGIN_DIR/hooks/lib/zensu-artifact-redact-v1.js"
ARTIFACT_HOOK="$PLUGIN_DIR/hooks/post-artifact-redact.sh"
WITNESS_HOOK="$PLUGIN_DIR/hooks/post-bash-witness.sh"
CROSSCHECK="$PLUGIN_DIR/hooks/lib/zensu-evidence-crosscheck.js"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

ZENSU_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"; export ZENSU_CONFIG

PASS=0; FAIL=0; SKIP=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
# A skipped guard is NOT a pass. Counting it as one makes the total unable to
# distinguish "verified" from "never ran" — precisely the failure this repo
# already records for `ln -s` on Git Bash.
skip() { echo "  SKIP  $1"; SKIP=$((SKIP+1)); }

finish() {
  echo "----"
  echo "test-artifact-redaction: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
  [ "$FAIL" -eq 0 ]
}

if ! command -v node >/dev/null 2>&1; then
  check "node is available (suite requires it)" FAIL
  finish; exit $?
fi

# ── Sandbox ──────────────────────────────────────────────────────────
# A fake HOME inside the temp root, with the project nested under it, so the
# longest-root-first ordering is exercised for real: the project root must be
# replaced before $HOME, or the project path decays to `~/IdeaProjects/demo`
# and R3 fails. Both roots are canonicalized because macOS resolves
# /var/folders/... to /private/var/folders/... and the two spellings must agree.
WORK="$(mktemp -d -t "artifact-redact-XXXXXX")" || { check "mktemp sandbox" FAIL; finish; exit $?; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_HOME="$WORK/h"
mkdir -p "$FAKE_HOME/IdeaProjects/demo/.zensu/logs" "$FAKE_HOME/IdeaProjects/demo/.zensu/plans"
mkdir -p "$FAKE_HOME/IdeaProjects/other/.zensu/logs"
FAKE_HOME="$(cd "$FAKE_HOME" && pwd -P)"
PROJ="$(cd "$FAKE_HOME/IdeaProjects/demo" && pwd -P)"
OTHER_PROJ="$(cd "$FAKE_HOME/IdeaProjects/other" && pwd -P)"

FOREIGN_USER="/Users/someoneelse/work/thing.txt"
FOREIGN_HOME="/home/otherdev/work/thing.txt"
LEAK_CMD="cd \"$PROJ/.claude/worktrees/wt\" && npm test"
LEAK_TEXT="$LEAK_CMD | notes: $FAKE_HOME/notes.md, $FOREIGN_USER, $FOREIGN_HOME"

LOGF="$PROJ/.zensu/logs/2026-01-01-0000_tdd-demo.log"
PLANF="$PROJ/.zensu/plans/2026-01-01-0000_tdd-demo.md"

session_key() { node "$SESSION_CORE" session-key "$1"; }

activate() {
  export CLAUDE_PROJECT_DIR="$1"
  export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$2" || return 1
  bash "$LOG_HELPER" --tdd-begin --session "$2" >/dev/null 2>&1
}

json_str() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"; }

# Assert the three publication-safety properties on one artifact.
assert_clean() {
  local label_prefix="$1" file="$2" n1="$3" n2="$4" n3="$5"
  if [ -f "$file" ] && ! grep -qF '/Users/' "$file"; then
    check "$n1 $label_prefix carries no /Users/ path" PASS
  else
    check "$n1 $label_prefix carries no /Users/ path" FAIL
  fi
  if [ -f "$file" ] && ! grep -qF '/home/' "$file"; then
    check "$n2 $label_prefix carries no /home/ path" PASS
  else
    check "$n2 $label_prefix carries no /home/ path" FAIL
  fi
  if [ -f "$file" ] && ! grep -qF "$PROJ" "$file"; then
    check "$n3 $label_prefix carries no absolute project root" PASS
  else
    check "$n3 $label_prefix carries no absolute project root" FAIL
  fi
}

# The discrimination that keeps assert_clean honest: a redaction that emptied or
# truncated the artifact would satisfy all three arms above. Asserting the
# content marker AND both substituted placeholders also pins rule 2 end-to-end —
# without the `~/notes.md` arm a writer that passed an empty `home` would still
# look clean, because no sandbox root contains /Users/ or /home/.
assert_survived() {
  local label="$1" file="$2" marker="$3" id="$4"
  # SC2088: the tilde is the literal placeholder rule 2 emits, not a path to
  # expand. Expanding it here would search for the real home directory and this
  # check would pass on an artifact that was never redacted.
  # shellcheck disable=SC2088
  if [ -f "$file" ] \
    && grep -qF "$marker" "$file" \
    && grep -qF '<project>' "$file" \
    && grep -qF '~/notes.md' "$file"; then
    check "$id $label survived redaction with <project> and ~ substituted" PASS
  else
    check "$id $label survived redaction with <project> and ~ substituted" FAIL
  fi
}

# ── Presence + syntax ────────────────────────────────────────────────
if [ -f "$REDACT" ] && node --check "$REDACT" 2>/dev/null; then
  check "R0a hooks/lib/zensu-artifact-redact-v1.js exists and parses" PASS
else
  check "R0a hooks/lib/zensu-artifact-redact-v1.js exists and parses" FAIL
fi

if [ -f "$ARTIFACT_HOOK" ] && bash -n "$ARTIFACT_HOOK" 2>/dev/null; then
  check "R0b hooks/post-artifact-redact.sh exists and parses" PASS
else
  check "R0b hooks/post-artifact-redact.sh exists and parses" FAIL
fi

if grep -qF 'post-artifact-redact.sh' "$HOOKS_JSON" 2>/dev/null \
  && node -e '
    const j = require(process.argv[1]);
    const post = (j.hooks && j.hooks.PostToolUse) || [];
    const on = m => post.some(e => e.matcher === m
      && (e.hooks || []).some(h => String(h.command || "").includes("post-artifact-redact.sh")));
    process.exit((on("Edit|Write|MultiEdit") && on("Bash")) ? 0 : 1);
  ' "$HOOKS_JSON" 2>/dev/null; then
  check "R0c hooks.json registers the redactor on Edit|Write|MultiEdit and Bash" PASS
else
  check "R0c hooks.json registers the redactor on Edit|Write|MultiEdit and Bash" FAIL
fi

# ── R1-R3: the narrative log, written through the `append` verb ──────
HOME="$FAKE_HOME" bash "$LOG_HELPER" append \
  --log "$LOGF" \
  --message "S1 CHECKPOINT — cmd=\"$LEAK_CMD\" exit=0 result=\"PASS\" | $LEAK_TEXT" \
  >/dev/null 2>&1
assert_clean "narrative log written through \`append\`" "$LOGF" R1 R2 R3
assert_survived "the appended log line" "$LOGF" 'S1 CHECKPOINT' R3a

# ── R4-R6: the plan, redacted by the PostToolUse hook ────────────────
SESSION="sess-redact-$$"
if activate "$PROJ" "$SESSION"; then
  check "R3b the synthetic Session Control session activated" PASS
else
  check "R3b the synthetic Session Control session activated" FAIL
fi

write_plan() {
  printf '# Plan\n\nRun: %s\n\nSee %s and %s and %s\n' \
    "$LEAK_CMD" "$FAKE_HOME/notes.md" "$FOREIGN_USER" "$FOREIGN_HOME" > "$1"
}
write_plan "$PLANF"
printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$PLANF")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
# These four assert the end-to-end property. They do NOT isolate the named-path
# branch — the plan is freshly written, so it is inside the sweep window too. R37
# (window) and R37b (extension) are the checks that discriminate the two arms.
assert_clean "plan written with the Write tool" "$PLANF" R4 R5 R6
assert_survived "the plan body" "$PLANF" '# Plan' R6a

# ── R7: a hand-rolled `printf >>` append is swept on the Bash matcher ─
RAW_LOG="$PROJ/.zensu/logs/2026-01-01-0001_tdd-raw.log"
printf 'RAW %s\n' "$LEAK_TEXT" > "$RAW_LOG"
sweep_payload() {
  printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"stdout":""},"session_id":%s}' \
    "$(json_str "$1")" "$(json_str "$SESSION")"
}
# Deliberately a command that does NOT mention `.zensu`: an earlier revision
# pre-filtered on that substring, which the one spelling the sweep exists to
# catch (`printf … >> "$LOG"`) evades.
sweep_payload 'printf "%s\n" "x" >> "$LOG"' \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
assert_clean "hand-rolled \`printf >>\` log" "$RAW_LOG" R7 R7b R7c
assert_survived "the hand-rolled log line" "$RAW_LOG" 'RAW ' R7d

# ── R8: witness / narrative-claim equality survives redaction ────────
XLOG="$PROJ/.zensu/logs/2026-01-01-0002_tdd-cross.log"
XCMD="cd \"$PROJ\" && npm test"
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"stdout":%s,"interrupted":false},"session_id":%s}' \
  "$(json_str "$XCMD")" "$(json_str "ok from $PROJ/run")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" STATE_DIR="$PROJ/.zensu/state" bash "$WITNESS_HOOK" >/dev/null 2>&1
WITNESS="$PROJ/.zensu/logs/witness-$(session_key "$SESSION").log"
HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG_HELPER" append \
  --log "$XLOG" \
  --message "AUDIT — cmd=\"$XCMD\" exit=0 result=\"PASS\"" >/dev/null 2>&1
if [ -f "$WITNESS" ] && [ -f "$XLOG" ] \
  && node "$CROSSCHECK" --log "$XLOG" --witness "$WITNESS" >/dev/null 2>&1; then
  check "R8 redacted witness still corroborates the redacted AUDIT claim" PASS
else
  check "R8 redacted witness still corroborates the redacted AUDIT claim" FAIL
fi

# Discrimination: the crosscheck must still REJECT a claim nothing recorded.
BADLOG="$PROJ/.zensu/logs/2026-01-01-0003_tdd-bad.log"
HOME="$FAKE_HOME" bash "$LOG_HELPER" append \
  --log "$BADLOG" \
  --message "AUDIT — cmd=\"npm run never-executed\" exit=0 result=\"PASS\"" >/dev/null 2>&1
if [ -f "$BADLOG" ] \
  && ! node "$CROSSCHECK" --log "$BADLOG" --witness "$WITNESS" >/dev/null 2>&1; then
  check "R8a crosscheck still fails an uncorroborated claim (R8 is not vacuous)" PASS
else
  check "R8a crosscheck still fails an uncorroborated claim (R8 is not vacuous)" FAIL
fi

# The witness `cmd` IS redacted (equality needs it) but the `tail` is NOT.
# Nothing compares the tail; the only reader is the crosscheck's failure-marker
# scan, and redaction there is purely subtractive — a `failed` token inside an
# absolute path would vanish and a contradiction would downgrade to `verified`.
if [ -f "$WITNESS" ] && grep -qF 'cmd="cd \"<project>\" && npm test"' "$WITNESS" \
  && grep -qF "tail=\"ok from $PROJ/run\"" "$WITNESS"; then
  check "R8b witness cmd is redacted while tail is left intact" PASS
else
  check "R8b witness cmd is redacted while tail is left intact" FAIL
fi

# ── R9: idempotence, and the no-op writes nothing at all ─────────────
if [ -f "$REDACT" ] && [ -f "$LOGF" ]; then
  BEFORE_SUM="$(cksum < "$LOGF")"
  BEFORE_ID="$(node -e 'const s=require("fs").statSync(process.argv[1]);process.stdout.write(s.ino+":"+s.mtimeMs)' "$LOGF")"
  env HOME="$FAKE_HOME" node "$REDACT" --file "$LOGF" --project "$PROJ" >/dev/null 2>&1
  RC=$?
  AFTER_SUM="$(cksum < "$LOGF")"
  AFTER_ID="$(node -e 'const s=require("fs").statSync(process.argv[1]);process.stdout.write(s.ino+":"+s.mtimeMs)' "$LOGF")"
  if [ "$RC" -eq 0 ] && [ "$BEFORE_SUM" = "$AFTER_SUM" ] && [ "$BEFORE_ID" = "$AFTER_ID" ]; then
    check "R9 a no-op pass exits 0, changes no bytes and writes nothing (inode + mtime intact)" PASS
  else
    check "R9 a no-op pass exits 0, changes no bytes and writes nothing (inode + mtime intact)" FAIL
  fi
else
  check "R9 a no-op pass exits 0, changes no bytes and writes nothing (inode + mtime intact)" FAIL
fi

# ── R10-R11: the rule set, driven directly ───────────────────────────
OUT10="$(env HOME="$FAKE_HOME" node -e '
  const m = require(process.argv[1]);
  process.stdout.write(m.redact("A /Users/other/x B /home/z/y C /root/w D",
    { projectRoot: process.argv[2], home: process.argv[3] }));
' "$REDACT" "$PROJ" "$FAKE_HOME" 2>/dev/null)"
if [ "$OUT10" = "A <home>/x B <home>/y C <home>/w D" ]; then
  check "R10 residual /Users, /home and /root prefixes map to <home>" PASS
else
  check "R10 residual /Users, /home and /root prefixes map to <home> (got: $OUT10)" FAIL
fi

OUT11="$(env HOME="$FAKE_HOME" node -e '
  const m = require(process.argv[1]);
  process.stdout.write(m.redact(process.argv[2] + "/src/a " + process.argv[3] + "/other/b",
    { projectRoot: process.argv[2], home: process.argv[3] }));
' "$REDACT" "$PROJ" "$FAKE_HOME" 2>/dev/null)"
if [ "$OUT11" = "<project>/src/a ~/other/b" ]; then
  check "R11 nested project root is replaced before \$HOME" PASS
else
  check "R11 nested project root is replaced before \$HOME (got: $OUT11)" FAIL
fi

# Both bounds, in one place. Without the RIGHT bound `/homework` becomes
# `<home>work`; without the LEFT bound the rule fires inside `src/home/x`; and
# a segment class admitting `"` eats the closing quote of a cmd="…" field, which
# desynchronizes the claim from the witness and produces the exact EVIDENCE GAP
# R8 exists to prevent.
OUT11B="$(env HOME="$FAKE_HOME" node -e '
  const m = require(process.argv[1]);
  const o = { projectRoot: process.argv[2], home: process.argv[3] };
  const cases = [
    ["/homework/notes.md", "/homework/notes.md"],
    ["/homes/shared", "/homes/shared"],
    ["src/home/index.ts", "src/home/index.ts"],
    ["file:///Users/marcel/x", "file://<home>/x"],
    ["AUDIT — cmd=\"ls /home/otherdev\" exit=0", "AUDIT — cmd=\"ls <home>\" exit=0"],
  ];
  const bad = cases.filter(([i, w]) => m.redact(i, o) !== w).map(([i]) => i);
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$PROJ" "$FAKE_HOME" 2>/dev/null)"
if [ "$OUT11B" = "OK" ]; then
  check "R11b every residual rule is bounded on both sides and keeps quotes" PASS
else
  check "R11b every residual rule is bounded on both sides and keeps quotes (bad: $OUT11B)" FAIL
fi

# Platform-conditional spellings, driven host-independently. This suite has no
# entry in tests/profiles/windows-ci.v1.json — a deliberate decision, not an
# oversight: the Windows wall clock for it is unmeasured and every shard is
# already budgeted, so the branches Windows would exercise are pinned here
# instead, through the module's own explicit inputs.
OUT11C="$(node -e '
  const m = require(process.argv[1]);
  const out = [];
  out.push(m.redact("x C:\\Users\\bob\\p y", { projectRoot: "", home: "" }));
  out.push(String(m.msysSpelling("D:\\a\\proj")));
  out.push(String(m.msysSpelling("/not/a/drive")));
  out.push(m.rootSpellings("/private/var/folders/a/b").includes("/var/folders/a/b") ? "alias" : "no-alias");
  process.stdout.write(out.join(" ; "));
' "$REDACT" 2>/dev/null)"
if [ "$OUT11C" = "x C:<home>\\p y ; /d/a/proj ; null ; alias" ]; then
  check "R11c Windows and /private spellings are handled (backslash, MSYS, alias)" PASS
else
  check "R11c Windows and /private spellings are handled (got: $OUT11C)" FAIL
fi

# ── R12-R14: every redactFile guard, asserted on status AND shape ────
LINK_TARGET="$WORK/real.log"
LINK="$PROJ/.zensu/logs/2026-01-01-0004_tdd-link.log"
printf 'LINK %s\n' "$FOREIGN_USER" > "$LINK_TARGET"
if ln -s "$LINK_TARGET" "$LINK" 2>/dev/null \
  && [ "$(node -e 'process.stdout.write(require("fs").lstatSync(process.argv[1]).isSymbolicLink()?"y":"n")' "$LINK")" = "y" ]; then
  R12_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$LINK" --project "$PROJ" 2>&1 >/dev/null)"
  RC=$?
  STILL_LINK="$(node -e 'process.stdout.write(require("fs").lstatSync(process.argv[1]).isSymbolicLink()?"y":"n")' "$LINK" 2>/dev/null)"
  if [ "$RC" -eq 2 ] && [ "$STILL_LINK" = "y" ] && grep -qF "$FOREIGN_USER" "$LINK_TARGET" \
    && printf '%s' "$R12_ERR" | grep -qF '(symlink)'; then
    check "R12 a symlinked artifact is refused AS a symlink (exit 2, link intact, target untouched)" PASS
  else
    check "R12 a symlinked artifact is refused AS a symlink (rc=$RC still_link=$STILL_LINK err=$R12_ERR)" FAIL
  fi
else
  skip "R12 symlinked-artifact refusal (host did not create a real symlink)"
fi

HARD_PEER="$PROJ/.zensu/logs/2026-01-01-0005_tdd-peer.log"
HARD_LINK="$PROJ/.zensu/logs/2026-01-01-0005_tdd-hard.log"
printf 'HARD %s\n' "$FOREIGN_USER" > "$HARD_PEER"
if ln "$HARD_PEER" "$HARD_LINK" 2>/dev/null \
  && [ "$(node -e 'process.stdout.write(String(require("fs").lstatSync(process.argv[1]).nlink))' "$HARD_LINK")" = "2" ]; then
  R13_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$HARD_LINK" --project "$PROJ" 2>&1 >/dev/null)"
  RC=$?
  if [ "$RC" -eq 2 ] && grep -qF "$FOREIGN_USER" "$HARD_PEER" \
    && printf '%s' "$R13_ERR" | grep -qF '(hard-link)'; then
    check "R13 a hard-linked artifact is refused (exit 2, peer untouched)" PASS
  else
    check "R13 a hard-linked artifact is refused (rc=$RC)" FAIL
  fi
  rm -f "$HARD_LINK" "$HARD_PEER"
else
  skip "R13 hard-link refusal (host did not create a hard link)"
fi

BIG="$PROJ/.zensu/logs/2026-01-01-0006_tdd-big.log"
node -e '
  const fs = require("fs");
  const fd = fs.openSync(process.argv[1], "w");
  fs.writeSync(fd, "BIG " + process.argv[2] + "\n");
  fs.ftruncateSync(fd, 9 * 1024 * 1024);
  fs.closeSync(fd);
' "$BIG" "$FOREIGN_USER"
R14_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$BIG" --project "$PROJ" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && head -c 200 "$BIG" | grep -qF "$FOREIGN_USER" \
  && printf '%s' "$R14_ERR" | grep -qF '(too-large)'; then
  check "R14 an oversized artifact is refused loudly rather than silently skipped" PASS
else
  check "R14 an oversized artifact is refused loudly rather than silently skipped (rc=$RC)" FAIL
fi
rm -f "$BIG"

# ── R15-R16: the `append` verb's own branches ────────────────────────
# The FIRST write of every shipped run is `--truncate` onto a path that does not
# exist yet, so that shape gets its own check before the pre-existing one.
FRESH="$PROJ/.zensu/logs/2026-01-01-0006_tdd-fresh.log"
rm -f "$FRESH"
HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG_HELPER" append --truncate \
  --log "$FRESH" --message "TDD STARTED — $LEAK_CMD" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$FRESH" ] && [ "$(wc -l < "$FRESH")" -eq 1 ] \
  && grep -qF 'TDD STARTED' "$FRESH" && grep -qF '<project>' "$FRESH"; then
  check "R14a --truncate CREATES a missing log and writes exactly one redacted line" PASS
else
  check "R14a --truncate CREATES a missing log and writes exactly one redacted line (rc=$RC)" FAIL
fi

TRUNC="$PROJ/.zensu/logs/2026-01-01-0007_tdd-trunc.log"
printf 'STALE LINE\n' > "$TRUNC"
HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG_HELPER" append --truncate \
  --log "$TRUNC" --message "TDD STARTED — $LEAK_CMD" >/dev/null 2>&1
if [ -f "$TRUNC" ] && ! grep -qF 'STALE LINE' "$TRUNC" \
  && grep -qF 'TDD STARTED' "$TRUNC" && grep -qF '<project>' "$TRUNC"; then
  check "R15 --truncate replaces a pre-existing log and still redacts" PASS
else
  check "R15 --truncate replaces a pre-existing log and still redacts" FAIL
fi

OUTSIDE="$WORK/escape.log"
printf 'UNTOUCHED\n' > "$OUTSIDE"
R16_ERR="$(HOME="$FAKE_HOME" bash "$LOG_HELPER" append --truncate \
  --log "$OUTSIDE" --message "pwned" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && grep -qF 'UNTOUCHED' "$OUTSIDE" && ! grep -qF 'pwned' "$OUTSIDE" \
  && printf '%s' "$R16_ERR" | grep -qF '(not-an-artifact-path)'; then
  check "R16 append refuses a --log outside .zensu/{plans,logs} (no arbitrary write)" PASS
else
  check "R16 append refuses a --log outside .zensu/{plans,logs} (rc=$RC err=$R16_ERR)" FAIL
fi

R16A_BEFORE="$(cksum < "$LOGF")"
R16A_ERR="$(HOME="$FAKE_HOME" bash "$LOG_HELPER" append --log "$LOGF" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$R16A_ERR" | grep -qF -- '--message <text> is required' \
  && [ "$R16A_BEFORE" = "$(cksum < "$LOGF")" ]; then
  check "R16a append refuses an ABSENT --message and writes no bare timestamp" PASS
else
  check "R16a append refuses an ABSENT --message (rc=$RC err=$R16A_ERR)" FAIL
fi

# The other half, and the one a "seen" flag on the flag alone would miss: the
# flag present as the LAST token, with no value to consume.
R16D_ERR="$(HOME="$FAKE_HOME" bash "$LOG_HELPER" append --log "$LOGF" --message 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$R16D_ERR" | grep -qF -- '--message needs a value' \
  && [ "$R16A_BEFORE" = "$(cksum < "$LOGF")" ]; then
  check "R16d append refuses a VALUELESS --message and writes no bare timestamp" PASS
else
  check "R16d append refuses a VALUELESS --message (rc=$RC err=$R16D_ERR)" FAIL
fi

SYMLOG="$PROJ/.zensu/logs/2026-01-01-0008_tdd-sym.log"
if ln -s "$OUTSIDE" "$SYMLOG" 2>/dev/null && [ -L "$SYMLOG" ]; then
  HOME="$FAKE_HOME" bash "$LOG_HELPER" append --log "$SYMLOG" --message "pwned2" >/dev/null 2>&1
  RC=$?
  if [ "$RC" -eq 2 ] && ! grep -qF 'pwned2' "$OUTSIDE"; then
    check "R16b append refuses a symlinked --log" PASS
  else
    check "R16b append refuses a symlinked --log (rc=$RC)" FAIL
  fi
  rm -f "$SYMLOG"
else
  skip "R16b symlinked --log refusal (host did not create a real symlink)"
fi

# ── R16c: the MODULE's own symlink refusal, not the shell pre-check ──
# R16b above drives the shell helper, which refuses a symlinked `--log` in its
# own `[ -L ]` pre-check and therefore returns before `writeArtifactLine` opens
# anything: delete `O_NOFOLLOW` from the module and R16b still passes. This check
# calls the writer directly, so the refusal it observes is the descriptor-level
# one — the `symlink` reason is only reachable through the ELOOP the open flag
# produces. Without the flag the open succeeds and the refusal degrades to
# `moved` (the dev/ino comparison catches it one layer later), which is a
# different guarantee with a different failure mode.
SYM_TARGET="$WORK/outside-16c.txt"
printf 'UNTOUCHED\n' > "$SYM_TARGET"
SYM_LOG="$PROJ/.zensu/logs/2026-01-01-0016_tdd-modsym.log"
rm -f "$SYM_LOG"
if ln -s "$SYM_TARGET" "$SYM_LOG" 2>/dev/null && [ -L "$SYM_LOG" ]; then
  OUT16C="$(node -e '
    const fs = require("node:fs");
    const m = require(process.argv[1]);
    const res = m.writeArtifactLine(process.argv[3], "pwned3\n", { expectedRoot: process.argv[2] });
    const body = fs.readFileSync(process.argv[4], "utf8");
    const bad = [];
    if (res.written !== false) bad.push("written=" + res.written);
    if (res.reason !== "symlink") bad.push("reason=" + res.reason);
    if (body !== "UNTOUCHED\n") bad.push("body=" + JSON.stringify(body));
    process.stdout.write(bad.length ? bad.join(" | ") : "OK");
  ' "$REDACT" "$PROJ" "$SYM_LOG" "$SYM_TARGET" 2>&1)"
  if [ "$OUT16C" = "OK" ]; then
    check "R16c writeArtifactLine itself refuses a symlinked artifact path" PASS
  else
    check "R16c writeArtifactLine itself refuses a symlinked artifact path (bad: $OUT16C)" FAIL
  fi
  rm -f "$SYM_LOG"
else
  skip "R16c module-level symlink refusal (host did not create a real symlink)"
fi

# ── R17: the sweep's narrowings and its project binding ──────────────
FRESH_WITNESS="$PROJ/.zensu/logs/witness-sweep-probe.log"
OLD_LOG="$PROJ/.zensu/logs/2026-01-01-0009_tdd-old.log"
FOREIGN_LOG="$OTHER_PROJ/.zensu/logs/2026-01-01-0010_tdd-foreign.log"
printf 'WITNESS %s\n' "$FOREIGN_USER" > "$FRESH_WITNESS"
printf 'OLD %s\n' "$FOREIGN_USER" > "$OLD_LOG"
printf 'FOREIGN %s\n' "$FOREIGN_USER" > "$FOREIGN_LOG"
node -e '
  const fs = require("fs");
  const old = new Date(Date.now() - 3600 * 1000);
  fs.utimesSync(process.argv[1], old, old);
' "$OLD_LOG"
SWEEP_CONTROL="$PROJ/.zensu/logs/2026-01-01-0012_tdd-control.log"
printf 'CONTROL %s\n' "$LEAK_TEXT" > "$SWEEP_CONTROL"
sweep_payload 'echo sweep' \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
# Positive control: without it, any failure that stops the hook before the sweep
# satisfies all three negatives below.
if [ -f "$SWEEP_CONTROL" ] && ! grep -qF "$FOREIGN_USER" "$SWEEP_CONTROL" \
  && grep -qF 'CONTROL' "$SWEEP_CONTROL"; then
  check "R17ctl the same sweep invocation DID redact an in-window artifact" PASS
else
  check "R17ctl the same sweep invocation DID redact an in-window artifact" FAIL
fi
if grep -qF "$FOREIGN_USER" "$FRESH_WITNESS"; then
  check "R17 the sweep skips witness-*.log" PASS
else
  check "R17 the sweep skips witness-*.log" FAIL
fi
if grep -qF "$FOREIGN_USER" "$OLD_LOG"; then
  check "R17a the sweep skips an artifact older than the window" PASS
else
  check "R17a the sweep skips an artifact older than the window" FAIL
fi
if grep -qF "$FOREIGN_USER" "$FOREIGN_LOG"; then
  check "R17b the sweep never touches another project's artifacts" PASS
else
  check "R17b the sweep never touches another project's artifacts" FAIL
fi

# ── R18: a symlinked artifact DIRECTORY cannot carry a write out ─────
ESCAPE_DIR="$WORK/escape-dir"
LINKED_PROJ="$FAKE_HOME/IdeaProjects/linked"
mkdir -p "$ESCAPE_DIR" "$LINKED_PROJ/.zensu"
printf 'OUTSIDE %s\n' "$FOREIGN_USER" > "$ESCAPE_DIR/2026-01-01-0011_tdd-escape.log"
if ln -s "$ESCAPE_DIR" "$LINKED_PROJ/.zensu/logs" 2>/dev/null && [ -L "$LINKED_PROJ/.zensu/logs" ]; then
  R18_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$LINKED_PROJ/.zensu/logs/2026-01-01-0011_tdd-escape.log" \
    --project "$LINKED_PROJ" 2>&1 >/dev/null)"
  RC=$?
  if [ "$RC" -eq 2 ] && grep -qF "$FOREIGN_USER" "$ESCAPE_DIR/2026-01-01-0011_tdd-escape.log" \
    && printf '%s' "$R18_ERR" | grep -qF '(artifact-directory-escapes)'; then
    check "R18 a symlinked .zensu/logs directory is refused (containment is canonicalized)" PASS
  else
    check "R18 a symlinked .zensu/logs directory is refused (rc=$RC)" FAIL
  fi
else
  skip "R18 symlinked artifact directory (host did not create a real symlink)"
fi

# ── R19: the witness prefix the sweep excludes is the one it writes ──
WITNESS_PREFIX_MOD="$(node -e '
  process.stdout.write(require(process.argv[1]).WITNESS_PREFIX);' "$REDACT" 2>/dev/null)"
if [ -n "$WITNESS_PREFIX_MOD" ] \
  && grep -qF "WITNESS_LOG=\"\$WITNESS_DIR/${WITNESS_PREFIX_MOD}\${SANITIZED_SESSION}.log\"" "$WITNESS_HOOK"; then
  check "R19 the module's WITNESS_PREFIX matches post-bash-witness.sh's own spelling" PASS
else
  check "R19 the module's WITNESS_PREFIX matches post-bash-witness.sh's own spelling (got: $WITNESS_PREFIX_MOD)" FAIL
fi

# ── R20: the hook consumes the module's layout, never its own copy ───
# The likely re-spelling is a hand-join, not the literal table, so the absence
# check has to cover `.zensu` in ANY form inside the node program — and it must
# be paired with the positive that the module's own seam is what runs.
# Comment lines are stripped: a comment may legitimately NAME `.zensu/logs` while
# explaining the containment, and only executable text can re-spell a layout.
HOOK_PROGRAM="$(awk '/^  node -e /,0' "$ARTIFACT_HOOK" | grep -v '^[[:space:]]*//')"
if [ -n "$HOOK_PROGRAM" ] \
  && ! printf '%s' "$HOOK_PROGRAM" | grep -qF '.zensu' \
  && ! printf '%s' "$HOOK_PROGRAM" | grep -qF 'plans' \
  && printf '%s' "$HOOK_PROGRAM" | grep -qF 'mod.sweepTargets(project)' \
  && printf '%s' "$HOOK_PROGRAM" | grep -qF 'mod.NON_ARTIFACT_REASONS' \
  && printf '%s' "$HOOK_PROGRAM" | grep -qF 'mod.TRANSIENT_REASONS' \
  && printf '%s' "$HOOK_PROGRAM" | grep -qF 'mod.CLEAN_REASONS'; then
  check "R20 the hook re-spells no layout and no reason set; it consumes the module's" PASS
else
  check "R20 the hook re-spells no layout and no reason set; it consumes the module's" FAIL
fi

# ── R21: append refuses a hard-linked destination ────────────────────
APPEND_PEER="$WORK/append-peer.log"
APPEND_HARD="$PROJ/.zensu/logs/2026-01-01-0013_tdd-appendhard.log"
printf 'PEER UNTOUCHED\n' > "$APPEND_PEER"
if ln "$APPEND_PEER" "$APPEND_HARD" 2>/dev/null \
  && [ "$(node -e 'process.stdout.write(String(require("fs").lstatSync(process.argv[1]).nlink))' "$APPEND_HARD")" = "2" ]; then
  HOME="$FAKE_HOME" bash "$LOG_HELPER" append --truncate \
    --log "$APPEND_HARD" --message "pwned-hard" >/dev/null 2>&1
  RC=$?
  if [ "$RC" -eq 2 ] && grep -qF 'PEER UNTOUCHED' "$APPEND_PEER" \
    && ! grep -qF 'pwned-hard' "$APPEND_PEER"; then
    check "R21 append refuses a hard-linked --log (the peer is neither truncated nor appended)" PASS
  else
    check "R21 append refuses a hard-linked --log (rc=$RC)" FAIL
  fi
  rm -f "$APPEND_HARD"
else
  skip "R21 append hard-link refusal (host did not create a hard link)"
fi

# ── R22: expectedRoot binds a writer to ITS project ──────────────────
FOREIGN_TARGET="$OTHER_PROJ/.zensu/logs/2026-01-01-0014_tdd-bind.log"
printf 'FOREIGN UNTOUCHED\n' > "$FOREIGN_TARGET"
HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG_HELPER" append \
  --log "$FOREIGN_TARGET" --message "pwned-bind" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ] && ! grep -qF 'pwned-bind' "$FOREIGN_TARGET" \
  && grep -qF 'FOREIGN UNTOUCHED' "$FOREIGN_TARGET"; then
  check "R22 append refuses another project's artifact when CLAUDE_PROJECT_DIR binds it" PASS
else
  check "R22 append refuses another project's artifact (rc=$RC)" FAIL
fi

R22B_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$FOREIGN_TARGET" --project "$PROJ" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$R22B_ERR" | grep -qF '(foreign-project)'; then
  check "R22b --file refuses an artifact belonging to another project" PASS
else
  check "R22b --file refuses an artifact belonging to another project (rc=$RC err=$R22B_ERR)" FAIL
fi

R22C_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$LOGF" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$R22C_ERR" | grep -qF -- '--project'; then
  check "R22c --file refuses without --project rather than accepting any project's artifact" PASS
else
  check "R22c --file refuses without --project (rc=$RC err=$R22C_ERR)" FAIL
fi

# ── R23: the hook REPORTS a refusal it cannot repair ─────────────────
LOUD="$PROJ/.zensu/logs/2026-01-01-0015_tdd-loud.log"
LOUD_PEER="$WORK/loud-peer.log"
printf 'LOUD %s\n' "$FOREIGN_USER" > "$LOUD_PEER"
if ln "$LOUD_PEER" "$LOUD" 2>/dev/null; then
  LOUD_ERR="$(sweep_payload 'echo loud' \
    | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" 2>&1 >/dev/null)"
  # ONE line, naming this file AND its reason: three independent greps over the
  # whole blob can be satisfied by a leftover fixture from an earlier check.
  # `(sweep)` marks a target the sweep produced rather than one the tool named,
  # which is what lets an operator tell "the file you just wrote" from "a file in
  # this project".
  if printf '%s' "$LOUD_ERR" | grep -qF "artifact left UNREDACTED (sweep) — $LOUD (hard-link)"; then
    check "R23 the hook reports an artifact it left unredacted instead of skipping silently" PASS
  else
    check "R23 the hook reports an artifact it left unredacted (err=$LOUD_ERR)" FAIL
  fi
  rm -f "$LOUD"
else
  skip "R23 loud-refusal reporting (host did not create a hard link)"
fi

QUIET_ERR="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$PROJ/src/ordinary.ts")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" 2>&1 >/dev/null)"
# The paired positive: the same arrangement, on a real artifact, must still act —
# without it this check is green whenever the hook does nothing at all.
QUIET_CONTROL="$PROJ/.zensu/logs/2026-01-01-0017_tdd-quiet.log"
printf 'QUIET %s\n' "$LEAK_TEXT" > "$QUIET_CONTROL"
printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$QUIET_CONTROL")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
# Scoped to THIS path rather than to total silence: with the sweep on the write
# matcher too, any hostile fixture left behind by an earlier check would otherwise
# fail this one while naming an unrelated file.
if ! printf '%s' "$QUIET_ERR" | grep -qF "$PROJ/src/ordinary.ts" \
  && ! grep -qF "$FOREIGN_USER" "$QUIET_CONTROL"; then
  check "R23a an ordinary non-artifact Write stays silent while a real artifact is still redacted" PASS
else
  check "R23a an ordinary non-artifact Write stays silent (err=$QUIET_ERR)" FAIL
fi

# ── R24: the two round-2 lossy branches ──────────────────────────────
NONUTF="$PROJ/.zensu/logs/2026-01-01-0016_tdd-binary.log"
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1],
    Buffer.concat([Buffer.from("BIN " + process.argv[2] + " "), Buffer.from([0xff, 0xfe]), Buffer.from("\n")]));
' "$NONUTF" "$FOREIGN_USER"
BEFORE_BIN="$(cksum < "$NONUTF")"
NONUTF_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$NONUTF" --project "$PROJ" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$NONUTF_ERR" | grep -qF '(not-utf8)' \
  && [ "$BEFORE_BIN" = "$(cksum < "$NONUTF")" ]; then
  check "R24 a non-UTF-8 artifact is refused rather than rewritten lossily" PASS
else
  check "R24 a non-UTF-8 artifact is refused rather than rewritten lossily (rc=$RC err=$NONUTF_ERR)" FAIL
fi
rm -f "$NONUTF"

# ── R25: two DISTINCT roots both collapse to <project> ───────────────
OUT25="$(node -e '
  const m = require(process.argv[1]);
  process.stdout.write(m.redact("/root-a/x and /root-b/y",
    { projectRoot: ["/root-a", "/root-b"], home: "" }));
' "$REDACT" 2>/dev/null)"
if [ "$OUT25" = "<project>/x and <project>/y" ]; then
  check "R25 the array projectRoot substitutes every candidate root" PASS
else
  check "R25 the array projectRoot substitutes every candidate root (got: $OUT25)" FAIL
fi

# ── R27: the log verb cannot reach a plan or the witness ─────────────
PLAN_TARGET="$PROJ/.zensu/plans/2026-01-01-0018_tdd-victim.md"
printf '# VICTIM PLAN\n' > "$PLAN_TARGET"
R27_ERR="$(HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG_HELPER" append --truncate \
  --log "$PLAN_TARGET" --message "pwned-plan" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && grep -qF '# VICTIM PLAN' "$PLAN_TARGET" \
  && ! grep -qF 'pwned-plan' "$PLAN_TARGET" \
  && printf '%s' "$R27_ERR" | grep -qF '(not-a-log-artifact)'; then
  check "R27 append refuses a plans/ destination, so --truncate cannot destroy a plan" PASS
else
  check "R27 append refuses a plans/ destination (rc=$RC)" FAIL
fi

WITNESS_TARGET="$PROJ/.zensu/logs/witness-victim.log"
printf 'WITNESS EVIDENCE\n' > "$WITNESS_TARGET"
R27A_ERR="$(HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG_HELPER" append --truncate \
  --log "$WITNESS_TARGET" --message "pwned-witness" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && grep -qF 'WITNESS EVIDENCE' "$WITNESS_TARGET" \
  && printf '%s' "$R27A_ERR" | grep -qF '(witness-artifact)'; then
  check "R27a append refuses a witness-*.log destination" PASS
else
  check "R27a append refuses a witness-*.log destination (rc=$RC err=$R27A_ERR)" FAIL
fi
# The same refusal must hold for a spelling the filesystem folds to the same
# inode: a case-sensitive test would fail OPEN on APFS or NTFS.
WITNESS_UPPER="$PROJ/.zensu/logs/WITNESS-victim.log"
R27B_ERR="$(HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG_HELPER" append --truncate \
  --log "$WITNESS_UPPER" --message "pwned-witness-upper" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$R27B_ERR" | grep -qF '(witness-artifact)' \
  && grep -qF 'WITNESS EVIDENCE' "$WITNESS_TARGET"; then
  check "R27b the witness refusal is case-insensitive (WITNESS- is refused too)" PASS
else
  check "R27b the witness refusal is case-insensitive (rc=$RC err=$R27B_ERR)" FAIL
fi
rm -f "$WITNESS_TARGET" "$WITNESS_UPPER"

# ── R28: the SHIPPED recipe works with no CLAUDE_PROJECT_DIR ─────────
# skills/tdd/SKILL.md Phase 2 renders `{log_file}` from `${CLAUDE_PROJECT_DIR:-.}`
# and runs `append --truncate` as the first write of every run. That variable is
# absent from the model's Bash environment on this host, so a `--truncate` gated
# on it would break every run — an earlier revision did exactly that. The
# destructive mode is constrained by the module (logs bucket, never a witness
# name, canonicalized directory, descriptor-judged) rather than by an ambient
# variable the caller sets anyway.
UNBOUND_DIR="$WORK/shipped/.zensu/logs"
mkdir -p "$UNBOUND_DIR"
( cd "$WORK/shipped" && env -u CLAUDE_PROJECT_DIR HOME="$FAKE_HOME" \
  bash "$LOG_HELPER" append --truncate \
  --log "./.zensu/logs/2026-01-01-0019_tdd-shipped.log" \
  --message "TDD STARTED — shipped recipe" >/dev/null 2>&1 )
RC=$?
if [ "$RC" -eq 0 ] && grep -qF 'TDD STARTED' "$UNBOUND_DIR/2026-01-01-0019_tdd-shipped.log"; then
  check "R28 the shipped --truncate recipe works with CLAUDE_PROJECT_DIR unset" PASS
else
  check "R28 the shipped --truncate recipe works with CLAUDE_PROJECT_DIR unset (rc=$RC)" FAIL
fi

# ── R44: the DESTRUCTIVE mode binds even with no CLAUDE_PROJECT_DIR ──
# `resolveArtifactTarget` skips its binding block when `expectedRoot` is
# undefined, and `append` maps an empty CLAUDE_PROJECT_DIR to exactly that, so
# containment reduces to SHAPE: any absolute --log resolving to a real
# <anyroot>/.zensu/logs/<name>.log is an accepted destination. Since the shipped
# recipe runs with that variable unset (R28), unbound is the DEFAULT path, and
# the redirect-carrying form this verb replaced WAS judged against the session
# root by the source-write gate — so the change narrowed an existing control.
#
# The bind is scoped to `--truncate` on purpose, and the scope was measured
# rather than assumed: applying cwd-or-ancestor to every mode broke R1/R2/R3/R3a
# and R9, which call append with an absolute --log from an unrelated cwd, as do
# the log commands of the chain that wrote this check. An unbound append adds a
# line to a foreign audit log; an unbound --truncate DESTROYS one, and only the
# second is worth denying a working call shape over. The additive residual is
# therefore open by decision, and is documented as a bound rather than dropped.
#
# R28 is the discrimination partner: the shipped --truncate recipe runs from the
# project root with a relative path, so the cwd IS the derived root.
S3_A="$WORK/xproj/a/.zensu/logs"
S3_B="$WORK/xproj/b/.zensu/logs"
mkdir -p "$S3_A" "$S3_B"
printf 'PRE-EXISTING AUDIT CONTENT OF PROJECT B\n' > "$S3_B/2026-01-01-0044_tdd-b.log"
( cd "$WORK/xproj/a" && env -u CLAUDE_PROJECT_DIR HOME="$FAKE_HOME" \
  bash "$LOG_HELPER" append --truncate \
  --log "$S3_B/2026-01-01-0044_tdd-b.log" \
  --message "WRITTEN FROM PROJECT A" >/dev/null 2>&1 )
RC44=$?
if [ "$RC44" -ne 0 ] && ! grep -qF 'WRITTEN FROM PROJECT A' "$S3_B/2026-01-01-0044_tdd-b.log" \
  && grep -qF 'PRE-EXISTING' "$S3_B/2026-01-01-0044_tdd-b.log"; then
  check "R44 --truncate with no CLAUDE_PROJECT_DIR refuses a foreign project log" PASS
else
  check "R44 --truncate with no CLAUDE_PROJECT_DIR refuses a foreign project log (rc=$RC44)" FAIL
fi

# ── R44c: the destructive bind is anchored on the PROCESS CWD ────────
# R44 proves the check refuses when the cwd is a different project. This is its
# discrimination partner in the other direction, and it pins a RESIDUAL rather
# than a guarantee: a caller that runs the verb FROM the foreign project selects
# the anchor itself, so the same truncate succeeds. `cd` carries no write channel
# for the source-write gate to recognize, so nothing else judges that shape
# either. The control therefore bounds an ACCIDENTAL cross-project truncate — the
# drifted-cwd case — and not a deliberate one, which is exactly what the comment
# at the check now says. Pinning it means narrowing it later is a decision rather
# than a discovery.
S3_B_LOG="$S3_B/2026-01-01-0044_tdd-b-residual.log"
printf 'PRE-EXISTING B CONTENT\n' > "$S3_B_LOG"
( cd "$WORK/xproj/b" && env -u CLAUDE_PROJECT_DIR HOME="$FAKE_HOME" \
  bash "$LOG_HELPER" append --truncate \
  --log "$S3_B_LOG" \
  --message "TRUNCATED FROM INSIDE B" >/dev/null 2>&1 )
RC44C=$?
if [ "$RC44C" -eq 0 ] && grep -qF 'TRUNCATED FROM INSIDE B' "$S3_B_LOG" \
  && ! grep -qF 'PRE-EXISTING B CONTENT' "$S3_B_LOG"; then
  check "R44c --truncate from inside the target project succeeds (accepted residual: the anchor is the cwd)" PASS
else
  check "R44c --truncate from inside the target project succeeds (rc=$RC44C)" FAIL
fi

# ── R44b: the additive mode is deliberately NOT bound — stated, not hidden
# This pins the accepted residual so that closing it later is a deliberate change
# rather than an accident, and so that the bound cannot quietly widen either.
( cd "$WORK/xproj/a" && env -u CLAUDE_PROJECT_DIR HOME="$FAKE_HOME" \
  bash "$LOG_HELPER" append \
  --log "$S3_B/2026-01-01-0044_tdd-b.log" \
  --message "ADDITIVE FROM PROJECT A" >/dev/null 2>&1 )
RC44B=$?
if [ "$RC44B" -eq 0 ] && grep -qF 'ADDITIVE FROM PROJECT A' "$S3_B/2026-01-01-0044_tdd-b.log" \
  && grep -qF 'PRE-EXISTING' "$S3_B/2026-01-01-0044_tdd-b.log"; then
  check "R44b append (additive) across projects is an accepted, documented residual" PASS
else
  check "R44b append (additive) across projects is an accepted, documented residual (rc=$RC44B)" FAIL
fi

# ── R44a: the same bind accepts a project root ABOVE the cwd ─────────
# The rule is cwd-or-ancestor, not cwd-equality: running the append from a
# subdirectory of the project is ordinary and must keep working, or the fix would
# trade one broken default for another.
S3_SUB="$WORK/xproj/a/src/deep"
mkdir -p "$S3_SUB"
( cd "$S3_SUB" && env -u CLAUDE_PROJECT_DIR HOME="$FAKE_HOME" \
  bash "$LOG_HELPER" append --truncate \
  --log "$S3_A/2026-01-01-0044_tdd-a.log" \
  --message "FROM A SUBDIRECTORY" >/dev/null 2>&1 )
RC44A=$?
if [ "$RC44A" -eq 0 ] && grep -qF 'FROM A SUBDIRECTORY' "$S3_A/2026-01-01-0044_tdd-a.log"; then
  check "R44a append accepts a project root that is an ancestor of the cwd" PASS
else
  check "R44a append accepts a project root that is an ancestor of the cwd (rc=$RC44A)" FAIL
fi

# ── R45: a write that lands in an orphaned inode is REPORTED ─────────
# writeArtifactLine judged the descriptor before the write and never again, so a
# rename arriving between the checks and the write sent the line to an inode no
# path names any more — and the function still answered written: true. The caller
# then exits 0 and the model believes the CHECKPOINT landed, while the sweeper
# reports a clean reason because nothing recorded a loss. This is the mirror of
# the window the header documents for redactFile, and it was neither guarded nor
# mentioned. The race is staged deterministically by wrapping fs.writeFileSync:
# a wall-clock race would be untestable, and the point under test is the
# POST-write verification, not the scheduler. The control arm is the
# discrimination partner — without it a re-verify that always refused would pass.
OUT45="$(node -e '
  const fs = require("node:fs");
  const dir = process.argv[3];
  function run(name, stage) {
    const p = dir + "/2026-01-01-0045_tdd-" + name + ".log";
    fs.writeFileSync(p, "");
    const real = fs.writeFileSync;
    let done = false;
    if (stage) {
      fs.writeFileSync = function (handle) {
        const r = real.apply(fs, arguments);
        if (!done && typeof handle === "number") {
          done = true;
          fs.renameSync(p, p + ".rotated");
        }
        return r;
      };
    }
    try {
      const m = require(process.argv[1]);
      return m.writeArtifactLine(p, "CHECKPOINT S4\n", { expectedRoot: process.argv[2] });
    } finally {
      fs.writeFileSync = real;
    }
  }
  const ctl = run("ctl", false);
  const raced = run("raced", true);
  const bad = [];
  if (ctl.written !== true || ctl.reason !== "written") bad.push("control=" + JSON.stringify(ctl));
  if (raced.written !== false || raced.reason !== "concurrent-write") bad.push("raced=" + JSON.stringify(raced));
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$PROJ" "$PROJ/.zensu/logs" 2>&1)"
if [ "$OUT45" = "OK" ]; then
  check "R45 a write into a renamed-away inode reports concurrent-write" PASS
else
  check "R45 a write into a renamed-away inode reports concurrent-write (bad: $OUT45)" FAIL
fi

# ── R46: a failed replace must not destroy what was there ────────────
# `replace` opened the target, ran ftruncateSync(fd, 0) and only then wrote, so a
# write that failed after the truncate left the artifact EMPTY with no recovery
# path — the destructive half had already committed. The recipe that uses this
# mode creates the run log, so the content at risk is a session audit trail. The
# temp+fsync+rename spelling redactFile already uses makes the publish atomic:
# the previous bytes stay addressable until the rename, and a failure before it
# changes nothing. The failure is staged by throwing from fs.writeFileSync, which
# is the one call both the old and the new spelling make with a numeric handle,
# so the same stage exercises both trees. The control arm proves replace still
# replaces — a mode that silently stopped writing would satisfy the first arm.
OUT46="$(node -e '
  const fs = require("node:fs");
  const dir = process.argv[3];
  function run(name, stage) {
    const p = dir + "/2026-01-01-0046_tdd-" + name + ".log";
    fs.writeFileSync(p, "OLD CONTENT\n");
    const real = fs.writeFileSync;
    if (stage) {
      fs.writeFileSync = function (handle) {
        if (typeof handle === "number") throw Object.assign(new Error("staged"), { code: "ENOSPC" });
        return real.apply(fs, arguments);
      };
    }
    let res;
    try {
      const m = require(process.argv[1]);
      res = m.writeArtifactLine(p, "NEW CONTENT\n", { expectedRoot: process.argv[2], mode: "replace" });
    } finally {
      fs.writeFileSync = real;
    }
    const leftover = fs.readdirSync(dir).filter(function (n) { return n.indexOf("zensu-redact-") !== -1; });
    return { res: res, body: fs.readFileSync(p, "utf8"), leftover: leftover.length };
  }
  const ctl = run("ctl", false);
  const hurt = run("hurt", true);
  const bad = [];
  if (ctl.res.written !== true || ctl.body !== "NEW CONTENT\n") bad.push("control=" + JSON.stringify(ctl));
  if (hurt.res.written !== false || hurt.res.reason !== "write-failed") bad.push("verdict=" + JSON.stringify(hurt.res));
  if (hurt.body !== "OLD CONTENT\n") bad.push("body=" + JSON.stringify(hurt.body));
  if (ctl.leftover !== 0 || hurt.leftover !== 0) bad.push("leftover=" + ctl.leftover + "/" + hurt.leftover);
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$PROJ" "$PROJ/.zensu/logs" 2>&1)"
if [ "$OUT46" = "OK" ]; then
  check "R46 a failed replace leaves the previous artifact intact and no temp behind" PASS
else
  check "R46 a failed replace leaves the previous artifact intact and no temp behind (bad: $OUT46)" FAIL
fi

# ── R47: redact does no replacement work when nothing can match ──────
# append redacts at write time, so the Bash sweep answers no-op for the narrative
# log on essentially every pass — and it paid the full set of replacement passes
# to say so, once per in-window tool call, over a file that only grows. The
# pre-check is a substring scan for the root spellings and the three literal
# residual prefixes; only a text that could match reaches a regex.
#
# The probe counts REPLACEMENT PASSES rather than every String.replace call: the
# spelling construction and escapeRegExp use replace too, and counting those
# would measure the wrong thing. A pass is identified by its replacement
# argument, which is always one of the three placeholders.
#
# The two dirty arms are the discrimination partners in both directions — they
# assert a nonzero pass count AND the redacted output, so a pre-check that
# returned early for everything would fail here rather than look like a win.
OUT47="$(node -e '
  const m = require(process.argv[1]);
  const opts = { projectRoot: process.argv[2], home: process.argv[3] };
  const real = String.prototype.replace;
  let passes = 0;
  String.prototype.replace = function (pattern, replacement) {
    if (replacement === "<project>" || replacement === "~" || replacement === "<home>") passes += 1;
    return real.apply(this, arguments);
  };
  function count(text) {
    passes = 0;
    const out = m.redact(text, opts);
    return { passes: passes, out: out };
  }
  const CLEAN = "GREEN — PASS (1 attempt, 79 tests) exit=0 result=all green";
  const clean = count(CLEAN);
  const dirty = count("cd " + process.argv[2] + " && npm test");
  const resid = count("cd /Users/otherdev/x && ls");
  String.prototype.replace = real;
  const bad = [];
  if (clean.passes !== 0) bad.push("clean-passes=" + clean.passes);
  if (clean.out !== CLEAN) bad.push("clean-out=" + JSON.stringify(clean.out));
  if (dirty.passes === 0) bad.push("dirty-passes=0");
  if (dirty.out !== "cd <project> && npm test") bad.push("dirty-out=" + JSON.stringify(dirty.out));
  if (resid.passes === 0) bad.push("resid-passes=0");
  if (resid.out !== "cd <home>/x && ls") bad.push("resid-out=" + JSON.stringify(resid.out));
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$PROJ" "$FAKE_HOME" 2>&1)"
if [ "$OUT47" = "OK" ]; then
  check "R47 redact runs no replacement pass over a text nothing can match" PASS
else
  check "R47 redact runs no replacement pass over a text nothing can match (bad: $OUT47)" FAIL
fi

# ── R48: the sweep does not stat an entry it can reject for free ─────
# lstatSync ran for every extension-matching NAME, including directories and
# other non-files, and the mtime cutoff was applied only after it. readdir with
# withFileTypes carries the type, so an entry that cannot be an artifact is
# rejected without a syscall. This does NOT make the window bound the
# enumeration — a regular file still costs one stat to read its mtime, and the
# three prose sites that claimed otherwise are corrected in this step rather than
# left standing. The cap in the next step is what bounds the work.
#
# The tree carries a DIRECTORY named like a log on purpose: it is the entry the
# old spelling paid a syscall to reject. The returned set is asserted alongside
# the count, so a sweep that stopped enumerating would fail rather than look
# cheap.
SWEEP_COST="$WORK/sweepcost"
mkdir -p "$SWEEP_COST/.zensu/logs" "$SWEEP_COST/.zensu/plans"
: > "$SWEEP_COST/.zensu/logs/2026-01-01-0048_tdd-fresh.log"
: > "$SWEEP_COST/.zensu/logs/2026-01-01-0048_tdd-old.log"
mkdir -p "$SWEEP_COST/.zensu/logs/2026-01-01-0048_tdd-adir.log"
: > "$SWEEP_COST/.zensu/logs/notes.txt"
touch -t 202601010000 "$SWEEP_COST/.zensu/logs/2026-01-01-0048_tdd-old.log"
OUT48="$(node -e '
  const fs = require("node:fs");
  const root = process.argv[2];
  const m = require(process.argv[1]);
  const real = fs.lstatSync;
  let stats = 0;
  fs.lstatSync = function (p) {
    if (String(p).indexOf(root) === 0) stats += 1;
    return real.apply(fs, arguments);
  };
  let out;
  try {
    out = m.sweepTargets(root, { windowSeconds: 300 });
  } finally {
    fs.lstatSync = real;
  }
  const bad = [];
  if (stats !== 2) bad.push("stats=" + stats);
  if (out.length !== 1 || !out[0].endsWith("2026-01-01-0048_tdd-fresh.log")) {
    bad.push("targets=" + JSON.stringify(out));
  }
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$SWEEP_COST" 2>&1)"
if [ "$OUT48" = "OK" ]; then
  check "R48 the sweep rejects a non-file entry without a stat" PASS
else
  check "R48 the sweep rejects a non-file entry without a stat (bad: $OUT48)" FAIL
fi

# ── R49: the sweep processes a bounded number of artifacts ───────────
# A `git checkout` refreshes every tracked artifact mtime at once, so the next
# tool call would redact all of them synchronously inside a PostToolUse hook,
# with no cap and no declared timeout. The cap is per invocation and ordered
# newest first, so the artifacts most likely to hold a fresh unredacted append
# are the ones processed; the rest are picked up by later passes while their
# mtime is still in the window.
#
# The uncapped arm is the discrimination partner: it proves the enumeration
# still sees all 30, so the cap is what bounds the result rather than a sweep
# that quietly stopped finding things.
OUT49="$(node -e '
  const fs = require("node:fs");
  const root = process.argv[2];
  const logs = root + "/.zensu/logs";
  fs.mkdirSync(logs, { recursive: true });
  fs.mkdirSync(root + "/.zensu/plans", { recursive: true });
  const now = Date.now();
  const names = [];
  for (let i = 0; i < 30; i += 1) {
    const name = "2026-01-01-00" + (i < 10 ? "0" + i : String(i)) + "_tdd-cap.log";
    const full = logs + "/" + name;
    fs.writeFileSync(full, "x\n");
    const stamp = (now - i * 1000) / 1000;
    fs.utimesSync(full, stamp, stamp);
    names.push(name);
  }
  const m = require(process.argv[1]);
  const capped = m.sweepTargets(root, { windowSeconds: 300 });
  const all = m.sweepTargets(root, { windowSeconds: 300, maxTargets: 100 });
  const base = capped.map(function (p) { return p.slice(p.lastIndexOf("/") + 1); });
  const bad = [];
  if (capped.length !== 25) bad.push("capped=" + capped.length);
  if (all.length !== 30) bad.push("uncapped=" + all.length);
  if (base[0] !== names[0]) bad.push("first=" + base[0]);
  const kept = names.slice(25).filter(function (n) { return base.indexOf(n) !== -1; });
  if (kept.length) bad.push("kept-oldest=" + kept.join(","));
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$WORK/sweepcap" 2>&1)"
if [ "$OUT49" = "OK" ]; then
  check "R49 the sweep caps its targets per invocation, newest mtime first" PASS
else
  check "R49 the sweep caps its targets per invocation, newest mtime first (bad: $OUT49)" FAIL
fi

# ── R50: a bind refusal is reported, not silent ──────────────────────
# A session bind failure disabled the whole PostToolUse net for the session and
# exited 0 with nothing on stderr, while this hook header promises that a refusal
# leaving an artifact un-redacted is written to stderr. Silence there is the
# worst shape the failure can take: every artifact ships unredacted and nothing
# records why. The control arm uses the activated session and asserts the note is
# ABSENT, so a hook that printed it unconditionally would fail here.
UNBOUND_PLAN="$PROJ/.zensu/plans/2026-01-01-0050_tdd-unbound.md"
printf '# Plan\nRun: cd "%s" && ls\n' "$FOREIGN_USER" > "$UNBOUND_PLAN"
ERR50="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$UNBOUND_PLAN")" "$(json_str "sess-never-activated-$$")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" 2>&1 >/dev/null)"
ERR50B="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$UNBOUND_PLAN")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" 2>&1 >/dev/null)"
if printf '%s' "$ERR50" | grep -qF 'session bind refused' \
  && ! printf '%s' "$ERR50B" | grep -qF 'session bind refused'; then
  check "R50 an unbindable session reports the disabled redactor on stderr" PASS
else
  check "R50 an unbindable session reports the disabled redactor on stderr (unbound=[$ERR50] bound=[$ERR50B])" FAIL
fi

# ── R51: the sweep redacts with the same root set the writers use ────
# `append` and the witness hook each pass [own authority, CLAUDE_PROJECT_DIR];
# the sweep passed the record root alone. A third redactor with a DIFFERENT root
# set can rewrite a narrative claim in a way the witness entry was not, and the
# crosscheck matches those two by equality — so the divergence mints an EVIDENCE
# GAP that no later sweep can repair, because both files are already written.
# The union is the fix: redactFile adds the artifact-derived root itself, so
# passing CLAUDE_PROJECT_DIR alongside the record root makes the sweep apply the
# union of both writers' sets rather than a set of its own.
#
# Two halves. The structural half pins the root set at the one place it is
# spelled, because a behavioral arm can only observe the divergence on a host
# where the two authorities disagree — which the fixture deliberately does not
# arrange. The behavioral half runs the sweep BETWEEN the append and the
# crosscheck, which is the interleaving nothing exercised: R8 checks the two
# writers against each other with no sweep in between.
if printf '%s' "$HOOK_PROGRAM" | grep -qF 'CLAUDE_PROJECT_DIR'; then
  check "R51 the sweep passes CLAUDE_PROJECT_DIR alongside the record root" PASS
else
  check "R51 the sweep passes CLAUDE_PROJECT_DIR alongside the record root" FAIL
fi

SWEPT_LOG="$PROJ/.zensu/logs/2026-01-01-0051_tdd-swept.log"
SWEPT_CMD="cd \"$PROJ\" && npm run build"
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"stdout":%s,"interrupted":false},"session_id":%s}' \
  "$(json_str "$SWEPT_CMD")" "$(json_str "built in $PROJ")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" STATE_DIR="$PROJ/.zensu/state" bash "$WITNESS_HOOK" >/dev/null 2>&1
HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG_HELPER" append \
  --log "$SWEPT_LOG" \
  --message "AUDIT — cmd=\"$SWEPT_CMD\" exit=0 result=\"PASS\"" >/dev/null 2>&1
sweep_payload 'printf "%s\n" "x" >> "$LOG"' \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
if [ -f "$SWEPT_LOG" ] && [ -f "$WITNESS" ] \
  && node "$CROSSCHECK" --log "$SWEPT_LOG" --witness "$WITNESS" >/dev/null 2>&1; then
  check "R51a a sweep between the append and the crosscheck keeps the claim corroborated" PASS
else
  check "R51a a sweep between the append and the crosscheck keeps the claim corroborated" FAIL
fi

# ── R52: the scanner guard acts on its own predicate ─────────────────
# The guard warned "the line will be written unscanned" for a scanner that is
# missing OR a symlink, and then did nothing: a symlinked-but-valid scanner was
# still required, still ran, and REFUSED the line. Both halves were wrong at
# once — the warning claimed an outcome that did not happen, and the refusal
# arrived after a message saying it would not. A branch that warns about an
# outcome it does not produce is worse than no branch, because it trains the
# reader to ignore it.
#
# The fix makes the guard consequential: the scanner path is dropped, so the
# node side takes its own fail-open branch and says so. The control arm runs the
# identical message against the unmodified plugin root and must still be
# REFUSED, or the step would have disabled the control instead of fixing it.
#
# The key is assembled at runtime rather than written literally: a literal here
# would be a credential-shaped string in a tracked file, which is exactly what
# the sibling write-gate exists to stop.
SCAN_COPY="$WORK/plugin-symlinked-scanner"
mkdir -p "$SCAN_COPY"
cp -R "$PLUGIN_DIR/hooks" "$SCAN_COPY/hooks"
rm -f "$SCAN_COPY/hooks/lib/secret-patterns.js"
ln -s "$PLUGIN_DIR/hooks/lib/secret-patterns.js" "$SCAN_COPY/hooks/lib/secret-patterns.js"
FAKE_KEY="AKIA$(head -c 16 /dev/zero | tr '\0' 'Z')"
SCAN_LOG="$PROJ/.zensu/logs/2026-01-01-0052_tdd-scan.log"
ERR52="$(HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT="$SCAN_COPY" \
  bash "$SCAN_COPY/hooks/lib/zensu-log.sh" append \
  --log "$SCAN_LOG" --message "CHECKPOINT key=$FAKE_KEY done" 2>&1 >/dev/null)"
RC52=$?
SCAN_CTL="$PROJ/.zensu/logs/2026-01-01-0052_tdd-scanctl.log"
HOME="$FAKE_HOME" bash "$LOG_HELPER" append \
  --log "$SCAN_CTL" --message "CHECKPOINT key=$FAKE_KEY done" >/dev/null 2>&1
RC52B=$?
if [ "$RC52" -eq 0 ] && [ -f "$SCAN_LOG" ] \
  && printf '%s' "$ERR52" | grep -qF 'credential scan unavailable' \
  && [ "$RC52B" -ne 0 ] && [ ! -f "$SCAN_CTL" ]; then
  check "R52 a symlinked scanner is dropped, not warned about and then used" PASS
else
  check "R52 a symlinked scanner is dropped, not warned about and then used (rc=$RC52 ctl=$RC52B err=[$ERR52])" FAIL
fi

# ── R53: the scan opt-out lands a bypass-ledger entry ────────────────
# Every sibling gate records `ZENSU_*=off` in the bypass ledger, and the ledger
# is what the chain-end report renders under "Gates bypassed". The new `append`
# chokepoint honoured `ZENSU_SECRET_SCAN=off` and recorded nothing, so a session
# that turned the credential scan off reported as a session that never did.
# Under-reporting there is worse than a missing feature: the report is read as a
# complete list.
#
# The before/after pair is the discrimination: the ledger is cumulative, so
# asserting presence alone would pass on an entry some earlier check left behind.
SCAN_OFF_LOG="$PROJ/.zensu/logs/2026-01-01-0053_tdd-scanoff.log"
SESSION_KEY53="$(session_key "$SESSION")"
LEDGER_BEFORE="$(bash "$LOG_HELPER" --bypass-list --session "$SESSION" 2>/dev/null)"
HOME="$FAKE_HOME" ZENSU_SECRET_SCAN=off ZENSU_SESSION_KEY="$SESSION_KEY53" \
  bash "$LOG_HELPER" append \
  --log "$SCAN_OFF_LOG" --message "CHECKPOINT scan disabled for this call" >/dev/null 2>&1
RC53=$?
LEDGER_AFTER="$(bash "$LOG_HELPER" --bypass-list --session "$SESSION" 2>/dev/null)"
if [ "$RC53" -eq 0 ] && [ -f "$SCAN_OFF_LOG" ] \
  && ! printf '%s' "$LEDGER_BEFORE" | grep -qF 'ZENSU_SECRET_SCAN' \
  && printf '%s' "$LEDGER_AFTER" | grep -qF 'ZENSU_SECRET_SCAN'; then
  check "R53 ZENSU_SECRET_SCAN=off at the append chokepoint is recorded in the bypass ledger" PASS
else
  check "R53 ZENSU_SECRET_SCAN=off at the append chokepoint is recorded in the bypass ledger (rc=$RC53 before=[$LEDGER_BEFORE] after=[$LEDGER_AFTER])" FAIL
fi

# ── R54: the SHIPPED Phase 2 recipe is executed, not re-typed ────────
# R28 asserts a hand-typed twin of the Phase 2 create command, so a flag that
# drifts in `skills/tdd/SKILL.md` — the file every run actually reads — is
# invisible to the suite while R28 stays green against the copy in the test. This
# arm extracts the line from the shipped skill, substitutes only the documented
# `{curly}` placeholders, and runs it. It is deliberately anchored on the flag
# spelling rather than a line number, so a moved section does not silently make
# the extraction match nothing: an empty extraction FAILS here.
#
# The residue guard names the three placeholders by hand rather than matching a
# generic `{word}`: the recipe legitimately contains `${CLAUDE_PLUGIN_ROOT}` and
# `${CLAUDE_PLUGIN_DATA}`, which a generic pattern reads as unsubstituted.
RECIPE_RAW="$(grep -m1 -F 'append --truncate --log {log_file}' "$PLUGIN_DIR/skills/tdd/SKILL.md")"
RECIPE_CMD="${RECIPE_RAW#2. \`}"
RECIPE_CMD="${RECIPE_CMD%\`}"
RECIPE_PROJ="$WORK/recipe-proj"
mkdir -p "$RECIPE_PROJ"
RECIPE_LOG_REL='.zensu/logs/2026-01-01-0054_tdd-recipe.log'
# The replacement is built in its own single-quoted variable: writing the
# `${CLAUDE_PROJECT_DIR:-.}` spelling inline inside `${var//pat/repl}` needs
# backslashes, and bash does NOT strip them from a replacement string — the
# recipe then ran with a literal `$\{` and wrote nothing.
RECIPE_LOG_SPELL='"${CLAUDE_PROJECT_DIR:-.}/'"$RECIPE_LOG_REL"'"'
RECIPE_CMD="${RECIPE_CMD//\{log_file\}/$RECIPE_LOG_SPELL}"
RECIPE_CMD="${RECIPE_CMD//\{title\}/Recipe extraction}"
RECIPE_CMD="${RECIPE_CMD//\{N\}/3}"
if [ -n "$RECIPE_RAW" ] && printf '%s' "$RECIPE_CMD" | grep -qF 'zensu-log.sh' \
  && ! printf '%s' "$RECIPE_CMD" | grep -qE '\{log_file\}|\{title\}|\{N\}'; then
  ( cd "$RECIPE_PROJ" && env HOME="$FAKE_HOME" \
      CLAUDE_PROJECT_DIR="$RECIPE_PROJ" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      CLAUDE_PLUGIN_DATA="${ZENSU_TEST_PLUGIN_DATA:-$WORK/plugin-data}" \
      SESSION_EPOCH=1767225600 \
      bash -c "$RECIPE_CMD" ) >/dev/null 2>&1
  RC54=$?
  if [ "$RC54" -eq 0 ] && [ -f "$RECIPE_PROJ/$RECIPE_LOG_REL" ] \
    && grep -qF 'TDD STARTED — Recipe extraction | steps: 3' "$RECIPE_PROJ/$RECIPE_LOG_REL"; then
    check "R54 the shipped Phase 2 recipe, extracted and executed, creates the run log" PASS
  else
    check "R54 the shipped Phase 2 recipe, extracted and executed, creates the run log (rc=$RC54)" FAIL
  fi
else
  check "R54 the shipped Phase 2 recipe could be extracted from skills/tdd/SKILL.md" FAIL
fi

# ── R55: the sweep never enumerates a witness name in EITHER bucket ──
# The exclusion was scoped `bucket === 'logs'`, while `redactFile` refuses any
# `witness-` basename in either bucket and answers `witness-artifact`. That reason
# is in none of the three exported sets, and the hook's named-path carve-out does
# not apply to a swept path — so a `witness-*.md` under `.zensu/plans/` made every
# main-thread tool call print "artifact left UNREDACTED (sweep)" for a file the
# design deliberately and correctly refuses, for the whole sweep window. An
# implicit residual class reporting a routine outcome as the worst one is exactly
# what the three-set partition exists to prevent.
#
# The file is hand-placed on purpose: `{ts}_tdd-{slug}.md` cannot produce that
# name, so this is reachable without being routine. The second assertion is the
# discrimination partner — the file must still be REFUSED (left unredacted on
# disk), or a sweep that simply redacted it would satisfy the first arm while
# destroying the one file the crosscheck cannot survive losing.
WITNESS_PLAN="$PROJ/.zensu/plans/witness-probe-r55.md"
printf 'PLANTED %s\n' "$FOREIGN_USER" > "$WITNESS_PLAN"
ERR55="$(sweep_payload 'printf "%s\n" "x" >> "$LOG"' \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" 2>&1 >/dev/null)"
if ! printf '%s' "$ERR55" | grep -qF 'witness-probe-r55.md' \
  && grep -qF "$FOREIGN_USER" "$WITNESS_PLAN"; then
  check "R55 a witness name in the plans bucket is skipped by the sweep, not reported as a fault" PASS
else
  check "R55 a witness name in the plans bucket is skipped by the sweep (err=[$ERR55])" FAIL
fi
rm -f "$WITNESS_PLAN"

# ── R29: the module refuses a shape it used to accept silently ───────
OUT29="$(node -e '
  const m = require(process.argv[1]);
  const r = m.resolveArtifactTarget(process.argv[2], 123);
  process.stdout.write(String(r.ok) + ":" + r.reason);
' "$REDACT" "$LOGF" 2>/dev/null)"
if [ "$OUT29" = "false:project-root-unusable" ]; then
  check "R29 a non-string expectedRoot refuses instead of skipping the binding" PASS
else
  check "R29 a non-string expectedRoot refuses instead of skipping the binding (got: $OUT29)" FAIL
fi

# ── R30: the caller root and the derived root are BOTH substituted ───
OUT30="$(env HOME="$FAKE_HOME" node -e '
  const fs = require("node:fs");
  const m = require(process.argv[1]);
  const file = process.argv[2];
  fs.writeFileSync(file, "A " + process.argv[3] + "/x B " + process.argv[4] + "/y\n");
  m.redactFile(file, { projectRoot: process.argv[3], home: "" });
  process.stdout.write(fs.readFileSync(file, "utf8").trim());
' "$REDACT" "$PROJ/.zensu/logs/2026-01-01-0020_tdd-union.log" "$WORK/callerroot" "$PROJ" 2>/dev/null)"
if [ "$OUT30" = "A <project>/x B <project>/y" ]; then
  check "R30 redactFile unions the caller root with the artifact-derived root" PASS
else
  check "R30 redactFile unions the caller root with the artifact-derived root (got: $OUT30)" FAIL
fi

# ── R31: a relative artifact path resolves against the given base ────
OUT31="$(cd "$WORK" && node -e '
  const m = require(process.argv[1]);
  const a = m.resolveArtifactTarget(".zensu/logs/2026-01-01-0000_tdd-demo.log", undefined, process.argv[2]);
  const b = m.resolveArtifactTarget(".zensu/logs/2026-01-01-0000_tdd-demo.log");
  process.stdout.write(String(a.ok) + ":" + String(b.ok));
' "$REDACT" "$PROJ" 2>/dev/null)"
if [ "$OUT31" = "true:false" ]; then
  check "R31 a relative artifact path resolves against the base, not the process cwd" PASS
else
  check "R31 a relative artifact path resolves against the base (got: $OUT31)" FAIL
fi

# ── R32: a throwing redact degrades to identity, never a lost entry ──
# The hook installs its fallback around the CALL, not just the module load: a
# throw from redact would otherwise reach the outer handler, which emits an empty
# session field and drops the whole witness ENTRY — fail-CLOSED, the opposite of
# what the hook promises. The closure is extracted from the hook and evaluated
# against a throwing stub, so the pin is the real expression rather than a
# paraphrase of it.
R32_CLOSURE="$(grep -F 'redact = (v) => { try { return mod.redact(v, opts); } catch (_) { return v; } };' "$WITNESS_HOOK")"
if [ -n "$R32_CLOSURE" ]; then
  OUT32="$(node -e '
    const mod = { redact() { throw new Error("boom"); } };
    const opts = {};
    let redact;
    eval(process.argv[1].trim());
    process.stdout.write(redact("cd /Users/x && npm test"));
  ' "$R32_CLOSURE" 2>/dev/null)"
  # Binding the closure to its CALL SITE is the other half: without it the
  # wrapper can be bypassed (`mod.redact(...)` called directly) with the extracted
  # literal still intact and this check still green.
  R32_CALLS="$(grep -cF 'mod.redact(' "$WITNESS_HOOK")"
  if [ "$OUT32" = "cd /Users/x && npm test" ] \
    && grep -qF 'redact(j.tool_input.command)' "$WITNESS_HOOK" \
    && [ "$R32_CALLS" -eq 1 ]; then
    check "R32 a throwing redact degrades to identity, and the wrapper is the only caller" PASS
  else
    check "R32 a throwing redact degrades to identity (out=$OUT32 mod.redact calls=$R32_CALLS)" FAIL
  fi
else
  check "R32 the witness hook wraps the redact CALL, not only the module load" FAIL
fi

# ── R33: the reason sets are a real partition, and dev/ino is enforced ─
OUT33="$(node -e '
  const m = require(process.argv[1]);
  const sets = [m.CLEAN_REASONS, m.TRANSIENT_REASONS, m.NON_ARTIFACT_REASONS];
  const all = sets.flatMap((s) => [...s]);
  const disjoint = all.length === new Set(all).size;
  process.stdout.write([
    disjoint ? "disjoint" : "overlap",
    m.TRANSIENT_REASONS.has("concurrent-write") ? "race" : "no-race",
    m.TRANSIENT_REASONS.has("moved") ? "moved" : "no-moved",
    m.CLEAN_REASONS.has("written") ? "written" : "no-written",
  ].join(" "));
' "$REDACT" 2>/dev/null)"
if [ "$OUT33" = "disjoint race moved written" ]; then
  check "R33 the three reason sets are disjoint and carry their documented members" PASS
else
  check "R33 the three reason sets are disjoint and carry their documented members (got: $OUT33)" FAIL
fi

# The dev/ino re-derivation. Its REJECT direction is a race no shell can stage
# deterministically, so it is pinned structurally in
# tests/structure/test-windows-portability-guards.sh alongside the two opens it
# guards; what this suite owns is the ACCEPT direction — the check must not
# refuse a perfectly ordinary artifact, which is how an over-strict guard would
# show up in production.
OUT33B="$(env HOME="$FAKE_HOME" node -e '
  const fs = require("node:fs");
  const path = require("node:path");
  const m = require(process.argv[1]);
  const file = path.join(process.argv[2], "2026-01-01-0021_tdd-ino.log");
  fs.writeFileSync(file, "A " + process.argv[3] + "\n");
  const first = m.redactFile(file, { projectRoot: process.argv[4], expectedRoot: process.argv[4], home: "" });
  const second = m.redactFile(file, { projectRoot: process.argv[4], expectedRoot: process.argv[4], home: "" });
  process.stdout.write(first.reason + " " + second.reason);
' "$REDACT" "$PROJ/.zensu/logs" "$FOREIGN_USER" "$PROJ" 2>/dev/null)"
if [ "$OUT33B" = "redacted no-op" ]; then
  check "R33b the dev/ino guard accepts an ordinary artifact (not over-strict), twice" PASS
else
  check "R33b the dev/ino guard accepts an ordinary artifact (got: $OUT33B)" FAIL
fi

# ── R36: the Write matcher sweeps too, so a subagent artifact is caught ─
# The hook is main-principal only, so an artifact a SUBAGENT wrote is picked up
# only by a later main-thread pass. Sweeping on the write matchers too adds
# SAMPLING POINTS — more chances to catch such an artifact inside its own window.
# It extends no deadline: the cutoff is the artifact's own mtime and nothing here
# touches it.
STRAY="$PROJ/.zensu/logs/2026-01-01-0024_tdd-stray.log"
printf 'STRAY %s\n' "$LEAK_TEXT" > "$STRAY"
UNRELATED="$PROJ/.zensu/plans/2026-01-01-0024_tdd-unrelated.md"
printf '# UNRELATED\n' > "$UNRELATED"
printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$UNRELATED")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
assert_clean "stray artifact reached only by the write-matcher sweep" "$STRAY" R36 R36b R36c
assert_survived "the stray log line" "$STRAY" 'STRAY ' R36d

# ── R37: the named-file path is load-bearing, not just the sweep ─────
# Every artifact the other Write arms hand over is also in the sweep set, so none
# of them can tell the two paths apart. Backdating this one past the window makes
# the named `file_path` the ONLY way it can be reached.
STALE_NAMED="$PROJ/.zensu/plans/2026-01-01-0025_tdd-stale.md"
printf '# STALE %s\n' "$LEAK_TEXT" > "$STALE_NAMED"
node -e '
  const fs = require("fs");
  const old = new Date(Date.now() - 3600 * 1000);
  fs.utimesSync(process.argv[1], old, old);
' "$STALE_NAMED"
printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$STALE_NAMED")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
if [ -f "$STALE_NAMED" ] && ! grep -qF "$FOREIGN_USER" "$STALE_NAMED" \
  && grep -qF '# STALE' "$STALE_NAMED" && grep -qF '<project>' "$STALE_NAMED"; then
  check "R37 a named file outside the sweep window is still redacted (the named path bites)" PASS
else
  check "R37 a named file outside the sweep window is still redacted" FAIL
fi
rm -f "$STALE_NAMED"

# ── R37b: the named path also reaches an off-extension artifact ──────
# The hook states two reasons the named path is not redundant. R37 covers the
# window; this covers the other: `sweepTargets` filters on the bucket extension
# while `resolveArtifactTarget` does not, so `.zensu/logs/notes.txt` is reachable
# only by being named.
ODD_EXT="$PROJ/.zensu/logs/notes.txt"
printf 'ODD %s\n' "$LEAK_TEXT" > "$ODD_EXT"
printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$ODD_EXT")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
if [ -f "$ODD_EXT" ] && ! grep -qF "$FOREIGN_USER" "$ODD_EXT" && grep -qF 'ODD ' "$ODD_EXT"; then
  check "R37b a named artifact the sweep skips on extension is still redacted" PASS
else
  check "R37b a named artifact the sweep skips on extension is still redacted" FAIL
fi
rm -f "$ODD_EXT"

# ── R35: redactFile refuses a witness artifact too ────────────────────
# The exclusion is not a sweep-only property: the targeted Edit/Write branch
# reaches redactFile with a caller-supplied path, and the witness `tail` must
# stay raw or a failure token inside an absolute path is swallowed and an
# EVIDENCE CONTRADICTION downgrades to `verified`.
WITNESS_RF="$PROJ/.zensu/logs/witness-redactfile.log"
printf 'WITNESS RF %s\n' "$FOREIGN_USER" > "$WITNESS_RF"
R35_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$WITNESS_RF" --project "$PROJ" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$R35_ERR" | grep -qF '(witness-artifact)' \
  && grep -qF "$FOREIGN_USER" "$WITNESS_RF"; then
  check "R35 redactFile refuses a witness artifact, not only the sweep" PASS
else
  check "R35 redactFile refuses a witness artifact (rc=$RC err=$R35_ERR)" FAIL
fi
rm -f "$WITNESS_RF"

# ── R34: a FIFO at an artifact path is refused, never hung on ─────────
FIFO="$PROJ/.zensu/logs/2026-01-01-0023_tdd-fifo.log"
if mkfifo "$FIFO" 2>/dev/null; then
  R34_ERR="$(env HOME="$FAKE_HOME" node "$REDACT" --file "$FIFO" --project "$PROJ" 2>&1 >/dev/null)"
  RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$R34_ERR" | grep -qF '(not-a-file)'; then
    check "R34 a FIFO at an artifact path is refused as not-a-file (O_NONBLOCK prevents the hang)" PASS
  else
    check "R34 a FIFO at an artifact path is refused as not-a-file (rc=$RC err=$R34_ERR)" FAIL
  fi
  rm -f "$FIFO"
else
  skip "R34 FIFO refusal (host did not create a FIFO)"
fi

# ── R38: a refusal is reported ONCE, not once per spelling ───────────
# A Write payload naming an artifact that is ALSO in the sweep set is the only
# shape where the dedup can be observed: without it the same refusal is emitted
# twice, once under the caller spelling and once under the sweep one.
DUP_PEER="$WORK/dup-peer.log"
DUP="$PROJ/.zensu/logs/2026-01-01-0026_tdd-dup.log"
printf 'DUP %s\n' "$FOREIGN_USER" > "$DUP_PEER"
if ln "$DUP_PEER" "$DUP" 2>/dev/null; then
  DUP_ERR="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
    "$(json_str "$DUP")" "$(json_str "$SESSION")" \
    | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" 2>&1 >/dev/null)"
  DUP_COUNT="$(printf '%s\n' "$DUP_ERR" | grep -cF "$DUP")"
  if [ "$DUP_COUNT" -eq 1 ]; then
    check "R38 a named artifact that is also swept is reported exactly once" PASS
  else
    check "R38 a named artifact that is also swept is reported exactly once (count=$DUP_COUNT)" FAIL
  fi
  rm -f "$DUP"
else
  skip "R38 dedup observation (host did not create a hard link)"
fi

# ── R39: the main-principal guard R36's rationale rests on ───────────
# R36 explains itself by "the hook is main-principal only". Nothing observed that
# until now, so the guard could be deleted with the whole suite green while R36's
# stated justification quietly became false.
SUB_STRAY="$PROJ/.zensu/logs/2026-01-01-0027_tdd-substray.log"
printf 'SUBSTRAY %s\n' "$LEAK_TEXT" > "$SUB_STRAY"
printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s,"agent_type":"zensu:code-reviewer","agent_id":"sub-1"}' \
  "$(json_str "$PLANF")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
SUB_UNTOUCHED=no
grep -qF "$FOREIGN_USER" "$SUB_STRAY" && SUB_UNTOUCHED=yes
# The paired positive: the IDENTICAL payload with the two agent fields removed
# must redact. Without it, any early exit in the hook satisfies the negative and
# the principal guard could be deleted with this check still green.
printf '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":%s},"tool_response":{},"session_id":%s}' \
  "$(json_str "$PLANF")" "$(json_str "$SESSION")" \
  | env HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$PROJ" bash "$ARTIFACT_HOOK" >/dev/null 2>&1
if [ "$SUB_UNTOUCHED" = "yes" ] && ! grep -qF "$FOREIGN_USER" "$SUB_STRAY"; then
  check "R39 a subagent payload is ignored while the same payload from the main thread acts" PASS
else
  check "R39 a subagent payload is ignored (untouched=$SUB_UNTOUCHED)" FAIL
fi
rm -f "$SUB_STRAY"

# ── R40: credential VALUES are refused, not redacted ─────────────────
# Moving the message off the command line removed the incidental scan
# `pre-write-secret-scan.sh` used to perform on it; `append` restores that control
# at the new chokepoint. It REFUSES rather than rewriting: a credential value is
# not a location, and silently redacting one would hide it from whoever has to
# rotate it. The fixture is assembled at run time from brace expansions so this
# file carries no matchable literal for the plugin's own secret gate.
SECRET_LOG="$PROJ/.zensu/logs/2026-01-01-0028_tdd-secret.log"
rm -f "$SECRET_LOG"
SECRET_KEY="aws_$(printf secret)_access_key"
SECRET_VAL="$(printf '%s' {a..z} | tr -d ' ')$(printf '%s' {0..9} | tr -d ' ')ABCD"
SECRET_MSG="$SECRET_KEY = \"$SECRET_VAL\""
R40_ERR="$(HOME="$FAKE_HOME" bash "$LOG_HELPER" append --log "$SECRET_LOG" --message "$SECRET_MSG" 2>&1 >/dev/null)"
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$R40_ERR" | grep -qF 'secret-value-detected' \
  && [ ! -f "$SECRET_LOG" ]; then
  check "R40 a credential value is refused, and no partial line is written" PASS
else
  check "R40 a credential value is refused (rc=$RC err=$R40_ERR)" FAIL
fi

# The escape the repo already teaches must work, or a false positive is a wedge.
HOME="$FAKE_HOME" ZENSU_SECRET_SCAN=off bash "$LOG_HELPER" append \
  --log "$SECRET_LOG" --message "$SECRET_MSG" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$SECRET_LOG" ] && grep -qF "$SECRET_KEY" "$SECRET_LOG"; then
  check "R40a ZENSU_SECRET_SCAN=off is honoured, so a false positive is not a wedge" PASS
else
  check "R40a ZENSU_SECRET_SCAN=off is honoured (rc=$RC)" FAIL
fi
rm -f "$SECRET_LOG"

# ── R41: an in-project directory named home/Users/root survives ──────
# Rules 1-2 emit `<project>` and `~`, whose last characters (`>`, `~`) are not in
# the LEFT class, so rule 3 used to fire immediately after them and collapse an
# ordinary in-project `home/` directory into `<project><home>`. That is a loss of
# audit fidelity, not a redaction gap — both writers mangled it identically, so the
# witness/claim equality survived and nothing else could see it.
#
# `Users` is the case that matters most and is easiest to leave out: it is the ONE
# spelling where the placeholder lookbehind meets the rule-3 alternative that
# CONSUMES a following segment, so a regression there eats the directory NAME
# (`<project>/Users/x` -> `<project><home>`) rather than merely a prefix. The
# `/Users/other/z` row is its discrimination partner — it proves rule 3 still fires
# where no placeholder precedes it, so a rule neutered into a no-op cannot pass.
OUT41="$(node -e '
  const m = require(process.argv[1]);
  const o = { projectRoot: process.argv[2], home: process.argv[3] };
  const cases = [
    ["cmd=\"ls " + process.argv[2] + "/home/config.yml\"", "cmd=\"ls <project>/home/config.yml\""],
    ["cmd=\"ls " + process.argv[2] + "/Users/x\"", "cmd=\"ls <project>/Users/x\""],
    ["cmd=\"ls " + process.argv[2] + "/Users/x/y.ts\"", "cmd=\"ls <project>/Users/x/y.ts\""],
    ["cmd=\"ls " + process.argv[2] + "/root/x\"", "cmd=\"ls <project>/root/x\""],
    ["cmd=\"ls " + process.argv[3] + "/home/y\"", "cmd=\"ls ~/home/y\""],
    ["cmd=\"ls " + process.argv[3] + "/Users/y\"", "cmd=\"ls ~/Users/y\""],
    ["cmd=\"ls /Users/other/z\"", "cmd=\"ls <home>/z\""],
  ];
  const bad = cases.filter(([i, w]) => m.redact(i, o) !== w).map(([i]) => i);
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$PROJ" "$FAKE_HOME" 2>/dev/null)"
if [ "$OUT41" = "OK" ]; then
  check "R41 an in-project directory named home/Users/root survives the residual rules" PASS
else
  check "R41 an in-project directory named home/Users/root survives (bad: $OUT41)" FAIL
fi

# ── R42: the residual rules replace the PATH and nothing after it ────
# SEGMENT excluded only the separators, whitespace and the two quote characters,
# so `;`, `:`, `)` and `.` were all valid segment characters and the greedy
# quantifier ran past the end of the path. The replacement then swallowed the
# punctuation and everything up to the next separator, DELETING text from an
# artifact a consuming repo commits as evidence. Redaction that removes more than
# the identifier is a fidelity defect, not a redaction gap: `cd /home/x;ls` lost
# the command that followed the `cd`.
OUT42="$(node -e '
  const m = require(process.argv[1]);
  const o = { projectRoot: process.argv[2], home: process.argv[3] };
  const cases = [
    ["cd /home/runner;ls -la", "cd <home>;ls -la"],
    ["PATH=/Users/otherdev:/usr/bin", "PATH=<home>:/usr/bin"],
    ["[notes](/home/runner)", "[notes](<home>)"],
    ["the checkout at /home/runner.", "the checkout at <home>."],
    ["run /home/runner, then stop", "run <home>, then stop"],
    ["cmd=\"ls /home/otherdev\"", "cmd=\"ls <home>\""],
    ["/homework/notes.md", "/homework/notes.md"],
    ["src/home/index.ts", "src/home/index.ts"],
  ];
  const bad = cases.filter(([i, w]) => m.redact(i, o) !== w)
    .map(([i, w]) => i + " => " + m.redact(i, o) + " (want " + w + ")");
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$PROJ" "$FAKE_HOME" 2>/dev/null)"
if [ "$OUT42" = "OK" ]; then
  check "R42 the residual rules replace the path and leave every following character intact" PASS
else
  check "R42 the residual rules replace the path and leave every following character intact (bad: $OUT42)" FAIL
fi

# ── R43: a mixed-separator path redacts like a pure one ──────────────
# RESIDUAL_RULES[0] used SEP_POSIX for the prefix AND the segment separator while
# RESIDUAL_RULES[1] used SEP_WIN for both, so neither could cross forms: the rule
# matched the prefix, the optional segment group failed on the other separator,
# and BOUNDARY succeeded on it. The output then LOOKED redacted while still
# naming the developer, which is worse than a miss — the assertable guarantee
# ("the file contains no /Users/") was satisfied by a string that still carried
# the identifier. The pure-separator rows are the discrimination partners: they
# prove the rule was never neutered into a no-op.
OUT43="$(node -e '
  const m = require(process.argv[1]);
  const o = { projectRoot: process.argv[2], home: process.argv[3] };
  const cases = [
    ["C:/Users\\bob", "C:<home>"],
    ["C:\\Users/bob", "C:<home>"],
    ["C:\\Users\\bob", "C:<home>"],
    ["/Users/bob/x", "<home>/x"],
    ["\\/Users\\/bob", "<home>"],
    ["/Users\\/bob", "<home>"],
    ["C:\\\\Users\\\\bob", "C:<home>"],
  ];
  const bad = cases.filter(([i, w]) => m.redact(i, o) !== w)
    .map(([i, w]) => JSON.stringify(i) + " => " + JSON.stringify(m.redact(i, o)) + " (want " + JSON.stringify(w) + ")");
  process.stdout.write(bad.length ? bad.join(" | ") : "OK");
' "$REDACT" "$PROJ" "$FAKE_HOME" 2>/dev/null)"
if [ "$OUT43" = "OK" ]; then
  check "R43 a mixed-separator path leaves no user segment behind" PASS
else
  check "R43 a mixed-separator path leaves no user segment behind (bad: $OUT43)" FAIL
fi

# ── R26: a SKIP on a POSIX host is a defect, not a pass ──────────────
# finish() reports SKIP separately, but the runner aggregates on the exit code
# alone, so a SKIP would otherwise be invisible in CI. On a host where the guards
# are genuinely exercisable, any SKIP means a check silently did not run.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] || [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
  if [ "$SKIP" -eq 0 ]; then
    check "R26 no guard check was skipped on a POSIX host" PASS
  else
    check "R26 no guard check was skipped on a POSIX host ($SKIP skipped)" FAIL
  fi
else
  check "R26 no guard check was skipped on a POSIX host (not a POSIX host)" PASS
fi

finish
