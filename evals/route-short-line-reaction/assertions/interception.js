'use strict';

const { parse, pairs, resultOf } = require('../lib/envelope.js');
const { END_REASON } = require('../lib/decision-probe.js');

module.exports = (output) => {
  const e = parse(output);
  const map = pairs(e);
  const skill = e.probe.find((r) => r.tool === 'Skill');
  if (!skill) return { pass: false, score: 0, reason: 'the probe recorded no Skill call' };
  if (skill.decision !== 'END') return { pass: false, score: 0, reason: `the probe answered the Skill call with ${skill.decision}` };
  let use = null;
  for (const [u, r] of map) if (r === skill) use = u;
  const result = resultOf(e, use);
  if (!result) return { pass: false, score: 0, reason: 'the stream shows no result for the Skill call the probe denied' };
  if (!result.isError) return { pass: false, score: 0, reason: 'the Skill call ran despite the deny, so PreToolUse does not hold here' };
  if (!result.text.includes(END_REASON)) return { pass: false, score: 0, reason: `the Skill call failed, but not with the probe's reason: ${result.text.slice(0, 200)}` };
  return { pass: true, score: 1, reason: "the Skill call was denied with the probe's reason before it ran" };
};
