'use strict';

const { parse, pairs, resultOf } = require('../lib/envelope.js');
const { CONTINUE_REASON } = require('../lib/decision-probe.js');

module.exports = (output) => {
  const e = parse(output);
  const map = pairs(e);
  const ask = e.probe.find((r) => r.tool === 'AskUserQuestion');
  if (!ask) return { pass: false, score: 0, reason: 'the probe recorded no AskUserQuestion call, so this CLI may not offer the tool under --permission-prompt-tool stdio' };
  if (ask.decision !== 'CONTINUE') return { pass: false, score: 0, reason: `the probe answered the AskUserQuestion call with ${ask.decision}` };
  let use = null;
  for (const [u, r] of map) if (r === ask) use = u;
  const result = resultOf(e, use);
  if (!result) return { pass: false, score: 0, reason: 'the stream shows no result for the AskUserQuestion call the probe answered' };
  if (!result.isError) return { pass: false, score: 0, reason: 'the AskUserQuestion call went through despite the deny, so the probe does not answer it before the permission channel' };
  if (!result.text.includes(CONTINUE_REASON)) return { pass: false, score: 0, reason: `the AskUserQuestion call failed, but not with the probe's reason: ${result.text.slice(0, 200)}` };
  return { pass: true, score: 1, reason: "AskUserQuestion was offered, and the probe answered it with its own reason before it reached a person" };
};
