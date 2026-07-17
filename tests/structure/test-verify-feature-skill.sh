#!/bin/bash
set -u

# Structure test for /zensu:verify-feature.
# Pins the public command, self-contained browser loop, isolated Zensu local adapter,
# credential-blind auth contract, evidence/verdict gates, pinned Playwright MCP runtime,
# plugin registration, and user-facing documentation. No browser or network is launched.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/verify-feature"
SKILL_MD="$SKILL_DIR/SKILL.md"
BROWSER_MD="$SKILL_DIR/rules/browser-verification.md"
ZENSU_MD="$SKILL_DIR/rules/zensu-monorepo.md"
MCP_JSON="$PLUGIN_DIR/.mcp.json"
MCP_PACKAGE="$PLUGIN_DIR/mcp-runtime/package.json"
MCP_LOCK="$PLUGIN_DIR/mcp-runtime/package-lock.json"
MCP_LAUNCHER="$PLUGIN_DIR/scripts/playwright-mcp.sh"
MCP_PROXY="$PLUGIN_DIR/scripts/playwright-mcp-proxy.js"
MCP_PROXY_TEST="$PLUGIN_DIR/tests/structure/playwright-mcp-proxy.test.js"
MCP_RUNTIME_DOC="$PLUGIN_DIR/docs/playwright-mcp-runtime.md"
RUNTIME_CONTROLLER="$SKILL_DIR/scripts/zensu-monorepo-runtime.sh"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
README_MD="$PLUGIN_DIR/README.md"
HELP_MD="$PLUGIN_DIR/skills/zensu-help/SKILL.md"
DOCTOR_SH="$PLUGIN_DIR/hooks/lib/zensu-doctor.sh"
DOCTOR_REPORT="$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js"
DOCTOR_SKILL="$PLUGIN_DIR/skills/doctor/SKILL.md"
AUTOPILOT_SKILL="$PLUGIN_DIR/skills/autopilot/SKILL.md"
AUTOPILOT_AUTH="$PLUGIN_DIR/skills/autopilot/rules/auth.md"
AUTOPILOT_CONFIG="$PLUGIN_DIR/skills/autopilot/rules/config.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$SKILL_MD" "$BROWSER_MD" "$ZENSU_MD" "$MCP_JSON" "$MCP_PACKAGE" "$MCP_LOCK" "$MCP_LAUNCHER" "$MCP_PROXY" "$MCP_PROXY_TEST" "$MCP_RUNTIME_DOC" "$RUNTIME_CONTROLLER" "$PLUGIN_JSON" \
  "$README_MD" "$HELP_MD" "$DOCTOR_SH" "$DOCTOR_REPORT" "$DOCTOR_SKILL" \
  "$AUTOPILOT_SKILL" "$AUTOPILOT_AUTH" "$AUTOPILOT_CONFIG"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-verify-feature-skill: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all skill, runtime, registration, and documentation files exist" PASS

# P1 — public identity and auto-trigger language.
grep -qxF '# /zensu:verify-feature' "$SKILL_MD" \
  && check "P1a namespaced H1 is /zensu:verify-feature" PASS \
  || check "P1a namespaced H1 is /zensu:verify-feature" FAIL
grep -qE '^name: *verify-feature *$' "$SKILL_MD" \
  && check "P1b frontmatter name is verify-feature" PASS \
  || check "P1b frontmatter name is verify-feature" FAIL
if grep -qiF 'test a feature live' "$SKILL_MD" && grep -qiF 'worktree' "$SKILL_MD" && grep -qiF 'end-to-end smoke check' "$SKILL_MD"; then
  check "P1c frontmatter recognizes live, worktree, and E2E verification intent" PASS
else
  check "P1c frontmatter recognizes live, worktree, and E2E verification intent" FAIL
fi
if grep -rqF '# /zensu:test-worktree' "$SKILL_DIR" || grep -rqE '^name: *test-worktree *$' "$SKILL_DIR"; then
  check "P1d old test-worktree name is not exposed as a command" FAIL
else
  check "P1d old test-worktree name is not exposed as a command" PASS
fi

# P2 — live verification scope and matrix completeness.
if grep -qF -- '--mode=local' "$SKILL_MD" && grep -qF 'deployed code' "$SKILL_MD" && grep -qF 'current worktree' "$SKILL_MD"; then
  check "P2a local and remote targets are explicit" PASS
else
  check "P2a local and remote targets are explicit" FAIL
fi
if grep -qF 'P0/P1/P2' "$SKILL_MD" && grep -qF 'completeness-critic' "$SKILL_MD" && grep -qF 'diff' "$SKILL_MD"; then
  check "P2b matrix is diff-grounded, prioritized, and completeness-checked" PASS
else
  check "P2b matrix is diff-grounded, prioritized, and completeness-checked" FAIL
fi
if grep -qF 'An autopilot recipe is not automatically safe' "$SKILL_MD" && grep -qF 'explicit scoped `down` command' "$SKILL_MD" && grep -qF 'candidate was rejected' "$SKILL_MD"; then
  check "P2d autopilot config is accepted only with a verification-safe lifecycle" PASS
else
  check "P2d autopilot config is accepted only with a verification-safe lifecycle" FAIL
fi
if grep -qF 'standalone Bash invocation, byte-for-byte' "$SKILL_MD" \
  && grep -qF 'Do not combine it with semicolons, `&&`, pipes' "$SKILL_MD"; then
  check "P2e configured teardown runs as an exact standalone Bash command" PASS
else
  check "P2e configured teardown runs as an exact standalone Bash command" FAIL
fi
if grep -qF 'Report only.' "$SKILL_MD" && grep -qF '/zensu:cover' "$SKILL_MD" && grep -qF '/zensu:autopilot' "$SKILL_MD"; then
  check "P2c live proof is separated from fixes, durable tests, and autopilot" PASS
else
  check "P2c live proof is separated from fixes, durable tests, and autopilot" FAIL
fi

# P3 — browser loop is bundled and requires all evidence planes.
if grep -qF 'rules/browser-verification.md' "$SKILL_MD"; then
  check "P3a skill loads its bundled browser verification rules" PASS
else
  check "P3a skill loads its bundled browser verification rules" FAIL
fi
for needle in browser_snapshot browser_take_screenshot browser_console_messages browser_network_requests browser_close; do
  if grep -qF "$needle" "$BROWSER_MD"; then
    check "P3 browser rule references $needle" PASS
  else
    check "P3 browser rule references $needle" FAIL
  fi
done
if grep -qF 'DOM and data' "$BROWSER_MD" && grep -qF '### Visual' "$BROWSER_MD" && grep -qF '### Runtime signals' "$BROWSER_MD"; then
  check "P3b DOM/data, visual, and runtime evidence are all mandatory" PASS
else
  check "P3b DOM/data, visual, and runtime evidence are all mandatory" FAIL
fi
if grep -qF 'every P0 was driven and passed' "$SKILL_MD" && grep -qF 'VERIFY-FEATURE-VERDICT: PASS' "$SKILL_MD"; then
  check "P3c PASS gate and machine-readable verdict are pinned" PASS
else
  check "P3c PASS gate and machine-readable verdict are pinned" FAIL
fi
if grep -qF 'bare, unfenced' "$SKILL_MD" \
  && grep -qF 'with no backticks, list marker, block quote, or text after it' "$SKILL_MD"; then
  check "P3d terminal verdict must be an unfenced final plain-text line" PASS
else
  check "P3d terminal verdict must be an unfenced final plain-text line" FAIL
fi
if grep -qF 'Explicit scope stays bounded.' "$SKILL_MD" \
  && grep -qF 'do not invent unrelated responsive, idempotence, error-path' "$SKILL_MD"; then
  check "P3e explicitly complete acceptance criteria prevent unrelated matrix expansion" PASS
else
  check "P3e explicitly complete acceptance criteria prevent unrelated matrix expansion" FAIL
fi

# P4 — credential-blind auth; no token extraction/injection recipe.
if grep -qiF 'credential-blind' "$SKILL_MD" && grep -qF 'use visible manual' "$SKILL_MD" \
  && grep -qF 'browser login or report the authenticated coverage as PARTIAL' "$SKILL_MD" \
  && grep -qF 'omits all' "$SKILL_MD" && grep -qF 'cookie/storage/session getters and setters' "$SKILL_MD"; then
  check "P4a auth is visible-only and omits broad browser storage capability" PASS
else
  check "P4a auth is visible-only and omits broad browser storage capability" FAIL
fi
if grep -qF 'not accept an auth artifact path' "$SKILL_MD" \
  && ! grep -rqF 'browser_set_storage_state' "$SKILL_DIR"; then
  check "P4b verify-feature never accepts or restores storage-state artifacts" PASS
else
  check "P4b verify-feature never accepts or restores storage-state artifacts" FAIL
fi
if grep -qF 'hard-denies every getter/exporter' "$SKILL_MD" \
  && grep -qF 'Do not invoke `auth.loginScript`' "$SKILL_MD"; then
  check "P4e future opaque auth requires a narrow deny-by-default broker" PASS
else
  check "P4e future opaque auth requires a narrow deny-by-default broker" FAIL
fi
if grep -qF '$GIT_ROOT/.zensu/verify-feature-runs/<random>' "$SKILL_MD" \
  && grep -qF 'Remove only the unique leaf on cleanup.' "$SKILL_MD"; then
  check "P4n run artifacts stay under a collision-safe workspace root" PASS
else
  check "P4n run artifacts stay under a collision-safe workspace root" FAIL
fi
if grep -qF 'pre-model evidence boundary' "$BROWSER_MD" \
  && grep -qF 'Contract v1 has' "$BROWSER_MD" && grep -qF 'no trusted model-visible sanitizer' "$BROWSER_MD" \
  && grep -qF 'report PARTIAL' "$BROWSER_MD"; then
  check "P4o authenticated console/network evidence fails closed before model ingestion" PASS
else
  check "P4o authenticated console/network evidence fails closed before model ingestion" FAIL
fi
if grep -qF 'validate the supplied base URL entirely' "$SKILL_MD" \
  && grep -qF 'before invoking any other tool' "$SKILL_MD" \
  && grep -qF 'Do not inspect Git' "$SKILL_MD"; then
  check "P4p unsafe remote URLs stop before every post-Skill tool" PASS
else
  check "P4p unsafe remote URLs stop before every post-Skill tool" FAIL
fi
if grep -qF '`validate.evidenceSafety` block' "$SKILL_MD" \
  && grep -qF 'fail-closed schema' "$SKILL_MD" \
  && grep -qF '`browser_navigate` result' "$SKILL_MD" \
  && grep -qF 'mode: declared-safe' "$AUTOPILOT_CONFIG" \
  && grep -qF 'the only mode supported by contract v1' "$AUTOPILOT_CONFIG" \
  && ! grep -qF 'redactionDriver' "$AUTOPILOT_CONFIG" \
  && grep -qF 'contractVersion' "$AUTOPILOT_CONFIG" \
  && grep -qF 'literal `false`' "$AUTOPILOT_CONFIG" \
  && grep -qF 'Every protected route' "$AUTOPILOT_CONFIG" \
  && grep -qF 'enforce this fail-closed boundary before navigation' "$BROWSER_MD"; then
  check "P4q protected DOM and visual evidence is safe before model ingestion" PASS
else
  check "P4q protected DOM and visual evidence is safe before model ingestion" FAIL
fi
if grep -qF 'future checked-in broker' "$SKILL_MD" \
  && grep -qF 'path-contained setter' "$SKILL_MD" \
  && grep -qF 'hard-denies every getter/exporter' "$SKILL_MD"; then
  check "P4g broad upstream storage tools stay disabled until a narrow broker exists" PASS
else
  check "P4g broad upstream storage tools stay disabled until a narrow broker exists" FAIL
fi
if grep -qF 'Use visible manual browser login' "$ZENSU_MD" \
  && grep -qF 'never read, print, or pass' "$ZENSU_MD" \
  && grep -qF 'If no credential-blind path' "$ZENSU_MD"; then
  check "P4h bundled Zensu adapter never runs a storage-state login script" PASS
else
  check "P4h bundled Zensu adapter never runs a storage-state login script" FAIL
fi
if grep -qF 'ORIGIN="$(parent_origin)"' "$RUNTIME_CONTROLLER" \
  && grep -qF 'APP_BASE_URL="$ORIGIN"' "$RUNTIME_CONTROLLER" \
  && grep -qF 'Resolve the planned application origin from the immutable parent policy' "$ZENSU_MD" \
  && grep -qF -- '--check-policy local "$APP_ORIGIN" "/" declared-safe' "$ZENSU_MD" \
  && grep -qF 'Use visible manual browser login' "$ZENSU_MD"; then
  check "P4i local auth waits for the exact frontend origin and stays visible" PASS
else
  check "P4i local auth waits for the exact frontend origin and stays visible" FAIL
fi
if grep -qF 'baseUrl:     "http://localhost:5173" # same-origin /api proxy' "$AUTOPILOT_CONFIG" \
  && grep -qF 'appOrigin:   "http://localhost:5173" # exact browser/storage-state origin' "$AUTOPILOT_CONFIG"; then
  check "P4j autopilot example pins distinct auth/app contract to its same-origin proxy" PASS
else
  check "P4j autopilot example pins distinct auth/app contract to its same-origin proxy" FAIL
fi
if grep -qF 'require non-loopback `https://` in remote mode' "$SKILL_MD" \
  && grep -qF 'reject query strings and fragments' "$SKILL_MD" \
  && grep -qF 'no username/password userinfo' "$SKILL_MD"; then
  check "P4k remote targets are HTTPS and credential-free before use/reporting" PASS
else
  check "P4k remote targets are HTTPS and credential-free before use/reporting" FAIL
fi
if grep -qF 'derive `ZENSU_APP_ORIGIN` from the sanitized navigation' "$SKILL_MD" \
  && grep -qF 'URL origin; never trust a recipe value independently' "$SKILL_MD" \
  && grep -qF 'exactly equal that derived origin' "$SKILL_MD"; then
  check "P4l remote auth metadata cannot override the validated application origin" PASS
else
  check "P4l remote auth metadata cannot override the validated application origin" FAIL
fi
if grep -qF 'before echoing, navigating, or authenticating' "$SKILL_MD" \
  && grep -qF 'never copy' "$SKILL_MD" \
  && grep -qF 'a rejected URL into output' "$SKILL_MD" \
  && grep -qF 'configured `auth.baseUrl` independently with the same mode-specific URL rules before use' "$SKILL_MD" \
  && grep -qF 'explicitly associates the auth origin with the same' "$SKILL_MD" \
  && grep -qF 'selected deployment/environment' "$SKILL_MD" \
  && grep -qF 'Never print or report a rejected' "$SKILL_MD" \
  && grep -qF 'authentication or application URL.' "$SKILL_MD"; then
  check "P4m remote URL rejection happens before use and never discloses rejected values" PASS
else
  check "P4m remote URL rejection happens before use and never discloses rejected values" FAIL
fi
if grep -qF 'Retain no component of a rejected URL.' "$SKILL_MD" \
  && grep -qF 'remote target rejected before resolution' "$SKILL_MD" \
  && grep -qF 'scheme, hostname, port, path, query key, query value, fragment, or' "$SKILL_MD"; then
  check "P4r rejected remote reports disclose no URL component" PASS
else
  check "P4r rejected remote reports disclose no URL component" FAIL
fi
if grep -qF "ZENSU_VERIFY_NAVIGATION_POLICY_V1" "$SKILL_MD" \
  && grep -qF 'intercepts every request before continuation' "$SKILL_MD" \
  && grep -qF 'Raw Playwright navigation' "$SKILL_MD" && grep -qF 'followed by a final-URL check is too late' "$SKILL_MD" \
  && grep -qF 'DNS rebinding' "$SKILL_MD" \
  && grep -qF 'Never replace it with navigate-then-check logic.' "$BROWSER_MD"; then
  check "P4s remote redirects are origin-gated before any model-visible response" PASS
else
  check "P4s remote redirects are origin-gated before any model-visible response" FAIL
fi
if grep -qF 'never copy raw console output' "$SKILL_MD" && grep -qF 'Strip query strings/fragments' "$SKILL_MD"; then
  check "P4f console/network evidence is sanitized before reporting" PASS
else
  check "P4f console/network evidence is sanitized before reporting" FAIL
fi
if grep -rqE 'jq +-r.*(token|localStorage)|TOK=.*jq|browser_evaluate.*localStorage\.setItem' "$SKILL_DIR"; then
  check "P4c no token extraction or localStorage injection recipe" FAIL
else
  check "P4c no token extraction or localStorage injection recipe" PASS
fi
if grep -qF 'Visible manual login' "$SKILL_MD" && grep -qF 'credential into chat' "$SKILL_MD"; then
  check "P4d remote/manual login stays in the visible browser" PASS
else
  check "P4d remote/manual login stays in the visible browser" FAIL
fi

# P5 — local adapter isolation, readiness, typed fixtures, and teardown.
for needle in '55432 + OFFSET' '8090 + OFFSET' 'FRONTEND_PORT="${ORIGIN##*:}"' 'pgvector/pgvector:pg17' '/api/health' '--strictPort' 'docker rm -f "$CONTAINER"'; do
  if grep -qF -- "$needle" "$RUNTIME_CONTROLLER"; then
    check "P5 local adapter pins $needle" PASS
  else
    check "P5 local adapter pins $needle" FAIL
  fi
done
if grep -qF 'Never use `pkill`' "$ZENSU_MD" \
  && grep -qF 'lease-authenticated supervisors' "$ZENSU_MD" \
  && grep -qF 'Mutable JSON' "$ZENSU_MD"; then
  check "P5a teardown is scoped to run-owned processes/resources" PASS
else
  check "P5a teardown is scoped to run-owned processes/resources" FAIL
fi
if grep -qF 'make -C backend seed' "$ZENSU_MD" && grep -qF 'without exposing the' "$ZENSU_MD"; then
  check "P5b fixture mutations prefer typed/repository-owned paths" PASS
else
  check "P5b fixture mutations prefer typed/repository-owned paths" FAIL
fi
if grep -qF '127.0.0.1:${PG_PORT}:5432' "$RUNTIME_CONTROLLER" && grep -qF 'SERVER_HOST=127.0.0.1' "$RUNTIME_CONTROLLER" \
  && grep -qF 'openssl rand -hex 24' "$RUNTIME_CONTROLLER" && grep -qF 'openssl rand -hex 32' "$RUNTIME_CONTROLLER"; then
  check "P5c local services bind loopback and use per-run DB/JWT secrets" PASS
else
  check "P5c local services bind loopback and use per-run DB/JWT secrets" FAIL
fi
if grep -qF '$(seq ' "$RUNTIME_CONTROLLER"; then
  check "P5d local adapter avoids non-portable seq dependency" FAIL
else
  check "P5d local adapter avoids non-portable seq dependency" PASS
fi
if grep -qF '[ -d "$WORKTREE/frontend/node_modules" ] || pnpm -C "$WORKTREE/frontend" install --frozen-lockfile' "$RUNTIME_CONTROLLER"; then
  check "P5e frontend dependencies install only when node_modules is absent" PASS
else
  check "P5e frontend dependencies install only when node_modules is absent" FAIL
fi
if grep -qF 'RUN_ID="$(openssl rand -hex 6)"' "$RUNTIME_CONTROLLER" \
  && grep -qF 'CONTAINER="$(expected_container "$RUN_ID")"' "$RUNTIME_CONTROLLER"; then
  check "P5f resource IDs include a per-run random component" PASS
else
  check "P5f resource IDs include a per-run random component" FAIL
fi
if grep -qF -- '--host 127.0.0.1 --port "$FRONTEND_PORT" --strictPort' "$RUNTIME_CONTROLLER"; then
  check "P5g Vite binds the same literal loopback host used by APP_ORIGIN" PASS
else
  check "P5g Vite binds the same literal loopback host used by APP_ORIGIN" FAIL
fi

# P6 — pinned lockfile-backed MCP and plugin manifest wiring.
if jq -e '.mcpServers.playwright.command == "${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh"' "$MCP_JSON" >/dev/null 2>&1 \
  && jq -e '.mcpServers.playwright.args | index("--isolated")' "$MCP_JSON" >/dev/null 2>&1 \
  && jq -e '.mcpServers.playwright.args | index("--caps=storage") | not' "$MCP_JSON" >/dev/null 2>&1 \
  && [ "$(jq -r '.dependencies["@playwright/mcp"]' "$MCP_PACKAGE")" = '0.0.75' ] \
  && jq -e '.packages["node_modules/@playwright/mcp"] | .version == "0.0.75" and (.integrity | startswith("sha512-"))' "$MCP_LOCK" >/dev/null 2>&1 \
  && grep -qF 'run_sanitized_child npm ci --prefix "$RUNTIME_GENERATION" --ignore-scripts --no-audit --no-fund' "$MCP_LAUNCHER" \
  && grep -qF 'run_sanitized_child node "$PROXY" --runtime-dir "$RUNTIME_GENERATION"' "$MCP_LAUNCHER"; then
  check "P6a Playwright MCP is pinned, integrity-locked, isolated, and brokered" PASS
else
  check "P6a Playwright MCP is pinned, integrity-locked, isolated, and brokered" FAIL
fi
PROXY_TEST_OUTPUT="$(node --test "$MCP_PROXY_TEST" 2>&1)"
PROXY_TEST_RC=$?
if [ "$PROXY_TEST_RC" = "0" ]; then
  check "P6g MCP broker exposes only the exact safe inventory and enforces navigation policy" PASS
else
  check "P6g MCP broker inventory/policy behavior (rc=$PROXY_TEST_RC, out=${PROXY_TEST_OUTPUT:0:500})" FAIL
fi
if grep -qF '@latest' "$MCP_JSON"; then
  check "P6b MCP runtime never floats on @latest" FAIL
else
  check "P6b MCP runtime never floats on @latest" PASS
fi
if grep -qF 'bash "${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}/scripts/playwright-mcp.sh" install-browser' "$SKILL_MD" \
  && grep -qF '`browser_install` is not a tool in the pinned' "$SKILL_MD" \
  && grep -qF 'run_sanitized_child "$BIN" install-browser' "$MCP_LAUNCHER"; then
  check "P6f missing browser recovery uses the pinned launcher install-browser command" PASS
else
  check "P6f missing browser recovery uses the pinned launcher install-browser command" FAIL
fi
if grep -qF 'ZENSU_MCP_TEST_MODE' "$MCP_LAUNCHER" \
  && grep -qF 'ZENSU_MCP_TEST_PASSTHROUGH' "$MCP_LAUNCHER" \
  && grep -qF 'ZENSU_MCP_RUNTIME_DIR_OVERRIDE' "$MCP_LAUNCHER" \
  && grep -qF 'test-only launcher controls are not supported' "$MCP_LAUNCHER" \
  && ! grep -qF 'RUNTIME_DIR="${ZENSU_MCP_RUNTIME_DIR_OVERRIDE' "$MCP_LAUNCHER"; then
  check "P6h production launcher rejects every former test override and passthrough" PASS
else
  check "P6h production launcher rejects every former test override and passthrough" FAIL
fi
if grep -qF 'mktemp -d' "$MCP_LAUNCHER" \
  && grep -qF 'cp "$PACKAGE_FILE" "$RUNTIME_GENERATION/package.json"' "$MCP_LAUNCHER" \
  && grep -qF 'cp "$LOCK_FILE" "$RUNTIME_GENERATION/package-lock.json"' "$MCP_LAUNCHER" \
  && grep -qF -- '--zensu-install-runtime' "$MCP_LAUNCHER" \
  && grep -qF 'materialize_runtime' "$MCP_LAUNCHER" \
  && grep -qF 'trap cleanup_runtime EXIT' "$MCP_LAUNCHER" \
  && grep -qF 'run_child' "$MCP_LAUNCHER" \
  && grep -qF '"$@" <&0 >&1 2>&2 &' "$MCP_LAUNCHER" \
  && ! grep -qF 'npm ci --prefix "$RUNTIME_DIR"' "$MCP_LAUNCHER" \
  && ! grep -qF 'INSTALL_LOCK=' "$MCP_LAUNCHER" \
  && ! grep -qF 'lockf ' "$MCP_LAUNCHER" \
  && ! grep -qF 'flock ' "$MCP_LAUNCHER" \
  && ! grep -qF '.zensu-lock-sha256' "$MCP_LAUNCHER" \
  && ! grep -qF 'needs_install' "$MCP_LAUNCHER"; then
  check "P6d every MCP start uses a signal-cleaned per-invocation runtime generation without shared install state" PASS
else
  check "P6d every MCP start uses a signal-cleaned per-invocation runtime generation without shared install state" FAIL
fi

ISO_TEST_DIR="$(mktemp -d -t zensu-mcp-isolated-XXXXXX)"
ISO_TEST_PLUGIN="$ISO_TEST_DIR/plugin"
ISO_TEST_RUNTIME="$ISO_TEST_PLUGIN/mcp-runtime"
ISO_TEST_SCRIPTS="$ISO_TEST_PLUGIN/scripts"
ISO_TEST_LAUNCHER="$ISO_TEST_SCRIPTS/playwright-mcp.sh"
ISO_TEST_BIN="$ISO_TEST_DIR/bin"
ISO_TEST_CALLS="$ISO_TEST_DIR/npm-prefixes"
ISO_TEST_READY="$ISO_TEST_DIR/a-ready"
ISO_TEST_RELEASE="$ISO_TEST_DIR/a-release"
ISO_TEST_SIGNAL_READY="$ISO_TEST_DIR/signal-ready"
ISO_TEST_SIGNAL_SEEN="$ISO_TEST_DIR/signal-seen"
ISO_TEST_WINDOWS=false
case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*) ISO_TEST_WINDOWS=true ;;
esac
mkdir -p "$ISO_TEST_RUNTIME" "$ISO_TEST_SCRIPTS" "$ISO_TEST_BIN"
cp "$MCP_LAUNCHER" "$ISO_TEST_LAUNCHER"
chmod +x "$ISO_TEST_LAUNCHER"
printf '{"name":"isolated-fixture","private":true}\n' >"$ISO_TEST_RUNTIME/package.json"
printf '{"name":"isolated-fixture","lockfileVersion":3}\n' >"$ISO_TEST_RUNTIME/package-lock.json"
mkdir -p "$ISO_TEST_RUNTIME/node_modules/.bin" "$ISO_TEST_RUNTIME/node_modules/@playwright/mcp"
cat >"$ISO_TEST_RUNTIME/node_modules/.bin/playwright-mcp" <<'MCP_TAMPERED'
#!/bin/bash
echo "TAMPERED-RUNTIME $*"
MCP_TAMPERED
chmod +x "$ISO_TEST_RUNTIME/node_modules/.bin/playwright-mcp"
printf 'tampered\n' >"$ISO_TEST_RUNTIME/node_modules/@playwright/mcp/tampered.txt"
cat >"$ISO_TEST_SCRIPTS/playwright-mcp-proxy.js" <<'PROXY_STUB'
#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
if (args[0] !== '--runtime-dir' || !args[1]) process.exit(80);
const runtime = args[1];
const command = args[2] || '';
const dependency = path.join(runtime, 'node_modules', '@playwright', 'mcp', 'dependency.txt');
if (command === 'hold') {
  const before = fs.readFileSync(dependency, 'utf8').trim();
  process.stdout.write(`before:${before}\n`);
  fs.writeFileSync(args[3], 'ready\n');
  while (!fs.existsSync(args[4])) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  const after = fs.readFileSync(dependency, 'utf8').trim();
  process.stdout.write(`after:${after}\n`);
  process.exit(before === after ? 0 : 1);
}
if (command === 'probe') {
  process.stdout.write(`probe:${fs.readFileSync(dependency, 'utf8').trim()}\n`);
  process.exit(0);
}
if (command === 'stdio') {
  process.stdout.write(`stdio:${fs.readFileSync(0, 'utf8').trim()}\n`);
  process.exit(0);
}
if (command === 'signal') {
  process.on('SIGTERM', () => {
    fs.writeFileSync(args[4], 'seen\n');
    process.exit(143);
  });
  fs.writeFileSync(args[3], `${process.pid}\n`);
  setInterval(() => {}, 50);
} else {
  process.exit(0);
}
PROXY_STUB
cat >"$ISO_TEST_BIN/npm" <<'NPM_STUB'
#!/bin/bash
set -euo pipefail
fixture_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source_runtime="$fixture_root/plugin/mcp-runtime"
calls_file="$fixture_root/npm-prefixes"
[ "${1:-}" = "ci" ] || exit 81
prefix=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then prefix="$2"; shift 2; else shift; fi
done
[ "$prefix" != "$source_runtime" ] || exit 82
cmp "$prefix/package.json" "$source_runtime/package.json" >/dev/null || exit 83
cmp "$prefix/package-lock.json" "$source_runtime/package-lock.json" >/dev/null || exit 84
printf '%s\n' "$prefix" >>"$calls_file"
mkdir -p "$prefix/node_modules/.bin" "$prefix/node_modules/@playwright/mcp"
basename "$prefix" >"$prefix/node_modules/@playwright/mcp/dependency.txt"
cat >"$prefix/node_modules/.bin/playwright-mcp" <<'MCP_STUB'
#!/bin/bash
set -euo pipefail
dependency="$(cd "$(dirname "$0")/../@playwright/mcp" && pwd)/dependency.txt"
case "${1:-}" in
  hold)
    before="$(cat "$dependency")"
    printf 'before:%s\n' "$before"
    : >"$2"
    while [ ! -f "$3" ]; do sleep 0.02; done
    after="$(cat "$dependency")"
    printf 'after:%s\n' "$after"
    [ "$before" = "$after" ]
    ;;
  probe)
    printf 'probe:%s\n' "$(cat "$dependency")"
    ;;
  stdio)
    IFS= read -r line
    printf 'stdio:%s\n' "$line"
    ;;
  signal)
    trap ': >"$3"; exit 143' HUP INT TERM
    : >"$2"
    while :; do sleep 0.05; done
    ;;
  *) printf 'trusted-playwright-mcp %s\n' "$*" ;;
esac
MCP_STUB
chmod +x "$prefix/node_modules/.bin/playwright-mcp"
NPM_STUB
chmod +x "$ISO_TEST_BIN/npm"
export ISO_TEST_RUNTIME ISO_TEST_CALLS
PATH="$ISO_TEST_BIN:$PATH" "$ISO_TEST_LAUNCHER" hold "$ISO_TEST_READY" "$ISO_TEST_RELEASE" >"$ISO_TEST_DIR/a.out" 2>"$ISO_TEST_DIR/a.err" &
ISO_TEST_PID_A=$!
ISO_TEST_WAIT=0
while [ ! -f "$ISO_TEST_READY" ] && [ "$ISO_TEST_WAIT" -lt 250 ]; do sleep 0.02; ISO_TEST_WAIT=$((ISO_TEST_WAIT+1)); done
PATH="$ISO_TEST_BIN:$PATH" "$ISO_TEST_LAUNCHER" probe >"$ISO_TEST_DIR/b.out" 2>"$ISO_TEST_DIR/b.err"
ISO_TEST_RC_B=$?
kill -0 "$ISO_TEST_PID_A" 2>/dev/null; ISO_TEST_A_ALIVE_DURING_B=$?
: >"$ISO_TEST_RELEASE"
wait "$ISO_TEST_PID_A"; ISO_TEST_RC_A=$?
ISO_TEST_BEFORE="$(sed -n 's/^before://p' "$ISO_TEST_DIR/a.out")"
ISO_TEST_AFTER="$(sed -n 's/^after://p' "$ISO_TEST_DIR/a.out")"
ISO_TEST_PREFIX_COUNT="$(wc -l <"$ISO_TEST_CALLS" | tr -d ' ')"
ISO_TEST_GENERATIONS_GONE=true
while IFS= read -r prefix; do
  case "$prefix" in "$ISO_TEST_RUNTIME"|"$ISO_TEST_RUNTIME"/*) ISO_TEST_GENERATIONS_GONE=false ;; esac
  [ ! -e "$prefix" ] || ISO_TEST_GENERATIONS_GONE=false
done <"$ISO_TEST_CALLS"
if [ "$ISO_TEST_RC_A" = "0" ] && [ "$ISO_TEST_RC_B" = "0" ] \
  && [ "$ISO_TEST_A_ALIVE_DURING_B" = "0" ] \
  && [ "$ISO_TEST_PREFIX_COUNT" = "2" ] \
  && [ -n "$ISO_TEST_BEFORE" ] && [ "$ISO_TEST_BEFORE" = "$ISO_TEST_AFTER" ] \
  && [ "$ISO_TEST_GENERATIONS_GONE" = "true" ] \
  && [ -e "$ISO_TEST_RUNTIME/node_modules/@playwright/mcp/tampered.txt" ] \
  && grep -qF 'probe:' "$ISO_TEST_DIR/b.out" \
  && ! grep -qF 'TAMPERED-RUNTIME' "$ISO_TEST_DIR/a.out" \
  && ! grep -qF 'TAMPERED-RUNTIME' "$ISO_TEST_DIR/b.out"; then
  check "P6e A keeps its isolated dependency while B materializes; both generations clean up and shared tampering is ignored" PASS
else
  check "P6e A keeps its isolated dependency while B materializes; both generations clean up and shared tampering is ignored" FAIL
fi

printf 'inherited-input\n' | PATH="$ISO_TEST_BIN:$PATH" "$ISO_TEST_LAUNCHER" stdio >"$ISO_TEST_DIR/stdio.out" 2>"$ISO_TEST_DIR/stdio.err"
ISO_TEST_STDIO_RC=$?
ISO_TEST_STDIO_PREFIX="$(tail -n 1 "$ISO_TEST_CALLS")"
if [ "$ISO_TEST_STDIO_RC" = "0" ] \
  && grep -qxF 'stdio:inherited-input' "$ISO_TEST_DIR/stdio.out" \
  && [ ! -e "$ISO_TEST_STDIO_PREFIX" ]; then
  check "P6k isolated runtime child inherits stdin/stdout/stderr and cleans after EOF" PASS
else
  check "P6k isolated runtime child inherits stdin/stdout/stderr and cleans after EOF" FAIL
fi

PATH="$ISO_TEST_BIN:$PATH" "$ISO_TEST_LAUNCHER" signal "$ISO_TEST_SIGNAL_READY" "$ISO_TEST_SIGNAL_SEEN" >"$ISO_TEST_DIR/signal.out" 2>"$ISO_TEST_DIR/signal.err" &
ISO_TEST_SIGNAL_PID=$!
ISO_TEST_WAIT=0
while [ ! -f "$ISO_TEST_SIGNAL_READY" ] && [ "$ISO_TEST_WAIT" -lt 250 ]; do sleep 0.02; ISO_TEST_WAIT=$((ISO_TEST_WAIT+1)); done
ISO_TEST_SIGNAL_PREFIX="$(tail -n 1 "$ISO_TEST_CALLS")"
ISO_TEST_SIGNAL_CHILD_PID=""
if [ -f "$ISO_TEST_SIGNAL_READY" ]; then
  ISO_TEST_SIGNAL_CHILD_PID="$(tr -d '\r\n' <"$ISO_TEST_SIGNAL_READY")"
fi
kill -TERM "$ISO_TEST_SIGNAL_PID" 2>/dev/null || true
wait "$ISO_TEST_SIGNAL_PID" 2>/dev/null; ISO_TEST_SIGNAL_RC=$?
ISO_TEST_SIGNAL_CHILD_GONE=false
case "$ISO_TEST_SIGNAL_CHILD_PID" in
  ''|*[!0-9]*) ;;
  *)
    if node -e '
      const pid = Number(process.argv[1]);
      try {
        process.kill(pid, 0);
        process.exit(1);
      } catch (error) {
        if (error && error.code === "ESRCH") process.exit(0);
        throw error;
      }
    ' "$ISO_TEST_SIGNAL_CHILD_PID"; then
      ISO_TEST_SIGNAL_CHILD_GONE=true
    fi
    ;;
esac
ISO_TEST_SIGNAL_OBSERVED=false
if [ -e "$ISO_TEST_SIGNAL_SEEN" ] || [ "$ISO_TEST_WINDOWS" = "true" ]; then
  # Node documents SIGTERM as an unconditional termination on Windows; its
  # JavaScript SIGTERM listener is therefore not a portable observation point.
  ISO_TEST_SIGNAL_OBSERVED=true
fi
if [ "$ISO_TEST_SIGNAL_RC" != "0" ] \
  && [ "$ISO_TEST_SIGNAL_CHILD_GONE" = "true" ] \
  && [ "$ISO_TEST_SIGNAL_OBSERVED" = "true" ] \
  && [ ! -e "$ISO_TEST_SIGNAL_PREFIX" ]; then
  check "P6j TERM stops the runtime child, is observed where supported, and cleans its generation" PASS
else
  check "P6j TERM stops the runtime child, is observed where supported, and cleans its generation" FAIL
fi
rm -rf "$ISO_TEST_DIR"
if jq -e '.skills | index("./skills/verify-feature")' "$PLUGIN_JSON" >/dev/null 2>&1 \
  && [ "$(jq -r '.mcpServers' "$PLUGIN_JSON" 2>/dev/null)" = './.mcp.json' ]; then
  check "P6c plugin manifest registers skill and MCP file" PASS
else
  check "P6c plugin manifest registers skill and MCP file" FAIL
fi
if grep -qF 'per-invocation runtime generation' "$MCP_RUNTIME_DOC" \
  && grep -qF 'outside the plugin root' "$MCP_RUNTIME_DOC" \
  && grep -qF 'signal-safe' "$MCP_RUNTIME_DOC" \
  && grep -qF 'No executable, dependency tree, or' "$MCP_RUNTIME_DOC" \
  && grep -qF 'shared `mcp-runtime/node_modules`' "$MCP_RUNTIME_DOC" \
  && grep -qF '`--check-policy`' "$MCP_RUNTIME_DOC" \
  && grep -qF 'normal npm content cache' "$MCP_RUNTIME_DOC"; then
  check "P6i runtime lifecycle documents isolated generations, cleanup, trust, preflight, and cache behavior" PASS
else
  check "P6i runtime lifecycle documents isolated generations, cleanup, trust, preflight, and cache behavior" FAIL
fi

# P7 — docs/help/doctor are synchronized.
if grep -qF '| `/zensu:verify-feature` |' "$README_MD"; then
  check "P7a README documents the verify-feature command" PASS
else
  check "P7a README documents the verify-feature command" FAIL
fi
if grep -qF 'skills/verify-feature/SKILL.md' "$HELP_MD" && grep -qF '/zensu:cover' "$HELP_MD"; then
  check "P7b help routes live verification and durable test authoring separately" PASS
else
  check "P7b help routes live verification and durable test authoring separately" FAIL
fi
if grep -qF 'playwright_mcp_declared' "$DOCTOR_SH" && grep -qF 'ZDOC_PLAYWRIGHT=configured' "$DOCTOR_SH" \
  && grep -qF 'valid integrity-locked plugin config + npm present' "$DOCTOR_REPORT" \
  && grep -qF 'ZDOC_PLAYWRIGHT_TOOLS=ready bash "$ROOT/hooks/lib/zensu-doctor.sh"' "$DOCTOR_SKILL" \
  && grep -qF 'Session Control: plugin root unavailable or invalid' "$DOCTOR_SKILL"; then
  check "P7c doctor validates config without claiming unproven MCP readiness" PASS
else
  check "P7c doctor validates config without claiming unproven MCP readiness" FAIL
fi
if grep -qF 'The plugin `.mcp.json` contains only the local Playwright driver' "$README_MD"; then
  check "P7d self-hosting docs distinguish Playwright MCP config from the Zensu API host" PASS
else
  check "P7d self-hosting docs distinguish Playwright MCP config from the Zensu API host" FAIL
fi

# P8 — portable/plugin-bundled text only.
if grep -rqF '~/.claude/skills' "$SKILL_DIR" || grep -rqF '~/.agents/skills' "$SKILL_DIR"; then
  check "P8a no personal skill-home dependency" FAIL
else
  check "P8a no personal skill-home dependency" PASS
fi
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
  check "P8b tracked skill content is English-only" FAIL
else
  check "P8b tracked skill content is English-only" PASS
fi
if grep -qF 'bash "${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}/scripts/playwright-mcp.sh" --check-policy' "$SKILL_MD" \
  && grep -qF '${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}/skills/verify-feature/scripts/zensu-monorepo-runtime.sh' "$ZENSU_MD" \
  && grep -qF 'bash "${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}/scripts/playwright-mcp.sh" --check-policy' "$ZENSU_MD" \
  && ! grep -qF '{ACTIVE_PLUGIN_ROOT}' "$SKILL_MD" \
  && ! grep -qF '{ACTIVE_PLUGIN_ROOT}' "$ZENSU_MD" \
  && ! grep -qF '${CLAUDE_PLUGIN_ROOT}' "$SKILL_MD" \
  && ! grep -qF '${CLAUDE_PLUGIN_ROOT}' "$ZENSU_MD"; then
  check "P8c skill and adapter use the fail-closed session-bound plugin root" PASS
else
  check "P8c skill and adapter use the fail-closed session-bound plugin root" FAIL
fi

echo "----"
echo "test-verify-feature-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
