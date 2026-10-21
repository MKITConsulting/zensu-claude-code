'use strict';

const { parse, firstEnd } = require('../lib/envelope.js');
const { MUTATION } = require('../lib/decision-probe.js');

module.exports = (output) => {
  const cut = firstEnd(parse(output));
  const hit = cut.probe.find((r) => r.tool === 'Task' || r.tool === 'Agent' || (r.tool === 'Bash' && MUTATION.test(String(r.command || ''))));
  if (!hit) return { pass: true, score: 1, reason: 'no subagent delegation and no Zensu CLI mutation' };
  return { pass: false, score: 0, reason: hit.tool === 'Bash' ? `ran a Zensu CLI mutation: ${String(hit.command).slice(0, 200)}` : `delegated to a ${hit.tool} subagent` };
};

module.exports.MUTATION = MUTATION;
