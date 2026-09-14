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
  normalizeRoute,
  policyContractFault,
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

// normalizeRoute has TWO production consumers: normalizeRoutes() in hooks/lib/verify-consent-v1.js,
// which builds the route list the human reads in the consent prompt, and parsePolicy() in
// scripts/playwright-mcp-proxy.js, which validates a recipe's declared routes at broker start.
// Its own truth table was graded by nothing. The load-bearing conjunct is the final
// `normalized === route`: without it a declared `/a/../b` renders as written while naming a
// different path, and `//evil.example.com/x` -- which a URL parser reads as a host -- renders
// as a route.
//
// `/a%2e%2e/b` is ACCEPTED and that is correct rather than an oversight. WHATWG treats `%2e%2e`
// as a double-dot segment, but only when it is the WHOLE segment; here the segment is `a%2e%2e`.
// Two independent readers of this file got that boundary wrong, so the discriminating pair is
// pinned rather than left to be re-derived: `/%2e%2e/b` collapses to `/b` and is refused,
// `/a%2e%2e/b` does not collapse and is kept. Every encoded spelling of a whole dot segment --
// `%2e%2e`, `%2E%2E`, `%2e.`, `.%2e` and the single-dot forms -- is in the refused list below,
// so encoding a traversal token does not neutralize the check.
test('route normalization accepts only an absolute, query-free, already-normalized pathname', () => {
  for (const good of ['/', '/login', '/a/b/c', '/a//b', '/a%2e%2e/b', '/%41']) {
    assert.equal(normalizeRoute(good), good, good);
  }

  for (const bad of ['login', '', '/a?b=1', '/a#f', '/a/*', '/a/../b', '/a/./b', '/a b',
    '//evil.example.com/x', '/a\\b',
    '/%2e%2e/b', '/%2E%2E/b', '/%2e./b', '/.%2e/b', '/a/%2e%2e/b', '/%2e/b', '/a/%2e/b',
    42, null, undefined, ['/a'], { toString: () => '/a' }]) {
    assert.equal(normalizeRoute(bad), null, JSON.stringify(bad));
  }
});

// The doctor RENDERS this string to an operator and the consent gate decides on it being
// empty, so the three causes have to stay tellable apart: a conflated one sends the reader to
// the wrong half of the policy.
test('the contract check names which guard refused and keeps the three causes distinct', () => {
  const target = { origin: 'http://127.0.0.1:4300', routes: ['/'], evidenceMode: 'declared-safe' };
  const causes = [
    ['{oops', 'policy is not valid JSON'],
    ['{}', 'policy contains unknown or missing keys'],
    [JSON.stringify({ version: 1 }), 'policy contains unknown or missing keys'],
    [JSON.stringify({ version: 1, mode: 'local', targets: [target], extra: 1 }), 'policy contains unknown or missing keys'],
    [JSON.stringify({ version: 2, mode: 'local', targets: [target] }), 'policy contract is invalid'],
    [JSON.stringify({ version: 1, mode: 'sideways', targets: [target] }), 'policy contract is invalid'],
    [JSON.stringify({ version: 1, mode: 'local', targets: [] }), 'policy contract is invalid'],
    [JSON.stringify({ version: 1, mode: 'local', targets: Array.from({ length: 9 }, () => target) }), 'policy contract is invalid'],
  ];
  for (const [raw, expected] of causes) assert.equal(policyContractFault(raw), expected, raw.slice(0, 48));
  assert.equal(new Set(causes.map(([, expected]) => expected)).size, 3);
  assert.equal(policyContractFault(JSON.stringify({ version: 1, mode: 'local', targets: [target] })), '');
});

// policyContractFault is the EXTRACTED form of parsePolicy's three TOP-LEVEL guards -- the
// doctor and the consent gate call it, while the broker still spells those guards itself, so
// nothing held the two in step. Both directions are pinned here, and the guarantee is scoped to
// the top-level shape:
//   refuse-side, the safety-relevant one: a value the shared check refuses is never one the
//   broker would run in, or the gate disarms the floor for a policy the broker will not start
//   on -- the exact defect the V27 repair removed;
//   accept-side: a value it accepts the broker accepts too, so a one-sided TIGHTENING makes the
//   doctor report a fault for a policy that works and the gate re-prompt for no reason.
// A PER-TARGET divergence remains BY DESIGN and is demonstrated at the end of this test: the
// shared check has no opinion below the top level. It is contained by the broker failing to
// start rather than by this check catching it -- an uncaught parsePolicy throw exits the broker
// process -- so it costs the human the prompt and the audit line, never a navigation.
test('the shared contract check and the broker agree on the top-level policy shape', async () => {
  const proxy = require(path.resolve(__dirname, '../../scripts/playwright-mcp-proxy.js'));
  const target = { origin: 'http://127.0.0.1:4300', routes: ['/'], evidenceMode: 'declared-safe' };
  const refused = ['', '{oops', '{}',
    JSON.stringify({ version: 1 }),
    JSON.stringify({ version: 1, mode: 'local', targets: [target], extra: 1 }),
    JSON.stringify({ version: 2, mode: 'local', targets: [target] }),
    JSON.stringify({ version: 1, mode: 'sideways', targets: [target] }),
    JSON.stringify({ version: 1, mode: 'local', targets: [] }),
    JSON.stringify({ version: 1, mode: 'local', targets: Array.from({ length: 9 }, () => target) })];

  for (const raw of refused) {
    assert.notEqual(policyContractFault(raw), '', raw.slice(0, 48));
    let mode = null;
    try { mode = (await proxy.parsePolicy(raw, async () => [])).mode; }
    catch (error) {
      // The broker prefixes the same three causes with "navigation "; comparing the pair is
      // what catches a reword on either side rather than only a widened guard.
      assert.equal(error.message, 'navigation ' + policyContractFault(raw), raw.slice(0, 48));
      continue;
    }
    assert.equal(mode, 'deny', raw.slice(0, 48));
  }

  // Accept-side. One shape is not enough: narrowing the shared check's accepted mode set or its
  // 1..8 target range alone would leave every one of these still runnable in the broker.
  const publicDns = async () => [{ address: '93.184.216.34', family: 4 }];
  const accepted = [
    [JSON.stringify({ version: 1, mode: 'local', targets: [target] }), 'local', async () => []],
    [JSON.stringify({
      version: 1,
      mode: 'remote',
      targets: [{ origin: 'https://app.example.com', routes: ['/'], evidenceMode: 'declared-safe' }],
    }), 'remote', publicDns],
    [JSON.stringify({
      version: 1,
      mode: 'local',
      targets: Array.from({ length: 8 }, (_unused, index) => ({
        origin: 'http://127.0.0.1:' + String(4300 + index), routes: ['/'], evidenceMode: 'declared-safe',
      })),
    }), 'local', async () => []],
  ];
  for (const [raw, mode, resolver] of accepted) {
    assert.equal(policyContractFault(raw), '', raw.slice(0, 48));
    assert.equal((await proxy.parsePolicy(raw, resolver)).mode, mode, raw.slice(0, 48));
  }

  // The shared check is deliberately TOP-LEVEL only: the broker still refuses a target the
  // check has no opinion about, and that refusal must not borrow one of the three causes.
  const badTarget = JSON.stringify({ version: 1, mode: 'local', targets: [{ ...target, evidenceMode: 'other' }] });
  assert.equal(policyContractFault(badTarget), '');
  await assert.rejects(proxy.parsePolicy(badTarget, async () => []), (error) => {
    assert.match(error.message, /navigation target contract is invalid/);
    return true;
  });
});
