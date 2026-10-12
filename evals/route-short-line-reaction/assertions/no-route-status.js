'use strict';

const { parse, firstLine } = require('../lib/envelope.js');

const PREFIXES = ['Executing via /zensu:tdd', 'Skipping TDD'];

module.exports = (output) => {
  const head = firstLine(parse(output).prose);
  const bad = PREFIXES.some((p) => head.startsWith(p));
  return { pass: !bad, score: bad ? 0 : 1, reason: bad ? `a route status line with no route injected: ${head.slice(0, 160)}` : 'no route status line' };
};

module.exports.PREFIXES = PREFIXES;
