---
paths:
  - "hooks/lib/bash-source-write-parse.js"
  - "hooks/pre-bash-source-write-gate.sh"
  - "hooks/checks/pre-bash-source-write-gate.sh"
  - "hooks/checks/pre-bash-zensu-gate.sh"
  - "hooks/lib/zensu-config.sh"
  - "hooks/lib/claude-path-v1.js"
  - "tests/structure/test-bash-source-write-gate.sh"
  - "tests/structure/git-repo-escape.test.js"
---

# Git Mutation Tables (`hooks/lib/bash-source-write-parse.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

**The gate is OPT-IN.** `hooks/pre-bash-source-write-gate.sh` runs rules (A), (B) and (C) only
when `zensu_hook_opted_in bashWriteGate` holds, which is an explicit boolean `true` in the
merged Zensu config; absent, `false` or a quoted `"true"` leaves the gate off. The same reader
backs `zensu_tdd_strict_enabled`, so the opt-in rule has one implementation. The Session
Control rebind check (`BSWG_MODE=control`) sits ABOVE that config check and runs regardless,
because it is a trust boundary rather than a convention — keep that order. The config check
in turn sits ABOVE the bind, so at the default the no-anchor deny of the two relaxed bind
states does not run either, and a project `.zensu/config.json` opt-in cannot reach it: the
opt-in is read through `CLAUDE_PROJECT_DIR` ahead of the bind, and that deny runs only when that
directory is unusable, so only a `~/.zensu/config.json` or `ZENSU_CONFIG` opt-in does. A foreign record is still refused at the default, by the
all-tool capability gate rather than here. The default flipped
on measured evidence: a seeded sample of 156 transcripts from September 2026 held 27 denies in
11 sessions, none of which stopped a real mistake, while 14 blocked intended work (takeover
moves, commits in a session's own worktree after the host moved it, multi-repository layouts)
and 1,085 commands carried a gate-off prefix, which the auto-mode classifier refused 19 times.
Every suite that exercises the rules therefore opts the gate in through a fixture of its own
that sets `{"hooks":{"bashWriteGate":true}}` — `CFG_ON` in the gate suite, `$SBOX/config.json`
in the bypass-ledger suite, the fixture's `.zensu/config.json` in the live e2e layer, and a
`gate-on-config.json` elsewhere; a fixture that points at the defaults now tests a gate that
does nothing. In the gate suite W5 and W5b pin the opt-in and the shared note, the W29 family
the default-off behavior on a bound session, and the `d`-suffixed unbound rows plus W87e2 and
W87g2 the same order in the relaxed and foreign-record states; `O29a2` and `O29f` in the
orphaned-root suite and `P5h2`/`P5h4`/`P5z2` in the bypass-ledger suite do the same there. **Version: `patch`** — no schema
field, strict key set, hook registration, matcher or attestation moves; only the default of a
permissively read key and the deny wording change.

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
The hook header in `hooks/checks/pre-bash-source-write-gate.sh` must NAME `GIT_MUTATIONS`
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
/ `continuationPlan` in `skills/session-trail/scripts/trail.mjs`, flow 3 and its step-4
placement paragraph in `skills/session-trail/references/takeover.md`, the Limits bullet in
`skills/session-trail/references/limits.md`, and
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
`CLAUDE_PROJECT_DIR` to a user) and flow 3 in `skills/session-trail/references/takeover.md`. The rule letters are named by `writeAnchor`'s
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
`hooks/checks/pre-bash-source-write-gate.sh` exempts
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
back unchanged — and each consumer applies its own policy on top. The consumers are a
GREP — `grep -rn 'msysDrivePrefix' hooks skills` — and not a bound. As of this writing:
`normalizeHostPathInput` in that same file, `msysToDrive` in the parser,
`hooks/lib/zensu-doctor-invocation.js`, `configLayers` in
`hooks/lib/session-auto-adopt-v1.js` (a driveless MSYS spelling of a config path falls
to "adoption enabled", because a config that cannot be read must not switch a repair
off), and — the first outside `hooks/` — `hostPath` in
`skills/session-trail/scripts/trail.mjs`, whose policy is a further one again (it FAILS
when the module cannot be loaded). The two the sentence below
contrasts are the two whose policies are opposites: its own
`normalizeHostPathInput` layers a fail-closed-by-THROWING policy for the session-control
trust boundary, while `msysToDrive` in the parser declines that policy. It has to: the
parser RETURNS a deny reason, so an exception would exit non-zero and the hook's fail-closed
branch would deny every Bash call in the session rather than the one command — and
`/var/folders/x`, a DEFAULT entry of the rule-(B) temp list, is one of the spellings that
policy throws on. That is the whole reason the split exists; do not "simplify" the parser
onto `normalizeHostPathInput`. This is the one EAGER sibling `require` in
`bash-source-write-parse.js` (the other, `./powershell-command-v1.js`, loads only for a
PowerShell payload, and a failed load denies that call with its own reason), taken deliberately so a fourth `within()`↔`isInside()`-style
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

**The harness lies on Windows in four ways, and each one fails SILENTLY on POSIX.**
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
- **Hand the command to `node` over stdin, never through an environment variable.**
  MSYS rewrites an environment value it takes for a path on its way into a native
  binary, and a command that starts with a rooted path is such a value. While
  `payload()` passed the command as `CMD`, W237 (`/usr/bin/ENV …`), W245
  (`/usr/bin/GIT …`) and W323 (`>/dev/null git …`) allowed on Windows in run
  41646817779 while the parser was right. W256 starts with `/usr/bin/cd` and stayed
  green only because its second command denies by rule (A) whatever becomes of its
  first word. W552 to W554 also start with a redirection to `/dev/null` and stayed
  green, so a green check of that shape proves nothing about the rewrite. `payload()`
  now pipes the command into `node`, as the host delivers it, and **W3i** pins that a
  rooted command arrives verbatim.

**The Windows timeout for this suite is a coverage boundary, not a formality.** At
`timeoutMs: 300000` in `tests/profiles/windows-ci.v1.json` the shard killed the suite
after roughly 210 of its checks, always mid-run at W122 — so W224, W233/W234 and
everything after them never executed on Windows at all while the shard still reported.
It is 600000 now, and run 41646817779 used 528 s of it for 605 checks. Adding checks costs Windows wall
clock; if the shard starts reporting `TIMED_OUT` again, the tail of the file has gone
unverified regardless of how many checks passed before it.

**Program names are read as a case-insensitive file system resolves them.** `programName(word,
isWindows)` delegates to `programName(value, platform, fold)` in `hooks/lib/claude-path-v1.js`
with the policy `"always"`, which keeps the part after the last `/` (on win32 also after the last
`\`), drops a `.exe` suffix in any case and folds with `toUpperCase().toLowerCase()`, on every
platform; `"platform"` folds only on darwin and win32 and any other value leaves the case: macOS and
Windows resolve `GIT`, `git.exe` or `ENV` as the lowercase program, and the parser cannot know the
file system of each `PATH` directory. `WRAP` matches on it in `detectControlMutation` and in the
rule loop, and a folded `program` decides `git`, `sed` and `dd`. The tee channel folds only in
command position (`program === "tee"`); elsewhere in the segment it stays the literal word `tee`,
because a folded scan of every token made `grep -n TEE src/app.rs` or a `drivers/tee` operand a
tee write. In `detectControlMutation`, `cmd0` keeps the written basename for the builtins
(`export`, `declare`, `typeset`, `readonly`, `local`, `unset`, `printf`, `read`), because the shell
runs any other spelling as an external program, which cannot change the shell's variables; an
over-deny there is the safe direction. The rule loop is stricter, because its `cmd0` moves the
tracked cwd (`cd`) and carries `GIT_DIR`/`GIT_WORK_TREE` (`export`, `declare -x`, `typeset -x`),
and a wrong move is an allow: `cmd0` is the word after quote removal only when it holds no `/`
and every wrapper skipped before it is exactly `command` or `builtin` (`SHELL_WRAP`), the two
builtins that keep a builtin in the current shell, or the unquoted `time` keyword at the start of
the command, and empty otherwise. A quoted `\time` or a `time` after an assignment is the external
program, so it leaves the cwd. Folding the wrapper skip without that
rule let `ENV cd /tmp; sed -i … src/app.rs` pass rule (A), and lowercase `env cd`, `sudo cd` and
`/usr/bin/cd` already moved the tracked cwd on the base. `detectChannels` matches `tee`, `sed -i`
and `dd of=` with the `iu` flags, an optional `.exe` and an optional closing quote, after a
backslash, a quote, `(` or a backtick as well as the earlier boundaries, and a second pass reads
each command's program word through `commandWords`, so the always-on
`CLAUDE_ENV_FILE` deny and the secret scan's Bash trigger (`hooks/lib/secret-scan-decide.js` scans
a Bash command only when the detector reports a channel) both read those spellings and the
quote-removed ones. BSD sed's `-I`, `--in-place` (and its abbreviations) and an option cluster
that holds `i` or `I` before an `e` or `f` edit in place like `-i`, in both readers (`sedInPlace`
for rule (A)); `-l` is read as a flag, because BSD sed takes no operand for it.

**Every word is read after the shell's quote removal, and the command word past each wrapper's own
options.** `segmentWords` splits a lexer segment on unquoted whitespace and removes quotes the way
bash does: a backslash, single and double quotes anywhere in the word, `$'…'` with the escapes
bash 3.2 decodes (measured: `\u` included, an unknown escape keeps its backslash, a NUL ends the
quoted part), and `$"…"` as double quotes. An expansion stays in the value verbatim, so the
`UNEXPANDED` rules still see it. An unquoted `<` or `>` ends the word and starts an operator token,
and `splitRedirects` takes the operators and their targets out of the word list, so redirections
before or between the words no longer hide the command word and `x>file` writes `file`.
`logicalText` builds each logical line in one pass: `scanLine` carries the quote state across
physical lines, so a newline inside quotes stays in the word and a backslash-newline outside single
quotes is removed, except after a `#` that starts a word outside quotes, because bash does not
continue a comment (`joinContinuations` is that join alone). `heredocDelimiters` then finds every
unquoted `<<` and `<<-` of the logical line outside comments and arithmetic, with the whole
quote-removed word as the delimiter, and `skipHeredocs` drops each body up to its exact delimiter
line, leading tabs stripped for `<<-`; `stripHeredocs` runs the same scanner per physical line.
`lex()` keeps an `&` that is part of a redirection operator (`2>&1`, `&>`, an `&>` glued to a
word) and the `|` of `>|` and `>&|` in the segment, so neither resets the tracked cwd as a
background or a pipe would, but not after an escaped `\<` or `\>`, which bash reads as a word
character. `redirectOperator` reads zsh's `>>|`, `>>&`, `&>|`, `&>>|`, `>&|` and `>!` whole, and
`splitRedirects` reads every output operator as a write except a `>&` or `>>&` whose target is a
descriptor number or `-`, plus `n<>` on a descriptor other than 0, so no text rewrite runs before
the reader; only `detectChannels` keeps the base's text collapse, for its channel test. `ansiC`
finds the end of `$'…'` before it decodes, so a `\c` before the closing quote does not swallow it,
`braceEnd` ends a `${…}` at its matching brace across nested quotes and `${`, and `$$` is one unit,
inside a nested string too. bash nests a single quote inside a double-quoted `${…}` and zsh reads
it as a character, so `readings` reads every segment both ways (`bashQuotes`), the Session Control
check and `detectChannels` judge both, and `main()` runs its rule loop (`scan`) a second time when
the two readings split a segment differently. `commandWords` skips the unquoted reserved words in
`RESERVED_WORDS`, reads the assignment words of `SHELL_ASSIGNMENT` (`NAME=`, `NAME+=`, `NAME[i]=`; only a plain `NAME=` feeds
`GIT_*` and the escape prefixes), then each `WRAP` name with the options `WRAPPER_OPTIONS` lists for
it, long options by unique prefix as getopt reads them, and the quote-removed `NAME=value` words
`env` and `sudo` take (the other wrappers keep the base's over-read). Its `ops` record `env -i`,
`env -`, `exec -c` (clear), `env -u` (unset), `env -C` and `sudo -D` (chdir) and every wrapper
assignment in order; `env -S` splices its split string back into the argument list, split by
`envSplit` the way env splits it (`\_` separates, `\c` stops, a `#` starts a comment), at most
`MAX_SPLITS` times, and a further `-S` sets `overflow`, which the Session Control check refuses.
That check refuses a protected name in any assignment, an unset op of one as removal,
`export -n`/`declare +x`/`typeset +x` and `-a`/`-A` of one as removal, `printf -vNAME`, a `for`,
`select` or `foreach` loop name and a `{NAME}` redirection as a rebind, and reads a subscript as its
name (`protectedName`); a full clear alone is NOT refused, because it names no input and
`model-bind` refuses a missing `CLAUDE_CODE_SESSION_ID`. `detectControlMutation` refuses when any of
three readings in `controlFinding` finds a rebind or a removal: `readControlMutation` (this
reader) and `wordSplitControlMutation` (a port of the earlier whitespace reading), which both apply
`baseControlMutation`, the rows the base had, so the always-on check refuses at least what the
base refused (drop the second reading and every spelling the new reader misreads becomes an
allow); and `shellControlMutation`, which runs `shellFinding` under both quote readings.
`shellFinding` follows shell grammar instead of splitting: it keeps quotes, `$'…'` and `$"…"`
whole, starts a comment only where a word starts, also inside `[[ … ]]` and an array literal
(`parenWord` drops it from the text `arrayFinding` reads), reads each heredoc at the end of its line
(an unquoted body through `expansions` after `cooked` removes its line continuations, a quoted one
not at all), tracks `case` patterns (`esac` after `|` or a leading `(` stays a pattern word; a
separator pops a `case` head that never reached `in`, and `;;`, `;&` or `;;&` unwinds to the
nearest `case`), `{ }` groups (only where `{` is the reserved word: command position or after
`coproc NAME`; a `)` unwinds everything down to its subshell), subshells, function definitions,
`[[ … ]]` (`conditional`, reading a regex operand of `=~` and an extended pattern as one word with
its parentheses and `|`, and ending only at `]]`, or where the old reading ended when no `]]`
follows; it also returns `broken`, the old reading's end before a later `]]` or the first newline
when neither follows, and the scanner reads the commands from there as well, then judges the words
before `]]` and returns to command position, so `then`, `do` or `}` right after it are read) and
`(( … ))`, also after a `PAREN_HEADS` word written directly before the parenthesis outside a
`case` pattern. Command position follows the shell: `commandStart`, which `atCommand` and
`assignPos` share, skips `coproc` and a `time` keyword with at most one `-p` and then at most one
`--`, and reads `time` as the keyword only at the start of a pipeline (`piped`) and never after
`coproc`; `atCommand` is false after a leading redirection (`redirected`) only in the bash quote
reading, because bash reads `[[`, `case` and `{` there as plain words while zsh 5.9 opens them
(measured), and neither reading opens `[[` or `case` inside a `case` pattern; after `coproc NAME`
a `COPROC_BODIES` word, a brace
group or a subshell, also with NAME glued to the parenthesis, is read as its compound command, and
a protected NAME there is held as a rebind (`held`) until the scan returns. `commandWords` skips
`time --` too. The scanner enters every `$(…)`, backtick, `<(…)`, zsh `=(…)` and bash 5.3's
`${ …; }` and `${| …; }` as commands, also inside double quotes and heredoc bodies, and reads zsh's
brace-less `$NAME[…]` subscript as arithmetic. `shellControlMutation` reads a command that holds a
line continuation a second time through `joinedText`, which joins a backslash-newline only where
the shell's input reader does: outside single quotes and comments, never in a quoted-delimiter
heredoc body, and in an unquoted body before the line is compared with its delimiter
(`keepHeredocs`), so a lookahead, a heredoc delimiter or a delimiter line split by a continuation
reads as the shell joins it. `heredocWord` ends a delimiter only at a shell blank or operator, so a
no-break space stays inside it. Each simple command it finds goes through
`commandWords` and `builtinControlMutation` (`commandFinding`), so the rows this change added,
`nameref` included, run only on commands found outside quotes, and quoted text that names
`declare -n` stays allowed. `builtinControlMutation` is `baseControlMutation` plus the name
operands of `getopts`, `mapfile`/`readarray`, `wait`, `vared`, `getln`, `set ±A` (attached or
not), `integer`/`float` and zsh's `read NAME?prompt` (`operandFinding`), the operand of
`printf`/`print -v`, `wait -p`, `read -a` and bash 5.3's `compgen -V` in any option cluster,
attached or not (`nameOption`), the arithmetic of `let` and of zsh's `repeat`, `shift`, `return`,
`break` and `continue`, the subscript of every declaration operand and of a `test` or `[` `-v`
operand (`subscriptFinding`), a protected operand of a `declare`, `typeset` or `local` whose
options convert the value (a cluster holding `T`, `i`, `E`, `F`, `l`, `u`, `L`, `R` or `Z`) as a
rebind, a protected name that zsh's `unset -m` pattern matches (`patternFinding`, which translates
the glob and refuses one it cannot translate as `dynamic`), an option word built at run time in
front of a protected operand of an `OPTION_BUILTINS` command as `dynamic`, and
`declare`/`typeset`/`local -n` as `nameref`. `commandFinding` reads `coproc` itself: a protected
first operand is a rebind, and otherwise the simple command after it is judged.
The scanner hands each `$((…))`, `((…))`, `$[…]`, assignment-word subscript (bracket-matched across
blanks, also in a declaration operand), array-literal element subscript (`arrayFinding`) and
`-eq`-family operand to `arithmeticFinding`, which bracket-matches nested subscripts, and each
`${…}` body to `parameterFinding`, which parses zsh's flags (`zshFlagsEnd`), the `=`, `~`, `^` and
`+` prefixes and the special parameters, and falls back to `arithmeticFinding` on a body it cannot
parse. A `$((` that does not close with `))` is read again as a command substitution. A name built
at run time is refused as `dynamic` only where that spelling has no common use: an `env -S` word
(`split`) whose `${` reaches `env` unexpanded (`literal`: the split string came from a split word
or its written spelling holds a single quote or a backslash) and sits in an option, assignment or
command position sets `dynamic` on the command reader, and so do an arithmetic lvalue spelled with `$` and zsh's `${(P)…}` assignment; a
shell-built operand stays allowed, because `export $(cat .env | xargs)` is a common idiom and
`source` reaches the same assignments. Nesting past `MAX_NESTING` (64), or a reading past a budget
of 32 steps per character plus 65,536, returns `deep`, refused with its own reason; the budget
bounds the re-reading of a `$((` as a substitution. `heredocDelimiters` skips `${…}` and `$[…]`, and
`heredocWord` reads `$"…"` as a quoted word, so neither hides later lines from any reading. The
rule loop runs git
with `-C <dir>` for each chdir op, so `gitTargets` judges an unexpanded one as it judges an
unexpanded `-C`, resolves tee, `sed -i` and `dd of=` operands against that directory (a relative
operand under an unexpanded one is not judged, and targets mode reports it as a write target), and
folds the ops over the carried and inline `GIT_*` values. W265 and W267-W554 in the
gate suite, F8c and D10-D14 in `tests/structure/test-secret-scan-gate.sh`, and the reader cases of
`git-repo-escape.test.js` pin it. **Known residuals, all stated in `docs/gates.md`:** zsh's other
readings (an unknown `$'…'` escape, `$"…"`, `=cmd`, `noglob`, `nocorrect`, `-`) are not applied,
although the Bash tool runs zsh where that is the user's shell (measured on macOS); a program word
built at run time, aliases and functions; a variable name the shell builds at run time in a
builtin or wrapper operand; code built or stored at run time (`eval`, `trap`, `bash -c`, `source`,
a script file, a `mapfile -C` callback); arithmetic through another variable's value or an integer
attribute; zsh's numeric `printf` arguments and module builtins; and wrappers outside `WRAP`. The
third reading is a hand-written approximation of the shell grammar, and a construct it misreads
can hide the commands after it, so every misreading is an allow. `lex()` still splits at a `;`, `&` or `|` inside quotes, so the two base
readers can refuse quoted text that spells a protected assignment. `[ … -eq … ]` and `test -eq`
evaluate no arithmetic in bash 5 or zsh 5.9 (measured), so those operands are not read; the
`-v NAME[…]` operand of `[[`, `[` and `test` does evaluate its subscript in bash 5.3 (measured),
and `subscriptFinding` reads it.

**The env-file path comparison folds on every platform.** `controlPathNamespace` and
`commandRefersToControlPath` pass both sides through `foldPath` (NFC, then
`toUpperCase().toLowerCase()`), because APFS resolves letter case and normalization variants of one
name to the same file (measured) and the parser cannot know the volume behind `CLAUDE_ENV_FILE`;
`wordsReferToControlPath` adds the quote-removed words, so `/Users/R\unner/…` matches as well. A
false refusal needs a write to a different file whose path folds to the env file's, which on a
case-sensitive volume is the only cost. W74 pins the case fold, W308 the decomposed spelling and
W318 the quote-removed path.

**One program-name helper, four readers.** `programName` in `claude-path-v1.js` is the shared total
helper. The parser uses it; `commandName` in `subagent-shell-guard-v1.js` (the policy
`"platform"`, without the win32 backslash cut), `commandName` in `work-order-v1.js` (no fold, no
`.exe` strip) and `commandBase` in `powershell-command-v1.js` (PowerShell's own resolution, which
cuts both separators everywhere and strips module qualifiers and more extensions) still carry code
of their own, because the unpushed branches `claude/jolly-diffie-7523da` and
`claude/work-order-name-case` rewrite exactly those functions. The unit case `the program-name
readers of the gates, compared over one corpus` pins each difference, so moving a reader onto the
helper changes a pinned line rather than a verdict nobody sees. Pins: the program-name
cases of `tests/structure/git-repo-escape.test.js`, W235-W266 in
`tests/structure/test-bash-source-write-gate.sh` and F8b in
`tests/structure/test-secret-scan-gate.sh`. **Version: `minor`** — the always-on Session Control
check refuses calls it let through, which changes the capability set of every session a newer
installation would serve (`.claude/rules/runtime-lineage.md`).

**Cross-file couplings — stated as a CRITERION, never a count**, because the count was "Three" while the list already held four: every hand-copy of a rule this parser owns, plus every PROSE assertion elsewhere that a message this parser emits says a particular thing. (The MSYS drive rule is deliberately NOT among them: it is
shared through `claude-path-v1.js`'s `msysDrivePrefix` rather than hand-copied — see the
paragraph above.) `WRAP` — the transparent-wrapper set rule (C)'s
`program` anchoring depends on — is hand-duplicated as a JS literal in
`hooks/checks/pre-bash-zensu-gate.sh`, where it drives that gate's token scan. The CLI gate also
unwraps through `WRAPPERS` in `hooks/lib/subagent-shell-guard-v1.js`, a larger set, and gates
what either reading finds, so `timeout`, `xargs` or `stdbuf` in front of a command is
transparent to the CLI gate and not to rule (C). The same guard restates the parser's shell
grammar (`RESERVED_WORDS`, `ASSIGNMENT_RE` for `SHELL_ASSIGNMENT`, `DIRECTORY_WRAPPERS` for
`SHELL_WRAP`, `WRAPPERS` for `WRAPPER_OPTIONS`); `WRAP` itself is derived from the keys of
`WRAPPER_OPTIONS`, so a wrapper never lacks its option table. The unit case `the shell readers of
the source-write parser and the subagent shell guard, compared over one corpus` pins where the two
readers agree and their three differences (`env -S`, `sudo -h` and the guard's extra wrappers), so
a change to either table moves a pinned line.
`within()` is a hand-copy of `isInside` in
`hooks/lib/reviewer-capability-v1.js`, held in lockstep only by W3b — and `contains()` in
`hooks/lib/zensu-autopilot-state.sh` is a further member this roster omitted while the
predicate was already anchored: it decides `mayHoldWorkspace`, so an unanchored spelling
reports `<project>/..bak` as a FREE workspace and lets a standalone `/zensu:build` chain arm
underneath a live durable run in the same tree. W18b in
`tests/structure/test-autopilot-state-machine.sh` pins both of its anchoring clauses and
forbids the bare `startsWith("..")` form returning; W18 alone did not, and no fixture
builds a `..`-prefixed worktree, so the revert was green from both directions — and the same
predicate exists in `session-control-core-v1.js`, `review-evidence-lease-v1.js` and
`hooks/lib/state-path-safety-v1.js` (the path walk that `_tdd_paths_safe` and the tdd-phase
lease processes load), with an UNANCHORED `startsWith("..")` variant in
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
PROSE rather than a table:** every reason rules (A), (B) and (C) produce ends with `OPT_IN_NOTE`,
which names `hooks.bashWriteGate` and leaves an intended command to the user, and never the
escape prefix. On the unbound path the hook appends its binding paragraph after that reason, so
the deny contains the note without ending on it. Four of the hook's own denies — the no-anchor deny, the two unbound parser failures and the
empty recorded root — carry the same sentence through its `OPT_IN_NOTE` shell variable, a
hand-copy that W5b holds equal to the parser's exported constant; the bound parser-failure
deny names `hooks.bashWriteGate` in a remedy of its own, which W218 pins. `skills/session-trail` (`references/takeover.md` and the emitted `MOVE_ALTERNATIVE`) ASSERTS
that shape — the refusal names the config key and no escape. W32, W33, W87 and W121 in
`tests/structure/test-bash-source-write-gate.sh` pin the note's words and the prefix's
absence on the parser side; `T35b` and `WT8v12`/`WT8v12b` pin each skill carrier's own
wording, but nothing compares either against the parser, so re-check that skill by hand
before rewording the note. And
`skills/pr-team-review` Phase E depends on `worktree remove` being judged on the tree
it destroys rather than on the addressed repository — narrow that carve-out and the
skill's documented cleanup starts denying, which is what W181/W185-W187 exist to
catch. That flow also depends on rule (B)'s temp carve-out, so `ZENSU_BSWGATE_TEMP_DIRS`
silently governs whether the shipped cleanup passes. Do not "fix" a deny there by
writing `ZENSU_BASH_WRITE_GATE=off` into a skill: a
shipped escape prefix teaches the hatch and lands a self-inflicted bypass-ledger entry.
