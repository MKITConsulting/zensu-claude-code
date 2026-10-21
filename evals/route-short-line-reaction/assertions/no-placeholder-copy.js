'use strict';

const { parse } = require('../lib/envelope.js');

const PLACEHOLDERS = ['<the source the field names>', '__ZENSU_DELIVERY_ROUTE__', '__ZENSU_ROUTE_COMMAND__'];

module.exports = (output) => {
  const prose = parse(output).prose;
  const hit = PLACEHOLDERS.find((s) => prose.includes(s));
  return { pass: !hit, score: hit ? 0 : 1, reason: hit ? `copied hook scaffolding: ${hit}` : 'no placeholder copied' };
};

module.exports.PLACEHOLDERS = PLACEHOLDERS;
