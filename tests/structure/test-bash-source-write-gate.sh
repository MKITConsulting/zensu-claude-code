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

UNIT="$PLUGIN_DIR/tests/structure/git-repo-escape.test.js"
if [ ! -f "$UNIT" ]; then
  check "W3a rule-C unit suite is missing from the checkout ($UNIT) — stage it with the change" FAIL
elif UNIT_OUT="$(node --test "$UNIT" 2>&1)"; then
  UNIT_PASS="$(printf '%s' "$UNIT_OUT" | sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p;s/^. pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
  # Exit 0 alone would also accept a file that registers zero cases.
  # Raise this with the file. The win32 cases are the ONLY witnesses of the MSYS
  # namespace fix — no POSIX host executes that branch end-to-end — so a stale
  # floor would let every one of them be deleted with this suite green.
  # A count floor only catches deletion-without-replacement; the win32 block could
  # be swapped for the same number of unrelated POSIX cases with it still green. So
  # pin the symbols too — those cases are the only witnesses of the MSYS fix.
  UNIT_SYMS=1
  for sym in "msysToDrive(" "splitTempList(" "isUnsafeTempEntry(" "winTempList(" "path.win32"; do
    grep -qF -- "$sym" "$UNIT" || UNIT_SYMS=0
  done
  if [ -n "$UNIT_PASS" ] && [ "$UNIT_PASS" -ge 45 ] && [ "$UNIT_SYMS" -eq 1 ]; then
    check "W3a rule-C option lattice unit suite passes ($UNIT_PASS cases, win32 witnesses present)" PASS
  else
    check "W3a rule-C unit suite reported '${UNIT_PASS:-no}' passing cases (want >= 45) win32_symbols=$UNIT_SYMS" FAIL
  fi
else
  check "W3a rule-C unit suite: $(printf '%s' "$UNIT_OUT" | grep -E '✖|fail [0-9]' | head -3 | tr '\n' ' ')" FAIL
fi

# `within` is a hand-copy of reviewer-capability-v1.js's isInside. Nothing but this
# pin notices if one is hardened and the gate keeps the old semantics.
# Compare the CLAUSES, not the spelling: the risk is one copy losing a guard, and
# a byte-comparison would instead fail on a harmless reorder or quote style.
contain_clauses() {
  printf '%s' "$1" | tr -d ' \n' | tr -d "\`'" | sed -e 's/"//g' -e 's/\${path.sep}/+path.sep/' \
    | grep -oE '===?\$?\{?\}?$|===""|!==\.\.|startsWith\(\.\.\+path\.sep|path\.isAbsolute' | sort -u
}
CONTAIN_A="$(contain_clauses "$(grep -A2 -F 'function within(root, p)' "$PARSER")")"
CONTAIN_B="$(contain_clauses "$(grep -A2 -F 'function isInside(base, candidate)' "$PLUGIN_DIR/hooks/lib/reviewer-capability-v1.js")")"
{ [ -n "$CONTAIN_A" ] && [ "$CONTAIN_A" = "$CONTAIN_B" ]; } \
  && check "W3b within() carries the same containment guards as reviewer-capability isInside()" PASS \
  || check "W3b containment guards diverged — parser=[$(printf '%s' "$CONTAIN_A" | tr '\n' ',')] capability=[$(printf '%s' "$CONTAIN_B" | tr '\n' ',')]" FAIL

# On Windows the project root arrives MSYS-converted (`D:\a\proj`, because it was
# exported) while the payload cwd and every command token arrive over stdin still
# spelled `/d/a/proj`. path.resolve does not bridge those — it reads the leading
# `/` as drive-relative and splices the POSIX path under the current drive — so a
# path that skips msysToDrive re-enters the comparison in a namespace of its own
# and the session's OWN root reads as an escape. That defect lives in
# path.resolve's platform behavior, so this suite cannot observe it from a POSIX
# host and git-repo-escape.test.js can only pin the normalizer itself. Hence a
# structural pin: every resolution site routes through it, and it stays
# platform-gated — dropping the guard would rewrite legitimate POSIX `/d/...`
# paths and hand rules (B) and (C) a different tree entirely.
# Match the PLATFORM ARGUMENT too, not just the call. Pinning `msysToDrive(` alone
# accepts a site written `msysToDrive(p, true)`, which would rewrite legitimate
# POSIX `/d/...` paths on macOS and Linux — the very regression this pin claims to
# prevent, and one no behavioral case can see, because the unit suite drives the
# function through its explicit parameter and never through IS_WINDOWS. The base
# operand is matched as any identifier so a parameter rename does not fail the pin.
# Cover the qualified spellings too: `path.posix.normalize` is already live in this
# file, so `path.posix.resolve(`/`path.win32.resolve(` is a spelling a future edit
# would reach for, and it would reintroduce the split namespace invisibly.
NS_UNROUTED="$(grep -nE 'path\.(posix\.|win32\.)?(resolve|join)\(' "$PARSER" | grep -v ':[[:space:]]*//' \
  | grep -vE 'path\.resolve\(([A-Za-z_$][A-Za-z0-9_$.]*, )?msysToDrive\(.*, IS_WINDOWS\)' \
  | cut -d: -f1 | tr '\n' ' ')"
NS_GATED="$(grep -c 'if (!isWindows' "$PARSER")"
# And pin the flag's own definition: a typo such as "windows" or "Windows_NT"
# leaves every assertion in both files green with the whole branch dead.
NS_FLAG="$(grep -c '^const IS_WINDOWS = process\.platform === "win32";$' "$PARSER")"
# gitTargets takes the platform so the unit layer can drive the win32 isPathish arm,
# and its DEFAULT is what production runs — the sole call site passes three arguments.
# Every unit case passes the flag explicitly, so narrowing the default to
# `isWindows === true` would kill that arm on Windows with the whole suite green.
NS_DEFAULT="$(grep -c 'isWindows === undefined ? IS_WINDOWS' "$PARSER")"
NS_CALLSITE="$(grep -c 'gitTargets(args, curdir, resolveFrom);' "$PARSER")"
NS_EXPORTED=0
node -e 'process.exit(typeof require(process.argv[1]).msysToDrive === "function"
  && typeof require(process.argv[1]).splitTempList === "function" ? 0 : 1)' "$PARSER" 2>/dev/null \
  && NS_EXPORTED=1
{ [ -z "$NS_UNROUTED" ] && [ "$NS_GATED" -ge 1 ] && [ "$NS_FLAG" -eq 1 ] && [ "$NS_EXPORTED" -eq 1 ] \
  && [ "$NS_DEFAULT" -eq 1 ] && [ "$NS_CALLSITE" -eq 1 ]; } \
  && check "W3c every path.resolve site routes through msysToDrive under IS_WINDOWS" PASS \
  || check "W3c namespace normalizer drift — unrouted:[$NS_UNROUTED] gated=$NS_GATED flag=$NS_FLAG exported=$NS_EXPORTED default=$NS_DEFAULT callsite=$NS_CALLSITE" FAIL

# msysToDrive is a hand-copy of claude-path-v1.js's MSYS branch — this parser
# takes no sibling require, and that module fails closed by THROWING, which here
# would deny every Bash call instead of the one command. Same trade as W3b's
# within()/isInside() copy, so it needs the same lockstep pin: nothing else
# notices if one spelling is corrected and the other keeps the old rule.
# The MSYS drive rule is SHARED, not copied: msysToDrive delegates to
# claude-path-v1.js's msysDrivePrefix. Pin that shape rather than a regex
# lockstep — a reintroduced private copy is the regression, and a lockstep pin
# would happily bless one. The remaining two `([A-Za-z])` rules in this parser are
# controlPathNamespace's ungated lower-casing pair, which serve the separate
# CLAUDE_ENV_FILE namespace on purpose; a third means a copy came back.
MSYS_SHARED="$(grep -c 'require("\./claude-path-v1\.js")' "$PARSER")"
MSYS_DELEGATES="$(grep -A2 -F 'function msysToDrive(' "$PARSER" | grep -c 'msysDrivePrefix(value')"
MSYS_RE_COUNT="$(grep -cE '\(\[A-Za-z\]\)' "$PARSER")"
MSYS_HOST_TOTAL="$(grep -c '^function msysDrivePrefix(value, platform' "$PLUGIN_DIR/hooks/lib/claude-path-v1.js")"
# And the shared rule must stay TOTAL — the moment it throws, this parser's hook
# denies every Bash call in the session instead of the one command.
MSYS_HOST_THROWS="$(grep -A4 -F 'function msysDrivePrefix(' "$PLUGIN_DIR/hooks/lib/claude-path-v1.js" | grep -c 'throw')"
{ [ "$MSYS_SHARED" -eq 1 ] && [ "$MSYS_DELEGATES" -eq 1 ] && [ "$MSYS_RE_COUNT" -eq 2 ] \
  && [ "$MSYS_HOST_TOTAL" -eq 1 ] && [ "$MSYS_HOST_THROWS" -eq 0 ]; } \
  && check "W3d msysToDrive delegates to the shared claude-path-v1 rule and keeps no copy" PASS \
  || check "W3d MSYS rule drift — shared=$MSYS_SHARED delegates=$MSYS_DELEGATES private_rules=$MSYS_RE_COUNT (want 2) host_total=$MSYS_HOST_TOTAL host_throws=$MSYS_HOST_THROWS" FAIL

# A deny reason quotes paths in the PARSER's comparison namespace: on Windows
# path.resolve emits `D:\a\…`, while $PROJ/$SIB below are the Git Bash spellings
# this script builds with `pwd`. Grepping the raw shell spelling would assert the
# host's path convention rather than the message, and would fail on Windows for a
# reason that has nothing to do with the contract under test. Route both sides
# through the same composition the parser uses; identity on POSIX.
# No fallback on failure: substituting the raw value would silently degrade every
# assertion that consumes this to the pre-fix comparison, and on POSIX — where raw
# and normalized coincide — nobody would ever see it. Nor can this `exit` on its
# own protect the callers: they use it in a command substitution, and with no
# `set -e` an exiting subshell just expands to the empty string — which `grep -qF`
# then matches against ANY input, turning three deny-reason checks into vacuous
# passes. So every consumer reads a variable assigned here and is guarded non-empty.
gate_ns() {
  node -e '
    const p = require("path");
    const { msysToDrive } = require(process.argv[1]);
    process.stdout.write(p.resolve(msysToDrive(process.argv[2], process.platform === "win32")));
  ' "$PARSER" "$1"
}
# The NS_* variables are assigned after $PROJ/$SIB exist — see below the workroot
# setup. W3e proves they are non-empty before any assertion consumes them.

# Resolved once, because two probes below run node with a REWRITTEN PATH and the
# effect of a `PATH=… cmd` prefix on the lookup of `cmd` itself is unspecified.
NODE_BIN="$(command -v node)"

# Whether two spellings name the same real directory AS THE GATE SEES IT — the
# same fs.realpathSync.native the parser's canonical() uses, reached through the
# same msysToDrive composition. Git Bash `ln -s` exits 0 while producing a copy
# or a shortcut that native Node does not follow, so `ln -s` succeeding is not
# evidence that a symlink exists; without this the symlink pair asserts ALLOW for
# two directories that genuinely differ, and the resulting DENY is correct.
same_realpath() {
  "$NODE_BIN" -e '
    const fs = require("fs");
    const p = require("path");
    const { msysToDrive } = require(process.argv[1]);
    const n = (v) => p.resolve(msysToDrive(v, process.platform === "win32"));
    try {
      process.exit(fs.realpathSync.native(n(process.argv[2])) === fs.realpathSync.native(n(process.argv[3])) ? 0 : 1);
    } catch (e) {
      process.exit(1);
    }
  ' "$PARSER" "$1" "$2"
}

# The hook emits its verdict through JSON.stringify, which DOUBLES every
# backslash. A needle spelled `D:\a\…` can therefore never match a haystack
# spelling it `D:\\a\\…`, so grepping the raw stdout failed three deny-reason
# checks on Windows for a message that was already correct — and, worse, made
# W121b (whose job is to prove a spelling is ABSENT) pass without testing
# anything. On POSIX the encoding is identity, which is why it stayed invisible.
# Not valid JSON -> pass the bytes through, so a non-JSON deny is still checked.
# Valid JSON with no reason -> empty, so every consumer's grep fails loudly
# rather than falling back to the escaped haystack this exists to avoid.
# Defined here, ahead of W3f/W3g: calling it earlier is a command-not-found whose
# only trace is stderr, and the command substitution flattens that to "" with no
# `set -e` to stop on it — the same silent-empty failure mode W3e already guards
# for gate_ns.
reason() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      const t=s.trim();
      if(!t){return;}
      let j;
      try{j=JSON.parse(t);}catch(_){process.stdout.write(s);return;}
      const o=j&&j.hookSpecificOutput;
      process.stdout.write((o&&o.permissionDecisionReason)||"");
    });
  '
}

node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const pres=(h.hooks&&h.hooks.PreToolUse)||[];
  const ok=pres.some(e=>(e.matcher||"")==="Bash" && (e.hooks||[]).some(z=>/pre-bash-source-write-gate\.sh/.test(z.command||"") && z.timeout===60));
  process.exit(ok?0:1);
' "$HOOKS_JSON" 2>/dev/null \
  && check "W4 registered as PreToolUse Bash matcher with timeout 60" PASS || check "W4 registered as PreToolUse Bash matcher with timeout 60" FAIL

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

# Resolve the deny-reason spellings ONCE, now that the paths exist, and prove they
# are non-empty. A command substitution swallows the helper's exit status, and an
# empty needle makes `grep -qF` match ANY input — so without this guard a broken
# helper would turn W121/W183/W204/W224 into vacuous passes rather than failures.
NS_SIB="$(gate_ns "$SIB")"
NS_PROJ="$(gate_ns "$PROJ")"
NS_SIB_WT="$(gate_ns "$SIB/wt")"
{ [ -n "$NS_SIB" ] && [ -n "$NS_PROJ" ] && [ -n "$NS_SIB_WT" ]; } \
  && check "W3e the deny-reason namespace helper resolves every expected path" PASS \
  || check "W3e gate_ns produced an empty spelling — deny-reason checks would match anything (sib=[$NS_SIB] proj=[$NS_PROJ] wt=[$NS_SIB_WT])" FAIL

# The escaping defect itself, pinned where every host can see it. The hook writes
# its reason through JSON.stringify, so a native path arrives with every
# backslash DOUBLED and a `D:\a\…` needle cannot match. On POSIX no path carries
# a backslash, which is exactly why grepping raw stdout stayed green here for as
# long as it did while three Windows checks failed on a message that was already
# correct. Feeding a synthetic reason makes the mechanism observable everywhere:
# absent from the raw envelope, present once decoded.
BS_PATH='D:\a\proj\sibling'
BS_JSON="$(node -e '
  process.stdout.write(JSON.stringify({hookSpecificOutput:{hookEventName:"PreToolUse",
    permissionDecision:"deny",permissionDecisionReason:"Blocked (D:\\a\\proj\\sibling)."}}));
')"
BS_DECODED="$(printf '%s' "$BS_JSON" | reason)"
if printf '%s' "$BS_JSON" | grep -qF "$BS_PATH"; then
  check "W3f raw hook stdout was expected to escape the backslash path but did not (got '$BS_JSON')" FAIL
elif printf '%s' "$BS_DECODED" | grep -qF "$BS_PATH"; then
  check "W3f reason() decodes the JSON escaping that hides a native path from grep -F" PASS
else
  check "W3f reason() lost the decoded path (got '$BS_DECODED')" FAIL
fi

# And every deny-reason capture must actually go through it. One capture left on
# raw stdout is invisible on POSIX and silently re-opens the same Windows hole.
SELF="$PLUGIN_DIR/tests/structure/test-bash-source-write-gate.sh"
CAP_TOTAL="$(grep -c 'REASON_[A-Z_]*="\$(payload' "$SELF")"
CAP_DECODED="$(grep -c 'bash "\$HOOK" 2>/dev/null | reason)"$' "$SELF")"
{ [ "$CAP_TOTAL" -gt 0 ] && [ "$CAP_TOTAL" -eq "$CAP_DECODED" ]; } \
  && check "W3g every deny-reason capture is decoded before it is grepped" PASS \
  || check "W3g deny-reason captures bypass the decoder (captures=$CAP_TOTAL decoded=$CAP_DECODED)" FAIL

# The premise the whole fix rests on. MSYS rewrites env and ARGV on the way into a
# native binary but never touches STDIN — which is precisely why the payload cwd
# and every command token still arrive spelled `/d/a/…` for path.resolve to splice
# under the current drive. Pin the stdin half directly: were a toolchain to start
# converting stdin too, msysToDrive would be normalizing an already-native path,
# every assertion here would stay green, and the real defect would have moved
# somewhere this suite does not look. The argv value is captured only to name the
# contrast in the failure text — it is the channel that IS rewritten.
STDIN_ECHO="$(printf '%s' "$SIB" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ process.stdout.write(s); });
')"
ARGV_ECHO="$(node -e 'process.stdout.write(process.argv[1])' "$SIB")"
[ "$STDIN_ECHO" = "$SIB" ] \
  && check "W3h stdin reaches node unconverted — the namespace split rule (B)/(C) must bridge" PASS \
  || check "W3h stdin was rewritten before node saw it (sent='$SIB' got='$STDIN_ECHO' argv='$ARGV_ECHO')" FAIL
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
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" bswgate-test \
  || { check "W0 session-control baseline bootstrap" FAIL; echo "----"; echo "test-bash-source-write-gate: $PASS PASS / $FAIL FAIL"; exit 1; }

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
  local label="$1" cmd="$2" exp="$3" cwd="${4:-$PROJ}" cfg="${5:-$CFG_DEF}" env_file="${6:-$PROJ/.claude-env}" home="${7:-${HOME:-}}"
  local out
  out="$(payload "$cmd" "$cwd" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
        -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_ENV_FILE="$env_file" \
        HOME="$home" \
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
# Formerly skipped on MSYS because "native node cannot map /x/ mount paths to the
# mangled env override" — which is exactly the defect msysToDrive and splitTempList
# fix, so the skip is now stale by construction. Every run() already passes the
# override, and W116/W175/W181 depend on it reaching TEMP; what W23 uniquely covers
# is the rule (B) side — a source WRITE under the temp root rather than a git verb
# addressed at it — and that arm would otherwise stay unexercised on Windows.
run "W23 temp-dir source write"           "printf x >> $FAKETMP/scratch.rs"       ALLOW
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
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_A" | grep -qF 'tracked' && printf '%s' "$REASON_A" | grep -qF 'ZENSU_BASH_WRITE_GATE=off'; } \
  && check "W32 clobber deny-reason: 'tracked' + escape-hatch hint" PASS \
  || check "W32 clobber deny-reason content" FAIL

REASON_B="$(payload 'printf x >> ../sibling/src/lib.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
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
            ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
printf '%s' "$REASON_ESC" | grep -qiF 'worktree' \
  && check "W54 escaped+tracked target reports rule-B (worktree) reason" PASS \
  || check "W54 escaped+tracked rule precedence" FAIL

# The parser refuses to promote the payload cwd to project authority on its own,
# not merely because the hook checks first. Both hook branches shield this, so
# without a direct probe the invariant could be deleted with the suite green.
PARSER_PAYLOAD='{"tool_input":{"command":"printf x > src/new.rs"},"cwd":"'"$PROJ"'"}'
if PAYLOAD="$PARSER_PAYLOAD" env -u CLAUDE_PROJECT_DIR node "$PARSER" >/dev/null 2>&1; then
  PARSER_NOROOT=allowed
else
  PARSER_NOROOT=refused
fi
if PAYLOAD="$PARSER_PAYLOAD" CLAUDE_PROJECT_DIR="$PROJ" node "$PARSER" >/dev/null 2>&1; then
  PARSER_ROOT=ok
else
  PARSER_ROOT=broken
fi
{ [ "$PARSER_NOROOT" = refused ] && [ "$PARSER_ROOT" = ok ]; } \
  && check "W227 the parser itself refuses an empty CLAUDE_PROJECT_DIR" PASS \
  || check "W227 parser project-root invariant (no-root=$PARSER_NOROOT with-root=$PARSER_ROOT)" FAIL

# ── Rule (C): git repository escape ──────────────────────────────────
# git reaches the same cross-checkout contamination as rule (B) without naming a
# write target at all, so no redirect/tee/sed/dd channel can see it. Gated only
# on ESCAPE: every mutation inside the session's own root stays ungated.
run "W98 -C absolute sibling add"              "git -C $SIB add ."                          DENY
run "W99 -C relative sibling commit"           "git -C ../sibling commit -m x"              DENY
run "W100 cd sibling then bare git add -A"     "cd ../sibling && git add -A"                DENY
run "W101 cumulative -C resolves like git"     "git -C .. -C sibling add ."                 DENY
run "W102 global -c operand does not hide -C"  "git -c user.name=x -C $SIB commit -m y"     DENY
run "W103 env-wrapped git escape"              "env git -C $SIB commit -m x"                DENY
run "W104 sudo-wrapped git escape"             "sudo git -C $SIB checkout ."                DENY
# The WRAP members that actually work — `nice`/`sudo -u` take their own flags and
# are a documented gap, so these are the ones worth pinning.
run "W189 command-wrapped git escape"          "command git -C $SIB add ."                  DENY
run "W190 exec-wrapped git escape"             "exec git -C $SIB add ."                     DENY
run "W191 nohup-wrapped git escape"            "nohup git -C $SIB add ."                    DENY
run "W105 git clean escape"                    "git -C $SIB clean -fd"                      DENY
run "W106 git restore escape"                  "git -C $SIB restore src/lib.rs"             DENY
run "W107 git reset escape"                    "git -C $SIB reset --hard"                   DENY
run "W108 in-subshell git escape"              "(cd ../sibling && git add .)"               DENY
# A pipe before the git verb must not erase an earlier `cd` — bash keeps it.
run "W228 cd survives a pipeline stage"        "cd ../sibling && git log | head && git add -A" DENY
run "W229 export survives a pipeline stage"    "export GIT_WORK_TREE=$SIB && true | true && git add -A" DENY
# ...but a cd made INSIDE the ending stage does not survive it.
run "W230 cd inside a pipeline stage does not leak" "cd ../sibling | true && git add -A"     ALLOW
run "W231 a later unexpanded -C invalidates an absolute one" \
  'git -C '"$SIB"' -C $BACK add -A'                                                          ALLOW
run "W109 in-project mutation stays ungated"   "git add -A"                                 ALLOW
run "W110 in-project -C mutation stays ungated" "git -C $PROJ commit -m x"                  ALLOW
run "W111 read-only status on sibling"         "git -C $SIB status"                         ALLOW
run "W112 read-only log on sibling"            "git -C $SIB log --oneline"                  ALLOW
run "W113 read-only rev-parse on sibling"      "git -C $SIB rev-parse HEAD"                 ALLOW
run "W114 worktree add is not a gated verb"    "git -C $SIB worktree add $WORKROOT/wt"      ALLOW
run "W115 subshell cd does not leak to git"    "(cd ../sibling) && git add ."               ALLOW
run "W116 temp-root repo carve-out"            "git -C $FAKETMP add ."                      ALLOW

# The incident this rule exists for: no -C, no cd — the payload cwd itself had
# drifted to the main checkout and a bare `git add -A` staged it. Only the
# `repo = curdir` seed can catch this, so without these three the seed is
# unwitnessed. The trailing-slash spelling is the regression pin for the
# un-normalized seed: it denied every in-project git verb before the fix.
run "W131 foreign payload cwd, bare git add"   "git add -A"          DENY  "$SIB"
run "W132 nested in-project payload cwd"       "git add -A"          ALLOW "$PROJ/src"
run "W133 trailing-slash payload cwd"          "git add -A"          ALLOW "$PROJ/"
run "W134 dot-segment payload cwd"             "git add -A"          ALLOW "$PROJ/src/.."
# W133/W134 are sanity controls, not regression pins — path.relative already
# returns "" for those spellings without any normalization. The discriminating
# witness for the canonicalized seed is the symlink pair below.
#
# The hook hands over a project root it already canonicalized while the payload
# cwd arrives as the host spelled it. A symlinked cwd is the real-world form of
# that split (macOS /var -> /private/var), and lexically the two never overlap,
# so an uncanonicalized seed denies both a new-file write and every git verb in
# the user's OWN project. W169 is the paired control: its target is absolute, so
# it denies with or without the canonicalization. Skipped where symlinks are
# unavailable — the reported PASS total is therefore platform-dependent, matching
# the existing W23 convention.
# `ln -s` exiting 0 is NOT evidence that a symlink exists: Git Bash satisfies it
# with a directory copy or a shortcut that native Node never follows. The two
# directories are then genuinely different, DENY is the correct verdict, and the
# ALLOW pair below would fail for a premise that does not hold rather than for
# the contract under test. Confirm the link through the very primitive the gate
# canonicalizes with, so this runs wherever real symlinks exist and skips only
# where the harness could not build one.
if ln -s "$PROJ" "$WORKROOT/proj-link" 2>/dev/null && same_realpath "$WORKROOT/proj-link" "$PROJ"; then
  run "W167 symlinked payload cwd, git mutation" "git add -A"        ALLOW "$WORKROOT/proj-link"
  run "W168 symlinked payload cwd, new file"     "printf x > src/viasym.rs" ALLOW "$WORKROOT/proj-link"
  run "W169 symlinked payload cwd still catches an escape" "printf x >> $SIB/src/lib.rs" DENY "$WORKROOT/proj-link"
else
  echo "  SKIP  W167-W169 symlinked payload cwd (no symlink the gate's realpath follows)"
fi

# TEMP_REAL is the realpath'd copy of the temp list, and it needs the SAME guards
# the raw list carries. A temp entry whose raw spelling is harmless but whose
# realpath is an ancestor of the project widens only after canonicalization: with
# the guard absent, that ancestor lands in TEMP_REAL and isTemp() then returns true
# for EVERY path, switching rules (B) and (C) off with no bypass-ledger entry.
# W234 is the control, so an unconditional-deny regression cannot satisfy W233.
if ln -s "$WORKROOT" "$WORKROOT/tmplink" 2>/dev/null; then
  OUT_TEMPLINK="$(payload "printf x >> $SIB/src/lib.rs" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PROJECT_DIR="$PROJ" ZENSU_CONFIG="$CFG_DEF" \
    ZENSU_BSWGATE_TEMP_DIRS="$WORKROOT/tmplink" bash "$HOOK" 2>/dev/null | classify)"
  [ "$OUT_TEMPLINK" = "DENY" ] \
    && check "W233 a temp entry whose realpath contains the project does not exempt everything" PASS \
    || check "W233 temp realpath ancestor exempted the tree (got '$OUT_TEMPLINK' want 'DENY')" FAIL
  OUT_TEMPLINK_OK="$(payload "printf x >> $FAKETMP/scratch.rs" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PROJECT_DIR="$PROJ" ZENSU_CONFIG="$CFG_DEF" \
    ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$OUT_TEMPLINK_OK" = "ALLOW" ] \
    && check "W234 control: an ordinary temp root still carves out" PASS \
    || check "W234 control temp carve-out broke (got '$OUT_TEMPLINK_OK' want 'ALLOW')" FAIL
else
  echo "  SKIP  W233-W234 temp realpath guard (symlinks unavailable)"
fi
# A nested dir whose NAME starts with '..' is inside the project; a bare
# startsWith("..") containment test calls it an escape.
mkdir -p "$PROJ/..bak"
run "W135 nested '..bak' dir is not an escape" "git -C ..bak add ."                         ALLOW

# Read-only spellings of gated verbs: denying these would assert something false.
run "W136 stash list on sibling"               "git -C $SIB stash list"                     ALLOW
run "W137 stash show on sibling"               "git -C $SIB stash show"                     ALLOW
run "W138 clean --dry-run on sibling"          "git -C $SIB clean --dry-run"                ALLOW
run "W139 clean -nd on sibling"                "git -C $SIB clean -nd"                      ALLOW
run "W140 apply --check on sibling"            "git -C $SIB apply --check p.patch"          ALLOW
run "W141 rm --dry-run on sibling"             "git -C $SIB rm --dry-run f"                 ALLOW
run "W142 stash push on sibling is gated"      "git -C $SIB stash push"                     DENY
run "W143 clean -fd on sibling is gated"       "git -C $SIB clean -fd"                      DENY

# worktree is gated for remove/move only — add/list/prune stay exempt.
run "W144 worktree remove on sibling"          "git -C $SIB worktree remove --force $WORKROOT/wt" DENY
run "W145 worktree move on sibling"            "git -C $SIB worktree move $SIB/a $SIB/b"    DENY
# A bare worktree NAME resolves against a list this parser never reads, so it is
# unjudgeable and passes rather than denying on a repository whose own tree the
# command never touches. Accepted gap, documented in the parser header.
run "W188 bare worktree name is unjudgeable"   "git -C $SIB worktree remove --force pr-42"  ALLOW
# An unexpanded token carries no location; path.resolve would splice the literal
# under the cwd and call it in-project, so the addressing is judged neither way.
run "W193 unexpanded -C operand is unresolved"  'git -C "$REPO" add -A'                      ALLOW
run "W194 unexpanded --work-tree is unresolved" 'git --work-tree="$WT" add -A'               ALLOW
run "W195 unexpanded worktree operand"          'git -C '"$SIB"' worktree remove --force "$WORKTREE"' ALLOW
# A `$` in a NON-addressing option says nothing about which repo is addressed and
# must not disarm the literal -C standing beside it.
run "W205 unexpanded -c value does not disarm a literal -C" \
  'git -c core.excludesFile=$HOME/.gitignore -C '"$SIB"' add -A'                             DENY
run "W206 unexpanded --namespace does not disarm a literal -C" \
  'git --namespace=$NS -C '"$SIB"' commit -m y'                                              DENY
run "W196 export GIT_WORK_TREE then git add"    "export GIT_WORK_TREE=$SIB && git add -A"    DENY
run "W197 export GIT_DIR then git commit"       "export GIT_DIR=$SIB/.git && git commit -m x" DENY
run "W198 export of an in-project work tree"    "export GIT_WORK_TREE=$PROJ && git add -A"   ALLOW
# rule (C) applies no extension filter — the README says so explicitly.
run "W199 non-source pathspec still denied"     "git -C $SIB add notes.md"                   DENY
# git's parse-options auto-negation: a later --no-dry-run cancels an earlier -n.
run "W200 clean -n --no-dry-run is a mutation"  "git -C $SIB clean -n --no-dry-run -fd"      DENY
run "W201 apply --stat --apply is a mutation"   "git -C $SIB apply --stat --apply p.patch"   DENY
run "W212 unexpanded --git-dir does not disarm a literal -C" \
  'git -C '"$SIB"' --git-dir=$GD add -A'                                                     DENY
# Control, not a regression pin: this stays ALLOW under the over-broad implementation too.
run "W213 unexpanded --git-dir beside an in-project -C (control)" \
  'git -C '"$PROJ"' --git-dir=$GD add -A'                                                    ALLOW
# Only -C re-bases every later resolution. An unexpanded --work-tree drops just
# its own candidate, so the literal escaping -C beside it is still judged.
run "W214 unexpanded --work-tree does not disarm a literal -C" \
  'git -C '"$SIB"' --work-tree=$WT add -A'                                                   DENY
run "W223 unexpanded -C suppresses a RELATIVE candidate" \
  'git -C $REPO --work-tree=../sibling add -A'                                               ALLOW
# ...but an absolute candidate resolves the same for every expansion of that -C.
run "W225 unexpanded -C does not hide an ABSOLUTE work tree" \
  'git -C $REPO --work-tree='"$SIB"' add -A'                                                 DENY
run "W226 unexpanded -C does not hide an ABSOLUTE worktree operand" \
  'git -C $REPO worktree remove --force '"$SIB"'/wt'                                         DENY
# expand(): only production's tilde handling makes these two differ. Without it
# both resolve to $PROJ/~ and both allow.
run "W215 tilde -C resolving outside HOME=sibling" "git -C ~ add ."                          DENY  "$PROJ" "$CFG_DEF" "$PROJ/.claude-env" "$SIB"
run "W216 tilde -C resolving inside HOME=project (control)"  "git -C ~ add ."                          ALLOW "$PROJ" "$CFG_DEF" "$PROJ/.claude-env" "$PROJ"
run "W207 apply --check --apply is a mutation"  "git -C $SIB apply --check --apply p.patch"  DENY
# A binding made inside a subshell dies with it; a plain `declare` never exports.
run "W208 subshell export does not leak"        "(export GIT_WORK_TREE=$SIB) && git add -A"  ALLOW
run "W209 declare without -x does not reach git" "declare GIT_WORK_TREE=$SIB && git add -A"  ALLOW
run "W210 declare -x does reach git"            "declare -x GIT_WORK_TREE=$SIB && git add -A" DENY
# Harvesting an assignment segment must not blind rules (A)/(B) to its redirect.
run "W211 redirect in an export segment still gated" "export Q=1 > src/app.rs"                DENY
run "W219 quoted export GIT_WORK_TREE value"   "export GIT_WORK_TREE=\"$SIB\" && git add -A"  DENY
run "W220 quoted export GIT_DIR value"         "export GIT_DIR='$SIB/.git' && git commit -m x" DENY
# An unexpanded env designation must not manufacture a bogus in-project work tree
# that then drops a real foreign git dir from the candidate list.
run "W221 unexpanded GIT_WORK_TREE suppresses"  'GIT_WORK_TREE=$WT git add -A'                ALLOW
# An unexpanded env work tree must not manufacture a bogus in-project tree that
# then drops the real foreign git dir from the candidate list.
run "W222 unexpanded GIT_WORK_TREE does not hide a foreign git-dir" \
  'GIT_WORK_TREE=$WT git --git-dir='"$SIB"'/.git/worktrees/w add -A'                          DENY
# plumbing twins of add/checkout/reset
run "W202 update-index on a sibling"            "git -C $SIB update-index --add -- f"        DENY
run "W203 checkout-index on a sibling"          "git -C $SIB checkout-index -a -f"           DENY
run "W146 worktree prune on sibling"           "git -C $SIB worktree prune"                 ALLOW
run "W147 worktree list on sibling"            "git -C $SIB worktree list"                  ALLOW
run "W148 in-project worktree add to outside path" "git worktree add $WORKROOT/wt2"         ALLOW

# Inline and env-wrapper GIT_DIR / GIT_WORK_TREE address the same foreign repo.
run "W149 inline GIT_WORK_TREE escape"         "GIT_WORK_TREE=$SIB git add ."               DENY
run "W150 inline GIT_DIR escape"               "GIT_DIR=$SIB/.git git commit -m x"          DENY
run "W151 env-wrapper GIT_DIR escape"          "env GIT_DIR=$SIB/.git git commit -m x"      DENY
run "W152 in-project GIT_WORK_TREE stays ungated" "GIT_WORK_TREE=$PROJ git add ."           ALLOW
# A LINKED worktree's git dir lives under the main checkout by construction, so an
# in-project --work-tree makes the foreign git dir a false positive, not an escape.
run "W153 linked-worktree git-dir + in-project work-tree" \
  "git --git-dir=$SIB/.git/worktrees/w --work-tree=$PROJ add ."                             ALLOW
run "W154 foreign git-dir without a work-tree"  "git --git-dir=$SIB/.git commit -m x"       DENY
# The exemption is for a LINKED worktree's admin dir only. A plain foreign .git
# paired with an in-project work tree still writes that repo's index and refs.
run "W170 plain foreign git-dir + in-project work-tree" \
  "git --git-dir=$SIB/.git --work-tree=$PROJ commit -m x"                                   DENY
run "W171 plain foreign git-dir + work-tree ." "git --git-dir=$SIB/.git --work-tree=. add -A" DENY
# worktree remove/move is judged on the tree it destroys, not the repo addressed.
run "W172 worktree remove of a foreign tree"   "git worktree remove --force $SIB/wt"        DENY
run "W173 worktree move of a foreign tree"     "git worktree move $SIB/wt $SIB/wt2"         DENY
run "W174 worktree remove of an in-project tree" "git worktree remove --force $PROJ/wt"     ALLOW
run "W175 worktree remove of a temp-root tree" "git -C $SIB worktree remove --force $FAKETMP/wt" ALLOW
# The EXPANDED form of the pr-team-review Phase E cleanup (the shipped text keeps
# "$WORKTREE" unexpanded, which rule (C) cannot judge at all): bookkeeping in the
# main checkout,
# tree under mktemp. It must pass WITHOUT the escape hatch, or the plugin would
# be teaching agents to prefix ZENSU_BASH_WRITE_GATE=off in a shipped skill.
run "W181 pr-team-review Phase E cleanup (expanded) needs no escape hatch" \
  "git -C $SIB worktree remove --force $FAKETMP/pr-42-review"                                ALLOW
run "W184 worktree operand after -- is still judged" "git worktree remove --force -- $SIB/wt" DENY

# The DEFAULT temp list — the one the shipped pr-team-review cleanup actually
# relies on — is overridden by ZENSU_BSWGATE_TEMP_DIRS in every other case here,
# so without these two the lazy raw+canonical retry decides no verdict anywhere.
REAL_TMP="$(mktemp -d)"
trap 'rm -rf "$WORKROOT" "$REAL_TMP"' EXIT
REAL_TMP_CANON="$(cd -P -- "$REAL_TMP" && pwd -P)"
default_temp_run() {
  local label="$1" cmd="$2" exp="$3" out
  out="$(payload "$cmd" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
        -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
        -u ZENSU_BSWGATE_TEMP_DIRS \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
        CLAUDE_ENV_FILE="$PROJ/.claude-env" ZENSU_CONFIG="$CFG_DEF" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}
default_temp_run "W185 real mktemp worktree removal under the DEFAULT temp list" \
  "git -C $SIB worktree remove --force $REAL_TMP/pr-42-review" ALLOW
default_temp_run "W186 the canonical spelling of that same temp root" \
  "git -C $SIB worktree remove --force $REAL_TMP_CANON/pr-42-review" ALLOW
default_temp_run "W187 the default list does not exempt a real sibling checkout" \
  "git -C $SIB worktree remove --force $SIB/wt" DENY
rmdir "$REAL_TMP" 2>/dev/null || true
# A file literally named -n must not read as clean's dry-run flag.
run "W176 pathspec named -n after -- does not disarm clean" "git -C $SIB clean -fd -- -n"   DENY
run "W177 pathspec named -n after -- does not disarm rm"    "git -C $SIB rm -f -- -n"       DENY
# wrapEnv coverage: both directions, and the deliberate asymmetry that a wrapper
# assignment supplies GIT_* but is NOT read as an escape hatch.
run "W178 env-wrapper GIT_WORK_TREE escape"    "env GIT_WORK_TREE=$SIB git add ."           DENY
run "W179 env-wrapper GIT_WORK_TREE in project" "env GIT_WORK_TREE=$PROJ git add ."         ALLOW
run "W180 env-wrapper escape hatch is not honored" "env ZENSU_BASH_WRITE_GATE=off git -C $SIB add ." DENY

# Quoted option values: unquoting the whole token before the '=' split leaves a
# leading quote, which makes the value non-absolute and lands it back in-project.
run "W155 --git-dir=\"quoted\" escape"          "git --git-dir=\"$SIB/.git\" commit -m x"    DENY
run "W156 --work-tree='quoted' escape"          "git --work-tree='$SIB' add ."               DENY
run "W157 --work-tree separate operand"         "git --work-tree $SIB add ."                 DENY

# rule (A) must not reach git pathspec operands
run "W158 git add naming tracked source"        "git add src/app.rs"                         ALLOW
run "W159 git checkout -- tracked source"       "git checkout -- src/app.rs"                 ALLOW
# ... but a redirect inside a git command is still a write channel (rule A holds)
run "W160 redirect inside a git command"        "git show HEAD:src/app.rs > src/app.rs"      DENY

# The target budget must bound decide()'s git calls, not silence later segments —
# and non-source targets must not spend it at all.
MANY="$(node -e 'let s="";for(let i=0;i<210;i++)s+="echo x > f"+i+".txt\n";process.stdout.write(s)')"
run "W161 rule C survives 210 non-source targets" "$MANY
git -C $SIB add -A"                                                                          DENY
run "W182 rule A survives 210 non-source targets" "$MANY
printf x >> src/app.rs"                                                                      DENY
REASON_BUDGET="$(payload "$MANY
git -C $SIB add -A" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
printf '%s' "$REASON_BUDGET" | grep -qF "$NS_SIB" \
  && check "W183 the post-budget deny is the rule-(C) verdict, not an unrelated one" PASS \
  || check "W183 post-budget deny reason (want '$NS_SIB' got '$REASON_BUDGET')" FAIL

# Accepted lexical gap: lex() is not quote-aware, so a quoted global-option
# operand containing & ; or | severs the segment before the subcommand.
run "W162 quoted '&' in a -c operand severs the segment (accepted gap)" \
  "git -C $SIB -c user.name=\"A & B\" commit -m x"                                           ALLOW
run "W117 inline ZENSU_BASH_WRITE_GATE=off"    "ZENSU_BASH_WRITE_GATE=off git -C $SIB add ." ALLOW
run "W118 inline ZENSU_MCP_GATE=off"           "ZENSU_MCP_GATE=off git -C $SIB add ."        ALLOW
run "W119 config bashWriteGate:false releases rule C" "git -C $SIB add ." ALLOW "$PROJ" "$CFG_OFF"

# --work-tree / --git-dir designate a repository without -C and without cd, so a
# rule that read only those two would miss them entirely.
run "W125 --git-dir= into sibling"             "git --git-dir=$SIB/.git commit -m x"        DENY
run "W126 --git-dir separate operand"          "git --git-dir $SIB/.git commit -m x"        DENY
run "W127 --work-tree= into sibling"           "git --work-tree=$SIB add ."                 DENY
# The post- -C resolution of a RELATIVE --work-tree cannot be witnessed in the
# deny direction: -C either moves the base deeper (harmless) or outward, and an
# outward base is already candidates[0], so the deny fires before --work-tree is
# read. Only an ALLOW discriminates — post- -C this is $PROJ/build (in project),
# pre- -C it would be $WORKROOT/build (an escape, DENY).
run "W128 --work-tree resolves after -C"       "git -C src --work-tree=../build add ."      ALLOW
run "W129 in-project --work-tree stays ungated" "git --work-tree=$PROJ add ."               ALLOW
run "W130 read-only with --git-dir on sibling" "git --git-dir=$SIB/.git log --oneline"      ALLOW

OUT_GIT_ENV="$(payload "git -C $SIB add ." | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_BASH_WRITE_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT_GIT_ENV" = "ALLOW" ] \
  && check "W120 process-env ZENSU_BASH_WRITE_GATE=off releases rule C -> ALLOW" PASS \
  || check "W120 process-env escape rule C (got '$OUT_GIT_ENV')" FAIL

# The process-env arm of ZENSU_MCP_GATE was pinned nowhere, for any rule, on
# either hook path — only its inline spelling was.
OUT_MCP_ENV="$(payload "git -C $SIB add ." | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
OUT_MCP_ENV_A="$(payload "printf x >> src/app.rs" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
{ [ "$OUT_MCP_ENV" = "ALLOW" ] && [ "$OUT_MCP_ENV_A" = "ALLOW" ]; } \
  && check "W166 process-env ZENSU_MCP_GATE=off releases rules A and C -> ALLOW" PASS \
  || check "W166 process-env ZENSU_MCP_GATE (ruleC='$OUT_MCP_ENV' ruleA='$OUT_MCP_ENV_A')" FAIL

# The deny has to be actionable on its own: which repo, which verb, the corrective
# form, and the opt-out. A reason naming only "a repository" leaves the agent
# guessing which checkout it just hit.
REASON_GIT="$(payload "git -C $SIB add ." | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_GIT" | grep -qF "$NS_SIB" \
  && printf '%s' "$REASON_GIT" | grep -qF 'git add' \
  && printf '%s' "$REASON_GIT" | grep -qF "git -C '$NS_PROJ'" \
  && printf '%s' "$REASON_GIT" | grep -qF 'ZENSU_BASH_WRITE_GATE=off'; } \
  && check "W121 rule-C deny names repo, subcommand, quoted -C fix and escape hatch" PASS \
  || check "W121 rule-C deny reason (want repo '$NS_SIB' and -C '$NS_PROJ'; got '$REASON_GIT')" FAIL

# AC-003: the reason must quote ONE namespace. The pre-fix message named the
# addressed repo as `D:\d\a\…` — path.resolve splicing the MSYS spelling under the
# current drive — beside a `D:\a\…` remedy: two spellings of one host in a single
# sentence. Grepping the RAW `$SIB` would not catch that (the broken message never
# contained the `/d/…` form either), so reconstruct the spliced spelling the way
# the pre-fix code produced it — resolve WITHOUT msysToDrive — and assert its
# absence. Only meaningful where the two namespaces differ; elsewhere it is a SKIP
# rather than a PASS, so the tally never implies coverage that did not run.
#
# The MSYS spelling reaches node over STDIN, and that is the whole reason this
# check works. MSYS rewrites ARGV on the way into a native binary, so passing
# `/d/a/…` as an argument delivers `D:\a\…` — already normalized, no splice left
# to reconstruct, and the check skipped itself on Windows while reporting the
# reassuring "spellings coincide". Stdin is the one channel MSYS does not touch,
# which is exactly why the payload carries the defect in production. W3h pins
# that premise. $NS_PROJ stays on argv: it is already native, so conversion is a
# no-op — and keeping the EXPECTATION side off stdin means MSYS's own rewrite
# acts as an oracle independent of the msysToDrive under test.
SPLICED="$(printf '%s' "$SIB" | node -e '
  const p = require("path");
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ process.stdout.write(p.resolve(process.argv[1], s)); });
' "$NS_PROJ" 2>/dev/null)"
if [ "$NS_SIB" != "$SIB" ] && [ -n "$SPLICED" ] && [ "$SPLICED" != "$NS_SIB" ]; then
  printf '%s' "$REASON_GIT" | grep -qF "$SPLICED" \
    && check "W121b deny reason still quotes the drive-spliced spelling ($SPLICED)" FAIL \
    || check "W121b deny reason quotes exactly one path namespace" PASS
else
  echo "  SKIP  W121b one-namespace check — no distinct spliced spelling to look for (raw='$SIB' ns='$NS_SIB' spliced='$SPLICED')"
fi

# A designated --work-tree/--git-dir hit is NOT fixed by adding -C: re-running with
# -C re-resolves the same escaping designation. The remedy sentence must say so.
REASON_GIT_WT="$(payload "git --work-tree=$SIB add ." | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
printf '%s' "$REASON_GIT_WT" | grep -qF 'denies again' \
  && check "W163 designated-path deny does not advise a -C that cannot clear it" PASS \
  || check "W163 designated-path remedy (got '$REASON_GIT_WT')" FAIL

# The third remedy arm. Without it a worktree deny would advise pointing
# --work-tree/--git-dir inside the root for a command that has neither flag.
REASON_WT_PATH="$(payload "git worktree remove --force $SIB/wt" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_WT_PATH" | grep -qF 'does not change which tree is destroyed' \
  && printf '%s' "$REASON_WT_PATH" | grep -qF "$NS_SIB_WT"; } \
  && check "W204 worktree deny names the destroyed tree and its own remedy" PASS \
  || check "W204 worktree remedy (want '$NS_SIB_WT' got '$REASON_WT_PATH')" FAIL

# Rule (C) resolves lexically and must never consult git about the foreign repo —
# otherwise a hung or missing git on another checkout could wedge or invert it.
GIT_SPY_BIN="$WORKROOT/git-spy-bin"
GIT_SPY_LOG="$WORKROOT/git-spy.log"
mkdir -p "$GIT_SPY_BIN"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "${ZENSU_TEST_GIT_SPY:?}"' 'exit 0' > "$GIT_SPY_BIN/git"
chmod +x "$GIT_SPY_BIN/git"
# The shim only intercepts where the PARSER's spawn mechanism honours it. The
# parser calls execFileSync WITHOUT a shell, and Windows resolves only a real
# executable image from PATH: an extensionless script named `git` is never
# reached, and a `.cmd` twin is refused outright since CVE-2024-27980. There the
# real git.exe answers instead, the log stays empty for a reason that has nothing
# to do with rule (C), and BOTH halves of the assertion below go vacuous — the
# empty log would "prove" an independence nothing tested. So probe the mechanism
# itself rather than the platform: wherever the shim is genuinely reachable the
# full assertion runs, and only where the parser could never reach it do we skip.
# Probed BEFORE the runs below, because the assertion reads the log they leave.
: > "$GIT_SPY_LOG"
env PATH="$GIT_SPY_BIN:$PATH" ZENSU_TEST_GIT_SPY="$GIT_SPY_LOG" "$NODE_BIN" -e '
  try { require("child_process").execFileSync("git", ["ls-files", "--spy-reachability-probe"],
        { stdio: "ignore", timeout: 2000 }); } catch (e) {}
' >/dev/null 2>&1
SPY_REACHABLE=0; [ -s "$GIT_SPY_LOG" ] && SPY_REACHABLE=1
spy_run() {
  : > "$GIT_SPY_LOG"
  payload "$1" | env PATH="$GIT_SPY_BIN:$PATH" ZENSU_TEST_GIT_SPY="$GIT_SPY_LOG" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
    ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify
}
# Positive control FIRST — an empty spy log proves nothing unless the shim is
# demonstrably reachable. A rule-(A) probe DOES consult git (tracked()).
OUT_SPY_CONTROL="$(spy_run "printf x >> src/app.rs")"
SPY_CONTROL_LOG="$(tr '\n' ';' < "$GIT_SPY_LOG")"
OUT_GIT_SPY="$(spy_run "git -C $SIB add .")"
if [ "$SPY_REACHABLE" = 1 ]; then
  # The control must show the shim was reached AND used for the tracked() lookup —
  # "the log is non-empty" alone would be satisfied by any incidental git call.
  { printf '%s' "$SPY_CONTROL_LOG" | grep -qF 'ls-files' && [ "$OUT_SPY_CONTROL" = "DENY" ] \
    && [ "$OUT_GIT_SPY" = "DENY" ] && [ ! -s "$GIT_SPY_LOG" ]; } \
    && check "W122 rule-C denies without asking git anything about the foreign repo" PASS \
    || check "W122 rule-C git independence (control='$OUT_SPY_CONTROL' spy-control='$SPY_CONTROL_LOG' ruleC='$OUT_GIT_SPY')" FAIL
else
  echo "  SKIP  W122 rule-C git independence (a PATH shim cannot intercept the parser's shell-less execFileSync on this host)"
fi

# Every gated verb must actually be gated: a verb dropped from the space-split
# GIT_MUTATIONS string would otherwise open silently while the suite stays green.
GIT_VERBS="$(node -e '
  const m = require(process.argv[1]);
  process.stdout.write(Array.from(m.GIT_MUTATIONS).join(" "));
' "$PARSER")"
GIT_VERB_COUNT="$(printf '%s' "$GIT_VERBS" | wc -w | tr -d ' ')"
VERB_FAIL=""
for v in $GIT_VERBS; do
  case "$v" in
    # `worktree` is the one verb whose bare form is deliberately read-only, so the
    # probe must name a gated subverb or the loop would assert the wrong thing.
    worktree) probe="git -C $SIB worktree remove --force $SIB/wt" ;;
    # Named subverbs whose bare form is a read-only listing.
    bisect)   probe="git -C $SIB bisect start" ;;
    submodule) probe="git -C $SIB submodule update --init" ;;
    sparse-checkout) probe="git -C $SIB sparse-checkout set src" ;;
    *)        probe="git -C $SIB $v" ;;
  esac
  out="$(payload "$probe" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
        ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "DENY" ] || VERB_FAIL="$VERB_FAIL $v($out)"
done
# The loop is driven BY the set, so it cannot notice a verb removed from it — the
# count assertion is what catches that direction; the membership list lives in
# git-repo-escape.test.js.
# An unconditional-deny regression would satisfy all 21+ DENY probes, so the same
# env shape must also produce an ALLOW.
VERB_CTRL="$(payload "git -C $SIB status" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
{ [ -z "$VERB_FAIL" ] && [ "$GIT_VERB_COUNT" -eq 24 ] && [ "$VERB_CTRL" = "ALLOW" ]; } \
  && check "W164 all $GIT_VERB_COUNT GIT_MUTATIONS verbs deny on a foreign repo, and the set still holds 24" PASS \
  || check "W164 ungated verbs:$VERB_FAIL count=$GIT_VERB_COUNT (want 24) control=$VERB_CTRL" FAIL

# The hook header must POINT at the tables rather than re-author them; an
# enumeration there is prose that silently drifts from the code.
HEADER_BLOCK="$(sed -n '1,60p' "$HOOK")"
HEADER_ENUM=""
for v in $GIT_VERBS; do
  case "$v" in mv|worktree) continue ;; esac
  printf '%s' "$HEADER_BLOCK" | grep -qF "\`$v\`" && HEADER_ENUM="$HEADER_ENUM $v"
done
{ printf '%s' "$HEADER_BLOCK" | grep -qF 'GIT_MUTATIONS' \
  && printf '%s' "$HEADER_BLOCK" | grep -qF 'GIT_READONLY_FORMS' \
  && printf '%s' "$HEADER_BLOCK" | grep -qiF 'not a security boundary' \
  && [ -z "$HEADER_ENUM" ]; } \
  && check "W165 hook header names both tables as the source of truth and re-authors neither" PASS \
  || check "W165 header/table drift — re-authored verbs:$HEADER_ENUM" FAIL

# FR-002 asks the PARSER header to name rule (C)'s accepted gaps. Nothing pinned
# that paragraph, so deleting it left the whole suite green.
# Bounded to the leading comment block, and matched on each gap's DISTINGUISHING
# clause — a bare token like "GIT_DIR" is equally satisfied by a sentence asserting
# the opposite.
PARSER_HEAD="$(awk '/^\/\// {seen=1; print; next} seen {exit}' "$PARSER")"
GAP_MISSING=""
while IFS= read -r gap; do
  [ -n "$gap" ] || continue
  printf '%s' "$PARSER_HEAD" | grep -qF -- "$gap" || GAP_MISSING="$GAP_MISSING [$gap]"
done <<'GAPS'
slips the (B)/(C) escape rules
tee >(proc) realfile
without quote awareness
exported by the user's shell before Claude
the whole command is recorded UNRESOLVED
a shell keyword hides the verb
ride along on an in-project --work-tree
move the cwd to
tokens split on whitespace
bare worktree NAME
assumes the MSYS mount convention
clamps at the drive root
so it is allowed even though the shell may resolve
not a security boundary
GAPS
[ -z "$GAP_MISSING" ] \
  && check "W192 the parser header still names every accepted rule-(C) gap" PASS \
  || check "W192 undocumented accepted gaps:$GAP_MISSING" FAIL

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
run_unbound "W123 unbound + git mutation escaping project" "git -C $SIB add ."             DENY
run_unbound "W124 unbound + read-only git on sibling"      "git -C $SIB status"            ALLOW
run_unbound "W217 unbound + in-project git mutation (control)" "git add -A"                    ALLOW
REASON_UNBOUND_C="$(payload "git -C $SIB add ." "$PROJ" | env -u ZENSU_SESSION_KEY \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_UNBOUND_C" | grep -qF "$NS_SIB" \
  && printf '%s' "$REASON_UNBOUND_C" | grep -qF "OUTSIDE this session's"; } \
  && check "W224 unbound rule-C deny keeps its own cause" PASS \
  || check "W224 unbound rule-C reason (got '$REASON_UNBOUND_C')" FAIL

# The unbound deny must keep the ORIGINAL write-rule cause and its escape hint —
# not only the appended binding sentence, or dropping the cause would leave every
# assertion green while the user loses the reason the write was refused.
REASON_UNBOUND="$(payload "printf x >> src/app.rs" "$PROJ" | env -u ZENSU_SESSION_KEY \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_UNBOUND" | grep -qF 'tracked' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF 'ZENSU_BASH_WRITE_GATE=off' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF 'no Session Control record' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF '/zensu:doctor'; } \
  && check "W87 unbound rule-A deny keeps its cause, escape hint, binding gap and /zensu:doctor" PASS \
  || check "W87 unbound deny reason (got '$REASON_UNBOUND')" FAIL
REASON_UNBOUND_B="$(payload "printf x >> $SIB/src/lib.rs" "$PROJ" | env -u ZENSU_SESSION_KEY \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
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

# The BOUND path used to discard the parser's exit status while its two siblings
# honored theirs. Same shim, no CLAUDE_PLUGIN_DATA override, so the bind succeeds.
OUT_PARSER_FAIL_BOUND="$(payload "printf x >> src/app.rs" "$PROJ" | env \
  PATH="$PARSER_FAIL_BIN:$PATH" ZENSU_TEST_REAL_NODE="$(command -v node)" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
REASON_PARSER_FAIL_BOUND="$(payload "printf x >> src/app.rs" "$PROJ" | env \
  PATH="$PARSER_FAIL_BIN:$PATH" ZENSU_TEST_REAL_NODE="$(command -v node)" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
# A bare DENY cannot show WHICH branch answered — the unbound arm and a narrowed
# bind failure both deny too. Only the bound arm emits this sentence.
{ [ "$OUT_PARSER_FAIL_BOUND" = "DENY" ] \
  && printf '%s' "$REASON_PARSER_FAIL_BOUND" | grep -qF 'could not be evaluated for this session'; } \
  && check "W218 bound parser runtime failure denies with the bound-arm reason" PASS \
  || check "W218 bound parser failure (got '$OUT_PARSER_FAIL_BOUND' / '$REASON_PARSER_FAIL_BOUND')" FAIL

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
