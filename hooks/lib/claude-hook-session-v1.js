#!/usr/bin/env node
'use strict';

// Rebuild the six helper-private Session Control bindings from standard
// Claude inputs: hook payloads provide session_id, while model-side helper
// calls provide CLAUDE_CODE_SESSION_ID. Ambient ZENSU_* values are deliberately
// ignored: the private, immutable context record is the only authority. The
// all-tool capability gate imports the same resolver.
//
// argv modes: (none) binds from a hook payload on stdin and prints the six
// exports; `model-bind` does the same from CLAUDE_CODE_SESSION_ID;
// `unregistered` answers by EXIT STATUS ONLY — 0 when Session Control has never
// registered the session, 1 for every other state including a record that
// exists and disagrees; `orphaned-project-root` answers by exit status — 0 when
// a record exists, validates in every other respect, and its recorded project
// root is simply gone — and on a match prints that dead path so callers can
// name it; `model-orphaned-project-root` is the same question asked from
// CLAUDE_CODE_SESSION_ID, for the model-side /zensu:doctor;
// `incompatible-runtime` and its `model-` twin answer by exit status — 0 when
// the record reads and the disagreement is a declared-incompatible executing
// lineage, with or without a vanished project root — and on a match print
// `recorded<TAB>executing`, two fields and never three; `pruned-plugin-root`
// and its `model-` twin answer the same way — 0 when the record is intact and
// the SOLE disagreement is that the installation which minted it no longer
// exists on disk — and print the same two-field pair, so every parser of that
// pair reads it unchanged; `orphaned-incompatible-root` and its `model-` twin
// answer the third fact of the lineage state separately — 0 and the dead path
// when the lineage is incompatible AND the recorded root is gone, **3** when it
// positively is not, and 1 for every unavailable answer — so the two-field
// format above can stay exactly as every shell parser reads it. That three-way
// status is not decoration: a caller that cannot tell a negative from an
// unavailable answer must guess, and the wrong guess makes it assert the
// workflow document survived. None of these prints bindings: a session in any of
// those states must stay unbound. The first three exist so the gates can tell
// the two RELAXABLE bind failures apart from each other and from all the rest;
// the rest name states that are NOT relaxable — for a live project root a
// workflow document is still reachable, and for a vanished root or a pruned
// installation the repair is adoption rather than a waiver — and exist so the
// diagnosis stops being reported as "no record", which is false, and so the one
// in-place remedy, /zensu:adopt-session, can be named. The two halves of the
// lineage state carry DIFFERENT truths about the workflow document, which is why
// that third fact has a hook-payload spelling and not only a model-side one: the
// Stop hook must not tell a user whose worktree is gone that their chain state
// survived.
//
// HOOK-PAYLOAD BINDS ADOPT; `model-bind` NEVER DOES. When the strict bind fails
// for a reason adoptableRecord admits (a lineage the version numbers refuse, a
// vanished project root, a pruned minting installation) the hook-payload mode
// hands the record to session-auto-adopt-v1.js, which re-mints it under the
// executing installation with provenance and sweeps the superseded leases, and
// the bind then succeeds on its strict re-read. The sixth export
// `ZENSU_SESSION_ADOPTED` names `recorded -> executing` when THIS invocation did
// that and is empty otherwise; NO hook reads it yet — it exists so the shell hook
// that adopted can announce it, and the planned consumer is the install-lineage
// notice hook. `adoption-refusal` (payload on stdin) is the read-only companion
// for the deny emitters: it prints ONE token — an ADOPTION_REFUSALS value,
// `opted-out`, `adopted-concurrently`, `superseded-record-exists` or
// `not-completed` — never a TAB, so the two-field pair above keeps the shape
// its shell parsers read, and exits 1 when the question cannot be answered.

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const hostPaths = require('./claude-path-v1.js');

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const ALLOWED_EVENTS = new Set([
  'SessionStart',
  'PreToolUse',
  'PostToolUse',
  'Stop',
  'UserPromptSubmit',
]);

function fail(message) {
  throw new Error(`claude hook session binder: ${message}`);
}

function canonicalDirectory(value, label, rejectAlias = false) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) {
    fail(`${label} is unavailable or unsafe`);
  }
  const requested = path.resolve(hostPaths.normalizeHostPathInput(value, label));
  let supplied;
  let canonical;
  try {
    supplied = fs.lstatSync(requested);
    canonical = fs.realpathSync.native(requested);
  } catch {
    fail(`${label} does not exist`);
  }
  if (rejectAlias && supplied.isSymbolicLink()) fail(`${label} must not be a symlink`);
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`${label} must be a real directory`);
  return canonical;
}

function privateRecordsDirectory(pluginData, allowMissing = false) {
  let current = pluginData;
  for (const segment of ['session-control', 'v1', 'records']) {
    current = path.join(current, segment);
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (error) {
      if (allowMissing && error.code === 'ENOENT') return null;
      fail('private Session Control record directory is missing');
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      fail('private Session Control record directory is unsafe');
    }
    if (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) {
      fail('private Session Control record directory permissions are unsafe');
    }
    if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
      fail('private Session Control record directory ownership is unsafe');
    }
  }
  if (fs.realpathSync.native(current) !== current) {
    fail('private Session Control record directory is aliased');
  }
  return current;
}

// True ONLY when Session Control has no record for this session at all — the
// records directory or the record file is simply absent. That is the 0.17.0
// upgrade state: Session Control shipped in that release, and a resume/compact
// SessionStart requires a record it never mints, so every session predating the
// update is unbindable forever and cannot be repaired in place.
//
// It is deliberately NOT true when a record EXISTS and disagrees with reality —
// runtime digest drift, a foreign plugin root, plugin data, or project root,
// tampering. A present-but-wrong record is a security signal and must keep
// failing every gate closed. Anything other than a clean ENOENT answers false,
// so an unreadable, unsafe, or ambiguous state also stays closed.
function unregisteredSession(payload, environment = process.env) {
  try {
    validateSessionId(payload.session_id);
    const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
    if (canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT') !== executedPluginRoot) {
      return false;
    }
    const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
    const recordsDir = privateRecordsDirectory(pluginData, true);
    if (recordsDir === null) return true;
    try {
      fs.lstatSync(path.join(recordsDir, `${core.sessionKey(payload.session_id)}.json`));
    } catch (error) {
      return error.code === 'ENOENT';
    }
    return false;
  } catch {
    return false;
  }
}

// The SECOND relaxable bind failure, and deliberately a separate predicate from
// unregisteredSession above: there a record is absent, here a record is present
// and intact and only the directory it points at is gone. Both mean no workflow
// state is reachable, but they are different diagnoses with different remedies,
// so the gates must be able to tell them apart rather than share one widened
// check.
//
// Returns the dead recorded project root, or null when this is not that state.
// Any additional disagreement, any unreadable or ambiguous state, and any
// exception answers null, so the caller keeps failing closed.
function resolveOrphanedProjectRoot(payload, environment = process.env) {
  try {
    validateSessionId(payload.session_id);
    const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
    if (canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT') !== executedPluginRoot) {
      return null;
    }
    const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
    const recordsDir = privateRecordsDirectory(pluginData, true);
    if (recordsDir === null) return null;
    const context = core.readOrphanedProjectRootContext({
      recordsDir,
      sessionId: payload.session_id,
      expectedHost: 'claude',
    });
    // The same two identity checks resolveHookSession applies, because
    // readOrphanedProjectRootContext validates the record against itself and
    // cannot see the running installation.
    //
    // Since semver-compatible binding the plugin-root check is itself
    // lineage-relaxed, so state the property that actually holds: a vanished
    // project root may be relaxed ALONGSIDE an executing root that is a
    // declared-compatible upgrade of the recorded one — that combination is
    // deliberate, because neither disagreement can anchor a workflow document.
    // What is still never relaxed alongside it is an INCOMPATIBLE root, a
    // differing plugin_data, or any other disagreement readContext rejects.
    if (!core.servesRecordedRuntime(context, executedPluginRoot, 'claude')) return null;
    if (context.plugin_data !== pluginData) return null;
    return context.project_root;
  } catch {
    return null;
  }
}

function orphanedProjectRootSession(payload, environment = process.env) {
  return resolveOrphanedProjectRoot(payload, environment) !== null;
}

// The THIRD bind-failure diagnosis, and a THIRD separate predicate — never a
// widening of either one above. Those two answer "is there anything left to
// enforce"; this one answers "is the record fine and only the runtime serving it
// declared incompatible". A plugin update that lands mid-session produces
// exactly that: the record is intact, its digest still verifies against the root
// it was minted under, and runtimeLineageCompatible refuses because at major 0
// the minor is the breaking axis.
//
// It is NOT a relaxable state, in EITHER of its two halves, but they are not
// relaxed for the same reason and a consumer must not treat them as one. When
// the recorded project root still exists a workflow document IS reachable, so
// relaxing a write gate would waive a live guarantee — unlike the two states
// above, where nothing is left to waive. When that root is GONE the document
// is not reachable from this record, and what keeps the state unrelaxed is instead that it has a real
// in-place repair: adoption, a deliberate user action that leaves provenance,
// rather than a silent waiver. Any caller that says something about the
// workflow document must read `orphanedProjectRoot` and branch; the Stop hook
// does. What the predicate buys is a NAME: the doctor row, the Stop release and
// the deny text can state the real cause and both versions instead of falling
// through to "no valid record", which is false and sends the user hunting for a
// record that is sitting intact in plugin data.
//
// It reads STRICTLY FIRST and falls back to the orphan reader only when the
// strict read throws. The fallback cannot widen the diagnosis, because
// readOrphanedProjectRootContext waives exactly one check and REFUSES a root
// that still exists: a record it returns disagrees about the project root and
// nothing else. Every other disagreement still throws in both readers and still
// answers null here.
//
// The combined state — vanished project root AND incompatible lineage — is
// therefore reported HERE rather than by the orphan predicate, which answers
// null for it because it re-applies servesRecordedRuntime. Before that fallback
// existed the combination fell through to "no valid record", which is false and
// is exactly the wording this diagnosis exists to remove; the state is also
// adoptable, so a deny that told the user to start a fresh session contradicted
// the repair /zensu:adopt-session offers. Reporting it here is what gives all
// five deny sites the in-place remedy without a sixth predicate.
//
// This does NOT relax anything: the state stays unbound and every gate keeps
// denying. RELAXING a gate for a vanished root is still the orphan predicate's
// job alone, and it still requires a compatible lineage.
//
// Returns { recorded, executing, orphanedProjectRoot } — both declared versions
// plus the dead project root, or null for that third field when the recorded
// root still exists — or null when this is not that state. Any additional
// disagreement, any unreadable or ambiguous state, and any exception answers
// null, so the caller keeps failing closed.
function resolveIncompatibleRuntime(payload, environment = process.env) {
  try {
    validateSessionId(payload.session_id);
    const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
    if (canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT') !== executedPluginRoot) {
      return null;
    }
    const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
    const recordsDir = privateRecordsDirectory(pluginData, true);
    if (recordsDir === null) return null;
    const readerOptions = {
      recordsDir,
      sessionId: payload.session_id,
      expectedHost: 'claude',
    };
    let context;
    let orphanedProjectRoot = null;
    try {
      context = core.readContext(readerOptions);
    } catch {
      // Only reached when the strict read failed. If THIS read also throws the
      // whole function answers null through the outer catch, so a record that
      // disagrees about anything else is never reclassified as this state.
      context = core.readOrphanedProjectRootContext(readerOptions);
      orphanedProjectRoot = context.project_root;
    }
    if (context.plugin_data !== pluginData) return null;
    // The disagreement must be the lineage and nothing else: if this root DOES
    // serve the record, the bind failed for some other reason and naming the
    // lineage would be a wrong diagnosis.
    if (core.servesRecordedRuntime(context, executedPluginRoot, 'claude')) return null;
    const executing = core.executingPluginVersion(executedPluginRoot, 'claude');
    // A root that declares nothing readable is not a lineage claim — it is a
    // root that cannot be identified — so it is not this state either.
    if (typeof executing !== 'string' || executing === '') return null;
    return { recorded: context.plugin_version, executing, orphanedProjectRoot };
  } catch {
    return null;
  }
}


// The FOURTH named bind failure: the record is intact and the SOLE disagreement
// is that the installation which minted it has been pruned from the plugin
// cache, so nothing can re-verify the record and no installation can serve it.
// Disjoint from the lineage predicate above by construction — that one needs
// the strict read to succeed, this one needs it to fail — and deliberately
// blind to lineage: the state is reachable under a compatible lineage too, and
// the remedy is the same either way. Adoption is the one exit, so like the
// lineage state this is named, never relaxed.
//
// Returns { recorded, executing } — both declared versions — or null when this
// is not that state. Any additional disagreement, any unreadable or ambiguous
// state, and any exception answers null, so the caller keeps failing closed.
function resolvePrunedPluginRoot(payload, environment = process.env) {
  try {
    validateSessionId(payload.session_id);
    const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
    if (canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT') !== executedPluginRoot) {
      return null;
    }
    const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
    const recordsDir = privateRecordsDirectory(pluginData, true);
    if (recordsDir === null) return null;
    const readerOptions = { recordsDir, sessionId: payload.session_id, expectedHost: 'claude' };
    // The strict read must FAIL: a record it accepts is either served or a
    // lineage question, and naming a pruned installation there would be a wrong
    // diagnosis. The relaxed read must then SUCCEED, which proves the absence of
    // the recorded root is the only thing the strict read tripped on.
    try {
      core.readContext(readerOptions);
      return null;
    } catch {
      // fall through to the relaxed read
    }
    const context = core.readPrunedPluginRootContext(readerOptions);
    if (context.plugin_data !== pluginData) return null;
    // The same sibling bound adoption applies: a pruned record of a FOREIGN
    // installation (a --plugin-dir checkout beside nothing) is a second
    // disagreement, not this state.
    // Both sides canonical, so the comparison stays in ONE namespace. The right
    // side already is — `executedPluginRoot` came from canonicalDirectory above,
    // and the parent of a realpath is itself a realpath. The left side is a
    // recorded STRING, and this is the one branch that can never re-canonicalize
    // its own root, because that root is gone by construction. Any change to the
    // symlink topology above the plugin cache AFTER minting — a dotfile manager
    // turning ~/.claude into a symlink, or the reverse, or a move to another
    // volume — would otherwise make the two disagree forever: the predicate
    // answers null, the state is never named, and the session falls back to the
    // generic deny and the unbounded Stop block this whole feature exists to
    // remove. It fails CLOSED, which is why it was P3 rather than P1. The parent
    // is proven to exist by readPrunedPluginRootContext, which canonicalDirectory's
    // it before returning, so it always resolves on this branch; if it somehow
    // does not, this throws into the catch below and answers null exactly as the
    // string compare did.
    if (canonicalDirectory(path.dirname(context.plugin_root), 'recorded plugin root parent')
        !== path.dirname(executedPluginRoot)) return null;
    const executing = core.executingPluginVersion(executedPluginRoot, 'claude');
    if (typeof executing !== 'string' || executing === '') return null;
    // The recorded version is rendered into `recorded<TAB>executing`, which the
    // shell parsers split with ${V%%$'\t'*} and ${V##*$'\t'} — first field and LAST. On
    // the lineage path readContextInternal proves manifest.version equals this
    // field, and that comparison is what has kept it separator-free; the pruned
    // waiver drops exactly that comparison, so this is the first producer without
    // it and the bound has to be applied here. validateContext only requireText's
    // the field, and requireText admits a tab: a recorded `0.19.0<TAB>9.9.9` would
    // put THREE fields on the wire, both halves would pass the consumers' own
    // shape guard, the middle one would vanish, and every surface would name a
    // version pair the record does not hold. One rule, from the module that owns
    // it — never a hand-copied alternation.
    if (!core.ADOPTION_SAFE_VERSION_RE.test(context.plugin_version)) return null;
    return { recorded: context.plugin_version, executing };
  } catch {
    return null;
  }
}

function validateSessionId(sessionId) {
  if (
    typeof sessionId !== 'string'
    || sessionId.trim() === ''
    || sessionId.length > 4096
    || /[\0\r\n]/.test(sessionId)
  ) {
    fail('session id is unavailable or unsafe');
  }
  if (/^(?:scv1_[a-f0-9]{64}|sha256:[a-f0-9]{64})$/.test(sessionId)) {
    fail('host session id must be raw, not a derived Session Control identifier');
  }
}

function readPayload() {
  const raw = fs.readFileSync(0);
  if (raw.length === 0 || raw.length > MAX_PAYLOAD_BYTES) fail('hook payload is empty or too large');
  let payload;
  try {
    payload = JSON.parse(raw.toString('utf8'));
  } catch {
    fail('hook payload is invalid JSON');
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    fail('hook payload must be an object');
  }
  if (payload.hook_event_name !== undefined && !ALLOWED_EVENTS.has(payload.hook_event_name)) {
    fail('unsupported hook event');
  }
  validateSessionId(payload.session_id);
  return payload;
}

function shellQuote(value) {
  if (typeof value !== 'string' || /[\0\r\n]/.test(value)) fail('binding value is unsafe');
  return `'${value.replaceAll("'", "'\\''")}'`;
}

// The adoption request this file hands to session-auto-adopt-v1.js. Built once so
// its two callers — resolveHookSession and the `adoption-refusal` mode — cannot
// disagree about the seven keys this file supplies. The ladder reads an eighth,
// `observedRecorded`, which only the SessionStart adapter can know and this file
// deliberately never sets. The capability gate is NOT a caller: it reaches the
// ladder through resolveHookSession's `autoAdopt` option.
function adoptionRequest(payload, environment, executedPluginRoot, pluginData, recordsDir) {
  return {
    executingPluginRoot: executedPluginRoot,
    pluginData,
    recordsDir,
    sessionId: payload.session_id,
    host: 'claude',
    environment,
    respectOptOut: true,
  };
}

// LAZY on purpose: session-auto-adopt-v1.js requires the lease sweep, which
// requires the lease owner, which requires THIS file. A top-level require here
// would close that cycle; inside a function body every module is initialized.
function autoAdoptModule() {
  return require('./session-auto-adopt-v1.js');
}

// The ONE stderr line about an adoption THIS process performed, for every caller
// that has no model or user channel: the CLI mode below on its success path, the
// CLI mode's failure path when the strict re-read fails after the adoption, and
// the in-process review-evidence hook. The sentence itself is the module's
// operatorLine, so every interpolated value goes through the shared screens.
// Never throws: it runs inside catch blocks, where a second fault would replace
// the diagnostic it was meant to accompany.
// The adoption a FAILED bind performed, or null. resolveHookSession hangs a verdict
// on two different errors: the typed refusal (outcome refused, opted-out, …) and the
// strict re-read that failed AFTER an adoption landed. Only the second is an
// adoption to disclose, and the outcome is compared against the module's constant
// rather than a literal a rename would silently orphan.
function performedAdoption(error) {
  if (!error || !error.adoption || typeof error.adoption !== 'object') return null;
  try {
    return error.adoption.outcome === autoAdoptModule().AUTO_ADOPT_OUTCOMES.ADOPTED ? error.adoption : null;
  } catch {
    return null;
  }
}

const BINDER_LEAD_IN = 'claude hook session binder';

// The operator line under the lead-in of the process that PERFORMED the adoption:
// an adoption the in-process evidence hook performed is that hook's, and naming the
// binder there attributed it to a process that never ran.
function writeAdoptionOperatorLine(adoption, leadIn = BINDER_LEAD_IN) {
  try {
    process.stderr.write(`${leadIn}: ${autoAdoptModule().operatorLine(adoption)}\n`);
  } catch {
    process.stderr.write(`${leadIn}: adopted the Session Control record (details unavailable)\n`);
  }
}

// Binds and DISCLOSES an adoption this process performed, on both halves: a bind
// that returns carries the verdict on `binding.adoption`, and a bind whose strict
// re-read then throws — a vanished project root — carries it on the error, which is
// re-thrown after the line. ONE implementation for this file's CLI mode and every
// in-process caller, so the disclosure policy is spelled once.
function bindAndDisclose(payload, environment = process.env, options = {}, leadIn = BINDER_LEAD_IN) {
  let binding;
  try {
    binding = resolveHookSession(payload, environment, options);
  } catch (error) {
    const performed = performedAdoption(error);
    if (performed) writeAdoptionOperatorLine(performed, leadIn);
    throw error;
  }
  if (binding.adoption) writeAdoptionOperatorLine(binding.adoption, leadIn);
  return binding;
}

function resolveHookSession(payload, environment = process.env, options = {}) {
  validateSessionId(payload.session_id);
  const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  const declaredPluginRoot = canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT');
  if (declaredPluginRoot !== executedPluginRoot) fail('CLAUDE_PLUGIN_ROOT does not match the executing plugin');

  const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
  const recordsDir = privateRecordsDirectory(pluginData);
  const sessionKey = core.sessionKey(payload.session_id);

  // The strict bind, unchanged in its semantics. Equal root, or a
  // declared-compatible upgrade of it: a plugin update that lands mid-session
  // moves the executing root while the record stays valid against its own (see
  // readContextInternal, which recomputes the digest and re-reads the manifest
  // against the RECORDED root). plugin_data is NOT relaxed — it is what keeps an
  // inline/dev source and an installed marketplace plugin on separate record
  // stores.
  const served = () => {
    const context = core.readContext({ recordsDir, sessionId: payload.session_id, expectedHost: 'claude' });
    if (!core.servesRecordedRuntime(context, executedPluginRoot, 'claude')) {
      fail('context plugin root is not a compatible lineage of the executing plugin');
    }
    if (context.plugin_data !== pluginData) fail('context plugin data does not match CLAUDE_PLUGIN_DATA');
    return context;
  };

  let context;
  let adoption = null;
  try {
    context = served();
  } catch (error) {
    // AUTOMATIC ADOPTION, hook-side callers only. A strict read that fails — a
    // lineage the version numbers refuse, a vanished project root, a pruned
    // minting installation — is handed to the shared ladder, whose admission is
    // exactly adoptableRecord's own: schema equality, sibling install, same
    // plugin data, executing not older. This binder classifies nothing itself,
    // so every other disagreement (tamper, digest drift, a foreign store) lands
    // on `record-unreadable` and on the unchanged deny below. `model-bind` never
    // opts in: a doctor or a zensu-log verb must stay write-free.
    if (!options.autoAdopt) throw error;
    const autoAdopt = autoAdoptModule();
    const OUTCOMES = autoAdopt.AUTO_ADOPT_OUTCOMES;
    const verdict = autoAdopt.adoptForHook(
      adoptionRequest(payload, environment, executedPluginRoot, pluginData, recordsDir),
    );
    if (verdict.outcome === OUTCOMES.ADOPTED) adoption = verdict;
    if (verdict.outcome === OUTCOMES.ADOPTED || verdict.outcome === OUTCOMES.ALREADY_SERVED) {
      // Re-read STRICTLY: the adopted record must serve itself. An adoption
      // whose recorded project root is gone legitimately re-throws here, and the
      // gates' orphan ladder then takes over — that is the AC-C17 property, now
      // reached without a manual step.
      try {
        context = served();
      } catch (again) {
        again.adoption = adoption;
        throw again;
      }
    } else {
      const refused = new Error(
        `claude hook session binder: automatic adoption ${verdict.outcome} (${verdict.reason}); ${error.message}`,
      );
      refused.code = core.ADOPTION_REFUSED_CODE;
      refused.reason = verdict.reason;
      refused.adoption = verdict;
      throw refused;
    }
  }

  return {
    context,
    pluginRoot: executedPluginRoot,
    pluginData,
    projectRoot: context.project_root,
    contextFile: path.join(recordsDir, `${sessionKey}.json`),
    recordsDir,
    sessionKey,
    adoption,
  };
}

// The refusal TOKEN for the shell deny emitters: one word, never a TAB, so the
// `recorded<TAB>executing` pair the shell parsers read stays exactly two fields.
// Read-only — it previews, it never adopts. Answers null when the question
// cannot be answered at all, which the CLI mode renders as exit 1.
function adoptionRefusalToken(payload, environment = process.env) {
  validateSessionId(payload.session_id);
  const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  const declaredPluginRoot = canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT');
  if (declaredPluginRoot !== executedPluginRoot) fail('CLAUDE_PLUGIN_ROOT does not match the executing plugin');
  const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
  const recordsDir = privateRecordsDirectory(pluginData);
  // NO RECORD AT ALL is not an adoption question. Every reader throws on an absent
  // record file, so the probe would answer `record-unreadable`, and the default
  // deny would then tell a session that simply has no record — hooks loaded
  // mid-session, the pre-Session-Control upgrade state — that its record "may have
  // been altered". A clean ENOENT answers null, so the deny reads as it always did.
  // Any other lstat fault falls through: something IS there, and the probe names it.
  try {
    fs.lstatSync(path.join(recordsDir, `${core.sessionKey(payload.session_id)}.json`));
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
  }
  const autoAdopt = autoAdoptModule();
  const OUTCOMES = autoAdopt.AUTO_ADOPT_OUTCOMES;
  const REASONS = autoAdopt.AUTO_ADOPT_REASONS;
  const preview = autoAdopt.previewAdoption(
    adoptionRequest(payload, environment, executedPluginRoot, pluginData, recordsDir),
  );
  switch (preview.outcome) {
    case OUTCOMES.REFUSED:
      return preview.reason;
    case OUTCOMES.OPTED_OUT:
      return REASONS.OPTED_OUT;
    case OUTCOMES.ALREADY_SERVED: {
      // Served NOW: either a concurrent hook adopted it since the caller's bind
      // failed, or the caller's failure was never a lineage one. Only a strict
      // read can tell, and only the first is this token's business. The second
      // answers NULL, never `not-completed`: the record serves, so nothing about
      // an adoption is incomplete, and a deny that blamed the adoption for a bind
      // that failed on a vanished project root would send the reader to retry a
      // call no retry can fix.
      try {
        resolveHookSession(payload, environment);
        return REASONS.ADOPTED_CONCURRENTLY;
      } catch {
        return null;
      }
    }
    case OUTCOMES.ADOPTABLE:
      // Adoptable, yet the caller's own bind failed inside adoptContext: a lock
      // timeout, or a fault in the adoption itself — a retry. The OTHER cause that
      // used to be separated here, a superseded record already in place, is asked
      // by the shared preview now and arrives above as a REFUSED verdict, so the
      // hook deny, the manual report and the adoption agree about that state.
      return REASONS.NOT_COMPLETED;
    default:
      return null;
  }
}

// SessionStart hooks with the same matcher run concurrently. A fresh startup
// therefore cannot require the Session Control sibling to have created its
// record already. Prefer a valid record when one exists (including retries),
// reject any unsafe existing record, and otherwise use Claude's stable project
// environment. The mutable payload cwd is never a project authority.
function resolveFreshHookProject(payload, environment = process.env) {
  validateSessionId(payload.session_id);
  const executedPluginRoot = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  const declaredPluginRoot = canonicalDirectory(environment.CLAUDE_PLUGIN_ROOT, 'CLAUDE_PLUGIN_ROOT');
  if (declaredPluginRoot !== executedPluginRoot) fail('CLAUDE_PLUGIN_ROOT does not match the executing plugin');

  const pluginData = canonicalDirectory(environment.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
  const recordsDir = privateRecordsDirectory(pluginData, true);
  if (recordsDir) {
    const sessionKey = core.sessionKey(payload.session_id);
    const recordFile = path.join(recordsDir, `${sessionKey}.json`);
    let recordStat;
    try {
      recordStat = fs.lstatSync(recordFile);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (recordStat) {
      if (recordStat.isSymbolicLink() || !recordStat.isFile() || recordStat.nlink !== 1) {
        fail('private Session Control record is unsafe');
      }
      return resolveHookSession(payload, environment).projectRoot;
    }
  }

  return canonicalDirectory(environment.CLAUDE_PROJECT_DIR, 'CLAUDE_PROJECT_DIR');
}

function main() {
  let payload;
  if (process.argv[2] === 'unregistered') {
    // Exit 0 only for a session Session Control has never registered. Shell
    // gates use it to tell that one recoverable state apart from every other
    // bind failure, which must stay fail-closed.
    if (process.argv.length !== 3) fail('unregistered does not accept arguments');
    process.exitCode = unregisteredSession(readPayload()) ? 0 : 1;
    return;
  }
  if (process.argv[2] === 'orphaned-project-root' || process.argv[2] === 'model-orphaned-project-root') {
    // Exit 0 only when the sole disagreement is a project root that no longer
    // exists, and on a match print that dead path so the caller can name what
    // to re-create instead of calling the record merely "invalid". The two
    // spellings differ only in where the session id comes from: a hook payload
    // on stdin, or CLAUDE_CODE_SESSION_ID for the model-side /zensu:doctor.
    // Never any bindings — a session in this state must stay unbound.
    const mode = process.argv[2];
    if (process.argv.length !== 3) fail(`${mode} does not accept arguments`);
    let sessionPayload;
    if (mode === 'model-orphaned-project-root') {
      const hostSessionId = process.env.CLAUDE_CODE_SESSION_ID;
      validateSessionId(hostSessionId);
      sessionPayload = { session_id: hostSessionId };
    } else {
      sessionPayload = readPayload();
    }
    const orphanedRoot = resolveOrphanedProjectRoot(sessionPayload);
    if (orphanedRoot === null) {
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${orphanedRoot}\n`);
    return;
  }
  if (process.argv[2] === 'incompatible-runtime' || process.argv[2] === 'model-incompatible-runtime') {
    // Exit 0 when the record READS and the disagreement is that the executing
    // runtime declares an incompatible lineage — with or WITHOUT a vanished
    // project root, which is the third fact the mode below answers — and on a
    // match print `recorded<TAB>executing` so the caller can name both versions
    // instead of reporting an anonymous mismatch. The two spellings differ only
    // in where the session id comes from, exactly as the orphan pair does.
    // Never any bindings: this state stays unbound until it is adopted.
    const mode = process.argv[2];
    if (process.argv.length !== 3) fail(`${mode} does not accept arguments`);
    let sessionPayload;
    if (mode === 'model-incompatible-runtime') {
      const hostSessionId = process.env.CLAUDE_CODE_SESSION_ID;
      validateSessionId(hostSessionId);
      sessionPayload = { session_id: hostSessionId };
    } else {
      sessionPayload = readPayload();
    }
    const versions = resolveIncompatibleRuntime(sessionPayload);
    if (versions === null) {
      process.exitCode = 1;
      return;
    }
    // TWO fields, never three. Every shell parser reads the executing half as
    // `${V##*$'\t'}`, which takes the LAST field, so appending anything here
    // would silently redirect all of them rather than fail. (Find them with a grep
    // for that expansion under hooks/ — the four shell gates share ONE site,
    // zensu_emit_named_bind_deny, beside the Stop hook and the doctor wrapper.) The dead project root
    // that resolveIncompatibleRuntime now also reports travels on its own mode
    // below instead.
    process.stdout.write(`${versions.recorded}\t${versions.executing}\n`);
    return;
  }
  if (process.argv[2] === 'pruned-plugin-root' || process.argv[2] === 'model-pruned-plugin-root') {
    // Exit 0 only when the record is intact and the SOLE disagreement is that
    // the installation which minted it no longer exists, and on a match print
    // `recorded<TAB>executing` — the same two-field pair the lineage mode
    // prints, so every parser of that pair reads this one unchanged. The two
    // spellings differ only in where the session id comes from, exactly as the
    // other pairs do. Never any bindings: this state stays unbound until it is
    // adopted.
    const mode = process.argv[2];
    if (process.argv.length !== 3) fail(`${mode} does not accept arguments`);
    let sessionPayload;
    if (mode === 'model-pruned-plugin-root') {
      const hostSessionId = process.env.CLAUDE_CODE_SESSION_ID;
      validateSessionId(hostSessionId);
      sessionPayload = { session_id: hostSessionId };
    } else {
      sessionPayload = readPayload();
    }
    const versions = resolvePrunedPluginRoot(sessionPayload);
    if (versions === null) {
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`${versions.recorded}\t${versions.executing}\n`);
    return;
  }
  if (process.argv[2] === 'orphaned-incompatible-root' || process.argv[2] === 'model-orphaned-incompatible-root') {
    // The third fact of the combined state, asked separately so the two-field
    // wire format above can stay exactly as its shell parsers read it. Exit 0 and
    // print the dead project root only when the record is lineage-incompatible
    // AND its recorded project root is gone; exit **3** for a plain incompatible
    // lineage whose root still exists, and 1 only when the question could not be
    // answered at all. Three statuses, never two: see the split below.
    //
    // BOTH spellings exist, and the hook-payload one is not decoration. The Stop
    // hook is a real consumer: its incompatible-lineage release tells the user
    // the workflow document survives and that the next Stop enforces the chain
    // again, and both are FALSE once the recorded root is gone — the document
    // is not reachable from this record, and the adoption re-mints around the same absent anchor, so
    // every later Stop takes the orphan release instead. It has to be able to
    // tell the two apart. The two spellings differ only in where the session id
    // comes from, exactly as the orphan and lineage pairs above do.
    const mode = process.argv[2];
    if (process.argv.length !== 3) fail(`${mode} does not accept arguments`);
    let sessionPayload;
    if (mode === 'model-orphaned-incompatible-root') {
      const hostSessionId = process.env.CLAUDE_CODE_SESSION_ID;
      validateSessionId(hostSessionId);
      sessionPayload = { session_id: hostSessionId };
    } else {
      sessionPayload = readPayload();
    }
    const state = resolveIncompatibleRuntime(sessionPayload);
    if (state === null) {
      // UNAVAILABLE, not a negative. The property that licenses this arm is
      // STRUCTURAL, not a census: NO `return null` in
      // `resolveIncompatibleRuntime` establishes that the recorded project root
      // still exists — not the plugin-root mismatch, the absent records
      // directory, the plugin_data mismatch, the `servesRecordedRuntime` arm
      // (a plain orphan whose lineage is compatible), the unidentifiable
      // executing version, nor the outer catch that swallows every fail()
      // including an unreadable record. Stated as the property rather than as a
      // count because a hand-maintained count is what goes stale: an earlier
      // wording said "five sites" while listing five of the six, and the omitted
      // one was the arm a future editor is most likely to reach for. So none
      // of them may claim the positive negative. Folding this into the arm below
      // is exactly what this channel exists to prevent, and it is the shape the
      // first attempt shipped: the Stop hook then reads 3, takes the deferral
      // message, and tells the user their workflow document survived on nothing
      // but a probe that failed.
      process.exitCode = 1;
      return;
    }
    if (state.orphanedProjectRoot === null) {
      // THREE, not 1, and the distinction is load-bearing for the Stop hook. A
      // caller that cannot tell "the recorded root is still there" from "the
      // probe could not answer" has to pick one of them, and picking the first
      // makes it assert the workflow document survives on nothing but an
      // inferred negative. `fail()` and every other error path exit 1, so 3 is a
      // POSITIVE answer — the record read, the lineage is incompatible, and the
      // recorded root is still on disk — and 1 is an unavailable one.
      process.exitCode = 3;
      return;
    }
    process.stdout.write(`${state.orphanedProjectRoot}\n`);
    return;
  }
  if (process.argv[2] === 'adoption-refusal') {
    if (process.argv.length !== 3) fail('adoption-refusal does not accept arguments');
    const token = adoptionRefusalToken(readPayload());
    if (token === null) fail('the adoption refusal could not be determined');
    process.stdout.write(`${token}\n`);
    return;
  }
  if (process.argv[2] === 'model-bind') {
    if (process.argv.length !== 3) fail('model-bind does not accept arguments');
    const hostSessionId = process.env.CLAUDE_CODE_SESSION_ID;
    validateSessionId(hostSessionId);
    payload = { session_id: hostSessionId };
  } else {
    if (process.argv.length !== 2) fail('unsupported command-line mode');
    payload = readPayload();
  }
  // Hook-payload binds adopt; model-bind never does. The doctor and the
  // zensu-log verbs bind through model-bind and must stay write-free — the
  // PreToolUse hooks that gated the Bash call carrying them have already adopted.
  // ONE operator line per adoption, because the gate suites admit a bounded number
  // of stderr lines per hook run. Debug channel: whether a hook's stderr reaches the
  // user on exit 0 is unverified, so the user-facing announcement travels elsewhere
  // (the SessionStart adapter, the capability gate, the doctor).
  //
  // State the ORDER, because it decides which of those actually speaks. After a
  // /reload-plugins the first bound contact of a turn is a UserPromptSubmit shell
  // hook, which binds through this very mode — so on the ordinary flow THIS
  // invocation adopts, and the capability gate's allow-path announcement is never
  // reached: by the time a tool call arrives the record already serves. That leaves
  // this line and /zensu:doctor as the only trace of such an adoption until a hook
  // consumes ZENSU_SESSION_ADOPTED. Every interpolated value goes through the same
  // screens the user-facing renderers apply.
  const binding = bindAndDisclose(payload, process.env, { autoAdopt: process.argv[2] !== 'model-bind' });

  const values = {
    ZENSU_CLAUDE_PLUGIN_ROOT: binding.pluginRoot,
    ZENSU_SESSION_KEY: binding.sessionKey,
    ZENSU_SESSION_CONTEXT: binding.contextFile,
    ZENSU_RUNTIME_DIGEST: binding.context.runtime_digest,
    ZENSU_PROJECT_ROOT: binding.projectRoot,
    // Sixth export, UNCONDITIONAL so the eval'd set keeps one shape: empty when
    // this invocation adopted nothing, `recorded -> executing` when it did.
    ZENSU_SESSION_ADOPTED: binding.adoption ? core.formatAdoptionPair(binding.adoption.recorded, binding.adoption.executing) : '',
  };
  for (const [name, value] of Object.entries(values)) {
    process.stdout.write(`export ${name}=${shellQuote(value)}\n`);
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    // An adoption this invocation PERFORMED whose strict re-read then failed was
    // already disclosed by bindAndDisclose, before the failure that follows it.
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  privateRecordsDirectory,
  // Exported so the ADOPTION path can apply the same rule every argv mode in this
  // file already applies. It was the one entry point that accepted a session id
  // straight from the environment without it, which made a DERIVED identifier — an
  // `scv1_<64hex>`, i.e. the name of a record file in the store — an accepted
  // identity there while the sibling modes refuse exactly that shape.
  validateSessionId,
  // For the in-process adopters (the review-evidence hook, the capability gate):
  // the same bind-and-disclose policy and operator line the CLI mode uses, so an
  // adoption performed outside the CLI is not silent.
  bindAndDisclose,
  writeAdoptionOperatorLine,
  performedAdoption,
  orphanedProjectRootSession,
  resolveFreshHookProject,
  resolveHookSession,
  resolveIncompatibleRuntime,
  resolveOrphanedProjectRoot,
  resolvePrunedPluginRoot,
  unregisteredSession,
};
