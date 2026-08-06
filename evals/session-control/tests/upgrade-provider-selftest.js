#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const YAML = require('yaml');
const { OLD_RELEASE_REVISION, parse } = require('../lib/upgrade-attestation.js');

const root = path.resolve(__dirname, '..', '..', '..');
const provider = path.join(root, 'evals', 'session-control', 'lib', 'upgrade-provider.js');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-upgrade-provider-selftest-'));
const source = path.join(temporary, 'source');
const fakeClaude = path.join(temporary, 'fake-claude.js');
const verifier = path.join(root, 'evals', 'session-control', 'lib', 'verify-upgrade-results.js');
const PROVIDER_CASE_TIMEOUT_MS = 60000;
const PROMPTFOO_PROCESS_OVERHEAD_MS = 60000;

function promptfooMatrixTimeout(caseCount) {
  assert.equal(Number.isSafeInteger(caseCount) && caseCount > 0, true);
  const timeout = (caseCount * PROVIDER_CASE_TIMEOUT_MS) + PROMPTFOO_PROCESS_OVERHEAD_MS;
  assert.equal(Number.isSafeInteger(timeout), true);
  return timeout;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', ...options });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return (result.stdout || '').trim();
}

function git(args) {
  return run('git', args, { cwd: source });
}

function write(relative, contents, mode = 0o600) {
  const file = path.join(source, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, contents, { encoding: 'utf8', mode });
}

function hook(name) {
  write(`hooks/${name}`, '#!/bin/bash\nexit 0\n', 0o700);
}

function providerEnvironment(fault = '') {
  const revision = git(['rev-parse', 'HEAD']);
  const credentialBoundary = fault === 'credential-boundary';
  return {
    ...process.env,
    ZENSU_EXPECTED_SOURCE_ROOT: source,
    ZENSU_EXPECTED_SOURCE_REVISION: revision,
    ZENSU_EXPECTED_CLAUDE_VERSION: '2.1.221',
    ZENSU_UPGRADE_TEST_MODE: '1',
    ZENSU_UPGRADE_TEST_CLAUDE_SCRIPT: fakeClaude,
    ZENSU_UPGRADE_SELFTEST_FAULT: fault,
    ZENSU_UPGRADE_TEST_CLI_TIMEOUT_MS: fault === 'sleep-cli-probe' ? '100' : '',
    ZENSU_UPGRADE_TEST_CLOSE_TIMEOUT_MS: fault === 'ignore-candidate-eof' ? '100' : '',
    ZENSU_UPGRADE_EXISTING_LOGIN: '0',
    ANTHROPIC_API_KEY: credentialBoundary ? 'selftest-api-credential' : '',
    CLAUDE_CODE_OAUTH_TOKEN: credentialBoundary ? 'selftest-oauth-credential' : '',
    PROMPTFOO_DISABLE_TELEMETRY: '1',
    PROMPTFOO_DISABLE_UPDATE: '1',
  };
}

function invoke(fault = '', environment = {}) {
  const result = spawnSync(process.execPath, [
    provider,
    'Validate the supported side-by-side Claude plugin upgrade lifecycle.',
    JSON.stringify({
      config: { source_dir: source },
      vars: { scenario_id: 'upgrade-v0161-side-by-side' },
    }),
  ], {
    encoding: 'utf8',
    cwd: path.join(root, 'evals', 'session-control'),
    env: { ...providerEnvironment(fault), ...environment },
    timeout: 60000,
  });
  assert.equal(git(['status', '--porcelain=v1', '--untracked-files=all']), '');
  return result;
}

function invokePreflight({
  prompt = 'Validate the supported side-by-side Claude plugin upgrade lifecycle.',
  options = {
    config: { source_dir: source },
    vars: { scenario_id: 'upgrade-v0161-side-by-side' },
  },
  context = {},
  rawOptions,
  environment = {},
} = {}) {
  return spawnSync(process.execPath, [
    provider,
    prompt,
    rawOptions === undefined ? JSON.stringify(options) : rawOptions,
    JSON.stringify(context),
  ], {
    encoding: 'utf8',
    cwd: path.join(root, 'evals', 'session-control'),
    env: { ...providerEnvironment(), ...environment },
    timeout: 60000,
  });
}

try {
  run('git', [
    '-c', 'protocol.file.allow=always',
    'clone', '--no-local', '--no-hardlinks', '--no-checkout', '--', root, source,
  ]);
  git(['checkout', '--detach', '--force', OLD_RELEASE_REVISION]);
  assert.equal(git(['rev-parse', 'v0.16.1^{commit}']), OLD_RELEASE_REVISION);
  git(['switch', '-c', 'candidate-selftest']);
  write('.claude-plugin/plugin.json', '{"name":"zensu","version":"0.16.1","hooks":"./hooks/hooks.json"}\n');
  write('.claude-plugin/marketplace.json', '{"name":"zensu","plugins":[{"name":"zensu","source":{"source":"github","repo":"MKITConsulting/zensu-claude-code","ref":"v0.16.1"},"version":"0.16.1"}]}\n');
  write('hooks/hooks.json', JSON.stringify({
    hooks: {
      SessionStart: [{ hooks: [
        'session-start-pulse.sh', 'session-start-banner.sh',
        'session-start-primer.sh', 'session-start-autopilot-resume.sh',
      ].map((name) => ({ type: 'command', command: `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${name}"` })) }],
      Stop: [{ hooks: [{ type: 'command', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/stop-chain-enforcer.sh"' }] }],
    },
  }, null, 2));
  fs.mkdirSync(path.join(source, 'hooks', 'lib'), { recursive: true, mode: 0o700 });
  const candidateCore = path.join(source, 'hooks', 'lib', 'session-control-core-v1.js');
  fs.copyFileSync(
    path.join(root, 'hooks', 'lib', 'session-control-core-v1.js'),
    candidateCore,
  );
  fs.appendFileSync(candidateCore, `
if (process.env.ZENSU_UPGRADE_SELFTEST_FAULT === 'forged-safe-error') {
  const error = new Error('ZENSU_DIAGNOSTIC_SECRET_SENTINEL ::error::ZENSU_DIAGNOSTIC_DIRECTIVE_SENTINEL');
  error.zensuSafeDiagnostic = true;
  throw error;
}
if (process.env.ZENSU_UPGRADE_SELFTEST_FAULT === 'candidate-crypto-monkeypatch') {
  require('node:crypto').createHash = () => ({
    update() { return this; },
    digest(encoding) {
      return encoding === 'hex' ? '0'.repeat(64) : Buffer.alloc(32);
    },
  });
}
`);
  git(['config', 'user.name', 'Upgrade Provider Selftest']);
  git(['config', 'user.email', 'upgrade-provider@zensu.invalid']);
  git(['config', 'core.hooksPath', process.platform === 'win32' ? 'NUL' : '/dev/null']);

  hook('session-start-session-control.sh');
  hook('pre-reviewer-capability-gate.sh');
  hook('pre-bash-zensu-gate.sh');
  hook('pre-bash-source-write-gate.sh');
  hook('pre-write-secret-scan.sh');
  hook('notification-integrity-probe.sh');
  write('docs/records/unrelated.json', '{}\n');
  write('hooks/hooks.json', JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: '.*', hooks: [{
          type: 'command', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-reviewer-capability-gate.sh"',
        }] },
        { matcher: 'Bash', hooks: [
          'pre-bash-zensu-gate.sh', 'pre-bash-source-write-gate.sh', 'pre-write-secret-scan.sh',
        ].map((name) => ({ type: 'command', command: `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${name}"` })) },
      ],
      SessionStart: [{ hooks: [
        'session-start-session-control.sh', 'session-start-pulse.sh',
        'session-start-banner.sh', 'session-start-primer.sh',
        'session-start-autopilot-resume.sh',
      ].map((name) => ({ type: 'command', command: `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${name}"` })) }],
      Notification: [{ hooks: [{
        type: 'command',
        command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/notification-integrity-probe.sh"',
      }] }],
      Stop: [{ hooks: [{ type: 'command', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/stop-chain-enforcer.sh"' }] }],
    },
  }, null, 2));
  git(['add', '.']);
  git(['-c', 'commit.gpgsign=false', 'commit', '-qm', 'fix: add Session Control compatibility']);

  fs.writeFileSync(fakeClaude, `#!/usr/bin/env node
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {spawnSync}=require('node:child_process');
if(process.env.ZENSU_UPGRADE_SELFTEST_LAUNCH_SENTINEL)fs.appendFileSync(process.env.ZENSU_UPGRADE_SELFTEST_LAUNCH_SENTINEL,'launched\\n');
const fault=process.env.ZENSU_UPGRADE_SELFTEST_FAULT||'';
const credentialBoundary=fault==='credential-boundary';
const hasApi=process.env.ANTHROPIC_API_KEY||'';
const hasOauth=process.env.CLAUDE_CODE_OAUTH_TOKEN||'';
const args=process.argv.slice(2);
const authCanary=args.includes('--safe-mode');
if(process.argv[2]==='--version'&&(hasApi||hasOauth))process.exit(9);
if(process.argv[2]==='--version'){
  const reply=()=>{process.stdout.write((fault==='wrong-cli-version-output'?'2.1.999':'2.1.221')+' (Claude Code selftest)\\n');process.exit(0);};
  if(fault==='sleep-cli-probe')setTimeout(reply,1000);else reply();
  return;
}
if(authCanary){
  const expected=credentialBoundary?'selftest-api-credential':'zensu-upgrade-selftest-auth-canary';
  if(hasApi!==expected||hasOauth)process.exit(31);
  process.stdout.write(
    fault==='auth-canary-wrong-output'
      ? 'ZENSU_AUTH_CANARY_WRONG\\n'
      : 'ZENSU_AUTH_CANARY_OK\\n',
  );
  process.exit(0);
}
if(!process.env.TMPDIR||process.env.TMPDIR!==process.env.TEMP||process.env.TMPDIR!==process.env.TMP||process.env.TMPDIR!==process.env.CLAUDE_CODE_TMPDIR)process.exit(8);
const existingLoginHome=process.env.ZENSU_UPGRADE_SELFTEST_EXISTING_LOGIN_HOME||'';
if(existingLoginHome&&fs.realpathSync.native(process.env.HOME)!==fs.realpathSync.native(existingLoginHome))process.exit(29);
if(args.length===3&&args[0]==='auth'&&args[1]==='status'&&args[2]==='--json'){
  if(!existingLoginHome)process.exit(30);
  if(fault==='existing-login-auth-canary-mutation'){
    fs.appendFileSync(path.join(existingLoginHome,'.claude','settings.json'),' ');
  }
  process.stdout.write(fault==='existing-login-auth-unavailable'
    ? '{"loggedIn":false,"authMethod":""}\\n'
    : '{"loggedIn":true,"authMethod":"selftest"}\\n');
  process.exit(0);
}
if(hasApi!=='zensu-upgrade-test-dummy-key'||hasOauth||process.env.ANTHROPIC_BASE_URL!=='http://127.0.0.1:9')process.exit(9);
if(args.includes('--dangerously-skip-permissions'))process.exit(17);
const permissionAt=args.indexOf('--permission-mode');
const toolsAt=args.indexOf('--tools');
const allowedAt=args.indexOf('--allowedTools');
const settingsAt=args.indexOf('--settings');
if(permissionAt<0||args[permissionAt+1]!=='dontAsk'||toolsAt<0||args[toolsAt+1]!=='Read,Bash'||allowedAt<0||settingsAt<0)process.exit(18);
const settings=JSON.parse(args[settingsAt+1]||'{}');
const sandbox=settings.sandbox||{};
if(sandbox.enabled!==true||sandbox.failIfUnavailable!==true||sandbox.autoAllowBashIfSandboxed!==false||sandbox.allowUnsandboxedCommands!==false)process.exit(22);
const guardCommand=settings?.hooks?.PreToolUse?.[0]?.hooks?.[0]?.command||'';
const guardMatch=guardCommand.match(/^'([^']+)' '([^']+)'$/);
if(settings?.hooks?.PreToolUse?.length!==1||settings.hooks.PreToolUse[0].matcher!=='Bash'||!guardMatch)process.exit(24);
const allowed=[];
for(let i=allowedAt+1;i<args.length&&!args[i].startsWith('--');i+=1)allowed.push(args[i]);
const bashRule="Bash(printf '%s\\\\n' ZENSU_UPGRADE_BASH_OK)";
const readRules=allowed.filter((rule)=>rule.startsWith('Read('));
if(allowed.length!==5||readRules.length!==4||!allowed.includes(bashRule))process.exit(19);
const readNames=readRules.map((rule)=>{
  const match=rule.match(/^Read\\(\\/\\/([^*?\\[\\]!#)]+)\\)$/);
  if(!match)process.exit(20);
  return path.basename(match[1]);
}).sort();
if(JSON.stringify(readNames)!==JSON.stringify(['candidate-turn.txt','old-turn-1.txt','old-turn-2.txt','old-turn-3.txt']))process.exit(21);
let session='';
for(let i=2;i<process.argv.length;i+=1){if(process.argv[i]==='--session-id')session=process.argv[i+1]||'';}
if(!/^[a-f0-9-]{36}$/.test(session))process.exit(10);
const registryFile=process.env.ZENSU_UPGRADE_SELFTEST_REGISTRY_FILE||path.join(process.env.CLAUDE_CONFIG_DIR,'plugins','installed_plugins.json');
const registry=JSON.parse(fs.readFileSync(registryFile,'utf8'));
const captured=registry.plugins['zensu@zensu'][0].installPath;
const trace=process.env.ZENSU_UPGRADE_SELFTEST_TRACE_FILE;
const control=process.env.ZENSU_UPGRADE_SELFTEST_CONTROL_DIR;
const diagnosticSecret='ZENSU_DIAGNOSTIC_SECRET_SENTINEL';
const diagnosticDirective='::error::ZENSU_DIAGNOSTIC_DIRECTIVE_SENTINEL';
let turn=0;
const installedVersion=JSON.parse(fs.readFileSync(path.join(captured,'.claude-plugin','plugin.json'),'utf8')).version;
const candidate=()=>installedVersion!=='0.16.1';
const inUseDirectory=path.join(captured,'.in_use');
const inUseMarker=path.join(inUseDirectory,String(process.pid));
fs.mkdirSync(inUseDirectory,{mode:0o700});
fs.writeFileSync(inUseMarker,'',{flag:'wx',mode:0o600});
process.on('exit',()=>{
  const linger=candidate()?fault==='linger-candidate-in-use':fault==='linger-old-in-use';
  if(!linger){try{fs.unlinkSync(inUseMarker);}catch(_error){}try{fs.rmdirSync(inUseDirectory);}catch(_error){}}
});
const hookConfig=(root)=>JSON.parse(fs.readFileSync(path.join(root,'hooks','hooks.json'),'utf8')).hooks;
const hookNames=(root,event,tool)=>{
  const names=[];
  for(const group of hookConfig(root)[event]||[]){
    if(tool!==undefined&&!new RegExp(group.matcher||'.*').test(tool))continue;
    for(const hook of group.hooks||[]){
      const match=String(hook.command||'').match(/\\/hooks\\/([A-Za-z0-9._-]+\\.sh)/);
      if(!match)process.exit(14);
      names.push(match[1]);
    }
  }
  return names;
};
const appendEvent=(root,event,tool,status=0)=>hookNames(root,event,tool).forEach((name)=>{
  if(fault==='diagnostic-secret-hook'&&name===diagnosticSecret+'.sh')return;
  const target=path.join(root,'hooks',name);
  const result=spawnSync('bash',[target],{
    encoding:'utf8',
    input:'{}\\n',
    env:{...process.env,CLAUDE_PLUGIN_ROOT:root},
  });
  if(status===0&&result.status!==0&&fault!=='nonzero-hook')process.exit(32);
});
const oldLive=path.join(control,'old-process-live');
if(candidate()){
  if(!fs.existsSync(oldLive))process.exit(15);
  const oldState=JSON.parse(fs.readFileSync(oldLive,'utf8'));
  if(fault==='diagnostic-secret-hook'){
    const hookFile=path.join(captured,'hooks','hooks.json');
    const config=JSON.parse(fs.readFileSync(hookFile,'utf8'));
    config.hooks.PreToolUse.push({matcher:'Read',hooks:[{type:'command',command:'bash '+path.join(captured,'hooks',diagnosticSecret+'.sh')}]});
    fs.writeFileSync(hookFile,JSON.stringify(config));
  }
  if(fault!=='missing-old-orphan-marker'){
    const orphanMarker=path.join(oldState.root,'.orphaned_at');
    const orphanTimestamp=fault==='stale-old-orphan-marker'?1000000000000:Date.now();
    const orphanValue=fault==='malformed-old-orphan-marker'?'not-a-timestamp':String(orphanTimestamp);
    fs.writeFileSync(orphanMarker,orphanValue,{flag:'wx',mode:0o644});
    if(fault==='stale-old-orphan-marker'){
      const stale=new Date(orphanTimestamp);
      fs.utimesSync(orphanMarker,stale,stale);
    }
  }
  if(fault==='candidate-orphan-marker')fs.writeFileSync(path.join(captured,'.orphaned_at'),String(Date.now()),{flag:'wx',mode:0o644});
  if(fault==='drop-old-in-use-on-candidate')fs.unlinkSync(path.join(oldState.root,'.in_use',String(oldState.pid)));
}else{
  fs.writeFileSync(oldLive,JSON.stringify({pid:process.pid,root:captured}),{flag:'wx',mode:0o600});
  process.on('exit',()=>{try{fs.unlinkSync(oldLive);}catch(_error){}});
}
const setup=()=>{
  appendEvent(captured,'SessionStart');
  if(candidate()&&fault!=='missing-record'){
    const data=process.env.ZENSU_UPGRADE_SELFTEST_PLUGIN_DATA;
    if(!data||path.basename(data)!=='zensu-zensu'||path.dirname(data)!==path.join(process.env.CLAUDE_CODE_PLUGIN_CACHE_DIR,'data'))process.exit(16);
    fs.mkdirSync(data,{recursive:true,mode:0o700});
    const core=require(path.join(captured,'hooks','lib','session-control-core-v1.js'));
    const recordsDir=path.join(data,'session-control','v1','records');
    core.registerContext({recordsDir,host:'claude',sessionId:session,projectRoot:process.cwd(),pluginRoot:captured,pluginData:data});
    core.initializeWorkflowState({projectRoot:process.cwd(),sessionId:session});
    if(fault==='extra-record')fs.writeFileSync(path.join(recordsDir,'extra.json'),'{}\\n',{mode:0o600});
    if(fault==='corrupt-candidate-context-binding'){
      const record=path.join(recordsDir,core.sessionKey(session)+'.json');
      const context=JSON.parse(fs.readFileSync(record,'utf8'));
      context.project_root=path.dirname(process.cwd());
      fs.writeFileSync(record,JSON.stringify(context)+'\\n',{mode:0o600});
    }
    if(fault==='corrupt-candidate-workflow-baseline'){
      const baseline=path.join(process.cwd(),'.zensu','state','tdd-phase-'+core.sessionKey(session)+'.json');
      const state=JSON.parse(fs.readFileSync(baseline,'utf8'));
      state.phase='CORRUPTED';
      fs.writeFileSync(baseline,JSON.stringify(state)+'\\n',{mode:0o600});
    }
  }
};
setup();
let buffer='';
process.stdin.setEncoding('utf8');
process.stdin.on('data',(chunk)=>{buffer+=chunk;let at;while((at=buffer.indexOf('\\n'))!==-1){const raw=buffer.slice(0,at);buffer=buffer.slice(at+1);if(!raw)continue;handle(JSON.parse(raw));}});
process.stdin.on('end',()=>{
  if(fault==='ignore-candidate-eof'&&candidate())setInterval(()=>{},1000);
});
function emit(value){process.stdout.write(JSON.stringify(value)+'\\n');}
function handle(envelope){
  turn+=1;
  if(fault==='crash'){process.exit(23);}
  emit({type:'system',subtype:'init',session_id:fault==='wrong-session'?'00000000-0000-4000-8000-000000000000':session,tools:fault==='diagnostic-secret-event'?[diagnosticSecret,diagnosticDirective]:undefined});
  if(fault==='diagnostic-secret-event'){
    emit({type:'assistant',subtype:diagnosticSecret,message:{content:[{type:'tool_use',id:'secret-tool',name:diagnosticSecret,input:{[diagnosticSecret]:true,[diagnosticDirective]:true}},{type:diagnosticDirective}]}});
    emit({type:'result',subtype:diagnosticDirective,is_error:true,result:diagnosticSecret,tools:[diagnosticSecret,diagnosticDirective],session_id:session});
    return;
  }
  let selected=captured;
  if(fault==='wrong-turn3-root'&&turn===3){
    selected=JSON.parse(fs.readFileSync(registryFile,'utf8')).plugins['zensu@zensu'][0].installPath;
  }
  const text=String(envelope?.message?.content||'');
  const fileMatch=text.match(/file_path ("(?:\\\\.|[^"\\\\])*")/);
  if(!fileMatch||!text.includes('reply with exactly the opaque token from the file'))process.exit(12);
  const file=JSON.parse(fileMatch[1]);
  const token=fs.readFileSync(file,'utf8').trim();
  if(!/^[A-Z_]+$/.test(token))process.exit(28);
  if(fault==='existing-login-primary-and-canary'&&!candidate()&&turn===1){
    fs.appendFileSync(path.join(existingLoginHome,'.claude','settings.json'),' ');
    emit({type:'assistant',message:{content:[{type:'text',text:token}]}});
    appendEvent(selected,'Stop');
    emit({type:'result',subtype:'success',is_error:false,result:token,session_id:session});
    return;
  }
  if(token==='FRESH_CANDIDATE_OK'&&fault==='candidate-prose-only-terminal'){
    emit({type:'assistant',message:{content:[{type:'text',text:token}]}});
    appendEvent(selected,'Stop');
    emit({type:'result',subtype:'success',is_error:false,result:token,session_id:session});
    return;
  }
  if(token==='FRESH_CANDIDATE_OK'&&fault==='replace-restore-additional-event-hook'){
    const hookFile=path.join(captured,'hooks','notification-integrity-probe.sh');
    const original=fs.readFileSync(hookFile);
    const mode=fs.statSync(hookFile).mode&0o777;
    fs.unlinkSync(hookFile);
    fs.writeFileSync(hookFile,'#!/bin/bash\\nexit 97\\n',{mode});
    fs.unlinkSync(hookFile);
    fs.writeFileSync(hookFile,original,{mode});
  }
  if(token==='FRESH_CANDIDATE_OK'&&fault==='replace-restore-candidate-plugin-root'){
    const displaced=captured+'.selftest-displaced';
    const mode=fs.statSync(captured).mode&0o777;
    fs.renameSync(captured,displaced);
    fs.mkdirSync(captured,{mode});
    fs.rmdirSync(captured);
    fs.renameSync(displaced,captured);
  }
  const id='tool-'+crypto.randomUUID();
  let restoredCandidateHook=null;
  if(token==='FRESH_CANDIDATE_OK'&&fault==='replace-restore-candidate-hook'){
    const hookFile=path.join(captured,'hooks','pre-reviewer-capability-gate.sh');
    const original=fs.readFileSync(hookFile);
    fs.writeFileSync(hookFile,'#!/bin/bash\\nexit 0\\n');
    restoredCandidateHook=()=>fs.writeFileSync(hookFile,original);
  }
  appendEvent(selected,'PreToolUse','Read');
  if(restoredCandidateHook)restoredCandidateHook();
  emit({type:'assistant',message:{content:[{type:'tool_use',id,name:'Read',input:{file_path:file}}]}});
  emit({type:'user',message:{content:[{type:'tool_result',tool_use_id:id,is_error:token==='FRESH_CANDIDATE_OK'&&fault==='candidate-errored-read-result',content:fs.readFileSync(file,'utf8')}]}});
  if(token==='FRESH_CANDIDATE_OK'){
    const bashId='tool-'+crypto.randomUUID();
    appendEvent(selected,'PreToolUse','Bash');
    const bashDescription='Print the fixed harmless upgrade probe token';
    emit({type:'assistant',message:{content:[{type:'tool_use',id:bashId,name:'Bash',input:{command:"printf '%s\\\\n' ZENSU_UPGRADE_BASH_OK",description:bashDescription}}]}});
    const guardPayload=(tool_input)=>JSON.stringify({hook_event_name:'PreToolUse',tool_name:'Bash',tool_input});
    const rejected=spawnSync(guardMatch[1],[guardMatch[2]],{encoding:'utf8',input:guardPayload({command:"printf '%s\\\\n' ZENSU_UPGRADE_BASH_OK",description:bashDescription,run_in_background:true})});
    if(rejected.status!==2)process.exit(25);
    const unsandboxed=spawnSync(guardMatch[1],[guardMatch[2]],{encoding:'utf8',input:guardPayload({command:"printf '%s\\\\n' ZENSU_UPGRADE_BASH_OK",description:bashDescription,dangerouslyDisableSandbox:true})});
    if(unsandboxed.status!==2)process.exit(27);
    if(fault!=='missing-bash-guard'){
      const accepted=spawnSync(guardMatch[1],[guardMatch[2]],{encoding:'utf8',input:guardPayload({command:"printf '%s\\\\n' ZENSU_UPGRADE_BASH_OK",description:bashDescription})});
      if(accepted.status!==0)process.exit(26);
    }
    if(fault!=='candidate-missing-bash-result'){
      emit({type:'user',message:{content:[{type:'tool_result',tool_use_id:bashId,is_error:false,content:'ZENSU_UPGRADE_BASH_OK\\n'}]}});
    }
  }
  emit({type:'assistant',message:{content:[{type:'text',text:token}]}});
  appendEvent(selected,'Stop',undefined,fault==='nonzero-hook'?7:0);
  if(fault==='mutate-old'&&turn===3)fs.writeFileSync(path.join(captured,'MUTATED'),'bad');
  if(fault==='secret-filename-drift'&&turn===3)fs.writeFileSync(path.join(captured,diagnosticSecret),'bad');
  if(fault==='rewrite-old-orphan-marker'&&turn===3)fs.writeFileSync(path.join(captured,'.orphaned_at'),String(Date.now()));
  if(fault==='mutate-candidate'&&candidate())fs.writeFileSync(path.join(captured,'MUTATED'),'bad');
  if(fault==='drop-candidate-in-use'&&candidate())fs.unlinkSync(inUseMarker);
  if(fault==='foreign-candidate-in-use'&&candidate())fs.writeFileSync(path.join(inUseDirectory,'999999'),'',{flag:'wx',mode:0o600});
  emit({type:'result',subtype:'success',is_error:false,result:token,session_id:session});
  if(fault==='close-stdin-before-turn-two'&&!candidate()&&turn===1){
    try{fs.closeSync(0);}catch(_error){}
    process.stdin.destroy();
    setInterval(()=>{},1000);
  }
}
`, { encoding: 'utf8', mode: 0o700 });

  const malformedOptions = invokePreflight({ rawOptions: '{' });
  assert.notEqual(malformedOptions.status, 0);
  assert.match(malformedOptions.stderr, /provider options is invalid JSON/);

  const wrongScenario = invokePreflight({ prompt: 'Validate an unrelated lifecycle.' });
  assert.notEqual(wrongScenario.status, 0);
  assert.match(wrongScenario.stderr, /Promptfoo scenario identity is missing/);

  if (process.platform === 'win32') {
    const launchLedger = path.join(temporary, 'windows-launch-ledger.jsonl');
    const launchSentinel = path.join(temporary, 'windows-fake-claude-launched');
    const unsupported = invokePreflight({
      environment: {
        ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE: launchLedger,
        ZENSU_UPGRADE_SELFTEST_LAUNCH_SENTINEL: launchSentinel,
      },
    });
    assert.notEqual(unsupported.status, 0);
    assert.match(
      unsupported.stderr,
      /Windows candidate containment is unsupported; no helper or Claude process was started/,
    );
    assert.equal(fs.existsSync(launchLedger), false);
    assert.equal(fs.existsSync(launchSentinel), false);
    assert.equal(
      git(['status', '--porcelain=v1', '--untracked-files=all']),
      '',
      'unsupported Windows validation changed the candidate checkout',
    );
    process.stdout.write('upgrade-provider-selftest.js: PASS (Windows zero-launch fail-closed)\n');
  } else {
  const forbiddenTestHome = invokePreflight({
    environment: { ZENSU_UPGRADE_TEST_EXISTING_LOGIN_HOME: source },
  });
  assert.notEqual(forbiddenTestHome.status, 0);
  assert.match(
    forbiddenTestHome.stderr,
    /test existing-login HOME is forbidden outside deterministic existing-login mode/,
  );

  const mismatchedHome = path.join(temporary, 'mismatched-existing-login-home');
  const actualHome = path.join(temporary, 'actual-existing-login-home');
  fs.mkdirSync(mismatchedHome);
  fs.mkdirSync(actualHome);
  const mismatchedExistingLogin = invokePreflight({
    environment: {
      ZENSU_UPGRADE_EXISTING_LOGIN: '1',
      ZENSU_UPGRADE_TEST_EXISTING_LOGIN_HOME: mismatchedHome,
      HOME: actualHome,
    },
  });
  assert.notEqual(mismatchedExistingLogin.status, 0);
  assert.match(
    mismatchedExistingLogin.stderr,
    /deterministic existing-login mode requires its exact hermetic test HOME/,
  );

  const mismatchedRevision = invokePreflight({
    environment: { ZENSU_EXPECTED_SOURCE_REVISION: '0'.repeat(40) },
  });
  assert.notEqual(mismatchedRevision.status, 0);
  assert.match(
    mismatchedRevision.stderr,
    /candidate source revision does not match the exact requested SHA/,
  );

  const invalidCliVersion = invokePreflight({
    environment: { ZENSU_EXPECTED_CLAUDE_VERSION: 'latest' },
  });
  assert.notEqual(invalidCliVersion.status, 0);
  assert.match(
    invalidCliVersion.stderr,
    /ZENSU_EXPECTED_CLAUDE_VERSION must be an explicit semantic version/,
  );

  const invalidCredential = invokePreflight({
    environment: { ANTHROPIC_API_KEY: 'invalid\ncredential' },
  });
  assert.notEqual(invalidCredential.status, 0);
  assert.match(invalidCredential.stderr, /explicit Claude credential is invalid/);

  const missingProductionCredential = invokePreflight({
    environment: { ZENSU_UPGRADE_TEST_MODE: '0' },
  });
  assert.notEqual(missingProductionCredential.status, 0);
  assert.match(
    missingProductionCredential.stderr,
    process.platform === 'linux'
      ? /explicit Claude credentials are unavailable/
      : /real Claude candidate upgrade validation requires Linux bubblewrap containment/,
  );

  const wrongCliOutput = invokePreflight({
    environment: { ZENSU_UPGRADE_SELFTEST_FAULT: 'wrong-cli-version-output' },
  });
  assert.notEqual(wrongCliOutput.status, 0);
  assert.match(wrongCliOutput.stderr, /Claude CLI must be exactly 2\.1\.221/);

  const rejectedAuthCanary = invokePreflight({
    environment: { ZENSU_UPGRADE_SELFTEST_FAULT: 'auth-canary-wrong-output' },
  });
  assert.notEqual(rejectedAuthCanary.status, 0);
  assert.match(
    rejectedAuthCanary.stderr,
    /plugin-free authenticated Claude canary failed/,
  );

  const unavailableAuthHome = path.join(temporary, 'unavailable-auth-home');
  fs.mkdirSync(unavailableAuthHome);
  const unavailableExistingLoginAuth = invokePreflight({
    environment: {
      ZENSU_UPGRADE_EXISTING_LOGIN: '1',
      ZENSU_UPGRADE_TEST_EXISTING_LOGIN_HOME: unavailableAuthHome,
      ZENSU_UPGRADE_SELFTEST_FAULT: 'existing-login-auth-unavailable',
      HOME: unavailableAuthHome,
    },
  });
  assert.notEqual(unavailableExistingLoginAuth.status, 0);
  assert.match(
    unavailableExistingLoginAuth.stderr,
    /existing-login credentials are unavailable to the isolated diagnostic process/,
  );

  const positive = invoke();
  assert.equal(positive.status, 0, positive.stderr);
  const attestation = parse(positive.stdout.trim());
  assert.equal(attestation.candidate_version_synthetic, true);
  assert.equal(attestation.candidate_source_version, '0.16.1');
  assert.equal(attestation.candidate_installed_version, '0.16.2');
  assert.equal(attestation.old_release_revision, OLD_RELEASE_REVISION);
  assert.equal(attestation.old_process_result_count, 3);
  assert.equal(attestation.execution_mode, 'deterministic-fake');

  const credentialLedger = path.join(temporary, 'credential-launch-ledger.jsonl');
  const credentialBoundary = invoke('credential-boundary', {
    ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE: credentialLedger,
  });
  assert.equal(credentialBoundary.status, 0, credentialBoundary.stderr);
  assert.equal(parse(credentialBoundary.stdout.trim()).gate, 'passed');
  const launchRecords = fs.readFileSync(credentialLedger, 'utf8')
    .split(/\r?\n/).filter(Boolean).map((raw) => JSON.parse(raw));
  const authenticated = launchRecords.filter(
    (record) => record.label === 'plugin-free authenticated Claude canary',
  );
  assert.equal(authenticated.length, 1);
  assert.deepEqual(authenticated[0].credential_names_present, ['ANTHROPIC_API_KEY']);
  const candidateLaunches = launchRecords.filter(
    (record) => /^contained (?:old|candidate) Claude lifecycle$/.test(record.label),
  );
  assert.equal(candidateLaunches.length, 2);
  assert.equal(candidateLaunches.every(
    (record) => JSON.stringify(record.credential_names_present) === '["ANTHROPIC_API_KEY"]',
  ), true);
  const helperLaunches = launchRecords.filter((record) => (
    !authenticated.includes(record) && !candidateLaunches.includes(record)
  ));
  assert.equal(helperLaunches.length > 0, true);
  assert.equal(helperLaunches.every(
    (record) => record.credential_names_present.length === 0,
  ), true);

  const promptfooConfig = path.join(temporary, 'promptfooconfig-upgrade-selftest.yaml');
  const promptfooResult = path.join(temporary, 'promptfoo-upgrade-result.json');
  const promptfooPositiveResult = path.join(temporary, 'promptfoo-upgrade-positive-result.json');
  const promptfooEvidence = path.join(temporary, 'promptfoo-upgrade-evidence.json');
  const promptfooConfigHome = path.join(temporary, 'promptfoo-config-home');
  const promptfooProvider = path.join(temporary, 'promptfoo-upgrade-selftest-provider.js');
  const mainFaultReasons = {
    'wrong-turn3-root': 'old turn three after candidate executed a hook from the wrong plugin root',
    'nonzero-hook': 'old turn one observed a nonzero hook response',
    'missing-record': 'fresh candidate created 0 total context records or used the wrong plugin-data path',
    'extra-record': 'fresh candidate created 2 total context records or used the wrong plugin-data path',
    crash: 'Claude exited before result 1',
    'mutate-old': 'fresh candidate process modified the old runtime root',
    'wrong-session': 'old process did not expose exactly one matching init per completed turn',
    'missing-bash-guard': 'fresh candidate exact Bash guard trace is missing',
    'missing-old-orphan-marker': 'old runtime after candidate activation is missing .orphaned_at',
    'malformed-old-orphan-marker': 'old runtime after candidate activation .orphaned_at marker is unsafe',
    'stale-old-orphan-marker': 'old runtime after candidate activation .orphaned_at timestamp is outside the candidate activation window',
    'candidate-orphan-marker': 'candidate runtime after candidate activation unexpectedly has .orphaned_at',
    'rewrite-old-orphan-marker': 'old runtime .orphaned_at marker changed after candidate activation',
    'drop-old-in-use-on-candidate': 'old process during candidate activation does not have exactly its own active .in_use marker',
    'diagnostic-secret-event': 'old turn one did not issue exactly the requested Read; observed tool_count=',
    'secret-filename-drift': 'fresh candidate process modified the old runtime root; changedEntries=count=1,sha256=',
    'diagnostic-secret-hook': 'candidate hook integrity changed after evaluator capture',
    'replace-restore-candidate-hook': 'candidate hook integrity changed after evaluator capture',
    'replace-restore-additional-event-hook': 'candidate hook integrity changed after evaluator capture',
    'replace-restore-candidate-plugin-root': 'candidate hook integrity changed after evaluator capture',
    'forged-safe-error': 'Claude exited before result 1; status=1; signal=none; stderr_category=session-control;',
    'candidate-crypto-monkeypatch': 'fresh candidate created 1 total context records or used the wrong plugin-data path',
    'close-stdin-before-turn-two': 'Claude stdin closed before prompt could be sent',
    'ignore-candidate-eof': 'Claude did not exit after stream EOF',
    'sleep-cli-probe': 'Claude CLI version probe exceeded its time bound',
    'candidate-prose-only-terminal': 'fresh candidate did not issue exactly the requested Read then harmless Bash probe; observed tool_count=0;',
    'candidate-errored-read-result': 'fresh candidate Read or Bash probe did not return a successful structured result',
    'post-cleanup-attestation-failure': 'isolated upgrade temporary directory cleanup failed',
    'hook-contract-remove-read': 'candidate hook configuration violates the evaluator-owned contract',
    'hook-contract-remove-bash': 'candidate hook configuration violates the evaluator-owned contract',
    'hook-contract-reorder-bash': 'candidate hook configuration violates the evaluator-owned contract',
    'hook-contract-duplicate-bash': 'candidate hook configuration violates the evaluator-owned contract',
    'hook-contract-remove-session-start': 'candidate hook configuration violates the evaluator-owned contract',
    'hook-contract-remove-stop': 'candidate hook configuration violates the evaluator-owned contract',
    'candidate-missing-bash-result': 'fresh candidate Read or Bash probe did not return a successful structured result',
    'corrupt-candidate-context-binding': 'fresh candidate context failed independent verification',
    'corrupt-candidate-workflow-baseline': 'fresh candidate workflow baseline failed independent verification',
    'mutate-candidate': 'fresh candidate process modified candidate runtime bytes; changedEntries=count=1,sha256=',
    'drop-candidate-in-use': 'fresh candidate process does not have exactly its own active .in_use marker',
    'foreign-candidate-in-use': 'fresh candidate process does not have exactly its own active .in_use marker',
    'linger-candidate-in-use': 'fresh candidate process retained an .in_use marker after process exit',
    'linger-old-in-use': 'old process retained an .in_use marker after process exit',
  };
  const existingLoginFaultReasons = {
    'existing-login-auth-canary-mutation': 'existing-login auth preflight changed the host config/cache canary',
    'existing-login-primary-and-canary': 'old turn one did not issue exactly the requested Read; observed tool_count=0;',
  };
  const existingLoginSecondaryReasons = {
    'existing-login-primary-and-canary': 'existing-login host config/cache canary also changed',
  };
  const faultReasons = { ...mainFaultReasons, ...existingLoginFaultReasons };
  const faults = Object.keys(mainFaultReasons);
  assert.equal(
    faults.length + 1,
    43,
    'The primary Promptfoo upgrade matrix must contain exactly 42 faults plus one positive case',
  );
  fs.writeFileSync(promptfooProvider, `#!/usr/bin/env node
'use strict';
const {spawnSync}=require('node:child_process');
const context=JSON.parse(process.argv[4]||'{}');
const fault=context?.vars?.injected_fault||'';
const existingLogin=context?.vars?.execution_profile==='hermetic-existing-login';
const reasons=${JSON.stringify(faultReasons)};
const secondaryReasons=${JSON.stringify(existingLoginSecondaryReasons)};
const forbiddenDiagnostics={
  'diagnostic-secret-event':['ZENSU_DIAGNOSTIC_SECRET_SENTINEL','::error::'],
  'secret-filename-drift':['ZENSU_DIAGNOSTIC_SECRET_SENTINEL'],
  'diagnostic-secret-hook':['ZENSU_DIAGNOSTIC_SECRET_SENTINEL'],
  'forged-safe-error':['ZENSU_DIAGNOSTIC_SECRET_SENTINEL','::error::'],
};
const existingLoginHome=${JSON.stringify(path.join(temporary, 'existing-login-homes'))}+'/'+(fault||'positive');
if(existingLogin){
  const fs=require('node:fs');
  const path=require('node:path');
  fs.rmSync(existingLoginHome,{recursive:true,force:true});
  fs.mkdirSync(path.join(existingLoginHome,'.claude'),{recursive:true,mode:0o700});
  fs.mkdirSync(path.join(existingLoginHome,'.claude','plugins','cache','nested'),{recursive:true,mode:0o700});
  fs.writeFileSync(path.join(existingLoginHome,'.claude','settings.json'),'{"theme":"selftest"}\\n',{mode:0o600});
  fs.writeFileSync(path.join(existingLoginHome,'.claude','plugins','cache','nested','canary'),'unchanged\\n',{mode:0o600});
  if(process.platform!=='win32')fs.symlinkSync('nested/canary',path.join(existingLoginHome,'.claude','plugins','cache','canary-link'));
}
const result=spawnSync(process.execPath,[${JSON.stringify(provider)},...process.argv.slice(2)],{
  encoding:'utf8',cwd:${JSON.stringify(path.join(root, 'evals', 'session-control'))},
  env:{
    ...process.env,
    ZENSU_UPGRADE_SELFTEST_FAULT:fault,
    ZENSU_UPGRADE_TEST_CLI_TIMEOUT_MS:fault==='sleep-cli-probe'?'100':'',
    ZENSU_UPGRADE_TEST_CLOSE_TIMEOUT_MS:fault==='ignore-candidate-eof'?'100':'',
    ZENSU_UPGRADE_EXISTING_LOGIN:existingLogin?'1':'0',
    ZENSU_UPGRADE_TEST_EXISTING_LOGIN_HOME:existingLogin?existingLoginHome:'',
    HOME:existingLogin?existingLoginHome:process.env.HOME,
  },timeout:${PROVIDER_CASE_TIMEOUT_MS},
});
if(!fault){process.stdout.write(result.stdout||'');process.stderr.write(result.stderr||'');process.exit(result.status??1);}
if(result.status===0||(result.stdout||'').includes('[control-upgrade-attestation]')){
  process.stderr.write('fault was not rejected: '+fault+'\\n');process.exit(1);
}
if(!reasons[fault]||!(result.stderr||'').includes(reasons[fault])){
  const observedReason=Object.entries(reasons).find(([,reason])=>(result.stderr||'').includes(reason))?.[0]||'unclassified';
  process.stderr.write('fault failed for the wrong reason: '+fault+'; observed_reason_class='+observedReason+'\\n');process.exit(1);
}
if(secondaryReasons[fault]&&!(result.stderr||'').includes(secondaryReasons[fault])){
  process.stderr.write('fault missed its secondary failure: '+fault+'\\n');process.exit(1);
}
if((forbiddenDiagnostics[fault]||[]).some((value)=>((result.stdout||'')+(result.stderr||'')).includes(value))){
  process.stderr.write('fault leaked a forbidden diagnostic value: '+fault+'\\n');process.exit(1);
}
process.stdout.write('EXPECTED_FAIL_CLOSED:'+fault+'\\n');
`, { encoding: 'utf8', mode: 0o700 });
  fs.mkdirSync(promptfooConfigHome, { mode: 0o700 });
  fs.writeFileSync(promptfooConfig, YAML.stringify({
    description: 'Deterministic Session Control side-by-side upgrade fake-provider E2E matrix',
    providers: [{
      id: `exec: ${JSON.stringify(process.execPath)} ${JSON.stringify(promptfooProvider)}`,
      config: { source_dir: source },
    }],
    prompts: [{ id: 'upgrade-selftest', raw: 'Validate the supported side-by-side Claude plugin upgrade lifecycle.' }],
    tests: [
      {
        description: 'Fake host executes the complete supported upgrade lifecycle',
        vars: { scenario_id: 'upgrade-v0161-side-by-side', injected_fault: '' },
        assert: [{ type: 'javascript', value: pathToFileURL(path.join(root, 'evals', 'session-control', 'assertions', 'upgrade-attestation.js')).href }],
      },
      ...faults.map((fault) => ({
        description: `Fake provider fails closed for ${fault}`,
        vars: { scenario_id: 'upgrade-v0161-side-by-side', injected_fault: fault },
        assert: [{ type: 'equals', value: `EXPECTED_FAIL_CLOSED:${fault}` }],
      })),
    ],
    evaluateOptions: { maxConcurrency: 1, repeat: 1 },
  }), { encoding: 'utf8', mode: 0o600 });
  const promptfoo = path.join(root, 'node_modules', '.bin', process.platform === 'win32' ? 'promptfoo.cmd' : 'promptfoo');
  const promptfooRun = spawnSync(promptfoo, [
    'eval', '--config', promptfooConfig, '--no-cache', '--no-share', '--no-write',
    '--no-progress-bar', '--output', promptfooResult,
  ], {
    encoding: 'utf8',
    env: { ...providerEnvironment(), PROMPTFOO_CONFIG_DIR: promptfooConfigHome },
    timeout: promptfooMatrixTimeout(faults.length + 1),
    shell: process.platform === 'win32',
  });
  assert.equal(promptfooRun.status, 0, `${promptfooRun.stderr || ''}\n${promptfooRun.stdout || ''}`);
  const promptfooRows = JSON.parse(fs.readFileSync(promptfooResult, 'utf8'))?.results?.results;
  assert.equal(promptfooRows?.length, faults.length + 1);
  assert.equal(promptfooRows.every((row) => row.success === true), true);
  assert.deepEqual(
    promptfooRows.map((row) => row.vars?.injected_fault).sort(),
    ['', ...faults].sort(),
    'Promptfoo did not execute the exact positive/negative fault multiset',
  );
  const positiveRow = promptfooRows.find((row) => row.vars?.injected_fault === '');
  assert.ok(positiveRow);
  fs.writeFileSync(promptfooPositiveResult, JSON.stringify({ results: { results: [positiveRow] } }));
  const verified = spawnSync(process.execPath, [
    verifier, promptfooPositiveResult, git(['rev-parse', 'HEAD']),
  ], { encoding: 'utf8' });
  assert.equal(verified.status, 0, verified.stderr || verified.stdout);
  assert.match(verified.stdout, /NON-AUTHORITATIVE deterministic-fake/);
  assert.equal(fs.existsSync(promptfooEvidence), false);

  git(['tag', '-f', 'v0.16.1', 'HEAD']);
  const retagged = invoke();
  assert.notEqual(retagged.status, 0, 'provider accepted a maliciously retagged v0.16.1');
  assert.match(retagged.stderr, /must resolve to pinned commit/);
  git(['tag', '-f', 'v0.16.1', OLD_RELEASE_REVISION]);

  const releaseManifest = JSON.parse(fs.readFileSync(
    path.join(source, '.claude-plugin', 'plugin.json'),
    'utf8',
  ));
  releaseManifest.version = '0.17.0';
  write('.claude-plugin/plugin.json', `${JSON.stringify(releaseManifest)}\n`);
  const releaseMarketplace = JSON.parse(fs.readFileSync(
    path.join(source, '.claude-plugin', 'marketplace.json'),
    'utf8',
  ));
  releaseMarketplace.plugins[0].version = '0.17.0';
  releaseMarketplace.plugins[0].source.ref = 'v0.17.0';
  write('.claude-plugin/marketplace.json', `${JSON.stringify(releaseMarketplace)}\n`);
  git(['add', '.claude-plugin/plugin.json', '.claude-plugin/marketplace.json']);
  git(['-c', 'commit.gpgsign=false', 'commit', '-qm', 'test: exercise a non-synthetic candidate version']);

  const existingLoginConfig = path.join(temporary, 'promptfooconfig-upgrade-existing-login.yaml');
  const existingLoginResult = path.join(temporary, 'promptfoo-upgrade-existing-login-result.json');
  const existingLoginPositiveResult = path.join(temporary, 'promptfoo-upgrade-existing-login-positive.json');
  const existingLoginEvidence = path.join(temporary, 'promptfoo-upgrade-existing-login-evidence.json');
  const existingLoginFaults = Object.keys(existingLoginFaultReasons);
  assert.equal(
    existingLoginFaults.length + 1,
    3,
    'The existing-login Promptfoo matrix must contain exactly two faults plus one positive case',
  );
  assert.equal(
    (faults.length + 1) + (existingLoginFaults.length + 1),
    46,
    'The combined Promptfoo upgrade matrix must contain exactly 46 cases',
  );
  fs.writeFileSync(existingLoginConfig, YAML.stringify({
    description: 'Hermetic existing-login and non-synthetic Session Control upgrade matrix',
    providers: [{
      id: `exec: ${JSON.stringify(process.execPath)} ${JSON.stringify(promptfooProvider)}`,
      config: { source_dir: source },
    }],
    prompts: [{ id: 'upgrade-existing-login-selftest', raw: 'Validate the supported side-by-side Claude plugin upgrade lifecycle.' }],
    tests: [
      {
        description: 'Hermetic existing-login profile validates an exact release version',
        vars: {
          scenario_id: 'upgrade-v0161-side-by-side',
          injected_fault: '',
          execution_profile: 'hermetic-existing-login',
          candidate_version_profile: 'release-version',
        },
        assert: [{ type: 'javascript', value: pathToFileURL(path.join(root, 'evals', 'session-control', 'assertions', 'upgrade-attestation.js')).href }],
      },
      ...existingLoginFaults.map((fault) => ({
        description: `Hermetic existing-login profile fails closed for ${fault}`,
        vars: {
          scenario_id: 'upgrade-v0161-side-by-side',
          injected_fault: fault,
          execution_profile: 'hermetic-existing-login',
          candidate_version_profile: 'release-version',
        },
        assert: [{ type: 'equals', value: `EXPECTED_FAIL_CLOSED:${fault}` }],
      })),
    ],
    evaluateOptions: { maxConcurrency: 1, repeat: 1 },
  }), { encoding: 'utf8', mode: 0o600 });
  const existingLoginRun = spawnSync(promptfoo, [
    'eval', '--config', existingLoginConfig, '--no-cache', '--no-share', '--no-write',
    '--no-progress-bar', '--output', existingLoginResult,
  ], {
    encoding: 'utf8',
    env: { ...providerEnvironment(), PROMPTFOO_CONFIG_DIR: promptfooConfigHome },
    timeout: promptfooMatrixTimeout(existingLoginFaults.length + 1),
    shell: process.platform === 'win32',
  });
  assert.equal(
    existingLoginRun.status,
    0,
    `${existingLoginRun.stderr || ''}\n${existingLoginRun.stdout || ''}`,
  );
  const existingLoginRows = JSON.parse(
    fs.readFileSync(existingLoginResult, 'utf8'),
  )?.results?.results;
  assert.equal(existingLoginRows?.length, existingLoginFaults.length + 1);
  assert.equal(existingLoginRows.every((row) => row.success === true), true);
  assert.deepEqual(
    existingLoginRows.map((row) => row.vars?.injected_fault).sort(),
    ['', ...existingLoginFaults].sort(),
    'Promptfoo did not execute the exact existing-login fault multiset',
  );
  const existingLoginPositive = existingLoginRows.find(
    (row) => row.vars?.injected_fault === '',
  );
  const existingLoginAttestation = parse(existingLoginPositive.response.output);
  assert.equal(existingLoginAttestation.execution_mode, 'deterministic-hermetic-existing-login-test');
  assert.equal(existingLoginAttestation.host_config_cache_canary_status, 'unchanged-local-diagnostic');
  assert.equal(existingLoginAttestation.candidate_source_version, '0.17.0');
  assert.equal(existingLoginAttestation.candidate_installed_version, '0.17.0');
  assert.equal(existingLoginAttestation.candidate_version_synthetic, false);
  fs.writeFileSync(
    existingLoginPositiveResult,
    JSON.stringify({ results: { results: [existingLoginPositive] } }),
  );
  const releaseRevision = git(['rev-parse', 'HEAD']);
  const diagnosticVerified = spawnSync(process.execPath, [
    verifier, existingLoginPositiveResult, releaseRevision,
  ], { encoding: 'utf8' });
  assert.equal(
    diagnosticVerified.status,
    0,
    diagnosticVerified.stderr || diagnosticVerified.stdout,
  );
  assert.match(
    diagnosticVerified.stdout,
    /NON-AUTHORITATIVE deterministic-hermetic-existing-login-test/,
  );
  const diagnosticPublication = spawnSync(process.execPath, [
    verifier, existingLoginPositiveResult, releaseRevision, existingLoginEvidence,
  ], { encoding: 'utf8' });
  assert.notEqual(diagnosticPublication.status, 0);
  assert.match(
    diagnosticPublication.stderr,
    /only split authenticated-canary and contained-candidate runs may publish upgrade evidence/,
  );
  assert.equal(fs.existsSync(existingLoginEvidence), false);

  const candidateRevision = git(['rev-parse', 'HEAD']);
  const candidateTree = git(['rev-parse', `${candidateRevision}^{tree}`]);
  const unrelatedRevision = git([
    '-c', 'commit.gpgsign=false', 'commit-tree', candidateTree,
    '-m', 'test: unrelated candidate history',
  ]);
  git(['checkout', '--detach', '--force', unrelatedRevision]);
  const unrelated = invoke();
  assert.notEqual(unrelated.status, 0, 'provider accepted an unrelated candidate history');
  assert.match(unrelated.stderr, /must be an ancestor of the candidate source revision/);
  git(['checkout', '--detach', '--force', candidateRevision]);
  process.stdout.write('upgrade-provider-selftest.js: PASS\n');
  }
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
