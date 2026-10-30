'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPO = path.resolve(__dirname, '..', '..');
const leaf = require('../../hooks/lib/git-read-only-v1.js');
const evidence = require('../../hooks/lib/evidence-run-v1.js');
const codeRoots = require('../../hooks/lib/code-roots-v1.js');
const core = require('../../hooks/lib/session-control-core-v1.js');

const SANDBOX = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-code-roots-')));
process.on('exit', () => fs.rmSync(SANDBOX, { recursive: true, force: true }));
const HOME = path.join(SANDBOX, 'home');
fs.mkdirSync(HOME, { recursive: true });
const GLOBAL_IGNORE = path.join(HOME, 'global-ignore');
fs.writeFileSync(GLOBAL_IGNORE, '*.globalignored\n');
fs.writeFileSync(path.join(HOME, '.gitconfig'), [
  '[user]',
  '\tname = Fixture',
  '\temail = fixture@example.invalid',
  '[core]',
  `\texcludesFile = ${GLOBAL_IGNORE}`,
  '[init]',
  '\tdefaultBranch = main',
  '',
].join('\n'));
process.env.HOME = HOME;
process.env.XDG_CONFIG_HOME = path.join(HOME, '.config');
process.env.GIT_CONFIG_NOSYSTEM = '1';
for (const name of Object.keys(process.env)) {
  if (name.startsWith('GIT_') && name !== 'GIT_CONFIG_NOSYSTEM') delete process.env[name];
}

const ENABLED = { enabled: true };
const OWN = 'aaaaaaaa-1111-2222-3333-444444444444';
const OTHER = 'bbbbbbbb-1111-2222-3333-444444444444';
const SHA = 'a'.repeat(40);
const CTX = {
  platform: 'linux',
  anchor: '/zf/work/anchor',
  home: '/zf/home/u',
  claudeConfigDir: '/zf/cfg/claude',
  pluginRoot: '/zf/opt/plugin',
  pluginData: '/zf/data/zensu',
};

function git(cwd, ...args) {
  const result = spawnSync('git', ['-C', cwd, ...args], { env: { ...process.env }, encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`git ${args.join(' ')} failed in ${cwd}: ${result.stderr}`);
  return result.stdout;
}

function write(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}

function repo(dir, files) {
  fs.mkdirSync(dir, { recursive: true });
  git(dir, 'init', '-q');
  for (const [name, content] of Object.entries(files || { 'README.md': 'seed\n' })) write(path.join(dir, name), content);
  git(dir, 'add', '-A');
  git(dir, 'commit', '-q', '-m', 'seed');
  return dir;
}

function head(dir) {
  return git(dir, 'rev-parse', 'HEAD').trim();
}

function scratch(t, name) {
  const dir = fs.mkdtempSync(path.join(SANDBOX, `${name}-`));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function entry(label, top, extra) {
  return { label, path: top, top, commonDir: `${top}/.git`, baseline: 'unborn', ...(extra || {}) };
}

function root(label, top, baseline) {
  return { label, path: top, top, commonDir: path.join(top, '.git'), baseline: baseline || 'unborn' };
}

function read(list, context, options) {
  return codeRoots.readCodeRoots({ active: true, codeRoots: list }, context || CTX, options || ENABLED);
}

function refused(list, pattern, context) {
  const answer = read(list, context);
  assert.equal(answer.status, 'anchor-only', `${JSON.stringify(list)} should fall back`);
  assert.deepEqual(answer.roots, []);
  assert.match(answer.reason, pattern);
}

function registry(base, sessions) {
  const config = path.join(base, 'cfg');
  fs.mkdirSync(path.join(config, 'sessions'), { recursive: true });
  sessions.forEach((session, index) => {
    fs.writeFileSync(path.join(config, 'sessions', `${index + 1}.json`),
      JSON.stringify({ pid: process.pid, sessionId: session.id, cwd: session.cwd }));
  });
  return config;
}

function armFixture(t, others) {
  const base = scratch(t, 'arm');
  const anchor = repo(path.join(base, 'anchor'));
  const home = path.join(base, 'home');
  const data = path.join(base, 'data');
  const records = path.join(base, 'records');
  for (const dir of [home, data, records]) fs.mkdirSync(dir, { recursive: true });
  const config = registry(base, [{ id: OWN, cwd: anchor }, ...(others || [])]);
  return { base, anchor, home, data, records, config };
}

function request(fx, specs, extra) {
  return {
    anchor: fx.anchor,
    codeRoots: specs,
    baselines: [],
    home: fx.home,
    claudeConfigDir: fx.config,
    pluginData: fx.data,
    sessionId: OWN,
    sessionKey: core.sessionKey(OWN),
    recordsDir: fx.records,
    environment: { CLAUDE_CONFIG_DIR: fx.config },
    worktreeKeepIdleHours: 72,
    ...(extra || {}),
  };
}

function arm(fx, specs, extra) {
  return codeRoots.armCodeRoots(request(fx, specs, extra), ENABLED);
}

function armRefused(fx, specs, pattern, extra) {
  const answer = arm(fx, specs, extra);
  assert.equal(answer.ok, false, `${specs.join(' ')} should be refused`);
  assert.match(answer.reason, pattern);
}

function withEnvironment(values, body) {
  const saved = {};
  for (const name of Object.keys(values)) {
    saved[name] = process.env[name];
    process.env[name] = values[name];
  }
  try {
    return body();
  } finally {
    for (const name of Object.keys(values)) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
  }
}

test('the leaf read-only prefix equals the constant session-trail spells privately', () => {
  const source = fs.readFileSync(path.join(REPO, 'skills/session-trail/scripts/trail.mjs'), 'utf8');
  const match = /^const READ_ONLY_GIT = (\[[^\]]*\]);$/m.exec(source);
  assert.ok(match, 'trail.mjs no longer declares READ_ONLY_GIT on one line');
  assert.deepEqual([...leaf.READ_ONLY_GIT], JSON.parse(match[1].replace(/'/g, '"')));
  assert.deepEqual(leaf.readOnlyGitArgs(['status']), [...leaf.READ_ONLY_GIT, 'status']);
  assert.ok(Object.isFrozen(leaf.READ_ONLY_GIT));
});

test('the leaf git environment scrub equals the evidence runner scrub, pathspec variables included', () => {
  assert.deepEqual([...leaf.GIT_SCRUBBED_ENV], [...evidence.GIT_SCRUBBED_ENV]);
  const polluted = {};
  for (const name of [...leaf.GIT_SCRUBBED_ENV, ...leaf.GIT_PATHSPEC_ENV]) polluted[name] = '/polluted';
  withEnvironment({ ...polluted, LANGUAGE: 'de', LANG: 'de_DE.UTF-8' }, () => {
    const ours = leaf.gitEnvironment({ EXTRA: '1' });
    assert.deepEqual(ours, evidence.gitEnvironment({ EXTRA: '1' }));
    for (const name of Object.keys(polluted)) assert.equal(ours[name], undefined, `${name} survived the scrub`);
    assert.equal(ours.GIT_OPTIONAL_LOCKS, '0');
    assert.equal(ours.LC_ALL, 'C');
    assert.equal(ours.LANG, 'C');
    assert.equal(ours.LANGUAGE, undefined);
    assert.equal(ours.GIT_TERMINAL_PROMPT, '0');
    assert.equal(ours.EXTRA, '1');
  });
});

test('the switch is off, and every document carrying codeRoots reads as anchor-only while it is', () => {
  assert.equal(codeRoots.CODE_ROOTS_ENABLED, false);
  const valid = { active: true, codeRoots: [entry('lib', '/zf/work/lib')] };
  for (const document of [valid, { codeRoots: 'garbage' }, { codeRoots: [] }]) {
    const answer = codeRoots.readCodeRoots(document, CTX);
    assert.equal(answer.status, 'disabled');
    assert.deepEqual(answer.roots, []);
    assert.equal(answer.reason, codeRoots.DISABLED_REASON);
    assert.equal(codeRoots.readCodeRoots(document, CTX, { enabled: false }).status, 'disabled');
  }
  assert.equal(codeRoots.DISABLED_REASON, 'multi-repo chains are not enabled in this build');
  for (const document of [{}, { active: true }, null, undefined, [], 'text']) {
    const answer = codeRoots.readCodeRoots(document, CTX, ENABLED);
    assert.equal(answer.status, 'absent');
    assert.deepEqual(answer.roots, []);
  }
});

test('a valid list reads as declared, and the reader returns copies with exactly the five keys', () => {
  const list = [
    entry('wt', '/zf/work/anchor/.claude/worktrees/wt', { commonDir: '/zf/work/anchor/.git', baseline: SHA }),
    entry('lib', '/zf/work/lib', { baseline: 'b'.repeat(64) }),
    entry('svc', '/zf/home/u/src/svc'),
  ];
  const answer = read(list);
  assert.equal(answer.status, 'ok');
  assert.equal(answer.reason, '');
  assert.deepEqual(answer.roots, list);
  answer.roots[0].path = '/elsewhere';
  assert.equal(list[0].path, '/zf/work/anchor/.claude/worktrees/wt');
  assert.deepEqual(Object.keys(answer.roots[1]).sort(), [...codeRoots.ENTRY_KEYS]);
});

test('an entry shape the reader does not accept falls back to anchor-only and names the entry', () => {
  refused('not a list', /not an array/);
  refused([], /empty/);
  refused(Array.from({ length: 9 }, (_, index) => entry(`r${index}x`, `/zf/work/r${index}`)), /more than 8/);
  refused([null], /entry 1 is not an object/);
  refused([[]], /entry 1 is not an object/);
  refused([{ ...entry('lib', '/zf/work/lib'), extra: 'x' }], /entry 1 carries a key the reader does not know/);
  const missing = entry('lib', '/zf/work/lib');
  delete missing.commonDir;
  refused([missing], /entry 1 lacks its commonDir key/);
  refused([entry('lib', '/zf/work/lib', { baseline: 7 })], /entry 1: its baseline is not a string/);
  refused([entry('lib', '/zf/work/lib'), { ...entry('two', '/zf/work/two'), label: 3 }], /entry 2: its label is not a string/);
});

test('a malformed, one-letter or repeated label falls back to anchor-only', () => {
  for (const label of ['a', 'A1', '1ab', 'ab_c', 'ab c', '-ab', `a${'b'.repeat(32)}`, '']) {
    refused([entry(label, '/zf/work/lib')], /its label does not match/);
  }
  refused([entry('lib', '/zf/work/lib'), entry('lib', '/zf/work/other')], /its label lib repeats entry 1/);
  assert.equal(read([entry('ab', '/zf/work/lib'), entry(`a${'b'.repeat(31)}`, '/zf/work/other')]).status, 'ok');
});

test('every forbidden character in a stored path falls back to anchor-only', () => {
  const characters = ['"', '$', '`', '\\', ',', '=', '\n', '\r',
    String.fromCodePoint(0), String.fromCodePoint(1), String.fromCodePoint(0x1f), String.fromCodePoint(0x7f),
    String.fromCodePoint(0x85), String.fromCodePoint(0x2028), String.fromCodePoint(0x2029)];
  for (const character of characters) {
    refused([entry('lib', `/zf/work/li${character}b`)], /its path holds a forbidden character/);
    refused([entry('lib', '/zf/work/lib', { commonDir: `/zf/work/lib/.g${character}it` })], /its commonDir holds a forbidden character/);
  }
  assert.equal(read([entry('lib', '/zf/work/l ib\'s (copy)')]).status, 'ok');
});

test('a path that is not a canonical absolute spelling, or a baseline that is no commit id, falls back to anchor-only', () => {
  for (const spelled of ['zf/work/lib', '/zf/work/lib/', '/zf/./lib', '/zf/../lib', '/zf//lib', '']) {
    refused([entry('lib', '/zf/work/lib', { path: spelled })], /its path (is not a canonical absolute path|is empty)/);
  }
  refused([entry('lib', '/zf/work/lib', { top: 'relative' })], /its top is not a canonical absolute path/);
  for (const baseline of ['HEAD', 'abc1234', 'A'.repeat(40), 'a'.repeat(41), 'a'.repeat(39), '']) {
    refused([entry('lib', '/zf/work/lib', { baseline })], /its baseline is neither unborn nor a full commit id/);
  }
  for (const baseline of ['unborn', SHA, 'c'.repeat(64)]) {
    assert.equal(read([entry('lib', '/zf/work/lib', { baseline })]).status, 'ok');
  }
});

test('a root that is the anchor, contains it or is a filesystem root falls back to anchor-only', () => {
  refused([entry('self', '/zf/work/anchor')], /code root self: it is the anchor itself/);
  refused([entry('up', '/zf/work')], /code root up: it is an ancestor of the anchor/);
  refused([entry('up', '/zf')], /code root up: it is an ancestor of the anchor/);
  refused([entry('fs', '/', { commonDir: '/.git' })], /code root fs: it is a filesystem root/);
  refused([entry('lib', '/zf/work/lib', { top: '/zf/work/anchor' })], /code root lib: it is the anchor itself/);
  refused([entry('lib', '/zf/work/lib')], /the anchor is unknown/, { ...CTX, anchor: '' });
  assert.equal(read([entry('wt', '/zf/work/anchor/.claude/worktrees/wt')]).status, 'ok');
});

test('a root at a control surface or above $HOME falls back to anchor-only', () => {
  refused([entry('home', '/zf/home/u')], /it is \$HOME/);
  refused([entry('home', '/zf/home')], /it is an ancestor of \$HOME/);
  refused([entry('dot', '/zf/home/u/.claude')], /it is ~\/\.claude/);
  refused([entry('mkt', '/zf/home/u/.claude/plugins/marketplaces/zensu')], /it lies inside ~\/\.claude/);
  refused([entry('cfg', '/zf/cfg/claude')], /it is CLAUDE_CONFIG_DIR/);
  refused([entry('cfg', '/zf/cfg')], /it is an ancestor of CLAUDE_CONFIG_DIR/);
  refused([entry('cfg', '/zf/cfg/claude/projects')], /it lies inside CLAUDE_CONFIG_DIR/);
  refused([entry('plg', '/zf/opt/plugin')], /it is the plugin root/);
  refused([entry('plg', '/zf/opt')], /it is an ancestor of the plugin root/);
  refused([entry('plg', '/zf/opt/plugin/hooks')], /it lies inside the plugin root/);
  refused([entry('dat', '/zf/data/zensu')], /it is the plugin data directory/);
  refused([entry('dat', '/zf/data')], /it is an ancestor of the plugin data directory/);
  refused([entry('dat', '/zf/data/zensu/evidence-run')], /it lies inside the plugin data directory/);
  assert.equal(read([entry('svc', '/zf/home/u/src/svc')]).status, 'ok');
});

test('two roots that name one directory or contain each other fall back to anchor-only, case-folded where the filesystem folds', () => {
  refused([entry('one', '/zf/work/lib'), entry('two', '/zf/work/lib')], /code roots one and two name the same directory/);
  refused([entry('one', '/zf/work/lib'), entry('two', '/zf/work/lib/vendor')], /code roots one and two contain each other/);
  refused([entry('one', '/zf/work/lib/vendor'), entry('two', '/zf/work/lib')], /code roots one and two contain each other/);
  const folded = [entry('one', '/zf/work/Lib'), entry('two', '/zf/work/lib')];
  assert.equal(read(folded).status, 'ok');
  refused(folded, /code roots one and two name the same directory/, { ...CTX, platform: 'darwin' });
  refused([entry('one', '/ZF/WORK/ANCHOR')], /code root one: it is the anchor itself/, { ...CTX, platform: 'darwin' });
  refused([entry('one', '/ZF/HOME/U/.CLAUDE/plugins')], /it lies inside ~\/\.claude/, { ...CTX, platform: 'darwin' });
});

test('a win32 list is read in its forward-slash drive form and a backslash spelling falls back', () => {
  const context = {
    platform: 'win32',
    anchor: 'C:/work/anchor',
    home: 'C:/Users/u',
    claudeConfigDir: '',
    pluginRoot: 'C:/plugins/zensu',
    pluginData: 'C:/data/zensu',
  };
  assert.equal(read([entry('lib', 'D:/src/lib')], context).status, 'ok');
  assert.equal(read([entry('wt', 'C:/work/anchor/.claude/worktrees/wt')], context).status, 'ok');
  refused([entry('lib', 'D:\\src\\lib')], /forbidden character/, context);
  refused([entry('fs', 'D:/', { commonDir: 'D:/.git' })], /it is a filesystem root/, context);
  refused([entry('self', 'c:/WORK/anchor')], /it is the anchor itself/, context);
  refused([entry('dot', 'C:/Users/u/.claude/plugins/x')], /it lies inside ~\/\.claude/, context);
  refused([entry('posix', '/src/lib')], /not a canonical absolute path/, context);
});

test('the module containment predicate equals the parser within, so no consumer of the module loads the parser', () => {
  const parser = require('../../hooks/lib/bash-source-write-parse.js');
  const pairs = [
    ['/zf/a', '/zf/a'],
    ['/zf/a', '/zf/a/b'],
    ['/zf/a', '/zf/ab'],
    ['/zf/a', '/zf'],
    ['/zf/a', '/zf/a/..bak'],
    ['/zf/a', '/zf/a/../b'],
    ['/zf/a/', '/zf/a/b'],
    ['/zf/a//', '/zf/a'],
    ['/', '/zf'],
    ['/', '/'],
  ];
  for (const [rootPath, candidate] of pairs) {
    assert.equal(codeRoots.contains(rootPath, candidate), parser.within(rootPath, candidate), `${rootPath} | ${candidate}`);
  }
});

test('only an active chain that is not done declares live roots', () => {
  const list = [entry('lib', '/zf/src/lib')];
  assert.equal(codeRoots.declaresLiveRoots({ active: true, codeRoots: list }), true);
  assert.equal(codeRoots.declaresLiveRoots({ active: true, chainDone: false, codeRoots: list }), true);
  assert.equal(codeRoots.declaresLiveRoots({ active: true, chainDone: true, codeRoots: list }), false);
  assert.equal(codeRoots.declaresLiveRoots({ active: false, codeRoots: list }), false);
  assert.equal(codeRoots.declaresLiveRoots({ active: 'true', codeRoots: list }), false);
  assert.equal(codeRoots.declaresLiveRoots({ codeRoots: list }), false);
  assert.equal(codeRoots.declaresLiveRoots(null), false);
  assert.equal(codeRoots.declaresLiveRoots('active'), false);
});

test('arming refuses while the switch is off, before it reads anything', () => {
  const answer = codeRoots.armCodeRoots({ anchor: '/nonexistent/anchor', codeRoots: ['lib=/nonexistent/lib'] });
  assert.deepEqual(answer, { ok: false, reason: codeRoots.DISABLED_REASON });
  const viaCli = codeRoots.main(['arm', '--anchor', '/nonexistent/anchor', '--code-root', 'lib=/nonexistent/lib'], {});
  assert.equal(viaCli.code, 2);
  assert.equal(viaCli.out, '');
  assert.equal(viaCli.err, `${codeRoots.DISABLED_REASON}\n`);
});

test('arming refuses a malformed request before it touches the filesystem', (t) => {
  const fx = armFixture(t);
  armRefused(fx, [], /no --code-root was given/);
  armRefused(fx, ['lib'], /--code-root must be spelled <label>=<value>/);
  armRefused(fx, ['=/x'], /--code-root must be spelled <label>=<value>/);
  armRefused(fx, ['Lib=/x'], /a code-root label must match/);
  armRefused(fx, ['l=/x'], /a code-root label must match/);
  armRefused(fx, ['lib=/x', 'lib=/y'], /the code-root label lib is declared twice/);
  armRefused(fx, Array.from({ length: 9 }, (_, index) => `r${index}x=/x${index}`), /at most 8 code roots/);
  armRefused(fx, ['lib='], /code root lib: no path was given/);
  armRefused(fx, ['lib=relative/path'], /code root lib: its path must be absolute/);
  armRefused(fx, ['lib=/x'], /names a label that no --code-root declares|names zzz that no --code-root declares/, { baselines: ['zzz=abc1234'] });
  armRefused(fx, ['lib=/x'], /its baseline is not a hexadecimal commit id/, { baselines: ['lib=HEAD~1'] });
  armRefused(fx, ['lib=/x'], /its baseline is given twice/, { baselines: ['lib=abc1234', 'lib=abc1234'] });
  armRefused(fx, ['lib=/x'], /the anchor could not be resolved/, { anchor: '' });
});

test('arming refuses a path that is missing, not a directory, outside git or inside a work tree below its top', (t) => {
  const fx = armFixture(t);
  const lib = repo(path.join(fx.base, 'lib'));
  write(path.join(fx.base, 'file.txt'), 'x\n');
  fs.mkdirSync(path.join(fx.base, 'plain'));
  fs.mkdirSync(path.join(lib, 'sub'));
  armRefused(fx, [`lib=${path.join(fx.base, 'missing')}`], /code root lib: its path does not exist/);
  armRefused(fx, [`lib=${path.join(fx.base, 'file.txt')}`], /code root lib: its path is not a directory/);
  armRefused(fx, [`lib=${path.join(fx.base, 'plain')}`], /code root lib: it is not a git work tree/);
  armRefused(fx, [`lib=${path.join(lib, 'sub')}`], /code root lib: it lies inside the work tree .* but is not its top/);
  armRefused(fx, [`lib=${fx.anchor}`], /code root lib: it is the anchor itself/);
  armRefused(fx, [`lib=${fx.base}`], /code root lib: it is an ancestor of the anchor/);
  armRefused(fx, [`lib=${fx.home}`], /code root lib: it is \$HOME/);
  armRefused(fx, [`cfg=${fx.config}`], /code root cfg: it is CLAUDE_CONFIG_DIR/);
  armRefused(fx, [`lib=${lib}`, `sub=${path.join(lib, 'sub')}`], /code roots lib and sub contain each other/);
});

test('arming refuses a baseline that is not an ancestor of HEAD, names no commit, or meets an unborn HEAD', (t) => {
  const fx = armFixture(t);
  const lib = repo(path.join(fx.base, 'lib'));
  const seed = head(lib);
  git(lib, 'checkout', '-q', '-b', 'side');
  write(path.join(lib, 'side.txt'), 'side\n');
  git(lib, 'add', '-A');
  git(lib, 'commit', '-q', '-m', 'side');
  const side = head(lib);
  git(lib, 'checkout', '-q', 'main');
  const unborn = path.join(fx.base, 'unborn');
  fs.mkdirSync(unborn);
  git(unborn, 'init', '-q');
  armRefused(fx, [`lib=${lib}`], /code root lib: its baseline is not an ancestor of the root's HEAD/, { baselines: [`lib=${side}`] });
  armRefused(fx, [`lib=${lib}`], /code root lib: its baseline does not name a commit/, { baselines: [`lib=${'d'.repeat(40)}`] });
  armRefused(fx, [`fresh=${unborn}`], /code root fresh: its HEAD is unborn/, { baselines: [`fresh=${seed}`] });
});

test('arming refuses a root whose label an anchor entry named @<label> would shadow', (t) => {
  const fx = armFixture(t);
  const lib = repo(path.join(fx.base, 'lib'));
  write(path.join(fx.anchor, '@lib'), 'shadow\n');
  armRefused(fx, [`lib=${lib}`], /code root lib: the anchor holds a top-level entry named @lib/);
  assert.equal(arm(fx, [`api=${lib}`]).ok, true);
});

test('arming accepts a nested worktree, a symlinked sibling and a root below $HOME, and records canonical paths with their baselines', (t) => {
  const fx = armFixture(t);
  const wt = path.join(fx.anchor, '.claude', 'worktrees', 'wt');
  git(fx.anchor, 'worktree', 'add', '-q', '-b', 'wt', wt);
  const lib = repo(path.join(fx.base, 'lib'));
  const first = head(lib);
  write(path.join(lib, 'second.txt'), 'second\n');
  git(lib, 'add', '-A');
  git(lib, 'commit', '-q', '-m', 'second');
  fs.symlinkSync(lib, path.join(fx.base, 'lib-link'), 'dir');
  const svc = repo(path.join(fx.home, 'src', 'svc'));
  const fresh = path.join(fx.base, 'fresh');
  fs.mkdirSync(fresh);
  git(fresh, 'init', '-q');
  const answer = arm(fx, [`wt=${wt}`, `lib=${path.join(fx.base, 'lib-link')}`, `svc=${svc}`, `fresh=${fresh}`],
    { baselines: [`lib=${first.slice(0, 12)}`] });
  assert.equal(answer.ok, true, answer.reason);
  assert.deepEqual(answer.roots, [
    { label: 'wt', path: wt, top: wt, commonDir: path.join(fx.anchor, '.git'), baseline: head(wt) },
    { label: 'lib', path: lib, top: lib, commonDir: path.join(lib, '.git'), baseline: first },
    { label: 'svc', path: svc, top: svc, commonDir: path.join(svc, '.git'), baseline: head(svc) },
    { label: 'fresh', path: fresh, top: fresh, commonDir: path.join(fresh, '.git'), baseline: 'unborn' },
  ]);
  const document = { active: true, codeRoots: answer.roots };
  const reread = codeRoots.readCodeRoots(document, { anchor: fx.anchor, home: fx.home, claudeConfigDir: fx.config, pluginData: fx.data }, ENABLED);
  assert.equal(reread.status, 'ok', reread.reason);
});

test('arming on a folder anchor accepts a work tree nested under it beside a live session anchored on the same folder', (t) => {
  const base = scratch(t, 'folder');
  const anchor = path.join(base, 'anchor');
  fs.mkdirSync(anchor);
  const lib = repo(path.join(anchor, 'lib'));
  const home = path.join(base, 'home');
  const data = path.join(base, 'data');
  const records = path.join(base, 'records');
  for (const dir of [home, data, records]) fs.mkdirSync(dir, { recursive: true });
  const config = registry(base, [{ id: OWN, cwd: anchor }, { id: OTHER, cwd: anchor }]);
  fs.writeFileSync(path.join(records, `${core.sessionKey(OTHER)}.json`), JSON.stringify({ project_root: anchor }));
  const answer = arm({ base, anchor, home, data, records, config }, [`lib=${lib}`]);
  assert.equal(answer.ok, true, answer.reason);
  assert.deepEqual(answer.roots, [{ label: 'lib', path: lib, top: lib, commonDir: path.join(lib, '.git'), baseline: head(lib) }]);
});

test('arming refuses a root another live session works in, is recorded in, or that another live chain declared', (t) => {
  const working = armFixture(t, [{ id: OTHER, cwd: '' }]);
  const lib = repo(path.join(working.base, 'lib'));
  fs.writeFileSync(path.join(working.config, 'sessions', '2.json'),
    JSON.stringify({ pid: process.pid, sessionId: OTHER, cwd: path.join(lib, 'src') }));
  armRefused(working, [`lib=${lib}`], /code root lib: another live session claims it/);

  const recorded = armFixture(t, [{ id: OTHER, cwd: '/zf-elsewhere' }]);
  const lib2 = repo(path.join(recorded.base, 'lib'));
  fs.mkdirSync(path.join(lib2, 'sub'));
  fs.writeFileSync(path.join(recorded.records, `${core.sessionKey(OTHER)}.json`), JSON.stringify({ project_root: path.join(lib2, 'sub') }));
  armRefused(recorded, [`lib=${lib2}`], /code root lib: another live session claims it/);

  const declared = armFixture(t);
  const lib3 = repo(path.join(declared.base, 'lib'));
  const otherAnchor = repo(path.join(declared.base, 'other-anchor'));
  fs.writeFileSync(path.join(declared.config, 'sessions', '2.json'),
    JSON.stringify({ pid: process.pid, sessionId: OTHER, cwd: otherAnchor }));
  fs.writeFileSync(path.join(declared.records, `${core.sessionKey(OTHER)}.json`), JSON.stringify({ project_root: otherAnchor }));
  const documentPath = core.adoptionWorkflowStatePath(otherAnchor, OTHER);
  write(documentPath, JSON.stringify({ active: true, codeRoots: [root('shared', lib3, 'unborn')] }));
  armRefused(declared, [`lib=${lib3}`], /code root lib: live session pid \d+ declared the overlapping code root shared/);
  write(documentPath, JSON.stringify({ active: true, chainDone: true, codeRoots: [root('shared', lib3, 'unborn')] }));
  assert.equal(arm(declared, [`lib=${lib3}`]).ok, true);
  write(documentPath, JSON.stringify({ active: false, codeRoots: [root('shared', lib3, 'unborn')] }));
  assert.equal(arm(declared, [`lib=${lib3}`]).ok, true);
  fs.rmSync(documentPath);
  fs.mkdirSync(documentPath);
  armRefused(declared, [`lib=${lib3}`], /the workflow document of live session pid \d+ could not be read/);
});

test('arming refuses when the live sessions cannot be verified or the session identity does not match', (t) => {
  const fx = armFixture(t);
  const lib = repo(path.join(fx.base, 'lib'));
  armRefused(fx, [`lib=${lib}`], /names another session than the one this chain is bound to/, { sessionKey: core.sessionKey(OTHER) });
  armRefused(fx, [`lib=${lib}`], /this session cannot be identified/, { sessionId: '' });
  armRefused(fx, [`lib=${lib}`], /the private Session Control records could not be read, so the live sessions cannot be verified/, { recordsDir: '' });
  armRefused(fx, [`lib=${lib}`], /the live sessions could not be verified \(the live-session registry .* cannot be read/,
    { environment: { CLAUDE_CONFIG_DIR: path.join(fx.base, 'no-config') } });
  const lonely = registry(path.join(fx.base, 'lonely'), [{ id: OTHER, cwd: '/zf-elsewhere' }]);
  armRefused(fx, [`lib=${lib}`], /this session is not in the live-session registry/, { environment: { CLAUDE_CONFIG_DIR: lonely } });
  fs.writeFileSync(path.join(fx.config, 'sessions', `${process.pid}.json`), '{not json');
  armRefused(fx, [`lib=${lib}`], /the live-session registry entry \d+\.json cannot be read/);
  fs.rmSync(path.join(fx.config, 'sessions', `${process.pid}.json`));
  fs.writeFileSync(path.join(fx.config, 'sessions', '2.json'), JSON.stringify({ pid: process.pid, sessionId: OTHER, cwd: '/zf-elsewhere' }));
  fs.writeFileSync(path.join(fx.records, `${core.sessionKey(OTHER)}.json`), '{not json');
  armRefused(fx, [`lib=${lib}`], /the Session Control record of live session pid \d+ cannot be read/);
});

test('a born root lists worktree, index, untracked and committed-since-baseline changes, renames by their new name', (t) => {
  const base = scratch(t, 'born');
  const lib = repo(path.join(base, 'lib'), { 'a.txt': 'a\n', 'b.txt': 'b\n', 'c.txt': 'c\n', 'keep.txt': 'k\n' });
  const baseline = head(lib);
  write(path.join(lib, 'g.txt'), 'g\n');
  git(lib, 'add', 'g.txt');
  git(lib, 'commit', '-q', '-m', 'mid-run');
  write(path.join(lib, 'a.txt'), 'changed\n');
  write(path.join(lib, 'e.txt'), 'e\n');
  git(lib, 'add', 'e.txt');
  write(path.join(lib, 'dir with space', 'f.txt'), 'f\n');
  fs.rmSync(path.join(lib, 'b.txt'));
  git(lib, 'mv', 'c.txt', 'c2.txt');
  const expected = ['a.txt', 'b.txt', 'c2.txt', 'dir with space/f.txt', 'e.txt', 'g.txt'];
  assert.deepEqual(codeRoots.enumerateRoot(root('lib', lib, baseline)), { ok: true, paths: expected });
  assert.deepEqual(codeRoots.countRoot(root('lib', lib, baseline)), { ok: true, count: expected.length });
  assert.deepEqual(codeRoots.enumerateRoot(root('lib', lib, head(lib))).paths, expected.filter((name) => name !== 'g.txt'));
});

test('the count follows the terminus recipe and keeps the global excludes file the enumeration drops', (t) => {
  const base = scratch(t, 'excludes');
  const lib = repo(path.join(base, 'lib'), { '.gitignore': '*.log\n' });
  write(path.join(lib, 'new.txt'), 'n\n');
  write(path.join(lib, 'only-global.globalignored'), 'g\n');
  write(path.join(lib, 'ignored.log'), 'l\n');
  const r = root('lib', lib, head(lib));
  assert.deepEqual(codeRoots.enumerateRoot(r).paths, ['new.txt', 'only-global.globalignored']);
  assert.deepEqual(codeRoots.countRoot(r), { ok: true, count: 1 });
});

test('an unborn root lists its index and untracked files, and a root armed unborn counts every file its first commits add', (t) => {
  const base = scratch(t, 'unborn');
  const fresh = path.join(base, 'fresh');
  fs.mkdirSync(fresh);
  git(fresh, 'init', '-q');
  write(path.join(fresh, 'staged.txt'), 's\n');
  git(fresh, 'add', 'staged.txt');
  write(path.join(fresh, 'untracked.txt'), 'u\n');
  const r = root('fresh', fresh, 'unborn');
  assert.deepEqual(codeRoots.enumerateRoot(r), { ok: true, paths: ['staged.txt', 'untracked.txt'] });
  assert.deepEqual(codeRoots.countRoot(r), { ok: true, count: 2 });
  git(fresh, 'add', '-A');
  git(fresh, 'commit', '-q', '-m', 'first');
  assert.deepEqual(codeRoots.enumerateRoot(r), { ok: true, paths: ['staged.txt', 'untracked.txt'] });
  assert.deepEqual(codeRoots.countRoot(r), { ok: true, count: 2 });
  assert.deepEqual(codeRoots.countRoot(root('fresh', fresh, head(fresh))), { ok: true, count: 0 });
});

test('a root that vanished, stopped being a work-tree top or lost its baseline is a fault naming the git command, never a clean count', (t) => {
  const base = scratch(t, 'faults');
  const gone = codeRoots.enumerateRoot(root('gone', path.join(base, 'gone')));
  assert.equal(gone.ok, false);
  assert.match(gone.command, /^git -C .*gone rev-parse --show-toplevel$/);
  assert.notEqual(gone.message, '');
  const counted = codeRoots.countRoot(root('gone', path.join(base, 'gone')));
  assert.equal(counted.ok, false);
  assert.equal(counted.count, 'unavailable');
  const outer = repo(path.join(base, 'outer'));
  fs.mkdirSync(path.join(outer, 'plain'));
  const moved = codeRoots.enumerateRoot(root('plain', path.join(outer, 'plain')));
  assert.equal(moved.ok, false);
  assert.match(moved.message, /no longer the top of a git work tree/);
  const lib = repo(path.join(base, 'lib'));
  const lost = codeRoots.enumerateRoot(root('lib', lib, '0'.repeat(40)));
  assert.equal(lost.ok, false);
  assert.match(lost.command, /rev-parse --verify --quiet 0{40}\^\{commit\}$/);
  const fresh = path.join(base, 'fresh');
  fs.mkdirSync(fresh);
  git(fresh, 'init', '-q');
  const orphaned = codeRoots.enumerateRoot(root('fresh', fresh, SHA));
  assert.equal(orphaned.ok, false);
  assert.match(orphaned.message, /HEAD is unborn while the recorded baseline names a commit/);
});

test('a root replaced by a symlink after arming is followed, as the use-time bound accepts', (t) => {
  const base = scratch(t, 'followed');
  const armed = path.join(base, 'armed');
  fs.mkdirSync(armed);
  git(armed, 'init', '-q');
  const other = repo(path.join(base, 'other'));
  write(path.join(other, 'b-only.txt'), 'b\n');
  fs.renameSync(armed, path.join(base, 'armed-moved'));
  fs.symlinkSync(other, armed, 'dir');
  assert.deepEqual(codeRoots.enumerateRoot(root('armed', armed, 'unborn')), { ok: true, paths: ['README.md', 'b-only.txt'] });
});

test('every git call into a code root carries the read-only prefix: no fsmonitor hook runs and the index is not rewritten', (t) => {
  const base = scratch(t, 'readonly');
  const lib = repo(path.join(base, 'lib'), { 'tracked.txt': 'same\n', '.gitignore': '*.log\n' });
  const marker = path.join(base, 'fsmonitor-ran');
  const hook = path.join(base, 'fsmonitor-hook.sh');
  fs.writeFileSync(hook, `#!/bin/sh\ntouch '${marker}'\nexit 1\n`, { mode: 0o755 });
  git(lib, 'config', 'core.fsmonitor', hook);
  const index = path.join(lib, '.git', 'index');
  const past = new Date(Date.now() - 3600 * 1000);
  fs.utimesSync(path.join(lib, 'tracked.txt'), past, past);
  const before = fs.statSync(index).mtimeMs;
  const r = root('lib', lib, head(lib));
  assert.deepEqual(codeRoots.enumerateRoot(r), { ok: true, paths: [] });
  assert.deepEqual(codeRoots.countRoot(r), { ok: true, count: 0 });
  assert.deepEqual(codeRoots.isIgnored(lib, 'x.log'), { ok: true, ignored: true });
  assert.equal(fs.existsSync(marker), false, 'the fsmonitor hook ran');
  assert.equal(fs.statSync(index).mtimeMs, before, 'the index was rewritten');
  git(lib, 'status', '--porcelain');
  assert.equal(fs.existsSync(marker), true, 'control: a plain git status runs the hook');
  assert.notEqual(fs.statSync(index).mtimeMs, before, 'control: a plain git status rewrites the index');
});

test('the environment scrub keeps an inherited GIT_DIR and a literal-pathspec switch from moving a code root', (t) => {
  const base = scratch(t, 'scrub');
  const lib = repo(path.join(base, 'lib'));
  const decoy = repo(path.join(base, 'decoy'), { 'DECOY.md': 'decoy\n' });
  write(path.join(decoy, 'decoy-only.txt'), 'd\n');
  write(path.join(lib, 'lib-only.txt'), 'l\n');
  const baseline = head(lib);
  assert.notEqual(baseline, head(decoy));
  withEnvironment({ GIT_DIR: path.join(decoy, '.git'), GIT_WORK_TREE: decoy, GIT_LITERAL_PATHSPECS: '1', GIT_INDEX_FILE: path.join(decoy, '.git', 'index') }, () => {
    assert.deepEqual(codeRoots.enumerateRoot(root('lib', lib, baseline)), { ok: true, paths: ['lib-only.txt'] });
    assert.deepEqual(codeRoots.isIgnored(lib, 'lib-only.txt'), { ok: true, ignored: false });
  });
});

test('check-ignore runs through the module with the in-repo rules alone, and a fault is not an answer', (t) => {
  const base = scratch(t, 'ignored');
  const lib = repo(path.join(base, 'lib'), { '.gitignore': '*.log\n' });
  assert.deepEqual(codeRoots.isIgnored(lib, 'x.log'), { ok: true, ignored: true });
  assert.deepEqual(codeRoots.isIgnored(lib, 'x.txt'), { ok: true, ignored: false });
  assert.deepEqual(codeRoots.isIgnored(lib, 'x.globalignored'), { ok: true, ignored: false });
  const fault = codeRoots.isIgnored(path.join(base, 'missing'), 'x.log');
  assert.equal(fault.ok, false);
  assert.match(fault.command, /check-ignore -q -- x\.log$/);
});

test('the anchor excludes every declared root inside it and an untracked link that resolves to one', (t) => {
  const base = scratch(t, 'exclusions');
  const anchor = repo(path.join(base, 'anchor'));
  const wt = path.join(anchor, '.claude', 'worktrees', 'wt');
  git(anchor, 'worktree', 'add', '-q', '-b', 'wt', wt);
  const nested = path.join(anchor, 'sub', 'vendor', 'clone');
  repo(nested);
  const lib = repo(path.join(base, 'lib'));
  fs.symlinkSync(lib, path.join(anchor, 'lib-link'), 'dir');
  fs.symlinkSync(path.join(base, 'unrelated'), path.join(anchor, 'unrelated-link'), 'dir');
  const roots = [root('wt', wt), root('lib', lib), root('clone', nested)];
  assert.deepEqual(codeRoots.anchorExclusions(anchor, roots), { ok: true, exclusions: ['.claude/worktrees/wt', 'sub/vendor/clone', 'lib-link'] });
  assert.deepEqual(codeRoots.anchorExclusions(path.join(anchor, 'sub'), [root('clone', nested)]), { ok: true, exclusions: ['sub/vendor/clone'] });
  assert.deepEqual(codeRoots.anchorExclusions(anchor, []), { ok: true, exclusions: [] });
  const plain = path.join(base, 'plain');
  fs.mkdirSync(plain);
  assert.deepEqual(codeRoots.anchorExclusions(plain, roots), { ok: true, exclusions: [] });
});

test('numstat records parse plain, binary, renamed and copied paths', () => {
  const records = ['1\t2\ta.txt', '-\t-\tbin.dat', '0\t0\t', 'old.txt', 'new.txt', '3\t1\t', 'src.txt', 'copy.txt', 'x\ty\tname with\ttab', ''];
  assert.deepEqual(codeRoots.numstatPaths(records.join('\0')), ['a.txt', 'bin.dat', 'new.txt', 'copy.txt', 'name with\ttab']);
  assert.deepEqual(codeRoots.numstatPaths(''), []);
});

test('the CLI reports status, roots, exclusions, counts, files and faults in tab-separated lines', (t) => {
  const base = scratch(t, 'cli');
  const anchor = repo(path.join(base, 'anchor'));
  const wt = path.join(anchor, '.claude', 'worktrees', 'wt');
  git(anchor, 'worktree', 'add', '-q', '-b', 'wt', wt);
  write(path.join(wt, 'wt-change.txt'), 'w\n');
  const lib = repo(path.join(base, 'lib'));
  write(path.join(lib, 'lib-change.txt'), 'l\n');
  const gone = path.join(base, 'gone');
  const workflow = path.join(base, 'workflow.json');
  const list = [root('wt', wt, head(wt)), root('lib', lib, head(lib)), root('gone', gone, 'unborn')];
  write(workflow, JSON.stringify({ active: true, codeRoots: list }));
  const args = ['--anchor', anchor, '--workflow', workflow, '--plugin-data', path.join(base, 'data')];
  const rootLines = list.map((r) => `root\t${r.label}\t${r.path}\t${r.top}\t${r.baseline}`);
  const readOut = codeRoots.main(['read', ...args], {}, ENABLED);
  assert.deepEqual(readOut, { out: ['status\tok\t', ...rootLines, ''].join('\n'), err: '', code: 0 });
  const counted = codeRoots.main(['count', ...args], {}, ENABLED);
  assert.equal(counted.code, 0);
  const countLines = counted.out.split('\n');
  assert.deepEqual(countLines.slice(0, 5), ['status\tok\t', ...rootLines, 'exclude\t.claude/worktrees/wt']);
  assert.equal(countLines[5], 'count\twt\t1');
  assert.equal(countLines[6], 'count\tlib\t1');
  assert.match(countLines[7], /^count\tgone\tunavailable\tgit -C .*gone rev-parse --show-toplevel\t\d+\t.+$/);
  const listed = codeRoots.main(['enumerate', ...args], {}, ENABLED).out.split('\n');
  assert.deepEqual(listed.slice(5, 7), ['file\twt\twt-change.txt', 'file\tlib\tlib-change.txt']);
  assert.match(listed[7], /^fault\tgone\tgit -C .*gone rev-parse --show-toplevel\t\d+\t.+$/);
  const disabled = codeRoots.main(['count', ...args], {});
  assert.deepEqual(disabled, { out: `status\tdisabled\t${codeRoots.DISABLED_REASON}\n`, err: '', code: 0 });
  const absent = codeRoots.main(['enumerate', '--anchor', anchor, '--workflow', path.join(base, 'missing.json')], {}, ENABLED);
  assert.deepEqual(absent, { out: 'status\tabsent\t\n', err: '', code: 0 });
  write(workflow, JSON.stringify({ active: true, codeRoots: [{ ...list[1], extra: 1 }] }));
  const fallback = codeRoots.main(['count', ...args], {}, ENABLED);
  assert.deepEqual(fallback, { out: 'status\tanchor-only\tentry 1 carries a key the reader does not know\n', err: '', code: 0 });
});

test('the CLI usage errors exit 2 and the ignored verb answers 0, 1 or 2', (t) => {
  const base = scratch(t, 'usage');
  const lib = repo(path.join(base, 'lib'), { '.gitignore': '*.log\n' });
  for (const argv of [[], ['bogus'], ['read'], ['read', '--anchor'], ['read', '--anchor', '/a', '--anchor', '/b'], ['read', '--weird', 'x'], ['ignored', '--top', lib]]) {
    const answer = codeRoots.main(argv, {});
    assert.equal(answer.code, 2, `${JSON.stringify(argv)} should be a usage error`);
    assert.match(answer.err, /^code-roots-v1: /);
  }
  assert.equal(codeRoots.main(['ignored', '--top', lib, '--path', 'x.log'], {}).code, 0);
  assert.equal(codeRoots.main(['ignored', '--top', lib, '--path', 'x.txt'], {}).code, 1);
  const fault = codeRoots.main(['ignored', '--top', path.join(base, 'missing'), '--path', 'x.log'], {});
  assert.equal(fault.code, 2);
  assert.match(fault.err, /check-ignore -q -- x\.log exited \d+: /);
  const run = spawnSync(process.execPath, [path.join(REPO, 'hooks/lib/code-roots-v1.js'), 'ignored', '--top', lib, '--path', 'x.log'], { encoding: 'utf8' });
  assert.equal(run.status, 0);
});
