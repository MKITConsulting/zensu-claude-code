'use strict';

const { parse, pairs, covers, proseAsk, LOOK_TOOLS } = require('../lib/envelope.js');

module.exports = (output) => {
  const e = parse(output);
  const map = pairs(e);
  let triage = null;
  for (const b of e.blocks) {
    if (b.kind === 'text' && proseAsk(b.text, 'router')) { triage = b; break; }
    if (b.kind === 'tool_use' && b.name === 'AskUserQuestion') {
      const r = map.get(b);
      if (r && covers(r.question, 'router')) { triage = b; break; }
    }
  }
  if (!triage) return { pass: false, score: 0, reason: 'no triage question (is the code built, is there a plan or spec, does it hold unbuilt items) was asked' };
  const setup = (b) => { const r = map.get(b); return Boolean(r && r.decision === 'SETUP'); };
  const earlier = e.blocks.find((b) => b.kind === 'tool_use' && b.line < triage.line && !setup(b) && (LOOK_TOOLS.includes(b.name) || b.name === 'AskUserQuestion'));
  if (earlier) return { pass: false, score: 0, reason: `${earlier.name} ran before the triage question` };
  const later = triage.kind === 'text' ? e.blocks.find((b) => b.kind === 'tool_use' && b.line > triage.line && LOOK_TOOLS.includes(b.name) && !setup(b)) : null;
  if (later) return { pass: false, score: 0, reason: `${later.name} ran after the triage question, so the model looked for the answers instead of leaving them to the user` };
  return { pass: true, score: 1, reason: 'the triage came before any file read or search and was left for the user to answer' };
};
