'use strict';

const assert = require('node:assert/strict');
const net = require('node:net');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const HELPER = path.resolve(__dirname, '../../scripts/verify-free-port.js');
const { freePort, parseArgs, probe } = require(HELPER);

function listen(port) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

test('argument parsing accepts --from and --exclude and refuses anything else', () => {
  assert.deepEqual(parseArgs([]), { from: null, exclude: new Set() });
  assert.deepEqual(parseArgs(['--from', '5173']), { from: 5173, exclude: new Set() });
  assert.deepEqual(parseArgs(['--exclude', '5173,5174,x']).exclude, new Set([5173, 5174]));
  assert.throws(() => parseArgs(['--from', '80']), /between 1024 and 65535/);
  assert.throws(() => parseArgs(['--from', 'abc']), /between 1024 and 65535/);
  assert.throws(() => parseArgs(['--bogus']), /usage/);
});

test('a free port is found from a base, skipping occupied and excluded ports', async () => {
  const anchor = await listen(0);
  const base = anchor.address().port;
  try {
    const occupied = await listen(base + 1).catch(() => null);
    try {
      const port = await freePort({ from: base, exclude: new Set([base + 2]) });
      assert.notEqual(port, base);
      assert.notEqual(port, base + 2);
      if (occupied) assert.notEqual(port, base + 1);
      assert.equal(await probe(port), port);
    } finally {
      if (occupied) await new Promise((resolve) => occupied.close(resolve));
    }
  } finally {
    await new Promise((resolve) => anchor.close(resolve));
  }
  const ephemeral = await freePort({ from: null, exclude: new Set() });
  assert.equal(Number.isInteger(ephemeral) && ephemeral >= 1024, true);
  await assert.rejects(freePort({ from: 65535, exclude: new Set([65535]) }), /no free loopback port/);
});

test('the CLI prints one port and reports a usage error on stderr', () => {
  const ok = spawnSync(process.execPath, [HELPER, '--from', '5173'], { encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /^[0-9]+\n$/);
  const bad = spawnSync(process.execPath, [HELPER, '--from', '1'], { encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /zensu verify free port: /);
});
