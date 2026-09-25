---
paths:
  - "hooks/lib/bash-source-write-parse.js"
  - "hooks/pre-bash-source-write-gate.sh"
  - "hooks/lib/claude-path-v1.js"
  - "tests/structure/test-bash-source-write-gate.sh"
  - "tests/structure/git-repo-escape.test.js"
---

# Git Mutation Tables (`hooks/lib/bash-source-write-parse.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

Rule (C) of the PreToolUse(Bash) source-write gate denies a working-tree-mutating
git subcommand whose target repository escapes the session root. Four module-scope
tables are its single source of truth — `GIT_MUTATIONS`, `GIT_READONLY_FORMS`,
`GIT_OPTS_WITH_OPERAND`, `LINKED_WORKTREE_GIT_DIR` — plus a fifth constant,
`UNEXPANDED`, which is NOT exported and therefore cannot be pinned from the unit
layer at all. The first three are re-encoded outside the module; the admin-dir
shape is re-encoded only as the W153 probe path.

**Adding or removing a gated verb** must land with all of these in the same commit:

- the verb-count literal in `tests/structure/test-bash-source-write-gate.sh` (W164),
  which is what catches a REMOVED verb — the probe loop is driven by the set itself
  and therefore cannot;
- the hardcoded membership list in `tests/structure/git-repo-escape.test.js`, kept
  deliberately independent of the set under test for the same reason;
- a read-only spelling in `GIT_READONLY_FORMS` if the verb has one, plus the pins
  that every exemption key is a gated verb and that each verb's bare form is still
  a mutation.

**Adding an operand-consuming global option** requires the membership list in
`git-repo-escape.test.js`: drop one and its operand parses as the subcommand,
silently disabling rule (C) for that spelling with the whole suite green.

**Documentation is machine-enforced in two places that pull in opposite directions.**
The hook header in `hooks/pre-bash-source-write-gate.sh` must NAME `GIT_MUTATIONS`
and `GIT_READONLY_FORMS` and re-author neither — W165 fails if a gated verb is
enumerated there. The parser header must NAME every accepted gap — W192 matches each
gap's distinguishing clause, not a bare keyword. Both pins also require the "not a
security boundary" framing to survive. `docs/gates.md` §"Source-Write Gate", the
hook-reference row and the `bashWriteGate` config row in `docs/configuration.md` point at
the tables rather than listing them, for the same reason; their VERB CONTENT is not
pinned. THREE needles in `docs/gates.md` §"Source-Write Gate" ARE pinned, by T29 in
`tests/structure/test-session-trail-skill.sh` — `cross-worktree takeover`,
`session-trail` and `does **not** cover a nested worktree`. The last IS the
containment claim, so rewording it fails the suite. That file is no longer wholly
unpinned; see the section below.

**The gate's ANCHOR contract is restated in NINE carriers outside the parser, and
nothing pins them against it.** `writeAnchor` / `writesLines` / `writeAnchorCaution`
/ `continuationPlan` in `skills/session-trail/scripts/trail.mjs`, flow 3, the step-4
placement paragraph and the Limits bullet in `skills/session-trail/SKILL.md`, and
BOTH paragraphs of `docs/gates.md` §"Source-Write Gate" — the cross-worktree one and
the continuation one beside it, which states the rule again in its own words. They do NOT carry
the same content, and the difference is what decides where an edit is owed. All of
them state the CONTAINMENT rule.

**`continuationPlan` is the one carrier that ACTS on the rule instead of only
restating it**, and its three narrowings are the reason it may. It renders and never
executes, and the reason is APPROVAL rather than gate coverage — a first wording claimed
the latter and was wrong about the two commands that matter. This script's writes happen
inside node where no PreToolUse gate can see them, so a worktree it created would be
unseen; but so are two of the four it RENDERS. Only `git apply` and the patch redirect
are judged: `bash-source-write-parse.js` gates `worktree` for `remove`/`move` only and
says `add` "stays ungated", and `detectChannels` recognizes no `tar -xf -`. What stands
in for the gate there is the renderer's own refusals — same repository, existing anchor,
resolved branch — which is why they are load-bearing rather than cosmetic. Four carriers
state this and all four must say it the same way. It prescribes a target path only off a TRUSTED channel: `covered ===
false` measured through `CLAUDE_PROJECT_DIR` is a sound DENY but its `callerRoot` is
the wider root, so a path derived from it can land outside the immutable one, and the
finding is reported with the path withheld (`weak-channel-no-target`). And its base
branch comes only from a LIVE read of the source worktree, never from the session
record's `branch` field — measured 2026-08-27, that field answered `main` for a
worktree actually on `claude/plugin-auto-mode-permissions-665942`, so the rendered
`git worktree add … -b` would have branched the continuation off `main` and left every
commit behind; with no live read it answers `branch-unresolved` rather than guessing.
Its `CONTINUATION_REASONS` set is closed and CARRIES `writeAnchor`'s own reason codes
verbatim, so renaming one there silently degrades every null cause here to
`unclassified` — the two sets move together, and `unclassified` is deliberately NOT
`no-channel`, whose own sentence asserts that neither environment variable was set. The `takeover` MARKDOWN brief deliberately
carries none of it, on the same terms as `writes`: a brief is read by a different
session than the one measured, where a rendered target path is a confident instruction
into the wrong tree.

**Windows is UNMEASURED here, not unreachable, and the distinction was got wrong
once.** `tests/structure/test-session-trail-verdict.sh` is in the `excluded` list of
`tests/profiles/windows-native-structure.v1.json` and absent from
`tests/profiles/windows-ci.v1.json`, so the BLOCKING PR shards skip it — but it IS in
`ciStructureTests` in `tests/profiles/promptfoo-local-only.v1.json`, so the weekly
windows-safety run executes it. The WC block will therefore run on Windows; it simply
never has yet. It is also the first case in that suite to create a real git repository
and worktree, which is new platform surface AND new wall clock for a suite whose
Windows runtime nobody has measured — take the figure from the first weekly run after
this lands. Both of its preconditions SKIP rather than fail, deliberately: a git that
cannot build the fixture, and a filesystem whose canonical spelling differs from the
literal one, are environment properties, and failing on either would redden a weekly
run for a reason unrelated to this feature.

**The two env channels are NOT equally authoritative, and only one direction of the
weaker one is sound.** `claude-hook-session-v1.js` reads `CLAUDE_PROJECT_DIR` solely
as the last resort when no Session Control record exists — its own header says "The
mutable payload cwd is never a project authority" — while the record's `projectRoot`
is what it exports as `ZENSU_PROJECT_ROOT`, and that is the value the gate compares.
For a session started in a subdirectory the ambient variable is therefore the WIDER
root. `writeAnchor` downgrades `covered` to `null` when containment was measured off
that channel, and leaves `covered: false` alone: containment in a wider root does not
imply containment in the narrower one, but NON-containment does. The downgrade travels
in the field rather than only in the render, so a `--json` consumer is not misled
either, and `source`/`callerRoot` still report what was measured. A channel is also
usable only when ABSOLUTE (a relative value would reach `path.resolve` inside
`canonicalDir` and be resolved against the process cwd — the derivation `W3b` exists
to forbid, one call further down than `W3b` can see) and the winning value is compared
VERBATIM (`.trim()` decides presence only; a trailing space is legal in a POSIX
directory name and the gate receives the untrimmed value). `W10`/`W11` pin all
four. The environment variables are named by `writeAnchor`'s header,
`writesLines`'
emitted text, `continuationPlan`'s own `weak-channel-no-target` line (which spells
`CLAUDE_PROJECT_DIR` to a user) and SKILL.md flow 3. The rule letters are named by `writeAnchor`'s
header (A, B and C), `writesLines` (A, B and C), flow 3 (A, B and C) and `docs/gates.md`
(C only). `writeAnchorCaution` names neither — deliberately, because it is persisted
into a brief a stranger reads. The Limits bullet withholds only those two things: it
restates the asymmetry IN FULL, naming both Edit-matcher hook filenames, the
capability gate and its main-principal exemption, and the containment definition,
then points at flow 3 for the routing rule. Do not describe it as an index entry while
the bullet carries the hook roster. A change to
`within()`, to how `project_root` is minted (`claude-session-control-v1.js`
`projectRoot: eventCwd`), or to which hook exports `ZENSU_PROJECT_ROOT` leaves every
carrier enumerated above wrong with both session-trail suites green — they drive `trail.mjs` against its
own definition and grep the prose for literals. `writeAnchor` no longer holds a hand-copy of
`within`: the parser now defines it at MODULE scope and EXPORTS it, and
`trail.mjs` requires the parser and CALLS it, so the containment rule has one
implementation and the two cannot drift. (The parser always had an export surface
— `detectChannels`, `gitTargets`, `msysToDrive` and the frozen tables, consumed by
`tests/structure/git-repo-escape.test.js`; what it did not export was `within`
itself. An earlier wording here said the parser "exports nothing", which read as
the former and was false.) The same require supplies `msysToDrive`, so the
comparison is now in the gate's namespace on Windows too. A FAILED load is
reported as `rejected:gate-unavailable` and yields `covered: null` — there is
deliberately no local fallback copy, because answering off a weaker rule than the
gate's is exactly what taking the seam removed. What remains this feature's OWN
encoding is the canonicalization: `canonicalPair` feeds both operands through
`msysToDrive` + `path.resolve` + `realpathSync.native` and applies `TRAILING_SEP`
(platform-selected, guarded by `path.parse(p).root === p`), which is NOT the
gate's `stripSlash` but a DIFFERENT rule — forward-slash-only and unguarded there.
A change to the gate's own canonicalization still has no recorded re-check site;
treat `canonicalPair` as the one remaining place where this feature encodes what
it believes the gate does. It canonicalizes both sides TOGETHER: one
`realpathSync` failure drops BOTH back to the lexical spelling, because
canonicalizing per operand put them in different namespaces whenever exactly one
path existed — the `!! MISSING` worktree case, where a symlinked anchor compared
as an escape from its own nested worktree. Do not
trust an ordinal here — an earlier wording said "sixth" and was already wrong,
because `hooks/lib/zensu-tdd-phase.sh` carries a further semantically equivalent spelling
inside a `node -e`. Read the enumeration below, not a count. THREE
narrowings are deliberate and stated at the copy, and they do NOT share a direction:
only rule (C)'s `isTemp` carve-out errs toward WARNING. The other two err toward
`allowed`: rule (A) fires on an IN-ANCHOR target — a raw shell overwrite of tracked
source — which is exactly where this answers `allowed`, and the third realpaths BOTH
sides while the gate realpaths only its roots and resolves a `cd` operand
lexically. That asymmetry is the property to re-check before letting the
hand-copy
drift. `writeAnchor`'s measured verdict reaches THREE carriers — `show`'s stdout,
`show --json` and `takeover --json` — and the third was already true before the
continuation work; an earlier wording here named only the first two and was wrong.
What reaches a `~/.claude/handoffs/` brief is `writeAnchorCaution`'s
STATIC containment sentence, deliberately unmeasured because a brief is read by a
session it was not measured against. A correction to that WORDING does not reach
files already written.

The `worktree`/`remove|move` literals appear three times — the `GIT_READONLY_FORMS`
entry, the `paths` guard in `gitTargets`, and the `addressed` substitution in
`decideGit`. A divergence is caught behaviorally (W144/W145/W172-W175 plus the unit
`paths` cases), not structurally; keep them in step by hand.

**The Windows comparison namespace.** Every path string enters rule (B)'s and rule
(C)'s comparison through `msysToDrive(value, isWindows)`. Windows is the only host
where the gate compares two spellings of one location. **The dividing line is stdin
against everything else**, not env against everything else: MSYS rewrites exported
variables AND the argument vector on the way into a native binary, so
`CLAUDE_PROJECT_DIR` arrives as `D:\a\proj`, while the payload cwd and every command
token — which travel over stdin, the one channel MSYS never touches — are still
spelled `/d/a/proj`. `path.resolve` then reads that leading `/` as drive-RELATIVE and
splices the whole POSIX path under the current drive (`D:\d\a\proj`). The session's
own root compares as an escape and every in-project git verb denies. **W3h pins the
stdin half of that premise**, because everything here rests on it: were stdin ever
converted too, `msysToDrive` would be normalizing an already-native path, every
assertion would stay green, and the real defect would have moved out of view. The
argv half is why the gate suite must hand a raw MSYS spelling to `node` over stdin
rather than as an argument — W121b silently skipped itself on Windows for exactly
that reason, reporting "spellings coincide" while testing nothing.
`hooks/pre-bash-source-write-gate.sh` exempts
`CLAUDE_ENV_FILE` from that same conversion by hand (`MSYS2_ENV_CONV_EXCL`), which is
why `controlPathNamespace` exists for that one variable and why it cannot be reused
here: it returns a lowercased forward-slash namespace, not `path.resolve`'s.

Two properties hold the fix, and W3c pins both because a POSIX host cannot observe
either: **every** `path.resolve` call routes through the normalizer (a new,
un-normalized resolution site silently reintroduces the split namespace), and the
normalizer stays platform-gated — on POSIX `/d/a/x` is a legitimate path, and
rewriting it there would hand both rules a different tree. `git-repo-escape.test.js`
drives the normalizer's own branches through its explicit `isWindows` parameter and
re-runs the production composition against `path.win32`. Deliberately absent: an
env-selectable platform switch. It would let the suite exercise the real hook
end-to-end on macOS, but an env var that changes path semantics is a bypass channel
that — unlike `ZENSU_BASH_WRITE_GATE=off` — lands no bypass-ledger entry.

**The MSYS drive rule is SHARED, not copied.** `claude-path-v1.js` exports
`msysDrivePrefix` as a TOTAL function — anything that is not an MSYS drive spelling comes
back unchanged — and each consumer applies its own policy on top. There are FOUR, not
two: `normalizeHostPathInput` in that same file, `msysToDrive` in the parser,
`hooks/lib/zensu-doctor-invocation.js`, and — the first outside `hooks/` —
`hostPath` in `skills/session-trail/scripts/trail.mjs`, whose policy is a third one
again (it FAILS when the module cannot be loaded). The two the sentence below
contrasts are the two whose policies are opposites: its own
`normalizeHostPathInput` layers a fail-closed-by-THROWING policy for the session-control
trust boundary, while `msysToDrive` in the parser declines that policy. It has to: the
parser RETURNS a deny reason, so an exception would exit non-zero and the hook's fail-closed
branch would deny every Bash call in the session rather than the one command — and
`/var/folders/x`, a DEFAULT entry of the rule-(B) temp list, is one of the spellings that
policy throws on. That is the whole reason the split exists; do not "simplify" the parser
onto `normalizeHostPathInput`. This is the ONE sibling `require` in
`bash-source-write-parse.js`, taken deliberately so a fourth `within()`↔`isInside()`-style
hand-copy never has to be maintained; if the module were missing the parser would fail to
load and its hook would deny, which is the fail-closed direction. W3d pins the delegation,
pins that no private copy reappears (the parser keeps exactly two `([A-Za-z])` rules of its
own, `controlPathNamespace`'s ungated lower-casing pair, which serve the separate
CLAUDE_ENV_FILE namespace), and pins that the shared rule stays throw-free.

Leaving an unconverted token raw changes no verdict: every rooted spelling the throwing
policy rejects resolves outside the session root, so `within()` reports an escape. Whether
that escape is DENIED is separate — `/tmp/x` and `/var/folders/x` are default temp members,
so `isTemp()` allows them by design and always did. Not converting a complete UNC is no gap
either: `path.resolve` already yields the same spelling.

**The temp list travels with the namespace.** `ZENSU_BSWGATE_TEMP_DIRS` is a LIST, and on
Windows both conventions arrive: MSYS converts an exported POSIX `:` list, while an
operator may supply a native `;`-separated one with drive-qualified entries. (The repo's
own renderer, `zensu-host-path.sh`, emits drive-qualified FORWARD-slash paths — `D:/a/tmp`
— and is not wired to this variable; it shows the shape to expect, it does not produce
this list.) `splitTempList` therefore treats a colon as a separator
except in drive position — a plain `.split(":")` shredded `D:\a\tmp` into `["D",
"\\a\\tmp"]`, so the intended root never entered `TEMP` and the rule (B) carve-out
silently stopped applying. The map that follows also drops any entry that resolves to a
filesystem ROOT: `TEMP_SAFE` rejects only roots that CONTAIN the project, which on win32
cannot catch `C:\` while the project sits on `D:` — that entry would carve out an entire
drive with no bypass-ledger entry, and `/c` only became spellable as a drive root once
`msysToDrive` started normalizing it.

**One accepted gap is NOT fail-closed and is pinned rather than fixed:** drive-relative
`D:rel` on the project's own drive resolves against the base and lands INSIDE the session
root, so it is allowed; if the shell's real cwd on that drive is elsewhere the write
escapes. It predates the normalizer (`D:rel` has no leading slash, so `msysToDrive` never
sees it) and `git-repo-escape.test.js` pins the judgment so a change to it is deliberate.

**The harness lies on Windows in three ways, and each one fails SILENTLY on POSIX.**
Every one of these turned a check green — or red — for a reason unrelated to the
contract it names, and none is observable from a POSIX host:

- **Grep the DECODED deny reason, never the hook's raw stdout.** The hook emits through
  `JSON.stringify`, which doubles every backslash, so a `D:\a\…` needle can never match a
  `D:\\a\\…` haystack. This failed W121/W183/W204 on Windows against a message that was
  already correct, and made W121b — whose whole job is to prove a spelling is ABSENT —
  pass without testing anything. `reason()` decodes it; **W3g** pins that every
  `REASON_*` capture is piped through it, and **W3f** makes the encoding itself
  observable on any host. W87e is the deliberate exception: it greps the JSON envelope.
- **A PATH shim cannot intercept the parser's `git`.** `tracked()` uses `execFileSync`
  with no shell, and Windows resolves only a real executable image: an extensionless
  script named `git` is never reached and a `.cmd` twin is refused outright since
  CVE-2024-27980, so the real `git.exe` answers and the spy log stays empty. Both halves
  of W122 then go vacuous — an empty log "proving" an independence nothing tested. It
  probes reachability first and skips only where the parser could never reach the shim.
- **`ln -s` exiting 0 is not evidence of a symlink.** Git Bash satisfies it with a copy
  or a shortcut native Node does not follow; the two directories then genuinely differ
  and DENY is CORRECT, so W167/W168 failed on a premise that did not hold. They confirm
  the link through `fs.realpathSync.native` — the same primitive `canonical()` uses.

**The Windows timeout for this suite is a coverage boundary, not a formality.** At
`timeoutMs: 300000` in `tests/profiles/windows-ci.v1.json` the shard killed the suite
after roughly 210 of its checks, always mid-run at W122 — so W224, W233/W234 and
everything after them never executed on Windows at all while the shard still reported.
It is 600000 now (matching `autopilot-plan-delegate`). Adding checks costs Windows wall
clock; if the shard starts reporting `TIMED_OUT` again, the tail of the file has gone
unverified regardless of how many checks passed before it.

**Cross-file couplings — stated as a CRITERION, never a count**, because the count was "Three" while the list already held four: every hand-copy of a rule this parser owns, plus every PROSE assertion elsewhere that a message this parser emits says a particular thing. (The MSYS drive rule is deliberately NOT among them: it is
shared through `claude-path-v1.js`'s `msysDrivePrefix` rather than hand-copied — see the
paragraph above.) `WRAP` — the transparent-wrapper set rule (C)'s
`cmd0` anchoring depends on — is hand-duplicated as a JS literal in
`hooks/pre-bash-zensu-gate.sh`; a wrapper added to one and not the other means the
same wrapped invocation is gated by one Bash gate and not its sibling.
`within()` is a hand-copy of `isInside` in
`hooks/lib/reviewer-capability-v1.js`, held in lockstep only by W3b — and `contains()` in
`hooks/lib/zensu-autopilot-state.sh` is a further member this roster omitted while the
predicate was already anchored: it decides `mayHoldWorkspace`, so an unanchored spelling
reports `<project>/..bak` as a FREE workspace and lets a standalone `/zensu:tdd` chain arm
underneath a live durable run in the same tree. W18b in
`tests/structure/test-autopilot-state-machine.sh` pins both of its anchoring clauses and
forbids the bare `startsWith("..")` form returning; W18 alone did not, and no fixture
builds a `..`-prefixed worktree, so the revert was green from both directions — and the same
predicate exists in `session-control-core-v1.js`, `review-evidence-lease-v1.js` and
`hooks/lib/zensu-tdd-phase.sh` (an inline `const within` inside its `node -e`
native-path validator), with an UNANCHORED `startsWith("..")` variant in
`finding-verify-v1.js` that has the `..bak` defect this gate fixed.
`skills/session-trail/scripts/trail.mjs` is NO LONGER on that list and was the FIRST
consumer that proved the seam works; `hooks/lib/plugin-data-guard-v1.js` is the SECOND, which
raises the stakes of this export list — removing `within` or `msysToDrive` now degrades a
PreToolUse DENY gate to allow as well as breaking a shipped skill: `within` is now defined at MODULE scope here
and EXPORTED, and that file requires this parser and CALLS it, so the only copy a
user ever read as a VERDICT rather than as a deny is gone. Its `W22` pins the
export, the specifier and the degrade-on-load-failure behaviour. Removing either
`within` or `msysToDrive` from the export list therefore breaks a shipped skill,
not just a test — which is the cost that buys the single implementation. Unlike `within()`↔`isInside`, `WRAP` is NOT pinned
against its `pre-bash-zensu-gate.sh` copy — check that one by hand. A THIRD wrapper set sits on
the same `Bash` matcher and is deliberately NOT a copy of `WRAP`: `commandPosition` in
`hooks/lib/verify-consent-v1.js` skips `command`, `builtin`, `exec`, `nohup`, `time`, `nice`,
`timeout`, `gtimeout`, `env`, `sudo` and `doas`, with one operand list shared by the last three.
It is registered here rather than shared because it cannot drift into an admit: the consent gate
REFUSES every wrapper it recognizes — `env`, `sudo` and `doas` as `ENV_ASSIGNMENT`, the rest as
`WRAPPER` — and a wrapper it does not recognize leaves the `playwright-cli` word outside command
position, which refuses as `INDIRECT`. That ladder therefore decides only which reason a refused
call names, never whether a call is admitted, and the unit case `a wrapper the ladder does not
know is refused too, so the ladder decides only the reason` holds both arms. One shared table was
weighed and declined: `WRAP` marks a wrapper TRANSPARENT so a rule can see through it, while the
consent ladder exists to NAME a refusal, and one table would tie an admit-relevant set to a
reason-only one. **A further coupling is
PROSE rather than a table, and nothing pins it either:** the deny message rule (C) emits ends
with a sentence naming the deliberate one-off escape prefix, and `skills/session-trail`'s
move-alternative advice ASSERTS that it does — it tells the reader the refusal names the
escape and deliberately declines to spell it, which is true only while that inline literal
survives. It is an inline string here rather than a named constant, and a grep for its
distinguishing words across `tests/` returns nothing, so a reword silently leaves a shipped
skill pointing at a message that names nothing. Either pin the literal against its owner or
re-check that skill by hand before rewording any deny text. And
`skills/pr-team-review` Phase E depends on `worktree remove` being judged on the tree
it destroys rather than on the addressed repository — narrow that carve-out and the
skill's documented cleanup starts denying, which is what W181/W185-W187 exist to
catch. That flow also depends on rule (B)'s temp carve-out, so `ZENSU_BSWGATE_TEMP_DIRS`
silently governs whether the shipped cleanup passes. Do not "fix" a deny there by
writing `ZENSU_BASH_WRITE_GATE=off` into a skill: a
shipped escape prefix teaches the hatch and lands a self-inflicted bypass-ledger entry.
