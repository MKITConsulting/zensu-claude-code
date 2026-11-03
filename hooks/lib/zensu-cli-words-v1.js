'use strict';

const COMMAND_DEPTH = 3;
const NOUNS = Object.freeze([
  'products', 'features', 'subfeatures', 'roadmap', 'tiers', 'security', 'journeys', 'mocks', 'design', 'link',
  'ghost', 'wiki', 'doc', 'knowledge', 'pulse', 'ai-work', 'work', 'plan', 'meta', 'org', 'auth',
]);
const NOUN_ALIASES = Object.freeze({
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
const VERB_ALIASES = Object.freeze({
  work: Object.freeze({ repos: 'repositories' }),
});
const GROUPS = Object.freeze({
  work: Object.freeze(['policy', 'repositories']),
  plan: Object.freeze(['followup']),
});

const NOUN_LOOKUP = new Map([...NOUNS.map((noun) => [noun, noun]), ...Object.entries(NOUN_ALIASES)]);
const VERB_LOOKUP = new Map(Object.entries(VERB_ALIASES).map(([noun, aliases]) => [noun, new Map(Object.entries(aliases))]));
const GROUP_LOOKUP = new Map(Object.entries(GROUPS).map(([noun, verbs]) => [noun, new Set(verbs)]));

function takesNextWord(word) {
  return !word.includes('=') && (word.length === 2 || word[1] === '-');
}

function commandWords(args) {
  const words = [];
  for (let index = 0; index < args.length && words.length < COMMAND_DEPTH; index += 1) {
    const word = args[index];
    if (word === '--') break;
    if (word === '') continue;
    if (word.startsWith('-')) {
      if (takesNextWord(word)) index += 1;
      continue;
    }
    words.push(word);
  }
  return words;
}

function commandNoun(word) {
  return NOUN_LOOKUP.get(word) || '';
}

function commandVerb(noun, word) {
  const aliases = VERB_LOOKUP.get(noun);
  return (aliases && aliases.get(word)) || word;
}

function isGroup(noun, verb) {
  const verbs = GROUP_LOOKUP.get(noun);
  return Boolean(verbs && verbs.has(commandVerb(noun, verb)));
}

module.exports = {
  GROUPS,
  NOUNS,
  NOUN_ALIASES,
  VERB_ALIASES,
  commandNoun,
  commandVerb,
  commandWords,
  isGroup,
};
