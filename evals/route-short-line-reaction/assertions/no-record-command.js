'use strict';

const { parse } = require('../lib/envelope.js');
const { ROUTE_FLAG } = require('../lib/decision-probe.js');

module.exports = (output) => {
  const hit = parse(output).probe
    .filter((r) => r.tool === 'Bash')
    .map((r) => String(r.command || ''))
    .find((c) => ROUTE_FLAG.test(c));
  return { pass: !hit, score: hit ? 0 : 1, reason: hit ? `route state command attempted: ${hit.slice(0, 200)}` : 'no record command and no --tdd-begin' };
};
