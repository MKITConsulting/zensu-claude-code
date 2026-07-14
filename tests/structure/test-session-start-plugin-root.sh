#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EXPORT_HOOK="$PLUGIN_DIR/hooks/session-start-export-root.sh"
PULSE_HOOK="$PLUGIN_DIR/hooks/session-start-pulse.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

if [ -f "$EXPORT_HOOK" ] && bash -n "$EXPORT_HOOK" 2>/dev/null; then
  check "C1 SessionStart root exporter exists and parses" PASS
else
  check "C1 SessionStart root exporter exists and parses" FAIL
fi

if command -v node >/dev/null 2>&1 && HOOKS_JSON="$HOOKS_JSON" node - <<'NODE'
const fs = require("fs");
const doc = JSON.parse(fs.readFileSync(process.env.HOOKS_JSON, "utf8"));
const groups = Object.values(doc.hooks || {}).flat();
const handlers = groups.flatMap(group => group.hooks || []);
if (!handlers.length) process.exit(1);
for (const hook of handlers) {
  if (hook.type !== "command") continue;
  if (typeof hook.command !== "string" || !/^bash "\$\{CLAUDE_PLUGIN_ROOT\}\/hooks\/[^"]+"$/.test(hook.command)) process.exit(2);
  if (Object.hasOwn(hook, "args")) process.exit(3);
}
const starts = (doc.hooks.SessionStart || []).flatMap(group => group.hooks || []);
if (!starts.some(hook => hook.command === 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/session-start-export-root.sh"')) process.exit(5);
NODE
then
  check "C2 command hooks carry the complete quoted invocation and register the exporter" PASS
else
  check "C2 command hooks use Claude Code's supported command-string schema" FAIL
fi

TMP="$(mktemp -d -t zensu-claude-root-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TEST_HOME="$TMP/home with space"
FAKE_ROOT="$TMP/plugin root 'quote \$dollar"
ENV_FILE="$TMP/claude env.sh"
mkdir -p "$TEST_HOME" "$FAKE_ROOT/hooks/lib"
printf '%s\n' '# fixture helper' > "$FAKE_ROOT/hooks/lib/zensu-log.sh"
printf '%s\n' 'export EXISTING_SESSION_VALUE=preserved' > "$ENV_FILE"

if [ -f "$EXPORT_HOOK" ]; then
  env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
    CLAUDE_ENV_FILE="$ENV_FILE" bash "$EXPORT_HOOK" >/dev/null 2>&1
fi

GOT="$(env -i PATH="$PATH" bash -c '. "$1"; printf "%s" "${ZENSU_CLAUDE_PLUGIN_ROOT:-}"' _ "$ENV_FILE" 2>/dev/null)"
EXPECTED_ROOT="$(native "$(cd "$FAKE_ROOT" && pwd -P)")"
if [ "$GOT" = "$EXPECTED_ROOT" ]; then
  check "C3 exported root round-trips spaces, quotes, and dollar characters" PASS
else
  check "C3 exported root round-trips safely (got '$GOT')" FAIL
fi

PRESERVED="$(env -i PATH="$PATH" bash -c '. "$1"; printf "%s" "${EXISTING_SESSION_VALUE:-}"' _ "$ENV_FILE" 2>/dev/null)"
if [ "$PRESERVED" = "preserved" ]; then
  check "C4 exporter appends without clobbering another SessionStart export" PASS
else
  check "C4 exporter preserves existing CLAUDE_ENV_FILE content" FAIL
fi

# A failed later SessionStart must invalidate a binding left by an earlier
# successful run; otherwise resume can silently retain the old installation.
printf '%s\n' 'export ZENSU_CLAUDE_PLUGIN_ROOT=/tmp/stale-root' > "$ENV_FILE"
BAD_ROOT="$TMP/missing-plugin-root"
env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$BAD_ROOT" \
  CLAUDE_ENV_FILE="$ENV_FILE" bash "$EXPORT_HOOK" >/dev/null 2>&1; BAD_RC=$?
STALE="$(env -i PATH="$PATH" bash -c '. "$1"; printf "%s" "${ZENSU_CLAUDE_PLUGIN_ROOT:-}"' _ "$ENV_FILE" 2>/dev/null)"
if [ "$BAD_RC" -ne 0 ] && [ -z "$STALE" ]; then
  check "C4b failed export invalidates an older session binding" PASS
else
  check "C4b failed export left stale root '$STALE' (rc=$BAD_RC)" FAIL
fi

# %q must remain sourceable for every POSIX filename byte Bash permits, and
# concurrent appenders must never tear an export line.
WEIRD_A="$TMP/plugin \"double\" \`tick\`"$'\n''newline-a'
WEIRD_B="$TMP/plugin second 'quote'"$'\n''newline-b'
mkdir -p "$WEIRD_A/hooks/lib" "$WEIRD_B/hooks/lib"
printf '%s\n' '# fixture helper' > "$WEIRD_A/hooks/lib/zensu-log.sh"
printf '%s\n' '# fixture helper' > "$WEIRD_B/hooks/lib/zensu-log.sh"
: > "$ENV_FILE"
env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$WEIRD_A" CLAUDE_ENV_FILE="$ENV_FILE" bash "$EXPORT_HOOK" >/dev/null 2>&1 & EA=$!
env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$WEIRD_B" CLAUDE_ENV_FILE="$ENV_FILE" bash "$EXPORT_HOOK" >/dev/null 2>&1 & EB=$!
wait "$EA"; RCA=$?; wait "$EB"; RCB=$?
ROUNDTRIP="$(env -i PATH="$PATH" bash -c '. "$1"; printf "%s" "${ZENSU_CLAUDE_PLUGIN_ROOT:-}"' _ "$ENV_FILE" 2>/dev/null)"; SOURCE_RC=$?
if [ "$RCA" -eq 0 ] && [ "$RCB" -eq 0 ] && [ "$SOURCE_RC" -eq 0 ] && \
   { [ "$ROUNDTRIP" = "$(native "$(cd "$WEIRD_A" && pwd -P)")" ] || \
     [ "$ROUNDTRIP" = "$(native "$(cd "$WEIRD_B" && pwd -P)")" ]; }; then
  check "C4c concurrent hostile-path exports remain complete and sourceable" PASS
else
  check "C4c concurrent exporter output was torn or unsourceable" FAIL
fi

rm -rf "$TEST_HOME/.zensu"
if [ -f "$EXPORT_HOOK" ]; then
  env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
    bash "$EXPORT_HOOK" >/dev/null 2>&1
fi
if [ ! -e "$TEST_HOME/.zensu/plugin-root" ]; then
  check "C5 missing CLAUDE_ENV_FILE fails open without writing the legacy pointer" PASS
else
  check "C5 exporter unexpectedly wrote the legacy pointer" FAIL
fi

rm -rf "$TEST_HOME/.zensu"
env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  bash "$PULSE_HOOK" >/dev/null 2>&1 || true
if [ ! -e "$TEST_HOME/.zensu/plugin-root" ]; then
  check "C6 peer SessionStart hooks self-resolve and never write the legacy pointer" PASS
else
  check "C6 pulse hook unexpectedly wrote the legacy pointer" FAIL
fi

if ROOT="$PLUGIN_DIR" node - <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.env.ROOT;
const targets = ["hooks", "skills", "agents", "scripts", "templates", "docs", "README.md", "CLAUDE.md"];
const needle = ".zensu/plugin-root";
const hits = [];
function scan(p) {
  const st = fs.statSync(p);
  if (st.isDirectory()) {
    for (const name of fs.readdirSync(p)) scan(path.join(p, name));
    return;
  }
  if (!/\.(?:sh|js|json|md)$/.test(p)) return;
  if (fs.readFileSync(p, "utf8").includes(needle)) hits.push(path.relative(root, p));
}
for (const rel of targets) {
  const p = path.join(root, rel);
  if (fs.existsSync(p)) scan(p);
}
if (hits.length) {
  process.stderr.write(`active legacy plugin-root references: ${hits.join(", ")}\n`);
  process.exit(1);
}
NODE
then
  check "C7 active hooks, skills, and docs contain no legacy pointer consumer" PASS
else
  check "C7 active hooks, skills, and docs contain no legacy pointer consumer" FAIL
fi

if ROOT="$PLUGIN_DIR" node - <<'NODE'
const fs=require("fs"), path=require("path"), root=process.env.ROOT;
const targets=["skills","agents","docs","templates","scripts","README.md","CLAUDE.md"];
const bad=[];
function scan(file) {
  const stat=fs.statSync(file);
  if (stat.isDirectory()) { for (const name of fs.readdirSync(file)) scan(path.join(file,name)); return; }
  if (!/\.(?:md|json|yaml)$/.test(file)) return;
  const text=fs.readFileSync(file,"utf8");
  if (/\{PLUGIN_ROOT\}|bash\s+["\x27]?\$\{?CLAUDE_PLUGIN_ROOT\b|bash\s+\$[A-Z_]*PLUGIN_ROOT\//.test(text)) bad.push(path.relative(root,file));
  if (file.endsWith(".md")) {
    for (const match of text.matchAll(/```(?:bash|sh)\s*\n([\s\S]*?)```/g)) {
      const block=match[1];
      if (/\$(?:ROOT|PLUGIN_ROOT)\b|\$\{(?:ROOT|PLUGIN_ROOT)\b/.test(block) &&
          !/(?:ROOT|PLUGIN_ROOT)=.*ZENSU_CLAUDE_PLUGIN_ROOT/.test(block)) {
        bad.push(`${path.relative(root,file)}:shell-block-reuses-root`);
      }
    }
  }
}
for (const rel of targets) if (fs.existsSync(path.join(root,rel))) scan(path.join(root,rel));
for (const rel of ["hooks/session-start-primer.sh","hooks/post-review-tdd-delegate.sh","hooks/stop-chain-enforcer.sh","hooks/pre-edit-tdd-reminder.sh"]) {
  const text=fs.readFileSync(path.join(root,rel),"utf8");
  if (/\{PLUGIN_ROOT\}|root\s*\+\s*["\x27]\/hooks\/|bash\s+\$\{?CLAUDE_PLUGIN_ROOT/.test(text)) bad.push(rel);
}
for (const rel of ["skills/tdd/SKILL.md","skills/self-review/SKILL.md"]) {
  if (!fs.readFileSync(path.join(root,rel),"utf8").includes("ZENSU_CLAUDE_PLUGIN_ROOT")) bad.push(`${rel}:missing-session-export`);
}
if (bad.length) { process.stderr.write(`model workflows bypass session-bound root: ${bad.join(", ")}\n`); process.exit(1); }
NODE
then
  check "C8 model workflows use the validated session-bound root" PASS
else
  check "C8 model workflows still consume hook-only or unquoted roots" FAIL
fi

echo "----"
echo "test-session-start-plugin-root: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
