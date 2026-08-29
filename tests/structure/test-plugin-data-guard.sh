#!/bin/bash
set -u

# Behavioural pin for hooks/pre-write-plugin-data-guard.sh.
#
# The hook denies a file-mutating tool call whose resolved target lies inside
# CLAUDE_PLUGIN_DATA. Before it existed, all three PreToolUse hooks matching a
# `Write` answered `allow` for such a target in every chain state — measured and
# recorded in docs/multi-repo-chains-spec.md §6.1.2. This suite drives the real
# hook against a real Session Control session and pins both directions.
#
# TWO HARNESS TRAPS ARE LOAD-BEARING HERE, both learned by measurement:
#
#   1. EVERY payload must carry `cwd`. Without it pre-reviewer-capability-gate.sh
#      answers `reviewer-capability-v1 deny: tool cwd is unavailable or unsafe`
#      (hooks/lib/reviewer-capability-v1.js) for EVERY destination, so a
#      three-hook check would report a containment that is not there and the
#      suite would pass for the wrong reason.
#   2. The allow controls are what make the deny checks mean anything. A hook
#      that denied unconditionally would satisfy every deny row on its own, so
#      the in-project and outside-the-project rows are not decoration.
#
# SCOPE, stated because the header above reasons about three hooks and the suite
# drives ONE: every row invokes only pre-write-plugin-data-guard.sh. An allow row
# therefore establishes that THIS hook does not deny, never that the write would
# be permitted — on a matcher where any hook's deny wins, those are different
# claims. The three-hook measurement that motivated the feature is recorded in
# docs/multi-repo-chains-spec.md §6.1.2, not re-established here.
#
# The chain-state rows exist because the sibling phase gate returns early while
# no chain is armed, and a strict chain denies EVERYTHING at UNINITIALIZED for
# an unrelated reason. `RED_WRITE` is used for the strict row precisely because
# it permits writes, so a deny there is this guard's and nobody else's.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$PLUGIN_DIR/hooks/pre-write-plugin-data-guard.sh"
LOG_HELPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

ESCAPE_RE='ZENSU_[A-Z_]+=.?off'

PASS=0; FAIL=0; SKIPPED=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
# An environment limitation is not a defect. Recording it as a FAIL would turn a
# host without real symlinks into a red suite; recording it as a PASS would hide
# the lost coverage. It gets its own counter and its own line.
skipped() { echo "  SKIP  $1"; SKIPPED=$((SKIPPED+1)); }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN 2>/dev/null || true

# Apple bash 3.2 is the floor here, so the scratch roots are tracked as a
# newline-delimited string rather than an array: an empty array expansion under
# `set -u` aborts on that shell.
TMP_ROOTS=""
cleanup() {
  local d
  while IFS= read -r d; do [ -n "$d" ] && rm -rf "$d"; done <<< "$TMP_ROOTS"
}
trap cleanup EXIT

payload() { # $1 tool  $2 file field  $3 path  $4 session  $5 cwd  [$6 agent_type]
  node -e '
    const [tool, field, target, sid, cwd, agentType] = process.argv.slice(1);
    const input = { content: "x" };
    input[field] = target;
    const body = {
      hook_event_name: "PreToolUse", tool_name: tool, tool_input: input,
      session_id: sid, cwd,
    };
    // claude-principal-v1.js classifies from the PAYLOAD, never from
    // CLAUDE_AGENT_TYPE — an env prefix leaves the caller classified as MAIN, so
    // a principal row driven that way could not fail for its stated reason.
    if (agentType) { body.agent_type = agentType; body.agent_id = "agent-fixture-1"; }
    process.stdout.write(JSON.stringify(body));
  ' "$1" "$2" "$3" "$4" "$5" "${6:-}"
}

verdict() { # $1 hook  rest: payload args -> ALLOW | DENY
  local hook="$1"; shift
  payload "$@" | bash "$hook" 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { console.log("ALLOW"); return; }
      try {
        const j = JSON.parse(s);
        const h = j.hookSpecificOutput || {};
        console.log(h.permissionDecision === "deny" ? "DENY" : "ALLOW");
      } catch (_) { console.log("UNPARSED"); }
    });'
}

# Raw hook output. verdict() reduces the response to two words, which threw the
# deny REASON and the stderr note away — FR-005 and the fault disclosures were
# asserted by nothing until these existed.
raw_stdout() { local hook="$1"; shift; payload "$@" | bash "$hook" 2>/dev/null; }
raw_stderr() { local hook="$1"; shift; payload "$@" 2>/dev/null | bash "$hook" 2>&1 >/dev/null; }

# Sets PROJ and exports CLAUDE_PROJECT_DIR in the CURRENT shell. It must not be
# called through a command substitution: the export would land in the subshell,
# and initialize-baseline.sh's `${CLAUDE_PROJECT_DIR:?}` would then terminate the
# sourcing shell with no output at all.
#
# The template is `${TMPDIR:-/tmp}`, never a hardcoded macOS-only path: that path
# does not exist on the ubuntu-latest deterministic shard this suite runs on, and
# `mktemp -d` would fail there and abort the whole file. What the hardcode was
# reaching for — macOS's default TMPDIR sitting behind the /var symlink — is
# already handled by the `cd -P && pwd -P` below, the idiom
# tests/structure/test-versioned-plugin-upgrade.sh uses for the same reason.
new_project() {
  PROJ="$(mktemp -d "${TMPDIR:-/tmp}/zensu-pdg.XXXXXX")" || return 1
  PROJ="$(cd "$PROJ" && pwd -P)" || return 1
  TMP_ROOTS="$TMP_ROOTS$PROJ
"
  mkdir -p "$PROJ/src"
  export CLAUDE_PROJECT_DIR="$PROJ"
}

# Returns non-zero when arming fails. Discarding that status let the vanilla and
# strict rows silently re-measure the unarmed case three times, which is the one
# way the chain-state rows can pass while testing nothing.
arm() { # $1 none|vanilla|strict
  local cfg="$CLAUDE_PROJECT_DIR/cfg.json"
  case "$1" in
    vanilla)
      printf '%s' '{"hooks":{"tddImplementation":false}}' > "$cfg"; export ZENSU_CONFIG="$cfg"
      bash "$LOG_HELPER" --tdd-begin >/dev/null 2>&1 || return 1 ;;
    strict)
      printf '%s' '{"hooks":{"tddImplementation":true}}' > "$cfg"; export ZENSU_CONFIG="$cfg"
      bash "$LOG_HELPER" --tdd-begin --tdd-mode strict >/dev/null 2>&1 || return 1
      bash "$LOG_HELPER" --phase RED_WRITE --step g1 >/dev/null 2>&1 || return 1 ;;
    *)
      printf '%s' '{"hooks":{"tddImplementation":false}}' > "$cfg"; export ZENSU_CONFIG="$cfg" ;;
  esac
  return 0
}

# The premise each armed row rests on, read from the workflow document rather
# than assumed: the phase the header says permits writes must actually be the
# recorded one.
armed_phase() {
  local doc
  doc="$(ls "$CLAUDE_PROJECT_DIR"/.zensu/state/tdd-phase-*.json 2>/dev/null | head -1)"
  [ -n "$doc" ] || { echo "(no document)"; return 1; }
  node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).phase)}catch(_){console.log("(unreadable)")}' "$doc"
}

# --- G1-G3: the store is denied in every chain state -------------------------
i=0
for state in none vanilla strict; do
  i=$((i + 1))
  new_project || { check "G$i project fixture" FAIL; continue; }
  SID="pdg-state-$i"
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID" >/dev/null 2>&1 || {
    check "G$i session baseline ($state)" FAIL; continue; }
  if arm "$state"; then
    check "G$i-arm the $state chain state was actually established" PASS
  else
    check "G$i-arm the $state chain state was actually established" FAIL
  fi
  if [ "$state" = "strict" ]; then
    PH="$(armed_phase)"
    [ "$PH" = "RED_WRITE" ] \
      && check "G$i-premise the strict chain really sits at RED_WRITE, the phase that permits writes" PASS \
      || check "G$i-premise the strict chain really sits at RED_WRITE (got '$PH')" FAIL
  fi
  STORE_TARGET="$CLAUDE_PLUGIN_DATA/session-control/v1/planted.json"
  [ "$(verdict "$GUARD" Write file_path "$STORE_TARGET" "$SID" "$PROJ")" = "DENY" ] \
    && check "G$i Write into the plugin-data store is denied (chain: $state)" PASS \
    || check "G$i Write into the plugin-data store is denied (chain: $state)" FAIL
  # Control: the same run must still allow an ordinary in-project write, or the
  # deny above proves nothing about containment.
  [ "$(verdict "$GUARD" Write file_path "$PROJ/src/foo.ts" "$SID" "$PROJ")" = "ALLOW" ] \
    && check "G$i-control in-project write still allowed (chain: $state)" PASS \
    || check "G$i-control in-project write still allowed (chain: $state)" FAIL
done

# --- G4-G9: tools, controls and the containment anchor -----------------------
new_project || { echo "FATAL: fixture"; exit 2; }
SID="pdg-shapes"
# shellcheck disable=SC1090
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID" >/dev/null 2>&1 \
  || { echo "FATAL: baseline"; exit 2; }
arm none
STORE="$CLAUDE_PLUGIN_DATA"
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/zensu-pdg-out.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
[ -n "$OUTSIDE" ] && [ -d "$OUTSIDE" ] || { echo "FATAL: fixture"; exit 2; }
OUTSIDE="$(cd "$OUTSIDE" && pwd -P)" || { echo "FATAL: fixture"; exit 2; }
TMP_ROOTS="$TMP_ROOTS$OUTSIDE
"
SIBLING="${STORE}-sibling"; mkdir -p "$SIBLING"
TMP_ROOTS="$TMP_ROOTS$SIBLING
"

[ "$(verdict "$GUARD" NotebookEdit notebook_path "$STORE/nb.ipynb" "$SID" "$PROJ")" = "DENY" ] \
  && check "G4 NotebookEdit into the store is denied" PASS \
  || check "G4 NotebookEdit into the store is denied" FAIL

[ "$(verdict "$GUARD" Edit file_path "$STORE/edited.json" "$SID" "$PROJ")" = "DENY" ] \
  && check "G5 Edit into the store is denied" PASS \
  || check "G5 Edit into the store is denied" FAIL

[ "$(verdict "$GUARD" Write file_path "$OUTSIDE/planted.json" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "G6 a write outside the project but outside the store is allowed" PASS \
  || check "G6 a write outside the project but outside the store is allowed" FAIL

# The anchored-containment bite: a sibling directory whose path merely PREFIXES
# the store must not be swept in. An unanchored startsWith would deny this.
[ "$(verdict "$GUARD" Write file_path "$SIBLING/planted.json" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "G7 a sibling directory whose path prefixes the store is allowed" PASS \
  || check "G7 a sibling directory whose path prefixes the store is allowed" FAIL

# A relative target resolves against the payload cwd, so standing in the store
# must not become a way in.
[ "$(verdict "$GUARD" Write file_path "planted.json" "$SID" "$STORE")" = "DENY" ] \
  && check "G8 a relative target resolved against a cwd inside the store is denied" PASS \
  || check "G8 a relative target resolved against a cwd inside the store is denied" FAIL

[ "$(verdict "$GUARD" Bash file_path "$STORE/planted.json" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "G9 a non-write tool is not judged by this gate" PASS \
  || check "G9 a non-write tool is not judged by this gate" FAIL

[ "$(verdict "$GUARD" MultiEdit file_path "$STORE/multi.json" "$SID" "$PROJ")" = "DENY" ] \
  && check "G9a MultiEdit into the store is denied" PASS \
  || check "G9a MultiEdit into the store is denied" FAIL

# --- G15-G18: symlink resolution ---------------------------------------------
# The property resolveTargetPath() exists for. Before these checks, every
# target the suite used was already canonical, so deleting canonicalize() left all
# rows green — the suite could not tell the implemented rule from a bare resolve.
mkdir -p "$OUTSIDE/sym"
ln -s "$STORE" "$OUTSIDE/sym/live" 2>/dev/null
ln -s "$STORE/session-control/v1/new.json" "$OUTSIDE/sym/dangling" 2>/dev/null
ln -s "$OUTSIDE/elsewhere.json" "$OUTSIDE/sym/outward" 2>/dev/null
# `ln -s` exiting 0 is not evidence of a symlink — Git Bash satisfies it with a
# copy or a shortcut that native Node does not follow, and this suite runs on the
# weekly Windows structure shard. Confirm through the same primitive the module
# decides with (fs.lstatSync().isSymbolicLink()), never through bash's `[ -L ]`.
is_symlink() {
  node -e 'try{process.exit(require("fs").lstatSync(process.argv[1]).isSymbolicLink()?0:1)}catch(_){process.exit(1)}' "$1"
}
# A host that HAS symlinks must not reach the skip arm: skipping there would hide
# a broken fixture rather than an absent capability. Only a host that genuinely
# cannot create them (Git Bash) is allowed to skip.
case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin|Linux)
    if is_symlink "$OUTSIDE/sym/live" && is_symlink "$OUTSIDE/sym/dangling"; then
      check "G14b-premise the POSIX fixture produced real symlinks" PASS
    else
      check "G14b-premise the POSIX fixture produced real symlinks" FAIL
    fi ;;
  *) skipped "G14b-premise POSIX symlink fixture (host is not POSIX)" ;;
esac
if is_symlink "$OUTSIDE/sym/live" && is_symlink "$OUTSIDE/sym/dangling"; then
  [ "$(verdict "$GUARD" Write file_path "$OUTSIDE/sym/live/session-control/v1/x.json" "$SID" "$PROJ")" = "DENY" ] \
    && check "G15 a write through a symlinked directory into the store is denied" PASS \
    || check "G15 a write through a symlinked directory into the store is denied" FAIL
  # The measured bypass: the leaf is a link to a file that does not exist yet, so
  # realpath cannot resolve it and the canonical spelling stays outside the store,
  # while the tool's own open(O_CREAT) follows the link in.
  [ "$(verdict "$GUARD" Write file_path "$OUTSIDE/sym/dangling" "$SID" "$PROJ")" = "DENY" ] \
    && check "G16 a dangling leaf symlink pointing into the store is denied" PASS \
    || check "G16 a dangling leaf symlink pointing into the store is denied" FAIL
  # Control for G16: the same shape pointing somewhere else must stay allowed, or
  # G16 would be satisfied by denying every symlink.
  [ "$(verdict "$GUARD" Write file_path "$OUTSIDE/sym/outward" "$SID" "$PROJ")" = "ALLOW" ] \
    && check "G17-control a dangling leaf symlink pointing outside the store is allowed" PASS \
    || check "G17-control a dangling leaf symlink pointing outside the store is allowed" FAIL
else
  skipped "G15 symlinked-directory deny (host produced no real symlink)"
  skipped "G16 dangling-leaf deny (host produced no real symlink)"
  skipped "G17-control dangling leaf outside the store (host produced no real symlink)"
fi
# The measured second bypass of the same class: `..` after a symlink into the
# store. path.resolve collapses `..` lexically, so before the component walk the
# link was never read and the judged path stayed outside while the kernel would
# land inside. The control is the same target without the `..`.
mkdir -p "$STORE/sub"
ln -s "$STORE/sub" "$OUTSIDE/sym/into" 2>/dev/null
if is_symlink "$OUTSIDE/sym/into"; then
  [ "$(verdict "$GUARD" Write file_path "$OUTSIDE/sym/into/../x.json" "$SID" "$PROJ")" = "DENY" ] \
    && check "G18 \`..\` after a symlink into the store is denied" PASS \
    || check "G18 \`..\` after a symlink into the store is denied" FAIL
  [ "$(verdict "$GUARD" Write file_path "$OUTSIDE/sym/into/x.json" "$SID" "$PROJ")" = "DENY" ] \
    && check "G18a-control the same target without the \`..\` is denied too" PASS \
    || check "G18a-control the same target without the \`..\` is denied too" FAIL
  # And the inverse: `..` that leaves the store must not be swept in.
  [ "$(verdict "$GUARD" Write file_path "$STORE/../outside-again.json" "$SID" "$PROJ")" = "ALLOW" ] \
    && check "G18b-control \`..\` that leaves the store is allowed" PASS \
    || check "G18b-control \`..\` that leaves the store is allowed" FAIL
else
  skipped "G18 \`..\` after a symlink into the store (host produced no real symlink)"
  skipped "G18a-control the same target without the \`..\` (host produced no real symlink)"
  skipped "G18b-control \`..\` that leaves the store (host produced no real symlink)"
fi

# The case-variant bypass, measured before the walk canonicalized each existing
# component: the store is realpath'd while the target kept the caller's spelling,
# so on a case-insensitive volume a case-flipped prefix lstats fine, compares as
# outside by pure string relative(), and the kernel writes inside.
STORE_PARENT="$(dirname "$STORE")"
STORE_LEAF="$(basename "$STORE")"
STORE_FLIPPED="$(printf '%s' "$STORE_LEAF" | tr '[:lower:][:upper:]' '[:upper:][:lower:]')"
if [ "$STORE_FLIPPED" != "$STORE_LEAF" ] && [ -d "$STORE_PARENT/$STORE_FLIPPED" ]; then
  [ "$(verdict "$GUARD" Write file_path "$STORE_PARENT/$STORE_FLIPPED/planted.json" "$SID" "$PROJ")" = "DENY" ] \
    && check "G23 a case-variant spelling of the store prefix is denied" PASS \
    || check "G23 a case-variant spelling of the store prefix is denied" FAIL
else
  skipped "G23 case-variant store prefix (case-sensitive volume, or no letters to flip)"
fi

# The two-hop symlink: a link whose TARGET traverses another link into the store.
# Allowed before the link target was re-split into the same walk.
ln -s "$STORE" "$OUTSIDE/sym/p" 2>/dev/null
ln -s "$OUTSIDE/sym/p/q.json" "$OUTSIDE/sym/L" 2>/dev/null
if is_symlink "$OUTSIDE/sym/L" && is_symlink "$OUTSIDE/sym/p"; then
  [ "$(verdict "$GUARD" Write file_path "$OUTSIDE/sym/L" "$SID" "$PROJ")" = "DENY" ] \
    && check "G24 a link whose target traverses another link into the store is denied" PASS \
    || check "G24 a link whose target traverses another link into the store is denied" FAIL
else
  skipped "G24 two-hop symlink (host produced no real symlink)"
fi

# Every path-bearing field is judged, not the first: a benign file_path beside a
# store-targeting notebook_path must still deny.
G25="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"NotebookEdit",tool_input:{file_path:process.argv[1],notebook_path:process.argv[2],content:"x"},session_id:process.argv[3],cwd:process.argv[4]}))' \
  "$PROJ/src/benign.ts" "$STORE/second-field.ipynb" "$SID" "$PROJ" | bash "$GUARD" 2>/dev/null | node -e '
  let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();
    if(!s){console.log("ALLOW");return}
    try{console.log((JSON.parse(s).hookSpecificOutput||{}).permissionDecision==="deny"?"DENY":"ALLOW")}catch(_){console.log("UNPARSED")}});')"
[ "$G25" = "DENY" ] \
  && check "G25 a store target in the second path field is judged, not skipped" PASS \
  || check "G25 a store target in the second path field is judged (got $G25)" FAIL

# A backslash is a legal POSIX filename character. Splitting on it unconditionally
# decomposed the path differently from the kernel: a symlink literally named `a\b`
# was never lstat'ed and the store it pointed into was judged outside. Measured as
# ALLOWED before splitSegments became platform-conditional.
BSLINK="$OUTSIDE/sym/a\\b"
ln -s "$STORE" "$BSLINK" 2>/dev/null
if is_symlink "$BSLINK"; then
  [ "$(verdict "$GUARD" Write file_path "$BSLINK/planted.json" "$SID" "$PROJ")" = "DENY" ] \
    && check "G27 a symlink whose name contains a backslash is followed, not split" PASS \
    || check "G27 a symlink whose name contains a backslash is followed, not split" FAIL
else
  skipped "G27 backslash-named symlink (host would not create it)"
fi
# Control: an ordinary backslash-bearing name outside the store stays allowed, so
# G27 cannot be satisfied by denying every backslash.
[ "$(verdict "$GUARD" Write file_path "$OUTSIDE/plain\\name.json" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "G27a-control a backslash-bearing name outside the store is allowed" PASS \
  || check "G27a-control a backslash-bearing name outside the store is allowed" FAIL

# The module must declare each of its resolver functions exactly ONCE. Two
# byte-identical copies shipped in this file and the 52 behavioural rows could not
# see them: the later declaration wins by hoisting, so an edit to the first would
# have been a silent no-op.
# Derived from the module rather than a hardcoded pair: the hoisting hazard
# applies to EVERY module-scope function, so a ninth one must be covered without
# an edit here.
MODULE_FNS="$(grep -oE '^function [A-Za-z_][A-Za-z0-9_]*' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" | awk '{print $2}' | sort -u)"
[ -n "$MODULE_FNS" ] \
  && check "G28-control the module declares functions this pin can count" PASS \
  || check "G28-control the module declares functions this pin can count" FAIL
for FN in $MODULE_FNS; do
  N="$(grep -c "^function $FN(" "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js")"
  [ "$N" = "1" ] \
    && check "G28 $FN is declared exactly once in the module" PASS \
    || check "G28 $FN is declared exactly once in the module (found $N)" FAIL
done

# The parser must still EXPORT what the guard requires. G13 pins the require and
# the absence of a local copy; neither notices an export-list edit, which is the
# change that silently degrades this DENY gate to allow.
EXPORTS_OK="$(node -e '
  const p = require(process.argv[1]);
  process.stdout.write(typeof p.within === "function" && typeof p.msysToDrive === "function" ? "yes" : "no");
' "$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js")"
[ "$EXPORTS_OK" = "yes" ] \
  && check "G29 the parser still exports within and msysToDrive as functions" PASS \
  || check "G29 the parser still exports within and msysToDrive as functions (got $EXPORTS_OK)" FAIL

# The one branch that can BLOCK a call. Every other fault allows; this one exits 2
# with a message, exactly as in every sibling gate, and nothing asserted it.
OTHERROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-pdg-otherroot.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
[ -n "$OTHERROOT" ] && [ -d "$OTHERROOT" ] || { echo "FATAL: fixture"; exit 2; }
OTHERROOT="$(cd "$OTHERROOT" && pwd -P)" || { echo "FATAL: fixture"; exit 2; }
TMP_ROOTS="$TMP_ROOTS$OTHERROOT
"
# One invocation, one status, one message: capturing them from two runs read as
# though the status belonged to the stderr capture.
payload Write file_path "$STORE/x.json" "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$OTHERROOT" bash "$GUARD" >/dev/null 2>"$OTHERROOT/err.txt"
G26RC=$?
G26E="$(cat "$OTHERROOT/err.txt" 2>/dev/null)"
[ "$G26RC" = "2" ] \
  && check "G26 a mismatched inherited CLAUDE_PLUGIN_ROOT refuses with exit 2" PASS \
  || check "G26 a mismatched inherited CLAUDE_PLUGIN_ROOT refuses with exit 2 (got rc=$G26RC)" FAIL
case "$G26E" in
  *"does not match the executing plugin"*) check "G26a and it names the cause on stderr" PASS ;;
  *) check "G26a and it names the cause on stderr (got '$G26E')" FAIL ;;
esac

ln -s "$OUTSIDE/sym/loopA" "$OUTSIDE/sym/loopB" 2>/dev/null
ln -s "$OUTSIDE/sym/loopB" "$OUTSIDE/sym/loopA" 2>/dev/null
if is_symlink "$OUTSIDE/sym/loopA"; then
  [ "$(verdict "$GUARD" Write file_path "$OUTSIDE/sym/loopA" "$SID" "$PROJ")" = "ALLOW" ] \
    && check "G18c a symlink cycle terminates and allows rather than hanging" PASS \
    || check "G18c a symlink cycle terminates and allows rather than hanging" FAIL
else
  skipped "G18c symlink cycle (host produced no real symlink)"
fi

# --- G19-G21: the deny reason and the principal ------------------------------
REASON="$(raw_stdout "$GUARD" Write file_path "$STORE/reason.json" "$SID" "$PROJ")"
case "$REASON" in
  *"private data store"*) check "G19 the deny reason names the store (FR-005)" PASS ;;
  *) check "G19 the deny reason names the store (FR-005)" FAIL ;;
esac
if [ -z "$REASON" ]; then
  check "G20 the deny reason teaches no escape (no reason captured — vacuous)" FAIL
elif printf '%s' "$REASON" | grep -qE "$ESCAPE_RE"; then
  check "G20 the deny reason teaches no escape" FAIL
else
  check "G20 the deny reason teaches no escape" PASS
fi

# FR-001: no main-principal gate. A subagent must not be able to write the store
# either, so the same deny must hold with a non-main principal in the environment.
G21="$(verdict "$GUARD" Write file_path "$STORE/agent.json" "$SID" "$PROJ" zensu:code-reviewer)"
[ "$G21" = "DENY" ] \
  && check "G21 the deny holds for a payload-declared non-main principal (FR-001)" PASS \
  || check "G21 the deny holds for a payload-declared non-main principal (FR-001, got $G21)" FAIL
# Premise: the fixture really does classify as non-main, or G21 measures MAIN twice.
# The premise must consult the module that DECIDES the principal, not re-read the
# two keys this suite wrote — otherwise it proves the fixture's shape and nothing
# about how the plugin classifies it.
G21P="$(payload Write file_path "$STORE/agent.json" "$SID" "$PROJ" zensu:code-reviewer \
  | node -e '
    const principals = require(process.argv[1]);
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      try {
        const p = JSON.parse(s);
        const who = principals.classifyPreToolPayload(p);
        console.log(who === principals.PRINCIPALS.MAIN ? "main" : "non-main");
      } catch (e) { console.log("unclassified"); }
    });' "$PLUGIN_DIR/hooks/lib/claude-principal-v1.js")"
[ "$G21P" = "non-main" ] \
  && check "G21-premise claude-principal-v1.js classifies the fixture as non-main" PASS \
  || check "G21-premise claude-principal-v1.js classifies the fixture as non-main (got $G21P)" FAIL

# --- G10-G11: fault direction ------------------------------------------------
G10="$(CLAUDE_PLUGIN_DATA="" verdict "$GUARD" Write file_path "$STORE/planted.json" "$SID" "$PROJ")"
[ "$G10" = "ALLOW" ] \
  && check "G10 an empty CLAUDE_PLUGIN_DATA allows rather than denies" PASS \
  || check "G10 an empty CLAUDE_PLUGIN_DATA allows rather than denies (got $G10)" FAIL

G11="$(CLAUDE_PLUGIN_DATA="$PROJ/does-not-exist" verdict "$GUARD" Write file_path "$STORE/planted.json" "$SID" "$PROJ")"
[ "$G11" = "ALLOW" ] \
  && check "G11 an unresolvable CLAUDE_PLUGIN_DATA allows rather than denies" PASS \
  || check "G11 an unresolvable CLAUDE_PLUGIN_DATA allows rather than denies (got $G11)" FAIL
# Same corroboration its sibling G11a carries: without it, ALLOW here is
# indistinguishable from a hook that never ran.
G11d="$(CLAUDE_PLUGIN_DATA="$PROJ/does-not-exist" raw_stderr "$GUARD" Write file_path "$STORE/planted.json" "$SID" "$PROJ")"
case "$G11d" in
  *"plugin-data-unset-or-unresolvable"*) check "G11d an unresolvable store is disclosed on stderr too" PASS ;;
  *) check "G11d an unresolvable store is disclosed on stderr too (got '$G11d')" FAIL ;;
esac

# An allow that is silent is indistinguishable from a clean allow, and this is the
# fault that turns the control off completely. The docs promise a stderr note.
G11a="$(CLAUDE_PLUGIN_DATA="" raw_stderr "$GUARD" Write file_path "$STORE/planted.json" "$SID" "$PROJ")"
case "$G11a" in
  *"plugin-data-unset-or-unresolvable"*) check "G11a an unarmed store is disclosed on stderr with its own reason" PASS ;;
  *) check "G11a an unarmed store is disclosed on stderr with its own reason (got '$G11a')" FAIL ;;
esac
# Control: an ordinary allow must stay quiet, or G11a would pass on noise.
G11b="$(raw_stderr "$GUARD" Write file_path "$PROJ/src/foo.ts" "$SID" "$PROJ")"
[ -z "$G11b" ] \
  && check "G11b-control an ordinary allow prints nothing on stderr" PASS \
  || check "G11b-control an ordinary allow prints nothing on stderr (got '$G11b')" FAIL

# A payload carrying no path field at all: allow, and quietly — it is not a fault
# that could hide a missing boundary.
NOPATH="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{content:"x"},session_id:process.argv[1],cwd:process.argv[2]}))' "$SID" "$PROJ")"
G11c="$(printf '%s' "$NOPATH" | bash "$GUARD" 2>/dev/null)"
G11cE="$(printf '%s' "$NOPATH" | bash "$GUARD" 2>&1 >/dev/null)"
[ -z "$G11c" ] \
  && check "G11c a payload with no path field allows" PASS \
  || check "G11c a payload with no path field allows (got '$G11c')" FAIL
# The comment used to claim quietness the row did not measure; stderr is asserted now.
[ -z "$G11cE" ] \
  && check "G11c-quiet and it allows quietly — a missing path cannot hide a missing boundary" PASS \
  || check "G11c-quiet and it allows quietly (got '$G11cE')" FAIL

# F11: the remaining disclosed faults. An unparseable payload is UNREADABLE.
BADJSON="$(printf '%s' 'not json at all')"
G11e="$(printf '%s' "$BADJSON" | bash "$GUARD" 2>/dev/null)"
G11eE="$(printf '%s' "$BADJSON" | bash "$GUARD" 2>&1 >/dev/null)"
[ -z "$G11e" ] \
  && check "G11e an unparseable payload allows" PASS \
  || check "G11e an unparseable payload allows (got '$G11e')" FAIL
case "$G11eE" in
  *"payload-unreadable"*) check "G11f an unparseable payload is disclosed with the payload reason" PASS ;;
  *) check "G11f an unparseable payload is disclosed on stderr (got '$G11eE')" FAIL ;;
esac

# GUARD_UNAVAILABLE: a plugin tree whose containment module is gone. Copying the
# two hook files plus an empty lib is enough — the require fails, the module
# loads, and the fault direction is what is under test.
FAKE="$(mktemp -d "${TMPDIR:-/tmp}/zensu-pdg-fake.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
[ -n "$FAKE" ] && [ -d "$FAKE" ] || { echo "FATAL: fixture"; exit 2; }
FAKE="$(cd "$FAKE" && pwd -P)" || { echo "FATAL: fixture"; exit 2; }
TMP_ROOTS="$TMP_ROOTS$FAKE
"
mkdir -p "$FAKE/hooks/lib"
cp "$GUARD" "$FAKE/hooks/" 2>/dev/null
cp "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" "$FAKE/hooks/lib/" 2>/dev/null
G11g="$(payload Write file_path "$STORE/planted.json" "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$FAKE" bash "$FAKE/hooks/pre-write-plugin-data-guard.sh" 2>/dev/null)"
G11gE="$(payload Write file_path "$STORE/planted.json" "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$FAKE" bash "$FAKE/hooks/pre-write-plugin-data-guard.sh" 2>&1 >/dev/null)"
[ -z "$G11g" ] \
  && check "G11g a tree without the containment module allows rather than denies" PASS \
  || check "G11g a tree without the containment module allows rather than denies (got '$G11g')" FAIL
case "$G11gE" in
  *"containment-rule-unavailable"*) check "G11h a missing containment module is disclosed with its own reason" PASS ;;
  *) check "G11h a missing containment module is disclosed on stderr (got '$G11gE')" FAIL ;;
esac

# The wrapper's own silent early exit: the module file absent. It must allow, and
# the docs say plainly that this one carries NO note.
FAKE2="$(mktemp -d "${TMPDIR:-/tmp}/zensu-pdg-fake2.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
[ -n "$FAKE2" ] && [ -d "$FAKE2" ] || { echo "FATAL: fixture"; exit 2; }
FAKE2="$(cd "$FAKE2" && pwd -P)" || { echo "FATAL: fixture"; exit 2; }
TMP_ROOTS="$TMP_ROOTS$FAKE2
"
mkdir -p "$FAKE2/hooks/lib"
cp "$GUARD" "$FAKE2/hooks/" 2>/dev/null
G11i="$(payload Write file_path "$STORE/planted.json" "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$FAKE2" bash "$FAKE2/hooks/pre-write-plugin-data-guard.sh" 2>&1)"
[ -z "$G11i" ] \
  && check "G11i an absent guard module allows silently, as documented" PASS \
  || check "G11i an absent guard module allows silently (got '$G11i')" FAIL

# --- G12-G14: source contracts ----------------------------------------------
# G12 and G13 assert the ABSENCE of a spelling, so each carries a control that
# fires the same pattern at a file known to contain it. Without the control a
# typo in the pattern turns the check green while testing nothing — the failure
# mode this repository has recorded more than once.
WITHIN_RE='^[[:space:]]*(function|const)[[:space:]]+within[[:space:]]*[(=]'

# No escape hatch: a ZENSU_*=off spelling here would hand back the capability the
# guard removes, and would owe an ESCAPE_STEMS entry it deliberately does not have.
if grep -qE "$ESCAPE_RE" "$GUARD" "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js"; then
  check "G12 the guard teaches no ZENSU_*=off escape" FAIL
else
  check "G12 the guard teaches no ZENSU_*=off escape" PASS
fi
if grep -qE "$ESCAPE_RE" "$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh"; then
  check "G12-control the escape pattern matches a file that does carry one" PASS
else
  check "G12-control the escape pattern matches a file that does carry one" FAIL
fi

# Containment comes from the module that owns it. A private re-spelling would be
# the fifth member of a hand-copy family this repository already tracks.
if grep -q 'require("./bash-source-write-parse.js")' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" \
  && ! grep -qE "$WITHIN_RE" "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js"; then
  check "G13 containment is required from the parser, never re-spelled" PASS
else
  check "G13 containment is required from the parser, never re-spelled" FAIL
fi
if grep -qE "$WITHIN_RE" "$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js"; then
  check "G13-control the within pattern matches the module that defines it" PASS
else
  check "G13-control the within pattern matches the module that defines it" FAIL
fi

# Registered on BOTH write matchers. A deny from any hook on a matcher wins, so
# an unregistered matcher is a silently unprotected tool family.
# The separator matters: `|` is also the matcher's own alternation, so joining on
# it cannot tell two groups from one combined matcher. Count and membership are
# asserted separately, and the tool set the module gates is compared against the
# tool names the matchers actually select — a matcher widened without touching
# WRITE_TOOLS yields a hook that runs and allows, with no signal.
REG="$(node -e '
  const path = require("path");
  const j = require(process.argv[1]);
  const guard = require(process.argv[2]);
  const want = "pre-write-plugin-data-guard.sh";
  const matchers = [];
  for (const group of j.hooks.PreToolUse || []) {
    if ((group.hooks || []).some((h) => h.command.includes(want))) matchers.push(group.matcher);
  }
  const selected = new Set(matchers.flatMap((m) => m.split("|")));
  const gated = [...guard.WRITE_TOOLS].sort().join(",");
  console.log(matchers.length + " " + [...selected].sort().join(",") + " " + gated);
' "$PLUGIN_DIR/hooks/hooks.json" "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js")"
REG_GROUPS="${REG%% *}"; REG_REST="${REG#* }"
REG_SELECTED="${REG_REST%% *}"; REG_GATED="${REG_REST##* }"
[ "$REG_GROUPS" = "2" ] \
  && check "G14 registered as two separate matcher groups" PASS \
  || check "G14 registered as two separate matcher groups (got $REG_GROUPS)" FAIL
[ "$REG_SELECTED" = "$REG_GATED" ] \
  && check "G14a the registered matchers and WRITE_TOOLS name the same tools ($REG_GATED)" PASS \
  || check "G14a the registered matchers and WRITE_TOOLS name the same tools (matchers=$REG_SELECTED gated=$REG_GATED)" FAIL

# A floor, because `exit 0` also accepts a file that registered no checks at all:
# an early `continue`, a deleted block or a skipped fixture would otherwise leave
# this suite green while measuring less than it claims. Raise it deliberately.
# SKIP-AWARE, or the counter defeats itself: nine rows sit behind the symlink
# premise, so a host without real symlinks would drop below any fixed floor and
# turn red — exactly what the skipped() counter exists to prevent.
EXPECTED_CHECKS=65
TOTAL=$((PASS + FAIL + SKIPPED))
[ "$TOTAL" -ge "$EXPECTED_CHECKS" ] \
  && check "G22 the suite registered at least $EXPECTED_CHECKS rows ($TOTAL incl. $SKIPPED skipped)" PASS \
  || check "G22 the suite registered at least $EXPECTED_CHECKS rows (only $TOTAL incl. $SKIPPED skipped)" FAIL

echo "----"
echo "test-plugin-data-guard: $PASS PASS / $FAIL FAIL / $SKIPPED SKIP"
[ "$FAIL" -eq 0 ]
