'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const MODULE = path.resolve(__dirname, '../../hooks/lib/zensu-cli-words-v1.js');
const words = require(MODULE);

test('the search skips every flag and the word a flag without = takes, an empty word, and stops at --', () => {
  const cases = [
    [['features', 'create'], ['features', 'create']],
    [['--api-url', 'https://h', 'features', 'create'], ['features', 'create']],
    [['features', '--product', 'p1', 'create', '--title', 'T'], ['features', 'create']],
    [['-p', 'p1', 'features', 'create'], ['features', 'create']],
    [['--product=p1', 'features', 'create'], ['features', 'create']],
    [['-p=p1', 'features'], ['features']],
    [['-abc', 'features', 'create'], ['features', 'create']],
    [['-', 'features'], ['features']],
    [['---x', 'value', 'features'], ['features']],
    [['', 'features', '', 'create'], ['features', 'create']],
    [['--', 'features', 'create'], []],
    [['features', '--', 'create'], ['features']],
    [['work', '--product', 'p1', 'policy', 'set'], ['work', 'policy', 'set']],
    [['work', 'policy', 'set', 'extra'], ['work', 'policy', 'set']],
    [['features', '--title'], ['features']],
    [['--title'], []],
    [[], []],
  ];
  for (const [args, expected] of cases) {
    const before = args.slice();
    assert.deepEqual(words.commandWords(args), expected, JSON.stringify(args));
    assert.deepEqual(args, before, JSON.stringify(args));
  }
});

test('the search returns at most three plain words, in input order, for any input', () => {
  const alphabet = ['--', '-', '', '-p', '-p=1', '--x', '--x=1', '-ab', '---y', 'a', 'b', 'features', 'work', 'policy'];
  let seed = 20261021;
  const next = () => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed;
  };
  for (let round = 0; round < 5000; round += 1) {
    const args = Array.from({ length: next() % 9 }, () => alphabet[next() % alphabet.length]);
    const found = words.commandWords(args);
    assert.ok(found.length <= 3, JSON.stringify(args));
    let from = 0;
    for (const word of found) {
      assert.ok(word !== '' && !word.startsWith('-'), JSON.stringify(args));
      const at = args.indexOf(word, from);
      assert.ok(at >= from, JSON.stringify(args));
      from = at + 1;
    }
  }
});

test('a noun is canonical or empty, and every alias names a canonical noun', () => {
  assert.deepEqual([...words.NOUNS], [
    'products', 'features', 'subfeatures', 'roadmap', 'tiers', 'security', 'journeys', 'mocks', 'design', 'link',
    'ghost', 'wiki', 'doc', 'knowledge', 'pulse', 'ai-work', 'work', 'plan', 'meta', 'org', 'auth',
  ]);
  assert.deepEqual({ ...words.NOUN_ALIASES }, {
    product: 'products',
    feature: 'features',
    subfeature: 'subfeatures',
    roadmaps: 'roadmap',
    tier: 'tiers',
    sec: 'security',
    journey: 'journeys',
    mock: 'mocks',
    docs: 'doc',
    kb: 'knowledge',
    'wiki-pages': 'wiki',
  });
  for (const [alias, noun] of Object.entries(words.NOUN_ALIASES)) {
    assert.ok(words.NOUNS.includes(noun), alias);
    assert.ok(!words.NOUNS.includes(alias), alias);
    assert.equal(words.commandNoun(alias), noun);
  }
  for (const noun of words.NOUNS) assert.equal(words.commandNoun(noun), noun);
  for (const word of ['api', 'Features', '', 'constructor', '__proto__', 'toString', undefined, null]) {
    assert.equal(words.commandNoun(word), '', String(word));
  }
});

test('the work verb alias reads repos as repositories, and no other noun has a verb alias', () => {
  assert.deepEqual(Object.keys(words.VERB_ALIASES), ['work']);
  assert.deepEqual({ ...words.VERB_ALIASES.work }, { repos: 'repositories' });
  assert.equal(words.commandVerb('work', 'repos'), 'repositories');
  assert.equal(words.commandVerb('work', 'repositories'), 'repositories');
  assert.equal(words.commandVerb('work', 'list'), 'list');
  assert.equal(words.commandVerb('work', undefined), undefined);
  assert.equal(words.commandVerb('plan', 'repos'), 'repos');
  assert.equal(words.commandVerb('features', 'repos'), 'repos');
  assert.equal(words.commandVerb('', 'repos'), 'repos');
  assert.equal(words.commandVerb('work', 'constructor'), 'constructor');
});

test('a group is a verb whose third word picks the command, under either spelling of the verb', () => {
  assert.deepEqual(Object.fromEntries(Object.entries(words.GROUPS).map(([noun, verbs]) => [noun, [...verbs]])), {
    work: ['policy', 'repositories'],
    plan: ['followup'],
    wiki: ['images'],
  });
  for (const [noun, verb] of [['work', 'policy'], ['work', 'repositories'], ['work', 'repos'], ['plan', 'followup'], ['wiki', 'images']]) {
    assert.equal(words.isGroup(noun, verb), true, `${noun} ${verb}`);
  }
  for (const [noun, verb] of [['plan', 'followups'], ['work', 'list'], ['work', ''], ['features', 'policy'], ['plan', 'repos'], ['wiki', 'image'], ['wiki', 'list'], ['', ''], ['work', undefined]]) {
    assert.equal(words.isGroup(noun, verb), false, `${noun} ${verb}`);
  }
});

test('the tables are frozen, so no caller can widen or narrow the rule', () => {
  for (const table of [words.NOUNS, words.NOUN_ALIASES, words.VERB_ALIASES, words.VERB_ALIASES.work, words.GROUPS, words.GROUPS.work, words.GROUPS.plan, words.GROUPS.wiki]) {
    assert.ok(Object.isFrozen(table));
  }
  assert.throws(() => { words.NOUN_ALIASES.wo = 'work'; }, TypeError);
  assert.equal(words.commandNoun('wo'), '');
});
