#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
EVAL_DIR="$PLUGIN_DIR/evals/route-short-line-reaction"
UNIT="$PLUGIN_DIR/tests/structure/route-short-line-graders.test.js"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
WRAPPER="$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh"
PROVIDER="$EVAL_DIR/provider.sh"
CAPTURE="$EVAL_DIR/lib/capture-injections.sh"
EVAL_CONFIG="$EVAL_DIR/eval-config.json"
MAIN_CFG="$EVAL_DIR/promptfooconfig.yaml"
PRE_CFG="$EVAL_DIR/promptfooconfig-preflight.yaml"
README="$EVAL_DIR/README.md"
FIXTURE_TEST="$EVAL_DIR/test-projects/cart-app/src/cart.test.js"
LEDGER_RULE="$PLUGIN_DIR/.claude/rules/prompt-ledger.md"
CODE_MESSAGE='Add an optional discountPercent parameter to cartTotal in src/cart.js that reduces the item subtotal by that percentage before the shipping fee is added, default 0.'
PLAN_MESSAGE='Plan this cart app as a product in Zensu: set up the roadmap with its features and tiers.'
source "$PLUGIN_DIR/tests/structure/lib-unit-summary.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

finish() {
  echo "----"
  echo "test-route-short-line-eval: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

checks_from() {
  local label verdict
  while IFS=$'\t' read -r label verdict; do
    [ -n "$label" ] || continue
    check "$label" "$verdict"
  done < "$1"
}

for f in "$UNIT" "$PROFILE" "$WRAPPER" "$PROVIDER" "$CAPTURE" "$EVAL_CONFIG" "$MAIN_CFG" "$PRE_CFG" "$README" \
  "$FIXTURE_TEST" "$LEDGER_RULE" "$EVAL_DIR/.gitignore" "$EVAL_DIR/lib/envelope.js" "$EVAL_DIR/lib/decision-probe.js" \
  "$EVAL_DIR/lib/inject-context.js" "$EVAL_DIR/test-projects/cart-app/package.json" "$EVAL_DIR/test-projects/cart-app/src/cart.js"; do
  if [ ! -f "$f" ]; then
    check "RS0 required file exists: ${f#$PLUGIN_DIR/}" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "RS0 node and git are available" FAIL
  finish
  exit 1
fi
check "RS0 required files, node and git are present" PASS

if node -e '
  const m = require(process.argv[1]);
  process.exit(m.ciStructureTests.includes("test-route-short-line-eval.sh") && !m.localStructureTests.includes("test-route-short-line-eval.sh") ? 0 : 1);
' "$PROFILE"; then
  check "RS0a the suite is classified as a CI structure test" PASS
else
  check "RS0a the suite is classified as a CI structure test" FAIL
fi

WORK="$(mktemp -d 2>/dev/null)" || { check "RS0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

if node --test "$UNIT" >"$WORK/unit.out" 2>&1; then
  check "RS1 the grader unit suite passes (node --test route-short-line-graders.test.js)" PASS
else
  check "RS1 the grader unit suite passes (node --test route-short-line-graders.test.js)" FAIL
  sed -n '1,60p' "$WORK/unit.out"
fi
UNIT_FLOOR="$(unit_overview_declared "${UNIT##*/}")"
if unit_cases_meet_floor "$WORK/unit.out" "$UNIT_FLOOR"; then
  check "RS1a the grader unit suite registered at least $UNIT_FLOOR passing cases (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" PASS
else
  check "RS1a the grader unit suite registered at least ${UNIT_FLOOR:-<no overview row>} passing cases (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" FAIL
fi
if RS1_OVERVIEW="$(unit_overview_check "$UNIT")"; then
  check "RS1b the SUITE-OVERVIEW Blocks cell matches what ${UNIT##*/} registers ($UNIT_FLOOR)" PASS
else
  check "RS1b $RS1_OVERVIEW" FAIL
fi

node - "$MAIN_CFG" "$PRE_CFG" > "$WORK/rs2.tsv" 2>&1 <<'NODE'
const fs = require('node:fs');
const [main, pre] = process.argv.slice(2).map((f) => fs.readFileSync(f, 'utf8'));
const out = [];
const t = (label, ok) => out.push(`${label}\t${ok ? 'PASS' : 'FAIL'}`);
for (const [name, text, repeat, concurrency] of [['promptfooconfig.yaml', main, 3, 2], ['promptfooconfig-preflight.yaml', pre, 1, 1]]) {
  t(`RS2 ${name} runs ./provider.sh on the immutable cart-app fixture`, text.includes("- id: 'exec: ./provider.sh'") && text.includes('working_dir: ./test-projects/cart-app') && text.includes('init_git: true'));
  t(`RS2 ${name} opens the prompt with the source line the provider parses`, /raw: \|\n {6}route-eval-source: \{\{route_source\}\}\n {6}\{\{user_message\}\}\n/.test(text));
  t(`RS2 ${name} grades every run with the three harness graders`, ['harness-attested', 'harness-injection', 'harness-isolation'].every((g) => text.includes(`value: file://assertions/${g}.js`)));
  t(`RS2 ${name} repeats ${repeat} times at concurrency ${concurrency}`, text.includes(`repeat: ${repeat}\n`) && text.includes(`maxConcurrency: ${concurrency}\n`));
}
process.stdout.write(`${out.join('\n')}\n`);
NODE
RS2_RC=$?
checks_from "$WORK/rs2.tsv"
[ "$RS2_RC" -eq 0 ] || check "RS2 the config check ran to completion (node rc=$RS2_RC)" FAIL
if grep -rqF 'llm-rubric' "$EVAL_DIR"; then
  check "RS2a no grader in the eval is a model rubric" FAIL
else
  check "RS2a no grader in the eval is a model rubric" PASS
fi

node - "$EVAL_DIR" > "$WORK/rs3.tsv" 2>&1 <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [dir] = process.argv.slice(2);
const listed = (cfg) => [...fs.readFileSync(path.join(dir, cfg), 'utf8').matchAll(/^ {2}- file:\/\/(scenarios\/\S+\.yaml)$/gm)].map((m) => m[1]);
const onDisk = (sub) => fs.readdirSync(path.join(dir, sub)).filter((f) => f.endsWith('.yaml')).map((f) => `${sub}/${f}`).sort();
const main = listed('promptfooconfig.yaml');
const pre = listed('promptfooconfig-preflight.yaml');
const same = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify(b) && new Set(a).size === a.length;
process.stdout.write([
  `RS3 promptfooconfig.yaml registers every graded scenario on disk, at least five (${main.length})\t${same(main, onDisk('scenarios')) && main.length >= 5 ? 'PASS' : 'FAIL'}`,
  `RS3 promptfooconfig-preflight.yaml registers every preflight scenario on disk (${pre.length})\t${same(pre, onDisk('scenarios/preflight')) && pre.length >= 1 ? 'PASS' : 'FAIL'}`,
].join('\n') + '\n');
NODE
RS3_RC=$?
checks_from "$WORK/rs3.tsv"
[ "$RS3_RC" -eq 0 ] || check "RS3 the inventory check ran to completion (node rc=$RS3_RC)" FAIL

node - "$PLUGIN_DIR" "$EVAL_DIR" "$WORK" > "$WORK/rs4.tsv" 2>&1 <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const [plugin, evalDir, work] = process.argv.slice(2);
const envelope = require(path.join(evalDir, 'lib', 'envelope.js'));
const route = require(path.join(evalDir, 'assertions', 'route-question-complete.js'));
const placeholder = require(path.join(evalDir, 'assertions', 'no-placeholder-copy.js')).PLACEHOLDERS[0];
const sources = /^SOURCES=' (.*) '$/m.exec(fs.readFileSync(path.join(evalDir, 'provider.sh'), 'utf8'))[1].split(' ');
const out = [];
const t = (label, ok) => out.push(`${label}\t${ok ? 'PASS' : 'FAIL'}`);
const varsOf = (text) => {
  const lines = text.split('\n');
  const vars = {};
  for (const line of lines.slice(lines.indexOf('vars:') + 1)) {
    const m = /^ {2}([a-z_]+): (.*)$/.exec(line);
    if (!m) break;
    vars[m[1]] = m[2].startsWith('"') ? JSON.parse(m[2]) : m[2];
  }
  return vars;
};
const scenarios = ['promptfooconfig.yaml', 'promptfooconfig-preflight.yaml']
  .flatMap((c) => [...fs.readFileSync(path.join(evalDir, c), 'utf8').matchAll(/^ {2}- file:\/\/(scenarios\/\S+\.yaml)$/gm)].map((m) => m[1]));
const seen = new Set();
scenarios.forEach((file, i) => {
  const v = varsOf(fs.readFileSync(path.join(evalDir, file), 'utf8'));
  const name = path.basename(file, '.yaml');
  const dir = path.join(work, `capture-${i}`);
  fs.mkdirSync(dir);
  const r = spawnSync('bash', [path.join(evalDir, 'lib', 'capture-injections.sh'), 'capture', v.route_source, plugin, dir, v.user_message], { encoding: 'utf8' });
  let cap = null;
  try { cap = JSON.parse(fs.readFileSync(path.join(dir, 'capture.json'), 'utf8')); } catch (_) { cap = null; }
  const text = fs.existsSync(path.join(dir, 'inject.txt')) ? fs.readFileSync(path.join(dir, 'inject.txt'), 'utf8') : '';
  const want = v.route_source === 'none' ? 0 : 1;
  t(`RS4 ${name}: the ${v.route_source} capture from this tree has shape ${v.expected_shape} and field ${v.expected_field}`,
    r.status === 0 && Boolean(cap) && cap.route_source === v.route_source && cap.shape === v.expected_shape && cap.field === v.expected_field && cap.blocks.length === want && (want === 1) === (text !== ''));
  if (v.anchor_clause) t(`RS4 ${name}: the captured line carries the anchor clause the scenario grades against`, text.includes(v.anchor_clause));
  if (v.expected_status) {
    const template = /begin your message with "([^"]+)"/.exec(text);
    const source = /^[a-z]+ \(([^)]+)\)$/.exec(v.expected_field);
    t(`RS4 ${name}: expected_status is the captured status template with the field's source filled in`,
      Boolean(template && source) && template[1].includes(placeholder) && template[1].split(placeholder).join(source[1]) === v.expected_status);
  }
  if (v.expected_shape === 'ask-short') t(`RS4 ${name}: the graders recognise the captured route labels and every disclosure the line promises`, envelope.covers(text, 'reminder') && route.missing(text).length === 0);
  if (v.expected_shape === 'router-short') t(`RS4 ${name}: the graders recognise the three triage questions the captured line names`, envelope.covers(text, 'router'));
  if (v.route_source === 'nonce') t(`RS4 ${name}: the nonce capture carries a fresh nonce and the directive that names it`, Boolean(cap) && /^ROUTE-EVAL-NONCE-[0-9a-f]{16}$/.test(cap.nonce || '') && text.startsWith(`Begin your reply with the exact line ${cap.nonce} `));
  seen.add(v.route_source);
});
t(`RS4 the scenarios exercise every source the provider accepts (${sources.join(' ')})`, sources.length > 0 && sources.every((s) => seen.has(s)));
process.stdout.write(`${out.join('\n')}\n`);
NODE
RS4_RC=$?
checks_from "$WORK/rs4.tsv"
[ "$RS4_RC" -eq 0 ] || check "RS4 the capture pins ran to completion (node rc=$RS4_RC)" FAIL

node - "$PLUGIN_DIR" "$EVAL_CONFIG" > "$WORK/rs5.out" 2>&1 <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [plugin, cfgFile] = process.argv.slice(2);
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : e.name.endsWith('.sh') ? [path.join(d, e.name)] : []));
const keys = new Set();
for (const f of walk(path.join(plugin, 'hooks'))) {
  for (const line of fs.readFileSync(f, 'utf8').split('\n')) {
    if (/^\s*#/.test(line)) continue;
    for (const m of line.matchAll(/zensu_hook_enabled\s+"?([A-Za-z]+)/g)) keys.add(m[1]);
  }
}
keys.delete('autoTdd');
const cfg = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
const got = Object.keys(cfg.hooks || {}).sort();
const want = [...keys].sort();
const ok = want.length >= 15 && JSON.stringify(got) === JSON.stringify(want) && Object.values(cfg.hooks).every((v) => v === false)
  && JSON.stringify(Object.keys(cfg).sort()) === JSON.stringify(['context', 'hooks']) && JSON.stringify(cfg.context) === JSON.stringify({ compactionNudge: false });
process.stdout.write(`${want.length} ${ok ? 'ok' : `want=${want.join(',')} got=${got.join(',')}`}`);
process.exit(ok ? 0 : 1);
NODE
RS5_RC=$?
RS5_OUT="$(cat "$WORK/rs5.out")"
if [ "$RS5_RC" -eq 0 ]; then
  check "RS5 eval-config.json switches off the context nudge and every hook switch the hooks read except autoTdd, whose false value prints a notice (${RS5_OUT%% *})" PASS
else
  check "RS5 eval-config.json switches off the context nudge and every hook switch the hooks read except autoTdd ($RS5_OUT)" FAIL
fi

mkdir -p "$WORK/silence-ok" "$WORK/silence-leak" "$WORK/silence-vacuous"
if bash "$CAPTURE" silence "$PLUGIN_DIR" "$EVAL_CONFIG" "$WORK/silence-ok" "$PLAN_MESSAGE" >/dev/null 2>"$WORK/silence-ok.err" \
  && node -e '
    const fs = require("node:fs");
    const [dir, plugin] = process.argv.slice(1);
    const s = JSON.parse(fs.readFileSync(`${dir}/silence.json`, "utf8"));
    const hooks = JSON.parse(fs.readFileSync(`${plugin}/hooks/hooks.json`, "utf8")).hooks.UserPromptSubmit
      .flatMap((g) => g.hooks || []).map((h) => /hooks\/([A-Za-z0-9._-]+)\.sh/.exec(h.command || "")).filter(Boolean).map((m) => m[1]);
    const version = JSON.parse(fs.readFileSync(`${plugin}/.claude-plugin/plugin.json`, "utf8")).version;
    process.exit(s.leaks.length === 0 && s.control.chars > 0 && s.router_control && s.router_control.chars > 0 && s.version === version && hooks.length > 0
      && JSON.stringify(s.hooks) === JSON.stringify(hooks)
      && hooks.includes("user-prompt-tdd-reminder") && hooks.includes("user-prompt-intent-router") ? 0 : 1);
  ' "$WORK/silence-ok" "$PLUGIN_DIR"; then
  check "RS6 eval-config.json silences every UserPromptSubmit hook of this tree on a planning prompt, against live positive controls for the reminder and the intent router" PASS
else
  check "RS6 eval-config.json silences every UserPromptSubmit hook of this tree on a planning prompt ($(head -c 300 "$WORK/silence-ok.err"))" FAIL
fi

printf '%s' '{"hooks":{}}' > "$WORK/no-switches.json"
bash "$CAPTURE" silence "$PLUGIN_DIR" "$WORK/no-switches.json" "$WORK/silence-leak" "$PLAN_MESSAGE" >/dev/null 2>"$WORK/silence-leak.err"
RS6B_RC=$?
if [ "$RS6B_RC" -eq 70 ] && node -e '
    const s = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const has = (h) => s.leaks.some((l) => l.startsWith(`${h}:first:`)) && s.leaks.some((l) => l.startsWith(`${h}:repeat:`));
    process.exit(has("user-prompt-tdd-reminder") && has("user-prompt-intent-router") ? 0 : 1);
  ' "$WORK/silence-leak/silence.json"; then
  check "RS6b without the switches the silence check refuses and names the reminder and the router on both prompts" PASS
else
  check "RS6b without the switches the silence check refuses and names the reminder and the router (rc=$RS6B_RC)" FAIL
fi

FAKE_ROOT="$WORK/fake-root"
mkdir -p "$FAKE_ROOT/hooks"
printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/user-prompt-tdd-reminder.sh\""}]}]}}' > "$FAKE_ROOT/hooks/hooks.json"
printf '#!/bin/bash\nexit 0\n' > "$FAKE_ROOT/hooks/user-prompt-tdd-reminder.sh"
printf '#!/bin/bash\nexit 0\n' > "$FAKE_ROOT/hooks/session-start-session-control.sh"
bash "$CAPTURE" silence "$FAKE_ROOT" "$EVAL_CONFIG" "$WORK/silence-vacuous" "$PLAN_MESSAGE" >/dev/null 2>"$WORK/silence-vacuous.err"
RS6C_RC=$?
if [ "$RS6C_RC" -eq 70 ] && grep -qF 'so the silence check proves nothing' "$WORK/silence-vacuous.err"; then
  check "RS6c a runtime whose reminder prints nothing even unconfigured fails the positive control" PASS
else
  check "RS6c a runtime whose reminder prints nothing even unconfigured fails the positive control (rc=$RS6C_RC)" FAIL
fi

FAKE_EXIT="$WORK/fake-exit"
mkdir -p "$FAKE_EXIT/hooks" "$WORK/silence-exit"
cp "$FAKE_ROOT/hooks/hooks.json" "$FAKE_ROOT/hooks/session-start-session-control.sh" "$FAKE_EXIT/hooks/"
printf '#!/bin/bash\nexit 2\n' > "$FAKE_EXIT/hooks/user-prompt-tdd-reminder.sh"
bash "$CAPTURE" silence "$FAKE_EXIT" "$EVAL_CONFIG" "$WORK/silence-exit" "$PLAN_MESSAGE" >/dev/null 2>"$WORK/silence-exit.err"
RS6D_RC=$?
if [ "$RS6D_RC" -eq 70 ] && node -e '
    const s = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    process.exit(s.leaks.some((l) => l.startsWith("user-prompt-tdd-reminder:first:")) ? 0 : 1);
  ' "$WORK/silence-exit/silence.json"; then
  check "RS6d a prompt hook that exits non-zero under the eval config counts as a leak, not as silence" PASS
else
  check "RS6d a prompt hook that exits non-zero under the eval config counts as a leak, not as silence (rc=$RS6D_RC)" FAIL
fi

cat > "$WORK/control-ok.sh" <<'SH'
#!/bin/bash
[ -f "$ZENSU_CONFIG" ] && exit 0
printf '%s' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"control"}}'
SH
cat > "$WORK/control-exit.sh" <<'SH'
#!/bin/bash
[ -f "$ZENSU_CONFIG" ] && exit 0
exit 2
SH
RS6E_BAD=""
for RS6E_FAILING in user-prompt-tdd-reminder user-prompt-intent-router; do
  RS6E_ROOT="$WORK/fake-control-$RS6E_FAILING"
  mkdir -p "$RS6E_ROOT/hooks" "$WORK/silence-control-$RS6E_FAILING"
  printf '%s\n' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/user-prompt-tdd-reminder.sh\""},{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/user-prompt-intent-router.sh\""}]}]}}' > "$RS6E_ROOT/hooks/hooks.json"
  cp "$FAKE_ROOT/hooks/session-start-session-control.sh" "$RS6E_ROOT/hooks/"
  for RS6E_HOOK in user-prompt-tdd-reminder user-prompt-intent-router; do
    if [ "$RS6E_HOOK" = "$RS6E_FAILING" ]; then
      cp "$WORK/control-exit.sh" "$RS6E_ROOT/hooks/$RS6E_HOOK.sh"
    else
      cp "$WORK/control-ok.sh" "$RS6E_ROOT/hooks/$RS6E_HOOK.sh"
    fi
  done
  bash "$CAPTURE" silence "$RS6E_ROOT" "$EVAL_CONFIG" "$WORK/silence-control-$RS6E_FAILING" "$PLAN_MESSAGE" >/dev/null 2>"$WORK/silence-control-$RS6E_FAILING.err"
  RS6E_RC=$?
  if [ "$RS6E_RC" -ne 70 ] || ! grep -qF 'a positive control failed when fired without the eval config' "$WORK/silence-control-$RS6E_FAILING.err"; then
    RS6E_BAD="$RS6E_BAD $RS6E_FAILING:$RS6E_RC"
  fi
done
if [ -z "$RS6E_BAD" ]; then
  check "RS6e a positive control that fails without the eval config stops the silence check, for the reminder and for the intent router" PASS
else
  check "RS6e a failing positive control stops the silence check (got:$RS6E_BAD)" FAIL
fi

FAKE_USER_HOME="$WORK/user-home"
FAKE_HOME="$FAKE_USER_HOME/.claude"
CONFIG_DIR="$WORK/config-dir"
mkdir -p "$FAKE_HOME/plugins" "$CONFIG_DIR/plugins" "$FAKE_USER_HOME/runs" "$WORK/decoy"
printf '%s\n' '{"enabledPlugins":{"zensu@zensu":true,"other@market":true,"off@market":false}}' > "$FAKE_HOME/settings.json"
printf '%s\n' '{"enabledPlugins":{"zensu@zensu":true,"third@market":true}}' > "$CONFIG_DIR/settings.json"
node -e 'require("node:fs").writeFileSync(process.argv[1], JSON.stringify({ version: 2, plugins: { "zensu@zensu": [{ scope: "project", projectPath: "/elsewhere", installPath: process.argv[3] }, { scope: "user", installPath: process.argv[2] }] } }))' \
  "$FAKE_HOME/plugins/installed_plugins.json" "$PLUGIN_DIR" "$WORK/decoy"
cp "$FAKE_HOME/plugins/installed_plugins.json" "$CONFIG_DIR/plugins/installed_plugins.json"
for RS7_CASE in "none|$CODE_MESSAGE||other@market" "router|$PLAN_MESSAGE|user-prompt-intent-router|third@market"; do
  RS7_SOURCE="${RS7_CASE%%|*}"
  RS7_REST="${RS7_CASE#*|}"
  RS7_MESSAGE="${RS7_REST%%|*}"
  RS7_REST="${RS7_REST#*|}"
  RS7_HOOK="${RS7_REST%%|*}"
  RS7_OFF="${RS7_REST#*|}"
  if [ "$RS7_SOURCE" = "none" ]; then
    env -u CLAUDE_CONFIG_DIR -u ROUTE_EVAL_CLAUDE_HOME HOME="$FAKE_USER_HOME" ROUTE_EVAL_RUN_PARENT="$FAKE_USER_HOME/runs" ROUTE_EVAL_DRY_RUN=1 \
      bash "$PROVIDER" "route-eval-source: $RS7_SOURCE"$'\n'"$RS7_MESSAGE"$'\n' >"$WORK/dry-$RS7_SOURCE.out" 2>"$WORK/dry-$RS7_SOURCE.err"
  else
    env -u ROUTE_EVAL_CLAUDE_HOME HOME="$FAKE_USER_HOME" CLAUDE_CONFIG_DIR="$CONFIG_DIR" ROUTE_EVAL_RUN_PARENT="$FAKE_USER_HOME/runs" ROUTE_EVAL_DRY_RUN=1 \
      bash "$PROVIDER" "route-eval-source: $RS7_SOURCE"$'\n'"$RS7_MESSAGE"$'\n' >"$WORK/dry-$RS7_SOURCE.out" 2>"$WORK/dry-$RS7_SOURCE.err"
  fi
  RS7_RC=$?
  if [ "$RS7_RC" -eq 0 ] && node -e '
      const fs = require("node:fs");
      const [file, source, message, hook, evalDir, plugin, off] = process.argv.slice(1);
      const lines = fs.readFileSync(file, "utf8").split("\n");
      const after = (prefix) => { const l = lines.find((x) => x.startsWith(prefix)); return l === undefined ? null : l.slice(prefix.length); };
      const settings = JSON.parse(after("ROUTE_EVAL_DRY_RUN: settings "));
      const env = after("ROUTE_EVAL_DRY_RUN: env ");
      const capture = JSON.parse(after("[route-eval-capture] "));
      const version = JSON.parse(fs.readFileSync(`${plugin}/.claude-plugin/plugin.json`, "utf8")).version;
      const pre = settings.hooks.PreToolUse;
      const prompt = settings.hooks.UserPromptSubmit;
      const ok = pre.length === 1 && pre[0].matcher === "*" && pre[0].hooks[0].command === `node '"'"'${evalDir}/lib/decision-probe.js'"'"'`
        && (source === "none" ? prompt === undefined : prompt[0].hooks[0].command === `node '"'"'${evalDir}/lib/inject-context.js'"'"'`)
        && JSON.stringify(settings.env) === JSON.stringify({ ZENSU_CONFIG: `${evalDir}/eval-config.json` })
        && JSON.stringify(settings.enabledPlugins) === JSON.stringify({ [off]: false })
        && env === `ZENSU_CONFIG=${evalDir}/eval-config.json ZENSU_WRAPPER_SETTINGS=<run>/settings.json ZENSU_ROUTE_EVAL_DIR=<run> ZENSU_ROUTE_EVAL_HOOK=${hook}`
        && after("ROUTE_EVAL_DRY_RUN: message ") === message
        && capture.route_source === source && capture.hook === hook
        && capture.live.root === plugin && capture.live.version === version && capture.live.leaks === 0 && capture.live.control_chars > 0 && capture.live.silent_hooks > 0
        && (source === "router" ? capture.live.router_control_chars > 0 : capture.live.router_control_chars === 0);
      process.exit(ok ? 0 : 1);
    ' "$WORK/dry-$RS7_SOURCE.out" "$RS7_SOURCE" "$RS7_MESSAGE" "$RS7_HOOK" "$EVAL_DIR" "$PLUGIN_DIR" "$RS7_OFF"; then
    check "RS7 the provider dry run for '$RS7_SOURCE' reads the user-scoped install from $([ "$RS7_SOURCE" = none ] && echo '~/.claude' || echo 'CLAUDE_CONFIG_DIR'), pins ZENSU_CONFIG, writes the probe, the inject hook only when a line is delivered, the other plugins off and an attested capture with the intent router's control" PASS
  else
    check "RS7 the provider dry run for '$RS7_SOURCE' (rc=$RS7_RC, $(head -c 300 "$WORK/dry-$RS7_SOURCE.err"))" FAIL
  fi
done
if [ -z "$(ls -A "$FAKE_USER_HOME/runs")" ]; then
  check "RS7a the provider removes its run directory when it exits" PASS
else
  check "RS7a the provider removes its run directory when it exits" FAIL
fi

mkdir -p "$WORK/home-disabled/plugins" "$WORK/home-missing/plugins"
printf '%s\n' '{"enabledPlugins":{"zensu@zensu":false}}' > "$WORK/home-disabled/settings.json"
cp "$FAKE_HOME/plugins/installed_plugins.json" "$WORK/home-disabled/plugins/installed_plugins.json"
cp "$FAKE_HOME/settings.json" "$WORK/home-missing/settings.json"
node -e 'require("node:fs").writeFileSync(process.argv[1], JSON.stringify({ version: 2, plugins: { "zensu@zensu": [{ scope: "project", projectPath: "/elsewhere", installPath: process.argv[2] }] } }))' \
  "$WORK/home-missing/plugins/installed_plugins.json" "$PLUGIN_DIR"
HOME="$FAKE_USER_HOME" ROUTE_EVAL_CLAUDE_HOME="$FAKE_HOME" ROUTE_EVAL_RUN_PARENT="$WORK/outside-runs" ROUTE_EVAL_DRY_RUN=1 \
  bash "$PROVIDER" "route-eval-source: ask"$'\n'"hi" >/dev/null 2>"$WORK/outside.err"
RS7B_OUTSIDE_RC=$?
RS7B_BAD=""
{ [ "$RS7B_OUTSIDE_RC" -eq 64 ] && grep -qF 'must lie under HOME' "$WORK/outside.err" && [ -z "$(ls -A "$WORK/outside-runs")" ]; } \
  || RS7B_BAD=" [run parent outside HOME rc=$RS7B_OUTSIDE_RC]"
for RS7B_CASE in "64|$FAKE_HOME|" "64|$FAKE_HOME|route-eval-source: bogus"$'\n'"hi" "64|$FAKE_HOME|route-eval-source: ask" \
  "64|$FAKE_HOME|route-eval-source: ask"$'\n\n' "64|$FAKE_HOME|hi"$'\n'"route-eval-source: ask" \
  "78|$WORK/home-disabled|route-eval-source: ask"$'\n'"hi" "78|$WORK/home-missing|route-eval-source: ask"$'\n'"hi"; do
  RS7B_WANT="${RS7B_CASE%%|*}"
  RS7B_REST="${RS7B_CASE#*|}"
  RS7B_HOME="${RS7B_REST%%|*}"
  RS7B_PROMPT="${RS7B_REST#*|}"
  HOME="$FAKE_USER_HOME" ROUTE_EVAL_CLAUDE_HOME="$RS7B_HOME" ROUTE_EVAL_RUN_PARENT="$FAKE_USER_HOME/runs" ROUTE_EVAL_DRY_RUN=1 \
    bash "$PROVIDER" "$RS7B_PROMPT" >/dev/null 2>&1
  RS7B_RC=$?
  [ "$RS7B_RC" -eq "$RS7B_WANT" ] || RS7B_BAD="$RS7B_BAD [want $RS7B_WANT got $RS7B_RC: $(printf '%s' "$RS7B_PROMPT" | head -1)]"
done
if [ -z "$RS7B_BAD" ] && [ -z "$(ls -A "$FAKE_USER_HOME/runs")" ]; then
  check "RS7b the provider refuses a malformed prompt and a run parent outside HOME with 64, and a disabled zensu@zensu or one without a user-scoped install with 78, before it creates a run" PASS
else
  check "RS7b the provider refusals:$RS7B_BAD" FAIL
fi

if [ "$(grep -cF 'CMD+=(--settings "$ZENSU_WRAPPER_SETTINGS")' "$WRAPPER")" = "1" ] \
  && grep -qF 'ZENSU_WRAPPER_SETTINGS must be an absolute path' "$WRAPPER" \
  && grep -qF 'ZENSU_WRAPPER_SETTINGS must name a regular file that is not a symlink' "$WRAPPER" \
  && grep -qF 'ZENSU_WRAPPER_SETTINGS cannot be combined with the reset-review-limit attestation' "$WRAPPER" \
  && grep -qF 'export ZENSU_WRAPPER_SETTINGS="$RUN_DIR/settings.json"' "$PROVIDER" \
  && grep -qF 'export ZENSU_CONFIG="$EVAL_CONFIG"' "$PROVIDER" \
  && grep -qF 'bash "$WRAPPER" "$MESSAGE" "$OPTIONS_JSON"' "$PROVIDER"; then
  check "RS8 the wrapper passes ZENSU_WRAPPER_SETTINGS as --settings behind its refusals, and the provider sets it with the eval config" PASS
else
  check "RS8 the wrapper passes ZENSU_WRAPPER_SETTINGS as --settings behind its refusals, and the provider sets it with the eval config" FAIL
fi

if node --test "$FIXTURE_TEST" >"$WORK/fixture.out" 2>&1 && unit_cases_meet_floor "$WORK/fixture.out" 2; then
  check "RS9 the cart-app fixture's own tests pass, so the model starts from a green tree" PASS
else
  check "RS9 the cart-app fixture's own tests pass (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" FAIL
fi

RS10_BAD=""
for RS10_NEEDLE in 'control-no-injection.yaml' 'ask-headless-code-change.yaml' 'decided-tdd-code-change.yaml' \
  'decided-direct-code-change.yaml' 'router-genuine-planning.yaml' 'preflight/channel-check.yaml' 'preflight/read-check.yaml' \
  'promptfoo eval --no-cache --no-share -c promptfooconfig-preflight.yaml' 'promptfoo eval --no-cache --no-share -c promptfooconfig.yaml' \
  'Run the preflight first' 'Always pass `--no-cache`' \
  'cost API credits' 'local-only' 'route-short-line-graders.test.js' 'test-route-short-line-eval.sh' '## Known confounds'; do
  grep -qF -- "$RS10_NEEDLE" "$README" || RS10_BAD="$RS10_BAD [$RS10_NEEDLE]"
done
for RS10_SCENARIO in "$EVAL_DIR"/scenarios/*.yaml; do
  grep -qF -- "$(basename "$RS10_SCENARIO")" "$README" || RS10_BAD="$RS10_BAD [$(basename "$RS10_SCENARIO")]"
done
if [ -z "$RS10_BAD" ]; then
  check "RS10 the README names every scenario, the uncached preflight-first run, the cost, the local-only status, the unit file and the known confounds" PASS
else
  check "RS10 the README lacks:$RS10_BAD" FAIL
fi

if grep -qF 'evals/route-short-line-reaction' "$LEDGER_RULE"; then
  check "RS11 the prompt-ledger rule points at the reaction eval for the short lines" PASS
else
  check "RS11 the prompt-ledger rule points at the reaction eval for the short lines" FAIL
fi

finish
