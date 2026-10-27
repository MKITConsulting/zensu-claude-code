'use strict';

const { parse, firstLine } = require('../lib/envelope.js');

const PREFIXES = ['Executing via /zensu:build', 'Skipping /zensu:build'];

module.exports = (output) => {
  const hit = parse(output).prose.split('\n').map(firstLine).find((l) => PREFIXES.some((p) => l.startsWith(p)));
  return { pass: !hit, score: hit ? 0 : 1, reason: hit ? `a route status line with no route injected: ${hit.slice(0, 160)}` : 'no route status line' };
};

module.exports.PREFIXES = PREFIXES;
