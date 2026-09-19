// Unit contract for the takeover-destination advice in
// skills/session-trail/scripts/trail.mjs — the whole EXPORTED advice surface plus the
// module-scope recipe constants it renders. Stated as the surface rather than as a list:
// the list said four while the file drove seven, and a roster that enumerates is a roster
// that goes stale on the next export.
//
// These are functions of a plain record. They do not open files and they write nothing; the
// one filesystem contact is `whereAdviceLines`, which canonicalizes two paths through
// `canonicalPair` to decide whether the taker is standing in the source worktree and falls back
// to the lexical spelling when either does not resolve. Say that rather than "no I/O" — the
// retired wording was false once `whereAdviceLines` joined the surface. Every property
// below was previously graded only end to end: each arm assertion in
// test-session-trail-verdict.sh costs two node spawns and can reach the array
// only through a JSON payload. Two branches had no executed case ANYWHERE for
// want of a seam — `adviceBlock`'s `firstPrefix`-on-a-leading-command arm, and
// an empty or single-line input.
//
// Driven from test-session-trail-verdict.sh, because tests/run-all.sh discovers
// only test-*.sh and would never execute a bare *.test.js.

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const mod = await import(new URL('../../skills/session-trail/scripts/trail.mjs', import.meta.url));

// A present-directory record with no live process and no desktop-app record.
// The arms read exactly four fields, so the fixture carries exactly four.
const rec = (over = {}) => ({ app: null, live: null, ccdStore: true, cwdExists: true, ...over });

const commands = (lines) => lines.filter((l) => mod.WORKTREE_ADVICE_COMMAND.test(l));

// Which fence ordinal a needle lands in; null when it is outside every fence.
// Mirrors `fence_of` in test-session-trail-verdict.sh so the two layers grade the
// same property in the same terms — with one deliberate difference: the OPENING
// fence is matched by `includes`, not by `trim().startsWith`. `adviceBlock` puts
// `firstPrefix` on that line when the array opens with a command, so a `- ` bullet
// sits ahead of the backticks and a prefix-anchored match silently finds no fence
// at all. The closing line carries only `indent`, so it stays anchored.
function fenceOf(rendered, needle) {
  let n = 0;
  let inside = false;
  for (const line of rendered) {
    if (!inside && line.includes('```bash')) { n += 1; inside = true; continue; }
    if (inside && line.trim() === '```') { inside = false; continue; }
    if (inside && line.includes(needle)) return n;
  }
  return null;
}

// Named for what it CHECKS. The property "the CLI does not run on import" is enforced by
// `if (isEntryPoint()) main();` and is not observable from these three assertions — two
// review rounds flagged the old name as overclaiming, so it states the surface instead.
test('the module exposes its advice surface as named exports', () => {
  assert.equal(typeof mod.worktreeAdvice, 'function');
  assert.equal(typeof mod.adviceBlock, 'function');
  assert.ok(mod.WORKTREE_ADVICE_COMMAND instanceof RegExp);
});

test('WORKTREE_ADVICE_COMMAND accepts exactly two spaces and rejects every other lead', () => {
  assert.equal(mod.WORKTREE_ADVICE_COMMAND.test('  git status'), true);
  assert.equal(mod.WORKTREE_ADVICE_COMMAND.test('  PATCH="$(mktemp)"'), true);
  assert.equal(mod.WORKTREE_ADVICE_COMMAND.test('git status'), false);
  assert.equal(mod.WORKTREE_ADVICE_COMMAND.test(' git status'), false);
  assert.equal(mod.WORKTREE_ADVICE_COMMAND.test('   git status'), false);
  assert.equal(mod.WORKTREE_ADVICE_COMMAND.test('\tgit status'), false);
  assert.equal(mod.WORKTREE_ADVICE_COMMAND.test('  '), false);
});

test('adviceBlock coalesces a contiguous command run into ONE fence', () => {
  const out = mod.adviceBlock(['lead', '  one', '  two', '  three', 'tail'], '   ', '   ', { carrier: 'markdown' });
  assert.equal(out.filter((l) => l.trim().startsWith('```bash')).length, 1);
  assert.equal(fenceOf(out, 'one'), 1);
  assert.equal(fenceOf(out, 'two'), 1);
  assert.equal(fenceOf(out, 'three'), 1);
});

test('adviceBlock splits a run broken by a column-zero prose line into TWO fences', () => {
  const out = mod.adviceBlock(['lead', '  one', 'read this first', '  two'], '   ', '   ', { carrier: 'markdown' });
  assert.equal(out.filter((l) => l.trim().startsWith('```bash')).length, 2);
  assert.equal(fenceOf(out, 'one'), 1);
  assert.equal(fenceOf(out, 'two'), 2);
});

// The branch `adviceBlock`'s own comment calls dormant: no arm leads with a
// command today, so this is the only executed case it has anywhere. Pinned as an
// exact array rather than by searching for the fence, because the property IS the
// placement of `firstPrefix` on that one line.
test('adviceBlock puts firstPrefix on the fence when the array OPENS with a command', () => {
  assert.deepEqual(
    mod.adviceBlock(['  only'], '   ', '- ', { carrier: 'markdown' }),
    ['', '- ```bash', '   only', '   ```', ''],
  );
});

test('adviceBlock on an empty array returns an empty array', () => {
  assert.deepEqual(mod.adviceBlock([], '   ', '   ', { carrier: 'markdown' }), []);
});

test('adviceBlock on a single prose line prefixes it with firstPrefix and opens no fence', () => {
  const out = mod.adviceBlock(['just prose'], '   ', '- ', { carrier: 'markdown' });
  assert.deepEqual(out, ['- just prose']);
});

test('every arm routes the taker into a worktree of their own', () => {
  const arms = [
    rec({ app: { archived: true } }),
    rec({ app: { archived: true }, live: { pid: 4242 } }),
    rec({ app: { archived: false } }),
    rec(),
    rec({ app: { archived: true }, cwdExists: false }),
    rec({ app: { archived: true }, live: { pid: 4242 }, cwdExists: false }),
    rec({ app: { archived: false }, cwdExists: false }),
    rec({ cwdExists: false }),
  ];
  for (const r of arms) {
    const lines = mod.worktreeAdvice(r);
    assert.ok(Array.isArray(lines) && lines.length > 0);
    assert.ok(lines.some((l) => l.includes('git worktree add')), `no create recipe in ${JSON.stringify(lines[0])}`);
  }
});

test('a present arm carries the recipe and a gone arm carries none', () => {
  const present = commands(mod.worktreeAdvice(rec({ app: { archived: true } })));
  const gone = commands(mod.worktreeAdvice(rec({ app: { archived: true }, cwdExists: false })));
  assert.ok(present.length > gone.length);
  assert.equal(gone.length, 1);
});

// The recipe is pasted by a HUMAN who substitutes every placeholder by hand.
// `briefShellArg` exists for exactly this everywhere else in the file — its own
// header says single-quoting is what neutralizes `$( )`, `;`, `&&` and `|` — and an
// ordinary `~/My Projects/repo` splits the command in two without it.
test('every path placeholder in a runnable line is single-quoted', () => {
  const lines = commands(mod.worktreeAdvice(rec({ app: { archived: true } })));
  const unquoted = lines.filter((l) => /<(their worktree|your new worktree)>/.test(l)
    && !/'<(their worktree|your new worktree)>'/.test(l));
  assert.deepEqual(unquoted, [], 'a runnable line carries a bare placeholder');
  for (const l of lines) {
    assert.ok(!/-C <\w/.test(l), `unquoted -C operand: ${JSON.stringify(l)}`);
  }
});

// `grep -n "120000"` matched any content line holding those six characters —
// guaranteed noise here, because the same command passes `--binary` and base85
// payloads are drawn from an alphabet where a six-character run is common. A check
// that fires on ordinary patches is a check that gets trained away. `--stat` hides
// `100755` exactly as it hides `120000`, and an executable needs no follow-up copy
// step to bite.
test('the mode grep is anchored to patch header lines and covers the executable bit', () => {
  const lines = mod.worktreeAdvice(rec({ app: { archived: true } }));
  const grep = commands(lines).find((l) => l.includes('grep'));
  assert.ok(grep, 'no grep step in the recipe');
  assert.ok(grep.includes('^'), `the grep is unanchored: ${JSON.stringify(grep)}`);
  assert.ok(grep.includes('120000'), 'the grep no longer names the symlink mode');
  assert.ok(grep.includes('100755'), 'the grep does not name the executable mode');
  const prose = lines.join('\n');
  assert.ok(/do not run the apply/i.test(prose), 'the text never says what to do on a hit');
});

// The patch is a complete copy of every uncommitted change in a worktree the same
// text calls unvetted, and a FAILED apply keeps it on purpose. Nothing told the
// reader to remove it afterwards, and a failed apply is the likely case here: this
// recipe targets a tree the change itself argues is usually dirty.
test('the emitted recipe names the patch lifetime and gives the temp file a findable name', () => {
  const lines = mod.worktreeAdvice(rec({ app: { archived: true } }));
  const prose = lines.join('\n');
  assert.ok(/when you are done inspecting/i.test(prose), 'the text never says to delete the patch');
  assert.ok(prose.includes('rm -f "$PATCH"'), 'the removal is not spelled out');
  // The NAME, not the `-t` flag the review proposed: `mktemp -t <prefix>` is a BSD
  // spelling, and GNU coreutils reads `-t` as a deprecated template form that wants
  // trailing X's — so the proposed literal is unportable in a recipe a reader pastes
  // on whichever host they happen to be on. An explicit template is unambiguous on
  // both, and the property the finding actually asks for is that a leftover patch is
  // findable by name.
  const mktemp = commands(lines).find((l) => l.includes('mktemp'));
  assert.ok(mktemp.includes('session-trail-carryover'), `no findable temp name: ${JSON.stringify(mktemp)}`);
  assert.ok(!/mktemp -t /.test(mktemp), `BSD-only \`mktemp -t\` spelling: ${JSON.stringify(mktemp)}`);
});

// `adviceBlock` coalesces a contiguous command run into ONE fence, which is what a
// copy button hands over in a single paste. The destructive apply therefore has to
// sit in a fence of its own: the `grep` and the `apply --stat` above it exist to be
// READ FIRST, and an argument about execution order only holds if the human stops
// between the third command and the fourth. A column-zero prose line breaks the run.
test('the destructive apply is not in the same paste unit as the steps that gate it', () => {
  const rendered = mod.adviceBlock(mod.worktreeAdvice(rec({ app: { archived: true } })), '   ', '   ', { carrier: 'markdown' });
  const gate = fenceOf(rendered, 'apply --stat');
  const grep = fenceOf(rendered, 'grep -nE');
  const destructive = fenceOf(rendered, 'apply "$PATCH"');
  assert.ok(gate !== null && grep !== null && destructive !== null,
    `a carry-over command is outside every fence (grep=${grep} stat=${gate} apply=${destructive})`);
  assert.equal(grep, gate, 'the two reading steps were split from each other');
  assert.notEqual(destructive, gate, 'the destructive apply shares a fence with the steps that gate it');
  assert.ok(destructive > gate, 'the destructive apply must come after the steps that gate it');
});

// `test -L` is a SYMLINK test, not a regular-file test: a hard link to a file
// outside the worktree is a regular file, so `test -L` is false and `cp` reads the
// content anyway — the very outcome the caution exists to prevent. FIFOs, device
// nodes and sockets pass it too. The pair that encodes the rule is
// `[ -f "$f" ] && [ ! -L "$f" ]`, and the step has to be runnable, because the
// obvious improvisation from prose word-splits on a filename with a space.
test('the untracked copy step is runnable and tests both -f and ! -L', () => {
  const lines = mod.worktreeAdvice(rec({ app: { archived: true } }));
  const body = commands(lines).join('\n');
  assert.ok(body.includes('-f "$s"'), 'no regular-file test in the copy step');
  assert.ok(body.includes('! -L "$s"'), 'no symlink exclusion in the copy step');
  assert.ok(/ls-files --others --exclude-standard -z/.test(body), 'the listing is not NUL-delimited');
  assert.ok(/read -r -d ''/.test(body), 'the copy step is not a NUL-safe read loop');
});

// The one bar anywhere for deciding whether to run the recipe AT ALL lived only in
// SKILL.md, which the model reads. The array below is what lands in a persisted
// brief a HUMAN opens and pastes from, and it stated the threat model and then went
// straight into the commands. The stop-condition belongs with whoever executes.
// EXACT COUNTS, not presence, and that is the whole repair. Keyed on presence of
// `do not run this at all` this case went vacuous for a round: the move alternative acquired
// a paragraph carrying the same words, both arrays render on the present leg, and deleting
// `CARRY_OVER`'s escape outright left the assert green. Re-pointing the needle fixed the
// INSTANCE and left the CLASS open — it discriminated again only by the accidental absence of
// a second carrier. A count of 1 makes uniqueness structural: a second carrier reddens
// immediately instead of silently absorbing the check. Same idiom as the exact-count asserts
// on the SKIPPED diagnostics further down, and for the same stated reason.
// THREE conjuncts, because the sentence spans three clauses across two array elements and
// each can be deleted alone: the CONDITION that triggers the stop, the stop itself, and the
// alternative it names. An earlier comment here claimed the needle was "the WHOLE escape
// sentence" while it pinned only the closing clause — so the trigger could be deleted and an
// unconditional stop clause would ship into the brief a human pastes from.
test('the emitted recipe carries the do-not-run-this-at-all escape', () => {
  const prose = mod.worktreeAdvice(rec({ app: { archived: true } })).join('\n');
  const count = (re) => (prose.match(re) || []).length;
  assert.equal(count(/copy the files across by hand instead/gi), 1,
    'the escape alternative is missing, or acquired a second carrier and can no longer say which array lost it');
  assert.equal(count(/do not run this at all/gi), 1,
    'the stop clause is missing, or acquired a second carrier');
  // `a worktree you would not cd into`, not the bare `would not cd into`: the move
  // alternative legitimately carries its own stop condition on the same tree, phrased `a tree
  // you would not cd into`. The count caught that on the first run, which is the point — the
  // bare form has two emitted carriers and would have been ambiguous from the day it was
  // written. The second source occurrence is a code comment and never reaches the array.
  assert.equal(count(/a worktree you would not cd into/gi), 1,
    'the condition that triggers the stop is missing, or acquired a second carrier');
});

// The recipe's first step SNAPSHOTS a working tree another agent may be editing, and
// the splice was unconditional across all four present arms. The state where nothing
// warned: `cwdExists` true, a live pid registered, `archived !== true` — the arm falls
// through to the unreadable or the plain-active lead, neither of which names the pid,
// so the reader got a full "snapshot the source tree" recipe with no signal that the
// source is live. Applied into the taker's worktree, a mid-edit diff lands a state
// neither tree ever had. The file already measures this; the advice never consulted it.
test('a live process gets a snapshot caution before the tree-reading recipe', () => {
  const lines = mod.worktreeAdvice(rec({ app: { archived: false }, live: { pid: 4242 } }));
  const text = lines.join('\n');
  assert.ok(text.includes('4242'), 'the live pid is never named on this arm');
  const cautionAt = lines.findIndex((l) => /snapshot/i.test(l));
  const recipeAt = lines.findIndex((l) => l.includes('PATCH="$(mktemp'));
  assert.ok(cautionAt !== -1, 'no snapshot caution anywhere on a live arm');
  assert.ok(recipeAt !== -1, 'the fixture arm carries no carry-over recipe at all');
  assert.ok(cautionAt < recipeAt, 'the caution does not precede the step it is about');
});

// The negative control. Without it the case above is satisfied by an unconditional
// splice — which is the shape it exists to reject.
test('an arm with no live process carries no snapshot caution', () => {
  const dead = mod.worktreeAdvice(rec({ app: { archived: false } })).join('\n');
  assert.ok(!/snapshot/i.test(dead), 'the live-only caution leaked onto a dead arm');
});

// The lead welded three independent observations — an archive flag, no live pid, and
// `dirExists` false — into a CAUSAL claim the predicate never measured. A deleted
// subdirectory, a rename, an unmounted volume and an unreadable parent all produce the
// same state, and `dirExists` is a `statSync` in a try/catch, so it answers false for
// every one of them.
test('the archived gone-leg lead reports what was observed, not why', () => {
  const text = mod.worktreeAdvice(rec({ app: { archived: true }, cwdExists: false })).join('\n');
  assert.ok(!/archiving removed it/i.test(text), 'the lead still asserts a cause it never measured');
  assert.ok(/archived/i.test(text), 'the lead no longer reports the archive flag');
  assert.ok(/not readable|no live pid/i.test(text), 'the lead reports neither of the other two observations');
});

// The gone leg said, in the same array: "only the branch survived, so there is nothing
// left to carry across" and then "the recorded path was a SUBDIRECTORY of a root that
// still exists". If the second is true the first is false — the root is on disk with
// its uncommitted work intact, and only the recorded subdirectory is missing.
test('the gone leg does not deny surviving work and then point at a surviving root', () => {
  for (const archived of [true, false, null]) {
    const lines = mod.worktreeAdvice(rec({ app: archived === null ? null : { archived }, cwdExists: false }));
    const text = lines.join('\n');
    assert.ok(!/nothing left to carry across/i.test(text),
      `the gone leg still asserts nothing survived (archived=${archived})`);
    assert.ok(/cannot run against it as printed/i.test(text),
      `the gone leg does not state what was actually measured (archived=${archived})`);
    assert.ok(/SUBDIRECTORY of a root that still exists/.test(text),
      `the gone leg dropped the surviving-root remedy (archived=${archived})`);
  }
});

// The gone leg used to order a substitution for `<their worktree>` — the token the
// carry-over recipe is built around — and to say the recipe "DOES apply" against a
// surviving root. No carrier renders that recipe on this leg: `worktreeAdvice` returns
// before the `...CARRY_OVER` spread, `cmdShow`'s pointer to the verbs that would print
// it is gated on the PRESENT leg, and `recipePlaceholders` scans COMMAND lines only, so
// a token named in prose never enters the printed substitution rule. The reader was
// therefore told to substitute a third token four lines under a rule block that had just
// finished naming two. The control is the other half of the same fact and is what keeps
// this from passing on a body that lost the recipe everywhere: the PRESENT leg carries
// that token in a runnable line, so the needle is live.
test('the gone leg orders no substitution into a recipe no carrier prints there', () => {
  const present = mod.worktreeAdvice(rec({ app: { archived: true } }));
  assert.ok(commands(present).some((l) => l.includes('<their worktree>')),
    'the present leg no longer carries the recipe token, so this needle proves nothing');
  for (const archived of [true, false, null]) {
    const lines = mod.worktreeAdvice(rec({ app: archived === null ? null : { archived }, cwdExists: false }));
    const text = lines.join('\n');
    assert.ok(!text.includes('<their worktree>'),
      `the gone leg still names the recipe's own placeholder (archived=${archived})`);
    assert.ok(/prints no carry-over recipe at all/.test(text),
      `the gone leg does not say the recipe is absent here (archived=${archived})`);
  }
  // The same claim, one carrier over. `whereAdviceLines` passes an EMPTY mapping on this leg
  // — the head's own labelled value is there to be read, not pasted — so a head sentence
  // telling the reader what "the advice below substitutes" describes a substitution that does
  // not happen. It survived the body fix because it lives in a different function; the pinned
  // read-not-paste and re-quote needles are unaffected and stay in the sibling case below.
  const goneHead = whereHead(mod.whereAdviceLines(whereRow({ cwdExists: false }), null));
  assert.ok(!/substitutes/.test(goneHead),
    `the gone-leg head still claims the advice below substitutes something:\n${goneHead}`);
});

// `cmdShow` prints every advice line into a SURVEY view with a nine-space prefix and
// no fence. The array grew from roughly six lines to sixty, so `show` — the command
// whose value is that you can scan it — started dumping a paste-and-run recipe into
// the middle of its output. The recipe's home is the persisted brief, which is what a
// human actually pastes from; `show` keeps the decision and points at the brief.
test('the survey form drops the carry-over recipe and the brief form keeps it', () => {
  const r = rec({ app: { archived: true } });
  const full = mod.worktreeAdvice(r);
  const noRecipe = mod.worktreeAdvice(r, { carryOver: false });
  assert.ok(full.some((l) => l.includes('PATCH="$(mktemp')), 'the full advice lost the recipe');
  assert.ok(!noRecipe.some((l) => l.includes('PATCH="$(mktemp')), 'carryOver:false still carries the recipe');
  assert.ok(noRecipe.some((l) => l.includes('git worktree add')), 'carryOver:false lost the create recipe');
  assert.ok(noRecipe.length < full.length, 'carryOver:false is not shorter than the full one');
});

// TWO axes, and the second one needs its own case because the first cannot stand in for it.
// The move alternative is withheld from the survey for a DIFFERENT reason than the recipe —
// the recipe is bulk, the route is a decision that must not be offered without the cost
// paragraph qualifying it — and while it rode the `carryOver` flag every assertion in the
// case above stayed true if the block were hoisted above the early return, because
// `CARRY_OVER` alone keeps the full form longer. Nothing in either suite would have seen it.
test('the survey form drops the move alternative and the brief form keeps it', () => {
  const r = rec({ app: { archived: true } });
  const full = mod.worktreeAdvice(r);
  const survey = mod.worktreeAdvice(r, { carryOver: false, move: false });
  assert.ok(full.some((l) => l.includes('worktree move')), 'the full advice lost the move alternative');
  assert.ok(!survey.some((l) => l.includes('worktree move')), 'the survey form leaked the move alternative');
  assert.ok(survey.some((l) => l.includes('git worktree add')), 'the survey form lost the create recipe');
});

// The axes are INDEPENDENT, which is the whole point of splitting them: dropping the
// migration half must not drop the decision half with it. A single flag could never fail
// this, which is why it is a case rather than a comment.
test('dropping the carry-over recipe alone keeps the move alternative', () => {
  const r = rec({ app: { archived: true } });
  const only = mod.worktreeAdvice(r, { carryOver: false });
  assert.ok(only.some((l) => l.includes('worktree move')), 'carryOver:false also dropped the move route');
  assert.ok(!only.some((l) => l.includes('PATCH="$(mktemp')), 'carryOver:false kept the recipe');
});

// The two routes must never share a fence, and until this case nothing held that.
// `MOVE_ALTERNATIVE`'s own header declares the separation load-bearing, and what produces
// it is the ELEVEN column-zero prose lines between the two commands — two closing ones from
// `TAKE_YOUR_OWN` and nine leading ones from `MOVE_ALTERNATIVE`. MEASURED: deleting either
// run alone leaves the fences split, and deleting both collapses them into one (create=1
// move=1), which is one copy button that creates the taker's worktree and then relocates
// the source session's out from under it. So this case catches the condense-the-advice
// edit and not a one-sided trim; the sibling ordering case below is what holds the leading
// run on its own. Every other move needle in both suites tests PRESENCE, never which paste
// unit the line lands in, so both edits were green everywhere.
//
// The relation is `create < move`, never a bare `notEqual`, and that is the ORDER contract
// rather than a tighter spelling of the same one. `worktreeAdvice`'s own splice comment says
// the create route is first because it is the default and needs no judgement from the reader;
// three emitted sentences then depend on it — `take the create route above instead`, `the
// -b claude/<name>-cont fork above is not needed`, and `the create recipe above stays the
// default`. Transposing the two spliced arrays leaves them in separate fences either way, so
// `notEqual` passes while the destructive route is offered ahead of the default and all three
// `above` sentences become false. `create < move` subsumes the separation at no extra cost.
test('the create route and the move alternative are not in the same paste unit', () => {
  const rendered = mod.adviceBlock(mod.worktreeAdvice(rec({ app: { archived: true } })), '   ', '   ', { carrier: 'markdown' });
  const create = fenceOf(rendered, "worktree add '<path>' -b");
  const move = fenceOf(rendered, "worktree move '<their worktree>'");
  assert.ok(create !== null && move !== null,
    `a route command is outside every fence (create=${create} move=${move})`);
  assert.ok(create < move,
    `the destructive move route is not offered after the default create route (create=${create} move=${move})`);
});

// The move's stop condition has to be READ before the command, for the reason the emitted
// text itself gives: one fenced command is one copy button, so a caution printed after it
// is read after it has run. The snapshot-caution case above pins the same property for the
// carry-over recipe; this is the move's own, and neither stands in for the other because
// the two arms are spliced independently.
test('the move alternative states its stop condition before the command', () => {
  const lines = mod.worktreeAdvice(rec({ app: { archived: true } }));
  const stopAt = lines.findIndex((l) => l.includes('take the create route above instead'));
  const moveAt = lines.findIndex((l) => l.includes("worktree move '<their worktree>'"));
  assert.ok(stopAt !== -1, 'the move alternative carries no stop condition at all');
  assert.ok(moveAt !== -1, 'the fixture arm carries no move alternative at all');
  assert.ok(stopAt < moveAt, 'the stop condition does not precede the command it is about');
});

// `movePid` derives from `livePid` rather than re-spelling its predicate, and what it tests
// is that function's SENTINEL — `'?'`, the value `livePid` answers for anything that is not
// a positive integer. Every other `live` fixture in this file is `null` or a real pid, so
// the sentinel branch had no executed case at any layer and the guard could only be read,
// never run. That matters because the branch decides whether a line labelled MEASURED is
// emitted at all: with the guard gone, an unresolvable pid renders `pid ? was registered and
// alive for that worktree` into a brief a different session opens later — a measurement
// claim with no measurement behind it. The case drives the BRANCH and not the literal, so a
// rename of `livePid`'s fallback cannot slip past it.
test('an unresolvable pid renders no MEASURED line in the move route', () => {
  const unresolvable = mod.worktreeAdvice(rec({ app: { archived: false }, live: { pid: null } }));
  const text = unresolvable.join('\n');
  assert.ok(text.includes('worktree move'), 'the fixture arm carries no move alternative at all');
  assert.ok(!text.includes('was registered and alive for that worktree'),
    'the move route claims a MEASURED pid it could not resolve');
  // The asymmetry the derivation deliberately keeps: the snapshot caution still renders the
  // sentinel, because there it qualifies a tree-reading recipe rather than asserting a
  // measurement. Without this half the case would pass against a build that dropped the
  // caution's pid entirely, which is a different defect wearing the same green.
  assert.ok(text.includes('pid ?'), 'the live snapshot caution stopped naming the pid slot');
  // The positive control, so the two assertions above cannot both pass vacuously: a real pid
  // DOES reach the MEASURED line on the same arm.
  const resolvable = mod.worktreeAdvice(rec({ app: { archived: false }, live: { pid: 4242 } })).join('\n');
  assert.ok(resolvable.includes('pid 4242 was registered and alive for that worktree'),
    'a resolvable pid no longer reaches the move route at all');
});

// `whereAdviceLines` DERIVES both its route sentence and its `<your new worktree>` claim from
// the body it renders. Without a narrowed body nothing distinguishes those derivations from
// hardcoded constants — the single production caller passes no options, so `hasMove` and
// `hasNewWorktree` are `true` on every reachable path and `const hasMove = true` would pass
// every other check in both suites. This is the one input that separates them.
test('the WHERE head derives its route sentences from the body it actually renders', () => {
  // `whereRow()` rather than `rec()`: this renderer reads `row.wt` through `briefShellArg`,
  // which `rec()` does not supply. Its declaration sits further down the file and resolves by
  // the time a registered case runs, which is how every sibling `whereAdviceLines` case works.
  const r = whereRow({ app: { archived: true } });
  const full = mod.whereAdviceLines(r, '/tmp/taker-worktree').join('\n');
  const narrowed = mod.whereAdviceLines(r, '/tmp/taker-worktree', { move: false, carryOver: false }).join('\n');
  assert.ok(full.includes('On the move route instead'), 'the full head lost its route sentence');
  assert.ok(full.includes('<your new worktree>'), 'the full head lost its carry-over operand claim');
  assert.ok(!narrowed.includes('On the move route instead'), 'the narrowed head announces a route its body does not carry');
  assert.ok(!narrowed.includes('<your new worktree>'), 'the narrowed head names an operand its body does not render');
  assert.ok(narrowed.includes('git worktree add'), 'the narrowed head lost the create route it still carries');
});

// The gone leg has no carry-over half at all, so the option must change nothing there
// — otherwise `show` and the briefs would disagree about an arm where there is nothing
// to disagree about.
test('the survey form is identical to the brief form on a gone arm', () => {
  const r = rec({ app: { archived: true }, cwdExists: false });
  assert.deepEqual(mod.worktreeAdvice(r, { carryOver: false }), mod.worktreeAdvice(r));
});

// MEASURED, and it is why the first wording of this recipe was wrong: a hard link is a
// second directory entry for a regular FILE, so `[ -f ]` is true and `[ ! -L ]` is true
// and it passes BOTH halves. (Probe: `ln outside.txt hard.txt` then the pair — hard.txt
// passes, link count 2.) The pair excludes symlinks, FIFOs, device nodes and sockets and
// nothing else, so the text may not offer the hard link as a reason the pair suffices.
test('the copy step does not claim the pair excludes a hard link', () => {
  const prose = mod.worktreeAdvice(rec({ app: { archived: true } })).join('\n');
  assert.ok(!/\[ ! -L \] alone lets a HARD LINK through/.test(prose),
    'the text still offers the hard link as the reason both predicates are needed');
  // ANCHORED on the disclosure sentence, not on two common words. `hard link` has two emitted
  // carriers and `residual` five, all inside `CARRY_OVER`, so the conjunction stayed green
  // with the one sentence this case exists to pin deleted — the same one-literal-several-
  // suppliers class the escape case above records, live in this same file.
  assert.equal((prose.match(/A HARD LINK is an ACCEPTED RESIDUAL/g) || []).length, 1,
    'the hard link is not disclosed as an accepted residual, or the disclosure has a second carrier');
});

// MEASURED against git 2.51.0: a tracked symlink whose TARGET is repointed produces
// `index 62c2b6a..e6c46ff 120000` and NO mode header, so a header-only pattern is silent
// on the one case where `git apply` rewrites a link in the taker's tree. A mode FLIP
// (`100644` -> `100755`) and a new symlink do carry headers.
test('the mode grep also matches the index line, where a repointed symlink carries its mode', () => {
  const grep = commands(mod.worktreeAdvice(rec({ app: { archived: true } }))).find((l) => l.includes('grep'));
  assert.ok(/\^index /.test(grep), `the grep cannot see a repointed symlink: ${JSON.stringify(grep)}`);
  assert.ok(grep.includes('120000'), 'the symlink mode is no longer named');
  assert.ok(grep.includes('100755'), 'the executable mode is no longer named');
});

// UNIVERSAL over placeholders, not existential over lines. `SRC='…' DST='…'` carries two
// placeholders on ONE line, so an existential check is satisfied by the first one while
// the second goes bare. Both `git worktree add` lines carry a `<path>` operand too, and
// the property is stated in three carriers as covering EVERY placeholder.
// The property is that a placeholder sits INSIDE a single-quoted region, not that it is
// wrapped in a quote pair of its own: `'claude/<name>-cont'` is correctly quoted, and
// insisting on `'<name>'` would reject it. Splitting on the quote character gives the two
// regions exactly — odd segments are inside, even segments are outside — which makes this
// a universal over PLACEHOLDERS rather than an existential over lines. That distinction is
// load-bearing here: `SRC='…' DST='…'` carries two placeholders on ONE line, so a check
// satisfied by any single quoted occurrence would pass with the second one bare.
const unquotedPlaceholders = (line) => line
  .split("'")
  .filter((_, i) => i % 2 === 0)
  .join(' ')
  .match(/<[a-z][a-z -]*>/g) || [];

test('every placeholder in every runnable line is single-quoted, counted not sampled', () => {
  for (const cwdExists of [true, false]) {
    for (const l of commands(mod.worktreeAdvice(rec({ app: { archived: true }, cwdExists })))) {
      assert.deepEqual(unquotedPlaceholders(l), [],
        `placeholder(s) outside the quoting: ${JSON.stringify(l)}`);
    }
  }
});

// The OPERATOR is the rule. Asserting the two predicates independently over a joined body
// passes when `&&` becomes `||`, which short-circuits on `-f` — following the symlink the
// caution exists to stop.
test('the copy step spells the conjunction on one line', () => {
  const lines = commands(mod.worktreeAdvice(rec({ app: { archived: true } })));
  assert.ok(lines.some((l) => l.includes('[ -f "$s" ] && [ ! -L "$s" ]')),
    'the two predicates are no longer conjoined on one line');
});

// The diagnostic prints a filename out of a repository this same text calls unvetted.
// `echo` interprets backslash escapes in dash and under bash's xpg_echo, so a plain-ASCII
// name can scroll the SKIPPED list away — and that list is what tells the reader which
// entries the safety test rejected.
test('the copy step reports a skipped entry through printf, not echo', () => {
  const body = commands(mod.worktreeAdvice(rec({ app: { archived: true } }))).join('\n');
  assert.ok(!/\becho "SKIPPED/.test(body), 'the skip diagnostic still goes through echo');
  assert.ok(/printf 'SKIPPED/.test(body), 'the skip diagnostic does not use printf');
});

// MEASURED: command substitution strips every trailing newline, so `$(dirname "$f")` on a
// directory literally named `d<NL>` yields `d` and creates the WRONG parent — defeating the
// newline safety `-z` and the NUL-delimited read are there to provide.
test('the copy step derives the parent without a command substitution', () => {
  const body = commands(mod.worktreeAdvice(rec({ app: { archived: true } }))).join('\n');
  assert.ok(!/\$\(dirname/.test(body), 'the parent is still derived through $(dirname …)');
});

// The loop guards the SOURCE leaf and wrote through whatever `$DST/<parent>` happened to
// be: `mkdir -p` succeeds on an existing symlink-to-directory and `cp` follows it.
test('the copy step refuses a symlinked destination parent', () => {
  const body = commands(mod.worktreeAdvice(rec({ app: { archived: true } }))).join('\n');
  assert.ok(/! -L "\$DST/.test(body), 'nothing checks the destination parent');
});

// `adviceBlock` fences a contiguous run, so a prose line inserted anywhere inside the copy
// loop publishes `while … do` in one bash fence and its `done` in another — a paste unit
// that cannot run. Nothing graded that, because every fence assertion named the four apply
// commands.
test('the copy loop renders as ONE fence, opener and closer together', () => {
  const rendered = mod.adviceBlock(mod.worktreeAdvice(rec({ app: { archived: true } })), '   ', '   ', { carrier: 'markdown' });
  const open = fenceOf(rendered, 'while IFS=');
  const close = fenceOf(rendered, 'done');
  assert.ok(open !== null && close !== null, `the loop is outside a fence (while=${open} done=${close})`);
  assert.equal(open, close, 'the copy loop was split across two fences');
});

// The other half of `unreadableWhy`, which no fixture at any layer reaches: the shell
// suite's `archive()` helper creates the desktop store before any WT8 fixture is graded,
// so `r.ccdStore` is true throughout it.
test('an absent desktop-app store gets its own wording', () => {
  const withStore = mod.worktreeAdvice(rec({ ccdStore: true })).join('\n');
  const noStore = mod.worktreeAdvice(rec({ ccdStore: false })).join('\n');
  assert.ok(withStore.includes('has no record for this session'), 'the has-a-store wording moved');
  assert.ok(noStore.includes('no desktop-app record store exists on this host'),
    'the absent-store wording is never rendered');
});

// MEASURED: `\037` is octal 31, so the class `\000-\037` spans bytes 0-31 and INCLUDES the
// line feed at `\012` — `printf 'x %s\n' one two | tr -d '\000-\037'` emits `x onex two`
// with no separator at all. The diagnostic that was hardened to stop a crafted filename
// forging rows lost the very boundary that delimits them. The range must skip `\012`.
// The bound belongs on the OPERAND, not on the line. Bounding the whole line forced a
// carve-out for `\012` — and that carve-out re-admitted the one control byte the attacker
// controls: a filename holding a newline then prints a second line indistinguishable from a
// genuine rejection. Bounding `$f` into `$n` and letting printf supply the terminator closes
// both. MEASURED: a name spelled `evil<LF>SKIPPED (not a regular file): .env` collapses to
// one row.
test('the skip diagnostics bound the filename, not the whole line', () => {
  const lines = commands(mod.worktreeAdvice(rec({ app: { archived: true } })));
  const body = lines.join('\n');
  assert.ok(/n=\$\(printf '%s' "\$f" \| tr -d '\\000-\\037\\177'\)/.test(body),
    'the untrusted filename is never bounded into its own variable');
  const skips = lines.filter((l) => l.includes('SKIPPED ('));
  assert.equal(skips.length, 6, `expected six skip diagnostics, got ${skips.length}`);
  for (const l of skips) {
    assert.ok(/printf 'SKIPPED \([^']*\): %s\\n' "\$n"/.test(l),
      `a diagnostic does not print the bounded name: ${JSON.stringify(l)}`);
    assert.ok(!/\| tr -d/.test(l), `a diagnostic still bounds the whole line: ${JSON.stringify(l)}`);
  }
});

// MEASURED: `cp -- src dst` where dst is a symlink to a file OUTSIDE the tree overwrites
// that outside file (probe: outside.txt held "original", held "PAYLOAD" afterwards). The
// round-1 guard covered the destination PARENT and left the leaf unguarded.
test('the copy step refuses a symlinked destination file', () => {
  const body = commands(mod.worktreeAdvice(rec({ app: { archived: true } }))).join('\n');
  assert.ok(/! -L "\$DST\/\$f"/.test(body), 'nothing checks the destination leaf');
});

// MEASURED, twice: `[ ! -L "$DST/$d" ]` lstats the WHOLE path, so for d='a/b' a symlinked
// `a` is followed and the test is false — the escape passes. And for a root-level entry
// the derivation yields d='.', where the test can never be true. A component check cannot
// express this; containment of the RESOLVED parent can.
// The COMPARISON, not two syntax fragments. Grading only `cd -P -- "$DST"` and
// `case "$p/" in` leaves two mutations green: a `*)` first arm makes containment
// unconditional, and dropping the guard on the `DSTR=` assignment leaves `$DSTR` empty, so
// the pattern degrades to `/*` and every absolute path is "inside". Both literals are
// asserted exactly. `CDPATH=` is part of it: `cd` consults CDPATH for a relative operand and
// PRINTS the resolved path, which the command substitution would then capture — measuring a
// tree the following `mkdir`/`cp`, which never consult CDPATH, do not touch.
test('the copy step verifies the resolved destination stays inside the new worktree', () => {
  const body = commands(mod.worktreeAdvice(rec({ app: { archived: true } }))).join('\n');
  assert.ok(body.includes('DSTR=$(CDPATH= cd -P -- "$DST" && pwd -P) &&'),
    'the destination root is not resolved CDPATH-proof, or its failure does not stop the loop');
  assert.ok(body.includes('p=$(CDPATH= cd -P -- "$DST/$d" 2>/dev/null && pwd -P)'),
    'the parent resolution is not CDPATH-proof');
  assert.ok(body.includes('case "$p/" in "$DSTR"/*) ;;'),
    'the resolved parent is not compared against the resolved root');
  assert.ok(!/! -L "\$DST\/\$d"/.test(body),
    'the ineffective per-component parent test is still there');
});

// `exit` in a recipe pasted into an interactive shell closes that shell — and with it the
// `$PATCH` variable the same recipe tells the reader to `rm -f` afterwards, leaving an
// unvetted patch in $TMPDIR under a name nobody can now spell. MEASURED that `a && b | c`
// parses as `a && (b | c)`, so chaining onto the pipeline gives the same abort with no exit.
test('the recipe never tells an interactive shell to exit', () => {
  const body = commands(mod.worktreeAdvice(rec({ app: { archived: true } }))).join('\n');
  assert.ok(!/\bexit\b/.test(body), 'the recipe still calls exit in a pasted block');
});

// Every rejection path prints, or the SKIPPED list is not the report the prose says it is —
// and `mkdir`'s and `cd`'s own stderr would carry the same attacker-supplied path unbounded.
// Selected on the STATEMENT, not on an operator spelling. The first version filtered on
// `|| continue`, which the recipe never writes — every rejection is `|| { …; continue; }` —
// so it matched nothing and could not see a silent drop written in the house idiom. The
// positive control is what keeps the selector from going inert again.
test('no rejection path drops an entry silently', () => {
  const lines = commands(mod.worktreeAdvice(rec({ app: { archived: true } })));
  const jumps = lines.filter((l) => /\bcontinue\b/.test(l));
  assert.equal(jumps.length, 7, `expected seven rejection paths, got ${jumps.length}`);
  const bare = jumps.filter((l) => !/SKIPPED \(|FAILED \(/.test(l));
  assert.deepEqual(bare, [], 'a rejection path skips an entry without reporting it');
});

// The recipe carries SIX skip diagnostics, so an existential check over a joined body
// passes with one of them reverted to `echo`.
test('every skip diagnostic uses printf, counted not sampled', () => {
  const lines = commands(mod.worktreeAdvice(rec({ app: { archived: true } })));
  const skips = lines.filter((l) => l.includes('SKIPPED ('));
  // EXACT, not a floor: a floor of two survived deleting one of the six diagnostics that
  // existed when it was written, with every other check green.
  assert.equal(skips.length, 6, `expected six skip diagnostics, got ${skips.length}`);
  for (const l of skips) {
    assert.ok(/printf 'SKIPPED \(/.test(l), `not a printf diagnostic: ${JSON.stringify(l)}`);
    assert.ok(!/echo\s+['"]?SKIPPED/.test(l), `still an echo diagnostic: ${JSON.stringify(l)}`);
  }
});

// `unquotedPlaceholders` treats even split segments as outside-quotes, which is only true
// while the line holds an EVEN number of apostrophes. One added `'` — the POSIX `'\''`
// idiom, a `don't` in a diagnostic — inverts the parity for the rest of that line and
// silently scores a bare placeholder as quoted. Grade the assumption instead of resting
// on it.
test('every runnable line holds a balanced number of quotes', () => {
  for (const cwdExists of [true, false]) {
    for (const l of commands(mod.worktreeAdvice(rec({ app: { archived: true }, cwdExists })))) {
      assert.equal((l.split("'").length - 1) % 2, 0,
        `odd number of apostrophes, so the quoted/unquoted split is unreliable: ${JSON.stringify(l)}`);
    }
  }
});

// The emitted rationale described the ROUND-2 spelling of the bound while the command four
// lines above it was the round-3 one — and the sentence was false about it: the shipped
// `tr -d '\000-\037\177'` is a SUPERSET of `\000-\037` and does delete LF, because the bound
// now sits on the filename and `printf`'s format supplies the terminator. Left standing, that
// sentence is an invitation to "repair" the command back into the `\012` carve-out that
// re-admitted the injectable byte.
test('the emitted rationale describes the bound the command actually uses', () => {
  // PROSE only. Joining the whole array let the `/CDPATH/` conjunct be satisfied by the
  // command lines that carry `CDPATH=`, which another case already pins exactly — so it
  // could never fail, and its message claimed something it did not test.
  const prose = mod.worktreeAdvice(rec({ app: { archived: true } }))
    .filter((l) => !mod.WORKTREE_ADVICE_COMMAND.test(l)).join('\n');
  assert.ok(!/deliberately SKIPS/.test(prose),
    'the rationale still claims a carve-out the command does not make');
  assert.ok(/bound sits on the FILENAME/i.test(prose) || /bounds the NAME/i.test(prose),
    'the rationale does not say where the bound sits');
  assert.ok(/CDPATH/.test(prose), 'the CDPATH decision is stated in SKILL.md and not here');
  assert.ok(/interactive shell/i.test(prose),
    'the reason the chain uses && rather than exit is stated in SKILL.md and not here');
});

// ONE decision, FIVE consumers — the same count `trail.mjs`'s own header and CLAUDE.md
// carry. The renderer test below (`no renderer re-derives the leg by hand`) enumerates only
// THREE of them; `whereAdviceLines` and `cmdAdopt` are the fourth and fifth, and both are graded
// by the derived-population check further down and by nothing else. This comment said FOUR for a
// round after `cmdAdopt` became a consumer in its own right, while the derived check five lines
// below already asserted the true five-set and therefore stayed green — the exact shape a
// hand-maintained census beside a derived one produces. `worktreeAdvice` picks its lead AND its
// body from it (those two drifted apart inside one function once, which is how a gone lead
// came to sit above a present body); `cmdShow` decides from the same answer whether to print
// its "TWO things are withheld here" (its anchor; the sentence after it is reworded whenever the withheld set changes) pointer, and
// it would otherwise print that pointer on an arm that emits no carry-over, which NO ARM
// asserts the absence of — the reason is the arm set and not the fixture set, and saying
// "no fixture renders a gone-leg `show`" was false in both halves: `SHOW_MD` in
// test-session-trail-verdict.sh is built from the `-0002` record, which that file's own
// comment labels the DIRECTORY-GONE leg, so the gone-leg render exists and it is the
// PRESENT-leg one that no `show` fixture covers; `printResume` decides whether to print its own copy of the gone-leg
// create command; and `whereAdviceLines`, which `cmdAdopt` renders, decides whether to emit the
// `'<their worktree>' = …` mapping line at all, the recorded path being the substitution
// value on the present leg only.
test('the leg decision has one implementation, and it answers both legs', () => {
  assert.equal(typeof mod.adviceLeg, 'function');
  assert.equal(mod.adviceLeg(rec()), 'present');
  assert.equal(mod.adviceLeg(rec({ cwdExists: false })), 'gone');
});

// The exported function agreeing with itself is not the property. What matters is that no
// leg-dependent RENDERER re-derives it: `worktreeAdvice` selected its LEAD through
// `adviceLeg` and its BODY through a hand-written `!r.cwdExists`, so a change to the
// function would have emitted a gone lead above a present body — the recorded directory
// declared unreadable, immediately followed by the recipe that reads it.
test('no renderer re-derives the leg by hand', () => {
  const src = fs.readFileSync(new URL('../../skills/session-trail/scripts/trail.mjs', import.meta.url), 'utf8');
  // COMMENTS ARE STRIPPED, as the three sibling whole-file walks in this file already do. This
  // one scanned raw source, so a future explanatory comment spelling `r.cwdExists` inside one of
  // these bodies would redden it for a reason unrelated to its contract — and `worktreeAdvice`'s
  // own header already discusses `cwdExists`, surviving only because it omits the `r.` prefix.
  const stripComments = (text) => text.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
  const body = (name, open) => {
    const i = src.indexOf(open);
    assert.ok(i !== -1, `${name} not found`);
    return stripComments(src.slice(i, src.indexOf('\n}\n', i)));
  };
  // `cmdShow` IS in this list now, and the exclusion it replaces is worth recording because it
  // went stale silently. It read `r.cwdExists` for the `!! MISSING` marker, so the blanket
  // predicate would have failed on correct code — and the narrow slice that stood in for it
  // started at the advice render, which put the marker OUTSIDE the graded region. Then the
  // round that gave `cmdShow` a complete WHERE head hoisted `adviceLeg(r)` into one local ~40
  // lines BELOW that marker, so one view derived the same fact twice, through two derivations,
  // and the scan was anchored past the first of them. The marker now renders from the hoisted
  // leg, `cmdShow` holds no `r.cwdExists` at all, and the blanket form is therefore available
  // — which is strictly stronger than a widened slice, because it needs no anchor to stay
  // correct as the function moves.
  for (const [name, open] of [
    ['worktreeAdvice', 'function worktreeAdvice(r, options = {}) {'],
    ['printResume', 'function printResume(r) {'],
    ['cmdShow', 'function cmdShow(opts) {'],
  ]) {
    assert.ok(!/r\.cwdExists/.test(body(name, open)),
      `${name} still derives the leg from r.cwdExists instead of adviceLeg`);
  }
  // The blanket list asserts ABSENCE and nothing else, so on its own it is satisfied by a
  // `cmdShow` that derives the leg some third way — or not at all. The positive half is what
  // the retired slice carried and must not be lost with it. The CALL, not the comparison:
  // `cmdShow` hoists the answer into one local, and pinning `adviceLeg(r) === 'present'` would
  // forbid that hoist rather than the hand-derivation.
  assert.ok(body('cmdShow', 'function cmdShow(opts) {').includes('adviceLeg(r)'),
    'cmdShow no longer takes its leg from adviceLeg');
});

// The population is DERIVED, not counted. "Five consumers" is asserted in prose in three
// carriers — this file, `trail.mjs`'s own header and CLAUDE.md — and the renderer scan above
// grades only renderers it NAMES, so a sixth consumer that uses `adviceLeg` correctly would
// leave all three prose copies stale with every check green. That is not hypothetical: it
// happened when `cmdAdopt` became the fifth, and this check passed throughout. Scanning the call sites and
// comparing the SET is the repo's own idiom for exactly this (`T36-control` derives its
// citation population by scanning both documents rather than counting its own rows).
//
// THREE directions, and only two of them are graded — say so rather than letting "two checks,
// two directions" read as coverage. This check catches a consumer ADDED through `adviceLeg`;
// the renderer scan above catches a NAMED renderer reverting to a hand-written `r.cwdExists`.
// What neither can see is a NEW renderer that hand-derives from `r.cwdExists` without ever
// calling `adviceLeg`: it is absent from this scan's set and absent from that scan's list. A
// blanket `cwdExists` scan cannot close it — the field is read legitimately in about a dozen
// status and display sites, which is why `cmdShow` is already excluded by hand above. The
// standing instruction is prose, in `trail.mjs`'s header and in CLAUDE.md: before adding a
// renderer that depends on the leg, grep `cwdExists`.
test('the adviceLeg consumer set is exactly the five the carriers name', () => {
  const src = fs.readFileSync(new URL('../../skills/session-trail/scripts/trail.mjs', import.meta.url), 'utf8');
  const lines = src.split('\n');
  // The walk STOPS at a column-zero `}`. Without that it never sees a function END, so a
  // module-scope call site resolves to whichever top-level `function` precedes it textually —
  // and `trail.mjs` really does put module-scope values between functions. MEASURED: a helper
  // planted between `worktreeAdvice`'s closing brace and `function adviceBlock(` was
  // attributed to `worktreeAdvice`, leaving the set unchanged and admitting a fourth consumer
  // silently. It is the same `}`-at-column-zero terminator the `body()` helper above relies on.
  const enclosing = (i) => {
    for (let j = i; j >= 0; j -= 1) {
      if (lines[j] === '}') return '(module scope)';
      const m = /^function ([A-Za-z0-9_]+)\s*\(/.exec(lines[j]);
      if (m) return m[1];
    }
    return '(module scope)';
  };
  const callers = new Set();
  lines.forEach((l, i) => {
    if (!l.includes('adviceLeg(')) return;
    if (/^function adviceLeg\b/.test(l) || l.trim().startsWith('//') || l.startsWith('export ')) return;
    callers.add(enclosing(i));
  });
  // `whereAdviceLines` joined with the adopt-advice route: it hands the renderer a placeholder
  // mapping on the PRESENT leg only, because that is the only leg where the recorded path IS
  // the substitution value. It is named here rather than `cmdAdopt` because the renderer was
  // extracted to module scope — the consumer is the FUNCTION that reads the leg, and this
  // walk attributes a site to its enclosing function.
  //
  // `cmdAdopt` is a consumer in its OWN right now: its failure payload names the leg, because
  // that is what tells a machine reader whether the recorded path may be substituted for
  // `'<their worktree>'` or is the one the body forbids substituting. Deriving that from
  // `row.cwdExists` at the payload would be the raw re-derivation this decision was extracted
  // to remove, and a gated key would make absence ambiguous against an older tool.
  assert.deepEqual([...callers].sort(), ['cmdAdopt', 'cmdShow', 'printResume', 'whereAdviceLines', 'worktreeAdvice'],
    'the adviceLeg consumer set moved — update the count and the roster in trail.mjs\'s header, '
    + 'in this file\'s header and in CLAUDE.md §"Takeover Destination" together');
});

// The `briefShellArg` CARRIER POPULATION, derived rather than counted. The census above
// `briefShellArg` in `trail.mjs` points HERE by name and states the same arithmetic this case
// asserts; before this walk existed, seven of the twelve carriers were held by that prose
// alone. The obvious `grep 'briefShellArg('` cannot close it either: TWO carriers interpolate
// a binding (`${S}`, `${T}`) and carry no call text at all, which is exactly how a future
// `const U = briefShellArg(…)` would hide a thirteenth. This walk resolves a binding back to
// its initializer, so it cannot.
//
// THE CASE TITLE IS A CROSS-FILE LITERAL, and it is PINNED from this side. That census quotes
// it verbatim to send a maintainer here, so an unpinned rename would leave the pointer naming
// a check the tree does not have. The title is therefore ONE literal here —
// `CENSUS_CASE_TITLE` names the case AND is the needle — and the fourth assertion below
// requires the census to still quote it. `TestContext.name` would spell it once more cheaply
// and is deliberately NOT used: it landed in Node v20.5.0 while CI pins a bare
// `node-version: 20`, so on 20.0-20.4 this case would fail for a version reason rather than a
// contract one, which is the shape this repo refuses.
//
// Describe the census by its ANCHOR rather than by quoting a sentence out of it,
// for the mirror reason: an earlier draft of this comment quoted two sentences from it that
// the same change then retired, leaving both greppable from nowhere.
//
// FOUR assertions, and each one is load-bearing on its own:
//   - the per-function ROSTER, which is what a twelfth carrier fails on;
//   - the per-CLASS split, which is the census's own (a)/(b)/(c) arithmetic — a carrier moved
//     between classes keeps the total at twelve and changes what the prose means;
//   - the BINDING half, which has no other control. Delete the `${name}` resolution and the
//     roster simply reads ten, a number a maintainer would "fix" by lowering the expectation.
//     Requiring that at least one carrier is reachable ONLY through a binding is what makes
//     the resolution load-bearing rather than decorative;
//   - the POINTER BACK, which closes the cross-file literal the paragraph above names.
//
// The enclosing walk is the one the `adviceLeg` consumer scan above uses, for the reason
// stated there: it STOPS at a column-zero `}`, so a module-scope site cannot be attributed to
// whichever `function` precedes it textually.
const CENSUS_CASE_TITLE = 'the briefShellArg carrier population is derived, and a twelfth carrier fails here';
test(CENSUS_CASE_TITLE, () => {
  const src = fs.readFileSync(new URL('../../skills/session-trail/scripts/trail.mjs', import.meta.url), 'utf8');
  const lines = src.split('\n');
  const enclosing = (i) => {
    for (let j = i; j >= 0; j -= 1) {
      if (lines[j] === '}') return '(module scope)';
      const m = /^function ([A-Za-z0-9_]+)\s*\(/.exec(lines[j]);
      if (m) return m[1];
    }
    return '(module scope)';
  };
  const isComment = (l) => l.trim().startsWith('//');
  // A binding is an initializer, never a carrier itself: the value is not pasted at this
  // line. Its USES are the carriers, and they are what the second pass collects.
  const bindings = new Map();
  lines.forEach((l, i) => {
    const m = /^\s*const ([A-Za-z0-9_]+) = briefShellArg\(/.exec(l);
    if (m && !isComment(l)) bindings.set(m[1], i);
  });
  assert.ok(bindings.size > 0,
    'no `const <name> = briefShellArg(...)` binding found — the binding half of this walk is vacuous');
  const bindingLines = new Set(bindings.values());
  const carriers = [];
  lines.forEach((l, i) => {
    if (isComment(l)) return;
    if (/^function briefShellArg\b/.test(l)) return;
    if (bindingLines.has(i)) return;
    const direct = l.includes('briefShellArg(');
    // TWO spellings, because the mapping moved into `substitutionRuleLines` and took the
    // interpolated one with it. A bound value used to reach a rendered line as `${S}`; it now
    // reaches the renderer as a bare `S` inside a `['<token>', S]` pair. Recognizing only the
    // first made the binding half of this walk decorative — the assertion below says so in as
    // many words — and dropped two real carriers out of the census at the same time.
    const viaBinding = [...bindings.keys()].some((n) => l.includes('${' + n + '}')
      || new RegExp(',\\s*' + n + '\\s*\\]').test(l));
    if (!direct && !viaBinding) return;
    // The census's own three classes, decided from the rendered line. The MAPPING test runs
    // first: class (c) is the one shape that is not a runnable line at all, and one of its
    // members would otherwise read as class (a) for want of a `git -C`. It has TWO spellings
    // since the mapping moved into `substitutionRuleLines`: the rendered `'<token>' = value`
    // line the renderer emits, and the `['<token>', value]` PAIR a caller hands it. Recognizing
    // only the first left the one remaining caller-side mapping in the residual, which is the
    // class this split exists to keep empty.
    // Class (a) is EXPLICIT and the residual is named `UNCLASSIFIED`, because an implicit
    // residual is the shape this repository records as a defect elsewhere: a carrier of a
    // genuinely new kind — a `git --git-dir` form, a `tar -C` extraction, both of which the
    // skill prose already discusses — would land in (a) by default and the class assertion
    // would then report a MOVED member where a NEW class arrived, sending the maintainer to
    // reconcile the wrong prose. All five of today's (a) members carry `cd -- `.
    const cls = /'<[^']*>' = /.test(l) || /\['<[^']*>', /.test(l) ? 'c (placeholder mapping)'
      : l.includes('git -C ') ? 'b (operate on a worktree)'
        : /\bcd -- |claude --resume /.test(l) ? 'a (reach a worktree)'
          : 'UNCLASSIFIED';
    carriers.push({ line: i + 1, fn: enclosing(i), cls, onlyViaBinding: !direct && viaBinding });
  });
  // The binding walk recognizes ONE syntactic form, so a binding written any other way — a
  // two-line `const U =` / `  briefShellArg(…)`, a `var`, a value returned from a helper —
  // leaves its `${U}` USES uncollected while the binding line itself is miscounted as a direct
  // carrier. This assertion is deliberately INDEPENDENT of `carriers`: an earlier spelling
  // walked the same four-way filter the carrier loop applies and then excluded every line that
  // loop had pushed, which made it tautologically empty and unable to fail at all. What it
  // compares instead is the STRICT binding form against a LOOSE one, so a shape the strict form
  // misses is named rather than silently reclassified. The loose pattern cannot match a direct
  // carrier: those interpolate as `= ${briefShellArg(`, with `${` between the operator and the
  // call.
  //
  // BOUND, stated rather than implied: this is a SINGLE-LINE scan, so it sees a `let`, a `var`,
  // an unusual spacing or a reassignment — and it does NOT see a two-line initializer
  // (`const U =` then `briefShellArg(…)`) or a value returned from a helper, because neither
  // puts the operator and the call on one line. Those two surface instead as a changed
  // per-function roster below, whose message says to update the census; a maintainer meeting
  // them there should widen the binding form rather than lower that expectation.
  //
  // Counted against `strictBindings.length`, NOT `bindings.size`: the map is keyed by NAME, so
  // two same-named bindings in different functions — `const S = briefShellArg(…)` in two
  // renderers — would collapse to one entry and report an initializer form that does not exist.
  const strictBindings = [];
  const looseBindings = [];
  lines.forEach((l, i) => {
    if (isComment(l) || /^function briefShellArg\b/.test(l)) return;
    if (/^\s*const ([A-Za-z0-9_]+) = briefShellArg\(/.test(l)) strictBindings.push(i);
    if (/=\s*briefShellArg\(/.test(l)) looseBindings.push(`  trail.mjs:${i + 1}  ${l.trim()}`);
  });
  assert.equal(looseBindings.length, strictBindings.length,
    'a briefShellArg binding uses an initializer form this walk does not recognize, so its '
    + '${name} uses are collected as nothing — widen the binding regex:\n' + looseBindings.join('\n'));
  const table = carriers.map((c) => `  trail.mjs:${c.line}  ${c.cls}  ${c.fn}${c.onlyViaBinding ? '  (via binding)' : ''}`).join('\n');
  const tally = (key) => carriers.reduce((acc, c) => { acc[c[key]] = (acc[c[key]] || 0) + 1; return acc; }, {});
  // The ROSTER, per enclosing function, and the expectation object below is the ONLY statement
  // of the count that can fail — this sentence is derived from it, never the other way round.
  // A previous spelling here said `continuationPlan` carries SEVEN and the census "moved from
  // six to twelve", while the object said six and the roster sums to eleven; the case title
  // still said a THIRTEENTH carrier fails, where at eleven it is a twelfth. That is the lagging
  // prose copy the owner comment above `briefShellArg` in `trail.mjs` forbids in as many words,
  // reproduced in the file that owns the derivation. Read the object, not a numeral.
  assert.deepEqual(tally('fn'), {
    continuationPlan: 6, printResume: 2, cmdTakeover: 1, cmdHandoff: 1, whereAdviceLines: 1,
  }, 'the briefShellArg carrier roster moved — update the census above `briefShellArg` in '
    + 'trail.mjs and this expectation together:\n' + table);
  assert.equal(tally('cls').UNCLASSIFIED, undefined,
    'a briefShellArg carrier matches none of the three classes — it is a NEW kind rather than '
    + 'a moved member, so widen the classifier and the census prose together rather than '
    + 'reconciling the split below:\n' + table);
  assert.deepEqual(tally('cls'), {
    // Class (c) fell from three to TWO when `substitutionRuleLines` took over emitting the
    // mapping line. `continuationPlan` used to render two mapping lines of its own; it hands
    // the renderer ONE pair literal now, carrying both values, so two carriers on two lines
    // became one carrier on one. The other member is `whereAdviceLines`'s own pair, whose
    // value is an inline `briefShellArg(row.wt)` rather than a binding.
    'a (reach a worktree)': 5, 'b (operate on a worktree)': 4, 'c (placeholder mapping)': 2,
  }, 'the briefShellArg CLASS split moved — this expectation is the only statement of it, '
    + 'because the census in trail.mjs deliberately carries the classification RULE and no '
    + 'numerals:\n' + table);
  // The roster and class assertions above already fail on a deleted `${name}` resolution:
  // dropping it takes `continuationPlan` to five and class (c) to one, and both run first. So
  // this one can never be what REPORTS the deletion, and saying it "has no other control" was
  // an over-claim. What it guards is the maintainer's RESPONSE — lowering those two
  // expectations to match rather than restoring the resolution — which is worth guarding and
  // is a different thing. Leaving the over-claim in place is how the next reader concludes the
  // roster does not cover the binding half and duplicates it.
  assert.ok(carriers.some((c) => c.onlyViaBinding),
    'no carrier is reachable ONLY through a binding, so the binding resolution in this walk '
    + 'is now decorative and a `const U = briefShellArg(…)` could hide one:\n' + table);
  // The census states the classification RULE and no counts. A hand-maintained numeral beside
  // a derived scan is a lagging copy of it, and this one had already contradicted itself: the
  // block said SIX non-carriers in one sentence and SEVEN in the next, four lines apart, while
  // warning in between that the subtrahend moves whenever the paragraph is reworded.
  for (const stale of ['CHECKING IT BY GREP', 'subtract those seven', 'subtract those six']) {
    assert.equal(src.includes(stale), false,
      `the briefShellArg census still carries the hand-maintained grep arithmetic (${stale}) — `
      + 'the derived scan in this case is the control, and a numeral beside it only goes stale');
  }
  // The pointer back. The census sends a maintainer here by this case's exact title, so
  // without this a rename leaves that sentence naming a check the tree does not have — the
  // same drift class the census itself exists to prevent one level down.
  assert.ok(src.includes('`' + CENSUS_CASE_TITLE + '`'),
    'the briefShellArg census in trail.mjs no longer quotes this case by name — rename both '
    + 'together, or the census points at a check that does not exist');
});

test('every advice line is a two-space command or column-zero prose, on every arm', () => {
  const arms = [true, false, null].flatMap((archived) => [true, false].map((cwdExists) => rec({
    app: archived === null ? null : { archived }, cwdExists,
  })));
  for (const r of arms) {
    for (const line of mod.worktreeAdvice(r)) {
      const ok = mod.WORKTREE_ADVICE_COMMAND.test(line) || /^\S/.test(line);
      assert.ok(ok, `line is neither a two-space command nor column-zero prose: ${JSON.stringify(line)}`);
    }
  }
});

// `adopt`'s `WHERE` head was a closure inside `cmdAdopt`, so its pure leg logic was
// reachable only through the full CLI and was graded exclusively by two shell fixtures —
// one of which had to `rm -rf` a real worktree to reach the gone leg at all. Its three
// siblings are module-scope exported members of the same advice surface — two of them array
// producers, `adviceLeg` a string one; this one closed over exactly one
// variable and bought nothing a parameter would not. The taker's own worktree is a SECOND
// parameter rather than a second closure read, because the caution below is the one thing
// the head can say that depends on where the READER is standing.
const whereRow = (over = {}) => ({
  sessionId: 'sess-source-0000000000000000', wt: '/tmp/source-wt',
  app: null, live: null, ccdStore: true, cwdExists: true, ...over,
});

test('whereAdviceLines is exported and renders the head on both legs', () => {
  assert.equal(typeof mod.whereAdviceLines, 'function');
  const present = mod.whereAdviceLines(whereRow(), null);
  assert.ok(present[0].startsWith('WHERE    for '), `head: ${JSON.stringify(present[0])}`);
  assert.equal(present[0].includes('!! MISSING'), false);
  const gone = mod.whereAdviceLines(whereRow({ cwdExists: false }), null);
  assert.ok(gone[0].includes('!! MISSING'), `gone head: ${JSON.stringify(gone[0])}`);
});

// The HEAD is everything before the advice body. `adviceBlock` renders at the caller's
// two-space indent, so no line it produces can carry the head's eleven-space lead — which
// is what lets these cases assert on the head alone. Asserting on the joined output would
// find `<path>` and `<session-branch>` in `TAKE_YOUR_OWN` and pass while the head names
// neither, which is the exact defect P1 reported.
const whereHead = (out) => {
  const head = [];
  for (const l of out) {
    if (l.startsWith('WHERE') || l.startsWith('           ')) head.push(l);
    else break;
  }
  return head.join('\n');
};

test('the present-leg head names every unmapped placeholder and the receipt trap', () => {
  const head = whereHead(mod.whereAdviceLines(whereRow(), null));
  // The quoting rule is SPLIT, and that split is the correctness of it. `'<their worktree>'` is
  // replaced together with its quotes ONLY because the value rendered above it already carries
  // its own — two quoted words back to back join into one unquoted word. Every other
  // placeholder is a BARE token the reader supplies, so taking its quotes with it strips the
  // single-quoting this file calls its own neutralizer for `$( )`, `;`, `&&` and `|` — and
  // `<session-branch>` is foreign-derived, where `git check-ref-format` admits all four.
  assert.ok(head.includes("Replace '<their worktree>' TOGETHER WITH the quotes around it"),
    `the mapped token's substitution rule is missing:\n${head}`);
  assert.ok(head.includes('replace the token INSIDE the'),
    `the head tells the reader to strip the quoting from the placeholders they supply:\n${head}`);
  assert.ok(head.includes('LEAVE THE QUOTES THERE'), `no keep-the-quotes rule:\n${head}`);
  assert.equal(head.includes('Replace each placeholder TOGETHER WITH'), false);
  assert.equal(head.includes('Replace the placeholder'), false);
  for (const ph of ['<path>', '<name>', '<session-branch>', '<your new worktree>']) {
    assert.ok(head.includes(ph), `the head never names ${ph}:\n${head}`);
  }
  // The wrong antecedent the head exists to remove: the receipt line one step above prints
  // `worktree: <edge.to.worktree>`, which is the tree the reader is ALREADY in. Substituting
  // it for `<your new worktree>` applies another session's uncommitted diff over their own
  // live work, so the head has to name that trap rather than merely leave the operand blank.
  assert.ok(head.includes('NOT the worktree named on the receipt line above'),
    `the head does not warn against the receipt line's own worktree:\n${head}`);
  // `<name>` is the ONE placeholder the together-with-the-quotes rule does not govern: it sits
  // INSIDE `'claude/<name>-cont'` (TAKE_YOUR_OWN), so replacing the quoted token drops the
  // `claude/` prefix and the `-cont` suffix and produces an unquoted branch operand. The head
  // must carve it out rather than state the rule over all five.
  assert.ok(head.includes("write '\\'' for an apostrophe"),
    `the head prescribes four hand-substitutions into quoted operands and never names the '\\'' idiom:\n${head}`);
  // `<path>` and `<your new worktree>` are ONE directory under two spellings: the create line
  // writes `<path>` and every destructive step writes `<your new worktree>`. A reader supplying
  // two different values creates the tree in one place and applies the diff into another.
  assert.ok(head.includes('the same directory'),
    `the head does not say <path> and <your new worktree> are one directory:\n${head}`);
});

// Flow 5 step 6 documents a hand-resumed session, and a hand-resume lands the taker IN the
// source's worktree. From that moment the carry-over's first step snapshots the source's
// uncommitted work AND the taker's own, mixed — so "the carry-over half is still fully
// actionable" is not sound on the route the paragraph serves. `cmdAdopt` has both values in
// scope, so the head says so instead of leaving the reader to notice.
// The trigger is EQUALITY, not containment, and the reason is what the two operands ARE. Both
// are `worktreeRoot()` results, and that walk returns the nearest ancestor holding a `.git`
// entry — so a plain subdirectory of the source worktree collapses to the source worktree
// itself and equality already covers it. Containment-without-equality therefore requires the
// taker's root to carry its OWN `.git`, which means a separate linked worktree: this
// repository's own mandated continuation layout, `<main>/.claude/worktrees/<name>`. There the
// caution's sentence is false — the patch step reads `git -C '<their worktree>' … diff HEAD` in
// the MAIN tree, which does not see a separate worktree's uncommitted state — so containment
// bought no true positive and one false warning on the layout the skill recommends.
test('the head warns when the taker is standing in the source worktree', () => {
  const marker = 'You are standing IN that tree';
  const at = (taker) => whereHead(mod.whereAdviceLines(whereRow(), taker));
  assert.ok(at('/tmp/source-wt').includes(marker), `equal paths raise no caution:\n${at('/tmp/source-wt')}`);
  // A nested tree of the taker's OWN is not the source's worktree, and saying so was the
  // defect this arm used to pin as intended behaviour.
  assert.equal(at('/tmp/source-wt/sub').includes(marker), false);
  assert.equal(at('/tmp/other-wt').includes(marker), false);
  assert.equal(at('/tmp/source-wt-2').includes(marker), false);
  assert.equal(at(null).includes(marker), false);
  assert.equal(at('').includes(marker), false);
});

// Every arm of that ladder that CANNOT answer must SAY so. A falsy taker worktree used to take
// neither branch — no caution, no disclosure, nothing — which is precisely the outcome the
// GATE arm beside it exists to forbid: "a failed load must not silently change a verdict".
// It is not hypothetical. `cmdAdopt`'s own success receipt spells
// `flatPath(edge.to.worktree) || '(unknown)'`, so this change's code already admits the value
// it passes here can be empty, and `boundPath` in the ledger module returns null for a path
// over its length bound. The two unanswerable causes get DIFFERENT reasons on purpose: a
// reader who is told the module did not load goes looking at the installation, and a reader
// whose own worktree was never resolved has a different thing to check.
test('an unanswerable standing-in check discloses its own reason', () => {
  const marker = 'could not be checked here';
  for (const taker of [null, '', undefined]) {
    const head = whereHead(mod.whereAdviceLines(whereRow(), taker));
    assert.ok(head.includes(marker),
      `a falsy taker worktree emitted neither the caution nor a disclosure (${JSON.stringify(taker)}):\n${head}`);
    assert.ok(head.includes('was not resolved'),
      `the disclosure does not name the taker's own worktree as the missing operand:\n${head}`);
  }
  // The ANSWERABLE arm must not acquire a disclosure it does not need.
  const answered = whereHead(mod.whereAdviceLines(whereRow(), '/tmp/other-wt'));
  assert.equal(answered.includes(marker), false,
    `a resolvable comparison still disclosed that it could not be made:\n${answered}`);
});

// The CANONICALIZING branch, which every case above leaves unexercised: those paths do not
// exist, so `canonicalPair` takes its lexical fallback and the equality it reports is a string
// comparison. The property the design argument rests on is the other one — that two different
// SPELLINGS of one directory compare equal — and nothing proved it at any layer.
test('two spellings of one directory raise the standing-in-source caution', (t) => {
  let real;
  let link;
  try {
    real = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'wt-canon-')));
    link = path.join(path.dirname(real), `${path.basename(real)}-link`);
    fs.symlinkSync(real, link, 'dir');
  } catch {
    // A filesystem that refuses a symlink is an environment property, not a contract failure.
    t.skip('could not create a symlinked second spelling');
    return;
  }
  // The OTHER environment cause, which the guard above cannot see: this case needs
  // `canonicalPair`, and `canonicalPair` needs a usable gate module. Where that module is
  // missing the renderer takes its could-not-check arm, `standingIn` stays false, and the
  // assertion below would blame the filesystem for a module-load fault — pointing a maintainer
  // at the wrong component. Probe the renderer's own disclosure instead of guessing.
  if (whereHead(mod.whereAdviceLines(whereRow(), '/tmp/other-wt')).includes('could not be checked here')) {
    t.skip('the path-comparison module is not usable here, so this case cannot measure canonicalPair');
    try { fs.unlinkSync(link); } catch { /* best effort */ }
    try { fs.rmSync(real, { recursive: true, force: true }); } catch { /* best effort */ }
    return;
  }
  try {
    const head = whereHead(mod.whereAdviceLines(whereRow({ wt: real }), link));
    assert.ok(head.includes('You are standing IN that tree'),
      `a symlinked second spelling of the same directory raised no caution:\n${head}`);
  } finally {
    try { fs.unlinkSync(link); } catch { /* best effort */ }
    try { fs.rmSync(real, { recursive: true, force: true }); } catch { /* best effort */ }
  }
});

// The gone leg's body tells the reader to run the carry-over "against the root that still
// exists, substituting it for <their worktree>" — so it DOES prescribe a substitution into a
// single-quoted operand, and the only candidate path on the carrier is this one. It stays
// `flatPath`, because the value the reader substitutes is a PREFIX of it rather than the value
// itself, and quoting a path they are not going to paste would invite pasting it. What was
// missing is the sentence saying so.
// DERIVED, and this is the case that says so — with the expectation taken from the RECIPE
// ARRAYS rather than from `recipePlaceholders`. The first spelling of this case graded the
// renderer against the very function the renderer calls, which is tautological in the one
// direction that matters: a derivation defect could not fail it. The tokens below are read
// out of the rendered body with an independent scan.
//
// A rule whose placeholder set is handed in by the caller is one more copy of that set, and
// the copy is what drifts. The renderer also emits the MAPPING lines now: a caller that
// spells its token once in a rendered line and once in an argument has the same hand-copy the
// extraction was justified by removing.
//
// SCOPE THE INDEPENDENCE CLAIM, because half of it is a hand-copy. What is independent is the
// SET: this scanner collects, dedupes and orders the tokens itself, so a defect in
// `recipePlaceholders`' collection fails the equality both ways. What is SHARED, by copy, is
// the indent PREDICATE — `/^ {2}\S/` is `WORKTREE_ADVICE_COMMAND` re-spelled — so a change to
// what counts as a runnable line moves both halves together and this case cannot see it. The
// copy is deliberate: importing the exported constant would make the predicate independent by
// construction and delete the only cross-check there is on the collection.
const tokensIn = (lines) => {
  const seen = [];
  for (const line of lines) {
    if (!/^ {2}\S/.test(line)) continue;
    for (const t of line.match(/<[^<>\n]+>/g) || []) if (!seen.includes(t)) seen.push(t);
  }
  return seen;
};

test('the substitution rule names exactly the placeholders of the recipe it governs', () => {
  const body = mod.worktreeAdvice(whereRow());
  const expected = tokensIn(body);
  assert.ok(expected.length >= 4,
    `the recipe carries too few placeholders for this case to mean anything: ${JSON.stringify(expected)}`);
  const rule = mod.substitutionRuleLines(body, [['<their worktree>', "'/tmp/source-wt'"]],
    { indent: '  ', carrier: 'terminal' }).join('\n');
  // EVERY token the runnable lines carry is named, and the set is exactly that — both
  // directions, so a rule naming a token the recipe does not carry fails here too.
  for (const token of expected) {
    assert.ok(rule.includes(token), `the rule never names ${token}:\n${rule}`);
  }
  const named = [...new Set(rule.match(/<[^<>\n]+>/g) || [])];
  assert.deepEqual(named.slice().sort(), expected.slice().sort(),
    `the rule and the recipe name different sets:\n  rule:   ${JSON.stringify(named)}\n  recipe: ${JSON.stringify(expected)}`);
  // The renderer emits its OWN mapping line, so the token is spelled once at the call site.
  assert.ok(rule.includes("'<their worktree>' = '/tmp/source-wt'"),
    `the renderer did not emit the mapping line it was given:\n${rule}`);
  assert.ok(rule.includes("Replace '<their worktree>' TOGETHER WITH the quotes"),
    `the mapped token lost its own rule:\n${rule}`);
  assert.equal(rule.includes('<their worktree> are yours to supply'), false,
    `a token the tool maps is also listed as the reader's to supply:\n${rule}`);
  // The SENTENCE is scoped to what was scanned. Widening the scan to prose was the other
  // option and it makes the quoting claim false for MORE tokens, not fewer: a prose
  // occurrence is genuinely unquoted. Scoping the claim is what makes it checkable.
  assert.ok(rule.includes('runnable line'),
    `the rule quantifies over the whole recipe while it was derived from the runnable lines only:\n${rule}`);
  // No POSITIONAL word: one carrier prints this rule after its body, and "below" then points
  // at a different block carrying the opposite rule.
  assert.equal(/\bbelow\b/.test(rule), false, `the rule still names a position:\n${rule}`);
  // A token added to a runnable line enrols itself, with no second list to maintain.
  const grown = body.concat(["  git -C '<a brand new operand>' status"]);
  const grownRule = mod.substitutionRuleLines(grown, [], { indent: '  ', carrier: 'terminal' }).join('\n');
  assert.ok(grownRule.includes('<a brand new operand>'),
    `a placeholder added to the recipe did not reach the rule, so the set is not derived:\n${grownRule}`);
  // A placeholder named only in PROSE stays out, deliberately: the rule governs runnable
  // operands, and prose in these arrays quotes shell syntax freely.
  const prosed = body.concat(['A sentence mentioning <not an operand> in passing.']);
  assert.equal(mod.substitutionRuleLines(prosed, [], { indent: '  ', carrier: 'terminal' })
    .join('\n').includes('<not an operand>'), false,
    'a placeholder named only in prose was pulled into the rule');
});

// THE CARRIER decides how a token is rendered, not the caller's indent. On the two PERSISTED
// briefs this text is markdown prose, and `<path>` is a well-formed HTML tag name there: a
// renderer or a sanitizer drops it, leaving "Nothing here is substituted for you: , , and are
// yours to supply." The only statement of which values a reader must supply becomes empty on
// the one carrier a different session opens.
test('the markdown carrier renders every placeholder as a code span', () => {
  const body = mod.worktreeAdvice(whereRow());
  const md = mod.substitutionRuleLines(body, [], { indent: '   ', carrier: 'markdown' }).join('\n');
  for (const token of tokensIn(body)) {
    assert.ok(md.includes('`' + token + '`'),
      `the markdown carrier renders ${token} as raw HTML:\n${md}`);
  }
  const term = mod.substitutionRuleLines(body, [], { indent: '   ', carrier: 'terminal' }).join('\n');
  assert.equal(term.includes('`<path>`'), false,
    `the terminal carrier acquired markdown code spans:\n${term}`);
  assert.ok(term.includes('<path>'), `the terminal carrier lost the token entirely:\n${term}`);
});

test('the gone leg says its recorded path is for reading, not for pasting', () => {
  const head = whereHead(mod.whereAdviceLines(whereRow({ cwdExists: false }), null));
  assert.ok(head.includes('recorded worktree (gone) = '), `no labelled value on the gone leg:\n${head}`);
  assert.ok(head.includes('shown for reading, not for pasting'),
    `the gone-leg value carries no read-not-paste caution:\n${head}`);
  assert.ok(head.includes('quote it yourself'),
    `the gone leg never tells the reader to re-quote before building a -C operand:\n${head}`);
  // The gone-leg BODY emits quoted placeholders of its own and the head used to prescribe
  // nothing about them at all, while the present leg one arm over carries a rule about
  // replacing a token together with its quotes. A reader who carries that habit across strips
  // the quoting off an operand this leg never mapped. Both legs state the rule that governs
  // the placeholders they actually render.
  //
  // DERIVED, never spelled out here. The first version of this case hardcoded the pair it
  // believed that body carried, which pinned the renderer's own derivation defect in place:
  // when the derivation was wrong the case agreed with it. The expectation comes off the
  // rendered body now, so the two cannot agree by construction.
  assert.ok(head.includes('LEAVE THE QUOTES THERE'),
    `the gone leg renders quoted placeholders and prescribes nothing about them:\n${head}`);
  assert.ok(head.includes("write '\\'' for an apostrophe"),
    `the gone leg prescribes a hand substitution into a quoted operand without the '\\'' idiom:\n${head}`);
  const goneTokens = tokensIn(mod.worktreeAdvice(whereRow({ cwdExists: false })));
  assert.ok(goneTokens.length >= 2,
    `the gone body carries too few placeholders for this case to mean anything: ${JSON.stringify(goneTokens)}`);
  for (const ph of goneTokens) {
    assert.ok(head.includes(ph), `the gone-leg head never names ${ph}:\n${head}`);
  }
  // And it must NOT acquire the mapped half: nothing on this leg carries a pre-quoted value.
  assert.equal(head.includes('TOGETHER WITH the quotes'), false,
    `the gone leg offers a together-with-the-quotes rule for a value it never maps:\n${head}`);
});

// `adviceBlock` emits literal ```bash markers, and the justification everywhere in this repo
// is "one fence is one COPY BUTTON" — a MARKDOWN-renderer property. `adopt` prints to a
// terminal, where those three backticks bound no selection and a reader who selects the block
// pastes them into a shell that answers `command not found`. The coalescing walk still owns
// the paste-unit split; only the marker is carrier-specific.
// ONE documented `--json` key, THREE producers, and they do not share an input shape: `show`
// and `takeover` pass `hydrate(resolve(...))`, `adopt` passes the BARE `resolve(...)` row.
// SKILL.md's adopt row tells a consumer the key behaves "as show and takeover already do",
// which asserts exactly the equivalence the input shapes do not guarantee. It holds today
// because every field the advice path reads is a `buildIndex` ROW-LITERAL field rather than a
// `summarize` key — and that argument was enforced by nothing, so adding one `summarize`-
// supplied read to any advice arm would make the same key carry different values for the same
// session depending on which verb produced it, with every suite green.
//
// Hydrating inside `cmdAdopt` would close it too and was DECLINED: `hydrate` re-summarizes the
// whole transcript and that verb needs it for nothing else, so the cost lands on a confirmation
// command that is otherwise pure. The derived population below is the cheaper half of the same
// guarantee, and it is the shape the sibling census case already uses.
test('every row field the advice path reads is supplied by the buildIndex row literal', () => {
  const src = fs.readFileSync(new URL('../../skills/session-trail/scripts/trail.mjs', import.meta.url), 'utf8');
  const lines = src.split('\n');
  const isComment = (l) => l.trim().startsWith('//');
  const start = lines.findIndex((l) => /^\s*const row = \{$/.test(l));
  assert.ok(start >= 0, 'the buildIndex row literal could not be located, so this walk is vacuous');
  const supplied = new Set();
  let spread = false;
  for (let i = start + 1; i < lines.length; i += 1) {
    if (/^\s*\};\s*$/.test(lines[i])) break;
    if (isComment(lines[i])) continue;
    if (lines[i].includes('...s')) { spread = true; continue; }
    const m = /^\s*([A-Za-z0-9_]+)\s*[,:]/.exec(lines[i]);
    if (m) supplied.add(m[1]);
  }
  assert.ok(supplied.size > 0, 'no row-literal keys were collected, so this walk is vacuous');
  assert.ok(spread, 'the buildIndex row literal no longer spreads summarize() — re-derive which '
    + 'keys are row-literal and which are transcript-derived before trusting this case');
  // `title` is deliberately NOT added. It arrives through the `...s` spread — `summarize()`
  // emits the key unconditionally and the statement after the literal only BACKFILLS it from
  // the desktop-app record — so whitelisting it would let an advice arm read exactly the class
  // of field this case exists to forbid, and `hydrate` re-derives it from a deep summarize, so
  // the two call shapes can genuinely disagree about its value.
  const bodyOf = (name) => {
    const i = lines.findIndex((l) => new RegExp(`^function ${name}\\(`).test(l));
    assert.ok(i >= 0, `the advice-path function ${name} could not be located`);
    if (/\}\s*$/.test(lines[i]) && lines[i].includes('return')) return [lines[i]];
    const out = [];
    for (let j = i; j < lines.length; j += 1) { out.push(lines[j]); if (lines[j] === '}') break; }
    return out;
  };
  const read = new Set();
  for (const fn of ['worktreeAdvice', 'adviceLeg', 'whereAdviceLines']) {
    for (const l of bodyOf(fn)) {
      if (isComment(l)) continue;
      for (const m of l.matchAll(/\b(?:r|row)\.([A-Za-z0-9_]+)\b/g)) read.add(m[1]);
    }
  }
  assert.ok(read.size > 0, 'no row-field reads were found in the advice path, so this walk is vacuous');
  const unsupplied = [...read].filter((k) => !supplied.has(k)).sort();
  assert.deepEqual(unsupplied, [],
    'the advice path reads a row field the buildIndex row literal does not supply, so it comes '
    + 'from summarize() and `adopt --json` (which passes the BARE row) now disagrees with '
    + '`show --json` and `takeover --json` for the same session:\n  ' + unsupplied.join('\n  ')
    + '\n  supplied: ' + [...supplied].sort().join(' '));
});

test('adviceBlock renders unfenced when the caller asks for it', () => {
  // `git one |` leaves the command OPEN, so `git two` is a continuation of it rather than a
  // second command — which is what keeps the expected prompt count at two while the block
  // still holds three command lines. A fixture of three independent commands would now
  // legitimately carry three prompts, and would stop grading the continuation rule at all.
  const lines = ['Prose line.', '  git one |', '  git two', 'More prose.', '  git three'];
  const fenced = mod.adviceBlock(lines, '  ', '  ', { carrier: 'markdown' });
  const plain = mod.adviceBlock(lines, '  ', '  ', { carrier: 'terminal' });
  // `fenced` used to test the DEFAULT and now tests the explicit markdown BRANCH: the carrier
  // became required, so the default-behaviour case this pair once carried disappeared with the
  // default itself. Recorded here rather than silently converted — the discrimination the pair
  // exists for (fence versus prompt) is unchanged, but it no longer says anything about what an
  // omitted argument does, and the two refusal cases at the foot of this file own that now.
  assert.ok(fenced.some((l) => l.includes('```bash')), 'the markdown branch lost its fence');
  assert.equal(plain.some((l) => l.includes('```')), false,
    `an unfenced render still carries a markdown fence:\n${plain.join('\n')}`);
  // The SPLIT survives: the two blocks stay separated by the column-zero prose line, so the
  // command that WRITES is still not in the same paste unit as the steps that gate it.
  const idxTwo = plain.findIndex((l) => l.includes('git two'));
  const idxProse = plain.findIndex((l) => l.includes('More prose.'));
  const idxThree = plain.findIndex((l) => l.includes('git three'));
  assert.ok(idxTwo < idxProse && idxProse < idxThree, `the paste units collapsed:\n${plain.join('\n')}`);
  for (const l of plain) {
    if (l.trim()) assert.ok(l.startsWith('  '), `an unfenced line lost the caller's indent: ${JSON.stringify(l)}`);
  }
  // The MARKER, on the first line of every COMMAND and nowhere else. Without an assertion the `$ ` could
  // be deleted with every suite green, because the order and indent checks above hold either
  // way and `L70`'s needles are substrings that match a prefixed line too.
  assert.equal(plain.filter((l) => l.includes('$ ')).length, 2,
    `one prompt per COMMAND, not per line and not none:\n${plain.join('\n')}`);
  assert.ok(plain.some((l) => l === '  $ git one |'), `the block opener carries no prompt:\n${plain.join('\n')}`);
  assert.ok(plain.some((l) => l === '    git two'), `a continuation line carries a prompt:\n${plain.join('\n')}`);
  assert.ok(plain.some((l) => l === '  $ git three'), `a later command in its own block carries no prompt:\n${plain.join('\n')}`);
  // The UNFENCED branch's `firstPrefix`, which had no case at all: every call site in the tree
  // passes it equal to `indent`, so the value `open` carries was unobservable and the arm could
  // be collapsed to `indent` with every suite green. Its fenced twin is pinned exactly; this is
  // the same pin on the other branch. The array OPENS with a command, which is the only shape
  // that reaches the arm.
  assert.deepEqual(mod.adviceBlock(['  only'], '   ', '- ', { carrier: 'terminal' }),
    ['', '- $ only', ''],
    'the unfenced branch ignored the caller\'s firstPrefix on a leading command');
});

// The REAL array through the terminal carrier's own option. Every other unfenced assertion in
// this file drives a synthetic three-command fixture, so the shape `cmdAdopt` actually ships —
// `CARRY_OVER`, whose untracked-copy step is ONE construct spanning a dozen entries — reached no
// layer. A per-line prompt on that construct asserts twelve separate commands and breaks the
// `&&`, `|` and `do…done` chain for anyone who pastes it, and nothing would have reported it.
// The marker marks a COMMAND, not a block. One prompt per block was the fix for a per-line
// spelling that broke the copy loop's `while … do … done` construct, and it overshot: the
// first block of `CARRY_OVER` holds THREE independent commands — take the patch, grep it for
// symlink and executable modes, list what it would change — and only the first was marked.
// The other two rendered prompt-less at a deeper indent, which reads as OUTPUT of the line
// above them. Those two are exactly the steps that exist to be READ before the destructive
// apply, so a reader who takes them for output skips the gate and runs the write blind.
//
// A continuation line is one the shell is still waiting to finish: the previous line ended in
// `|`, `&&`, `||`, `\`, `do` or `then`, or we are inside a `do … done` / `then … fi` body.
// Everything else starts a command and carries its own prompt.
test('every independent command in a block carries its own prompt, and no continuation line does', () => {
  const out = mod.adviceBlock(mod.worktreeAdvice(rec({ app: { archived: true } })), '  ', '  ', { carrier: 'terminal' });
  const marked = (needle) => {
    const line = out.find((l) => l.includes(needle));
    assert.ok(line, `the recipe never rendered ${needle}:\n${out.join('\n')}`);
    return line.includes('$ ');
  };
  // The three independent reads of the first block.
  assert.ok(marked('PATCH="$(mktemp'), 'the patch step lost its prompt');
  assert.ok(marked('grep -nE'), 'the mode grep renders as output of the line above it');
  assert.ok(marked('apply --stat'), 'the --stat listing renders as output of the line above it');
  // The destructive apply, in its own block.
  assert.ok(marked('apply "$PATCH" && rm -f'), 'the destructive apply lost its prompt');
  // The copy loop: two assignments, then one pipeline whose body must stay unmarked.
  assert.ok(marked("SRC='<their worktree>'"), 'the loop preamble lost its prompt');
  assert.ok(marked('DSTR=$(CDPATH='), 'the destination resolve is a command of its own');
  assert.equal(marked('while IFS='), false, 'a continuation of a pipeline carries its own prompt');
  assert.equal(marked('n=$(printf'), false, 'a line inside the loop body carries its own prompt');
  assert.equal(marked('  done'), false, 'the loop terminator carries its own prompt');
});

test('the real recipe renders unfenced with one prompt per block and its split intact', () => {
  const out = mod.adviceBlock(mod.worktreeAdvice(rec({ app: { archived: true } })), '  ', '  ', { carrier: 'terminal' });
  assert.equal(out.some((l) => l.includes('```')), false, `a markdown fence on the terminal carrier:\n${out.join('\n')}`);
  // BY CONTENT, and anchored on nothing. The selector used to be `/^\s+(?:done|…)/`, which
  // cannot match a line the regression it targets would have produced: under a per-line prompt
  // those lines render `  $ done`, where the character after the leading spaces is `$` and the
  // keyword alternation never gets its turn. The filter came back empty, the precondition below
  // fired instead, and the assertion this case is named for could never bite. Measured on all
  // four spellings before the change.
  const loopBody = out.filter((l) => /(?:\bdone\s*$|while IFS=|n=\$\(printf)/.test(l) && !l.includes('SRC='));
  assert.ok(loopBody.length >= 3, `the copy loop did not render:\n${out.join('\n')}`);
  // None of these is the FIRST line of its block — that is `SRC=… DST=…` — so none may carry a
  // prompt. This is the assertion the per-line spelling failed: it marked all twelve.
  for (const l of loopBody) {
    assert.equal(l.includes('$ '), false,
      `a continuation line of the copy loop carries its own prompt: ${JSON.stringify(l)}`);
  }
  // The SPLIT the renderer owns, asserted on the carrier that ships rather than on the fenced
  // one: the destructive apply must not sit in the same blank-line-delimited block as the two
  // read steps that gate it.
  const blockOf = (needle) => {
    let n = 0;
    let prevBlank = true;
    for (const l of out) {
      if (!l.trim()) { prevBlank = true; continue; }
      if (prevBlank) n += 1;
      prevBlank = false;
      if (l.includes(needle)) return n;
    }
    return null;
  };
  const stat = blockOf('apply --stat');
  const apply = blockOf('apply "$PATCH"');
  assert.ok(stat !== null && apply !== null, `a carry-over step did not render:\n${out.join('\n')}`);
  assert.notEqual(apply, stat, `the destructive apply shares a paste unit with the steps that gate it:\n${out.join('\n')}`);
});

// A REAL SHELL, not a regex. `CARRY_OVER` and `TAKE_YOUR_OWN` are shell programs authored as
// JavaScript string arrays, and roughly twenty assertions in this file grade them by pattern —
// every one of which holds while the composed script fails to parse. The tree's own shell-parse
// oracle, tests/structure/bash32-substitution-scan.js, selects candidates with
// `name.endsWith('.sh')`, so it cannot see a line of this recipe; CLAUDE.md records that bound
// in §"bash 3.2 Command-Substitution Truncation" as an accepted limitation. This closes it for
// the one recipe a reader is invited to paste and run.
//
// Per BLOCK rather than per line, because a block is the paste unit and a line of the copy loop
// is not a program on its own. The blocks are taken the way `adviceBlock` takes them — runs of
// consecutive command lines — so this grades exactly what a reader copies.
test('every rendered command block parses in a real shell', (t) => {
  const probe = spawnSync('bash', ['-n', '-c', ':'], { encoding: 'utf8' });
  if (probe.error || probe.status !== 0) {
    // A host with no usable bash is an environment property, not a contract failure — the same
    // ground the symlink case above skips on.
    t.skip('no usable bash on PATH');
    return;
  }
  // FROM THE RENDERER, not from the source array. What a reader pastes is what `adviceBlock`
  // coalesced into one unit; re-deriving the split here meant a change to that coalescing —
  // the thing that decides the paste unit — could never reach this check. Both legs, because
  // the gone leg renders a command of its own and reached no shell at all.
  let graded = 0;
  for (const row of [rec({ app: { archived: true } }), rec({ app: { archived: true }, cwdExists: false })]) {
    const rendered = mod.adviceBlock(mod.worktreeAdvice(row), '  ', '  ', { carrier: 'terminal' });
    const blocks = [];
    let current = [];
    for (const line of rendered) {
      // A rendered COMMAND is either marked (`  $ cmd`) or a continuation, which `adviceBlock`
      // indents two further spaces past the caller's indent. PROSE sits at the caller's indent
      // with no marker — the same two spaces a source-array command carries, which is why the
      // source-array predicate cannot be reused on rendered output.
      const code = line.replace(/^\s*\$ /, '').replace(/^\s+/, '');
      if (line.trim() === '') { if (current.length) { blocks.push(current); current = []; } continue; }
      if (/^\s*\$ /.test(line) || /^ {4}\S/.test(line)) { current.push(code); continue; }
      if (current.length) { blocks.push(current); current = []; }
    }
    if (current.length) blocks.push(current);
    for (const block of blocks) {
      const program = block.join('\n');
      const r = spawnSync('bash', ['-n', '-c', program], { encoding: 'utf8' });
      assert.equal(r.status, 0,
        `a rendered block does not parse:\n${program}\n--- bash said ---\n${r.stderr || '(nothing)'}`);
      graded += 1;
    }
  }
  assert.ok(graded >= 4, `too few rendered blocks reached a shell across both legs: ${graded}`);
});

// TWO renderers, ONE carrier axis, and it is REQUIRED rather than defaulted. They used to
// default in OPPOSITE directions — `adviceBlock` rendered MARKDOWN for an absent carrier and
// `substitutionRuleLines` rendered TERMINAL — so a reader of either signature inferred the
// wrong default for its sibling, and both persisted-brief call sites already relied on that
// asymmetry by naming the carrier on one and omitting it on the other. The failure directions
// are not symmetric either: a defaulted fence puts stray backticks on a terminal, while a
// dropped code span lets a markdown sanitizer empty the token list and leave "Nothing here is
// substituted for you: , , and are yours to supply." in a file a DIFFERENT session opens.
//
// REFUSING is the house answer for an argument of this class, not aligning the two defaults on
// one value. `_autopilot_workspace_refusal` in this repository takes its audience as a
// POSITIONALLY REQUIRED argument and refuses a two-argument call rather than falling back to a
// form, for the same reason: the wrong value has a user-visible safety consequence, so omitting
// it must be the thing a new call site trips over rather than something it inherits silently.
// Aligning the defaults removes the contradiction and keeps the silent fallback.
//
// The THROW is safe here SPECIFICALLY because `main()` carries a total try/catch that flushes
// before it reports, so a bad carrier surfaces as a reported cause rather than a half-written
// brief. If that catch is ever removed, throwing becomes a partial-write hazard.
test('adviceBlock refuses an absent or unrecognized carrier rather than defaulting', () => {
  const lines = ['Prose line.', '  git one'];
  assert.throws(() => mod.adviceBlock(lines, '  ', '  '), /carrier/,
    'an omitted carrier still renders instead of refusing');
  assert.throws(() => mod.adviceBlock(lines, '  ', '  ', {}), /carrier/,
    'an empty options object still renders instead of refusing');
  assert.throws(() => mod.adviceBlock(lines, '  ', '  ', { carrier: 'markdwon' }), /carrier/,
    'a misspelled carrier still renders instead of refusing');
  // BOTH recognized values still render, so the refusal cannot be satisfied by a function that
  // throws unconditionally.
  assert.ok(mod.adviceBlock(lines, '  ', '  ', { carrier: 'markdown' }).some((l) => l.includes('```bash')));
  assert.equal(mod.adviceBlock(lines, '  ', '  ', { carrier: 'terminal' }).some((l) => l.includes('```')), false);
});

test('substitutionRuleLines refuses an absent or unrecognized carrier rather than defaulting', () => {
  const body = mod.worktreeAdvice(rec({ app: { archived: true } }));
  assert.throws(() => mod.substitutionRuleLines(body, [], { indent: '  ' }), /carrier/,
    'an omitted carrier still renders instead of refusing');
  assert.throws(() => mod.substitutionRuleLines(body, []), /carrier/,
    'an omitted options object still renders instead of refusing');
  assert.throws(() => mod.substitutionRuleLines(body, [], { indent: '  ', carrier: 'terminl' }), /carrier/,
    'a misspelled carrier still renders instead of refusing');
  const md = mod.substitutionRuleLines(body, [], { indent: '  ', carrier: 'markdown' }).join('\n');
  const term = mod.substitutionRuleLines(body, [], { indent: '  ', carrier: 'terminal' }).join('\n');
  assert.ok(md.includes('`<path>`'), `the markdown carrier stopped code-spanning:\n${md}`);
  assert.equal(term.includes('`<path>`'), false, `the terminal carrier grew a code span:\n${term}`);
});
