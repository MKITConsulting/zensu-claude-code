# zensu-claude-code Repo Conventions

## Language

**English only.** All code, comments, docs, commit messages, plan files,
prompts, fixture content, and pattern alternations must be in English.

Runtime `.zensu/plans/*.md` and `.zensu/logs/*.log` are gitignored HERE
(`.gitignore` ignores `.zensu/*` except `config.json`), but they are **no longer
exempt from this rule**. Consuming repos commit them as an audit trail and may
later open-source the repository, so the plugin now writes them to be
publishable: `hooks/lib/zensu-artifact-redact-v1.js` strips absolute developer
paths at write time, and `templates/tdd-plan.md` plus `skills/tdd/SKILL.md`
Phase 2 instruct the model to author both artifacts in English. A German plan
written in a German session would land in someone else's public history — which
is exactly the harm this rule exists to prevent, whether or not the file is
tracked here. Every tracked file must be English-only, and so must every
artifact the plugin emits.

**Carve-out — verbatim user-utterance match literals.** Hook directive strings
— and verbatim citations of those literals in structure-test pins, in
README/CHANGELOG feature descriptions, and in this carve-out — may contain
non-English phrases ONLY as match literals for real user input:
the TDD preference fast-paths (e.g. `'kein tdd'`, `'mit tdd'`, `'tdd bitte'`)
and the generic-action literals that are explicitly NOT a preference
(e.g. `'mach mal'`, `'los gehts'`, `'jetzt umsetzen'`) in
`plan-approved-delegate.sh` / `user-prompt-tdd-reminder.sh`. They exist to
recognize what multilingual users actually type, never as prose. Keep these
phrase lists in lockstep across every directive variant (strict and vanilla)
— never edit one variant alone.

**Second carve-out — eval grader alternations matching MODEL output.** The same
narrow allowance extends to one further SHAPE: an alternation matched against
model PROSE whose language the product does not control. It is stated as a shape
rather than as a file-and-grader list because the list was written that way once
and was wrong in both directions within a single round — it named
`anchor-failed-step.yaml`'s failure-in-the-prose grader "and nothing else" while
the German counter-grader arms (`schritt`, `von`, `aus`) sat in that file AND in
`anchor-multi-step.yaml`, which the list excluded by name. Two members exist
today, both under `evals/zen-mode-reaction/scenarios/`: the failure-in-the-prose
grader (`fehlgeschlag`, `fehlschlag`, `gescheitert`, `rot`, `schlägt fehl`) and
the `Step N of M` counter grader, which appears in both anchor scenarios. The reason is the same in kind
but the source is the other side of the exchange: the zen-mode directive that
scenario grades says the words around the anchor's marks follow the USER's own
language, so a correct reply to a German-speaking user is German prose. An
English-only alternation would report that correct reply as a violation, which
`evals/zen-mode-reaction/README.md` names as the one outcome an eval must never
produce. The FIXTURES are a different matter and carry no allowance: every
canned reply in `tests/structure/zen-anchor-assertions.test.js` is English,
because a fixture is authored text rather than a match literal. Extend this
carve-out only for another grader in the same position — a pattern matched
against text whose language the product does not control — and never for prose,
a comment, or a fixture.

**The MEMBERSHIP above is enforced by nothing, and neither is any arm list.** `Z26` in
`tests/structure/test-zen-mode.sh` is what makes this checkable, and its allowance is
MECHANICAL and file-independent: it exempts a match sitting inside a `/.../` regex
literal in ANY carrier it scans, which is precisely what keeps prose, comments and
fixtures violations everywhere. So the load-bearing half is enforced and the
ENUMERATION is not — a German arm added to a grader in `safety-carve-out.yaml` would
pass the guard with this paragraph unamended, and so would a further arm in an existing
one. The SHAPE is what governs; the two members named above are a census taken at one
moment, not a bound the suite holds. Check by grep before relying on it, and never
strip a German arm because this paragraph did not list its grader.

## Artifact Path Redaction (`hooks/lib/zensu-artifact-redact-v1.js`)

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

## TDD Mode Precedence (`hooks/lib/zensu-config.sh` + `zensu-log.sh --tdd-begin`)

The strict/vanilla implementation mode is decided by a FOUR-RANK ladder, and
`hooks/lib/zensu-log.sh`'s `--tdd-begin` branch is the only place that orders all four
ranks:

1. the session marker `/zensu:tdd-mode` records (`hooks/lib/zensu-tdd-mode.sh` writes
   `<project>/.zensu/state/tdd-mode-<session-key>.json`)
2. `--tdd-begin --tdd-mode strict` — the CALLING SKILL's own default
3. `hooks.tddImplementation`
4. vanilla

**Rank 2 is escalation-only, and that removes the one downgrade spelling a gate can
see.** The value reaches the flag from a `TDD-MODE:` line in a model-read
specification, and a spec body is not always user-authored — `/zensu:pr-fix-findings`
builds one out of PR review-comment bodies. `strict` is therefore the only accepted
value; relaxing the discipline stays rank 1, the user's own action. Widening the
whitelist re-opens a downgrade channel that lands no bypass-ledger entry.

It NARROWS the channel rather than closing it: rank 1's carrier is an ordinary file in
the project tree, and NO gate covers it while the chain is inactive — not the Edit gate
(`pre-edit-tdd-reminder.sh` returns early on an inactive chain, ahead of its
`.zensu/state/` deny) and not the Bash source-write gate (`bash-source-write-parse.js`
carries no `.zensu` rule at all). Both an `Edit`/`Write` and a shell redirect therefore
reach `{"mode":"vanilla"}` ungated. The controls there are prose — "only the user
changes the mode", in `skills/tdd-mode/SKILL.md` and `skills/pr-fix-findings/SKILL.md`
— not a gate. Say so plainly, name both channels, and do not upgrade the claim:
hardening one gate would not close it.

**Rank 2 must outrank rank 3**, or the shipped `tddImplementation: false` makes every
skill default unreachable. **Rank 1 must outrank rank 2**, or a skill overrides the
user.

**Two sites FREEZE the resolved mode into a chain's `vanilla` flag**, and both resolve
the same ladder for every rank that exists there: `zensu-log.sh --tdd-begin` (ranks
1-4), and the Stop-hook adoption of a deferred review (`stop-chain-enforcer.sh`
`VANILLA_SEED` → `autopilot_adopt_pending_review` → `tdd_seed_deferred_review`), which
has no caller-flag carrier and therefore resolves 1 → 3 → 4. Accepted consequence: a
chain armed strict purely through rank 2 in a default-config project seeds its adopted
deferred-review generation vanilla. Everything downstream — the edit gate, the Stop legend,
`--mode` — reads the FROZEN flag and never the marker, so a mid-chain switch changes
nothing. Say "the next chain", never "this session".

**`/zensu:tdd-mode --status` is the ONE reader that consults both**, and it is not a
counter-example to the rule above — it exists to report the rule. It resolves the session
mode from the marker (ranks 1 → 3 → 4) and then reads the running chain's FROZEN flag via
`tdd_state_file` / `tdd_session_active` / `tdd_vanilla_mode`, appending a disclosure when
the two disagree. That makes it a fourth frozen-flag reader, so a change to the flag's
name, shape or accessors lands here as well as in the three above. It degrades to the
resolved-mode answer when the phase library cannot be sourced, because the source happens
after the base line is computed — a load fault loses the disclosure, never the mode.

**Effective vs configured is a deliberate split.** `plan-approved-delegate.sh`,
`user-prompt-tdd-reminder.sh` and the Stop seed call `zensu_tdd_strict_effective`
(marker over config); `session-start-banner.sh` and `session-start-primer.sh` stay on
`zensu_tdd_strict_enabled` BY DESIGN — at SessionStart no marker for the new session
can exist yet, so an "effective" read there would only ever return the config anyway.
A directive that names a cause must name the one that actually decided: after the
switch to the effective mode, the vanilla branches may not assert
`hooks.tddImplementation=false`.

Moving together with the ladder: `zensu_tdd_mode_marker_path` / `zensu_tdd_mode_state_linked`
/ `zensu_tdd_mode_marker_state` / `zensu_tdd_mode_override` / `zensu_tdd_strict_effective`
(the single path template and parse — the writer sources
them rather than re-spelling, unlike zen-mode, whose template is hand-copied into its
reader hook). `zensu_tdd_mode_marker_state` owns the marker VOCABULARY —
`strict|vanilla|released|none`, four values, where `released` is a present `{"mode":"auto"}`
and `none` is absence-or-unreadable — and it is the only parse; `zensu_tdd_mode_override` is a
total reduction over it that collapses `released|none` to `auto`, so its callers keep a
three-value contract and the two cannot drift. `zensu_tdd_mode_state_linked` is the symlink
guard for the `.zensu` / state-dir / marker triple plus an optional extra leaf, and the WRITER
now calls the reader's copy rather than spelling its own; its pre-rename re-check is
deliberately a SECOND call, because that duplication is the TOCTOU defense and collapsing the
two would remove it. A new marker value lands in the reader, in the reduction, and in
`--status`'s label set. Then the `TDD-MODE:` producer (`skills/pr-fix-findings/SKILL.md`) and its parser
(`skills/tdd/SKILL.md` Phase 0 + Mandatory command protocol step 1), that same skill's
§"Vanilla Implementation Mode", which states the ladder a THIRD time for the model,
`skills/tdd-mode/SKILL.md`, `docs/configuration.md` (the `tddImplementation` row),
`docs/gates.md` §Activation, `docs/tdd-manager-workflow.md` §Vanilla implementation mode,
and `docs/architecture.md`. A site left behind does not fail closed — it leaves a stale
rank list the model reads while the helper resolves a different one.

**A second site re-encodes the ORDER**, not just the ladder's prose: `--status` in
`hooks/lib/zensu-tdd-mode.sh` resolves rank 1 → 3 → 4 itself to report provenance. It
is structurally blind to rank 2, and so are the two pre-begin directive hooks — a caller
flag exists only at the moment of arming. So `--status` can answer `vanilla (config)`
while the next `/zensu:pr-fix-findings` run legitimately arms strict; the `mode:` echo at
`--tdd-begin` is the only authoritative report. A new rank, or a fourth marker value,
lands in `--tdd-begin`, in `zensu_tdd_strict_effective` AND here.
`tests/structure/test-tdd-mode-toggle.sh` pins the ladder and the fail-safes;
`test-tdd-vanilla-mode.sh` E3/E3b pin that the freeze survives a marker flip.

**Known gap:** no `/zensu:doctor` row reports the marker or a chain's frozen `vanilla`
flag, so a session-scoped choice is visible only in the `--tdd-begin` echo and in
`/zensu:tdd-mode --status`. Do not claim doctor visibility until that row exists.

## Requirements-Table Gate (`hooks/lib/zensu-plan-requirements.sh`)

`--tdd-complete` refuses a chain whose plan carries no usable `## Requirements` table.
It exists because `/zensu:converge` anchors its whole flow-back audit on that table and
takes a documented LEGACY STOP without one — and in `/zensu:autopilot` the CONVERGE stage
is the ONLY edge into `OPEN_PR` (`hooks/lib/zensu-autopilot-state.sh`, `CONVERGE:CONVERGENCE_PASSED`),
so a missing table turned a machine-mandatory gate into a clean-looking no-op. Both ends
stayed green, which is why it went unnoticed: measured across the author's plan corpus,
a third of plans written after the feature shipped carried no table at all.

**The rule lives in ONE place, and it is STRICTER than converge — not identical.**
The library is the executable copy. Converge's own table rule is its **Phase 0 step 2**
legacy stop, which keys on the table being ABSENT; this library additionally refuses a
present-but-placeholder table, and the two also disagree about deprecated rows in the
opposite direction (counted here, EXCLUDED from converge's coverage audit). Say
"stricter", never "shared" or "cannot disagree": a plan this gate passes is not
automatically one converge can audit in full. The Requirement column is located from the
table's header row rather than assumed to be the second, because the repo-override contract
pins the columns and never their ORDER.

**Which plan is judged is the load-bearing decision, and BOTH channels are bounded.**
`--plan <path>` wins (the skill passes it, in both the Phase 6 spelling and the
Mandatory-command-protocol one — they must not disagree); otherwise the gate reads the
edit-landing receipt's `log` field and substitutes `.zensu/logs/<stem>.log` →
`.zensu/plans/<stem>.md`, because both artifacts are created from one
`{SESSION_TS}_tdd-{slug}` stem. The derivation binds the receipt's `schema` discriminator and
requires the `log` to resolve INSIDE the project's own `.zensu/logs/`; the explicit flag must
resolve inside `.zensu/plans/` and carry the same stem — and with no derivable stem the flag is
REFUSED rather than falling through to the directory bound alone, EXCEPT when
`ZENSU_EDIT_LANDING_GATE=off` is what removed the receipt. That switch is documented as
exempting a session from the receipt precondition, and no receipt means no stem, so refusing
there would make the documented exemption unusable for the shipped invocation, which always
passes `--plan`. In that one case the bound is DROPPED and DISCLOSED (`REQUIREMENTS GATE STEM
UNCHECKED` on stderr), never faked. Without those bounds the flag would
silently defeat the session anchoring the derivation exists to provide — any older plan with
one filled row would satisfy the gate — and a receipt is an ordinary file the session can
write. Every comparison canonicalizes both sides (`realpath` / `cd … && pwd -P`): on macOS a
temp root is spelled `/var/…` by the caller and `/private/var/…` by the kernel, and a raw
string compare there rejects the session's own plan. Four things must therefore move
together: the stem convention in `skills/tdd/SKILL.md` Phase 2, the receipt's `log` field and
its JSON ENCODING in `hooks/lib/zensu-edit-landing.sh`, the substitution in `zensu-log.sh`,
`templates/tdd-plan.md` — whose `{acceptance criterion — machine-checkable}` / `{functional requirement}` cells are exactly what the placeholder-stripping rule keys on, so changing that placeholder syntax makes the gate misjudge — and `{plan_file}`'s definition beside `{log_file}` in Principle 3 — which Phase 2 step 1 now
WRITES, so producer and consumer share one spelling. The receipt's `log` is JSON-ENCODED and
persisted PROJECT-ANCHORED, so the reader never has to guess a root. One of these IS pinned and
it is easy to miss: `tests/structure/test-autopilot-durable-skill.sh` D9 hardcodes the bound
`--tdd-complete` literal from the skill, so adding the flag to that spelling broke a CI suite
this session. The roster is neither fully unpinned nor fully pinned, and D9 is the pin.

**Asymmetric fail direction, deliberately.** An explicit `--plan` that names nothing REFUSES —
the caller asserted where the plan is. A DERIVED path that is not there does NOT, because
nothing was asserted — but the gate then prints `REQUIREMENTS GATE UNRESOLVED` instead of
staying quiet, because "the table passed" and "no table was checked" reading the same is the
exact failure this feature exists to remove. **Refusal wording is typed**: exits 3/4 are a
verdict about the plan, exit 2 and anything else (a missing library included) refuse with
"could not judge the plan" — the sibling rule CLAUDE.md already states for the plan-payload
gate, that a load fault must never be reported as a judged payload.

**Scoping and the switch are copied from the edit-landing receipt gate**, which sits directly
above it in the same verb: a resolvable git HEAD plus a non-empty change set. The two share ONE
change-set computation and ONE spelling of the receipt path — the shared values carry a
verb-scoped `_tc_` prefix, not an `_el_` one, so neither reads as the other's private state, and
`tests/structure/test-tdd-complete-receipt-gate.sh` W3pre/W3 hardcode that prefix (renaming it
made W3 silently vacuous once already, which is why W3pre now checks its own anchor first) —
but they must NEVER share a switch: the computation is armed when EITHER is on, and both
`ZENSU_EDIT_LANDING_GATE` and `ZENSU_REQUIREMENTS_GATE` record a bypass-ledger entry (both were
added to `ZENSU_BYPASS_GATE_ALLOWLIST`; the ledger is what keeps everything a chain renders
under "Gates bypassed" true). **All four consumers conjoin on the scope**, the two gates and the
two ledger records: out of scope there is no decision point to short-circuit, so recording an
escape there would name a gate that never ran.

**Every root in this verb comes from `zensu_resolve_project_dir`, and there is NO divergence to
defend against — a claim an earlier draft of this section got wrong.** `zensu-log.sh` matches
every `--*` verb at the top of the file, binds the session, and unconditionally re-exports
`CLAUDE_PROJECT_DIR="$(zensu_resolve_project_dir)"` BEFORE any verb body runs, so an inherited
`CLAUDE_PROJECT_DIR=` prefix cannot reach the gate at all. `_tc_root` therefore calls that
accessor for OWNERSHIP — the alternative was triple-`dirname` surgery over a layout
`tdd_state_file` owns, which a layout change would silently mis-root — not as a defense. Do not
reintroduce a "the two can disagree about which tree they looked at" residual; it is false. A `.zensu/plans` or `.zensu/logs` component that
is a SYMLINK is refused rather than resolved through — canonicalizing both sides and comparing
for equality would otherwise compare a link target with itself and admit a file anywhere on the
host — and the `..` test is anchored (`rel === ".." || rel.startsWith(".." + sep)`), because a
real file named `..bak.log` inside the directory is inside it.

**Ordering is a contract, not layout.** The receipt refusal must stay FIRST (a session with
neither artifact should hear about the audit it skipped, not about a plan it never reached),
and the table refusal must stay ABOVE the standalone/bound split, which is the only reason
Autopilot-bound chains are gated at all. `tests/structure/test-requirements-table-gate.sh`
B1/B2 pin both, anchored on the REFUSAL text rather than on the env var — the shared
computation names `ZENSU_REQUIREMENTS_GATE` above the receipt refusal, so the switch is the
wrong landmark. Note that source pins must match the ON-DISK bytes: the refusal spells the
section name as an escaped `` \`## Requirements\` `` inside a double-quoted echo, so a grep
written against the decoded message finds nothing.

**The `## Requirements` shape has SEVEN readers, not two**, and all five beside this library
and `/zensu:converge` are model-executed and PRESENCE-ONLY, so every one of them accepts a
placeholder-only table this library refuses: `skills/self-review/SKILL.md` twice (the per-AC
table in the chain-end summary, and the converge offer it renders), and `skills/tdd/SKILL.md`
three times (Phase 6 step 6c's "If the plan has no `## Requirements` table (legacy plan), skip
silently"; the step-10 converge offer, which this thread renders when `hooks.selfReview` is
disabled; and the vanilla-mode statement that the table and the `Covers` mapping stay binding).
A change to what counts as a usable table has to reach all seven. Two further containment
predicates were added by this gate — the JS one inside the `node -e` reader and the shell one in
the explicit channel — which extend the hand-copied `within()` / `isInside()` family this file
already tracks; neither is reachable from a unit layer, because the JS half lives in a `node -e`
string argument rather than a required module. That placement is a KNOWN COST, not an oversight:
it is why the Windows namespace defect in the derivation had to be found by review rather than by
a `path.win32` unit test, and extracting the resolver into a module is the standing fix.
**The two copies do not enforce the same bound**, which the cost note alone would not tell you:
the JS half accepts anything that does not ESCAPE `.zensu/logs/` — including a subdirectory —
while the shell half requires exact directory equality for `.zensu/plans/`. Low impact (a looser
logs bound only changes the derived stem) but it is a divergence, not one rule in two places.
**Neither half has ever run on Windows**: `test-requirements-table-gate.sh` is not in
`tests/profiles/windows-ci.v1.json`, which is a curated set, so the derived channel's Windows
behavior is unverified in both directions — say "unverified", never "covered".

**The receipt schema moved to `edit-landing-v2`, and the reader accepts BOTH.** Holding the
discriminator at `v1` while the `log` field became project-relative was tried first and was
wrong: one schema name then covered two value domains, so the reader had to infer the writer from
a leading slash — and that inference REFUSED a perfectly readable v1 receipt on win32, which,
because the shipped skill always passes `--plan`, became a completion-blocking `exit 1` rather
than a warning. The version cost was never avoidable: under the runtime-lineage rule above a
persisted shape that moves costs a `minor` release whether or not the NAME moves, so
`version_type: minor` is required for this change either way — moving the name is simply what
buys the reader something for that price. Keep this true: `v1` is a SUPPORTED input, not a
corruption. A plugin update landing between the step 5b audit and `--tdd-complete` is explicitly
served by the lineage rule, so both branches must stay readable, and both are judged by
CONTAINMENT rather than by spelling.

Operator-facing accounts that must move with it: `docs/gates.md` §"Requirements-Table Gate",
the `ZENSU_REQUIREMENTS_GATE` and `ZENSU_EDIT_LANDING_GATE` rows plus the visible-opt-outs
enumeration in `docs/configuration.md`, and discipline patch 11 in
`docs/tdd-manager-workflow.md`.

**Known gaps, accepted and named:**

- **The check is one-sided.** It proves a table EXISTS and is filled in; it cannot tell whether
  the rows describe the work actually done. A chain that copies eight plausible requirements it
  never implemented passes. Closing that is `/zensu:converge`'s job, which is what this gate
  exists to keep reachable.
- **A bound zero-change chain is not gated, and that is the edge the feature is about.** The
  scope requires a non-empty change set, but Phase 2 writes a plan unconditionally and
  `--outcome no-changes` is NOT special-cased in `zensu-autopilot-state.sh` — the run still
  travels its return stage into CONVERGE, the only edge into `OPEN_PR`, and converge
  mtime-resolves that ungated plan and legacy-stops. Do not read "CONVERGE is the only edge
  into OPEN_PR" as "that edge is now covered".
- **`ZENSU_EDIT_LANDING_GATE=off` weakens this gate too.** With no receipt there is no run-log
  stem, so an explicit `--plan` keeps only its plans-directory bound: a stale plan from an
  earlier session in the same project satisfies it. Disclosed on stderr, not silent, and the
  same switch already carries its own ledger entry.
- **The git-environment scrub is scoped to this verb, and its sibling is not scrubbed.**
  `--tdd-complete`'s three scope `git` calls run through a subshell that unsets the THIRTEEN
  `GIT_*` variables `_tc_git` lists — discovery and config-injection levers alike, not just the
  three this paragraph used to name; the `--chain-done` zero-change terminus in the same file
  still calls bare `git`, so a one-token prefix there still drives its change count to zero. The
  wrapper is defined INSIDE the `--tdd-complete` case arm, which makes the asymmetry structural
  rather than a one-line follow-up: sharing it means hoisting the definition above the verb
  dispatch. Knowingly left as is.
- **A mid-run commit disarms BOTH gates.** The change set is the worktree against `HEAD` with no
  baseline range, so a chain that committed its work measures zero changes and both preconditions
  skip — without even the `REQUIREMENTS GATE UNRESOLVED` line, because the whole block is out of
  scope. The sibling edit-landing library carries a `--baseline` range for exactly this case;
  this verb does not.
- **The standalone `/zensu:converge` offer carries no plan path**, so the gate and the consumer
  can resolve different plans: the gate judges the receipt-derived plan, converge takes the
  newest by mtime. `/zensu:autopilot` step 2b closes this for the bound flow by passing the
  session plan explicitly; the standalone offer literal is rendered by
  `post-review-tdd-delegate.sh` and pinned in several suites, so changing it is a
  cross-file edit that has not been made.
- **A THIRD renderer of the bound `--tdd-complete` deliberately omits `--plan`:**
  `hooks/lib/chain-recovery-v1.js`'s `NEXT_COMMAND` (mirrored in `skills/recover-chain/SKILL.md`)
  renders the recovery spelling flag-free, so an unwedged chain takes the derived channel — the
  weaker one, which can end at `REQUIREMENTS GATE UNRESOLVED` when no receipt exists. It is left
  that way because the recovery renderer has no session plan path to interpolate.
- **The load-fault branch is not behaviorally tested, and cannot be from a bound session.**
  Session Control binds the executing plugin root by runtime DIGEST, so removing or renaming
  `zensu-plan-requirements.sh` in the executing tree makes every stateful command refuse with
  `context runtime digest mismatch` before the verb runs, and a copied plugin root is refused for
  the same reason. Both shapes were tried here and both failed on the binding; the branch is
  pinned at source instead (LM1/LM2).

## Version Bumps

**Every plugin version bump MUST update `.claude-plugin/plugin.json`, the
marketplace version, AND the marketplace source `ref` in the same commit.**

The two files serve different consumers:

- `.claude-plugin/plugin.json` — manifest read by claude-code when loading the installed plugin. Defines runtime agents/skills/hooks/mcpServers.
- `.claude-plugin/marketplace.json` — catalog read by `claude plugin marketplace update <name>`. Its Zensu entry uses the official GitHub source object for `MKITConsulting/zensu-claude-code` and an immutable `v<plugin version>` ref. Both `.plugins[0].version` and `.plugins[0].source.ref` must match `plugin.json`; a mutable branch source is forbidden.

Historical: `marketplace.json` was created at `0.2.0` (commit `a0a58b2`) and never re-bumped while `plugin.json` advanced through 0.2.x → 0.3.x. Result: every release between 0.2.0 and 0.3.15 was invisible to the directory marketplace and users running `claude plugin install zensu@zensu` could not pull the new code without uninstalling + manually clearing the cache directory. Fixed in PR #31; this convention prevents recurrence.

**Releasing — automated via the `Release` workflow** (`.github/workflows/release.yml`):

1. Actions → **Release** → run with a `version_type` (`patch`/`minor`/`major`). The `prepare` job computes the next version from the latest `vX.Y.Z` tag, bumps `plugin.json` + marketplace version + marketplace `ref` + the README badge **together**, and generates a `## [X.Y.Z]` CHANGELOG section from the conventional commits since the last tag (git-cliff, `cliff.toml`). For a real run it creates the `release/vX.Y.Z` commit locally, then runs `bash tests/run-all.sh --ci` **against that exact commit** — the suite gates the tree that actually ships, never a pre-bump tree nobody releases — verifies the exact clean commit SHA plus the Session Control runtime digest, uploads deterministic SHA-bound evidence, and **only then pushes the branch** and prints a "Compare & PR" link. The suite runs once per job on purpose: two full runs inside one job exceeded the runner limit and made every release time out. Promptfoo and live-model suites are local-only and are never invoked by GitHub Actions. `dry_run: true` remains an offline version/notes preview: it creates no commit, uploads no release evidence, and pushes nothing.

   **`skip_test_gate: true` ships WITHOUT the suite, and is the one input that removes a guarantee rather than adding one.** It refuses without a non-empty `skip_reason`, and the evidence artifact then records `gate: "skipped"` plus that reason — it can never say `passed`, so a release that skipped is distinguishable forever after from one that did not. Everything else still binds: the exact-SHA pin, the clean-tree check, the runtime digest, the version/ref invariant, and the evidence upload. The decision is written into the release commit as a `Release-Test-Gate: skipped` trailer, because the `publish` job is push-triggered and `inputs.*` is empty there; the trailer is also what a reviewer reads in the release PR. **Consequence, stated rather than glossed:** any commit whose subject starts with `chore(release): bump version to` AND carries that trailer skips the publish gate, so the protected-PR review — not a machine check — is what stands between a hand-written trailer and an unverified tag. Use it for a release whose diff you have already verified another way (a counter bump, a docs-only fix), never as the default path.
2. Open the PR from that link, then review + **squash-merge** it. (CI pushes the branch but does not open the PR — the org caps the workflow token for PR creation; release/tag creation only needs the per-job `contents: write`, which works.)
3. The release commit landing on `main` is **not** plugin go-live: the updated catalog points to an as-yet unavailable tag. The `publish` job verifies the GitHub repo/ref/version invariant and rejects a pre-existing tag at any other commit, re-runs `bash tests/run-all.sh --ci` against the exact clean `${{ github.sha }}`, revalidates the runtime digest, and uploads a second deterministic SHA-bound evidence artifact. Only then does it create `vX.Y.Z` at that SHA and a **published** GitHub Release (notes = the new CHANGELOG section, source zip attached). Successful tag creation makes the source resolvable and is go-live. An exact existing tag with a missing release can be repaired idempotently after repeating the deterministic gate. Users pull it via `claude plugin marketplace update zensu`. The release notes were already reviewed in the bump PR body, so there is no separate draft-publish step.

The version/ref invariant above is machine-enforced: the gate runs `tests/run-all.sh --ci` (including the version-sync and immutable-marketplace tests) before the branch is pushed. For a manual hotfix bump, follow the invariant by hand — `plugin.json` version + marketplace version + marketplace `ref: vX.Y.Z` + README badge (same version) + a new `## [X.Y.Z] - YYYY-MM-DD` CHANGELOG section + commit subject `chore(release): bump version to X.Y.Z`.

If marketplace version or source `ref` ever lags `plugin.json` (for example, a hand bump forgot one field), fix both in the release PR before any tag is created or any user-side `claude plugin install <name>@<name>` attempt.

## Windows Budget for `best-solution-first`

The suite cap was raised 300000 -> 600000, matching its siblings, but **the cap is
not the ceiling that binds** and the measurement says which one is. On the last
green run `windows-shard-4` completed in **1591 s** against its `profileTimeoutMs`
of 1800000 — roughly **209 s of headroom for the whole shard**. A suite never
receives its configured `timeoutMs`; it receives the shard's remaining budget, so
raising this number buys nothing while the shard is that close to its own ceiling.

The suite is spawn-dominated — nearly every check spawns a `bash` plus a `node`,
it builds five fixture plugin trees, and it now also drives
`tests/structure/rule-block-v1.test.js` as its B0 driver — and `windows-shard-4`
also carries `plan-payload-path-transport`, which this file records at a measured
714 s. Growth here therefore has to be paid for by moving a suite OFF that shard,
not by raising a number. If the shard starts reporting an abort, the tail of
whichever suite ran last went unverified regardless of how many checks passed
before it.

The suite-level wall clock on Windows is still **unmeasured**; only the shard is.
The note lives here because `tests/run-profile.js`'s `SUITE_KEYS` throws on any key
outside `{id, runner, path, args, timeoutMs}`, so a `note` field in the manifest is
a CI-wide outage rather than documentation.

## Runtime Lineage (`version_type` is load-bearing)

A plugin update that lands while a session is running leaves the Session Control
record naming the installation that minted it. The running installation may
still **serve** that record when the two share a lineage —
`servesRecordedRuntime` / `runtimeLineageCompatible` in
`hooks/lib/session-control-core-v1.js`. It is the ONE implementation all five
call sites share: `resolveHookSession` and its `resolveOrphanedProjectRoot`
mirror in `hooks/lib/claude-hook-session-v1.js`, `currentClaudeSessionContext`,
and both the SessionStart-resume and SubagentStart branches of
`hooks/lib/claude-session-control-v1.js`. `relatedClaudeSessionContexts` is
deliberately excluded: it compares two records against each other, not a record
against the executing runtime. The axis:

- **same major**, and **while major is `0`, the same minor as well** — `0.17.1 ↔
  0.17.2` compatible, `0.17.x ↔ 0.18.0` not. Without the second clause "same
  major" would make `0.9.2` compatible with `0.17.2`.
- **never backwards**: the executing version must be at least the recorded one.
- the executing root must be a **sibling** of the recorded one, which is what
  keeps a `--plugin-dir` checkout from adopting an installed session's record.

**While the plugin is at major `0`, MINOR is therefore the breaking axis.** A
breaking change costs a `minor` release and a non-breaking feature is a `patch`.
The list below is signed: entries are breaking unless the entry says otherwise.
A breaking one forces the bump because a running session would otherwise be
served by a runtime that cannot read what it wrote; the two marked NOT are
carve-outs kept here so a releaser meets them where they will look:

- the context record or workflow-state **schema** (`SCHEMA_VERSION`, any field
  added, removed or retyped);
- **any strict key set** — `reviewRearm`'s `exactKeys`,
  `deferredReviewCancellation`, and every other validator that rejects an
  unknown or missing key rather than ignoring it;
- **removing or renaming a registered hook, or changing a hook's matcher**;
  **adding** one is NOT in this list and is a `patch`. **Provenance, because it
  matters here:** this exemption and the config-key one below were WRITTEN BY the
  change that needed them — the release that added the best-solution-first hook and
  its `bestSolutionFirst` key. A commit amending the policy that classifies it is
  the shape that deserves a second reader, so it got one: the exemption was
  challenged in review and survived on the argument below, not on the author's own
  say-so. Anyone widening either exemption should expect the same standard. The
  argument has two halves
  and the second is the load-bearing one. First, `runtimeLineageCompatible`
  compares version tuples only and never inspects the hook inventory, an older
  harness never loads a hook its own `hooks.json` does not declare, and the new
  hook is invoked from the tree that declares it. Second — and this is the part a
  reader will otherwise miss — adding a file DOES change the runtime digest, since
  `manifestRuntimeEntries` folds `hooks` and `docs` in wholesale; what keeps an
  in-flight bind alive is that `readContextInternal` measures the **recorded**
  root, and the upgraded case re-measures the executing tree against the caller's
  claim rather than against the record. Do not over-bump defensively; do
  re-derive this if the added hook writes session state, participates in a strict
  key set, **or can return a `permissionDecision` of ANY kind — deny, ask OR allow**.
  The list said only DENY until the reviewer-spawn grant landed, and a releaser
  matching on it would have found no entry covering a hook that GRANTS and
  classified `patch`. The exemption's own closing test already settles it without
  the list: the exempt shape is an ADVISORY hook "whose only output is
  `additionalContext`", which a hook emitting a `permissionDecision` is not, in
  either direction. The third disqualifier is the one an earlier wording
  left out, and it is the one that matters: a hook that can refuse a tool call
  changes the capability set of every session an older runtime is still serving,
  which is exactly what makes a matcher change breaking in the bullet above. A new
  `PreToolUse` entry on the existing `Bash` matcher returning
  `permissionDecision: deny` writes no session state and touches no strict key
  set, so it passed both original tests while being as breaking as anything in
  this list. The test is CAPABILITY, not storage: an ADVISORY hook — one whose
  only output is `additionalContext` — is the exempt shape, and that is what the
  two hooks this exemption was written for are;
- **adding a permissively-read config key** is likewise NOT in this list and is
  a `patch`, for a reason unrelated to the hook inventory: `zensu_hook_enabled` tests only
  `j.hooks[key] === false`, so an older runtime ignores a key it does not know
  rather than failing on it. A key read by a STRICT VALIDATOR is the opposite
  case and belongs under the strict-key-set bullet above — but read that bullet's
  own definition before matching on the word "strict": its members REJECT an
  unknown or missing key. `zensu_hook_enabled_strict` does no such thing. It reads
  one key by name, grants when it is absent, and is strict about the VALUE and the
  READ, not about the key SET — so `hooks.reviewerSpawnAutoAllow` keeps the `patch`
  argument above. The reason it survives is worth stating, because it is not the
  obvious one: the strictness lives in a NEW reader that older runtimes do not
  have, never in a validator they run, so a config carrying that key degrades to a
  no-op there exactly as an unknown key always did. Strict value reading is not
  strict key-set validation; do not conflate them and over-bump;
- the **attestation shape**, which is itself a schema two versions must agree
  on. A change to it has to ship in the release that *introduces* the policy it
  serves, never one release later.

Consequence: the `Release` workflow's `version_type` input carries meaning, not
just a number. Choosing `patch` for a change in that list ships a compatibility
claim the code cannot honour. The predicate encodes what the numbers *mean*; it
cannot verify that this policy was followed.

**The release that introduces this policy is itself a `minor`**, because it adds
`executing_plugin_root` and `executing_runtime_digest` to the attestation. It is
the last release before the policy binds, so nothing is served across it.

**Known gap 1 — the review-evidence lease is NOT lineage-relaxed.**
`hooks/lib/review-evidence-lease-v1.js` still compares its recorded
`plugin_root` strictly, so a lease minted before an upgrade is refused after it.
Because `listRecords` validates every record and propagates the first failure,
that one lease then fails every later lease operation for the session. Closing it
needs a lease-schema change — the lease record carries no `plugin_version`, so
there is nothing to judge a lineage against. It is pinned as CURRENT behavior in
`tests/structure/test-versioned-plugin-upgrade.sh` rather than left accidental,
so changing it silently fails loudly. **Adoption works around it, it does not
close it:** `discardSupersededLeases` moves every entry `listRecords` would REJECT
— broader than "names the previous installation", narrower than "everything that
reader rejects"; the entry script's header states the exact selector — OUT of the
records directory (into a sibling `superseded/<key>/`,
because `listRecords` fails on any non-`.json` entry, so setting one aside in
place would be strictly worse). The count is reported, never absorbed.

`docs/session-control.md` "Unbindable sessions" carries the operator-facing
account, including the pin this weakens and the two attestation fields that
state the executing runtime. `tests/session-control/session-control-core-v1.test.js`
pins the axis and the sibling rule;
`tests/structure/test-versioned-plugin-upgrade.sh` pins the end-to-end verdicts
across synthetic installs, including that serving a record never rewrites it.

## Adopting a Record Across a Lineage Break (`adoptableRecord` / `adoptContext`)

The lineage rule above judges DECLARED versions and cannot see whether the
persisted shapes actually moved. When they did not, its refusal wedges a session
the running code could read perfectly well — and every write channel is denied,
so the user cannot repair it. `adoptableRecord` / `adoptContext` in
`hooks/lib/session-control-core-v1.js` are the one explicit exit.

**The authorising axis is SCHEMA equality, not the version numbers, and that
gate closes itself.** `validateContext` already enforces the record's
`schema_version` and `validateWorkflowState` already enforces the workflow
document's `schema`, so a release that genuinely moves a persisted shape makes
one of the two unreadable and adoption declines with no new check to remember.
Do NOT replace either with an explicit version comparison — the self-closing
property is the whole design, and a hand-written check is the thing that gets
forgotten.

Six conditions are ALL required; seven refusal reasons name exactly which one
failed (condition 5 can fail as either `executing-runtime-unidentified` or
`executing-runtime-older`):
`record-unreadable`, `plugin-data-mismatch`,
`already-served`, `not-a-sibling-installation`, `executing-runtime-unidentified`,
`executing-runtime-older`, `workflow-schema-mismatch`. `plugin_data` and the
sibling bound are NOT relaxed here either — the latter is what keeps a
`--plugin-dir` checkout from adopting an installed session.

**There is deliberately NO condition on the CALLER's project root, and
`adoptableRecord` does not read `options.projectRoot` at all.** There was one, and
it made this repair unreachable in exactly the state it exists for. Two sources of
truth disagree about "the project": the record is minted from the SessionStart
**payload cwd** (`claude-session-control-v1.js`), while the adoption entry point is
handed **`CLAUDE_PROJECT_DIR`**, a literal the skill renders from the harness. A
fork whose cwd was a worktree records that worktree while the harness still reports
somewhere else — and `cd` cannot change `CLAUDE_PROJECT_DIR`, so the refusal named a
remedy no one in that session could perform. Removing it relaxes nothing: the anchor
is CARRIED from the record (`adoptContext` passes `verdict.context.project_root` to
`buildContext`), no write is located by the caller's value, and the bound stated in
the entry script's header — `readContext`, the sibling root, `plugin_data` — never
included this comparison. It also put the module back in step with itself:
`resolveHookSession` answers `projectRoot: context.project_root` under "The mutable
payload cwd is never a project authority", and this was the one place a
caller-supplied directory outranked the record. A record whose project root is GONE
is still refused, as `record-unreadable` — `validateContext` canonicalizes it at
condition 1. Consequently `zensu-session-adopt.sh` no longer requires
`CLAUDE_PROJECT_DIR`; it used to render it through `zensu-host-path.sh`, which
rejects a non-directory, so an unset or deleted value exited before printing any
report. The recognizer still ACCEPTS the assignment — the diagnostic reads it and the
two share one set — but the shipped skill command STOPPED PASSING it: the recognizer
holds every PATH assignment in the prefix to a rooted literal value — `ZDOC_PLAYWRIGHT_TOOLS`
is a Set-membership check, not a path one — so a harness
that rendered the placeholder empty would have refused the whole invocation over a
value nobody reads.

**Two invariants, both learned from the chain-recovery precedent:**

1. **No record field is ever added.** Provenance is a workflow `history` entry
   under the reserved phase `RUNTIME_ADOPTED`, protected in the same two guard
   sites as `CHAIN_RECOVERED` (`zensu-log.sh --phase` and `tdd_write_phase` /
   `_tdd_write_phase_critical`). A field would itself be the breaking bump this
   feature exists to survive, and would cost a `minor` — which would wedge every
   session then running.
2. **No bypass-ledger entry.** The ledger records gate ESCAPES so that everything
   under "Gates bypassed" is true. Adoption escapes no gate; it re-mints a
   record. Same rule, same reason, as `--chain-recover`.

The previous record is never overwritten — it is renamed to
`<key>.superseded-<recorded-version>.json` and stays readable, so "the record is
immutable" remains literally true. `created_at` is carried over.

**The gate channel is a SECOND recognized command, admitted on a DIFFERENT
argument.** `hooks/lib/zensu-doctor-invocation.js` admitted exactly one shape
because `zensu-doctor.sh` writes nothing. `zensu-session-adopt.sh` WRITES, so it
carries its own justification in its own header, and that header is what the
recognizer points at. Keep the recognized list at two; a third entry needs its
justification written down the same way, not a wave at either existing one.
Moving together: `RECOGNIZED` in the recognizer, `isRecognizedInvocation` (the
module main and `reviewer-capability-v1.js` both call it; `isDoctorInvocation`
stays the doctor-only predicate), and `zensu_doctor_allowed`'s contract comment.

**A SUPERSEDED installation that has been PRUNED from the plugin cache is its own
named state, `pruned-plugin-root`, and it is adoptable.** It used to be the wedge
this section warned about: `validateContext` canonicalized `context.plugin_root`
unconditionally, so an absent recorded root made `readContext` throw,
`resolveIncompatibleRuntime` answered null, every gate denied with the generic
revalidation text, the doctor fell back to the `unbound` row whose "no valid
record" wording is false, `adoptableRecord` refused `record-unreadable` — and the
Stop hook fell through to its unbounded block and LOOPED, in a session whose every
other channel was already denied. Measured on the maintainer's machine before the
fix: the cache held three versions, 4101 of 7913 records named a pruned root, one
live session was wedged this way and twenty-two more were recorded on the next
two versions to be pruned.

**The reader is `readPrunedPluginRootContext`, and existence is the ONE waived
check — proven, never assumed.** `validateContext` and `readContextInternal` take
an `allowMissingPluginRoot` waiver (the twin of `allowMissingProjectRoot`; each has
exactly one opt-in caller) under which the digest re-measure and the manifest
re-read are SKIPPED — there is nothing left to measure. The reader re-applies the
shape half through `requireAbsentDirectoryPath` (control characters, absoluteness,
normalization — spelled as PR #272 spells it, so a merge keeps one copy), requires
the root's PARENT to be a real directory (a pruned installation leaves its cache
directory behind; a record naming a root under a directory that never existed is
not this state), and returns only on a clean `lstat` ENOENT — a present root fails
`still exists`. **The cost, stated:** with the minting tree gone, `runtime_digest`
and `plugin_version` are shape-checked only and taken on the record's word. What
still binds the record: session hash, schema, principal profiles, `plugin_data`
equality, the recorded project root existing, the sibling cache directory, and the
workflow document's schema. That is why such a record is **adopted once, with
`--confirm`, and never served** — serving stays strict at every strict read site
(`resolveHookSession`, `currentClaudeSessionContext`, `zensu_resolve_project_dir`,
SessionStart resume/compact, SubagentStart), and the re-minted record is
re-verifiable again.

**Disjoint from `incompatible-runtime` by construction, and blind to lineage on
purpose.** `resolvePrunedPluginRoot` requires the STRICT read to fail and the
relaxed read to succeed; the lineage predicate requires the strict read to succeed.
No consumer has to order the two, and the state is reachable under a compatible
lineage as well (three patch releases inside one minor while a session lives),
where the remedy is the same. The binder modes `pruned-plugin-root` /
`model-pruned-plugin-root` print the same two-field `recorded<TAB>executing` pair,
so the five parsers of that pair read it unchanged. **Sites that move together:**
the reader, the waiver and the helper in the core plus its exports;
`resolvePrunedPluginRoot` / `prunedPluginRootSession` and the mode pair in the
binder; `zensu_session_pruned_plugin_root` / `_model` and the `pruned-plugin-root`
scope of `zensu_emit_hook_session_deny` in `zensu-session.sh`, which now spells
FIVE scopes; the pruned branch beside the lineage branch in all four binding gates
(`pre-bash-zensu-gate.sh`, `pre-bash-source-write-gate.sh`,
`pre-write-secret-scan.sh`, `pre-edit-tdd-reminder.sh`) and the self-worded FIFTH
denier in `reviewer-capability-v1.js` — five deniers, the same set as the lineage
state, which that file's own neighbouring comments already count as five; the FOURTH release arm in
`stop-chain-enforcer.sh` plus its block reason and final stderr, which count four
released states; the third probe in `zensu-doctor.sh` and the `pruned-plugin-root`
case of `bindingLine()`; `adoptableRecord`'s condition-1 ladder (strict → pruned),
its condition-3 skip, and the `prunedPluginRoot` field on the verdict and on the
`adoptContext` result; `PRUNED_NOTE` / `PRUNED_EXPLANATION` and the reworded
`record-unreadable` remedy in `session-adopt-report-v1.js`; and the operator
accounts in `docs/session-control.md` §"Unbindable sessions",
`docs/tdd-manager-workflow.md`'s Stop-binding paragraphs, `skills/doctor/SKILL.md`,
`skills/adopt-session/SKILL.md` — and the `stop-chain-enforcer.sh` row in
`docs/configuration.md`, which states the COUNT of released bind failures and is the
one carrier this change originally left behind, saying three where the hook's own
fallback already said four. `ADOPTION_REFUSALS` is unchanged — seven
values, so CONV-1 is untouched — and no persisted shape moved.

**Pins, and one thing Part D learned.** Part D (AC-D01…AC-D10) in
`tests/structure/test-versioned-plugin-upgrade.sh` replaced JUDGE-3, which pinned
the old boundary — do not restore it; the unit cases beside the lease-lock cases in
`tests/session-control/session-control-core-v1.test.js` drive the reader, the
helper and the ladder; `P1ad3`/`P1ad4` in `tests/structure/test-doctor.sh` pin the
row. In this state the bind fails inside the CORE, so the authoritative stderr
diagnostic is the raw `session-control-v1: context plugin root does not exist`
line rather than a binder-prefixed one, and Part D's gate helper tolerates exactly
that line where AC-C04's tolerates only the prefix. **Composition with PR #272:**
condition 1 becomes `strict → orphaned-project-root → pruned-plugin-root` when
that PR lands; the COMBINED state — project root gone AND installation pruned —
still refuses `record-unreadable`, and is the recorded gap. **Version: `patch`** —
no record or workflow field, no strict key set, no hook added, removed or renamed,
no matcher change, no config key, no attestation change; every change relaxes a
deny or names a state, and the new argv modes are a call convention inside one
installation.

**A vanished recorded PROJECT root is an OPEN gap, not a settled distinction.**
Removing the caller's project-root condition closed one of the two ways the two
sources of truth diverge in worktree workflows — a cwd that was a worktree while the
harness reported elsewhere. The other is still a permanent wedge: a worktree later
REMOVED (`git worktree remove`, the documented cleanup in `skills/pr-team-review`
Phase E) makes `readContext` throw at condition 1, so adoption answers
`record-unreadable` whose remedy says to start a fresh session. Combined with an
incompatible lineage, `orphanedProjectRootSession` does not fire either, and
`/zensu:doctor` falls back to the same `unbound` row. `readOrphanedProjectRootContext`
ALREADY distinguishes *record intact, project root absent* from *record altered or
pruned*, and the gates already consume it — adoption does not. Widening it is a
separate and larger decision, because adoption would then have to succeed with an
anchor that does not exist. Word it as open here and in `skills/adopt-session/SKILL.md`,
so the next reader does not take "that one still refuses" for "and should".

**Three re-encodings move with this.** Their coverage is stated once, in the
store-layout bullet below, and nowhere else — a ledger that contradicts itself about
its own pins is the failure mode it exists to prevent. The wire format and the
version-shape rule are unchecked:

- the `recorded<TAB>executing` wire format — one producer
  (`claude-hook-session-v1.js`) and five parsers (`zensu-doctor.sh`,
  `stop-chain-enforcer.sh`, `pre-bash-zensu-gate.sh`, `pre-edit-tdd-reminder.sh`,
  `pre-bash-source-write-gate.sh` / `pre-write-secret-scan.sh` share one spelling).
  Every parser reads `${V##*$'\t'}` for the executing half, which takes the LAST
  field: adding a third field silently redirects all five rather than failing.
- the version-shape rule, spelled twice for two different hazards —
  `ADOPTION_SAFE_VERSION_RE` (a version reaches a FILENAME) and
  `ZENSU_SAFE_VERSION_RE` (a version reaches a JSON string, and now also the
  doctor report). Identical alternation, deliberate hand-copy; keep them in step.
- the review-evidence store layout, hardcoded in `discardSupersededLeases` as
  `review-evidence/v1/{records,superseded}/<key>` and re-implementing the
  ownership predicate that `review-evidence-lease-v1.js` owns, plus — since the
  destination guard landed — that module's `ensurePrivateDirectory` policy, its
  `LEASE_ID_RE`, and its `MAX_RECORD_BYTES`. FIVE copied elements, not one, of
  which only two were ever pinned — and both pins compared source SPELLINGS rather
  than behaviour, so `8388608` in the owner would turn them red with nothing wrong
  while neither checked that the two sides applied the constant to the same
  quantity.

  **THE SEAM HAS BEEN TAKEN, and the copies are gone.** The trigger this file
  recorded — "if this function needs a fourth correction, take the seam" — had
  fired. The direction is the one that was always available: a core -> lease CALL
  cycles (that module requires the binder, which requires this core), so the SWEEP
  moved instead, into `hooks/lib/review-evidence-sweep-v1.js`, where requiring the
  owner is acyclic. `review-evidence-lease-v1.js` now exports `LEASE_ID_RE`,
  `MAX_RECORD_BYTES`, `REVIEW_EVIDENCE_SEGMENTS`, a `leaseRecordIsOwned` predicate
  and `withLock`, and the sweep consumes those five.

  **One copy deliberately SURVIVES, and claiming otherwise was the overstatement
  review caught.** `privateEnough` in the sweep reproduces `ensurePrivateDirectory`'s
  mode/uid pair verbatim, because the two do different things with the same
  predicate: the owner REPAIRS with a chmod, this one may only LOOK. It is a
  read-only twin, not a removed copy — do not "align" them, and do not read "the
  copies are gone" as covering it.

  **The stated cost was paid, not avoided:** the sweep is an EIGHTH host obligation
  now, not part of the cross-host core half. `adoptContext` no longer sweeps at all
  — the adoption ENTRY POINT calls it after the record swap — so a port that takes
  only the core delta gets an adoption that never sweeps and leaves every superseded
  lease wedging the store. What the move bought: the function is exported and driven
  by `tests/structure/session-control-lease-sweep.test.js`, so its refusal arms cost
  a temp directory each instead of a full synthetic install plus a session
  lifecycle, and three return shapes the shell layer could not reach are ordinary
  cases.

  The source `lstat`'s ENOENT branch remains the silent one: it cannot tell "no
  lease was ever minted" from a layout that moved, so a layout change still makes
  the sweep a SILENT no-op. That is now bounded rather than open — the layout is one
  exported constant both sides read — but it is not closed.

**Port-relevant.** The core half is `adoptableRecord` / `adoptContext` /
`executingPluginVersion` / `adoptionWorkflowStatePath` plus `ADOPTION_REFUSALS`, in
the cross-host `session-control-core-v1.js` — and, since the pruned-installation
state landed, `readPrunedPluginRootContext`, `requireAbsentDirectoryPath` and the
`allowMissingPluginRoot` waiver beside them, while the host half gains a NINTH
obligation, enumerated with the other eight below rather than counted twice here.
`discardSupersededLeases` is NO LONGER
among them — it moved to `hooks/lib/review-evidence-sweep-v1.js` and is the EIGHTH
host obligation enumerated below. Note that
`adoptableRecord`'s `options.projectRoot` is now INERT — accepted and never read —
so a port that takes only the core delta (the condition gone) while its own entry
script still requires and host-path-renders a project-dir variable still exits
before printing any report, which is the same wedge in a different place. The two
halves move together. The host
half is NINE separate obligations, and a port that takes only the core delta gets
`adoptContext` with no reachable caller and keeps the wedge: the entry script, the
recognizer's `RECOGNIZED` entry, the doctor branch and row, the Stop release, the
deny scope at every gate that denies in this state, the skill, — easy to miss
— a binder exporting a `privateRecordsDirectory` equivalent that applies the
symlink/alias/permission/ownership checks, because the entry script resolves the
records directory through it and never by hand-joining, EIGHTH the sweep itself
(`hooks/lib/review-evidence-sweep-v1.js`, plus the owner exports it consumes and the
entry point's call to it) — a port that skips it re-mints the record and leaves every
superseded lease wedging the store — and NINTH the pruned-installation surface set: the
binder mode pair, the shell wrapper pair, the deny scope, the gate branches, the Stop arm
and the doctor probe, because a port that takes the reader alone gets a record it can
adopt and no surface that tells the user so. A port that copies only
the script gets a TypeError rendered as the wrong refusal. `zensu-codex`,
`zensu-kiro` and `zensu-antigravity` were NOT included in this change.

**Two spellings of one root, and only Windows can tell them apart.** The sweep decides
ownership with `record.plugin_root === executingPluginRoot`, a STRING compare. Leases carry
`binding.pluginRoot`, which reached the store through the core's `canonicalDirectory` —
`fs.realpathSync.native`. The adopt call site passes the record's own `plugin_root` and so
agrees by construction; the in-place REPAIR call site received `ZADOPT_PLUGIN_ROOT`, which
`zensu-session-adopt.sh` renders through `zensu-host-path.sh`. On win32 that renderer emits a
drive-qualified FORWARD-slash path while the native spelling uses backslashes, so the compare
inverted the selector a second time and the repair set aside the one live lease it had to keep
— `windows-shard-2` reported `leases set aside : 2` where 1 was correct, with every POSIX shard
green. `repairSweepRoot` now canonicalizes, falling back to the rendered value rather than
throwing, because that branch owes the caller a verdict. Anything else that hands a root to
this module owes it the same canonicalization.

**`ENOENT` is not proof of absence, and the entry point read it as such.** `lstat` on a path
whose ancestor is a FILE answers ENOTDIR on POSIX and ENOENT on win32, so a `review-evidence`
file took the "no store here" branch and `discardSupersededLeases` reported a clean sweep over
a store it never opened. `firstNonTraversableAncestor` re-derives the answer from the
components instead of the errno; it follows links on purpose, so a symlink to a real directory
stays traversable and the POSIX verdict is unchanged. It is EXPORTED for the unit layer alone
— from a POSIX host the branch is unreachable through the public entry point, so without a
direct handle the fix would ship with no executed case anywhere. Its `path.relative` bound is
another member of the hand-copied `within()` / `isInside()` family this file tracks.

**`test-versioned-plugin-upgrade.sh` grades the LAST COMMIT, not the working tree.**
It captures `git rev-parse HEAD` and its install fixture materializes both synthetic
roots with `git ls-tree`, so every behavioral row — and the copies of
`skills/adopt-session/SKILL.md` that AC-C04 and CONV-1 read — measures the committed
revision. An uncommitted change under `hooks/` or `skills/` is therefore reported
GREEN against the previous commit, which is not a hypothetical: a real regression in
`discardSupersededLeases` shipped that way for a full review round, because every
measurement of it had been taken before the commit that carried it. Test-file edits
DO take effect immediately, and SEVERAL rows read the working tree — the four unit
drivers (`zensu-doctor-invocation`, `session-control-lineage`, the lease sweep and
the adoption report), the three seam pins hoisted to the front of the file so a
Windows timeout cannot drop them, the committed-tree check beside them, the
lease-gap grep, and AC-013 — each labelled `WORKING TREE, not HEAD` in place. The
count is deliberately NOT written out, matching the rule the suite states about
itself: a hand-maintained number is exactly what a driven loop cannot catch when a
row is removed, and the two hand-copy pins this enumeration used to name were
themselves deleted when the seam was taken. Getting that set wrong is its own hazard, in the
opposite direction: a reader who believes an uncommitted constant is invisible will
misread a pin that in fact grades it immediately. Commit first, then measure.

**The Windows timeout for `test-versioned-plugin-upgrade.sh` is MEASURED, and the
measurement is one sample.** `windows-shard-2` logged
`PASSED versioned-plugin-upgrade (107613ms)` against the 900000 ms ceiling — roughly
12%, so about seven eighths of the budget is unused. Taken at the head that carried
Part C plus the AC-C11/AC-C11b/AC-C12 family.

**That sample is now STALE, and saying so is the point of recording it.** The work
that took the seam added two further `node --test` drivers to this suite plus roughly
450 lines of rows, and no Windows wall clock was taken afterwards. The 107613 ms
figure describes a head that no longer exists. Do not budget against it; re-measure
on the next green Windows run and replace the number and its provenance sentence
together. Part D of the same suite — the pruned-installation rows, three further
synthetic installs — landed after that note without a Windows sample either, so
the same instruction applies twice over.

Read the original sample as ONE sample, not as a bound. The sibling
`stop-enforcer-self-review-routing` note in this file records a 29% spread across
two green runs of byte-identical content on the same runner class, so a single
figure says nothing about the worst case — it says only that the suite is not
currently close to its ceiling. Budget against the measured figure and re-measure
after a change that adds process runs; the previous wording tried to substitute a
hand-counted itemization of node and bash invocations for a wall clock, and that
itemization went stale on its next row edit, which is exactly why it is gone.
The caveat lives here and NOT in the manifest:
`tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and throws at manifest load, which aborts
EVERY Windows shard before a single suite runs — a `note` field there is a
CI-wide outage, not documentation. Note also that shard-2's `profileTimeoutMs` is
1800000, so a run genuinely approaching 900 s surfaces as a profile abort rather
than the suite `TIMED_OUT` this ceiling exists to make visible.

Operator-facing accounts that must move with it: `docs/session-control.md`
"Unbindable sessions", the binding rows in `skills/doctor/SKILL.md`, and
`skills/adopt-session/SKILL.md`. `tests/structure/test-versioned-plugin-upgrade.sh`
Part C pins the named state, the doctor row, the Stop release, the Bash-matcher
allowance with its ordinary-command discrimination, the refusal truth table, the
end-to-end repair, and that the reserved phase cannot be minted through `--phase`.

## Autopilot Run Scope (`hooks/lib/zensu-autopilot-state.sh`)

A durable Autopilot run is scoped by TWO independent axes, and confusing them is the
mistake this section exists to prevent.

- **Who may see and drive it — the OWNER session.** The active pointer is
  `.zensu/state/autopilot-active-<sha256(ownerSessionId)>.json`, built by
  `_autopilot_active_path`. `autopilot_read_active` takes the owner and filters the
  inventory by it: another session's run is not an orphan, not a hidden run, and not a
  conflict — it is invisible.
- **What it may collide on — the WORKSPACE.** The run records `workspaceRoot`, the git
  working tree it drives. `begin` refuses when any nonterminal run in the inventory holds
  the same `workspaceRoot`, REGARDLESS of owner, because that is the resource two runs
  would actually corrupt: one branch, one commit history, one pull request.

Before this split there was one pointer per project root, so two sessions sharing a project
root serialized even when they drove different worktrees, and a run left nonterminal by a
session that no longer exists blocked the project forever.

**`read-active` and `read-workspace` are two questions, and collapsing them re-opens a real
hole.** "What is MY run" is owner-scoped: the resume hook, `plan-approved-delegate.sh`, the
three `stop-chain-enforcer.sh` sites, both `post-review-tdd-delegate.sh` sites, and
`--autopilot-status`. "Does ANY session hold this working tree" is owner-INDEPENDENT and
must stay so: `_autopilot_begin_standalone_tdd_critical`,
`_autopilot_adopt_pending_review_critical`, and both fences in
`_autopilot_deferred_contention_result`. All four call
`_autopilot_read_workspace_critical` DIRECTLY, and the reason DIFFERS per group —
saying "each is already inside the project lease" is false for half of them. The
two locked fences are inside it. The two contention fences deliberately read
UNLOCKED, because they are reached precisely when the lease could not be
acquired; their own header calls that a read-only proof. What holds for all four
is that none of them may take a SECOND lease acquisition. The public
`autopilot_read_workspace` is the wrapper for callers
OUTSIDE it — it takes the lease itself — and it has exactly ONE: the
`post-review-tdd-delegate.sh` preflight, which passes a single argument. The Stop hook's rc=4
read was deleted when the fence began publishing its sentence, so the wrapper's preference
parameter currently has no production caller at all — S7h2 guards it for the next one. The symbol to look for is `autopilot_read_workspace`'s third
parameter, not a line number. Do NOT restate this as "there is deliberately no public
wrapper": that sentence stood here while the delegate was already calling one, and
it now contradicts the rc=4 account below in the same section. Owner-scoping that second group would let a
standalone `/zensu:tdd` chain arm underneath another session's durable run in the same tree.
The team-review identity check is a THIRD shape: it resolves the owner from the RUN record
and then asks the first question, because the pointer that must still designate that run is
its owner's, not the attesting caller's.

**The two deferred-review fences ask the owner-independent question and then WEIGH the
answer; that is not a fourth shape and it is not owner-scoping.** They still call
`_autopilot_read_workspace_critical` and a foreign run is still fully visible to them —
what changed is the CONSEQUENCE of a hold. `_autopilot_workspace_hold_blocks_adoption`
refuses on either of two independent grounds: the holder's `ownerSessionId` equals this
session (in production only reachable when the owner-keyed pointer read failed while the
run record is live, so releasing would infer completion for an active OWN generation), or
`_autopilot_deferred_work_present` reports deferred-review work. With neither, the fence
returns **6**, the code the Stop hook already treats as a normal no-work result. Every
unreadable input — an absent holder, an unparseable record, an unresolvable pending path —
answers BLOCKING, so the relaxation costs nothing fail-open. Only the FIRST fence of
`_autopilot_deferred_contention_result` takes this; its second fence stays unconditional,
because `tdd_pending_review_owned_by_other` has proven a foreign claim by the time it runs.

**`_autopilot_deferred_work_present` TRACKS `_tdd_adopt_pending_review_critical`'s "no
work" verdict; it is a HAND COPY of that ladder and must never be described as "the exact
predicate".** A bare `[ -f ]` existence test disagrees with the owner in BOTH directions and
each disagreement costs something real, which is why the copy carries three parts rather
than one. An UNSAFE marker — symlink, FIFO, directory, dangling link — is tamper evidence
the owner REFUSES on (`_tdd_path_safe … regular-or-absent`), so a bare test would relax the
fence on exactly the state the owner blocks on; the copy applies the same guard and reports
work PRESENT. A plain marker past the TTL is "no work" to the owner, which DELETES it and
returns 2 — so reporting it present rebuilds the permanent wedge, and because the fence
returns before that deleter runs, nothing would ever reap it either; the copy therefore
takes `ttl_hours` (threaded from `$4` in the locked fence and `$3` in the contention one, and passed on as the FIRST argument)
and excuses it through `_tdd_pending_file_stale`. A stale CLAIM is deliberately NOT excused,
because the owner reconciles a claim rather than dropping it. The residual divergences are
named rather than papered over, and the honest form is GENERIC because an enumeration goes
stale: any state the owner reaches only AFTER reading claim METADATA is "no work" to it and
"work present" here. Three exist today — a claim whose reconcile status is `owned`, a
`done|cancelled` claim with no queued marker, and a `done|cancelled` claim whose queued marker
is itself stale — all over-approximations that keep a refusal, never a relaxation. Note also
that the copy reads the marker under the OUTER lease only, never the pending lease that
governs it, so a marker published concurrently can read as absent. The marker is never LOST by
that: it stays queued, and the next Stop that samples it acts on it — with the tree free that
is the adoption, under a foreign hold it is the fence refusing again. What a missed sample
defers is therefore the REFUSAL, never the adoption, which is the same correction the
known-gap paragraph further down states in full; keep the three sites in step and do not
reintroduce "a later Stop adopts it", which names an outcome the held case cannot reach. The
standing fix for all of this is to export the source-selection
ladder from `zensu-tdd-phase.sh` so both modules call one predicate.

The threading is `ttl_hours` FIRST, `root` second, in both helpers — they take their two shared
operands in the same order on purpose, because both are optional with defaults and a
transposed call would produce a plausible-but-wrong anchor rather than an arity error.

**The own-run arm weighs an IDENTITY, so it must not be decided by filename sort order.**
`read-workspace` reported `inventory.find(...)` — the first nonterminal holder by sorted run
filename — and several runs can hold one tree, because a record carrying no `workspaceRoot`
holds EVERY tree in its project. A legacy foreign record sorting first would therefore
shadow the caller's own live run and flip the arm from block to release. The mode now
filters to ALL holders and accepts an optional fourth argument, a preferred
`ownerSessionId`, which both fences pass. **This does not owner-scope the question:** the
preference selects WHICH holder is reported, never WHETHER the tree is held, and with no
preference supplied the result is byte-identical to the first holder. `path_indexes` for
`read-workspace` stays `(0 1)` — the new argument is an identifier, not a path.

**What that fixed, stated because it was a shipped defect and not a hypothetical.** The
check ran BEFORE anything asked whether a deferred review existed, so a session whose own
chain was inactive (`OUTER_PRESENT=false` plus `SESSION_ACTIVE!=true` → `ADOPT_ELIGIBLE`)
was denied at Stop by a foreign run it had nothing to do with — and, because occupancy is
CONTAINMENT in both directions, by a run whose worktree merely sat below its tree. Measured
on 0.19.0 against a live consuming project: `autopilot_read_active` correctly answered
`rc=1` for the foreign session while `autopilot_adopt_pending_review` answered `rc=4`, with
no `pending-review.json` anywhere in that project. **`test-autopilot-stop-enforcer.sh` S7
PINNED that behaviour** — a foreign session's Stop was asserted to `block` — so this is a
deliberate policy change, not only a bug fix: S7 now asserts it RELEASES and still mutates
nothing, `S7d` is the discriminator that a queued deferred review restores the refusal, and
`S8g` is the control that an own active generation still fails closed. Do not "restore" S7.

**The rc=4 refusal names the holder, and that is load-bearing rather than cosmetic.** THREE
sites ON THE DEFERRED-REVIEW ADOPTION PATH produce rc=4 and all three render the existing
`_autopilot_workspace_refusal` on stderr — the locked fence, and BOTH fences of
`_autopilot_deferred_contention_result`,
including the second one, which refuses unconditionally and had been discarding the record.
State that base: `_autopilot_begin_standalone_tdd_critical` is a FOURTH caller of the same
renderer, on the standalone-begin path, and it refuses unconditionally — so a change to the
renderer reaches it too, and it passes its own session id for the same reason the three below
do.
That omission mattered precisely because the contention path is reached when the Outer lease
could not be taken, which is exactly when the hook's own lease-taking read fails too: the run
id was then named on NEITHER channel. `stop-chain-enforcer.sh`'s rc=4 arm takes the sentence the
fence PUBLISHED and performs no read of its own. It once re-read the holder here, and the rule
then was that the read had to carry `$SESSION_ID` as the holder preference — several runs can
hold one tree, and an unpreferenced read reports `holders[0]` while the fence judged a
different record, so the remedy could point at a run that is not the blocker. Publishing the
sentence removed the read and the rule with it; do not restore either from this paragraph.

**Three remedy texts, not one; the distinction is a safety property, and ONE site decides it.**
When the named holder is FOREIGN the block reason names `/zensu:autopilot-release` and the
operator stderr line quotes `zensu-log.sh --autopilot-release --run <id> --confirm` — one
renderer, two audiences, and only the stderr one is read by a human. When it is owned by THIS session the
reason must NOT offer that command: the release worker skips its self-release guard in exactly
this state — the guard fires only while the owner pointer still designates the run, and this
arm is reachable only when that pointer read failed — so following it would cancel the
session's own live generation. The third is the unnamed fallback when the holder cannot be
read at all, and it prescribes NO release command either — ownership is unknown on that
branch, and the own-run case is the LIKELY one there, because it is reached under the same
lease contention that made the read fail. Prescribing a release would aim it at this session's
own live generation in exactly the state the renderer withholds it from. So no branch pairs a
run id with a release command it has not verified as foreign, and
`_autopilot_workspace_refusal` emits the CLI spelling `zensu-log.sh --autopilot-release --run
<id> --confirm` for the OPERATOR audience and the slash form for the MODEL audience — one
renderer, two forms, and the audience argument is what selects. The unnamed fallback's own wording is pinned by S7n, and only
by S7n. S8g used to hold it and was re-pointed at the own-run wording when the published
sentence began reaching that fixture, which left it briefly uncovered; S7n is a SOURCE pin,
because the branch is unreachable from any fixture — the fence blocks for every holder it
cannot read, and a `stateValid` record always satisfies the renderer's shape tests. It asserts
the literal quotes no `--confirm` and no `zensu-log.sh` and names both ownership
possibilities. The holder clause is emitted LAST, and the reason has changed: it originally
had to be, because its named form ended in a shell command and anything appended was copied
along with it (an earlier spelling produced `--confirm.`). The MODEL form the block reason now
carries ends in a slash-command name instead, so the ordering is retained for consistency and
to keep a future reword from reintroducing the hazard, not because it is still load-bearing.

**A SECOND copy of the foreign sentence lives in the `begin` worker mode**, emitted from the
JS when a durable begin is refused, and it is pinned in a DIFFERENT suite
(`tests/structure/test-autopilot-state-machine.sh` W3, which greps the `workspace held by
nonterminal run …` lead and the `/zensu:autopilot-release` guided form, and asserts `--confirm`
is ABSENT — do not send a maintainer looking for a needle the suite now forbids). It
carries NO own-run branch, and the reason is ORDERING rather than a missing identity: the worker
DOES have the caller's `ownerSessionId` in that mode. What keeps the text foreign-only is that
the own-run cases above it (`hiddenNonterminal`, the pointer's own nonterminal run) already
`fail(4)`, and `candidate.runId !== runId` excludes the last survivor — so no own run reaches
that branch. Those checks must stay ABOVE it; widening them would emit a foreign remedy for the
caller's own live run. S7m now compares the two byte for byte by extracting the worker's
template and rendering the helper against the same run id, so a reword of either turns that
check red; before it, the two were pinned only in separate suites and could drift silently.

**The own-vs-foreign choice belongs to the RENDERER, and putting it anywhere else fails open.**
`_autopilot_workspace_refusal` takes the caller's session id as its second argument and selects
the wording itself; every caller that can see its own run passes it. The argument is POSITIONALLY
REQUIRED and only its VALUE may be empty — the renderer refuses on `[ "$#" -eq 3 ]`, so "optional"
was the wrong word for it and a two-argument call does not fall back to a form, it refuses. An earlier
spelling decided it in `stop-chain-enforcer.sh` from a second `_autopilot_holder_owner` read,
and that read's failure mode was the dangerous one: an unresolvable owner compared UNEQUAL to
the session id and selected the FOREIGN text, so the hook offered the release command against
this session's own live generation exactly when it could not establish ownership. Worse, the
library's own stderr line still quoted that command regardless, so the withholding was
contradicted on the operator channel. One decision site, inside the renderer, removes both:
the hook now resolves two names rather than three, and its only failure mode is the unnamed
fallback. A caller that omits the id gets the foreign wording — so omitting it is the thing to
check when a new call site is added. **Two arguments, not one:** a site that renders the
holder must ALSO forward the preference to the READ that produced it. The standalone-begin
fence passed the id to the renderer and not to the read for one round, which meant it could
never emit the own-run wording and would quote a release command against whichever record
sorted first. Three reviewers found that independently; treat "renders the holder" as
implying both.

**The fence PUBLISHES its rendered sentence, and the hook prefers it over re-deriving one.**
`_autopilot_publish_workspace_refusal` sets `ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT` beside every
rc=4 render, and BOTH public entry points — `autopilot_adopt_pending_review` and
`autopilot_begin_standalone_tdd` — clear it first, so a stale sentence can never be reused.
(The name carries the library prefix on purpose: it is the only module-scope assignment in this
file, and the house precedent for a sourced-library global the Stop hook reads by name is
`ZENSU_SAFE_VERSION_RE`.) **TWO forms are rendered from one holder.** The OPERATOR form goes to
stderr and quotes the audited `zensu-log.sh --autopilot-release --run <id> --confirm`, because a
human reads it. The MODEL form is what the block reason carries and names `/zensu:autopilot-release`
INSTEAD — `--confirm` is the consent control, so a complete invocation in a model-facing channel
routes around the only place that control exists, and a bare `zensu-log.sh` is a name a model
would resolve against the repository it is standing in. S7k pins all three shapes. This exists because the hook's own read happens AFTER the lease is released and the
worker reports `preferred || holders[0]`: a second FOREIGN run publishing in that window could
be named instead of the record the fence judged, and the rendered remedy quotes a real CANCEL.
Deriving it once, under the lease, from the judged record closes that window — and it made the
CONTENDED path strictly better, which is the measurable part: S8g now sees the run NAMED with
the own-run wording where it previously got only the unnamed fallback, because the contention
fence's unlocked read succeeds exactly when the hook's lease-taking one cannot.
`_autopilot_locked_run` runs its callback in the current shell and the Stop hook calls the
public verb without a subshell, which is what lets a variable carry it.

**The hook now takes the published sentence and NEVER re-derives one**, and the fallback that
briefly stood beside it was deleted rather than kept. Its stated trigger — "a runtime that does
not publish" — was unreachable (the plugin root is derived from the hook script itself and
re-checked, so hook and library are always one tree), while its REAL trigger was a failed render
— in which case a second read is a fresh chance to name the WRONG run, not a recovery. Deleting
it removed this file's last module-private `_autopilot_*` call: `hooks/` outside this library now
contains none. The suite still drives five private helpers directly, which is what
S7f/S7f2/S7g/S7h/S7j/S7k/S7m rest on.

Assertions inside ONE suite pin the wording — `tests/structure/test-autopilot-stop-enforcer.sh`
S7d's guided-form needle plus its assertion that `--confirm` is ABSENT — the AUDITED
`--autopilot-release --run <id> --confirm` needle moved to S7k when the block reason took the
model form, and S7k carries the `grep -qF --` guard that spelling still needs (without it grep
parses the pattern as options and the check passes vacuously, which it did),
S7d's positive assertion on the `Retrying Stop cannot clear the hold` clause — it was a
NEGATIVE assertion on a literal that existed nowhere in the tree, which could never fail and
left AC-004's no-retry-advice half unpinned — S7i's containment-case naming needle, S7k's three-shape renderer pin (operator form quotes the
audited command, model form names only the guided skill, own-run holder gets neither)
(the release command must be ABSENT there and present for a foreign holder), S7j's negative
shape tests on both renderers, S7n's source pin on the unnamed fallback (behaviourally
unreachable, so a source pin is the only available control), S8i's end-to-end own-run pin (the run named, the release
command absent), S8g's contended own-run pin (the same property reached through the PUBLISHED
sentence rather than the hook's read), S7m's byte comparison of the `begin` worker's twin
against the renderer, and the shared `holds this working tree` lead — so rewording it
is a same-suite edit, EXCEPT for the own-run clause: S7o pins `which belongs to this session`
and `finish or repair that run` against `skills/autopilot-release/SKILL.md`, which teaches the
model to recognize that case by those literals. The needles are deliberately different: a bare
`autopilot-release` substring matches BOTH branches and would have let the named and unnamed
paths pass each other's check.

**The relaxation DISCLOSES.** `_autopilot_workspace_hold_blocks_adoption` prints one stderr
line before returning false, because rc=6 is otherwise indistinguishable from "no run held the
tree at all" and a guard that stands down invisibly is the shape this repository treats as
worse than the wedge it removes. It is not a bypass-ledger entry and must not become one: no
user-supplied switch was escaped. **The premise under that argument is UNVERIFIED and is
recorded as such:** nothing measured in this work establishes that this host surfaces
Stop-hook stderr to the user on a non-blocking exit 0. If it does not, the relaxation has no
observable at all and the disclosure argument above buys nothing — so verify it before
leaning on it, and do not restate the claim as though it were established. S7g captures that stderr separately and requires it — the
hook fixtures cannot, because `invoke()` discards stderr, so without a direct capture the line
could be deleted with every check green. **Accepted cost, named because it is not obvious:**
the line is UNRATED and the state that produces it is a steady state, not an event — an
ordinary session with no own run and no active chain reaches `ADOPT_ELIGIBLE` on every turn
end, so the disclosure repeats on every Stop for as long as the foreign run stays nonterminal.
Gating it would remove the observability it exists for; the repetition is the price — but
the price has a known, unpaid remedy and it is named here rather than left to be rediscovered:
this repository already ships the shape that keeps the observability without the noise, the
per-session band file in `user-prompt-context-nudge.sh`, which here would key on the pair
(session, holder run id) so the line prints once per hold rather than once per turn end. Not
implemented; a follow-up, not a defect.

**Two ordering rules inside the fence, both learned by having them wrong.** The ladder
has the WORK arm LAST, and every arm above it returns the same value — 0, blocking. So while a
marker exists a `blocks` result is UNATTRIBUTABLE, and a check that drives the guards then
proves nothing about any of them. State the mechanism, not the outcome: an earlier wording here
said the work arm "masks every guard above it", which has the order backwards. That is why S7f keeps only
the marker-decided arm and S7f2 re-drives every input guard, plus the claim and unsafe-marker arms, after `rm -f`. And the `root`
parameters default to `${CLAUDE_PROJECT_DIR:-}` rather than to empty — an empty value is
indistinguishable from unset to `_tdd_path_safe`, so defaulting to empty would CLEAR a correct
anchor and reinstate the nearest-existing-ancestor fallback the parameter exists to prevent.

**The library ALSO writes that sentence to stderr from inside the fence, and the redundancy
is deliberate.** They serve different consumers — operator stderr versus the model-facing
block reason — and it is the CONTENDED case that needs both: there the library renders a
NAMED line from its unlocked read while the hook's lease-taking read fails and falls back to
the unnamed remedy. Removing either loses the run id on one of the two paths. Accepted cost:
on a contended Stop the user can see the sentence twice, and the two reads are taken at
different instants.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field, no strict key set (the run schema's `STATE_KEYS` /
`STATE_KEYS_WORKSPACE` are untouched), no hook added, removed or renamed and no matcher
changed, no new config key (the fence reuses `zensu_pending_review_ttl_hours`), no
attestation change. The `read-workspace` worker mode gains an OPTIONAL fourth argument, which
is a call convention inside one installation and never a persisted shape — an older runtime
passing three args gets its previous answer. The Stop hook denies strictly LESS than before,
which cannot make state written by one runtime unreadable to the other; the capability rule
in that section is about ADDING a hook that can deny, and relaxing an existing hook's deny is
not in the list. Recorded here because the section's other `**Version.**` paragraph reads
`minor` and describes the ORIGINAL pointer/schema change, not this delta.

**The audience is a property of the CHANNEL, and all three model-read channels were routed to
the guided form.** The two that a first pass left behind were `_autopilot_begin_standalone_tdd_critical`'s
stderr — the tool RESULT of a `zensu-log.sh --tdd-begin` a model runs — and the `begin` worker's
own `fail(4, …)` twin, surfaced by `zensu-log.sh` the same way. Both now emit
`/zensu:autopilot-release` rather than a runnable `--confirm` invocation, which cost W3 and W13
in `test-autopilot-state-machine.sh` and re-pointed S7m at the renderer's MODEL form. The
OPERATOR form survives on exactly one channel: the Stop hook's stderr, where a human reads it.
`_autopilot_publish_workspace_refusal` therefore takes the stderr audience as its third
argument, and `_autopilot_workspace_refusal` REFUSES an unrecognized audience rather than
defaulting to the permissive spelling.

**CLOSED, and recorded so it is not re-opened as a gap:** the contention fence's
foreign-holder-WITH-WORK rc=4 arm had no executed case — S8g reaches that fence through the
own-run arm and S8h through the release arm — and S8j now drives it, asserting the run is named
and no runnable cancel is quoted.

**Known gap: the `root` parameter of `_autopilot_deferred_work_present` and
`_autopilot_workspace_hold_blocks_adoption` is UNPINNED, for TWO reasons and the second is
structural.** Asserting that the fence blocks pins nothing there, because the
predicate fails closed and every failure mode gives that same answer. The discriminating shape
needs the anchor alone to decide, and an attempt at it did not reproduce that split — the marker
path is resolved through `zensu_resolve_project_dir` rather than through the symlinked component
such a fixture plants. And every fixture in that suite lives under `$TMP`, while
`_tdd_paths_safe` always trusts `${TMPDIR:-/tmp}` as an anchor, so the argument can never BE the
deciding anchor there. A discriminating check needs a fixture rooted outside both `TMPDIR` and
`HOME`. Recorded rather than papered over with a check that passes for an unestablished reason.

**Known gap: `_autopilot_deferred_work_present` tracks the MARKER half of the owner's ladder
only.** (Anchor by SYMBOL, not by line: every line reference into this file went stale within a
round while the symbol names did not.) Any claim file
at all reports work present, while the owner reads claim METADATA and answers no-work for a
claim reconciled `owned` by another session and for a `done|cancelled` claim with nothing
queued. So with the tree free those states release, and under a foreign hold they still block —
the same class of refusal this change removes, one case narrower. Direction is a retained
refusal, never a relaxation, which is why it ships; closing it needs a read-only reconciliation
status `zensu-tdd-phase.sh` does not export, which is the recorded standing fix.

**Known gap: the own-run arm is a correctness guard, not an authorization boundary.** It
decides on `ownerSessionId`, an unauthenticated field in a directory this file elsewhere
records as session-writable, and `stateValid` checks only its SHAPE — there is no MAC and no
counter over a run record. So a session can flip its OWN fence between block and relax by
editing its own record, exactly as it could already by deleting it. The holder preference
closes the ACCIDENTAL shadowing (a legacy foreign record sorting ahead of the caller's live
run); it does not close a deliberate write, and nothing here should be read as doing so.

**There is a SECOND direction, and it runs the other way.** The preference selects the holder
by `ownerSessionId`, so a co-tenant that writes ONE shape-valid record carrying a VICTIM's
owner id and a `workspaceRoot` containing the victim's tree steers that victim's fence onto the
own-run arm — and the own-run arm withholds the release command and names a run the victim can
neither see through `--autopilot-status` (which is owner-scoped) nor release. The direction is
non-destructive and it cannot make a fence RELAX: the own-run arm blocks. But it is a foreign
writer changing what another session is told, which is more than "a session can flip its own
fence", and the state directory is writable from inside any session in the project.

**Known gap: a stale marker under a held tree is never reaped.** The release arm returns
before `tdd_adopt_pending_review` runs, and that call is what owns the `rm -f` for an expired
marker. The marker is inert while stale and is reaped by the first adoption after the hold
clears, so this is a leak rather than a wedge — but the fence's own comment argues the
reaping asymmetry against the OPPOSITE choice, and it applies to the branch that shipped too.

**Known gap, accepted and named: work-presence is sampled once, unlocked, at BOTH fences.**
Scoping this to the contention path was wrong and read as if holding the Outer lease made the
locked fence immune. It does not: the Outer lease and the PENDING lease are different
resources and `_autopilot_deferred_work_present` takes neither, so
`tdd_write_pending_review` — which takes the pending lock — can publish a marker that either
fence misses. The contention fence has the sample outside its own check-prove-recheck bracket
as well, but that bracket only ever re-read OCCUPANCY, so it was never the thing that would
have covered this.

State the consequence precisely, because an earlier wording got it backwards: what is deferred
is the REFUSAL, not the adoption. A missed marker makes this Stop RELEASE; on the next Stop the
marker is visible, so the fence sees work in play and the foreign hold BLOCKS again. The marker
is never lost, and no Stop adopts anything it should not — but "a DEFERRED adoption" described
an outcome that does not occur, since a held tree is exactly where adoption does not happen.

**CONTAINMENT is pinned, and it took a real git fixture to do it.** Every other check in the
suite builds a plain `mktemp -d` project, so holder and stopper resolve the SAME workspace
key and only EQUALITY is exercised — the containment branch of `mayHoldWorkspace` is never
taken. S7i is the one that reaches it: `git init` plus `git worktree add` of a NESTED
worktree, the run begun with that worktree declared through `autopilot_begin_run`'s sixth
argument, and the Stop driven from the CONTAINING tree. It asserts both directions in that
one tree — release with nothing queued, and a refusal naming `contain_run` once a marker
exists. That is the exact shape of the reported production defect, so it is the check to
keep working if the fixture ever goes red. Note the two prerequisites it silently needs: a
usable `git worktree` (it fails loudly rather than skipping if the directory is absent) and
`autopilot_begin_run`'s workspace override, which refuses anything that is not itself a git
toplevel.

**One resolver decides the workspace for the writer and for every gate.**
`_autopilot_session_workspace` resolves cwd → git toplevel → canonical path, and falls back
to the project root when cwd is outside it. `autopilot_begin_run` and all three occupancy
gates call it. Two different spellings would make a gate silently miss the run it exists to
see. `--autopilot-begin --workspace <path>` overrides it, but only for a tree that is either the session's own resolved tree or a directory under the project root; anything else refuses with rc 3. Accepted narrowing: a git worktree OUTSIDE the project root can no longer be declared.
`workspaceRoot` is deliberately NOT a member of any `path_indexes` list in `_autopilot_node`:
it is a comparison key rather than a path the worker opens, and it may legitimately sit
outside the project root, which `_autopilot_native_project_path` rejects by design.

**The field is accepted in BOTH key shapes on purpose.** `stateValid` admits `STATE_KEYS`
and `STATE_KEYS_WORKSPACE`, and `mayHoldWorkspace` short-circuits on an ABSENT field, so a
record minted before the upgrade holds EVERY workspace in its project — not its `projectRoot`,
which is what an earlier draft of this paragraph claimed and what the deleted `workspaceOf`
fallback would have implemented. A single strict key set would make every run minted before
the upgrade invalid, `readRunInventory` fails the FIRST invalid record, and the whole project
would then fail closed — strictly worse than the wedge this work removes.

**The occupancy comparison is CONTAINMENT, not equality, and it runs in both directions.**
The key is a git toplevel resolved from the CALLING process's cwd, and the writer and the
gates are different processes: a session that begins a run from the project root and later
reaches a gate from a worktree BELOW it produces two different keys for one branch. `contains`
answers "held" whenever either tree contains the other, which also covers the git-failure
fallback — that path yields the project root while a working resolve yields the repository
toplevel above it. Equality alone reported such a pair as free, and a standalone `/zensu:tdd`
chain then armed underneath a live durable run.

**The FORWARD direction is the one that is not solved, and concurrency makes it normal.**
`begin` writes `workspaceRoot` while still declaring `schemaVersion: 1`, so an installation
WITHOUT this change reads an unknown key at a version it claims to support and rejects the
record. Two mitigations, and the residue between them is stated rather than glossed. First, the
blast radius is bounded: `read-active` now passes its owner into `readRunInventory`, which skips
a record it can prove belongs to someone else BEFORE validating it, so one session's
unreadable record no longer fails every session in the project. Anything unattributable — a
record that will not parse at all — still fails closed, because it cannot be proven to be
someone else's. Second, `begin` and `read-workspace` deliberately pass NO owner and stay strict:
they genuinely need every record. The residue: an older installation running `begin` in a
project where a newer one is live still fails closed, and that is not tested because the suite
has no second installation to run it from. The lineage rule does not cover this — it governs
Session Control record binding, not the project-local run inventory — so a MINOR release is the
only thing standing between the two.

**The `--confirm` on `--autopilot-release` is prose-backed, not consent-backed.** It is an argv
token the model can supply to itself, exactly like `zensu-session-adopt.sh --confirm`, and the
"wait for the user to say yes" control lives in `skills/autopilot-release/SKILL.md`, not in a
gate. Say so plainly rather than describing the flag as user confirmation. What bounds the
damage MECHANICALLY is that it escapes no gate and cannot forge `DONE` — the worker only ever
applies `CANCEL`. Everything else is prose: the skill tells the model to take the run id from a
refusal, but nothing enforces that, and any nonterminal run in the project is releasable by id
from an enumerable directory. Nor is liveness checked: a run whose owner session is very much
alive is cancelled just as readily. `.zensu/state/` is already writable from inside a session by
an ungated shell redirect, so the flag is not the narrowest channel to that directory either.

**The legacy pointer is adopted only by its own owner.** `autopilot-active.json` is never
written any more. When the owner-keyed pointer is absent it is read as a fallback and honored
only if the run it references belongs to the caller; a legacy pointer owned by anyone else is
ignored, and that is precisely the unwedge. `activePointerFor` re-implements the same
resolution inside the worker for `apply` and both budget modes, which receive the state
DIRECTORY rather than a pointer path and derive the owner from the run record.

**`--autopilot-release` bypasses exactly one check.** It applies a real `CANCEL` under the
project lock with the ownership comparison skipped, and refuses a terminal run, a caller that
owns the run, and an exhausted ledger. Provenance is the derived event id (`release-<sha256>`),
NOT a payload field: `payloadValid` requires `CANCEL` to carry the empty object, so a marked
payload would make the released run unreadable to any runtime that has not taken this change.
**No bypass-ledger entry** — the ledger records gate ESCAPES so that everything under "Gates
bypassed" is true, and this escapes no gate. Same rule, same reason, as `--chain-recover`.

**Version.** The pointer layout and the run schema both move, so this is a **`minor`** release
under "Runtime Lineage (`version_type` is load-bearing)" above. The version is never set by
hand; the release pipeline owns it.

**Known gaps, accepted:**

- A refusal names the holding run but the release is a separate, user-confirmed step. It has
  to be: the run belongs to a session that may still be alive.
- **`OWNER_SESSION_MISMATCH` in `plan-approved-delegate.sh` is now unreachable, and the plan
  it used to refuse falls through to the standalone policy instead.** A foreign session that
  approves a plan carrying another run's `<!-- zensu-autopilot:<run> -->` marker no longer
  reaches the owner comparison, because the run is invisible to its owner-scoped read; it is
  asked the ordinary "run /zensu:tdd?" question. Nothing is mutated — the foreign run is not
  touched and no binding is created — so this is a lost DIAGNOSTIC, not a lost guarantee.
  Restoring it needs the marker before the read, and the marker is only resolved inside the
  payload evaluator (see "Plan-Gate Payload Sources"), which reads fields by name and must
  not be duplicated in shell. The exit-6 arm and its `BLOCK_CODE` are deliberately left in
  place rather than deleted, so a future evaluator that can answer "this marker names a run
  you do not own" has its receipt waiting. What the foreign caller now gets is NOTHING: the
  branch is skipped before any payload source is resolved, so it cannot be used as an
  existence oracle either — which is what F20/F20a, F32/F32a and F45c in
  `tests/structure/test-plan-payload-fallback.sh` pin, alongside P6 in
  `tests/structure/test-autopilot-plan-delegate.sh`. Those five cases were written against
  the refusal receipt and now assert the silence instead; F45c in particular no longer pins
  an ORDERING between the ownership and origin refusals, because neither is reachable.
- `/zensu:doctor` still carries NO Autopilot row of any kind. A held workspace is visible in
  the `--autopilot-begin` refusal, in the standalone-TDD begin refusal, in the deferred-review
  Stop refusal (which names the holding run whenever it can be read — including when it
  belongs to this session, where only the release COMMAND is withheld — and names no run at
  all when the read failed), in the
  stderr line the fence prints when it stands down, and in `/zensu:autopilot-release`. Do not
  claim doctor visibility until that row exists — and keep this enumeration in step with the
  rc=4 account above, which is where those refusals are specified.
- The `SESSION_CONTEXT_UNAVAILABLE` arm in `plan-approved-delegate.sh` is defense in depth, not
  the live path: `zensu_bind_hook_session` refuses an unresolvable session earlier, so the receipt
  a caller actually sees in that state is `RUNTIME_UNAVAILABLE`. Measured by P8a-P8c in
  `tests/structure/test-autopilot-plan-delegate.sh`, which therefore pin the fail-closed DIRECTION
  (a `PLAN_GATE_BLOCKED` receipt rather than the standalone policy) and not the specific code.
- `_autopilot_storage_safe` validates the legacy pointer by name; the owner-keyed one is
  checked at `_autopilot_begin_critical`, the only site that writes it. Reads are protected
  by `regularFile`, which rejects symlinks and hard links.

Moving together with the scope: `_autopilot_owner_key`, `_autopilot_active_path`,
`_autopilot_legacy_active_path`, `autopilot_workspace_root`, `_autopilot_session_workspace`,
`_autopilot_read_workspace_critical`, `autopilot_read_workspace` and
`_autopilot_workspace_refusal` — which `stop-chain-enforcer.sh`'s rc=4 arm NO LONGER resolves at
all: it once resolved three names there by `declare -F`, and all three are gone (the ownership
read moved into the renderer, and the re-read fallback was deleted). What the arm now depends on
across the file boundary is the VARIABLE spelling, not a function name; the one surviving
`declare -F` in that file guards `autopilot_adopt_pending_review` and is unrelated —
`_autopilot_holder_owner`, `_autopilot_holder_run_id`, `zensu_pending_review_claim_file` (exported from
`zensu-tdd-phase.sh` so the `.claim` suffix is not re-encoded here — a drifted copy would fail
OPEN, because adoption RENAMES the marker onto the claim and a reader looking for the wrong name
would see neither file and answer "no work" while a deferred review is live; the accessor now
takes an OPTIONAL pre-resolved pending path, and the owner module's five former hand-spellings
call it, so `zensu-tdd-phase.sh` spells the suffix exactly ONCE. A SIXTH spelling survives outside
that module and belongs on this roster: `hooks/lib/session-control-core-v1.js` hardcodes the whole
filename `pending-review.json.claim`, which no accessor can reach and nothing pins against this
one) and
`_autopilot_publish_workspace_refusal` (both intra-file: the Stop
hook calls neither, so renaming either is a single-file edit), plus the module-scope
`ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT` that publisher sets — THAT spelling is what
`stop-chain-enforcer.sh`'s rc=4 arm reads across the file boundary, so renaming IT is a
cross-file edit whose failure mode is the unnamed fallback — `_autopilot_deferred_work_present`,
`_autopilot_workspace_hold_blocks_adoption` (whose pending predicate is a HAND COPY of
`_tdd_adopt_pending_review_critical`'s ladder, pinned end-to-end by S7/S7d/S7e/S7i and
arm-by-arm by S7f/S7f2/S7g, which drive it directly because no hook fixture reaches those
guards; S7h and S7h2 pin the holder preference at the private and PUBLIC read; S8i pins the own-run remedy end to end through the LOCKED
fence, and S8g reaches the same wording through the CONTENTION fence — its stub kills
`_autopilot_locked_run`, so the two cover both publish paths rather than one twice), `_autopilot_rendered_dir`, `autopilot_release_run`, the `read-active` / `read-workspace` /
`begin` / `apply` / `release` / budget worker modes with their `path_indexes`,
`projectRootIndex` and `workspaceRootIndex` entries, the worker's own second re-encoding of the
pointer name (`activePointerFor`, `OWNER_POINTER_PREFIX`, `LEGACY_POINTER_NAME`), the SEVEN hook
`read-active` call sites enumerated above, the three `ACTIVE_POINTER_HINT` probes that name both
pointer spellings, `hooks/lib/zensu-log.sh` (the `--workspace` flag, the owner-aware
`--autopilot-status`, and the `--autopilot-release` verb with its derived event id),
`skills/autopilot/SKILL.md`, `skills/autopilot-release/SKILL.md`, and the plugin manifest's
skill list. Operator-facing accounts that must move with it: `README.md`'s skill table,
`docs/tdd-manager-workflow.md` §"Autopilot run scope", the `session-start-autopilot-resume.sh`
row in `docs/configuration.md`, and — easy to miss, because the roster named only the resume
row while the deferred-review fence account lives elsewhere — the `stop-chain-enforcer.sh`
row in `docs/configuration.md` — and its `pendingReviewTtlHours` row, the ONLY written statement
anywhere that at `0` a marker of any age sustains this refusal indefinitely. The
`stop-chain-enforcer.sh` row PARAPHRASES the fence's pending-work precondition but
QUOTES both remedy spellings — `/zensu:autopilot-release` and the audited
`zensu-log.sh --autopilot-release --run <id> --confirm` — so a reword of either remedy is a
cross-file edit. Only the refusal SENTENCE itself is pinned solely by the
`test-autopilot-stop-enforcer.sh` assertions above.
`tests/structure/test-autopilot-state-machine.sh` pins the pointer, the two refusals and the
legacy fallback; `test-autopilot-adversarial-recovery.sh` X1a pins the `begin`, `read-active`,
`release` and `read-workspace` `path_indexes` literals. It does NOT pin every mode in the table
— `read-run`, `apply`, `team-review-receipt-meta` and the two budget modes are unpinned, so a
change to one of those fails behaviorally or not at all.

## CLI Command Classification (`hooks/lib/zensu-mcp-tools.sh` + `hooks/lib/zensu-cli-map.sh`)

The plugin drives Zensu through the typed `zensu` CLI (the MCP server still exists for the Zensu web app, but is no longer wired into the plugin). The write-gate now intercepts `zensu <noun> <verb>` Bash invocations rather than MCP tool calls.

**When the Zensu backend gains a new operation, two files move together:** classify the canonical tool name in `hooks/lib/zensu-mcp-tools.sh` (state-mutating → `ZENSU_MUTATION_TOOL_NAMES`; read/telemetry → the `zensu_is_read_tool` allowlist `ZENSU_READ_TOOL_PREFIXES` / `ZENSU_READ_TOOL_NAMES`), AND map its `zensu <noun> <verb>` CLI form to that tool name in `hooks/lib/zensu-cli-map.sh`.

`zensu-mcp-tools.sh` is the single source of truth for read/mutation classification, consumed by:

- `hooks/pre-bash-zensu-gate.sh` — the PreToolUse(Bash) write-gate: parses `zensu <noun> <verb>` from the command, resolves each via `zensu-cli-map.sh`, and classifies via this SoT — `zensu_is_read_tool` commands pass ungated, mutations are default-denied unless workflow-driven.
- `hooks/lib/zensu-cli-map.sh` — the CLI→tool-name adapter the gate and the marker test use. Its mutation entries stay a subset of `ZENSU_MUTATION_TOOL_NAMES`.
- `tests/structure/test-skill-workflow-markers.sh` — the build-time guard that fails if a skill runs a `zensu` mutation command (resolved via the map) without the `--workflow-begin` / `--workflow-end` markers.

Consequences of forgetting a new operation:

- **New mutation, not added to `ZENSU_MUTATION_TOOL_NAMES`:** the marker test will NOT flag a skill that runs it un-wrapped. **Test-coverage gap, not an open gate.**
- **New read, not added to the read-allowlist:** if the map resolves it to a name that classifies as a mutation, it is wrongly gated on the main thread until added.
- **New CLI verb, not added to `zensu-cli-map.sh`:** the gate cannot resolve it → treated as unknown/neutral → allowed ungated, so a mutating verb would slip the nudge. Add every new mutating verb to the map.

Invariant: `ZENSU_MUTATION_TOOL_NAMES` must stay a strict superset of every skill's `--workflow-begin --tools` declaration AND of every mutation the CLI map emits. `tests/structure/test-bash-zensu-gate.sh` + `test-skill-workflow-markers.sh` pin the read/mutation classification and the CLI-form detection.

## Foreign-Chain Row (`zensu-doctor.sh` + `zensu-doctor-report.js`)

A session FORK is silent: the host mints a new session id mid-conversation, carries the
whole history over and re-fires `SessionStart`, so the workflow document armed under the
old key becomes unreachable and every later `zensu-log.sh` call answers `no-session`. The
chain stops existing while the user still believes it is running. `/zensu:doctor`'s
`chain: open chain(s) not owned by this session` row is the only thing that reports it.

**FOUR halves, and a port that takes three ships a row that silently never fires.** The wrapper exports `ZDOC_SESSION_KEY` and
`ZDOC_SESSION_PROJECT_ROOT` out of its own `zensu_bind_model_session` (one tab-separated
substitution, so a single status decides the `bound` branch and a partial pair is dropped
whole); the renderer owns the predicate and its single `bound`-plus-shape guard AND the
record-anchored state directory; the chain-shape OWNER must export `INERT_SHAPES`, whose
absence withholds the row; and the operator accounts carry the diagnose-only limit. The premise is
HOST-COUPLED: a host that cannot mint a new session id mid-conversation has nothing to
diagnose here.

**The row states an OBSERVATION, never a cause, and that wording is the feature.** Nothing
available to a read-only renderer distinguishes a forked-away session from a live sibling
driving its own chain in the same project — and a live sibling is ORDINARY under this
repository's own worktree rule. An earlier draft asserted the fork as fact and prescribed
`/zensu:tdd`; that made a false claim about a running session and told the reader to arm a
competing chain. Only the WORDING changed — the row is still `WARN`, `line()` counts WARN toward
`warnCount`, and `main()` gates "all checks green" on it, so the green-summary consequence below
is still live and is listed as a gap rather than as something the reword fixed.

**The CAUSE ORDER inside that wording is itself a contract, and it was wrong once.** The row's
predicate is every open chain in this project not owned by this session and inside the TTL. The
DOMINANT member of that set is a session that ended without `--chain-done` — a closed terminal —
not a fork. An earlier wording named the fork as "the usual cause" and opened with "if those
sessions are still running, nothing is wrong here": it described the rare case and dismissed the
common one, which trains a reader to ignore the row. The abandoned chain is named FIRST, the live
sibling second, the fork third, and `P1mj1` pins that order. Note what this does NOT change: for
an abandoned chain the state really is stale, so the row is correctly a warning — demoting it to
`OK` was considered and rejected, because a row that can never affect the summary is a row people
stop reading. The green-summary cost is the price and is recorded as a gap below.

**The deletion target is SHELL-QUOTED, never filtered against a character class.** A
`DELETABLE_PATH_RE` allowlist was tried first and was wrong in BOTH directions: it excluded
`path.sep`, so on win32 no candidate could ever match and the whole pending-review cleanup was
unreachable on that host, and it excluded the space, so an ordinary `~/My Projects/...` was
refused with a message blaming the user's filesystem. `shellQuotePath` single-quotes instead,
which is total; only a CONTROL byte is still refused, because quoting makes it harmless to the
shell but not to the report line a model reads back. `deletableTarget` also walks from the
CANONICAL root (`realpathSync.native`) rather than the caller's spelling, which is what makes the
"no component of the chain is a symlink" claim TRUE rather than true-below-the-root — requiring
`root` to equal its own realpath instead would refuse every macOS session under `/var/folders`.
Its `..` test is the ANCHORED form, and it returns `{path, reason}` so the row names WHICH check
failed: an unresolvable disjunction reads as a fault in the user's filesystem. `skills/doctor/SKILL.md`
Phase 3 consumes the quoted literal verbatim and re-verifies the chain AFTER the confirmation,
because the renderer measured it before.

**The pending-review row ages on the marker's own `ts`, not on the filesystem mtime.**
`pendingReviewStamp` mirrors `_tdd_pending_file_stale` in `hooks/lib/zensu-tdd-phase.sh`, which is
the canonical staleness reader for that file. Reading the mtime alone let the doctor print
"expired, safe to clear" for a marker the Stop enforcer still treated as LIVE — the same class the
`ttl === 0` fix closed, on the other axis. Two readers of one file must not disagree about which
markers are dead. The `ts` read is size-bounded; an absent or unparseable `ts` still falls back to
the mtime, so the pre-existing behaviour survives.

**The whole Session state block is anchored on the RECORD's project root, not on
`CLAUDE_PROJECT_DIR`, and that is a fix to PRE-EXISTING rows as much as to this one.** Every
writer anchors there: `zensu-log.sh` re-exports `CLAUDE_PROJECT_DIR` from
`zensu_resolve_project_dir`, which resolves `ZENSU_PROJECT_ROOT` out of the immutable record,
before any verb body runs. The renderer read the raw harness value, so whenever the two differed
— the ordinary case for a session whose cwd is a worktree — `stateBlock` scanned a directory no
writer uses and `readWorkflowState` never opened the documents at all. `stateProjectRoot` prefers
the recorded root under a `bound` verdict and falls back to the caller's value only because a
session with no record has nothing better. **An earlier attempt COMPARED the two and withheld the
row when they disagreed; that was strictly worse** — it withheld exactly the fork-in-a-worktree
case the row exists for, and silently. Do not reintroduce the comparison.

**Two conditions withhold the row, both fail CLOSED, and BOTH now DISCLOSE.**
`currentSessionKey` requires `ZDOC_BINDING === 'bound'` beside the shape. The wrapper
states "empty for every verdict except bound" and now clears both values unconditionally
rather than `:=`-seeding them — the only two EXPORTED `ZDOC_*` that deviate from that convention,
because their meaning depends on a verdict reached further down and the `unknown` /
`unavailable` branches never reach the bind. The reader enforces it anyway, since a caller
supplying `ZDOC_BINDING` skips the whole resolution block; without that, one report could
print the ❌ no-record row and, below it, a row keyed on a session key it had just said does
not exist. The wrapper half used to withhold SILENTLY, which is the one verdict a diagnostic
may not give — it now emits its own "missing check, not an all-clear" row, and the module
half's row is no longer conjoined on `ownKey !== ''`, because that conjunction meant a tree
which broke BOTH halves printed NEITHER row. `rowArmed` names the arming rule once, above the
loop, so the filter and the two disclosures cannot drift apart. `P1mm5`/`P1mm6` pin the
wrapper half in both directions.

**Ordering is a contract.** The foreign-open push sits BELOW the wedged and dead-end early
returns. Those rows carry their own remedy, and a second row naming the same truncated key
with a contradictory instruction is worse than no row. `P1ms2` pins it with an `awk` line
comparison, because no fixture in the suite builds a wedged chain.

**Age comes from the document's `updated_at`, and there is NO mtime fallback** — `.zensu/state/`
is session-writable and a bare `touch -t` would move a document out of the window without
producing anything `validateWorkflowState` accepts. An `updated_at` that does not parse yields no age at all
and excludes the entry — a fallback would be dead code pretending to be a safety net — and, WHILE THE BOUND IS ARMED, a
stamp in the FUTURE is treated as outside the window rather than absolute-valued, so a skewed
or planted one cannot hold the row open forever. At `0` no window is claimed, so only a stamp
that cannot be read at all excludes an entry. `0`
DISABLES the bound rather than shrinking it to nothing, matching `docs/configuration.md`
and the sibling `reviewerDenialRows`; the row then drops its "touched within Nh" clause
rather than advertising a 0h window.

**A BLANK `ZDOC_TTL_HOURS` now falls back to the default rather than resolving to `0`, and
that is a behaviour change to this row as much as to the pending-review one.** `Number('')`
is `0`, which passed the `>= 0` bound, so a wrapper fault that exported an empty string
switched the window off silently — and `zensu-doctor.sh` exports the variable unconditionally
after a conditional resolve, which makes blank reachable. `ttlHours` and `implStopThreshold`
read through one `boundedEnvInt`, so absent and blank take the fallback and only an in-range
integer wins. `ttlHours()` has THREE call sites — this row, the pending-review verdict and
`reviewerDenialRows` — and a FOURTH consumer of the resolved value, `ownRefusalNoteLive`,
which takes it as a parameter rather than re-reading it. Word it that way: counting it as a
fourth CALL SITE double-counts the read this row already performs. That fourth consumer is
what decides whether the implementing-turns row carries its refusal caveat. That last one
carries a consequence the discussion above does not otherwise cover: at the documented `0`,
`classifyDenialNote` never returns `stale`, so a note of any age keeps qualifying that row.

**Known gaps, accepted and named:**

- **A model holding the PREVIOUS release's skill body deletes a file this report never
  examined, and no renderer-side change can prevent it.** `skills/doctor/SKILL.md` as shipped in
  **0.19.0** says to DERIVE the target: "`${CLAUDE_PROJECT_DIR}/.zensu/state`". Under the lineage
  rule a `0.19.0 → 0.19.x` update keeps the session running, so the NEW renderer measures the
  RECORD root while the model still holds that instruction — and where the two differ, which is
  exactly the worktree case this feature exists for, the confirmed `rm` removes the other tree's
  marker. Verified against the installed 0.19.0 skill, not inferred. Three larger fixes were
  considered and none closes it: quoting the path does not help (an old body never reads the
  row's path), a `--clear-pending --confirm` verb does not help (an old body does not know it
  exists), and suppressing the word "expired" would delete the finding in the one case it
  matters. What bounds the harm: the user still confirms, and the damage is one stale marker.
  What this change DOES do is make the CURRENT skill safe — it consumes the printed literal and
  re-verifies after the confirmation. Do not describe this as mitigated.
- **The branch that PRODUCES the exported pair has no executed coverage, and the reason is
  measured.** `P1mp`/`P1mp1` are source greps. An earlier note claimed a real bind needs a live
  host session; that is FALSE — against the suite's own `strand-open` baseline
  `zensu_bind_model_session` returns 0 from a plain child process, and the wrapper's exact
  substitution body reproduces the correct pair inline. What could not be made to work is
  `bash "$HELPER"` end to end, which still reports no valid record in that fixture; the cause was
  not established (it is not the in-substitution comment and not the shape guards, both measured).
  The end-to-end check was REMOVED rather than weakened until it passed. So the composite exit
  status, the TAB split and the pair reaching the renderer are unexercised — on a branch that
  decides `ZDOC_BINDING` for every session, not just this row.
- **A same-project-root sibling permanently withholds the green summary.** The row is `WARN`, so
  while another live session holds an open chain under the SAME project root and within the TTL,
  `/zensu:doctor` cannot print "all checks green". A sibling in its own worktree has its own
  `.zensu/state` and does not trigger it. `P1mg1` pins the row's contribution to the warning
  count, which is the same property from the other side.
- **The Windows wall clock for the enlarged `test-doctor.sh` block is UNMEASURED.** The suite is
  absent from `tests/profiles/windows-ci.v1.json` and sits in the `excluded` list of
  `windows-native-structure.v1.json`, so no PR shard runs it — but the weekly Windows Safety
  structure shards do, and the foreign-chain block roughly doubled the suite's process count.
  A LOCAL run took 28 s on a loaded machine, but a loaded-local second is not an ubuntu-latest
  second; that entry now reads 12 — the previous 6 s CI figure doubled — and is labelled an
  estimate in the file's own note. Take
  the figure from the next green weekly Windows run and replace both. Say "unmeasured", never
  "cheap".
- **"No full session key is printed" scopes to THIS row, not to the block.** The
  invalid-CAS-document row prints whole `tdd-phase-scv1_<64 hex>.json` filenames, and
  deliberately: a reader told to inspect a broken document needs its name. The foreign-chain
  row truncates to 13 characters and is pinned that way; do not restate the requirement as a
  tree-wide invariant.
- **The `scv1_` shape is an untracked hand-copy family and this change added two members.**
  `SESSION_KEY_RE` exists in `session-control-core-v1.js` and is not exported, so the JS copy in
  the renderer and the bash-native one in the wrapper join a family that already spans several
  files. **A prose census goes stale the next time a site is added, so this is a GREP and not a
  list: before changing this shape, run `grep -rn 'scv1_' hooks/` and change every site.** An
  earlier revision of this bullet DID enumerate them and undercounted — the renderer already
  held four copies before this change added a fifth. Two facts a grep cannot supply: the
  unexported owner is `SESSION_KEY_RE`, and `zensu-edit-landing.sh` spells the class `[0-9a-f]`
  rather than `[a-f0-9]`, so the family had already drifted. Exporting the owner's constant is
  the standing fix.
- **A foreign chain that is WEDGED or at a DEAD END never reaches the row.** Those branches
  return first, deliberately, so one truncated key is never named twice with contradictory
  instructions — but the rows that do name it say "from the session that owns each chain",
  which is unperformable in exactly the state this feature exists to diagnose. The entries
  say "from the session that owns each chain" and nothing more. A qualifier naming the
  ownership was drafted and is NOT implemented — an earlier revision of this bullet claimed
  it shipped, which was false; grep finds the phrase only on the foreign-open row and the
  inert disclosure. The FORK is not named for them either.
- **The Config block keeps the OLD root.** `configFiles()` still builds the project overlay
  from `CLAUDE_PROJECT_DIR`, and `ZDOC_TTL_HOURS` is resolved before the bind, so where the two
  roots differ the doctor judges a `.zensu/config.json` that `zensu-log.sh` never reads. The
  TTL half is consistent with the Stop enforcer, which does not re-export the root; the config
  half is not, and is left as-is rather than widened silently.
- **The `chain-closed` half of the inert set has no behavioural fixture.** Driving a chain to
  that shape needs a real reviewer spawn to consume the review ticket, which no structure suite
  can perform. The exclusion is exercised only through `no-session`; `P1ms` covers the rename risk
  instead, by asserting that `INERT_SHAPES` is exported, holds both shapes, and that every member
  is a shape `chainShape` actually RETURNS — driven by calling it, not by membership in the
  sibling `NEXT_COMMAND` table. That earlier spelling reproduced the exact blindness this export
  was created to remove: renaming only the returned literal left the table key in place and kept
  the check green while a genuinely closed foreign chain rendered as an open one. Measured, not
  argued — the classifier-driven form catches that rename and the table-driven form does not.
- **RESOLVED — see §"Implementing-Phase Turn Counter" below; the rest of this bullet is the
  original finding, in past tense.** An OWN chain parked at `implementing` USED TO render at
  `OK`, and that is the shape a session lands in when it DECLINES the review chain rather than
  fails it.
  `hooks/stop-chain-enforcer.sh`'s `SESSION_IMPL_COMPLETE` early return releases Stop
  unconditionally while that flag
  is not `true`, so a session that arms `--tdd-begin`, does the work and never runs
  `--tdd-complete` is never asked for a reviewer: no directive, no cap, and no bypass-ledger
  entry — the ledger records gate ESCAPES and no gate was ever reached. `chainShape` then
  answers `implementing`, which is in neither `RECOVERABLE_SHAPES` nor `DEAD_END_SHAPES`, and
  the foreign-open row excludes it by `entry.key === ownKey`. It therefore reaches ONLY the
  count row, whose severity is `unclassifiable ? WARN : OK` — so the shape IS printed and "all
  checks green" still holds beside it. Observed as a real session outcome, not constructed: a
  session whose harness prompt forbade the `Agent` tool declined the five-agent fan-out,
  withheld `--tdd-complete` for exactly that reason, and self-reviewed instead.
  **Warning on `implementing` alone is NOT the fix** — that is the shape of every chain that is
  legitimately mid-implementation, so such a row would fire throughout every normal run and be
  trained away within a day. **An AGE bound is not the fix either, and it was the first thing
  proposed here.** The foreign-open row already ages on `updated_at` against
  `zensu_pending_review_ttl_hours`, and reusing that for an OWN chain measures WALL TIME — which
  a powered-off machine, a paused session, an overnight break and a holiday all accumulate with
  nothing wrong. Such a row reports the user's calendar, not the model's behaviour, and the
  existing foreign-open row carries the same weakness rather than justifying a second copy of it.
  **COUNT TURNS, NOT TIME.** The distinguishing signal is how often this session ENDED A TURN
  while the chain was still `implementing` and the worktree still reported changed files — the
  shape of a model working alongside an undeclared gate rather than through it. A machine that
  is off counts zero, a paused session counts zero, a holiday counts zero, and only continued
  work past the open gate counts up. The mechanism already exists in this same file for the
  phase one step later: the `CAP` release in `hooks/stop-chain-enforcer.sh` counts Stop blocks
  against `autoFixMaxRounds + 3` rather than against a clock.
  **Anchor by SYMBOL here, never by line number.** Both references above once carried one
  (`:951` and `:954-956`) and both went stale in the same commit that inserted
  `zensu_impl_stop_nudge` above them — a line number in prose is a claim nothing recomputes,
  and no reader can tell a correct one from a drifted one without opening the file. C41 in
  `tests/structure/test-impl-stop-counter.sh` forbids the FORM rather than pinning today's
  numbers, which would only reset the clock on the same defect. What is missing is the equivalent counter
  for the implementing phase plus a workflow-state slot to hold it — which under §"Runtime
  Lineage" is a schema change and therefore a `minor`, so it should travel with a schema change
  that is landing anyway rather than buy a release of its own. The nudge must stay ADVISORY and
  never become a block: a long legitimate implementation genuinely does span many turns, so a
  false positive may cost a line of text and must never cost a wedged chain.
  **THIS IS NOW IMPLEMENTED**, and it lives in its own section — see
  §"Implementing-Phase Turn Counter" below. It is deliberately NOT written up here: the
  paragraphs that close this section (its operator accounts, its `patch` verdict) were written
  about the foreign-chain row and are still true of it, so a second feature documented inside
  this section's gap list puts two version verdicts under one heading and makes one of them
  read as false.

**Operator-facing accounts that must move with it:** `skills/doctor/SKILL.md` (the frontmatter
`session state` clause, the row bullet, and the Phase 3 cleanup, which must delete the path the
expired row PRINTED rather than re-derive one from `CLAUDE_PROJECT_DIR`) and the
immutable-parent-context bullet in `docs/session-control.md` §"Claude Code Workflows".

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field, no strict key set, no hook added/removed/renamed and no matcher
changed, no new config key (the row reuses `zensu_pending_review_ttl_hours`), no attestation
change. The renderer is advisory and cannot deny, and it requires `chain-recovery-v1.js` from its
own plugin root, so no cross-version module mixing arises. Recorded here because the section also
states that PRE-EXISTING rows changed where they read, which reads like a breaking change and is
not one.

**Port-relevant.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included in this
change; each carries its own doctor against a different harness, and the fork premise has to be
re-decided per host before any of the four halves is worth porting.

`tests/structure/test-doctor.sh` P1mg–P1mt1 pin the row, its severity, the summary
interaction, the withholding guard, the record anchor and its fallback, the TTL semantics in both directions and at `0`, the
read-only contract, the wrapper source shape, and the three-way wording drift.

**The `patch` verdict above is about the foreign-chain row ALONE.** The turn counter in the
next section is a separate feature with its own verdict; do not read that paragraph as
covering it.

## Implementing-Phase Turn Counter (`hooks/stop-chain-enforcer.sh` + `zensu-tdd-phase.sh`)

`zensu_impl_stop_nudge` counts a TURN whenever a Stop ends with the chain still at
`implementing` and the worktree reporting changed source, and at or past
`hooks.implStopNudgeAfter` (default 12) it writes ONE advisory line to stderr and still
releases. **The default is a JUDGEMENT, not a measurement, and it moved once already:** at 5
it fired during ordinary work — the implementing phase of this repository's own chains ends
more than five turns with a dirty tree routinely, including the chain that built this
feature — which is exactly the "trained away within a day" failure the rejections below
exist to prevent. 12 buys headroom over a long honest implementation while still being far
short of a parked chain. Re-derive it if anyone ever measures the real distribution.
`/zensu:doctor` renders the same finding as a `WARN` chain row for chains this
session owns. It exists because the release at the `SESSION_IMPL_COMPLETE != "true"` branch
is unconditional, so a chain that never runs `--tdd-complete` is asked for no reviewer at
all — no directive, no cap, and no bypass-ledger entry, because the ledger records gate
ESCAPES and no gate is ever reached.

**Three shapes were rejected, and each rejection is load-bearing.** Warning on the shape
alone is what every legitimately mid-implementation chain looks like, so the row would fire
throughout every normal run and be trained away within a day. An AGE bound reports the
user's calendar rather than the model's behaviour — a powered-off machine, a paused session,
an overnight break and a holiday all accumulate wall clock with nothing wrong, and they
accumulate zero here. And BLOCKING is out: a long legitimate implementation genuinely spans
many turns, so a false positive may cost a line of text and must never wedge a chain.

**In their ORDINARY branch both surfaces name ONE exit, with its preconditions, and never
the zero-change terminus.**
`--tdd-complete` refuses without an edit-landing receipt and without a usable
`## Requirements` table, and BOTH gates arm on the same dirty tree the notice requires — so
naming the verb bare would hand the reader a command that refuses in the same breath. From
shape `implementing` no review ticket has ever been consumed, so `--chain-done` is the
UNQUALIFIED no-ticket terminus and a mid-run commit drives its change-count guard to zero:
offering it would teach an exit that closes a chain nothing reviewed, defeating the
guarantee this feature exists to protect.

**Say "in their ordinary branch", never "both surfaces always", because TWO branches of
the notice deliberately name NO exit** — the counter-failure branches, which fire AHEAD of the
threshold comparison. **State where they point, because an earlier revision of this paragraph
got it backwards and three operator carriers copied the error:** they point at a rendered
`zensu-log.sh --chain-status`, which reports `implStopCount` whatever its value, and they say
explicitly that the `/zensu:doctor` chain row is THRESHOLD-GATED and shows no count until
that recorded value reaches the bound. Sending a reader with a stuck counter to that row is the
one thing those branches must not do; `C28b` asserts the `chain-status` and `threshold-gated`
needles and asserts the retired "keeps reporting the last value" claim ABSENT.

**The refused-spawn branch is NOT one of them, and the correction is worth stating because
this paragraph said the opposite for a release.** It named THREE branches and described the
refusal branch as WITHHOLDING `--tdd-complete`. The reasoning was sound as far as it went —
completing while the refusal stands moves the chain into a gate the host will not let it
pass — and it was still the wrong call, for a reason the paragraph never reached:
`reviewer_spawn_denied` carries no generation or recency bound, this path never blocks so the
cap never releases it, and withholding the verb kept the chain where no ticket could be issued
and therefore no spawn attempted. Nothing could ever clear the verdict. The branch now names
the exit AND states the refusal, its kind, the observed count and the `permissions.allow` rule
beside it, so stale evidence costs a sentence rather than the chain.

**The two surfaces no longer CONTRADICT each other, and the exact strength of that claim is
the thing to keep.** The branch mints the denial note, and while a live note for the same
session key stands the doctor row ADDS a caveat naming the refusal and telling the reader to
lift the permission before taking the exit. It does NOT withhold the command. Withholding was
tried first and was wrong twice: the note is an unauthenticated file in a session-writable
directory, so withholding let anything able to write there DELETE the row's only remedy while
asserting a host refusal that never happened; and the note is minted only by a Stop that gets
past the dirty-tree and threshold gates, while the row renders off the persisted counter alone
— so a single clean-tree turn (the mid-run-commit shape this same section already records)
cleared the note and silently restored the bare recommendation. Qualifying is stable under
both: a missing note costs the caveat, never the remedy, and a planted one can only add a
caveat.

**A THIRD consequence of the same asymmetry, and it is a CONFIGURATION one:** the mint sits
past the threshold comparison while the clear is unconditional, so `hooks.implStopNudgeAfter:
0` — and every turn below the threshold — deletes a refusal note without re-recording it. The
switched-off `✅` row says only that no chain was measured; it does not say the refusal
diagnostic stopped persisting. Recorded in the `implStopNudgeAfter` row rather than fixed,
because moving the mint above the comparison would persist a diagnostic for a check the
operator switched off.

**KNOWN GAP, the residual of exactly that asymmetry.** `reviewer_denial_note_clear` runs
unconditionally at the impl-not-complete exit while the mint sits behind the nudge's own gates,
so between a clean-tree Stop and the next dirty one the caveat is absent while the refusal still
stands. The row is then the ordinary remedy — correct in form, missing a warning. The direction
is under-warning, never a wrong command, which is why it ships; closing it means probing the
transcript on every implementing Stop, which is the cost that branch's own comment declines.
**A SECOND residual travels with the clear-then-mint order, and "over-reporting" UNDERSTATES
it — three reviewers said so and they are right.** The clear at the impl-not-complete exit
unlinks the note and the mint re-stamps `detectedAtMs` with the current instant, so for the
session's own note the `stale` verdict and the reaper's age arm cannot fire FOR AS LONG AS the
session keeps ending dirty turns past the bound. Scope it that way rather than calling it
unreachable outright: once the session stops producing such turns the note is no longer
re-stamped and both arms apply normally — which is precisely the case the reaper exists for.
The conclusion is unchanged, because the window that matters is the one where the branch is
firing: while it fires, there is no recency bound on this path. The TTL is the only recency
control this feature has — the probe
itself has none — so on this path there is no recency bound at all. **Name the route, because
two successive drafts of this sentence named the wrong one.**
Ordinary convergence does not reach it — `reviewer-spawn-denial-v1.js` derives its status from
the LAST reviewer result in the tail, so a spawn that succeeds after the refusal flips the
verdict to `clear`. But neither does the cap-release or self-review route, which the previous
draft named: the re-stamping mint lives in `zensu_impl_stop_nudge`, whose single call site is
the `SESSION_IMPL_COMPLETE != "true"` exit, and a capped or self-reviewing chain has
`implComplete === true` and never reaches it. What actually reaches it is what the probe's
selector admits: ANY refused `zensu:code-reviewer` spawn anywhere in the scanned tail while
`implComplete` is false — including one from a flow that never armed a chain at all, since
`/zensu:cover` orders that spawn and states it never runs `--tdd-begin`. The CHAIN never spawns
a reviewer at `implementing`, so the self-heal is not
GUARANTEED — but it is not impossible either, and the sentence before this one is why: a flow
like `/zensu:cover` can spawn one without arming a chain, and a successful spawn there does
flip the verdict to `clear`. Say "not guaranteed", never "cannot occur", and the note is re-stamped
every dirty turn end. That is WIDER than either earlier draft, not narrower. NOT fixed here,
and the cheap fix is on record rather than left to
be rediscovered: read the existing note's `detectedAtMs` before the clear and carry it forward on
a re-mint with an unchanged `kind`, so the TTL ages the REFUSAL rather than the turn.

**Sites that move together:** `zensu_run_bounded` in `hooks/lib/zensu-bounded-run.sh`, the ONE
watchdog ladder for the two Stop-path children that read outside the process — the `git status` this
counter runs and the refused-spawn transcript read. They carried hand-copied ladders and the
`gtimeout` arm reached only one of them; `C49` and `C56a` pin each call site by name, `C42`/`C42a`
pin the ladder's own arms and their order, `C56` forbids a `return` in the arm positions its
pattern can see and `C56d` requires an unwrapped `"$@"` to survive in the body — neither reads
ARM POSITION, so do not restate them as pinning "the last arm". It LIVES in `hooks/lib/` because a third consumer already exists —
`user-prompt-context-nudge.sh` reads a host-supplied transcript path with no watchdog at all —
and a helper defined in a leaf hook cannot serve it. Three review rounds asked for that move
before it was taken. **What is still owed at that third site is the WRAPPING**, one `source`
line plus one call, left to its own review because it alters a second hook's behaviour and
belongs to that hook's suite. Its exposure is also WIDER than the Stop hook's and the comment
there now says so: that reader opens with a plain `openSync` after a shell `[ -f ]` in another
process, where the Stop-path reader hardens the open, so a FIFO in the TOCTOU window blocks it.
Both the watchdog and the hardened open are owed there. Then `_zensu_config_bounded_int` in
`zensu-config.sh`, which is now
the sole body behind `zensu_impl_stop_nudge_after` AND behind `zensu_autofix_max_rounds` and
`zensu_pending_review_ttl_hours` — so a change to it reaches the auto-fix budget and the
pending-review TTL, two features documented in other sections entirely. The three getters are
one-line calls whose four operands must stay positional literals, because `impl_getter_operand`
in `tests/structure/test-impl-stop-counter.sh` reads the default and the max straight out of
the implementing-turns call for C29 and C31. The extraction is `getter_operand`, parameterized
on getter and key, and it reaches ALL THREE keys — say three, not two: the two CONSTANT-MIRROR
pins cover two of them (`implStopNudgeAfter` through C29/C31/C31a, and `pendingReviewTtlHours`
through **C57**, which pins `TTL_HOURS_FALLBACK` / `TTL_HOURS_MAX` in the doctor renderer
against the TTL getter's own operands — a pair that declared itself a mirror in prose and was
pinned nowhere until the collapse made one extractor able to hold it), and **C58** reads every
getter's operands through the same extraction to drive its bound matrix. So `autoFixMaxRounds`
has no renderer mirror, but its call line is bound by the positional-literal contract too: an
operand that stops being readable there fails C58. Then
`WORKFLOW_INTEGER_EXTENSIONS` in `session-control-core-v1.js`;
the THREE closed counter key sets in `zensu-tdd-phase.sh` (`tdd_get_counter`,
`tdd_increment_counter`, and the `names` map in `_tdd_increment_counter_critical`, transition
token `impl_guard`); **the EIGHT reset sites**, which `delete` the key rather than zeroing it,
matching how those callbacks treat the Autopilot link fields — a counter that survives a re-arm
makes chain 2 of a session render "parked" on its first turn, which is exactly the false
positive the rejections above exist to avoid. **State the criterion correctly, because a first
draft got it wrong and the wrong version is what mis-scoped the search:** the roster is
"every site that ARMS a generation **plus every full document reset, wherever it lives**", NOT
"every site that touches `stopBlockCount`" (the `codeReviewDone` and `reviewRound` resets are
review-budget resets and are correctly skipped). Only two of the eight arm — `tdd_set_flag` on
`active`→true and `_tdd_begin_session_critical`; the rest are teardowns, and reading the roster
as arm-only is what left the JS twins out at first. Six live in `zensu-tdd-phase.sh`; the other
TWO are in `session-control-core-v1.js` — `resetDeferredReviewState` and the
`deferred-review-transfer` draft. **They do NOT reset the same set, and an earlier revision of
this sentence claimed they did.** `resetDeferredReviewState` clears the peer
`WORKFLOW_INTEGER_EXTENSIONS` member `autopilotAttempt`; the transfer draft touches no Autopilot
field at all — it writes `active`, `implComplete`, `chainDone`, `codeReviewDone`,
`selfReviewFixed`, the ticket pair, `reviewRound`, `stopBlockCount`, `implStopCount` and
`deferredReviewClaim`, and nothing else. The `delete` there rests on its own ground rather than
on a symmetry that does not exist: an absent key reads as `0` in all three readers.
`deferredReviewStateIsIdle` in that
same file is deliberately NOT extended: it tests `stopBlockCount === 0`, and an absent key is
not `0`, so adding this one would make every reset chain read as non-idle.
Then `zensu_impl_stop_nudge_after` in `zensu-config.sh` against `IMPL_STOP_NUDGE_FALLBACK`
/ `IMPL_STOP_NUDGE_MAX` in `zensu-doctor-report.js`, which are a hand-copy of its default and
bounds; and the `ZDOC_IMPL_STOP_NUDGE_AFTER` export in `zensu-doctor.sh` against
`implStopThreshold` — that file sources `zensu-config.sh` ONCE for both getters, and the count
is pinned by `C33` because it shipped as two, one inside each resolve block, while a
requirements table recorded the single-source rule as met; and **the `implStopNudgeAfter` entry
in `config.example.json`**, which this roster omitted while both sibling flag sections name
their own — that file is advertised as carrying every flag, so a rename driven off this roster
would leave it advertising a dead key; and **`chain-recovery-v1.js`**, which owns both the remedy vocabulary
and the counter's projection — `normalizeChainState` / `classifyChain` carry
`implStopCount` beside `stopBlockCount`, the doctor row reads `report.implStopCount` and
`report.nextCommand` rather than the raw document, and `--chain-status` therefore reports the
count for free. **`hooks/lib/reviewer-spawn-denial-v1.js` is a DEPENDENCY of this feature too, not only of
§"Host-Refused Reviewer Spawn".** The notice's refused-spawn branch calls
`reviewer_spawn_denied` and renders `REVIEWER_DENIAL_KIND` and `REVIEWER_DENIALS` from the
same probe, so that module's verdict vocabulary, its `status=`/`kind=`/`denials=` output
contract and the probe wrapper's memoization all reach THIS surface. The coupling is
fail-open in the direction that matters and that is the part to keep in view: the probe
leaves the verdict `none` on every failure, so a missing, unreadable or predating module
silently returns this branch to the ordinary remedy — the WRONG remedy in precisely the
state the module exists to detect. An installation older than v0.18.2 therefore gets the
ordinary notice, exactly as that section records for its own surfaces, and nothing surfaces
the skew. The Stop hook is the ONE surface that still hand-authors the remedy, because the module is
not loaded there — so the bound `--tdd-complete` spelling exists in exactly TWO places,
`shapeCommand` and `complete_cmd`. `INNER_BOUND_ARGS` in the same hook carries the identical
flag TRIPLE but only ever onto `--chain-done`, so it shares the ARGUMENTS and not the verb;
do not read it as a third `--tdd-complete` renderer. Since the round that consolidated them
the two no longer share a spelling either — they share an IMPLEMENTATION,
`zensu_autopilot_link_args`, which is the single SHELL renderer of that triple and is pinned
at exactly one site by `C45`. **That pin is file-scoped and the contract is not:**
`hooks/post-review-tdd-delegate.sh` builds the same string from its own `AUTOPILOT_*`
globals, and `hooks/lib/chain-recovery-v1.js`'s `shapeCommand` builds it in JS, where a
shell function is structurally unreachable. Two residual copies, named here rather than
implied by a claim of oneness. §"Requirements-Table Gate" keeps the
tree-wide roster of bound `--tdd-complete` spellings — consult that rather than a count here.
**A BLANK value falls back rather than disabling** — `Number('')` is `0`,
which passes the `>= 0` bound, so treating blank as absent is what keeps a wrapper fault from
silently deleting the row. **`0` emits an explicit switched-off `OK` row**, the same rule
`hooks.reviewerSpawnPermissionCheck` follows: a disabled check must never be
indistinguishable from a clean one.

**The refused-spawn branch NAMES the exit and states the refusal beside it — it does NOT
withhold the verb, and the reversal is recorded because the withholding version shipped and
looked right.** Completing while the refusal stands really does move the chain into a gate the
host will not let it pass, and every later Stop then blocks until the cap releases; that is why
withholding was chosen. What it missed is that `reviewer_spawn_denied` carries NO generation or
recency bound — it answers `blocked` for the last reviewer result anywhere in the module's
bounded transcript tail — and that on THIS surface the self-correction §"Host-Refused Reviewer
Spawn" relies on ("as soon as one spawn is attempted") cannot occur: this path never blocks, so
the cap never releases it, and withholding the verb keeps the chain where no ticket can be
issued and therefore no spawn attempted. One stale refusal pinned every later turn into the
withhold arm for the rest of the session — a state with no exit, adopted to avoid one that at
least ends at the cap. A real bound needs an arming instant to compare a transcript timestamp
against, and the workflow document carries none (`history[].ts` is optional and empty in
vanilla), so it is a schema field and a MINOR release; it is deliberately NOT paid for here.
`C27` pins the current contract and its comment records the reversal, so a later reader does not
restore the withholding from this paragraph's first sentence.

**The branch MINTS a denial note, and that is what makes the two surfaces agree.**
`reviewer_denial_note_clear` runs in the SAME `if` statement as `zensu_impl_stop_nudge`, with
`outer_finish` between them — and naming that middle call matters, because it is the one that
can set `DECISION_EMITTED` and make the nudge return before it can re-mint, so a durable
Autopilot block landing there leaves the note cleared and unminted. Without a mint here the
diagnosis died with the Stop: `reviewerDenialRows` returns early on an empty note
set and `/zensu:doctor` said nothing about the refusal, while its own implementing-turns row went
on printing `--tdd-complete`. The row now QUALIFIES `report.nextCommand` with a caveat while a live
note for its own session key exists, and NEVER withholds it — which is why `chainRows` takes the
`.zensu/state` listing and its directory as two optional trailing arguments. Withholding is what
this paragraph described for one committed revision, and restoring it from an older reading would
reinstate both defects the reversal removed: an unauthenticated note in a session-writable
directory able to delete the row's only remedy, and a single clean-tree Stop clearing the note
while the row still renders off the persisted counter. The liveness rule is shared, not copied:
`classifyDenialNote` returns `live|stale|rejected|missing` so `reviewerDenialRows` keeps its
three buckets while `ownRefusalNoteLive` tests for one, and `denialKindsAllowed` is the single
module load. `C27n` pins the mint; `C35pre`/`C35`/`C35s`/`C35r` pin the un-noted, live-note,
stale-note and shape-rejected arms, ALL FOUR of which require the command to be present.

**`REVIEWER_SPAWN_ALLOW_RULE` is module-scope for an ORDERING reason, not a style one.** Its two
consumers sit on opposite sides of the file: `DENIAL_RULE` in the blocked-Stop branch, and the
nudge, which runs from an early exit ABOVE that branch and therefore cannot see an assignment
made there — the same constraint the `complete_cmd` renderer states about `LOG_COMMAND`. The
nudge shipped one round naming no rule and no file at all. It names ONLY the user-scoped
settings path, for the reason §"Host-Refused Reviewer Spawn" gives.

**The probe excludes the plugin's own `.zensu` tree**, and that is not cosmetic: Phase 2
writes a plan and a log there unconditionally, so in any repository that tracks those
artifacts — which this repo's own artifact policy encourages — every chain would read as
dirty from its second turn and the predicate would stop discriminating. The probe is
watchdog-bounded WHEN a watchdog EXISTS — the unqualified form stood here eighty lines above
its own correction in the gap list. The ladder is `timeout`, then `gtimeout` (the spelling a
Homebrew coreutils install puts on PATH), then unbounded; on base macOS NEITHER exists, so
there the last arm is what runs. The SAME conditional applies to a second
child: the refused-spawn branch puts the transcript probe on this path too, and that read has
no deadline on the same hosts. It is the same conditional LITERALLY now — both children call
`zensu_run_bounded`, which exists because the arm added to one of two hand-copied ladders
was missing from the other, and the one left behind was the child whose own comment records
the LARGER exposure (a host-supplied transcript path that may sit on network-backed storage).
**State the CRITERION, not an ordinal — an enumeration here was written as
"a THIRD child" and was already short by one on the day it landed.** EVERY `node` child this
path spawns is unbounded on hosts without `timeout`, and the TWO the lease adds carry no
`timeout` guard on ANY host: the denial-note writer and the reaper's own scan. The counter is
what put both on this path, where they now run on every dirty turn end past the threshold — the
reaper's pre-check used to return before spawning anything, and the mint is what makes it pass
every time. It is guarded by `command -v git`, carries `--no-optional-locks` so a diagnostic
never rewrites the user's index, and takes NO pipeline, because a `| head` would replace
git's exit status with `head`'s and turn a missing repository into a clean tree. It keeps the
THREE-variable `GIT_*` scrub rather than `_tc_git`'s thirteen, deliberately: this probe gates
an advisory, not a refusal, and the finding proposing the wider list was judged a false
positive on that ground.

**SEVEN checks in `tests/structure/test-impl-stop-counter.sh` grade THIS FILE, and the
coupling fires in the UNOBVIOUS direction** — the shape §"Gate-Disable Prefixes" records
for G12 and §"Session Lineage Ledger" for its own two. An ordinary CLAUDE.md prose edit
reddens a suite named for the implementing-turns counter, and nothing points at the remedy
from the side that changes. They are: `C41`, which forbids a `<file>:<line>` source anchor
ANYWHERE in this file and is filename-independent, so a source filename followed by a colon
and a line number trips it in any section — including in a sentence explaining the rule, which
is how this paragraph first turned it red; `C42b`, which requires the word `gtimeout`
somewhere in the file; `C51`, `C52` and `C59`, which require the literals `zensu_autopilot_link_args`,
`_zensu_config_bounded_int` and `zensu_run_bounded`, so renaming any of the three shared owners
without amending this section turns them red; `C53`, which
extracts the PARAGRAPH containing `The SAME conditional applies to a second` and requires
`gtimeout` inside it — the slice itself spans lines, so rewrapping the paragraph is safe, but
that ANCHOR SENTENCE must stay unbroken on one line or the slice comes back empty, and moving
it to another paragraph is not safe either; and `C39`, which is the one that grades PROSE
rather than a symbol — it requires this file to carry the emitted `threshold-gated` clause as
many times as it carries that clause's lead-in, so rewording or dropping that sentence here
reddens it, with the least self-explanatory failure text of the seven.

**Operator-facing accounts that must move with it:** the `implStopNudgeAfter` row AND the
`stop-chain-enforcer.sh` row in `docs/configuration.md`, discipline patch 13 in
`docs/tdd-manager-workflow.md` (plus the patch RANGE in `docs/gates.md`, which is a separate
file and drifts silently — but NOT that file's "bounded-counter enumeration and Mermaid node
label", which this roster named and which do not exist there: a grep for `implStopCount`,
`implStopNudgeAfter` or any counter enumeration in `docs/gates.md` returns nothing, so the
obligation pointed at content that was never in that file), and the implementing-turns bullets
plus the frontmatter `session state` clause in `skills/doctor/SKILL.md` — "the parked-chain
bullet" is what this roster said, and that name was retired on every emitted surface a round
earlier, so a maintainer navigating by it found nothing.
`tests/structure/test-impl-stop-counter.sh` pins the counter, both surfaces, the reset on
re-arm, the `.zensu` pathspec exclusion and its positive control, the non-git inertness and the
schema-membership bite; `tests/structure/test-doctor.sh` `P1mt2`/`P1mt3` pin the row's
three-way wording and its NEGATIVE terminus claim.

**Version: `minor` by policy, and the measurement is recorded beside it rather than used to
argue it away.** §"Runtime Lineage" lists "any field added" to the workflow-state schema as
breaking. Measured: `validateWorkflowExtensions` type-checks only the fields it LISTS and only
when present, so it never rejects an unknown key; `validateWorkflowToken` accepts any
`^[a-z][a-z0-9_-]{0,63}$`, so `impl_guard` passes; and `normalizeChainState` spreads unknown
keys through — an older runtime really does read a document carrying `implStopCount`. The
recommendation stays `minor` anyway: the author of a change is the wrong party to grant it its
own carve-out, and this file records that both existing carve-outs survived on argument rather
than on their author's say-so.

**The verdict is about the RELEASE, not about any single review round, and saying so matters
because a reviewer walked a later round's file list against §"Runtime Lineage" and correctly
derived `patch` from it.** The field lands in `WORKFLOW_INTEGER_EXTENSIONS`
(`session-control-core-v1.js`) and the three counter key sets (`zensu-tdd-phase.sh`); a fix
round that touches neither of those files changes no persisted shape and would score `patch`
on its own. Score the verdict against the whole diff the release ships — here, everything
since the branch point — never against the working-tree diff of the round in front of you.

**Known gaps, accepted and named:**

- **The doctor row's remedy is not RUNNABLE, while the Stop surface's is.** The row
  interpolates `report.nextCommand`, which the owning module renders as a bare
  `zensu-log.sh --tdd-complete …` — no interpreter, no path, no `CLAUDE_PLUGIN_DATA`. The
  Stop hook renders the same verb in full, for the reason its own comment gives: a flag with
  no program is not a command the reader can run. Taking the command from the owning module
  was the right dependency direction and the runnability gap travelled with it. The fix is to
  prefix module-supplied `zensu-log.sh` spellings in the RENDERER — leaving `NEXT_COMMAND`
  alone, since the module cannot know the plugin root — and it belongs to all four chain rows
  rather than this one, which is why it is not taken inside a change set already five review
  rounds deep.
- **The increment joined the WEAKER lock domain, deliberately.** `tdd_increment_counter`
  reaches `_tdd_increment_counter_critical` directly, so this write holds only the CAS lock,
  while the sibling counter on the same hook, `tdd_increment_stop_budget`, takes the EXTERNAL
  lease. The document therefore has two writer classes that do not serialise against each
  other. Taking the lease here was weighed and REJECTED: it is contended precisely on a path
  whose contract is to release immediately, so buying atomicity against a writer class nobody
  has demonstrated running concurrently with this Stop would trade a real every-turn latency
  regression for a hypothetical lost advisory count. The residual is that a lease-only writer
  restoring its own snapshot could revert this count and move `revision`, the CAS token,
  backwards. The split PREDATES this counter; what is new is that a second writer joined the
  weaker side of it. The sibling can afford the lease because its own path BLOCKS, and this
  one cannot for the same reason. `C44` pins that the decision stays recorded at the call site
  and `C46` that the `docs/configuration.md` row does not lend it `stopBlockCount`'s
  atomicity qualifier.

- **The stated packaging condition was NOT met.** The design note asks that the schema change
  travel with another one that is landing anyway; none is. It buys a `minor` of its own.
- **The Windows wall clock is UNMEASURED.** The suite is deliberately absent from
  `tests/profiles/windows-ci.v1.json`, whose shards are already close to their
  `profileTimeoutMs`, so it never runs on the blocking Windows PR shard. It IS in
  `ciStructureTests`, which `run-windows-safety-shard.js` builds the weekly Windows Safety
  structure inventory from, so it DOES run there, with no measurement yet. Say "unmeasured",
  never "POSIX only".
- **No `tests/profiles/ci-shard-weights.v1.json` entry**, so the suite is costed at
  `defaultSeconds`. That file requires a real CI figure and its own note sanctions the
  omission; add it from the first green ubuntu-latest `--ci` run rather than estimating.
- **The threshold is resolved BEFORE the session bind** and, unlike the TTL, is never
  re-resolved against the record root, so it inherits the Config-block root gap the previous
  section names. **The asymmetry is real and was briefly written out of this file in error, so
  it is worth stating with its evidence:** `zensu-doctor.sh` remembers `ZDOC_TTL_PINNED` before
  the bind and, when the record root and `CLAUDE_PROJECT_DIR` differ, re-resolves the TTL from
  the record root into `ZDOC_TTL_REBOUND` unless the caller pinned it. The threshold block does
  no such thing, and says so: "Deliberately NOT re-resolved after the bind." The neighbouring
  sentence in that same comment — "Same canonical-getter rule as the TTL above, and the same
  known bound" — is about the GETTER and the pre-bind read, not about re-resolution, and reading
  it as the latter is what produced the wrong correction.
- **A blocked Stop is not a turn, and that makes the whole check INERT for a healthy durable
  Autopilot run.** `emit_block` sets `DECISION_EMITTED` and the nudge returns on it, so a Stop
  the enforcer itself refuses is neither counted nor commented on — correct semantics, and the
  reason the bound `--autopilot-run …` spelling the notice can build is reachable only for a
  chain whose outer run is already DONE, BLOCKED or CANCELLED: `outer_finish` blocks on this
  very branch for every owned non-terminal run under budget. The standalone path, which is the
  case this feature was built for, is unaffected. The guard has no behavioural coverage: the
  suite builds no durable-run fixture.
- **The own-chain row withholds the green summary for the whole time a legitimate
  implementation runs past the bound**, exactly as §"Foreign-Chain Row" records for a
  same-project sibling. The stderr notice also repeats on EVERY Stop past the bound — nothing
  latches it. Raising the default from 5 to 12 deferred that cost; it did not remove it, and
  saying otherwise would be the "trained away within a day" dynamic the rejections above name.
  **The durable fix is a discriminator, not another number**, and it is NOT implemented: demote
  the row to `OK` when the counter ADVANCED since the previous report — evidence of ongoing work
  — and keep `WARN` only when it did not, which is the parked-versus-busy distinction the row's
  own text claims to make and a turn count alone cannot. It needs somewhere to remember the
  previous reading, and the doctor is read-only by contract, so it is a design change rather
  than a tweak.
- **Counting a turn is now a freshness heartbeat for a NEIGHBOURING row.** The increment goes
  through `mutateWorkflowState`, which stamps `updated_at`, and that field is what
  `documentAgeMs` ages the foreign-open row on. So a chain being counted can no longer age out
  of another same-project session's foreign-open WARN row. The direction is defensible — an
  actively counted chain is not abandoned — but it deepens the "same-project-root sibling
  permanently withholds the green summary" gap the previous section records.
- **PARTLY CLOSED, and the remaining half is what a reader must not mistake for the whole.**
  The gap was that only the literal `0` disclosed, so a large in-range threshold suppressed the
  row silently on both surfaces — and the config carrier is writable from inside a session, so
  that was a silent off-switch for a review-integrity diagnostic with no gate escaped and
  therefore no bypass-ledger entry. `/zensu:doctor` now ALSO discloses at the getter's own
  maximum (999999), in its own row. What is NOT closed: the Stop surface has no such
  disclosure at all — it tests only `> 0` — and the doctor's arm fires at exactly 999999, so
  any value the counter will not reach in a real session still suppresses the row silently
  on both surfaces without saying so — a threshold of 5000 is as effective an off-switch as
  999999 and discloses nothing. Say it that way, never as a numeric RANGE: the default is 12
  and the row renders there, so "every value from 1 to 999998" was false. Keying BOTH surfaces
  on reachability rather than on two literals is the remaining
  fix. **Do not read the new row as closing this bullet.**
- **The watchdog fallback is unbounded, and on base macOS the fallback is the DEFAULT.** The
  ladder probes `timeout`, then `gtimeout` (the Homebrew coreutils spelling), then runs
  `git status` with no deadline at all. MEASURED on the maintainer's own host: neither binary
  exists on base macOS, so the unbounded arm is not an edge case there — it is what runs.
  **Do not describe `|| return 0` as the mitigation.** It tests an EXIT STATUS, so it degrades
  a git that returns and can do nothing about one that hangs, which is the only failure a
  watchdog exists for; an earlier wording here named it as though it covered the hang. Two
  fixes were weighed and both rejected, so this stays a stated bound rather than a TODO:
  making the probe inert without a watchdog would switch the whole diagnostic off on exactly
  the platform it was built for, and a hand-rolled background-plus-poll watchdog adds latency
  to every counted Stop plus a temp file and a killed child on a path whose contract is to
  release immediately. `C42`/`C42a`/`C42b` in `tests/structure/test-impl-stop-counter.sh` pin
  the ladder and hold this bullet against it.
- **The probe is defeated by a mid-run commit and is scoped to the project subtree.** A chain
  that commits each turn measures a clean tree and is never counted — the same accepted hole
  §"Requirements-Table Gate" records for `--tdd-complete`. And `-- .` under `-C "$PROJECT_ROOT"`
  bounds the probe to the project, while the edit-landing audit it points at is repo-root
  anchored, so a project root nested in a larger repository can carry landed edits the audit
  sees and this probe does not.

## Relaxable Bind Failures (`hooks/lib/claude-hook-session-v1.js`)

A failed bind to the immutable Session Control record denies, with exactly **two**
documented exceptions. Both mean no workflow document is reachable, so relaxing waives
nothing — and they are deliberately **two predicates, never one widened check**, because
they are different diagnoses with different remedies:

- `unregisteredSession` — no record at all (the 0.17.0 upgrade state). True only on a
  clean `ENOENT` of the records directory or the record file.
- `orphanedProjectRootSession` / `resolveOrphanedProjectRoot` — a record valid in every
  other respect whose recorded `project_root` is gone (a deleted or recycled worktree).
  It waives ONE check via `readOrphanedProjectRootContext`
  (`hooks/lib/session-control-core-v1.js`, an internal `allowMissingProjectRoot` option
  on `validateContext`) and additionally requires that path to be **absent** — `lstat`,
  never `realpath`, so a dangling symlink stays a present-but-wrong root. It then
  re-applies the plugin-root and plugin-data identity checks `resolveHookSession`
  applies, so a second disagreement is never relaxed alongside the first.
  **Amended by semver-compatible binding:** the plugin-root check there is now the
  lineage-relaxed `servesRecordedRuntime`, so a vanished project root IS relaxed
  alongside an executing root that is a declared-compatible upgrade — deliberate,
  since neither disagreement can anchor a workflow document. An INCOMPATIBLE root,
  a differing `plugin_data`, and every other disagreement stay unrelaxed. See
  "Runtime Lineage (`version_type` is load-bearing)" above.

**Every gate that relaxes one must consider the other**, and they do NOT all agree by
design — the split is the contract, so changing a predicate means re-deciding each site.
The authoritative per-gate roster is the "Unbindable sessions" table in
`docs/session-control.md`, which
carries one column per state; keep exactly one roster and do not duplicate it here. Two
properties are easy to get wrong and cost the whole feature:

- **A deny from ANY hook on a matcher wins.** `hooks.json` registers four PreToolUse
  hooks on the `Bash` matcher (`pre-bash-witness.sh`, `pre-bash-zensu-gate.sh`,
  `pre-bash-source-write-gate.sh`, `pre-write-secret-scan.sh`) and one on `.*`
  (`pre-reviewer-capability-gate.sh` via `reviewer-capability-v1.js`). Only four of the
  five can deny: `pre-bash-witness.sh` is advisory by construction and always exits 0
  (§"Witness Attempt Half"), which is exactly why it may sit on this matcher at all — but
  it is counted here rather than left out, because O21a enumerates the matcher and would
  have to be re-derived by anyone who trusted a roster that omitted it. `/zensu:doctor` runs through Bash, so it is reachable only
  if EVERY one of them allows. Both the `.*` gate and the secret-scan gate were missed in
  turn while the single-gate test stayed green and the feature silently did not work.
  `tests/structure/test-orphaned-project-root.sh` O21a therefore enumerates the Bash
  matcher from `hooks.json` and asserts every hook on it allows, so a hook added later is
  covered without editing the test.
- **Mutating tools stay denied on purpose.** `pre-edit-tdd-reminder.sh` relaxes neither
  state: nothing in either can anchor a write to a project. Its matcher is
  `Edit|Write|MultiEdit`, so `NotebookEdit` is NOT phase-gated — in a healthy session
  either, which is why the relaxation restores the pre-Session-Control capability set
  rather than widening it. Say "Edit/Write/MultiEdit", never "all mutating tools".
- **A Bash write without a project anchor denies; a read does not.** In both relaxed
  states `CLAUDE_PROJECT_DIR` is typically gone or unset — in the orphaned state it is by
  construction the deleted directory, since the record's `project_root` was minted from
  the SessionStart cwd. `pre-bash-source-write-gate.sh` therefore runs the parser's
  `BSWG_MODE=detect` channel check, which needs no anchor, and denies only commands that
  actually write. Denying unconditionally there once put the diagnostic back behind the
  defect it reports, and the healthy-anchor test fixtures hid it; `O29`/`O29a` pin both
  the deleted-root and unset-anchor shapes.

Shell wrappers live in `hooks/lib/zensu-session.sh` (`zensu_session_unregistered`,
`zensu_session_orphaned_project_root`, `..._model`, plus
`zensu_session_incompatible_runtime` / `..._model` and
`zensu_session_pruned_plugin_root` / `..._model`). The orphaned wrapper **prints the
dead path on stdout** and BOTH version-pair predicates print `recorded<TAB>executing`;
inside a PreToolUse gate stdout is the JSON decision channel, so a caller wanting the
predicate alone must discard it explicitly, and a caller wanting the value must capture
it into a variable before emitting anything.

**The third and fourth predicates are DIAGNOSES, never further relaxations.**
`zensu_session_incompatible_runtime` and `zensu_session_pruned_plugin_root`
belong to this roster only because every gate that consults the two above must decide what
to do about them too — and the answer is the same everywhere: keep denying. A workflow document
is still reachable in either state, so relaxing would waive a live guarantee rather than a dead
one. What they change is the MESSAGE: `zensu_emit_hook_session_deny` now spells FIVE scopes,
two of which — `incompatible-runtime` and `pruned-plugin-root` — take the two versions as
positional arguments. FIVE gates can deny
in either state: the four shell gates emit the matching scope, and `pre-reviewer-capability-gate.sh` —
the `.*` matcher, where `isRecognizedInvocation` is false for every non-Bash tool — spells the
same cause and remedy itself in JS, because the shell emitter is not reachable from it. A gate
left on the generic text tells the user to start a fresh session while its sibling says the session can
be repaired in place — two denies contradicting each other about the two bind failures that
have an in-place remedy. The Stop hook is the single exception and RELEASES for both, because
it cannot read the chain from an unbound session at all.

`zensu_emit_hook_session_deny` must never assert "no record" as the cause: naming the
wrong relaxable state sends a user whose worktree was deleted hunting for a record that is
sitting intact in plugin data. Same rule for the `/zensu:doctor` binding rows.

**The release claims only what an ENOENT proves.** A moved or renamed root, and an
unmounted volume, produce the same ENOENT while the workflow state survives intact
elsewhere — so the Stop release says no completion was proven, never that nothing existed
to prove. It also means the release can be induced by renaming the project root, and that
IS reachable from inside a session: `mv` carries no write channel, while `ZENSU_CHAIN` is
read from the hook's inherited environment and a per-command prefix cannot reach it — the
two are not equivalent capabilities. Accepted anyway, because the alternative wedges every
legitimately deleted worktree forever with no in-session escape. **Known open improvement:**
an induced release is currently silent — it cannot be ledgered, because the document a
bypass entry would live in is the one that became unreachable — so a detection surface (a
sidecar beside the immutable record, surfaced by `/zensu:doctor`) is still missing.

**Port-relevant.** The core half (`validateContext`'s `allowMissingProjectRoot`,
`readContextInternal`/`readOrphanedProjectRootContext`) lives in the cross-host
`session-control-core-v1.js`; the host half (binder mode, shell predicate, gate
re-decisions, doctor row) is per host. A port that takes only the core delta keeps the
worktree-deletion wedge; a port that takes neither drifts from this core.

Operator-facing accounts that must move with the predicates: the "Unbindable sessions"
table in `docs/session-control.md`, the Stop-binding section of
`docs/tdd-manager-workflow.md`, and the
binding rows in `skills/doctor/SKILL.md`.
`tests/structure/test-orphaned-project-root.sh` pins the predicate truth table, the
capability gate, every Bash-matcher hook, the Edit gate and the doctor rows;
`tests/structure/test-stop-session-binding-recovery.sh` pins the Stop halves, where B4 is
the discrimination test that a root which still EXISTS but no longer matches keeps
blocking, and B1d that a second disagreement is never relaxed alongside the first.

## Git Mutation Tables (`hooks/lib/bash-source-write-parse.js`)

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
then points at flow 3 for the routing rule. Do not describe it as an index entry —
an earlier wording here did, and `T30` in `test-session-trail-skill.sh` now fails on
that claim for as long as the bullet really carries the hook roster. A change to
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

**Three cross-file couplings.** (The MSYS drive rule is deliberately NOT among them: it is
shared through `claude-path-v1.js`'s `msysDrivePrefix` rather than hand-copied — see the
paragraph above.) `WRAP` — the transparent-wrapper set rule (C)'s
`cmd0` anchoring depends on — is hand-duplicated as a JS literal in
`hooks/pre-bash-zensu-gate.sh`; a wrapper added to one and not the other means the
same wrapped invocation is gated by one Bash gate and not its sibling.
`within()` is a hand-copy of `isInside` in
`hooks/lib/reviewer-capability-v1.js`, held in lockstep only by W3b — and the same
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
against its `pre-bash-zensu-gate.sh` copy — check that one by hand. And
`skills/pr-team-review` Phase E depends on `worktree remove` being judged on the tree
it destroys rather than on the addressed repository — narrow that carve-out and the
skill's documented cleanup starts denying, which is what W181/W185-W187 exist to
catch. That flow also depends on rule (B)'s temp carve-out, so `ZENSU_BSWGATE_TEMP_DIRS`
silently governs whether the shipped cleanup passes. Do not "fix" a deny there by
writing `ZENSU_BASH_WRITE_GATE=off` into a skill: a
shipped escape prefix teaches the hatch and lands a self-inflicted bypass-ledger entry.

## Plugin-Data Guard (`hooks/pre-write-plugin-data-guard.sh` + `plugin-data-guard-v1.js`)

A PreToolUse gate on `Edit|Write|MultiEdit` AND `NotebookEdit` that denies a file-mutating
call whose resolved target lies inside `CLAUDE_PLUGIN_DATA` — the store holding the immutable
Session Control records and the review-evidence leases.

**It closes a MEASURED hole.** Measured 2026-08-28, recorded in
`docs/multi-repo-chains-spec.md` §6.1.2: all three PreToolUse hooks matching a `Write`
answered `allow` for a target inside the store in every chain state — no chain armed, a
vanilla chain, and a strict chain at `RED_WRITE`. Enumerate that matcher from `hooks.json`
before claiming a count: the `.*` capability gate matches `Write` too, and missing it is the
exact mistake §"Relaxable Bind Failures" already records twice.

**A hook of its own, not a branch in `pre-edit-tdd-reminder.sh`.** That hook returns early
while no chain is armed, which is precisely the state in which the store is read.

**ELEVEN RESIDUALS, and the guarantee is false without them.** (1) The **Bash channel is not
covered at all**: `bash-source-write-parse.js` filters targets through `SRC`, which carries no
`json`, and `mv`/`cp` are out of scope, so a redirect, copy, move or link into the store passes
every Bash gate. (2) `<project>/.zensu/state/` is NOT in the store and is NOT covered — never
describe this gate as protecting "the anchors every gate binds to". (3) A **hard link** outside
the store to a file inside it is judged by its own path and allowed; it needs `ln`, so it sits
behind residual 1. (4) Only the four tool names in `WRITE_TOOLS` are judged — `apply_patch` is in
`reviewer-capability-v1.js`'s `MUTATING_FILE_TOOLS` and is NOT here, and no MCP write tool is
matched. (5) The store's LOCATION is the ambient `CLAUDE_PLUGIN_DATA`, not the bound record's
authoritative `plugin_data`; a wrong value disarms the gate, disclosed on stderr. Residuals 2
and 3 are MAIN-THREAD ONLY — `reviewer-capability-v1.js` covers both for a non-main principal.
(6) The plugin ROOT is not covered — only the data store; `reviewer-capability-v1.js` protects
BOTH trees for a non-main principal, so its protected ROOT SET is a superset of this one — but it
resolves with a WEAKER walk, so "superset" describes the roots and never the enforced boundary. (7) The decision is taken at PreToolUse and the tool opens afterwards, so a component
swapped in between is followed — a property of the hook shape that no PreToolUse gate can remove,
and the reason this is a control rather than a guarantee. (8) COMPOSING 1 AND 6: this gate's own
decision module sits inside that unprotected plugin root, so one ungated main-thread `Edit` — or
anything holding `Bash`, by residual 1 — removes or replaces it and the wrapper then declines.
Neither parent residual states it on its own, which is why it is listed rather than left to be
composed by the reader. It is DISCLOSED, not silent: the wrapper's stderr note is what separates
"the gate did not run" from a clean allow. (9) THE MIRROR OF 3: a symlink INSIDE the
store whose target is outside is judged by its resolved location and ALLOWED — both
resolution paths agree on it — so one `ln -s` planted through residual 1's channel
becomes ongoing Edit-channel control over what a reader gets back from that record
path. The store's own bytes stay untouched, which is why it is a residual rather
than a defect in the walk. (10) NOTHING BOUNDS THE PROJECT ROOT: the over-arm valve
fires whenever the store contains or equals it, so a project root naming a directory
INSIDE the store carves that subtree out. A residual of the valve, NOT a regression —
the total disarm it replaced allowed the whole store in the same configuration — and
bounding it would teach this module the store's own layout, which is a shape it does
not own. AND THE EQUALITY CASE IS THE MAXIMUM: at `store === projectRoot` the carve-out
is the whole store and the gate denies nothing — say "never more permissive than the
total disarm it replaced", never "strictly stricter", because at equality the two are
identical. (11) THE VALVE'S PROJECT ROOT IS THE AMBIENT `CLAUDE_PROJECT_DIR`, which
§"Foreign-Chain Row" in this same file records as NOT the authoritative anchor — every
writer resolves the bound record's `project_root`. Where the two diverge, the ordinary
case for a session whose cwd is a worktree, the valve carves out the harness root while
the session writes elsewhere, and `overArmUnchecked` stays false because the root DID
resolve. Binding the record here would put a session lookup on every `Edit`. State the carriers precisely rather
than as a uniform count: all eleven sit in the module header, `docs/gates.md` and the
`docs/configuration.md` row; the hook header carries residuals 1 and 2 and delegates the rest to
the module header.

**THE NET DELTA IS THE MAIN THREAD ONLY, and the measurement sentence must say so.**
`hooks/lib/reviewer-capability-v1.js` already denies every NON-main principal a write into this
store (`protectedRoots`, `immutableRuntimeRoots`) and returns early for `main-v1`. So this gate
adds exactly main-thread `Edit`/`Write`/`MultiEdit`/`NotebookEdit` — which is the channel §6.1.2
measured open, and is the justification. Never justify it with "every principal": true of the
hook's behaviour, false as a description of what it adds. That module therefore belongs on the
coupled-site roster below, with the principal split spelled out.

**RESOLUTION IMITATES THE KERNEL, and TWO bypasses of one class were measured before it did.**
Both came from resolving the spelling before resolving the links. First, a DANGLING leaf symlink
into the store: `realpath` cannot resolve a destination that does not exist yet, so the canonical
spelling stayed outside while the tool's own `open(O_CREAT)` followed the link in. Second,
`<symlink-into-store>/../x`: `path.resolve` collapses `..` LEXICALLY, so the link was never read.
A THIRD was measured one round later — a case-variant spelling of the store prefix, which on a
case-insensitive volume `lstat`s fine while `within`'s pure string compare reports it outside —
and a FOURTH, a link whose own target traverses another link into the store. Four bypasses of one
class in four rounds is the argument for the structural form: `resolveTargetPath` walks components left to right, follows a
symlink at each one, and applies `..` to the ALREADY RESOLVED prefix, bounded on both the
component count and the link hops. THREE properties carry it, and dropping any one reopens a
measured bypass: the raw spelling and its base travel SEPARATELY into the walk (a `path.resolve`
on the way in collapses `..` before a link can be read); every EXISTING ordinary component is
`realpath`ed, so both operands of `within` sit in one case namespace; and a link TARGET is
re-split into segments and prepended to the remaining walk rather than adopted wholesale.
`tests/structure/test-msys-special-plugin-module-boundaries.sh` also carries a probe for this
hook's module transport, beside the secret scanner's.

**Fault direction: every fault ALLOWS, with TWO exceptions.** The shared plugin-root identity guard which
refuses with exit 2 as in every sibling — on this matcher that refusal blocks the call, so the
claim must never be written unqualified — and `TRUNCATED` refuses when a resolution hits an
internal bound, because "outside" is a claim a walk that did not finish has not earned. That
second one is the ONE deny in this module that is not a proven containment; it is safe because no
legitimate input reaches a bound. FOUR faults carry a stderr note, and the labels matter:
the containment module failing to load, a payload the module cannot read (a PAYLOAD fault, not a
load fault), `NO_STORE`, the one that turns the control off completely, and `NO_TARGET`, a
payload with no path field — which is what a renamed or restructured host field looks like from
here. The set is `SILENT_FAULT_IS_A_LIE` and it has FOUR members; every carrier of this sentence
said three. A FIFTH note is not a fault: `overArmUnchecked` reports an armed decision taken
without a project root, so the over-arm valve could not be evaluated. THREE further faults are outside the
MODULE's reach, because the wrapper returns before `node` runs: a missing `node`, a `hooks/lib`
its `cd -P` cannot enter, and a `plugin-data-guard-v1.js` that is absent or symlinked. They are
NOT SILENT — the wrapper writes its own stderr note at each, and so does its exit-2 plugin-root
branches — self-resolution failure and inherited-root mismatch, two distinct messages, so name
them in the plural. Say "cannot carry the module's TYPED reason", never "cannot carry a note": the earlier
wording named a structural limit where there was a choice, and `cannot` is the word that stops the
next maintainer from fixing it. What is genuinely structural is only that the module never runs.

**No escape and no config flag**, deliberately — so `ESCAPE_STEMS` in
`tests/structure/test-gauntlet-loop-skill.sh` and `ZENSU_BYPASS_GATE_ALLOWLIST` stay untouched,
and nothing here lands a bypass-ledger entry: there is no gate escape to record.

**Coupled sites that move together:** `ZENSU_GUARD_CALLER_CWD`, exported by the wrapper before
its `cd -P` and read by the module's CLI entry point — named in three places — the wrapper, the module's CLI entry point and the
`pre-write-plugin-data-guard.sh` row in `docs/configuration.md` — and PINNED by `G44`, which
derives the name from the wrapper's own export and fails on a one-sided rename. Without that pin a
rename re-anchors every relative target in the plugin tree and fails only for relative spellings,
so the ordinary rows stay green; `hooks/lib/reviewer-capability-v1.js`, which owns a SUPERSET of this
boundary for every non-main principal through a DIFFERENT predicate (`isInside`, the hand-copy
pair `within` is held in lockstep with by W3b) AND a DIFFERENT RESOLVER
(`canonicalCandidate` ↔ `resolveTargetPath`), pinned since the round that added `G39` in
`tests/structure/test-plugin-data-guard.sh` — a SLICED source scan over the two resolver bodies
with a control on EACH side, which is weaker than one shared implementation and stronger than
nothing: it sees an element deleted from either resolver and nothing else — they diverge in TWO ways, and the second is what makes
the shared extraction non-mechanical: `canonicalCandidate` collapses `..` lexically before any
`lstat` — the second bypass measured here — while per-component canonicalization is SHARED; and
their FAULT CONTRACTS are opposite, the sibling throwing into a consumer that DENIES while this
walk swallows into one that ALLOWS. One shared resolver has to serve both directions. A
one shared module is the standing fix; the sliced lockstep pin is what exists today — a divergence between them is a principal-dependent
verdict on one boundary, not merely duplicated code; §"Git Mutation Tables"'s seam-consumer
paragraph, which names this module as the second consumer; both matcher groups in
`hooks/hooks.json` ↔ the module's
`WRITE_TOOLS` (pinned by G14/G14a, which compare the registered matchers' tool names against
the exported set — a matcher widened alone yields a hook that runs and allows with no signal);
the hook count in `docs/configuration.md` plus every `#hooks-N` anchor, INCLUDING the one in
`docs/architecture.md` — which H3 in `test-readme-hook-count-sync.sh` does cover, since it binds
that file alongside `docs/configuration.md` and `README.md`; an earlier wording here called it
unpinned and contradicted §"Reviewer-Spawn Grant" two sections up; the flagless-hook
roster in `docs/architecture.md`; the per-gate roster in `docs/session-control.md` (this gate
binds no session, so all three columns are identical); `docs/gates.md`'s gate COUNT in its own
intro, which no test checks; the README docs-index row; the suite manifest entry in
`tests/profiles/promptfoo-local-only.v1.json` together with the counts in
`tests/SUITE-OVERVIEW.md`; and the seam-consumer sentence in `bash-source-write-parse.js` —
this module is its SECOND consumer, so removing `within` or `msysToDrive` now degrades a DENY
gate to allow, not just a skill's rendering.

**Version: `minor`.** Walked against §"Runtime Lineage": adding a hook is a `patch` UNLESS it
can DENY, and this one does. The capability set of every session an older runtime still serves
changes, which is the disqualifier that bullet spells out.

**Known gaps, accepted and named:** the Windows half is UNVERIFIED — the suite is in
`ciStructureTests` and NOT in `windows-ci.v1.json`, so it never runs on the Windows PR shard — but
the weekly Windows Safety structure shard DOES run it, so the Windows half stays unverified only
until that run reports green. Never write "never runs on Windows". A `node --test` driver DOES exist since the round that added `tests/structure/plugin-data-guard-v1.test.js`, and it injects `decide()`'s
`isWindows` seam on every call and reaches the containment export-shape arm through a
copied module beside a stub sibling parser — but the platform-conditional separator class still means the branch
where a backslash IS a separator is exactly the one that unverified platform would exercise. Say
"unverified", never "covered". The resolver pair (`resolveTargetPath` ↔ `canonicalCandidate`) is pinned by the
sliced `G39` scan and its two controls, which catches a deleted element on either side but cannot
see a semantic divergence; one extracted resolver is the durable end state and is deliberately NOT this
change, because swapping the sibling's resolver alters verdicts for non-main principals in
sessions an older runtime still serves — its own `minor` decision. `/zensu:doctor` carries no
row for this gate, so a store that was never configured is visible only in the hook's stderr note.

**Port-relevant.** The core half is `decide` / `denyReason` / `describe` / `SILENT_FAULT_IS_A_LIE` / `resolveTargetPath` / `targetsOf` / `payloadFromRaw` — whose `null` return on a failed read is the ONLY thing keeping an unreadable accumulation off the silent-allow path, so a port that skips it reproduces the bypass —
`REASONS` / `WRITE_TOOLS` / `PATH_FIELDS` in the host-neutral module, plus its ONE sibling
require. The host half is TEN obligations: the hook and its two matcher registrations, the host's TOOL-NAME vocabulary, which payload field carries the path (`file_path` vs
`notebook_path`), the store's own location, the operator accounts, the
CALLER-CWD capture (the wrapper must record its own directory BEFORE the `cd` that reaches the
module and hand it in, or a relative target anchors in the plugin tree), the PROJECT-ROOT read
that feeds the over-arm valve — without it a store containing the project denies every write in a
session with no config flag and no env escape — and the TWO stderr disclosures the entry point
writes: the `SILENT_FAULT_IS_A_LIE` note and the `overArmUnchecked` line. Those last three are the
easiest to miss, and each of them removes a control rather than a convenience. The last
two are the STDIN LIFECYCLE and the DECISION EMISSION: `payloadFromRaw` is in the core
half, but the `accumulationFailed` flag it keys on is set only by host-half code, and a
handler registered on `end` alone never runs when a readable is destroyed by an error —
so a port that satisfies the other eight and writes an `end`-only handler always passes
`accumulationFailed: false` and reproduces the silent allow with the core copied
verbatim. The emission is the `hookSpecificOutput`/`permissionDecision` envelope and the
no-`process.exit()` rule, assigned to the host half exactly as the sibling plan gate
assigns its own. The module names no
environment variable of its own; all three anchors (store, caller cwd, project root) are read in
the host half and passed as options, so a port re-decides those reads without touching the
decision. `zensu-codex`,
`zensu-kiro` and `zensu-antigravity` were NOT included in this change.

## Witness Attempt Half (`hooks/pre-bash-witness.sh` + `hooks/lib/zensu-witness.sh`)

The Phase 6 witness cross-check could corroborate a PASS and **structurally could not
corroborate a FAILURE**, and the cause is the host rather than any code in this repo.
Claude Code does not deliver `PostToolUse` for a Bash call that did not complete
successfully, so `hooks/post-bash-witness.sh` never ran for a failing command and the
witness log carried no record of it at all. Since
`hooks/lib/zensu-evidence-crosscheck.js` matches a CHECKPOINT/AUDIT claim against a
witness entry by EQUALITY, every claim naming a failing command could only ever reach
`EVIDENCE GAP` — the same verdict as a command that was never run. The evidence channel
was one-sided in exactly the direction evidence discipline cares about most.

**MEASURED, in both halves, and the two halves answer different questions.** Live, with
a chain armed: `bash -c 'echo …; exit 3'` produced zero matching witness lines while the
same command exiting 0 produced exactly one; in the wild, a structure suite exiting 1
produced no entry while four sibling suites exiting 0 immediately around it all did.
Against a fixture, the RESULT hook was fed five payload dialects — `exit_code: 3`,
`exit_code: 0`, a bare-string `tool_response`, no `tool_response` at all, and
`is_error: true` — and wrote a line for every one of them. So the hook has no branch on
the exit status and cannot be the cause; the missing line is the event never arriving.
Do not re-diagnose this as an early return in the writer. `P12-A0` in
`tests/structure/test-post-bash-witness.sh` keeps that control executed, precisely so the
next reader does not have to re-derive it.

**The fix is a SECOND writer on the one channel the host fires unconditionally.**
`hooks/pre-bash-witness.sh` runs on `PreToolUse` `Bash` and records
`BASH-ATTEMPT cmd="…"` before the command runs. An attempt with no matching completed
entry is then POSITIVE evidence rather than an absence, and the cross-check consumes it
as such:

| witness | claimed green | claimed non-pass |
|---------|---------------|------------------|
| attempt + completed | judged on the completed entry's `tail=`, unchanged | unchanged |
| attempt, no completed | `EVIDENCE CONTRADICTION` | **verified** — the direction that was unreachable |
| neither | `EVIDENCE GAP`, unchanged | `EVIDENCE GAP`, unchanged |

**Nothing about corroboration was widened to get there, and the check that proves it is
the one to keep.** A claim matching neither kind is still a gap; a log-writing command's
ATTEMPT is excluded exactly as its completed entry always was; and a witness log written
before this hook existed carries no attempt lines, so every verdict over it is
byte-identical to the previous behaviour. `P6d`, `P6f` and `P6g` in
`tests/structure/test-evidence-crosscheck.sh` are those three.

**The attempt line proves the call REACHED the Bash tool, never that it exited
non-zero**, and the wording must not be tightened. Every `PreToolUse` hook on a matcher
runs whatever any of them decides, so an attempt is recorded for a call another gate then
DENIES — and for one the user aborts. `ATTEMPT_ONLY_MARKER` therefore reads "the tool
call never completed (non-zero exit, interruption or denial)", and it is EXPORTED so no
consumer re-spells it.

**The fail-then-fix cycle is why the attempt records are not consulted once a completed
entry exists.** A command that failed, was fixed and re-ran green leaves two attempts and
one completed entry; treating the surplus attempts as evidence would report a false
contradiction on every normal red-to-green cycle. `P6e` is the pin.

**ADVISORY, and that is load-bearing rather than stylistic.** The hook writes nothing to
stdout, returns no `permissionDecision` of any kind, and always exits 0 — including on
the inherited-plugin-root mismatch every sibling answers with `exit 2`. On `PreToolUse`,
stdout is the decision channel and a non-zero exit BLOCKS the call, so a witness that
failed closed would break every Bash call in the session, starting with the ones it
exists to record.

**ONE extraction, called twice.** `hooks/lib/zensu-witness.sh` owns the redact-module
resolution and the payload decode; both hooks source it. The two writers must redact
`cmd` identically or the attempt matches neither its own completed entry nor the claim,
so this is the one place in the feature where a hand copy would lose evidence silently
rather than loudly. What each hook deliberately KEEPS is the house pattern the existing
pins scan per file: the plugin-root guard, the principal check, the session bind, the
bypass-ledger block and the log-path spelling.

**`ZENSU_TEST_WITNESS=off` governs BOTH halves**, and both record the ledger entry. The
recorder dedups per gate, so a session still lands exactly one — and recording it in the
attempt half is what keeps the ledger honest for a session in which the escape is set and
every Bash call fails, where the result half never runs at all. No new stem enters
`ESCAPE_STEMS`; the spelling already existed.

**The attempt half is scoped exactly like the result half** — main principal, bound
session, chain-state `active`. Recording attempts for an unarmed session would put lines
in a log the result half never writes to, and the cross-check would read every one of
them as a run that did not finish.

**Version: `patch`.** Walked against §"Runtime Lineage (`version_type` is load-bearing)"
entry by entry: no context-record or workflow-state schema field, no strict key set, no
hook removed or renamed and no matcher changed, no new config key, no attestation change.
Adding a hook is a `patch` UNLESS it can return a `permissionDecision`, which this one
cannot in either direction — it is the ADVISORY shape that exemption names. The witness
log gains a line KIND, but it is an ephemeral per-session artifact read only by the
cross-check in the same tree, never a persisted shape two runtimes must agree on, and the
parser accepts a log with no attempt lines unchanged.

**Coupled sites that move together:** `WITNESS_ATTEMPT_MARKER` / `WITNESS_MARKER` /
`ATTEMPT_ONLY_MARKER` in `hooks/lib/zensu-evidence-crosscheck.js` (all three EXPORTED so
the suite builds its fixtures from the producer rather than re-spelling the format); the
`kind` field `parseWitness` now stamps on every entry, whose ABSENCE means a completed
entry — a legacy log parses with no `kind` at all, so the predicate tests for `attempt`
and never for `result`, and inverting it would silently discard every pre-upgrade entry;
the `Bash` `PreToolUse` matcher in `hooks/hooks.json`; the hook count in
`docs/configuration.md` (header, prose and the `#hooks-N` anchor) plus the
`configuration.md#hooks-N` cross-link in `docs/architecture.md`; `R19` and `R32` in
`tests/structure/test-artifact-redaction.sh`, which now scan BOTH writers and the shared
library respectively; the mechanism-2 consumer list in the header of
`tests/structure/test-msys-special-plugin-module-boundaries.sh`; `P3`'s roster in
`tests/structure/test-bypass-ledger.sh`; and `adopt_hook_expected` in
`tests/structure/test-versioned-plugin-upgrade.sh`, which is the coupling that fired
in the UNOBVIOUS direction and cost a red Windows shard. AC-C04 enumerates the Bash
matcher from `hooks.json` and expects EVERY hook on it to deny the adoption command
on win32, so registering an advisory hook there reported as `unexpected:
pre-bash-witness.sh` in a suite named for plugin upgrades. The exception set now
lives in one helper both AC-C04 loops call, and every member states why it cannot
deny — a third entry needs its own sentence. Note the platform bound on verifying
this: `ADOPT_EXPECTED` is `allow` on POSIX, so on macOS every hook expects `allow`
and the regression is INVISIBLE; the helper's deny-default branch is driven
directly rather than reached through the suite.

**Operator-facing accounts that must move with it:** the `pre-bash-witness.sh` row, the
`post-bash-witness.sh` row and the `ZENSU_TEST_WITNESS` row in `docs/configuration.md`;
the four-channel table, the redaction-writer table and §"Witness channel" in
`docs/tdd-manager-workflow.md`; and `skills/tdd/SKILL.md` Phase 6 step 1 together with
the claim-format note beside it that states the witness `exit=` is always `?` — the two
sit in different steps and a reader who finds one must be told about the other.

**Known gaps, accepted and named:**

- **A denied or aborted call is indistinguishable from a failed one.** All three leave
  the same attempt-only shape, and the contradiction text says so rather than guessing.
  Narrowing it would need the host to report the outcome, which is the thing it does not
  do.
- **The doubled hook cost is real, and it is NOT confined to armed chains** — an earlier
  wording of this bullet said an unarmed session pays nothing, and that is false by simple
  reading. Both writers run the payload extraction BEFORE the activation check, because the
  session id they check activation for comes out of that extraction, so every Bash call in
  every session with a readable Session Control record now spawns one extra `bash`
  (`zensu-host-path.sh`) and one extra `node` (the extractor) whether or not a chain is
  armed. That ordering is pre-existing in the result half; the attempt half doubles it. The
  cheap fix is available and NOT taken here: `zensu_bind_hook_session` exports
  `ZENSU_SESSION_KEY`, so the attempt half could test activation off that value first and
  return before spawning anything — left alone because the final check is the authoritative
  one and reordering it is a behaviour change to a path every Bash call travels, which
  belongs in its own review. Say "unmeasured", never "free".
- **Windows is UNVERIFIED.** `test-post-bash-witness.sh` and `test-evidence-crosscheck.sh`
  are absent from `tests/profiles/windows-ci.v1.json`, whose shards this file records as
  already close to their `profileTimeoutMs`, so the new checks never run on the blocking
  Windows PR shard. Say "unverified", never "covered".
- **No `/zensu:doctor` row.** A session in which the attempt half stopped recording — an
  unregistered hook, a `hooks.json` edit — is visible only as cross-check verdicts
  reverting to `EVIDENCE GAP`, which is exactly the pre-change behaviour and therefore
  silent. `P12-A1` pins the registration at build time; nothing checks an installed tree.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included.
  The premise is host-coupled in both directions: a port must re-measure whether its own
  harness fires the post-tool event for a failing command, and whether its pre-tool event
  fires unconditionally. A port that copies the hook without taking that measurement
  ships a second writer for a gap it may not have.

## Bypass Ledger Read Contract (`tdd_bypasses`)

`tdd_bypasses` is the ONE member of the `_tdd_read_validated_state` reader family
that signals an unreadable document through its EXIT STATUS rather than an echoed
sentinel. Its siblings — `tdd_state_status`, `tdd_get_flag`, `zensu_workflow_allows`,
`tdd_phase`, `tdd_step`, `tdd_has_red_fail`, `tdd_get_counter` — all stay total and
`return 0` with a value (`invalid`, `false`, `INVALID_STATE`, `0`, …). The divergence
is deliberate: this reader's value is rendered VERBATIM into the user-facing
`Gates bypassed during this session:` line, so a sentinel would be printed as if it
were a gate name. It returns **1** for a document that does not validate and **2**
for one that is absent, because a clean ENOENT at `--tdd-begin` is the ordinary
first-arming case and must not be reported as damage.

**No rendering site consumes that status directly.** `zensu_bypass_display`, beside the
constants in `hooks/lib/zensu-tdd-phase.sh`, owns the whole ladder — including a
catch-all that fails CLOSED on an unknown status, which three hand-rolled copies
previously got backwards by testing `-eq 1` and falling silent instead. Its second
argument decides ONLY what an absent document renders: `text` for a terminus that must
disclose (`--bypass-list`, the post-review delegate), the default `empty` for a clearing
verb (`--tdd-begin`, `--tdd-reset`) and for a Stop release, where a clean ENOENT means
nothing was ever recorded. It re-raises `tdd_bypasses`' status, so `--bypass-list` still
exits **3** on a non-zero read — distinct from its pre-existing exit 2 for an unavailable
session identity. `tdd_add_bypass`'s own dedupe is the one exception: it consumes the raw
value inside a `case` word and discards the status by design. Adding a sixth rendering
site means calling the helper, never re-rolling the mapping; both message constants live
beside `ZENSU_BYPASS_GATE_ALLOWLIST` and neither sentence may be hand-copied into a
consumer.

**A chain terminus and a Stop release are both disclosure points**, because a gate escape
needs no file change to be recorded — `ZENSU_TEST_WITNESS` and `ZENSU_MCP_GATE` are both
reachable without one, so a zero-change chain is exactly where an undisclosed escape would
hide. Four release paths therefore render the line themselves on **stderr**, the operator
channel every other Stop release message already uses: `ZENSU_CHAIN=off`,
`hooks.chainEnforcer=false`, the cap release after a chain fails to converge (all three via
`zensu_render_bypass_release` in `hooks/stop-chain-enforcer.sh`), and the `--chain-done`
verb itself via `zensu_render_terminus_bypasses` in `hooks/lib/zensu-log.sh`, which covers
both the standalone and the bound spelling so either entry point discloses. A new release
path added above the routing branches needs the same call.

**Operator-facing accounts that must move with this contract:** the "Visible opt-outs
(bypass ledger)" paragraph in `docs/configuration.md`, which is the AUTHORITATIVE residual
list — the other surfaces point at it rather than restating it, because three divergent
copies is exactly the drift this rule exists to prevent; the `## Open` rendering rules in
`skills/self-review/SKILL.md`; the build-union rule in `skills/autopilot/SKILL.md` and its
`templates/autopilot-pr-body.md` third value. `tests/structure/test-bypass-ledger.sh` pins
the first three; the template is not pinned by that suite.

**What the ledger proves is narrower than it reads.** Validation is STRUCTURAL:
`validateWorkflowState` checks shape plus a self-derivable `session_id_hash`, and the
`bypasses` array carries no MAC and no monotone counter. A document edited in place
but left schema-valid still reads `valid` and renders `none` — `test-bypass-ledger.sh`'s
P5y case performs exactly that read-modify-write and expects a valid result. Closing that
needs a persisted authenticity signal, which is a workflow-state schema field and
therefore a breaking minor under the Runtime Lineage rule; it is deliberately not
paid for. Say "what a readable document recorded", never "no gate was escaped".

## Status-Marker Legend (CHAIN-END SUMMARY + PR bodies)

Every status and verdict cell of the chain-end report and of the plugin-opened PR body
carries a leading marker — 🟢 good, 🟡 attention, 🔴 bad, ⚪ not applicable. **The marker
PREFIXES the value and never replaces it**, which is the whole safety property: a
verbatim-carry literal (`EDIT NOT LANDED`, `UNVERIFIED (no claims logged)`, an unresolved
`PENDING PREDICATE`, `EVIDENCE GAP`, `EVIDENCE CONTRADICTION`,
`EVIDENCE CROSS-CHECK UNAVAILABLE`, `FINDING VERIFICATION DEGRADED`, the bypass ledger's
`UNREADABLE — …`) keeps its own words after its marker. Reducing one to a bare coloured
dot deletes the disclosure while keeping the colour, which is worse than having no colour
at all.

**"Keeps its own words" is NOT "byte for byte", and the difference was a real
contradiction before it was written down.** The same cells are subject to the pipe-escaping
rule — first every backslash doubled, then every pipe as a backslash-pipe — and an escaped
cell is by construction not byte-identical to its source. The two rules were both stated as
absolutes over one cell, and a model resolving that in favour of byte-identity emits an
unescaped `|`, which splits the table row and drops exactly the verdict clause the row
exists to surface. The legend now subordinates one to the other explicitly.

**⚪ is bound to PROVENANCE, never to judgement**, and it has exactly ONE admissible case:
a requirement row the plan already marks deprecated. An earlier spelling added "or a step
this project has no equivalent of", which cites no source at all and let a skipped build or
a disabled gate be spelled ⚪ — benign-looking — where the next sentence demands 🟡. The
bound matters because `skills/autopilot/SKILL.md` states that a dropped criterion "keeps its
ID and is marked deprecated", so *dropped* and *deprecated* name one observable state
through two vocabularies whose markers are opposite. An outcome merely not run is 🟡; a
requirement this session did not implement is 🔴 dropped even if it was retired mid-session.

**The `Check | Verdict` marking rule is a VALUE-SHAPE rule, not an enumeration**, and the
difference is what keeps it total. An earlier spelling listed the OUTCOME rows by name, so
a row added later stayed unclassified and unmarked with every check green — and the FACT
rationale it carried ("a title, a count and a path are not verdicts") contradicted its own
membership, because `Tests created` and `Coverage` render as counts and were nonetheless
listed as OUTCOME rows. The rule now names only the four unmarked rows — Feature, Files
modified, Plan, Log — marks everything else, and states that a count measured AGAINST a
target is a state. Two rows were added at the same time, and their extra arms are of DIFFERENT kinds:
`Finding verification` carries a NOT-RUN arm (🟡, because the gate is config-gated and a
disabled gate must never render like a clean one — the rule this repo already applies to
`reviewerSpawnPermissionCheck`), while `Gates bypassed` carries a NOT-READABLE arm, since
its value is always read and the failure mode is an unreadable ledger rather than an absent
one. Its 🟢 is bound to the literal `none` and everything else is 🔴, so a reworded ledger
constant cannot render clean.

**EIGHT CARRIERS, and a census in prose goes stale the next time one is added — so this is
a GREP, not a list: before rewording the legend or the vocabulary, run
`grep -rlE '🟢|🟡|🔴|⚪' hooks skills templates docs agents` and judge every hit.** Use `-E`;
an earlier spelling of this instruction used a BRE alternation over `🟡 unvalidated` and
`🟡 partial`, which matched NOTHING under `docs` — the operator carrier spells the set as
`🟡 attention (partial, …)` — so the one root added to reach that carrier reached nothing,
reintroducing under the fix the exact census failure this file records for the
`zensu:code-reviewer` and `scv1_` identities. The eight as of this writing:

1. `hooks/post-review-tdd-delegate.sh` — the `COMBINED_SUMMARY_DIRECTIVE` string.
2. `skills/self-review/SKILL.md` §"### Final report" — the second renderer.
3. `docs/tdd-manager-workflow.md` §"Chain-end combined summary" — the operator account.
4. `templates/pr-body.md` — the AC `Status` column.
5. `templates/autopilot-pr-body.md` — the same column, autopilot's variant.
6. `skills/autopilot/SKILL.md` — the step-3 PR-body renderer, which restates the whole
   vocabulary, AND the Phase 2 delivery invariant, which restates the `deprecated` cell. The
   invariant was missed on the first pass and shipped the unmarked spelling for a round.
7. `skills/cover/rules/drivers.md` — the one behavioural CONSUMER, which resolves ACs from
   the PR body and must match the status WORD inside the cell rather than compare the cell
   to a bare literal.
8. `docs/review-chain.md` — the OVERRIDE contract, whose mandatory-section rows for both
   PR-body templates name the marker prefix. It is what keeps a repo override from deleting
   the rule silently, so the argument two paragraphs down depends on it; it was omitted from
   the roster while both a pin and that argument already pointed at it.

Carriers 1 and 2 must carry the legend SENTENCE byte-identically;
`evals/config-gate/test-post-review-combined-summary.sh` extracts it from the hook's
DECODED `additionalContext` and from the skill and compares, with a non-empty control on
each extraction. That pin was bite-tested: a one-word reword of the skill legend turns it
red. **That pin covers the legend SENTENCE and NOTHING BELOW IT**, because `LEGEND_RE`
terminates at `takes no marker.` — so every marker-bearing rule the two carriers share
sits after it. A separate SHARED-VOCABULARY arm closes that: it asserts the deliverable
`Status` vocabulary, the `ID | Status` vocabulary and the delimited no-Requirements
fallback line in BOTH schemas, each with a non-empty control. Two properties are
load-bearing. Both schemas are whitespace-FLATTENED first, because the skill wraps the
`ID | Status` vocabulary across two physical lines while the hook carries it on one, so
an unflattened needle would fail on the skill for a reason unrelated to drift. And the
fallback needle carries its BACKTICK DELIMITERS: both carriers delimit that literal so
the model knows where the emitted line ends, the hook's copy sits inside a `$'...'`
segment where a backtick is literal, and asserting the delimited form over the RENDERED
directive therefore proves in one check that the delimiter is present AND that it was
not eaten by command substitution. Bite-tested the same way: a one-word reword on the
SKILL side alone reports 50 PASS / 1 FAIL and restoring returns it green.
**The verbatim-literal pins are PER CARRIER and the two lists legitimately differ** —
the delegate renderer has a `Mtime audit` row where the self-review renderer has
`Evidence cross-check`, so the evidence literals live only in the latter. Both loops are
SCOPED to the summary schema, because a file-wide presence grep is satisfied by occurrences
elsewhere in the same file and cannot fail for the reason it is written for. The
orphaned-marker predicate runs over the RENDERED directive, never the hook source: the whole
directive is one physical source line whose breaks are `\n` escapes, so a source-side scan
was structurally inert for that carrier. It prints a sentinel on a clean scan, so a throw is
distinguishable from "no orphans found".

Carrier 3 is pinned by `R17-P2b` in `tests/structure/test-tdd-manager-patches.sh`; carrier 4
by `P5a2` and carrier 5 by `P2c2` in `tests/structure/test-templates.sh` (that suite binds
`TPL_PR` to the AUTOPILOT template and `TPL_PRBODY` to the shared one — easy to invert, and
this paragraph did invert it once); `P5a4` pins both templates' PROSE rule, which is the only
thing an override author reads; `P5a5` pins carrier 6 and forbids the exact spelling
``status `deprecated` `` anywhere in it — that literal is the WHOLE needle, so an unmarked
`status: deprecated` written without backticks is NOT caught, and the claim must not be
widened past it; `P8c` in `tests/structure/test-plan-requirement-ids.sh` pins
carrier 7. `P5a3` pins the override mandatory-section rows and is anchored PER ROW, because
the phrase occurs on both and a file-wide needle stays green after a one-sided deletion.

**The legend equality is asserted on carrier 1's RENDERED form**, never on its source: the
eval extracts it from the decoded `additionalContext`, so a `\'` inside the `$'…'` string
renders as `'` and compares equal to the skill's plain apostrophe. Two constraints were
claimed here and BOTH were retired for the same reason — no mechanism observes them: a
backtick is literal inside `$'…'` and inside the double-quoted re-expansion, and an
apostrophe survives the render. Keep the sentence readable in both syntaxes by convention
if you like; do not state it here as a rule the pin enforces.

**A repo override can delete the rule from carriers 4 and 5**, because
`docs/review-chain.md` states an override REPLACES a template wholesale. The marker prefix
is therefore listed among both templates' MANDATORY SECTIONS there. Do not restate the
operator doc's claim as covering override repos without it.

**Two neighbouring vocabularies are deliberately NOT reconciled.**
`hooks/lib/zensu-doctor-report.js` declares `OK = '✅'; WARN = '⚠️'; BAD = '❌'` for the same
good/attention/bad axis. They stay separate because this set has a fourth state the doctor
has no counterpart for, and because `⚠️` is an emoji-presentation sequence whose width
misaligns a table column. A later reader should not "reconcile" the two sets.

**Known gaps, accepted and named:**

- The `## Open` table carries the same evidence literals UNMARKED while the
  `Check | Verdict` cell marks them — deliberate, because every row in `## Open` is by
  definition open, and both renderers now state that exemption so it does not live only in
  the operator doc.
- The unmarked-rows rule is pinned at the INSTRUCTION level only. Whether a model actually
  renders it is model behaviour that only a live-model eval could observe, so do not claim
  the invariant is enforced.
- **Two per-requirement vocabularies exist over the same `AC-###` ids and are NOT
  reconciled:** the chain-end `ID | Status` table uses met / partial / contradicted /
  dropped / deprecated, while the PR body uses pass / partial / unvalidated / fail /
  deprecated. They answer different questions — one is plan coverage, the other is
  validation outcome — but nothing states the mapping, and `skills/converge/SKILL.md`
  carries a THIRD (met / partial / missing / contradicted, plus `deprecated — skipped`)
  with no markers at all, offered from inside the very `## Open` section this feature
  colours. Colouring converge was considered and deliberately not done here.
- The `Gates bypassed` row names the ledger's `UNREADABLE — …` prefix, whose owning
  constants are named in §"Bypass Ledger Read Contract". The row is keyed so that 🟢 is
  exclusive to the literal `none` and EVERYTHING else is 🔴, which is what makes a reworded
  constant safe — an earlier wording here claimed it "still falls to 🔴 for any named
  escape", which was false, because a reworded unreadable line is neither `none` nor a
  named escape and matched no arm at all. Recorded here rather than in that section's
  roster.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field, no strict key set, no hook added, removed or renamed and no
matcher changed, no new config key, no attestation change, and no `permissionDecision` in
either direction — the change is directive text plus template and doc prose, which that
section classifies explicitly as a `patch`.

**Port-relevant.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included.
A port owns its own renderers and its own PR-body template, so it re-decides the vocabulary
and the pins; the marker set and the provenance bound are the portable half.

## Chain Shape & Rearm Receipt (`hooks/lib/chain-recovery-v1.js`)

`chain-recovery-v1.js` is the single source of truth for two things, and it is **not**
cosmetic diagnostics code:

- `rearmReceiptVerdict()` decides whether a pending `reviewRearm` receipt agrees with its
  own workflow document. `_tdd_issue_review_ticket_critical` delegates its `markerValid`
  check to it, so **relaxing this predicate widens who may issue a review ticket** —
  treat it as write-gate code.
- `classifyChain()` maps a workflow document to the chain shape, the supported next
  command, and the `recoverable` flag that authorizes `--chain-recover`.

These consumers must move together with it, and `classifyChain`'s returned FIELD NAMES are
part of that contract: the `--chain-status` verb, the `--chain-recover` transaction (both in
`hooks/lib/zensu-tdd-phase.sh`), the refusal-hint renderer in `hooks/lib/zensu-log.sh` (a DIRECT `require`
consumer since it reads `BLOCKED_RECOVERY_COMMAND`, plus `wedged` / `deadEnd` /
`recoverable` / `nextCommand` / `shape` off the report), `hooks/stop-chain-enforcer.sh`
(hardcodes the shape literals `wedged-stale-rearm` and `self-review-unbindable`), the `/zensu:doctor` renderer
(`hooks/lib/zensu-doctor-report.js`, a field-name consumer — and a CONSUMER of the exported
`INERT_SHAPES`, never a second hardcoder of it. A hand-copy there was tried and was wrong in the
one direction that matters: it compared against the `NEXT_COMMAND` lookup table, so renaming the
literal `chainShape` RETURNS while leaving the table key in place kept the copy agreeing while a
genuinely closed foreign chain rendered as open. A consumer cannot check a producer it does not
own, which is why the set moved here; `test-doctor.sh` P1ms pins the export and its contents, P1ms1 that the
renderer keeps no private copy), the ticket issuer, and the rearm writer
(`_tdd_rearm_autopilot_review_critical`, which takes `isLinkId`, `RETURN_STAGES` and
`REARM_MARKER_KEYS` from here) — adding a receipt field or a return stage in the writer
alone would make every receipt it mints classify as stale and wedge the chain permanently.

`isLinkId` carries a SECOND obligation that is easy to miss from this roster, and it is not
about the receipt: `shapeCommand` interpolates `autopilotRunId`, `autopilotAttempt` and
`chainId` into a command string UNQUOTED, and the only thing that makes that safe is that
`autopilotLinkage` reaches it solely under `linkage === 'bound'`, which requires `isLinkId` on
both ids. Consumers relay `nextCommand` verbatim — the `/zensu:doctor` chain rows print it as a
remedy to run — so WIDENING that character class and this interpolation must be re-decided
together. The class is also HAND-COPIED: `tdd_chain_snapshot` in `zensu-tdd-phase.sh` spells it
character-identically, and `zensu-autopilot-state.sh` already spells it with a different minimum
length, so a widening is a multi-site decision. `chain-recovery-v1.test.js` pins the shell
metacharacters against both interpolated ids.

An eighth place hardcodes the same receipt schema independently: the `reviewRearm` validator
in `hooks/lib/session-control-core-v1.js` rejects the ENTIRE workflow document when the key
set does not match, which fails every hook closed — strictly worse than a wedged chain. A
receipt-key change must therefore land THERE FIRST, in the same commit as the module and the
writer. A ninth site hardcodes the key NAME only: `_tdd_mark_unclaimed_review_critical`
refuses the unqualified no-ticket terminus while `reviewRearm` is present. That conjunct
narrows the terminus only WHILE a chain is wedged — `--chain-recover` drops the receipt and
the terminus becomes reachable again, by design. Renaming the field without updating the
conjunct removes even that narrowing.

Two more sites hardcode the provenance literals rather than importing them:
`zensu-log.sh --phase` and `tdd_write_phase` / `_tdd_write_phase_critical` reserve the
`CHAIN_RECOVERED` phase and the `chain-recovered: ` reason prefix so only the repair can
mint a provenance entry. Renaming `RECOVERY_HISTORY_PHASE` or `RECOVERY_HISTORY_REASON_PREFIX`
without updating those guards leaves them reserving a dead name and makes the `recoveries`
counter forgeable again.

The repair runs under TWO locks, in this order and never the reverse: the external process
lease `_tdd_locked_run` takes (`external-<sha256(resourcePath)>`) and then the core CAS lock
`mutateWorkflowState` takes (`state-<sessionKey>`). Both are required — the ticket writers
serialize only on the lease, so the core lock alone would not exclude them — and the
`recoverable` predicate is deliberately re-evaluated INSIDE the mutation callback, after
both are held.

The operator-facing shape table in `skills/recover-chain/SKILL.md` mirrors `NEXT_COMMAND`
(a new shape means a new table row); a new `BLOCKED_RECOVERY_COMMAND` reason must be named
in that skill's "recoverable: false" paragraph. `tests/structure/test-chain-recover.sh` T42
enforces that every emitted shape and reason is documented somewhere in the skill.
`tests/structure/chain-recovery-v1.test.js` (node --test) pins the shape lattice and the
receipt predicate; `tests/structure/test-chain-recover.sh` pins the end-to-end behavior.

**Two invariants the recovery must never break**, both learned the hard way in review:

1. `recoverable` requires `reviewTicketConsumed === true`, and the repair NEVER WRITES the
   ticket slot. Writing `reviewTicketConsumed = true` on a document that has it `false` would
   complete the precondition of the *unqualified* no-ticket terminus
   (`_tdd_mark_unclaimed_review_critical`), letting `--code-review-done` close a chain with no
   reviewer, no ticket and no round — so the repair REFUSES such a document (`ticket-slot`)
   instead of normalizing it. A retained CONSUMED ticket is allowed, because `reviewTicket !== ''`
   keeps that terminus shut on its own. The invariant is "the repair never writes a value that
   was a missing precondition of a terminus" — NOT "the repair never makes a terminus
   reachable": dropping the receipt deliberately returns a wedged chain to exactly the
   permissiveness of any freshly armed chain, including that terminus.
2. The bypass ledger records gate escapes ONLY, so everything rendered under "Gates bypassed"
   is true. The repair records its provenance as a workflow `history` entry inside its own
   transaction — never as a ledger entry.

## Plan-Gate Payload Sources (`hooks/lib/plan-payload-v1.js`)

The Autopilot plan-approval gate reads the approved plan from FOUR payload sources, in
precedence order, and `plan-payload-v1.js` is the single source of truth for which:

| # | Source | Live on the current Claude Code build |
|---|--------|----------------------------------------|
| 1 | `tool_input.plan` | no |
| 2 | `tool_input.planFilePath` | no |
| 3 | `tool_response.plan` | **yes** |
| 4 | `tool_response.filePath` | **yes** |

Sources 1-2 are dead on this host and still ranked first on purpose: a host that DOES declare
those ExitPlanMode fields keeps its meaning, and an explicit caller-supplied plan must not be
overridden by the harness copy. `tests/structure/test-autopilot-plan-delegate.sh` P16 pins that
the legacy carrier still delegates identically, so keeping them costs no behavior.

**Retiring them is not a four-check edit.** In `test-plan-payload-fallback.sh` the `tool_input`
carriers are driven by every case built by `payload()`, `payload_nonstring_plan()`,
`payload_input_and_response()` and the inline F21a/F43 builders — roughly twenty checks — plus
P16. Most have a source-4 mirror already (F5→F35, F6→F36, F7→F37, F13→F40, F15→F38, F16→F39,
F17→F41); the rest would have to be re-pointed at the response carrier. The trigger is a
RE-CAPTURE, not a hunch: only a fresh capture from every supported host can show that none of
them populates `tool_input` for ExitPlanMode any more.

**Why the dead sources are dead.** The harness strips ExitPlanMode fields its schema does not
declare — a captured payload carries `tool_input == {"_targetMode":"auto"}` — and delivers the
approved plan in `tool_response`, a structured object (`plan`, `filePath`, `isAgent`,
`hasTaskTool`). Before this was understood every Autopilot run died at its single planning gate
with `INVALID_PLAN_PAYLOAD`, unfixable from the model side.

**Fields are read BY NAME, never by scanning text.** The rendered response a model sees carries
a `Your plan has been saved to: <path>` preamble, but the plan body is model-authored: mining
that text would let plan prose inject its own preamble and name the path the gate opens.
`test-plan-payload-fallback.sh` F31b (a rendered string response is never mined) and F34 (a
`saved to:` line inside the plan body never names the approved bytes) are the pins; both
discriminate through the persisted digest, because an absent decoy proves nothing.

**Everything that re-encodes this shape must move together:** the module's `SOURCES` table;
every `payload*` builder in `tests/structure/test-plan-payload-fallback.sh` — `payload`,
`payload_nonstring_plan`, `payload_response`, `payload_response_nonstring`,
`payload_response_shape`, `payload_input_and_response`, plus the inline F21a, F31c, F43 and
F11b-tool builders; the fixture-shape assertion F33a; and the whole-flow builders in
`test-autopilot-full-cycle.sh` and `test-autopilot-plan-delegate.sh` (which also keeps
`payload_input_dialect` for the legacy carrier). The committed capture
`tests/structure/fixtures/exitplanmode-posttooluse-payload.v1.json` pins the shape the gate was
BUILT AGAINST; it cannot observe live harness drift — only a fresh capture can.

**Operator-facing account that must move with the sources:** `skills/autopilot/SKILL.md`, which
names `tool_response.plan` and `tool_response.filePath` when it tells the skill where the run
marker has to travel.

`tests/structure/plan-payload-v1.test.js` (node --test, driven from
`test-plan-payload-fallback.sh` F11b) pins the table's order, liveness and label shape, the
reader's refusal codes, and the branches the shell layer cannot reach — a NUL-byte path, a
bare-string carrier, a hard link. F11d pins that every module reason maps to an exit code and
back to the identically named BLOCK_CODE, which no behavioral case can observe.

**The response also declares WHO called, and that is judged before any source is read.**
`tool_response.isAgent === true` refuses as `PLAN_RESPONSE_AGENT_ORIGIN_REJECTED`, and a
present non-boolean refuses as `PLAN_RESPONSE_ORIGIN_TYPE_REJECTED` rather than being read as
falsy — `"false"` and `0` are both truthy-adjacent spellings that would otherwise approve an
agent-originated plan by coercion. This is a POSITIVE assertion layered on Session Control's
absence-based principal check, which grants `main-v1` only to the top-level thread; it is free
to make because the harness supplies the field. Two orderings are load-bearing and pinned:
it runs AFTER the owner and stage checks, so an unauthorized caller still learns nothing about
the response shape (F45c), and BEFORE the source walk, so no payload-named path is opened for
a caller who may not approve. F45/F45a are the bites — measured against the pre-change hook,
which APPROVES both shapes — and F45b is the positive control that the same builder with
`isAgent: false` still approves. Each of the four owns a separate armed run: sharing one let an
approval in an earlier case push the run past `PLANNING`, and every later case then failed on
the transition instead of on what it was about.

**Three checks pin behavior this gate already had and never exercised**, so they pass in both
trees and are coverage, not bites: F47/F47a (a plugin missing the reader module refuses as
`RUNTIME_UNAVAILABLE` — asserted to NOT be `PLAN_EVALUATION_UNAVAILABLE`, which would claim the
payload was judged — with a restored-module positive control), F48 (the module path reaches
node through the environment, never argv, matched against a closed allowlist of line forms
because the evaluator spans ~90 lines and a line-scoped grep would miss an argv token appended
below it), and F49/F49a (a hard link refused through both carriers).

**`PLAN_STAGE_MISMATCH` (exit 7) is unreachable and deliberately left so.** The shell `case`
already filters the active document to `PLANNING|AWAIT_TDD`, and the evaluator re-reads
`state.stage` from that SAME document — there is no second source to disagree with it. The
re-check is defense in depth for a future where the two diverge; do not write a behavioral
fixture for it, there is none.

**The `openMode` seam exists to reach dead code, and must stay a MODE.** The `noFollow === 0`
branch in `readPlanFile` is what a host without `O_NOFOLLOW` runs; every POSIX host this ships
to defines the flag, so in production it never executes. `readPlanFile(path, openMode)` compares
its second argument against the string `LSTAT_PRECHECK_MODE` and never ORs it into the open
flags — a caller can only take the STRICTER path, never widen the open. The unit suite pins that
with `O_CREAT` as the discriminator: were the argument a mask, the reader would create a missing
path instead of reporting it unreadable. Measured property worth keeping: deleting EITHER of the
branch's two guards leaves the suite green, because the other still catches the link; deleting
both fails only in `plan-payload-v1.test.js`. `test-windows-portability-guards.sh` carries the
reader in its secure-open inventory — every other pin there is per-file and therefore blind to a
NEW file carrying a hardened open.

**The Windows timeout for this suite is a coverage boundary, not a formality.** At
`timeoutMs: 600000` in `tests/profiles/windows-ci.v1.json` the `plan-payload-path-transport`
step reported `TIMED_OUT` at check ~61 of 70, so F45c, F49/F49a, F48, F12 and F47/F47a never
executed on Windows while the shard still reported its earlier checks as passing. It is 900000
now, and the full 70-check suite measures **714 s** there — 79% of the new ceiling, so roughly a
quarter of the budget is left. Every check costs Windows wall clock (the old run reached F45 at
540 s of 600 s) and the tail is the expensive part: four extra armed runs plus one full
plugin-tree copy. Budget against the 714 s, not against the ceiling. If the shard starts
reporting `TIMED_OUT` again, the tail of the file has gone unverified regardless of how many
checks passed before it. Same failure mode, same remedy, as the source-write gate's own note
above.

**The digest binds the bytes that TRAVELLED.** When source 3 wins, `approvedPlanSha256` is over
the response string, not the file at source 4's path. The two agreed byte-for-byte in the
capture and F44 pins that agreement, but they are not contracted to; `approvedPlanSha256` is
only written and shape-validated, never re-derived, so a host whose response string and saved
file disagree would silently bind the transported copy.

**Port-relevant.** The module OWNS `SOURCES`; a port edits that table in its own copy of the
file rather than calling in with a different one. `resolveApprovedPlan(payload, sources)` takes
a table argument so the unit suite can drive the walk with a synthetic one, and it REFUSES an
empty or malformed supplied table instead of substituting this host's carriers — two of which
open a payload-named file. A port also carries two host-half obligations the module cannot:
render the lib DIRECTORY through `zensu-host-path.sh` (that script rejects files) before
appending the file name, and guard the loaded spelling with `-f` / `! -L` / `! -r` plus an
export-shape check, routing any load fault to the RUNTIME receipt — never to
`PLAN_EVALUATION_UNAVAILABLE`, which claims the payload was judged. The host half — WHICH carrier a host populates — must be re-decided per port;
`zensu-codex`, `zensu-kiro` and `zensu-antigravity` carry the same gate against different
harnesses and were deliberately left out of the change that introduced sources 3-4. The
host-neutral half is everything below the resolution: the single `<!-- zensu-autopilot:RUN_ID -->`
marker, run-id equality, the owner and stage checks that precede every read, and the digest.
A port that takes only the module gets the field decision; it still owns its own emission and
its own exit ladder, which stay in `hooks/plan-approved-delegate.sh`.

## Host-Refused Reviewer Spawn (`hooks/lib/reviewer-spawn-denial-v1.js`)

The Stop chain-enforcer demands a `zensu:code-reviewer` spawn. When the HOST
permission layer refuses that spawn, the call never executes — so no PreToolUse
or PostToolUse hook can see it, and without this module the enforcer repeats an
impossible instruction until its cap (`autoFixMaxRounds + 3`) releases the guard.

Ten things are coupled and must move together:

- **`DENIAL_MARKERS` are host literals**, read out of the installed Claude Code
  binary (`DENIAL_MARKERS_SOURCE_BUILD` = 2.1.240: `Permission for this action was
  denied by the Claude Code auto mode classifier.` and `Permission for this action
  has been denied.`). The build is exported and pinned against the module header,
  so the constant cannot drift away from the provenance note beside it. They are
  matched as PREFIXES because the host appends its own `Reason: ...` tail. A host
  that rewords them silently disables the diagnosis — re-verify against the
  binary, never against memory. Re-verified 2026-08-22 with `strings` over
  2.1.237, 2.1.239 and 2.1.240: byte-identical in all three, each stored WITH the
  trailing `Reason: ` the prefix rule declines to contract, and no third
  refusal-result literal exists to add. The same transcript entry also carries a
  host-native `toolDenialKind` beside `message` (observed `automode-blocked`); it
  is deliberately NOT read — an undocumented, unversioned field whose absence
  would be indistinguishable from a clean spawn — and the module header plus a
  unit case record that it was seen and declined rather than missed.
  The `kind` values are re-encoded in exactly TWO
  places outside the module: the `case` arms in `hooks/stop-chain-enforcer.sh`
  that render cause and remedy, and the closed set `reviewerDenialRows` accepts
  from a note. A THIRD consumer READS the field without re-encoding it:
  `zensu_impl_stop_nudge` in that same hook interpolates `REVIEWER_DENIAL_KIND`
  and `REVIEWER_DENIALS` straight into its notice (see §"Implementing-Phase Turn
  Counter"), so a new marker reaches that surface under its real name with no
  shell edit — and, unlike the `case` arms, with no remedy arm to add and none
  missing. The hook's PROBE deliberately holds no third copy — it reads `kind`
  as a field, so a marker added to the module reaches the doctor under its real
  name with no shell edit, where the old closed set degraded it to the empty
  string and made the doctor render `unclassified` for a refusal both sides could
  already name. Adding a marker still means adding a remedy arm; without one the
  refusal renders unclassified, which is a degraded message rather than a wrong
  one, because the unknown arm is the safe arm. **That safety clause is already OVERTAKEN, and by code that predates the turn
  counter — record it, do not restate it as a live rule.** Keeping the value a
  `case` SELECTOR is what would hold module output out of user-visible text, and
  TWO stderr messages already interpolate it: the cap-release diagnosis in
  `stop-chain-enforcer.sh`, which predates this counter, and the counter's own
  refused-spawn notice. Neither reaches the hook's JSON `reason`, which is the
  string the clause was written about, so nothing is broken — but a renamed `kind`
  now moves operator-visible bytes in two places, and that cost belongs in the
  rename's plan rather than inside a rule the tree stopped following.
- **The CLI's one output line is a parsed contract**, not a display string:
  `status=<s> kind=<k> tool=<n> spawns=<n> denials=<n>`. The probe matches
  `status=` in first position, and reads `denials` with `${probe##* denials=}`,
  which requires THAT field to stay last. `kind` is position-independent by
  construction. Separators stay load-bearing throughout: every field is anchored
  on a leading space. The exact-line assertion in
  `tests/structure/reviewer-spawn-denial-v1.test.js` is the pin.
- **The sidecar name is re-encoded in the doctor renderer.** The hook writes
  `.zensu/state/reviewer-spawn-denied-<scv1 session key>.json`;
  `reviewerDenialRows` in `hooks/lib/zensu-doctor-report.js` matches
  `^reviewer-spawn-denied-scv1_[a-f0-9]{64}\.json$`. Rename one and doctor goes
  quiet with everything still green. T25 is the only check that drives both sides
  end to end.
- **`REVIEWER_SUBAGENT_TYPE` has a registered hand-copy, and the doctor also
  reports this refusal PROACTIVELY.** `REVIEWER_AGENT` in
  `hooks/lib/zensu-doctor-report.js` copies it rather than importing it: that
  module is required LAZILY inside `reviewerDenialRows`, so a load failure
  degrades one row, while a top-level require would take the whole report down.
  `DENIAL_RULE` in `stop-chain-enforcer.sh` carries the same identity again — and so
  do seven further files. **Do not treat any enumeration of them as complete.** The
  literal lives in TEN files under `hooks/` (34 matching lines, re-measured 2026-08-31
  after this branch merged `main`, which is exactly the occasion the note below warns about
  — the two branches carried different counts and the merged tree has neither; `grep -rc … | awk` summed — and the grep instruction below is itself one of them,
  which is why the number moves when this very paragraph is edited),
  including two functional comparisons a rename breaks silently:
  `post-review-tdd-delegate.sh`'s `SUBAGENT_TYPE` test and `claude-principal-v1.js`'s
  list entry. A census in prose goes stale the next time a site is added, which is why
  the instruction is a GREP and not a list: **before renaming this identity, run
  `grep -rn 'zensu:code-reviewer' hooks/` and change every site.** ONE pair is
  machine-checked — `test-doctor.sh` P1by pins `REVIEWER_AGENT` against the exporting
  `REVIEWER_SUBAGENT_TYPE`, the pair most likely to diverge because the require is lazy
  and nothing at load time compares them. A SECOND carrier is pinned, and the count
  below is derived from both: `ZENSU_REVIEW_SPAWN_IN_SCOPE` in
  `hooks/lib/zensu-tdd-phase.sh` made that file the TENTH carrier, and because it names
  `zensu:review-aspect` and `zensu:review-judge` in the same sentence a rename of ANY of
  the three identities lands there — so T38 in
  `tests/structure/test-stop-enforcer-self-review-routing.sh` asserts all three on the
  emitted directive. Ten files, three pinned (the lazy-require pair plus this one),
  so **the other seven files are NOT pinned**, in the same sense `WRAP` is unpinned
  above. Re-derive that number when a carrier is added or a pin lands; it is arithmetic
  over two facts stated here, not an independent claim. **It no longer has to be
  re-derived by hand:** T47 in `tests/structure/test-stop-enforcer-self-review-routing.sh`
  MEASURES the carrier count and the matching-line count and fails when this paragraph
  disagrees with the tree — which is how the previous figures (NINE / 29, and the derived
  six; then TEN / 32 across a merge) were found stale one commit after `hooks/lib/reviewer-spawn-allow-v1.js` became a
  carrier. Note the direction of that coupling: an ordinary change under `hooks/` that
  adds or removes the literal turns a suite named for Stop-enforcer routing red, and the
  remedy is to edit THIS paragraph, not the file you were working on — the same
  unobvious direction §"Gate-Disable Prefixes" records for `ESCAPE_STEMS` and G12. Rename the agent in one place only and
  the surviving copies keep telling the user to allow a subagent name nothing
  spawns, with every check green.
  Beside the reactive row, that file's `permissionExposureRows` reads
  `$HOME/.claude/settings.json` — and ONLY that path, for the reason
  §"The model-facing reason names only `~/.claude/settings.json`" below gives — and warns before any spawn is refused.
  Its host literals carry their own provenance constant `SETTINGS_SOURCE_BUILD`:
  `permissions.{defaultMode,allow,deny,ask}`, the `auto` value, `autoMode.allow`,
  the `Agent(<name>)` rule grammar, the file layout — **and the deny -> ask ->
  allow evaluation order**, which is listed separately because its failure mode is
  the opposite of the others': a rename makes the check fall SILENT (useless), a
  REORDER leaves every row rendering and turns the deny row's "adding a
  permissions.allow rule changes nothing" into a false claim. P1bd cross-checks
  the constant against the provenance comment that enumerates them, the way
  `reviewer-spawn-denial-v1.js` cross-checks `DENIAL_MARKERS_SOURCE_BUILD` against
  its module header; P1bd1 pins the order clause. Its rows are held in step with
  `skills/doctor/SKILL.md` by P1be, the same drift pin P1qr applies to the reactive
  rows — `docs/tdd-manager-workflow.md` §"The proactive counterpart, before any
  chain wedges" is the third account and is NOT covered by that pin.
- **Every row that INSTRUCTS a settings edit carries `SELF_PERMISSION_BAR`**, and
  all SIX call sites consume it — the exposure row, the reactive refused-spawn row,
  the deny row, the ask row, the could-not-judge row, and the refusal caveat the
  implementing-turns row appends when a live note records a refused spawn. That sixth
  arrived with the turn counter and this census was left at five for a round, which is
  the drift the enumeration exists to prevent. The two that previously
  spelled the sentence inline now consume the constant with their emitted bytes
  unchanged, which is what keeps P1be and P1qr green. A shared constant with an
  unconsumed copy beside it is worse than either honest duplication or one source,
  because it advertises a single source that does not exist; do not reintroduce one.
  **The bar ALSO exists in `hooks/stop-chain-enforcer.sh`, in bash, where no copy can
  ever consume the constant — and this paragraph does NOT enumerate them, because the
  enumeration was wrong the day it was written.** It said "twice" and named the
  blocked-Stop `REASON` and the turn counter's refused-spawn notice, while the
  cap-release diagnosis carried a third, independently worded copy (`the remedy is the
  user's to apply and no agent may apply it for them, least of all by editing a
  settings file itself`) that meets this section's own membership test — a remedy
  string EMITTED to a user. A maintainer working from that census would have reworded
  two sites and left the third stating the rule in a fourth form. So: **before
  rewording this bar, run `grep -n 'settings file' hooks/stop-chain-enforcer.sh` and
  judge every hit**, the same instruction this file gives for `zensu:code-reviewer`
  and `scv1_`. Two facts a grep cannot supply, and they are the reason the class is
  hard: two of the three bash copies are second person and match `SELF_PERMISSION_BAR`
  (`no agent may edit a settings file to widen its own permissions`) in neither person nor
  wording, while the cap-release copy is THIRD person like the constant and differs only in
  wording — so "neither person nor wording", which this paragraph asserted of all of them, is
  false for the very copy it exists to stop people missing; and
  `skills/doctor/SKILL.md` carries two further paraphrases beside the one place it
  pins the constant verbatim. Nothing pins any bash copy against anything. Never
  describe this sentence as having one source.
- **The deny-first caveat sentence is a SEVEN-member hand-copy class, pinned nowhere
  across its copies.** The seventh is `REVIEWER_SPAWN_DENY_FIRST` in
  `hooks/stop-chain-enforcer.sh`, interpolated into the implementing-turns refused-spawn
  notice — a remedy string EMITTED to a user, which is this paragraph's own membership
  test. It PARAPHRASES rather than sharing the trailing clause, so it cannot be caught by
  the three `grep -qF` pins below; `C27` in `tests/structure/test-impl-stop-counter.sh`
  now pins its distinguishing lead-in instead, which makes it the SIXTH member with a pin —
  read that against this bullet's own closing sentence, which says five of the six original
  members are caught by something and `unjudgeableRow` alone is the copy nothing catches. That
  sentence still holds; the class is now six-of-seven pinned, with `unjudgeableRow` still the
  sole unpinned copy. The count below was SIX and stale on the day the constant landed —
  corrected here rather than in a later round, because the same commit updated the
  adjacent `SELF_PERMISSION_BAR` census and left this one alone.
  The original six, unchanged: `DENY_FIRST_CAVEAT` in `hooks/lib/zensu-doctor-report.js`
  is consumed by the ask row, the exposure row and the `auto-exposure-granted` row; the reactive row in the SAME
  file spells its own lead-in and shares only the trailing clause; `DENIAL_REMEDY`
  in `hooks/stop-chain-enforcer.sh` is a third; `skills/doctor/SKILL.md`'s
  refused-spawn bullet is a fourth; and `unjudgeableRow` in the renderer is a
  FIFTH, which states the same deny-before-allow precedence in its own words and
  deliberately does NOT consume the constant — that row tells the reader to go and
  READ the entry, while `DENY_FIRST_CAVEAT` tells them to REMOVE a deny, so reusing
  it verbatim there would give the wrong instruction. A SIXTH member is the deny row itself,
  which says "Deny is evaluated before ask and allow" and "while it stands, adding a
  permissions.allow rule for this spawn changes nothing" in its own words and consumes only
  `SELF_PERMISSION_BAR`.
  **State the base or the count means nothing.** The six MEMBERS are: the constant itself,
  the reactive row, `DENIAL_REMEDY`, the SKILL.md refused-spawn bullet, `unjudgeableRow`, and
  the deny row. THREE of them carry the trailing clause VERBATIM — the constant, the reactive
  row and `DENIAL_REMEDY` — and a fourth, the SKILL.md bullet, carries its first half verbatim.
  That verbatim sharing is exactly what makes the three `grep -qF` pins possible; a genuine
  paraphrase could not be pinned that way. Only the deny row and `unjudgeableRow` paraphrase it — but the
  deny row is nonetheless PINNED, by its own clause: `P1bv` and `P1bm3` match
  `Deny is evaluated before ask and allow` literally. So five of the six are caught by
  something, and `unjudgeableRow` alone is the copy nothing catches; it is the one to check
  by hand after any reword. The ask row, the exposure row and the
  `auto-exposure-granted` row CONSUME the constant — THREE consumers since the reviewer-spawn
  grant landed — which keeps them out of the drift class entirely: consumers, not members. The
  renderer's own comment beside the constant counts the same class as FIVE BESIDES the
  constant, which is the same six; keep both numbers and both bases, and do not "fix" one
  into the other. The criterion needs a real discriminator, not a blanket exclusion: a member
  is a remedy string EMITTED to a user, plus the one skill bullet that STANDS IN for such a
  string — the refused-spawn bullet, which relays the reactive row's remedy in its own words.
  The proactive-row bullets in `skills/doctor/SKILL.md` also restate the precedence and stay
  excluded, but state the test precisely, because two of them DO re-author a sentence: the
  could-not-judge bullet and the unreadable-entry bullet write their own remedy in their own
  words. They are excluded because each accompanies a row whose wording the model is sent to
  read, so a reword of that row is what a maintainer notices; the refused-spawn bullet is a
  member because it stands in for a string the model never sees rendered. `docs/tdd-manager-workflow.md` is
  narrative and outside the class. Without that discriminator the class grows until it stops
  being checkable, which is what an earlier wording of this paragraph did. P1be and P1qr each pin a doctor copy against
  the skill, and the routing suite pins the enforcer copy against itself — nothing
  pins the doctor and the enforcer against each other. Reword one and the others
  go stale with every check green; check them by hand, as with `WRAP` above.
- **That proactive check's PORT half is not this module's.** A port that renames
  only the literals still ships a wrong check: the branch LADDER in
  `permissionExposureLadder` encodes the deny -> ask -> allow precedence, so a host
  that orders them differently needs the ladder reordered, not the strings renamed.
  The wrapper is TWO functions, not one, and a port that copies only the outer name
  ships half of it: `permissionExposureRows` contains the throw so a fault costs one
  row instead of the whole report, and `permissionExposureRowsInner` turns the
  ladder's silence into a statement — the ✅ row when the check ran and found nothing,
  a did-not-run row when `HOME` is unset. The split exists so the row-counting seam
  sits INSIDE the try; collapsing them would put the counter outside the containment. Counting emitted rows rather than threading a flag through
  the ladder's exits is deliberate: a branch added later cannot forget to close itself
  out. A port that copies the ladder without the wrapper ships the silence back.
  A host with no per-user permission-rule file at all DROPS the check rather than
  repointing it — there is nothing to read. The accounts a port also owns are
  `skills/doctor/SKILL.md`'s `⚠️`/`✅ permissions:` bullets and its green-summary bound,
  `docs/tdd-manager-workflow.md` §"The proactive counterpart", and the bullet above.
  P1bh requires every suite that NAMES either doctor file to sandbox HOME or to
  carry an explicit `# zensu-doctor-home-exempt:` sentence — deliberately blunt,
  because its first version tried to recognise an execution and missed the one
  suite that binds the path to a variable and runs it six hundred lines later.
  The renderer reads HOME for both the user-scoped config and the settings file,
  so a suite without one is environment-dependent. P1bi separately requires every
  settings key the ladder reads to be shape-vetted, which is the coupling that
  reopens the original defect if it drifts.
  **The proactive ladder is now decision-then-text, and the two halves must move
  together**: `classifyPermissionExposure` answers WHICH verdicts hold — in emission
  order, as a LIST, so the fact that the auto-mode verdict and the `autoMode.allow`
  verdict can both hold is visible in the return value instead of asserted in prose —
  and `ROW_TEXT` is the only place a row is worded. Adding a row means adding a kind to
  both; neither half can grow a branch the other does not know about. `P1bd2` slices
  `classifyPermissionExposure` (not the ladder) to derive the deny/ask/allow order, so
  moving the decision to another function makes that pin report an underivable order
  rather than passing vacuously.
  **The check has an off-switch, and it is a boolean, never a path override**:
  `hooks.reviewerSpawnPermissionCheck` (default `true`), read from the SAME `cfgReads`
  the Config block already gathered — a second `readJson` pass would double the
  non-blocking opens the FIFO hardening exists for. It suppresses the ROW and can never
  redirect which file is opened, which is what keeps `claudeSettingsFile`'s refusal of a
  `ZDOC_`/`ZENSU_` override intact: that argument is about INJECTION and it still holds,
  while this closes the SUPPRESSION complaint it never answered. **Disabling does not
  produce silence** — it emits one ✅ row naming the flag and saying the check was
  skipped, because silence is the one verdict this check cannot qualify and hiding the
  rows under a config key would reinstate the defect the feature removed. `P1bz`/`P1bz1`
  pin both halves and `P1bz2` pins that a quoted `"false"` does not disable it.
  **The proactive ladder has no unit seam**: this renderer exports nothing and
  ends in `process.exit(0)`, so `settingsShape`, the rule predicates
  (`matchesDenyOrAskRule` and `matchesAllowRule` — deliberately TWO named predicates and
  not one boolean-flag predicate, because the flag named the input while it decided the
  trim behaviour, so no call site said which side of the asymmetry it meant — plus
  `namesReviewerSpawn`, `mentionsReviewerAgent`, `hasUnreadableEntry`), the shared
  `isVerifiedSpelling` test that every exact-match arm consults instead of re-spelling it,
  the combinator `reviewerSpawnMention` over the deny/ask pair, and the
  branch ladder are pinned only behaviorally, by shell fixtures. `reviewerSpawnMention` is
  not a further predicate — it is a reduction over two lists — but it encodes a rule neither
  the predicates nor the ladder carry: `'named'` outranks `'shaped'` ACROSS the deny and ask
  lists, and `namesReviewerSpawn` must scan its whole list rather than return at the first
  match, or the precedence silently becomes positional WITHIN a list. A port that copies
  only the predicates renders the weaker row for a list that really does name the reviewer. Two of those fixtures reach their branch through a `node --require`
  preload rather than through a settings file, because neither a short read nor a
  throw inside the check is producible from file content alone (P1bp, P1bs).
  `settingsShape` returns TWO deferred carriers, not one: each row is suppressed only
  by a malformed key its own claim depends on. Collapsing them back into one carrier
  restores the defect where a malformed `autoMode.allow` deleted the exposure row. Extracting a
  pure classifier into a `*-v1.js` module would buy one, at the cost of a lazy
  require, a degraded-row fixture and a `node --test` driver charged to a named
  Windows shard budget. Deliberately not done; recorded so it is not mistaken for
  an oversight.
- **The unit suite needs a driver.** `tests/run-all.sh` discovers only
  `tests/structure/test-*.sh`, so `tests/structure/reviewer-spawn-denial-v1.test.js`
  is invoked from `test-stop-enforcer-self-review-routing.sh` (T26, which asserts a
  case-count floor because exit 0 also accepts a file registering zero cases). A new
  `*.test.js` with no driver is never executed by the tree runner. That driver
  charges the unit suite's runtime to this shard's Windows budget
  (`tests/profiles/windows-ci.v1.json`, `stop-enforcer-self-review-routing`), where
  a `TIMED_OUT` means the tail of the file never ran. The driver therefore runs
  FIRST in that file, before any scenario: it needs only `PLUGIN_DIR` and
  `STATE_DIR`, and at the tail a timeout cost the whole unit suite — the only
  coverage the scanner's own properties have anywhere.
- **The note is only this plugin's word when a session backs it.** `reviewerDenialRows`
  requires `tdd-phase-<same key>.json` beside the note before counting it. The state
  directory is writable from inside the session, so a note judged purely on its own
  contents would let anything able to write there mint a row telling the user to widen
  `permissions.allow` for the very spawn it wants. Change the workflow-document name and
  the binding silently stops matching; `P1qq` is the pin.
- **One fixture is a real host capture, and it is the only one that can falsify the
  hand-authored envelopes.** `tests/structure/fixtures/reviewer-spawn-denied-transcript.v1.jsonl`
  is a redaction of two entries taken verbatim out of a Claude Code 2.1.237 session whose
  `zensu:code-reviewer` spawns the classifier refused: the `tool_use`/`tool_result` pair,
  `is_error`, the full refusal body and `toolDenialKind` are the original bytes; the
  prompt, ids, cwd and branch are placeholders. Every other transcript in both suites is
  written by this repo and therefore pins only what this repo BELIEVES the host emits.
  Driven at the unit layer (four cases, including a shape guard so a gutted redaction
  fails loudly) and end-to-end by T36/T36a, which sit beside scenario 7 rather than at
  the tail for the Windows-budget reason below. Like
  `fixtures/exitplanmode-posttooluse-payload.v1.json`, it CANNOT observe live harness
  drift — only a fresh capture can.

**The Windows budget for this suite is MEASURED, and the measurement is a RANGE.**
Two green runs of byte-identical suite content reported `stop-enforcer-self-review-routing`
at **985846 ms** and **1274496 ms** — a 29% spread on the same GitHub runner class, so a
single sample here says nothing about headroom. Budget against the HIGH figure: at
`timeoutMs: 1500000` in `tests/profiles/windows-ci.v1.json` the slow run consumes 85% of
its own cap. The previous ceiling of 1200000 sat BELOW that high sample and the suite
was killed by it, which is exactly the failure this range exists to prevent.
**That range no longer covers the file.** Scenario 7b (T36/T36a, the real-host capture)
added a session and a Stop after the range was taken, and the T38-T59 scope-sentence block
added a second post-range increment on top of that — one further session and two further
`bash "$STOP"` invocations in T59, plus roughly twenty source and behavioural checks. The
ceiling was NOT raised for either: 85% of cap was already the slow sample's share, and this
file's own rule is that a ceiling comes from a green wall clock and never from an estimate.

**IT WAS RE-MEASURED, AND IT HAD ALREADY GONE RED — the ceiling HAS since been raised, so
the paragraph above is history rather than current state.** It said to re-measure if the
shard ever reported `TIMED_OUT`; it did, on more than one branch. The cap sat AT the
measurement — the error the shard-8 note in `windows-ci-contract.test.js` ends by naming —
so `main` itself was a coin flip on every run rather than a suite under test being at
fault. Two things changed together: `review-worker-evidence-lease` MOVED to
`windows-shard-8`, leaving this suite ALONE on shard 7 with the shard's whole envelope, and
the cap rose. **The NUMBERS live in that contract-test note and are deliberately not copied
here**, for the reason this file gives about `MAX_BLOCK` and about the architecture doc's
KB totals: a prose copy of a measurement goes stale silently, and the note carries the run
ids, the measured wall clocks and the arithmetic together.

**KNOWN RESIDUAL, and it is the reason this is a mitigation rather than a fix:** the raise
does not absorb the 29% spread recorded above, and at this suite's current size no cap
inside the shard envelope can — the envelope itself is smaller than the spread's upper end.
The raise cannot go further without moving `timeout-minutes` and every profile's
`profileTimeoutMs` together. The durable answer is to find why this suite needs 25 minutes
on Windows, and until then, treat a `TIMED_OUT` here as the suite outgrowing its shard
rather than as a defect in whatever change happened to be under test — and expect the cap
to bind again.

**The shard budget is the SECOND ceiling, and it binds first.** `windows-shard-7`'s
`profileTimeoutMs` is 1800000 and every profile is pinned to that same value
(`windows-ci-contract.test.js`), which is itself pinned against the job's
`timeout-minutes: 35`. A suite therefore never receives its configured `timeoutMs` — it
receives `profileTimeoutMs` MINUS everything its shard already spent. When
`autopilot-state-machine` (554832 ms) still shared this shard, the routing suite started
with 1138363 ms and died there while its own cap read 1200000 ms, so raising the cap
alone would have changed nothing. Do NOT read a suite's `timeoutMs` as its deadline;
read the shard's remaining budget. Note also that summing a shard's `timeoutMs` values
and comparing that to `profileTimeoutMs` proves nothing — EVERY shard exceeds it by
design, because the per-suite values are individual caps and not a shared budget.

**Three conditions decide a refusal, and no one of them is sufficient.** (1) the
`tool_result` is keyed by `tool_use_id` to an `Agent`/`Task` call whose
`subagent_type` is the reviewer; (2) the host's own `is_error === true`; (3) the
result text STARTS with a marker. Keying alone was the original design and it was
wrong: for an `Agent` call the tool_result body IS the subagent's returned message,
so a reviewer that merely quotes a denial literal — reviewing this module, for
instance — was read as a refusal and the chain was abandoned with a real review in
hand. **It is a diagnostic, never a gate:** an unreadable transcript, an absent
`transcript_path`, or a missing module must leave every existing routing decision
byte-identical, which is what T19 pins.

**The only terminus the denial branch teaches is the zero-change one.** In its
STANDALONE spelling that command verifies its own claim and refuses while any file
is changed, so a chain with real changes cannot be closed there — that would claim a
review that never ran, and the branch says so. The Autopilot-BOUND spelling carries
`--outcome no-changes` into the durable receipt and performs no worktree check at
all; that is pre-existing in `zensu-log.sh` and is restated as a known gap below,
because this branch is what promotes the command to the only exit on offer. It also does NOT disclose the Stop cap count:
a number plus "stop acting" is a wait-it-out recipe. Do not "fix" a wedge here by
teaching an unqualified `--chain-done`.

**The note must never outlive the chain it describes.** Every path that releases
Stop without routing the inner chain retires it, because after such a release this
session's Stop never reaches the routing branches again and nothing else can remove
a note keyed to its session: the three terminal early exits (no active session,
implementation not complete, chain closed) — and note that the MIDDLE one is now also a
WRITE site, because it clears and then runs `zensu_impl_stop_nudge`, which re-mints when
that Stop reaches its refused-spawn branch — both inner-guard escapes
(`ZENSU_CHAIN=off`, `hooks.chainEnforcer=false`), every release in the Autopilot
escape branch, and the BLOCKED-outer release that owns the current inner
generation — plus the cap path once the chain has converged, and the writing path
itself on a `clear` verdict. Treat that as the rule, not the list: a NEW release
path added above the routing branches needs the same call. T23/T29/T30/T31/T32 pin
the ones reachable from the routing suite. The Autopilot-escape sites need a
durable run, which that suite never builds, so their pins live in
`tests/structure/test-autopilot-stop-enforcer.sh` instead: S14 covers the
terminal-stage escape and S15 the audited one, which are different lines. The
BLOCKED-outer release remains unpinned.
An `errored` verdict retires NOTHING, deliberately: it means the module could not
tell whether the spawn was refused, and clearing on it would delete a correct
diagnosis whenever a retry died of something else.

**THREE sites mint a note, not two.** The routing site guarded by `REVIEWER_DENIAL_ROUTED`, the
cap-release site guarded by hand with `tdd_code_review_done`, and — added by the
implementing-turns counter — `zensu_impl_stop_nudge`'s refused-spawn branch, whose guard is
STRUCTURAL rather than a test: it runs only from the `SESSION_IMPL_COMPLETE != "true"` exit, and
a chain whose implementation is not complete has no review to have converged. A caller added
elsewhere breaks that silently, which is why the guard is named here rather than left to be
inferred from a call position.

**A converged chain must never mint a note — and must not inherit one either.**
The self-review branch retires any note first, because a refusal EARLIER in the
same session is stale the moment a spawn succeeds, and that branch never consults
the probe, so nothing below it would clear one. BOTH write sites enforce the
minting half separately. The routing site is guarded by `REVIEWER_DENIAL_ROUTED`, a
flag both arms of the routing ladder set and the self-review branch never does.
Testing the probe's STATUS there instead would test "some branch happened to consult
the probe" — true today only because one branch can, so a probe call added anywhere
above for an unrelated message would silently start minting notes on the converged
path with every check still green. The
cap-release site sits ABOVE that branch and does consult the probe, so it is guarded
by `tdd_code_review_done` by hand: a model that re-spawns the reviewer against the
self-review directive and has THAT refused would otherwise leave doctor reporting
"no review ran" for a chain that had already converged. A session that never Stops
again still cannot clear its own note, so `reviewerDenialRows` ages one out against
the same TTL `pending-review.json` uses — in BOTH directions, since a timestamp in
the future yields a negative age that never crosses the bound. T23/T27/T29 and
P1qg/P1qm/P1qn/P1qo are the pins.

**The TTL suppresses the row; `reviewer_denial_notes_reap` removes the file.** The
clear path sweeps two sets, and it is the ONE place a Stop unlinks a file owned by
another session — which is why the name is matched against the same
character-exact shape the writer asserts, never a prefix.

- **Unbound** — no `tdd-phase-<key>.json` beside it. `reviewerDenialRows` already
  refuses to count these, so removing one destroys no diagnosis anyone reads.
- **Past the TTL** — read from the same config key the doctor ages against
  (`zensu_pending_review_ttl_hours`), and `0` DISABLES it on both sides. This is
  the set that matters: the unbound check alone is nearly inert, because
  SessionStart writes a baseline workflow document for every session, so the
  session whose note outlives it still HAS one. Without the age arm the sweep
  would only ever catch a document somebody deleted by hand.

An unreadable or unparseable note is deliberately NOT reaped. The doctor reports
it as a note this plugin did not write and tells the user to delete it; unlinking
it here would silently destroy a file this plugin does not own. The doctor stays
read-only by contract — the reaping lives in the hook, under the same lease as
every other write to that directory. T35 is the pin, and it plants a LIVE
neighbour alongside the two dead files precisely because a sweep that deleted
every note it could name would satisfy a one-sided check.

**Anything spawned inside the lease must redirect stdin, not only its output.**
The keeper is a bash coprocess and its control channel is a pipe; a child that
inherits those descriptors holds the write end open after the parent closes it,
so the keeper never sees EOF and the release hangs. The reaper's node process
needs `</dev/null` for that reason alone. The failure does not look like a
deadlock from the outside — it surfaces as unrelated checks failing two scenarios
later, because the Stop that held the lease finished in a degraded state. Cheap to
prevent, expensive to diagnose.

**Both halves of the note run under the workflow document's external lease.** It
was the only artifact in `.zensu/state/` written with none, and its two halves are
an unlink and a rename, so a clear could remove a note a concurrent write had just
published. `reviewer_note_locked` wraps both. The lease is an IMPROVEMENT, never a
precondition — on failure the operation still runs unlocked, because failing to
write the note must not change the Stop decision. That fallback is only sound while
both callbacks ALWAYS return 0, which is what makes a non-zero result unambiguously
a lease failure rather than a failed operation; give either one a meaningful exit
status and a failed write starts running twice. The probe runs BEFORE the lease is
taken: it reads a host-supplied transcript with no deadline above it, and holding
this directory's lease across that read would make every other writer wait on it.
The nested clear inside the writer therefore calls the UNLOCKED spelling — the
lease is not reentrant.

**The note path is anchored on `PROJECT_ROOT`, never on `TDD_STATE_DIR`.** That
variable is a retired ambient root the repo pins as non-authoritative. The reader
resolves the directory from the RECORD's project root (`stateProjectRoot`, see
§"Foreign-Chain Row"), which is the same root the writer's `zensu_resolve_project_dir`
yields — they agree by construction. Honoring an override would write the note where
`/zensu:doctor` never looks and aim an unlink outside the session-bound directory.

**The note's shape-and-freshness judgement now has TWO consumers and ONE implementation.**
`classifyDenialNote` (verdict `live|stale|rejected|missing`) and `denialKindsAllowed` in
`hooks/lib/zensu-doctor-report.js` were EXTRACTED from `reviewerDenialRows` when
§"Implementing-Phase Turn Counter" needed the same predicate to decide whether its chain row
carries a refusal caveat; `ownRefusalNoteLive` is NOT an extraction but a new second consumer
built on them, so the pre-existing `reviewerDenialRows` pins do not cover it — its only coverage
is `C35pre`/`C35`/`C35s`/`C35r` in `tests/structure/test-impl-stop-counter.sh`. A change to the note schema therefore
reaches a row in a different feature; the verdict is a WORD rather than a boolean precisely so
the counting consumer keeps its three buckets while the qualifying one tests for `live`.

**Both sides of the note treat it as untrusted.** The session can write that
directory, so the writer refuses a symlink, a non-file or a hard link and lands an
`O_EXCL` temp file by rename; the reader decides shape before opening, caps the size,
and counts a note as a refusal ONLY when it parses with `schemaVersion === 1`, a
`kind` the writer itself issues, and a finite timestamp. Anything else is reported as
a note this plugin did not write — never as a refusal, because a planted empty file
would otherwise manufacture a row telling the user to widen permissions. The one
deliberate exception: a plugin root that cannot load the module cannot vet the kind,
and there the row still renders with the kind degraded to `unknown` (P1qf) — losing
the label is acceptable, losing the finding is not.

**The model-facing reason names only `~/.claude/settings.json`.** The project-local
`.claude/settings.local.json` is a path the agent itself can write, and naming it
beside the exact rule that grants the refused capability is an invitation that prose
alone would have to talk it out of. The `/zensu:doctor` row withholds it for the SAME
reason — that row is read by the model too, so "user-facing" does not make it safe.
Only the docs carry the fuller form.

**Operator-facing accounts that must move with the markers, the block reason, and
the note:** the host-refusal paragraph in `docs/tdd-manager-workflow.md`, the
refused-spawn row in `skills/doctor/SKILL.md`, and the `stop-chain-enforcer.sh` row
in `docs/configuration.md`. The PROACTIVE check has three of its own, listed here
so a maintainer navigating by this paragraph reaches them: §"The proactive
counterpart, before any chain wedges" in `docs/tdd-manager-workflow.md`, the
`⚠️`/`✅ permissions:` bullets plus the green-summary bound in `skills/doctor/SKILL.md`,
and the two bullets above.

**Port-relevant.** The PROACTIVE check has its own port half, stated in the two
bullets above and NOT covered by this paragraph: `permissionExposureRows`,
`permissionExposureRowsInner` and `SETTINGS_SOURCE_BUILD` in
`hooks/lib/zensu-doctor-report.js`, the `permissions.*` / `autoMode.allow` grammar,
the `Task` / `Task(` spellings the low-claim predicate admits WITHOUT verification
against `SETTINGS_SOURCE_BUILD`, `reviewerSpawnMention` and its cross-list precedence, the single `~/.claude/settings.json` path, and — the
two a literal-renaming port misses — the branch ladder, which encodes the
deny -> ask -> allow precedence in code rather than in a string, and `FATAL_RULE_KEYS`,
whose membership is DERIVED from that same order, so a port that reorders the ladder and
leaves the constant alone ships a wrong fatal/deferred split.

**The Config block carries its own host-coupled claim, and it is NOT the settings ladder's.**
`readJson`'s three flags — `io`, `cap`, `loaderFallback` — encode facts about THIS host's config
loader, `rd()` in `hooks/lib/zensu-config.sh`: that an open or read error makes it return `{}`,
that it has no size limit, and that it MERGES a global with a project file so a broken overlay
does not fall back to defaults. Two rows state those facts to the user verbatim. A port whose
loader caps size, aborts instead of falling back, or reads a single file would ship both
sentences as false verdicts with every check green — the same failure class
`SETTINGS_SOURCE_BUILD` exists to prevent, one block over. Re-decide the three flags against the
port's own loader, or drop the Config block's loader claims entirely.

**Known gap in the Config block, accepted and recorded.** The `soleSource` axis is present-ness,
not effectiveness: when BOTH default config files exist and both degrade to `{}`, each failure row
says "the other config source still applies" while defaults actually apply. Not a regression — the
predicate that preceded it was wrong in that case too — and self-limiting, because a row prints for
each broken file. Closing it means counting entries that are present AND not `loaderFallback`.
For the REACTIVE module below, every constant here is host-coupled: a port copies
`DENIAL_MARKERS`, `SPAWN_TOOL_NAMES` and the transcript envelope
(`message.content[]`, `tool_use`/`tool_result`, `tool_use_id`, `input.subagent_type`,
`is_error`) into its own file and re-decides them against its harness — a port that
takes only the module inherits Claude Code's literals and will silently never fire.
The host half — which payload field carries the transcript, where the note lives, and
the doctor row — is re-decided per host. `scanTranscript(path, options)` takes
`subagentType` so a host with a different reviewer name needs no fork of the walk.

**Known gaps, accepted and deliberate:**

- **The whole diagnosis is inert on an installation that predates it, and that is the
  first thing to check before suspecting the scanner.** The probe's
  `[ -f "$lib" ] && [ ! -L "$lib" ] || return 0` returns before `node` is ever invoked,
  leaving the verdict `none` and routing byte-identical — the correct fail-open
  direction for a diagnostic, and indistinguishable from "no refusal happened". The
  module first shipped in **v0.18.2**; a session on 0.18.1 or earlier gets the ordinary
  `Resume the /zensu:tdd Phase 6 review sequence` directive on every Stop until the cap
  releases, and `/zensu:doctor` stays silent because no note is ever minted. Measured
  2026-08-22: three classifier-refused `zensu:code-reviewer` spawns, seven Stop
  interceptions, zero notes — and the shipped scanner run against that same transcript
  afterwards answered `status=blocked kind=auto-mode-classifier spawns=3 denials=3`. The
  detection was never wrong; the code was not installed. Nothing surfaces the version
  skew, so diagnose it by checking whether the executing plugin root actually contains
  `hooks/lib/reviewer-spawn-denial-v1.js` before touching the marker set. T36b pins the
  guard and its position ahead of the invocation.
- **The "one further attempt" sanction can be re-offered.** Its withdrawal keys on
  `REVIEWER_DENIALS >= 2`, and that count is computed over the scanned transcript tail
  (`MAX_TAIL_BYTES` / `MAX_LINES`), not over durable state — so in a long enough session
  two earlier refusals scroll out of the window and the arm sanctions a retry again.
  Closing it means carrying the count in per-session state. The code comment beside the
  arm in `stop-chain-enforcer.sh` and the `**Known gap:**` clause in
  `docs/tdd-manager-workflow.md`'s host-refusal paragraph are the other two carriers.
- The verdict has no chain-generation lower bound. After a cap release and a fresh
  `/zensu:tdd`, the newest reviewer result in the transcript is still the old refusal,
  so the branch fires again before any new spawn is attempted. The reason text handles
  it by sanctioning exactly ONE further attempt when the user says they applied the
  rule; a generation bound (an arming ordinal in `options`) is the real fix and is not
  implemented. **Why it is not a cheap fix, measured rather than assumed:** the
  transcript DOES carry a per-entry `timestamp`, but the workflow document carries
  nothing to compare it against. `_tdd_begin_session_critical` writes no history
  entry, and `history[].ts` is optional and stays EMPTY in vanilla mode, where the
  RED/GREEN FSM is never driven — so there is no reliable "when did this generation
  arm" instant to bound the scan with. Supplying one means a new workflow-state
  field, which under the runtime-lineage rule above is a schema change and therefore
  a MINOR release. That price buys the removal of a misroute which is bounded to a
  single Stop and self-corrects as soon as one spawn is attempted, which is exactly
  what the reason text already asks for. Re-decide it when a schema change lands for
  another reason and the field can travel with it.
- The zero-change terminus this branch offers is worktree-verified only in its
  STANDALONE spelling. An Autopilot-bound chain routes `--outcome no-changes` through
  `autopilot_finish_tdd_attempt`, which never reads the worktree. That is pre-existing
  — the untouched ordinary branch offers the same command — but this branch is the one
  that tells the model the spawn cannot succeed, which promotes it to the only exit on
  offer. Closing that gap belongs in `zensu-log.sh`, not here.
- A denial note is keyed to its own session, so no other session can retire it
  through the ordinary clear path. `reviewer_denial_notes_reap` is the deliberate
  exception and the only one: any Stop in that project removes a note that is
  unbound or past the TTL, which is what bounds a note whose session is gone for
  good. The row it would have rendered was already suppressed by the same TTL, so
  the sweep changes which files exist, never which findings are reported.

## Reviewer-Spawn Grant (`hooks/pre-agent-reviewer-allow.sh` + `reviewer-spawn-allow-v1.js`)

The preventive half of the section above. That one DIAGNOSES a classifier refusal after the
spawn is already lost; this one keeps the refusal from happening, by returning
`permissionDecision: "allow"` on the `Agent|Task` matcher for Zensu's own confined reviewers.

**The mechanism is MEASURED, and the measurement is what makes the feature real.** Two headless
`--permission-mode auto` runs of one prompt in an isolated directory, against Claude Code
**2.1.245**: without the hook the debug log records `classifier_request_started … tool=Agent`;
with it there is no classifier request for `tool=Agent` at all, only
`Hook result has permissionBehavior=allow` then
`Hook approved tool use for Agent, bypassing permission prompt`. The build is recorded in
`ALLOW_BYPASS_SOURCE_BUILD` and cross-checked against the module header by the unit suite, for
the same reason `DENIAL_MARKERS_SOURCE_BUILD` exists. **Re-verify against the binary, never
against memory:** a host that reorders its pipeline turns this module into a silent no-op —
the fail-open direction, but the wedge comes back.

**A plugin cannot ship a permission rule, which is why this is a hook at all.** The plugin
component surface is `commands`, `agents`, `skills`, `hooks`, `mcpServers`, `lspServers`; there
is no `permissions` key. Do not propose one.

**THE SET IS DERIVED, NEVER SPELLED**, and that is the single most important property to keep.
It is `claude-principal-v1.js`'s `REVIEWER_TYPES` ∪ `EVIDENCE_WORKER_TYPES` — the same
classifier `SubagentStart` uses to inject `reviewer-readonly-v1` — restricted to the
plugin-scoped `zensu:` spellings. Adding a confined agent there reaches this grant with no edit
here, and CLAUDE.md's standing "grep before renaming `zensu:code-reviewer`" instruction keeps
holding. **One narrowing is deliberate and load-bearing:** `REVIEWER_TYPES` also carries the
BARE names (`code-reviewer`, …) so `--agents` fixtures and same-named PROJECT agents get the
read-only principal. Those are not our files — a project may define `code-reviewer` with
`tools: Bash`, and the principal classification is prompt-level policy while `tools:`
frontmatter is what the harness enforces. Granting a bare name would hand a project-authored
agent a classifier-free spawn. **That scope reservation is an UNVERIFIED premise** — nothing in
the tree measures whether the host reserves `zensu:` to the plugin, while the bypass itself is
measured and pinned. `zensu:zensu-plm` is excluded for the STRUCTURAL reason only: `PLM_TYPES`
is a separate classification returning `HOST` and is never fed to `pluginScoped`. Do not restate
that as "no `tools:` line" — `agents/zensu-plm.md` declares `tools: Read, Grep, Glob`, so that
reason is false and its natural repair is to widen the set.

**THE HOOK CAN ONLY GRANT OR STAY SILENT**, and every failure path is a silent `exit 0` — the
OPPOSITE of the fail-closed direction every other gate takes. A non-zero exit from a PreToolUse
hook BLOCKS the call, so a fail-closed grant hook would break every Agent spawn in the session,
including the reviewer it exists to admit. Even the inherited-plugin-root mismatch, which every
sibling hook answers with `exit 2`, reports on stderr and then declines. `A16` pins that the
hook always exits 0; do not "harden" it into a gate.

**Four conditions, all required:** main principal, a bound Session Control record,
`hooks.reviewerSpawnAutoAllow` not exactly `false`, and set membership. **The armed-chain
condition was specified and then REJECTED on discovery** — `plan-review-worker` and
`pr-review-worker` are spawned by `/zensu:plan-review` and `/zensu:pr-team-review`, neither of
which arms a TDD chain or calls `--workflow-begin`, so a chain condition would ship a grant
missing two of the five. The lease alternative was rejected too: the lease is minted by skill
prose the gate cannot verify, and this file already records that module's store layout as a
repeated drift source. What bounds the risk is CONFINEMENT, not chain state — the grant admits
a SPAWN, and the child's own tool calls are permission-checked separately.

**Three host limits, none of them a defect to be fixed by widening the grant:** a
`permissions.deny` or `permissions.ask` rule still overrides it; another hook on the same
matcher returning deny or ask outranks it (the host ranks deny > ask > allow across all hooks
on a matcher); and an SDK session supplying `canUseTool` (`requireCanUseTool`) forces the full
pipeline. Headless `-p` does NOT set that flag. The first limit is why the doctor's proactive
deny and ask rows STAY, and why the granted row still carries `DENY_FIRST_CAVEAT`.

**Disclosure is not optional, because this is a capability the plugin hands ITSELF.** Two
surfaces, deliberately unequal: the SessionStart banner line is silenceable by
`hooks.sessionBanner`, the `/zensu:doctor` row is not silenceable by the grant's own flag and
renders in BOTH states. Same reasoning as `reviewerSpawnPermissionCheck` — hiding the rows
under the config key would reinstate the defect the feature removes.

**The doctor coupling has a sharp edge that cost ten green checks once.** A row that warns
whenever the decision module cannot be loaded fires on every plugin root that PREDATES this
feature, which is most doctor fixtures. The rule is asymmetric: an absent HOOK means the
feature is not installed — silent, and the ordinary exposure rows already give that reader the
right advice; hook present but module missing IS worth a row, because the hook then declines
silently while the banner says a grant is in force. `reviewerSpawnGrantRows` RETURNS the
resolved grant state and `configBlock` threads it into `permissionExposureRows`, because the
auto-mode advice is only correct when the grant is not already covering the spawn it
recommends a rule for. That thread introduced `ROW_LEVEL`, a THIRD map beside
`classifyPermissionExposure` and `ROW_TEXT` — the two-map rule in the section above now has an
exception, and a kind missing from `ROW_LEVEL` is a warning.

**Version.** The hook can GRANT, so it is NOT the advisory shape the hook-inventory exemption
covers under "Runtime Lineage (`version_type` is load-bearing)" — it changes the capability set
of every session an older runtime is still serving, exactly as a matcher change does. This is a
**`minor`** release. The config key alone would have been a `patch`; the hook is what decides it.

Moving together: `hooks/pre-agent-reviewer-allow.sh`, `hooks/lib/reviewer-spawn-allow-v1.js`,
the `Agent|Task` entry in `hooks/hooks.json`, `reviewerSpawnAutoAllowDisabled` /
`reviewerSpawnHookWired` / `reviewerSpawnGrantRows` / `ROW_LEVEL` / the
`auto-exposure-granted` verdict AND the `grantActive` conjunct on the `automode-prose` branch
in `hooks/lib/zensu-doctor-report.js`, `zensu_hook_enabled_strict` in
`hooks/lib/zensu-config.sh`, the banner line in `hooks/session-start-banner.sh`, and the
`reviewerSpawnAutoAllow` entry in `config.example.json` — that file is advertised as carrying
every flag and five sibling suites pin their own there. **The tool-name domain is a THIRD
coupling:** `SPAWN_TOOL_NAMES` is imported from `reviewer-spawn-denial-v1.js` and re-encoded as
the `hooks.json` matcher, so a member added in that module without widening the matcher leaves
the grant inert for that tool with every check green.
Operator-facing accounts: `docs/gates.md` §"Reviewer-Spawn Grant", the hook row and the
`reviewerSpawnAutoAllow` row in `docs/configuration.md` — plus, in that SAME file, the
`### Hooks (N)` header, the prose count and its `#hooks-N` link, and separately the
`configuration.md#hooks-N` cross-link in `docs/architecture.md`. `test-readme-hook-count-sync`
H2 turns red on the header count and H3 on any inconsistent reference; `docs/architecture.md`
was outside H3's file list until this change added it, so that cross-link was the one
occurrence nothing scanned, `docs/tdd-manager-workflow.md` §"The preventive layer", and the
reviewer-spawn bullets in `skills/doctor/SKILL.md` — do not restate a COUNT here, because the
next row added invalidates it; `A24` in `test-reviewer-spawn-allow.sh` is what holds the roster
against the renderer, and its phrase list is the thing to extend when a row is added.
**Bullet ORDER in that skill is load-bearing:** `P1bx`
resolves the FIRST `- **⚠️ permissions:` bullet and requires the deny-first clause in it, so a
new warning bullet placed above the exposure one fails that pin while naming the wrong drift.

**Known gaps, accepted and named:**

- **Only the plugin's own reviewers are covered.** Every other subagent type in the session is
  still classifier-subject, so a refusal there still reaches the reactive diagnosis above. The
  memory of this repo records the refusal as intermittent for EVERY subagent type; this feature
  narrows the blast radius, it does not remove the classifier.
- **The measurement is one host, one build, two runs.** It was taken with a throwaway `probe`
  agent rather than `zensu:code-reviewer`, and the classifier would have allowed that spawn
  anyway — what the runs prove is that the classifier is not CONSULTED, which is the claim that
  matters. No end-to-end run against a genuinely refused reviewer spawn exists.
- **Windows is unverified.** `tests/structure/test-reviewer-spawn-allow.sh` is deliberately NOT
  in `tests/profiles/windows-ci.v1.json`: every shard there is already close to its
  `profileTimeoutMs`, and adding a suite has to be paid for by moving another one off. Say
  "unverified", never "covered".
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included. A port
  owns BOTH halves: the module's derived set and its own host's answer to whether a hook allow
  precedes that host's permission layer at all — which is a measurement, not an assumption.
- **`reviewerSpawnGrantRows` both renders and returns**, so the grant state the exposure check
  consumes is a side effect of a render call and the ORDER of the two calls in `configBlock` is
  load-bearing. Reversing them yields `grantActive === undefined` and restores the wrong
  auto-mode advice. The sibling check in the same file models the alternative
  (`classifyPermissionExposure` decides, `ROW_TEXT` words), and splitting this one the same way
  is the standing fix. Left as is deliberately: the split would touch the one function three
  review findings had just corrected.
- **`ROW_LEVEL` could travel inside the verdict.** `classifyPermissionExposure` already returns
  per-verdict objects, so a `level` field would delete the third map and restore the two-map
  rule stated above it. A missing entry defaults to WARN, which is the safe direction, so this
  is design cost rather than a defect.
- **The banner is a WEAKER check than the doctor, by design and by wording.** It tests the flag
  and the two files; it does NOT verify registration or that the decision module loads. Its text
  names `/zensu:doctor` as the authoritative check for exactly that reason. A shared
  installed-ness predicate — a `--grant-state` mode on the decider that both surfaces call —
  is the uncompromised answer and is not implemented.
- **One review finding was REFUTED, recorded so it is not "fixed" later.** A round-2 reviewer
  reported that nothing derives the confinement check from the grant set, having grepped the
  shell suite only. `tests/structure/reviewer-spawn-allow-v1.test.js` does exactly that: it maps
  each member to `agents/<name>.md` and requires the exact read trio, so widening
  `REVIEWER_TYPES` with an unconfined agent fails there.

## Review-Spawn Scope Sentence (`ZENSU_REVIEW_SPAWN_IN_SCOPE`)

Some hosts inject a session rule telling the model not to spawn a subagent the user
did not ask for. On Claude Code 2.1.248 it arrives as the `heron_brook` prompt
section, whose built-in fallback a server-supplied `tengu_heron_brook` value replaces
wholesale. It is prompt-level steering, **not a gate** — no hook enforces it and no
bypass-ledger entry records it — and a model that reads it as a flat prohibition
withholds the very spawns the review chain is made of, silently, until the Stop cap
releases the guard. That is an observed session outcome, not a hypothesis.

**The sentence does NOT rule on that rule's scope, and two rejected drafts are why.**
The rule's condition is PROVENANCE — who asked — and a hook cannot observe it:
`plan-approved-delegate.sh` has a documented fast-path that arms the workflow
non-interactively with no human present, and the Stop enforcer itself arms an adopted
deferred-review generation, so on both paths the spawns genuinely ARE unrequested. The
first draft asserted the user had asked (false on both). The second asserted the rule
"is about ad-hoc fan-out", which swapped the rule's own criterion for one the plugin
can always satisfy — the same error one clause over. What ships states the observable
SHAPE and then ROUTES: withholding is allowed, but not silently, so the user decides.
Never re-open this by giving the plugin a verdict on a restraint it does not own.

**One owner, three render sites, one deliberate non-site.** The owner is
`hooks/lib/zensu-tdd-phase.sh` under its own `# --- Review-spawn scope sentence (shared directive text)` banner — NOT part of the bypass-ledger section it sits below, whose two message
constants have their own contract. It is rendered by `stop-chain-enforcer.sh`'s resume
directive and by BOTH severity arms of `post-review-tdd-delegate.sh`'s fix-round
directive. The host-refusal branch deliberately does not render it: **do not restate
that arm as user-gated** — it fires on `reviewer_spawn_denied`, the scanner's own
`blocked` verdict, with no user utterance involved. It is withheld because that branch
already tells the model the spawn CANNOT succeed, so a scope argument there would read
as pressure to work around a refusal.

**The render side is a closed ALLOWLIST, and the criterion is "can a refusal be RULED
OUT" — not "was one observed", and not "did the probe succeed".** The distinction is not
pedantic: it is the test a maintainer applies when the scanner gains a sixth status, and
an earlier revision of this paragraph got it wrong in the direction that would misclassify
one. `reviewer_spawn_denied` is true only for
`status=blocked`, so every other verdict reaches the resume branch, and the enforcer
records the probe's OWN word in `REVIEWER_DENIAL_RAW` beside the routing status. The
allowlist is `clear|none|unprobed|unreadable`; everything else withholds.

`errored` is the only RECOGNIZED verdict that withholds — a reviewer result the host
flagged as an error whose text matched no `DENIAL_MARKERS` prefix. It does NOT establish a
refusal, and saying so was the error: `reviewer-spawn-denial-v1.js`'s own header lists
three causes — a reworded host message, a subagent crash, a transport failure — and tells
callers to treat the verdict as no detection. What it establishes is that a refusal cannot
be ruled out, and the enforcer diverges from that header for the RENDER decision only,
never for routing. Rendering "do not withhold silently and do not work around it" beside a
result that may be a reworded refusal is the adjacency the design forbids, and worse than
the case it was written for: that reason carries no permission text at all, so nothing
tells the model which restraint is meant. Both residual arms of the probe's `case` NAME
themselves — `unknown` for a status word this shell does not recognize, `unparseable` for
output that is not a status line — so an unrecognized verdict withholds by allowlist
closure rather than by inheriting an initializer. `blocked` never reaches the `case` at
all; the `elif` above consumes it.

**`unreadable` RENDERS, and an earlier revision of this feature had it backwards.** Its
usual provenance is the module's `readTail` failure path — a rotated or deleted
transcript, a FIFO, an EACCES path — which precedes any inspection of a tool result; it
can also come from the module's outer catch, which does wrap the scan. Either way the
DIRECTION is what decides: it is the same could-not-look outcome as a probe that timed out
or an installation with no scanner module, and both of those leave `unprobed`, which
renders. Withholding on one while rendering on the others put a single evidence class on
two opposite sides inside one block.

**Do not "simplify" the allowlist to a `clear`-only gate either.** Measured:
`reviewer-spawn-denial-v1.js` answers `verdict('none')` when no reviewer result exists at
all, which is every chain's FIRST resume Stop — the case this sentence exists for — so a
`clear`-only gate deletes the feature instead of narrowing it.

A second consequence travels with the gate: with the clause rendered the reason states TWO
sanctioned deviations, so the resume site selects `LEGEND_CLOSER_WITH_EXCEPTIONS` and a
plural exception lead-in, and states the second exception together with its own bound —
reporting a withholding does NOT release the Stop guard, and the host-refusal branch
discloses the same thing about its own report instruction. The singular
`LEGEND_CLOSER_WITH_EXCEPTION` stays at the host-refusal site, whose reason legitimately
states one exception and is byte-identical to baseline. Those two are the second and third
members of a THREE-member verbatim-frame hand-copy class with `LEGEND_CLOSER`; the frame
is compared by no check, so reword one and reword all three.

**`hooks.reviewSpawnScopeSentence` (default true) is the operator opt-out**, read
PERMISSIVELY through `zensu_hook_enabled` at both render sites — for this key "enabled"
means a sentence renders, so an unreadable config falling back to enabled restores the
default rather than a capability, which is why it is NOT the strict reader
`reviewerSpawnAutoAllow` uses. It exists because this is the one piece of model-facing
prose in the tree whose subject is a HOST-level rule; without it the only lever was
`hooks.chainEnforcer=false`, which disables the whole guard — and is not ledgered
either: a config-disabled gate has no decision point, so only the EIGHT `ZENSU_*` gate escapes
listed under §"Visible opt-outs" ever produce an entry — and not every `ZENSU_*=off`
spelling is among them, `ZENSU_AUTOPILOT` and `ZENSU_SESSION_LINEAGE` being the two this
file already records as escapes that are deliberately not ledgered. Disabling THIS key likewise escapes no gate and records nothing.

**KNOWN BOUND 0, and it is the one the first roster missed entirely.** This sentence
only ever reaches a model that got as far as a BLOCKED Stop. A session that reads a host
rule as a prohibition normally withholds `--tdd-complete` too, and `stop-chain-enforcer.sh`
releases Stop UNCONDITIONALLY while `SESSION_IMPL_COMPLETE` is not true — so neither
render site is reached, and the chain parks at `implementing`. §"Foreign-Chain Row"
records that shape as an observed session outcome and names the only instrument that
could see it: counting turns ended while `implementing` with a changed worktree, never
wall time. Not addressed here — a turn counter is a workflow-state field and therefore
a MINOR release under §"Runtime Lineage".

**Residual carriers, stated rather than closed.** KNOWN BOUND 1: `skills/tdd/SKILL.md`
Phase 6 orders the FIRST spawn of every chain before any hook directive exists, so a
session that withholds the very first fan-out learns this only after one blocked Stop —
one turn, not a wedge. KNOWN BOUND 2: `hooks/lib/chain-recovery-v1.js`'s `NEXT_COMMAND`
instructs a reviewer spawn from JS, where a shell constant is structurally unreachable.
That bound is NOT planned to be closed, and the remedy an earlier wording gave was
backwards: "the owner MOVES to a shared JS module" inverts the problem, because a JS
module is exactly as unreachable from `sh` as `sh` is from JS and all three render sites
are POSIX shell. If a cross-language carrier is ever genuinely needed the shape that
serves both is `hooks/lib/rule-block-v1.js`'s `readRuleBlock`, which this repo already
ships for precisely that pattern.

**KNOWN BOUND 3 is the WORST of them, and its roster is a GREP, not a list.** Several
skill flows order the same review-aspect + code-reviewer fan-out without arming a chain
— `cover` states in its own body that it is skill-driven and NOT Stop-hook-gated — so
bound 1's mitigation does not apply and a withheld fan-out there is permanently silent.
The sentence says "armed in this session", which puts them outside its scope by
construction rather than by oversight; that does not make the gap smaller. The first
enumeration named three files while nine under `skills/` carried the identity, which is
the census failure this file already records for the sibling identity — so **before
deciding this bound is closed, run `grep -rn 'zensu:review-aspect' skills/`** and judge
per file whether it ORDERS a fan-out or merely describes one.

`tests/structure/test-stop-enforcer-self-review-routing.sh` T38-T59 pin this section's
claims: the render and the non-render (T38, T39, T42), the plural and singular closers and
the exception lead-in that must agree with each (T43, T52, T53), the full render allowlist
including `none`, `unprobed` and `unreadable` (T50, T51) and the named residual (T54), the
config key at the Stop site (T45), the host build (T46), the census (T47), the bound roster
(T48), the windowed-`REVIEWER_DENIALS` carriers (T49), the example-config entry (T55), and
the absence of the ledger claim this section once made (T56), the second exception with its own bound (T57), and the record-anchored config read at the Stop site, pinned at source by T58 and behaviourally in both directions by T59 — the overlay channel every other fixture in that suite bypasses, because `ZENSU_CONFIG` short-circuits `cfg()` before the project overlay is consulted. The one-owner boundary is
T40: occurrence counts for both the constant and the clause, no consumer redeclaration, a
single-line plain-assignment form with no `:-`, no borrowed branch discriminator, and a
hand-copy scan over SIX roots — `hooks/`, `skills/`, `docs/`, `agents/`, `templates/` and
repo-root `CLAUDE.md`, with `tests/` carved out because the suite legitimately holds the
needle. `docs/tdd-manager-workflow.md` §"The review-spawn scope sentence" is the operator
account; P3a-P3f in `tests/structure/test-post-review-self-review-handoff.sh` pin the
fix-round site on its emitted context.

**Moving together:** `hooks/lib/zensu-tdd-phase.sh` (the constant, its
`ZENSU_REVIEW_SPAWN_SCOPE_SOURCE_BUILD` provenance constant and the bound roster),
`hooks/stop-chain-enforcer.sh` (`REVIEWER_DENIAL_RAW`, the render allowlist, the two legend
closers and the exception lead-in), `hooks/post-review-tdd-delegate.sh` (the clause, its own exception clause and the
withhold status line — all three set in one config-gated block and all three travelling
together), `hooks/lib/reviewer-spawn-denial-v1.js` (its STATUS vocabulary, which the
enforcer's probe `case` hand-enumerates: a sixth status added there lands in the residual
arm and WITHHOLDS, which is the opposite of the could-not-look direction this section
states, so classify it in that `case` in the same commit), and the `reviewSpawnScopeSentence` entry
in `config.example.json` — that file is advertised as carrying every flag, and T55 pins this
one there. **Operator-facing accounts:** the `reviewSpawnScopeSentence` row in
`docs/configuration.md` and §"The review-spawn scope sentence" in
`docs/tdd-manager-workflow.md`.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field, no strict key set (`zensu_hook_enabled` is the PERMISSIVE
reader, not `zensu_hook_enabled_strict`), no hook added, removed or renamed and no matcher
changed, no attestation change, and no `permissionDecision` of any kind — the change is
directive text plus a permissively-read config key, which that section classifies explicitly
as a `patch`.

**Known gap:** the sentence has THREE independent suppressors — the config key, the probe
verdict, and the branch it renders in — and all three produce byte-identical absence with no
`/zensu:doctor` row to tell them apart. That is weaker than the two nearest precedents,
`ruleCarrierRows` (whose four states must render differently) and
`reviewerSpawnPermissionCheck` (where disabling deliberately does not produce silence). Do
not claim doctor visibility for this key until such a row exists. **Port-relevant:** the premise is host-coupled — a port must re-decide whether
its harness carries an equivalent rule class at all, and re-spell all three agent
identities. `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included.

The windowed-`REVIEWER_DENIALS` gap this work uncovered belongs to
§"Host-Refused Reviewer Spawn" and is recorded in that section's own gap list, not here.

## Marker-Block Carriers (`session-start-evidence-discipline.sh` + `user-prompt-best-solution-first.sh`)

Two hooks inject a rule read at run time from a one-line marker block under `docs/`. They share
ONE hardened reader, ONE `MAX_FILE` and ONE `MAX_BLOCK`, and they are NOT interchangeable:

- `session-start-evidence-discipline.sh` — SessionStart + SubagentStart, block in
  `docs/evidence-discipline.md`, **no opt-out flag**. Nothing silences it.
- `user-prompt-best-solution-first.sh` — UserPromptSubmit + SubagentStart, block in
  `docs/best-solution-first.md`, opt-out `hooks.bestSolutionFirst`. It additionally loads
  `zensu-config.sh`, which is its only extra refusal path.

**A THIRD consumer reads the same block, and it must never grow its own parser.**
`ruleCarrierRows` in `hooks/lib/zensu-doctor-report.js` is the operator's only signal that a
carrier stopped injecting: build-time pins govern this repository's copy, never an installed
tree, and every run-time refusal but the plugin-root mismatch is silent. It `require`s
`rule-block-v1.js` LAZILY and guarded, exactly as `reviewerDenialRows` does — a load fault costs
that row, not the whole report — and a hand-copied marker parse there would report on bytes the
hook would have refused. `RULE_CARRIERS` re-encodes the two `doc` paths and both marker pairs, so
a renamed rule file or a reworded marker lands here as well as in the hook. `RULE_REASON_TEXT`
re-encodes the module's `REASONS` values: one added there and not here renders as unrecognized
rather than as health, which is the safe direction and is deliberate. `P5a`-`P5h` in
`tests/structure/test-doctor.sh` pin that all four states — intact, suppressed by flag, refused,
and not-checked — render DIFFERENTLY from one another; a row that rendered unconditionally would
reinstate the silence it exists to remove. That suite's green fixture copies the real module and
both real docs rather than stubbing them, so it cannot go green against a parser nothing ships.

**`MAX_BLOCK` is declared twice, hand-copied once more, and bound by three checks.** The two
declarations are the hooks; the one hand copy is `tests/structure/test-best-solution-first.sh`
(a suite variable, bound by B2h). Do not spell the number anywhere else — name the constant.
The prose copy in `docs/architecture.md` was removed for exactly that reason. H4e in
`test-evidence-discipline.sh` (which reads the value out of the SIBLING file rather than
hand-copying it, and therefore fails if that file is renamed — deliberate: the alternative is a
third copy of the number), B2h in `test-best-solution-first.sh`, and the cross-carrier equality
in `test-windows-portability-guards.sh`. `MAX_FILE` is bound only by that last one, because both
per-file pins grep its declaration without the value.

**The cross-carrier comparison extracts a RANGE and its boundaries are load-bearing.** It strips
full-line comments, then selects from `const pre = fs.lstatSync(rulePath);` to the enforcement
`block.length > MAX_BLOCK`, so it covers the hardened reader, the marker-position parse and the
bound's use. Two properties keep it from going vacuous, and both were learned by probe:

1. **The end address is a substring match**, so a trailing `// … block.length > MAX_BLOCK …` on a
   code line survives the full-line strip and truncates the range. Added to BOTH carriers it kept
   the bodies equal and satisfied a bare `grep` for the needle, with both enforcements deleted and
   the suite fully green. The probe and its numbers live in the comment above the check; do not
   re-author them here. What closes it: the extracted body's LAST LINE must be the enforcement
   statement, and each literal must occur exactly ONCE per carrier — the count is what removes
   the class rather than the probed spellings, and it also covers a shadowing redeclaration
   between `const rulePath` and `const pre`, which is inside the hook's `try` block.
2. **Comment TEXT inside the range is deliberately not compared.** That is what lets the two
   carriers carry differently-worded notes on the shared constant; it also means a one-sided edit
   to an in-range comment no longer fails the check. Stated, not accidental.

**The refusal set is prose in EIGHT places and forks easily** — one shared reader, eight
restatements, and no test pins the wording. It is a hand sweep, so the roster is the control:

- `hooks/session-start-evidence-discipline.sh` (header)
- `hooks/user-prompt-best-solution-first.sh` (header)
- `docs/architecture.md` §Evidence Discipline
- `docs/architecture.md` §Best Solution First
- `docs/evidence-discipline.md`
- `docs/best-solution-first.md`
- `docs/configuration.md` — the evidence-discipline hook row
- `docs/configuration.md` — the best-solution-first hook row

The shape: an unknown event, a malformed payload, and a rule file that is absent, symlinked,
swapped between the pre-check and the open, oversized in FILE or in BLOCK, short-read, or
malformed — plus a missing `node`, and for the sibling its config
library. Every one exits `0` silently. The only branch that REPORTS a cause is a mismatched inherited
`CLAUDE_PLUGIN_ROOT`, which exits `2` on stderr; the plugin-root RESOLUTION failure a line above
it also exits `2` but prints nothing, so it is neither silent-zero nor operator-visible. A site that names only the file ceiling sends an operator
whose rule silently stopped injecting to check the file size and conclude the hook is broken. The
count above drifted once already (it read SEVEN while listing eight), which is exactly how a site
gets missed.

**A review ceiling, not a ratio.** Each suite carries a `REVIEW_CEILING` below the `MAX_BLOCK`
fail-safe so the next clause is argued rather than absorbed. The criterion is ABSOLUTE headroom,
identical on both carriers, never a preserved percentage: ratio parity hands the larger slack to
whichever block is bigger and self-erodes as the block grows.

**`REVIEW_HEADROOM` is enforced ONE-SIDEDLY, in the suite that owns the ceiling.** Each owning
suite asserts that its remaining slack — `REVIEW_CEILING` minus the measured block — never
EXCEEDS the declared headroom, and the cross-carrier arm compares the two declared headrooms so
they cannot drift apart. Both earlier shapes were wrong and are recorded so neither is retried:
deriving the ceiling from the live block over-constrained it (with both ceilings fixed it reduces
to a constraint on the two rule TEXTS' length difference that no file states, and a
one-character edit turned the guards suite red at 88 against 89), while comparing two inert
literals constrained nothing at all (raising one ceiling from 900 to 1000 left every check green
while the realized headroom became 189 against 89 — measured, both times). One-sided and
per-suite is what avoids both: block growth only shrinks the slack and stays green, and a
unilateral ceiling raise fails in the suite where the edit was made. Accepted consequence: a
block that shrinks far below its ceiling also trips it, which is correct — a ceiling that has
drifted away from its text has stopped being a tripwire.

Provenance of the number, stated because the comments call it "roughly one clause": 89 is the
remainder of the evidence carrier's pre-existing round ceiling (900 minus 811), retained rather
than re-derived, and the sibling moved from 1800 to 1741 to match it. It admits the shorter
sentences of these blocks and not the longer ones. That is a defensible policy but it is not a
measurement of a clause; re-deriving it from the two blocks' actual sentence lengths is open.

Both suites measure through `node`, not `${#var}`: bash counts bytes under `LC_ALL=C` and code
points otherwise, while the hooks compare `String.length` — UTF-16 code units — and both blocks
carry non-ASCII characters. `test-evidence-discipline.sh` passes identically under `LC_ALL=C`,
which is the claim tested rather than asserted.

`test-evidence-discipline.sh` C6 pins the one measured figure in `docs/architecture.md` — the emitted
character length — against a value it derives. C5 works the other way for the carrier population: it
FORBIDS restating the total as a literal and requires the prose to name `EXPECTED_AGENTS` and
`EXPECTED_SKILLS` instead, because a numeral there goes stale on every new skill. Both directions were
learned the hard way — C5 first pinned the numeral, and the count moved from 32 to 33 in a merge before
this branch even landed. Stated so the sentence is not read as covering the pair: the SIBLING's figures in
the same document — its emitted length and the per-turn total derived from it — are NOT pinned. The suite is absent from `tests/profiles/windows-ci.v1.json`, so it never runs on
the Windows PR shard; it IS in `ciStructureTests`, which the weekly Windows Safety structure
shards execute.

## Gate-Disable Prefixes (`ZENSU_*=off`) and `test-gauntlet-loop-skill.sh` G12

**Introducing a new `ZENSU_<NAME>=off` escape means editing a skill test in the same
commit.** `tests/structure/test-gauntlet-loop-skill.sh` G12 scans `skills/gauntlet-loop/`
for any gate-disable prefix, because a prompt carrier that teaches one hands the model a
hatch that lands no bypass-ledger entry. A negative scan is only as wide as its
alternation, so G12 builds its pattern from a hardcoded `ESCAPE_STEMS` list, and its
`G12a` arm re-derives the set from `hooks/`, `docs/` and this file and FAILS when the two
disagree.

That makes the coupling run in an unobvious direction: an ordinary change under `docs/`
or `hooks/` that adds — or removes the last occurrence of — such a literal turns a suite
named for the gauntlet-loop skill red, and the remedy is to edit `ESCAPE_STEMS`, not the
file you were working on. The message names both sets so the diagnosis is in the failure
itself, but nothing points at it from the side that changes.

It is not hypothetical. `ZENSU_REQUIREMENTS_GATE=off` arrived with the
plan-requirements completion gate and was caught on the next merge, by exactly this arm.

Two properties worth keeping when touching G12: the derivation carries the same quote
tolerance as the pattern it validates (the gates compare after shell quote removal, so
`ZENSU_CHAIN='off'` disables one at runtime and a bare `=off` derivation is blind to it),
and an EMPTY derivation is a FAIL rather than a skip — a swallowed `grep -r` failure used
to read as agreement while the control block still printed PASS.

**Not every member of this set is a gate.** `ZENSU_SESSION_LINEAGE=off` (`skills/session-trail/scripts/trail.mjs`)
refuses every session-lineage ledger write and is a PRIVACY control: it disables no gate,
widens no capability, and deliberately records **no** bypass-ledger entry — the ledger
exists so that everything rendered under "Gates bypassed" is a gate that was escaped, and
adding this would make that line false. It is in `ESCAPE_STEMS` because the set is derived
mechanically from every `ZENSU_*=off` literal under `hooks/`, `docs/` and `CLAUDE.md`, and
because G12's own purpose — a prompt carrier must never TEACH one of these spellings —
applies to it exactly as it does to the gates. So membership here says something about the
SPELLING, never about what the variable does.

**State the two counts, because they are NOT the same number and the gap is the point.**
`ESCAPE_STEMS` now holds TEN stems; `ZENSU_BYPASS_GATE_ALLOWLIST` in
`hooks/lib/zensu-tdd-phase.sh` holds EIGHT, and `docs/configuration.md` §"Visible opt-outs"
stays the authoritative ledger roster. TWO stems are therefore in the set and not in the
ledger, and `ZENSU_SESSION_LINEAGE` is not the first: `ZENSU_AUTOPILOT` was already one,
because its escape is recorded as an audited `BLOCKED` transition rather than as a ledger
entry. Do not "reconcile" the two lists — they answer different questions, and a reader
who makes them agree has either ledgered something that escapes no gate or stopped G12
from covering a spelling a skill must not teach. A future member needs its own two
sentences here, and the counts above updated with it.

## Fixture Mutation Events (`scripts/fixture-mutation-watch.js`)

The promptfoo wrapper attests `tracked_clean` for the immutable eval fixture from TWO
independent signals: a manifest comparison (`scripts/fixture-manifest.js`, also polled every
10 ms) and a filesystem-event marker. **The marker is not redundant** — it is the only thing
that catches a TRANSIENT mutation, written and restored byte-for-byte before the run ends,
which is what `test-claude-promptfoo-wrapper.sh` P13-S6 pins.

**Both watch backends now share ONE decision, `classifyFixtureEvent`.** They did not, and
the divergence was the bug: the per-directory backend gated `.git` behind a manifest delta
while the recursive one (`fs.watch(root, {recursive:true})`, FSEvents on macOS) marked any
path outright. Under load that made the wrapper attest dirty against its own `git init` +
`git add` + `git commit` seeding, which runs BEFORE the watcher starts — P13-S8 failed with
rc=3 on 8 of 8 concurrent runs and 0 of 8 idle. Three further event shapes were measured the
same way and are gated for the same reason: the watched ROOT's own basename (what libuv
reports for an event on the watched directory itself), a directory that CONTAINS a run-owned
subtree (`.zensu`, whose children the wrapper permits the run to write, coalesced upward),
and garbled names FSEvents emits under coalescing (`.git/ä`).

**The gated classes are adjudicated by the MANIFEST; ordinary fixture paths are NOT, and
that split is load-bearing.** A manifest gate on an ordinary path would destroy transient
detection outright — the manifest is equal by definition in exactly that case. Ordinary paths
are separated by the entry's own `ctimeMs`/`mtimeMs` against the watcher's start instead: a
denied write leaves the inode untouched, a restore does not, and an unreadable entry marks
(a deletion is a mutation). Do NOT "simplify" that branch onto `gateOnManifest` — it reads as
one consistent rule and silently removes the feature P13-S6 exists for. The ctime half of the
argument is POSIX only; on Windows that field is the creation time and settable, which is
acceptable solely because the `init_git` path requires `sandbox-exec`/`bwrap` and exits 69
without one.

Moving together: `RUN_OWNED` (the ancestor set is DERIVED from it, never hand-listed),
`EXCLUDED_PATHS` and `gitControlSnapshot` in `fixture-manifest.js` (what a manifest delta can
still see is what makes gating `.git` safe), and the registered-case floor in the shell
driver. `tests/structure/fixture-mutation-watch.test.js` carries the four measured shapes and
pins the single-implementation property at SOURCE level — a rule pin alone cannot catch a
SECOND copy of the rule, which is what the bug was. The suite is local-only
(`tests/profiles/promptfoo-local-only.v1.json`, and in the `excluded` list of
`windows-native-structure.v1.json`), so none of this runs in GitHub Actions.

**Known gap, measured and not closed.** Under the harness that failed 8 of 8 before the fix,
128 runs at a heavier setting produced ONE failure whose cause was not established; 224
instrumented runs at the same setting could not reproduce it. Say "the observed shapes are
closed", never "the watcher cannot false-positive".

## Session Lineage Ledger (`skills/session-trail/scripts/session-lineage-v1.mjs`)

**Not the same "lineage" as either section above it.** §"Runtime Lineage
(`version_type` is load-bearing)" is about whether an EXECUTING PLUGIN may serve a
Session Control record it did not mint, and §"Adopting a Record Across a Lineage
Break" is the explicit exit from that refusal. This section is about a chain of
CLAUDE SESSIONS handing work to each other, has no relationship to plugin versions,
and shares no code with either. The three collide on one English word; a change to
one of them lands in none of the others.

`/zensu:session-trail` records every takeover as one edge in a **machine-wide,
multi-writer** store, and this module is the single source of truth for its schema,
its layout, its refusal table and the chain walk. It is the reason the skill has a
write channel at all — before it, `trail.mjs` had none, and SKILL.md said so.

**The store is a DIRECTORY of one record per edge, never a shared append-only file.**
Six windows write it concurrently and atomic append behaves differently on Windows
than on POSIX; an exclusive `wx` create of a uniquely named record needs no lock and
cannot interleave. `labels.json` is the one exception and lands by O_EXCL temp plus
rename — it is a read-modify-write, so **concurrent labels can still lose an update**;
the rename removes only the torn-file half of the hazard.

**Two identity routes, deliberately independent.** The account comes from the desktop
store, whose top-level directory IS the `accountUuid` (measured 2026-08-21 three ways:
`oauthAccount.accountUuid` in `~/.claude.json`, `lastKnownAccountUuid` in
`Claude/config.json`, and `ant-device-registry.json`'s key set). The window comes from
the process ancestry up to the owning `Claude.app` process. Only the macOS path is
MEASURED; the Windows and Linux candidates are probed and can win — `ccdStoreCandidates`
tries `$XDG_CONFIG_HOME/Claude` and `~/.config/Claude` there — they are UNVERIFIED, not
unreachable. Where no candidate exists the account is `null` and the ancestry still
groups by window. `ZENSU_CCD_STORE` overrides the probe list and is AUTHORITATIVE, and
`lineage --diagnose` prints every candidate with its verdict.

**The edge's `repo` comes from the HANDED-OVER work, never from the recording
process's cwd.** The documented takeover route runs from a window in a different repo,
so deriving it from the recorder filed the edge under the taker's repo and made the
default repo-scoped `lineage` render nothing where the work lives — an empty answer
indistinguishable from "no handover happened".

**Sites that move with the schema:** the module, `trail.mjs`'s wrappers, the `v1`
segment quoted in `skills/session-trail/SKILL.md`, `tests/structure/session-lineage-v1.test.js`,
and the `v1` path spelled throughout `tests/structure/test-session-trail-lineage.sh`.

**Two couplings fire in the UNOBVIOUS direction**, the same shape §"Gate-Disable
Prefixes" records for G12 — an ordinary edit elsewhere reddens a suite named for
something else, and nothing points at it from the side that changes:

- `tests/structure/test-windows-portability-guards.sh` binds
  `SESSION_LINEAGE="$ROOT/skills/session-trail/scripts/session-lineage-v1.mjs"` and
  hardcodes eight source literals out of `readBoundedFile` — both platform gates, the
  `fs.openSync` flag expression, the `fstatSync` line and both refusal returns. So
  rewording that reader, or normalising a quote style in it, reddens a suite named for
  Windows portability. (It already did: the module carried a double-quoted `"win32"`
  beside a single-quoted one, and the pin held the inconsistency in place.)
- `package.json` is asserted by four checks in `tests/structure/test-session-trail-lineage.sh`
  (`L41` the exact `c8` pin, `L41a` that the coverage run drives all three suites, `L41b`
  the include glob's quoting, `L41c-control`). So an ordinary dependency bump or npm-script
  edit reddens the session-trail lineage suite.

**The DISPATCHER owns command-flag scoping, and two tables must stay key-identical.**
`parseArgs` accepts every flag for every command, so a flag belonging to another verb
parsed and was then ignored — `takeover x --forget y` recorded an edge and named
neither flag, and `adopt --no-record` wrote the machine-wide record the flag said it
was skipping. `COMMANDS` and `COMMAND_FLAGS` sit adjacent in `trail.mjs` for that
reason: `COMMANDS` drives the routing AND the usage string, `COMMAND_FLAGS` must carry
a row for every one of its keys, and `refuseForeignFlags` fails closed on a missing row
rather than defaulting to `[]`. The unknown-command refusal stays FIRST, so a typo is
reported as a typo. Two entries are DELIBERATE accept-and-ignore, not oversights:
`--force` on `list` and `limited`, which SKILL.md documents as a survey rule —
`instances` emits no verdict and so refuses it. `L56h` derives both key sets from
source and compares them, so an eleventh command cannot be added to one alone;
`test-session-trail-skill.sh`'s `T16` and its `json-mode-order` guard read `COMMANDS`
and `handler(opts)` and BOTH went red when the if/else chain was replaced — they are
part of this coupling, not collateral.

**Every disclosure has ONE owner and must reach BOTH carriers.** The recurring defect
in this file is a read that FAILED rendering exactly like a read that found nothing,
and it kept surviving one code path over: `truncatedNote` was added when eleven
carriers of `led.truncated` were all inside `JSON.stringify`, and `renderLedgerFault`
was added when the listing branch disclosed `directoryError` and `schemaNewer` while
its `--where` sibling disclosed neither and still closed with the `--backfill` offer,
the one line in the file that mints machine-wide guesses. Same rule for the walk's own
bounds — `truncated` and `revisited` reached the `--where` rendering and were dropped
by the listing one on both carriers. A new renderer calls the owner; it never writes
the sentence again. `lineage --backfill --apply` is gated on a capped read for the
reason it is gated on an unreadable record: the duplicate guard is built from that read.

**The ceiling is a BOUND on the ancestor walk, never a candidate for it.**
`ledgerPathUnlinked(dir, stopAt)` refuses a symlink at any component between `dir` and
the caller's ceiling — `lstat` declines to follow the FINAL component alone, so a link
at `session-lineage/` or `v1/` was resolved as an ordinary intermediate one and
`lineage --forget --apply` unlinked a record OUTSIDE the ledger. The ceiling ITSELF is
tested first and never lstat'ed, matching `ensureLedgerDir`, which breaks before pushing
it into its checked set. Judging it instead made the two halves disagree about one tree:
a symlinked `~/.claude` is the ordinary shape under a dotfile manager, so the write path
kept landing records while every read answered `ESYMLINK` and the only retraction channel
refused forever. **All four readers of this store take the ceiling** — `readEdges`,
`removeEdgeFiles`, `readLabels` and `otherSchemaLedgers` — because each one's WRITER
already refuses that tree, and a reader that did not made read and write disagree. **Every
INTERNAL caller must thread it too**, which this sentence once implied and did not check:
`updateLabels` held the ceiling, passed it to `writeLabels` and omitted it from its own
`readLabels`, so the two halves of one read-modify-write disagreed about the same tree.
`readLabels`' guard is CONDITIONAL — with no ceiling it makes no ancestor check at all,
unlike `readEdges`, which still makes the leaf check — so an omission there is silent.
`session-lineage-v1.test.js` pins the write side, the read side, the delete side and the
discriminating case that a component BELOW a symlinked ceiling is still refused;
`test-session-trail-lineage.sh` L59a/L59b drive the same root end to end.

**Accepted residual, stated rather than implied:** `removeEdgeFiles` checks the ancestors
ONCE and each iteration then re-derives its path, so a directory component swapped for a
symlink after the guard resolves through the new link. The per-file `lstat`+`unlink` pair
is safe on its own, because `unlink` never follows a final symlink — the exposure is the
directory swap, not the leaf — and Node exposes no `unlinkat`/dirfd, so it cannot be
closed in this shape. `ensureLedgerDir` documents its own analogous check-then-create
window the same way.

**The chain walk takes ONE source of successors.** `walkChain(sessionId, source, maxHops)`
accepts an edge array or a prebuilt `indexBySource` map. It used to take both, and once
an index was supplied the array was dead — a caller could hand it two that disagree and
the walk followed the index silently. `chainRoots(edges)` builds its own index for the
same reason, and there the pair was worse than dead: `edges` decides which roots exist
while the index decides where each chain goes. Deriving the array back out of a map is
rejected — flattening groups edges by source key, and the DISCOVERY ORDER of roots is
the order chains render in. Measured after the change, with the shared index
`cmdLineage` uses: n=5000 renders in 4 ms, against the 1669 ms recorded before R10
removed the per-root re-index; rebuilding per root still reproduces the quadratic shape
at 1834 ms, which is the control that keeps the first figure meaningful.

**The two ledger writes land by DIFFERENT primitives, and the difference is the
guarantee.** An edge record lands with `fs.linkSync`, which refuses a name that already
exists — that is what makes the store append-only. `labels.json` lands with
`fs.renameSync`, which replaces the whole document by design because it is a
read-modify-write. SKILL.md claimed both landed by rename, which describes the opposite
guarantee for one of them. `T11b`'s write-site allowlist names `linkSync` for this
reason, and its control loop must plant one per named primitive or the branch can be
deleted with every control green.

**Sites that move with the ENDPOINT field set**, which is separate and was got wrong
once: `makeEndpoint` owns the shape and `ENDPOINT_KEYS` is derived from it rather than
hand-listed, but three PROSE copies are not derived — the persisted-field sentence in
`skills/session-trail/SKILL.md` and its two `--json` disclosure paragraphs. Those are
a PRIVACY claim a reader decides from, so an over-list is as wrong as an under-list;
`test-session-trail-skill.sh` T26 pins both directions, scoped to the ledger lines
because the data-sources table legitimately documents `cwd` and `title` for three
OTHER files.

**Sites that move with a new `print(JSON.stringify(` payload in `trail.mjs`:** every
one must carry `skipped: SKIPPED`, and `test-session-trail-skill.sh` T22 pins the
COUNT as well — a new payload fails that suite until the expected number is raised,
which is the registration, not an obstacle. Every payload that reports the ledger's
state must additionally carry `ledgerTruncated`, `ledgerError` and `schemaNewer`
together; `L36b` counts the first against the second so a payload cannot report two
of the three.

**Permission posture, stated because nothing enforces it.** The ledger write happens
INSIDE the node process, so no PreToolUse hook sees it: not `pre-write-secret-scan.sh`,
not `pre-edit-tdd-reminder.sh`, not the Bash source-write gate. It is the only
persistence in this skill the user never approves a Write for, its target is whatever
`--config-dir`/`CLAUDE_CONFIG_DIR` names, and what it persists includes both
endpoints' absolute worktree path and branch. `--no-record` is the opt-out, and
`lineage --forget <session> --apply` is the only way a landed record leaves. Flow 3
step 0 in `skills/session-trail/SKILL.md` states this where the decision is taken;
keep it there, not only in that file's Safety section.

**The v-partition is now REPORTED, not read.** `ledgerPaths` still partitions the
store by `v${LEDGER_SCHEMA_VERSION}` while `classifyEdge` ALSO judges `schemaVersion`
inside a record, and the partition still wins — so `SCHEMA_NEWER`/`SCHEMA_OLDER` remain
reachable only from a hand-planted record. What changed is the CONSEQUENCE:
`otherSchemaLedgers` enumerates sibling `v*` directories, and a build whose own
directory is empty beside a populated one reports a MIGRATION instead of "No handover
has been recorded yet" — which had been followed by an offer to reconstruct guesses
for handovers the machine still held as measurements, one directory away. It does not
READ those records, and closing that still means dropping the derived segment or
teaching `readEdges` to enumerate siblings.

**`recordedAt` is judged by SHAPE, not by parseability, and the two are not close.**
It is the sole ordering key at four sites — the dedupe survivor, the branch `walkChain`
prefers, the `--where` answer and the rendered order — and every one of them ranks it
as a plain string, which is only chronological for the fixed-width UTC spelling
`toISOString()` produces. The guard was `Number.isFinite(Date.parse(...))`, which
judges VALIDITY. Measured against it: `"July 4, 2026"` parsed, sorted ABOVE every real
stamp and was actually earlier; `"9999"` — the value the ordering comment itself names
as the motivating defect — was still accepted; `"2026-02-31T00:00:00.000Z"` was
accepted as a February date meaning 3 March. The store is append-only and machine-wide,
so one such record wins every ordering decision permanently. `isIsoInstant` is the one
predicate, and the ordering comment beside `recordedAtKey` now points at it rather than
asserting the shape it depends on. All three writers already produce that spelling
(`nowStamp()` and the backfill's `new Date(mtime).toISOString()`), so the tightening
refuses nothing this tree writes — a fourth writer that does not is refused at READ
time, which loses the record rather than mis-ordering the ledger. Ported from the
parallel working copy, whose `isIsoInstant` this is.

**A tightened field validator can make a neighbouring test vacuous, and one nearly
did.** The unit fixtures passed bare ordinals (`'1'`, `'2'`) as `recordedAt`, which is
what made them readable; once the shape is enforced, the NUL-session-id case would have
been refused for its STAMP and would have kept asserting `MALFORMED` while never
reaching the guard it is named for. Its fixture carries a real instant now. When a
validator moves, re-read every case that asserts the same refusal reason for a
different cause.

**There is ONE display-bound family, and it is `flatPath`/`instanceId`/`sessionTag`/
`briefPath`.** Two grew independently — this line added a `showId(...).slice(0, 8)`
pair while the write-anchor work added the family above — and both were solving
"bound the value a reader retypes as a selector". They are not equivalent, which is
why the merge picked rather than kept both. Measured on the losing one:
`showId(x).slice(0, 8)` renders a zero-advance character as a SPACE, so
`a<ZWSP>bcdefgh` comes out `"a bcdefg"` — seven real characters in an eight-column
field — and an ESC byte comes out `"abc [31m"`. `instanceId` strips the zero-advance
class FIRST and the ordering is the whole point. `showId` is gone and its thirteen
call sites render through `sessionTag`, so a `list` row and an `instances` row still
name the same prefix, which is the only thing an 8-character id is for.
`test-session-trail-skill.sh` T22c pins the call-site floor and T22c-a pins that a raw
slice does not come back.

**`extractTouchedFiles` must NOT bound the path, and the reason is ORDERING rather
than trust.** Every renderer strips the worktree prefix with `rel(t.path, r.wt)`, a
string comparison against the RAW `r.wt`; a path bounded at extraction no longer
shares that prefix, so `rel` returns the absolute path and the row renders whole. It
was measured doing worse than that: with a worktree carrying a newline the briefs
emitted no `## Files the session touched` rows at all, and `test-session-trail-verdict.sh`
W8 is what caught it. All three renderers bound the value themselves — `flatPath` in
`show`, `briefPath` in both briefs — so the early bound was redundant as well as wrong.
The general rule: bind AFTER the last comparison that uses the raw spelling, never
before it.

**Deferrals this ledger carries, each accepted rather than overlooked:**

- **The confidence tier is not authenticated.** `confirmed` is a field in a JSON file
  every session on the machine can write, so it records what a WRITER CLAIMED, never
  what happened. The order gates ranking, not trust. Authenticating it means a MAC
  over the record, which is a schema change.
- **A concurrent label can still be lost.** `updateLabels` owns the whole
  read-modify-write and re-checks the file's identity plus size immediately before
  landing, and it REPORTS a failure to land instead of printing success — but it is a
  bounded retry, not a lock. Two windows can still interleave; the window is narrowed,
  not closed.
- **A window label written before incarnation keying stops resolving.** The key is now
  `<pid>@<start>` (§ the `label` row in SKILL.md), so a bare-pid key no longer matches
  anything. That is the safe direction — the alternative is the label resurfacing on
  an unrelated window that inherited the number — and `label --remove <pid>` clears the
  old form, which is the only thing that can still name it.
- **Two properties are pinned at SOURCE because no behavioural check can reach them
  from a sandbox**, and each says so in its own check comment: the `msysDrivePrefix`
  routing (identity off win32 by construction) and `cmdLabel` landing through
  `updateLabels` (the loss window needs two processes interleaving). Source pins rot
  differently from behavioural ones — each carries a control that fails if its own
  scan matches nothing. **`windowOf`'s basename match was the third and no longer is.**
  It read as unreachable because every fixture starts `node` from a shell, so no
  ancestor ever matched — neutering the function to `return null` cost exactly one
  check. The `window-probe` command takes the table as a parameter over stdin, so
  `L63`–`L63f` now drive the rule that decides the answer, INCLUDING the negative case
  the old source pin existed for: a path that merely lives under a claude-named
  directory (`~/claude-tools/bin/watcher`) is not a window, with the same tree matching
  once the name moves into the basename. A property listed here as untestable, once a
  seam makes it testable, is a stale claim rather than a residual — check this list
  when a seam lands.
- **The record-count cap is proven COMPUTED but not proven end-to-end.** The unit suite
  plants `MAX_EDGE_RECORDS + 5` records; the shell checks prove `ledgerTruncated`
  travels on every ledger-aware payload. Nothing drives a real over-cap ledger through
  the CLI, because 20 000 files is a Windows-budget problem, not a correctness one.

**`tests/structure/test-session-trail-lineage.sh`'s Windows ceiling is MEASURED, and
the measurement is now STALE — say so rather than quoting it as headroom.** The figure
below was taken at 70 checks; the suite is at 268. The rule this section exists to
record is that the ceiling is set from the FIRST GREEN WALL CLOCK on the shard, never
estimated from the macOS time and never raised speculatively — so the number stands
until a green Windows run replaces it, and until then the 9x ratio is what new checks
are budgeted against, not the remaining percentage. The ceiling was deliberately NOT
raised in the change that more than doubled the suite: raising it without a measurement
would trade a visible `TIMED_OUT` for a silent tail truncation. And the caveat cannot
live in the manifest — `tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and aborts every Windows shard at manifest load,
so a `note` field there is a CI-wide outage rather than documentation.

It is `timeoutMs: 900000` in `tests/profiles/windows-ci.v1.json` on `windows-shard-3`.
First green-shard measurement, run 32598374524 on `win25-vs2026`: **273905 ms at 70
checks** — 30% of its own cap, against **31 s on macOS** (measured 2026-08-22, idle
machine, at 66 checks). Windows is roughly 9x slower here, which is the ratio to
budget new checks against. An earlier note in this section claimed ~4 s on macOS;
that figure predated the suite roughly doubling and was what the 900000 ceiling had
originally been reasoned against.
**THE PROJECTION HAS BEEN REPLACED BY A MEASUREMENT, and it was 28% low.** Run
32998414210, job 98273571899: `session-trail-lineage` took **893084 ms** where the
projection below said "about 700000". Keep that gap in view before trusting the next
projection — the METHOD was sound and the NUMBER was still wrong by four minutes of
Windows wall clock, which on a shard this tight is the whole margin.

**The shard budget binds FIRST and is the tighter of the two, and on that run it
BOUND.** `windows-shard-3` carries a `profileTimeoutMs` of 1800000. Its eight suites
reported 137085 + 511955 + 1238 + 11207 + 9543 + 893084 + 95894 + 140066 ms =
**1800072 ms** — the envelope, exactly. `windows-profile-lifecycle-contract` ran last
and was granted **139971 ms of its own 420000 ms cap**, then reported `TIMED_OUT`. It
was not slow; it was not paid for. That is the failure §Host-Refused Reviewer Spawn
records verbatim ("read the shard's remaining budget", not the suite's `timeoutMs`),
observed rather than predicted.

**The suite therefore moved to `windows-shard-8`, alone.** Not to a different
neighbour: the same run's job durations were shard-1 1630 s, shard-2 1187 s, shard-3
1886 s, shard-4 1779 s, shard-5 1008 s, shard-6 1011 s, shard-7 1516 s, and 893 s does
not fit inside any of them under a 1800 s envelope. Adding a shard is what the
arithmetic left; rebalancing was not available. The move is three files in one commit —
`tests/profiles/windows-ci.v1.json`, the matrix in `.github/workflows/ci.yml`, and
`expectedProfiles` in `tests/structure/windows-ci-contract.test.js` — and the contract
test fails loudly when they disagree. **Shard 3's own eight-member accounting was wrong
in this file before that move**: it counted seven and omitted `autopilot-release-cli`
(600000), which is precisely how a headroom claim survives being false.

**The cap is 600000, and every earlier number is recorded here because each was wrong
in a different, instructive way.** 893084 of 900000 is 99.2%, and this file said so — "a single added
check can turn it red" — while the manifest shipped 900000 anyway. Run 33018717088 then
spent 900138 ms reaching 229 of 288 checks and was killed by that cap. Two samples of
byte-identical content therefore read 893084 (completed) and >900138 (killed at 79%),
and both were measuring a STALLED SUBPROCESS rather than the suite:
the win32 process probe timed out 115 times at 8000 ms, roughly 920 s of that 997 s.
The cap was then briefly 1500000, sized against a projection built on those poisoned
samples. Once the probe was fixed, run 33054489866 reported `PASSED
session-trail-lineage (154673ms)`, 280 PASS / 0 FAIL / 4 SKIP — so 1500000 was ten
times the real figure.

**Three sizing errors, three different lessons, and the middle one is the one that
generalises.** A ceiling set AT the measurement is already breached — one sample is a
lower bound on a distribution, never a bound on the next run. A ceiling set from a
projection is only as good as what the samples measured, and these measured a defect.
And a ceiling set far ABOVE the measurement stops being a tripwire at all: 600000 is
3.9x the real figure and deliberately BELOW the ~650 s a reintroduced probe stall would
cost, so that regression trips the cap instead of merely making CI slow. Alone on shard
8 the cap — not the shard — is what binds this suite.

**That measurement is also why 600000 was REJECTED for this suite, not merely not
adopted.** The parallel working copy lowered its own ceiling to 600000 on the strength
of a green run of a 70-check variant measuring 274 s. This suite is four times that
size and measured 893 s: adopting the number would have reported `TIMED_OUT` on every
Windows run. A ceiling is not portable between two suites sharing an `id`; only the
RATIO is — and the ratio under-predicted by 28%.

**The win32 process probe has NEVER passed on Windows, and that is a standing state
rather than a regression.** `processTable()` in `skills/session-trail/scripts/trail.mjs`
runs `Get-CimInstance Win32_Process` and keys every window label on the pid plus its
start time; on the runner it yields nothing, so `windowKey()` answers null, no
`labels.json` window entry is ever written, and L32c-control, L35, L35c, L52-control,
L52 and L52a fail against a file that was never created. Runs 32998414210 and
33018717088 carry those failures WORD FOR WORD, and the `-EncodedCommand` change
between them moved nothing — it removed a real argument-mangling hazard, so keep it,
but do not credit it with a fix it did not deliver. The probe's environment was
replaced wholesale and left the process without `PATH`, `windir`, `SystemDrive` or
`ComSpec`; `Get-CimInstance` reaches WMI through the provider host under
`System32\Wbem`, which nothing named. That omission was the leading suspect and did
NOT fix it, and the `PSModulePath` pin the security comment exists for is kept.

**The cause is now OBSERVED, and it is a STALL, not a failure.** `probeFault()` records
the exit code, signal and first stderr line, and `processStartTimeHealth()` renders it
as `probe-failed — …` where it used to say only `no-process-table`. Run 33052576528
answered `probe-failed — ETIMEDOUT signal SIGTERM`: powershell.exe was killed at its
timeout every single time, having written nothing to stderr. **The arithmetic closes
it.** One full suite run enters `processTable()` **115 times** (counted on macOS,
2026-08-27), so an 8000 ms stall costs 920 s — against the 997 s that run actually took.
The probe stall was very nearly the entire Windows wall clock of this suite; only about
77 s was real work, and the earlier "the cap is too small" reading was a symptom.

**Therefore the probe timeout goes DOWN, not up**, which is the opposite of the
instinct: 12000 would have put the failing case at ~1457 s against a 1500000 cap. It is
5000, so a stalling probe stays inside ~650 s while a working one still fits. What
should make it fast is the startup-cost control in the program itself —
`$PSModuleAutoLoadingPreference='None'` plus an explicit `Import-Module CimCmdlets`,
a four-column `SELECT` instead of whole instances, and `LOCALAPPDATA` restored so the
module analysis cache is not rebuilt on every start. **The uncompromised fix is none of
these**: it is not spawning powershell.exe 115 times. A short-TTL process-table cache in
the config dir would collapse that to a handful and would pay off for every Windows user
of this CLI, not just for CI. It carries its own containment and symlink rules, so it is
named here rather than smuggled into a CI repair.

**It worked.** Run 33054489866: `PASSED session-trail-lineage (154673ms)`, 280 PASS /
0 FAIL / 4 SKIP, with every window-namespace check green and no `probe-failed` line
anywhere — 997 s down to 155 s. If they ever go red again, read the `START TIMES` line
in `lineage --diagnose` before theorising: that line is the whole reason this took one
round instead of three. The L32c-control probe line that
was supposed to surface this greped for `process start` while the text channel prints
`START TIMES`, so it never matched on any platform and reported its own fallback as
though it were a finding; a diagnostic whose needle is never exercised is worse than
none, because it answers confidently.

Replace these figures from the next green Windows shard. A shard abort
truncates the tail of the second suite silently. The caveat lives here and NOT in the manifest:
`tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and aborts every Windows shard at manifest load.

**Two fixture defects in that suite were invisible on POSIX and cost a whole CI
round**, and both are the MSYS/native split this file already documents for
`bash-source-write-parse.js`. Neither was a product defect — the product is native
on both hosts — but both made real checks fail for a reason unrelated to their
subject:

- **`$$` is not a pid `process.kill(pid, 0)` can see.** Under Git Bash it is an MSYS
  pid from a different namespace, so the shell's own pid never reads as live and
  every liveness-dependent check (`L8b`, `L16`, `L24`) failed on that premise rather
  than on its own. The suite now spawns a detached node helper and takes the pid
  NODE reports, which is in the namespace the product consults on every host, and
  retires it in the EXIT trap. `L0b` is the premise check that named this on the
  first Windows run instead of letting three checks fail opaquely — keep it.
- **A hand-written fixture record must carry the spelling production writes.** `L25`
  interpolated a shell path into an edge record while node's `process.cwd()` reports
  the native one, so repo scoping found nothing. Every path a shell writes into a
  fixture here goes through `hostpath` (`cygpath -m`), the same helper the path
  comparisons already used.

**The suite isolates by `--config-dir` and `$ZENSU_CCD_STORE`, deliberately not by
`$HOME`.** Its sibling `test-session-trail-verdict.sh` redirects the home directory
instead — and it does NOT skip itself on Windows, which an earlier revision of this
paragraph claimed: `trailrun` sets `USERPROFILE` alongside `HOME` and that suite's own
V0 probe measures the PAIR, so the redirection succeeds where `os.homedir()` reads
`USERPROFILE`. §"Git Mutation Tables" says the WC block "will therefore run on
Windows", and the two paragraphs now agree. Both suites
also unset `CLAUDE_CONFIG_DIR`, because `trail.mjs` honours it and `$HOME` is only a
fallback — with it exported, a fixture read would resolve against the developer's
real config root and a `takeover` would write a real edge there. In the lineage suite
the unset is BELT, not the mechanism: `--config-dir` already outranks the variable in
`resolveRoots`, and the unset is what keeps that true for a check added later without
the flag. Exactly ONE invocation there omits it — the L10 case, whose whole subject is
that the variable is honoured — and `L28` pins that it stays exactly one, because a
second exemption is indistinguishable from a forgotten `env -u`.

## Takeover Destination (`worktreeAdvice` in `skills/session-trail/scripts/trail.mjs`)

**A THIRD session-trail axis, and the one most easily confused with the other two.**
§"Git Mutation Tables" tracks the WRITE-ANCHOR contract — *may I write there* — in six
carriers. §"Session Lineage Ledger" tracks a chain of sessions handing work to each
other. This one asks *will the directory still exist while I work in it*, and it shares
no code with either. All three live in the same skill; a change to one lands in none of
the others.

**The answer is now the same on every arm: a worktree of the taker's OWN.** There used
to be one exception — an already-archived session whose directory had survived was
adopted in place — and it was the worst arm to except rather than the safest. A survivor
is the tree `git worktree remove` refused on, and 37 of 40 sampled survivors were dirty,
so a takeover's first commit very often removes the condition that kept it alive.
**That is a correlation over 40 samples, and the wording has to stay one:** "close to by
construction" asserted a MECHANISM the sample does not support, and it stood here and in
`SKILL.md` while the emitted text hedged it correctly as "almost always" — a maintainer-
facing overstatement above a user-facing statement that was already right. SKILL.md §6
measures the other half of the shape: 498 of 657 archived worktree-sessions lost their
directory. The arms now decide only what to SAY, never whether to stay — an arm that
returns without a `git worktree add` line has reintroduced the defect, which is what
`WT8k` grades over a source-derived roster of all eight fixtures rather than a hand list.
`WT8L`/`WT8L2` grade the half `WT8k` cannot see: the `-b` SPELLING, in both directions.
That was the one measured routing decision the change turned on and nothing asserted it —
deleting `-b claude/<name>-cont` left every check in both suites green. The gone arm's
forbidden needle is the LONGER `add <path> -b claude/`, because its own prose legitimately
offers `-b claude/<name>-cont` as the remedy when git reports the branch already checked
out somewhere.

**`archivedAndDead` is named for what the EXPRESSION computes.** It was `safeToAdopt` —
a name that read as clearance — and then `archivedSurvivor`, which read as "the directory
survived" and needed eight lines of apology on the gone leg explaining that it means the
opposite there. The predicate carries no directory term at all
(`archived === true && !liveDespiteArchive`); the directory split happens one level down,
in `leg`. A name that has to be defended at one of its two use sites is the wrong name,
and the apology comment went with the rename rather than surviving it.

**The arm is decided ONCE, above the directory split, and both legs index `ADVICE_LEADS`.**
Lifting the three predicates was only half the job — the four-way LADDER that consumes them
was hand-written twice, in the same order, and this feature's own history is the argument:
retiring the old early return forced the identical reordering edit to be made by hand in
both places, where a one-sided version parses, renders, and is caught only if a fixture
happens to cover the affected arm. Each cell of the table is a FUNCTION, because two arms
interpolate a measured value (the live pid, and why the archive state could not be read),
and one shape is cheaper to hold than two.

**The rule has TWO halves and the second is easy to drop.** Choosing a directory settles
where COMMITTED work goes; a `git worktree add` carries nothing else. The present-directory
arms therefore also carry `CARRY_OVER`, the recipe that moves the uncommitted half out, and
the gone arms say the recipe cannot run against a path that is not readable rather than
printing one whose source is not there.

**The safety properties of that recipe are enumerated in the two reader-facing carriers,
and this section deliberately restates neither them nor their COUNT.** It used to, and that made a FOURTH hand-maintained copy of text that
already exists in the code comment above `CARRY_OVER`, in the emitted array a human reads,
and in `SKILL.md` flow 3 step 4 — a four-way agreement whose own paragraph recorded that it
had already gone stale once (it read THREE for a round after `--binary` was added, and FOUR
for a round after the quoting, the paste-unit split and the regular-files-only loop landed).
The two READER-FACING carriers are the authority: the `CARRY_OVER` rationale comment in
`skills/session-trail/scripts/trail.mjs` and `skills/session-trail/SKILL.md` flow 3 step 4,
which must agree with each other on the COUNT and on every property. `T35b` pins the
SKILL.md copy needle by needle and `WT8m3`/`WT8m4`/`WT8m5` plus
`tests/structure/worktree-advice-v1.test.js` pin the EMITTED array. State the bound with
them: no check compares the two COUNTS, and the rationale COMMENT above `CARRY_OVER` has
no pin at all — which is where three stale claims were found in one review cycle. That
agreement is held by review, not by a suite. What stays here
is the pin roster below and the gaps at the end — the parts that exist nowhere else.

**Three hand-maintained counts encode ONE fact, in TWO files, and they are related by
arithmetic nothing computes:** `WT8_PRESENT_EXPECT` and `WT8_GONE_EXPECT` in
`tests/structure/test-session-trail-verdict.sh`, and `T35_EXPECT` in
`tests/structure/test-session-trail-skill.sh`, where **`T35_EXPECT` = `WT8_PRESENT_EXPECT` +
`WT8_GONE_EXPECT`**. Adding one command to `CARRY_OVER` reddens two suites in two files, and
each failure message now names its sibling so the second edit is not a hunt. The VALUES are
deliberately not repeated in this file: they moved three times inside one review cycle and
this paragraph was stale after every one of them, which is the drift a fourth hand copy
always produces. Read them from the two suites; what this paragraph owns is the RELATION.
**They must NOT
be derived, and that is worth stating so nobody "fixes" them into vacuity:** the same
extraction that would produce the expectation also loses the two-space prefix, so a derived
expectation drops in lockstep with the defect and passes. The exactness is load-bearing;
what was missing was signposting.

**Coupled carriers, and the pin that holds them:** the advice command literals —
`TAKE_YOUR_OWN`'s and the gone leg's `git worktree add` spellings AND every `CARRY_OVER`
command — are hand-restated in `skills/session-trail/SKILL.md` flow 3 step 4, in its table
and its fenced blocks. A FOURTH copy of the gone-leg spelling lives in `printResume` and is
OUTSIDE the extractor's range, which ends at `worktreeAdvice`'s closing brace: it is
byte-identical today and a one-sided edit to it is unpinned. `T35`/`T35-control` in `tests/structure/test-session-trail-skill.sh`
extract every two-space command literal from the first hoisted constant through the END of
`worktreeAdvice` — a RANGE, not one array, because scoping it to `CARRY_OVER` would leave
the two literals that encode the rule unpinned, and because the constants now live at module
scope while the gone leg's command is still inside the function. Its `sed` decodes the one
JavaScript escape those literals carry (`\'`, from the shell-quoted placeholders); without
that, every quoted command reads as missing from a markdown carrier that agrees with it.
**Both scans are SCOPED to flow 3 step 4.** The rationale scan always was, because `symlink`
and `mktemp` occur in unrelated passages and a whole-file grep passes while the recipe's own
rationale is gone. The COMMAND scan was not, and that made it presence-in-the-file rather
than presence-in-the-right-cell: transposing the `-b` and no-`-b` spellings between the
table's *Directory present* and *Directory gone* columns left both literals in the file, so
the model read the rule backwards with every check green — and moving the fenced recipe out
of step 4 entirely was invisible the same way. `T35-control` asserts an EXACT count, not a
floor: a floor survives deleting the `apply --stat` step from both carriers at once, which is
the edit the pin exists to stop. `T35b-control` guards both scans against an empty slice.

**`WORKTREE_ADVICE_COMMAND` / `adviceBlock` are a producer/consumer contract between one
array and two briefs.** A command line is one indented exactly two spaces; prose sits at
column zero. It is deliberately NOT a `git `-anchored rule any more — `CARRY_OVER` opens
with a `PATCH="$(mktemp …)" && …` line, and its copy loop carries `while`, `[`, `mkdir` and
`done` lines besides — and the widening cuts both ways: a prose line that acquires
a two-space lead-in is published inside a ```bash fence in two persisted briefs. `WT8p`
grades both directions structurally rather than against a verb allowlist. Before the
extraction the two briefs disagreed about the same array — `cmdHandoff` re-fenced per line,
`cmdTakeover` fenced nothing — so a recipe was runnable in one brief and prose in the other.
Contiguous commands coalesce into ONE fence, and it takes TWO pins to hold that — one per
renderer. `WT8q` drives `cmdTakeover` and `WT8q2` drives `cmdHandoff`, which is the call
site whose own comment names it as the origin of the per-line-fencing defect. One was not
enough and that is measured, not argued: with only `WT8q`, reverting `cmdHandoff` alone
left every check in both suites green. Both render a PRESENT-leg brief, which no other
fixture here does — every other one is directory-gone, and a single isolated command cannot
show coalescing at all. `WT8r` consumes those same two renders rather than making its own,
and covers the other axis: the `r.cwdExists` prose branches in both briefs, graded against
the gone leg so it cannot pass by rendering one branch twice.

**Coalescing is now a TWO-SIDED property, and both pins assert the split as well.** One
fence is one COPY BUTTON, so coalescing all four carry-over commands put the destructive
`git apply` in the same paste unit as the `grep` and the `apply --stat` that exist to gate
it — and the "these steps sit between the diff and the apply" argument is about execution
ORDER, which only holds if the human stops between the third command and the fourth. A
column-zero prose line breaks `adviceBlock`'s run, so the two READING steps still coalesce
(splitting those from each other would reintroduce the per-line fencing) while the
destructive line sits in a later fence of its own. `WT8q`/`WT8q2` grade both halves, because
either one alone is satisfied by the shape they exist to reject.

**A THIRD consumer renders the same array and no check reached it.** `cmdShow` prints every
line into a survey view with a nine-space prefix and no fence; when the carry-over recipe
landed the array grew from roughly six lines to dozens, so `show` began dumping a
paste-and-run recipe into the middle of the one output whose value is that you can scan it.
`worktreeAdvice(r, { carryOver: false })` returns the decision half only, and `cmdShow`
points at the briefs for the rest. The option is opt-OUT on purpose: the briefs are what a
human pastes from, and a new caller that forgets it gets more rather than less. The `--json`
payload is deliberately NOT summarized — it is a data carrier, and every `wt_case` in the
verdict suite reads the advice through it, which is what `WT8s` grades from both sides.

**The advice surface was NOT extracted into a `worktree-advice-v1.mjs` sibling, and the
decline is recorded here so it is not re-litigated from scratch — twice already a round
reported it as recorded when it was not.** The repo's own convention for an extracted module
is exactly that shape: `session-lineage-v1.mjs` sits in the same directory with its own
`node --test` file. Three facts argue for taking it. The unit file is already NAMED
`worktree-advice-v1.test.js`, for a module that does not exist. Importing the "pure" advice
surface evaluates `claude-path-v1.js`, `bash-source-write-parse.js` and `session-lineage-v1.mjs`
at load, because they are `trail.mjs`'s own imports. And `worktreeAdvice` can reach
`process.exit` through `fail()`, which is not a thing a library does to its importer.

What argued against taking it in the round that raised it is concrete rather than
conservative: `T35`'s extractor anchors `^const CARRY_OVER = \[`, `^function worktreeAdvice\(`,
`^\}$` and `^const WORKTREE_ADVICE_COMMAND` against `$TRAIL_MJS`, and that anchor set has
already gone dead once without a sound. Moving the constants re-points four anchors,
`T35_EXPECT`, this roster and the unit file's import in one edit.

**The trigger is a second importer, or the next change that has to re-point those anchors
anyway.** The move carries three obligations: re-home `livePid`, replace the `fail()` call
with a thrown error, and re-point the extractor.

**Known gaps, accepted and named:**

- **The rule is prose, not a gate.** Nothing stops a session working in another session's
  worktree; the source-write gate only refuses a COMMIT outside the anchor, which is the
  other axis. This change makes every rendered recommendation point at the taker's own
  worktree — it does not enforce one.
- **The carry-over's untracked half carries a hazard no git flag touches**, and it is now
  a RUNNABLE loop rather than a sentence. `ls-files --others --exclude-standard` reports a
  SYMLINK by name like any other path, so a copy follows it out of the worktree — in a
  repository you have not vetted, that is how a key or another checkout leaves its
  directory. The check is the PAIR `[ -f "$s" ] && [ ! -L "$s" ]`, and neither half is
  optional: `test -L` alone — which both carriers used to name as *the* check — is a symlink
  test offered as the implementation of a REGULAR-FILE rule, so FIFOs, device nodes and
  sockets pass it; `[ -f ]` alone FOLLOWS a symlink, which is the mirror defect and the
  obvious spelling a reader reaches for. **A HARD LINK passes BOTH halves and is an accepted
  RESIDUAL, not a case the pair closes** — MEASURED, a hard link is a second directory entry
  for a regular file. The review finding that prompted the loop, the first emitted wording and
  an earlier revision of this bullet all claimed otherwise; the two reader-facing carriers now
  state the residual and name the link-count test beside it. It is emitted rather than described because prose left the reader to
  improvise a loop that word-splits on a filename with a space. It still applies to copying
  by hand, because the "do not run this at all" escape does not answer it — and that escape
  now lives in the EMITTED array too, not only in SKILL.md, since SKILL.md is read by the
  model while the array lands in the brief a human pastes from. Pinned on both carriers, by different
  suites: `T35b` covers the SKILL.md copy, and `WT8m3`/`WT8m4`/`WT8m5` plus
  `tests/structure/worktree-advice-v1.test.js` cover the EMITTED text — the one that reaches a persisted brief,
  and the one `T35` cannot see, since its extractor matches command literals and these
  cautions are the prose beside them.
- **`adviceBlock` IS exported now, and its dormant branch has an executed case.** The
  `firstPrefix`-on-a-leading-command arm is still dormant by construction — every arm opens
  with a prose sentence naming its cause — and it exists so the helper does not silently eat
  `cmdHandoff`'s `- ` bullet the first time an arm is reordered. `trail.mjs` now guards its
  CLI dispatch on being the process entry point and exports FOUR names — `adviceBlock`,
  `worktreeAdvice`, `adviceLeg` and `WORKTREE_ADVICE_COMMAND` — so
  `tests/structure/worktree-advice-v1.test.js` drives that branch, an empty input and a
  single-line input directly. `adviceLeg` is the ONE implementation of the present/gone
  decision, and it exists because that decision has three consumers: `worktreeAdvice` picks
  its lead AND its body from it, `cmdShow` decides from the same answer whether to print the
  pointer at the recipe its survey view withholds, and `printResume` decides whether to print
  its own copy of the gone-leg create command. Every one of those was a hand-written
  `r.cwdExists` at some point in this feature's history, and one of them drifted INSIDE a
  single function — the lead came from `adviceLeg` while the body came from a raw
  re-derivation. Before adding a renderer that depends on the leg, grep `cwdExists`. The entry-point guard
  compares REALPATHS on both sides: an installed plugin root is routinely reached through a
  symlink, and a string compare would answer "not the entry point" for a genuine invocation,
  turning the whole CLI into a silent no-op — far worse than the import side effect it
  removes. The unit file is driven from `test-session-trail-verdict.sh`, because
  `tests/run-all.sh` discovers only `test-*.sh`; its case count is hand-maintained and EXACT
  there, for the same reason `T35_EXPECT` is.
- **The line-anchored citations from `docs/multi-repo-chains-*` into this skill broke THREE
  times during one change**, silently each time, because `test-multi-repo-doc-citations.sh`
  states in its own header that a citation landing on a different but still substantive line
  is invisible to it. `T36` in `tests/structure/test-session-trail-skill.sh` is the tripwire,
  and it lives in THIS skill's suite rather than in the docs' because the file that MOVES the
  target is this one. It pairs each citation with a needle naming the cited CONTENT; when it
  fails, re-derive the line and fix the doc — never weaken the needle. **Seven rows, across
  BOTH carriers**: grading only the spec was the first spelling, and it reproduced the very
  defect it was written for, since the overview HTML twins three of those citations and had
  already drifted once inside this change. One row hardcodes its own line number, because the
  spec cites `SKILL.md` twice and a generic regex cannot tell them apart — that row's regex
  moves with the citation, which fixing the doc alone does not do. It has since caught
  further drifts, from both carriers at once — the first time that class failed loudly
  instead of silently. No ordinal here on purpose: the drift count lives only in run logs,
  so a number written down would be hand-maintained and would go stale, which is the failure
  mode this file warns about elsewhere. `T36-control` derives the citation POPULATION by
  scanning both documents rather than counting its own rows, so a citation into this skill
  that no row covers fails loudly instead of being graded by nothing.
  `test-multi-repo-doc-citations.sh`'s header points here, because an editor working from
  the docs' side would naturally run that suite and a green run there says nothing about
  these citations. **Re-derive each citation PER SITE, never by pattern sweep.** A regex
  over `trail\.mjs:\d+` was used twice to update these and collapsed both HTML citations
  onto one number both times — the two `<p class="src">` lines carry no prose to key on, so
  a sweep cannot tell the `gitState` card from the `printResume` one. `T36` caught it on
  both occasions, which is the only reason this is a note rather than a shipped defect.
  A symbol-resolved citation format would remove the fragility rather than catch it, and is
  not implemented.
- **`--resume` still lands in the source worktree by design.** The printed resume line is
  unchanged, and `FRESH_SESSION_SOURCES` excludes `resume`, so a resumed session keeps the
  original anchor. `--fork-session` is the route whose anchor is the directory it starts in,
  and the only one where the own-worktree rule and the write anchor land on the same place —
  but only the HANDOFF brief and SKILL.md flow 3 step 4 name it. The takeover brief renders
  no resume line at all, so it does not, and any claim that "both briefs" name the fork is
  false. Either way it is guidance, not a mechanism.
- **The `noStore` branch of `unreadableWhy` is unreachable from `test-session-trail-verdict.sh`.**
  `$FAKE` is one directory for the whole run, and the `archive()` helper itself does the
  `mkdir -p` on the store path; its FIRST call sits in the top-level fixture-setup block,
  over two thousand lines before any WT8 fixture is graded. So the store exists by then and
  `r.ccdStore` can never read `false` there. Two wrong causes were written down before that
  one — the WT8 block's own `archive()` calls (which run AFTER the unreadable fixture is
  graded) and the W13 case's `mkdir -p` (which is real but not first) — so name the helper
  and its first call site, not a line number that moves. Pre-existing, predates this rule,
  and it means one of the two hedged wordings has no executed case anywhere.

## zen-mode Chain-Progress Anchor (`user-prompt-zen-mode.sh` rule 6)

Rule 6 of the zen-mode contract asks for a one-line progress anchor above the closing
next step. It lives in the hook, the skill, the operator doc row and EVERY
`evals/zen-mode-reaction/scenarios/*.yaml`, and `tests/structure/test-zen-mode.sh` pins all
of them — the count is deliberately not written out here, because the eval roster is DERIVED
from the directory and a hand-maintained numeral is exactly what a driven loop cannot catch: `hooks/user-prompt-zen-mode.sh` (the ACTIVE `additionalContext` directive — the
authoritative copy, re-injected every prompt), `skills/zen-mode/SKILL.md` rule 6,
`docs/configuration.md`'s `user-prompt-zen-mode.sh` hook row, and every
`evals/zen-mode-reaction/scenarios/*.yaml`, which embed the whole directive verbatim.
Z19b pins the directive carriers against each other, Z19c pins the extraction regex
across the two zen suites, Z19d pins the operator row.

**The anchor is deliberately DECOUPLED from `hooks/lib/zensu-autopilot-state.sh`.** An
earlier revision used that module's `STAGES` set as the label vocabulary, and review
found the copy already wrong in three ways: `GATES` (unconditional) was missing while
`VALIDATE`/`COVER` (gated on `state.options`) were listed, `AWAIT_TDD` was missing too,
and the four marks are linear while that machine is cyclic — `GATES`, `CONVERGE`,
`VALIDATE` and `COVER` all re-enter through `toAwaitTdd`, so a retried stage had no
defined mark. The rule now names the steps the SESSION observed plus the ones it told
the user it would take, and explicitly forbids copying a canonical pipeline out of
another component. **Do not reintroduce the coupling**, and note that the worked EXAMPLE
is part of it: a model copies the example before it obeys the prohibition beside it, so
the example's step names must belong to no shipped component (they are checked against
`.claude-plugin/plugin.json`'s skill list by hand — `implement` is a skill and `verify` is the stem of `verify-feature`,
`fetch`/`parse`/`render` are not).

**Five couplings fire in the UNOBVIOUS direction**, the same shape §"Gate-Disable
Prefixes" records for G12 — an ordinary edit elsewhere reddens a suite named for the
zen-mode hook, and nothing points at it from the side that changes:

- Z19b DERIVES its eval carrier roster from `evals/zen-mode-reaction/scenarios`, so
  ADDING or REMOVING a scenario reddens this suite. Both halves are real only because
  the floor is taken from the count `promptfooconfig.yaml` REGISTERS: an earlier
  spelling floored on a bare absolute literal, so deleting a scenario together with its
  registration left a consistent smaller world in which nothing turned red — and this is
  the ONLY CI-run check that reads that directory, the sibling that compares against the
  config being local-only. The derivation must be able to fail LOUDLY when it derives
  NOTHING: a `registered > 0` conjunct guarded the comparison at first, so a changed
  registration spelling silently dropped the floor back to the absolute one. Measured
  against a fixture, the same real loss reported
  `eval-dir:4-scenarios-but-config-registers-5` with an intact config and reported []
  once the spelling moved. It pushes `eval-config:registers-only-N` below three and then
  compares unconditionally.
- `tests/structure/test-best-solution-first.sh` B14/B14a/B14b pin THIS directive's SCOPE
  clause — its ranking obligation and the anti-inflation counterweight — so editing that
  clause reddens a suite named for the best-solution-first hook, with nothing in this
  section pointing at it. Note the boundary: a rule-6-only edit does NOT trip B14, so the
  coupling is invisible until the day someone condenses the whole directive.
- Z19c binds `tests/structure/test-promptfoo-zen-mode.sh` and compares the
  ACTIVE-directive extraction regex SOURCE, so editing that suite reddens this one.
- Z19d greps the `docs/configuration.md` hook row and anchors on
  `^\|\s*`user-prompt-zen-mode\.sh`\s*\|`, so rewording that row — or renaming the hook
  file — reddens this suite.
- Z29 drives `tests/structure/zen-anchor-assertions.test.js`, which derives its scenario
  roster from that same directory and pins each anchor scenario's grader COUNT and its
  pass/fail VECTOR. So adding, removing or reordering a grader inside a scenario reddens
  this suite. TWO floors guard the unit file and they count different things — do not
  conflate them, as an earlier revision of this bullet did. `Z29_FLOOR` lives in
  `test-zen-mode.sh` and counts `test()` REGISTRATIONS; the per-table `floor:` values live
  in the unit file and count CASES. Both fire on REMOVAL only: adding a case or a test
  cannot turn either red, so raising the matching number in the same commit that adds one is
  a CONVENTION the file states in its own comment, not an enforcement — the same convention
  `test-session-trail-skill.sh` T22 records. `Z29_FLOOR` sat at 3 against a file of 6 and
  admitted the deletion of every case that actually executes a grader; the per-table floors
  were added after three cases were landed in one round without a test, which left each of
  them deletable with everything green. WHICH CEILING PAYS for the driver, stated because
  both sibling sections state it for theirs and re-deriving it is a grep across four
  manifests: `test-zen-mode.sh` has NO `windows-ci.v1.json` entry — it is in that profile's
  sibling `windows-native-structure.v1.json` `excluded` list with a reason — so no per-suite
  Windows cap can be blown here, and its `node --test` cost lands on the ubuntu shard
  partition through `ci-shard-weights.v1.json`, at the unchanged `defaultSeconds`. That file
  calls its own numbers a balance hint on which coverage never depends.

**The safety carve-out rides in the SAME directive string as the anchor**, and P8 in
`test-promptfoo-zen-mode.sh` — the only full-fidelity check that the eval copies match
the hook — is `localStructureTests` and never runs in CI (`run-all.sh --ci` skips it).
Z19b therefore carries three carve-out needles applied to the whole-directive carriers
only, NOT to the `skill` carrier, which is sliced to rule 6 while the carve-out is rule 9.
Without them a reworded carve-out would leave `safety-carve-out.yaml` grading a directive
no session receives, with every CI suite green.

**A run-time seam exists for the carrier problem and was DECLINED, deliberately.**
`hooks/lib/rule-block-v1.js` exports `readRuleBlock`, and both
`hooks/session-start-evidence-discipline.sh` and `hooks/user-prompt-best-solution-first.sh`
consume it instead of holding a copy; `/zensu:doctor` already renders a `rule carriers:`
row for those two. Adopting it here would move the directive into a markdown block, delete
Z19c outright (neither suite would need a hand-copied extractor), and give zen-mode an
operator surface that can tell "stopped injecting" from "user turned it off" — which it
currently has none of. The cost is real on both sides and is why it was not taken in this
change: a malformed block drops the injection SILENTLY, which for zen-mode means the mode
quietly stops; every eval `spec_block` copy still needs its own text regardless, so it
removes one copy and not all of them; and it is a migration commit of its own rather than a
line in a fix. **The fact that actually settles the cost is a BOUND, and an earlier
revision of this paragraph omitted it:** `hooks/lib/rule-block-v1.js` declares `MAX_BLOCK`
and refuses a larger block, and `Z30`'s floor for this directive — its declared ceiling
minus its declared headroom — sits ABOVE that constant, so EVERY admissible directive
length is over the shared reader's limit. The comparison is stated qualitatively on
purpose: §"Marker-Block Carriers" above says to name that constant and never to spell its
value, because a prose copy of the number goes stale silently, and the copy it already had
to remove from `docs/architecture.md` is the precedent. Adopting the seam is therefore not "a migration commit of its own" but a
re-decision of a bound shared with the two always-on marker-block carriers, which is a
larger change than the paragraph implied and lands squarely in the silent
dropped-injection failure it warns about. Recorded so the next reader knows the
alternative was weighed, not missed.

**The injection is now BOUNDED, and that is what makes the figures maintainable.** `Z30` in
`tests/structure/test-zen-mode.sh` measures the emitted directive through `node`
(`String.length`, because the text carries four non-ASCII marks and `${#var}` counts bytes
or code points depending on locale) and holds it one-sidedly: growth past the declared
ceiling fails, and so does a shrink further below it than the declared headroom, because a
ceiling that has drifted away from its text has stopped being a tripwire. The rule 6
rewrite took the directive from 2951 to 4664 characters — 57% — with nothing observing it.

**Known gap, accepted:** the KB/KiB totals in `docs/architecture.md` are still hand-derived
from that character count, so they age whenever the directive moves even though the count
itself is now pinned. They were corrected in this change (4664 + 1764 ≈ 6.3 KB per turn),
and the `C6` attribution error in the same paragraph — it named
`tests/structure/test-best-solution-first.sh`, which contains no `C6` — was corrected with
them.

**Version: `patch`.** Walked against §"Runtime Lineage (`version_type` is load-bearing)"
entry by entry: no context-record or workflow-state schema field, no strict key set, no
hook added, removed or renamed and no matcher changed, no new config key (`zenMode` and
`zenModeDefault` are pre-existing), and no attestation change. The hook's only output is
`additionalContext`, which is exactly the ADVISORY shape the hook-inventory exemption
names, and it returns no `permissionDecision` in either direction. Two things read like a
breaking change here and are not, which is why the walk is written down rather than left to
be re-derived: the runtime digest DOES move, because `manifestRuntimeEntries` folds `hooks`
and `docs` in wholesale — but `readContextInternal` measures the RECORDED root — and the
directive is stateless, re-emitted from the executing tree on every prompt, so nothing
persisted crosses the upgrade. The only per-session artefact zen-mode owns is the
`{"active":true|false}` marker, whose shape is untouched. Choosing `minor` would be
actively harmful rather than merely wasteful: while the plugin is at major `0` the minor is
the breaking axis, so it would refuse every in-flight session until the user ran
`/zensu:adopt-session --confirm`.

## Pull Request Workflow

**Never commit or push to a closed or merged PR's branch.** Once a PR is merged or closed, its branch is dead — additional commits there belong on a new branch with a new PR.

**Re-check immediately before EVERY push, not once per session.** A PR can flip from OPEN to MERGED between two of your commands (the user, a teammate, or an auto-merge can land it). Treat each push as a fresh interaction:

```bash
gh pr view <num> --json state,mergedAt
```

If `state` is `MERGED` or `CLOSED`, **abort the push**:

1. `git fetch origin main`
2. Create a new branch off `origin/main`
3. Cherry-pick or re-author the change onto the new branch
4. Push the new branch and open a new PR

A `gh pr list --head <branch>` check is not sufficient — it does not distinguish OPEN from MERGED/CLOSED. Read the `state` field explicitly.

This applies to AI agents and humans alike. The `/create-pr` slash command's "PR already exists for this branch" guard does NOT cover the merged-branch case. "I just rebased ten minutes ago" is not a substitute for the check — re-run it every push.

**Every plugin-opened PR body carries an Acceptance Criteria table.** The shared, repo-overridable template is `templates/pr-body.md` (resolution: `.zensu/templates/pr-body.md` at the working-tree toplevel, else `${CLAUDE_PLUGIN_ROOT}/templates/pr-body.md`). Its `## Acceptance criteria` table takes one row per stable `AC-###`/`FR-###` id read from the feature's TDD plan `## Requirements` table via `hooks/lib/zensu-plan-requirements.sh` (exit 0 = usable); when no usable table exists the template's single stub row stays in place — never ship an empty table. Both PR openers honor this: `/zensu:pilot` renders `pr-body.md`, and `/zensu:autopilot` uses its richer `autopilot-pr-body.md` variant (the same table plus the build-time bypass-ledger audit line).
