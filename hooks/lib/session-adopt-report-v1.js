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
// tests/structure/session-adopt-report.test.js.

const path = require("node:path");
const core = require("./session-control-core-v1.js");
// The superseded-lease sweep. It is NOT part of adoptContext any more: requiring the
// lease owner from the core is a require cycle, so the sweep moved into its own
// module and this entry script — which already loads both halves — became its
// caller. Required at the TOP on purpose: a broken or missing sweep module then
// fails this command before adoptContext has mutated anything, rather than after.
const sweepLeases = require("./review-evidence-sweep-v1.js");

const pluginRoot = process.env.ZADOPT_PLUGIN_ROOT;
const pluginData = process.env.ZADOPT_PLUGIN_DATA;
const sessionId = process.env.ZADOPT_SESSION_ID;
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
const buildRequest = () => ({
  recordsDir: privateRecordsDirectory(pluginData),
  sessionId,
  host: "claude",
  pluginData,
  executingPluginRoot: pluginRoot,
});

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
const PAIR_SEPARATOR = / : /;
const NON_ASCII = new RegExp("[\\u007f-\\uffff]", "g");
const SPACE_RUN = / {2,}/g;
const safe = (value) => {
  const text = String(value);
  if (SAFE_DISPLAY.test(text) && !DOUBLE_SPACE.test(text) && !PAIR_SEPARATOR.test(text)) {
    return text;
  }
  return JSON.stringify(text)
    .replace(NON_ASCII, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"))
    // The DOUBLE_SPACE invariant applies to BOTH branches. It used to guard only the
    // fast path, so `/tmp/a"b  project : x` was rendered through JSON.stringify with
    // the two-space run and the colon intact — the exact forgery the fast-path guard
    // exists to stop, arriving through the branch meant to be the safer one. Single
    // spaces survive, so an ordinary quoted path stays readable.
    .replace(SPACE_RUN, (run) => "\\u0020".repeat(run.length));
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
    "The record could not be re-verified against the installation that minted it. Its recorded project root may be gone, that installation may have been pruned from the plugin cache, the record may have been altered, or a persisted schema really did change in this release. Adoption cannot tell these apart, and in this state /zensu:doctor cannot name the directory either. Start a fresh Claude Code session.",
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
      // The executing root comes from the RECORD, not from the verdict: a refusal
      // carries only `{ ok, reason }` — reading `verdict.context` here threw
      // "Cannot read properties of undefined", which an end-to-end row caught and
      // the predicate-level unit test could not. And not from the environment
      // either: the sweep compares this value against each lease's recorded
      // plugin_root, so it has to be the same canonical spelling the record holds.
      // "Already served" is precisely the statement that the record names this
      // installation.
      let servedRoot;
      try {
        servedRoot = core.readContext({
          recordsDir: request.recordsDir,
          sessionId: request.sessionId,
          expectedHost: "claude",
        }).plugin_root;
      } catch (error) {
        process.stdout.write("Zensu session adoption — NOT adoptable (" + safe(verdict.reason) + ")\n\n");
        process.stdout.write("The record says this installation already serves it, but it could not be re-read to\n");
        process.stdout.write("sweep the lease store: " + safe(error && error.message ? error.message : "unknown") + "\n");
        process.exitCode = 1;
        return;
      }
      const repaired = sweepLeases.discardSupersededLeases(
        request.pluginData,
        core.sessionKey(request.sessionId),
        servedRoot,
      );
      process.stdout.write("Zensu session adoption — ALREADY SERVED (lease store repaired)\n\n");
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
  // WHICH directory the sweep refused, empty when it refused nothing. ONE field: a
  // parallel boolean would be a second spelling of the same fact.
  const leasesUnsafeScope = leasesScope(leases);
  // The component the sweep refused, when it named one. Empty is a legitimate answer
  // — a lock failure knows the store is unusable without knowing which part of it is.
  const leasesUnsafeAt = typeof leases.unsafeAt === "string" ? leases.unsafeAt : "";
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
    process.stdout.write("\nNOTE: this session had no workflow document, so there was nothing to record the\n");
    process.stdout.write("takeover in. That is a normal state, not a fault.\n");
  } else if (adopted.provenance !== "recorded") {
    process.stdout.write("\nWARNING: the adoption succeeded but its provenance entry could not be written.\n");
    process.stdout.write("The takeover is real and unrecorded in the workflow history; report this rather than repeating it.\n");
  }
  reportLeaseWarnings(leases);
}

// Shared by the ordinary adoption and the in-place lease-store repair, so the two can
// never drift into telling the user different things about the same sweep result.
function reportLeaseWarnings(leases) {
  const leasesUnsafeScope = leasesScope(leases);
  // The component the sweep refused, when it named one. Empty is a legitimate answer
  // — a lock failure knows the store is unusable without knowing which part of it is.
  const leasesUnsafeAt = typeof leases.unsafeAt === "string" ? leases.unsafeAt : "";
  if (leases.discarded > 0) {
    process.stdout.write("\nNOTE: " + leases.discarded + " review-evidence lease(s) were set aside because they name the previous\n");
    process.stdout.write("installation. Any review evidence they reserved has to be gathered again.\n");
  }
  if (leasesUnsafeScope) {
    // Names the directory that actually failed. Both cases stop the sweep, but they
    // sit in different places and mean different things: a refused DESTINATION is
    // the shared superseded/ directory, which the sweep only ever writes to — a
    // planted link there is an active tamper signal, and pointing the operator at
    // the records directory the sweep had just read successfully left it
    // uninvestigated.
    if (leasesUnsafeScope === "destination") {
      process.stdout.write("\nWARNING: the review-evidence SUPERSEDED directory could not be opened safely,\n");
      // The OFFENDING component, not the leaf. The walk refuses on four different
      // paths — review-evidence, v1, superseded and superseded/<session key> — and
      // naming the leaf for all four sent the operator to a path that cannot exist
      // whenever the refusal was a plain file planted at one of its parents.
      if (leasesUnsafeAt) {
        process.stdout.write("The component that was refused is: " + safe(leasesUnsafeAt) + "\n");
      } else {
        process.stdout.write("It is under <plugin_data>/review-evidence/v1/superseded/.\n");
      }
      process.stdout.write("That subtree is one this plugin only writes to. Two causes produce this: an entry\n");
      process.stdout.write("there that is not a plain directory you own — which is a tamper signal — or an\n");
      process.stdout.write("ordinary I/O failure such as a full or read-only store. Inspect it before doing\n");
      process.stdout.write("anything else. Once the cause is removed, run this command again with\n");
      process.stdout.write("--confirm: an already-served record re-runs the sweep as an in-place repair.\n");
    } else {
      process.stdout.write("\nWARNING: the review-evidence lease RECORDS directory of this session could not be\n");
      process.stdout.write("opened safely, so no lease was inspected or set aside. Same two causes as above: an\n");
      process.stdout.write("entry that is not a plain directory you own, or an I/O failure. If any lease there\n");
      process.stdout.write("names the previous installation, review-evidence operations keep failing until it is\n");
      process.stdout.write("moved out by hand.\n");
    }
  }
  if (leases.failed.length > 0) {
    process.stdout.write("\nWARNING: " + leases.failed.length + " review-evidence lease(s) could NOT be set aside: " + leases.failed.map(safe).join(", ") + "\n");
    // Do NOT assert which of the several possible causes applies. An entry lands here
    // when the move collided with a file already set aside, when the link or the
    // unlink half failed, or on an ordinary I/O error — naming only "they still name
    // the previous installation" picked one of those and stated it as fact.
    process.stdout.write("Because every lease read validates the whole set, review-evidence operations will keep\n");
    process.stdout.write("failing for this session until those entries are moved out of the records directory by\n");
    process.stdout.write("hand. Check first whether a file of the same name is already sitting in the superseded\n");
    process.stdout.write("directory: a collision is refused rather than overwritten, so nothing was destroyed.\n");
    process.stdout.write("The adoption itself is complete.\n");
  }
}

module.exports = {
  DOUBLE_SPACE,
  NON_ASCII,
  REMEDY,
  SAFE_DISPLAY,
  leasesScope,
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
