'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const path = require('node:path');

const floor = require('../../hooks/lib/verify-navigation-floor-v1.js');
const {
  FLOOR_REASONS,
  checkNavigationTarget,
  classifyOrigin,
  isLoopbackHost,
  isPublicAddress,
  normalizeHostname,
  resolveRemoteHost,
} = floor;

test('the broker requires the floor module instead of carrying its own predicates', () => {
  const proxyPath = path.resolve(__dirname, '../../scripts/playwright-mcp-proxy.js');
  const source = require('node:fs').readFileSync(proxyPath, 'utf8');
  assert.match(source, /verify-navigation-floor-v1\.js/);
  for (const own of ['function isPublicIpv4', 'function expandIpv6', 'function isLoopbackHost', 'function resolveRemoteHost']) {
    assert.equal(source.includes(own), false, own);
  }
  const proxy = require(proxyPath);
  assert.equal(proxy.isPublicAddress, isPublicAddress);
});

test('loopback detection accepts every 127/8 address and ::1 and nothing else', () => {
  assert.equal(isLoopbackHost('127.0.0.1'), true);
  assert.equal(isLoopbackHost('127.255.0.9'), true);
  assert.equal(isLoopbackHost('[::1]'), true);
  assert.equal(isLoopbackHost('::1'), true);
  assert.equal(isLoopbackHost('localhost'), false);
  assert.equal(isLoopbackHost('128.0.0.1'), false);
  assert.equal(isLoopbackHost('::ffff:127.0.0.1'), false);
  assert.equal(normalizeHostname('[2001:DB8::1]'), '2001:db8::1');
});

test('public-address classification rejects private, reserved, loopback, mapped and documentation ranges', () => {
  for (const denied of ['10.1.2.3', '100.64.0.1', '127.0.0.1', '169.254.169.254', '172.16.0.1', '192.168.1.1', '192.0.2.1', '198.18.0.1', '203.0.113.5', '224.0.0.1', '0.0.0.0', '::1', 'fc00::1', 'fe80::1', '2001:db8::1', '::ffff:93.184.216.34', 'not-an-ip']) {
    assert.equal(isPublicAddress(denied), false, denied);
  }
  for (const allowed of ['93.184.216.34', '8.8.8.8', '2606:2800:220:1:248:1893:25c8:1946']) {
    assert.equal(isPublicAddress(allowed), true, allowed);
  }
});

test('navigation targets refuse credentials, query and fragment, and unknown schemes', () => {
  assert.equal(checkNavigationTarget('http://user:pw@127.0.0.1:5173/').reason, FLOOR_REASONS.CREDENTIALS);
  assert.equal(checkNavigationTarget('http://127.0.0.1:5173/?x=1').reason, FLOOR_REASONS.QUERY_OR_FRAGMENT);
  assert.equal(checkNavigationTarget('http://127.0.0.1:5173/#top').reason, FLOOR_REASONS.QUERY_OR_FRAGMENT);
  assert.equal(checkNavigationTarget('http://127.0.0.1:5173/api?x=1', false).ok, true);
  assert.equal(checkNavigationTarget('file:///etc/passwd').reason, FLOOR_REASONS.SCHEME);
  assert.equal(checkNavigationTarget('not a url').reason, FLOOR_REASONS.INVALID);
  assert.equal(checkNavigationTarget('ws://127.0.0.1:5173/events', false).origin, 'http://127.0.0.1:5173');
  assert.equal(checkNavigationTarget('wss://app.example.com/events', false).origin, 'https://app.example.com');
});

test('origin classification splits literal loopback from public https and refuses the rest', () => {
  assert.equal(classifyOrigin('http://127.0.0.1:5173/inventory').mode, 'local');
  assert.equal(classifyOrigin('https://[::1]:8443/').mode, 'local');
  assert.equal(classifyOrigin('https://app.example.com/dashboard').mode, 'remote');
  assert.equal(classifyOrigin('https://93.184.216.34/').mode, 'remote');
  assert.equal(classifyOrigin('http://localhost:5173/').reason, FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK);
  assert.equal(classifyOrigin('http://app.example.com/').reason, FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK);
  assert.equal(classifyOrigin('http://10.0.0.5/').reason, FLOOR_REASONS.REMOTE_HTTPS);
  assert.equal(classifyOrigin('https://10.0.0.5/').reason, FLOOR_REASONS.REMOTE_NOT_PUBLIC);
  assert.equal(classifyOrigin('https://169.254.169.254/latest/meta-data').reason, FLOOR_REASONS.REMOTE_NOT_PUBLIC);
  assert.equal(classifyOrigin('https://[::ffff:93.184.216.34]/').reason, FLOOR_REASONS.REMOTE_NOT_PUBLIC);
  assert.equal(classifyOrigin('http://user:pw@127.0.0.1:5173/').reason, FLOOR_REASONS.CREDENTIALS);
  assert.equal(classifyOrigin('http://127.0.0.1:5173/?q').reason, FLOOR_REASONS.QUERY_OR_FRAGMENT);
});

test('remote host resolution pins only globally routable answers', async () => {
  assert.deepEqual(await resolveRemoteHost('93.184.216.34', async () => []), ['93.184.216.34']);
  await assert.rejects(resolveRemoteHost('10.0.0.1', async () => []), /not globally routable/);
  const resolver = async () => [{ address: '93.184.216.34' }, { address: '93.184.216.34' }];
  assert.deepEqual(await resolveRemoteHost('app.example.com', resolver), ['93.184.216.34']);
  const mixed = async () => [{ address: '93.184.216.34' }, { address: '192.168.0.1' }];
  await assert.rejects(resolveRemoteHost('app.example.com', mixed), /non-public or unresolved/);
  await assert.rejects(resolveRemoteHost('app.example.com', async () => []), /non-public or unresolved/);
});

// A non-string target is refused rather than coerced. String(["http://127.0.0.1:9999"]) is the
// bare URL, so coercion classified an array argument as loopback and let it reach the consent
// broker's approved map without a prompt.
test('the navigation target refuses a non-string target instead of coercing it', () => {
  for (const value of [['http://127.0.0.1:9999/'], undefined, null, 42, { toString: () => 'http://127.0.0.1:9999/' }]) {
    assert.equal(checkNavigationTarget(value).reason, FLOOR_REASONS.INVALID);
    assert.equal(classifyOrigin(value).ok, false);
    assert.equal(classifyOrigin(value).mode, undefined);
  }
  assert.equal(classifyOrigin('http://127.0.0.1:9999/').mode, 'local');
});
