---
paths:
  - "hooks/lib/verify-consent-v1.js"
  - "hooks/lib/verify-navigation-floor-v1.js"
  - "hooks/pre-browser-navigation-consent.sh"
  - "hooks/post-browser-navigation-consent.sh"
  - "scripts/playwright-mcp-proxy.js"
  - "scripts/playwright-mcp.sh"
  - ".mcp.json"
  - "skills/verify-feature/**"
  - "tests/structure/test-verify-consent.sh"
  - "tests/structure/verify-consent-v1.test.js"
  - "tests/structure/verify-navigation-floor-v1.test.js"
---

# Browser Consent Gate (`hooks/lib/verify-consent-v1.js` + the two consent hooks)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

`/zensu:verify-feature` used to require a launch-time `ZENSU_VERIFY_NAVIGATION_POLICY_V1`
before any browser call, which no end user can supply: the broker reads it once when the MCP
server starts, so no in-session Bash call can configure it, and the desktop app has no shell
prefix at all. The gate replaces that precondition for LOOPBACK targets with a host-rendered
permission prompt the model cannot answer. Remote targets still need the policy, and that is
not a limitation to engineer away: Chromium's DNS pins are passed at browser launch, so an
origin approved mid-session could not be pinned.

**A PreToolUse hook was chosen over MCP elicitation because the desktop app has no elicitation
channel** (CLI-only since 2.1.76). The decision module is shaped so elicitation can replace the
prompt later without changing the memory or the wording.

**The broker's MCP server key is `zensu-browser`, unique on purpose, and the matcher keeps both
spellings of it.** The gate is registered on the tool NAME,
`mcp__(plugin_zensu_)?zensu-browser__browser_(navigate|tabs)`. The key used to be `playwright`,
which is also the default key of upstream `@playwright/mcp`, so the optional plugin-scope group
matched every foreign server keyed `playwright`: the gate applied this plugin's loopback-only
floor to a user's own browser server and denied its remote navigations in every session, with no
skill running. `/zensu:verify-feature` and `/zensu:doctor` also accepted that foreign server as
the broker. Renaming the plugin's OWN key closed all of it without narrowing anything, and the
foreign-server deny note retired with the collision it explained.
**Do not answer a future collision by narrowing the matcher to the plugin-scoped spelling.** Two
facts forbid it. The bare spelling is real for this plugin: the manifest declares
`mcpServers: "./.mcp.json"`, and when this repository is opened as a project that same file loads
as a project-scope server under the bare name — measured, not inferred. That ordinary load fails
to start (see the residual below), so the bare matcher arm is DEFENSE IN DEPTH rather than a
spelling a running broker is known to carry: a broker runs under the bare name only where the
declaration starts outside the plugin loader with a resolvable command — `${CLAUDE_PLUGIN_ROOT}`
resolving because that variable is present where Claude Code expands `.mcp.json`, or the
declaration copied into another MCP scope with a real path. Neither launch was measured here. And
`hookRegistered` in `scripts/playwright-mcp-proxy.js` compares only the matcher STRING and never
sees the server name, so a broker launched under a spelling the matcher does not cover still
starts in consent mode with no gate, where it approves any loopback origin that holds a live
execution marker — and the broker's own marker read carries no session key, although the marker
NAME embeds one. A unique key keeps both spellings gated. **It is a naming CONVENTION, not a
server identity:** a foreign server keyed `zensu-browser` would still match the gate and would
still be accepted as the broker by `/zensu:doctor` and `/zensu:verify-feature`. The rename makes
a collision unlikely rather than impossible, and that look-alike case is a residual. Claude Code's
MCP documentation states that a hook matcher written against the bare server key never fires for
a plugin-bundled server, which is why the plugin-scoped spelling is the one an installed plugin
produces. `tests/structure/verify-consent-v1.test.js` pins that a server keyed `playwright`
reaches no decision and that no refusal names one; `tests/structure/test-verify-consent.sh` V21c
pins the first half through the hook, judged on the hook's exit status as well as its output,
and V21d the second half on the broker's real remote refusal.
**Known residual:** root `.mcp.json` still loads as a project-scope server whenever this
repository is opened as a project, where `${CLAUDE_PLUGIN_ROOT}` is unexpanded and the server
fails with ENOENT. It no longer hides anyone's `playwright` server. Inlining `mcpServers` into
`.claude-plugin/plugin.json` would remove it; that touches every suite that copies `.mcp.json`
into a sandbox plugin tree plus the doctor's config-integrity check, and is not done here.

**The prompt must describe the grant the BROKER makes, not the one the hook asks about.** This is
stated as a RULE, not as a live divergence — both now ask per origin, and the paragraph below
records why. It is kept because the divergence is the easy one to reintroduce: the broker stores
the classified ORIGIN and checks no route afterwards, so any future prompt promising a narrower
grant than that would have the human decide on a false description. The sentence names the origin
and says the browser does not check routes again.

**CONSENT IS PER ORIGIN, in all three carriers, and the route-scoped design that preceded it is
recorded here so it is not rebuilt.** The first attempt asked per route while the PROMPT told the
human a Yes opened the whole origin and the BROKER checked only the origin (`assertAllowedUrl`
tests `policy.approved.has(target.origin)` and returns before any route test). Three components,
two contracts. The route half then carried its own defect: a record was stamped with a fresh read
of the LIVE recipe on every write, INCLUDING writes for navigations that were never prompted, and
the silent-allow arm tested the union of those sets — so a session could widen the recipe, drive
one already-allowed route, and launder a new route into the silently-allowed set with no human in
the loop. Binding the set to the prompt would have fixed that one defect and left the three
carriers still disagreeing. Removing the route axis fixes both: a record is exactly
`(origin, route, decidedBy, at)`, the route is an audit line, and the recipe's declared routes are
prompt CONTEXT only. The cost is stated rather than hidden — there is no per-route control inside
an approved loopback origin, which is what the prompt has always promised.

**`isSymbolicLink()` beside an `lstat` verdict is DEAD, and this is a SHAPE, not a census.**
`fs.lstatSync` does not follow the final component, so it never reports a symlink as a file or a
directory: wherever this feature writes `!info.isFile() || info.isSymbolicLink()` or
`!info.isDirectory() || info.isSymbolicLink()`, the first half already decides and the second is
unreachable. It also protects nothing against the edit it looks like a belt against — an
`lstatSync` → `statSync` "simplification" makes `isFile()`/`isDirectory()` true for a symlink AND
`isSymbolicLink()` false, so the conjunct dies with the guard it appears to back up. The conjuncts
are left in place; what must not happen is a reader treating one as load-bearing. Do NOT enumerate
the sites here — a first attempt named one and a reviewer found eight, which is exactly how a prose
census goes stale. Grep `isSymbolicLink()` across `hooks/lib/verify-consent-v1.js` and
`scripts/playwright-mcp-proxy.js` before relying on any of them.

**One resolver decides which recipe governs.** `resolveRecipeFile` prefers `.zensu/runtime.yaml`
over `.zensu/autopilot.yaml` and skips a symlinked candidate. Both hooks and the `/zensu:doctor`
row consume it; the ladder used to be spelled three times, where a one-sided edit made the pre
hook decide against one file while the post hook recorded against another. **The two anchors
still differ and that is a stated bound, not an oversight:** the hooks resolve the project root
from the immutable record, the doctor from the session root or the harness value.

**`--config=<path>` steers the SKILL and is invisible to the gate**, so a recipe passed that way
declares no synthetic-safe routes to the prompt. Stated in the operator doc rather than closed.

**The declared routes come from the guarded recipe read and from nowhere else.** An environment
override sat in `readInputs` and short-circuited the branch carrying the lstat, symlink and size
guards, with no production producer and neither hook clearing it. It is deleted; a test that
needs routes writes a real recipe.

**The consent line sits BELOW the sessionBanner gate**, unlike the reviewer-spawn grant line
above it. The distinction is what the line reports: the grant announces a capability the plugin
hands itself, which a checked-out config must not be able to hide; consent announces that a
PROMPT will appear, which is a usage hint. Hiding it costs the user a hint and hides nothing.

**Coupled sites that move together:** the `zensu-browser` server key in `.mcp.json` against
`BROWSER_SERVER_KEY`, its one owner in the decision module. Only three readers DERIVE from that
export — `CONSENT_MATCHER` / `NAVIGATION_TOOL_RE` in the same module, and the key
`playwright_mcp_declared` reads in `hooks/lib/zensu-doctor.sh`, which takes it from the executing
installation's module rather than spelling it. Every other carrier is a HAND COPY: both matcher
registrations in the hook manifest, the accepted namespaces in `skills/verify-feature/SKILL.md`
and `skills/doctor/SKILL.md`, `BROWSER_NAMESPACES` in
`evals/verify-feature/assertions/transcript-check.js`, and the Session Control mutating-control
canary in `scripts/session-control-claude-wrapper.sh`, `evals/session-control/lib/live-evidence.js`,
`evals/session-control/lib/evidence-worker-contract.js` and
`evals/session-control/tests/wrapper-selftest.sh`. They are pinned rather than derived, and the pin
list has to cover every carrier the sentence above names or a carrier reads as unheld: the unit
suite holds the export against `.mcp.json` and the matcher, `V4` in
`tests/structure/test-verify-consent.sh` holds BOTH hook-manifest registrations string-equal to
the module's `CONSENT_MATCHER`, the near-match case in
`tests/structure/verify-feature-transcript-check.test.js` holds `BROWSER_NAMESPACES` against the
exported key, `P6l` holds the verify-feature skill, `P2l` the doctor skill, and the selftest stub
refuses a wrapper whose canary prompt or probe agent names a different tool. The DERIVATION
itself is held too, and it was not: `P1el`/`P1el2`/`P1el3` in `tests/structure/test-doctor.sh`
extract `playwright_mcp_declared`'s body and require it to name `BROWSER_SERVER_KEY`, to carry no
literal `zensu-browser`, and to guard the module the way every other consumer does — without
them, reverting the doctor to a hand copy kept every suite green, because `P1ek` asserts an
output message a literal satisfies identically. The key itself is REFUSED at load unless it is
regex-inert (`/^[a-z][a-z0-9-]*$/`): it reaches a `RegExp` source while the hook manifest carries
the same matcher as a literal the host compiles, so a metacharacter would make the two readers
disagree about which tool names are gated, and a quantifier would narrow the module's own test
until every navigation read as "not a navigation" and the host took the silence as allow. **A grep for `zensu-browser` does NOT find every carrier.** The `.*`
capability gate in `hooks/lib/reviewer-capability-v1.js` treats any tool name matching
`/^mcp__.*zensu/i` as a Zensu MCP tool and denies host-profile-v1 every one whose operation is not
on its `ZENSU_MCP_READ_RE` prefix list, which no browser operation is — even `browser_snapshot` —
so it denies neutral subagents the broker under BOTH spellings — the plugin-scoped one through
`plugin_zensu_`, the bare one only because the key happens to contain `zensu`. The retired bare
`mcp__playwright__*` never matched. A future key without `zensu` in it would silently hand neutral
subagents the bare broker; `tests/structure/test-reviewer-capability-gate.sh` pins both verdicts,
the deny reason, and the foreign `playwright` server staying allowed. That reason had to move
with the rename: it read `cannot invoke mutating Zensu MCP tools`, which promises a non-mutating
variant that would pass, and no browser operation is on the read allowlist — so it now names the
allowlist itself, and the suite pins BOTH that wording and the absence of the word `mutating`. A SECOND carrier matches a FRAGMENT of that same reason and is easy to miss because it lives outside `tests/`: `evals/session-control/lib/contract-provider.js` passes it to `assertDenied`, and it is reached only by the `evals/session-control (self-check)` suite on a CI ubuntu shard. The rename shipped once with that fragment still reading `mutating Zensu MCP` — every local suite green, CI red on one shard. `CONSENT_MATCHER` also moves against the broker's own
`consentHookRegistered`, which reads the module's constant and compares it to the manifest —
so that check proves internal consistency and says nothing about how the host renders the
prefix; `RECIPE_NAMES` and `resolveRecipeFile` against the doctor's recipe probe;
`FLOOR_REASONS`, `CONSENT_REMOTE_REASON` and `normalizeRoute` in the shared floor, which the
broker and the decision module both consume rather than hand-copying — the remote sentence
lived in two files with no check comparing them; the memory filename shape against
`skills/verify-feature/SKILL.md`, which both spells that path and owns the report's `Consent`
block — the doctor renderer has no such block, and naming it there sent a maintainer to a file
that does not carry it; every doctor STATE against the rows documented in the doctor skill, which
a suite check holds in step — do not restate a COUNT here, because the next state added
invalidates it, and this roster already shipped one that was stale on the day it was written;
the doctor's three top-level policy guards, which used to be a hand copy of `parsePolicy`'s own
three throw messages and are now a CALL: `hooks/lib/verify-navigation-floor-v1.js` owns
`policyContractFault`, and `zensu-doctor.sh` and the consent gate both invoke it, so those two
cannot drift about what a usable policy is. The reason the doctor may call it is worth keeping,
because an earlier wording had it wrong: it is NOT that calling the owner would put DNS in a
read-only diagnostic, since `parsePolicy(raw, resolver)` takes its resolver as a parameter and
reaches DNS only for `mode: "remote"`. It is that a stubbed refusing resolver would report a
VALID remote policy as invalid, which is the one verdict a diagnostic must never invent — so the
PER-TARGET rules stay `parsePolicy`'s alone and the shared check is top-level only.
**The remaining hand copy is `parsePolicy`'s own**, which still spells those three guards itself
rather than calling `policyContractFault`, and it is no longer unpinned: the last test in
`tests/structure/verify-navigation-floor-v1.test.js` compares the two in BOTH directions — every
value the shared check refuses must be one the broker refuses or denies, and its thrown message
must equal `'navigation ' + policyContractFault(raw)`; every value it accepts must be one the
broker accepts, across `local`, `remote` and the eight-target upper bound, so a one-sided
TIGHTENING is caught as well as a one-sided widening. That pin fires in the UNOBVIOUS direction,
which is why `parsePolicy` carries a pointer comment naming it: an edit inside
`scripts/playwright-mcp-proxy.js` reddens a suite named for the floor module. **The uncompromised
fix is NOT taken:** have `parsePolicy` call `policyContractFault` and delete its three literals,
leaving one implementation instead of two kept in step by a test;
the EXECUTION-MARKER family, which this roster omitted for a round while the feature shipped:
`STATE_SEGMENTS` / `evidenceDirFor` (the one owner for the module's JS consumers — the broker
and the doctor wrapper consume it rather than joining the segments themselves. Say it that way
rather than as oneness: both consent HOOKS still hand-join the two segments in shell, and
`session-control-core-v1.js` declares its own `WORKFLOW_STATE_SEGMENTS` twin, so a layout change
is a multi-site edit),
`MEMORY_NAME_PREFIX` / `EVIDENCE_NAME_PREFIX` (the one owner of each half of the marker name FOR
THE MODULE'S OWN JS CONSUMERS — the regex, `evidencePathFor`'s substitution and
`liveEvidenceOrigins`' session filter are all built from it, because a one-sided edit there left
the writer working while the doctor's filter matched nothing and rendered the benign row. State
the qualifier: `MEMORY_NAME_PREFIX` is HAND-COPIED in both consent hooks, which each spell
`verify-consent-${ZENSU_SESSION_KEY}.json` in shell, so renaming it is a three-site edit and this
constant makes it neither one edit nor a loud failure — the hooks would build a path the module's
own `MEMORY_NAME_RE` then refuses. `EVIDENCE_NAME_PREFIX` has TWO code carriers besides its owner — the
proxy's `truncated` refusal and the renderer's `unjudged` row, both of which spell the marker
glob into a sentence a model reads — and its literal is restated in FOUR operator accounts:
`docs/gates.md`, `docs/verify-feature.md`, the `pre-browser-navigation-consent.sh` row in
`docs/configuration.md`, and `skills/doctor/SKILL.md`. Treat that as a census taken at one moment
rather than a bound the suite holds: `grep -rln 'verify-consent-exec-'` over `hooks`, `scripts`,
`docs`, `skills` and this file is what settles it) / `EVIDENCE_NAME_RE` / `evidenceOriginTag` / `evidencePathFor` /
`evidenceStatUsable` (the STAT-level half of the liveness rule, owned ONCE: the reader refused
`nlink !== 1` while the reaper's own predicate checked only the size, so a live hard-linked
marker was refused by every reader AND reported honourable by the sweep — unreadable and
unreapable at once, holding a walk-budget slot the sweep exists to free) /
`evidenceBodyLive(parsed, now, maxAge)` (the BODY half, owned once for the same reason — unifying
only the stat rule left the version/origin/stamp/re-classification/verdict/age ladder spelled
twice. Its WINDOW is a parameter because the two callers legitimately differ: `MAX_EVIDENCE_REAP_AGE_MS`
is strictly larger than `MAX_EVIDENCE_AGE_MS`, and that gap is load-bearing. `liveEvidenceOrigins`
takes `maxAgeMs` as an option and the broker's expiry probe drives it with `Number.MAX_SAFE_INTEGER` —
that widened read is the ONLY thing that can answer `expired`, so a sweep clocked on the reader's
own window would delete exactly the marker that diagnosis needs, from any later write anywhere in
the project, and the broker would then report a gate that never ran. Never state the two rules as
unable to diverge: they diverge on this one axis by design and nowhere else) /
`EXECUTION_VERDICTS` / `classifyExecution(seen)` (the doctor's row vocabulary, owned here rather
than hand-written a second time inside the probe's `node -e` string. It travels to the shell as a
WORD, never as an exit status: a status ladder put the answer on the same channel as every way a
process can die, and moving the benign verdict from 1 to another small integer only traded one
collision for another) /
`evidencePathAllowed` / `EVIDENCE_VERSION` (the marker's OWN schema discriminator, deliberately
not the memory's — `appendRecord` refuses an unreadable memory rather than rebuilding it, so a
bump made for the marker would have wedged every project's memory) / `MAX_EVIDENCE_FILES` (the
name is per session AND per
origin; a one-file-per-session shape made a second decided origin rename over the first),
`writeExecutionEvidence` / `executionEvidencePresent` / `executionEvidenceSeen` /
`liveEvidenceOrigins` and `MAX_EVIDENCE_AGE_MS` / `MAX_EVIDENCE_BYTES`, the marker's own
`{version, origin, verdict, at}` body — whose `verdict` now has an OWNER, `EVIDENCE_VERDICTS`
with its two NAMED members `EVIDENCE_VERDICT_ALLOWED` and `EVIDENCE_VERDICT_WEAKEST`, the way
`DECIDED_BY` owns the memory's `decidedBy`. The weakest member is named rather than taken by
index because the doctor's row PREFERS it so a declined prompt is disclosed. It was hand-spelled
at seven sites for a two-value set, and one of those crossed a PROCESS boundary: the doctor
probe's `seen.verdict === "allowed"` ternary, which would have reported every `asked` marker as
cleared if the constant were renamed under it. State where that comparison lives NOW, because it
MOVED and this paragraph described the intermediate step for a release: the probe compares no
verdict at all — it calls `mod.classifyExecution(seen)`, which does the comparison inside the
module, so the crossing that remains is the FUNCTION and the literal fallback is gone. A probe
against a module without that export refuses as `unjudged` rather than degrading. The two vocabularies OVERLAP on
the word `asked` and belong to different artifacts, so a scan for bare spellings has to be scoped
to `verdict`-bearing lines or it reports the memory's owner as a drift — `REASONS.EVIDENCE_PATH_REFUSED`
plus the writer's own five refusals, `EVIDENCE_ORIGIN_REFUSED` / `EVIDENCE_ORIGIN_TAG_MISMATCH` /
`EVIDENCE_STAMP_INVALID` / `EVIDENCE_TOO_LARGE` / `EVIDENCE_WRITE_FAILED`, which were ad-hoc
literals at their five return sites while `runPre` interpolated the value into an operator line —
so they were rendered strings with no owner. The last is a PREFIX and the suffix stays Node's own
errno, which this module does not own, and
`statePathAllowed`'s reason and hard-link parameters — the memory keeps `nlink !== 1` and the
marker does not, deliberately, so a change there is a two-artifact decision. Across files:
`consentEvidenceState` in `scripts/playwright-mcp-proxy.js` (SIX values — `present` /
`expired` / `absent` / `unjudged` / `unread` / `truncated` — where the `expired` arm keeps a slow
human answer from being reported as a gate that never ran, `unjudged` keeps a module fault from
being reported as one either, `unread` names a state directory the walk could not open, and
`truncated` names a walk that hit `MAX_EVIDENCE_FILES` before it could answer. The last two were
`absent` for a round, which is the same conflation the first two exist to remove: a directory
that could not be opened and a budget that ran out both refused with a sentence naming a gate
that had run. The two classifiers of ONE record are deliberately unequal, and saying so here is
what keeps a later reader from "aligning" them: the broker splits `unread` and `truncated` because
its refusal names a cause to a human, while `classifyExecution` collapses both into `unjudged`
because the doctor's row offers one remedy for either. Their module-compat contracts are OPPOSITE
too — the broker degrades to the older boolean `executionEvidencePresent` when `executionEvidenceSeen`
is missing, and the doctor probe REFUSES a module without `classifyExecution`. Both directions are
right for their own consumer; neither is a drift), `CONSENT_EVIDENCE_STATES` and `consentRefusalFor` in that same file — ONE owner for the state
set and ONE renderer for the refusal each state produces, because the approval ladder re-spelled
the set as four `if` arms plus a catch-all that ASSERTED a cause, so a seventh state would have
named a fact the probe never established; the residual arm is state-NEUTRAL and names only what
it could not interpret, the shape the sibling doctor renderer already had —
the consent-policy record's own field set (`pluginRoot` / `evidenceDir` / `projectRoot`,
where a constructor taking two of the three silently dropped the anchor and left the granting
read's containment walk inert, and where `evidenceDir` is now RE-DERIVED per call from the loaded
module rather than taken from the startup value: `consentModule` is re-VERIFIED every call — `require` returns the cache for an unchanged path, so
what re-runs is the `lstat` and its plain-file test, which is the only per-call verification there
is — because this process outlives the tree it resolved its mode from, while the directory derived
from it was resolved once, so a module fault in that one window disabled consent approval for the life of the
MCP server and emitted "reinstall the plugin" for a plugin that had recovered), the
`ZENSU_VERIFY_PROJECT_ROOT` entry in `scripts/playwright-mcp.sh`'s `env -i` allowlist — without
it the broker's anchor silently becomes its own cwd — and the `ZDOC_VERIFY_EXEC` wire between
`hooks/lib/zensu-doctor.sh` and `hooks/lib/zensu-doctor-report.js`, whose FIVE states
(`ran|ran-asked|none|unjudged|unknown`) each need a row and a `skills/doctor/SKILL.md` bullet.
`ran-asked` is the one a census is likeliest to miss: it is a SECOND success state, reached when
the live marker records the gate ASKING rather than clearing from memory, so a reader counting
"one green state" finds two. Two
hand-copies travel with it and both are PINNED rather than trusted: the consent arming set
(`consent|consent-no-recipe|consent-recipe-unchecked`), spelled in the wrapper and in the
renderer's `CONSENT_MODE_STATES`, by `P1vr`; and every `verify-feature`/`verify-feature gate`
row against the skill, by `P1vg`, whose selector had to be widened — its `'verify-feature: '`
form could not see the `gate:` family at all, which is the half-pinned shape this file records
for `AC-C19`. Then `consentHookRegistered` / `consentRecorderRegistered`, which share one lookup because their
CONSUMERS differ — the broker asks only about the gate, the doctor about both; and the operator accounts in `docs/gates.md`, `docs/configuration.md`
(both hook rows plus the hook count and its anchors), `docs/verify-feature.md`, the README
docs-index rows, the suite manifest entry and the counts in `tests/SUITE-OVERVIEW.md`.

**Version for the EXECUTION-MARKER delta: `patch`, and it is its own verdict.** The paragraph
below is about the ORIGINAL hook addition; a releaser matching on it would get the wrong answer
for this one, which is why this file states one scoped verdict per delta. Walked against
§"Runtime Lineage" entry by entry: no context-record or workflow-state schema field — the marker
is a file in `<project>/.zensu/state`, the same class as the consent memory, and it is the
argument §"Workflow-Baseline Repair" uses for its own rebuild counter; no strict key set; no hook
added, removed or renamed and no matcher changed; no new config key; no attestation change. The
new module exports are additive, and a runtime that does not read them is unaffected. ONE mixed
case is real and is scored here rather than left to be discovered: a NEWER broker beside an OLDER
gate that writes no marker refuses every loopback origin. That is a refusal rather than an
unreadable persisted shape, and the two ship in one tree — the broker is launched from the plugin
root that carries the gate — so it is not a lineage break; a `--plugin-dir` checkout beside an
installed root is the shape that could produce it, and the sibling-root rule already refuses to
serve across that boundary.

**Version: `minor`.** Walked against §"Runtime Lineage": adding a hook is a `patch` UNLESS it
can DENY or ASK, and this one does both. It changes the capability set of every session an older
runtime is still serving, which is the disqualifier that bullet spells out.

**Version for the SERVER-KEY rename: `minor`, and it is its own verdict.** Walked against
§"Runtime Lineage": changing a hook's matcher is on the breaking list, and both consent
registrations moved. The MCP tool namespace moved with it, so EVERY permission rule written for
`mcp__plugin_zensu_playwright__*` or `mcp__playwright__*` stops matching the broker and has to be
re-spelled for `mcp__plugin_zensu_zensu-browser__*` or `mcp__zensu-browser__*` — an `allow` rule
starts prompting again, which is loud, while a `deny` or `ask` rule silently stops restricting
the broker, which is the direction that needs saying. The user-facing account of it lives in
`docs/gates.md` and in the `docs/verify-feature.md` troubleshooting table, and it belongs in the
release commit body. Whether a session that spans the update can hold the old
tool names beside the new hook registrations is UNVERIFIED; if it can, the gate does not fire for
those names, so no execution marker is written for them, and the broker refuses a consent-mode
navigation unless a marker another gate wrote for that origin in the same tree is still live. The
mixed state therefore fails closed in the ordinary case. No context-record or workflow-state
field, strict key set or attestation moved.

**Known gaps, accepted and named:**

- **A rename voids a user's own `permissions` rules for the broker, and the shipped mitigation is
  prose only.** Every rule written for `mcp__plugin_zensu_playwright__…` / `mcp__playwright__…`
  stops matching: an `allow` shows itself, because the call prompts again, while an `ask` or a
  `deny` stops restricting SILENTLY — and the consent gate covers only `browser_navigate` and
  `browser_tabs`, so for the broker's other fifteen tools a lost deny is replaced by no Zensu gate
  ON THE MAIN THREAD. Every non-main principal is still denied all seventeen, and the
  OUTCOME is one while the MECHANISM is three: `host-profile-v1` through
  `reviewer-capability-v1.js`'s `/^mcp__.*zensu/i` substring rule plus `ZENSU_MCP_READ_RE`, which
  is the only one of the three that depends on the key CONTAINING `zensu`; `reviewer-readonly-v1`
  and `zensu-plm-readonly-v1` through `REVIEWER_READ_TOOLS` in that same module; and
  `evidence-worker-v1` through `ALLOWED_TOOLS` in `review-evidence-lease-v1.js`. The principal
  ladder returns at the second and third before the substring rule is reached, so a future key
  without `zensu` in it costs coverage for the NEUTRAL principal alone. Two tripwires fire in the
  UNOBVIOUS direction if this gap is ever closed: `V43c` in
  `tests/structure/test-verify-consent.sh` reddens when either operator account names a doctor row
  for the retired tool names, and `V45`'s tree-wide census in the same suite reddens when any file
  outside its four-carrier list drives the retired spelling — both in a suite named for the
  consent gate rather than for the doctor. `docs/gates.md` §"Re-spell permission rules after updating" and the
  `docs/verify-feature.md` §5 troubleshooting row are the whole remedy. **A `/zensu:doctor` row
  for it was BUILT and then REMOVED, and that is recorded rather than left to be rediscovered.**
  It read `~/.claude/settings.json` through the existing reader and warned when a retired name
  still appeared in `deny`, `ask` or `allow`. Five review perspectives found five separate
  defects in it in one round: it re-read a credential-bearing file a second time in the same
  block, against that function's own read-once rule; its `!shape.ok` gate re-collapsed the
  deferred-carrier split `settingsShape` exists to provide; it hand-copied the CURRENT broker
  namespaces instead of deriving them from `BROWSER_SERVER_KEY`, so a later key move would have
  made the row instruct a re-spelling toward a name that was itself retired; its silence rested
  on a sibling disclosure that `hooks.reviewerSpawnPermissionCheck: false` removes; and it warned
  permanently for a bare `mcp__playwright__` rule that legitimately targets a user's OWN upstream
  server, which `warnCount` then denies a green summary forever. Doing it properly means
  threading ONE settings read through `configBlock` into both consumers, splitting the
  plugin-scoped spelling from the bare one, giving the row its own did-not-run arms, deriving the
  new names from the key, and joining it to the `P1be` renderer-vs-skill drift pin — a change to
  the permission-exposure subsystem with its own contracts, and its own review. It does NOT
  belong inside a server-key rename.

- **The decision module reads host variable NAMES itself**, which the sibling plugin-data guard's
  port contract forbids: that module takes every anchor as an option and names no variable. Four
  remain here. A port therefore inherits this host's spellings. Not taken in the round that found
  it, because it is a signature change across both hooks and the unit suite.
- **The gate count in the `docs/gates.md` intro is checked by nothing**, and this feature moved
  it. The same gap the plugin-data guard records for its own row.
- **The `unknown` execution row withholds the green summary for every non-`bound` session.** The
  wrapper answers `unknown` whenever no session key or recorded project root is available, and
  §"Foreign-Chain Row" records that both are empty for every binding verdict except `bound` — so
  an orphaned-project-root, incompatible-runtime or pruned-installation session in a consent-mode
  project can never print "all checks green". The row is correct and the cost is real; it is
  recorded here because three sibling rows record the identical cost for themselves and this
  section said nothing.
- **The Windows half is unverified.** The suite is in the CI structure inventory the weekly
  Windows Safety shard builds, and NOT in the blocking Windows PR profile, so the Windows half
  stays unverified until that weekly run reports green. Say "unverified", never "never runs".
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included. A port
  owns both halves, and the host half includes a measurement rather than an assumption: whether
  its harness renders a PreToolUse `ask` as a prompt the model cannot answer. The EXECUTION MARKER
  splits the same way and a port that takes one half gets a broken gate: the core half is
  `STATE_SEGMENTS` / `evidenceDirFor` / `stateComponentsSafe` / `EVIDENCE_NAME_RE` /
  `evidenceOriginTag` / `evidencePathFor` / `evidencePathAllowed` / `writeExecutionEvidence` /
  `executionEvidencePresent` / `executionEvidenceSeen` / `liveEvidenceOrigins` /
  `EVIDENCE_NAME_PREFIX` / `EVIDENCE_VERSION` / `EVIDENCE_VERDICTS` with both named members /
  `MAX_EVIDENCE_AGE_MS` / `MAX_EVIDENCE_BYTES` /
  `MAX_EVIDENCE_FILES` / `evidenceStatUsable` / `evidenceStillHonourable` / `reapExpiredEvidence`
  (whose EXPORT key is `reapBudgetSpent`, so a port implementing the name written here alone ships
  a module the suite's own driver cannot reach) /
  `MAX_EVIDENCE_REAP_AGE_MS` / `evidenceBodyLive` / `EXECUTION_VERDICTS` / `classifyExecution` /
  `recordingStream` plus
  `statePathAllowed`'s two parameters — and `MEMORY_NAME_PREFIX` / `MEMORY_NAME_RE`, which this
  list omitted for a round while `evidencePathFor` DERIVES the marker name from the MEMORY name
  — it tests `MEMORY_NAME_RE` and substitutes one prefix for the other — so a port that takes the
  marker half alone gets a writer that throws on its first call. The two are NOT what keeps the
  reaper off a consent memory: `EVIDENCE_NAME_RE` is, and it is already on this list. Say the
  derivation, not the separation; the host half is FIVE obligations — where the broker's
  project anchor comes from and how it survives the launcher's environment sanitization (this
  host names `ZENSU_VERIFY_PROJECT_ROOT` in an `env -i` allowlist), the broker's own refusal
  wording including its `expired` arm, the doctor wrapper's five-state derivation and its
  session binding, the renderer's SIX rows — the sixth is the unrecognized-state row, which is
  what keeps a drifted wrapper value from rendering silence — and the operator accounts. A port that copies only
  the module gets a marker nothing writes and nothing reads.
- **THREE ordering and budget rules are load-bearing and read as layout, so they are stated
  here rather than left to a diff.** FIRST, `runPre` emits the decision ENVELOPE before it writes
  the marker. For a new origin the envelope is the `ask` and the marker written for it carries
  verdict `asked`, which the broker treats as a clearance — so with the marker first, a hook
  process tree that died before the write left a live self-approving marker behind and no prompt
  was ever raised. The wrapper's `|| deny` catches an ordinary non-zero exit, so that path needs
  the wrapper killed too, and whether this host admits a call after a timed-out hook is
  UNVERIFIED; the order is taken anyway because it is free and fail-closed the other way round —
  a lost marker refuses, where a lost envelope approved. SECOND, `reapExpiredEvidence` is
  BUDGETED to `MAX_EVIDENCE_FILES` and sits OUTSIDE the publish `try`, clocked on the wall clock
  rather than on the caller's `at`. It runs inside the gating hook and reads and parses every
  candidate, so an unbounded walk let a session-writable directory decide how long that hook
  takes to answer; inside the try, a throw would have reported a marker that DID land as
  `evidence-write-failed:*`; and clocked on a back-dated `at`, every live marker in the directory
  failed the `age >= 0` arm and was swept. `reapBudgetSpent` is exported for the bound's executed
  case alone and has no production reader. THIRD, the doctor probe's benign verdict is exit **4**,
  not 1: `node` exits 1 on a fatal outside its own try and a failed `cd -P` short-circuiting the
  `&&` exits 1 too, and stderr is discarded there, so either one rendered the green row asserting
  that the directory was read and held nothing — the exact claim the status capture exists to
  prevent. The `cd` carries its own `|| exit 2` for the same reason.
- **The readers REFUSE an anchorless call.** `liveEvidenceOrigins` requires `options.projectRoot`
  and answers `read: false` without it. The containment walk is checked AGAINST that root, so a
  call supplying none has nothing to verify — and while the anchor was optional the module's
  DEFAULT was open: `executionEvidencePresent(dir, origin)` read whatever directory it was handed,
  through a symlinked `.zensu` or `state`. One caller was hardened against that and the module a
  port copies was not, which is how the class comes back. The DELETING sibling carries the same
  anchor now, and it is the one that needed it most: `reapExpiredEvidence` is an `unlink`
  primitive whose export key sits on the public surface, and it took a bare directory while the
  reading sibling refused one. Its production call site already held both operands, so the anchor
  cost it nothing — a caller that supplies none now reaps zero rather than sweeping a directory
  nothing verified.
- **Two diagnoses are COARSER than their cause, and both are named rather than fixed.** A
  `.zensu` swapped for a symlink and a state directory that is simply not there both leave
  `liveEvidenceOrigins` answering `read: false`, so the broker's `unread` refusal hedges about a
  directory that may not exist when what it found was tamper. And a non-regular object planted at
  a derivable marker name makes `statePathAllowed` refuse the WRITE for as long as it stands while
  every reader skips it, so `consentEvidenceState` answers `absent` — naming absence where the
  cause is a refused write. Neither surface makes a false claim and the write refusal is disclosed
  on stderr; separating them means a seventh broker state, which is a vocabulary decision for
  `CONSENT_EVIDENCE_STATES` and `consentRefusalFor` rather than a wording change.
- **The marker reader opens with a plain `readFileSync` after an `lstat`, so a FIFO swapped into
  that window blocks the broker's approval path — and there are now TWO such sites, on two
  different paths.** The second is `evidenceStillHonourable`, which the reaper calls once per
  candidate, so a decided navigation carries up to `MAX_EVIDENCE_FILES` of these windows INSIDE
  the PreToolUse gate. Say COUNT and never a comparison against the broker: `liveEvidenceOrigins`
  breaks early only on a wantOrigin MATCH, and a miss is exactly what produces a refusal, so the
  broker's own path is bounded by the same budget — twice over, because `consentEvidenceState`
  runs that walk once for the present probe and again for the widened expiry probe. Scope the
  class to the reader alone and the wider surface goes unrecorded. An already-present FIFO is refused by `evidenceStatUsable`
  before either read, so this is the swap race alone — and the sibling consent
  memory reader has had the identical shape since before this feature. Both belong behind an
  `O_RDONLY|O_NOFOLLOW|O_NONBLOCK` open plus `fstat`, the hardening
  `readRegularFileSnapshot` in `session-control-core-v1.js` already applies for this class.
  NOT taken here: changing the memory reader too is a second artifact's regression surface, and
  changing only the marker would leave the pair inconsistent. Named rather than left to be
  rediscovered.
- **CLOSED, and recorded so it is not re-opened as a gap.** The broker used to trust that the
  host ran the hook, so with hooks disabled host-side consent mode accepted unconsented loopback
  navigations while the doctor reported registration rather than execution. It now requires a
  live per-session marker the gate writes for every decided local target, and `/zensu:doctor`
  carries a SECOND row — `verify-feature gate:` — reporting EXECUTION beside the registration
  row. What is NOT closed is authenticity: the marker is a file in a directory the session can
  write, so it separates a gate that ran from one that did not and authenticates nothing against
  a session forging its own. Say "the silent case is gone", never "the gate cannot be forged".
- **The consent decision is SINGLE-LAYER, and the layer that survives in-session tampering is
  the one that does not enforce consent.** State it that way rather than folding it into the
  bullet above, which covers a host that never ran the hook and not a session that changed what
  the hook does. In consent mode `approveConsentOrigin` inserts the origin into
  `policy.approved` and the `assertAllowedUrl` on the next line tests membership in that same
  set — which was just made true — so for a `browser_navigate` the broker re-checks the FLOOR
  and nothing else. That is defensible as a design: the approved set is what polices
  subresources and in-page navigations, and `configureContext` genuinely refuses an unapproved
  origin there. What it means is that the human's answer is enforced in exactly one place. The
  broker loads its floor once at start; the hook re-executes its decision module from the plugin
  root on EVERY call, and no write gate covers that tree — `pre-write-plugin-data-guard.sh`
  defends the plugin DATA store, not the plugin root. So an in-session module swap changes every
  later verdict, and the broker cannot notice.
- **Consent mode is still ENTERED from a file read, and what changed is what entering it
  buys.** `resolveStartupPolicy` enters consent when `consentHookRegistered` is true, and that
  predicate `lstat`s two files and parses `hooks/hooks.json` under `path.join(__dirname, '..')`
  — a claim made by a file in the broker's own tree, never a fact about the running session.
  The three routes by which the hook does not actually execute are unchanged: hooks disabled
  host-side; the broker launched from tree A (`__dirname/..`) while the host loaded its hook
  registry from tree B — an installed root beside a `--plugin-dir` checkout, with nothing
  comparing the two; and a plugin swap while the long-lived MCP process still holds the mode it
  resolved once at start. What is closed is the CONSEQUENCE: `approveConsentOrigin` refuses
  without a live per-session marker, so all three routes now land on a refusal rather than on
  unprompted access to every loopback origin. **Two properties carry that and neither is
  optional.** The marker is read at APPROVAL time, never cached with the mode, which is what
  reaches the third route inside a process that resolved its mode once. And it is ORIGIN-bound
  and time-bounded, with every fault answering absent, so a marker for one origin can never
  admit a second and a stale one cannot hold the window open. **The residual is
  authenticity, not silence:** the state directory is session-writable, so this separates a
  gate that ran from one that did not and does not defend against a session forging its own
  marker; closing that needs a signal the session cannot mint, which nothing here provides.
  A SECOND residual is the approved SET: once an origin is in it the broker checks the marker
  no further for that origin, deliberately — a consent the human already gave is not revoked
  by a later plugin change — so read "re-read every time" as being about the WRITE into that
  set, never about each later navigation.
