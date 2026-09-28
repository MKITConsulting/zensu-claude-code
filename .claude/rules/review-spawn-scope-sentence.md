---
paths:
  - "hooks/lib/zensu-tdd-phase.sh"
  - "tests/structure/test-stop-enforcer-self-review-routing.sh"
  - "tests/structure/test-post-review-self-review-handoff.sh"
---

# Review-Spawn Scope Sentence (`ZENSU_REVIEW_SPAWN_IN_SCOPE`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

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
config key at the Stop site (T45), the host build (T46), the bound roster
(T48), the windowed-`REVIEWER_DENIALS` carriers (T49), the example-config entry (T55), and
the absence of the ledger claim from both doc carriers (T56), the second exception with its own bound (T57), and the record-anchored config read at the Stop site, pinned at source by T58 and behaviourally in both directions by T59 — the overlay channel every other fixture in that suite bypasses, because `ZENSU_CONFIG` short-circuits `cfg()` before the project overlay is consulted. The one-owner boundary is
T40: occurrence counts for both the constant and the clause, no consumer redeclaration, a
single-line plain-assignment form with no `:-`, no borrowed branch discriminator, and a
hand-copy scan over FIVE roots — `hooks/`, `skills/`, `docs/`, `agents/` and `templates/`,
with `tests/` carved out because the suite legitimately holds the needle. `docs/tdd-manager-workflow.md` §"The review-spawn scope sentence" is the operator
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
