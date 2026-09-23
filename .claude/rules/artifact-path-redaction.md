---
paths:
  - "hooks/lib/zensu-artifact-redact-v1.js"
  - "hooks/post-artifact-redact.sh"
  - "tests/structure/test-artifact-redaction.sh"
---

# Artifact Path Redaction (`hooks/lib/zensu-artifact-redact-v1.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

Consuming repos commit `.zensu/plans/{ts}_tdd-{slug}.md` and
`.zensu/logs/{ts}_tdd-{slug}.log` as an audit trail and may later open-source the
repository. A scan of ~27k committed log lines across four such repos found **no
credential values** and ~436 lines carrying an absolute developer path, almost all
inside the `cmd="…"` field of CHECKPOINT/AUDIT lines. The module is the single
source of truth for what makes those two artifacts publishable.

**THREE RULES, and the ORDER is the contract**: project root(s) → `<project>`,
`$HOME` → `~`, residual `/Users/<seg>` / `/home/<seg>` / `/root` (and the Windows
`\Users\<seg>`) → `<home>`. Rule 1 must precede rule 2 or a nested project decays
to `~/IdeaProjects/<product>/<repo>`, which still names the product. Rule 3 is what
makes the guarantee CHECKABLE — "no `/Users/` in the file" is testable, "no
sensitive path" is not. Every rule is bounded on BOTH sides; drop the right bound
and `/homework` becomes `<home>work`, drop the left and the rule fires inside
`src/home/index.ts`. The segment class also excludes quotes, because eating the
closing `"` of a `cmd="…"` field desynchronizes the claim from its witness entry.

**Secret NAMES are never redacted** — a name grants no access and this repo's own
workflows carry `secrets.GITHUB_TOKEN` in public. Credential VALUES are a different
problem: they belong to `hooks/pre-write-secret-scan.sh` / `secret-patterns.js`, and
because moving the log message off the command line removed that gate's incidental
sight of it, `append` RESTORES the control at the chokepoint — it runs the same
curated rules over the message and REFUSES on a match rather than redacting, since
rewriting a credential silently would hide it from whoever has to rotate it. It
honours `ZENSU_SECRET_SCAN=off` and the `zensu-secret-allow` line marker — the two
escapes the gate itself teaches — so a heuristic false positive is not a wedge.

**The ledger picture is narrower than "unrecorded", and worth stating precisely
because a first draft of this paragraph got it wrong.** `pre-write-secret-scan.sh`
carries TWO ledger sites: it records the AMBIENT `ZENSU_SECRET_SCAN=off` directly,
before the decider runs at all, and it records the INLINE per-command prefix
through the decider's `__bypass__` verdict. `append` now carries a ledger site of its
own, at the log-write chokepoint, best-effort in a subshell so a ledger write can never
cost a log line. **State its channel by MECHANISM, not by outcome — an earlier revision
of this paragraph got the outcome exactly backwards.** It tests its own PROCESS
ENVIRONMENT (`[ "${ZENSU_SECRET_SCAN:-}" = "off" ]`), and a shell assignment written in
front of a command is exported into that command's environment, so the verb cannot tell
an inline prefix on its own invocation from an exported one and records BOTH. R53 is
the pin, and it uses the inline spelling. What it never records is a prefix on some
OTHER command — only the decider sees those, and this verb never consults it. The
direction of the old error is worth naming: the ledger recorded MORE than the
documentation claimed, so no rendered entry was ever false. One bound travels with the
new site and is not cosmetic: the
identity comes from `zensu_resolve_session_id ""`, which reads `ZENSU_SESSION_KEY`, so
an `append` run outside a Zensu-started session records nothing. This verb deliberately
carries no session bind and there is no second source for that identity.
A prefix on some OTHER command neither silences this scan nor is recorded here — it
never enters this process. What remains open is narrower: whether the DECIDER ledgers
an inline prefix on the `append` command itself.
"May or may not" is the honest word: `detectChannels` is not tokenized and not
quote-aware, so a `>` anywhere in the `--message` text — `"RED -> GREEN"` is
enough — makes it report a redirect and the escape IS ledgered. The absence of an
entry is therefore a property of the message text, never of the verb. The ledger's
invariant is soundness — everything it renders is true — not completeness, so none
of this makes a rendered entry false.

**`hooks.secretScan:false` does NOT disable this scan.** Only the env escapes do.
The divergence is deliberate: `zensu_hook_enabled` spawns `node` per call and
`append` runs once per log line, so consulting the config here would put a process
spawn on the hottest path in the workflow. Recorded rather than left for someone to
discover from a refusal naming a variable the config row never mentions.

**FOUR WRITERS apply it, and the last exists because the first two cannot be
enough:** `zensu-log.sh append` (the narrative log, at write time), BOTH witness
writers — `hooks/pre-bash-witness.sh` for the `BASH-ATTEMPT cmd` field and
`hooks/post-bash-witness.sh` for the `BASH cmd` one, which share the single
extraction in `hooks/lib/zensu-witness.sh` precisely so their substitution cannot
diverge (see the symmetry rule below, and §"Witness Attempt Half" for why there are
two of them at all), and
`hooks/post-artifact-redact.sh` (a bounded sweep on BOTH registered matchers,
plus the named `file_path` on the write matchers). Both artifacts are
MODEL-authored, so a guarantee that holds only while the model follows a recipe is
not a guarantee.

**The witness is redacted for SYMMETRY, not for its own safety.** It is gitignored
in THIS repository, and the plugin ships nothing that makes that true in a consuming
one — say "in this repo", never "everywhere". `zensu-evidence-crosscheck.js` matches a claim against a
witness entry by EQUALITY, so redacting one side only turns every claim naming an
absolute path into an `EVIDENCE GAP`. Each writer passes its OWN authority plus
`CLAUDE_PROJECT_DIR` when that is set — never the other writer's, so agreement
rests on the two coinciding, which the skill's own log path makes the normal case
(`projectRoot` accepts an array): `append` derives the root from the
artifact path, the witness hook from the Session Control record, and they must
substitute identically even when the two authorities disagree. **Only `cmd` is
redacted — `tail` deliberately is not.** Nothing compares the tail; its only reader
is `failureMarker`, and redaction there is purely subtractive, so a `failed` token
inside an absolute path would vanish and an `EVIDENCE CONTRADICTION` would downgrade
to `verified`.

**The log WRITE happens inside the module, never through a shell redirect.** A
`>>` names a path and follows what it finds, so the validation and the write name
different objects — and `[ -L ]` is blind to a HARD link, which
`resolveArtifactTarget` cannot see either because it canonicalizes only the parent.
Planting one inside `.zensu/logs/` turned the verb into an append/truncate
primitive on any file on the same filesystem. `writeArtifactLine` opens with `O_NOFOLLOW`, judges the descriptor (`isFile`,
`nlink === 1`, and the expected dev/ino re-derived from the canonical parent, which
catches the name resolving to a DIFFERENT inode than the one opened — the
rename/replace race, NOT an intermediate-directory swap: when nothing moved the
re-derived parent is the lexical parent, so the lstat re-traverses what the open
traversed and both move together), and never truncates in place. `O_TRUNC`
stays out of the open flags, because truncating at open would run BEFORE the `nlink`
check could refuse. The destructive mode publishes by RENAME instead: an earlier
spelling ran `ftruncate` after those checks, which committed the destroy before the
new bytes existed and left the artifact empty on a failed write, so `mode: 'replace'`
now routes to `replaceArtifactFile`, which validates the target through a read-only
descriptor, writes an `O_EXCL` temp beside it, `fsync`s, re-checks, and renames. It is
named for what it can do: `mode: 'replace'` destroys, and it refuses any bucket but
`logs` and any `witness-` name, so the log verb cannot reach a committed plan or the
crosscheck's evidence.

**`append` carries no leading `--` on purpose** — a leading `--` selects the Session
Control binding case, and a log append must survive a shell with no
`CLAUDE_CODE_SESSION_ID`. That is also why its CONTAINMENT is not optional: the verb
performs the write `bash-source-write-parse.js` rules (A)/(B) exist to judge, while
carrying none of the redirect/tee/heredoc tokens that make a command parseable as a
channel, so no Bash gate can see it. `resolveArtifactTarget` refuses any path that is
not a real `<root>/.zensu/{plans,logs}/<file>`, canonicalizing the artifact directory
and comparing it against the canonical root's own join — never against a second
realpath of the same lexical path, which resolves through the same symlink and
therefore proves nothing.

**The array collapse is a real cost, not just a feature.** When the two
authorities name genuinely DIFFERENT directories, both render `<project>`, so the
placeholder stops being a unique referent and a path outside the session's project
reads as if it were inside it. The `append` path forces agreement through
`expectedRoot` only when `CLAUDE_PROJECT_DIR` is set — without it there is no
second authority to disagree with — while the witness passes both without a
check, deliberately, because losing the equality match is worse than an ambiguous
placeholder in a gitignored file.

**A fifth `within()`-family hand-copy lives in this feature** and belongs on the roster
in §"Git Mutation Tables": the `append` verb's cwd anchor spells its own containment
check inline in the `node -e` program (`here !== rootReal && !here.startsWith(rootReal +
path.sep)`), rather than calling the module that owns containment. It is the ANCHORED
form, so it carries none of the `..bak` defect, and it is unreachable from a unit layer
for the same reason the requirements-gate copies are.

**Coupled sites that move together:** the module's `ARTIFACT_BUCKETS` / `ARTIFACT_DIR`,
which are module-INTERNAL — `post-artifact-redact.sh` consumes the layout TRANSITIVELY,
by calling `sweepTargets` and `redactFile` rather than joining
`.zensu/plans` and `.zensu/logs` itself, and it never imported either constant; an
earlier revision of this clause said it consumed them directly, and the module header
now records the same correction. `SWEEP_WINDOW_SECONDS` and `SWEEP_MAX_TARGETS` are
NAMED in the hook's own header prose and imported by nothing — it calls
`mod.sweepTargets(project)` with no options and the module defaults apply internally —
so that coupling is documentation-only and breaks SILENTLY, which is the same trap the
module header now records in its own words;
`WITNESS_PREFIX`'s only consumer outside the module is R19 in
`tests/structure/test-artifact-redaction.sh`, which the next clause already names.
Then: the `WITNESS_PREFIX` ↔ `post-bash-witness.sh`'s own
`witness-${SANITIZED_SESSION}.log` spelling, pinned by R19; the `Edit|Write|MultiEdit`
matcher spelling in FIVE places — `hooks/hooks.json`, `docs/configuration.md`,
`docs/tdd-manager-workflow.md`, R0c, and the JS disjunction in
`hooks/post-artifact-redact.sh` that actually selects the branch, which is the one
a `NotebookEdit` added to the matcher would silently miss; the hook
count in `docs/configuration.md` (header, prose, and the `#hooks-N` anchor in
`docs/architecture.md` — the anchor was outside H3's file list until the reviewer-spawn
grant landed, and `test-readme-hook-count-sync.sh` H3 now scans that file too, so all three
are pinned; H3 remains purely NEGATIVE, forbidding a stray number without asserting that a
`#hooks-N` reference still exists, so a reworded or deleted cross-link still passes); the
secure-open inventory in `tests/structure/test-windows-portability-guards.sh`; and
the `msysSpelling` inverse, which is a HAND-COPY of `claude-path-v1.js`'s rule
validated by round-tripping through `msysDrivePrefix` — that module exports no
inverse, and a change to the shared rule silently drops the MSYS spelling out of
`rootSpellings` with no error; and `writeArtifactLine` performs NO redaction of its own — it is a raw write primitive
whose caller composes `redact` then `writeArtifactLine`, so a second caller of the
export would produce an unredacted line under `written: true`; the `--file` CLI has
no production consumer at all and exists for the suite, which is why containment is
enforced there too; `resolveArtifactTarget`'s returned FIELD NAMES (`ok`, `reason`, `path`, `bucket`,
`projectRoot`, `realParent`) — `zensu-log.sh append` reads `target.projectRoot` and
`sameInode` reads `target.realParent`, and renaming either silently reverts rule 1
in the case this design calls normal, under exit 0; the reason vocabulary itself — `CLEAN_REASONS`,
`TRANSIENT_REASONS` AND `NON_ARTIFACT_REASONS` are all exported precisely so no
consumer re-spells any part of it, because a renamed reason would otherwise make
the hook shout about every ordinary Write, and an implicit residual class already
made a routine race report as the worst outcome the hook can produce.

**The invariant is per-artifact, not per-directory.** `writeArtifactLine` refuses
any `witness-` name, and `hooks/post-bash-witness.sh` still writes its log with a
plain shell `>>`. That is deliberate — the witness is rewritten every run and is
gitignored in THIS repository — but it means "the write happens inside the module" is
a property of the two PUBLISHABLE artifacts only. Do NOT restate it as "never
committed": a consuming repo only gets that by adding `.zensu/state/` and `.zensu/logs/witness-*.log` itself.

**Operator-facing accounts that must move with it:** `docs/tdd-manager-workflow.md`
§"Publication safety of the plan and log" (which carries the narrative, including
the `SWEEP_WINDOW_SECONDS` value as prose), both hook rows in
`docs/configuration.md` — the `post-artifact-redact.sh` row, which is the ONE row
carrying BOTH sweep values as prose (`SWEEP_WINDOW_SECONDS` as "last 5 minutes" and
`SWEEP_MAX_TARGETS` as a bare `(25)`, so raising the cap silently falsifies a shipped
operator-facing doc). R49 in `tests/structure/test-artifact-redaction.sh` encodes that
same value twice more and breaks LOUDLY rather than silently, which is why it is named
here and not in the silent-coupling paragraph below — and raising the cap to the
fixture count or above does not merely fail it, it destroys its discrimination, because
the capped and uncapped arms then agree. A new cap needs a fixture count above it. Then
the redaction paragraph of the
`post-bash-witness.sh` row, which has already drifted once by claiming the `tail`
is redacted and carries no window at all — plus `docs/tdd-manager-workflow.md`'s §1 artifact paragraph, its
four-channel table and its §"Witness channel" paragraph (the line that drifted),
`docs/architecture.md`'s Graceful-Degradation bullet and its flagless-hook list,
`skills/tdd/SKILL.md` Principle 3 and Phase 2, and `templates/tdd-plan.md`.

**Test-side couplings, which break silently rather than loudly:** the manifest
entry in `tests/profiles/promptfoo-local-only.v1.json` (`run-all.sh` refuses to
execute at all when the manifest and the directory disagree) together with the
counts in `tests/SUITE-OVERVIEW.md`; the `append --log … --message …` command shape
built in `tests/structure/evidence-crosscheck-v1.test.js`, where a rename of the
verb or the flag changes what the cross-check excludes; and the grep-exact literals
of the secure-open inventory in `tests/structure/test-windows-portability-guards.sh` —
which is also the ONLY Windows pin any part of this module has, since
`test-artifact-redaction.sh` has no `windows-ci.v1.json` entry and the `\Users\<seg>`
rule and the `msysSpelling` inverse are therefore exercised on POSIX only
(`tests/SUITE-OVERVIEW.md` carries that decision and its reasoning);
and the mechanism-2 consumer list in the header of
`tests/structure/test-msys-special-plugin-module-boundaries.sh`, which stays true
only while a new module-transport consumer is added to it.

**Port-relevant.** The core half is `redact` / `redactFile` / `writeArtifactLine` /
`resolveArtifactTarget` / `sweepTargets` / `projectRootFromArtifactPath` /
`defaultHome` (both writers call it, so a port that omits it gets a TypeError in
its log writer) plus the
layout constants and ALL THREE reason sets (`CLEAN_REASONS`, `TRANSIENT_REASONS`,
`NON_ARTIFACT_REASONS` — an explicit partition, because an implicit residual class
once made a routine race report as the worst outcome the hook can produce), all in the host-neutral module — together
with its ONE sibling `require`, `claude-path-v1.js`'s `msysDrivePrefix`, without
which the module does not load at all. A SEVENTH host obligation goes with the log
verb: the credential-value scan, which couples it to `secret-patterns.js`'s
location, its `scan()` name and its `{matches:[{rule}]}` shape. A port that takes
the writer without it ships the writer minus the control this section says `append`
restores. The load-failure DIRECTION differs per
writer and a port must keep it: `append` fails closed (a lost log line is worse
than a loud refusal), both hooks fail open (a missing witness entry fails the
cross-check closed, and a PostToolUse hook must never block the call it follows). The host half is SIX obligations a port must re-decide: the
log-writer verb, the witness-side call, the PostToolUse hook and its registration,
which payload field carries the path, the module transport (this host renders the
lib DIRECTORY through `zensu-host-path.sh`), and — easiest to miss — the host's
TOOL-NAME vocabulary: both matchers sweep and only the write matchers add the
named path, so a port that takes the writer but keeps these names gets a hook that
returns on every call, module loaded and never redacting. A port that takes only the module gets
the rules and no writer. `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT
included in this change.

**The PostToolUse net is MAIN-THREAD only.** `zensu_hook_is_main_principal` gates
it, so a subagent's `Write` to a plan is caught only by a later main-thread pass —
on EITHER matcher, since both sweep — and only while the artifact is still younger
than `SWEEP_WINDOW_SECONDS`. Sweeping on the write matchers adds sampling points;
it extends no deadline, because the cutoff is the artifact's own mtime. The writer
verb is unaffected; this is a bound on the net, not on the guarantee's primary
path, and it is listed here rather than left to be discovered.

**Writer-side only.** Artifacts already committed in consuming repos are
untouched; this change makes everything written from now on publishable, and no
repository becomes safe to open-source because of it alone.

**Known bounds, stated rather than implied:** the rule is textual, so a path spelled
through a symlink or an alias matching no known root is not caught (macOS's
`/private/{tmp,var}` is the one pair handled by hand); a git repository root ABOVE the
project root is covered only insofar as `$HOME` covers it; the `Bash` sweep only
revisits artifacts modified within `SWEEP_WINDOW_SECONDS`, so earlier runs are out of
reach by design — this is a writer-side fix, not a history rewrite; email addresses and
internal URLs are NOT redacted; a DOUBLY encoded separator (`\\\\Users\\\\bob`, four
backslashes — JSON encoding applied twice) still leaves the user segment, because
the escaped-separator rules cap at two; neither writer produces that spelling, since
the witness redacts before `JSON.stringify`, so it sits inside the textual bound
rather than outside it; `expectedRoot` binds `append` only when
`CLAUDE_PROJECT_DIR` is set, so without it the containment is artifact-SHAPE only
and any project's `.zensu/logs` is an accepted destination — narrow, but not
nothing, and deliberately NOT gated on that variable: an earlier revision made
`--truncate` refuse without it and broke the shipped Phase 2 recipe outright,
because the variable is absent from the model's Bash environment on this host,
which is exactly why `{log_file}` is rendered from `${CLAUDE_PROJECT_DIR:-.}`.
An env var the caller sets is not an authority; what constrains the destructive
mode is the module; and nothing here recognizes a customer name or an internal hostname, which is why the English-only + repo-root-relative authoring rules
ship in `templates/tdd-plan.md` and `skills/tdd/SKILL.md` Phase 2 alongside the code.
`tests/structure/test-artifact-redaction.sh` pins the rules, every writer, every
refusal and the witness/claim equality.
