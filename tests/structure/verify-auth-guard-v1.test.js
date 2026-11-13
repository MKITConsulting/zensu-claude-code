'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const PLUGIN = path.resolve(__dirname, '..', '..');
const LIB = path.join(PLUGIN, 'hooks', 'lib');
const DISPATCHER = path.join(LIB, 'hook-dispatch-v1.js');
const guard = require(path.join(LIB, 'verify-auth-guard-v1.js'));
const authState = require(path.join(LIB, 'verify-auth-state-v1.js'));
const consent = require(path.join(LIB, 'verify-consent-v1.js'));
const registration = require(path.join(LIB, 'hook-registration-v1.js'));
const dispatch = require(DISPATCHER);
const WRAPPER = path.join(PLUGIN, 'hooks', authState.AUTH_GUARD_HOOK_FILE);

const PROJECT = '/work/app';
const RUN = `${PROJECT}/.zensu/verify-feature-runs/run-a1`;
const STATE = `${RUN}/auth/storage-state.json`;
const LEAD = 'Zensu verify-auth guard: ';
const POSIX_ONLY = process.platform === 'win32' ? 'the wrapper and symlink cases need a POSIX shell and unprivileged symlinks' : false;

const payload = (tool, input, cwd = PROJECT) => ({ hook_event_name: 'PreToolUse', tool_name: tool, tool_input: input, cwd });
const verdict = (tool, input, cwd) => guard.decide({ payload: payload(tool, input, cwd) });

function tempDir(t, prefix) {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('the guard check is registered once, in-process and fail-open, on exactly the tools the guard judges', () => {
  const entries = registration.DISPATCHED_CHECKS.filter((check) => check.name === 'verify-auth-guard');
  assert.equal(entries.length, 1);
  const [entry] = entries;
  assert.deepEqual({ ...entry }, {
    event: 'PreToolUse', name: 'verify-auth-guard', matcher: guard.GUARD_MATCHER, script: authState.AUTH_GUARD_HOOK_FILE, body: null, failure: 'open',
  });
  assert.deepEqual([...guard.GUARD_TOOLS], [...authState.AUTH_GUARD_TOOLS]);
  for (const tool of guard.GUARD_TOOLS) assert.equal(registration.hostMatcherCovers(entry.matcher, tool), registration.REGISTRATION.REGISTERED, tool);
  for (const tool of ['WebFetch', 'WebSearch', 'Agent', 'Task', 'TodoWrite', 'Read2', 'BashOutput']) {
    assert.equal(registration.hostMatcherCovers(entry.matcher, tool), registration.REGISTRATION.UNREGISTERED, tool);
  }
  for (const tool of guard.GUARD_TOOLS.filter((name) => !['Bash', 'PowerShell'].includes(name))) assert.ok(guard.PATH_FIELDS[tool], tool);
  assert.equal(consent.authGuardRegistered(PLUGIN), registration.REGISTRATION.REGISTERED);
  const wrapper = fs.readFileSync(WRAPPER, 'utf8');
  assert.match(wrapper, /zensu_hook_dispatch pre verify-auth-guard "\$_zensu_hooks"/);
  assert.match(wrapper, /ZENSU_GUARD_CALLER_CWD="\$\(pwd -P/);
  if (process.platform !== 'win32') assert.notEqual(fs.statSync(WRAPPER).mode & 0o111, 0);
});

test('a file tool that reaches a run auth directory is denied, in every spelling of the path', () => {
  const denied = [
    ['Read', { file_path: STATE }],
    ['Read', { file_path: `${RUN}/auth` }],
    ['Read', { file_path: `${RUN}/auth/artifact/nested/state.json` }],
    ['Read', { file_path: '.zensu/verify-feature-runs/run-a1/auth/storage-state.json' }],
    ['Read', { file_path: 'auth/storage-state.json' }, RUN],
    ['Read', { file_path: `${RUN}/output/../auth/storage-state.json` }],
    ['Read', { file_path: `${PROJECT}/.ZENSU/Verify-Feature-Runs/run-a1/AUTH/storage-state.json` }],
    ['Read', { file_path: 'C:\\work\\app\\.zensu\\verify-feature-runs\\run-a1\\auth\\storage-state.json' }],
    ['Read', { file_path: `${RUN}/auth/.storage-state.json.0123456789ab.tmp` }],
    ['Read', { file_path: `${RUN}/auth./storage-state.json` }],
    ['Edit', { file_path: STATE, old_string: 'a', new_string: 'b' }],
    ['Write', { file_path: STATE, content: '{}' }],
    ['MultiEdit', { file_path: STATE, edits: [] }],
    ['NotebookEdit', { notebook_path: `${RUN}/auth/notes.ipynb`, new_source: '' }],
  ];
  for (const [tool, input, cwd] of denied) {
    const result = verdict(tool, input, cwd);
    assert.equal(result.deny, true, `${tool} ${JSON.stringify(input)}`);
    assert.equal(result.reason, guard.REASONS.PATH);
    assert.ok(guard.namesAuthPath(result.target), result.target);
  }
  const allowed = [
    ['Read', { file_path: `${RUN}/${consent.RUN_CONFIG_NAME}` }],
    ['Read', { file_path: `${RUN}/${consent.RUN_OUTPUT_DIR_NAME}/page.png` }],
    ['Read', { file_path: `${RUN}/authority/notes.txt` }],
    ['Read', { file_path: `${RUN}/auth/../browser/page.png` }],
    ['Read', { file_path: `${PROJECT}/.zensu/verify-feature-runs` }],
    ['Read', { file_path: `${PROJECT}/.zensu/verify-feature-runs/auth/${consent.RUN_CONFIG_NAME}` }],
    ['Read', { file_path: `${PROJECT}/src/auth/session.js` }],
    ['Read', { file_path: `${PROJECT}/auth/storage-state.json` }],
    ['Edit', { file_path: `${PROJECT}/docs/verify-feature-runs.md`, old_string: 'a', new_string: 'b' }],
    ['Write', { file_path: `${PROJECT}/.zensu/runtime.yaml`, content: 'auth:\n  mode: login-script\n' }],
  ];
  for (const [tool, input, cwd] of allowed) assert.deepEqual(verdict(tool, input, cwd), { deny: false, reason: guard.REASONS.CLEAN }, `${tool} ${JSON.stringify(input)}`);
  assert.deepEqual(verdict('WebFetch', { url: `file://${STATE}` }), { deny: false, reason: guard.REASONS.OTHER_TOOL });
});

test('a link into a run auth directory is denied through the path it resolves to', { skip: POSIX_ONLY }, (t) => {
  const root = tempDir(t, 'zensu-auth-guard-');
  const auth = path.join(root, '.zensu', 'verify-feature-runs', 'run-a1', 'auth');
  fs.mkdirSync(auth, { recursive: true });
  fs.writeFileSync(path.join(auth, 'storage-state.json'), '{"cookies":[],"origins":[]}');
  fs.mkdirSync(path.join(root, 'notes'));
  fs.symlinkSync(path.join(auth, 'storage-state.json'), path.join(root, 'notes', 'state.json'));
  fs.symlinkSync(auth, path.join(root, 'notes', 'dir'));
  const viaFile = verdict('Read', { file_path: path.join(root, 'notes', 'state.json') }, root);
  assert.equal(viaFile.deny, true);
  assert.equal(viaFile.target, path.join(auth, 'storage-state.json'));
  assert.equal(verdict('Read', { file_path: 'notes/dir/storage-state.json' }, root).deny, true);
  assert.equal(verdict('Grep', { pattern: 'value', path: path.join(root, 'notes', 'dir') }, root).deny, true);
  assert.equal(verdict('Read', { file_path: path.join(root, 'notes', 'missing.json') }, root).deny, false);
  fs.symlinkSync(path.join(root, '.zensu', 'verify-feature-runs'), path.join(root, 'runs'));
  fs.symlinkSync(path.join(root, '.zensu', 'verify-feature-runs', 'run-a1'), path.join(root, 'run'));
  assert.equal(verdict('Grep', { pattern: 'value', path: path.join(root, 'runs') }, root).deny, true);
  assert.equal(verdict('Glob', { pattern: '**/*.json', path: path.join(root, 'run') }, root).deny, true);
  assert.equal(verdict('Grep', { pattern: 'value', path: 'run' }, root).deny, true);
});

test('a search is denied when its root or its pattern reaches a run auth directory, and allowed otherwise', () => {
  const runs = `${PROJECT}/.zensu/verify-feature-runs`;
  const denied = [
    ['Grep', { pattern: 'sid', path: RUN }],
    ['Grep', { pattern: 'sid', path: RUN, glob: '*.json' }],
    ['Grep', { pattern: 'sid', path: runs, glob: '**/*' }],
    ['Grep', { pattern: 'sid', path: `${RUN}/auth` }],
    ['Grep', { pattern: 'sid', path: PROJECT, glob: '.zensu/verify-feature-runs/*/auth/*' }],
    ['Grep', { pattern: 'sid', glob: `${RUN}/auth/*.json` }],
    ['Glob', { pattern: '.zensu/verify-feature-runs/**' }],
    ['Glob', { pattern: '*/a{u,x}th/*', path: runs }],
    ['Glob', { pattern: '[a]uth/*', path: RUN }],
    ['Glob', { pattern: '*/storage-state.json', path: RUN }],
    ['Glob', { pattern: '**/*.png', path: RUN }],
    ['Glob', { pattern: 'state.json', path: `${RUN}/auth/artifact` }],
    ['Grep', { pattern: 'sid', path: RUN, glob: '!browser/**' }],
    ['Glob', { pattern: '[[:alpha:]]uth/*', path: RUN }],
    ['Glob', { pattern: '[]a]uth/*', path: RUN }],
    ['Grep', { pattern: 'sid', path: RUN, glob: '[!]]uth/*' }],
    ['Glob', { pattern: '[[=a=]]uth/*', path: RUN }],
    ['Grep', { pattern: 'sid', path: RUN, glob: 'a\\uth/*' }],
    ['Glob', { pattern: '\\a\\u\\t\\h/*', path: RUN }],
    ['Grep', { pattern: 'sid', path: RUN, glob: '[a[=]u[t=]h/*' }],
    ['Glob', { pattern: '[a[:]u[t:]h/*', path: RUN }],
    ['Glob', { pattern: '[a[.]u[t.]h/*', path: RUN }],
    ['Grep', { pattern: 'sid', path: RUN, glob: '[a{]u{t,x}h/*' }],
    ['Glob', { pattern: '(auth)/*', path: RUN }],
    ['Glob', { pattern: '*[ht]/*', path: RUN }],
  ];
  for (const [tool, input] of denied) assert.equal(verdict(tool, input).deny, true, `${tool} ${JSON.stringify(input)}`);
  const allowed = [
    ['Grep', { pattern: 'sid', path: `${RUN}/${consent.RUN_OUTPUT_DIR_NAME}` }],
    ['Grep', { pattern: 'sid', path: RUN, glob: `${consent.RUN_OUTPUT_DIR_NAME}/*.txt` }],
    ['Grep', { pattern: 'sid', path: PROJECT }],
    ['Grep', { pattern: 'verify-feature-runs/run-a1/auth', path: `${PROJECT}/docs` }],
    ['Glob', { pattern: `${consent.RUN_OUTPUT_DIR_NAME}/*.png`, path: RUN }],
    ['Glob', { pattern: '*.png', path: `${RUN}/${consent.RUN_OUTPUT_DIR_NAME}` }],
    ['Glob', { pattern: `*/${consent.RUN_CONFIG_NAME}`, path: runs }],
    ['Glob', { pattern: `*/${consent.RUN_OUTPUT_DIR_NAME}/*.png`, path: runs }],
    ['Glob', { pattern: 'src/**/*.ts' }],
  ];
  for (const [tool, input] of allowed) assert.equal(verdict(tool, input).deny, false, `${tool} ${JSON.stringify(input)}`);
});

test('a shell command that names a run auth path is denied in every spelling the shell joins, and the skill\'s own calls pass', () => {
  const denied = [
    ['Bash', `cat ${STATE}`],
    ['Bash', "cat '.zensu/verify-feature-runs/run-a1/auth/storage-state.json'"],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/au""th/storage-state.json'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/a\\uth/state.json'],
    ['Bash', 'cat .zensu/verify-feature-\\\nruns/run-a1/auth/state.json'],
    ['Bash', 'cp .zensu/verify-feature-runs/run-a1/auth/* /tmp/copy'],
    ['Bash', 'ls -la .zensu/verify-feature-runs/*/auth'],
    ['Bash', 'tar czf out.tgz .zensu/verify-feature-runs/run-a1/{auth,browser}'],
    ['Bash', 'cd .zensu/verify-feature-runs/run-a1 && cat auth/storage-state.json'],
    ['Bash', 'python3 -c "print(open(\'.zensu/verify-feature-runs/run-a1/auth/storage-state.json\').read())"'],
    ['Bash', 'grep -r token .zensu/verify-feature-runs/run-a1/auth'],
    ['Bash', 'find .zensu/verify-feature-runs -name storage-state.json'],
    ['PowerShell', 'Get-Content .zensu/verify-feature-runs/run-a1/auth/storage-state.json'],
    ['PowerShell', "Get-Content ('.zensu/verify-feature-runs/run-a1/au' + 'th/state.json')"],
    ['PowerShell', 'Get-Content .zensu/verify-feature-runs/run-a1/a`uth/state.json'],
    ['PowerShell', 'Get-Content .zensu\\verify-feature-runs\\run-a1\\auth\\state.json'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1{/auth,}/*.json'],
    ['Bash', 'cat .zensu/{verify-feature-runs/run-a1/auth,x}/state.json'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/{x,{y,auth}}/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[[:alpha:]]uth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[]a]uth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[!]]uth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[[=a=]]uth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[[:a]uth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/{a,b,c,d,e,f,g,h,i}{a,b,c,d,e,f,g,h,i}{a,b,c,d,e,f,g,h,i}'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[a[=]u[t=]h/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[a"]"]uth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[a\\]]uth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/[a{]u{t,x}h/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/{a..z}uth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/(auth)/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/(auth|x)/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/@(auth)/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/authx#/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/auth~x/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/*h/*'],
    ['Bash', 'ls .zensu/verify-feature-runs/run-a1/*[ht]'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/$D/*'],
    ['Bash', 'cat ".zensu/verify-feature-runs/run-a1/a b/../auth/"*'],
    ['Bash', "cat '.zensu/verify-feature-runs/run-a1/a;b/../auth/'*"],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/x/.?/auth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/<->/../auth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs/run-a1/browser/**/../../auth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs*/run-a1/auth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs{,/x}/run-a1/auth/*'],
    ['Bash', 'cat .zensu/verify-feature-runs{/x/y/z,/run-a1/auth}/*'],
    ['PowerShell', 'Get-ChildItem .zensu/verify-feature-runs/run-a1/[a]uth'],
  ];
  for (const [tool, command] of denied) {
    const result = verdict(tool, { command });
    assert.deepEqual(result, { deny: true, reason: guard.REASONS.COMMAND }, `${tool} ${command}`);
  }
  const allowed = [
    ['Bash', `rm -rf ${RUN}`],
    ['Bash', 'rm -rf .zensu/verify-feature-runs/run-a1'],
    ['Bash', 'ls .zensu/verify-feature-runs'],
    ['Bash', `node scripts/verify-browser-config.js --run-dir ${RUN} --mode local --origin http://127.0.0.1:4300 --login-recipe ${PROJECT}/.zensu/runtime.yaml`],
    ['Bash', `playwright-cli -s=${authState.AUTH_SESSION_PREFIX}run-a1 open --config=${RUN}/${consent.RUN_CONFIG_NAME}`],
    ['Bash', `cat ${RUN}/${consent.RUN_OUTPUT_DIR_NAME}/console.txt`],
    ['Bash', 'cat src/auth/session.js'],
    ['Bash', 'git status --short'],
    ['PowerShell', 'Get-ChildItem .zensu/verify-feature-runs'],
    ['Bash', 'echo {a,b,c,d,e,f,g,h,i}{a,b,c,d,e,f,g,h,i}{a,b,c,d,e,f,g,h,i}'],
    ['Bash', `cat .zensu/verify-feature-runs/run-a1/${consent.RUN_CONFIG_NAME} | jq .`],
    ['Bash', `x=$(cat .zensu/verify-feature-runs/run-a1/${consent.RUN_CONFIG_NAME});echo "$x"`],
    ['Bash', `ls -l ".zensu/verify-feature-runs/run-a1/${consent.RUN_OUTPUT_DIR_NAME}/page 1.png"`],
    ['Bash', 'ls .zensu/verify-feature-runs/run-a1/*.png'],
    ['Bash', `ls .zensu/verify-feature-runs/*/${consent.RUN_OUTPUT_DIR_NAME}/*.png`],
    ['Bash', `ls .zensu/verify-feature-runs/run-a1/${consent.RUN_OUTPUT_DIR_NAME}/**/*.png`],
    ['Bash', 'RUN_DIR="$GIT_ROOT/.zensu/verify-feature-runs/$(openssl rand -hex 6)"'],
    ['PowerShell', `Get-Content .zensu/verify-feature-runs/run-a1/${consent.RUN_CONFIG_NAME} -Raw | ConvertFrom-Json`],
  ];
  for (const [tool, command] of allowed) assert.deepEqual(verdict(tool, { command }), { deny: false, reason: guard.REASONS.CLEAN }, `${tool} ${command}`);
  assert.deepEqual(verdict('Bash', {}), { deny: false, reason: guard.REASONS.CLEAN });
});

test('a browser CLI call that names a verify-feature run directory needs a zensu-verify session, and both markers derive from their owners', () => {
  const cliVersion = require(path.join(LIB, 'playwright-cli-version-v1.js'));
  assert.equal(guard.SESSION_MARKER, consent.SESSION_PREFIX);
  assert.deepEqual([...guard.CLI_WORDS], [...cliVersion.BINARY_NAMES, cliVersion.PACKAGE_NAME]);
  const config = `--config=${RUN}/${consent.RUN_CONFIG_NAME}`;
  const denied = [
    ['Bash', `playwright-cli -s=mine open ${config} http://127.0.0.1:4300/`],
    ['Bash', `playwright-cli open ${config}`],
    ['Bash', `/usr/local/bin/playwright-cli -s=mine open ${config}`],
    ['Bash', `npx @playwright/cli@0.1.21 -s=mine open ${config}`],
    ['Bash', `play''wright-cli -s=mine open ${config}`],
    ['Bash', `cd ${RUN} && playwright-cli -s=mine open --config=${consent.RUN_CONFIG_NAME}`],
    ['PowerShell', `playwright-cli -s=mine open ${config}`],
  ];
  for (const [tool, command] of denied) assert.deepEqual(verdict(tool, { command }), { deny: true, reason: guard.REASONS.SESSION }, `${tool} ${command}`);
  const allowed = [
    `playwright-cli -s=${authState.AUTH_SESSION_PREFIX}run-a1 open ${config}`,
    `playwright-cli -s=${consent.SESSION_PREFIX}run-a1 open ${config}`,
    `cat ${RUN}/${consent.RUN_CONFIG_NAME}`,
    'playwright-cli -s=mine open --config=/tmp/other.json',
    'node x.js --run-dir /u/playwright-cli-tests/.zensu/verify-feature-runs/r',
  ];
  for (const command of allowed) assert.deepEqual(verdict('Bash', { command }), { deny: false, reason: guard.REASONS.CLEAN }, command);
  const reason = guard.denyReason({ deny: true, reason: guard.REASONS.SESSION });
  assert.ok(reason.startsWith(LEAD));
  assert.ok(reason.includes('-s=<session> exactly as the helper printed it'));
  assert.ok(!reason.includes('playwright-cli'));
});

test('a payload the dispatcher could not parse is refused exactly when it names a verify-feature run, and both marker tests agree', () => {
  const marked = [
    `{"tool_name":"Read","tool_input":{"file_path":"${STATE}"`,
    '{"tool_name":"Bash","tool_input":{"command":"cat .zensu/verify\\u002dfeature-runs/r/auth/x"',
    '{"tool_name":"Bash","tool_input":{"command":"cat .zensu/verify-feature-\\"runs/r"',
    '{"command":"ls VERIFY-FEATURE-RUNS"',
    "{'command':'cat .zensu/verify-feature-r`uns/x'",
  ];
  const unmarked = ['', '{"tool_name":"Read","tool_input":{"file_path":"/work/app/src/x.js"', 'verify feature runs', 'verify-feature-run'];
  for (const raw of marked) {
    assert.deepEqual(guard.decide({ payload: undefined, raw }), { deny: true, reason: guard.REASONS.UNREADABLE }, raw);
    assert.equal(guard.marked(raw), true, raw);
    assert.equal(dispatch.authGuardMarked(raw), true, raw);
  }
  for (const raw of unmarked) {
    assert.deepEqual(guard.decide({ payload: undefined, raw }), { deny: false, reason: guard.REASONS.UNMARKED }, raw);
    assert.equal(guard.marked(raw), false, raw);
    assert.equal(dispatch.authGuardMarked(raw), false, raw);
  }
  assert.equal(guard.decide({ payload: [STATE], raw: STATE }).deny, true);
  assert.equal(guard.decide({ payload: null, raw: '{}' }).deny, false);
});

test('the deny reason names the reached path without control bytes and names the remedy instead of a retry', () => {
  const pathDeny = guard.denyOutput({ deny: true, reason: guard.REASONS.PATH, target: `${RUN}/auth/a\nb\u001b[31m.json` });
  assert.deepEqual(Object.keys(pathDeny.hookSpecificOutput), ['hookEventName', 'permissionDecision', 'permissionDecisionReason']);
  assert.equal(pathDeny.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.equal(pathDeny.hookSpecificOutput.permissionDecision, 'deny');
  const text = pathDeny.hookSpecificOutput.permissionDecisionReason;
  assert.ok(text.startsWith(LEAD));
  assert.ok(text.includes(`(${RUN}/auth/a?b?[31m.json)`), text);
  assert.doesNotMatch(text, /[\u0000-\u001f\u007f]/);
  for (const phrase of ['Do not retry through another tool, path spelling or command', 'use the Grep tool or a commit message file', 'Phase 4 discards what is left with the run-config helper\'s --discard-state']){
    assert.ok(text.includes(phrase), phrase);
  }
  assert.ok(guard.denyReason({ deny: true, reason: guard.REASONS.COMMAND }).includes('(the command names a path inside a run auth directory)'));
  assert.ok(guard.denyReason({ deny: true, reason: guard.REASONS.UNREADABLE }).includes('(the payload could not be read and names a verify-feature run)'));
});

test('the dispatcher runs the guard alone, and refuses only a marked payload when its module is missing, linked or broken', (t) => {
  const run = (dispatcher, input, cwd = PROJECT) => spawnSync(process.execPath, [dispatcher, 'pre', '--only', 'verify-auth-guard'], {
    input, encoding: 'utf8', timeout: 30000, env: { ...process.env, CLAUDE_PLUGIN_ROOT: '', ZENSU_GUARD_CALLER_CWD: cwd },
  });
  const deniedInput = JSON.stringify(payload('Read', { file_path: STATE }));
  const cleanInput = JSON.stringify(payload('Read', { file_path: `${PROJECT}/src/index.js` }));
  const denied = run(DISPATCHER, deniedInput);
  assert.equal(denied.status, 0, denied.stderr);
  const decision = JSON.parse(denied.stdout).hookSpecificOutput;
  assert.equal(decision.permissionDecision, 'deny');
  assert.ok(decision.permissionDecisionReason.startsWith(LEAD));
  const relative = run(DISPATCHER, JSON.stringify({ tool_name: 'Read', tool_input: { file_path: 'auth/storage-state.json' } }), RUN);
  assert.equal(JSON.parse(relative.stdout).hookSpecificOutput.permissionDecision, 'deny');
  const clean = run(DISPATCHER, cleanInput);
  assert.equal(clean.status, 0, clean.stderr);
  assert.equal(clean.stdout, '');

  const root = tempDir(t, 'zensu-auth-guard-root-');
  fs.cpSync(path.join(PLUGIN, 'hooks'), path.join(root, 'hooks'), { recursive: true });
  const copy = path.join(root, 'hooks', 'lib', 'hook-dispatch-v1.js');
  const module = path.join(root, 'hooks', 'lib', 'verify-auth-guard-v1.js');
  const broken = [
    ['absent', () => fs.rmSync(module), 'its decision module is absent or a symlink'],
    ['linked', () => { if (process.platform !== 'win32') fs.symlinkSync(path.join(LIB, 'verify-auth-guard-v1.js'), module); }, 'its decision module is absent or a symlink'],
    ['throwing', () => { fs.rmSync(module, { force: true }); fs.writeFileSync(module, "'use strict';\nthrow new Error('broken');\n"); }, 'its decision module failed'],
  ];
  for (const [label, damage, cause] of broken) {
    if (label === 'linked' && process.platform === 'win32') continue;
    damage();
    const refused = run(copy, deniedInput);
    assert.equal(refused.status, 0, `${label}: ${refused.stderr}`);
    const reason = JSON.parse(refused.stdout).hookSpecificOutput.permissionDecisionReason;
    assert.equal(reason, `${LEAD}refused a call that names a verify-feature run directory because ${cause}; reinstall the plugin or run /zensu:doctor`, label);
    const quiet = run(copy, cleanInput);
    assert.equal(quiet.stdout, '', label);
    fs.rmSync(module, { force: true });
  }
});

test('the entry-point wrapper dispatches the guard with node and still refuses a marked payload without it', { skip: POSIX_ONLY }, (t) => {
  const bash = ['/bin/bash', '/usr/bin/bash'].find((candidate) => fs.existsSync(candidate));
  assert.ok(bash, 'a POSIX host has bash');
  const deniedInput = JSON.stringify(payload('Read', { file_path: STATE }));
  const cleanInput = JSON.stringify(payload('Read', { file_path: `${PROJECT}/src/index.js` }));
  const withNode = spawnSync(bash, [WRAPPER], { input: deniedInput, encoding: 'utf8', timeout: 30000, env: { ...process.env, CLAUDE_PLUGIN_ROOT: '' } });
  assert.equal(withNode.status, 0, withNode.stderr);
  assert.ok(JSON.parse(withNode.stdout).hookSpecificOutput.permissionDecisionReason.startsWith(`${LEAD}this call reaches`));
  const bin = tempDir(t, 'zensu-auth-guard-bin-');
  for (const tool of ['cat', 'tr']) {
    const found = ['/bin', '/usr/bin'].map((dir) => path.join(dir, tool)).find((candidate) => fs.existsSync(candidate));
    fs.symlinkSync(found, path.join(bin, tool));
  }
  const noNode = (input) => spawnSync(bash, [WRAPPER], { input, encoding: 'utf8', timeout: 30000, env: { PATH: bin, HOME: process.env.HOME || '/' } });
  const fallback = noNode(deniedInput);
  assert.equal(fallback.status, 0, fallback.stderr);
  assert.equal(JSON.parse(fallback.stdout).hookSpecificOutput.permissionDecisionReason,
    `${LEAD}refused a call that names a verify-feature run directory because the guard could not reach node or its dispatcher; reinstall the plugin or run /zensu:doctor`);
  assert.equal(noNode(deniedInput.replace('verify-feature-runs', 'verify-feature-r\\"uns')).stdout.length > 0, true);
  const quiet = noNode(cleanInput);
  assert.equal(quiet.status, 0);
  assert.equal(quiet.stdout, '');
});
