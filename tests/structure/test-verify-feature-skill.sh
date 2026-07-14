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

for f in "$SKILL_MD" "$BROWSER_MD" "$ZENSU_MD" "$MCP_JSON" "$MCP_PACKAGE" "$MCP_LOCK" "$MCP_LAUNCHER" "$MCP_PROXY" "$MCP_PROXY_TEST" "$RUNTIME_CONTROLLER" "$PLUGIN_JSON" \
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
  && grep -qF 'npm ci --prefix "$RUNTIME_DIR" --ignore-scripts --no-audit --no-fund' "$MCP_LAUNCHER" \
  && grep -qF 'exec node "$PROXY" --runtime-dir "$RUNTIME_DIR"' "$MCP_LAUNCHER"; then
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
if grep -qF 'bash {PLUGIN_ROOT}/scripts/playwright-mcp.sh install-browser' "$SKILL_MD" \
  && grep -qF '`browser_install` is not a tool in the pinned' "$SKILL_MD" \
  && grep -qF 'exec "$BIN" "$@"' "$MCP_LAUNCHER"; then
  check "P6f missing browser recovery uses the pinned launcher install-browser command" PASS
else
  check "P6f missing browser recovery uses the pinned launcher install-browser command" FAIL
fi
if grep -qF 'ZENSU_MCP_TEST_MODE' "$MCP_LAUNCHER" \
  && grep -qF 'ZENSU_MCP_TEST_PASSTHROUGH' "$MCP_LAUNCHER" \
  && ! grep -qF 'RUNTIME_DIR="${ZENSU_MCP_RUNTIME_DIR_OVERRIDE' "$MCP_LAUNCHER"; then
  check "P6h runtime override is available only behind explicit test mode" PASS
else
  check "P6h runtime override is available only behind explicit test mode" FAIL
fi
if grep -qF 'INSTALL_LOCK="$RUNTIME_DIR/.install.lock"' "$MCP_LAUNCHER" \
  && grep -qF 'lockf -k "$INSTALL_LOCK"' "$MCP_LAUNCHER" \
  && grep -qF 'flock "$INSTALL_LOCK"' "$MCP_LAUNCHER" \
  && grep -qF -- '--zensu-install-runtime' "$MCP_LAUNCHER" \
  && grep -qF 'install_if_needed' "$MCP_LAUNCHER" \
  && grep -qF 'released automatically' "$MCP_LAUNCHER"; then
  check "P6d concurrent MCP starts use an auto-released kernel lock and re-check install state" PASS
else
  check "P6d concurrent MCP starts use an auto-released kernel lock and re-check install state" FAIL
fi

LOCK_TEST_DIR="$(mktemp -d -t zensu-mcp-lock-XXXXXX)"
LOCK_TEST_RUNTIME="$LOCK_TEST_DIR/runtime"
LOCK_TEST_BIN="$LOCK_TEST_DIR/bin"
LOCK_TEST_CALLS="$LOCK_TEST_DIR/npm-calls"
mkdir -p "$LOCK_TEST_RUNTIME" "$LOCK_TEST_BIN"
printf '{}\n' >"$LOCK_TEST_RUNTIME/package.json"
printf '{"lockfileVersion":3}\n' >"$LOCK_TEST_RUNTIME/package-lock.json"
printf 'abandoned-file-is-inert\n' >"$LOCK_TEST_RUNTIME/.install.lock"
cat >"$LOCK_TEST_BIN/npm" <<'NPM_STUB'
#!/bin/bash
set -e
prefix=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then prefix="$2"; shift 2; else shift; fi
done
printf 'npm-ci\n' >>"$LOCK_TEST_CALLS"
sleep 0.2
mkdir -p "$prefix/node_modules/.bin"
cat >"$prefix/node_modules/.bin/playwright-mcp" <<'MCP_STUB'
#!/bin/bash
echo "stub-playwright-mcp $*"
MCP_STUB
chmod +x "$prefix/node_modules/.bin/playwright-mcp"
NPM_STUB
chmod +x "$LOCK_TEST_BIN/npm"
export LOCK_TEST_CALLS
ZENSU_MCP_TEST_MODE=1 ZENSU_MCP_TEST_PASSTHROUGH=1 ZENSU_MCP_RUNTIME_DIR_OVERRIDE="$LOCK_TEST_RUNTIME" PATH="$LOCK_TEST_BIN:$PATH" "$MCP_LAUNCHER" --help >"$LOCK_TEST_DIR/one.out" 2>"$LOCK_TEST_DIR/one.err" &
LOCK_TEST_PID_ONE=$!
ZENSU_MCP_TEST_MODE=1 ZENSU_MCP_TEST_PASSTHROUGH=1 ZENSU_MCP_RUNTIME_DIR_OVERRIDE="$LOCK_TEST_RUNTIME" PATH="$LOCK_TEST_BIN:$PATH" "$MCP_LAUNCHER" --version >"$LOCK_TEST_DIR/two.out" 2>"$LOCK_TEST_DIR/two.err" &
LOCK_TEST_PID_TWO=$!
wait "$LOCK_TEST_PID_ONE"; LOCK_TEST_RC_ONE=$?
wait "$LOCK_TEST_PID_TWO"; LOCK_TEST_RC_TWO=$?
LOCK_TEST_NPM_COUNT="$(wc -l <"$LOCK_TEST_CALLS" | tr -d ' ')"
if [ "$LOCK_TEST_RC_ONE" = "0" ] && [ "$LOCK_TEST_RC_TWO" = "0" ] \
  && [ "$LOCK_TEST_NPM_COUNT" = "1" ] \
  && [ -f "$LOCK_TEST_RUNTIME/.install.lock" ] \
  && grep -qF 'stub-playwright-mcp' "$LOCK_TEST_DIR/one.out" \
  && grep -qF 'stub-playwright-mcp' "$LOCK_TEST_DIR/two.out"; then
  check "P6e concurrent launchers ignore an inert lock file and execute exactly one install" PASS
else
  check "P6e concurrent launchers ignore an inert lock file and execute exactly one install" FAIL
fi
rm -rf "$LOCK_TEST_DIR"
if jq -e '.skills | index("./skills/verify-feature")' "$PLUGIN_JSON" >/dev/null 2>&1 \
  && [ "$(jq -r '.mcpServers' "$PLUGIN_JSON" 2>/dev/null)" = './.mcp.json' ]; then
  check "P6c plugin manifest registers skill and MCP file" PASS
else
  check "P6c plugin manifest registers skill and MCP file" FAIL
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
  && grep -qF 'ZDOC_PLAYWRIGHT_TOOLS=ready bash {PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh' "$DOCTOR_SKILL"; then
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

echo "----"
echo "test-verify-feature-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
