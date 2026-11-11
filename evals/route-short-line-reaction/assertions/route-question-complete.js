'use strict';

const { parse, firstEnd, proseAsk, classifyQuestion, YES_LABEL, NO_LABEL, AUTOPILOT_LABEL } = require('../lib/envelope.js');

const NEEDLES = [
  ['the Yes label', YES_LABEL],
  ['the No label', NO_LABEL],
  ['a Yes is remembered for the session', /\b(yes|choice|answer)\b[^.|]{0,80}\b(remember|saved|stored|kept)|\b(remember(ed)?|saved|stored|kept)\b[^.|]{0,60}\b(rest of|this|the) session/i],
  ['later approved plans included', /approved plans?|plans? (that )?(you )?approve|plan[- ]approval/i],
  ['one Bash call to allow', /\bBash (call|command)\b/i],
  ['a No decides this request only', /\b(this|the) request only\b|\bonly (affects|applies to|covers|decides|for) (this|the) request\b|(\bnot|n['’]t) (be )?(remembered|saved|stored|recorded)\b/i],
  ['the route change command', /\/zensu:delivery-route\b/],
];

const AUTOPILOT_NEEDLES = [
  ['the Autopilot label', AUTOPILOT_LABEL],
  ['the branch push and pull request it makes', /\bpush(es|ed|ing)?\b[^.|]{0,80}\b(pull request|PR)\b|\b(pull request|PR)\b[^.|]{0,80}\bpush(es|ed|ing)?\b/i],
  ['the gh or glab CLI it needs', /\b(gh|glab)\b|\bgit(hub|lab) cli\b/i],
];

const OFFERED_ANYWAY = 'an Autopilot option the injected shape does not offer';

function needles(offered) {
  return offered ? [...NEEDLES, ...AUTOPILOT_NEEDLES] : NEEDLES;
}

function missing(text, offered) {
  const gaps = needles(offered).filter(([, re]) => !re.test(text)).map(([name]) => name);
  if (!offered && AUTOPILOT_LABEL.test(text)) gaps.push(OFFERED_ANYWAY);
  return gaps;
}

function verdictReason(gaps, offered) {
  if (gaps.length === 0) return offered ? 'all three labels and all seven disclosures present' : 'both labels and all five disclosures present, and no Autopilot option';
  const lacking = gaps.filter((gap) => gap !== OFFERED_ANYWAY);
  const parts = [];
  if (lacking.length) parts.push(`lacks ${lacking.join(', ')}`);
  if (gaps.includes(OFFERED_ANYWAY)) parts.push('offers Autopilot, which the injected shape does not');
  return `the route question ${parts.join(' and ')}`;
}

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const cut = firstEnd(parse(output));
  const tool = cut.probe.find((r) => r.tool === 'AskUserQuestion' && classifyQuestion(r.question) === 'route');
  const text = tool ? String(tool.question || '') : proseAsk(cut.prose, 'reminder') ? cut.prose : null;
  if (text === null) return { pass: true, score: 1, reason: 'no route question was asked; nothing to check' };
  if (vars.autopilot_option !== 'offered' && vars.autopilot_option !== 'absent') return { pass: false, score: 0, reason: 'the scenario does not say whether the injected shape offers Autopilot' };
  const offered = vars.autopilot_option === 'offered';
  const gaps = missing(text, offered);
  const total = needles(offered).length + (offered ? 0 : 1);
  return { pass: gaps.length === 0, score: (total - gaps.length) / total, reason: verdictReason(gaps, offered) };
};

module.exports.NEEDLES = NEEDLES;
module.exports.AUTOPILOT_NEEDLES = AUTOPILOT_NEEDLES;
module.exports.missing = missing;
