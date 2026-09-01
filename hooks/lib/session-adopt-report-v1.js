'use strict';

// The adoption report — what `zensu-session-adopt.sh` prints, and the decisions
// behind it.
//
// It lived as a ~180-line `node -e '...'` payload inside that script's single-quoted
// shell string. Review of PR #252 recorded the cost: the carrier was shaping the code
// (every pattern had to be built with `new RegExp("...")`, and no apostrophe could
// appear anywhere), and it left `safe()` — a function whose comment names four
// concrete threats — with no test in either direction. Its sibling recognized
// command already runs a real file, and the PreToolUse recognizer pins only the outer
// `bash <adopt script>` shape, so moving it here changed nothing about what the gate
// admits.
//
// Run as a program by that script; required as a module by
// tests/structure/session-adopt-report-v1.test.js.

const fs = require("node:fs");
const path = require("node:path");
const core = require("./session-control-core-v1.js");
// The superseded-lease sweep. It is NOT part of adoptContext any more: requiring the
// lease owner from the core is a require cycle, so the sweep moved into its own
// module and this entry script — which already loads both halves — became its
// caller. Required at the TOP on purpose: a broken or missing sweep module then
// fails this command before adoptContext has mutated anything, rather than after.
const sweepLeases = require("./review-evidence-sweep-v1.js");

// The three inputs are read INSIDE buildRequest, not at module scope. Freezing them
// at require time made main() undrivable from a unit test: every case would share one
// environment captured before the file was loaded.
// The binder OWNS the private-store constructor, and this uses it rather than a
// hand-joined path: it additionally rejects a records directory that is a
// symlink, an alias, group- or world-accessible, or owned by another user.
// Skipping those checks would let the repair mint a record into a store that the
// very next tool call refuses for exactly those reasons — a false success, and a
// new record sitting somewhere another local user can rewrite it.
//
// Resolved INSIDE main(), never at module top level: all five of its refusal
// conditions throw, and a throw out here would escape the handler below and print
// a raw stack trace — in the one state where every other channel is already
// denied, and where those conditions are exactly the diagnosis the user needs
// stated plainly.
const privateRecordsDirectory = require("./claude-hook-session-v1.js").privateRecordsDirectory;
const buildRequest = () => {
  const pluginData = process.env.ZADOPT_PLUGIN_DATA;
  return {
    recordsDir: privateRecordsDirectory(pluginData),
    sessionId: process.env.ZADOPT_SESSION_ID,
    host: "claude",
    pluginData,
    executingPluginRoot: process.env.ZADOPT_PLUGIN_ROOT,
  };
};

// The recorded project root is echoed into a terminal AND into the model context,
// and the strict read constrains it less than that use deserves: validateContext
// rejects only NUL, CR and LF there, while the sibling readOrphanedProjectRootContext
// rejects the whole C0-plus-DEL class for exactly this reason. So print the plain
// path when it is plain and a JSON-escaped one when it is not: an escape sequence in
// a directory name must not be able to rewrite or hide the one line that says which
// project is being taken over. The normal path is unchanged, which is what keeps the
// report greppable.
// A POSITIVE allowlist, and every non-constant STRING field in the report goes
// through it. The two counts are integers the sweep produces and are not folded.
// A deny class was the first attempt and it was wrong in both directions: it caught
// U+007F, which JSON.stringify does NOT escape, and it missed the bidi overrides and
// U+2028, which are exactly what could hide the line naming the project being taken
// over. It was also applied to two fields while provenance, the superseded filename,
// the stuck-lease names and the error messages carried the same filesystem-derived
// text raw. So: anything outside the set below is JSON-escaped AND folded to ASCII,
// because JSON.stringify alone leaves every non-ASCII code point intact.
// The class admits a space and a colon, and the project line is the LAST field of
// the read-only block, so a run of spaces would let a directory name forge further
// "label : value" pairs after it — and the skill keys real behaviour off exactly
// those pairs. Nothing in an ordinary path carries a double space, so requiring one
// space at a time costs nothing and closes the forgery.
// Expressed by UNICODE PROPERTY, not an ASCII range. The ASCII form admitted no
// letter outside A-Za-z, so any project path with an umlaut, an accent, CJK or a
// non-breaking space took the fold — the degraded rendering of the single line this
// report exists to add, landing on exactly the developers whose home directory is
// not pure ASCII. The positive allowlist is kept; only its alphabet widens.
//
// Every named threat still folds, because none of them is a letter, a number or a
// combining mark: the bidi overrides are \p{Cf}, U+2028/2029 are \p{Zl}/\p{Zp}, and
// U+007F is \p{Cc}.
const SAFE_DISPLAY = /^[\p{L}\p{N}\p{M} _.,:;/\\@+~()=-]*$/u;
const DOUBLE_SPACE = / {2}/;
// The class admits a space AND a colon, and DOUBLE_SPACE only rejects two ADJACENT
// spaces — so a value with single spaces and colons passed through raw and could
// forge a further `label : value` pair after the line it sits on. That needs no local
// privilege: context.project_root is minted from the SessionStart cwd and
// validateContext rejects only NUL, CR and LF in it, so anyone who supplies the
// directory name the user opens Claude Code in controls this substring. A real path
// containing " : " now renders JSON-quoted, which is still readable.
// It guards `: ` and ` :`, not only ` : `. This report emits THREE separator
// spellings and this guard covered one: `  ` (the padding), ` : ` (the aligned pair),
// and `: ` in `WARNING: `, `NOTE: `, `  superseded record: ` and
// ` could NOT be set aside: `. A project directory named `repo WARNING: inspect
// /tmp/x` carries only allowlisted characters, no double space and no ` : `, so it
// printed VERBATIM and forged a whole warning line — the lines skills/adopt-session
// tells the model to relay word for word.
//
// MEASURED against this allowlist, not assumed: of the known colon confusables,
// exactly three pass SAFE_DISPLAY — U+003A itself, U+02D0 MODIFIER LETTER TRIANGULAR
// COLON (\p{Lm}) and U+A4FD LISU LETTER TONE MYA JEU (\p{Lo}). Every other one, and
// every non-ASCII space, is already rejected by the positive class.
const COLON_LIKE = "\\u003a\\u02d0\\ua4fd";
const PAIR_SEPARATOR = new RegExp("[" + COLON_LIKE + "] | [" + COLON_LIKE + "]", "u");
// Renders as nothing while counting as a letter or a mark, which is how an invisible
// character splits the two literal guards above. MEASURED: nine default-ignorable
// code points pass SAFE_DISPLAY — U+034F, U+115F, U+1160, U+17B4, U+17B5, U+180B,
// U+3164, U+FE00, U+FFA0 — and each one turns `repo X: recorded` back into a value
// that prints verbatim while still reading as a label.
const INVISIBLE = /\p{Default_Ignorable_Code_Point}/u;
// A combining mark with no base of its own attaches to the PRECEDING space and paints
// on it. MEASURED: U+0301 and the spacing visargas U+0903 and U+0F7F all printed as
// themselves, because \p{M} is inside the allowlist and neither literal guard carries
// a mark. The rule is the mark's BASE, so a decomposed accent on a letter — the case
// the allowlist was widened for — still prints as itself.
const ORPHAN_MARK = /(?:^|[ ])\p{M}/u;
const NON_ASCII = /[\u007f-\uffff]/g;
const SPACE_RUN = / {2,}/g;
// Applied AFTER NON_ASCII has folded U+02D0 and U+A4FD to escapes, so only the ASCII
// colon can still sit beside a space here.
const COLON_SPACE_GLOBAL = /:[ ]/g;
const SPACE_COLON_GLOBAL = /[ ]:/g;
const safe = (value) => {
  const text = String(value);
  if (SAFE_DISPLAY.test(text)
    && !DOUBLE_SPACE.test(text)
    && !PAIR_SEPARATOR.test(text)
    && !INVISIBLE.test(text)
    && !ORPHAN_MARK.test(text)) {
    return text;
  }
  return JSON.stringify(text)
    .replace(NON_ASCII, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"))
    // The DOUBLE_SPACE invariant applies to BOTH branches. It used to guard only the
    // fast path, so `/tmp/a"b  project : x` was rendered through JSON.stringify with
    // the two-space run and the colon intact — the exact forgery the fast-path guard
    // exists to stop, arriving through the branch meant to be the safer one. Single
    // spaces survive, so an ordinary quoted path stays readable.
    .replace(SPACE_RUN, (run) => "\\u0020".repeat(run.length))
    // Same reasoning as the double-space fold above, for the separator the fast path
    // now also guards: a value that reached this branch for an unrelated reason must
    // not keep a usable `: ` intact.
    .replace(COLON_SPACE_GLOBAL, ":\\u0020")
    .replace(SPACE_COLON_GLOBAL, "\\u0020:");
};

// WHICH directory the sweep refused, empty when it refused nothing.
//
// The previous coercion was `typeof leases.unsafe === "string" ? leases.unsafe : ""`,
// which fails OPEN: an unexpected shape mapped to the CLEAN verdict and the entire
// WARNING branch never printed. Failing toward reporting costs the same line.
const leasesScope = (leases) => {
  if (!leases) return "";
  if (typeof leases.unsafe === "string") return leases.unsafe;
  return leases.unsafe ? "source" : "";
};

// ALREADY_SERVED is the one refusal with something left to do, and only under
// --confirm.
//
// adoptContext commits the record and only THEN sweeps the lease store, and the two
// are not transactional together. A process death in that window leaves a committed
// adoption with superseded leases still in place — and every later run refuses here,
// so the documented remedy becomes unreachable for exactly the state it repairs.
// Moving the sweep before the record swap is not available: it lives in its own
// module because requiring the lease owner from the core is a cycle, and the entry
// point calls it after adoptContext returns.
//
// A report-only run stays strictly read-only. That is not a nicety — it is what the
// PreToolUse recognizer's justification for admitting this command rests on.
// The root the repair sweeps against: the EXECUTING installation, never the one
// the record names.
//
// `already-served` does NOT mean the record names this installation.
// servesRecordedRuntime is true on the equality fast path AND on the
// lineage-relaxed sibling arm, so after a compatible upgrade the recorded root
// and the executing root are different directories. Leases are minted with the
// EXECUTING root (review-evidence-lease-v1.js writes binding.pluginRoot, and the
// binder answers executedPluginRoot), and the lease reader compares against that
// same value. Sweeping against the recorded root therefore INVERTED the selector:
// the stale entries wedging listRecords were kept and the live ones set aside,
// and the report printed a clean repair over it.
//
// The value is canonical but NOT necessarily the spelling this comparison needs,
// and that distinction is invisible from a POSIX host. zensu-session-adopt.sh
// renders it through zensu-host-path.sh; on win32 that renderer emits a
// drive-qualified FORWARD-slash path (`D:/a/x`), while every lease is minted with
// `binding.pluginRoot`, which reached the store through the core's
// canonicalDirectory — `fs.realpathSync.native`, so `D:\a\x`. The sweep compares
// `record.plugin_root === executingPluginRoot` as a STRING, so on Windows the two
// spellings inverted the selector a second time: the live lease this branch must
// keep was set aside. Measured on windows-shard-2, which reported `leases set
// aside : 2` where 1 was correct while every POSIX shard stayed green.
//
// The adopt path below never carried the defect because it passes the record's own
// `plugin_root`, which is already the native spelling.
const repairSweepRoot = (request) => {
  try {
    return fs.realpathSync.native(request.executingPluginRoot);
  } catch {
    // zensu-session-adopt.sh already proved this root readable, so a failure here
    // means it vanished mid-run. Fall back to the rendered value rather than
    // throw: this branch owes the caller a verdict, not a crash.
    return request.executingPluginRoot;
  }
};

const leaseFault = (repaired) =>
  !!(leasesScope(repaired) || (repaired.failed && repaired.failed.length > 0));

// The SECOND thing an already-served run can repair, and the reason that refusal
// stopped being a dead end. The record needs nothing; the workflow document the
// record ANCHORS can still be gone, and while it is, reviewer-capability-v1.js
// denies every tool in the session. See §"Workflow-Baseline Repair" in CLAUDE.md.
//
// EVERY comparison against a baseline state token goes through this accessor, and
// that is a contract rather than a style. A bare `core.BASELINE_STATES.MISSING`
// throws a TypeError when the loaded core predates the baseline exports — and this
// command's whole job is to answer in a state where everything else fails closed,
// so a crash here is the worst available outcome. `baselineVerdict` already wraps
// its own call for exactly that reason; a bare dereference in the comparisons
// AROUND it undoes the contract from outside the try. One site sat on a
// POST-MUTATION path, after the record swap had already been committed, where a
// throw would have lost the closing warning and every lease result with it.
// A positive `typeof` test, never `=== undefined`: an absent export would
// otherwise match an absent state and read as a hit, which is the same trap the
// `isBaselineAlreadyPresent` predicate below exists to avoid.
const baselineState = (name) => {
  const states = (core && core.BASELINE_STATES) || {};
  return typeof states[name] === "string" && states[name] ? states[name] : null;
};
const isBaselineState = (value, name) => {
  const token = baselineState(name);
  return token !== null && value === token;
};

// The half is FAULTED, never merely "not done", when the document is present but
// unsafe or unreadable: something is sitting at that path, and this command
// refuses to build over it. `present` is not a fault — it is the ordinary state
// of a healthy session running this command for the lease half alone.
const baselineFault = (baseline) => {
  if (!baseline) return "";
  if (typeof baseline.fault === "string" && baseline.fault) return baseline.fault;
  if (typeof baseline.refusal === "string" && baseline.refusal) return baseline.refusal;
  if (isBaselineState(baseline.state, "UNSAFE")
    || isBaselineState(baseline.state, "UNREADABLE")) {
    return baseline.state;
  }
  return "";
};

// The headline is CHOSEN from the verdicts, never printed before them: a refused
// sweep once announced a repair. It now composes BOTH halves, so a run that
// rebuilt the baseline and left a lease stuck cannot report either one alone.
// `baseline` is optional — omitted, the two-clause form collapses to exactly the
// lease-only wording this function had before the baseline half existed.
const repairHeadline = (repaired, baseline) => {
  const parts = [];
  if (baselineFault(baseline)) {
    parts.push("workflow baseline NOT repaired");
  } else if (baseline && baseline.rebuilt) {
    parts.push("workflow baseline rebuilt");
  }
  if (leaseFault(repaired)) {
    parts.push("lease store NOT repaired");
  } else if (repaired.discarded) {
    parts.push("lease store repaired");
  }
  if (!parts.length) return "Zensu session adoption — ALREADY SERVED (nothing to repair)";
  return "Zensu session adoption — ALREADY SERVED (" + parts.join("; ") + ")";
};

// A refused or partial repair is a failure, and the exit code has to say so: the
// branch returned without touching process.exitCode, so it exited 0 on a refusal
// while the skill's own contract reserves 0 for a successful report or adoption.
// EITHER half failing is enough — a rebuilt baseline does not launder a stuck
// lease, and a clean sweep does not launder a baseline this command refused.
const repairExitCode = (repaired, baseline) =>
  (baselineFault(baseline) || leaseFault(repaired) ? 1 : 0);

const shouldRepairInPlace = (verdict, confirmed) =>
  !!verdict
  && verdict.ok === false
  && verdict.reason === core.ADOPTION_REFUSALS.ALREADY_SERVED
  && confirmed === true;

// Read-only, and it never throws. The core contracts that its verdict function
// does not either, but this command's whole job is to answer in a state where
// everything else fails closed, so a crashed helper here would be the worst
// available outcome. A local failure is reported as `fault`, which is
// deliberately NOT a word from core.BASELINE_REFUSALS: a reader must be able to
// tell "the core refused the bind" from "this command could not reach a verdict".
const baselineVerdict = (request) => {
  let verdict;
  try {
    verdict = core.workflowBaselineVerdict(request);
  } catch (error) {
    return {
      fault: "verdict-unavailable",
      detail: error && error.message ? error.message : "unknown",
    };
  }
  if (!verdict.ok) return { refusal: verdict.reason };
  return {
    state: verdict.state,
    path: verdict.path,
    // The component the refusal is about. Naming the leaf for an ancestor fault
    // sends the operator to a path that need not exist.
    unsafeAt: verdict.unsafeAt || null,
    projectRoot: verdict.projectRoot,
  };
};

// The baseline half of a --confirm run. It runs BEFORE the lease sweep, and the
// order is not cosmetic: the sweep is about evidence a later review needs, while
// the baseline decides whether this session can make a tool call at all.
//
// Only `missing` is acted on. Everything else — a healthy document, a tamper
// shape, a refused bind — is returned unchanged, so this function can be called
// unconditionally and the caller does not re-implement the repairable rule.
const repairBaseline = (request, baseline) => {
  if (!baseline || !isBaselineState(baseline.state, "MISSING")) return baseline;
  try {
    const repaired = core.repairWorkflowBaseline(request);
    return {
      ...baseline,
      rebuilt: true,
      provenance: repaired.provenance,
      path: repaired.path,
    };
  } catch (error) {
    // A BENIGN race is not a fault. Between this command's verdict and the core's
    // own re-check, a concurrent SessionStart or a second window can heal the
    // document — which is the outcome this command wanted. Reporting that as
    // `rebuild-failed` gave exit 1 and told the user "the cause above has to be
    // cleared first" for a session that was already fine, while the SessionStart
    // caller swallowed the identical throw. The core now types the two apart so
    // both callers make ONE judgement.
    // The PREDICATE, never the raw constant: `undefined === undefined` reads as a
    // match, so a tree where the export is missing would report every refusal —
    // tamper included — as the benign race, with exit 0 and "nothing to repair".
    if (typeof core.isBaselineAlreadyPresent === "function"
      && core.isBaselineAlreadyPresent(error)) {
      return { ...baseline, state: baselineState("PRESENT") || baseline.state, healedElsewhere: true };
    }
    return {
      ...baseline,
      fault: "rebuild-failed",
      detail: error && error.message ? error.message : "unknown",
    };
  }
};

// What SURVIVED the document. A rebuilt baseline reads "never active", so these
// are the only remaining traces of what the lost one may have been in the middle
// of. They are LISTED and never interpreted: this command cannot tell a live
// deferred review from a stale marker, and saying which would be a claim it has
// not earned. A closed candidate set plus a cap, because the directory is
// session-writable and this output is read back by a model.
const EVIDENCE_MAX = 12;
// The four NAMES below are hand-copies and there is no accessor to take them
// from: `pending-review.json` is owned by `zensu_pending_review_file`,
// `pending-review.json.claim` by `zensu_pending_review_claim_file` (both shell,
// in hooks/lib/zensu-tdd-phase.sh), `reviewer-spawn-denied-<key>.json` by
// hooks/stop-chain-enforcer.sh and hooks/lib/zensu-doctor-report.js, and the
// `autopilot-active-` prefix by `OWNER_POINTER_PREFIX` in
// hooks/lib/zensu-autopilot-state.sh. The failure direction is SILENT
// SUBTRACTION: a renamed artifact simply drops out of a list this command
// presents to the user as what survived, with nothing reporting that anything
// was missed. They are on the coupled-site roster in CLAUDE.md for that reason.
//
// The DIRECTORY is no longer among them. It used to re-join `.zensu`/`state` by
// hand inside the very feature whose core declares that layout once; it is now
// derived from the document's own resolved path, so a layout move cannot leave
// this reader scanning a directory no writer uses.
const survivingEvidence = (projectRoot, sessionId) => {
  if (typeof projectRoot !== "string" || !projectRoot) return [];
  let key;
  let stateDirectory;
  try {
    key = core.sessionKey(sessionId);
    stateDirectory = path.dirname(core.adoptionWorkflowStatePath(projectRoot, sessionId));
  } catch {
    return [];
  }
  let entries;
  try {
    entries = fs.readdirSync(stateDirectory);
  } catch {
    return [];
  }
  const wanted = (name) => name === "pending-review.json"
    || name === "pending-review.json.claim"
    || name === "reviewer-spawn-denied-" + key + ".json"
    || /^autopilot-active-[0-9a-f]{64}\.json$/.test(name);
  return entries.filter(wanted).sort().slice(0, EVIDENCE_MAX);
};

// The report-only diagnosis, and the reason an already-served run is worth making
// at all in a wedged session. The generic remedy says the record is fine — true,
// and on its own it sends the user away from the actual cause.
function renderBaselineDiagnosis(baseline, sessionId) {
  const out = [];
  const w = (line) => out.push(line);
  // The FAULT test runs FIRST, and the order is the contract. repairBaseline's
  // catch spreads the verdict, so a failed rebuild keeps `state: MISSING` — with
  // the state branches first, that shape reached the MISSING branch and printed
  // "Re-run this command with --confirm to rebuild it" underneath the line saying
  // the rebuild had just been refused. A remedy that is the operation that
  // already failed is worse than none, and it was reachable: a symlinked
  // .zensu/state classifies MISSING while ensureDescendantDirectory refuses it.
  // NARROWER than baselineFault on purpose. baselineFault also reports `unsafe`
  // and `unreadable` as faults — correct for the headline and the exit code,
  // wrong here, because those two have their OWN wording below and testing the
  // broad predicate first swallowed it. What must precede the state branches is a
  // LOCAL fault only: this command could not judge, or its rebuild was refused.
  const localFault = (baseline && typeof baseline.fault === "string" && baseline.fault)
    || (baseline && typeof baseline.refusal === "string" && baseline.refusal)
    || "";
  if (localFault) {
    w("\nThe workflow document of this session could NOT be judged or repaired ("
      + safe(localFault) + ").\n");
    if (baseline && baseline.detail) w("  " + safe(baseline.detail) + "\n");
    w("That is a missing check rather than an all-clear, and the cause above has to be\n");
    w("cleared first — re-running this command will fail the same way. Run /zensu:doctor.\n");
    return out.join("");
  }
  if (baseline && isBaselineState(baseline.state, "MISSING")) {
    w("\nThis session's workflow document is MISSING:\n");
    w("  " + safe(baseline.path) + "\n");
    w("\nWhile it is gone the capability gate denies EVERY tool in this session, because a\n");
    w("deleted document must never be read as \"no chain was ever active\". Re-run this\n");
    w("command with --confirm to rebuild it.\n");
    w("\nRebuilding is a real loss, not a restore: a review chain that was live when the\n");
    w("document vanished is gone, and the new baseline reads \"never active\".\n");
    const evidence = survivingEvidence(baseline.projectRoot, sessionId);
    if (evidence.length) {
      w("\nThese session-state files survived and may say what the lost document was in the\n");
      w("middle of. This command does not interpret them:\n");
      evidence.forEach((name) => w("  " + safe(name) + "\n"));
    }
    return out.join("");
  }
  if (baseline && (isBaselineState(baseline.state, "UNSAFE")
    || isBaselineState(baseline.state, "UNREADABLE"))) {
    w("\nThis session's workflow document is " + safe(baseline.state).toUpperCase() + ":\n");
    // The OFFENDING component, which is not always the leaf: the directory ladder
    // reports the same UNSAFE token for a symlinked `.zensu` or `.zensu/state`,
    // and with one of those replaced the leaf below it need not exist at all —
    // so printing the leaf sent the operator to a path they could not inspect and
    // told them to remove a file that was not there.
    w("  " + safe(baseline.unsafeAt || baseline.path) + "\n");
    if (baseline.unsafeAt && baseline.unsafeAt !== baseline.path) {
      w("  (the document itself is " + safe(baseline.path) + ", but the component above\n");
      w("  is what makes it unsafe — inspect that one)\n");
    }
    // No repair is offered here, deliberately. Something IS sitting at that path;
    // rebuilding over it would destroy the evidence and hand the session its
    // capabilities back in the same step.
    w("\nThat is not a missing document, so this command will NOT rebuild it — something is\n");
    w("at that path. Inspect it before doing anything else: a symlink, a hard link or a\n");
    w("non-file there is a tamper signal, while unreadable content can also be an ordinary\n");
    w("truncated write. Once you know which, remove the file and start a fresh session.\n");
    return out.join("");
  }
  return "";
}

// The --confirm counterpart. Every state that is not a clean rebuild has to reach
// the user as its own sentence: a rebuild whose provenance could not be written is
// a real repair with an unrecorded cause, and folding it into the success line
// would lose the one fact a later reader needs.
function renderBaselineNotes(baseline, sessionId) {
  const out = [];
  const w = (line) => out.push(line);
  if (!baseline) return "";
  if (baseline.healedElsewhere) {
    // Its OWN sentence, which is this function's stated contract. Without it the
    // benign race rendered byte-identical to "the document was fine all along":
    // headline "nothing to repair", `workflow baseline: present`, exit 0 — for a
    // user whose report-only run had just called the document MISSING.
    w("\nNOTE: the workflow document was missing when this command reported it, and was\n");
    w("rebuilt by something else — a concurrent SessionStart, or a second window — before\n");
    w("--confirm acted. This run rebuilt nothing, and the session is usable again.\n");
    return out.join("");
  }
  if (baseline.rebuilt) {
    w("\nNOTE: the workflow document was missing and has been rebuilt at\n");
    w("  " + safe(baseline.path) + "\n");
    w("This session is able to run tools again. The rebuilt baseline reads \"never active\":\n");
    w("a review chain that was live when the document vanished is gone and is not recovered\n");
    w("by this repair.\n");
    if (baseline.provenance !== "recorded") {
      w("\nWARNING: the rebuild succeeded but its provenance entry could not be written (\""
        + safe(String(baseline.provenance)) + "\").\n");
      w("The rebuild is real and unrecorded in the workflow history; report this rather than\n");
      w("repeating it.\n");
    }
    return out.join("");
  }
  if (baselineFault(baseline)) {
    // The lead states WHAT happened; the diagnosis owns the cause, the detail and
    // the remedy. Writing the fault token and `detail` here as well printed both
    // twice.
    //
    // The sessionId is threaded rather than passed as "", and the honest bound is
    // that it is currently UNREAD on this path: the diagnosis's local-fault branch
    // returns before the MISSING branch that lists surviving evidence, and
    // `baselineFault` is truthy only for a local fault or for a tamper state,
    // which takes its own branch. It is threaded anyway because passing "" was an
    // active defect rather than a neutral placeholder — an empty id makes
    // core.sessionKey throw, so survivingEvidence would silently return an empty
    // list the moment a branch reordering made it reachable, which is exactly the
    // failure this parameter now cannot have.
    w("\nWARNING: the workflow document was NOT repaired.\n");
    w(renderBaselineDiagnosis(baseline, sessionId));
    return out.join("");
  }
  return "";
}

// Every refusal names the condition that was not met, and every one of them has
// a different remedy. A generic "not adoptable" would put the user back where
// the misleading doctor row left them.
const REMEDY = {
  [core.ADOPTION_REFUSALS.RECORD_UNREADABLE]:
    "The record could not be re-verified against the installation that minted it. Its recorded project root may be gone, that installation may have been pruned from the plugin cache, the record may have been altered, or a persisted schema really did change in this release. Adoption cannot tell these apart, and in this state /zensu:doctor cannot name the directory either. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.PLUGIN_DATA]:
    "The record belongs to a different plugin-data store — typically a development checkout against an installed plugin, or the reverse. That boundary is never relaxed. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.ALREADY_SERVED]:
    "Nothing to RE-MINT: this installation already serves the record. TWO things beside the record can still be wedged. The workflow document this session is anchored to may be gone — a deleted and re-created worktree loses it, because .zensu/state/ is gitignored — and while it is, the capability gate denies every tool in the session. The lease store is the second: an adoption writes the record first and sweeps the store afterwards, so a run that died in between leaves the record correct and the store still wedged. Re-run this command with --confirm to repair both; it is idempotent and re-mints nothing. Anything the lines below report as MISSING is what --confirm will act on. If tools are still failing after it, the cause is a different one — run /zensu:doctor.",
  [core.ADOPTION_REFUSALS.NOT_SIBLING]:
    "The executing installation is not a sibling of the one that minted the record, so it cannot be an upgrade of it. A --plugin-dir checkout never adopts an installed session. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.EXECUTING_UNIDENTIFIED]:
    "The executing installation does not declare a usable version, so no lineage judgement is possible. Repair the plugin installation; /zensu:doctor reports plugin integrity.",
  [core.ADOPTION_REFUSALS.BACKWARDS]:
    "The executing installation is OLDER than the one that minted the record. Only a newer runtime may take over the state of an older one, never the reverse. Re-install the newer version, or start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.WORKFLOW_SCHEMA]:
    "The workflow document of this session cannot be read by the executing runtime, which means a persisted shape really did change. This is the case adoption must refuse. Start a fresh Claude Code session.",
};

// Wrapped in a function because `node -e` evaluates at module top level, where a
// bare `return` is a syntax error — and a syntax error here would surface as a
// crashed helper rather than as the refusal it was meant to print.
function main() {
  let request;
  try {
    request = buildRequest();
  } catch (error) {
    process.stdout.write("Zensu session adoption — NOT adoptable (private-record-store-unsafe)\n\n");
    process.stdout.write("The private Session Control record store could not be opened safely: "
      + safe(error && error.message ? error.message : "unknown") + "\n");
    process.stdout.write("It is missing, aliased, or has unsafe permissions or ownership. Repair the store\n");
    process.stdout.write("or start a fresh Claude Code session; adoption cannot mint a record into it.\n");
    process.exitCode = 1;
    return;
  }
  const verdict = core.adoptableRecord(request);
  if (!verdict.ok) {
    if (shouldRepairInPlace(verdict, process.env.ZADOPT_CONFIRM === "1")) {
      // The record needs nothing; the LEASE STORE may still be wedged. adoptContext
      // commits the record and only then sweeps, and the two are not transactional
      // together — so a process death in that window leaves a committed adoption with
      // superseded leases still in place, and every later run refuses here. Without
      // this branch the documented remedy is unreachable for exactly the state it
      // exists to repair.
      //
      // It is idempotent by construction: the sweep only ever moves entries that do
      // NOT name the executing installation, so a store that is already clean yields
      // a zero count and creates nothing.
      // The sweep root is the EXECUTING installation — see repairSweepRoot for why
      // the recorded one inverted the selector on exactly the upgrade this branch
      // serves.
      // The BASELINE half runs first — see repairBaseline for why the order is a
      // decision rather than a layout. A wedged session cannot make a tool call
      // until the workflow document is back; a stuck lease only costs it a review.
      const baseline = repairBaseline(request, baselineVerdict(request));
      const repaired = sweepLeases.discardSupersededLeases(
        request.pluginData,
        core.sessionKey(request.sessionId),
        repairSweepRoot(request),
      );
      // Headline AFTER both verdicts, never before them: printing "repaired"
      // unconditionally made a refused sweep announce a success.
      process.stdout.write(repairHeadline(repaired, baseline) + "\n\n");
      process.stdout.write("  workflow baseline: " + safe(baselineFault(baseline)
        || (baseline && baseline.rebuilt ? "rebuilt" : String((baseline && baseline.state) || "unknown"))) + "\n");
      process.stdout.write("  leases set aside : " + repaired.discarded + "\n");
      process.stdout.write("  leases stuck     : " + repaired.failed.length + "\n\n");
      process.stdout.write("This installation already serves the record, so nothing was re-minted. The workflow\n");
      process.stdout.write("document and the lease store are the two parts beside the record that can still be\n");
      process.stdout.write("wedged, and both were checked.\n");
      if (repaired.discarded === 0 && repaired.failed.length === 0 && !leasesScope(repaired)
        && !baselineFault(baseline) && !(baseline && baseline.rebuilt)) {
        process.stdout.write("Nothing needed repairing. If tools are still failing, the cause is a different\n");
        process.stdout.write("one — run /zensu:doctor.\n");
      }
      process.stdout.write(renderBaselineNotes(baseline, request.sessionId));
      reportLeaseWarnings(repaired);
      process.exitCode = repairExitCode(repaired, baseline);
      return;
    }
    process.stdout.write("Zensu session adoption — NOT adoptable (" + safe(verdict.reason) + ")\n\n");
    process.stdout.write((REMEDY[verdict.reason] || "No remedy is known for this refusal. Start a fresh Claude Code session.") + "\n");
    // ONLY on already-served, and only without --confirm: this is the read-only
    // half of the one refusal that has something left to do. Every other refusal
    // means the record itself is the problem, so a diagnosis of the document it
    // anchors would point past the actual cause. Strictly read-only — that is the
    // premise the PreToolUse recognizer's admission of this command rests on.
    if (verdict.reason === core.ADOPTION_REFUSALS.ALREADY_SERVED) {
      process.stdout.write(renderBaselineDiagnosis(baselineVerdict(request), request.sessionId));
    }
    process.exitCode = 1;
    return;
  }

  if (process.env.ZADOPT_CONFIRM !== "1") {
    process.stdout.write("Zensu session adoption — ADOPTABLE\n\n");
    process.stdout.write("  record minted by : " + safe(verdict.recorded) + "\n");
    process.stdout.write("  executing        : " + safe(verdict.executing) + "\n");
    process.stdout.write("  project          : " + safe(verdict.context.project_root) + "\n\n");
    process.stdout.write("The record is intact and this installation can take it over in place.\n");
    process.stdout.write("Nothing has been changed. Run the same command with --confirm to adopt.\n");
    return;
  }

  const adopted = core.adoptContext(request);
  // The record is swapped at this point. The sweep is the second half of the
  // adoption and runs here rather than inside adoptContext; every one of its own
  // filesystem paths is caught internally, so it reports a verdict rather than
  // throwing after a mutation that already succeeded.
  const leases = sweepLeases.discardSupersededLeases(
    request.pluginData,
    core.sessionKey(request.sessionId),
    adopted.context.plugin_root,
  );
  process.stdout.write("Zensu session adoption — ADOPTED\n\n");
  process.stdout.write("  record minted by : " + safe(adopted.recorded) + "\n");
  process.stdout.write("  now served by    : " + safe(adopted.executing) + "\n");
  // The anchor the session is bound to from here on. It is carried from the
  // record, never from where this command was invoked, and naming it is the one
  // place the user learns which project that actually is.
  process.stdout.write("  project          : " + safe(adopted.projectRoot) + "\n");
  process.stdout.write("  superseded record: " + safe(adopted.supersededFile) + "\n");
  process.stdout.write("  provenance       : " + safe(adopted.provenance) + "\n");
  process.stdout.write("  leases set aside : " + leases.discarded + "\n");
  process.stdout.write("  leases stuck     : " + leases.failed.length + "\n\n");
  process.stdout.write("This session is bound again from the next tool call onward — no restart is needed.\n");
  if (adopted.provenance === "no-workflow-document") {
    // NOT "a normal state, not a fault" — that wording predates the
    // workflow-baseline repair and is now false in the composed state it names.
    // adoptableRecord condition 6 tolerates a missing document, so a lineage
    // break PLUS a missing baseline lands here: the record is re-minted, the
    // report reads fully successful, and the capability gate then denies every
    // later tool call for the one reason this report did not mention.
    // CLASSIFY before promising. `adoptContext` decides this provenance with
    // `fs.existsSync`, which FOLLOWS symlinks and returns false on any error — so
    // a dangling symlink or an EACCES at the leaf lands here too, and an
    // unconditional "re-run with --confirm to rebuild" then points at a repair
    // that refuses by design. That is the same `test -e` hazard the Stop arm was
    // qualified for and the doctor row was moved off, left standing on this one
    // carrier.
    let adoptedShape = null;
    try {
      adoptedShape = core.classifyWorkflowBaselineShape(
        core.adoptionWorkflowStatePath(adopted.projectRoot, request.sessionId),
        adopted.projectRoot,
      );
    } catch (_error) { adoptedShape = null; }
    process.stdout.write("\nWARNING: this session has no usable workflow document, so there was nothing to\n");
    process.stdout.write("record the takeover in — and while that is so the capability gate denies EVERY\n");
    process.stdout.write("tool in this session. The adoption above is real and is not enough on its own.\n");
    if (isBaselineState(adoptedShape, "UNSAFE")) {
      process.stdout.write("Something is SITTING at that path, so --confirm will REFUSE to rebuild it:\n");
      process.stdout.write("  " + safe(core.baselineUnsafeComponent(adopted.projectRoot,
        core.adoptionWorkflowStatePath(adopted.projectRoot, request.sessionId))) + "\n");
      process.stdout.write("Inspect that before doing anything else, then start a fresh session.\n");
    } else {
      process.stdout.write("Re-run this command with --confirm to rebuild the document, provided it is\n");
      process.stdout.write("genuinely absent rather than replaced; rebuilding is a loss, not a restore — a\n");
      process.stdout.write("review chain that was live when it vanished is gone.\n");
    }
  } else if (adopted.provenance !== "recorded") {
    process.stdout.write("\nWARNING: the adoption succeeded but its provenance entry could not be written.\n");
    process.stdout.write("The takeover is real and unrecorded in the workflow history; report this rather than repeating it.\n");
  }
  reportLeaseWarnings(leases);
}

// Shared by the ordinary adoption and the in-place lease-store repair, so the two can
// never drift into telling the user different things about the same sweep result.
// RENDERS to a string rather than writing, so every arm is drivable from a unit
// test. It was write-only, which is why three of its branches had never been
// executed by anything.
function renderLeaseWarnings(leases) {
  const out = [];
  const w = (line) => out.push(line);
  const leasesUnsafeScope = leasesScope(leases);
  // The component the sweep refused, when it named one. Empty is a legitimate answer
  // — a lock failure knows the store is unusable without knowing which part of it is.
  const leasesUnsafeAt = typeof leases.unsafeAt === "string" ? leases.unsafeAt : "";
  const nameComponent = () => {
    if (leasesUnsafeAt) {
      w("The component that was refused is: " + safe(leasesUnsafeAt) + "\n");
    }
  };
  if (leases.discarded > 0) {
    w("\nNOTE: " + leases.discarded + " review-evidence lease(s) were set aside because they name the previous\n");
    w("installation. Any review evidence they reserved has to be gathered again.\n");
  }
  if (leasesUnsafeScope) {
    // Names the directory that actually failed. The three cases stop the sweep for
    // different reasons and have different remedies: a refused DESTINATION is the
    // shared superseded/ directory, which the sweep only ever writes to — a planted
    // link there is an active tamper signal; a refused SOURCE is this session's own
    // records directory; and a BUSY LOCK is neither, it is ordinary contention.
    if (leasesUnsafeScope === "locked") {
      w("\nWARNING: the review-evidence lease store is LOCKED, so no lease was inspected or\n");
      w("set aside. That is ordinary contention rather than a damaged store: another\n");
      w("process in this session holds the lock, or one exited without releasing it.\n");
      w("Nothing here needs repairing by hand. Re-run this command with --confirm once\n");
      w("that process has finished; if it persists, start a fresh Claude Code session.\n");
    } else if (leasesUnsafeScope === "destination") {
      w("\nWARNING: the review-evidence SUPERSEDED directory could not be opened safely,\n");
      // The OFFENDING component, not the leaf. The walk refuses on four different
      // paths — review-evidence, v1, superseded and superseded/<session key> — and
      // naming the leaf for all four sent the operator to a path that cannot exist
      // whenever the refusal was a plain file planted at one of its parents.
      if (leasesUnsafeAt) {
        nameComponent();
      } else {
        w("It is under <plugin_data>/review-evidence/v1/superseded/.\n");
      }
      w("That subtree is one this plugin only writes to. Two causes produce this: an entry\n");
      w("there that is not a plain directory you own — which is a tamper signal — or an\n");
      w("ordinary I/O failure such as a full or read-only store. Inspect it before doing\n");
      w("anything else. Once the cause is removed, run this command again with\n");
      w("--confirm: an already-served record re-runs the sweep as an in-place repair.\n");
    } else {
      w("\nWARNING: the review-evidence lease RECORDS directory of this session could not be\n");
      // The source arm collects a component name on four of its returns and used to
      // throw it away, which is the same "named the wrong path" defect the
      // destination arm was fixed for.
      nameComponent();
      w("opened safely, so no lease was inspected or set aside. Same two causes as above: an\n");
      w("entry that is not a plain directory you own, or an I/O failure. If any lease there\n");
      w("names the previous installation, review-evidence operations keep failing until it is\n");
      w("moved out by hand.\n");
    }
  }
  if (leases.failed.length > 0) {
    w("\nWARNING: " + leases.failed.length + " review-evidence lease(s) could NOT be set aside: " + leases.failed.map(safe).join(", ") + "\n");
    // Do NOT assert which of the several possible causes applies. An entry lands here
    // when the move collided with a file already set aside, when the link or the
    // unlink half failed, or on an ordinary I/O error — naming only "they still name
    // the previous installation" picked one of those and stated it as fact.
    w("Because every lease read validates the whole set, review-evidence operations will keep\n");
    w("failing for this session until those entries are moved out of the records directory by\n");
    w("hand. Check first whether a file of the same name is already sitting in the superseded\n");
    w("directory: a collision is refused rather than overwritten, so nothing was destroyed.\n");
    w("The adoption itself is complete.\n");
  }
  return out.join("");
}

// Shared by the ordinary adoption and the in-place lease-store repair, so the two
// can never drift into telling the user different things about the same sweep.
function reportLeaseWarnings(leases) {
  process.stdout.write(renderLeaseWarnings(leases));
}

module.exports = {
  DOUBLE_SPACE,
  INVISIBLE,
  ORPHAN_MARK,
  PAIR_SEPARATOR,
  NON_ASCII,
  REMEDY,
  SAFE_DISPLAY,
  leasesScope,
  leaseFault,
  baselineFault,
  baselineVerdict,
  repairBaseline,
  renderBaselineDiagnosis,
  renderBaselineNotes,
  survivingEvidence,
  renderLeaseWarnings,
  repairExitCode,
  repairHeadline,
  repairSweepRoot,
  reportLeaseWarnings,
  shouldRepairInPlace,
  main,
  safe,
};

// Running as a program keeps the outer try/catch the shell payload carried: an
// uncaught throw here would surface as a crashed helper rather than as the refusal it
// was meant to print. Requiring it as a module must NOT run it.
if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write("zensu:adopt-session: "
      + safe(error && error.message ? error.message : "unknown failure") + "\n");
    process.exitCode = 1;
  }
}
