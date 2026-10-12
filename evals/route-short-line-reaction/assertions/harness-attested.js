'use strict';

const { parse } = require('../lib/envelope.js');

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const e = parse(output);
  const fail = (reason) => ({ pass: false, score: 0, reason });
  if (e.headerCount !== 1) return fail(`expected one attestation header, found ${e.headerCount}`);
  if (!e.attestation) return fail('no [wrapper_attestation] record after the header');
  if (e.attestation.init_git !== true) return fail('the wrapper did not run the immutable git fixture');
  if (!e.capture) return fail('no [route-eval-capture] record after the attestation');
  if (e.capture.route_source !== vars.route_source) return fail(`the capture says ${e.capture.route_source}, the scenario says ${vars.route_source}`);
  const live = e.capture.live || {};
  if (live.leaks !== 0 || !(live.control_chars > 0) || !(live.silent_hooks > 0)) return fail(`the installed runtime was not proven silent: ${JSON.stringify(e.capture.live || null)}`);
  if (vars.router_fires === 'yes' && !(live.router_control_chars > 0)) return fail('the installed intent router gave nothing on this message without the eval config, so its silence under the config proves nothing');
  return { pass: true, score: 1, reason: `attested; installed runtime ${live.version} silent across ${live.silent_hooks} prompt hooks` };
};
