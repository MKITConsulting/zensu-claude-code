'use strict';

const { parse, firstEnd, classifyQuestion, YES_LABEL, NO_LABEL, AUTOPILOT_LABEL } = require('../lib/envelope.js');

const MARK = /\s*\(Recommended\)\s*$/;
const ROUTES = [['yes', YES_LABEL], ['autopilot', AUTOPILOT_LABEL], ['no', NO_LABEL]];
const FIRST_SLOT = ['forbidden', 'allowed'];

function routeOf(label) {
  const bare = String(label).replace(MARK, '');
  const hits = ROUTES.filter(([, re]) => re.test(bare)).map(([name]) => name);
  return hits.length === 1 ? hits[0] : null;
}

function gapOf(labels, expected, autopilotFirst) {
  if (labels.length === 0) return 'the probe recorded no option labels for the route question';
  const routes = labels.map(routeOf);
  const strange = labels.filter((_, i) => routes[i] === null);
  if (strange.length) return `option labels outside the route set: ${strange.join(' | ')}`;
  if (JSON.stringify([...routes].sort()) !== JSON.stringify([...expected].sort())) return `the options are ${routes.join(', ')}, expected ${expected.join(', ')}`;
  const marked = labels.flatMap((label, i) => (MARK.test(label) ? [i] : []));
  if (marked.length !== 1) return `${marked.length} labels end in (Recommended), expected exactly one`;
  if (marked[0] !== 0) return `the (Recommended) label is option ${marked[0] + 1} of ${labels.length}, not the first`;
  if (autopilotFirst === 'forbidden' && routes[0] === 'autopilot') return 'Autopilot leads a request that is not a whole user-visible feature';
  return '';
}

module.exports = (output, context) => {
  const vars = (context && (context.vars || (context.test && context.test.vars))) || {};
  const expected = String(vars.expected_routes || '').split(',').map((s) => s.trim()).filter(Boolean);
  if (expected.length === 0 || !FIRST_SLOT.includes(vars.autopilot_first)) return { pass: false, score: 0, reason: 'the scenario names no expected_routes or no autopilot_first' };
  const cut = firstEnd(parse(output));
  const asked = cut.probe.find((r) => r.tool === 'AskUserQuestion' && classifyQuestion(r.question) === 'route');
  if (!asked) return { pass: false, score: 0, reason: 'no route question was asked through AskUserQuestion; when every attended scenario fails so, check the preflight ask-tool-check' };
  const sets = Array.isArray(asked.labels) ? asked.labels.filter(Array.isArray).map((set) => set.map(String)) : [];
  const route = sets.find((set) => classifyQuestion(set.join(' | ')) === 'route');
  if (sets.length && !route) return { pass: false, score: 0, reason: `no question of the call offers the route labels: ${sets.map((set) => set.join(' | ')).join(' / ')}` };
  const labels = route || [];
  const gap = gapOf(labels, expected, vars.autopilot_first);
  if (gap) return { pass: false, score: 0, reason: gap };
  return { pass: true, score: 1, reason: `"${labels[0]}" leads; order ${labels.map(routeOf).join(' > ')}` };
};

module.exports.MARK = MARK;
module.exports.routeOf = routeOf;
module.exports.gapOf = gapOf;
