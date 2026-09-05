'use strict';
const net = require('node:net');

const FLOOR_REASONS = Object.freeze({
  INVALID: 'navigation target is invalid',
  CREDENTIALS: 'navigation target contains credentials',
  QUERY_OR_FRAGMENT: 'navigation target contains query or fragment',
  LOCAL_LITERAL_LOOPBACK: 'local navigation policy accepts literal loopback-IP origins only',
  REMOTE_HTTPS: 'remote navigation policy requires non-loopback HTTPS origins',
  REMOTE_NOT_PUBLIC: 'remote address is not globally routable',
  SCHEME: 'navigation target scheme is not http, https, ws, or wss',
});

const CONSENT_REMOTE_REASON = 'consent mode admits literal loopback origins only; a remote target needs the parent-environment navigation policy';

function normalizeRoute(route) {
  if (typeof route !== 'string' || !route.startsWith('/')
      || route.includes('?') || route.includes('#') || route.includes('*')) return null;
  let normalized;
  try { normalized = new URL(route, 'https://zensu.invalid').pathname; }
  catch (_error) { return null; }
  return normalized === route ? route : null;
}

function normalizeHostname(hostname) {
  return String(hostname).toLowerCase().replace(/^\[|\]$/g, '');
}

function ipv4Number(address) {
  const parts = String(address).split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return null;
  return parts.reduce((value, part) => ((value << 8) | part) >>> 0, 0);
}

function inIpv4Range(value, base, bits) {
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return (value & mask) === (ipv4Number(base) & mask);
}

function isPublicIpv4(address) {
  const value = ipv4Number(address);
  if (value === null) return false;
  const denied = [
    ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8],
    ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24],
    ['192.88.99.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24],
    ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
  ];
  return !denied.some(([base, bits]) => inIpv4Range(value, base, bits));
}

function expandIpv6(address) {
  const zoneFree = String(address).toLowerCase().split('%')[0];
  if (zoneFree.includes('.')) return null;
  const halves = zoneFree.split('::');
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const missing = 8 - left.length - right.length;
  if (missing < 0 || (halves.length === 1 && missing !== 0)) return null;
  const groups = [...left, ...Array(missing).fill('0'), ...right];
  if (groups.length !== 8 || groups.some((group) => !/^[0-9a-f]{1,4}$/.test(group))) return null;
  return groups.map((group) => Number.parseInt(group, 16));
}

function isPublicIpv6(address) {
  const groups = expandIpv6(address);
  if (!groups) return false;
  const value = groups.reduce((result, group) => (result << 16n) | BigInt(group), 0n);
  const inRange = (base, bits) => {
    const baseGroups = expandIpv6(base);
    const baseValue = baseGroups.reduce((result, group) => (result << 16n) | BigInt(group), 0n);
    const shift = 128n - BigInt(bits);
    return (value >> shift) === (baseValue >> shift);
  };
  if (!inRange('2000::', 3)) return false;
  const specialPurpose = [
    ['2001::', 32],
    ['2001:1::', 32],
    ['2001:2::', 48],
    ['2001:10::', 28],
    ['2001:20::', 28],
    ['2001:db8::', 32],
    ['2002::', 16],
    ['3fff::', 20],
  ];
  return !specialPurpose.some(([base, bits]) => inRange(base, bits));
}

function isPublicAddress(address) {
  const family = net.isIP(address);
  return family === 4 ? isPublicIpv4(address) : family === 6 ? isPublicIpv6(address) : false;
}

function isLoopbackHost(hostname) {
  const normalized = normalizeHostname(hostname);
  if (normalized === '::1') return true;
  const value = ipv4Number(normalized);
  return value !== null && inIpv4Range(value, '127.0.0.0', 8);
}

async function resolveRemoteHost(hostname, resolver) {
  const normalized = normalizeHostname(hostname);
  if (net.isIP(normalized)) {
    if (!isPublicAddress(normalized)) throw new Error(FLOOR_REASONS.REMOTE_NOT_PUBLIC);
    return [normalized];
  }
  const records = await resolver(normalized, { all: true, verbatim: true });
  const addresses = [...new Set(records.map((record) => record.address))];
  if (addresses.length === 0 || addresses.some((address) => !isPublicAddress(address))) {
    throw new Error('remote DNS includes a non-public or unresolved address');
  }
  return addresses;
}

function comparisonOrigin(parsed) {
  if (parsed.protocol === 'ws:') return `http://${parsed.host}`;
  if (parsed.protocol === 'wss:') return `https://${parsed.host}`;
  return parsed.origin;
}

function checkNavigationTarget(rawUrl, navigation = true) {
  let parsed;
  try { parsed = new URL(String(rawUrl)); }
  catch (_error) { return { ok: false, reason: FLOOR_REASONS.INVALID }; }
  if (!['http:', 'https:', 'ws:', 'wss:'].includes(parsed.protocol)) {
    return { ok: false, reason: FLOOR_REASONS.SCHEME };
  }
  if (parsed.username || parsed.password) return { ok: false, reason: FLOOR_REASONS.CREDENTIALS };
  if (navigation && (parsed.search || parsed.hash)) return { ok: false, reason: FLOOR_REASONS.QUERY_OR_FRAGMENT };
  return { ok: true, parsed, origin: comparisonOrigin(parsed), pathname: parsed.pathname };
}

function classifyOrigin(rawUrl, navigation = true) {
  const target = checkNavigationTarget(rawUrl, navigation);
  if (!target.ok) return target;
  const { parsed } = target;
  const hostname = normalizeHostname(parsed.hostname);
  const secure = parsed.protocol === 'https:' || parsed.protocol === 'wss:';
  if (isLoopbackHost(hostname)) {
    return { ...target, mode: 'local', hostname };
  }
  if (net.isIP(hostname)) {
    if (!secure) return { ok: false, reason: FLOOR_REASONS.REMOTE_HTTPS, origin: target.origin };
    if (!isPublicAddress(hostname)) return { ok: false, reason: FLOOR_REASONS.REMOTE_NOT_PUBLIC, origin: target.origin };
    return { ...target, mode: 'remote', hostname };
  }
  if (!secure) return { ok: false, reason: FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK, origin: target.origin };
  return { ...target, mode: 'remote', hostname };
}

module.exports = {
  CONSENT_REMOTE_REASON,
  FLOOR_REASONS,
  checkNavigationTarget,
  classifyOrigin,
  expandIpv6,
  inIpv4Range,
  ipv4Number,
  isLoopbackHost,
  isPublicAddress,
  isPublicIpv4,
  isPublicIpv6,
  normalizeHostname,
  normalizeRoute,
  resolveRemoteHost,
};
