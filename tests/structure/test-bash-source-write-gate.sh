#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh"
PARSER="$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/pre-bash-source-write-gate.sh exists" FAIL
  echo "----"; echo "test-bash-source-write-gate: $PASS PASS / $FAIL FAIL"; exit 1
fi

# ── Structure pins ───────────────────────────────────────────────────
[ -x "$HOOK" ] && check "W1 hook exists + executable" PASS || check "W1 hook exists + executable" FAIL
bash -n "$HOOK" 2>/dev/null && check "W2 hook bash -n syntax" PASS || check "W2 hook bash -n syntax" FAIL
{ [ -f "$PARSER" ] && node --check "$PARSER" 2>/dev/null; } \
  && check "W3 parser exists + node --check" PASS || check "W3 parser exists + node --check" FAIL

node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const pres=(h.hooks&&h.hooks.PreToolUse)||[];
  const ok=pres.some(e=>(e.matcher||"")==="Bash" && (e.hooks||[]).some(z=>/pre-bash-source-write-gate\.sh/.test(z.command||"")));
  process.exit(ok?0:1);
' "$HOOKS_JSON" 2>/dev/null \
  && check "W4 registered as PreToolUse Bash matcher" PASS || check "W4 registered as PreToolUse Bash matcher" FAIL

grep -qF 'zensu_hook_enabled bashWriteGate' "$HOOK" \
  && check "W5 config-gated via zensu_hook_enabled bashWriteGate (default-on)" PASS \
  || check "W5 config-gated via zensu_hook_enabled bashWriteGate (default-on)" FAIL

# ── Behavioral harness ───────────────────────────────────────────────
# A real (nested) git project + a sibling checkout. A controlled fake-temp dir
# (via the ZENSU_BSWGATE_TEMP_DIRS seam) keeps verdicts independent of where the
# repo itself is checked out.
WORKROOT="$PLUGIN_DIR/tests/.bswgate-tmp.$$"
trap 'rm -rf "$WORKROOT"' EXIT
PROJ="$WORKROOT/proj"; SIB="$WORKROOT/sibling"; FAKETMP="$WORKROOT/faketmp"
mkdir -p "$PROJ/src" "$PROJ/build" "$SIB/src" "$FAKETMP"
(
  cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'fn main(){}\n' > src/app.rs && printf 'build/\n' > .gitignore \
    && git add src/app.rs .gitignore && git commit -qm init && printf 'gen\n' > build/gen.rs
) >/dev/null 2>&1
(
  cd "$SIB" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'pub fn x(){}\n' > src/lib.rs && git add src/lib.rs && git commit -qm init
) >/dev/null 2>&1

CFG_DEF="$(mktemp -t bswgate-def-XXXXXX)";  printf '%s' '{"hooks":{}}'                    > "$CFG_DEF"
CFG_OFF="$(mktemp -t bswgate-off-XXXXXX)";   printf '%s' '{"hooks":{"bashWriteGate":false}}' > "$CFG_OFF"
export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_TEST_PLUGIN_DATA="$WORKROOT/plugin-data"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" bswgate-test

payload() {
  CMD="$1" CWD="${2:-$PROJ}" node -e '
    const o={hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.env.CMD},cwd:process.env.CWD,session_id:"bswgate-test"};
    process.stdout.write(JSON.stringify(o));
  '
}
classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("ALLOW");return;}
      try{const j=JSON.parse(s);const d=j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision;process.stdout.write(d==="deny"?"DENY":(d||"OTHER"));}
      catch(_){process.stdout.write("BADJSON");}
    });
  '
}
# run <label> <cmd> <expected> [cwd] [cfg] [claude-env-file]
run() {
  local label="$1" cmd="$2" exp="$3" cwd="${4:-$PROJ}" cfg="${5:-$CFG_DEF}" env_file="${6:-$PROJ/.claude-env}"
  local out
  out="$(payload "$cmd" "$cwd" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
        -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_ENV_FILE="$env_file" \
        ZENSU_CONFIG="$cfg" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}

# (A) clobber existing tracked source -> DENY
run "W6 append >> tracked .rs"              "printf 'x\n' >> src/app.rs"            DENY
run "W7 clobber > tracked .rs"              "printf 'x\n' > src/app.rs"             DENY
run "W8 glued >>tracked (no space)"         "printf x >>src/app.rs"                 DENY
run "W9 tee tracked .rs"                    "echo x | tee src/app.rs"               DENY
run "W10 tee -a tracked .rs"               "echo x | tee -a src/app.rs"            DENY
run "W11 sed -i '' tracked .rs"            "sed -i '' 's/x/y/' src/app.rs"         DENY
run "W12 sed -i.bak tracked .rs"          "sed -i.bak 's/x/y/' src/app.rs"        DENY
run "W13 dd of= tracked .rs"              "dd if=/dev/null of=src/app.rs"         DENY
HEREDOC="$(printf 'cat > src/app.rs <<EOF\nZZZ_BROKEN\nEOF\n')"
run "W14 heredoc clobber tracked .rs"     "$HEREDOC"                              DENY

# (B) worktree / project escape -> DENY (even for new files)
run "W15 relative escape to sibling"      "printf x >> ../sibling/src/lib.rs"     DENY
run "W16 cd-into-sibling then write"      "cd ../sibling && printf x >> src/lib.rs" DENY
run "W17 escape, brand-new file"          "printf x > ../sibling/src/brandnew.rs" DENY
run "W18 absolute escape path"            "printf x >> $SIB/src/lib.rs"           DENY

# Allow — Bash keeps normal file power
run "W19 new file inside project"         "printf x > src/newfile.rs"             ALLOW
run "W20 glued new file inside project"   "printf x >src/newfile2.rs"             ALLOW
run "W21 non-source extension (.md)"      "echo hi > notes.md"                    ALLOW
run "W22 gitignored existing .rs"         "printf x >> build/gen.rs"              ALLOW
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  SKIP  W23 temp-dir source write (MSYS: native node cannot map /x/ mount paths to the mangled env override)" ;;
  *)
    run "W23 temp-dir source write"       "printf x >> $FAKETMP/scratch.rs"       ALLOW ;;
esac
run "W24 read, no write"                  "cat src/app.rs"                        ALLOW
run "W25 plain command, no write"         "git status"                            ALLOW
run "W26 arithmetic compare (not redir)"  "test 5 -gt 3 && echo ok"               ALLOW

# Escape hatch + config
run "W27 inline ZENSU_BASH_WRITE_GATE=off" "ZENSU_BASH_WRITE_GATE=off printf x >> src/app.rs" ALLOW
run "W28 inline ZENSU_MCP_GATE=off"        "ZENSU_MCP_GATE=off printf x >> src/app.rs"        ALLOW
run "W29 config bashWriteGate:false"       "printf x >> src/app.rs" ALLOW "$PROJ" "$CFG_OFF"

# Process-env escape (set on the hook process itself)
OUT="$(payload 'printf x >> src/app.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_BASH_WRITE_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "W30 process-env ZENSU_BASH_WRITE_GATE=off -> ALLOW" PASS \
  || check "W30 process-env escape (got '$OUT')" FAIL

# The parser remains fail-open only after a trusted hook session is bound;
# empty/non-JSON payloads cannot establish that binding and are denied.
OUT="$(printf '' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_DEF" bash "$HOOK" 2>/dev/null | classify)"
OUT2="$(printf '%s' 'not json' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_DEF" bash "$HOOK" 2>/dev/null | classify)"
{ [ "$OUT" = "DENY" ] && [ "$OUT2" = "DENY" ]; } \
  && check "W31 empty + non-JSON cannot bind a hook session -> DENY" PASS \
  || check "W31 binding failure (empty='$OUT' nonjson='$OUT2')" FAIL

# Deny-reason content
REASON_A="$(payload 'printf x >> src/app.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$REASON_A" | grep -qF 'tracked' && printf '%s' "$REASON_A" | grep -qF 'ZENSU_BASH_WRITE_GATE=off'; } \
  && check "W32 clobber deny-reason: 'tracked' + escape-hatch hint" PASS \
  || check "W32 clobber deny-reason content" FAIL

REASON_B="$(payload 'printf x >> ../sibling/src/lib.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$REASON_B" | grep -qiF 'worktree' && printf '%s' "$REASON_B" | grep -qF 'ZENSU_BASH_WRITE_GATE=off'; } \
  && check "W33 escape deny-reason: 'worktree' + escape-hatch hint" PASS \
  || check "W33 escape deny-reason content" FAIL

# ── Regression pins from review round 1 ──────────────────────────────
# fd / quoting / redirect-variant correctness
run "W34 stderr-redirect is not a write"        "cat src/app.rs 2>&1"                       ALLOW
run "W35 redirect + trailing 2>&1 gated"        "printf x > src/app.rs 2>&1"                DENY
run "W36 quoted '>' in a message arg"           'git commit -m "refactor > faster"'         ALLOW
run "W37 quoted path, no redirect operator"     'echo "see src/app.rs"'                     ALLOW
run "W41 glued single-quoted redirect path"     "printf x >'src/app.rs'"                    DENY
run "W42 glued double-quoted append path"       "printf x >>\"src/app.rs\""                 DENY
run "W43 dd of= quoted path"                    "dd if=/dev/null of='src/app.rs'"           DENY
run "W44 redirect-all &> gated"                 "printf x &> src/app.rs"                     DENY
run "W45 redirect-all append &>> gated"         "printf x &>> src/app.rs"                    DENY
run "W51 noclobber override >| gated"           "echo x >| src/app.rs"                       DENY
run "W52 noclobber override glued >|"           "printf x >|src/app.rs"                      DENY
run "W53 of= only gated for dd (not echo)"      "echo of=src/app.rs"                         ALLOW

# transparent wrappers (env/sudo/command) must not hide the real verb
run "W55 env-wrapped sed -i"                    "env sed -i '' 's/x/y/' src/app.rs"         DENY
run "W56 sudo-wrapped dd of="                   "sudo dd if=/dev/null of=src/app.rs"        DENY
run "W57 env-wrapped redirect still gated"      "env printf x > src/app.rs"                 DENY

# >&FILE redirect-all-to-file (the &> mirror); fd dups (>&2 / >&-) stay ALLOW
run "W58 >& redirect-all to tracked (spaced)"   "printf x >& src/app.rs"                     DENY
run "W59 >& redirect-all to tracked (glued)"    "printf x >&src/app.rs"                      DENY
run "W60 >&2 fd-dup is not a file write"        "echo x >&2"                                 ALLOW
run "W61 >&- fd-close is not a file write"      "echo x >&-"                                 ALLOW
# accepted lexical limitation (documented): tee >(proc) severs a trailing real file
run "W62 tee >(proc) realfile (accepted gap)"   "echo x | tee >(cat) src/app.rs"             ALLOW

# tee multi-target + process substitution + interspersed redirect
run "W38 tee two targets, one tracked"          "echo x | tee notes.md src/app.rs"          DENY
run "W39 tee process-substitution"              "echo x | tee >(cat)"                        ALLOW
run "W50 tee with interspersed redirect"        "echo x | tee > /dev/null src/app.rs"        DENY

# cd scoping: escaped-cd still tracks cwd; subshell cd does not leak
run "W47 escaped cd still tracks cwd"           "ZENSU_BASH_WRITE_GATE=off cd ../sibling && printf x >> src/lib.rs" DENY
run "W48 subshell cd does not leak (no FP)"     "(cd ../sibling) && printf x > src/new.rs"   ALLOW
run "W49 in-subshell escape still caught"       "(cd ../sibling && printf x > src/lib.rs)"   DENY

# here-string (<<<) must not be treated as a heredoc and swallow a later write
HS="$(printf 'grep p <<<WORD\nprintf y > src/app.rs\n')"
run "W46 here-string does not swallow next write" "$HS"                                      DENY

# escape suppressed by config also covers rule B (escape), not just rule A
run "W40 escape suppressed by bashWriteGate:false" "printf x >> ../sibling/src/lib.rs" ALLOW "$PROJ" "$CFG_OFF"

# Protected Session Control inputs and CLAUDE_ENV_FILE remain immutable even
# when the source-write convention is disabled or an escape hatch is present.
run "W63 direct Session Control export assignment" "ZENSU_PROJECT_ROOT=/tmp/other env" DENY
run "W64 exported Session Control rebind" "export ZENSU_SESSION_CONTEXT=/tmp/other" DENY
run "W65 unset Session Control export" "unset ZENSU_SESSION_KEY" DENY
run "W66 printf -v Session Control rebind" "printf -v ZENSU_RUNTIME_DIGEST bad" DENY
run "W67 append through CLAUDE_ENV_FILE variable" 'printf '\''export ZENSU_PROJECT_ROOT=/tmp/other\n'\'' >> "$CLAUDE_ENV_FILE"' DENY
run "W68 native CLAUDE_ENV_FILE vs Git-Bash command path" \
  "printf x >> /d/a/zensu-claude-code/session/.claude-env" DENY "$PROJ" "$CFG_DEF" \
  'D:\a\zensu-claude-code\session\.claude-env'
run "W69 control rebind ignores bashWriteGate:false" "ZENSU_CLAUDE_PLUGIN_ROOT=/tmp/other env" DENY "$PROJ" "$CFG_OFF"
run "W70 control rebind ignores inline escape" "ZENSU_BASH_WRITE_GATE=off ZENSU_PROJECT_ROOT=/tmp/other env" DENY
run "W71 protected path prefix is not an exact CLAUDE_ENV_FILE match" \
  "printf x >> /d/a/zensu-claude-code/session/.claude-env.backup" ALLOW "$PROJ" "$CFG_DEF" \
  'D:\a\zensu-claude-code\session\.claude-env'
run "W72 symbolic CLAUDE_ENV_FILE reference is independent of native path parsing" \
  'printf x >> "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_DEF" \
  'D:\a\zensu-claude-code\session\.claude-env'
run "W73 POSIX CLAUDE_ENV_FILE comparison remains case-sensitive and exact" \
  "printf x >> /Users/Runner/Session/.claude-env" DENY "$PROJ" "$CFG_DEF" \
  '/Users/Runner/Session/.claude-env'
run "W74 POSIX CLAUDE_ENV_FILE does not fold case" \
  "printf x >> /users/runner/session/.claude-env" ALLOW "$PROJ" "$CFG_DEF" \
  '/Users/Runner/Session/.claude-env'
run "W75 direct host session-id assignment" "CLAUDE_CODE_SESSION_ID=other env" DENY
run "W76 exported host session-id rebind" "export CLAUDE_CODE_SESSION_ID=other" DENY
run "W77 unset host session-id" "unset CLAUDE_CODE_SESSION_ID" DENY
run "W78 printf -v host session-id rebind" "printf -v CLAUDE_CODE_SESSION_ID other" DENY
run "W79 host session-id rebind ignores bashWriteGate:false" \
  "CLAUDE_CODE_SESSION_ID=other env" DENY "$PROJ" "$CFG_OFF"

# The mandatory control parser is a trust boundary. A selective runtime failure
# must deny before config and escape hatches instead of falling through.
REAL_NODE="$(command -v node)"
CONTROL_FAIL_BIN="$WORKROOT/control-fail-bin"
mkdir -p "$CONTROL_FAIL_BIN"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "${BSWG_MODE:-}" = "control" ]; then exit 23; fi' \
  'exec "${ZENSU_TEST_REAL_NODE:?}" "$@"' \
  > "$CONTROL_FAIL_BIN/node"
chmod +x "$CONTROL_FAIL_BIN/node"
OUT_CONTROL_FAIL="$(payload 'git status' | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
  -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
  PATH="$CONTROL_FAIL_BIN:$PATH" ZENSU_TEST_REAL_NODE="$REAL_NODE" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_ENV_FILE="$PROJ/.claude-env" \
  ZENSU_CONFIG="$CFG_OFF" ZENSU_BASH_WRITE_GATE=off \
  bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT_CONTROL_FAIL" = "DENY" ] \
  && check "W80 control-parser runtime failure denies before config and escapes" PASS \
  || check "W80 control-parser runtime failure (got '$OUT_CONTROL_FAIL')" FAIL

# rule precedence: an escaped AND tracked target reports the worktree (B) reason
REASON_ESC="$(payload "printf x >> $SIB/src/lib.rs" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
            ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
printf '%s' "$REASON_ESC" | grep -qiF 'worktree' \
  && check "W54 escaped+tracked target reports rule-B (worktree) reason" PASS \
  || check "W54 escaped+tracked rule precedence" FAIL

# ── Unbindable session ───────────────────────────────────────────────
# A session whose Session Control record cannot be read (resumed across a plugin
# update, or started before Session Control existed) used to lose EVERY Bash
# call here, which deadlocked /zensu:doctor behind the defect it reports. The
# write rules must survive that state; everything else must get through.
UNBOUND_DATA="$WORKROOT/unbound-plugin-data"
mkdir -p "$UNBOUND_DATA"
chmod 700 "$UNBOUND_DATA"
run_unbound() {
  local label="$1" cmd="$2" exp="$3"
  local out
  out="$(payload "$cmd" "$PROJ" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
        -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_ENV_FILE="$PROJ/.claude-env" \
        CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
        ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}
run_unbound "W81 unbound + read-only command"        "git status"                         ALLOW
run_unbound "W82 unbound + the doctor invocation"    'bash "$ROOT/hooks/lib/zensu-doctor.sh"' ALLOW
run_unbound "W83 unbound + write to tracked source"  "printf x >> src/app.rs"             DENY
run_unbound "W84 unbound + write escaping project"   "printf x >> $SIB/src/lib.rs"         DENY
run_unbound "W85 unbound + Session Control rebind"   "export ZENSU_SESSION_KEY=scv1_dead"  DENY
run_unbound "W86 unbound + new untracked source"     "printf x > src/brandnew.rs"          ALLOW

# The unbound deny must keep the ORIGINAL write-rule cause and its escape hint —
# not only the appended binding sentence, or dropping the cause would leave every
# assertion green while the user loses the reason the write was refused.
REASON_UNBOUND="$(payload "printf x >> src/app.rs" "$PROJ" | env -u ZENSU_SESSION_KEY \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$REASON_UNBOUND" | grep -qF 'tracked' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF 'ZENSU_BASH_WRITE_GATE=off' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF 'no Session Control record' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF '/zensu:doctor'; } \
  && check "W87 unbound rule-A deny keeps its cause, escape hint, binding gap and /zensu:doctor" PASS \
  || check "W87 unbound deny reason (got '$REASON_UNBOUND')" FAIL
REASON_UNBOUND_B="$(payload "printf x >> $SIB/src/lib.rs" "$PROJ" | env -u ZENSU_SESSION_KEY \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
printf '%s' "$REASON_UNBOUND_B" | grep -qF 'worktree' \
  && check "W87a unbound rule-B deny still reports the worktree-escape cause" PASS \
  || check "W87a unbound rule-B reason (got '$REASON_UNBOUND_B')" FAIL

# The inline-escape arm of the unbound branch: without it the raw __bypass__
# marker would leak into a user-facing deny.
run_unbound "W87b unbound + inline ZENSU_BASH_WRITE_GATE=off" "ZENSU_BASH_WRITE_GATE=off printf x >> src/app.rs" ALLOW
run_unbound "W87c unbound + inline ZENSU_MCP_GATE=off"        "ZENSU_MCP_GATE=off printf x >> src/app.rs"        ALLOW

# The payload cwd must never become the project authority while unbound: rule (B)
# protects files that do not exist yet, so only it can catch this write, and a
# model-influenced cwd would otherwise make every path look in-project.
OUT_UNBOUND_CWD="$(CMD="printf x > $SIB/src/never-created.rs" CWD="/" node -e '
  process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",
    tool_input:{command:process.env.CMD},cwd:process.env.CWD,session_id:"bswgate-test"}));
' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT_UNBOUND_CWD" = "DENY" ] \
  && check "W87d unbound ignores a payload cwd that would collapse the worktree rule" PASS \
  || check "W87d unbound payload-cwd authority (got '$OUT_UNBOUND_CWD')" FAIL

# Without a project root there is no authority to judge a write against, so the
# gate refuses rather than allowing unchecked. The target must be one NO other
# rule can catch — a file that does not exist (so rule A cannot fire) inside the
# project (so rule B would not fire either) — or the case would pass whether or
# not the guard exists.
OUT_UNBOUND_NOPROJ="$(payload "printf x > src/never-created-here.rs" "$PROJ" | env -u CLAUDE_PROJECT_DIR \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$OUT_UNBOUND_NOPROJ" | grep -qF 'permissionDecision":"deny' \
  && printf '%s' "$OUT_UNBOUND_NOPROJ" | grep -qF 'no usable CLAUDE_PROJECT_DIR'; } \
  && check "W87e unbound without CLAUDE_PROJECT_DIR denies with that exact cause" PASS \
  || check "W87e unbound missing project root (got '$OUT_UNBOUND_NOPROJ')" FAIL


# A parser that cannot RUN must not degrade into a blanket allow.
PARSER_FAIL_BIN="$WORKROOT/parser-fail-bin"
mkdir -p "$PARSER_FAIL_BIN"
printf '%s\n' '#!/bin/bash' \
  'if [ "${BSWG_MODE-unset}" = "" ]; then exit 42; fi' \
  'exec "${ZENSU_TEST_REAL_NODE:?}" "$@"' > "$PARSER_FAIL_BIN/node"
chmod +x "$PARSER_FAIL_BIN/node"
OUT_PARSER_FAIL="$(payload "printf x >> src/app.rs" "$PROJ" | env \
  PATH="$PARSER_FAIL_BIN:$PATH" ZENSU_TEST_REAL_NODE="$(command -v node)" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT_PARSER_FAIL" = "DENY" ] \
  && check "W87f unbound parser runtime failure denies, never allows unchecked" PASS \
  || check "W87f unbound parser failure (got '$OUT_PARSER_FAIL')" FAIL

# The relaxation covers ONE state. A record that exists but disagrees with the
# executing installation is a security signal and keeps denying every command.
FOREIGN_DATA="$WORKROOT/foreign-plugin-data"
FOREIGN_PLUG="$WORKROOT/foreign-plug"
mkdir -p "$FOREIGN_DATA/session-control/v1/records" "$FOREIGN_DATA/session-control/v1/locks" \
  "$FOREIGN_PLUG/.claude-plugin" "$FOREIGN_PLUG/hooks"
chmod 700 "$FOREIGN_DATA" "$FOREIGN_DATA/session-control" "$FOREIGN_DATA/session-control/v1" \
  "$FOREIGN_DATA/session-control/v1/records" "$FOREIGN_DATA/session-control/v1/locks"
printf '{"name":"zensu","version":"9.9.9"}\n' > "$FOREIGN_PLUG/.claude-plugin/plugin.json"
printf '{"hooks":{}}\n' > "$FOREIGN_PLUG/hooks/hooks.json"
if node -e '
  const path = require("path");
  const [corePath, data, plug, project, sessionId] = process.argv.slice(1);
  require(corePath).registerContext({
    recordsDir: path.join(data, "session-control", "v1", "records"),
    host: "claude", sessionId, projectRoot: project, pluginRoot: plug, pluginData: data,
  });
' "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" "$FOREIGN_DATA" "$FOREIGN_PLUG" "$PROJ" "bswgate-test" 2>/dev/null; then
  OUT_FOREIGN="$(payload "git status" "$PROJ" | env \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$FOREIGN_DATA" \
    ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$OUT_FOREIGN" = "DENY" ] \
    && check "W87g a record from another installation stays fail-closed, relaxation is not reused" PASS \
    || check "W87g foreign record (got '$OUT_FOREIGN')" FAIL
else
  check "W87g foreign-record fixture could not be minted" FAIL
fi

# The predicate is the single authority four gates now trust, so pin its own
# contract rather than only the two states the consumers happen to reach.
# Loosening it to swallow errors other than ENOENT would widen the relaxation
# while leaving every consumer suite green.
BINDER_MOD="$PLUGIN_DIR/hooks/lib/claude-hook-session-v1.js"
predicate_says_unregistered() {
  printf '{"hook_event_name":"PreToolUse","session_id":"bswgate-test","tool_input":{"command":"x"}}' \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$1" \
      node "$BINDER_MOD" unregistered >/dev/null 2>&1
}
predicate_says_unregistered "$UNBOUND_DATA" \
  && check "W90 predicate: an absent records store is unregistered" PASS \
  || check "W90 predicate: an absent records store is unregistered" FAIL

# The shared deny emitter serves callers with different knowledge. A caller that
# has NOT ruled out the unregistered state must not tell a user with no record
# that the doctor is denied — that is the one command still reachable for them.
# Nothing pinned this before, which is how a wrong diagnosis landed green once.
SESSION_LIB="$PLUGIN_DIR/hooks/lib/zensu-session.sh"
DENY_DEFAULT="$(bash -c 'source "$1"; zensu_emit_hook_session_deny' _ "$SESSION_LIB" 2>/dev/null)"
DENY_NARROWED="$(bash -c 'source "$1"; zensu_emit_hook_session_deny narrowed' _ "$SESSION_LIB" 2>/dev/null)"
{ printf '%s' "$DENY_DEFAULT" | grep -qF 'immutable Zensu session binding is unavailable' \
  && printf '%s' "$DENY_DEFAULT" | grep -qF '/zensu:doctor' \
  && ! printf '%s' "$DENY_DEFAULT" | grep -qF 'including the doctor stays denied'; } \
  && check "W95 the un-narrowed deny keeps the doctor pointer for a no-record session" PASS \
  || check "W95 un-narrowed deny (got '$DENY_DEFAULT')" FAIL
{ printf '%s' "$DENY_NARROWED" | grep -qF 'immutable Zensu session binding is unavailable' \
  && printf '%s' "$DENY_NARROWED" | grep -qF 'not the no-record state'; } \
  && check "W96 the narrowed deny says the no-record state was already ruled out" PASS \
  || check "W96 narrowed deny (got '$DENY_NARROWED')" FAIL
# Only callers that actually pre-filter may claim the narrowed scope.
NARROWED_CALLERS="$(grep -rlF 'zensu_emit_hook_session_deny narrowed' "$PLUGIN_DIR/hooks" 2>/dev/null | sort)"
NARROWED_EXPECTED="$(printf '%s\n%s\n' "$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh" "$PLUGIN_DIR/hooks/pre-write-secret-scan.sh" | sort)"
[ "$NARROWED_CALLERS" = "$NARROWED_EXPECTED" ] \
  && check "W97 only the two predicate-filtering gates use the narrowed deny scope" PASS \
  || check "W97 narrowed-scope callers (got '$NARROWED_CALLERS')" FAIL
predicate_says_unregistered "$FOREIGN_DATA" \
  && check "W91 predicate: a record from another installation is NOT unregistered" FAIL \
  || check "W91 predicate: a record from another installation is NOT unregistered" PASS
LOOSE_DATA="$WORKROOT/loose-plugin-data"
mkdir -p "$LOOSE_DATA/session-control/v1/records"
chmod 700 "$LOOSE_DATA" "$LOOSE_DATA/session-control" "$LOOSE_DATA/session-control/v1"
chmod 0755 "$LOOSE_DATA/session-control/v1/records"
LOOSE_MODE="$(stat -f '%Lp' "$LOOSE_DATA/session-control/v1/records" 2>/dev/null \
  || stat -c '%a' "$LOOSE_DATA/session-control/v1/records" 2>/dev/null)"
if [ "$LOOSE_MODE" = "755" ]; then
  predicate_says_unregistered "$LOOSE_DATA" \
    && check "W92 predicate: a group/other-readable records store is NOT unregistered" FAIL \
    || check "W92 predicate: a group/other-readable records store is NOT unregistered" PASS
else
  check "W92 predicate loose-perms case (skipped: filesystem ignores mode bits)" PASS
fi
if printf '{"hook_event_name":"PreToolUse","session_id":"bswgate-test","tool_input":{"command":"x"}}' \
  | env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" node "$BINDER_MOD" unregistered >/dev/null 2>&1; then
  check "W93 predicate: an unset CLAUDE_PLUGIN_DATA is NOT unregistered" FAIL
else
  check "W93 predicate: an unset CLAUDE_PLUGIN_DATA is NOT unregistered" PASS
fi
if printf '{"hook_event_name":"PreToolUse","session_id":"bswgate-test","tool_input":{"command":"x"}}' \
  | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
    node "$BINDER_MOD" unregistered extra-arg >/dev/null 2>&1; then
  check "W94 predicate: the CLI mode rejects extra arguments" FAIL
else
  check "W94 predicate: the CLI mode rejects extra arguments" PASS
fi

# An unparseable envelope is NOT the unbindable-session case: with no readable
# command there is nothing to judge, so it keeps the original deny (see W31).
OUT_UNBOUND_EMPTY="$(printf '' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" ZENSU_CONFIG="$CFG_DEF" bash "$HOOK" 2>/dev/null | classify)"
OUT_UNBOUND_JUNK="$(printf '%s' 'not json' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" ZENSU_CONFIG="$CFG_DEF" bash "$HOOK" 2>/dev/null | classify)"
{ [ "$OUT_UNBOUND_EMPTY" = "DENY" ] && [ "$OUT_UNBOUND_JUNK" = "DENY" ]; } \
  && check "W88 unbound + unparseable payload still denies" PASS \
  || check "W88 unbound unparseable (empty='$OUT_UNBOUND_EMPTY' junk='$OUT_UNBOUND_JUNK')" FAIL

# The explicit escapes stay reachable while unbound — a user who knowingly opts
# out must not need a bindable session to do it.
OUT_UNBOUND_ESCAPE="$(payload "printf x >> src/app.rs" "$PROJ" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" ZENSU_CONFIG="$CFG_DEF" \
  ZENSU_BASH_WRITE_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT_UNBOUND_ESCAPE" = "ALLOW" ] \
  && check "W89 unbound + process-env escape -> ALLOW" PASS \
  || check "W89 unbound process-env escape (got '$OUT_UNBOUND_ESCAPE')" FAIL

rm -f "$CFG_DEF" "$CFG_OFF"

echo "----"
echo "test-bash-source-write-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
