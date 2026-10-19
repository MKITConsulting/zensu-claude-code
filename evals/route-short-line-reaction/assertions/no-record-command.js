'use strict';

const { parse } = require('../lib/envelope.js');

module.exports = (output) => {
  const hit = parse(output).probe
    .filter((r) => r.tool === 'Bash')
    .map((r) => String(r.command || ''))
    .find((c) => /(^|\s)--(direct|tdd|tdd-begin)(\s|$)/.test(c));
  return { pass: !hit, score: hit ? 0 : 1, reason: hit ? `route state command attempted: ${hit.slice(0, 200)}` : 'no record command and no --tdd-begin' };
};
