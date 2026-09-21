#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const core = require('./session-control-core-v1.js');
const hostPaths = require('./claude-path-v1.js');
const principals = require('./claude-principal-v1.js');
// Top-level here is fine: this adapter is a hook entry point nothing requires,
// so adapter -> auto-adopt -> sweep -> lease -> binder -> core is acyclic. The
// binder itself must require the same module lazily — see its header.
const defaultAutoAdopt = require('./session-auto-adopt-v1.js');
const autoAdopt = defaultAutoAdopt;
const defaultCore = core;

const MAX_PAYLOAD_BYTES = 1024 * 1024;
const MAX_SESSION_SOURCE_LENGTH = 64;
// The host's own SessionStart sources are startup, clear, fork, resume and
// compact. Only the fresh ones are named: `fork` mints a NEW host session id
// for a copied conversation, so it can only ever arrive without a record.
// Everything unnamed — the continuations, plus any source the host adds after
// this build — registers a fresh record when none exists and reuses the
// existing one otherwise, because refusing an unknown source leaves the whole
// session unbindable rather than merely ungated.
const FRESH_SESSION_SOURCES = new Set(['startup', 'clear', 'fork']);

function fail(message) {
  throw new Error(`claude session-control adapter: ${message}`);
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
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) fail('hook payload must be an object');
  if (!['SessionStart', 'SubagentStart'].includes(payload.hook_event_name)) fail('unsupported hook event');
  if (
    typeof payload.session_id !== 'string'
    || payload.session_id.trim() === ''
    || payload.session_id.length > 4096
    || /[\0\r\n]/.test(payload.session_id)
  ) {
    fail('session id is unavailable or unsafe');
  }
  if (/^(?:scv1_[a-f0-9]{64}|sha256:[a-f0-9]{64})$/.test(payload.session_id)) {
    fail('host session id must be raw, not a derived Session Control identifier');
  }
  if (payload.hook_event_name === 'SessionStart' && !isUsableSessionSource(payload.source)) {
    fail('SessionStart source is unavailable or unsupported');
  }
  return payload;
}

function isUsableSessionSource(source) {
  return typeof source === 'string'
    && source.trim() !== ''
    && source.length <= MAX_SESSION_SOURCE_LENGTH
    && !/[\0\r\n]/.test(source);
}

function canonicalDirectory(value, label, rejectAlias = false) {
  if (typeof value !== 'string' || value.trim() === '' || /[\0\r\n]/.test(value)) fail(`${label} is unsafe`);
  const normalizedValue = hostPaths.normalizeHostPathInput(value, label);
  if (rejectAlias) {
    let supplied;
    try {
      supplied = fs.lstatSync(path.resolve(normalizedValue));
    } catch {
      fail(`${label} does not exist`);
    }
    if (supplied.isSymbolicLink()) fail(`${label} must not be a symlink`);
  }
  let canonical;
  try {
    canonical = fs.realpathSync.native(normalizedValue);
  } catch {
    fail(`${label} does not exist`);
  }
  const stat = fs.lstatSync(canonical);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`${label} must be a real directory`);
  return canonical;
}

function ensurePrivatePath(baseInput, segments) {
  let current = canonicalDirectory(baseInput, 'private path base', true);
  for (const segment of segments) {
    current = path.join(current, segment);
    if (!fs.existsSync(current)) {
      try {
        fs.mkdirSync(current, { mode: 0o700 });
      } catch (error) {
        // Another cold start may have created the same private generation after
        // existsSync(). Validate that winner below instead of treating EEXIST
        // as a startup failure.
        if (error.code !== 'EEXIST') throw error;
      }
    }
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail('private control path is unsafe');
    if (process.platform !== 'win32') {
      fs.chmodSync(current, 0o700);
      if ((fs.lstatSync(current).mode & 0o077) !== 0) fail('private control path permissions are unsafe');
    }
  }
  return current;
}

function authoritativePluginRoot() {
  const root = canonicalDirectory(path.resolve(__dirname, '..', '..'), 'executed plugin root');
  for (const variable of ['CLAUDE_PLUGIN_ROOT', 'PLUGIN_ROOT', 'ZENSU_PLUGIN_ROOT']) {
    if (!process.env[variable]) continue;
    if (canonicalDirectory(process.env[variable], variable) !== root) {
      fail(`${variable} does not match the executed plugin installation`);
    }
  }
  return root;
}

// `systemMessage` is the host's user-facing common field. Its DELIVERY by a
// synchronous SessionStart or SubagentStart hook is documented but was not
// measured in this work — CLAUDE.md records it as unverified — so it rides
// beside `additionalContext` rather than instead of it, and only when a caller
// has something the USER, not just the model, must hear: an adoption this hook
// performed or observed.
function hookOutput(event, additionalContext, systemMessage = '') {
  const output = {
    hookSpecificOutput: {
      hookEventName: event,
      additionalContext,
    },
  };
  if (typeof systemMessage === 'string' && systemMessage !== '') output.systemMessage = systemMessage;
  return output;
}

function rejectSourceRevisionOverride() {
  for (const variable of ['ZENSU_SOURCE_REVISION', 'ZENSU_SOURCE_REVISION_AUTHORITY']) {
    if (process.env[variable] !== undefined) {
      fail(`${variable} is unsupported; session source provenance is content-addressed`);
    }
  }
}

// The PUSH half of the rebuild disclosure. `/zensu:doctor` renders the
// BASELINE_REBUILT history entry, but that is a PULL channel: it says nothing until
// somebody runs it, and the one person who needs to know did not ask. This notice
// travels on the SessionStart `additionalContext` the model already receives, so the
// very first reply after an automatic heal can say what was lost.
//
// It is model-facing, which is a real bound rather than a detail: nothing forces the
// model to relay it, so this SUPPLEMENTS the doctor row and never replaces it. It is
// deliberately not a Stop-hook block — after a rebuild the baseline reads "never
// active", so there is no armed chain left to enforce and a block would obstruct the
// common blameless case (a deleted and re-created worktree) to catch a rare one it
// cannot tell apart, the distinguishing state having been destroyed with the document.
const BASELINE_HEAL_NOTICE = 'Zensu: this session\'s workflow document was missing and was '
  + 'rebuilt automatically at SessionStart. Rebuilding is a loss, not a restore: the '
  + 'rebuilt baseline reads "never active", so a review chain that was live when the '
  + 'document vanished is gone and the Stop guard will release this session without '
  + 'asking for a reviewer. Tell the user this in your next reply, and offer /zensu:tdd '
  + 'to re-arm if that work still needs a review. /zensu:doctor reports the same finding.';

// The PUSH half of the adoption disclosure, on both channels the host offers a
// SessionStart: `additionalContext` for the model and `systemMessage` for the
// user. The text comes from session-auto-adopt-v1.js's renderAdoptionNotice — the
// renderer the `.*` gate's allow-path announcement uses too — so this file holds
// no version screen, no provenance screen and no lease clause of its own. (The
// binder's stderr line is a third surface with its own lead-in; it shares the
// SCREENS, not the renderer.)
function adoptionNotice(adoption, label) {
  return autoAdopt.renderAdoptionNotice(adoption, { where: `at this ${label}` });
}

// Serve the existing record, or ADOPT it when the executing installation cannot
// serve it by version number but adoptableRecord admits it — the same ladder the
// PreToolUse binder runs, so a compaction or a subagent spawn after a plugin
// update binds instead of dying. A refusal keeps failing the hook, naming why.
//
// An `already-served` verdict reached AFTER the strict serve failed means a
// sibling hook on the same event adopted the record in the window between the
// two reads. Two siblings bind on these events: the Autopilot resume hook, through
// the CLI binder with its output discarded, and the review-evidence hook, IN
// PROCESS through resolveHookSession — neither has a user channel of its own, so
// that adoption is announced here. The bound is stated rather than implied: this
// notice exists only when THIS process read the old record first. A sibling that
// finished before the first serve below leaves a record that simply serves, the
// first serve succeeds, and nothing here knows an adoption happened — so ordering
// still decides whether the user hears about it from this hook, and /zensu:doctor's
// adoption row is the surface that does not depend on it.
//
// `deps` is the unit seam: the substitution of the observed version is unreachable
// from the upgrade suite, whose held lock makes every racer probe the old record.
function serveOrAdopt(readerOptions, pluginRoot, pluginData, sessionId, label, noun, deps) {
  const core = (deps && deps.core) || defaultCore;
  const autoAdopt = (deps && deps.autoAdopt) || defaultAutoAdopt;
  const OUTCOMES = autoAdopt.AUTO_ADOPT_OUTCOMES;
  // The version this process READ before anyone adopted, kept for the sibling
  // case below. It is the only honest source for "updated FROM": once a sibling
  // has re-minted the record, its plugin_version is the executing version.
  let observedRecorded = null;
  const serve = () => {
    const context = core.readContext(readerOptions);
    if (!core.servesRecordedRuntime(context, pluginRoot, 'claude')) {
      if (typeof context.plugin_version === 'string') observedRecorded = context.plugin_version;
      fail(`${label} plugin root is neither the ${noun}'s plugin nor a compatible upgrade of it`);
    }
    if (context.plugin_data !== pluginData) fail(`${label} plugin data does not match the ${noun}`);
    return context;
  };
  try {
    return { context: serve(), adoption: null };
  } catch (error) {
    // The observed version travels ON THE REQUEST: an `already-served` verdict has
    // no `recorded` of its own, and the module is the one place that may put the
    // caller's observation on the verdict. This process used to patch the returned
    // verdict instead.
    const verdict = autoAdopt.adoptForHook({
      executingPluginRoot: pluginRoot,
      pluginData,
      recordsDir: readerOptions.recordsDir,
      sessionId,
      host: 'claude',
      environment: process.env,
      respectOptOut: true,
      observedRecorded,
    });
    if (verdict.outcome === OUTCOMES.ADOPTED || verdict.outcome === OUTCOMES.ALREADY_SERVED) {
      // Strict re-read: the adopted record must serve itself. A vanished
      // recorded project root re-throws here exactly as it always did — and
      // when THIS process adopted, the failure names that adoption, so the
      // re-mint is not lost behind the message of a bind it could not repair.
      // The lease clause travels with it: this message is the ONLY report of that
      // adoption's sweep, because the hook fails and no notice is ever rendered.
      try {
        return { context: serve(), adoption: verdict };
      } catch (again) {
        if (verdict.outcome === OUTCOMES.ADOPTED) {
          fail(`${label}: ${autoAdopt.operatorLine(verdict)} — but the strict re-read still fails: ${again.message}`);
        }
        throw again;
      }
    }
    fail(`${label}: automatic adoption ${verdict.outcome} (${verdict.reason}); ${error.message}`);
  }
  return null;
}

function main() {
  const payload = readPayload();
  // SessionStart also carries agent_type for top-level `claude --agent`
  // sessions. Use the same trusted-payload classifier as PreToolUse so only a
  // host session with neither agent field receives main-v1. Exact reviewers
  // stay read-only and every other explicit or partial identity stays neutral.
  const principal = payload.hook_event_name === 'SubagentStart'
    ? principals.classifySubagent(payload.agent_type, payload.agent_id)
    : principals.classifyPreToolPayload(payload);
  const pluginRoot = authoritativePluginRoot();
  rejectSourceRevisionOverride();
  const pluginData = canonicalDirectory(process.env.CLAUDE_PLUGIN_DATA, 'CLAUDE_PLUGIN_DATA', true);
  const controlRoot = ensurePrivatePath(pluginData, ['session-control', 'v1']);
  const recordsDir = ensurePrivatePath(controlRoot, ['records']);
  ensurePrivatePath(controlRoot, ['locks']);

  let context;
  let baselineHealNotice = '';
  let adoption = null;
  if (payload.hook_event_name === 'SessionStart') {
    const key = core.sessionKey(payload.session_id);
    const recordFile = path.join(recordsDir, `${key}.json`);
    const eventCwd = canonicalDirectory(payload.cwd, 'SessionStart cwd');
    const isFresh = FRESH_SESSION_SOURCES.has(payload.source);
    if (fs.existsSync(recordFile)) {
      // Resume/compact occurs after CwdChanged and may report a descendant or
      // external detached-worktree cwd. Reuse the immutable record anchor;
      // cwd is host location metadata and must never become a rebind request.
      // Only a known-fresh source must still land in the recorded project: an
      // unknown one may well be a continuation the host added after this build.
      // A resume or compact is where a mid-session plugin upgrade surfaces
      // again: the record still names the root it was minted against, while
      // this hook now executes from the new one. A compatible lineage serves the
      // record as before; an incompatible one is ADOPTED here — re-minted under
      // the executing installation with provenance — instead of failing the hook,
      // which used to kill the very session one compaction after it had survived
      // every tool call. A refused adoption still fails, naming why.
      const served = serveOrAdopt(
        { recordsDir, sessionId: payload.session_id, expectedHost: 'claude' },
        pluginRoot,
        pluginData,
        payload.session_id,
        'SessionStart', 'existing session',
      );
      context = served.context;
      adoption = served.adoption;
      if (isFresh && eventCwd !== context.project_root) {
        fail('fresh SessionStart cwd does not match the existing session project');
      }
      // The record exists and this runtime serves it, so the ONE thing that can
      // still be gone is the workflow document the record anchors. A bare
      // readWorkflowState failed the hook there, which repaired nothing and left
      // the session wedged: the capability gate denies every tool while the
      // document is absent, and no later SessionStart could help either, because
      // this same branch would fail again.
      //
      // The argument for healing it is the one the sibling *no record* branch
      // already makes below in its own words — refusing creates no document, and
      // no document fails every stateful hook closed for the rest of the session.
      // It grants nothing a fresh session would not have: a baseline reading
      // "never active", which is all a rebuilt one can say.
      //
      // ENOENT ONLY. `unsafe` (a symlink, a hard link, a non-file, an oversized
      // file) and `unreadable` (present, does not validate) still fail here:
      // something IS at that path, and rebuilding over it would destroy the
      // evidence. classifyWorkflowBaseline performs the PRESENT read itself, so
      // this replaces the previous readWorkflowState rather than adding a second.
      const baselineFile = core.adoptionWorkflowStatePath(context.project_root, payload.session_id);
      const baselineState = core.classifyWorkflowBaseline(
        baselineFile,
        context.project_root,
        payload.session_id,
      );
      if (baselineState === core.BASELINE_STATES.MISSING) {
        try {
          // Records its own BASELINE_REBUILT history entry, so an automatic heal is
          // never silent — the same provenance the confirmed repair leaves. The
          // RESULT is read rather than discarded: repairWorkflowBaseline catches a
          // failed mutateWorkflowState internally and returns
          // `provenance: "unavailable: ..."` instead of throwing, so an
          // unrecorded rebuild would otherwise leave no trace on the ONE path that
          // runs without the user asking for it. The confirmed path already
          // surfaces this; this one said nothing.
          const healed = core.repairWorkflowBaseline({
            recordsDir,
            sessionId: payload.session_id,
            pluginData,
            executingPluginRoot: pluginRoot,
            host: 'claude',
          });
          // Set on BOTH outcomes. The rebuild is real whether or not its provenance
          // entry landed, and the branch below reports the missing entry, never the
          // missing rebuild — hanging the notice off `provenance` would withhold it
          // in exactly the case with the least surviving evidence.
          baselineHealNotice = BASELINE_HEAL_NOTICE;
          if (healed && healed.provenance !== 'recorded') {
            process.stderr.write(
              'zensu SessionStart: the workflow document was rebuilt but its '
              + 'BASELINE_REBUILT provenance entry could not be written ('
              + String(healed.provenance) + '). The rebuild is real and '
              + 'unrecorded in the workflow history; report this rather than '
              + 'repeating it.\n',
            );
          }
        } catch (error) {
          // repairWorkflowBaseline re-evaluates the verdict and refuses anything
          // that is no longer `missing`. Between the classify above and its own
          // read, a concurrent writer can legitimately have created the document —
          // and this adapter has NO local catch, so that benign race exited the
          // whole SessionStart hook non-zero and left the session with no baseline
          // for the rest of its life: the exact class of wedge this branch exists
          // to remove.
          //
          // The CODE decides, not a second classification and not the message.
          // Re-classifying here worked but put the decision in the host adapter,
          // where the sibling caller made the opposite one; the core now types the
          // two cases apart so both hosts branch on one judgement.
          // The PREDICATE, never the raw constant: `undefined === undefined` reads
          // as a match, so a tree where the export is missing would report every
          // refusal — tamper included — as the benign race.
          if (typeof core.isBaselineAlreadyPresent === 'function'
            && core.isBaselineAlreadyPresent(error)) {
            // Someone else healed it. That is the outcome this branch wanted.
          } else {
            throw error;
          }
        }
      } else if (baselineState !== core.BASELINE_STATES.PRESENT) {
        fail(`SessionStart workflow document is ${baselineState}: ${baselineFile}`);
      }
    } else {
      // No record for this session id, whatever the source claims: a fork, a
      // resume whose private record was pruned, or a continuation across a
      // plugin upgrade. Register it exactly like a cold start instead of
      // failing — refusing here creates no record, and no record fails every
      // stateful hook closed for the rest of the session. It grants nothing a
      // plain `startup` would not: a fresh anchor and a baseline workflow
      // document. Inherited chain state is deliberately NOT reconstructed —
      // the host payload carries no parent session id.
      context = core.registerContext({
        recordsDir,
        host: 'claude',
        sessionId: payload.session_id,
        projectRoot: eventCwd,
        pluginRoot,
        pluginData,
      });
      core.initializeWorkflowState({
        projectRoot: context.project_root,
        sessionId: payload.session_id,
      });
    }
  } else {
    // Same reasoning as the SessionStart branch above, and just as load-bearing:
    // the review chain fans out subagents, so a strict comparison here would let
    // an upgraded session keep working right up to the moment it tries to
    // review itself. The child adopts too: the payload carries the PARENT's
    // session id, the record is per session, and the records lock serializes
    // this hook against the evidence hook on the same matcher — the loser sees
    // already-served and re-reads. Refusing instead would wedge the review
    // chain at its first fan-out after a reload.
    const served = serveOrAdopt(
      { recordsDir, sessionId: payload.session_id, expectedHost: 'claude' },
      pluginRoot,
      pluginData,
      payload.session_id,
      'SubagentStart', 'parent session',
    );
    context = served.context;
    adoption = served.adoption;
    if (payload.cwd) {
      // CwdChanged may move an otherwise bound session into an external
      // detached worktree. The host payload is trusted location metadata, not
      // a session authenticator; session_id plus the private record remain the
      // immutable binding.
      canonicalDirectory(payload.cwd, 'SubagentStart cwd');
    }
  }

  const additionalContext = principal === principals.PRINCIPALS.REVIEWER
    ? core.renderReviewerContext(context)
    : principal === principals.PRINCIPALS.EVIDENCE_WORKER
      ? core.renderEvidenceWorkerContext(context)
    : principal === principals.PRINCIPALS.MAIN
      ? core.renderMainContext(context)
      : core.renderHostContext(context);
  // Appended rather than substituted: the principal's own context is what binds the
  // session, and a notice that replaced it would trade a disclosure for the binding.
  // The adoption notice ALSO travels as the user-facing systemMessage: an adoption
  // is a fact about the user's session, not only about the model's context. The
  // MODEL-facing copy is appended for the main thread only — it names the
  // superseded record, whose basename is the session selector every confined
  // principal's rendered context deliberately withholds, and it names
  // /zensu:doctor, a main-only command. A reviewer, an evidence worker or a
  // neutral child gets its bound context unchanged; the user still gets the line.
  const adoptionText = adoption ? adoptionNotice(adoption, payload.hook_event_name) : '';
  const modelNotice = principal === principals.PRINCIPALS.MAIN ? adoptionText : '';
  const notices = [baselineHealNotice, modelNotice].filter((text) => text !== '');
  const emittedContext = notices.length === 0
    ? additionalContext
    : `${additionalContext}\n\n${notices.join('\n\n')}`;
  process.stdout.write(`${JSON.stringify(hookOutput(payload.hook_event_name, emittedContext, adoptionText))}\n`);
}

// Exports ABOVE the entry guard, so a module that requires this file never sees an
// empty export object. `serveOrAdopt` is exported for its unit seam alone; the hook
// wrapper launches this file as the entry module, where the guard below runs main.
module.exports = { serveOrAdopt };

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
