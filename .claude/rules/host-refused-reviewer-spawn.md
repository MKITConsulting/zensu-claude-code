---
paths:
  - "hooks/lib/reviewer-spawn-denial-v1.js"
  - "tests/structure/reviewer-spawn-denial-v1.test.js"
  - "tests/structure/test-stop-enforcer-self-review-routing.sh"
---

# Host-Refused Reviewer Spawn (`hooks/lib/reviewer-spawn-denial-v1.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

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
  literal lives in TEN files under `hooks/` (34 matching lines, measured 2026-09-23),
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
  over two facts stated here, not an independent claim. No check measures these figures,
  so re-count with the grep above before relying on them. Rename the agent in one place only and
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

**IT DID REPORT `TIMED_OUT`, and the prediction above held exactly.** On the PR carrying
the workflow-baseline repair, `windows-shard-7` reported
`TIMED_OUT stop-enforcer-self-review-routing (1500157ms)` against its own 1500000 cap while
the same shard was GREEN on `main` — so the content this suite scans grew past the edge the
paragraph above says it was sitting on. The remedy was NOT to raise the cap inside the
shard: the sibling `review-worker-evidence-lease` measured 158850 ms on that run, so the
1800000 shard budget left roughly 141000 ms of room and a raise would have bought 9% against
an unknown requirement. The SIBLING moved instead, to `windows-shard-8`, which measured a
196 s job against the same 1800000 budget after `session-trail-lineage` came down to 154673 ms
— the same rebalance-rather-than-add move this file records for that suite, and it costs no
new CI job because a suite moving between existing profiles changes no key in
`expectedProfiles`. `stop-enforcer-self-review-routing` now holds `windows-shard-7` ALONE at
`timeoutMs: 1740000`, deliberately below the 1800000 profile budget so an overrun still
surfaces as a visible suite `TIMED_OUT` rather than as a profile abort that truncates the
tail silently.

**The green figure arrived on the very next run and is now the one to budget against:
`PASSED stop-enforcer-self-review-routing (1482704ms)`**, alone on `windows-shard-7`, with
the whole shard job at 1579 s. Two things about it are worth keeping. It is BELOW the
1500000 cap the previous run breached at 1500157 ms, so the failure was the documented 29%
spread landing on its slow side rather than a step change — which is exactly why a single
sample must not be read as headroom. And 1482704 against 1740000 is **85% of cap**, the same
share this section already called too tight at the old ceiling; the difference is that the
suite now holds the shard alone, so the only other bound is the 1800000 profile budget it
no longer shares. Treat further growth here as needing a shard of its own, not another
raise. The sibling measured `PASSED review-worker-evidence-lease (113321ms)` on
`windows-shard-8`, whose two suites together came to roughly 265 s against 1800000.

**The shard budget is the SECOND ceiling, and it binds first — though on the run that
forced the rebalance above it was the SUITE cap that bound, not the shard.**
`windows-shard-7`'s
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
