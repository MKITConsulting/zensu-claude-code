'use strict';

const { parse, pairs, resultOf } = require('../lib/envelope.js');
const { reasonFor } = require('../lib/decision-probe.js');

const HOOK_ERROR = /^PreToolUse:\S+ hook error:/;

function answeredByProbe(record, result) {
  if (record.decision === 'ALLOW') return !(result.isError && HOOK_ERROR.test(result.text));
  return result.isError && result.text.includes(reasonFor(record.decision));
}

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
  const foreign = [];
  for (const [use, record] of map) {
    const result = resultOf(e, use);
    if (result && !answeredByProbe(record, result)) foreign.push(`${use.name} #${record.seq} (${record.decision}): ${result.text.split('\n')[0].slice(0, 160)}`);
  }
  if (foreign.length) return fail(`${foreign.length} call(s) did not get the probe's answer, so another hook or the tool itself decided them: ${foreign.join('; ')}`);
  const by = e.probe.length > 0 && e.probe.every((r) => r.id) ? 'id' : 'position';
  return { pass: true, score: 1, reason: `isolated; ${e.probe.length} probed calls paired by ${by} and answered by the probe; fixture unchanged` };
};
