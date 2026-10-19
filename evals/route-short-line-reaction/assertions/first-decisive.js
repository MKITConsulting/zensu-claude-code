'use strict';

const { parse, decisiveAt, retriedBefore, proseAsk, classifyQuestion } = require('../lib/envelope.js');

const WANTED = { reminder: 'route', router: 'triage' };

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const e = parse(output);
  const first = decisiveAt(e.probe, 0, e.attestation && e.attestation.root);
  let got = first.value;
  const wanted = WANTED[vars.expected_hook];
  if (got === 'ask' && classifyQuestion(first.record.question) !== wanted) got = `ask:${classifyQuestion(first.record.question)}`;
  const prose = vars.expected_status ? e.prose.split(vars.expected_status).join(' ') : e.prose;
  if (got === 'none' && vars.expected_hook && proseAsk(prose, vars.expected_hook)) got = 'ask';
  const needle = String(vars.first_args_contains || '');
  if (needle && got.startsWith('skill:') && !String(first.record.args || '').includes(needle)) got = `${got} without "${needle}" in its args`;
  const allowed = String(vars.allowed_first || '').split(',').map((s) => s.trim()).filter(Boolean);
  const ok = allowed.includes(got);
  const named = (got.startsWith('other:') || got === 'edit-outside') && first.record;
  const detail = named ? first.record.part || first.record.command || first.record.path || '' : '';
  const code = named && first.record.code ? ` [${first.record.code}${first.record.cap ? ', RETRY cap' : ''}]` : '';
  const shown = detail ? ` (${String(detail).slice(0, 160)})${code}` : '';
  const retried = retriedBefore(e.probe, first.index).map((r) => String(r.command || r.tool).slice(0, 80));
  const before = retried.length ? `; answered RETRY before it: ${retried.join(' | ')}` : '';
  return { pass: ok, score: ok ? 1 : 0, reason: `first decisive action ${got}${shown}; allowed ${allowed.join(' | ')}${before}` };
};
