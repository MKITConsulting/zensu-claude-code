'use strict';

const { parse, openingLines } = require('../lib/envelope.js');

module.exports = (output) => {
  const e = parse(output);
  const nonce = e.capture && e.capture.nonce;
  if (!nonce) return { pass: false, score: 0, reason: 'the capture carries no nonce' };
  const lines = openingLines(e);
  const ok = lines.includes(nonce);
  const head = lines.length ? lines[lines.length - 1] : '';
  return { pass: ok, score: ok ? 1 : 0, reason: ok ? 'the injected directive reached the model' : `the opening line "${head.slice(0, 120)}" is not the injected nonce, so the hook channel did not deliver` };
};
