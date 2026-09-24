---
paths:
  - "hooks/lib/chain-recovery-v1.js"
  - "skills/recover-chain/**"
  - "tests/structure/chain-recovery-v1.test.js"
  - "tests/structure/test-chain-recover.sh"
---

# Chain Shape & Rearm Receipt (`hooks/lib/chain-recovery-v1.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

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
renderer keeps no private copy), the ticket issuer, `hooks/lib/zen-anchor-v1.js` (a FIELD-NAME, VALUE-DOMAIN and EXPORT consumer since
the zen-mode chain anchor landed: it reads `report.shape`, `report.linkage` and
`report.autopilot.outcome`, and it consumes `STUCK_SHAPES` — the module body reads that
export and no other, it is that export's only consumer under `hooks/`, and removing or
renaming it makes `anchorToken` THROW for every shape that HAS a position, disabling the
anchor on every prompt of every zen-mode session, with the disclosure landing on a channel
this file records as unverified for delivery. Say "that has a position", not "every shape":
the two inert shapes return `none` before the read is reached. `ALL_SHAPES` is
consumed by that module's UNIT CONTRACT and never by the module — its only appearance
under `hooks/` outside the owner is a comment — so removing it reddens the key-parity
cases alone. Stated the way the doctor's `INERT_SHAPES` clause six lines above is, and its `OUTCOME_POSITION` allowlist is keyed on `CHAIN_OUTCOMES`
members — a fifth member added there renders no anchor rather than inheriting a mark, which is
the fail-open direction, but it does mean a new outcome reaches that module silently and needs
a row there), and the rearm writer
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

Two more sites hardcode the provenance literals rather than importing them: `zensu-log.sh --phase`,
and `_tdd_reserved_provenance` — the one body `tdd_write_phase` and `_tdd_write_phase_critical` both
delegate to — reserve the
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
