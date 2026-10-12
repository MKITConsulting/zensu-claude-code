'use strict';

const { parse, openingLines } = require('../lib/envelope.js');

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const want = String(vars.expected_status || '');
  const lines = openingLines(parse(output));
  const ok = want !== '' && lines.some((l) => l.startsWith(want));
  const head = lines.length ? lines[lines.length - 1] : '';
  return { pass: ok, score: ok ? 1 : 0, reason: ok ? 'status line exact' : `the opening line "${head.slice(0, 160)}" is not "${want}"` };
};
