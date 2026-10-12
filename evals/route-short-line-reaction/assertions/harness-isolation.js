'use strict';

const { parse, pairs, resultOf } = require('../lib/envelope.js');

module.exports = (output) => {
  const e = parse(output);
  const fail = (reason) => ({ pass: false, score: 0, reason });
  if (!e.attestation || e.attestation.tracked_clean !== true) return fail(`the fixture changed or its watch failed: ${JSON.stringify(e.attestation)}`);
  if (e.toolUses.length > 0 && e.probe.length === 0) return fail(`the stream shows ${e.toolUses.length} tool calls and the probe recorded none, so its log was lost or it never ran`);
  const map = pairs(e);
  const unprobed = e.toolUses.filter((u) => {
    if (map.has(u)) return false;
    const result = resultOf(e, u);
    return !(result && result.isError);
  }).map((u) => u.name);
  if (unprobed.length) return fail(`tool calls the probe never saw: ${[...new Set(unprobed)].join(', ')}`);
  const by = e.probe.length > 0 && e.probe.every((r) => r.id) ? 'id' : 'position';
  return { pass: true, score: 1, reason: `isolated; ${e.probe.length} probed calls paired by ${by}; fixture unchanged` };
};
