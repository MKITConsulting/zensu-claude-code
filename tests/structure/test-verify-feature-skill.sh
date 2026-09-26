#!/bin/bash
set -u

# zensu-doctor-home-exempt: this suite never RUNS the doctor. It greps
# skills/doctor/SKILL.md for the wrapper invocation line, so no renderer
# process is started and no HOME is resolved.
# Structure test for /zensu:verify-feature.
# Pins the public command, self-contained browser loop, isolated Zensu local adapter,
# credential-blind auth contract, evidence/verdict gates, playwright-cli command set,
# plugin registration, and user-facing documentation. No browser or network is launched.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/verify-feature"
SKILL_MD="$SKILL_DIR/SKILL.md"
BROWSER_MD="$SKILL_DIR/rules/browser-verification.md"
ZENSU_MD="$SKILL_DIR/rules/zensu-monorepo.md"
SETUP_MD="$SKILL_DIR/rules/setup.md"
CONSENT_MODULE="$PLUGIN_DIR/hooks/lib/verify-consent-v1.js"
FLOOR_MODULE="$PLUGIN_DIR/hooks/lib/verify-navigation-floor-v1.js"
BROWSER_CONFIG="$PLUGIN_DIR/scripts/verify-browser-config.js"
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

for f in "$SKILL_MD" "$BROWSER_MD" "$ZENSU_MD" "$SETUP_MD" "$CONSENT_MODULE" "$FLOOR_MODULE" "$BROWSER_CONFIG" \
  "$RUNTIME_CONTROLLER" "$PLUGIN_JSON" "$README_MD" "$HELP_MD" "$DOCTOR_SH" "$DOCTOR_REPORT" "$DOCTOR_SKILL" \
  "$AUTOPILOT_SKILL" "$AUTOPILOT_AUTH" "$AUTOPILOT_CONFIG"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-verify-feature-skill: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all skill, consent-gate, registration, and documentation files exist" PASS

SKILL_FLAT="$(tr '\n' ' ' < "$SKILL_MD" | tr -s ' ')"
BROWSER_FLAT="$(tr '\n' ' ' < "$BROWSER_MD" | tr -s ' ')"
SETUP_FLAT="$(tr '\n' ' ' < "$SETUP_MD" | tr -s ' ')"
README_FLAT="$(tr '\n' ' ' < "$README_MD" | tr -s ' ')"

CONSENT_FACTS="$(node -e '
  const mod = require(process.argv[1]);
  process.stdout.write([mod.PLAYWRIGHT_CLI_SOURCE_VERSION, mod.SESSION_PREFIX, mod.SESSION_ENV].map((value) => String(value || "")).join("|"));
' "$CONSENT_MODULE" 2>/dev/null)"
IFS='|' read -r PW_MEASURED CONSENT_SESSION_PREFIX CONSENT_SESSION_ENV <<<"$CONSENT_FACTS"
if [ -n "${PW_MEASURED:-}" ] && [ -n "${CONSENT_SESSION_PREFIX:-}" ] && [ -n "${CONSENT_SESSION_ENV:-}" ]; then
  check "P0a the consent module yields its measured playwright-cli version ($PW_MEASURED), session prefix and session variable" PASS
else
  check "P0a the consent module yields its measured playwright-cli version, session prefix and session variable (facts=$CONSENT_FACTS)" FAIL
fi
PW_STUB_BIN="$(mktemp -d "${TMPDIR:-/tmp}/zensu-vfs-cli.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
trap 'rm -rf -- "$PW_STUB_BIN"' EXIT
mkdir -p "$PW_STUB_BIN/node_modules/@playwright/cli"
printf '#!/bin/sh\nexit 0\n' > "$PW_STUB_BIN/playwright-cli"
chmod 755 "$PW_STUB_BIN/playwright-cli"
printf '{"name":"@playwright/cli","version":"%s"}\n' "${PW_MEASURED:-}" > "$PW_STUB_BIN/node_modules/@playwright/cli/package.json"
PW_STUB_READ="$(PATH="$PW_STUB_BIN:$PATH" node -e 'const v = require(process.argv[1]).installedVersion(process.env); process.stdout.write(v.source + " " + v.version)' "$PLUGIN_DIR/hooks/lib/playwright-cli-version-v1.js" 2>/dev/null)"
if [ -n "${PW_MEASURED:-}" ] && [ "$PW_STUB_READ" = "manifest $PW_MEASURED" ]; then
  check "P0b the stub playwright-cli every --check-policy call puts first on PATH reads as the measured version ($PW_MEASURED)" PASS
else
  check "P0b the stub playwright-cli every --check-policy call puts first on PATH reads as the measured version (got: ${PW_STUB_READ:-<none>})" FAIL
fi

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
TABLE_VERDICT="$(node -e '
  const fs = require("node:fs");
  const mod = require(process.argv[2]);
  const allowed = mod.ALLOWED_COMMANDS || {};
  const text = fs.readFileSync(process.argv[1], "utf8");
  const start = text.indexOf("## 0. The command set on a `zensu-verify` session");
  const end = start === -1 ? -1 : text.indexOf("\n## ", start + 1);
  if (start === -1 || end === -1) { process.stdout.write("command-set section not found"); process.exit(1); }
  const section = text.slice(start, end);
  const spans = (cell) => Array.from(cell.matchAll(/`([^`]+)`/g), (match) => match[1]);
  const flagsOf = (part) => spans(part).filter((span) => span.startsWith("--")).map((span) => span.slice(2).split(/[=\s<]/)[0]);
  const documented = new Map();
  const problems = [];
  for (const line of section.split("\n")) {
    if (!line.startsWith("|")) continue;
    const cells = line.split("|").slice(1, -1).map((cell) => cell.trim());
    if (cells.length !== 3 || cells[0] === "Purpose" || /^-+$/.test(cells[0])) continue;
    const rowCommands = [];
    for (const span of spans(cells[1])) {
      const name = span.split(/\s+/)[0];
      if (name === "clear-*") {
        for (const other of rowCommands.slice()) if (other.startsWith("set-")) rowCommands.push("clear-" + other.slice(4));
      } else {
        rowCommands.push(name);
      }
    }
    for (const name of rowCommands) {
      if (documented.has(name)) problems.push(name + " is listed twice");
      documented.set(name, new Set());
    }
    for (const segment of cells[2].split(";")) {
      const colon = segment.indexOf(":");
      if (colon === -1) {
        if (flagsOf(segment).length > 0) problems.push("a flag is documented without its command");
        continue;
      }
      const flags = flagsOf(segment.slice(colon + 1));
      for (const owner of spans(segment.slice(0, colon))) {
        if (!rowCommands.includes(owner)) { problems.push(owner + " has flags documented outside its row"); continue; }
        for (const flag of flags) documented.get(owner).add(flag);
      }
    }
  }
  const keys = Object.keys(allowed);
  if (keys.length === 0) problems.push("the module exports no commands");
  for (const key of keys) {
    if (!documented.has(key)) { problems.push(key + " is missing from the table"); continue; }
    const expected = Array.from(allowed[key]).sort().join(",");
    const got = Array.from(documented.get(key)).sort().join(",");
    if (expected !== got) problems.push(key + " flags differ: table [" + got + "] module [" + expected + "]");
  }
  for (const name of documented.keys()) {
    if (!Object.prototype.hasOwnProperty.call(allowed, name)) problems.push(name + " is not a gate command");
  }
  if (problems.length > 0) { process.stdout.write(problems.join("; ")); process.exit(1); }
  process.stdout.write(String(keys.length));
' "$BROWSER_MD" "$CONSENT_MODULE" 2>&1)"
TABLE_RC=$?
if [ "$TABLE_RC" = "0" ] && [ -n "$TABLE_VERDICT" ]; then
  check "P3f the browser rule command table names exactly the gate's $TABLE_VERDICT commands, each with its own flags" PASS
else
  check "P3f the browser rule command table names exactly the gate's commands, each with its own flags ($TABLE_VERDICT)" FAIL
fi
DENY_VERDICT="$(node -e '
  const fs = require("node:fs");
  const mod = require(process.argv[2]);
  const allowed = mod.ALLOWED_COMMANDS || {};
  const text = fs.readFileSync(process.argv[1], "utf8");
  const start = text.indexOf("Everything else is");
  const end = start === -1 ? -1 : text.indexOf("Never re-issue a denied call", start);
  if (start === -1 || end === -1) { process.stdout.write("deny list not found"); process.exit(1); }
  const listed = new Set(Array.from(text.slice(start, end).matchAll(/`([^`]+)`/g), (match) => match[1]));
  const problems = [];
  const commands = ["eval", "run-code", "delete-data", "route", "request", "network-state-set", "upload", "drop", "pdf",
    "attach", "detach", "install", "install-browser", "close-all", "kill-all"];
  for (const name of commands) {
    if (!listed.has(name)) problems.push(name + " is not in the deny list");
    if (Object.prototype.hasOwnProperty.call(allowed, name)) problems.push(name + " is a gate command");
  }
  const gateFlags = Object.values(allowed).flatMap((list) => Array.from(list));
  for (const flag of ["filename", "persistent", "profile"]) {
    if (!listed.has("--" + flag)) problems.push("--" + flag + " is not in the deny list");
    if (gateFlags.includes(flag)) problems.push("--" + flag + " is a gate flag");
  }
  const family = /cookie|storage|state|route|request-|response-|network-|video|trac|record|pdf|upload|eval|run-code|install|attach|detach|delete|kill|close-all/;
  for (const key of Object.keys(allowed)) {
    if (family.test(key)) problems.push(key + " belongs to a denied family");
  }
  if (problems.length > 0) { process.stdout.write(problems.join("; ")); process.exit(1); }
' "$BROWSER_MD" "$CONSENT_MODULE" 2>&1)"
DENY_RC=$?
if [ "$DENY_RC" = "0" ]; then
  check "P3g the deny list names every denied command and flag, and none of them is a gate command" PASS
else
  check "P3g the deny list names every denied command and flag, and none of them is a gate command ($DENY_VERDICT)" FAIL
fi
if grep -qF '`--json`, `--raw`, `--help` and `--version` are accepted on every command.' "$BROWSER_MD" \
  && grep -qF 'A flag given twice is denied too.' "$BROWSER_MD" \
  && grep -qF 'Run each call as its own plain Bash command on the main thread: exactly one `playwright-cli` call per Bash command, with no other command, operator, pipe, substitution, wrapper or package launcher around it. Quote an argument that carries `?`, `*`, `[` or `{`, or that starts with `~` or `=`.' <<<"$BROWSER_FLAT"; then
  check "P3h harmless flags, repeated flags, and plain main-thread calls are pinned in the browser rule" PASS
else
  check "P3h harmless flags, repeated flags, and plain main-thread calls are pinned in the browser rule" FAIL
fi
DOLLAR_RULE='Single-quote an argument that carries `$`: double quotes do not help'
if grep -qF "$DOLLAR_RULE" <<<"$BROWSER_FLAT" && grep -qF "$DOLLAR_RULE" <<<"$SKILL_FLAT"; then
  check "P3i the browser rule and the skill both state that an argument carrying \$ is single-quoted" PASS
else
  check "P3i the browser rule and the skill both state that an argument carrying \$ is single-quoted" FAIL
fi
DOLLAR_EXCEPTION='the gate reads a `$` outside single quotes as an expansion it cannot judge unless whitespace, the end of the command or a closing double quote follows it'
if grep -qF "$DOLLAR_EXCEPTION" <<<"$BROWSER_FLAT" && grep -qF "$DOLLAR_EXCEPTION" <<<"$SKILL_FLAT" \
  && ! grep -qF 'that whitespace or the end of the command does not follow' <<<"$BROWSER_FLAT" \
  && ! grep -qF 'that whitespace or the end of the command does not follow' <<<"$SKILL_FLAT"; then
  check "P3k the browser rule and the skill both exempt a \$ before a closing double quote from the expansion rule" PASS
else
  check "P3k the browser rule and the skill both exempt a \$ before a closing double quote from the expansion rule" FAIL
fi
AUTOPILOT_CONFIG_FLAT="$(tr '\n' ' ' < "$AUTOPILOT_CONFIG" | tr -s ' ')"
if grep -qF 'It is a textual gate: it judges the calls whose command text names the CLI and that session, which is one more reason every call spells both literally.' <<<"$SKILL_FLAT" \
  && grep -qF 'the Bash-matcher hook pair that judges each `playwright-cli` call whose command text names the CLI and a `zensu-verify` session, or names the CLI while the hook environment'"'"'s `PLAYWRIGHT_CLI_SESSION` names one' <<<"$AUTOPILOT_CONFIG_FLAT" \
  && ! grep -qF 'judges every `playwright-cli` call' <<<"$SKILL_FLAT" \
  && ! grep -qF 'judges every `playwright-cli` call' <<<"$AUTOPILOT_CONFIG_FLAT"; then
  check "P3l the skill and the autopilot config rule say the gate judges the command text, not every call" PASS
else
  check "P3l the skill and the autopilot config rule say the gate judges the command text, not every call" FAIL
fi
SHAPE_VERDICT="$(node -e '
  const fs = require("node:fs");
  const mod = require(process.argv[2]);
  const reasons = mod.REASONS || {};
  const text = fs.readFileSync(process.argv[1], "utf8").replace(/\s+/g, " ");
  const problems = [];
  const finalSentence = "A command or flag that is not available, an origin outside the run config or the navigation policy, a refused or unanswerable consent prompt, and a call from a subagent are final.";
  if (!text.includes(finalSentence)) problems.push("the final-denial sentence is missing");
  const start = text.indexOf("A shape denial objects only to how the call is spelled");
  const end = start === -1 ? -1 : text.indexOf("a second denial of that call is final", start);
  if (start === -1 || end === -1) {
    problems.push("the shape-denial passage is missing");
  } else {
    const passage = text.slice(start, end);
    const named = Array.from(passage.matchAll(/`([A-Z][A-Z_]+)`/g), (match) => match[1]);
    for (const key of named) {
      if (!Object.prototype.hasOwnProperty.call(reasons, key)) problems.push(key + " is not a REASONS key");
    }
    const shapeKeys = Array.isArray(mod.SHAPE_REASONS) ? mod.SHAPE_REASONS : [];
    const finalKeys = Array.isArray(mod.FINAL_REASONS) ? mod.FINAL_REASONS : [];
    if (shapeKeys.length === 0 || finalKeys.length === 0) problems.push("the module exports no SHAPE_REASONS or FINAL_REASONS");
    for (const key of Object.keys(reasons)) {
      if (shapeKeys.includes(key) === finalKeys.includes(key)) problems.push(key + " is not in exactly one class");
    }
    for (const key of shapeKeys) {
      if (!named.includes(key)) problems.push(key + " is not named as a shape denial");
    }
    for (const key of finalKeys) {
      if (named.includes(key)) problems.push(key + " is final but named as a shape denial");
    }
    if (typeof mod.SHAPE_MARKER !== "string" || !passage.includes(mod.SHAPE_MARKER)) {
      problems.push("the passage does not quote the note the gate appends to a shape denial");
    }
    if (!passage.includes("Answer a shape denial once: re-issue the same call as one plain call with single-quoted literal arguments.")) {
      problems.push("the one-retry instruction is missing");
    }
  }
  if (problems.length > 0) { process.stdout.write(problems.join("; ")); process.exit(1); }
' "$BROWSER_MD" "$CONSENT_MODULE" 2>&1)"
SHAPE_RC=$?
if [ "$SHAPE_RC" = "0" ]; then
  check "P3j a shape denial is answered once by a plain single-quoted re-issue, and every other denial stays final" PASS
else
  check "P3j a shape denial is answered once by a plain single-quoted re-issue, and every other denial stays final ($SHAPE_VERDICT)" FAIL
fi
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
  && grep -qF 'The browser consent gate denies every cookie, local/session-storage and state command on a `zensu-verify` session because they expose credential material.' <<<"$SKILL_FLAT"; then
  check "P4a auth is visible-only and the gate denies every browser storage command" PASS
else
  check "P4a auth is visible-only and the gate denies every browser storage command" FAIL
fi
if grep -qF 'not accept an auth artifact path' "$SKILL_MD" \
  && ! grep -rqF 'browser_set_storage_state' "$SKILL_DIR"; then
  check "P4b verify-feature never accepts or restores storage-state artifacts" PASS
else
  check "P4b verify-feature never accepts or restores storage-state artifacts" FAIL
fi
if grep -qF 'hard-denies every getter/exporter' "$SKILL_MD" \
  && grep -qF 'Do not invoke `auth.loginScript`' <<<"$SKILL_FLAT"; then
  check "P4e future opaque auth requires a narrow deny-by-default gate" PASS
else
  check "P4e future opaque auth requires a narrow deny-by-default gate" FAIL
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
  && grep -qF 'which prints the page title and writes a snapshot of the page' "$SKILL_MD" \
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
if grep -qF 'A future gate may re-enable opaque state only when it admits a path-contained setter and hard-denies every getter/exporter.' <<<"$SKILL_FLAT"; then
  check "P4g browser state commands stay denied until a narrow gate exists" PASS
else
  check "P4g browser state commands stay denied until a narrow gate exists" FAIL
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
  && grep -qF 'Resolve the planned application origin before starting any resource' "$ZENSU_MD" \
  && grep -qF -- '--check-policy local "$APP_ORIGIN" "/" declared-safe' "$ZENSU_MD" \
  && grep -qF 'Use visible manual browser login' "$ZENSU_MD"; then
  check "P4i local auth waits for the exact frontend origin and stays visible" PASS
else
  check "P4i local auth waits for the exact frontend origin and stays visible" FAIL
fi
if grep -qF 'Without a parent policy the gate runs in consent mode and the same three commands still' "$ZENSU_MD" \
  && grep -qF 'prints `consent` with exit `0`' "$ZENSU_MD" \
  && grep -qF 'consent_origin' "$RUNTIME_CONTROLLER" \
  && grep -qF 'node "$FREE_PORT_HELPER" --from 5173' "$RUNTIME_CONTROLLER"; then
  check "P4t bundled adapter picks and records its own loopback origin in consent mode" PASS
else
  check "P4t bundled adapter picks and records its own loopback origin in consent mode" FAIL
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
if grep -qF 'ZENSU_VERIFY_NAVIGATION_POLICY_V1' "$SKILL_MD" \
  && grep -qF 'Redirects are not filtered by the browser.' <<<"$SKILL_FLAT" \
  && grep -qF 'read the `Page URL` line `playwright-cli` prints' <<<"$SKILL_FLAT" \
  && grep -qF 'stop driving that page: take no snapshot or screenshot and read no console or network output from it, run `close`, and report the scenario PARTIAL with the redirect as the observation.' <<<"$SKILL_FLAT" \
  && grep -qF 'pins each hostname to an approved public address in Chromium to prevent DNS rebinding.' <<<"$SKILL_FLAT" \
  && grep -qF '2. Read the `Page URL` line of every navigating call.' "$BROWSER_MD" \
  && grep -qF 'Every navigating call prints a `Page URL` line.' <<<"$BROWSER_FLAT"; then
  check "P4s a redirect off the run config is caught on the Page URL line before any evidence is read" PASS
else
  check "P4s a redirect off the run config is caught on the Page URL line before any evidence is read" FAIL
fi
if grep -qF 'node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy <local|remote> "<validated-origin>" "<exact-page-route>" declared-safe' "$SKILL_MD" \
  && grep -qF 'It prints `consent` or `policy` and exits `0`, or' "$SKILL_MD"; then
  check "P4u every route runs the run-config helper's --check-policy preflight" PASS
else
  check "P4u every route runs the run-config helper's --check-policy preflight" FAIL
fi
if grep -qF 'never copy raw console output' "$SKILL_MD" && grep -qF 'Strip query strings/fragments' "$SKILL_MD"; then
  check "P4f console/network evidence is sanitized before reporting" PASS
else
  check "P4f console/network evidence is sanitized before reporting" FAIL
fi
if grep -rqE 'jq +-r.*(token|localStorage)|TOK=.*jq|(browser_evaluate|playwright-cli.*(eval|run-code)).*localStorage\.setItem' "$SKILL_DIR"; then
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

# P6 — playwright-cli driver and plugin manifest wiring.
if node -e '
  const manifest = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  const skills = Array.isArray(manifest.skills) ? manifest.skills : [];
  process.exit(skills.includes("./skills/verify-feature") && !Object.prototype.hasOwnProperty.call(manifest, "mcpServers") ? 0 : 1);
' "$PLUGIN_JSON" 2>/dev/null; then
  check "P6a plugin manifest registers the skill and declares no MCP server" PASS
else
  check "P6a plugin manifest registers the skill and declares no MCP server" FAIL
fi
MCP_LEFTOVERS=""
for gone in scripts/playwright-mcp.sh scripts/playwright-mcp-proxy.js mcp-runtime/package.json mcp-runtime/package-lock.json \
  docs/playwright-mcp-runtime.md tests/structure/playwright-mcp-proxy.test.js; do
  if [ -e "$PLUGIN_DIR/$gone" ] || [ -L "$PLUGIN_DIR/$gone" ]; then MCP_LEFTOVERS="$MCP_LEFTOVERS $gone"; fi
done
if [ -z "$MCP_LEFTOVERS" ]; then
  check "P6b the bundled Playwright MCP launcher, broker, runtime lockfiles, and their doc and unit file are gone" PASS
else
  check "P6b the bundled Playwright MCP launcher, broker, runtime lockfiles, and their doc and unit file are gone (still present:$MCP_LEFTOVERS)" FAIL
fi
if [ ! -e "$PLUGIN_DIR/.mcp.json" ] || ! grep -qE 'playwright|zensu-browser' "$PLUGIN_DIR/.mcp.json"; then
  check "P6c no plugin .mcp.json declares a playwright or zensu-browser server" PASS
else
  check "P6c no plugin .mcp.json declares a playwright or zensu-browser server" FAIL
fi
MCP_TOOL_FILES="$(grep -rlE 'browser_(navigate|navigate_back|snapshot|take_screenshot|console_messages|network_requests|close|tabs|install|evaluate|click|type|fill_form|press_key|hover|drag|select_option|resize|wait_for|handle_dialog|file_upload|run_code|set_storage_state|storage_state)|mcp__[A-Za-z0-9_-]*(browser|playwright)' "$PLUGIN_DIR/skills" 2>/dev/null | tr '\n' ' ')"
if [ -z "$MCP_TOOL_FILES" ]; then
  check "P6d no file under skills/ names an MCP browser tool or an MCP browser namespace" PASS
else
  check "P6d no file under skills/ names an MCP browser tool or an MCP browser namespace (files: $MCP_TOOL_FILES)" FAIL
fi
MCP_NAME_FILES="$(grep -rlF 'playwright-mcp' "$PLUGIN_DIR/skills" 2>/dev/null | tr '\n' ' ')"
if [ -z "$MCP_NAME_FILES" ]; then
  check "P6e no file under skills/ names playwright-mcp" PASS
else
  check "P6e no file under skills/ names playwright-mcp (files: $MCP_NAME_FILES)" FAIL
fi
PREFLIGHT_FLAT="$(awk '/^## playwright-cli preflight/{p=1;next} /^## /{p=0} p' "$SKILL_MD" | tr '\n' ' ' | tr -s ' ')"
if [ -n "${PW_MEASURED:-}" ] \
  && grep -qF 'check with `command -v playwright-cli`' <<<"$PREFLIGHT_FLAT" \
  && grep -qF "name the pinned install route for the user to run — \`npm install -g @playwright/cli@${PW_MEASURED}\`, the version the browser consent gate was measured against; \`brew install playwright-cli\` is unpinned" <<<"$PREFLIGHT_FLAT" \
  && grep -qF 'Never install it on their behalf' <<<"$PREFLIGHT_FLAT" \
  && grep -qF "parses its arguments as measured against version ${PW_MEASURED} and denies an argument shape it does not recognize rather than admitting it — including a \`zensu-verify\` session name it does not resolve as the call's session." <<<"$PREFLIGHT_FLAT"; then
  check "P6f the playwright-cli preflight checks PATH, names the pinned install route, labels brew unpinned, and states the measured version ${PW_MEASURED:-}" PASS
else
  check "P6f the playwright-cli preflight checks PATH, names the pinned install route, labels brew unpinned, and states the measured version ${PW_MEASURED:-}" FAIL
fi
if grep -qF 'obtain explicit approval for the networked download' <<<"$PREFLIGHT_FLAT" \
  && grep -qF '`playwright-cli install-browser` WITHOUT a session flag' <<<"$PREFLIGHT_FLAT" \
  && grep -qF 'Never switch to Firefox or WebKit' <<<"$PREFLIGHT_FLAT"; then
  check "P6g a missing browser is installed only after approval, outside the zensu-verify session, and stays Chromium" PASS
else
  check "P6g a missing browser is installed only after approval, outside the zensu-verify session, and stays Chromium" FAIL
fi
if grep -qF '### Browser session (both modes)' "$SKILL_MD" \
  && grep -qF 'node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --run-dir "$RUN_DIR" --mode <local|remote> --origin "<app-origin>"' "$SKILL_MD" \
  && [ -n "${CONSENT_SESSION_PREFIX:-}" ] && grep -qF "\`session=${CONSENT_SESSION_PREFIX}<id>\`" "$SKILL_MD" \
  && [ -n "${CONSENT_SESSION_ENV:-}" ] \
  && grep -qF "Copy the printed session name and config path LITERALLY into every later call. Never rebuild them, never hold them in a shell variable, and never set \`${CONSENT_SESSION_ENV}\`: the gate denies a session or argument it cannot read as a literal." <<<"$SKILL_FLAT" \
  && grep -qF 'playwright-cli -s=<session> open --config=<config> [--headed] <app-origin><route>' "$SKILL_MD"; then
  check "P6h the browser session copies the helper's session name and config path literally into every call" PASS
else
  check "P6h the browser session copies the helper's session name and config path literally into every call" FAIL
fi
if grep -qF 'Run each `playwright-cli` call as its own plain Bash command on the main thread — exactly one call per Bash command, with nothing before or after it: no `&&`, `;` or pipe, no subshell or command substitution, no wrapper such as `timeout` or `nohup`, no package launcher such as `npx`, never through `xargs`, `bash -c`, a heredoc or a here-string, and never from a subagent. The gate denies every other shape. Name the same session on every call: `playwright-cli -s=<session> <command> ...`, and quote an argument that carries `?`, `*`, `[` or `{`, or that starts with `~` or `=`, because the gate reads an unquoted one as a shell pattern it cannot judge.' <<<"$SKILL_FLAT" \
  && grep -qF 'every call from a subagent' "$SKILL_MD" \
  && grep -qF 'every command that is not exactly one plain `playwright-cli` call' <<<"$SKILL_FLAT"; then
  check "P6i every playwright-cli call is a plain main-thread Bash command on the same session" PASS
else
  check "P6i every playwright-cli call is a plain main-thread Bash command on the same session" FAIL
fi
if grep -qF 'Never run `playwright-cli eval` or `run-code`; the browser consent gate denies both on a `zensu-verify` session' <<<"$SKILL_FLAT" \
  && grep -qF 'never `close-all` or `kill-all`, which end sessions this run does not own' <<<"$SKILL_FLAT" \
  && grep -qF 'never `attach` to a running browser' <<<"$SKILL_FLAT" \
  && grep -qF 'the gate denies an `export` or an environment assignment on a command that carries a `zensu-verify` call.' <<<"$SKILL_FLAT"; then
  check "P6j the skill forbids page evaluation, foreign-session teardown, attaching, and environment changes" PASS
else
  check "P6j the skill forbids page evaluation, foreign-session teardown, attaching, and environment changes" FAIL
fi
PHASE4="$(awk '/^## Phase 4/{p=1;next} /^## /{p=0} p' "$SKILL_MD")"
if grep -qF 'run `playwright-cli -s=<session> close` for every session this run opened' <<<"$PHASE4" \
  && grep -qF 'Run `playwright-cli -s=<session> close` even after a failed assertion or cancelled login.' "$BROWSER_MD"; then
  check "P6k Phase 4 closes every session this run opened, even after a failure" PASS
else
  check "P6k Phase 4 closes every session this run opened, even after a failure" FAIL
fi
if grep -qF '| `--print-policy` | with `--setup` | off |' "$SKILL_MD" \
  && grep -qF '## 5. `--print-policy`' "$SETUP_MD" \
  && grep -qF "ZENSU_VERIFY_NAVIGATION_POLICY_V1='<rendered JSON>' node" "$SETUP_MD" \
  && grep -qF 'node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy local "<origin>" "<route>" declared-safe' "$SETUP_MD" \
  && grep -qF '`policy` on stdout with exit `0` means the rendered JSON approves that route.' "$SETUP_MD" \
  && grep -qF 'the project-level settings files are not the place, because the session can write them.' <<<"$SETUP_FLAT"; then
  check "P6l --print-policy renders the policy, proves it with --check-policy, and keeps it out of project settings" PASS
else
  check "P6l --print-policy renders the policy, proves it with --check-policy, and keeps it out of project settings" FAIL
fi
TEMPLATE_VERDICT="$(node -e '
  const fs = require("node:fs");
  const floor = require(process.argv[2]);
  const match = fs.readFileSync(process.argv[1], "utf8").match(/`(\{"version":1,[^`]*\})`/);
  if (!match) { process.stdout.write("policy template not found"); process.exit(1); }
  const rendered = match[1].split("<port>").join("5173").split("<declared routes>").join(JSON.stringify("/"));
  const parsed = floor.parsePolicyTargets(rendered);
  if (!parsed.ok) { process.stdout.write(String(parsed.fault)); process.exit(1); }
  if (parsed.mode !== "local") { process.stdout.write("mode " + parsed.mode); process.exit(1); }
' "$SETUP_MD" "$FLOOR_MODULE" 2>&1)"
TEMPLATE_RC=$?
if [ "$TEMPLATE_RC" = "0" ]; then
  check "P6m the --print-policy template passes the navigation policy contract once its placeholders are filled" PASS
else
  check "P6m the --print-policy template passes the navigation policy contract once its placeholders are filled ($TEMPLATE_VERDICT)" FAIL
fi
CHECK_CONSENT_OUT="$(env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 PATH="$PW_STUB_BIN:$PATH" node "$BROWSER_CONFIG" --check-policy local "http://127.0.0.1:5173" "/" declared-safe 2>/dev/null)"
CHECK_CONSENT_RC=$?
if [ "$CHECK_CONSENT_RC" = "0" ] && [ "$CHECK_CONSENT_OUT" = "consent" ]; then
  check "P6n --check-policy prints consent and exits 0 for a loopback route without a policy" PASS
else
  check "P6n --check-policy prints consent and exits 0 for a loopback route without a policy (rc=$CHECK_CONSENT_RC out=$CHECK_CONSENT_OUT)" FAIL
fi
CHECK_POLICY='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:5173","routes":["/"],"evidenceMode":"declared-safe"}]}'
CHECK_POLICY_OUT="$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$CHECK_POLICY" PATH="$PW_STUB_BIN:$PATH" node "$BROWSER_CONFIG" --check-policy local "http://127.0.0.1:5173" "/" declared-safe 2>/dev/null)"
CHECK_POLICY_RC=$?
if [ "$CHECK_POLICY_RC" = "0" ] && [ "$CHECK_POLICY_OUT" = "policy" ]; then
  check "P6o --check-policy prints policy and exits 0 for a route the launch policy approves" PASS
else
  check "P6o --check-policy prints policy and exits 0 for a route the launch policy approves (rc=$CHECK_POLICY_RC out=$CHECK_POLICY_OUT)" FAIL
fi
CHECK_ROUTE_OUT="$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$CHECK_POLICY" PATH="$PW_STUB_BIN:$PATH" node "$BROWSER_CONFIG" --check-policy local "http://127.0.0.1:5173" "/admin" declared-safe 2>&1)"
CHECK_ROUTE_RC=$?
case "$CHECK_ROUTE_OUT" in
  *'route is not approved for evidence by the navigation policy'*) CHECK_ROUTE_NAMED=true ;;
  *) CHECK_ROUTE_NAMED=false ;;
esac
if [ "$CHECK_ROUTE_RC" = "1" ] && [ "$CHECK_ROUTE_NAMED" = "true" ]; then
  check "P6p --check-policy exits 1 naming the reason for a route the launch policy does not approve" PASS
else
  check "P6p --check-policy exits 1 naming the reason for a route the launch policy does not approve (rc=$CHECK_ROUTE_RC out=$CHECK_ROUTE_OUT)" FAIL
fi
CHECK_REMOTE_OUT="$(env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 PATH="$PW_STUB_BIN:$PATH" node "$BROWSER_CONFIG" --check-policy remote "https://example.com" "/" declared-safe 2>&1)"
CHECK_REMOTE_RC=$?
case "$CHECK_REMOTE_OUT" in
  *'remote-target-needs-parent-environment-policy'*) CHECK_REMOTE_NAMED=true ;;
  *) CHECK_REMOTE_NAMED=false ;;
esac
if [ "$CHECK_REMOTE_RC" = "1" ] && [ "$CHECK_REMOTE_NAMED" = "true" ]; then
  check "P6q --check-policy refuses a remote target without a launch policy before any DNS lookup" PASS
else
  check "P6q --check-policy refuses a remote target without a launch policy before any DNS lookup (rc=$CHECK_REMOTE_RC out=$CHECK_REMOTE_OUT)" FAIL
fi

# P7 — docs/help/doctor are synchronized.
if grep -qF '| `/zensu:verify-feature` |' "$README_MD"; then
  check "P7a README documents the verify-feature command" PASS
else
  check "P7a README documents the verify-feature command" FAIL
fi
if grep -qF 'skills/verify-feature/SKILL.md' "$HELP_MD" && grep -qF '/zensu:cover' "$HELP_MD" \
  && grep -qF 'browser evidence, playwright-cli' "$HELP_MD"; then
  check "P7b help routes live verification and durable test authoring separately" PASS
else
  check "P7b help routes live verification and durable test authoring separately" FAIL
fi
if grep -qF 'command -v playwright-cli' "$DOCTOR_SH" \
  && grep -qF 'playwright-cli-version-v1.js' "$DOCTOR_SH" \
  && ! grep -qF 'playwright_mcp_declared' "$DOCTOR_SH" \
  && grep -qF 'playwright-cli: installed (' "$DOCTOR_REPORT" \
  && grep -qF 'playwright-cli: not found on PATH' "$DOCTOR_REPORT" \
  && grep -qF 'CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh"' "$DOCTOR_SKILL" \
  && ! grep -qF 'ZDOC_PLAYWRIGHT_TOOLS' "$DOCTOR_SKILL" \
  && grep -qF 'Session Control: plugin root unavailable or invalid' "$DOCTOR_SKILL"; then
  check "P7c doctor probes playwright-cli and its version without an MCP readiness claim" PASS
else
  check "P7c doctor probes playwright-cli and its version without an MCP readiness claim" FAIL
fi
if grep -qF 'The plugin ships no MCP server, so there is no Zensu API or hosted-MCP endpoint' "$README_MD" \
  && grep -qF "need \`playwright-cli\` on \`PATH\` (\`npm install -g @playwright/cli@${PW_MEASURED}\`, the version the browser consent gate was measured against; \`brew install playwright-cli\` is unpinned)." <<<"$README_FLAT"; then
  check "P7d README states the plugin ships no MCP server and requires playwright-cli for browser verification" PASS
else
  check "P7d README states the plugin ships no MCP server and requires playwright-cli for browser verification" FAIL
fi
INSTALL_DRIFT=""
for carrier in "$SKILL_MD" "$README_MD" "$DOCTOR_SKILL" "$AUTOPILOT_CONFIG" "$PLUGIN_DIR/docs/verify-feature.md" "$PLUGIN_DIR/docs/gates.md" "$PLUGIN_DIR/docs/operations.md"; do
  carrier_flat="$(tr '\n' ' ' < "$carrier" | tr -s ' ')"
  if [ -z "${PW_MEASURED:-}" ] || ! grep -qF "\`npm install -g @playwright/cli@${PW_MEASURED}\`" <<<"$carrier_flat" \
    || ! grep -qF '`brew install playwright-cli` is unpinned' <<<"$carrier_flat" \
    || grep -qF '`npm install -g @playwright/cli`' <<<"$carrier_flat"; then
    INSTALL_DRIFT="$INSTALL_DRIFT ${carrier#"$PLUGIN_DIR"/}"
  fi
done
if ! grep -qF "'\`npm install -g @playwright/cli' + (measured ? '@' + measured : '') + '\`'" "$DOCTOR_REPORT" \
  || ! grep -qF '`brew install playwright-cli` is unpinned' "$DOCTOR_REPORT"; then
  INSTALL_DRIFT="$INSTALL_DRIFT hooks/lib/zensu-doctor-report.js"
fi
if [ -z "$INSTALL_DRIFT" ]; then
  check "P7e every playwright-cli install route names the pinned npm command and labels brew unpinned" PASS
else
  check "P7e every playwright-cli install route names the pinned npm command and labels brew unpinned (drift in:$INSTALL_DRIFT)" FAIL
fi
DOCTOR_FLAT="$(tr '\n' ' ' < "$DOCTOR_SKILL" | tr -s ' ')"
READINESS_MISSING=""
grep -qF 'It refuses unless `hooks/hooks.json` demonstrably registers both consent hooks on a matcher that covers Bash, the installed `playwright-cli` manifest names the measured version, and no empty or relative PATH entry comes before or holds `playwright-cli`; then report PARTIAL with its reason, and never open a browser without the run config it writes.' <<<"$SKILL_FLAT" || READINESS_MISSING="$READINESS_MISSING [skill: registration, measured version and PATH-entry refusals]"
grep -qF 'The label is literal: the run-config helper writes no run config unless both hooks demonstrably answer registered' <<<"$DOCTOR_FLAT" || READINESS_MISSING="$READINESS_MISSING [doctor: literal label]"
grep -qF 'tell the user not to start `/zensu:verify-feature` until this row clears' <<<"$DOCTOR_FLAT" || READINESS_MISSING="$READINESS_MISSING [doctor: do not start until the row clears]"
if [ -z "$READINESS_MISSING" ]; then
  check "P7f the skill names the helper's registration, measured-version and PATH-entry refusals, and the doctor says it refuses while a consent hook is unregistered" PASS
else
  check "P7f the skill names the helper's registration, measured-version and PATH-entry refusals, and the doctor says it refuses while a consent hook is unregistered (missing:$READINESS_MISSING)" FAIL
fi
if grep -qF 'the `@playwright/cli` package the binary on `PATH` resolves to — one beside an npm shim, else the nearest manifest within four directories of the resolved binary — without running it.' <<<"$DOCTOR_FLAT" \
  && ! grep -qF 'the nearest manifest within four directories of the resolved binary, else one beside an npm shim' <<<"$DOCTOR_FLAT"; then
  check "P7g the doctor skill reads the npm-shim sibling manifest first, as the version module does" PASS
else
  check "P7g the doctor skill reads the npm-shim sibling manifest first, as the version module does" FAIL
fi
PIN_DRIFT=""
grep -qxF "npm install -g @playwright/cli@${PW_MEASURED:-unset}" "$PLUGIN_DIR/docs/verify-feature.md" || PIN_DRIFT="$PIN_DRIFT docs/verify-feature.md(install block)"
grep -qF "pinned by a golden recording of \`playwright-cli\` ${PW_MEASURED:-unset}'s parser" <<<"$(tr '\n' ' ' < "$PLUGIN_DIR/docs/gates.md" | tr -s ' ')" || PIN_DRIFT="$PIN_DRIFT docs/gates.md(golden recording)"
grep -qF "grader was written against \`playwright-cli\` ${PW_MEASURED:-unset})" <<<"$(tr '\n' ' ' < "$PLUGIN_DIR/evals/verify-feature/README.md" | tr -s ' ')" || PIN_DRIFT="$PIN_DRIFT evals/verify-feature/README.md"
if [ -z "$PIN_DRIFT" ]; then
  check "P7h the fenced install line, the golden-recording sentence and the eval README name the measured version ${PW_MEASURED:-}" PASS
else
  check "P7h the fenced install line, the golden-recording sentence and the eval README name the measured version ${PW_MEASURED:-} (drift in:$PIN_DRIFT)" FAIL
fi
if grep -qF 'A wrapper script outside the package with no `package.json` near it looks exactly like this' <<<"$DOCTOR_FLAT" \
  && grep -qF 'A wrapper script with another package'"'"'s `package.json` within four directories reads like this too, and then the directory npm installs `playwright-cli` into also has to come first on PATH.' <<<"$DOCTOR_FLAT" \
  && grep -qF 'A wrapper script with a `package.json` the doctor cannot judge within four directories, such as a project manifest with no name, reads like this too, and then the directory npm installs `playwright-cli` into also has to come first on PATH.' <<<"$DOCTOR_FLAT"; then
  check "P7i the doctor skill tells a wrapper script with no nearby manifest from one under another package" PASS
else
  check "P7i the doctor skill tells a wrapper script with no nearby manifest from one under another package" FAIL
fi
if grep -qF 'The manifest vouches for the package, not for the binary: a wrapper script in a directory that holds such a manifest reads the same.' <<<"$DOCTOR_FLAT" \
  && grep -qF 'A missing prefilter library also makes it deny every other Bash call whose payload names `playwright` or `zensu-verify`, with `prefilter library unavailable` — in a project whose path names either word, every Bash call except the recognized `/zensu:doctor` and adoption commands — so tell the user those denials share this cause.' <<<"$DOCTOR_FLAT"; then
  check "P7j the doctor skill says the manifest vouches for the package, not the binary, and what a missing prefilter library denies" PASS
else
  check "P7j the doctor skill says the manifest vouches for the package, not the binary, and what a missing prefilter library denies" FAIL
fi
if grep -qF 'a missing, symlinked or unloadable decision module makes the consent hook deny every gated call, so `/zensu:verify-feature` cannot drive a browser;' <<<"$DOCTOR_FLAT" \
  && grep -qF 'A missing prefilter library makes it deny every call the skill issues, although a gated call that splits `playwright` and `zensu-verify` with a backslash before `n`, `r` or `t` then passes unjudged.' <<<"$DOCTOR_FLAT" \
  && ! grep -qF 'a missing prefilter library or a missing, symlinked or unloadable decision module makes the consent hook deny every gated call' <<<"$DOCTOR_FLAT"; then
  check "P7k the doctor skill limits the deny-every-gated-call claim to the decision module and names the backslash spelling a missing prefilter library lets through" PASS
else
  check "P7k the doctor skill limits the deny-every-gated-call claim to the decision module and names the backslash spelling a missing prefilter library lets through" FAIL
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
if grep -qF 'node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy' "$SKILL_MD" \
  && grep -qF 'ROOT="${CLAUDE_PLUGIN_ROOT}"' "$SKILL_MD" \
  && grep -qF 'supporting files loaded through `Read` do not receive' "$SKILL_MD" \
  && grep -qF '<absolute-plugin-root>/skills/verify-feature/scripts/zensu-monorepo-runtime.sh' "$ZENSU_MD" \
  && grep -qF 'node "<absolute-plugin-root>/scripts/verify-browser-config.js" --check-policy' "$ZENSU_MD" \
  && ! grep -qF '{ACTIVE_PLUGIN_ROOT}' "$SKILL_MD" \
  && ! grep -qF '{ACTIVE_PLUGIN_ROOT}' "$ZENSU_MD" \
  && ! grep -qF 'ZENSU_CLAUDE_PLUGIN_ROOT' "$SKILL_MD" \
  && ! grep -qF 'ZENSU_CLAUDE_PLUGIN_ROOT' "$ZENSU_MD" \
  && ! grep -qF '${CLAUDE_PLUGIN_ROOT}' "$ZENSU_MD"; then
  check "P8c skill uses native root rendering and concretizes adapter placeholders" PASS
else
  check "P8c skill uses native root rendering and concretizes adapter placeholders" FAIL
fi

CHANGELOG_MD="$PLUGIN_DIR/CHANGELOG.md"
RELEASE_YML="$PLUGIN_DIR/.github/workflows/release.yml"
P9_VERDICTS="$(node -e '
  const fs = require("node:fs");
  const os = require("node:os");
  const path = require("node:path");
  const { spawnSync } = require("node:child_process");
  const [workflow, changelogFile, measured] = process.argv.slice(1);
  const RULE = "mcp__plugin_zensu_playwright__";
  const LAST_MCP_RELEASE = [0, 21, 1];
  const DATED = /^## \[([0-9]+)\.([0-9]+)\.([0-9]+)\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$/;
  const workflowLines = fs.readFileSync(workflow, "utf8").split("\n");
  function program(stepName, openRe, closeRe) {
    const step = workflowLines.findIndex((line) => line.includes("- name: " + stepName));
    const open = step === -1 ? -1 : workflowLines.findIndex((line, index) => index > step && openRe.test(line));
    const close = open === -1 ? -1 : workflowLines.findIndex((line, index) => index > open && closeRe.test(line));
    if (close === -1) throw new Error("the awk program of step \"" + stepName + "\" was not found in release.yml");
    return workflowLines.slice(open + 1, close).join("\n");
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "changelog-release-"));
  function awk(args) {
    const run = spawnSync("awk", args, { encoding: "utf8" });
    if (run.status !== 0) throw new Error("awk failed: " + run.stderr);
    return run.stdout;
  }
  function blocksOf(text) {
    const lines = text.split("\n");
    const found = [];
    for (let i = 0; i < lines.length; i += 1) {
      if (lines[i] !== "### Upgrade notes") continue;
      let end = i + 1;
      while (end < lines.length && !/^##{1,2} /.test(lines[end])) end += 1;
      const block = lines.slice(i, end).join("\n");
      if (!block.includes(RULE)) continue;
      let heading = i - 1;
      while (heading >= 0 && !/^## /.test(lines[heading])) heading -= 1;
      found.push({ block, heading: heading === -1 ? "" : lines[heading], start: i, end });
    }
    return found;
  }
  function placement(text, measuredVersion) {
    const found = blocksOf(text);
    if (found.length !== 1) throw new Error(found.length + " upgrade-notes blocks name " + RULE);
    const { block, heading } = found[0];
    if (heading === "## [Unreleased]") {
      const install = "npm install -g @playwright/cli@" + measuredVersion;
      if (!block.includes(install)) throw new Error("the unreleased notes do not name " + install);
      return "Unreleased";
    }
    const dated = DATED.exec(heading);
    if (!dated) throw new Error("the notes sit under " + JSON.stringify(heading));
    const version = dated.slice(1, 4).map(Number);
    const order = version[0] - LAST_MCP_RELEASE[0] || version[1] - LAST_MCP_RELEASE[1] || version[2] - LAST_MCP_RELEASE[2];
    if (order <= 0) throw new Error("the notes sit under " + version.join(".") + ", a release that still shipped the MCP server");
    if (!/npm install -g @playwright\/cli@[0-9]+\.[0-9]+\.[0-9]+/.test(block)) throw new Error("the released notes name no pinned install");
    return version.join(".");
  }
  function release(text, measuredVersion, version) {
    const before = placement(text, measuredVersion);
    const section = path.join(dir, "section.md");
    const source = path.join(dir, "source.md");
    fs.writeFileSync(section, "## [" + version + "] - 2099-01-01\n\n### Added\n\n- **release**: Synthetic generated entry\n");
    fs.writeFileSync(source, text);
    const released = awk([program("Prepend section into CHANGELOG.md", /^\s*awk \x27\s*$/, /^\s*\x27 "\$SECTION" CHANGELOG\.md > /), section, source]);
    const headings = released.split("\n").filter((line) => /^## /.test(line));
    const at = headings.indexOf("## [Unreleased]");
    if (at === -1 || headings.lastIndexOf("## [Unreleased]") !== at) throw new Error("the released file does not carry exactly one Unreleased heading");
    if (headings[at + 1] !== "## [" + version + "] - 2099-01-01") throw new Error("the generated section does not follow the Unreleased heading");
    const after = placement(released, measuredVersion);
    const expected = before === "Unreleased" ? version : before;
    if (after !== expected) throw new Error("the release left the notes under " + after + ", not " + expected);
    const releasedFile = path.join(dir, "released.md");
    fs.writeFileSync(releasedFile, released);
    const notes = awk(["-v", "ver=" + after, program("Extract release notes from CHANGELOG", /^\s*awk -v ver="\$VER" \x27\s*$/, /^\s*\x27 CHANGELOG\.md > /), releasedFile]);
    if (!notes.includes(blocksOf(released)[0].block)) throw new Error("the release notes for " + after + " do not carry the upgrade notes");
    return { released, version: after };
  }
  function moveUnder(text, heading) {
    const lines = text.split("\n");
    const [found] = blocksOf(text);
    if (!found) throw new Error("no upgrade notes to move");
    const block = lines.slice(found.start, found.end);
    const rest = lines.slice(0, found.start).concat(lines.slice(found.end));
    const target = rest.findIndex((line) => line.startsWith(heading));
    if (target === -1) throw new Error("no " + heading + " section to move the notes into");
    return rest.slice(0, target + 2).concat(block, rest.slice(target + 2)).join("\n");
  }
  const verdicts = [];
  function scenario(name, run) {
    try { verdicts.push(name + "\tok\t" + run()); }
    catch (error) { verdicts.push(name + "\tfail\t" + String(error.message || error).replace(/\s+/g, " ")); }
  }
  const changelog = fs.readFileSync(changelogFile, "utf8");
  const bumped = measured.replace(/[0-9]+$/, (patch) => String(Number(patch) + 1));
  try {
    scenario("placement", () => placement(changelog, measured));
    scenario("release", () => release(changelog, measured, "99.0.0").version);
    scenario("stale-section", () => placement(moveUnder(changelog, "## [0.21.1] - "), measured));
    scenario("bumped", () => {
      const shipped = release(changelog, measured, "99.0.0").released;
      return release(shipped, bumped, "99.1.0").version + " with measured " + bumped;
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  process.stdout.write(verdicts.join("\n") + "\n");
' "$RELEASE_YML" "$CHANGELOG_MD" "$PW_MEASURED" 2>&1)"
p9_verdict() { printf '%s\n' "$P9_VERDICTS" | awk -F '\t' -v name="$1" '$1 == name { print $2 "\t" $3 }'; }
case "$(p9_verdict placement)" in
  ok$'\t'*) check "P9a the upgrade notes are one block, under Unreleased with the measured pin or under a release after 0.21.1 ($(p9_verdict placement | cut -f2))" PASS ;;
  *) check "P9a the upgrade notes are one block, under Unreleased with the measured pin or under a release after 0.21.1 ($(p9_verdict placement | cut -f2))" FAIL ;;
esac
case "$(p9_verdict release)" in
  ok$'\t'*) check "P9b release.yml's own insertion and notes awk carry the upgrade notes into the release section and its notes ($(p9_verdict release | cut -f2))" PASS ;;
  *) check "P9b release.yml's own insertion and notes awk carry the upgrade notes into the release section and its notes ($(p9_verdict release | cut -f2))" FAIL ;;
esac
case "$(p9_verdict stale-section)" in
  fail$'\t'*'a release that still shipped the MCP server'*) check "P9c notes moved under 0.21.1 are refused" PASS ;;
  *) check "P9c notes moved under 0.21.1 are refused (got: $(p9_verdict stale-section))" FAIL ;;
esac
case "$(p9_verdict bumped)" in
  ok$'\t'*) check "P9d the released notes survive the next release and a bump of the measured version ($(p9_verdict bumped | cut -f2))" PASS ;;
  *) check "P9d the released notes survive the next release and a bump of the measured version ($(p9_verdict bumped | cut -f2))" FAIL ;;
esac

echo "----"
echo "test-verify-feature-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
