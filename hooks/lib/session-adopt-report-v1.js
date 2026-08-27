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
const safeDisplay = require("./zensu-safe-display-v1.js");
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
// The SAME rule every argv mode in the binder applies to a host session id, applied
// here because this was the one entry point that did not. `zensu-session-adopt.sh`
// forwards `CLAUDE_CODE_SESSION_ID` verbatim, and `core.sessionKey` returns an
// `scv1_<64hex>` value UNCHANGED — that spelling is the name of a record file in the
// store, so without this check the store's own directory listing was a list of
// accepted identities. Called in main() FIRST, with its own
// headline and remedy, and again inside buildRequest so the invariant stays local to
// the function that builds the request and a second caller cannot skip it.
const validateSessionId = require("./claude-hook-session-v1.js").validateSessionId;
const buildRequest = () => {
  const pluginData = process.env.ZADOPT_PLUGIN_DATA;
  validateSessionId(process.env.ZADOPT_SESSION_ID);
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
// The rule itself now lives in the dependency-free leaf module beside this one.
// It was defined HERE first, and the doctor renderer then reached for it with a
// guarded lazy require plus its own narrower fallback copy — a display rule in two
// implementations, owned by a feature command that drags four further modules in
// behind it. `safe` is kept as this file's spelling because the report and its unit
// suite are written against that name.
const safe = safeDisplay.safeDisplayValue;
// Re-exported unchanged so the unit suite keeps pinning the rule through the
// consumer that renders it, rather than having to know where it now lives.
const { SAFE_DISPLAY, DOUBLE_SPACE, NON_ASCII } = safeDisplay;

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

// The headline is CHOSEN from the sweep verdict. It used to be printed before the
// verdict was consulted, so a refused sweep still announced a repair.
const repairHeadline = (repaired) => {
  if (leasesScope(repaired) || (repaired.failed && repaired.failed.length > 0)) {
    return "Zensu session adoption — ALREADY SERVED (lease store NOT repaired)";
  }
  if (!repaired.discarded) {
    return "Zensu session adoption — ALREADY SERVED (nothing to repair)";
  }
  return "Zensu session adoption — ALREADY SERVED (lease store repaired)";
};

// A refused or partial sweep is a failure, and the exit code has to say so: the
// branch returned without touching process.exitCode, so it exited 0 on a refusal
// while the skill's own contract reserves 0 for a successful report or adoption.
const repairExitCode = (repaired) =>
  (leasesScope(repaired) || (repaired.failed && repaired.failed.length > 0) ? 1 : 0);

const shouldRepairInPlace = (verdict, confirmed) =>
  !!verdict
  && verdict.ok === false
  && verdict.reason === core.ADOPTION_REFUSALS.ALREADY_SERVED
  && confirmed === true;

// Every refusal names the condition that was not met, and every one of them has
// a different remedy. A generic "not adoptable" would put the user back where
// the misleading doctor row left them.
const REMEDY = {
  [core.ADOPTION_REFUSALS.RECORD_UNREADABLE]:
    "The record could not be re-verified against the installation that minted it. That installation may have been pruned from the plugin cache, the record may have been altered, or a persisted schema really did change in this release. A recorded project root that is merely GONE is no longer one of these — that state is adoptable — so the disagreement here is one of the others — or there is no record for this session at all, which lands on this same reason. Adoption cannot tell them apart, and in this state /zensu:doctor cannot name the cause either. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.PLUGIN_DATA]:
    "The record belongs to a different plugin-data store — typically a development checkout against an installed plugin, or the reverse. That boundary is never relaxed. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.ALREADY_SERVED]:
    "Nothing to RE-MINT: this installation already serves the record. The lease store is a separate matter — an adoption writes the record first and sweeps the store afterwards, so a run that died in between leaves the record correct and the store still wedged. Re-run this command with --confirm to sweep it again; that repair is idempotent and re-mints nothing. If tools are still failing after it, the cause is a different one — run /zensu:doctor.",
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
  // TWO refusal classes, two headlines. `buildRequest` performs two independent
  // checks — the session identity and the private record store — and routing both
  // into one `catch` printed `private-record-store-unsafe` for a malformed or
  // DERIVED session id, telling the user to repair a store that was never reached.
  // That contradicted this file's own contract that every refusal names the
  // condition it failed; three review seats found it independently. Each class
  // keeps its own cause and its own remedy now.
  try {
    validateSessionId(process.env.ZADOPT_SESSION_ID);
  } catch (error) {
    process.stdout.write("Zensu session adoption — NOT adoptable (session-id-unusable)\n\n");
    process.stdout.write("The session identity this command was given cannot be used: "
      + safe(error && error.message ? error.message : "unknown") + "\n");
    process.stdout.write("It is empty, malformed, or a DERIVED Session Control identifier rather than the\n");
    process.stdout.write("raw host session id. Nothing was read and nothing was changed. Start a fresh\n");
    process.stdout.write("Claude Code session; the record store is not implicated.\n");
    process.exitCode = 1;
    return;
  }
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
      const repaired = sweepLeases.discardSupersededLeases(
        request.pluginData,
        core.sessionKey(request.sessionId),
        repairSweepRoot(request),
      );
      // Headline AFTER the verdict, never before it: printing "repaired"
      // unconditionally made a refused sweep announce a success.
      process.stdout.write(repairHeadline(repaired) + "\n\n");
      process.stdout.write("  leases set aside : " + repaired.discarded + "\n");
      process.stdout.write("  leases stuck     : " + repaired.failed.length + "\n\n");
      process.stdout.write("This installation already serves the record, so nothing was re-minted. The lease\n");
      process.stdout.write("store was swept again, which is the one part of an adoption that can be left\n");
      process.stdout.write("half-done if the previous run died after the record was written.\n");
      if (repaired.discarded === 0 && repaired.failed.length === 0 && !leasesScope(repaired)) {
        process.stdout.write("Nothing needed repairing. If tools are still failing, the cause is a different\n");
        process.stdout.write("one — run /zensu:doctor.\n");
      }
      reportLeaseWarnings(repaired);
      process.exitCode = repairExitCode(repaired);
      return;
    }
    process.stdout.write("Zensu session adoption — NOT adoptable (" + safe(verdict.reason) + ")\n\n");
    process.stdout.write((REMEDY[verdict.reason] || "No remedy is known for this refusal. Start a fresh Claude Code session.") + "\n");
    process.exitCode = 1;
    return;
  }

  if (process.env.ZADOPT_CONFIRM !== "1") {
    process.stdout.write("Zensu session adoption — ADOPTABLE\n\n");
    process.stdout.write("  record minted by : " + safe(verdict.recorded) + "\n");
    process.stdout.write("  executing        : " + safe(verdict.executing) + "\n");
    process.stdout.write("  project          : " + safe(verdict.context.project_root)
      + (verdict.orphanedProjectRoot ? "  (GONE)" : "") + "\n\n");
    // The unqualified sentence is only earned when a workflow document was
    // actually readable. In the orphaned branch condition 6 never ran, so
    // claiming the record is "intact" at the same strength as on the ordinary
    // path overstates what was checked — see the qualified line below.
    if (!verdict.orphanedProjectRoot) {
      process.stdout.write("The record is intact and this installation can take it over in place.\n");
    }
    // Stated BEFORE the user confirms, not only after: an adoption that leaves
    // Edit, Write and every WRITING Bash command denied is not the rescue an
    // unqualified "adoptable" implies,
    // and finding that out afterwards reads as a failed repair.
    if (verdict.orphanedProjectRoot) {
      process.stdout.write("The record itself is readable and this installation can take it over in place.\n");
      process.stdout.write("\nThe recorded project root no longer exists — a deleted or recycled worktree left\n");
      process.stdout.write("the workflow state unreachable from this record. Adoption still applies and is\n");
      process.stdout.write("worth doing: it clears the lineage break, so READ-ONLY Bash and the read-only\n");
      process.stdout.write("diagnostics work again. It does NOT restore writes — Edit, Write and MultiEdit\n");
      process.stdout.write("stay denied, and so does any Bash command the source-write gate can attribute\n");
      process.stdout.write("as a write, because a write cannot be attributed to a project that is not\n");
      process.stdout.write("there. NotebookEdit is the one mutation that still passes, in a healthy\n");
      process.stdout.write("session too. To write again, re-create exactly that directory or start a\n");
      process.stdout.write("fresh Claude Code session. If it was moved rather than deleted, its state\n");
      process.stdout.write("still exists there.\n");
      // The schema-equality check that authorises an ordinary takeover did NOT
      // run here, and a report that stays silent about it lets the user read a
      // weaker check as the stronger one. Condition 6 is guarded by an
      // existsSync on the workflow document, which is false for an absent root.
      process.stdout.write("\nNOT CHECKED: with no readable workflow document, the schema-equality check that\n");
      process.stdout.write("normally authorises a takeover was not performed, and a document restored later\n");
      process.stdout.write("is not verified against this runtime. Re-creating the directory BEFORE adopting\n");
      process.stdout.write("is what lets that check run; adopting first skips it for good.\n");
    }
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
  process.stdout.write("  project          : " + safe(adopted.projectRoot)
    + (adopted.orphanedProjectRoot ? "  (GONE)" : "") + "\n");
  process.stdout.write("  superseded record: " + safe(adopted.supersededFile) + "\n");
  process.stdout.write("  provenance       : " + safe(adopted.provenance) + "\n");
  process.stdout.write("  leases set aside : " + leases.discarded + "\n");
  process.stdout.write("  leases stuck     : " + leases.failed.length + "\n\n");
  if (adopted.orphanedProjectRoot) {
    // Never the unqualified "bound again" line for this shape. The lineage break
    // is gone, but the anchor is still a directory that does not exist, which is
    // the ordinary orphaned-project-root state: reads and diagnostics run, writes
    // do not. Saying otherwise would send the user straight into a deny.
    process.stdout.write("This session's lineage break is repaired from the next tool call onward — no restart\n");
    process.stdout.write("is needed. The recorded project root is still gone, so the session is now in the\n");
    process.stdout.write("orphaned-project-root state: READ-ONLY Bash and the read-only diagnostics work,\n");
    process.stdout.write("while Edit, Write and MultiEdit stay denied, and so does any Bash command the source-write gate can attribute as a write, — a write cannot\n");
    process.stdout.write("be attributed to a project that is not there. Re-create exactly that directory,\n");
    process.stdout.write("or start a fresh Claude Code session, to write again.\n");
  } else {
    process.stdout.write("This session is bound again from the next tool call onward — no restart is needed.\n");
  }
  if (adopted.provenance === "no-workflow-document") {
    // TWO sentences for one provenance value, because that value means two
    // different things. The guard behind it is an existsSync UNDER
    // adopted.projectRoot, and in the orphaned case that directory is the absent
    // one — so `no-workflow-document` is returned unconditionally there, whether
    // or not the session ever had a document. Printing "this session had no
    // workflow document ... a normal state" is then a claim the code never
    // established and is affirmatively wrong in the primary case: the document
    // lived under that root. Held to the same evidentiary standard the Stop
    // releases use — "not reachable", never "gone" — since one ENOENT cannot
    // tell a delete from a move.
    if (adopted.orphanedProjectRoot) {
      process.stdout.write("\nNOTE: the recorded project root is gone, so any workflow document it held is not\n");
      process.stdout.write("reachable from this record and the takeover could not be written into one. If that\n");
      process.stdout.write("directory was moved rather than deleted, its state still exists there.\n");
    } else {
      process.stdout.write("\nNOTE: this session had no workflow document, so there was nothing to record the\n");
      process.stdout.write("takeover in. That is a normal state, not a fault.\n");
    }
  } else if (adopted.provenance !== "recorded") {
    process.stdout.write("\nWARNING: the adoption succeeded but its provenance entry could not be written.\n");
    process.stdout.write("The takeover is real and unrecorded in the workflow history; report this rather than repeating it.\n");
  }
  // DELIBERATELY no `process.exitCode` here, and the asymmetry with the repair branch
  // is the point rather than an oversight. There the sweep IS the whole operation, so
  // a refused or partial sweep is the operation failing and exit 1 says so. Here the
  // record was re-minted successfully and the sweep is secondary: exiting non-zero
  // would tell a caller the ADOPTION failed, which is false and is the more damaging
  // wrong answer of the two. The warnings below carry the sweep's verdict in full.
  //
  // Recorded because a review round proposed unifying the two, the unified version was
  // written, and AC-C12 caught it: that row requires this command to exit 0 while its
  // destination refusal is named — it is the pin that encodes this distinction.
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
  NON_ASCII,
  REMEDY,
  SAFE_DISPLAY,
  leasesScope,
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
