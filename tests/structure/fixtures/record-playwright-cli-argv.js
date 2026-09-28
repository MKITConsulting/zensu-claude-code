'use strict';

const fs = require('node:fs');
const path = require('node:path');

const CASES = [
  ['-s=zensu-verify-a', 'goto', 'http://127.0.0.1:1/'],
  ['-s', 'zensu-verify-a', 'list'],
  ['--session', 'zensu-verify-a', 'snapshot'],
  ['--session=zensu-verify-a'],
  ['--s=zensu-verify-a', 'snapshot'],
  ['-s', 'a', '-s', 'b', 'snapshot'],
  ['--session', 'a', '--session', 'b'],
  ['-s=', 'snapshot'],
  ['-s5', 'snapshot'],
  ['-sfoo', 'snapshot'],
  ['-s', '--json', 'snapshot'],
  ['-s_x', 'snapshot'],
  ['-abc', 'x'],
  ['-g'],
  ['-g', 'install'],
  ['-h'],
  ['-v'],
  ['--version'],
  ['--help', 'open'],
  ['--json', 'snapshot'],
  ['--raw', 'eval', '1'],
  ['open', '--config=/a.json', '--config=/b.json'],
  ['open', '--config', '--headed'],
  ['open', '--config', '/a.json', 'http://127.0.0.1:1/'],
  ['--filter', 'x', '--filter', 'y', '--filter', 'z'],
  ['open', '--headed', '--headed', 'http://127.0.0.1:1/'],
  ['--no-headed'],
  ['--headed', 'false'],
  ['--headed', 'true', 'x'],
  ['--no-', 'x'],
  ['---x', 'y'],
  ['open', '--headed=yes'],
  ['--json=1', 'snapshot'],
  ['fill', 'e1', '--', '--submit'],
  ['goto', '--', '-s=x'],
  ['a', '--', 'b', '--', 'c'],
  ['--'],
  ['-'],
  ['-1', 'x'],
  ['--_'],
  ['--_', 'x'],
  ['screenshot', '--filename=a.png', '--full-page'],
  ['snapshot', '--depth', '3'],
  ['click', 'e1', '--button', 'right', '--modifiers', 'Alt'],
  ['-szensu-verify-run1', 'eval', '1'],
  ['-szensu-verify-a', 'eval', '1'],
  ['-s/zensu-verify-a', 'snapshot'],
  ['-s.x', 'y'],
  ['-s-', 'snapshot'],
  ['-_s', 'zensu-verify-a', 'eval', '1'],
  ['-.s', 'zensu-verify-a', 'eval', '1'],
  ['-@s', 'zensu-verify-a', 'eval', '1'],
  ['-S', 'zensu-verify-a', 'eval', '1'],
];

function extract(source, pattern, label, file = 'program.js') {
  const match = source.match(pattern);
  if (!match) throw new Error(`${label} not found in ${file}`);
  return match;
}

function binNames(pkg) {
  if (typeof pkg.bin === 'string') return [pkg.name.split('/').pop()];
  return Object.keys(pkg.bin || {}).sort();
}

function record(cliRoot) {
  const pkg = JSON.parse(fs.readFileSync(path.join(cliRoot, 'package.json'), 'utf8'));
  if (pkg.name !== '@playwright/cli') throw new Error(`${cliRoot} is not the @playwright/cli package`);
  const corePkgFile = require.resolve('playwright-core/package.json', { paths: [cliRoot] });
  const clientDir = path.join(path.dirname(corePkgFile), 'lib', 'tools', 'cli-client');
  const program = fs.readFileSync(path.join(clientDir, 'program.js'), 'utf8');
  const help = JSON.parse(fs.readFileSync(path.join(clientDir, 'help.json'), 'utf8'));
  const registry = fs.readFileSync(path.join(clientDir, 'registry.js'), 'utf8');
  extract(registry, /function explicitSessionName\(sessionName\) \{\s*return sessionName \|\| process\.env\.PLAYWRIGHT_CLI_SESSION;\s*\}/,
    'session precedence', 'registry.js');
  const own = JSON.parse(extract(program, /const booleanOptions = (\[[^\]]*\]);/, 'booleanOptions')[1]);
  extract(program, /const boolean = \[\.\.\.help\.booleanOptions, \.\.\.booleanOptions\];/, 'boolean set');
  extract(program, /import_minimist\.minimist\)\(argv, \{ boolean, string: \["_"\] \}\)/, 'minimist call');
  extract(program, /if \(args\.s\) \{\s*args\.session = args\.s;\s*delete args\.s;\s*\}/, 'session fold');
  extract(program, /if \(args\.g\) \{\s*args\.global = true;\s*delete args\.g;\s*\}/, 'global fold');
  const boolean = [...help.booleanOptions, ...own];
  const { minimist } = require(path.join(clientDir, 'minimist.js'));
  const cases = CASES.map((argv) => {
    try {
      const args = minimist(argv.slice(), { boolean, string: ['_'] });
      if (args.s) {
        args.session = args.s;
        delete args.s;
      }
      if (args.g) {
        args.global = true;
        delete args.g;
      }
      return { argv, args };
    } catch (error) {
      return { argv, error: String(error && error.message) };
    }
  });
  return {
    schema: 1,
    source: {
      package: pkg.name,
      version: pkg.version,
      bin: binNames(pkg),
      playwrightCore: JSON.parse(fs.readFileSync(corePkgFile, 'utf8')).version,
    },
    booleanOptions: [...new Set(boolean)].sort(),
    stringOptions: ['_'],
    sessionPrecedence: 'argument-over-environment',
    cases,
  };
}

if (require.main === module) {
  const [cliRoot, out] = process.argv.slice(2);
  if (!cliRoot || !out) {
    process.stderr.write('usage: node record-playwright-cli-argv.js <@playwright/cli package directory> <output json>\n');
    process.exit(2);
  }
  fs.writeFileSync(out, `${JSON.stringify(record(path.resolve(cliRoot)), null, 2)}\n`);
}

module.exports = { CASES, record };
