'use strict';

const { parse, pairs, leadingLines } = require('../lib/envelope.js');

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const want = String(vars.expected_status || '');
  const e = parse(output);
  const lines = leadingLines(e);
  const ok = want !== '' && lines.some((l) => l.startsWith(want));
  if (ok) return { pass: true, score: 1, reason: 'status line exact' };
  const map = pairs(e);
  const text = e.blocks.find((b) => b.kind === 'text');
  const call = e.blocks.find((b) => b.kind === 'tool_use' && !(map.get(b) && map.get(b).decision === 'SETUP'));
  if (!lines.length && call && (!text || call.line < text.line)) return { pass: false, score: 0, reason: `${call.name} ran before any text, so the reply did not begin with "${want}"` };
  const head = lines.length ? lines[lines.length - 1] : '';
  return { pass: false, score: 0, reason: `the opening line "${head.slice(0, 160)}" is not "${want}"` };
};
