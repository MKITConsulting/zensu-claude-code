'use strict';

const path = require('path');
const { spawnSync } = require('child_process');
const { commands } = require('../lib-skill-free-text.js');
const { REQUIRED } = require('../../../hooks/lib/ai-work-preflight-v1.js');

function run(binary, args) {
  const result = spawnSync(binary, args, {
    encoding: 'utf8',
    env: Object.assign({}, process.env, { ZENSU_NO_UPDATE_CHECK: '1' }),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${binary} ${args.join(' ')} exited ${result.status}: ${result.stderr}`);
  return result.stdout;
}

function main(argv) {
  const [source, binary = 'zensu'] = argv;
  if (!source) {
    console.error('usage: record-zensu-cli-floor-help.js "<archive> of the zensu-cli v<floor> release, sha256 <digest>" [<zensu binary>] > tests/structure/fixtures/zensu-cli-<floor>-floor-help.json');
    return 2;
  }
  const root = path.resolve(__dirname, '..', '..', '..');
  const recorded = {
    version: run(binary, ['--version']).split('\n')[0],
    source,
    help: Object.fromEntries(Object.keys(REQUIRED).map((sub) => [sub, run(binary, ['ai-work', sub, '--help'])])),
    commands: Object.fromEntries(commands(root).map((command) => [command, run(binary, [...command.split(' '), '--help'])])),
  };
  process.stdout.write(`${JSON.stringify(recorded, null, 2)}\n`);
  return 0;
}

process.exitCode = main(process.argv.slice(2));
