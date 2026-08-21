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
