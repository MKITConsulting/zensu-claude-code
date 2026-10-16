'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const ROOT = path.join(__dirname, '..', '..');
const guard = require(path.join(ROOT, 'hooks', 'lib', 'subagent-shell-guard-v1.js'));
const CONFIG_SH = path.join(ROOT, 'hooks', 'lib', 'zensu-config.sh');

function tempDir(label) {
  const created = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `shell-guard-${label}-`)));
  fs.chmodSync(created, 0o700);
  return created;
}

function layout(projectName = 'project') {
  const base = tempDir('layout');
  const home = path.join(base, 'home');
  const trusted = {
    pluginData: path.join(home, '.claude', 'plugins', 'data', 'zensu-zensu'),
    pluginRoot: path.join(home, '.claude', 'plugins', 'cache', 'zensu', 'zensu', '9.9.9'),
    contextFile: path.join(home, '.claude', 'plugins', 'data', 'zensu-zensu', 'session-control', 'v1', 'records', 'scv1_x.json'),
    projectRoot: path.join(home, 'work', projectName),
    toolCwd: path.join(home, 'work', projectName),
  };
  for (const directory of [trusted.pluginData, trusted.pluginRoot, path.join(trusted.projectRoot, 'src'), path.join(trusted.projectRoot, 'build')]) {
    fs.mkdirSync(directory, { recursive: true });
  }
  return { base, home, trusted, env: { HOME: home, ZENSU_CONFIG: path.join(base, 'absent.json') } };
}

function linkedLayout(target) {
  const base = tempDir('linked');
  const home = path.join(base, 'home');
  const real = target === 'outside' ? path.join(base, 'outside', 'claude') : path.join(home, 'dotfiles', 'claude');
  fs.mkdirSync(path.join(real, 'plugins', 'data', 'zensu-zensu', 'session-control'), { recursive: true });
  fs.mkdirSync(path.join(real, 'plugins', 'cache', 'zensu', 'zensu', '9.9.9'), { recursive: true });
  fs.mkdirSync(path.join(home, 'work', 'project', 'src'), { recursive: true });
  fs.symlinkSync(real, path.join(home, '.claude'), 'dir');
  const trusted = {
    pluginData: path.join(real, 'plugins', 'data', 'zensu-zensu'),
    pluginRoot: path.join(real, 'plugins', 'cache', 'zensu', 'zensu', '9.9.9'),
    contextFile: path.join(real, 'plugins', 'data', 'zensu-zensu', 'session-control', 'v1', 'records', 'scv1_x.json'),
    projectRoot: path.join(home, 'work', 'project'),
    toolCwd: path.join(home, 'work', 'project'),
  };
  return { base, home, trusted, env: { HOME: home, ZENSU_CONFIG: path.join(base, 'absent.json') } };
}

function bash(command, extra = {}) {
  return { tool_name: 'Bash', tool_input: { command, ...extra }, agent_id: 'agent-1', agent_type: 'general-purpose' };
}

function verdict(fixture, command, options = {}) {
  return guard.accidentReason(bash(command), fixture.trusted, fixture.env, options) ? 'deny' : 'allow';
}

function driveRoot(value) {
  try {
    return path.parse(fs.realpathSync.native(value)).root.toLowerCase();
  } catch {
    return null;
  }
}

function rootRemovalReason(projectRoot) {
  return driveRoot('/') === driveRoot(projectRoot) ? guard.REASONS.projectRoot : null;
}

const ALLOWED = [
  'git status --short',
  'npm test',
  'pwd',
  'ls -la src',
  'grep -rn zensu-log.sh hooks/',
  'sed -n 1,20p hooks/lib/zensu-log.sh',
  'rm -rf build dist',
  'rm -f *.log',
  'mv ../x .',
  'git stash list',
  'git stash show -p',
  'git checkout -b feature',
  'git worktree add ../w -b w',
  'ps -o user -p 1',
  'ps -ef',
  'printenv PATH',
  'cat ~/.claude/settings.json',
  'node --test tests/structure/session-control-core-v1.test.js',
  'sh -c true',
  'set -euo pipefail; make',
  'declare -f',
  'cd src && make check',
  'echo done > report.txt',
  'git commit -m "feat(export): add CSV export"',
  'git commit -m "fix(env): load .env.local first"',
  'git commit -m "fix(session): harden zensu-session.sh"',
  "grep -E '^(export|set) ' deploy.sh",
  "cat > Dockerfile <<'EOF'\nFROM node:20\nENV NODE_ENV=production\nEOF",
  "cat <<'EOF'\n$CLAUDE_CODE_SESSION_ID\nEOF",
  "git log --oneline | sed 's/ .*//'",
  "sed 's/.*=//' f",
  "sed -E 's/(.*)\\.ts$/\\1.js/' f",
  "find . -regex '.*\\.py'",
  "npx jest --testPathPattern='.*\\.spec\\.ts'",
  "find . -type f -not -path '*/.*'",
  'rm -rf */node_modules',
  'rm -f */*.log',
  'cd build && rm -rf *',
  'git restore --staged .',
  'git rm -r --cached .',
  'sleep 1 & sleep 2 & wait',
  '(sleep 1 & wait)',
  'mv ../x . > /dev/null',
  'echo "$HOME"',
  'ls -la # rm -rf .zensu/state',
  'ls -la # $(rm -rf .)',
  'cat <<EOF\n\\$ZENSU_X\nEOF',
  "cat <<'EOF'\n$(rm -rf .)\nEOF",
  'cd build || exit 1; rm -rf *',
  'set -e; cd build; rm -rf *',
  'set -euo pipefail\ncd build\nrm -rf *',
  '(cd build && rm -rf *) && ls',
  'for d in a b; do (cd "$d" && make); done',
  'cd packages/a; npm test; cd ../b; npm test; cd ../c; npm test',
  'rm -rf {build,dist}',
  'sort -k1,1 -t, data.csv',
  "find . -name '*.log' -delete",
  'grep -rn "process.env" src',
  'grep -rn "process.env.ZENSU_CONFIG" hooks',
  "rg 'JSON.stringify(process.env)' lib",
  'git commit -m "fix: read os.environ once"',
  "cat > config.js <<'EOF'\nmodule.exports = { env: process.env };\nEOF",
  'python3 -m json.tool <<EOF\n{"a": "process.env"}\nEOF',
  "awk -F, '{print $1}' data.csv",
  "perl -pi -e 's/a/b/' f.txt",
  'jq -r .env.PATH config.json',
  'jq . env/config.json',
  "jq -n 'env.HOME'",
  'git -C src/lib restore ..',
  'cd build && rm -rf "$PWD"/*',
  `bash <<'EOF'\ncd build && rm -rf "$PWD"/*\nEOF`,
  `env -C build bash -c 'rm -rf "$PWD"/*'`,
  `rm -rf ${String.fromCodePoint(2)}`,
  `grep -rn "require('./hooks/lib/claude-hook-session-v1.js')" tests`,
  "git commit -m 'docs: quote `zensu-log.sh` in the guide'",
  'tmux ls',
  'tmux has-session -t dev',
  'tmux capture-pane -p -t dev',
  'tmux kill-session -t run',
  'screen -ls',
  'screen -S dev -X quit',
  'screen -Dm make test',
  "tmux display -p '#S'",
  'tmux ls \\; \\; ls',
  "tmux bind-key x display hi '\\;' new-window",
  'screen -r dev -X quit',
  'screen -S dev -padmin -X quit',
];

const DENIED = [
  ['env', guard.REASONS.dump],
  ['env | sort', guard.REASONS.dump],
  ['printenv', guard.REASONS.dump],
  ['export -p', guard.REASONS.dump],
  ['declare -p', guard.REASONS.dump],
  ['set', guard.REASONS.dump],
  ['compgen -e', guard.REASONS.dump],
  ['cat /proc/self/environ', guard.REASONS.dump],
  ['ps eww', guard.REASONS.dump],
  ['node -e "console.log(process.env)"', guard.REASONS.dump],
  ['python3 -c "import os; print(os.environ)"', guard.REASONS.dump],
  ['printf %s "$CLAUDE_CODE_SESSION_ID"', guard.REASONS.selector],
  ['echo ${CLAUDE_PLUGIN_DATA}', guard.REASONS.selector],
  ['ZENSU_CONFIG=/x bash t.sh', guard.REASONS.selector],
  ['export CLAUDE_PLUGIN_ROOT=/x', guard.REASONS.selector],
  ['unset ZENSU_SESSION_KEY', guard.REASONS.selector],
  ['env -u ZENSU_X make', guard.REASONS.selector],
  ['node -e "process.env.ZENSU_SESSION_KEY"', guard.REASONS.selector],
  ['bash hooks/lib/zensu-log.sh --chain-done', guard.REASONS.helper],
  ['./hooks/lib/zensu-log.sh', guard.REASONS.helper],
  ['source hooks/lib/zensu-session.sh', guard.REASONS.helper],
  ['node hooks/lib/session-control-core-v1.js render-main', guard.REASONS.helper],
  ['node hooks/lib/claude-hook-session-v1.js model-bind', guard.REASONS.helper],
  ['zensu_bind_model_session', guard.REASONS.helper],
  ['sudo bash hooks/lib/zensu-doctor.sh', guard.REASONS.helper],
  ['bash hooks/lib/zensu-session-adopt.sh --confirm', guard.REASONS.helper],
  ['find . -name zensu-log.sh -exec bash {} +', guard.REASONS.helper],
  [`node -e "require('./hooks/lib/claude-hook-session-v1.js')"`, guard.REASONS.helper],
  [`python3 -c "import subprocess; subprocess.run(['bash','hooks/lib/zensu-log.sh','--chain-done'])"`, guard.REASONS.helper],
  [`python3 -c "import subprocess; subprocess.run(['zensu-log.sh', '--chain-done'])"`, guard.REASONS.helper],
  [`node -e 'require("child_process").execSync("bash hooks/lib/zensu-doctor.sh")'`, guard.REASONS.helper],
  [`ruby -e 'system("zensu-log.sh", "--chain-done")'`, guard.REASONS.helper],
  ["node -e 'require(`./hooks/lib/session-control-core-v1.js`)'", guard.REASONS.helper],
  ["perl -e 'print `zensu-log.sh --chain-done`'", guard.REASONS.helper],
  [`node -e "require('./hooks/lib/session-control-core-v1')"`, guard.REASONS.helper],
  ['node hooks/lib/session-control-core-v1 render-main', guard.REASONS.helper],
  ["gh pr comment 12 --body 'Fixed the retry in `zensu-log.sh`.'", guard.REASONS.helper],
  ['ls .zensu/state', guard.REASONS.workflowDirectory],
  ['cat ./.zensu/state/x.json', guard.REASONS.workflowDirectory],
  ['rm -rf .z*', guard.REASONS.workflowDirectory],
  ['ls ~/.zensu', guard.REASONS.workflowDirectory],
  ['ls ~/.claude/plugins/data/zensu-zensu/session-control', guard.REASONS.protectedPath],
  ['cat $HOME/.claude/plugins/cache/zensu/zensu/9.9.9/hooks/hooks.json', guard.REASONS.protectedPath],
  ['rm -rf ~/.claude/plugins/data', guard.REASONS.protectedParent],
  ['rm -rf ~/.claude', guard.REASONS.protectedParent],
  ['rm -rf ~/.claude/plugins/', guard.REASONS.protectedParent],
  ['ls ~/.cl*', guard.REASONS.protectedParent],
  ['git clean -fdx', 'the command runs a git operation that removes or reverts work (git clean)'],
  ['git stash', 'the command runs a git operation that removes or reverts work (git stash)'],
  ['git stash -u', 'the command runs a git operation that removes or reverts work (git stash)'],
  ['git stash pop', 'the command runs a git operation that removes or reverts work (git stash)'],
  ['git reset --hard HEAD', 'the command runs a git operation that removes or reverts work (git reset --hard)'],
  ['git checkout .', 'the command runs a git operation that removes or reverts work (git checkout over the whole tree or with --force)'],
  ['git checkout -f main', 'the command runs a git operation that removes or reverts work (git checkout over the whole tree or with --force)'],
  ['git restore .', 'the command runs a git operation that removes or reverts work (git restore over the whole tree)'],
  ['git worktree remove x', 'the command runs a git operation that removes or reverts work (git worktree remove)'],
  ['git worktree prune', 'the command runs a git operation that removes or reverts work (git worktree prune)'],
  ['git -C sub clean -n', 'the command runs a git operation that removes or reverts work (git clean)'],
  ['nohup git clean -fd', 'the command runs a git operation that removes or reverts work (git clean)'],
  ['timeout 5 git clean -fd', 'the command runs a git operation that removes or reverts work (git clean)'],
  ["eval 'git clean -fdx'", 'the command runs a git operation that removes or reverts work (git clean)'],
  ['bash <<< "git clean -fd"', 'the command runs a git operation that removes or reverts work (git clean)'],
  ['git switch -f main', 'the command runs a git operation that removes or reverts work (git switch --force or --discard-changes)'],
  ['git restore --staged --worktree .', 'the command runs a git operation that removes or reverts work (git restore over the whole tree)'],
  ['env > /tmp/env.txt', guard.REASONS.dump],
  ['env >env.txt', guard.REASONS.dump],
  ['printenv > env.txt', guard.REASONS.dump],
  ['export -p > vars.txt', guard.REASONS.dump],
  ['set > vars.txt', guard.REASONS.dump],
  ['echo "$(printenv)"', guard.REASONS.dump],
  ['node -p process.env', guard.REASONS.dump],
  ['node -p "JSON.stringify(process.env, null, 2)"', guard.REASONS.dump],
  ['python3 -c "import os; print(os.environ.get(\'CLAUDE_CODE_SESSION_ID\'))"', guard.REASONS.selector],
  ['echo $ZENSU_SESSION_KEY', guard.REASONS.selector],
  ["sh -c 'echo $ZENSU_X'", guard.REASONS.selector],
  ['cat <<EOF\n$CLAUDE_CODE_SESSION_ID\nEOF', guard.REASONS.selector],
  ['npm run dev &', guard.REASONS.background],
  ['nohup npm run dev > /tmp/dev.log 2>&1 &', guard.REASONS.background],
  ['setsid npm start', guard.REASONS.background],
  ["tmux new-session -d -s dev 'npm run dev'", guard.REASONS.background],
  ['tmux new -d npm run dev', guard.REASONS.background],
  ['tmux -L work new-s -d make watch', guard.REASONS.background],
  ["tmux new-window -t dev 'npm test'", guard.REASONS.background],
  ["tmux send-keys -t dev 'npm run dev' Enter", guard.REASONS.background],
  ["tmux run-shell -b 'npm run dev'", guard.REASONS.background],
  ["tmux has-session -t dev \\; split-window 'npm test'", guard.REASONS.background],
  ['nohup tmux new -d make watch', guard.REASONS.background],
  ['screen -dmS dev npm run dev', guard.REASONS.background],
  ['screen -S dev -d -m npm start', guard.REASONS.background],
  ["screen -S dev -X stuff 'npm run dev'", guard.REASONS.background],
  ['bash -c "screen -dm npm run dev"', guard.REASONS.background],
  ["tmux neww 'npm run dev'", guard.REASONS.background],
  ["tmux splitw -h 'npm test'", guard.REASONS.background],
  ["tmux respawnp -k 'npm run dev'", guard.REASONS.background],
  ["tmux respawnw -k 'npm run dev'", guard.REASONS.background],
  ["tmux pipep 'cat >> pane.log'", guard.REASONS.background],
  ["tmux respawn-pane -k 'npm run dev'", guard.REASONS.background],
  ["tmux respawn-window -k 'npm run dev'", guard.REASONS.background],
  ["tmux if-shell true 'neww npm run dev'", guard.REASONS.background],
  ["tmux pipe-pane 'cat >> pane.log'", guard.REASONS.background],
  ["tmux set-buffer 'npm run dev' \\; paste-buffer -t dev", guard.REASONS.background],
  ['tmux pasteb -t dev', guard.REASONS.background],
  ["tmux display-popup -E 'npm run dev'", guard.REASONS.background],
  ["tmux popup -E 'npm run dev'", guard.REASONS.background],
  ['tmux -- new -d make watch', guard.REASONS.background],
  ['tmux -Lwork new -d make', guard.REASONS.background],
  ["tmux kill-session -t old \\; 'neww;'", guard.REASONS.background],
  ['screen -S dev -X screen npm run dev', guard.REASONS.background],
  ['screen -S dev -X exec npm run dev', guard.REASONS.background],
  ["screen -S dev -X eval 'stuff make'", guard.REASONS.background],
  ['screen -S dev -X at 0 stuff make', guard.REASONS.background],
  ['screen -S dev -X paste .', guard.REASONS.background],
  ['screen -S dev -X process a', guard.REASONS.background],
  ['screen -S dev -Q stuff make', guard.REASONS.background],
  ['screen -Sdm dev npm run dev', guard.REASONS.background],
  ["screen -x dev -X stuff 'npm run dev'", guard.REASONS.background],
  ["screen -r dev -X stuff 'npm run dev'", guard.REASONS.background],
  ['bash -c "git reset --hard"', 'the command runs a git operation that removes or reverts work (git reset --hard)'],
  ['bash -c "cd $REPO && git reset --hard origin/main"', 'the command runs a git operation that removes or reverts work (git reset --hard)'],
  ['sh -c "git clean -fdx $X"', 'the command runs a git operation that removes or reverts work (git clean)'],
  ['sh -c "npm start > $LOG 2>&1 &"', guard.REASONS.background],
  ['bash -c "cd $X && rm -rf ."', guard.REASONS.projectRoot],
  ['bash -c "rm -rf $PWD"', guard.REASONS.projectRoot],
  ['eval "cd $X && rm -rf ."', guard.REASONS.projectRoot],
  ['git checkout -- "$(git rev-parse --show-toplevel)"', 'the command runs a git operation that removes or reverts work (git checkout over the whole tree or with --force)'],
  ['cd src && git checkout -- ..', 'the command runs a git operation that removes or reverts work (git checkout over the whole tree or with --force)'],
  ['git -C src restore ..', 'the command runs a git operation that removes or reverts work (git restore over the whole tree)'],
  ['git -C .. restore project', 'the command runs a git operation that removes or reverts work (git restore over the whole tree)'],
  ['bash -c "cd \\"$X\\" && rm -rf ."', guard.REASONS.projectRoot],
  ['eval "cd \\"$X\\" && rm -rf ."', guard.REASONS.projectRoot],
  ['bash -c "cd build && rm -rf $(pwd)/*"', guard.REASONS.projectRoot],
  ['eval "cd build && rm -rf $PWD"', guard.REASONS.projectRoot],
  ['bash <<EOF\ncd build && rm -rf $PWD\nEOF', guard.REASONS.projectRoot],
  ['env -C build rm -rf "$PWD"', guard.REASONS.projectRoot],
  ['git -C src restore -- "$PWD"/*', 'the command runs a git operation that removes or reverts work (git restore over the whole tree)'],
  ['echo "${X:-$(rm -rf .)}"', guard.REASONS.projectRoot],
  ['echo $(( $(git clean -fdx) + 1 ))', 'the command runs a git operation that removes or reverts work (git clean)'],
  ['env -C build bash <<< "rm -rf $PWD"', guard.REASONS.projectRoot],
  ['env -C build bash <<EOF\nrm -rf $PWD\nEOF', guard.REASONS.projectRoot],
  ['sudo -D build sh <<< "rm -rf $(pwd)"', guard.REASONS.projectRoot],
  ['bash <<EOF\ncd build && rm -rf ${PWD:?}\nEOF', guard.REASONS.projectRoot],
  ['cd build; rm -rf "${PWD:?}"/*', guard.REASONS.projectRoot],
  ['rm -rf "${PWD:-.}"', guard.REASONS.projectRoot],
  ['rm -rf ${HOME:?}/.claude/plugins/data', guard.REASONS.protectedParent],
  ['echo ${X:-"it\'s $(git clean -fdx)"}', 'the command runs a git operation that removes or reverts work (git clean)'],
  ["echo ${X:-$'it\\'s' $(git clean -fdx)}", 'the command runs a git operation that removes or reverts work (git clean)'],
  [`rm -rf ~/.claude/plugins/{data,${String.fromCodePoint(1)}}`, guard.REASONS.protectedParent],
  ['claude plugin update zensu', guard.REASONS.plugin],
  ['claude plugins list', guard.REASONS.plugin],
  ['rm -rf .', guard.REASONS.projectRoot],
  ['rm -rf ..', guard.REASONS.projectRoot],
  ['rm -rf *', guard.REASONS.projectRoot],
  ['rm -rf $(pwd)', guard.REASONS.projectRoot],
  ['rm -rf "$PWD"', guard.REASONS.projectRoot],
  ['rm -rf ~', guard.REASONS.projectRoot],
  ['mv . ../elsewhere', guard.REASONS.projectRoot],
  ['rmdir ../project', guard.REASONS.projectRoot],
  ['rm -rf "$(git rev-parse --show-toplevel)"', guard.REASONS.projectRoot],
  ['rm -rf */', guard.REASONS.projectRoot],
  ['rm -rf ~/*/project', guard.REASONS.projectRoot],
  ['cd .. && rm -rf project', guard.REASONS.projectRoot],
  ['cd ~/work && rm -rf project', guard.REASONS.projectRoot],
  ['(cd build) && rm -rf ../project', guard.REASONS.projectRoot],
  ["bash <<'EOF'\nrm -rf .\nEOF", guard.REASONS.projectRoot],
  ['find . -mindepth 1 -delete', guard.REASONS.projectRoot],
  ['find . -maxdepth 1 -exec rm -rf {} +', guard.REASONS.projectRoot],
  ["find . -name '*' -delete", guard.REASONS.projectRoot],
  ['find . ! -name keep.txt -delete', guard.REASONS.projectRoot],
  ["find . -regex '.*' -delete", guard.REASONS.projectRoot],
  ['env --unset=ZENSU_X make', guard.REASONS.selector],
  ['env -iu ZENSU_X make', guard.REASONS.selector],
  ['sudo ZENSU_X=1 make', guard.REASONS.selector],
  ['bash <<EOF\necho \\$ZENSU_X\nEOF', guard.REASONS.selector],
  ['[[ -v ZENSU_SESSION_KEY ]] && echo set', guard.REASONS.selector],
  ['pushd src && popd && rm -rf .', guard.REASONS.projectRoot],
  ['cd src && cd - && rm -rf .', guard.REASONS.projectRoot],
  ['false && cd build; rm -rf .', guard.REASONS.projectRoot],
  ['cd build; rm -rf *', guard.REASONS.projectRoot],
  ['cd build && make || echo failed; rm -rf *', guard.REASONS.projectRoot],
  ['if [ -d build ]; then cd build; fi; rm -rf *', guard.REASONS.projectRoot],
  ['(cd build) ; rm -rf *', guard.REASONS.projectRoot],
  ['cd "$X" && rm -rf *', guard.REASONS.projectRoot],
  ['command cd .. && rm -rf project', guard.REASONS.projectRoot],
  ['env -C .. rm -rf project', guard.REASONS.projectRoot],
  ['env --chdir=.. rm -rf project', guard.REASONS.projectRoot],
  ['sudo -D .. rm -rf project', guard.REASONS.projectRoot],
  ['cd src && rm -rf "$(git rev-parse --show-toplevel)"', guard.REASONS.projectRoot],
  ['rm -rf {.,build}', guard.REASONS.projectRoot],
  ['ls ~/.claude/plugins/{data,cache}/zensu-zensu', guard.REASONS.protectedPath],
  ['cat <<EOF\n$(rm -rf .)\nEOF', guard.REASONS.projectRoot],
  ['coproc npm run dev', guard.REASONS.background],
  ['npm run build & wait; npm run dev &', guard.REASONS.background],
  ['(npm run dev &)', guard.REASONS.background],
  ['jq -n env', guard.REASONS.dump],
  ["jq -n '$ENV'", guard.REASONS.dump],
  ["jq -n 'env.ZENSU_SESSION_KEY'", guard.REASONS.selector],
  ["node <<'EOF'\nconsole.log(process.env)\nEOF", guard.REASONS.dump],
  ['node --eval="console.log(process.env)"', guard.REASONS.dump],
  ["python3 - <<'EOF'\nimport os\nprint(os.environ['ZENSU_SESSION_KEY'])\nEOF", guard.REASONS.selector],
  ["awk 'BEGIN { for (k in ENVIRON) print k }'", guard.REASONS.dump],
  ["awk 'BEGIN { print ENVIRON[\"ZENSU_X\"] }'", guard.REASONS.selector],
  ["ruby -e 'p ENV'", guard.REASONS.dump],
  ["perl -e 'print %ENV'", guard.REASONS.dump],
  ["perl -le 'print $ENV{ZENSU_X}'", guard.REASONS.selector],
  ["pwsh -c 'Get-ChildItem env:'", guard.REASONS.dump],
  ["deno eval 'console.log(Deno.env.toObject())'", guard.REASONS.dump],
  ["php -r 'print_r(getenv());'", guard.REASONS.dump],
];

test('ordinary commands pass the accident guard', () => {
  const fixture = layout();
  for (const command of ALLOWED) {
    assert.equal(guard.accidentReason(bash(command), fixture.trusted, fixture.env), null, command);
  }
});

test('every listed form is denied with its rule', () => {
  const fixture = layout();
  for (const [command, reason] of DENIED) {
    assert.equal(guard.accidentReason(bash(command), fixture.trusted, fixture.env), reason, command);
  }
});

test('a directory outside the project may be emptied after a cd that must succeed', () => {
  const fixture = layout();
  const elsewhere = path.join(fixture.base, 'elsewhere');
  fs.mkdirSync(elsewhere);
  assert.equal(verdict(fixture, `cd "${elsewhere}" && rm -rf *`), 'allow');
  assert.equal(guard.accidentReason(bash(`cd "${elsewhere}"; rm -rf *`), fixture.trusted, fixture.env), guard.REASONS.projectRoot);
});

test('the working directory model is bounded', () => {
  const fixture = layout();
  const scattered = `${Array.from({ length: 8 }, (_, index) => `cd d${index}`).join('; ')}; ls`;
  assert.equal(guard.accidentReason(bash(scattered), fixture.trusted, fixture.env), guard.REASONS.directories);
  const chained = `${Array.from({ length: 40 }, (_, index) => `cd d${index} && make`).join(' && ')}`;
  assert.equal(guard.accidentReason(bash(chained), fixture.trusted, fixture.env), null);
});

test('absolute spellings of the project root and its parents are denied', () => {
  const fixture = layout();
  const { projectRoot } = fixture.trusted;
  const parent = path.dirname(projectRoot);
  for (const command of [`rm -rf ${projectRoot}`, `rm -rf ${parent}`, `rm -rf ${parent}/*`, `rm -rf ${parent}/proj*`]) {
    assert.equal(guard.accidentReason(bash(command), fixture.trusted, fixture.env), guard.REASONS.projectRoot, command);
  }
  assert.equal(verdict(fixture, `rm -rf ${projectRoot}/src/*`), 'allow');
  assert.equal(guard.accidentReason(bash('rm -rf /'), fixture.trusted, fixture.env), rootRemovalReason(projectRoot));
  assert.equal(verdict(fixture, `ls ${fixture.trusted.pluginData}`), 'deny');
  const git = (operation) => `the command runs a git operation that removes or reverts work (${operation})`;
  assert.equal(guard.accidentReason(bash(`git restore ${projectRoot}`), fixture.trusted, fixture.env), git('git restore over the whole tree'));
  assert.equal(guard.accidentReason(bash(`git checkout -- ${projectRoot}/`), fixture.trusted, fixture.env), git('git checkout over the whole tree or with --force'));
  assert.equal(guard.accidentReason(bash(`git rm -r ${projectRoot}`), fixture.trusted, fixture.env), git('git rm over the whole tree'));
  assert.equal(verdict(fixture, `git restore --staged ${projectRoot}`), 'allow');
  assert.equal(verdict(fixture, `git rm -r --cached ${projectRoot}`), 'allow');
  assert.equal(verdict(fixture, `git checkout -- ${projectRoot}/src`), 'allow');
});

test('the project overlay under HOME leaves globs that cannot reach protected state alone', () => {
  const fixture = layout();
  const env = { ...fixture.env, CLAUDE_PROJECT_DIR: fixture.trusted.projectRoot };
  for (const command of [...ALLOWED, 'ls *.md', 'cat */package.json', 'du -sh *', 'for f in *.json; do wc -l "$f"; done']) {
    assert.equal(guard.accidentReason(bash(command), fixture.trusted, env), null, command);
  }
  for (const [command, reason] of DENIED) {
    assert.equal(guard.accidentReason(bash(command), fixture.trusted, env), reason, command);
  }
  assert.equal(guard.accidentReason(bash('rm -rf /'), fixture.trusted, env), rootRemovalReason(fixture.trusted.projectRoot));
  assert.equal(guard.accidentReason(bash('cat .zens*/config.json'), fixture.trusted, env), guard.REASONS.protectedPath);
  assert.equal(guard.accidentReason(bash('rm -rf ~/.claude/plug*'), fixture.trusted, env), guard.REASONS.protectedParent);
  assert.equal(guard.accidentReason(bash('ls ~/.claude/plugins/*/zensu-zensu'), fixture.trusted, env), guard.REASONS.protectedPath);
  assert.equal(guard.accidentReason(bash('ls ~/.claude/plugins/data/zen*/session-control'), fixture.trusted, env), guard.REASONS.protectedPath);
});

test('background shells and a disabled sandbox are denied', () => {
  const fixture = layout();
  assert.equal(
    guard.accidentReason(bash('sleep 1', { run_in_background: true }), fixture.trusted, fixture.env),
    guard.REASONS.background,
  );
  assert.equal(
    guard.accidentReason(bash('ls', { dangerouslyDisableSandbox: true }), fixture.trusted, fixture.env),
    guard.REASONS.sandbox,
  );
  assert.equal(guard.accidentReason(bash('sleep 1', { run_in_background: false }), fixture.trusted, fixture.env), null);
});

test('a quoted path with spaces stays one word', () => {
  const fixture = layout('Client Work');
  const root = fixture.trusted.projectRoot;
  assert.equal(guard.accidentReason(bash(`rm -rf "${root}"`), fixture.trusted, fixture.env), guard.REASONS.projectRoot);
  assert.equal(
    guard.accidentReason(bash(`git -C "${root}" clean -fdx`), fixture.trusted, fixture.env),
    'the command runs a git operation that removes or reverts work (git clean)',
  );
  assert.equal(guard.accidentReason(bash(`rm -rf "${root}/build"`), fixture.trusted, fixture.env), null);
});

test('a symlinked ~/.claude is judged by both spellings', { skip: process.platform === 'win32' }, () => {
  for (const target of ['dotfiles', 'outside']) {
    const fixture = linkedLayout(target);
    const reason = (command) => guard.accidentReason(bash(command), fixture.trusted, fixture.env);
    assert.equal(reason('ls ~/.claude/plugins/data/zensu-zensu/session-control'), guard.REASONS.protectedPath, target);
    assert.equal(reason('rm -rf ~/.claude/plugins'), guard.REASONS.protectedParent, target);
    assert.equal(reason('rm -rf ~/.claude'), guard.REASONS.protectedParent, target);
    assert.equal(reason('cat ~/.claude/settings.json'), null, target);
    const declared = { ...fixture.env, CLAUDE_PLUGIN_DATA: path.join(fixture.home, '.claude', 'plugins', 'data', 'zensu-zensu') };
    const viaDeclared = guard.accidentReason(bash('ls ~/.claude/plugins/data/zensu-zensu'), fixture.trusted, declared);
    assert.equal(viaDeclared, guard.REASONS.protectedPath, target);
  }
});

test('the parser keeps quoted text whole and separates redirections and heredocs', () => {
  const parsed = guard.parseScript("git commit -m 'a; b' > out.txt 2>&1 && cat <<'EOF'\nrm -rf .\nEOF", { platform: 'linux' });
  const commands = parsed.items.filter((item) => item.kind === 'command');
  assert.deepEqual(commands[0].words.map((word) => word.value), ['git', 'commit', '-m', 'a; b']);
  assert.deepEqual(commands[0].redirects.map((redirect) => [redirect.op, redirect.word.value]), [['>', 'out.txt']]);
  assert.deepEqual(commands[1].words.map((word) => word.value), ['cat']);
  assert.equal(commands[1].heredocs[0].body, 'rm -rf .');
  assert.equal(commands.length, 2);
});

test('the parser reports comments, keeps heredoc escapes and expands braces', () => {
  const text = 'ls # .zensu\necho a#b';
  const parsed = guard.parseScript(text, { platform: 'linux' });
  assert.deepEqual(parsed.comments.map(([start, end]) => text.slice(start, end)), ['# .zensu']);
  assert.deepEqual(parsed.items.map((item) => item.words.map((word) => word.value)), [['ls'], ['echo', 'a#b']]);
  const heredoc = guard.parseScript('cat <<EOF\n\\$A "$B" \\\\$C\nEOF', { platform: 'linux' });
  assert.deepEqual(heredoc.expansions, ['B', 'C']);
  const braces = guard.parseScript("rm -rf {a,b{c,d}} '{x,y}' {z}", { platform: 'linux', home: '/h' });
  assert.deepEqual(braces.items[0].words.map((word) => word.value), ['rm', '-rf', 'a', 'bc', 'bd', '{x,y}', '{z}']);
  const tilde = guard.parseScript('A={a,b} ls {~,x}/.claude B={c,d}', { platform: 'linux', home: '/h' });
  assert.deepEqual(tilde.items[0].words.map((word) => word.value), ['A={a,b}', 'ls', '/h/.claude', 'x/.claude', 'B=c', 'B=d']);
});

test('a ZENSU_CONFIG beside the project protects only its own file', () => {
  const fixture = layout();
  const env = { ...fixture.env, ZENSU_CONFIG: path.join(fixture.home, 'work', 'zensu.json') };
  const reason = (command) => guard.accidentReason(bash(command), fixture.trusted, env);
  assert.equal(reason('ls ..'), null);
  assert.equal(reason('cd .. && rm -rf project'), guard.REASONS.projectRoot);
  assert.equal(reason('cat ../zensu.json'), guard.REASONS.protectedPath);
  assert.equal(reason('ls ../*.md'), null);
  assert.equal(reason('cat ../*'), guard.REASONS.protectedPath);
  assert.equal(reason('cat */../../zen*'), guard.REASONS.protectedPath);
});

test('the command walker finds every simple command the shell would run', () => {
  const zensu = (command) => guard.commandInvocations(command, { platform: 'linux' })
    .filter((invocation) => invocation.name === 'zensu')
    .map((invocation) => invocation.words.join(' '));
  for (const command of [
    'zensu security classify f1',
    'timeout 60 zensu security classify f1',
    'nice -n 5 zensu security classify f1',
    'env -i zensu security classify f1',
    'sudo -u ci zensu security classify f1',
    "printf 'f1\\n' | xargs -n1 zensu security classify f1",
    'for id in f1; do zensu security classify f1; done',
    'if true; then zensu security classify f1; fi',
    'bash -c "zensu security classify f1"',
    "sh -lc 'zensu security classify f1'",
    'eval "zensu security classify f1"',
    'bash <<EOF\nzensu security classify f1\nEOF',
    'bash <<< "zensu security classify f1"',
    'x=$(zensu security classify f1)',
    'echo `zensu security classify f1`',
    'X=${X:-$(zensu security classify f1)}',
    'echo "${X:-`zensu security classify f1`}"',
    'echo $(( $(zensu security classify f1) + 1 ))',
    'echo ${X:-"it\'s $(zensu security classify f1)"}',
    '"zensu" security classify f1',
    '\\zensu security classify f1',
    '/opt/bin/zensu security classify f1',
  ]) {
    assert.deepEqual(zensu(command), ['security classify f1'], command);
  }
  for (const command of [
    'grep -rn "zensu security classify" skills',
    'echo use zensu security classify please',
    "cat <<'EOF'\nzensu security classify f1\nEOF",
    'git commit -m "docs: run zensu security classify; then review"',
    'bash hooks/lib/zensu-log.sh --workflow-begin',
  ]) {
    assert.deepEqual(zensu(command), [], command);
  }
  const [prefixed] = guard.commandInvocations('ZENSU_MCP_GATE=off env ZENSU_API_URL=http://localhost:8090 timeout 9 zensu features get f1', { platform: 'linux' });
  assert.equal(prefixed.name, 'zensu');
  assert.deepEqual(prefixed.environment, { ZENSU_MCP_GATE: 'off', ZENSU_API_URL: 'http://localhost:8090' });
  assert.deepEqual(prefixed.words, ['features', 'get', 'f1']);
  assert.deepEqual(zensu('ZENSU_MCP_GATE=off bash -c "zensu security classify f1"'), ['security classify f1']);
  assert.equal(
    guard.commandInvocations('ZENSU_MCP_GATE=off bash -c "zensu security classify f1"', { platform: 'linux' })
      .find((invocation) => invocation.name === 'zensu').environment.ZENSU_MCP_GATE,
    'off',
  );
});

test('a symlinked config layer protects its target', { skip: process.platform === 'win32' }, () => {
  const fixture = layout();
  const target = path.join(fixture.base, 'dotfiles', 'zensu.json');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, '{}');
  fs.mkdirSync(path.join(fixture.home, '.zensu'), { recursive: true });
  fs.symlinkSync(target, path.join(fixture.home, '.zensu', 'config.json'));
  assert.equal(guard.accidentReason(bash(`echo '{}' > ${target}`), fixture.trusted, fixture.env), guard.REASONS.protectedPath);
  assert.equal(guard.accidentReason(bash(`ls ${path.dirname(target)}`), fixture.trusted, fixture.env), null);
});

test('the grant refusal names every way a config layer withdraws the shell', () => {
  const refusal = guard.grantRefusal({ agent_id: 'a', agent_type: 'general-purpose' }, {});
  assert.equal(
    refusal,
    'hooks.subagentShell withdraws the subagent shell (false in a config layer, a config layer that could not be read or resolved, or no config layer to consult)',
  );
});

test('every string field is scanned, not only the command', () => {
  const fixture = layout();
  assert.equal(
    guard.accidentReason(bash('pwd', { description: 'inspect .zensu/state' }), fixture.trusted, fixture.env),
    guard.REASONS.workflowDirectory,
  );
  assert.equal(
    guard.accidentReason(bash('pwd', { note: ['ok', { path: '.zensu/logs/x.log' }] }), fixture.trusted, fixture.env),
    guard.REASONS.workflowDirectory,
  );
});

test('only Bash is a shell call; Monitor and the other command names stay with the allowlist', () => {
  assert.equal(guard.isShellCall({ tool_name: 'Bash', tool_input: {} }), true);
  for (const name of ['Monitor', 'shell', 'exec', 'exec_command', 'terminal', 'command', 'bash', 'BASH']) {
    assert.equal(guard.isShellCall({ tool_name: name, tool_input: { command: 'x' } }), false, name);
  }
});

test('the grant refuses unnamed children, read-only identities and personas', () => {
  const fixture = layout();
  const refuse = (payload) => guard.grantRefusal(payload, fixture.env);
  assert.match(refuse({ agent_id: 'a' }), /no usable agent_type/);
  assert.match(refuse({ agent_id: 'a', agent_type: ' ' }), /no usable agent_type/);
  assert.match(refuse({ agent_id: 'a', agent_type: 'x'.repeat(513) }), /no usable agent_type/);
  assert.match(refuse({ agent_id: 'x'.repeat(600), agent_type: 'general-purpose' }), /unusable agent_id/);
  for (const type of ['zensu:review-aspect', 'review-judge', 'zensu:zensu-plm', 'zensu:pr-review-worker']) {
    assert.match(refuse({ agent_id: 'a', agent_type: type }), /read-only Zensu agent/, type);
  }
  assert.match(refuse({ agent_id: 'a', agent_type: 'zensu-review-domain' }), /zensu-review-\* persona/);
  assert.match(refuse({ agent_id: 'a', agent_type: 'acme:zensu-review-security' }), /zensu-review-\* persona/);
  assert.equal(refuse({ agent_id: 'a', agent_type: 'workflow-subagent' }), null);
  assert.equal(refuse({ agent_type: 'Explore' }), null);
});

test('the shell violation carries the guard tail and separates grant from guard', () => {
  const fixture = layout();
  const grant = guard.shellViolation({ ...bash('pwd'), agent_type: undefined }, fixture.trusted, fixture.env);
  assert.equal(grant.kind, 'grant');
  assert.equal(grant.reason, 'the subagent reports no usable agent_type, so the shell grant cannot tell it from a read-only reviewer.');
  assert.equal(grant.reason.includes(guard.GRANT_TAIL), false);
  const accident = guard.shellViolation(bash('git clean -fdx'), fixture.trusted, fixture.env);
  assert.equal(accident.kind, 'guard');
  assert.equal(
    accident.reason,
    `host-profile-v1 shell guard: the command runs a git operation that removes or reverts work (git clean). ${guard.GUARD_TAIL}`,
  );
  assert.equal(guard.shellViolation(bash('pwd'), fixture.trusted, fixture.env), null);
});

function shellStrict(env) {
  const result = spawnSync('bash', ['-c', 'source "$1"; if zensu_hook_enabled_strict subagentShell; then printf 1; else printf 0; fi', 'zensu-config', CONFIG_SH], {
    env: { PATH: process.env.PATH, ...env },
    encoding: 'utf8',
  });
  return result.stdout;
}

test('the strict flag reader agrees with zensu_hook_enabled_strict', () => {
  const base = tempDir('strict');
  const home = path.join(base, 'home');
  const project = path.join(base, 'project');
  fs.mkdirSync(path.join(home, '.zensu'), { recursive: true });
  fs.mkdirSync(path.join(project, '.zensu'), { recursive: true });
  const globalFile = path.join(home, '.zensu', 'config.json');
  const projectFile = path.join(project, '.zensu', 'config.json');
  const scenarios = [
    ['no config files', {}, {}],
    ['global true', { global: '{"hooks":{"subagentShell":true}}' }, {}],
    ['global false', { global: '{"hooks":{"subagentShell":false}}' }, {}],
    ['project false under a global true', { global: '{"hooks":{"subagentShell":true}}', project: '{"hooks":{"subagentShell":false}}' }, {}],
    ['malformed global', { global: '{"hooks":' }, {}],
    ['hooks null', { global: '{"hooks":null}' }, {}],
    ['top-level array', { global: '[]' }, {}],
    ['hooks without the key', { global: '{"hooks":{"other":false}}' }, {}],
    ['no hooks object', { global: '{"x":1}' }, {}],
    ['explicit file says false', { explicit: '{"hooks":{"subagentShell":false}}' }, {}],
    ['explicit file is absent', { explicitAbsent: true }, {}],
    ['no candidate at all', {}, { noHome: true, posixOnly: true }],
    ['directory at the config path', { directory: true }, {}],
    ['explicit path with a line break', { explicitBroken: true }, {}],
  ];
  for (const [label, files, flags] of scenarios) {
    if (flags.posixOnly && process.platform === 'win32') continue;
    for (const file of [globalFile, projectFile]) fs.rmSync(file, { recursive: true, force: true });
    if (files.global) fs.writeFileSync(globalFile, files.global);
    if (files.project) fs.writeFileSync(projectFile, files.project);
    if (files.directory) fs.mkdirSync(globalFile);
    const env = {};
    if (!flags.noHome) {
      env.HOME = home;
      env.CLAUDE_PROJECT_DIR = project;
    }
    if (files.explicit) {
      const explicit = path.join(base, 'explicit.json');
      fs.writeFileSync(explicit, files.explicit);
      env.ZENSU_CONFIG = explicit;
    }
    if (files.explicitAbsent) env.ZENSU_CONFIG = path.join(base, 'missing.json');
    if (files.explicitBroken) env.ZENSU_CONFIG = `${path.join(base, 'broken')}\n.json`;
    const js = guard.strictFlagEnabled(guard.CONFIG_KEY, env) ? '1' : '0';
    assert.equal(js, shellStrict(env), label);
  }
});

test('a relative explicit config path withdraws the grant', () => {
  assert.equal(guard.strictFlagEnabled(guard.CONFIG_KEY, { ZENSU_CONFIG: 'zensu-team.json', HOME: '/h' }), false);
  assert.equal(guard.strictFlagEnabled(guard.CONFIG_KEY, { ZENSU_CONFIG: 'C:/cfg.json' }, { platform: 'linux' }), false);
});

test('the config authorities name every layer, a superset of the strict candidates', () => {
  const env = { HOME: '/h', ZENSU_CONFIG: '/x/c.json', CLAUDE_PROJECT_DIR: '/p' };
  assert.deepEqual(
    guard.configAuthorities(env),
    ['/h/.zensu', '/h/.zensu/config.json', '/x/c.json', '/p/.zensu', '/p/.zensu/config.json'],
  );
  assert.deepEqual(guard.configAuthorities({}), []);
  for (const layers of [env, { HOME: '/h', CLAUDE_PROJECT_DIR: '/p' }]) {
    for (const candidate of guard.strictCandidates(layers, 'linux')) {
      assert.ok(guard.configAuthorities(layers).includes(candidate), candidate);
    }
  }
});

test('the strict candidates mirror the shell reader', () => {
  assert.deepEqual(guard.strictCandidates({ ZENSU_CONFIG: '/x/c.json', HOME: '/h' }, 'linux'), ['/x/c.json']);
  assert.deepEqual(guard.strictCandidates({ HOME: '/h', CLAUDE_PROJECT_DIR: '/p' }, 'linux'), ['/h/.zensu/config.json', '/p/.zensu/config.json']);
  assert.deepEqual(guard.strictCandidates({ HOME: '' }), []);
  assert.deepEqual(guard.strictCandidates({ HOME: '/c/Users/dev' }, 'win32'), ['C:/Users/dev/.zensu/config.json']);
});

test('Windows spellings reach the same rules', () => {
  const noFs = { realpathSync: { native() { throw new Error('no filesystem in this test'); } } };
  const trusted = {
    pluginData: 'C:\\Users\\dev\\.claude\\plugins\\data\\zensu-zensu',
    pluginRoot: 'C:\\Users\\dev\\.claude\\plugins\\cache\\zensu\\zensu\\9.9.9',
    contextFile: 'C:\\Users\\dev\\.claude\\plugins\\data\\zensu-zensu\\session-control\\v1\\records\\scv1_x.json',
    projectRoot: 'C:\\Users\\dev\\work\\project',
    toolCwd: 'C:\\Users\\dev\\work\\project',
  };
  const env = { HOME: '/c/Users/dev' };
  const reason = (command) => guard.accidentReason(bash(command), trusted, env, { platform: 'win32', fs: noFs });
  assert.equal(reason('ls /c/Users/dev/.claude/plugins/data/zensu-zensu'), guard.REASONS.protectedPath);
  assert.equal(reason('dir C:\\Users\\dev\\.claude\\plugins\\data\\zensu-zensu'), guard.REASONS.protectedPath);
  assert.equal(reason('ls ~/.claude/plugins/data/zensu-zensu'), guard.REASONS.protectedPath);
  assert.equal(reason('ls ~/.CLAUDE/Plugins/data/zensu-zensu'), guard.REASONS.protectedPath);
  assert.equal(reason('rm -rf ~/.claude/plugins'), guard.REASONS.protectedParent);
  assert.equal(reason('rm -rf /c/Users/dev/work/project'), guard.REASONS.projectRoot);
  assert.equal(reason('rm -rf C:\\Users\\dev\\work'), guard.REASONS.projectRoot);
  assert.equal(reason('type .ZENSU\\state\\x.json'), guard.REASONS.workflowDirectory);
  assert.equal(reason('git.exe clean -fd'), 'the command runs a git operation that removes or reverts work (git clean)');
  assert.equal(reason('ls src'), null);
  const rootOn = (drive) => ({
    realpathSync: {
      native(value) {
        if (value === '/') return `${drive}:\\`;
        throw new Error('no filesystem in this test');
      },
    },
  });
  const rootRemoval = (drive) => guard.accidentReason(bash('rm -rf /'), trusted, env, { platform: 'win32', fs: rootOn(drive) });
  assert.equal(rootRemoval('C'), guard.REASONS.projectRoot);
  assert.equal(rootRemoval('D'), null);
  const spaced = {
    pluginData: 'C:\\Users\\John Doe\\.claude\\plugins\\data\\zensu-zensu',
    pluginRoot: 'C:\\Users\\John Doe\\.claude\\plugins\\cache\\zensu\\zensu\\9.9.9',
    contextFile: 'C:\\Users\\John Doe\\.claude\\plugins\\data\\zensu-zensu\\session-control\\v1\\records\\scv1_x.json',
    projectRoot: 'C:\\Users\\John Doe\\work\\project',
    toolCwd: 'C:\\Users\\John Doe\\work\\project',
  };
  const spacedReason = (command) => guard.accidentReason(bash(command), spaced, { HOME: 'C:\\Users\\John Doe' }, { platform: 'win32', fs: noFs });
  assert.equal(spacedReason('rm -rf ~/.claude/plugins'), guard.REASONS.protectedParent);
  assert.equal(spacedReason('rm -rf "C:\\Users\\John Doe\\work\\project"'), guard.REASONS.projectRoot);
  assert.equal(spacedReason('rm -rf build'), null);
});

test('case folding follows the platform filesystem', () => {
  const fixture = layout();
  assert.equal(verdict(fixture, 'ls .ZENSU/state', { platform: 'darwin' }), 'deny');
  assert.equal(verdict(fixture, 'ls .ZENSU/state', { platform: 'linux' }), 'allow');
});
