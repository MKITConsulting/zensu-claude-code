'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const MODULE = path.resolve(__dirname, '../../hooks/lib/repo-conventions-v1.js');
const conventions = require(MODULE);
const ZERO_TRAILERS = Object.freeze({ 'Co-authored-by': 0, 'Signed-off-by': 0, 'Assisted-by': 0 });
const BASE_TIME = 1767225600;

function tempDir(t) {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'repo-conventions-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function fixture(t) {
  const root = tempDir(t);
  const repo = path.join(root, 'repo');
  fs.mkdirSync(repo);
  fs.writeFileSync(path.join(root, 'gitconfig'), '');
  const env = Object.assign({}, process.env, { GIT_CONFIG_GLOBAL: path.join(root, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' });
  for (const name of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR']) delete env[name];
  let clock = 0;
  const run = (args) => {
    clock += 1;
    const stamp = `${BASE_TIME + clock * 60} +0000`;
    const result = spawnSync('git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
      '-c', 'commit.gpgsign=false', '-c', 'init.defaultBranch=main', ...args], {
      cwd: repo,
      env: Object.assign({}, env, { GIT_AUTHOR_DATE: stamp, GIT_COMMITTER_DATE: stamp }),
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, `git ${args.join(' ')} failed: ${result.stderr}`);
    return result.stdout;
  };
  run(['init', '--quiet']);
  return {
    root,
    repo,
    env,
    git: (...args) => run(args),
    write(rel, text = 'text\n') {
      const file = path.join(repo, rel);
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, text);
    },
    add: () => run(['add', '--all']),
    commit: (subject, body) => run(['commit', '--quiet', '--allow-empty', '-m', subject, ...(body ? ['-m', body] : [])]),
    probe: (provider) => conventions.probe({ repo, provider, env }),
  };
}

test('a GitHub layout reports every convention source as JSON fields', (t) => {
  const f = fixture(t);
  f.write('.github/pull_request_template.md', '## Summary\n');
  f.write('.github/PULL_REQUEST_TEMPLATE/feature.md');
  f.write('CONTRIBUTING.md');
  f.write('AGENTS.md');
  f.write('CLAUDE.md');
  f.write('commitlint.config.js', 'module.exports = {};\n');
  f.add();
  f.commit('feat(api): add the endpoint', 'Signed-off-by: Fixture <fixture@example.test>');
  f.commit('fix: handle the empty case');
  f.commit('Update the readme');
  assert.deepEqual(f.probe('github'), {
    provider: 'github',
    prTemplate: '.github/pull_request_template.md',
    prTemplateRefused: null,
    prTemplates: ['.github/pull_request_template.md', '.github/PULL_REQUEST_TEMPLATE/feature.md'],
    overrides: [],
    commitlint: ['commitlint.config.js'],
    ref: 'HEAD',
    defaultBranch: null,
    subjects: ['Update the readme', 'fix: handle the empty case', 'feat(api): add the endpoint'],
    conventionalShare: 0.67,
    trailers: { 'Co-authored-by': 0, 'Signed-off-by': 1, 'Assisted-by': 0 },
    contributing: ['CONTRIBUTING.md'],
    agents: ['AGENTS.md'],
    claude: ['CLAUDE.md'],
  });
});

test('a GitLab layout takes Default.md as the default and lists every merge request template', (t) => {
  const f = fixture(t);
  f.write('.gitlab/merge_request_templates/Default.md');
  f.write('.gitlab/merge_request_templates/bug.md');
  f.write('.gitlab/merge_request_templates/notes.txt');
  f.write('docs/CONTRIBUTING.md');
  f.write('.claude/CLAUDE.md');
  f.add();
  f.commit('chore: start');
  const found = f.probe('gitlab');
  assert.equal(found.provider, 'gitlab');
  assert.equal(found.prTemplate, '.gitlab/merge_request_templates/Default.md');
  assert.deepEqual(found.prTemplates, ['.gitlab/merge_request_templates/Default.md', '.gitlab/merge_request_templates/bug.md']);
  assert.deepEqual(found.contributing, ['docs/CONTRIBUTING.md']);
  assert.deepEqual(found.claude, ['.claude/CLAUDE.md']);
  assert.deepEqual(found.agents, []);
});

test('the GitHub default template takes .github/ first, then the root, then docs/, in any letter case and as .md or .txt', (t) => {
  const f = fixture(t);
  f.write('docs/pull_request_template.md');
  f.write('PULL_REQUEST_TEMPLATE.txt');
  f.add();
  f.commit('chore: start');
  assert.equal(f.probe('github').prTemplate, 'PULL_REQUEST_TEMPLATE.txt');
  f.write('.github/Pull_Request_Template.MD');
  f.write('.github/pull_request_template.yml');
  f.add();
  f.commit('chore: more templates');
  const found = f.probe('github');
  assert.equal(found.prTemplate, '.github/Pull_Request_Template.MD');
  assert.deepEqual(found.prTemplates, ['.github/Pull_Request_Template.MD', 'PULL_REQUEST_TEMPLATE.txt', 'docs/pull_request_template.md']);
});

test('an unknown provider names no default template but still lists every template found', (t) => {
  const f = fixture(t);
  f.write('.github/pull_request_template.md');
  f.write('.gitlab/merge_request_templates/Default.md');
  f.add();
  f.commit('chore: start');
  const found = f.probe('unknown');
  assert.equal(found.prTemplate, null);
  assert.deepEqual(found.prTemplates, ['.github/pull_request_template.md', '.gitlab/merge_request_templates/Default.md']);
  assert.equal(conventions.probe({ repo: f.repo, provider: 'bitbucket', env: f.env }).provider, 'unknown');
});

test('a template that git does not track is not reported', (t) => {
  const f = fixture(t);
  f.write('README.md');
  f.add();
  f.commit('chore: start');
  f.write('.github/pull_request_template.md');
  f.write('AGENTS.md');
  const found = f.probe('github');
  assert.equal(found.prTemplate, null);
  assert.deepEqual(found.prTemplates, []);
  assert.deepEqual(found.agents, []);
});

test('a template tracked as a symlink is not reported, so a link to a file outside the repository never reaches a pull request body', (t) => {
  if (process.platform === 'win32') {
    t.skip('creating a symlink needs extra privileges on Windows');
    return;
  }
  const f = fixture(t);
  const outside = path.join(f.root, 'outside.txt');
  fs.writeFileSync(outside, 'private\n');
  fs.mkdirSync(path.join(f.repo, '.github'));
  fs.symlinkSync(outside, path.join(f.repo, '.github', 'pull_request_template.md'));
  f.write('CONTRIBUTING.md');
  f.add();
  f.commit('chore: start');
  const found = f.probe('github');
  assert.equal(found.prTemplate, null);
  assert.deepEqual(found.prTemplates, []);
  assert.deepEqual(found.contributing, ['CONTRIBUTING.md']);
});

test('a configured template is reported once git tracks it as a plain .md or .txt file, and refused with a reason otherwise', (t) => {
  const f = fixture(t);
  f.write('.github/pull_request_template.md');
  f.write('docs/review/checklist.md', '## Checklist\n');
  f.write('docs/notes.TXT');
  f.write('docs/a b.md');
  f.write('.env.md');
  f.write('config/settings.json', '{}\n');
  f.write('docs/large.md', 'x'.repeat(conventions.TEMPLATE_MAX_BYTES + 1));
  f.write('.gitignore', 'docs/ignored.md\n');
  f.add();
  f.commit('chore: start');
  f.write('docs/ignored.md');
  f.write('docs/untracked.md');
  fs.writeFileSync(path.join(f.root, 'outside.md'), 'private\n');
  const configured = (template) => conventions.probe({ repo: f.repo, provider: 'github', template, env: f.env });
  for (const [template, kept] of [['docs/review/checklist.md', 'docs/review/checklist.md'], ['docs/notes.TXT', 'docs/notes.TXT'], ['.env.md', '.env.md']]) {
    const found = configured(template);
    assert.equal(found.prTemplate, kept, template);
    assert.equal(found.prTemplateRefused, null, template);
  }
  const refusals = [
    [path.join(f.root, 'outside.md'), /not a relative path below the top level/],
    ['C:/outside.md', /not a relative path below the top level/],
    ['/etc/outside.md', /not a relative path below the top level/],
    ['../outside.md', /not a relative path below the top level/],
    ['docs/../.github/pull_request_template.md', /not a relative path below the top level/],
    ['./docs/review/checklist.md', /not a relative path below the top level/],
    ['docs//review/checklist.md', /not a relative path below the top level/],
    ['', /not a relative path below the top level/],
    ['docs/a b.md', /a character other than a letter/],
    ['docs\\review\\checklist.md', /a character other than a letter/],
    ['docs/-review.md', /a path segment starts with a dash/],
    ['config/settings.json', /names no \.md or \.txt file/],
    ['docs/untracked.md', /git does not track the file/],
    ['docs/ignored.md', /git does not track the file/],
    ['docs/missing.md', /git does not track the file/],
    ['docs/REVIEW/checklist.md', /git does not track the file/],
    ['docs/large.md', /larger than 65536 bytes/],
  ];
  for (const [template, reason] of refusals) {
    const found = configured(template);
    assert.equal(found.prTemplate, null, template);
    assert.match(found.prTemplateRefused, reason, template);
    assert.deepEqual(found.prTemplates, ['.github/pull_request_template.md'], template);
  }
});

test('overrides lists the plain .md files under .zensu/templates, tracked or not, below the size bound', (t) => {
  const f = fixture(t);
  f.write('.zensu/templates/pr-body.md', '## Acceptance criteria\n');
  f.write('.zensu/templates/tdd-plan.md');
  f.add();
  f.commit('chore: start');
  f.write('.zensu/templates/autopilot-pr-body.md');
  f.write('.zensu/templates/notes.txt');
  f.write('.zensu/templates/large.md', 'x'.repeat(conventions.TEMPLATE_MAX_BYTES + 1));
  fs.mkdirSync(path.join(f.repo, '.zensu', 'templates', 'nested.md'));
  assert.deepEqual(f.probe('github').overrides, ['.zensu/templates/autopilot-pr-body.md', '.zensu/templates/pr-body.md', '.zensu/templates/tdd-plan.md']);
  const empty = fixture(t);
  empty.commit('chore: start');
  assert.deepEqual(empty.probe('github').overrides, []);
  empty.write('.zensu', 'not a directory\n');
  assert.deepEqual(empty.probe('github').overrides, []);
});

test('a symlink anywhere on a template path is refused: a configured template, a forge template below a linked directory and every override', (t) => {
  if (process.platform === 'win32') {
    t.skip('creating a symlink needs extra privileges on Windows');
    return;
  }
  const f = fixture(t);
  const outside = path.join(f.root, 'outside');
  fs.mkdirSync(outside);
  fs.writeFileSync(path.join(outside, 'pull_request_template.md'), 'private\n');
  fs.writeFileSync(path.join(outside, 'pr-body.md'), 'private\n');
  f.write('.github/pull_request_template.md');
  f.write('docs/review/checklist.md');
  fs.mkdirSync(path.join(f.repo, 'linked'));
  fs.symlinkSync(path.join(outside, 'pull_request_template.md'), path.join(f.repo, 'linked', 'template.md'));
  f.add();
  f.commit('chore: start');
  const linked = conventions.probe({ repo: f.repo, provider: 'github', template: 'linked/template.md', env: f.env });
  assert.equal(linked.prTemplate, null);
  assert.match(linked.prTemplateRefused, /is a symlink, or the file is not a regular file/);
  fs.rmSync(path.join(f.repo, 'docs', 'review'), { recursive: true });
  fs.symlinkSync(outside, path.join(f.repo, 'docs', 'review'));
  fs.writeFileSync(path.join(outside, 'checklist.md'), 'private\n');
  const below = conventions.probe({ repo: f.repo, provider: 'github', template: 'docs/review/checklist.md', env: f.env });
  assert.equal(below.prTemplate, null);
  assert.match(below.prTemplateRefused, /is a symlink, or the file is not a regular file/);
  fs.rmSync(path.join(f.repo, '.github'), { recursive: true });
  fs.symlinkSync(outside, path.join(f.repo, '.github'));
  const forge = f.probe('github');
  assert.equal(forge.prTemplate, null);
  assert.deepEqual(forge.prTemplates, []);
  fs.mkdirSync(path.join(f.repo, '.zensu', 'templates'), { recursive: true });
  fs.symlinkSync(path.join(outside, 'pr-body.md'), path.join(f.repo, '.zensu', 'templates', 'pr-body.md'));
  assert.deepEqual(f.probe('github').overrides, []);
  fs.rmSync(path.join(f.repo, '.zensu', 'templates'), { recursive: true });
  fs.symlinkSync(outside, path.join(f.repo, '.zensu', 'templates'));
  assert.deepEqual(f.probe('github').overrides, []);
  fs.rmSync(path.join(f.repo, '.zensu'), { recursive: true });
  fs.mkdirSync(path.join(outside, 'templates'));
  fs.writeFileSync(path.join(outside, 'templates', 'pr-body.md'), 'private\n');
  fs.symlinkSync(outside, path.join(f.repo, '.zensu'));
  assert.deepEqual(f.probe('github').overrides, []);
});

test('a default branch or remote whose name could act as shell syntax or an option reads as unknown, and such a template name is left out of the list', (t) => {
  const f = fixture(t);
  f.write('.gitlab/merge_request_templates/Default.md');
  f.write('.gitlab/merge_request_templates/$(id).md');
  f.write('.github/PULL_REQUEST_TEMPLATE/-option.md');
  f.write('.github/PULL_REQUEST_TEMPLATE/feature.md');
  f.add();
  f.commit('feat: shared');
  f.git('update-ref', 'refs/remotes/origin/main$(id)', 'HEAD');
  f.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main$(id)');
  f.git('checkout', '--quiet', '-b', 'feature');
  f.commit('Local work in progress');
  const unsafe = f.probe('gitlab');
  assert.equal(unsafe.defaultBranch, null);
  assert.equal(unsafe.ref, 'HEAD');
  assert.equal(unsafe.prTemplate, '.gitlab/merge_request_templates/Default.md');
  assert.deepEqual(unsafe.prTemplates, ['.github/PULL_REQUEST_TEMPLATE/feature.md', '.gitlab/merge_request_templates/Default.md']);
  f.git('update-ref', 'refs/remotes/origin/-x', 'HEAD');
  f.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/-x');
  assert.equal(f.probe('gitlab').defaultBranch, null);
  f.git('update-ref', 'refs/remotes/origin/trunk', 'HEAD~1');
  f.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/trunk');
  f.git('config', 'remote.-x.url', 'https://example.test/x.git');
  f.git('config', 'remote.-x.fetch', '+refs/heads/*:refs/remotes/-x/*');
  f.git('config', 'branch.feature.remote', '-x');
  f.git('config', 'branch.feature.merge', 'refs/heads/trunk');
  f.git('update-ref', 'refs/remotes/-x/trunk', 'HEAD~1');
  const remote = f.probe('gitlab');
  assert.equal(remote.ref, 'origin/trunk');
  assert.equal(remote.defaultBranch, 'trunk');
});

test('package.json counts as a commitlint config only while it carries a commitlint key', (t) => {
  const f = fixture(t);
  f.write('package.json', JSON.stringify({ name: 'fixture', commitlint: { extends: ['@commitlint/config-conventional'] } }));
  f.write('.commitlintrc.yml', 'extends: []\n');
  f.add();
  f.commit('chore: start');
  assert.deepEqual(f.probe('github').commitlint, ['.commitlintrc.yml', 'package.json']);
  f.write('package.json', JSON.stringify({ name: 'fixture' }));
  assert.deepEqual(f.probe('github').commitlint, ['.commitlintrc.yml']);
  f.write('package.json', '{ not json');
  assert.deepEqual(f.probe('github').commitlint, ['.commitlintrc.yml']);
  f.write('package.json', '["commitlint"]');
  assert.deepEqual(f.probe('github').commitlint, ['.commitlintrc.yml']);
});

test('the sample holds the 20 newest subjects and rounds the conventional share to two decimals', (t) => {
  const f = fixture(t);
  for (let n = 1; n <= 23; n += 1) f.commit(n % 3 === 0 ? `Plain change ${n}` : `fix(part)!: change ${n}`);
  const found = f.probe('github');
  assert.equal(found.subjects.length, conventions.SUBJECT_LIMIT);
  assert.equal(found.subjects[0], 'fix(part)!: change 23');
  assert.equal(found.subjects[19], 'fix(part)!: change 4');
  assert.equal(found.conventionalShare, 0.7);
});

test('merge commits are not part of the sample', (t) => {
  const f = fixture(t);
  f.commit('chore: root');
  f.git('checkout', '--quiet', '-b', 'side');
  f.commit('fix: on the side');
  f.git('checkout', '--quiet', 'main');
  f.commit('feat: on main');
  f.git('merge', '--quiet', '--no-ff', '-m', 'Merge branch side', 'side');
  assert.deepEqual(f.probe('github').subjects, ['feat: on main', 'fix: on the side', 'chore: root']);
});

test('the Conventional Commits form needs a lowercase type, an optional scope and bang, a colon and a space', () => {
  for (const subject of ['feat: x', 'fix(api): y', 'feat(api)!: z', 'build-ci: w', 'chore!: v']) {
    assert.ok(conventions.CONVENTIONAL_SUBJECT.test(subject), subject);
  }
  for (const subject of ['Feat: x', 'feat:x', 'feat(): y', 'Merge branch main', 'Revert "feat: x"', 'fixup! feat: x', 'WIP']) {
    assert.ok(!conventions.CONVENTIONAL_SUBJECT.test(subject), subject);
  }
});

test('trailers count the sampled commits that carry each key, in any letter case, from the trailer block only', (t) => {
  const f = fixture(t);
  f.commit('feat: one', 'Co-authored-by: A <a@example.test>\nco-authored-by: B <b@example.test>');
  f.commit('feat: two', 'Signed-off-by: C <c@example.test>\nAssisted-by: Tool');
  f.commit('feat: three', 'Signed-off-by: is mentioned here in prose.\n\nThe message goes on after it.');
  f.commit('feat: four');
  assert.deepEqual(f.probe('github').trailers, { 'Co-authored-by': 1, 'Signed-off-by': 1, 'Assisted-by': 1 });
});

test('the history and the default branch come from the remote default branch when the clone knows it', (t) => {
  const f = fixture(t);
  f.commit('feat: shared');
  f.git('update-ref', 'refs/remotes/origin/main', 'HEAD');
  f.git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main');
  f.git('checkout', '--quiet', '-b', 'feature');
  f.commit('Local work in progress');
  const found = f.probe('github');
  assert.equal(found.ref, 'origin/main');
  assert.equal(found.defaultBranch, 'main');
  assert.deepEqual(found.subjects, ['feat: shared']);
});

test('a branch that tracks another remote reads that remote default branch', (t) => {
  const f = fixture(t);
  f.commit('feat: upstream history');
  f.git('config', 'remote.upstream.url', 'https://example.test/upstream.git');
  f.git('config', 'remote.upstream.fetch', '+refs/heads/*:refs/remotes/upstream/*');
  f.git('update-ref', 'refs/remotes/upstream/trunk', 'HEAD');
  f.git('symbolic-ref', 'refs/remotes/upstream/HEAD', 'refs/remotes/upstream/trunk');
  f.git('checkout', '--quiet', '-b', 'feature');
  f.git('config', 'branch.feature.remote', 'upstream');
  f.git('config', 'branch.feature.merge', 'refs/heads/trunk');
  f.commit('Local work in progress');
  const found = f.probe('github');
  assert.equal(found.ref, 'upstream/trunk');
  assert.equal(found.defaultBranch, 'trunk');
  assert.deepEqual(found.subjects, ['feat: upstream history']);
});

test('an empty repository reports no subjects, a null share and zero trailers', (t) => {
  const f = fixture(t);
  const found = f.probe('github');
  assert.deepEqual(found.subjects, []);
  assert.equal(found.conventionalShare, null);
  assert.deepEqual(found.trailers, ZERO_TRAILERS);
  assert.equal(found.ref, 'HEAD');
  assert.equal(found.defaultBranch, null);
});

test('a directory outside every git work tree is an error, not an empty answer', (t) => {
  const outside = tempDir(t);
  const found = conventions.probe({ repo: outside, provider: 'github' });
  assert.match(found.error, /is not inside a git work tree/);
});

test('a subdirectory of the work tree reports paths relative to its top level', (t) => {
  const f = fixture(t);
  f.write('AGENTS.md');
  f.write('src/main.js');
  f.add();
  f.commit('feat: start');
  const found = conventions.probe({ repo: path.join(f.repo, 'src'), provider: 'github', env: f.env });
  assert.deepEqual(found.agents, ['AGENTS.md']);
  assert.deepEqual(found.subjects, ['feat: start']);
});

test('a GIT_DIR in the environment cannot point the probe at another repository', (t) => {
  const a = fixture(t);
  a.write('AGENTS.md');
  a.add();
  a.commit('feat: in repository a');
  const b = fixture(t);
  b.commit('Plain change in repository b');
  const found = conventions.probe({ repo: a.repo, provider: 'github', env: Object.assign({}, a.env, { GIT_DIR: path.join(b.repo, '.git') }) });
  assert.deepEqual(found.subjects, ['feat: in repository a']);
  assert.deepEqual(found.agents, ['AGENTS.md']);
});

test('subjects lose control and line-separator characters and stop at the length bound', (t) => {
  const f = fixture(t);
  f.commit(`fix: tab\there and${String.fromCodePoint(0x2028)}separator`);
  f.commit(`feat: ${'x'.repeat(300)}`);
  const [newest, older] = f.probe('github').subjects;
  assert.equal(newest.length, conventions.SUBJECT_MAX_LENGTH);
  assert.equal(older, 'fix: tab here and separator');
});

test('the CLI prints one JSON line and refuses an unknown argument or provider with exit 2', (t) => {
  const f = fixture(t);
  f.write('AGENTS.md');
  f.add();
  f.commit('feat: start');
  const ok = spawnSync(process.execPath, [MODULE, '--repo', f.repo, '--provider', 'gitlab'], { env: f.env, encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout.trim().split('\n').length, 1);
  assert.equal(JSON.parse(ok.stdout).provider, 'gitlab');
  const configured = spawnSync(process.execPath, [MODULE, '--repo', f.repo, '--template', 'AGENTS.md'], { env: f.env, encoding: 'utf8' });
  assert.equal(configured.status, 0, configured.stderr);
  assert.equal(JSON.parse(configured.stdout).prTemplate, 'AGENTS.md');
  for (const args of [['--provider', 'bitbucket'], ['--bogus'], ['--repo', f.repo, '--repo', f.repo], ['--template', 'AGENTS.md', '--template', 'AGENTS.md']]) {
    const bad = spawnSync(process.execPath, [MODULE, ...args], { env: f.env, encoding: 'utf8' });
    assert.equal(bad.status, 2, args.join(' '));
    assert.match(bad.stderr, /usage: repo-conventions-v1\.js/);
  }
  const outside = spawnSync(process.execPath, [MODULE, '--repo', tempDir(t)], { env: f.env, encoding: 'utf8' });
  assert.equal(outside.status, 1);
  assert.match(outside.stderr, /repo-conventions-v1: .* is not inside a git work tree/);
});
