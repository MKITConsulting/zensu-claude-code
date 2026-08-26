#!/bin/bash
set -u

# Pins the PreToolUse(Agent|Task) reviewer-spawn grant (pre-agent-reviewer-allow.sh):
# it admits Zensu's own capability-confined reviewer subagents before the host
# permission layer is consulted, stays silent on every other path, and NEVER denies.
# Also pins the disclosure surfaces — the SessionStart banner line and the
# /zensu:doctor rows — because a grant the plugin hands itself must be visible.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-agent-reviewer-allow.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
MODULE="$PLUGIN_DIR/hooks/lib/reviewer-spawn-allow-v1.js"
UNIT="$PLUGIN_DIR/tests/structure/reviewer-spawn-allow-v1.test.js"
REPORT="$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js"
BANNER="$PLUGIN_DIR/hooks/session-start-banner.sh"

SBOX="$(mktemp -d -t revallow-XXXXXX)"
export CLAUDE_PLUGIN_DATA="$SBOX/plugin-data"
mkdir -p "$CLAUDE_PLUGIN_DATA"
PROJECT="$SBOX/project"
mkdir -p "$PROJECT"
NO_CONFIG="$SBOX/.no-such-config.json"
trap 'rm -rf "$SBOX"' EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ] || [ ! -f "$MODULE" ]; then
  check "A0 hook and decision module exist" FAIL
  echo "----"
  echo "test-reviewer-spawn-allow: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "A1 hook exists and is executable" PASS || check "A1 hook exists and is executable" FAIL
bash -n "$HOOK" 2>/dev/null && check "A2 bash -n syntax check passes" PASS || check "A2 bash -n syntax check passes" FAIL

# ── A3 registration, matcher included ────────────────────────────────
if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const hit=(h.hooks.PreToolUse||[]).find(e=>(e.hooks||[])
    .some(z=>/pre-agent-reviewer-allow\.sh/.test(z.command||"")));
  if(!hit) process.exit(1);
  process.exit(hit.matcher==="Agent|Task"?0:2);
' "$HOOKS_JSON" 2>/dev/null; then
  check "A3 registered in hooks.json PreToolUse on matcher Agent|Task" PASS
else
  check "A3 registered in hooks.json PreToolUse on matcher Agent|Task" FAIL
fi

# ── A4 the unit driver runs here, with a case-count floor ────────────
# tests/run-all.sh discovers only test-*.sh, so a *.test.js with no driver is
# never executed by the tree runner. Exit 0 also accepts a file registering zero
# cases, which is why the floor is asserted rather than the exit status alone.
UNIT_OUT="$(node --test "$UNIT" 2>&1)"
UNIT_RC=$?
UNIT_COUNT="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^# *pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
[ -z "$UNIT_COUNT" ] && UNIT_COUNT="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^.*pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
# The floor is DERIVED from the file, not a literal: a hardcoded number drifts below the
# real count and then silently tolerates deleted cases.
# `test.skip(`/`test.todo(` count too: without them a disabled case lowers BOTH sides
# together and the equality still holds over a case that no longer runs.
UNIT_EXPECTED="$(grep -cE "^test(\.(skip|todo))?\(" "$UNIT" 2>/dev/null || echo 0)"
UNIT_TOTAL="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^# *tests \([0-9][0-9]*\)$/\1/p' | tail -1)"
[ -z "$UNIT_TOTAL" ] && UNIT_TOTAL="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^.*tests \([0-9][0-9]*\)$/\1/p' | tail -1)"
if [ "$UNIT_RC" -eq 0 ] && [ -n "$UNIT_COUNT" ] && [ "$UNIT_EXPECTED" -gt 0 ] \
  && [ "$UNIT_COUNT" -eq "$UNIT_EXPECTED" ] && [ "${UNIT_TOTAL:-0}" -eq "$UNIT_COUNT" ]; then
  check "A4 reviewer-spawn-allow-v1.test.js green with all $UNIT_EXPECTED registered cases" PASS
else
  check "A4 reviewer-spawn-allow-v1.test.js green with all registered cases (rc=$UNIT_RC ran=${UNIT_COUNT:-none} registered=$UNIT_EXPECTED)" FAIL
fi

# ── Behavioral helpers ───────────────────────────────────────────────
SESSION_ID="revallow-session-$$"

register_session() {
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"SessionStart", source:"startup",
    session_id:process.argv[1], cwd:process.argv[2]
  }))' "$SESSION_ID" "$PROJECT" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null 2>&1
}

# $1 subagent_type  $2 tool_name  $3 session_id  $4 config file  $5 optional agent_type
run_hook() {
  local sub="$1" tool="$2" sid="$3" cfg="$4" agent="${5:-}"
  node -e '
    const [sub, tool, sid, cwd, agent] = process.argv.slice(1);
    const p = { hook_event_name:"PreToolUse", session_id:sid, cwd:cwd,
      tool_name:tool, tool_input:{ subagent_type:sub, prompt:"review" } };
    if (agent) { p.agent_type = agent; p.agent_id = "agent-1"; }
    process.stdout.write(JSON.stringify(p));
  ' "$sub" "$tool" "$sid" "$PROJECT" "$agent" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$cfg" \
      bash "$HOOK" 2>/dev/null
}

granted() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c); process.stdin.on("end",()=>{
      try {
        const j=JSON.parse(s);
        const o=j.hookSpecificOutput||{};
        process.exit(o.hookEventName==="PreToolUse" && o.permissionDecision==="allow" ? 0 : 1);
      } catch(_) { process.exit(1); }
    });
  ' 2>/dev/null
}

if register_session; then
  check "A5pre a Session Control record was registered for the fixture session" PASS
else
  check "A5pre a Session Control record was registered for the fixture session" FAIL
fi

AGENTS="$(node -e 'process.stdout.write(require(process.argv[1]).CONFINED_REVIEWER_AGENTS.join(" "))' "$MODULE" 2>/dev/null)"
if [ -n "$AGENTS" ]; then
  check "A5pre2 the confined agent list was resolved from the module" PASS
else
  check "A5pre2 the confined agent list was resolved from the module" FAIL
fi

# ── A5/A6 the grant itself ───────────────────────────────────────────
# Cardinality first: an empty derivation would leave GRANT_OK at 1 and print PASS having
# asserted nothing, which is the vacuous-row shape this repo rejects elsewhere.
AGENT_COUNT="$(printf '%s\n' $AGENTS | grep -c . || echo 0)"
if [ "$AGENT_COUNT" -eq 5 ]; then
  check "A5pre3 the derivation yields the five plugin-scoped reviewers" PASS
else
  check "A5pre3 the derivation yields the five plugin-scoped reviewers (got $AGENT_COUNT)" FAIL
fi
GRANT_OK=1
[ "$AGENT_COUNT" -gt 0 ] || GRANT_OK=0
for agent in $AGENTS; do
  for tool in Agent Task; do
    if ! printf '%s' "$(run_hook "$agent" "$tool" "$SESSION_ID" "$NO_CONFIG")" | granted; then
      GRANT_OK=0
      echo "        (no grant for $agent via $tool)"
    fi
  done
done
[ "$GRANT_OK" -eq 1 ] && check "A5 every confined reviewer is granted through Agent and Task" PASS \
  || check "A5 every confined reviewer is granted through Agent and Task" FAIL

GRANT_BODY="$(run_hook "zensu:code-reviewer" Agent "$SESSION_ID" "$NO_CONFIG")"
case "$GRANT_BODY" in
  *'"deny"'*|*'"ask"'*) check "A6 the emitted decision never carries deny or ask" FAIL ;;
  *) check "A6 the emitted decision never carries deny or ask" PASS ;;
esac
case "$GRANT_BODY" in
  *'hooks.reviewerSpawnAutoAllow'*) check "A7 the decision reason names the off-switch" PASS ;;
  *) check "A7 the decision reason names the off-switch" FAIL ;;
esac

# ── A8-A11 silence ───────────────────────────────────────────────────
# Asserts the STATUS as well as the silence. Empty output alone cannot tell a silent
# decline from the fail-closed `exit 2` every other gate in this tree uses — and a
# non-zero exit from a PreToolUse hook BLOCKS the spawn, which is the one outcome this
# hook must never produce. Without the status arm, changing either early exit to `exit 2`
# left these rows green while every Agent spawn in the session would have been blocked.
silent() {
  local label="$1"; shift
  local out rc
  out="$(run_hook "$@")"; rc=$?
  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then check "$label" PASS; else check "$label" FAIL; fi
}
silent "A8 an unconfined subagent type is silent" "general-purpose" Agent "$SESSION_ID" "$NO_CONFIG"
silent "A9 the PLM agent is silent" "zensu:zensu-plm" Agent "$SESSION_ID" "$NO_CONFIG"
silent "A10 a bare reviewer name is silent, only plugin-scoped names are granted" "code-reviewer" Agent "$SESSION_ID" "$NO_CONFIG"
silent "A11 a tool outside Agent|Task is silent" "zensu:code-reviewer" Bash "$SESSION_ID" "$NO_CONFIG"
silent "A12 an unregistered session is silent, never granted" "zensu:code-reviewer" Agent "no-such-session-$$" "$NO_CONFIG"
silent "A13 a subagent principal never earns a grant" "zensu:code-reviewer" Agent "$SESSION_ID" "$NO_CONFIG" "zensu:review-aspect"

# ── A14/A15 the off-switch ───────────────────────────────────────────
printf '{"hooks":{"reviewerSpawnAutoAllow":false}}\n' > "$SBOX/off.json"
printf '{"hooks":{"reviewerSpawnAutoAllow":"false"}}\n' > "$SBOX/quoted.json"
silent "A14 hooks.reviewerSpawnAutoAllow=false disables the grant" "zensu:code-reviewer" Agent "$SESSION_ID" "$SBOX/off.json"
if printf '%s' "$(run_hook "zensu:code-reviewer" Agent "$SESSION_ID" "$SBOX/quoted.json")" | granted; then
  check "A15 a quoted \"false\" does not disable the grant" PASS
else
  check "A15 a quoted \"false\" does not disable the grant" FAIL
fi

# ── A16 the hook never exits non-zero ────────────────────────────────
EXIT_OK=1
for sub in "zensu:code-reviewer" "general-purpose" ""; do
  run_hook "$sub" Agent "$SESSION_ID" "$NO_CONFIG" >/dev/null 2>&1 || EXIT_OK=0
done
run_hook "zensu:code-reviewer" Agent "no-such-session-$$" "$NO_CONFIG" >/dev/null 2>&1 || EXIT_OK=0
[ "$EXIT_OK" -eq 1 ] && check "A16 the hook always exits 0 — a non-zero exit would block the spawn" PASS \
  || check "A16 the hook always exits 0 — a non-zero exit would block the spawn" FAIL

# ── A17-A20 disclosure: /zensu:doctor ────────────────────────────────
DOC_HOME="$SBOX/home"
mkdir -p "$DOC_HOME/.claude"
doctor() {
  ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" ZENSU_CONFIG="$1" CLAUDE_PROJECT_DIR="$PROJECT" \
  HOME="$DOC_HOME" node "$REPORT" 2>/dev/null
}
DOC_ON="$(doctor "$NO_CONFIG")"
# The needle reaches INTO the rendered agent list: stopping at the sentence would leave a
# truncated or empty list rendering a wrong row with this check still green.
case "$DOC_ON" in
  *"admits its own read-only reviewer spawns (zensu:code-reviewer,"*"zensu:review-judge"*)
    check "A17 doctor discloses the active grant and names the agents it covers" PASS ;;
  *) check "A17 doctor discloses the active grant and names the agents it covers" FAIL ;;
esac
case "$DOC_ON" in
  *"the session must bind to a valid Session Control record"*)
    check "A17a the row states the per-call conditions this check cannot see" PASS ;;
  *) check "A17a the row states the per-call conditions this check cannot see" FAIL ;;
esac
case "$DOC_ON" in
  *"pre-agent-reviewer-allow.sh"*) check "A18 the doctor row names the hook that grants" PASS ;;
  *) check "A18 the doctor row names the hook that grants" FAIL ;;
esac
DOC_OFF="$(doctor "$SBOX/off.json")"
case "$DOC_OFF" in
  *"reviewer-spawn grant is switched off"*) check "A19 doctor reports a disabled grant instead of falling silent" PASS ;;
  *) check "A19 doctor reports a disabled grant instead of falling silent" FAIL ;;
esac
case "$DOC_OFF" in
  *"admits its own read-only reviewer spawns"*) check "A19a the active row is suppressed while the grant is off" FAIL ;;
  *) check "A19a the active row is suppressed while the grant is off" PASS ;;
esac

# A20 with permission mode auto and no allow rule, the advice must change:
# the grant already covers the spawn the old row told the user to add a rule for.
printf '{"permissions":{"defaultMode":"auto"}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_AUTO_ON="$(doctor "$NO_CONFIG")"
DOC_AUTO_OFF="$(doctor "$SBOX/off.json")"
case "$DOC_AUTO_ON" in
  *"no settings edit is needed for them"*) check "A20 auto mode plus an active grant reports no settings edit is needed" PASS ;;
  *) check "A20 auto mode plus an active grant reports no settings edit is needed" FAIL ;;
esac
case "$DOC_AUTO_ON" in
  *'Add "Agent(zensu:code-reviewer)" to permissions.allow'*)
    check "A20a the settings-edit advice is withdrawn while the grant is active" FAIL ;;
  *) check "A20a the settings-edit advice is withdrawn while the grant is active" PASS ;;
esac
case "$DOC_AUTO_OFF" in
  *'Add "Agent(zensu:code-reviewer)" to permissions.allow'*)
    check "A20b the settings-edit advice returns when the grant is off" PASS ;;
  *) check "A20b the settings-edit advice returns when the grant is off" FAIL ;;
esac
# The grant does NOT survive a deny rule, so the caveat has to travel with the granted
# row too. Anchored on the caveat's own opening clause rather than the bare word "deny",
# which the surrounding rows also contain.
case "$DOC_AUTO_ON" in
  *"Remove any deny rule that names the Agent tool first"*)
    check "A20c the granted row keeps the deny-first caveat" PASS ;;
  *) check "A20c the granted row keeps the deny-first caveat" FAIL ;;
esac

# ── A21/A22 disclosure: the SessionStart banner ──────────────────────
banner() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"startup",session_id:process.argv[1],cwd:process.argv[2]}))' \
    "$SESSION_ID" "$PROJECT" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$1" bash "$BANNER" 2>/dev/null
}
BANNER_ON="$(banner "$NO_CONFIG")"
case "$BANNER_ON" in
  *"Reviewer spawns"*"hooks.reviewerSpawnAutoAllow=false"*)
    check "A21 the banner discloses the grant and names the off-switch" PASS ;;
  *) check "A21 the banner discloses the grant and names the off-switch" FAIL ;;
esac
BANNER_OFF="$(banner "$SBOX/off.json")"
# ANCHORED absence: the banner has several earlier `exit 0` paths, so empty output is also
# what a banner that never rendered looks like. Prove it rendered before proving the line is
# gone.
case "$BANNER_OFF" in
  *"Zensu PLM v"*) check "A22pre the banner rendered in the off case (absence anchor)" PASS ;;
  *) check "A22pre the banner rendered in the off case (absence anchor)" FAIL ;;
esac
case "$BANNER_OFF" in
  *"Reviewer spawns"*) check "A22 the banner line is absent once the grant is off" FAIL ;;
  *) check "A22 the banner line is absent once the grant is off" PASS ;;
esac

# ── A23 the flag is carried by config.example.json, like every sibling flag ───
if node -e '
  const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(c.hooks && c.hooks.reviewerSpawnAutoAllow === true ? 0 : 1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "A23 config.example.json carries hooks.reviewerSpawnAutoAllow" PASS
else
  check "A23 config.example.json carries hooks.reviewerSpawnAutoAllow" FAIL
fi

# ── A24 every rendered permissions row is documented in the doctor skill ─────
# P1be is the drift pin two documents name as holding the doctor rows and
# skills/doctor/SKILL.md in step, but its corpus is built from fixtures that never reach a
# grant state, so all four rows added here are invisible to it. Pin them where they render.
SKILL_MD="$PLUGIN_DIR/skills/doctor/SKILL.md"
A24_MISS=""
for phrase in \
  "admits its own read-only reviewer spawns" \
  "no settings edit is needed for them" \
  "the reviewer-spawn grant is switched off" \
  "could not be loaded" \
  "does not register it on a PreToolUse matcher covering the spawn tools" \
  "could not be read or parsed"; do
  grep -qF -- "$phrase" "$SKILL_MD" || A24_MISS="$A24_MISS [$phrase]"
done
[ -z "$A24_MISS" ] && check "A24 all four grant rows are documented in skills/doctor/SKILL.md" PASS \
  || check "A24 grant rows missing from skills/doctor/SKILL.md:$A24_MISS" FAIL

# ── A25/A26 the two broken-installation doctor states ────────────────────────
# Both are unreachable from the live plugin root, so they need throwaway roots. Without
# these the "installed but unloadable" and "not installed" branches are pinned nowhere.
mk_root() { # $1 dest  $2 include module  $3 include hook
  local d="$1"
  mkdir -p "$d/.claude-plugin" "$d/hooks/lib"
  cp "$PLUGIN_DIR/.claude-plugin/plugin.json" "$d/.claude-plugin/" 2>/dev/null
  cp "$PLUGIN_DIR/.claude-plugin/marketplace.json" "$d/.claude-plugin/" 2>/dev/null
  cp "$PLUGIN_DIR/hooks/hooks.json" "$d/hooks/" 2>/dev/null
  [ "$3" = "hook" ] && cp "$PLUGIN_DIR/hooks/pre-agent-reviewer-allow.sh" "$d/hooks/"
  [ "$2" = "module" ] && cp "$PLUGIN_DIR/hooks/lib/reviewer-spawn-allow-v1.js" "$d/hooks/lib/"
  return 0
}
doctor_at() {
  ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$1" ZENSU_CONFIG="$NO_CONFIG" CLAUDE_PROJECT_DIR="$PROJECT" \
  HOME="$DOC_HOME" node "$REPORT" 2>/dev/null
}
mk_root "$SBOX/root-nomodule" nomodule hook
DOC_NOMOD="$(doctor_at "$SBOX/root-nomodule")"
case "$DOC_NOMOD" in
  *"could not be loaded"*"broken installation, not a configuration choice"*)
    check "A25 an installed hook without its decision module reports a broken installation" PASS ;;
  *) check "A25 an installed hook without its decision module reports a broken installation" FAIL ;;
esac
case "$DOC_NOMOD" in
  *"admits its own read-only reviewer spawns"*)
    check "A25a the active grant row is suppressed on a broken installation" FAIL ;;
  *) check "A25a the active grant row is suppressed on a broken installation" PASS ;;
esac
mk_root "$SBOX/root-nohook" module nohook
DOC_NOHOOK="$(doctor_at "$SBOX/root-nohook")"
case "$DOC_NOHOOK" in
  *"permissions:"*) check "A26pre the report reached its permissions block (absence anchor)" PASS ;;
  *) check "A26pre the report reached its permissions block (absence anchor)" FAIL ;;
esac
case "$DOC_NOHOOK" in
  *"reviewer-spawn grant"*|*"admits its own read-only reviewer spawns"*)
    check "A26 a root predating the feature renders no grant row at all" FAIL ;;
  *) check "A26 a root predating the feature renders no grant row at all" PASS ;;
esac

# ── A27 a deny rule still warns while the grant is active ────────────────────
# AC-009's second half. Every deny/ask fixture in test-doctor.sh runs against a sandbox root
# where the grant is inactive, so this pairing existed nowhere.
printf '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer)"]}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_DENY="$(doctor "$NO_CONFIG")"
case "$DOC_DENY" in
  *"a permissions.deny entry in ~/.claude/settings.json matches the"*)
    check "A27 a deny rule still warns while the grant is active" PASS ;;
  *) check "A27 a deny rule still warns while the grant is active" FAIL ;;
esac
case "$DOC_DENY" in
  *"no settings edit is needed for them"*)
    check "A27a the granted row does not fire while a deny rule stands" FAIL ;;
  *) check "A27a the granted row does not fire while a deny rule stands" PASS ;;
esac
printf '{"permissions":{"defaultMode":"auto","ask":["Agent(zensu:code-reviewer)"]}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_ASK="$(doctor "$NO_CONFIG")"
case "$DOC_ASK" in
  *"a permissions.ask entry in ~/.claude/settings.json matches the"*)
    check "A28 an ask rule still warns while the grant is active" PASS ;;
  *) check "A28 an ask rule still warns while the grant is active" FAIL ;;
esac

# ── A29 the grant survives every hook registered on the Agent matcher ────────
# The host resolves deny > ask > allow across ALL hooks on a matcher, so exercising this
# hook alone proves nothing about the real pipeline. Drive every PreToolUse hook whose
# matcher matches `Agent` and require that none of them denies or asks.
A29_BAD=""
A29_HOOKS="$(node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const out=[];
  for (const g of (h.hooks.PreToolUse||[])) {
    if (!new RegExp(g.matcher || ".*").test("Agent")) continue;
    for (const e of (g.hooks||[])) {
      const m=/hooks\/([A-Za-z0-9._-]+\.sh)/.exec(e.command||"");
      if (m) out.push(m[1]);
    }
  }
  process.stdout.write([...new Set(out)].join(" "));
' "$HOOKS_JSON" 2>/dev/null)"
for hk in $A29_HOOKS; do
  [ "$hk" = "pre-agent-reviewer-allow.sh" ] && continue
  HK_OUT="$(node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.argv[1],
      cwd:process.argv[2],tool_name:"Agent",
      tool_input:{subagent_type:"zensu:code-reviewer",prompt:"review"}}));
  ' "$SESSION_ID" "$PROJECT" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$NO_CONFIG" \
      bash "$PLUGIN_DIR/hooks/$hk" 2>/dev/null)"
  case "$HK_OUT" in
    *'"deny"'*|*'"ask"'*) A29_BAD="$A29_BAD [$hk]" ;;
  esac
done
if [ -z "$A29_HOOKS" ]; then
  check "A29 no sibling hook on the Agent matcher outranks the grant (no hooks resolved)" FAIL
elif [ -z "$A29_BAD" ]; then
  check "A29 no sibling hook on the Agent matcher outranks the grant" PASS
else
  check "A29 sibling hooks on the Agent matcher return deny or ask:$A29_BAD" FAIL
fi

# ── A30 the hook reads the flag through the FAIL-CLOSED helper ───────────────
# A14/A15 pass identically under either reader, so without this pair the whole FR-001
# decision could be reverted with every check green.
if grep -qF 'zensu_hook_enabled_strict reviewerSpawnAutoAllow' "$HOOK"; then
  check "A30 the hook reads the flag through zensu_hook_enabled_strict" PASS
else
  check "A30 the hook reads the flag through zensu_hook_enabled_strict" FAIL
fi
if grep -qE '(^|[^_])zensu_hook_enabled reviewerSpawnAutoAllow' "$HOOK"; then
  check "A30a the permissive reader is not used on this key" FAIL
else
  check "A30a the permissive reader is not used on this key" PASS
fi

# ── A31 a present-but-unreadable config withdraws the grant ──────────────────
# The behavioral half of FR-001. The permissive reader answers "enabled" here because rd()
# swallows the parse error and returns {}; the fail-closed one declines.
printf 'this is not json\n' > "$SBOX/broken.json"
if [ -z "$(run_hook "zensu:code-reviewer" Agent "$SESSION_ID" "$SBOX/broken.json")" ]; then
  check "A31 a present but unparseable config withdraws the grant" PASS
else
  check "A31 a present but unparseable config withdraws the grant" FAIL
fi

# ── A32 withdrawal is sticky across config sources ───────────────────────────
# A project-local .zensu/config.json must not be able to re-arm a grant the user withdrew
# globally: that file travels with a checked-out repository.
STICKY_HOME="$SBOX/sticky-home"; STICKY_PROJ="$SBOX/sticky-project"
mkdir -p "$STICKY_HOME/.zensu" "$STICKY_PROJ/.zensu"
printf '{"hooks":{"reviewerSpawnAutoAllow":false}}\n' > "$STICKY_HOME/.zensu/config.json"
printf '{"hooks":{"reviewerSpawnAutoAllow":true}}\n' > "$STICKY_PROJ/.zensu/config.json"
STICKY_OUT="$(node -e '
  process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.argv[1],
    cwd:process.argv[2],tool_name:"Agent",tool_input:{subagent_type:"zensu:code-reviewer"}}));
' "$SESSION_ID" "$PROJECT" \
  | env -u ZENSU_CONFIG CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$STICKY_PROJ" HOME="$STICKY_HOME" \
    bash "$HOOK" 2>/dev/null)"
[ -z "$STICKY_OUT" ] && check "A32 a project overlay cannot re-arm a globally withdrawn grant" PASS \
  || check "A32 a project overlay cannot re-arm a globally withdrawn grant" FAIL

# ── A33 the autoMode.allow prose row is suppressed while the grant is active ──
printf '{"permissions":{"defaultMode":"auto"},"autoMode":{"allow":["prefer zensu:code-reviewer"]}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_PROSE_ON="$(doctor "$NO_CONFIG")"
DOC_PROSE_OFF="$(doctor "$SBOX/off.json")"
case "$DOC_PROSE_ON" in
  *"permissions:"*) check "A33pre the report reached its permissions block (absence anchor)" PASS ;;
  *) check "A33pre the report reached its permissions block (absence anchor)" FAIL ;;
esac
case "$DOC_PROSE_ON" in
  *"classifier guidance in prose"*)
    check "A33 the autoMode prose row is suppressed while the grant is active" FAIL ;;
  *) check "A33 the autoMode prose row is suppressed while the grant is active" PASS ;;
esac
case "$DOC_PROSE_OFF" in
  *"classifier guidance in prose"*)
    check "A33a the autoMode prose row returns when the grant is off" PASS ;;
  *) check "A33a the autoMode prose row returns when the grant is off" FAIL ;;
esac

# ── A34 an unwired hook is a broken installation, not a grant ────────────────
mk_root "$SBOX/root-unwired" module hook
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/pre-agent-reviewer-allow.sh\\""}]}]}}\n' > "$SBOX/root-unwired/hooks/hooks.json"
DOC_UNWIRED="$(doctor_at "$SBOX/root-unwired")"
case "$DOC_UNWIRED" in
  *"does not register it on a PreToolUse matcher covering the spawn tools"*)
    check "A34 a hook registered on a non-spawn matcher reports a broken installation" PASS ;;
  *) check "A34 a hook registered on a non-spawn matcher reports a broken installation" FAIL ;;
esac
case "$DOC_UNWIRED" in
  *"admits its own read-only reviewer spawns"*)
    check "A34a the active grant row is suppressed for an unwired hook" FAIL ;;
  *) check "A34a the active grant row is suppressed for an unwired hook" PASS ;;
esac
mk_root "$SBOX/root-badjson" module hook
printf 'not json at all\n' > "$SBOX/root-badjson/hooks/hooks.json"
DOC_BADJSON="$(doctor_at "$SBOX/root-badjson")"
case "$DOC_BADJSON" in
  *"could not be read or parsed"*)
    check "A34b an unreadable hooks.json reports could-not-judge, not not-wired" PASS ;;
  *) check "A34b an unreadable hooks.json reports could-not-judge, not not-wired" FAIL ;;
esac

# ── A35 the granted row keeps its ✅ level ───────────────────────────────────
# ROW_LEVEL carries exactly one entry and defaults to WARN, so deleting it would silently
# turn a healthy configuration's row into a warning.
printf '{"permissions":{"defaultMode":"auto"}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_GLYPH="$(doctor "$NO_CONFIG")"
if printf '%s\n' "$DOC_GLYPH" | grep -q '^ *✅.*no settings edit is needed for them'; then
  check "A35 the granted exposure row renders at the ✅ level" PASS
else
  check "A35 the granted exposure row renders at the ✅ level" FAIL
fi

# ── A36 the banner's file guards, not only its flag ──────────────────────────
mk_root "$SBOX/root-banner" nomodule hook
cp "$PLUGIN_DIR/hooks/session-start-banner.sh" "$SBOX/root-banner/hooks/" 2>/dev/null
cp -R "$PLUGIN_DIR/hooks/lib" "$SBOX/root-banner/hooks/" 2>/dev/null
rm -f "$SBOX/root-banner/hooks/lib/reviewer-spawn-allow-v1.js"
cp "$PLUGIN_DIR/.claude-plugin/plugin.json" "$SBOX/root-banner/.claude-plugin/" 2>/dev/null
BANNER_NOMOD="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"startup",session_id:process.argv[1],cwd:process.argv[2]}))' "$SESSION_ID" "$PROJECT" \
  | CLAUDE_PLUGIN_ROOT="$SBOX/root-banner" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$NO_CONFIG" \
    bash "$SBOX/root-banner/hooks/session-start-banner.sh" 2>/dev/null)"
case "$BANNER_NOMOD" in
  *"Zensu PLM v"*) check "A36pre the throwaway-root banner rendered (absence anchor)" PASS ;;
  *) check "A36pre the throwaway-root banner rendered (absence anchor)" FAIL ;;
esac
case "$BANNER_NOMOD" in
  *"Reviewer spawns"*)
    check "A36 the banner withholds the grant line when the decision module is absent" FAIL ;;
  *) check "A36 the banner withholds the grant line when the decision module is absent" PASS ;;
esac

echo "----"
echo "test-reviewer-spawn-allow: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
