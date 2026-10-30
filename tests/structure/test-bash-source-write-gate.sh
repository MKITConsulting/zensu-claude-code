#!/bin/bash
set -u

# zensu-doctor-home-exempt: this suite never RUNS the doctor. It only names
# hooks/lib/zensu-doctor.sh inside a command STRING handed to the write gate, to
# check that the gate admits that shape. Its own HOME= is a pass-through of the
# ambient HOME into the gate, not a sandbox, so it cannot stand in for one.
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

. "$(dirname "$0")/lib-unit-registry.sh"
UNIT="$PLUGIN_DIR/tests/structure/git-repo-escape.test.js"
unit_check "W3a the rule-C option lattice unit file passes" "$UNIT"
UNIT_SYMS=1
for sym in "msysToDrive(" "splitTempList(" "isUnsafeTempEntry(" "winTempList(" "path.win32"; do
  grep -qF -- "$sym" "$UNIT" || UNIT_SYMS=0
done
if [ "$UNIT_SYMS" -eq 1 ]; then
  check "W3a-symbols the unit file still drives the win32 witnesses of the MSYS namespace fix" PASS
else
  check "W3a-symbols the unit file lost a win32 witness (msysToDrive, splitTempList, isUnsafeTempEntry, winTempList or path.win32)" FAIL
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
  const reg=require(process.argv[2]);
  const pres=(h.hooks&&h.hooks.PreToolUse)||[];
  const covers=(e,tool)=>reg.hostMatcherCovers(e.matcher,tool)===reg.REGISTRATION.REGISTERED;
  const ok=pres.some(e=>covers(e,"Bash") && covers(e,"PowerShell") && !covers(e,"Read") && (e.hooks||[]).some(z=>/pre-bash-source-write-gate\.sh/.test(z.command||"") && z.timeout===60));
  process.exit(ok?0:1);
' "$HOOKS_JSON" "$PLUGIN_DIR/hooks/lib/hook-registration-v1.js" 2>/dev/null \
  && check "W4 registered on a PreToolUse matcher covering Bash and PowerShell with timeout 60" PASS || check "W4 registered on a PreToolUse matcher covering Bash and PowerShell with timeout 60" FAIL

{ grep -qF 'zensu_hook_opted_in bashWriteGate || exit 0' "$HOOK" \
  && ! grep -qF 'zensu_hook_enabled bashWriteGate' "$HOOK"; } \
  && check "W5 config-gated via zensu_hook_opted_in bashWriteGate (opt-in, default off)" PASS \
  || check "W5 config-gated via zensu_hook_opted_in bashWriteGate (opt-in, default off)" FAIL

HOOK_OPT_IN_NOTE="$(sed -n 's/^OPT_IN_NOTE="\(.*\)"$/\1/p' "$HOOK")"
PARSER_OPT_IN_NOTE="$(node -e 'process.stdout.write(String(require(process.argv[1]).OPT_IN_NOTE).trim())' \
  "$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js" 2>/dev/null)"
{ [ -n "$HOOK_OPT_IN_NOTE" ] && [ "$HOOK_OPT_IN_NOTE" = "$PARSER_OPT_IN_NOTE" ] \
  && [ "$(grep -cF '${OPT_IN_NOTE}' "$HOOK")" -eq 4 ]; } \
  && check "W5b the hook's OPT_IN_NOTE equals the parser's exported note and reaches the four hook-side denies that interpolate it" PASS \
  || check "W5b hook note '$HOOK_OPT_IN_NOTE' vs parser note '$PARSER_OPT_IN_NOTE'" FAIL

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

CFG_ON="$(mktemp -t bswgate-on-XXXXXX)";     printf '%s' '{"hooks":{"bashWriteGate":true}}'   > "$CFG_ON"
CFG_OFF="$(mktemp -t bswgate-off-XXXXXX)";   printf '%s' '{"hooks":{"bashWriteGate":false}}'  > "$CFG_OFF"
CFG_UNSET="$(mktemp -t bswgate-unset-XXXXXX)"; printf '%s' '{"hooks":{}}'                     > "$CFG_UNSET"
CFG_QUOTED="$(mktemp -t bswgate-quoted-XXXXXX)"; printf '%s' '{"hooks":{"bashWriteGate":"true"}}' > "$CFG_QUOTED"
export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_TEST_PLUGIN_DATA="$WORKROOT/plugin-data"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" bswgate-test \
  || { check "W0 session-control baseline bootstrap" FAIL; echo "----"; echo "test-bash-source-write-gate: $PASS PASS / $FAIL FAIL"; exit 1; }

payload() {
  CMD="$1" CWD="${2:-$PROJ}" TOOL="${3:-Bash}" node -e '
    const o={hook_event_name:"PreToolUse",tool_name:process.env.TOOL,tool_input:{command:process.env.CMD},cwd:process.env.CWD,session_id:"bswgate-test"};
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
  local label="$1" cmd="$2" exp="$3" cwd="${4:-$PROJ}" cfg="${5:-$CFG_ON}" env_file="${6:-$PROJ/.claude-env}" home="${7:-${HOME:-}}"
  local out
  out="$(payload "$cmd" "$cwd" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
        -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_ENV_FILE="$env_file" \
        HOME="$home" \
        ZENSU_CONFIG="$cfg" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}

# The parser bounds its work at MAX_TARGETS. This path used to fail OPEN at the
# cap; #210 closed that, because padding a command with junk operands was a way
# to buy one free clobber of real tracked source. The budget now lives inside
# decide(), is spent only by operands that actually EXIST, and treats exhaustion
# as tracked — so the pads below cost nothing and the real source write is still
# judged. W161/W182/W183 pin the same posture from the other direction.
# The no-project-root branch reaches the cap differently: there the loop guard is
# the only rule left, so it fails closed on its own (pinned by O29e in
# test-orphaned-project-root.sh). Both arms of that guard must stay held —
# without this case the `targetsOnly &&` qualifier could be dropped, silently
# restoring the fail-open, and every suite would stay green.
BUDGET_CMD="printf x"
budget_i=0
while [ "$budget_i" -lt 210 ]; do
  BUDGET_CMD="$BUDGET_CMD > pad$budget_i.txt"
  budget_i=$((budget_i + 1))
done
run "W5a anchored path still judges the real target past the budget cap" \
  "$BUDGET_CMD > src/app.rs" DENY

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

run "W29b default config leaves rule A off"   "printf x >> src/app.rs"             ALLOW "$PROJ" "$CFG_UNSET"
run "W29c default config leaves rule B off"   "printf x >> ../sibling/src/lib.rs"  ALLOW "$PROJ" "$CFG_UNSET"
run "W29d default config leaves rule C off"   "git -C $SIB add ."                  ALLOW "$PROJ" "$CFG_UNSET"
run "W29e default config admits a takeover worktree move" \
  "git -C $SIB worktree move $SIB/wt-old $PROJ/wt-new"                             ALLOW "$PROJ" "$CFG_UNSET"
run "W29e-control opted in, the same takeover move is refused" \
  "git -C $SIB worktree move $SIB/wt-old $PROJ/wt-new"                             DENY  "$PROJ" "$CFG_ON"
run "W29f quoted \"true\" does not opt in"    "printf x >> src/app.rs"             ALLOW "$PROJ" "$CFG_QUOTED"
run "W29g absent config file leaves the gate off" \
  "printf x >> src/app.rs"                                                         ALLOW "$PROJ" "$WORKROOT/no-such-config.json"
run "W29h control rebind still denies under the default config" \
  "ZENSU_CLAUDE_PLUGIN_ROOT=/tmp/other env"                                        DENY  "$PROJ" "$CFG_UNSET"
run "W29i host session-id rebind still denies under the default config" \
  "CLAUDE_CODE_SESSION_ID=other env"                                               DENY  "$PROJ" "$CFG_UNSET"
run "W29j opted in, rule A denies"            "printf x >> src/app.rs"             DENY  "$PROJ" "$CFG_ON"

# Process-env escape (set on the hook process itself)
OUT="$(payload 'printf x >> src/app.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_BASH_WRITE_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "W30 process-env ZENSU_BASH_WRITE_GATE=off -> ALLOW" PASS \
  || check "W30 process-env escape (got '$OUT')" FAIL

# The parser remains fail-open only after a trusted hook session is bound;
# empty/non-JSON payloads cannot establish that binding and are denied while the gate is opted in.
OUT="$(printf '' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
OUT2="$(printf '%s' 'not json' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
{ [ "$OUT" = "DENY" ] && [ "$OUT2" = "DENY" ]; } \
  && check "W31 empty + non-JSON cannot bind a hook session -> DENY" PASS \
  || check "W31 binding failure (empty='$OUT' nonjson='$OUT2')" FAIL

# Deny-reason content
REASON_A="$(payload 'printf x >> src/app.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_A" | grep -qF 'tracked' \
  && printf '%s' "$REASON_A" | grep -qF 'opt-in and runs because hooks.bashWriteGate is true' \
  && ! printf '%s' "$REASON_A" | grep -qF 'ZENSU_BASH_WRITE_GATE'; } \
  && check "W32 clobber deny-reason: 'tracked' + the opt-in key, never the escape prefix" PASS \
  || check "W32 clobber deny-reason content (got '$REASON_A')" FAIL

REASON_B="$(payload 'printf x >> ../sibling/src/lib.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_B" | grep -qiF 'worktree' \
  && printf '%s' "$REASON_B" | grep -qF 'opt-in and runs because hooks.bashWriteGate is true' \
  && ! printf '%s' "$REASON_B" | grep -qF 'ZENSU_BASH_WRITE_GATE'; } \
  && check "W33 escape deny-reason: 'worktree' + the opt-in key, never the escape prefix" PASS \
  || check "W33 escape deny-reason content (got '$REASON_B')" FAIL

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
  "printf x >> /d/a/zensu-claude-code/session/.claude-env" DENY "$PROJ" "$CFG_ON" \
  'D:\a\zensu-claude-code\session\.claude-env'
run "W69 control rebind ignores bashWriteGate:false" "ZENSU_CLAUDE_PLUGIN_ROOT=/tmp/other env" DENY "$PROJ" "$CFG_OFF"
run "W70 control rebind ignores inline escape" "ZENSU_BASH_WRITE_GATE=off ZENSU_PROJECT_ROOT=/tmp/other env" DENY
run "W71 protected path prefix is not an exact CLAUDE_ENV_FILE match" \
  "printf x >> /d/a/zensu-claude-code/session/.claude-env.backup" ALLOW "$PROJ" "$CFG_ON" \
  'D:\a\zensu-claude-code\session\.claude-env'
run "W72 symbolic CLAUDE_ENV_FILE reference is independent of native path parsing" \
  'printf x >> "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_ON" \
  'D:\a\zensu-claude-code\session\.claude-env'
run "W73 POSIX CLAUDE_ENV_FILE exact path" \
  "printf x >> /Users/Runner/Session/.claude-env" DENY "$PROJ" "$CFG_ON" \
  '/Users/Runner/Session/.claude-env'
run "W74 a POSIX CLAUDE_ENV_FILE path folds letter case, as a case-insensitive volume resolves it" \
  "printf x >> /users/runner/session/.claude-env" DENY "$PROJ" "$CFG_OFF" \
  '/Users/Runner/Session/.claude-env'
run "W75 direct host session-id assignment" "CLAUDE_CODE_SESSION_ID=other env" DENY
run "W76 exported host session-id rebind" "export CLAUDE_CODE_SESSION_ID=other" DENY
run "W77 unset host session-id" "unset CLAUDE_CODE_SESSION_ID" DENY
run "W78 printf -v host session-id rebind" "printf -v CLAUDE_CODE_SESSION_ID other" DENY
run "W79 host session-id rebind ignores bashWriteGate:false" \
  "CLAUDE_CODE_SESSION_ID=other env" DENY "$PROJ" "$CFG_OFF"
run "W235 an uppercase env wrapper still carries a host session-id rebind" "ENV CLAUDE_CODE_SESSION_ID=other env" DENY "$PROJ" "$CFG_OFF"
run "W236 a mixed-case sudo wrapper still carries a Session Control rebind" "Sudo ZENSU_PROJECT_ROOT=/tmp/other true" DENY "$PROJ" "$CFG_OFF"
run "W237 an env wrapper behind a path in another case still carries a rebind" "/usr/bin/ENV ZENSU_SESSION_KEY=x true" DENY "$PROJ" "$CFG_OFF"
run "W238 an uppercase tee into CLAUDE_ENV_FILE" 'echo x | TEE "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W239 an uppercase sed -i on CLAUDE_ENV_FILE" 'SED -i s/a/b/ "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W240 an uppercase dd of= CLAUDE_ENV_FILE" 'DD of="$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W241 an uppercase EXPORT is no builtin and rebinds nothing" "EXPORT ZENSU_SESSION_KEY=x" ALLOW "$PROJ" "$CFG_OFF"
run "W242 an uppercase UNSET is no builtin and removes nothing" "UNSET ZENSU_SESSION_KEY" ALLOW "$PROJ" "$CFG_OFF"
run "W243 uppercase git -C sibling add" "GIT -C $SIB add ." DENY
run "W244 uppercase env wrapper before git -C sibling add" "ENV git -C $SIB add ." DENY
run "W245 a path to git in another case" "/usr/bin/GIT -C $SIB add ." DENY
run "W246 git.exe -C sibling add" "git.exe -C $SIB add ." DENY
run "W247 an uppercase git read in the sibling still passes" "GIT -C $SIB status" ALLOW
run "W248 uppercase sed -i on tracked .rs" "SED -i s/x/y/ src/app.rs" DENY
run "W249 BSD sed -I on tracked .rs" "sed -I '' s/x/y/ src/app.rs" DENY
run "W250 uppercase tee on tracked .rs" "echo x | TEE src/app.rs" DENY
run "W251 a path to tee on tracked .rs" "echo x | /usr/bin/tee src/app.rs" DENY
run "W252 uppercase dd of= tracked .rs" "DD of=src/app.rs" DENY
run "W253 an uppercase CD is no builtin and keeps the cwd" "CD $SIB && git add ." ALLOW
run "W254 an uppercase ENV runs cd outside the shell, so a write after it stays in the project" "ENV cd $FAKETMP; printf x > src/app.rs" DENY
run "W255 a lowercase env runs cd outside the shell as well" "env cd $FAKETMP; printf x > src/app.rs" DENY
run "W256 a cd spelled with a path is no builtin and keeps the cwd" "/usr/bin/cd $FAKETMP; printf x > src/app.rs" DENY
run "W257 command keeps cd in the shell, so the cwd moves" "command cd $FAKETMP && printf x > src/app.rs" ALLOW
run "W258 an uppercase ENV before cd leaves git add in the sibling cwd" "ENV cd $PROJ; git add -A" DENY "$SIB"
run "W259 an uppercase ENV before cd leaves git add in the project" "ENV cd $SIB; git add ." ALLOW
run "W260 grep naming TEE before a tracked file is no tee write" "grep -n TEE src/app.rs" ALLOW
run "W261 grep naming a tee directory before a tracked file is no tee write" "grep -n x tools/tee src/app.rs" ALLOW
run "W262 an uppercase tee in a subshell into CLAUDE_ENV_FILE" 'echo x | (TEE "$CLAUDE_ENV_FILE")' DENY "$PROJ" "$CFG_OFF"
run "W263 sed -i in a command substitution on CLAUDE_ENV_FILE" 'x=$(SED -i s/a/b/ "$CLAUDE_ENV_FILE")' DENY "$PROJ" "$CFG_OFF"
run "W264 a quoted tee into CLAUDE_ENV_FILE" 'echo x | "tee" "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W265 a quote inside the program word is removed as bash removes it" "g'i't -C $SIB add ." DENY

WIN32_PRELOAD="$WORKROOT/win32-platform.js"
printf '%s\n' 'Object.defineProperty(process, "platform", { value: "win32" });' > "$WIN32_PRELOAD"
WIN32_PAYLOAD="$(payload "'C:\\Git\\cmd\\git.exe' -C $SIB add .")"
WIN32_OUT="$(PAYLOAD="$WIN32_PAYLOAD" CLAUDE_PROJECT_DIR="$PROJ" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" \
  node -r "$WIN32_PRELOAD" "$PARSER" 2>/dev/null)"
HOST_OUT="$(PAYLOAD="$WIN32_PAYLOAD" CLAUDE_PROJECT_DIR="$PROJ" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" \
  node "$PARSER" 2>/dev/null)"
HOST_WIN32="$(node -e 'process.stdout.write(process.platform === "win32" ? "yes" : "no")')"
WIN32_READ=other
case "$WIN32_OUT" in
  ('Blocked `git add` against a repository OUTSIDE'*) WIN32_READ=deny ;;
esac
HOST_READ=other
case "$HOST_OUT" in
  ('') HOST_READ=allow ;;
  ('Blocked `git add` against a repository OUTSIDE'*) HOST_READ=deny ;;
esac
HOST_WANT=allow
[ "$HOST_WIN32" = yes ] && HOST_WANT=deny
{ [ "$WIN32_READ" = deny ] && [ "$HOST_READ" = "$HOST_WANT" ]; } \
  && check "W266 the rule loop reads a backslash path to git.exe as git on win32 only" PASS \
  || check "W266 win32 program path reading (win32=$WIN32_READ host=$HOST_READ host-is-win32=$HOST_WIN32)" FAIL

run "W267 a backslash before the env wrapper is removed, so the host session-id rebind is refused" "\\env CLAUDE_CODE_SESSION_ID=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W268 quotes inside the env wrapper word are removed" "e'n'v CLAUDE_CODE_SESSION_ID=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W269 a backslash before export is removed, so the builtin rebinds" "\\export ZENSU_SESSION_KEY=x" DENY "$PROJ" "$CFG_OFF"
run "W270 a backslash before unset is removed, so the builtin removes" "\\unset ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W271 an ANSI-C quoted env wrapper is decoded" "\$'\\x65nv' CLAUDE_CODE_SESSION_ID=x true" DENY "$PROJ" "$CFG_OFF"
run "W272 a locale-quoted env wrapper is read as double quotes" "\$\"env\" CLAUDE_CODE_SESSION_ID=x true" DENY "$PROJ" "$CFG_OFF"
run "W273 a backslash before git is removed, so rule (C) judges git -C sibling add" "\\git -C $SIB add ." DENY
run "W274 a backslash before cd is removed, so git add after it is judged in the sibling" "\\cd ../sibling && git add ." DENY
run "W275 a quoted git read in the sibling still passes" "'git' -C $SIB status" ALLOW
LC_UNSET="$(printf 'unset \\\nZENSU_SESSION_KEY')"
run "W276 a backslash-newline continues the line, so the unset after it is refused" "$LC_UNSET" DENY "$PROJ" "$CFG_OFF"
LC_GIT="$(printf 'git -C %s \\\nadd .' "$SIB")"
run "W277 a backslash-newline inside git -C sibling add keeps the verb on its command" "$LC_GIT" DENY
LC_COMMENT="$(printf '# note \\\nunset ZENSU_SESSION_KEY')"
run "W278 a comment line that ends in a backslash does not swallow the unset on the next line" "$LC_COMMENT" DENY "$PROJ" "$CFG_OFF"
run "W279 env -i does not end the protected-assignment scan" "env -i CLAUDE_CODE_SESSION_ID=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W280 env -- does not end the protected-assignment scan" "env -- CLAUDE_CODE_SESSION_ID=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W281 sudo's own -u operand does not end the scan" "sudo -u root ZENSU_PROJECT_ROOT=/x true" DENY "$PROJ" "$CFG_OFF"
run "W282 nice -n before env does not end the scan" "nice -n 5 env ZENSU_SESSION_KEY=x true" DENY "$PROJ" "$CFG_OFF"
run "W283 env -S splits its string into further env arguments" "env -S 'CLAUDE_CODE_SESSION_ID=x bash' x.sh" DENY "$PROJ" "$CFG_OFF"
run "W284 env -u of a protected input is refused" "env -u ZENSU_SESSION_KEY bash x.sh" DENY "$PROJ" "$CFG_OFF"
REASON_ENV_UNSET="$(payload "env --unset=CLAUDE_CODE_SESSION_ID bash x.sh" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
  -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_ENV_FILE="$PROJ/.claude-env" ZENSU_CONFIG="$CFG_OFF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
printf '%s' "$REASON_ENV_UNSET" | grep -qF 'Blocked removal of protected Session Control input CLAUDE_CODE_SESSION_ID.' \
  && check "W285 env --unset of a protected input is refused as removal, like unset" PASS \
  || check "W285 env --unset removal reason (got '$REASON_ENV_UNSET')" FAIL
run "W286 env -i alone rebinds nothing and stays allowed" "env -i PATH=/usr/bin bash x.sh" ALLOW "$PROJ" "$CFG_OFF"
run "W287 env -u of an unprotected name stays allowed" "env -u FOO bash x.sh" ALLOW "$PROJ" "$CFG_OFF"
run "W288 sudo -u before git -C sibling add no longer hides the verb" "sudo -u me git -C $SIB add ." DENY
run "W289 nice -n before git -C sibling add no longer hides the verb" "nice -n 10 git -C $SIB add ." DENY
run "W290 env -C runs git in the sibling" "env -C $SIB git add ." DENY
run "W291 env -i before a git read in the sibling stays allowed" "env -i git -C $SIB status" ALLOW
run "W292 a double-quoted assignment after env is read as one" "env \"CLAUDE_CODE_SESSION_ID=x\" bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W293 a single-quoted assignment after an uppercase ENV is read as one" "ENV 'ZENSU_SESSION_KEY=x' true" DENY "$PROJ" "$CFG_OFF"
run "W294 a quoted GIT_WORK_TREE after env still names the sibling for rule (C)" "env \"GIT_WORK_TREE=$SIB\" git add -A" DENY
run "W295 a quoted leading assignment is a command word to bash, not an assignment" "\"CLAUDE_CODE_SESSION_ID=x\" true" ALLOW "$PROJ" "$CFG_OFF"
run "W296 an append assignment rebinds the host session id" "CLAUDE_CODE_SESSION_ID+=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W297 an indexed assignment rebinds a Session Control input" "ZENSU_SESSION_KEY[0]=x" DENY "$PROJ" "$CFG_OFF"
run "W298 export of an append assignment rebinds" "export ZENSU_SESSION_KEY+=x" DENY "$PROJ" "$CFG_OFF"
run "W299 printf -v with the name attached rebinds" "printf -vZENSU_SESSION_KEY x" DENY "$PROJ" "$CFG_OFF"
run "W300 export -n removes a Session Control input from the environment" "export -n ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W301 declare +x removes a Session Control input from the environment" "declare +x ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W302 declare -x of a Session Control input without a value stays allowed" "declare -x ZENSU_SESSION_KEY" ALLOW "$PROJ" "$CFG_OFF"
run "W303 an if before export does not hide the rebind" "if export ZENSU_SESSION_KEY=x; then :; fi" DENY "$PROJ" "$CFG_OFF"
run "W304 a brace group before unset does not hide the removal" "{ unset ZENSU_SESSION_KEY; }" DENY "$PROJ" "$CFG_OFF"
run "W305 a pipeline negation before an assignment does not hide the rebind" "! CLAUDE_CODE_SESSION_ID=x true" DENY "$PROJ" "$CFG_OFF"
run "W306 a leading redirection before export does not hide the rebind" "2>/dev/null export ZENSU_SESSION_KEY=x" DENY "$PROJ" "$CFG_OFF"
run "W307 a for loop's do no longer hides git -C sibling add" "for f in a; do git -C $SIB add .; done" DENY
ENV_NFC="$(printf '/Users/R\303\274nner/Session/.claude-env')"
CMD_NFD="$(printf 'printf x >> /Users/Ru\314\210nner/Session/.claude-env')"
run "W308 a decomposed spelling of the env-file path is the same file" "$CMD_NFD" DENY "$PROJ" "$CFG_OFF" "$ENV_NFC"
run "W309 sed -ni edits in place" "sed -ni s/x/y/ src/app.rs" DENY
run "W310 sed --in-place edits in place" "sed --in-place s/x/y/ src/app.rs" DENY
run "W311 sed -i with an attached suffix after another option edits in place" "sed -E -i.bak s/x/y/ src/app.rs" DENY
run "W312 sed -n -e p reads the tracked file" "sed -n -e p src/app.rs" ALLOW
run "W313 sed --in-place on CLAUDE_ENV_FILE is refused whatever the opt-in says" 'sed --in-place s/a/b/ "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W314 quotes inside tee are removed, so a tee into CLAUDE_ENV_FILE is refused" 'echo x | t'"'"'e'"'"'e "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W315 a backslash before tee is removed" 'echo x | \tee "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W316 a backslash inside sed is removed" 's\ed -i s/a/b/ "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W317 quotes inside dd are removed" '"d"d of="$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W318 a backslash inside a literal env-file path is removed" 'printf x >> /Users/R\unner/Session/.claude-env' DENY "$PROJ" "$CFG_OFF" \
  '/Users/Runner/Session/.claude-env'
run "W319 a redirection glued to a word still writes the tracked file" "printf x>src/app.rs" DENY
run "W320 2>&1 after cd ../sibling keeps the cwd it moved to" "cd ../sibling 2>&1 && printf x > src/lib.rs" DENY
run "W321 the time keyword keeps cd in the shell" "time cd ../sibling; git add ." DENY
run "W322 a quoted time is the external program, so its cd leaves the cwd" "\\time cd ../sibling; git add ." ALLOW
run "W323 a leading redirection does not hide git -C sibling add" ">/dev/null git -C $SIB add ." DENY
run "W324 a \\c at the end of \$'...' ends there, so the unset after it is refused" "unset \$'\\c' ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W325 \\c pairs with an escaped backslash, so the export after it is refused" "export \$'\\c\\\\' CLAUDE_CODE_SESSION_ID=x; bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W326 a quoted brace inside \${...} does not end it, so the unset after it is refused" "unset \${x:-'}'} ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W327 a nested quote inside a double-quoted \${...} does not end the string" "export \"\${x:-\"'\"}\" ZENSU_SESSION_KEY=x" DENY "$PROJ" "$CFG_OFF"
run "W328 the same nested quote before a leading assignment" "A=\"\${x:-\"'\"}\" CLAUDE_CODE_SESSION_ID=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W329 an escaped < before & is a word, so the & still ends the command" "true \\<& CLAUDE_CODE_SESSION_ID=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W330 an escaped > before | is a word, so the pipe still ends the command" "echo \\>| ZENSU_SESSION_KEY=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W331 an &> glued to the name splits off, so the unset is refused" "unset ZENSU_SESSION_KEY&>/dev/null" DENY "$PROJ" "$CFG_OFF"
run "W332 an &> glued to env splits off, so the wrapper is read" "env&>/dev/null CLAUDE_CODE_SESSION_ID=x bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W333 an &> glued to tee splits off, so the write to CLAUDE_ENV_FILE is refused" 'echo x | tee&>/dev/null "$CLAUDE_ENV_FILE"' DENY "$PROJ" "$CFG_OFF"
run "W334 \$\$ is one unit, so its ' opens a plain single quote" "unset \$\$'\\' ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W335 \$\$ is one unit, so its { opens no expansion" "unset \$\${'}' ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
LC_HEREDOC="$(printf 'cat <<EOF \\\nx\nEOF\nunset ZENSU_SESSION_KEY')"
run "W336 a heredoc opener continued by a backslash-newline starts its body after the joined line" "$LC_HEREDOC" DENY "$PROJ" "$CFG_OFF"
LC_HEREDOC_BODY="$(printf 'cat <<EOF \\\nEOF\nunset ZENSU_SESSION_KEY')"
run "W337 the whitespace reading still refuses the unset that the word reader places in the body" "$LC_HEREDOC_BODY" DENY "$PROJ" "$CFG_OFF"
run "W338 a quoted brace inside \${...} does not hide the tee operand after it" "echo x | tee \${x:-'}'} src/app.rs" DENY
run "W339 an escaped < before & does not hide git -C sibling add" "true \\<& git -C $SIB add ." DENY
run "W340 an &> glued to git splits off, so rule (C) reads the verb" "git&>/dev/null -C $SIB add ." DENY
LC_HEREDOC_GIT="$(printf 'cat <<EOF \\\nx\nEOF\ngit -C %s add .' "$SIB")"
run "W341 a heredoc opener continued by a backslash-newline does not hide the git line after the body" "$LC_HEREDOC_GIT" DENY
run "W342 an expansion holding a quoted brace stays a plain argument" "echo \"\${x:-'}'}\" ZENSU_SESSION_KEY" ALLOW "$PROJ" "$CFG_OFF"
run "W343 an escaped < before & with a harmless command after it stays allowed" "echo \\<& ls" ALLOW "$PROJ" "$CFG_OFF"
LC_HEREDOC_LS="$(printf 'cat <<EOF \\\nx\nEOF\nls')"
run "W344 a continued heredoc opener with a harmless line after the body stays allowed" "$LC_HEREDOC_LS" ALLOW "$PROJ" "$CFG_OFF"
run "W345 a >& after a quoted apostrophe still writes the file it names" "echo \"it's\" >&src/app.rs" DENY
run "W346 a >| after a quoted apostrophe still writes the file it names" "echo \"it's\" >|src/app.rs" DENY
run "W347 \$\$ inside a string inside \${...} is one unit, so the tee operand after it is read" "echo x | tee \${x:-\"\$\${\"} src/app.rs" DENY
run "W348 the same inside a double-quoted \${...}" "echo x | tee \"\${x:-\"\$\${\"}\" src/app.rs" DENY
run "W349 a >& to a descriptor after a quoted apostrophe stays allowed" "echo \"it's\" >&2" ALLOW
run "W350 bash nests a single quote inside a double-quoted \${...}, so the tee operand after it is read" "echo x | tee \"\${x:-'\"'}\" src/app.rs" DENY
run "W351 the same nested quote does not hide env -u of a protected input" "A=\"\${x:-'\"'}\" env -u ZENSU_SESSION_KEY bash x.sh" DENY "$PROJ" "$CFG_OFF"
run "W352 zsh's >>| appends to the file it names" "echo x >>| src/app.rs" DENY
run "W353 zsh's >>& appends to the file it names" "echo x >>& src/app.rs" DENY
run "W354 zsh's &>| writes the file it names" "echo x &>| src/app.rs" DENY
run "W355 zsh's &>>| appends to the file it names" "echo x &>>| src/app.rs" DENY
LC_QUOTED_HEREDOC="$(printf "echo '<<X'\nunset ZENSU_SESSION_KEY")"
run "W356 a quoted << opens no heredoc, so the unset on the next line is refused" "$LC_QUOTED_HEREDOC" DENY "$PROJ" "$CFG_OFF"
LC_ARITH_SHIFT="$(printf 'n=$((1<<bits))\nunset ZENSU_SESSION_KEY')"
run "W357 an arithmetic shift opens no heredoc, so the unset on the next line is refused" "$LC_ARITH_SHIFT" DENY "$PROJ" "$CFG_OFF"
LC_QUOTED_HASH="$(printf 'unset " #" \\\nZENSU_SESSION_KEY')"
run "W358 a quoted # starts no comment, so the backslash-newline still joins the unset" "$LC_QUOTED_HASH" DENY "$PROJ" "$CFG_OFF"
run "W359 a for loop assigns its name, so a protected loop variable is a rebind" "for ZENSU_SESSION_KEY in x; do bash x.sh; done" DENY "$PROJ" "$CFG_OFF"
run "W360 unset of index 0 removes a protected scalar" "unset 'ZENSU_SESSION_KEY[0]'" DENY "$PROJ" "$CFG_OFF"
run "W361 a {NAME} redirection assigns the descriptor number to NAME" "{ZENSU_SESSION_KEY}>/dev/null true" DENY "$PROJ" "$CFG_OFF"
run "W362 declare -a turns a protected input into an array, which is not exported" "declare -a ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
LC_DASHED_DELIM="$(printf 'cat <<EOF-1\nx\nEOF-1\nunset ZENSU_SESSION_KEY')"
run "W363 a heredoc delimiter is the whole word, so the unset after EOF-1 is refused" "$LC_DASHED_DELIM" DENY "$PROJ" "$CFG_OFF"
run "W364 zsh's >&| writes the file it names" "echo x >&|src/app.rs" DENY
run "W365 a read-write redirection on descriptor 1 writes the file" "echo x 1<>src/app.rs" DENY
run "W366 a read-write redirection on standard input writes nothing" "cat 0<>src/app.rs" ALLOW
LC_COMMENT_HEREDOC="$(printf '# note <<EOF\nunset ZENSU_SESSION_KEY')"
run "W367 a << inside a comment opens no heredoc, so the unset on the next line is refused" "$LC_COMMENT_HEREDOC" DENY "$PROJ" "$CFG_OFF"
run "W368 read into a subscript of a protected input is a rebind" "read 'ZENSU_SESSION_KEY[1]'" DENY "$PROJ" "$CFG_OFF"
run "W369 env -S splits at \\_ as env does, so the second assignment is read" "env -S 'A=1\\_CLAUDE_CODE_SESSION_ID=x' node x.js" DENY "$PROJ" "$CFG_OFF"
run "W370 more env -S split strings than the check reads is refused" "env -S -v -S -v -S -v -S -v -S -v -S -v -S -v -S -v -S 'CLAUDE_CODE_SESSION_ID=x bash' x.sh" DENY "$PROJ" "$CFG_OFF"
run "W371 env -C moves the directory tee writes in" "env -C ../sibling tee src/lib.rs" DENY
run "W372 sudo -D moves the directory sed -i edits in" "sudo -D ../sibling sed -i s/a/b/ src/lib.rs" DENY
run "W373 env -C moves the directory dd of= writes in" "env -C ../sibling dd of=src/lib.rs" DENY
run "W374 an assignment after env -i reaches git" "env -i GIT_WORK_TREE=$SIB git add -A" DENY
run "W375 env -i clears a leading assignment before git runs" "GIT_WORK_TREE=$SIB env -i git add -A" ALLOW
run "W376 env -u drops a leading assignment before git runs" "GIT_WORK_TREE=$SIB env -u GIT_WORK_TREE git add -A" ALLOW
run "W377 a for loop over another name stays allowed" "for f in a b; do echo \$f; done" ALLOW "$PROJ" "$CFG_OFF"
run "W378 declare -a and a {NAME} redirection of other names stay allowed" "declare -a FOO; {fd}>/dev/null true" ALLOW "$PROJ" "$CFG_OFF"
LC_QUOTED_DELIM="$(printf "cat <<'E O F'\nunset ZENSU_SESSION_KEY\nE O F")"
run "W379 a quoted delimiter with spaces ends its body, which bash does not run" "$LC_QUOTED_DELIM" ALLOW "$PROJ" "$CFG_OFF"
LC_TAB_DELIM="$(printf 'cat <<-EOF\n\tunset ZENSU_SESSION_KEY\n\tEOF')"
run "W380 <<- strips leading tabs from the delimiter line" "$LC_TAB_DELIM" ALLOW "$PROJ" "$CFG_OFF"
LC_QUOTED_HASH_OK="$(printf 'echo "a #b" \\\nok')"
run "W381 a quoted # with a harmless continued line stays allowed" "$LC_QUOTED_HASH_OK" ALLOW "$PROJ" "$CFG_OFF"
run "W382 getopts assigns its name operand" "getopts a ZENSU_SESSION_KEY -a" DENY "$PROJ" "$CFG_OFF"
run "W383 mapfile assigns its array operand" "mapfile ZENSU_SESSION_KEY < /dev/null" DENY "$PROJ" "$CFG_OFF"
run "W384 readarray assigns its array operand after its own options" "readarray -t -u 3 CLAUDE_CODE_SESSION_ID" DENY "$PROJ" "$CFG_OFF"
run "W385 wait -p assigns the variable it names" "wait -n -p ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W386 coproc NAME turns the name into an array of descriptors" "coproc ZENSU_SESSION_KEY { cat; }" DENY "$PROJ" "$CFG_OFF"
run "W387 zsh's print -v assigns the name inside an option cluster" "print -rv ZENSU_SESSION_KEY x" DENY "$PROJ" "$CFG_OFF"
run "W388 zsh's set -A assigns the array it names" "set -A ZENSU_PROJECT_ROOT a b" DENY "$PROJ" "$CFG_OFF"
run "W389 zsh's set +A assigns the array it names" "set +A ZENSU_SESSION_KEY a" DENY "$PROJ" "$CFG_OFF"
run "W390 zsh's integer assigns the name" "integer ZENSU_SESSION_KEY=5" DENY "$PROJ" "$CFG_OFF"
run "W391 zsh's float converts the name even without a value" "float ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W392 zsh's read takes the name before ? and the prompt after it" "read 'ZENSU_SESSION_KEY?key> '" DENY "$PROJ" "$CFG_OFF"
run "W393 zsh's vared assigns the name it edits" "vared ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W394 zsh's getln assigns the name it reads into" "getln ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W395 let assigns through arithmetic" "let ZENSU_SESSION_KEY=1" DENY "$PROJ" "$CFG_OFF"
run "W396 let assigns through a quoted compound operator" "let \"ZENSU_SESSION_KEY += 1\"" DENY "$PROJ" "$CFG_OFF"
run "W397 an arithmetic command assigns with spaces around =" "(( ZENSU_SESSION_KEY = 1 ))" DENY "$PROJ" "$CFG_OFF"
run "W398 an arithmetic prefix increment assigns" "(( ++CLAUDE_CODE_SESSION_ID ))" DENY "$PROJ" "$CFG_OFF"
run "W399 an arithmetic for loop assigns its counter" "for (( ZENSU_SESSION_KEY = 0; ZENSU_SESSION_KEY < 1; ZENSU_SESSION_KEY++ )); do :; done" DENY "$PROJ" "$CFG_OFF"
run "W400 an arithmetic expansion inside double quotes assigns" "echo \"\$(( ZENSU_SESSION_KEY <<= 1 ))\"" DENY "$PROJ" "$CFG_OFF"
run "W401 the \$[ ] arithmetic expansion assigns" ": \$[ ZENSU_SESSION_KEY = 1 ]" DENY "$PROJ" "$CFG_OFF"
run "W402 an operand of [[ -eq ]] is evaluated as arithmetic" "[[ ZENSU_SESSION_KEY=5 -eq 5 ]]" DENY "$PROJ" "$CFG_OFF"
run "W403 zsh evaluates the count of repeat as arithmetic" "repeat 'ZENSU_SESSION_KEY=1' true" DENY "$PROJ" "$CFG_OFF"
run "W404 zsh evaluates the operand of shift as arithmetic" "shift 'ZENSU_SESSION_KEY=1'" DENY "$PROJ" "$CFG_OFF"
run "W405 the subscript of an assignment word is evaluated as arithmetic" "a[ZENSU_SESSION_KEY=2]=x" DENY "$PROJ" "$CFG_OFF"
run "W406 the subscript of a printf -v operand is evaluated as arithmetic" "printf -v 'a[ZENSU_SESSION_KEY=3]' x" DENY "$PROJ" "$CFG_OFF"
run "W407 the subscript inside \${...} is evaluated as arithmetic" ": \${a[ZENSU_SESSION_KEY=1]}" DENY "$PROJ" "$CFG_OFF"
run "W408 \${NAME:=...} assigns a protected input" ": \${ZENSU_SESSION_KEY:=x}" DENY "$PROJ" "$CFG_OFF"
run "W409 \${NAME=...} inside double quotes assigns a protected input" "echo \"\${CLAUDE_CODE_SESSION_ID=x}\"" DENY "$PROJ" "$CFG_OFF"
run "W410 zsh's \${NAME::=...} assigns a protected input" ": \${ZENSU_SESSION_KEY::=x}" DENY "$PROJ" "$CFG_OFF"
run "W411 a nameref to a protected input is refused" "declare -n ref=ZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W412 a nameref without a target takes one from its first assignment" "declare -n ref; ref=ZENSU_SESSION_KEY; ref=x" DENY "$PROJ" "$CFG_OFF"
run "W413 local -n inside an option cluster is a nameref too" "f() { local -rn r=x; }; f" DENY "$PROJ" "$CFG_OFF"
run "W414 env -S expands \${VAR} into an assignment name" "env -S '\${N}=x bash' x.sh" DENY "$PROJ" "$CFG_OFF"
run "W415 env -S expands \${VAR} into the operand of -u" "env -S '-u \${N} bash' x.sh" DENY "$PROJ" "$CFG_OFF"
run "W416 an arithmetic lvalue built from \$N names its variable at run time" "(( \$N = 1 ))" DENY "$PROJ" "$CFG_OFF"
run "W417 zsh's \${(P)...} assignment names its variable at run time" ": \${(P)N::=x}" DENY "$PROJ" "$CFG_OFF"
LC_BODY_SUBST="$(printf 'cat <<EOF\n$(ZENSU_SESSION_KEY=x bash x.sh)\nEOF')"
run "W418 a command substitution in an unquoted heredoc body runs, so its rebind is refused" "$LC_BODY_SUBST" DENY "$PROJ" "$CFG_OFF"
LC_BODY_TICK="$(printf 'cat <<EOF\n`unset ZENSU_SESSION_KEY`\nEOF')"
run "W419 a backtick substitution in an unquoted heredoc body runs, so its unset is refused" "$LC_BODY_TICK" DENY "$PROJ" "$CFG_OFF"
LC_BODY_ARITH="$(printf ': <<EOF\n$(( ZENSU_SESSION_KEY = 7 ))\nEOF')"
run "W420 an arithmetic expansion in an unquoted heredoc body assigns" "$LC_BODY_ARITH" DENY "$PROJ" "$CFG_OFF"
LC_BODY_PARAM="$(printf 'cat <<EOF\n${ZENSU_SESSION_KEY:=x}\nEOF')"
run "W421 an assigning expansion in an unquoted heredoc body assigns" "$LC_BODY_PARAM" DENY "$PROJ" "$CFG_OFF"
LC_BODY_TABS="$(printf 'cat <<-EOF\n\t$(export ZENSU_SESSION_KEY=x)\n\tEOF')"
run "W422 a <<- body is read the same way" "$LC_BODY_TABS" DENY "$PROJ" "$CFG_OFF"
LC_BODY_QUOTED="$(printf 'cat <<%sEOF%s\n$(ZENSU_SESSION_KEY=x bash x.sh)\nEOF' "'" "'")"
run "W423 a quoted-delimiter heredoc body is not expanded and stays allowed" "$LC_BODY_QUOTED" ALLOW "$PROJ" "$CFG_OFF"
LC_BODY_TEXT="$(printf 'cat <<EOF\n\\$(ZENSU_SESSION_KEY=x bash x.sh)\nZENSU_SESSION_KEY=x is text\nEOF')"
run "W424 an escaped substitution and plain text in an unquoted body stay allowed" "$LC_BODY_TEXT" ALLOW "$PROJ" "$CFG_OFF"
run "W425 an arithmetic assignment inside single quotes stays allowed" "echo '\$(( ZENSU_SESSION_KEY = 1 ))'" ALLOW "$PROJ" "$CFG_OFF"
run "W426 grep for the assignment spelling stays allowed" "grep -rn \"ZENSU_SESSION_KEY=\" hooks" ALLOW "$PROJ" "$CFG_OFF"
run "W427 a pattern match and a default expansion stay allowed" "[[ \$l == ZENSU_SESSION_KEY=* && -n \"\${ZENSU_SESSION_KEY:-}\" ]]" ALLOW "$PROJ" "$CFG_OFF"
run "W428 read -p and getopts with expanded operands stay allowed" "read -p \"\$prompt\" x; getopts \"\$opts\" opt" ALLOW "$PROJ" "$CFG_OFF"
run "W429 printf of an assignment string and of the name stays allowed" "printf '%s\\n' \"ZENSU_SESSION_KEY=x\" ZENSU_SESSION_KEY" ALLOW "$PROJ" "$CFG_OFF"
run "W430 let, an arithmetic command and \${x:=} on other names stay allowed" "let x=1; (( i++ )); : \${x:=1}" ALLOW "$PROJ" "$CFG_OFF"
run "W431 mapfile, export PATH and an indexed assignment stay allowed" "mapfile -t lines < f; export PATH=\"\$HOME/bin:\$PATH\"; m[\$k]=v" ALLOW "$PROJ" "$CFG_OFF"
run "W432 names the shell builds at run time stay allowed" "export \$(cat .env | xargs); unset \"\$v\"" ALLOW "$PROJ" "$CFG_OFF"
run "W433 declare -p of a protected input and env FOO=1 stay allowed" "declare -p ZENSU_SESSION_KEY; env FOO=1 true" ALLOW "$PROJ" "$CFG_OFF"
run "W434 env -S expanding a value or an argument stays allowed" "env -S 'A=\${HOME} bash' x.sh; env -S 'bash \${HOME}/x.sh'" ALLOW "$PROJ" "$CFG_OFF"
LC_COMMENT_PARAM="$(printf '# ${ZENSU_SESSION_KEY:=x}\ntrue')"
run "W435 an assigning expansion inside a comment stays allowed" "$LC_COMMENT_PARAM" ALLOW "$PROJ" "$CFG_OFF"
REASON_NAMEREF="$(payload "declare -n ref=x" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
  -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_ENV_FILE="$PROJ/.claude-env" ZENSU_CONFIG="$CFG_OFF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
printf '%s' "$REASON_NAMEREF" | grep -qF 'Blocked a Bash nameref declaration, which this check cannot follow to the variable it names.' \
  && check "W436 every nameref is refused, with a reason that says the check cannot follow it" PASS \
  || check "W436 nameref reason (got '$REASON_NAMEREF')" FAIL
REASON_RUNTIME_NAME="$(payload "env -S '\${N}=x bash' x.sh" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
  -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_ENV_FILE="$PROJ/.claude-env" ZENSU_CONFIG="$CFG_OFF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
printf '%s' "$REASON_RUNTIME_NAME" | grep -qF 'builds the name of a variable it assigns or removes at run time' \
  && check "W437 a name built at run time is refused with a reason that says so" PASS \
  || check "W437 run-time name reason (got '$REASON_RUNTIME_NAME')" FAIL
run "W438 wait -p with the name attached to its option assigns it" "wait -n -pZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W439 read -a with the name attached inside an option cluster assigns it" "read -raZENSU_SESSION_KEY" DENY "$PROJ" "$CFG_OFF"
run "W440 a subscript holding a nested subscript is read as arithmetic" "a[ZENSU_SESSION_KEY=b[0]]=x" DENY "$PROJ" "$CFG_OFF"
run "W441 a subscript with blanks in an assignment word is read as arithmetic" "a[ ZENSU_SESSION_KEY=1 ]=x" DENY "$PROJ" "$CFG_OFF"
run "W442 a declaration operand's subscript with blanks is read as arithmetic" "declare a[ ZENSU_SESSION_KEY=1 ]=x" DENY "$PROJ" "$CFG_OFF"
LC_LOCALE_DELIM="$(printf 'cat <<$"EOF"\nEOF\nZENSU_SESSION_KEY=evil bash x.sh')"
run "W443 a \$\"…\" heredoc delimiter ends at its quote-removed word, so the next line is read" "$LC_LOCALE_DELIM" DENY "$PROJ" "$CFG_OFF"
LC_BODY_JOIN_ARITH="$(printf ': <<EOF\n$(( ZENSU_SESSION_\\\nKEY = 7 ))\nEOF')"
run "W444 a backslash-newline in an unquoted body is removed before the arithmetic is read" "$LC_BODY_JOIN_ARITH" DENY "$PROJ" "$CFG_OFF"
LC_BODY_JOIN_PARAM="$(printf ': <<EOF\n${ZENSU_SESSION_\\\nKEY::=evil}\nEOF')"
run "W445 a backslash-newline in an unquoted body is removed before an assigning expansion is read" "$LC_BODY_JOIN_PARAM" DENY "$PROJ" "$CFG_OFF"
run "W446 quoted text that names declare -n or mapfile stays allowed" "git commit -m \"Refuse namerefs (declare -n) outright\"; rg -n 'local -n|declare -n' hooks; rg -n 'x|mapfile ZENSU_SESSION_KEY' tests" ALLOW "$PROJ" "$CFG_OFF"
run "W447 a [[ operand after && is read as arithmetic" "[[ -n x && 1 -eq ZENSU_SESSION_KEY=5 ]]" DENY "$PROJ" "$CFG_OFF"
run "W448 a [[ operand after || is read as arithmetic" "[[ x || ZENSU_SESSION_KEY-=1 -ne 0 ]]" DENY "$PROJ" "$CFG_OFF"
run "W449 a [[ operand inside a group is read as arithmetic" "[[ ( 5 -eq ZENSU_SESSION_KEY=5 ) ]]" DENY "$PROJ" "$CFG_OFF"
run "W450 the substring offset of \$0 is read as arithmetic" ": \${0:ZENSU_SESSION_KEY=1}" DENY "$PROJ" "$CFG_OFF"
run "W451 the substring offset of \$@ is read as arithmetic" ": \${@:ZENSU_SESSION_KEY=1}" DENY "$PROJ" "$CFG_OFF"
run "W452 zsh's ::= after a = prefix modifier assigns" ": \${=ZENSU_SESSION_KEY::=evil}" DENY "$PROJ" "$CFG_OFF"
run "W453 zsh's ::= after a flag whose argument holds ) assigns" ": \${(s.).)ZENSU_SESSION_KEY::=evil}" DENY "$PROJ" "$CFG_OFF"
LC_BODY_CASE="$(printf ': <<EOF\n$(case x in x) ZENSU_SESSION_KEY=x bash x.sh;; esac)\nEOF')"
run "W454 a case pattern does not end a body substitution" "$LC_BODY_CASE" DENY "$PROJ" "$CFG_OFF"
LC_BODY_COMMENT="$(printf ': <<EOF\n$(# )\nZENSU_SESSION_KEY=x bash x.sh)\nEOF')"
run "W455 a comment does not end a body substitution" "$LC_BODY_COMMENT" DENY "$PROJ" "$CFG_OFF"
LC_COMMIT_QUOTED="$(printf 'git commit -m "$(cat <<%sEOF%s\nfix: refuse (( $N++ )) and ${ZENSU_SESSION_KEY:=x}\nEOF\n)"' "'" "'")"
run "W456 a quoted-delimiter heredoc inside a quoted substitution stays unread" "$LC_COMMIT_QUOTED" ALLOW "$PROJ" "$CFG_OFF"
LC_COMMIT_UNQUOTED="$(printf 'git commit -m "$(cat <<EOF\nfix: $(( ZENSU_SESSION_KEY = 1 ))\nEOF\n)"')"
run "W457 an unquoted-delimiter heredoc inside a quoted substitution is read" "$LC_COMMIT_UNQUOTED" DENY "$PROJ" "$CFG_OFF"
run "W458 a # right after a substitution is no comment" ": \$(:)#; (( ZENSU_SESSION_KEY = 1 ))" DENY "$PROJ" "$CFG_OFF"
run "W459 a # inside \${…} is no comment" ": \${MSG:-see #12}; (( ZENSU_SESSION_KEY = 1 ))" DENY "$PROJ" "$CFG_OFF"
LC_WORD_HASH_DOC="$(printf ': $(:)#x <<EOF\nit%ss $(( ZENSU_SESSION_KEY = 1 ))\nEOF' "'")"
run "W460 a heredoc after a word holding # is still a heredoc" "$LC_WORD_HASH_DOC" DENY "$PROJ" "$CFG_OFF"
LC_BODY_SUBSHELL_UNSET="$(printf 'cat <<EOF\n$((unset ZENSU_SESSION_KEY; bash x.sh) )\nEOF')"
run "W461 \$(( that does not close with )) is a command substitution in a body" "$LC_BODY_SUBSHELL_UNSET" DENY "$PROJ" "$CFG_OFF"
LC_BODY_SUBSHELL_ENV="$(printf 'cat <<EOF\n$((env -u ZENSU_SESSION_KEY bash x.sh) )\nEOF')"
run "W462 env -u inside such a body substitution is read" "$LC_BODY_SUBSHELL_ENV" DENY "$PROJ" "$CFG_OFF"
run "W463 an element subscript of an array literal is read as arithmetic" "a=([ZENSU_SESSION_KEY=1]=x)" DENY "$PROJ" "$CFG_OFF"
run "W464 an element subscript in a declare -a operand is read as arithmetic" "declare -a a=([ZENSU_SESSION_KEY=1]=x)" DENY "$PROJ" "$CFG_OFF"
run "W465 an element subscript in a += array literal is read as arithmetic" "a+=( [ZENSU_SESSION_KEY=1]=x )" DENY "$PROJ" "$CFG_OFF"
run "W466 an arithmetic target with a nested subscript assigns" "(( ZENSU_SESSION_KEY[a[0]] = 1 ))" DENY "$PROJ" "$CFG_OFF"
run "W467 let increments a target with a nested subscript" "let 'ZENSU_SESSION_KEY[b[0]]++'" DENY "$PROJ" "$CFG_OFF"
run "W468 an assigning expansion with a nested subscript assigns" ": \${ZENSU_SESSION_KEY[a[0]+1]:=x}" DENY "$PROJ" "$CFG_OFF"
LC_BRACE_SHIFT="$(printf ': ${x:-a<<b}\nZENSU_SESSION_KEY=evil bash x.sh')"
run "W469 a << inside \${…} is no heredoc, so the next line is read" "$LC_BRACE_SHIFT" DENY "$PROJ" "$CFG_OFF"
LC_BRACKET_SHIFT="$(printf ': $[1<<2]\nunset ZENSU_SESSION_KEY; bash x.sh')"
run "W470 a << inside \$[…] is no heredoc, so the next line is read" "$LC_BRACKET_SHIFT" DENY "$PROJ" "$CFG_OFF"
run "W471 zsh set -A with the array name attached assigns it" "set -AZENSU_SESSION_KEY evil" DENY "$PROJ" "$CFG_OFF"
run "W472 zsh set +A with the array name attached assigns it" "set +AZENSU_SESSION_KEY evil" DENY "$PROJ" "$CFG_OFF"
LC_COMMIT_APOSTROPHE="$(printf 'git commit -m "$(cat <<%sEOF%s\nfix: don%st drop the key\nEOF\n)"; (( ZENSU_SESSION_KEY = 1 ))' "'" "'" "'")"
run "W473 an apostrophe in a quoted heredoc message does not hide the next command" "$LC_COMMIT_APOSTROPHE" DENY "$PROJ" "$CFG_OFF"
LC_COMMIT_NAMEREF="$(printf 'git commit -m "$(cat <<%sEOF%s\ndeclare -n, typeset -n and local -n are refused.\nEOF\n)"' "'" "'")"
run "W474 a commit message that names declare -n stays allowed" "$LC_COMMIT_NAMEREF" ALLOW "$PROJ" "$CFG_OFF"
LC_DEEP="$(printf '%.0s$(' $(seq 70))x$(printf '%.0s)' $(seq 70))"
REASON_DEEP="$(payload "$LC_DEEP" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
  -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_ENV_FILE="$PROJ/.claude-env" ZENSU_CONFIG="$CFG_OFF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
printf '%s' "$REASON_DEEP" | grep -qF 'Blocked a Bash command nested deeper than this check reads.' \
  && check "W475 a command nested past the reader's depth bound is refused with a reason that says so" PASS \
  || check "W475 nesting reason (got '$REASON_DEEP')" FAIL
run "W476 a builtin inside a function body is read" "f() { mapfile ZENSU_SESSION_KEY; }" DENY "$PROJ" "$CFG_OFF"
run "W477 time before an arithmetic command does not hide it" "time (( ZENSU_SESSION_KEY = 1 ))" DENY "$PROJ" "$CFG_OFF"
run "W478 a group after coproc NAME is read as commands" "coproc X { ZENSU_SESSION_KEY=x bash x.sh; }" DENY "$PROJ" "$CFG_OFF"
run "W479 time before [[ does not hide its operands" "time [[ 1 -eq ZENSU_SESSION_KEY=1 ]]" DENY "$PROJ" "$CFG_OFF"
run "W480 a function definition, its call and a literal brace word stay allowed" "f() { echo hi; }; f; echo { a }" ALLOW "$PROJ" "$CFG_OFF"
run "W481 if written directly before (( still runs the arithmetic command" 'if(( ZENSU_SESSION_KEY = 1 )); then bash x.sh; fi' DENY "$PROJ" "$CFG_OFF"
run "W482 while written directly before (( still runs the arithmetic command" 'while(( ZENSU_SESSION_KEY = 1 )); do bash x.sh; break; done' DENY "$PROJ" "$CFG_OFF"
run "W483 for written directly before (( is the arithmetic for loop" 'for(( ZENSU_SESSION_KEY = 1; ; )); do bash x.sh; break; done' DENY "$PROJ" "$CFG_OFF"
run "W484 if written directly before ( still runs the subshell" 'if( getopts a ZENSU_SESSION_KEY -a; bash x.sh ); then :; fi' DENY "$PROJ" "$CFG_OFF"
run "W485 in written directly before a case pattern's ( still opens the pattern list" 'case x in(x) getopts a ZENSU_SESSION_KEY -a; bash x.sh;; esac' DENY "$PROJ" "$CFG_OFF"
run "W486 a brace word inside a subshell does not hide the subshell's closing paren" 'echo "$( ( echo { ); (( ZENSU_SESSION_KEY = 1 )); bash x.sh )"' DENY "$PROJ" "$CFG_OFF"
run "W487 a brace redirect target inside a subshell does not hide the subshell's closing paren" 'echo "$( ( echo > { ); (( ZENSU_SESSION_KEY = 1 )); bash x.sh )"' DENY "$PROJ" "$CFG_OFF"
run "W488 a case after time keeps its pattern parens inside a substitution" 'echo "$(time case x in x) (( ZENSU_SESSION_KEY = 1 )); bash x.sh;; esac)"' DENY "$PROJ" "$CFG_OFF"
run "W489 an assignment word after time keeps its blank-spaced subscript" 'time a[ ZENSU_SESSION_KEY=1 ]=x; bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W490 esac after | in a case pattern is a pattern word" 'echo "$(case x in a|esac|*) (( ZENSU_SESSION_KEY = 1 )); bash x.sh;; esac)"' DENY "$PROJ" "$CFG_OFF"
run "W491 a regex operand of =~ keeps its parens and | inside the conditional" 'echo "$( [[ x =~ (a|b) ]]; (( ZENSU_SESSION_KEY = 1 )); bash x.sh )"' DENY "$PROJ" "$CFG_OFF"
run "W492 an extended pattern after == keeps its parens and | inside the conditional" 'echo "$( [[ x == @(a|b) ]]; (( ZENSU_SESSION_KEY = 1 )); bash x.sh )"' DENY "$PROJ" "$CFG_OFF"
LC_COND_COMMENT="$(printf '[[ # ]]\n1 -eq ZENSU_SESSION_KEY=1 ]]; bash x.sh')"
run "W493 a comment inside a conditional does not end it" "$LC_COND_COMMENT" DENY "$PROJ" "$CFG_OFF"
LC_ARRAY_COMMENT="$(printf 'a=( # )\n[ZENSU_SESSION_KEY=1]=x ); bash x.sh')"
run "W494 a comment inside an array literal does not end it" "$LC_ARRAY_COMMENT" DENY "$PROJ" "$CFG_OFF"
LC_JOIN_ARITH="$(printf ': $\\\n(( ZENSU_SESSION_KEY = 1 )); bash x.sh')"
run "W495 a backslash-newline after \$ still forms an arithmetic expansion" "$LC_JOIN_ARITH" DENY "$PROJ" "$CFG_OFF"
LC_JOIN_PARAM="$(printf ': $\\\n{ZENSU_SESSION_KEY:=x}; bash x.sh')"
run "W496 a backslash-newline after \$ still forms an assigning expansion" "$LC_JOIN_PARAM" DENY "$PROJ" "$CFG_OFF"
LC_JOIN_SUBST="$(printf 'echo $\\\n(getopts a ZENSU_SESSION_KEY -a; bash x.sh)')"
run "W497 a backslash-newline after \$ still forms a command substitution" "$LC_JOIN_SUBST" DENY "$PROJ" "$CFG_OFF"
LC_JOIN_DELIM="$(printf 'cat <<EO\\\nF\nEOF\n(( ZENSU_SESSION_KEY = 1 )); bash x.sh')"
run "W498 a backslash-newline inside a heredoc delimiter is removed before it is compared" "$LC_JOIN_DELIM" DENY "$PROJ" "$CFG_OFF"
LC_JOIN_BODY="$(printf 'cat <<EOF\nE\\\nOF\n(( ZENSU_SESSION_KEY = 1 )); bash x.sh')"
run "W499 an unquoted heredoc body line joined by a backslash-newline can end the body" "$LC_JOIN_BODY" DENY "$PROJ" "$CFG_OFF"
run "W500 ! written directly before (( still runs the arithmetic command" '!(( ZENSU_SESSION_KEY = 1 )) || bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W501 until written directly before (( still runs the arithmetic command" 'until(( ZENSU_SESSION_KEY = 1 )); do bash x.sh; done' DENY "$PROJ" "$CFG_OFF"
run "W502 elif written directly before (( still runs the arithmetic command" 'if false; then :; elif(( ZENSU_SESSION_KEY = 1 )); then bash x.sh; fi' DENY "$PROJ" "$CFG_OFF"
run "W503 then written directly before (( still runs the arithmetic command" 'if true; then(( ZENSU_SESSION_KEY = 1 )); bash x.sh; fi' DENY "$PROJ" "$CFG_OFF"
run "W504 do written directly before (( still runs the arithmetic command" 'for i in 1; do(( ZENSU_SESSION_KEY = 1 )); bash x.sh; done' DENY "$PROJ" "$CFG_OFF"
run "W505 else written directly before (( still runs the arithmetic command" 'if false; then :; else(( ZENSU_SESSION_KEY = 1 )); bash x.sh; fi' DENY "$PROJ" "$CFG_OFF"
run "W506 time written directly before (( still runs the arithmetic command" 'time(( ZENSU_SESSION_KEY = 1 )); bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W507 an assignment word after time -- applies to the command" 'time -- ZENSU_SESSION_KEY=1 bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W508 an assignment word after time -p -- applies to the command" 'time -p -- ZENSU_SESSION_KEY=1 bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W509 regex and extended-pattern operands of [[ stay allowed" 'v=foo; [[ $v =~ ^(foo|bar)$ ]] && echo ok; [[ $v == @(a|b) ]] || echo no' ALLOW "$PROJ" "$CFG_OFF"
run "W510 brace words, a brace in a subshell and a brace redirect target stay allowed" 'echo { } "$( ( echo { ) )"; echo > {' ALLOW "$PROJ" "$CFG_OFF"
run "W511 esac as a pattern word after | or ( stays allowed" 'case x in a|esac) echo y;; esac; case esac in (esac) echo z;; esac' ALLOW "$PROJ" "$CFG_OFF"
run "W512 time with its options before a command or an arithmetic command stays allowed" 'time -p ls; time -- ls; time (( i++ ))' ALLOW "$PROJ" "$CFG_OFF"
run "W513 reserved words written directly before (( on other names stay allowed" 'if((i < 3)); then :; fi; while((n--)); do :; done' ALLOW "$PROJ" "$CFG_OFF"
LC_ARRAY_NOTE="$(printf 'a=( 1 # note\n2 ); echo ${a[1]}')"
run "W514 a commented array literal stays allowed" "$LC_ARRAY_NOTE" ALLOW "$PROJ" "$CFG_OFF"
LC_CONTINUED="$(printf 'docker run \\\n  -e FOO=1 \\\n  img')"
run "W515 a command continued over several lines stays allowed" "$LC_CONTINUED" ALLOW "$PROJ" "$CFG_OFF"
run "W516 a [[ word that is no command stays an argument" 'echo [[ x; ls' ALLOW "$PROJ" "$CFG_OFF"
LC_COND_NOTE="$(printf '[[ $x == y ]] # ZENSU_SESSION_KEY=1\nls')"
run "W517 a comment after a conditional stays unread" "$LC_COND_NOTE" ALLOW "$PROJ" "$CFG_OFF"
run "W518 time after a pipe is the external program, so a case word after it opens nothing" 'echo | time case x in; (( ZENSU_SESSION_KEY = 1 )); bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W519 a second -p after time is the command word, so a case word after it opens nothing" 'time -p -p case x in; (( ZENSU_SESSION_KEY = 1 )); bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W520 a case word that opens nothing does not hide later commands" 'time -p -p case x; let ZENSU_SESSION_KEY=1; bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W521 a [[ word in a case pattern opens no conditional" 'case x in [[ | x) ;; esac; (( ZENSU_SESSION_KEY = 1 )); bash x.sh; echo ]]' DENY "$PROJ" "$CFG_OFF"
run "W522 a [[ word after a leading redirection opens no conditional" '>f [[ x; (( ZENSU_SESSION_KEY = 1 )); bash x.sh; echo ]]' DENY "$PROJ" "$CFG_OFF"
LC_REDIRECT_COND="$(printf '>f [[ x\n(( ZENSU_SESSION_KEY = 1 ))\nbash x.sh')"
run "W523 a [[ word after a leading redirection does not swallow the next lines" "$LC_REDIRECT_COND" DENY "$PROJ" "$CFG_OFF"
run "W524 a case word after a leading redirection opens nothing" '>f case x in; (( ZENSU_SESSION_KEY = 1 )); bash x.sh' DENY "$PROJ" "$CFG_OFF"
LC_COMMENT_JOIN="$(printf '# \\\n: $\\\n(( ZENSU_SESSION_KEY = 1 )); bash x.sh')"
run "W525 a comment ending in a backslash does not continue onto the next line" "$LC_COMMENT_JOIN" DENY "$PROJ" "$CFG_OFF"
LC_QUOTED_BODY_JOIN="$(printf 'cat <<%sEOF%s\nx\\\nEOF\n: $\\\n(( ZENSU_SESSION_KEY = 1 )); bash x.sh' "'" "'")"
run "W526 a quoted heredoc body line ending in a backslash still ends at its delimiter" "$LC_QUOTED_BODY_JOIN" DENY "$PROJ" "$CFG_OFF"
run "W527 a case after coproc NAME is read as the coprocess command" 'echo "$(coproc X case x in x) (( ZENSU_SESSION_KEY = 1 )); bash x.sh;; esac); wait)"' DENY "$PROJ" "$CFG_OFF"
run "W528 a subshell written against coproc NAME is read as commands" 'coproc X(getopts a ZENSU_SESSION_KEY -a; bash x.sh); wait' DENY "$PROJ" "$CFG_OFF"
LC_EXTGLOB_PATTERN="$(printf 'shopt -s extglob\necho "$(case x in !(a)) (( ZENSU_SESSION_KEY = 1 )); bash x.sh;; esac)"')"
run "W529 an extended !( pattern in a case pattern list stays one pattern word" "$LC_EXTGLOB_PATTERN" DENY "$PROJ" "$CFG_OFF"
run "W530 then right after ]] is a reserved word" 'if [[ x ]] then(( ZENSU_SESSION_KEY = 1 )); bash x.sh; fi' DENY "$PROJ" "$CFG_OFF"
run "W531 a closing brace right after ]] ends its group" 'echo "$(case x in x) { [[ y ]] } ;& y) (( ZENSU_SESSION_KEY = 1 )); bash x.sh;; esac)"' DENY "$PROJ" "$CFG_OFF"
run "W532 zsh's typeset -T ties a protected input to an array" 'typeset -T ZENSU_SESSION_KEY k; k=(evil)' DENY "$PROJ" "$CFG_OFF"
run "W533 a typeset -i that converts a protected value is a rebind" 'typeset -i ZENSU_SESSION_KEY' DENY "$PROJ" "$CFG_OFF"
run "W534 a typeset -E that converts a protected value is a rebind" 'typeset -E ZENSU_SESSION_KEY' DENY "$PROJ" "$CFG_OFF"
run "W535 an assignment word after coproc applies to its simple command" 'coproc ZENSU_SESSION_KEY=x zensu-log.sh --x' DENY "$PROJ" "$CFG_OFF"
run "W536 a wrapper after coproc is read as in any simple command" 'coproc env CLAUDE_CODE_SESSION_ID=x cmd' DENY "$PROJ" "$CFG_OFF"
run "W537 zsh's brace-less \$NAME[…] subscript is read as arithmetic" ': $HOME[ZENSU_SESSION_KEY=1]' DENY "$PROJ" "$CFG_OFF"
run "W538 the -v operand of [[ evaluates its subscript" '[[ -v a[ZENSU_SESSION_KEY=1] ]]' DENY "$PROJ" "$CFG_OFF"
run "W539 the -v operand of test evaluates its subscript" "test -v 'a[ZENSU_SESSION_KEY=1]'" DENY "$PROJ" "$CFG_OFF"
run "W540 a builtin inside bash 5.3's \${ …; } runs in the current shell" ': ${ mapfile ZENSU_SESSION_KEY; }' DENY "$PROJ" "$CFG_OFF"
run "W541 a builtin inside bash 5.3's \${| …; } runs in the current shell" ': ${| getopts a ZENSU_SESSION_KEY; }' DENY "$PROJ" "$CFG_OFF"
run "W542 an option built at run time cannot hide a nameref to a protected input" 'o=-n; declare $o r=ZENSU_SESSION_KEY; r=evil; bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W543 an option built at run time cannot hide printf -v on a protected input" 'o=-v; printf $o ZENSU_SESSION_KEY evil; bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W544 zsh evaluates the operand of break as arithmetic" "for i in 1; do break 'ZENSU_SESSION_KEY=1'; done; zensu-log.sh --x" DENY "$PROJ" "$CFG_OFF"
run "W545 compgen -V turns a protected input into an unexported array" 'compgen -V ZENSU_SESSION_KEY -W evil; bash x.sh' DENY "$PROJ" "$CFG_OFF"
run "W546 an env -S string the shell expands builds no name for env" 'env -S "${ENV_ARGS}" node app.js; env -S ${ENV_ARGS} node app.js' ALLOW "$PROJ" "$CFG_OFF"
LC_NBSP_DELIM="$(printf 'cat <<EOF\302\240X\nEOF\302\240X\nZENSU_SESSION_KEY=evil zensu-log.sh --x\nEOF')"
run "W547 a heredoc delimiter keeps a blank the shell does not split on" "$LC_NBSP_DELIM" DENY "$PROJ" "$CFG_OFF"
run "W548 zsh's unset -m pattern that matches a protected input is a removal" "unset -m 'ZENSU_SESSION_*'" DENY "$PROJ" "$CFG_OFF"
run "W549 an unset -m pattern that matches no protected input stays allowed" "unset -m 'FOO_*'; unset -v FOO" ALLOW "$PROJ" "$CFG_OFF"
LC_WIDE_SUBSCRIPTS="$(printf 'a[;%.0s' $(seq 1 20000))"
run "W550 unclosed subscripts across a long command exhaust the work bound" "$LC_WIDE_SUBSCRIPTS" DENY "$PROJ" "$CFG_OFF"
run "W551 ordinary declarations, subscripts, test -v and a coproc group stay allowed" "local x=\"\$v\"; printf '%s=%s\n' ZENSU_SESSION_KEY \"\$ZENSU_SESSION_KEY\"; typeset -i count=0; echo \$PATH[0]; test -v HOME; coproc mycat { cat; }" ALLOW "$PROJ" "$CFG_OFF"

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
            ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
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
    CLAUDE_PROJECT_DIR="$PROJ" ZENSU_CONFIG="$CFG_ON" \
    ZENSU_BSWGATE_TEMP_DIRS="$WORKROOT/tmplink" bash "$HOOK" 2>/dev/null | classify)"
  [ "$OUT_TEMPLINK" = "DENY" ] \
    && check "W233 a temp entry whose realpath contains the project does not exempt everything" PASS \
    || check "W233 temp realpath ancestor exempted the tree (got '$OUT_TEMPLINK' want 'DENY')" FAIL
  OUT_TEMPLINK_OK="$(payload "printf x >> $FAKETMP/scratch.rs" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PROJECT_DIR="$PROJ" ZENSU_CONFIG="$CFG_ON" \
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
run "W215 tilde -C resolving outside HOME=sibling" "git -C ~ add ."                          DENY  "$PROJ" "$CFG_ON" "$PROJ/.claude-env" "$SIB"
run "W216 tilde -C resolving inside HOME=project (control)"  "git -C ~ add ."                          ALLOW "$PROJ" "$CFG_ON" "$PROJ/.claude-env" "$PROJ"
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
        CLAUDE_ENV_FILE="$PROJ/.claude-env" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
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
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
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
      ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_BASH_WRITE_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT_GIT_ENV" = "ALLOW" ] \
  && check "W120 process-env ZENSU_BASH_WRITE_GATE=off releases rule C -> ALLOW" PASS \
  || check "W120 process-env escape rule C (got '$OUT_GIT_ENV')" FAIL

# The process-env arm of ZENSU_MCP_GATE was pinned nowhere, for any rule, on
# either hook path — only its inline spelling was.
OUT_MCP_ENV="$(payload "git -C $SIB add ." | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
OUT_MCP_ENV_A="$(payload "printf x >> src/app.rs" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
{ [ "$OUT_MCP_ENV" = "ALLOW" ] && [ "$OUT_MCP_ENV_A" = "ALLOW" ]; } \
  && check "W166 process-env ZENSU_MCP_GATE=off releases rules A and C -> ALLOW" PASS \
  || check "W166 process-env ZENSU_MCP_GATE (ruleC='$OUT_MCP_ENV' ruleA='$OUT_MCP_ENV_A')" FAIL

# The deny has to be actionable on its own: which repo, which verb, the corrective
# form, and the opt-out. A reason naming only "a repository" leaves the agent
# guessing which checkout it just hit.
REASON_GIT="$(payload "git -C $SIB add ." | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_GIT" | grep -qF "$NS_SIB" \
  && printf '%s' "$REASON_GIT" | grep -qF 'git add' \
  && printf '%s' "$REASON_GIT" | grep -qF '/zensu:adopt-session --reanchor' \
  && ! printf '%s' "$REASON_GIT" | grep -qF "$NS_PROJ" \
  && ! printf '%s' "$REASON_GIT" | grep -qF 'git -C' \
  && ! printf '%s' "$REASON_GIT" | grep -qF 'ZENSU_BASH_WRITE_GATE' \
  && case "$REASON_GIT" in (*'ask the user to run it or to switch the gate off.') true ;; (*) false ;; esac; } \
  && check "W121 rule-C deny names repo, subcommand, the re-anchor route and the opt-in note last, never the escape prefix or another worktree" PASS \
  || check "W121 rule-C deny reason (want repo '$NS_SIB', --reanchor, opt-in note last, no '$NS_PROJ', no git -C, no escape prefix; got '$REASON_GIT')" FAIL

REASON_WRITE_OUT="$(payload "printf x > $SIB/src/new.rs" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_WRITE_OUT" | grep -qF "$NS_SIB" \
  && printf '%s' "$REASON_WRITE_OUT" | grep -qF '/zensu:adopt-session --reanchor' \
  && ! printf '%s' "$REASON_WRITE_OUT" | grep -qF "$NS_PROJ" \
  && ! printf '%s' "$REASON_WRITE_OUT" | grep -qF 'ZENSU_BASH_WRITE_GATE' \
  && case "$REASON_WRITE_OUT" in (*'ask the user to run it or to switch the gate off.') true ;; (*) false ;; esac; } \
  && check "W121c rule-B deny names the re-anchor route and the opt-in note last, never the escape prefix or another worktree" PASS \
  || check "W121c rule-B deny reason (want '$NS_SIB', --reanchor, opt-in note last, no '$NS_PROJ', no escape prefix; got '$REASON_WRITE_OUT')" FAIL

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
          ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
printf '%s' "$REASON_GIT_WT" | grep -qF 'denies again' \
  && check "W163 designated-path deny does not advise a -C that cannot clear it" PASS \
  || check "W163 designated-path remedy (got '$REASON_GIT_WT')" FAIL
{ printf '%s' "$REASON_GIT_WT" | grep -qF '/zensu:adopt-session --reanchor' \
  && ! printf '%s' "$REASON_GIT_WT" | grep -qF 'ZENSU_BASH_WRITE_GATE' \
  && case "$REASON_GIT_WT" in (*'ask the user to run it or to switch the gate off.') true ;; (*) false ;; esac; } \
  && check "W163c designated-path deny names the re-anchor route and keeps the opt-in note last, never the escape prefix" PASS \
  || check "W163c designated-path deny (want --reanchor, the opt-in note last and no escape prefix; got '$REASON_GIT_WT')" FAIL
! printf '%s' "$REASON_GIT_WT" | grep -qF "$NS_PROJ" \
  && check "W163b designated-path deny names no worktree other than the one it addressed" PASS \
  || check "W163b designated-path remedy names '$NS_PROJ' (got '$REASON_GIT_WT')" FAIL

# The third remedy arm. Without it a worktree deny would advise pointing
# --work-tree/--git-dir inside the root for a command that has neither flag.
REASON_WT_PATH="$(payload "git worktree remove --force $SIB/wt" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_WT_PATH" | grep -qF 'does not change which tree is destroyed' \
  && printf '%s' "$REASON_WT_PATH" | grep -qF "$NS_SIB_WT"; } \
  && check "W204 worktree deny names the destroyed tree and its own remedy" PASS \
  || check "W204 worktree remedy (want '$NS_SIB_WT' got '$REASON_WT_PATH')" FAIL
! printf '%s' "$REASON_WT_PATH" | grep -qF -- '--reanchor' \
  && check "W204b a worktree-operand deny offers no re-anchor, which would not stop the destroy" PASS \
  || check "W204b worktree-operand deny names --reanchor (got '$REASON_WT_PATH')" FAIL

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
    ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify
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
        ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "DENY" ] || VERB_FAIL="$VERB_FAIL $v($out)"
done
# The loop is driven BY the set, so it cannot notice a verb removed from it — the
# count assertion is what catches that direction; the membership list lives in
# git-repo-escape.test.js.
# An unconditional-deny regression would satisfy all 21+ DENY probes, so the same
# env shape must also produce an ALLOW.
VERB_CTRL="$(payload "git -C $SIB status" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
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
outside WRAP or the coproc keyword hides the verb
ride along on an in-project --work-tree
move the cwd to
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
  local label="$1" cmd="$2" exp="$3" cfg="${4:-$CFG_ON}"
  local out
  out="$(payload "$cmd" "$PROJ" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
        -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_ENV_FILE="$PROJ/.claude-env" \
        CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
        ZENSU_CONFIG="$cfg" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
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
run_unbound "W83d unbound at the default config + write to tracked source" "printf x >> src/app.rs" ALLOW "$CFG_UNSET"
run_unbound "W84d unbound at the default config + write escaping project"  "printf x >> $SIB/src/lib.rs" ALLOW "$CFG_UNSET"
run_unbound "W123d unbound at the default config + git mutation escaping project" "git -C $SIB add ." ALLOW "$CFG_UNSET"
run_unbound "W85d unbound at the default config + Session Control rebind still denies" "export ZENSU_SESSION_KEY=scv1_dead" DENY "$CFG_UNSET"
REASON_UNBOUND_C="$(payload "git -C $SIB add ." "$PROJ" | env -u ZENSU_SESSION_KEY \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ printf '%s' "$REASON_UNBOUND_C" | grep -qF "$NS_SIB" \
  && printf '%s' "$REASON_UNBOUND_C" | grep -qF "OUTSIDE this session's"; } \
  && check "W224 unbound rule-C deny keeps its own cause" PASS \
  || check "W224 unbound rule-C reason (got '$REASON_UNBOUND_C')" FAIL
! printf '%s' "$REASON_UNBOUND_C" | grep -qF -- '--reanchor' \
  && check "W224b unbound rule-C deny offers no re-anchor a session without a record cannot run" PASS \
  || check "W224b unbound rule-C reason names --reanchor (got '$REASON_UNBOUND_C')" FAIL

# The unbound deny must keep the ORIGINAL write-rule cause and its opt-in note —
# not only the appended binding sentence, or dropping the cause would leave every
# assertion green while the user loses the reason the write was refused.
REASON_UNBOUND="$(payload "printf x >> src/app.rs" "$PROJ" | env -u ZENSU_SESSION_KEY \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
# Two distinct states reach this branch — no record at all, and a record whose
# recorded project root is gone — so the binding sentence must name both rather
# than assert the first, which would send a user with a deleted worktree hunting
# for a record that is right there.
{ printf '%s' "$REASON_UNBOUND" | grep -qF 'tracked' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF 'hooks.bashWriteGate is true' \
  && ! printf '%s' "$REASON_UNBOUND" | grep -qF 'ZENSU_BASH_WRITE_GATE' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF 'no usable Session Control project root' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF 'no record at all' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF 'no longer exists' \
  && printf '%s' "$REASON_UNBOUND" | grep -qF '/zensu:doctor'; } \
  && check "W87 unbound rule-A deny keeps its cause, the opt-in key, both binding gaps and /zensu:doctor" PASS \
  || check "W87 unbound deny reason (got '$REASON_UNBOUND')" FAIL
REASON_UNBOUND_B="$(payload "printf x >> $SIB/src/lib.rs" "$PROJ" | env -u ZENSU_SESSION_KEY \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
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
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
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
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$OUT_UNBOUND_NOPROJ" | grep -qF 'permissionDecision":"deny' \
  && printf '%s' "$OUT_UNBOUND_NOPROJ" | grep -qF 'no usable CLAUDE_PROJECT_DIR' \
  && printf '%s' "$OUT_UNBOUND_NOPROJ" | grep -qF 'hooks.bashWriteGate is true' \
  && ! printf '%s' "$OUT_UNBOUND_NOPROJ" | grep -qF 'ZENSU_BASH_WRITE_GATE'; } \
  && check "W87e unbound without CLAUDE_PROJECT_DIR denies with that exact cause and names the opt-in key" PASS \
  || check "W87e unbound missing project root (got '$OUT_UNBOUND_NOPROJ')" FAIL
OUT_UNBOUND_NOPROJ_DEF="$(payload "printf x > src/never-created-here.rs" "$PROJ" | env -u CLAUDE_PROJECT_DIR \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_UNSET" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT_UNBOUND_NOPROJ_DEF" = "ALLOW" ] \
  && check "W87e2 at the default config the no-anchor write deny does not run" PASS \
  || check "W87e2 no-anchor write at the default config (got '$OUT_UNBOUND_NOPROJ_DEF')" FAIL

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
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
REASON_PARSER_FAIL="$(payload "printf x >> src/app.rs" "$PROJ" | env \
  PATH="$PARSER_FAIL_BIN:$PATH" ZENSU_TEST_REAL_NODE="$(command -v node)" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
{ [ "$OUT_PARSER_FAIL" = "DENY" ] \
  && printf '%s' "$REASON_PARSER_FAIL" | grep -qF 'hooks.bashWriteGate is true' \
  && ! printf '%s' "$REASON_PARSER_FAIL" | grep -qF 'ZENSU_BASH_WRITE_GATE'; } \
  && check "W87f unbound parser runtime failure denies, never allows unchecked, and names the opt-in key" PASS \
  || check "W87f unbound parser failure (got '$OUT_PARSER_FAIL' / '$REASON_PARSER_FAIL')" FAIL

# The BOUND path used to discard the parser's exit status while its two siblings
# honored theirs. Same shim, no CLAUDE_PLUGIN_DATA override, so the bind succeeds.
OUT_PARSER_FAIL_BOUND="$(payload "printf x >> src/app.rs" "$PROJ" | env \
  PATH="$PARSER_FAIL_BIN:$PATH" ZENSU_TEST_REAL_NODE="$(command -v node)" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
REASON_PARSER_FAIL_BOUND="$(payload "printf x >> src/app.rs" "$PROJ" | env \
  PATH="$PARSER_FAIL_BIN:$PATH" ZENSU_TEST_REAL_NODE="$(command -v node)" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | reason)"
# A bare DENY cannot show WHICH branch answered — the unbound arm and a narrowed
# bind failure both deny too. Only the bound arm emits this sentence.
{ [ "$OUT_PARSER_FAIL_BOUND" = "DENY" ] \
  && printf '%s' "$REASON_PARSER_FAIL_BOUND" | grep -qF 'could not be evaluated for this session' \
  && printf '%s' "$REASON_PARSER_FAIL_BOUND" | grep -qF 'hooks.bashWriteGate to false in the Zensu config layer that enables it' \
  && ! printf '%s' "$REASON_PARSER_FAIL_BOUND" | grep -qF 'ZENSU_BASH_WRITE_GATE'; } \
  && check "W218 bound parser runtime failure denies with the bound-arm reason" PASS \
  || check "W218 bound parser failure (got '$OUT_PARSER_FAIL_BOUND' / '$REASON_PARSER_FAIL_BOUND')" FAIL

# The relaxation covers exactly those two states. A record that exists but disagrees with the
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
    ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$OUT_FOREIGN" = "DENY" ] \
    && check "W87g a record from another installation stays fail-closed, relaxation is not reused" PASS \
    || check "W87g foreign record (got '$OUT_FOREIGN')" FAIL
  OUT_FOREIGN_DEF="$(payload "git status" "$PROJ" | env \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$FOREIGN_DATA" \
    ZENSU_CONFIG="$CFG_UNSET" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$OUT_FOREIGN_DEF" = "ALLOW" ] \
    && check "W87g2 at the default config the gate exits before its bind, leaving a foreign record to the capability gate" PASS \
    || check "W87g2 foreign record at the default config (got '$OUT_FOREIGN_DEF')" FAIL
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
# TWO states are relaxable, so the narrowed deny must say both were ruled out —
# and must not assert "no record" as the cause, which would send a user whose
# recorded worktree was deleted hunting for a record that is sitting intact in
# plugin data. Same misdiagnosis the doctor and Stop reasons were corrected for.
{ printf '%s' "$DENY_NARROWED" | grep -qF 'immutable Zensu session binding is unavailable' \
  && printf '%s' "$DENY_NARROWED" | grep -qF 'neither relaxable state' \
  && printf '%s' "$DENY_NARROWED" | grep -qF 'recorded project root no longer exists'; } \
  && check "W96 the narrowed deny says BOTH relaxable states were already ruled out" PASS \
  || check "W96 narrowed deny (got '$DENY_NARROWED')" FAIL
# Only callers that actually pre-filter may claim the narrowed scope. TWO routes
# reach it now and both are scanned, because scanning one alone is how this check
# went quietly wrong once: the per-gate ladder moved into
# zensu_emit_named_bind_deny, the gates began passing the scope as an argument,
# and the grep for the direct spelling matched NOTHING while the property it
# guards was still perfectly intact. An empty result compares unequal, so it
# failed loudly rather than passing — but a needle that matches nothing has
# stopped testing its subject in either direction. The shared helper itself must
# never appear in this set: it renders whatever scope it is handed and claims none.
NARROWED_CALLERS="$( {
  grep -rlF 'zensu_emit_hook_session_deny narrowed' "$PLUGIN_DIR/hooks"
  grep -rlE 'zensu_emit_named_bind_deny "\$[A-Za-z_][A-Za-z0-9_]*" narrowed' "$PLUGIN_DIR/hooks"
} 2>/dev/null | sort -u)"
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
  CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
OUT_UNBOUND_JUNK="$(printf '%s' 'not json' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
{ [ "$OUT_UNBOUND_EMPTY" = "DENY" ] && [ "$OUT_UNBOUND_JUNK" = "DENY" ]; } \
  && check "W88 unbound + unparseable payload still denies" PASS \
  || check "W88 unbound unparseable (empty='$OUT_UNBOUND_EMPTY' junk='$OUT_UNBOUND_JUNK')" FAIL

# The explicit escapes stay reachable while unbound — a user who knowingly opts
# out must not need a bindable session to do it.
OUT_UNBOUND_ESCAPE="$(payload "printf x >> src/app.rs" "$PROJ" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" ZENSU_CONFIG="$CFG_ON" \
  ZENSU_BASH_WRITE_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT_UNBOUND_ESCAPE" = "ALLOW" ] \
  && check "W89 unbound + process-env escape -> ALLOW" PASS \
  || check "W89 unbound process-env escape (got '$OUT_UNBOUND_ESCAPE')" FAIL

psrun() {
  local label="$1" cmd="$2" exp="$3" cfg="${4:-$CFG_ON}"
  local out
  out="$(payload "$cmd" "$PROJ" PowerShell | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
        -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
        CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_ENV_FILE="$PROJ/.claude-env" \
        ZENSU_CONFIG="$cfg" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}
psrun "WP1 PowerShell rebind of a Session Control input with the gate off"   "\$env:ZENSU_SESSION_KEY = 'x'"                      DENY "$CFG_OFF"
psrun "WP2 PowerShell SetEnvironmentVariable under a run-time name"           "[Environment]::SetEnvironmentVariable(\$n, 'x')"     DENY "$CFG_OFF"
psrun "WP3 PowerShell write to the CLAUDE_ENV_FILE path"                       "Add-Content -Path '$PROJ/.claude-env' -Value 'x'"   DENY "$CFG_OFF"
psrun "WP4 PowerShell Environment provider path built at run time"           "Set-Item \"env:\$n\" 1"                             DENY "$CFG_OFF"
psrun "WP5 PowerShell Invoke-Expression of text built at run time"           "iex \$code"                                        DENY "$CFG_OFF"
psrun "WP6 PowerShell unrelated environment variable with the gate off"      "\$env:OTHER = 'x'; Get-ChildItem"                  ALLOW "$CFG_OFF"
psrun "WP7 PowerShell write with the gate off"                               "Set-Content src/app.rs 'x'"                        ALLOW "$CFG_OFF"
psrun "WP8 PowerShell read-only pipeline with the gate on"                   "Get-ChildItem -Recurse | Select-String fn"         ALLOW
psrun "WP9 PowerShell write cmdlet with the gate on"                         "Set-Content src/app.rs 'x'"                        DENY
psrun "WP10 PowerShell redirection into a file with the gate on"             "Get-Content src/app.rs > src/copy.rs"              DENY
psrun "WP11 PowerShell native program with the gate on"                      "git status"                                        DENY
psrun "WP12 PowerShell redirection to the null device with the gate on"      "Get-ChildItem 2>\$null"                            ALLOW
WP_CONTROL="$(payload "\$env:ZENSU_SESSION_KEY = 'x'" "$PROJ" PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_ENV_FILE="$PROJ/.claude-env" ZENSU_CONFIG="$CFG_OFF" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$WP_CONTROL" | grep -qF 'Blocked a PowerShell command because it names the protected Session Control input ZENSU_SESSION_KEY' \
  && printf '%s' "$WP_CONTROL" | grep -qF 'run it through the Bash tool' \
  && ! printf '%s' "$WP_CONTROL" | grep -qF 'hooks.bashWriteGate'; } \
  && check "WP13 the PowerShell control deny names the input and the Bash tool" PASS \
  || check "WP13 PowerShell control deny wording (got '$WP_CONTROL')" FAIL
WP_CHILD="$(node -e 'process.stdout.write(JSON.stringify({tool_name:"PowerShell",agent_id:"a1",agent_type:"general-purpose",tool_input:{command:"iex $code"},cwd:"/tmp"}))' \
  | BSWG_MODE=control PAYLOAD= node "$PARSER" 2>/dev/null)"
{ printf '%s' "$WP_CHILD" | grep -qF 'report the need to the main thread' && ! printf '%s' "$WP_CHILD" | grep -qF 'Bash tool'; } \
  && check "WP14 the PowerShell control deny sends a subagent to the main thread" PASS \
  || check "WP14 PowerShell control deny for a subagent (got '$WP_CHILD')" FAIL
WP_RULES="$(payload "Set-Content src/app.rs 'x'" "$PROJ" PowerShell | env -u ZENSU_PROJECT_ROOT CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
  CLAUDE_ENV_FILE="$PROJ/.claude-env" ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$WP_RULES" | grep -qF 'source-write rules cannot judge, because Set-Content is not a read-only command' \
  && printf '%s' "$WP_RULES" | grep -qF 'Run it through the Bash tool, or change files with Edit or Write.' \
  && printf '%s' "$WP_RULES" | grep -qF 'hooks.bashWriteGate is true' \
  && ! printf '%s' "$WP_RULES" | grep -qF 'ZENSU_BASH_WRITE_GATE'; } \
  && check "WP15 the PowerShell rules deny names the refused command, the Bash tool and the opt-in key" PASS \
  || check "WP15 PowerShell rules deny wording (got '$WP_RULES')" FAIL
WP_UNBOUND="$(payload "Set-Content src/never-created-here.rs 'x'" "$PROJ" PowerShell | env -u CLAUDE_PROJECT_DIR \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
WP_UNBOUND_READ="$(payload "Get-ChildItem -Recurse" "$PROJ" PowerShell | env -u CLAUDE_PROJECT_DIR \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$UNBOUND_DATA" \
  ZENSU_CONFIG="$CFG_ON" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$WP_UNBOUND" | grep -qF 'WRITE-TARGET (unevaluated: a PowerShell command this check cannot prove read-only' && [ -z "$WP_UNBOUND_READ" ]; } \
  && check "WP16 unbound without CLAUDE_PROJECT_DIR a PowerShell write denies and a PowerShell read passes" PASS \
  || check "WP16 unbound PowerShell (write='$WP_UNBOUND' read='$WP_UNBOUND_READ')" FAIL
WP_COPY="$WORKROOT/powershell-module-missing"
mkdir -p "$WP_COPY"
cp -R "$PLUGIN_DIR/hooks" "$WP_COPY/hooks"
rm -f "$WP_COPY/hooks/lib/powershell-command-v1.js"
WP_MISSING="$(payload "Get-ChildItem" "$PROJ" PowerShell | env CLAUDE_PLUGIN_ROOT="$WP_COPY" CLAUDE_PROJECT_DIR="$PROJ" \
  ZENSU_CONFIG="$CFG_OFF" bash "$WP_COPY/hooks/pre-bash-source-write-gate.sh" 2>/dev/null)"
WP_MISSING_BASH="$(payload "ls" "$PROJ" | env CLAUDE_PLUGIN_ROOT="$WP_COPY" CLAUDE_PROJECT_DIR="$PROJ" \
  ZENSU_CONFIG="$CFG_OFF" bash "$WP_COPY/hooks/pre-bash-source-write-gate.sh" 2>/dev/null)"
{ [ ! -e "$WP_COPY/hooks/lib/powershell-command-v1.js" ] \
  && printf '%s' "$WP_MISSING" | grep -qF '"permissionDecision":"deny"' \
  && printf '%s' "$WP_MISSING" | grep -qF 'powershell-command-v1.js could not be loaded' \
  && printf '%s' "$WP_MISSING" | grep -qF 'Run the command through the Bash tool, and reinstall the plugin' \
  && ! printf '%s' "$WP_MISSING" | grep -qF 'retry in a fresh session' && [ -z "$WP_MISSING_BASH" ]; } \
  && check "WP17 without the analyzer every PowerShell call denies with the Bash tool and a reinstall named, and a Bash call is unaffected" PASS \
  || check "WP17 analyzer-less copy (powershell='$WP_MISSING' bash='$WP_MISSING_BASH')" FAIL
rm -rf "$WP_COPY"

rm -f "$CFG_ON" "$CFG_OFF" "$CFG_UNSET" "$CFG_QUOTED"

unit_check_done "W3z every unit file the registry gives this suite was graded"
echo "----"
echo "test-bash-source-write-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
