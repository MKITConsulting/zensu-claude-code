#!/bin/bash
# SessionStart hook — user-facing "Zensu is active" banner + usage hints.
# Plain stdout (shown to the user, like session-start-pulse.sh). Fires only on
# fresh starts (source=startup/clear); silent on resume/compact to avoid spam.
# Gated by hooks.sessionBanner (default on). Companion: session-start-primer.sh
# (model-facing orientation via additionalContext).
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
_ZENSU_BANNER_QUIET=""
zensu_hook_enabled sessionBanner || _ZENSU_BANNER_QUIET=1

# Only on fresh starts. Skip resume/compact. Missing source -> treat as startup.
{ INPUT="$(cat)"; } 2>/dev/null
SOURCE=""
if command -v node >/dev/null 2>&1; then
  SOURCE="$(printf '%s' "$INPUT" | node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{ try { const j=JSON.parse(s||"{}");
      process.stdout.write(typeof j.source==="string"?j.source:""); } catch(_){ process.stdout.write(""); } });
  ' 2>/dev/null)"
fi
case "$SOURCE" in
  resume|compact) exit 0 ;;
esac

# The ONE line in this file that reports a permission decision rather than a usage hint, so
# it sits ABOVE the sessionBanner gate: that flag is a NOISE control ("hide this banner",
# usage hints, the skills list) and it is read PERMISSIVELY, so a .zensu/config.json
# travelling inside a checked-out repository can set it. The grant's own reader was made
# sticky and fail-closed precisely so such a file cannot RE-ARM the bypass; leaving the
# announcement under the noise flag let that same file HIDE a capability it could not grant.
# It stays BELOW the resume/compact filter deliberately: that is a separate, deliberate
# silence contract (pinned as B11 in test-session-start-banner.sh), and a resumed session
# already showed this line at its original start. A session resumed long after that start
# therefore does not see it again — /zensu:doctor remains the surface that always answers.
# Guarded on the two files that actually produce the grant, not on the flag alone: with the
# hook or its decision module absent the hook declines every spawn, and a banner asserting a
# capability that is not in force is exactly the state the doctor's broken-installation row
# exists to name. The flag uses the fail-CLOSED reader for the same reason the hook does.
if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/pre-agent-reviewer-allow.sh" ] \
  && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/reviewer-spawn-allow-v1.js" ] \
  && zensu_hook_enabled_strict reviewerSpawnAutoAllow; then
  echo "zensu: Reviewer spawns — this plugin is configured to admit its own read-only reviewer subagents (Read/Grep/Glob only) itself, so the host permission layer is not asked for them. This line checks the flag and the two files; /zensu:doctor is the authoritative check and additionally verifies the hook's registration and that its decision module loads. Turn off: hooks.reviewerSpawnAutoAllow=false in ~/.zensu/config.json."
fi

# Whether the delivery-route question can actually be asked. Four conditions, all
# required: the flag, node, the hook file, and no configured default route —
# plan-approved-delegate.sh exits 0 silently without node or without its own
# libraries, and zensu_hook_enabled reports ENABLED when node is missing, so the flag
# alone would promise a question that cannot fire. Same reasoning, and same shape, as
# the reviewer-spawn guard above.
# GRADED ELSEWHERE: the first three arms are pinned by D26 (the autoTdd flag), D29
# (node) and D30 (the delegate hook file), and the off-state disclosure below by D27 —
# all in tests/structure/test-plan-approved-delegate.sh; the fourth, a configured
# hooks.defaultDeliveryRoute resolved below, is pinned by R14 in
# tests/structure/test-delivery-route.sh. Neither is this hook's own suite. The split
# is deliberate — test-plan-approved-delegate.sh is absent from the blocking Windows PR
# shard, where D29's stub-PATH fixture would cost budget and is unverified — so
# editing the tip literals below reddens suites named for other files.
_ZENSU_ROUTE_QUESTION_LIVE=yes
zensu_hook_enabled autoTdd || _ZENSU_ROUTE_QUESTION_LIVE=no
command -v node >/dev/null 2>&1 || _ZENSU_ROUTE_QUESTION_LIVE=no
[ -f "${CLAUDE_PLUGIN_ROOT}/hooks/plan-approved-delegate.sh" ] || _ZENSU_ROUTE_QUESTION_LIVE=no
# A configured hooks.defaultDeliveryRoute answers the question before it is asked, so
# the tip below must not promise one. Config-only on purpose (same rule as the mode
# line): a session with a new key has no session marker yet, and a marker a clear
# keeps under the same key is disclosed by the directive field, the status line,
# --status and the /zensu:doctor row, never by this banner. The key is read under the
# root the binder's resolveFreshHookProject answers: an existing record's root on a
# retry or a clear, else Claude's stable CLAUDE_PROJECT_DIR. The mutable payload cwd
# is never authoritative. When that resolution is unavailable the ambient read stands.
# KNOWN LIMIT, not closed here: on a FRESH start this hook runs concurrently with the
# Session Control registrar, which mints the record from the payload cwd. Until the
# record exists this read falls back to CLAUDE_PROJECT_DIR, so where the two roots
# differ the race decides which tree's config the banner discloses, while both
# ask-hooks later read the record's root.
# TWIN: session-start-autopilot-resume.sh resolves its root through the same binder
# call and the same host-path conversions; change the two together. Like that copy,
# this one calls the binder even without CLAUDE_PROJECT_DIR, so an existing record
# still wins on a clear.
_ZENSU_ROUTE_ROOT=""
if command -v node >/dev/null 2>&1; then
  _ZENSU_ROUTE_ROOT="$(
    NATIVE_PLUGIN_ROOT="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "$CLAUDE_PLUGIN_ROOT")" || exit 1
    NATIVE_PLUGIN_DATA="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}")" || exit 1
    NATIVE_PROJECT_ROOT=""
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
      NATIVE_PROJECT_ROOT="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "$CLAUDE_PROJECT_DIR")" || exit 1
    fi
    cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || exit 1
    printf '%s' "$INPUT" \
      | CLAUDE_PLUGIN_ROOT="$NATIVE_PLUGIN_ROOT" \
        CLAUDE_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" \
        CLAUDE_PROJECT_DIR="$NATIVE_PROJECT_ROOT" \
        node -e '
      const fs = require("node:fs");
      const binder = require("./claude-hook-session-v1.js");
      const payload = JSON.parse(fs.readFileSync(0, "utf8"));
      process.stdout.write(binder.resolveFreshHookProject(payload));
      ' 2>/dev/null
  )" || _ZENSU_ROUTE_ROOT=""
fi
if [ -n "$_ZENSU_ROUTE_ROOT" ]; then
  _ZENSU_ROUTE_DEFAULT="$(zensu_default_delivery_route "$_ZENSU_ROUTE_ROOT")"
else
  _ZENSU_ROUTE_DEFAULT="$(zensu_default_delivery_route)"
fi
case "$_ZENSU_ROUTE_DEFAULT" in
  tdd|direct) _ZENSU_ROUTE_QUESTION_LIVE=no ;;
esac

# The DISCLOSURE that the consent question is switched off sits ABOVE the
# sessionBanner gate, for the reason the reviewer-spawn line above gives: that flag
# is a NOISE control read PERMISSIVELY, and a .zensu/config.json travels inside a
# checked-out repository — so below the gate, ONE committed file could both switch
# the delivery-route question off and hide that it did. Reporting an absent consent
# gate is a permission fact, not a usage hint. It keys on the FLAG alone: a missing
# node is a broken installation rather than a configured choice, and naming the flag
# there would be false. The enabled-state tip below is an ordinary usage hint and
# stays under the gate.
if ! zensu_hook_enabled autoTdd; then
  echo "zensu: Tip — use Claude Code Plan mode for code changes. The delivery-route question is off (hooks.autoTdd=false), so an approved plan is implemented directly; invoke /zensu:tdd, /zensu:autopilot or /zensu:pilot yourself to pick a route."
fi
# Same placement, same reason: a configured default route silences the question
# from a file that travels inside the checkout, so the disclosure must not be
# hideable by the noise flag below it. The default reaches the plan-approval hook
# only while hooks.autoTdd is on and the per-prompt reminder only while
# hooks.tddReminder is on — each hook exits on its own flag BEFORE it resolves the
# route — so the line names the half that is live instead of promising both.
case "$_ZENSU_ROUTE_DEFAULT" in
  tdd|direct)
    if [ "$_ZENSU_ROUTE_DEFAULT" = tdd ]; then
      _ZENSU_ROUTE_EFFECT="takes the Zensu workflow"
    else
      _ZENSU_ROUTE_EFFECT="is implemented directly"
    fi
    _ZENSU_ROUTE_PLAN_ON=yes; _ZENSU_ROUTE_PROMPT_ON=yes
    zensu_hook_enabled autoTdd || _ZENSU_ROUTE_PLAN_ON=no
    zensu_hook_enabled tddReminder || _ZENSU_ROUTE_PROMPT_ON=no
    _ZENSU_ROUTE_TAIL="a preference stated in your message decides only that request, and /zensu:delivery-route changes the route for this session."
    case "${_ZENSU_ROUTE_PLAN_ON}${_ZENSU_ROUTE_PROMPT_ON}" in
      yesyes) echo "zensu: Delivery route — hooks.defaultDeliveryRoute=$_ZENSU_ROUTE_DEFAULT: an approved plan or a code request $_ZENSU_ROUTE_EFFECT without the route question; $_ZENSU_ROUTE_TAIL" ;;
      yesno)  echo "zensu: Delivery route — hooks.defaultDeliveryRoute=$_ZENSU_ROUTE_DEFAULT: an approved plan $_ZENSU_ROUTE_EFFECT without the route question (the code-request half is off: hooks.tddReminder=false); $_ZENSU_ROUTE_TAIL" ;;
      noyes)  echo "zensu: Delivery route — hooks.defaultDeliveryRoute=$_ZENSU_ROUTE_DEFAULT: a code request $_ZENSU_ROUTE_EFFECT without the route question (the plan-approval half is off: hooks.autoTdd=false, so an approved plan is implemented directly); $_ZENSU_ROUTE_TAIL" ;;
      *)      echo "zensu: Delivery route — hooks.defaultDeliveryRoute=$_ZENSU_ROUTE_DEFAULT is configured but decides nothing: both readers are off (hooks.autoTdd=false, hooks.tddReminder=false), and each hook exits on its own flag before the route is resolved." ;;
    esac
    ;;
esac

[ -n "$_ZENSU_BANNER_QUIET" ] && exit 0

# Consent mode announces that a PROMPT will appear, never a capability the plugin
# granted itself — so it sits BELOW the sessionBanner gate, unlike the reviewer-spawn
# line above. Hiding it costs the user a usage hint; hiding the grant would have hidden
# a capability a checked-out .zensu/config.json cannot grant but could conceal.
# /zensu:doctor's verify-feature row is not silenceable and remains the authoritative check.
if [ -z "${ZENSU_VERIFY_NAVIGATION_POLICY_V1:-}" ] \
  && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/pre-browser-navigation-consent.sh" ] \
  && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/post-browser-navigation-consent.sh" ] \
  && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/verify-consent-v1.js" ]; then
  echo "zensu: Browser verification — no navigation policy is set, so /zensu:verify-feature runs in consent mode: it drives playwright-cli, and the first time its zensu-verify browser session reaches a loopback origin you are asked through the permission prompt; remote targets still need the policy. /zensu:doctor checks playwright-cli, the hook registration and the runtime recipe."
fi


VERSION="?"
if command -v node >/dev/null 2>&1; then
  V="$(
    cd -P -- "$CLAUDE_PLUGIN_ROOT" || exit 1
    node -e 'try{const p=require("./.claude-plugin/plugin.json");process.stdout.write(p.version||"?")}catch(_){process.stdout.write("?")}' 2>/dev/null
  )"
  [ -n "$V" ] && VERSION="$V"
fi

echo "zensu: Zensu PLM v${VERSION} active — features as first-class citizens."
# The route tip is emitted only when the question can actually be asked
# (_ZENSU_ROUTE_QUESTION_LIVE above). The off-state DISCLOSURE is not here — it sits
# above the sessionBanner gate, where a noise flag cannot suppress it.
if zensu_tdd_strict_enabled; then
  echo "zensu: Flow — track features → implement (strict RED→GREEN TDD) → review chain → dashboard."
  if [ "$_ZENSU_ROUTE_QUESTION_LIVE" = yes ]; then
    echo "zensu: Tip — use Claude Code Plan mode for code changes; on approval Zensu asks which delivery route to take: /zensu:autopilot (unattended to a reviewed, validated PR), /zensu:tdd (this plan now, RED→GREEN + review chain, edits TDD-gate-enforced), /zensu:pilot (guided pipeline for a feature already tracked in Zensu), or implementing it directly."
  else
    echo "zensu: Tip — use Claude Code Plan mode for code changes."
  fi
else
  echo "zensu: Flow — track features → implement (vanilla mode, TDD discipline off via hooks.tddImplementation=false) → review chain → dashboard."
  if [ "$_ZENSU_ROUTE_QUESTION_LIVE" = yes ]; then
    echo "zensu: Tip — use Claude Code Plan mode for code changes; on approval Zensu asks which delivery route to take: /zensu:autopilot (unattended to a reviewed, validated PR), /zensu:tdd (this plan now, vanilla implementation with the evidence audits + review chain enforced), /zensu:pilot (guided pipeline for a feature already tracked in Zensu), or implementing it directly."
  else
    echo "zensu: Tip — use Claude Code Plan mode for code changes."
  fi
fi
echo "zensu: Skills — /zensu:bootstrap · /zensu:ghost-scan · /zensu:autopilot · /zensu:pilot · /zensu:implement · /zensu:tdd · /zensu:security-review · /zensu:pulse · /zensu:zensu-help (Q&A)."
if command -v zensu >/dev/null 2>&1; then
  echo "zensu: CLI ready ($(command -v zensu)) — Zensu skills drive it. On an auth error run: zensu auth login."
else
  echo "zensu: ⚠ 'zensu' CLI not found on PATH — Zensu skills need it. Install: curl -fsSL https://zensu.dev/install.sh | sh  then: zensu auth login."
fi
echo "zensu: Hide this banner: set hooks.sessionBanner=false in ~/.zensu/config.json."
exit 0
