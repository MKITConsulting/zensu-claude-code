// Unit contract for the takeover-destination advice in
// skills/session-trail/scripts/trail.mjs — `worktreeAdvice`, its module-scope
// recipe constants, `WORKTREE_ADVICE_COMMAND` and `adviceBlock`.
//
// These are pure functions of a plain record with no I/O, and every property
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
import fs from 'node:fs';

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
  const out = mod.adviceBlock(['lead', '  one', '  two', '  three', 'tail'], '   ', '   ');
  assert.equal(out.filter((l) => l.trim().startsWith('```bash')).length, 1);
  assert.equal(fenceOf(out, 'one'), 1);
  assert.equal(fenceOf(out, 'two'), 1);
  assert.equal(fenceOf(out, 'three'), 1);
});

test('adviceBlock splits a run broken by a column-zero prose line into TWO fences', () => {
  const out = mod.adviceBlock(['lead', '  one', 'read this first', '  two'], '   ', '   ');
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
    mod.adviceBlock(['  only'], '   ', '- '),
    ['', '- ```bash', '   only', '   ```', ''],
  );
});

test('adviceBlock on an empty array returns an empty array', () => {
  assert.deepEqual(mod.adviceBlock([], '   ', '   '), []);
});

test('adviceBlock on a single prose line prefixes it with firstPrefix and opens no fence', () => {
  const out = mod.adviceBlock(['just prose'], '   ', '- ');
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
  const rendered = mod.adviceBlock(mod.worktreeAdvice(rec({ app: { archived: true } })), '   ', '   ');
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
test('the emitted recipe carries the do-not-run-this-at-all escape', () => {
  const prose = mod.worktreeAdvice(rec({ app: { archived: true } })).join('\n');
  assert.ok(/do not run this at all/i.test(prose), 'the emitted recipe has no way out');
  assert.ok(/by hand/i.test(prose), 'the escape does not name the alternative');
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

// `cmdShow` prints every advice line into a SURVEY view with a nine-space prefix and
// no fence. The array grew from roughly six lines to sixty, so `show` — the command
// whose value is that you can scan it — started dumping a paste-and-run recipe into
// the middle of its output. The recipe's home is the persisted brief, which is what a
// human actually pastes from; `show` keeps the decision and points at the brief.
test('the survey form drops the carry-over recipe and the brief form keeps it', () => {
  const r = rec({ app: { archived: true } });
  const full = mod.worktreeAdvice(r);
  const survey = mod.worktreeAdvice(r, { carryOver: false });
  assert.ok(full.some((l) => l.includes('PATCH="$(mktemp')), 'the full advice lost the recipe');
  assert.ok(!survey.some((l) => l.includes('PATCH="$(mktemp')), 'the survey form still carries the recipe');
  assert.ok(survey.some((l) => l.includes('git worktree add')), 'the survey form lost the create recipe');
  assert.ok(survey.length < full.length, 'the survey form is not shorter than the full one');
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
  assert.ok(/hard link/i.test(prose), 'the hard-link residual is not named at all');
  assert.ok(/residual/i.test(prose), 'the hard link is not disclosed as an accepted residual');
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
  const rendered = mod.adviceBlock(mod.worktreeAdvice(rec({ app: { archived: true } })), '   ', '   ');
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

// ONE decision, THREE consumers — the same count `trail.mjs`'s own header and CLAUDE.md
// carry, and the same three the renderer test below enumerates (`no renderer re-derives the
// leg by hand`). `worktreeAdvice` picks its lead AND its
// body from it (those two drifted apart inside one function once, which is how a gone lead
// came to sit above a present body); `cmdShow` decides from the same answer whether to print
// its "the recipe is not in this view" pointer, and it would otherwise print that pointer on
// an arm that emits no carry-over, which no fixture would catch because none renders a
// gone-leg `show`; and `printResume` decides whether to print its own copy of the gone-leg
// create command.
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
  const body = (name, open) => {
    const i = src.indexOf(open);
    assert.ok(i !== -1, `${name} not found`);
    return src.slice(i, src.indexOf('\n}\n', i));
  };
  // `cmdShow` is deliberately NOT in this list, and the reason is stated rather than left to
  // be rediscovered: it reads `r.cwdExists` legitimately, for the `!! MISSING` marker, so the
  // same blanket predicate would fail on correct code. Its leg derivation is therefore graded
  // only by the narrower assertion below.
  for (const [name, open] of [
    ['worktreeAdvice', 'function worktreeAdvice(r, options = {}) {'],
    ['printResume', 'function printResume(r) {'],
  ]) {
    assert.ok(!/r\.cwdExists/.test(body(name, open)),
      `${name} still derives the leg from r.cwdExists instead of adviceLeg`);
  }
  // The `cmdShow` half, scoped to the WHERE block so the legitimate `!! MISSING` read is not
  // swept up: between the advice render and the write-anchor lines, the leg comes from
  // `adviceLeg` and from nothing else.
  const show = src.slice(src.indexOf('const wtAdvice = worktreeAdvice(r, { carryOver: false });'));
  const where = show.slice(0, show.indexOf('writesLines('));
  assert.ok(where.includes("adviceLeg(r) === 'present'"),
    'cmdShow no longer takes its leg from adviceLeg');
  assert.ok(!/r\.cwdExists/.test(where),
    'cmdShow re-derives the leg by hand inside the WHERE block');
});

// The population is DERIVED, not counted. "Three consumers" is asserted in prose in three
// carriers — this file, `trail.mjs`'s own header and CLAUDE.md — and the renderer scan above
// grades only renderers it NAMES, so a fourth consumer that uses `adviceLeg` correctly would
// leave all three prose copies stale with every check green. Scanning the call sites and
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
test('the adviceLeg consumer set is exactly the three the carriers name', () => {
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
  assert.deepEqual([...callers].sort(), ['cmdShow', 'printResume', 'worktreeAdvice'],
    'the adviceLeg consumer set moved — update the count and the roster in trail.mjs\'s header, '
    + 'in this file\'s header and in CLAUDE.md §"Takeover Destination" together');
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
