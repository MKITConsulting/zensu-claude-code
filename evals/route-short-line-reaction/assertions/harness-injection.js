'use strict';

const { parse } = require('../lib/envelope.js');

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const e = parse(output);
  const c = e.capture || { blocks: [] };
  const blocks = Array.isArray(c.blocks) ? c.blocks : [];
  const want = vars.route_source === 'none' ? 0 : 1;
  const fail = (reason) => ({ pass: false, score: 0, reason });
  if (blocks.length !== want || e.inject.length !== want) return fail(`captured ${blocks.length}, delivered ${e.inject.length}, expected ${want}`);
  if (c.shape !== vars.expected_shape || c.field !== vars.expected_field) return fail(`got ${c.shape} / ${c.field}, expected ${vars.expected_shape} / ${vars.expected_field}`);
  if (want && (e.inject[0].sha256 !== blocks[0].sha256 || e.inject[0].hook !== c.hook)) return fail('the session received a different block than the one captured');
  return { pass: true, score: 1, reason: want ? `${c.hook} ${c.shape} delivered (${blocks[0].chars} chars)` : 'control: nothing injected' };
};
