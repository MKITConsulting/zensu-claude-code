---
paths:
  - "hooks/pre-write-plugin-data-guard.sh"
  - "hooks/lib/plugin-data-guard-v1.js"
  - "tests/structure/test-plugin-data-guard.sh"
  - "tests/structure/plugin-data-guard-v1.test.js"
---

# Plugin-Data Guard (`hooks/pre-write-plugin-data-guard.sh` + `plugin-data-guard-v1.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

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
