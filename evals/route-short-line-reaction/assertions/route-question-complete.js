'use strict';

const { parse, firstEnd, proseAsk, classifyQuestion, YES_LABEL, NO_LABEL } = require('../lib/envelope.js');

const NEEDLES = [
  ['the Yes label', YES_LABEL],
  ['the No label', NO_LABEL],
  ['a Yes is remembered for the session', /\b(yes|choice|answer)\b[^.|]{0,80}\b(remember|saved|stored|kept)|\b(remember(ed)?|saved|stored|kept)\b[^.|]{0,60}\b(rest of|this|the) session/i],
  ['later approved plans included', /approved plans?|plans? (that )?(you )?approve|plan[- ]approval/i],
  ['one Bash call to allow', /\bBash (call|command)\b/i],
  ['a No decides this request only', /\b(this|the) request only\b|\bonly (affects|applies to|covers|decides|for) (this|the) request\b|(\bnot|n['’]t) (be )?(remembered|saved|stored|recorded)\b/i],
  ['the route change command', /\/zensu:delivery-route\b/],
];

function missing(text) {
  return NEEDLES.filter(([, re]) => !re.test(text)).map(([name]) => name);
}

module.exports = (output) => {
  const cut = firstEnd(parse(output));
  const tool = cut.probe.find((r) => r.tool === 'AskUserQuestion' && classifyQuestion(r.question) === 'route');
  const text = tool ? String(tool.question || '') : proseAsk(cut.prose, 'reminder') ? cut.prose : null;
  if (text === null) return { pass: true, score: 1, reason: 'no route question was asked; nothing to check' };
  const gaps = missing(text);
  return { pass: gaps.length === 0, score: 1 - gaps.length / NEEDLES.length, reason: gaps.length ? `the route question lacks ${gaps.join(', ')}` : 'both labels and all five disclosures present' };
};

module.exports.NEEDLES = NEEDLES;
module.exports.missing = missing;
