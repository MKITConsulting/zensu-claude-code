'use strict';

const { parse, decisiveAt, classifyQuestion } = require('../lib/envelope.js');
const { MUTATION } = require('../lib/decision-probe.js');

module.exports = (output) => {
  const e = parse(output);
  const first = decisiveAt(e.probe, 0, e.attestation && e.attestation.root);
  let got = first.value;
  if (got === 'ask') got = `ask:${classifyQuestion(first.record.question)}`;
  if (got === 'other:Bash' && MUTATION.test(String(first.record.command || ''))) got = 'zensu-mutation';
  if (got.startsWith('skill:zensu:') || got === 'ask:route' || got === 'ask:triage' || got === 'delegate' || got === 'zensu-mutation') {
    return { pass: false, score: 0, reason: `with nothing injected the first decisive action is a route action: ${got}` };
  }
  const named = (got.startsWith('other:') || got === 'edit-outside') && first.record;
  const detail = named ? ` (${String(first.record.part || first.record.command || first.record.path || '').slice(0, 160)})` : '';
  return { pass: true, score: 1, reason: `route-neutral; edit-first baseline ${got === 'edit' ? 'yes' : 'no'}: first decisive action ${got}${detail}` };
};
