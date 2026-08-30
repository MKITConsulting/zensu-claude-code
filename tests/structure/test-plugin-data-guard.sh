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
# An ENVIRONMENTAL skip is a fact about the host, not lost coverage: the premise
# the row needs cannot exist here and no other host would have exercised it
# differently. It still counts toward SKIPPED — the reader must see it — but the
# zero-skip rule below must not fail on it. Measured: G23 needs a case-INSENSITIVE
# volume, so it skips on every case-sensitive filesystem, which is Linux CI; the
# suite went red there while every macOS run reported 0 SKIP.
SKIPPED_ENV=0
skipped_env() { skipped "$1"; SKIPPED_ENV=$((SKIPPED_ENV+1)); }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN 2>/dev/null || true

# Apple bash 3.2 is the floor here, so the scratch roots are tracked as a
# newline-delimited string rather than an array: an empty array expansion under
# `set -u` aborts on that shell.

# --- G38: the unit driver ----------------------------------------------------
# tests/run-all.sh discovers only tests/structure/test-*.sh, so a *.test.js file
# with no driver is never executed by the tree runner. This row is that driver.
# It runs FIRST among the expensive rows for the reason the sibling
# stop-enforcer suite states: at the tail, a Windows shard timeout would drop the
# only coverage the module's injectable seams have anywhere.
#
# The case-count floor is not decoration — `node --test` exits 0 for a file that
# registers no cases at all, so an early `return` or a deleted block would leave
# this row green while measuring nothing.
UNIT="$PLUGIN_DIR/tests/structure/plugin-data-guard-v1.test.js"
# The reporter is PINNED. Node selects `spec` or `tap` by its own rules, and
# the two spell the summary differently — the floor silently read 0 against the
# spec form while the suite itself was green, which is the exact vacuity this
# row exists to prevent.
UNIT_OUT="$(node --test --test-reporter=tap "$UNIT" 2>&1)"; UNIT_RC=$?
UNIT_PASS="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p')"
UNIT_SKIP="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^# skipped \([0-9][0-9]*\)$/\1/p')"
[ -z "$UNIT_PASS" ] && UNIT_PASS=0
[ -z "$UNIT_SKIP" ] && UNIT_SKIP=0
UNIT_REG=$((UNIT_PASS + UNIT_SKIP))
[ "$UNIT_RC" -eq 0 ] \
  && check "G38 the plugin-data-guard unit suite passes" PASS \
  || check "G38 the plugin-data-guard unit suite passes (rc=$UNIT_RC)" FAIL
# REGISTERED, not passing. Three unit cases skip themselves on a host that cannot
# produce a real symlink, so a floor set from this host's passing count would turn
# such a host red for an environment fact — the same mistake G42 was fixed for one
# axis over. The registered count is what is platform-independent.
[ "$UNIT_REG" -ge 37 ] \
  && check "G38-floor the unit suite registered at least 37 cases ($UNIT_REG = $UNIT_PASS passing + $UNIT_SKIP skipped)" PASS \
  || check "G38-floor the unit suite registered at least 37 cases (only $UNIT_REG)" FAIL
# ...and a separate passing floor that tolerates exactly the three symlink cases,
# so a case that stops running for any OTHER reason still costs the suite.
[ "$UNIT_PASS" -ge 34 ] \
  && check "G38-pass at least 34 unit cases actually ran ($UNIT_PASS, $UNIT_SKIP skipped)" PASS \
  || check "G38-pass at least 34 unit cases actually ran (only $UNIT_PASS)" FAIL

TMP_ROOTS=""
cleanup() {
  local d
  while IFS= read -r d; do [ -n "$d" ] && rm -rf -- "$d"; done <<< "$TMP_ROOTS"
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
# The store fixture is VALIDATED before a single row writes into it. It is not
# this suite's own mktemp: initialize-baseline.sh derives it from
# ZENSU_TEST_PLUGIN_DATA, which an environment can point anywhere. Unvalidated,
# `mkdir -p "$STORE/sub"` and the `-sibling` fixture below create directories in
# whatever that names — measured against an override outside the suite's temp
# namespace, which was written into and left behind. Containment in $PROJ is the
# check because $PROJ is the one root this file registered for cleanup, so
# "inside it" and "we will remove it" are the same statement.
STORE="$CLAUDE_PLUGIN_DATA"
[ -n "$STORE" ] || { echo "FATAL: fixture: the baseline left CLAUDE_PLUGIN_DATA empty"; exit 2; }
case "$STORE" in
  /*) ;;
  *) echo "FATAL: fixture: store is not absolute: $STORE"; exit 2 ;;
esac
[ -d "$STORE" ] && [ ! -L "$STORE" ] \
  || { echo "FATAL: fixture: store is not a real directory: $STORE"; exit 2; }
STORE="$(cd "$STORE" && pwd -P)" || { echo "FATAL: fixture: store is unresolvable"; exit 2; }
case "$STORE" in
  "$PROJ"/*) ;;
  *) echo "FATAL: fixture: the store must live under this run's own project root."
     echo "         got:      $STORE"
     echo "         expected: below $PROJ"
     echo "         (ZENSU_TEST_PLUGIN_DATA is set to a tree this suite would write into and never clean up)"
     exit 2 ;;
esac
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

# --- G30-G32: a truncated resolution must not read as a completed one ---------
# Both budget bounds used to `return resolved`, the partially-resolved prefix. A
# spelling that starts OUTSIDE the store, spends the component budget on `a/..`
# pairs, then climbs into the store was answered `target-outside-plugin-data` and
# ALLOWED — measured, with no symlink and no Bash involved, which is why the two
# G30 rows differ ONLY in how many pairs they carry. The padded rows build their
# target through node so the repetition count is explicit rather than a here-doc.
pad_target() { # $1 pair count -> a spelling that starts at /tmp and lands in $STORE
  PAD_N="$1" PAD_STORE="$STORE" node -e '
    const path = require("path");
    const store = process.env.PAD_STORE;
    const climb = "../".repeat(store.split("/").filter(Boolean).length + 1);
    process.stdout.write("/tmp/" + "a/../".repeat(Number(process.env.PAD_N))
      + climb + store.replace(/^\//, "") + "/x.json");
  '
}

[ "$(verdict "$GUARD" Write file_path "$(pad_target 3)" "$SID" "$PROJ")" = "DENY" ] \
  && check "G30-control a short padded spelling that lands in the store is denied" PASS \
  || check "G30-control a short padded spelling that lands in the store is denied" FAIL

[ "$(verdict "$GUARD" Write file_path "$(pad_target 2100)" "$SID" "$PROJ")" = "DENY" ] \
  && check "G30 the same spelling past MAX_COMPONENTS is denied, not allowed" PASS \
  || check "G30 the same spelling past MAX_COMPONENTS is denied, not allowed" FAIL

# The refusal must NOT borrow the ordinary deny sentence: that one asserts the
# target is inside the store, which is exactly what a truncated walk could not
# establish. The channel is stdout, not stderr — a truncated walk now denies, and
# a deny carries its reason in the response rather than in an operator note.
case "$(raw_stdout "$GUARD" Write file_path "$(pad_target 2100)" "$SID" "$PROJ")" in
  *"target-resolution-truncated"*)
    check "G31 the truncation refusal names its own cause, not the containment one" PASS ;;
  *) check "G31 the truncation refusal names its own cause, not the containment one" FAIL ;;
esac

# --- G35: a store that CONTAINS the workspace carves out the project ----------
# Only a store that IS a filesystem root was refused. A CLAUDE_PLUGIN_DATA one
# step below that — an ancestor of the project — armed the gate over the whole
# tree and denied every write, and this gate ships with no config flag and no
# env escape, so the session could not edit the file that would fix it. The
# carve-out is SCOPED: an in-project write goes through, everything else in the
# store still denies.
G35="$(CLAUDE_PLUGIN_DATA="$(dirname "$PROJ")" verdict "$GUARD" Write file_path "$PROJ/src/ordinary.ts" "$SID" "$PROJ")"
[ "$G35" = "ALLOW" ] \
  && check "G35 a store containing the workspace still allows an in-project write" PASS \
  || check "G35 a store containing the workspace still allows an in-project write (got '$G35')" FAIL

# The carve-out must NOT borrow the disclosed no-store note. The gate is armed
# and working here, and printing "did not run" on every ordinary write is how an
# operator learns to ignore the channel that also carries the real faults.
G35D="$(CLAUDE_PLUGIN_DATA="$(dirname "$PROJ")" raw_stderr "$GUARD" Write file_path "$PROJ/src/ordinary.ts" "$SID" "$PROJ")"
case "$G35D" in
  *"did not run"*)
    check "G35-disclose the carve-out does not claim the guard did not run" FAIL ;;
  *) check "G35-disclose the carve-out does not claim the guard did not run" PASS ;;
esac
# The POSITIVE half. This was the only weakened-boundary state with no signal at
# all: the strictly safer one — the valve could not be evaluated, so everything in
# the store denies — printed a line, while the permissive one was byte-identical
# to a clean allow. Asserting only the absence of the wrong sentence would pass on
# empty stderr.
case "$G35D" in
  *"carved out the project"*)
    check "G35-disclose-note the carve-out announces itself" PASS ;;
  *) check "G35-disclose-note the carve-out announces itself (got '$G35D')" FAIL ;;
esac
# ...and the control: an ordinary write with a correctly configured store must not
# carry it, or the row above would pass for a note that fires on every call.
case "$(raw_stderr "$GUARD" Write file_path "$PROJ/src/ordinary.ts" "$SID" "$PROJ")" in
  *"carved out the project"*)
    check "G35-disclose-control the note is absent with a correct store" FAIL ;;
  *) check "G35-disclose-control the note is absent with a correct store" PASS ;;
esac

# ...and the other half of the carve-out, which is the whole point of scoping it:
# a target inside the store but OUTSIDE the project is still denied.
G35S="$(CLAUDE_PLUGIN_DATA="$(dirname "$PROJ")" verdict "$GUARD" Write file_path "$(dirname "$PROJ")/session-control/v1/record.json" "$SID" "$PROJ")"
[ "$G35S" = "DENY" ] \
  && check "G35-scope a store target outside the project is still denied" PASS \
  || check "G35-scope a store target outside the project is still denied (got '$G35S')" FAIL

# --- G45: the over-arm valve announces when it could not be evaluated ---------
# Every other disclosed fault here has a behavioural row; this one had none, so
# deleting the host's stderr write left the suite green. The valve is skipped
# whenever the project root cannot be resolved, and that is exactly the state in
# which a containing store denies every write with no way out.
# ONE invocation, both halves. Capturing the note from a run whose stdout was
# discarded left the DENY unpinned, so a change that kept the note while disarming
# the gate would have passed. Same lesson G26 records for its own pair.
G45_OUT="$(mktemp "${TMPDIR:-/tmp}/zensu-pdg-g45.XXXXXX")"
TMP_ROOTS="$TMP_ROOTS$G45_OUT
"
G45_ERR="$(payload Write file_path "$STORE/planted.json" "$SID" "$PROJ" 2>/dev/null | env -u CLAUDE_PROJECT_DIR bash "$GUARD" 2>&1 >"$G45_OUT")"
case "$G45_ERR" in
  *"armed without a project root"*)
    check "G45 an armed decision without a project root says the valve was unchecked" PASS ;;
  *) check "G45 an armed decision without a project root says the valve was unchecked" FAIL ;;
esac
case "$(cat "$G45_OUT")" in
  *'"permissionDecision":"deny"'*)
    check "G45-deny and the same run still denies the store target" PASS ;;
  *) check "G45-deny and the same run still denies the store target" FAIL ;;
esac
# The control: with a project root the line must NOT appear, or the row above
# would pass for a note that fires on every call.
case "$(raw_stderr "$GUARD" Write file_path "$STORE/planted.json" "$SID" "$PROJ")" in
  *"armed without a project root"*)
    check "G45-control the note is absent when the valve could be evaluated" FAIL ;;
  *) check "G45-control the note is absent when the valve could be evaluated" PASS ;;
esac

[ "$(verdict "$GUARD" Write file_path "$STORE/still-denied.json" "$SID" "$PROJ")" = "DENY" ] \
  && check "G35-control a correctly configured store still denies" PASS \
  || check "G35-control a correctly configured store still denies" FAIL

# --- G36: the payload read is bounded ----------------------------------------
# The module accumulated stdin without a cap on the hottest matcher in the
# plugin, to read four fields — a Write carries its whole `content`. The sibling
# decision module on an overlapping matcher declares a 1 MiB ceiling. An over-cap
# payload must still ALLOW (the fault direction is unchanged) and must DISCLOSE,
# so the size of a payload never decides silently whether the gate judged at all.
BIG="$(BIG_STORE="$STORE" BIG_SID="$SID" BIG_PROJ="$PROJ" node -e '
  const big = "x".repeat(1024 * 1024 + 4096);
  process.stdout.write(JSON.stringify({
    hook_event_name: "PreToolUse", tool_name: "Write",
    tool_input: { file_path: process.env.BIG_STORE + "/planted.json", content: big },
    session_id: process.env.BIG_SID, cwd: process.env.BIG_PROJ,
  }));
')"
G36="$(printf '%s' "$BIG" | bash "$GUARD" 2>/dev/null | node -e '
  let s=""; process.stdin.on("data",c=>s+=c).on("end",()=>{
    s=s.trim(); if(!s){console.log("ALLOW");return;}
    try{const h=(JSON.parse(s).hookSpecificOutput)||{};
      console.log(h.permissionDecision==="deny"?"DENY":"ALLOW");}catch(_){console.log("UNPARSED");}});')"
[ "$G36" = "DENY" ] \
  && check "G36 a payload larger than 1 MiB targeting the store is still denied" PASS \
  || check "G36 a payload larger than 1 MiB targeting the store is still denied (got '$G36')" FAIL

# The review asked for a 1 MiB cap routing an over-cap payload to the disclosed
# UNREADABLE reason, which allows. That was REJECTED and the rejection is the
# point of this row: padding `content` past any such cap would then be a way to
# write into the store. The real defect the review found is narrower — the
# accumulation could throw and leave a stack trace instead of a typed reason —
# so the accumulation is guarded and no size decides the verdict.
# ABSOLUTE, like every other source row here, and the count is tested as a
# NUMBER. `grep -c` prints nothing and exits 2 when it cannot read the file, so
# the empty string used to fall through to the catch-all and report PASS — a row
# that reported health when it had read nothing at all.
G36N="$(grep -c 'process.stdin.on("data"' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" 2>/dev/null || true)"
case "$G36N" in
  ''|*[!0-9]*) check "G36-guard the stdin accumulation exists to be guarded (unreadable: '$G36N')" FAIL ;;
  0) check "G36-guard the stdin accumulation exists to be guarded (none found)" FAIL ;;
  *) check "G36-guard the stdin accumulation exists to be guarded ($G36N)" PASS ;;
esac

# Scoped to the DATA handler alone. A wider range reaches the `end` handler's
# pre-existing catch and the row passes without anything being guarded — which is
# exactly how it read on its first run here.
G36L="$(grep -n 'process.stdin.on("data"' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" | cut -d: -f1)"
# FAIL CLOSED on anything that is not a single line number. An empty $G36L makes
# `sed -n "p"` print the WHOLE module, and the case below then matches the
# helper's own definition — so a re-spelled needle reported PASS having read
# something else entirely. Same class as the G36-guard row above.
case "$G36L" in
  ''|*[!0-9]*) check "G36-typed the accumulation goes through a guarded helper (unreadable line number: '$G36L')" FAIL ;;
esac
G36G="$(sed -n "${G36L}p" "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" 2>/dev/null || true)"
case "$G36G" in
  *"accumulate("*)
    check "G36-typed the accumulation goes through a guarded helper, not a bare append" PASS ;;
  *) check "G36-typed the accumulation goes through a guarded helper, not a bare append (got '$G36G')" FAIL ;;
esac

# --- G37: the caller's cwd reaches the module --------------------------------
# The wrapper `cd -P`s into hooks/lib to require the module by a relative
# specifier, so before this the module's relative-target fallback anchored at
# <plugin root>/hooks/lib rather than where the tool call was issued. A payload
# that carries no `cwd` and a RELATIVE target naming a store path therefore
# resolved outside the store and was allowed, while the tool itself would have
# resolved it inside. The wrapper hands its own directory over instead.
#
# The payload is built inline rather than through payload(): that helper always
# emits a `cwd` key, and the property under test is its ABSENCE.
no_cwd_payload() { # $1 relative target
  node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PreToolUse",
      tool_name: "Write",
      tool_input: { file_path: process.argv[1], content: "x" },
      session_id: "sess-g37",
    }));
  ' "$1"
}
G37_REL="$(basename "$STORE")/session-control/v1/planted.json"
G37="$(cd "$(dirname "$STORE")" && no_cwd_payload "$G37_REL" | bash "$GUARD" 2>/dev/null \
  | node -e '
    let s = ""; process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { console.log("ALLOW"); return; }
      try { console.log((JSON.parse(s).hookSpecificOutput || {}).permissionDecision === "deny" ? "DENY" : "ALLOW"); }
      catch (_) { console.log("UNPARSED"); }
    });')"
[ "$G37" = "DENY" ] \
  && check "G37 a payload with no cwd and a relative store target is denied" PASS \
  || check "G37 a payload with no cwd and a relative store target is denied (got '$G37')" FAIL

# The discriminating control. The same relative spelling, issued from a
# directory that does NOT contain the store, must still be allowed — otherwise
# G37 would pass for a guard that denied every relative target regardless of
# where it resolves.
G37C="$(cd "$OUTSIDE" && no_cwd_payload "$G37_REL" | bash "$GUARD" 2>/dev/null \
  | node -e '
    let s = ""; process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { console.log("ALLOW"); return; }
      try { console.log((JSON.parse(s).hookSpecificOutput || {}).permissionDecision === "deny" ? "DENY" : "ALLOW"); }
      catch (_) { console.log("UNPARSED"); }
    });')"
[ "$G37C" = "ALLOW" ] \
  && check "G37-control the same relative target outside the store still allows" PASS \
  || check "G37-control the same relative target outside the store still allows (got '$G37C')" FAIL

# An explicit absolute payload cwd must keep outranking the wrapper's own
# directory: the hook does not necessarily run where the tool call was issued,
# and the caller's export is only the FALLBACK. Run from a directory that does
# not contain the store, with a payload cwd that does.
G37P="$(cd "$OUTSIDE" && node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PreToolUse",
      tool_name: "Write",
      tool_input: { file_path: process.argv[1], content: "x" },
      session_id: "sess-g37", cwd: process.argv[2],
    }));
  ' "$G37_REL" "$(dirname "$STORE")" | bash "$GUARD" 2>/dev/null \
  | node -e '
    let s = ""; process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { console.log("ALLOW"); return; }
      try { console.log((JSON.parse(s).hookSpecificOutput || {}).permissionDecision === "deny" ? "DENY" : "ALLOW"); }
      catch (_) { console.log("UNPARSED"); }
    });')"
[ "$G37P" = "DENY" ] \
  && check "G37-payload an absolute payload cwd still outranks the wrapper's fallback" PASS \
  || check "G37-payload an absolute payload cwd still outranks the wrapper's fallback (got '$G37P')" FAIL

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
  *) skipped_env "G14b-premise POSIX symlink fixture (host is not POSIX)" ;;
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
  skipped_env "G23 case-variant store prefix (case-sensitive volume, or no letters to flip)"
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
# applies to EVERY module-scope function, so a NEW one must be covered without
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
  # Terminating is still the property this row exists for. The VERDICT changed
  # deliberately: a cycle exhausts MAX_LINK_HOPS, which is a truncated walk, and
  # a truncated walk no longer reports "outside" — it refuses. Nothing legitimate
  # is lost, because the kernel answers ELOOP on that path anyway; what is gained
  # is that the bound stops being a silent allow. The old expectation was written
  # before that distinction existed.
  [ "$(verdict "$GUARD" Write file_path "$OUTSIDE/sym/loopA" "$SID" "$PROJ")" = "DENY" ] \
    && check "G18c a symlink cycle terminates and refuses rather than hanging or allowing" PASS \
    || check "G18c a symlink cycle terminates and refuses rather than hanging or allowing" FAIL
  case "$(raw_stdout "$GUARD" Write file_path "$OUTSIDE/sym/loopA" "$SID" "$PROJ")" in
    *"target-resolution-truncated"*)
      check "G18c-cause the cycle refusal names the bound, not containment" PASS ;;
    *) check "G18c-cause the cycle refusal names the bound, not containment" FAIL ;;
  esac
else
  skipped "G18c symlink cycle (host produced no real symlink)"
  skipped "G18c-cause symlink cycle reason (host produced no real symlink)"
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

# A payload carrying no path field at all.
NOPATH="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{content:"x"},session_id:process.argv[1],cwd:process.argv[2]}))' "$SID" "$PROJ")"
G11c="$(printf '%s' "$NOPATH" | bash "$GUARD" 2>/dev/null)"
G11cE="$(printf '%s' "$NOPATH" | bash "$GUARD" 2>&1 >/dev/null)"
[ -z "$G11c" ] \
  && check "G11c a payload with no path field allows" PASS \
  || check "G11c a payload with no path field allows (got '$G11c')" FAIL
# It allows, but it does NOT allow quietly. Once the tool name has matched the
# write-tool set the call carries a target by construction, so an absent path
# field is not an ordinary outcome — it is what a host that renamed or
# restructured the field looks like, and in that state the gate allows every
# write on every call. The silence this row used to assert was the one shape
# indistinguishable from a healthy allow.
case "$G11cE" in
  *"payload-carries-no-path"*)
    check "G11c-quiet a missing path field is disclosed, not silent" PASS ;;
  *) check "G11c-quiet a missing path field is disclosed, not silent (got '$G11cE')" FAIL ;;
esac

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

# The wrapper's own early exit: the module file absent.
FAKE2="$(mktemp -d "${TMPDIR:-/tmp}/zensu-pdg-fake2.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
[ -n "$FAKE2" ] && [ -d "$FAKE2" ] || { echo "FATAL: fixture"; exit 2; }
FAKE2="$(cd "$FAKE2" && pwd -P)" || { echo "FATAL: fixture"; exit 2; }
TMP_ROOTS="$TMP_ROOTS$FAKE2
"
mkdir -p "$FAKE2/hooks/lib"
cp "$GUARD" "$FAKE2/hooks/" 2>/dev/null
G11i="$(payload Write file_path "$STORE/planted.json" "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$FAKE2" bash "$FAKE2/hooks/pre-write-plugin-data-guard.sh" 2>&1)"
# It allows — the fault direction is unchanged — but it does NOT do so silently.
# The wrapper is a shell script and already writes stderr for its identity guard,
# so "the wrapper returns before node runs" only ever established that the
# MODULE's typed note cannot reach here. Silence was a choice, and it was the one
# state indistinguishable from a healthy allow: an ungated main-thread Write to
# the module disarms the gate for good, and nothing said so.
case "$G11i" in
  *"plugin-data guard did not run"*)
    check "G11i an absent guard module allows and says so" PASS ;;
  *) check "G11i an absent guard module allows and says so (got '$G11i')" FAIL ;;
esac
case "$G11i" in
  *'"permissionDecision"'*)
    check "G11i-allow the note did not turn the allow into a decision" FAIL ;;
  *) check "G11i-allow the note did not turn the allow into a decision" PASS ;;
esac

# The plugin-root RESOLUTION failure is a SECOND exit-2 branch, and the header
# enumerated only one. It printed nothing, so on this matcher a moved or
# unreadable plugin directory refused every write with an empty stderr.
#
# It is pinned at SOURCE rather than driven: triggering it needs `dirname "$0"/..`
# to fail for a script the suite just invoked by that same path, which no fixture
# can arrange without also making the invocation itself fail. The control below is
# what keeps the pin from going vacuous — it fires the same extraction at the
# identity branch, which is driven end to end by G26/G26a.
G33="$(awk '/_ZENSU_EXECUTED_PLUGIN_ROOT=/,/^fi$/' "$GUARD")"
case "$G33" in
  *"cannot resolve its own plugin root"*)
    check "G33 the plugin-root resolution failure names its cause before exit 2" PASS ;;
  *) check "G33 the plugin-root resolution failure names its cause before exit 2" FAIL ;;
esac
case "$G33" in
  *"does not match the executing plugin"*)
    check "G33-control the extraction really covers the exit-2 region" PASS ;;
  *) check "G33-control the extraction really covers the exit-2 region" FAIL ;;
esac

# The two remaining silent exits. Both are structurally undriveable from a suite
# that itself requires node and a real hooks/lib, so they are pinned at source
# with the same control discipline.
G34="$(grep -c 'plugin-data guard did not run' "$GUARD")"
[ "${G34:-0}" -ge 3 ] \
  && check "G34 all three allowing early exits carry a note ($G34 found)" PASS \
  || check "G34 all three allowing early exits carry a note (only ${G34:-0})" FAIL

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



# --- G40: both directions for every gated tool -------------------------------
# The suite had a deny row per tool and an in-project ALLOW control for only one
# of them, so a gate that denied every write from three of the four tools would
# have read as fully covered. Both directions are now asserted for each, and the
# axis is DRIVEN FROM THE EXPORTED SET rather than written out: a tool added to
# WRITE_TOOLS arrives here with no edit, and G40-count is what proves the loop
# actually ran once per member instead of silently iterating over nothing.
#
# Each payload carries EVERY member of PATH_FIELDS at once. That removes the one
# hardcoded mapping this loop would otherwise need — which tool speaks which
# field — and asserts the module's real contract, which reads the fields by name
# and not by tool.
all_fields_payload() { # $1 tool  $2 target
  node -e '
    const [tool, target, fields] = process.argv.slice(1);
    const input = { content: "x" };
    for (const f of fields.split(",")) input[f] = target;
    process.stdout.write(JSON.stringify({
      hook_event_name: "PreToolUse", tool_name: tool, tool_input: input,
      session_id: "sess-g40", cwd: process.argv[4],
    }));
  ' "$1" "$2" "$PDG_FIELDS" "$PROJ"
}
tool_verdict() { # $1 tool  $2 target -> ALLOW | DENY
  all_fields_payload "$1" "$2" | bash "$GUARD" 2>/dev/null | node -e '
    let s = ""; process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { console.log("ALLOW"); return; }
      try { console.log((JSON.parse(s).hookSpecificOutput || {}).permissionDecision === "deny" ? "DENY" : "ALLOW"); }
      catch (_) { console.log("UNPARSED"); }
    });'
}
PDG_TOOLS="$(node -e 'process.stdout.write([...require(process.argv[1]).WRITE_TOOLS].sort().join(" "))' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js")"
PDG_FIELDS="$(node -e 'process.stdout.write(require(process.argv[1]).PATH_FIELDS.join(","))' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js")"
G40_ROWS=0
for tool in $PDG_TOOLS; do
  V="$(tool_verdict "$tool" "$STORE/session-control/v1/$tool.json")"
  [ "$V" = "DENY" ] \
    && check "G40 $tool into the store is denied" PASS \
    || check "G40 $tool into the store is denied (got '$V')" FAIL
  G40_ROWS=$((G40_ROWS+1))
  V="$(tool_verdict "$tool" "$PROJ/src/$tool.ts")"
  [ "$V" = "ALLOW" ] \
    && check "G40 $tool inside the project is allowed" PASS \
    || check "G40 $tool inside the project is allowed (got '$V')" FAIL
  G40_ROWS=$((G40_ROWS+1))
done
G40_EXPECT=$(( $(printf '%s\n' "$PDG_TOOLS" | wc -w) * 2 ))
[ "$G40_ROWS" -eq "$G40_EXPECT" ] && [ "$G40_ROWS" -gt 0 ] \
  && check "G40-count the axis ran both directions for every exported tool ($G40_ROWS)" PASS \
  || check "G40-count the axis ran both directions for every exported tool (ran $G40_ROWS, expected $G40_EXPECT)" FAIL

# --- G36-wired: the payload helper is actually CALLED with the flag -----------
# `payloadFromRaw` is unit-tested as a pure function, and G36-typed only sees the
# data handler. Nothing observed the `end` handler PASSING `accumulationFailed`
# into it, so dropping that one argument restored the whole defect — empty buffer,
# `{}` parsed, NOT_A_WRITE, silent allow — with both suites green.
case "$(grep -c 'payloadFromRaw(raw, accumulationFailed)' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" 2>/dev/null || true)" in
  ''|*[!0-9]*) check "G36-wired the payload helper receives the accumulation flag (unreadable count)" FAIL ;;
  0) check "G36-wired the payload helper receives the accumulation flag" FAIL ;;
  *) check "G36-wired the payload helper receives the accumulation flag" PASS ;;
esac
# A stream fault must reach the same verdict, so the listener has to exist AND the
# verdict has to be reachable from it rather than from `end` alone.
# The BODY, not just the registration. An empty handler satisfied a bare
# "is it registered" grep while a stream fault still reached the verdict through
# `close` with the flag unset and a truncated buffer — the routing this row
# exists for, undone with every check green.
case "$(grep -c 'process.stdin.on("error", () => { accumulationFailed = true; raw = ""; finalize(); });' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" 2>/dev/null || true)" in
  ''|*[!0-9]*) check "G36-wired-error the stdin error listener routes to the verdict (unreadable count)" FAIL ;;
  0) check "G36-wired-error the stdin error listener routes to the verdict" FAIL ;;
  *) check "G36-wired-error the stdin error listener routes to the verdict" PASS ;;
esac
case "$(grep -c 'process.stdin.on("close", finalize)' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" 2>/dev/null || true)" in
  ''|*[!0-9]*) check "G36-wired-close the verdict is reachable from close, not only end (unreadable count)" FAIL ;;
  0) check "G36-wired-close the verdict is reachable from close, not only end" FAIL ;;
  *) check "G36-wired-close the verdict is reachable from close, not only end" PASS ;;
esac

# --- G46: the carve-out reason value is one literal in three files ------------
# The value reaches two operator-facing documents verbatim. Every sibling reason
# that reaches a surface is grep-pinned here; this one was not, so renaming it
# left both docs asserting a string the gate no longer emits with every check
# green. The literal is DERIVED from the module rather than spelled again.
G46_VALUE="$(node -e 'process.stdout.write(require(process.argv[1]).REASONS.SCOPED_IN_PROJECT)' "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js")"
if [ -z "$G46_VALUE" ]; then
  check "G46 the carve-out reason value is exported and non-empty" FAIL
else
  check "G46 the carve-out reason value is exported and non-empty ($G46_VALUE)" PASS
  G46_MISS=""
  for doc in "$PLUGIN_DIR/docs/gates.md" "$PLUGIN_DIR/docs/configuration.md"; do
    grep -qF "$G46_VALUE" "$doc" || G46_MISS="$G46_MISS $(basename "$doc")"
  done
  [ -z "$G46_MISS" ] \
    && check "G46-docs both operator carriers quote the exported value" PASS \
    || check "G46-docs both operator carriers quote the exported value (missing:$G46_MISS)" FAIL
fi

# --- G39: the resolver pair moves in lockstep --------------------------------
# hooks/lib/reviewer-capability-v1.js owns the same boundary for every NON-main
# principal, through canonicalCandidate() — a second resolver that nothing pins
# against this one. A divergence between them is a principal-dependent verdict on
# one boundary, not merely duplicated code, so the four elements they must share
# are asserted in BOTH files. One extracted resolver is the durable end state;
# until then this is what notices a one-sided edit.
#
# The pair's KNOWN divergences are deliberate and are NOT asserted away here:
# canonicalCandidate collapses `..` lexically before any lstat, and its fault
# contract throws into a consumer that DENIES while this walk swallows into one
# that ALLOWS. What IS asserted is that the guard still explains why it declines
# the lexical collapse — an unexplained difference is how the two drift.
lockstep() { # $1 guard module  $2 sibling module -> OK | MISSING:<element>
  node -e '
    const fs = require("fs");
    const verdict = () => {
    // SLICED to the resolver, never the whole file. Every element below occurs
    // elsewhere in reviewer-capability-v1.js — lstat and realpath in its own
    // directory validators, the while-loop in two unrelated walks — so a
    // file-scoped match was satisfied by code that is not canonicalCandidate, and
    // deleting that resolver s per-component canonicalization left this row green.
    const slice = (text, fn) => {
      const at = text.indexOf("function " + fn + "(");
      if (at < 0) return "";
      const next = text.indexOf("\nfunction ", at + 1);
      return next < 0 ? text.slice(at) : text.slice(at, next);
    };
    const [guardFile, siblingFile] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
    // Each slice is tested SEPARATELY before the concatenation. Testing the sum
    // made the guard-side refusal unreachable while `decide` existed, so a
    // renamed resolver reported a missing element instead of a missing function
    // — a true failure naming the wrong cause.
    const guardResolver = slice(guardFile, "resolveTargetPath");
    if (guardResolver === "") { return "MISSING:guard:resolveTargetPath is not a top-level function"; }
    const sibling = slice(siblingFile, "canonicalCandidate");
    if (sibling === "") { return "MISSING:sibling:canonicalCandidate is not a top-level function"; }
    const guard = guardResolver;
    // Each element is a property both resolvers depend on. A one-sided removal
    // changes what one principal may write and leaves the other alone.
    const shared = [
      ["per-component lstat", /fs\.lstatSync\(candidate\)/],
      ["symlink branch", /isSymbolicLink\(\)/],
      ["link target re-read", /fs\.readlinkSync\(candidate\)/],
      ["per-component canonicalization", /fs\.realpathSync\.native\(candidate\)/],
      ["a bounded walk", /while \(pending\.length > 0\)/],
    ];
    for (const [name, re] of shared) {
      if (!re.test(guard)) { return "MISSING:guard:" + name; }
      if (!re.test(sibling)) { return "MISSING:sibling:" + name; }
    }
    if (!/NOT path\.resolve\(\)/.test(guardFile)) { return "MISSING:guard:the lexical-collapse rationale"; }
    return "OK";
    };
    console.log(verdict());
  ' "$1" "$2"
}
G39="$(lockstep "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" "$PLUGIN_DIR/hooks/lib/reviewer-capability-v1.js")"
[ "$G39" = "OK" ] \
  && check "G39 both resolvers carry every shared element" PASS \
  || check "G39 both resolvers carry every shared element (got $G39)" FAIL

# The anti-vacuity control, and it is a real one: the same scan is run against a
# COPY of the guard with the canonicalization deleted. A pin whose pattern can
# never fail asserts nothing, and this repo has shipped that mistake before.
G39_MUT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-pdg-mut.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
[ -n "$G39_MUT" ] && [ -d "$G39_MUT" ] || { echo "FATAL: fixture"; exit 2; }
G39_MUT="$(cd "$G39_MUT" && pwd -P)" || { echo "FATAL: fixture"; exit 2; }
TMP_ROOTS="$TMP_ROOTS$G39_MUT
"
sed 's/fs\.realpathSync\.native(candidate)/fs.realpathSync.native(String(candidate))/' \
  "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" > "$G39_MUT/mutated.js"
G39C="$(lockstep "$G39_MUT/mutated.js" "$PLUGIN_DIR/hooks/lib/reviewer-capability-v1.js")"
case "$G39C" in
  MISSING:guard:*canonicalization*)
    check "G39-control the scan fails when the guard loses its canonicalization" PASS ;;
  *) check "G39-control the scan fails when the guard loses its canonicalization (got $G39C)" FAIL ;;
esac

# ...and the SIBLING side, which had no arm at all. It is the half the file-scoped
# scan could not see: every element but readlinkSync occurs elsewhere in that
# file, so only a sliced scan can notice the resolver losing one.
sed 's/current = fs\.realpathSync\.native(candidate);/current = fs.realpathSync.native(String(candidate));/' \
  "$PLUGIN_DIR/hooks/lib/reviewer-capability-v1.js" > "$G39_MUT/mutated-sibling.js"
G39CS="$(lockstep "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js" "$G39_MUT/mutated-sibling.js")"
case "$G39CS" in
  MISSING:sibling:*canonicalization*)
    check "G39-control-sibling the scan fails when the sibling loses its canonicalization" PASS ;;
  *) check "G39-control-sibling the scan fails when the sibling loses its canonicalization (got $G39CS)" FAIL ;;
esac

# FR-002 is a spec constraint, and the durable form of it is a DEPENDENCY rule
# rather than a diff check: this gate must never LOAD the sibling module. A
# `git diff` row would fail on the sibling's next legitimate change and teach
# the reader to ignore it. Naming the sibling in PROSE is deliberate and stays
# allowed — the module header's residual list points at it — so the scan is
# anchored on the require, never on the string.
case "$(grep -cE "require\(['\"]\.?[^'\"]*reviewer-capability" "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js")" in
  0) check "G39-independent the guard never loads the sibling module" PASS ;;
  *) check "G39-independent the guard never loads the sibling module" FAIL ;;
esac

# ...and the control that the scan can fail at all.
case "$(printf '%s\n' "require(\"./reviewer-capability-v1.js\")" | grep -cE "require\(['\"]\.?[^'\"]*reviewer-capability")" in
  0) check "G39-independent-control the require scan can match" FAIL ;;
  *) check "G39-independent-control the require scan can match" PASS ;;
esac


# --- G43: both registrations carry an explicit timeout -----------------------
# This gate can DENY, so a hang is not a slow hook — it is a stalled tool call on
# the two matchers every file edit travels through. The value matches the sibling
# gates that also deny (pre-bash-source-write-gate.sh,
# pre-reviewer-capability-gate.sh) rather than the advisory hooks that carry none.
# BOTH registrations are asserted, because the second matcher was added later and
# a per-file check would not have seen it.
G43="$(node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const found = [];
  for (const g of j.hooks.PreToolUse || []) {
    for (const h of g.hooks || []) {
      if (h.command.includes("pre-write-plugin-data-guard.sh")) {
        found.push(g.matcher + "=" + (typeof h.timeout === "number" ? h.timeout : "none"));
      }
    }
  }
  console.log(found.length === 0 ? "NONE" : found.sort().join(" "));
' "$PLUGIN_DIR/hooks/hooks.json")"
case "$G43" in
  *none*|NONE) check "G43 both registrations carry an explicit timeout (got $G43)" FAIL ;;
  *) check "G43 both registrations carry an explicit timeout ($G43)" PASS ;;
esac

# --- G44: the caller-cwd transport is one name in two files ------------------
# The wrapper exports it, the module's CLI entry point reads it, and nothing
# else in the tree mentions it. Renaming either side silently re-anchors every
# relative target in the plugin tree and fails only for relative spellings, so
# the ordinary rows stay green. This is the pin that catches it. A third carrier
# now names the variable too — the `pre-write-plugin-data-guard.sh` row in
# docs/configuration.md — so it is no longer a two-site name, but only this row
# fails on a one-sided rename.
G44="$(node -e '
  const fs = require("fs");
  const [wrapper, mod] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
  const name = (wrapper.match(/export ([A-Z_]*CALLER_CWD)/) || [])[1];
  if (!name) { console.log("NO-EXPORT"); }
  else if (!new RegExp("process\\.env\\." + name).test(mod)) { console.log("NOT-READ:" + name); }
  else { console.log("OK:" + name); }
' "$PLUGIN_DIR/hooks/pre-write-plugin-data-guard.sh" "$PLUGIN_DIR/hooks/lib/plugin-data-guard-v1.js")"
case "$G44" in
  OK:*) check "G44 the wrapper exports the caller-cwd name the module reads (${G44#OK:})" PASS ;;
  *) check "G44 the wrapper exports the caller-cwd name the module reads (got $G44)" FAIL ;;
esac

# TWO FLOORS, and the split is the point. `exit 0` also accepts a file that
# registered no checks at all — an early `continue`, a deleted block or a
# skipped fixture would otherwise leave this suite green while measuring less
# than it claims. BOTH floors sit at the MEASURED counts, not below them, so a
# deleted row fails the floor it exists to protect; raise them with every added
# row. Note the three rows below are registered AFTER this count is taken.
#
# The REGISTERED floor counts skips, so it survives a host without real
# symlinks. On its own it is defeated by exactly the failure it exists to
# catch: a fixture that stopped working would skip every symlink row and still
# clear it. The EXECUTED floor is therefore asserted separately, over rows that
# actually ran, and it tolerates only the known-skippable set.
# TWELVE skip sites across THREE premises, not nine behind one: ten rows need a
# real symlink (G15/G16/G17-control, G18/G18a-control/G18b-control, G24, G27,
# G18c/G18c-cause), G14b-premise needs a POSIX host, and G23 needs a
# case-INSENSITIVE volume. The executed floor tolerates all twelve, because a
# host can legitimately lack every premise at once.
MAX_SKIPPABLE=12
EXPECTED_CHECKS=114
EXECUTED_FLOOR=$((EXPECTED_CHECKS - MAX_SKIPPABLE))
EXECUTED=$((PASS + FAIL))
TOTAL=$((PASS + FAIL + SKIPPED))
[ "$TOTAL" -ge "$EXPECTED_CHECKS" ] \
  && check "G22 the suite registered at least $EXPECTED_CHECKS rows ($TOTAL incl. $SKIPPED skipped)" PASS \
  || check "G22 the suite registered at least $EXPECTED_CHECKS rows (only $TOTAL incl. $SKIPPED skipped)" FAIL
[ "$EXECUTED" -ge "$EXECUTED_FLOOR" ] \
  && check "G41 at least $EXECUTED_FLOOR rows actually executed ($EXECUTED)" PASS \
  || check "G41 at least $EXECUTED_FLOOR rows actually executed (only $EXECUTED)" FAIL

# A skipped row must cost the suite when it means coverage was LOST — a fixture
# that stopped producing symlinks degrades silently to green otherwise. It must
# NOT cost the suite when the premise is a fact about the host: G23 needs a
# case-insensitive volume and simply cannot run on ext4, so counting it here made
# the suite red on Linux CI for a reason unrelated to the code. The measured
# quantity is therefore SKIPPED minus SKIPPED_ENV, on every host — the Windows
# carve-out remains, because there `ln -s` can be satisfied by a copy that native
# Node does not follow, which is a host fact the symlink rows cannot detect
# per-row.
LOST_COVERAGE=$((SKIPPED - SKIPPED_ENV))
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    check "G42 skipped rows are tolerated on this Windows host ($SKIPPED, $SKIPPED_ENV environmental)" PASS ;;
  *)
    [ "$LOST_COVERAGE" -eq 0 ] \
      && check "G42 no row lost coverage on this POSIX host ($SKIPPED skipped, all $SKIPPED_ENV environmental)" PASS \
      || check "G42 $LOST_COVERAGE row(s) lost coverage on this POSIX host ($SKIPPED skipped, $SKIPPED_ENV environmental)" FAIL ;;
esac

echo "----"
echo "test-plugin-data-guard: $PASS PASS / $FAIL FAIL / $SKIPPED SKIP"
[ "$FAIL" -eq 0 ]
