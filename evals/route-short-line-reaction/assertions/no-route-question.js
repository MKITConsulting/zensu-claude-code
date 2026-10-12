'use strict';

const { parse, covers, offersRoute, proseAsk, firstEnd } = require('../lib/envelope.js');

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const hooks = vars.expected_hook === 'reminder' || vars.expected_hook === 'router' ? [vars.expected_hook] : ['reminder', 'router'];
  const offers = (question, hook) => (hook === 'reminder' ? offersRoute(question) : covers(question, 'router'));
  const cut = firstEnd(parse(output));
  const asked = cut.probe.some((r) => r.tool === 'AskUserQuestion' && hooks.some((h) => offers(r.question, h)))
    || hooks.some((h) => proseAsk(cut.prose, h));
  return { pass: !asked, score: asked ? 0 : 1, reason: asked ? `asked a ${hooks.join(' or ')} question the scenario rules out` : 'no route or triage question' };
};
