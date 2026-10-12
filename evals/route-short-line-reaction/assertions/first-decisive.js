'use strict';

const { parse, decisive, proseAsk } = require('../lib/envelope.js');

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const e = parse(output);
  let got = decisive(e.probe);
  if (got === 'none' && vars.expected_hook && proseAsk(e.prose, vars.expected_hook)) got = 'ask';
  const allowed = String(vars.allowed_first || '').split(',').map((s) => s.trim()).filter(Boolean);
  const ok = allowed.includes(got);
  return { pass: ok, score: ok ? 1 : 0, reason: `first decisive action ${got}; allowed ${allowed.join(' | ')}` };
};
