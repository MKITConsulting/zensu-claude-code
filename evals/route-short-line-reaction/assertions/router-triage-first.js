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
  const look = e.blocks.find((b) => b.kind === 'tool_use' && LOOK_TOOLS.includes(b.name) && b.line < triage.line && !setup(b));
  if (look) return { pass: false, score: 0, reason: `${look.name} ran before the triage question` };
  return { pass: true, score: 1, reason: 'the triage came before any file read or search' };
};
