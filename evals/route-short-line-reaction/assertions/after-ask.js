'use strict';

const { parse, decisiveAt } = require('../lib/envelope.js');

module.exports = (output) => {
  const e = parse(output);
  const first = decisiveAt(e.probe, 0);
  if (first.value !== 'ask') return { pass: true, score: 1, reason: 'no route question was asked through the tool, so nothing follows it to grade' };
  const next = decisiveAt(e.probe, first.index + 1);
  const ok = next.value === 'none' || next.value === 'skill:zensu:tdd';
  return { pass: ok, score: ok ? 1 : 0, reason: ok ? `after the unanswered route question: ${next.value}` : `after the unanswered route question the run went on to ${next.value}` };
};
