'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ps = require(path.join(__dirname, '..', '..', 'hooks', 'lib', 'powershell-command-v1.js'));

const NAMES = [
  'CLAUDE_ENV_FILE', 'CLAUDE_CODE_SESSION_ID', 'ZENSU_CLAUDE_PLUGIN_ROOT', 'ZENSU_SESSION_KEY',
  'ZENSU_SESSION_CONTEXT', 'ZENSU_RUNTIME_DIGEST', 'ZENSU_PROJECT_ROOT',
];
const ENV_FILE_RE = /c:[\\/]work[\\/]\.claude-env/i;
const OPTIONS = { names: NAMES, refersToEnvFile: (text) => ENV_FILE_RE.test(text) };
const BT = String.fromCharCode(96);
const EN_DASH = String.fromCodePoint(0x2013);
const OPAQUE = ps.OPAQUE_ARGUMENT;

function zensu(text) {
  const result = ps.zensuInvocations(text);
  if (result.unjudged) return 'UNJUDGED';
  return result.invocations.map((entry) => entry.rest.map((word) => (word === OPAQUE ? '<opaque>' : word)).join(' '));
}

function control(text) {
  return ps.controlVerdict(text, OPTIONS) ? 'DENY' : 'PASS';
}

function readOnly(text) {
  return ps.readOnlyVerdict(text).readOnly ? 'READ' : 'WRITE';
}

function table(cases, judge) {
  for (const [text, expected] of cases) assert.deepEqual(judge(text), expected, JSON.stringify(text));
}

const ZENSU_LITERAL = [
  ['zensu features list', ['features list']],
  ['ZENSU.EXE features create --name x', ['features create --name x']],
  ["& 'C:\\Program Files\\Zensu\\zensu.exe' security classify f1", ['security classify f1']],
  ['& "C:\\tools\\zensu.cmd" features create', ['features create']],
  ['.\\zensu features create', ['features create']],
  ['C:\\tools\\zensu.exe features create', ['features create']],
  ['zen' + BT + 'su features create', ['features create']],
  ['& "zen' + BT + 'u{73}u" features create', ['features create']],
  ['zensu features create ' + BT + '\n  --name x', ['features create --name x']],
  ['zensu $noun create', ['<opaque> create']],
  ['zensu @args', ['<opaque>']],
  ['zensu features create --name "$name"', ['features create --name <opaque>']],
  ['zensu --% features create', ['<opaque>']],
  ['zensu features create ' + EN_DASH + 'h', ['features create ' + EN_DASH + 'h']],
  ['zensu ' + EN_DASH + 'name x', [EN_DASH + 'name x']],
];

const ZENSU_MENTIONS = [
  ['Get-ChildItem', []],
  ['git commit -m "Update zensu docs"', []],
  ['Write-Output zensu', []],
  ['"zensu features create"', []],
  ['# zensu features create', []],
  ['<# zensu features create #> Get-Date', []],
  ["@'\nzensu features create\n'@ | Out-Null", []],
  ['Get-Content .zensu/plans/x.md', []],
  ['Set-Location C:\\IdeaProjects\\dev.zensu\\zensu-claude-code', []],
  ['"zensu features create" | ForEach-Object { $_.Split(" ") }', []],
  ['bash "$env:HOME/.claude/plugins/cache/zensu/zensu/0.27.0/hooks/lib/zensu-log.sh" --phase x', []],
  ['bash C:/Users/me/.claude/plugins/cache/zensu/zensu/0.27.0/hooks/lib/zensu-log.sh --phase x', []],
  ['pwsh -File C:\\x\\zensu-tasks.ps1', []],
];

const ZENSU_NESTED = [
  ['(zensu features create)', ['features create']],
  ['$(zensu features create)', ['features create']],
  ['$r = zensu features create', ['features create']],
  ['Write-Output "$(zensu features create)"', ['features create']],
  ['if ($true) { zensu features create }', ['features create']],
  ['foreach ($i in 1..3) { zensu features create }', ['features create']],
  ['1..3 | ForEach-Object { zensu features create }', ['features create']],
  ['& { zensu features create }', ['features create']],
  ['zensu features list; zensu features create', ['features list', 'features create']],
  ['zensu features list && zensu features create', ['features list', 'features create']],
  ['zensu features list | Out-String', ['features list']],
  ['return zensu features create', ['features create']],
  ['switch ($x) { "a" { zensu features create } }', ['features create']],
  ['try { zensu features create } catch { }', ['features create']],
  ['$a = @{ k = (zensu features create) }', ['features create']],
  ["pwsh -NoProfile -Command 'zensu features create'", ['features create']],
  ["powershell -ep Bypass -c 'zensu features create'", ['features create']],
  ['pwsh -File C:\\npm\\zensu.ps1 features create', ['features create']],
  ['pwsh -File:C:\\npm\\zensu.ps1 features create', ['features create']],
  ['pwsh C:\\npm\\zensu.ps1 features $verb', ['features <opaque>']],
];

const ZENSU_UNJUDGED = [
  'pwsh -enc AAAA zensu',
  "bash -c 'zensu features create'",
  "bash -lc 'zensu features create'",
  'cmd /c zensu features create',
  'wsl zensu features create',
  "iex 'zensu features create'",
  'Invoke-Expression "zensu features create"',
  'Microsoft.PowerShell.Utility\\Invoke-Expression "zensu features list"',
  'Start-Process zensu -ArgumentList features,create',
  "& $exe features create; 'zensu'",
  '& (Get-Command zensu) features create',
  '$p = "zensu"; & $p features create',
  'function z { zensu @args }; z features create',
  'Set-Alias z zensu; z features create',
  'Set-Item function:z { zensu features create }',
  '[Diagnostics.Process]::Start("zensu", "features create")',
  '. zensu',
  'zensu features create "unterminated',
  'pwsh -c $code; zensu features list',
  'pwsh -$option x; zensu features list',
  'zensu features list | bash',
  '& ("zen" + "su") features create',
  "& ('zen' + 'su') features create",
];

test('a literal zensu call is found in every spelling PowerShell runs it', () => {
  table(ZENSU_LITERAL, zensu);
});

test('text that only mentions zensu, or starts a script file, yields no zensu call', () => {
  table(ZENSU_MENTIONS, zensu);
});

test('zensu calls inside blocks, pipelines, subexpressions and nested PowerShell are found', () => {
  table(ZENSU_NESTED, zensu);
});

test('a zensu call this check cannot read is reported as unjudged, never as no call', () => {
  table(ZENSU_UNJUDGED.map((text) => [text, 'UNJUDGED']), zensu);
});

const CONTROL_NAMES = [
  ["$env:ZENSU_SESSION_KEY = 'x'", 'DENY'],
  ["$ENV:zensu_session_key = 'x'", 'DENY'],
  ['${env:ZENSU' + BT + "_SESSION_KEY} = 'x'", 'DENY'],
  ['[Environment]::SetEnvironmentVariable("ZENSU_SESS' + BT + 'u{49}ON_KEY", "x")', 'DENY'],
  ["[Environment]::SetEnvironmentVariable('ZENSU_' + 'SESSION_KEY', 'x')", 'DENY'],
  ["$n = 'ZENSU_SESS' + 'ION_KEY'; [Environment]::GetEnvironmentVariable($n)", 'DENY'],
  ['Set-Item env:ZENSU_PROJECT_ROOT C:\\x', 'DENY'],
  ['Get-Item env:CLAUDE_ENV_FILE', 'DENY'],
  ['cmd /c set ZENSU_SESSION_KEY=1', 'DENY'],
  ["iex '$env:ZENSU_PROJECT_ROOT = 1'", 'DENY'],
  ['Get-Content C:\\work\\.claude-env', 'DENY'],
  ['Add-Content -Path "C:/work/.claude-env" -Value x', 'DENY'],
];

const CONTROL_DYNAMIC = [
  ['$n = "x"; Set-Item "env:$n" 1', 'DENY'],
  ['Set-Item -Path (Join-Path env: $n) -Value 1', 'DENY'],
  ['Set-Item -Path ("en" + "v:" + $n) -Value 1', 'DENY'],
  ['Remove-Item env:$n', 'DENY'],
  ['Set-Location env:', 'DENY'],
  ['New-PSDrive -Name e -PSProvider Environment -Root ""', 'DENY'],
  ['[Environment]::SetEnvironmentVariable($n, "x")', 'DENY'],
  ['iex $code', 'DENY'],
  ['$ExecutionContext.InvokeCommand.InvokeScript($code)', 'DENY'],
  ['[scriptblock]::Create($code).Invoke()', 'DENY'],
  ['& ([scriptblock]::Create($c))', 'DENY'],
  ['Start-Process notepad -Environment $h', 'DENY'],
  ['$psi = New-Object Diagnostics.ProcessStartInfo; $psi.Environment["A"] = "b"', 'DENY'],
  ['New-Object Diagnostics.ProcessStartInfo', 'DENY'],
  ["[Diagnostics.Process]::Start('pwsh', $a)", 'DENY'],
  ['$x = "unterminated', 'DENY'],
];

const CONTROL_SHELLS = [
  ['pwsh -enc AAAA', 'DENY'],
  ["pwsh -c 'Get-Date'", 'PASS'],
  ["pwsh -ep Bypass -c 'Set-Item env:$x 1'", 'DENY'],
  ["powershell -ep Bypass 'Set-Item env:$x 1'", 'DENY'],
  ["pwsh -ep Bypass 'Set-Item env:$x 1'", 'PASS'],
  ["pwsh -Command:'Set-Item env:$x 1'", 'DENY'],
  ["'Get-Date' | pwsh -", 'DENY'],
  ["'Get-Date' | pwsh -NoProfile", 'DENY'],
  ['pwsh -File -', 'DENY'],
  ['pwsh -c $code', 'DENY'],
  ['pwsh -c:$code', 'DENY'],
  ['powershell x.ps1 $arg', 'DENY'],
  ['pwsh -$option AAAA', 'DENY'],
  ['pwsh -File C:\\x\\run.ps1', 'PASS'],
  ['pwsh -NoProfile -File $script -Name $value', 'PASS'],
  ['powershell -ExecutionPolicy Bypass -File $script', 'PASS'],
  ["pwsh -wd $dir -c 'Get-Date'", 'PASS'],
  ['pwsh x.ps1 $arg', 'PASS'],
  ['cmd /c "set %n%=1"', 'DENY'],
  ['cmd /c $line', 'DENY'],
  ['cmd /c dir', 'PASS'],
  ['wsl ls $dir', 'DENY'],
  ['env $assignment bash run.sh', 'DENY'],
  ['sudo pwsh -c "Set-Item env:$x 1"', 'DENY'],
  ['bash C:/x/zensu-log.sh --phase y', 'PASS'],
  ['bash "$env:CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh" --phase y', 'PASS'],
  ['bash -- $script', 'PASS'],
  ['bash --version', 'PASS'],
  ["bash -c 'echo hi' _ $x", 'PASS'],
  ['bash -c "$cmd"', 'DENY'],
  ['bash -lc $cmd', 'DENY'],
  ['bash -eo pipefail -c $cmd', 'DENY'],
  ['bash -c -- $cmd', 'DENY'],
  ['bash -$flags $cmd', 'DENY'],
  ['bash -s $x', 'DENY'],
  ["'echo hi' | bash", 'DENY'],
  ['fish --command=$cmd', 'DENY'],
  ['fish -C $cmd', 'DENY'],
  ['nohup bash -c $cmd', 'DENY'],
  ['xargs bash -c', 'DENY'],
  ["xargs -I{} bash -c 'echo {}'", 'PASS'],
  ['timeout 10 $cmd', 'PASS'],
  ["Start-Process pwsh -ArgumentList '-enc','AAAA'", 'DENY'],
  ["Start-Process pwsh -ArgumentList '-c','Get-Date'", 'PASS'],
  ['Start-Process bash -ArgumentList $a', 'DENY'],
  ["Start-Process pwsh -ArgumentList '-File', $f", 'DENY'],
  ['Start-Process notepad -ArgumentList $file', 'PASS'],
  ['Start-Process $exe -ArgumentList $a', 'PASS'],
  ['Start-Process notepad -Environment @{ A = "b" }', 'PASS'],
  ["[Diagnostics.Process]::Start('notepad', $f)", 'PASS'],
  ['[Diagnostics.Process]::Start($exe)', 'PASS'],
];

const CONTROL_ORDINARY = [
  ["$env:OTHER = 'x'", 'PASS'],
  ["$env:Path += ';C:\\x'", 'PASS'],
  ['Set-Content $file "x"', 'PASS'],
  ['Get-ChildItem env:', 'PASS'],
  ["[Environment]::SetEnvironmentVariable('OTHER', 'x')", 'PASS'],
  ["iex 'Get-Date'", 'PASS'],
  ["[ScriptBlock]::Create('Get-Date').Invoke()", 'PASS'],
  ['git status', 'PASS'],
  ['Get-ChildItem -Recurse | Select-String foo', 'PASS'],
  ['Invoke-Command -ComputerName $c -ScriptBlock { Get-Date }', 'PASS'],
  ['Start-Job -FilePath $f', 'PASS'],
  ['npm test -- --grep $pattern', 'PASS'],
];

test('the Session Control check refuses every spelling of a protected name and of the env file', () => {
  table(CONTROL_NAMES, control);
});

test('the Session Control check refuses Environment writes and code it can only see at run time', () => {
  table(CONTROL_DYNAMIC, control);
});

test('the Session Control check judges nested PowerShell, shells and wrappers by how they read code', () => {
  table(CONTROL_SHELLS, control);
});

test('the Session Control check passes ordinary commands', () => {
  table(CONTROL_ORDINARY, control);
});

test('a name or provider path built at run time from anything but string literals is the documented residual, as in Bash', () => {
  assert.equal(control('Set-Item -Path $p -Value 1'), 'PASS');
  assert.equal(control("$n = [char]0x5A + 'ENSU_SESSION_KEY'; [Environment]::GetEnvironmentVariable($n)"), 'PASS');
  assert.deepEqual(zensu("& ([char]0x7A + 'ensu') features create"), []);
  assert.deepEqual(zensu('Write-Output ("zen" + "su")'), []);
});

test('a deny names the reason the check refused the command', () => {
  assert.match(ps.controlVerdict("$env:ZENSU_SESSION_KEY = 'x'", OPTIONS), /protected Session Control input ZENSU_SESSION_KEY/);
  assert.match(ps.controlVerdict('Get-Content C:\\work\\.claude-env', OPTIONS), /file behind CLAUDE_ENV_FILE/);
  assert.match(ps.controlVerdict('iex $code', OPTIONS), /runs text built at run time/);
  assert.match(ps.controlVerdict('$x = "open', OPTIONS), /could not be read/);
  assert.equal(ps.controlVerdict('Get-Date', OPTIONS), '');
});

const READ_CASES = [
  ['Get-ChildItem -Recurse | Select-String foo', 'READ'],
  ['Get-Content a.txt > b.txt', 'WRITE'],
  ['git status', 'WRITE'],
  ['Set-Content a.txt x', 'WRITE'],
  ['Get-Date 2>$null', 'READ'],
  ['ls | % { $_.Name }', 'READ'],
  ['ls | % Delete', 'WRITE'],
  ['ls | % -MemberName Name', 'READ'],
  ['(Get-Item x).Delete()', 'WRITE'],
  ["[IO.File]::WriteAllText('x', 'y')", 'WRITE'],
  ['$x = 1', 'READ'],
  ["${C:\\x} = 'y'", 'WRITE'],
  ['Get-ChildItem | Remove-Item', 'WRITE'],
  ['cd ..; Get-ChildItem', 'READ'],
  ['Get-Content x | Out-File y', 'WRITE'],
  ['Get-Content x | Tee-Object y', 'WRITE'],
  ['Write-Output x >> y', 'WRITE'],
  ['Get-ChildItem *>&1', 'READ'],
  ['& { Get-Date }', 'READ'],
  ['. ./x.ps1', 'WRITE'],
  ['Get-ChildItem -Path $(rm x)', 'WRITE'],
  ['Get-ChildItem "$(rm x)"', 'WRITE'],
  ["Write-Output @'\n$(rm x)\n'@", 'READ'],
  ['Write-Output @"\n$(rm x)\n"@', 'WRITE'],
  ['"a" > $null', 'READ'],
  ['Get-Content x -Raw | ConvertFrom-Json', 'READ'],
  ['(Get-Content x).Split(",") | Sort-Object', 'READ'],
  ['Get-Item x | Set-ItemProperty -Name y -Value z', 'WRITE'],
  ['Get-ChildItem --% /s', 'WRITE'],
  ['& $tool', 'WRITE'],
  ['(Get-Item C:\\tmp\\a.txt).IsReadOnly = $true', 'WRITE'],
  ["(Get-Item x).Attributes = 'Hidden'", 'WRITE'],
  ["(Get-ChildItem x).LastWriteTime = '2000-01-01'", 'WRITE'],
  ["$f = Get-Item x; $f.Attributes = 'Hidden'", 'WRITE'],
  ["$m = 'Delete'; (Get-ChildItem C:\\tmp).ForEach($m)", 'WRITE'],
  ["$h = @{}; $h['k'] = 1", 'WRITE'],
  ['(Get-ChildItem).ForEach({ $_.Name })', 'READ'],
  ["(Get-ChildItem).Where({ $_.Length -gt 1 }, 'First')", 'READ'],
  ['[int]$n = 5', 'READ'],
  ['$a, $b = 1, 2', 'READ'],
  ['$x += 1', 'READ'],
];

test('the read-only verdict passes only allowlisted reads and refuses everything else', () => {
  table(READ_CASES, readOnly);
  assert.match(ps.readOnlyVerdict('git status').reason, /git is not a read-only command/);
});

test('analyze reports a fault instead of guessing', () => {
  for (const text of ['"open', "'open", '$(Get-Date', 'Get-Date )', '@"\nno end', '<# open', 'Get-Date ' + BT]) {
    assert.notEqual(ps.analyze(text).fault, null, JSON.stringify(text));
  }
  assert.match(ps.analyze('x'.repeat(ps.MAX_TEXT_LENGTH + 1)).fault, /larger than the check reads/);
  assert.notEqual(ps.analyze('('.repeat(200) + 'Get-Date' + ')'.repeat(200)).fault, null);
  assert.equal(ps.analyze('Get-Date').fault, null);
});

test('normalizeCommandName resolves aliases, paths, module qualifiers and extensions', () => {
  const cases = [
    ['iex', 'invoke-expression'],
    ['Microsoft.PowerShell.Utility\\Invoke-Expression', 'invoke-expression'],
    ['C:\\tools\\Zensu.EXE', 'zensu'],
    ['./zensu', 'zensu'],
    ['zensu.cmd. ', 'zensu'],
    ['C:\\bin\\ls', 'ls'],
    ['%', 'foreach-object'],
    ['Set-Location', 'set-location'],
  ];
  for (const [raw, expected] of cases) assert.equal(ps.normalizeCommandName(raw), expected, raw);
});

test('the alias table maps lowercase names onto lowercase commands the verdicts know', () => {
  for (const [alias, command] of Object.entries(ps.ALIASES)) {
    assert.equal(alias, alias.toLowerCase(), alias);
    assert.equal(command, command.toLowerCase(), command);
    assert.ok(!Object.prototype.hasOwnProperty.call(ps.ALIASES, command), `${alias} resolves to another alias ${command}`);
  }
  for (const name of ps.READ_ONLY_COMMANDS) assert.equal(name, name.toLowerCase(), name);
});

const CONFORMANCE_CORPUS = [
  ...ZENSU_LITERAL, ...ZENSU_MENTIONS, ...ZENSU_NESTED,
  ...CONTROL_NAMES, ...CONTROL_DYNAMIC, ...CONTROL_SHELLS, ...CONTROL_ORDINARY, ...READ_CASES,
].map(([text]) => text).concat(ZENSU_UNJUDGED);

const CONFORMANCE_SCRIPT = [
  "$ErrorActionPreference = 'Stop'",
  '$utf8 = [System.Text.UTF8Encoding]::new($false)',
  '$out = [System.Collections.Generic.List[string]]::new()',
  'foreach ($line in [System.IO.File]::ReadAllLines($env:ZENSU_PS_CORPUS, $utf8)) {',
  '  $text = $utf8.GetString([System.Convert]::FromBase64String($line))',
  '  $tokens = $null',
  '  $errors = $null',
  '  $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)',
  '  $names = [System.Collections.Generic.List[string]]::new()',
  '  foreach ($node in $ast.FindAll({ param($candidate) $candidate -is [System.Management.Automation.Language.CommandAst] }, $true)) {',
  '    $name = $node.GetCommandName()',
  '    if ($name) { $names.Add([System.Convert]::ToBase64String($utf8.GetBytes($name))) }',
  '  }',
  "  $out.Add('C ' + $errors.Count + ' ' + ($names -join ','))",
  '}',
  'foreach ($entry in [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault().Commands) {',
  '  if ($entry -is [System.Management.Automation.Runspaces.SessionStateAliasEntry]) {',
  "    $out.Add('A ' + $entry.Name + ' ' + $entry.Definition)",
  '  }',
  '}',
  '[System.IO.File]::WriteAllLines($env:ZENSU_PS_RESULT, $out, $utf8)',
].join('\n');

function powershellHost() {
  const names = process.platform === 'win32' ? ['powershell.exe', 'pwsh'] : ['pwsh'];
  for (const name of names) {
    const probe = spawnSync(name, ['-NoProfile', '-NonInteractive', '-Command', 'exit 0'], { timeout: 60000 });
    if (!probe.error && probe.status === 0) return name;
  }
  return null;
}

const HOST = powershellHost();
const CONFORMANCE_SKIP = process.platform !== 'win32' && HOST === null
  ? 'no PowerShell on PATH here; the case is required on win32, where powershell.exe always exists'
  : false;

test('every command the PowerShell parser finds is one the analyzer reports, and every built-in alias is known', { skip: CONFORMANCE_SKIP }, () => {
  assert.ok(HOST, 'no PowerShell host answered on win32');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-ps-conformance-'));
  try {
    const corpusFile = path.join(dir, 'corpus.json');
    const resultFile = path.join(dir, 'result.json');
    fs.writeFileSync(corpusFile, CONFORMANCE_CORPUS.map((text) => Buffer.from(text, 'utf8').toString('base64')).join('\n') + '\n');
    const run = spawnSync(HOST, ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(CONFORMANCE_SCRIPT, 'utf16le').toString('base64')], {
      encoding: 'utf8',
      timeout: 180000,
      env: { ...process.env, ZENSU_PS_CORPUS: corpusFile, ZENSU_PS_RESULT: resultFile },
    });
    assert.equal(run.status, 0, `${HOST} exited ${run.status}: ${run.stderr}`);
    const lines = fs.readFileSync(resultFile, 'utf8').replace(/^\uFEFF/, '').split(/\r?\n/).filter(Boolean);
    const cases = lines.filter((line) => line.startsWith('C ')).map((line) => {
      const [, errors, encoded = ''] = line.split(' ');
      return { errors: Number(errors), names: encoded.split(',').filter(Boolean).map((name) => Buffer.from(name, 'base64').toString('utf8')) };
    });
    const aliases = lines.filter((line) => line.startsWith('A ')).map((line) => {
      const [, name, definition = ''] = line.split(' ');
      return { name, definition };
    });
    assert.equal(cases.length, CONFORMANCE_CORPUS.length);
    assert.ok(aliases.length > 100, `${HOST} listed ${aliases.length} built-in aliases`);
    const misses = [];
    cases.forEach((entry, index) => {
      if (entry.errors > 0) return;
      const text = CONFORMANCE_CORPUS[index];
      const analysis = ps.analyze(text);
      if (analysis.fault) {
        misses.push(`${JSON.stringify(text)}: the analyzer faulted (${analysis.fault}) on text PowerShell parses`);
        return;
      }
      const ours = new Set(analysis.commands.map((command) => command.name));
      for (const name of entry.names) {
        const normalized = ps.normalizeCommandName(name);
        if (!ours.has(normalized)) misses.push(`${JSON.stringify(text)}: PowerShell runs ${name}, the analyzer saw ${[...ours].join(', ') || 'nothing'}`);
      }
    });
    for (const alias of aliases) {
      const key = String(alias.name).toLowerCase();
      const command = String(alias.definition).toLowerCase().replace(/\.exe$/, '');
      if (ps.ALIASES[key] !== command) misses.push(`alias ${alias.name} -> ${alias.definition} is not in ALIASES (has ${ps.ALIASES[key]})`);
    }
    assert.deepEqual(misses, []);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
