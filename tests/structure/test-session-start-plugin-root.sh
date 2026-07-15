#!/bin/bash
# Plugin paths are session-native; no global Last-Writer-Wins root pointer.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PULSE_HOOK="$PLUGIN_DIR/hooks/session-start-pulse.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ -f "$PULSE_HOOK" ] && bash -n "$PULSE_HOOK" 2>/dev/null; then
  check "R1 pulse hook exists and parses" PASS
else
  check "R1 pulse hook exists and parses" FAIL
fi

if grep -qE '\.zensu/plugin-root|\$HOME/\.zensu|plugin-root' "$PULSE_HOOK"; then
  check "R2 pulse hook contains no legacy root-pointer writer" FAIL
else
  check "R2 pulse hook contains no legacy root-pointer writer" PASS
fi

TMP="$(mktemp -d -t zensu-native-root-XXXXXX)"
HOME_ON="$TMP/home-on"
HOME_OFF="$TMP/home-off"
mkdir -p "$HOME_ON/.zensu" "$HOME_OFF/.zensu"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' '/sentinel/must/not/change' > "$HOME_ON/.zensu/plugin-root"
BEFORE_ON="$(cksum "$HOME_ON/.zensu/plugin-root")"
HOME="$HOME_ON" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PULSE_HOOK" >/dev/null 2>&1 || true
AFTER_ON="$(cksum "$HOME_ON/.zensu/plugin-root")"
if [ "$BEFORE_ON" = "$AFTER_ON" ]; then
  check "R3 pulse enabled leaves a pre-existing legacy pointer byte-identical" PASS
else
  check "R3 pulse enabled leaves a pre-existing legacy pointer byte-identical" FAIL
fi

printf '%s\n' '/sentinel/must/not/change' > "$HOME_OFF/.zensu/plugin-root"
printf '%s\n' '{"hooks":{"pulseSession":false}}' > "$HOME_OFF/.zensu/config.json"
BEFORE_OFF="$(cksum "$HOME_OFF/.zensu/plugin-root")"
HOME="$HOME_OFF" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PULSE_HOOK" >/dev/null 2>&1 || true
AFTER_OFF="$(cksum "$HOME_OFF/.zensu/plugin-root")"
if [ "$BEFORE_OFF" = "$AFTER_OFF" ]; then
  check "R4 pulse disabled also leaves the legacy pointer byte-identical" PASS
else
  check "R4 pulse disabled also leaves the legacy pointer byte-identical" FAIL
fi

# Two plugin installs may start concurrently under the same HOME. Each hook
# must source libraries from its own session-native root; neither may coordinate
# through or overwrite the historical singleton pointer.
SHARED_HOME="$TMP/shared-home"
ROOT_A="$TMP/plugin root A"
ROOT_B="$TMP/plugin root B"
mkdir -p "$SHARED_HOME/.zensu" "$ROOT_A/hooks/lib" "$ROOT_B/hooks/lib"
printf '%s\n' '/sentinel/shared/root' > "$SHARED_HOME/.zensu/plugin-root"
SHARED_BEFORE="$(cksum "$SHARED_HOME/.zensu/plugin-root")"
cp "$PULSE_HOOK" "$ROOT_A/hooks/session-start-pulse.sh"
cp "$PULSE_HOOK" "$ROOT_B/hooks/session-start-pulse.sh"
cp "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$ROOT_A/hooks/lib/zensu-config.sh"
cp "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$ROOT_B/hooks/lib/zensu-config.sh"
printf '%s\n' '{"hooks":{"pulseSession":true}}' > "$TMP/two-root-config.json"
(
  cd "$PLUGIN_DIR" || exit 1
  HOME="$SHARED_HOME" CLAUDE_PLUGIN_ROOT="$ROOT_A" CLAUDE_PROJECT_DIR="$PLUGIN_DIR" \
    ZENSU_CONFIG="$TMP/two-root-config.json" bash "$ROOT_A/hooks/session-start-pulse.sh" \
    > "$TMP/root-a.out" 2> "$TMP/root-a.err"
  printf '%s\n' "$?" > "$TMP/root-a.rc"
) &
PID_A=$!
(
  cd "$PLUGIN_DIR" || exit 1
  HOME="$SHARED_HOME" CLAUDE_PLUGIN_ROOT="$ROOT_B" CLAUDE_PROJECT_DIR="$PLUGIN_DIR" \
    ZENSU_CONFIG="$TMP/two-root-config.json" bash "$ROOT_B/hooks/session-start-pulse.sh" \
    > "$TMP/root-b.out" 2> "$TMP/root-b.err"
  printf '%s\n' "$?" > "$TMP/root-b.rc"
) &
PID_B=$!
wait "$PID_A" 2>/dev/null || true
wait "$PID_B" 2>/dev/null || true
SHARED_AFTER="$(cksum "$SHARED_HOME/.zensu/plugin-root")"
if [ "$(cat "$TMP/root-a.rc" 2>/dev/null)" = "0" ] \
  && [ "$(cat "$TMP/root-b.rc" 2>/dev/null)" = "0" ] \
  && grep -qF 'zensu: pulse session ready' "$TMP/root-a.out" \
  && grep -qF 'zensu: pulse session ready' "$TMP/root-b.out" \
  && [ "$SHARED_BEFORE" = "$SHARED_AFTER" ]; then
  check "R4a concurrent sessions resolve two roots independently without pointer races" PASS
else
  check "R4a concurrent sessions resolve two roots independently without pointer races" FAIL
fi

if ROOT="$PLUGIN_DIR" node - <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.env.ROOT;
const targets = ["hooks", "skills", "agents", "templates", "scripts", "docs", "README.md"];
const bad = [];
function scan(p) {
  const st = fs.statSync(p);
  if (st.isDirectory()) {
    for (const name of fs.readdirSync(p)) scan(path.join(p, name));
    return;
  }
  if (!/\.(?:sh|js|json|md)$/.test(p)) return;
  const text = fs.readFileSync(p, "utf8");
  if (text.includes(".zensu/plugin-root") || text.includes("{PLUGIN_ROOT}")) {
    bad.push(path.relative(root, p));
  }
}
for (const rel of targets) {
  const p = path.join(root, rel);
  if (fs.existsSync(p)) scan(p);
}
if (bad.length) {
  process.stderr.write(`legacy plugin-root consumers: ${bad.join(", ")}\n`);
  process.exit(1);
}
NODE
then
  check "R5 active runtime, skills, templates, and docs contain no legacy pointer consumer" PASS
else
  check "R5 active runtime, skills, templates, and docs contain no legacy pointer consumer" FAIL
fi

if ROOT="$PLUGIN_DIR" node - <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.env.ROOT;
const targets = ["skills", "agents", "templates", "docs", "README.md"];
const bad = [];
function scan(p) {
  const st = fs.statSync(p);
  if (st.isDirectory()) {
    for (const name of fs.readdirSync(p)) scan(path.join(p, name));
    return;
  }
  if (!/\.(?:md|json|yaml)$/.test(p)) return;
  const text = fs.readFileSync(p, "utf8");
  if (/bash\s+\$(?:\{CLAUDE_PLUGIN_ROOT\}|CLAUDE_PLUGIN_ROOT)\//.test(text)) bad.push(path.relative(root, p));
}
for (const rel of targets) {
  const p = path.join(root, rel);
  if (fs.existsSync(p)) scan(p);
}
if (bad.length) {
  process.stderr.write(`unquoted component executable paths: ${bad.join(", ")}\n`);
  process.exit(1);
}
NODE
then
  check "R6 component executable paths quote native CLAUDE_PLUGIN_ROOT" PASS
else
  check "R6 component executable paths quote native CLAUDE_PLUGIN_ROOT" FAIL
fi

if HOOKS_JSON="$HOOKS_JSON" node - <<'NODE'
const fs = require("fs");
const doc = JSON.parse(fs.readFileSync(process.env.HOOKS_JSON, "utf8"));
const groups = Object.values(doc.hooks || {}).flat();
const commands = groups.flatMap(group => group.hooks || []).filter(hook => hook.type === "command");
if (!commands.length) process.exit(1);
for (const hook of commands) {
  if (typeof hook.command !== "string" || !/^bash "\$\{CLAUDE_PLUGIN_ROOT\}\/hooks\/[^"]+"$/.test(hook.command)) process.exit(2);
}
NODE
then
  check "R7 hook commands carry a complete quoted native-root invocation" PASS
else
  check "R7 hook commands carry a complete quoted native-root invocation" FAIL
fi

for component in \
  "$PLUGIN_DIR/skills/autopilot/SKILL.md" \
  "$PLUGIN_DIR/skills/tdd/SKILL.md" \
  "$PLUGIN_DIR/skills/pr-team-review/SKILL.md" \
  "$PLUGIN_DIR/skills/pr-fix-findings/SKILL.md" \
  "$PLUGIN_DIR/skills/self-review/SKILL.md"
do
  if ! grep -qF '${CLAUDE_PLUGIN_ROOT}' "$component"; then
    check "R8 core workflow components use native CLAUDE_PLUGIN_ROOT" FAIL
    echo "----"
    echo "test-session-start-plugin-root: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "R8 core workflow components use native CLAUDE_PLUGIN_ROOT" PASS

if SKILLS_ROOT="$PLUGIN_DIR/skills" node - <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.env.SKILLS_ROOT;
const failures = [];

function visit(p) {
  const stat = fs.statSync(p);
  if (stat.isDirectory()) {
    for (const name of fs.readdirSync(p)) visit(path.join(p, name));
    return;
  }
  if (!p.endsWith(".md") || !p.split(path.sep).includes("rules")) return;
  const text = fs.readFileSync(p, "utf8");
  const rel = path.relative(root, p);
  if (text.includes("${CLAUDE_PLUGIN_ROOT}")) failures.push(`${rel}: raw rule uses component env token`);
  if (!text.includes("{ACTIVE_PLUGIN_ROOT}")) return;

  const parts = p.split(path.sep);
  const rulesIndex = parts.lastIndexOf("rules");
  const skillDir = parts.slice(0, rulesIndex).join(path.sep) || path.sep;
  const parent = path.join(skillDir, "SKILL.md");
  let parentText = "";
  try { parentText = fs.readFileSync(parent, "utf8"); } catch (_) {}
  if (!parentText.includes("{ACTIVE_PLUGIN_ROOT}")
      || !parentText.includes("${CLAUDE_PLUGIN_ROOT}")
      || !parentText.includes("concrete")) {
    failures.push(`${rel}: registered parent does not map the active root concretely`);
  }
}

visit(root);
if (failures.length) {
  process.stderr.write(`${failures.join("\n")}\n`);
  process.exit(1);
}
NODE
then
  check "R9 raw Read rules use ACTIVE_PLUGIN_ROOT with a concrete parent mapping" PASS
else
  check "R9 raw Read rules use ACTIVE_PLUGIN_ROOT with a concrete parent mapping" FAIL
fi

echo "----"
echo "test-session-start-plugin-root: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
