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
SOURCE=""
if command -v node >/dev/null 2>&1; then
  SOURCE="$(node -e '
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

[ -n "$_ZENSU_BANNER_QUIET" ] && exit 0

VERSION="?"
if command -v node >/dev/null 2>&1; then
  V="$(
    cd -P -- "$CLAUDE_PLUGIN_ROOT" || exit 1
    node -e 'try{const p=require("./.claude-plugin/plugin.json");process.stdout.write(p.version||"?")}catch(_){process.stdout.write("?")}' 2>/dev/null
  )"
  [ -n "$V" ] && VERSION="$V"
fi

echo "zensu: Zensu PLM v${VERSION} active — features as first-class citizens."
if zensu_tdd_strict_enabled; then
  echo "zensu: Flow — track features → implement (strict RED→GREEN TDD) → review chain → dashboard."
  echo "zensu: Tip — use Claude Code Plan mode for code changes; on approval Zensu asks which delivery route to take: /zensu:autopilot (unattended to a reviewed, validated PR), /zensu:tdd (this plan now, RED→GREEN + review chain, edits TDD-gate-enforced), /zensu:pilot (guided pipeline for a feature already tracked in Zensu), or implementing it directly."
else
  echo "zensu: Flow — track features → implement (vanilla mode, TDD discipline off via hooks.tddImplementation=false) → review chain → dashboard."
  echo "zensu: Tip — use Claude Code Plan mode for code changes; on approval Zensu asks which delivery route to take: /zensu:autopilot (unattended to a reviewed, validated PR), /zensu:tdd (this plan now, vanilla implementation with the evidence audits + review chain enforced), /zensu:pilot (guided pipeline for a feature already tracked in Zensu), or implementing it directly."
fi
echo "zensu: Skills — /zensu:bootstrap · /zensu:ghost-scan · /zensu:autopilot · /zensu:pilot · /zensu:implement · /zensu:tdd · /zensu:security-review · /zensu:pulse · /zensu:zensu-help (Q&A)."
if command -v zensu >/dev/null 2>&1; then
  echo "zensu: CLI ready ($(command -v zensu)) — Zensu skills drive it. On an auth error run: zensu auth login."
else
  echo "zensu: ⚠ 'zensu' CLI not found on PATH — Zensu skills need it. Install: curl -fsSL https://zensu.dev/install.sh | sh  then: zensu auth login."
fi
echo "zensu: Hide this banner: set hooks.sessionBanner=false in ~/.zensu/config.json."
exit 0
