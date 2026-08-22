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

**THREE WRITERS apply it, and the third exists because the first two cannot be
enough:** `zensu-log.sh append` (the narrative log, at write time),
`hooks/post-bash-witness.sh` (the witness `cmd` — see the symmetry rule below), and
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
closes the same swap one component higher), and never truncates in place. `O_TRUNC`
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

**Coupled sites that move together:** the module's `ARTIFACT_BUCKETS` / `ARTIFACT_DIR`,
which are module-INTERNAL — `post-artifact-redact.sh` consumes the layout TRANSITIVELY,
by calling `sweepTargets` and `resolveArtifactTarget` rather than joining
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
`docs/architecture.md`, which `test-readme-hook-count-sync.sh` does NOT cover); the
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
  `--tdd-complete`'s three scope `git` calls run through a subshell that unsets `GIT_DIR`,
  `GIT_WORK_TREE` and `GIT_INDEX_FILE`; the `--chain-done` zero-change terminus in the same file
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
Anything below forces the breaking bump, because a running session would
otherwise be served by a runtime that cannot read what it wrote:

- the context record or workflow-state **schema** (`SCHEMA_VERSION`, any field
  added, removed or retyped);
- **any strict key set** — `reviewRearm`'s `exactKeys`,
  `deferredReviewCancellation`, and every other validator that rejects an
  unknown or missing key rather than ignoring it;
- **removing or renaming a registered hook, or changing a hook's matcher**;
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
close it:** `discardSupersededLeases` moves every lease naming the previous
installation OUT of the records directory (into a sibling `superseded/<key>/`,
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

Seven conditions are ALL required; eight refusal reasons name exactly which one
failed (condition 6 can fail as either `executing-runtime-unidentified` or
`executing-runtime-older`):
`record-unreadable`, `plugin-data-mismatch`, `project-root-mismatch`,
`already-served`, `not-a-sibling-installation`, `executing-runtime-unidentified`,
`executing-runtime-older`, `workflow-schema-mismatch`. `plugin_data` and the
sibling bound are NOT relaxed here either — the latter is what keeps a
`--plugin-dir` checkout from adopting an installed session.

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

**The whole feature needs the SUPERSEDED installation to still be on disk.**
`validateContext` canonicalizes `context.plugin_root` and `readContextInternal`
recomputes the digest against it, so an absent recorded root makes `readContext`
throw — and then `resolveIncompatibleRuntime` answers null, the doctor falls back
to the `unbound` row whose "no valid record" wording this work exists to remove,
and `adoptableRecord` refuses as `record-unreadable`. The diagnosis degrades to
the misleading wording exactly when the repair is impossible. Do not describe the
lineage row as covering every mid-session upgrade; it covers the ones whose
previous version was not pruned.

**Three re-encodings move with this, and none of them is checked by a test:**

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
  destination guard landed — that module's `ensurePrivateDirectory` policy and its
  `LEASE_ID_RE`. Four copied elements, not one. The stated reason is narrower than
  it looks: a core -> lease CALL would cycle (that module requires the binder,
  which requires this core), but an ENTRY-POINT seam would not, because
  `zensu-session-adopt.sh` already requires both. The real cost of the seam is
  that it moves the sweep from the core half to an eighth host obligation. If this
  function needs a fourth correction, take the seam. The source `lstat`'s ENOENT
  branch is also the silent one: it cannot tell "no lease was ever minted" from a
  layout that moved, so a layout change makes the sweep a SILENT no-op.

**Port-relevant.** The core half is `adoptableRecord` / `adoptContext` /
`discardSupersededLeases` / `executingPluginVersion` / `adoptionWorkflowStatePath`
plus `ADOPTION_REFUSALS`, in the cross-host `session-control-core-v1.js`. The host
half is SEVEN separate obligations, and a port that takes only the core delta gets
`adoptContext` with no reachable caller and keeps the wedge: the entry script, the
recognizer's `RECOGNIZED` entry, the doctor branch and row, the Stop release, the
deny scope at every gate that denies in this state, the skill, and — easy to miss
— a binder exporting a `privateRecordsDirectory` equivalent that applies the
symlink/alias/permission/ownership checks, because the entry script resolves the
records directory through it and never by hand-joining. A port that copies only
the script gets a TypeError rendered as the wrong refusal. `zensu-codex`,
`zensu-kiro` and `zensu-antigravity` were NOT included in this change.

**The Windows timeout for `test-versioned-plugin-upgrade.sh` is now UNMEASURED.**
It was raised 600000 -> 900000 when Part C added roughly five synthetic installs
and four session lifecycles, but no Windows wall clock was taken — unlike the two
suites this file records a measured figure for. Budget against a measurement
before trusting the headroom. The caveat lives here and NOT in the manifest:
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

- **A deny from ANY hook on a matcher wins.** `hooks.json` registers three PreToolUse
  hooks on the `Bash` matcher (`pre-bash-zensu-gate.sh`, `pre-bash-source-write-gate.sh`,
  `pre-write-secret-scan.sh`) and one on `.*` (`pre-reviewer-capability-gate.sh` via
  `reviewer-capability-v1.js`). `/zensu:doctor` runs through Bash, so it is reachable only
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
`zensu_session_incompatible_runtime` / `..._model`). The orphaned wrapper **prints the
dead path on stdout** and the incompatible-runtime pair prints `recorded<TAB>executing`;
inside a PreToolUse gate stdout is the JSON decision channel, so a caller wanting the
predicate alone must discard it explicitly, and a caller wanting the value must capture
it into a variable before emitting anything.

**The third predicate is a DIAGNOSIS, never a third relaxation.** `zensu_session_incompatible_runtime`
belongs to this roster only because every gate that consults the two above must decide what
to do about it too — and the answer is the same everywhere: keep denying. A workflow document
is still reachable in that state, so relaxing would waive a live guarantee rather than a dead
one. What it changes is the MESSAGE: `zensu_emit_hook_session_deny` gained a fourth scope,
`incompatible-runtime`, taking the two versions as positional arguments. FIVE gates can deny
in that state: the four shell gates emit that scope, and `pre-reviewer-capability-gate.sh` —
the `.*` matcher, where `isRecognizedInvocation` is false for every non-Bash tool — spells the
same cause and remedy itself in JS, because the shell emitter is not reachable from it. A gate
left on the generic text tells the user to start a fresh session while its sibling says the session can
be repaired in place — two denies contradicting each other about the one bind failure that
has an in-place remedy. The Stop hook is the single exception and RELEASES, because it cannot
read the chain from an unbound session at all.

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
the tables rather than listing them, for the same reason; they are not pinned.

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
back unchanged — and both consumers apply their own policy on top: its own
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
predicate exists in `session-control-core-v1.js` and `review-evidence-lease-v1.js`,
with an UNANCHORED `startsWith("..")` variant in `finding-verify-v1.js` that has the
`..bak` defect this gate fixed. Unlike `within()`↔`isInside`, `WRAP` is NOT pinned
against its `pre-bash-zensu-gate.sh` copy — check that one by hand. And
`skills/pr-team-review` Phase E depends on `worktree remove` being judged on the tree
it destroys rather than on the addressed repository — narrow that carve-out and the
skill's documented cleanup starts denying, which is what W181/W185-W187 exist to
catch. That flow also depends on rule (B)'s temp carve-out, so `ZENSU_BSWGATE_TEMP_DIRS`
silently governs whether the shipped cleanup passes. Do not "fix" a deny there by
writing `ZENSU_BASH_WRITE_GATE=off` into a skill: a
shipped escape prefix teaches the hatch and lands a self-inflicted bypass-ledger entry.

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
(`hooks/lib/zensu-doctor-report.js`), the ticket issuer, and the rearm writer
(`_tdd_rearm_autopilot_review_critical`, which takes `isLinkId`, `RETURN_STAGES` and
`REARM_MARKER_KEYS` from here) — adding a receipt field or a return stage in the writer
alone would make every receipt it mints classify as stale and wedge the chain permanently.

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

Five things are coupled and must move together:

- **`DENIAL_MARKERS` are host literals**, read out of the installed Claude Code
  binary (`DENIAL_MARKERS_SOURCE_BUILD` = 2.1.231: `Permission for this action was
  denied by the Claude Code auto mode classifier.` and `Permission for this action
  has been denied.`). The build is exported and pinned against the module header,
  so the constant cannot drift away from the provenance note beside it. They are
  matched as PREFIXES because the host appends its own `Reason: ...` tail. A host
  that rewords them silently disables the diagnosis — re-verify against the
  binary, never against memory. The `kind` values are re-encoded in exactly TWO
  places outside the module: the `case` arms in `hooks/stop-chain-enforcer.sh`
  that render cause and remedy, and the closed set `reviewerDenialRows` accepts
  from a note. The hook's PROBE deliberately holds no third copy — it reads `kind`
  as a field, so a marker added to the module reaches the doctor under its real
  name with no shell edit, where the old closed set degraded it to the empty
  string and made the doctor render `unclassified` for a refusal both sides could
  already name. Adding a marker still means adding a remedy arm; without one the
  refusal renders unclassified, which is a degraded message rather than a wrong
  one, because the unknown arm is the safe arm. Reading the field is safe only
  while the value stays a `case` SELECTOR: interpolate `REVIEWER_DENIAL_KIND` into
  the reason string and module output becomes operator-visible text.
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

**The Windows budget for this suite is MEASURED, and the measurement is a RANGE.**
Two green runs of byte-identical suite content reported `stop-enforcer-self-review-routing`
at **985846 ms** and **1274496 ms** — a 29% spread on the same GitHub runner class, so a
single sample here says nothing about headroom. Budget against the HIGH figure: at
`timeoutMs: 1500000` in `tests/profiles/windows-ci.v1.json` the slow run consumes 85% of
its own cap. The previous ceiling of 1200000 sat BELOW that high sample and the suite
was killed by it, which is exactly the failure this range exists to prevent.

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
implementation not complete, chain closed), both inner-guard escapes
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
variable is a retired ambient root the repo pins as non-authoritative, and the only
reader resolves the directory from `CLAUDE_PROJECT_DIR` — honoring an override would
write the note where `/zensu:doctor` never looks and aim an unlink outside the
session-bound directory.

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
in `docs/configuration.md`.

**Port-relevant.** Every constant here is host-coupled: a port copies
`DENIAL_MARKERS`, `SPAWN_TOOL_NAMES` and the transcript envelope
(`message.content[]`, `tool_use`/`tool_result`, `tool_use_id`, `input.subagent_type`,
`is_error`) into its own file and re-decides them against its harness — a port that
takes only the module inherits Claude Code's literals and will silently never fire.
The host half — which payload field carries the transcript, where the note lives, and
the doctor row — is re-decided per host. `scanTranscript(path, options)` takes
`subagentType` so a host with a different reviewer name needs no fork of the walk.

**Known gaps, accepted and deliberate:**

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
