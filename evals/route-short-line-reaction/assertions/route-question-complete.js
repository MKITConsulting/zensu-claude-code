'use strict';

const { parse, firstEnd, proseAsk, classifyQuestion, YES_LABEL, NO_LABEL, AUTOPILOT_LABEL } = require('../lib/envelope.js');

const SUBJECT = /\b(?:yes|choice|answer)\b/gi;
const MEMORY = /\b(?:remember(?:ed)?|saved|stored|kept)\b/gi;
const DURATION = /\b(?:for|to|through|throughout|during|over)\s+the\s+rest\s+of\s+(?:this|the)\s+session\b/gi;
const SESSION_SCOPE = /\b(?:this|the)\s+session\b/i;
const REQUEST_SCOPE = /\b(?:this|that|the|one)\s+request\b/i;
const NEGATION = /\b(?:not|never|cannot|no longer|nothing|none|neither|nor|rather than|instead of)\b|n['’]t\b/i;
const ASKED_AGAIN = /\b(?:won['’]t|will not|isn['’]t|is not|not|never)\s+(?:be\s+)?asked\s+again\b/gi;
const PICK = /\b(?:pick|picks|choose|chooses|select|selects|answer|answers|say|says)\s+[*_"'“‘]*(yes|no)\b/gi;
const ROUTE_CHANGE = /\/zensu:delivery-route\b/i;
const CLAUSE_BREAK = /[,;]|:(?=\s|$)/;
const LABEL_LEAD = /^[\s*_`"'“”‘’>•-]+/;
const LEAD_ONLY = /^\W*(?:(?:and|but|or|so|yet|then|however|although|though|even|because|since|as|if|when|once|unless|until|while|whilst|whereas|that|also|now|still|thus|therefore|hence|too|meanwhile|otherwise|instead|nevertheless|nonetheless|moreover|furthermore|besides|indeed|likewise)\b\W*)*$/i;
const NEW_CLAUSE = /\b(?:but|though|although|while|whilst|whereas|because)\b|\b(?:and|so|then|yet|since|as|once|when|if|unless|until)\s+(?=(?:it|its|this|that|you|your|the|a|an|there|zensu|i|we|they|my|our|their|no)\b)/i;
const NO_SUBJECT = /^\W*(?:(?:[Aa]|[Tt]he|[Yy]our)\s+)?["'“‘*_]*No\b/;
const HOLDING = /\b(?:remember(?:s|ed)?|sav(?:e|es|ed)|stor(?:e|es|ed)|keeps?|kept|record(?:s|ed)?|appl(?:y|ies|ied)|holds?|held|carr(?:y|ies|ied)|lasts?|stays?|remains?|persists?)\b/i;
const GAP = 80;

function affirmative(span) {
  return !ROUTE_CHANGE.test(span) && !NEGATION.test(span.replace(ASKED_AGAIN, ' '));
}

function spans(re, text) {
  return [...text.matchAll(re)].map((m) => ({ start: m.index, end: m.index + m[0].length }));
}

function clauseBefore(sentence, index) {
  return sentence.slice(0, index).split(CLAUSE_BREAK).pop();
}

function clauseAfter(sentence, index) {
  return sentence.slice(index).split(CLAUSE_BREAK)[0];
}

function linked(sentence, from, to) {
  return to.start >= from.end && to.start - from.end <= GAP && affirmative(sentence.slice(from.end, to.start));
}

function unblocked(sentence, predicate) {
  return affirmative(clauseBefore(sentence, predicate.start)) && !ROUTE_CHANGE.test(sentence.slice(0, predicate.start));
}

function negatesHolding(clause) {
  return clause.replace(ASKED_AGAIN, ' ').split(NEW_CLAUSE).some((part, k) => {
    if (k > 0 && NO_SUBJECT.test(part)) return false;
    const negation = NEGATION.exec(part);
    return Boolean(negation) && HOLDING.test(part.slice(negation.index));
  });
}

function settled(sentence, duration) {
  const lead = clauseBefore(sentence, duration.start).split(SUBJECT).pop();
  if (!LEAD_ONLY.test(lead)) return true;
  const host = sentence.slice(duration.end).split(CLAUSE_BREAK).find((clause) => !LEAD_ONLY.test(clause));
  return !negatesHolding(host || '');
}

function memoryHolds(sentence, memory) {
  const after = clauseAfter(sentence, memory.end);
  return unblocked(sentence, memory) && affirmative(after.split(SESSION_SCOPE)[0]) && !REQUEST_SCOPE.test(after);
}

function pickedNo(sentence, subject) {
  const picks = [...sentence.slice(0, subject.end + 6).matchAll(PICK)];
  return picks.length > 0 && picks[picks.length - 1][1].toLowerCase() === 'no';
}

function joined(sentence, subject, predicate) {
  if (linked(sentence, subject, predicate)) return true;
  return linked(sentence, predicate, subject) && affirmative(clauseAfter(sentence, subject.end));
}

function startsWith(segment, label) {
  const match = label.exec(segment.replace(LABEL_LEAD, ''));
  return Boolean(match) && match.index === 0;
}

function disclosesYes(sentence, tied) {
  const subjects = spans(SUBJECT, sentence).filter((s) => !pickedNo(sentence, s));
  const memories = spans(MEMORY, sentence).filter((m) => memoryHolds(sentence, m));
  const durations = spans(DURATION, sentence).filter((d) => unblocked(sentence, d) && settled(sentence, d));
  const predicates = [...memories, ...durations];
  if (subjects.some((s) => predicates.some((p) => joined(sentence, s, p)))) return true;
  return tied && (durations.length > 0 || memories.some((m) => SESSION_SCOPE.test(clauseAfter(sentence, m.end))));
}

function remembersYes(text) {
  const segments = String(text || '').split('|');
  return segments.some((segment, i) => {
    const tied = i > 0 && startsWith(segments[i - 1], YES_LABEL) && ![YES_LABEL, NO_LABEL, AUTOPILOT_LABEL].some((label) => startsWith(segment, label));
    return segment.split(/(?<=[.!?;])\s+|\n+/).some((sentence) => disclosesYes(sentence, tied));
  });
}

const NEEDLES = [
  ['the Yes label', YES_LABEL],
  ['the No label', NO_LABEL],
  ['a Yes is remembered for the session', { test: remembersYes }],
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
