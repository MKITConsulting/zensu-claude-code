'use strict';

const { parse, pairs, resultOf } = require('../lib/envelope.js');

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const marker = String(vars.read_marker || '');
  const fail = (reason) => ({ pass: false, score: 0, reason });
  if (!marker) return fail('the scenario names no read_marker');
  const e = parse(output);
  const reads = [];
  for (const [use, record] of pairs(e)) if (use.name === 'Bash' && record.decision === 'ALLOW') reads.push(resultOf(e, use));
  if (!reads.length) return fail('the probe allowed no Bash call, so the allowed path never ran');
  if (reads.some((r) => r && !r.isError && r.text.includes(marker))) return { pass: true, score: 1, reason: `an allowed Bash read ran in the fixture and returned ${JSON.stringify(marker)}` };
  const first = reads[0];
  const seen = first ? `${first.isError ? 'an error: ' : ''}${first.text.split('\n')[0].slice(0, 200)}` : 'no result';
  return fail(`no allowed Bash read returned ${JSON.stringify(marker)} without an error; the first one returned ${seen}`);
};
