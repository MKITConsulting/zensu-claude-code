#!/usr/bin/env node
// zensu-doctor-report.js — read-only diagnostics renderer for /zensu:doctor.
// Reads the plugin's own manifest/hooks, the effective config files, Claude
// Code's own settings files (for the reviewer-spawn exposure row only), and the
// session dir, then prints a four-block status table using ✅/⚠️/❌
// glyphs. NEVER writes, NEVER throws out (every failure degrades to a ⚠️ row),
// ALWAYS exits 0 — the skill decides what to do about warnings.
//
// Tool facts (zensu CLI, node, the code-forge CLI, Playwright) and the pending-
// review TTL are resolved by the bash wrapper (command -v + the VCS-driver forge
// detection are shell concerns; the TTL comes from the canonical
// zensu_pending_review_ttl_hours getter so the doctor and the real Stop enforcer
// agree) and handed in via ZDOC_* env, so this file stays a pure file/JSON
// reader that a structure test can drive with fixtures.
//
// Inputs (all overridable so the structure test can point at a sandbox):
//   ZENSU_DOCTOR_PLUGIN_DIR  plugin root holding .claude-plugin/ + hooks/
//   ZENSU_CONFIG             full-override config file (else HOME + project)
//   ZENSU_DOCTOR_CLAUDE_SETTINGS  full-override Claude Code settings file
//                            (else HOME + project settings.json/settings.local.json)
//   HOME, CLAUDE_PROJECT_DIR standard config-resolution roots; session state
//                            is always CLAUDE_PROJECT_DIR/.zensu/state
//   ZDOC_NODE/ZENSU/PLAYWRIGHT            tool probe results from the wrapper/skill
//   ZDOC_FORGE_PROVIDER/CLI/STATE/EDITION forge detection from the VCS driver
//   ZDOC_TTL_HOURS           pending-review TTL from the canonical getter
//   ZDOC_NOW_MS              clock override for deterministic tests

'use strict';
var fs = require('fs');
var path = require('path');

var OK = '✅';
var WARN = '⚠️';
var BAD = '❌';

// Mirror of hooks/lib/zensu-config.sh zensu_pending_review_ttl_hours: the wrapper
// passes the canonical value via ZDOC_TTL_HOURS; these apply only to a direct
// (test/no-wrapper) invocation and must stay in lockstep with that getter.
var TTL_HOURS_FALLBACK = 6;
var TTL_HOURS_MAX = 8760;
var CHAIN_ROW_LIMIT = 8;
// Hardcoded copy of the review-chain agent name. The same literal is a semantic
// key in hooks/lib/claude-principal-v1.js (REVIEWER_TYPES) and in
// hooks/post-review-tdd-delegate.sh; renaming the agent must update all three.
// Unlike those two, THIS copy fails silently — the row simply stops firing.
var REVIEWER_AGENT = 'zensu:code-reviewer';
var MAX_JSON_BYTES = 1048576;

var env = process.env;
var out = [];
var warnCount = 0;
var badCount = 0;

function line(glyph, text) {
  if (glyph === WARN) warnCount++;
  else if (glyph === BAD) badCount++;
  out.push('  ' + glyph + '  ' + text);
}
function block(title) {
  out.push('');
  out.push(title);
}
function readGuardedJson(p) {
  // One descriptor for the check AND the read, so the file inspected is the file
  // parsed. O_NONBLOCK where the host has it: a FIFO left at this path would
  // otherwise block the open itself, and a hung renderer is the one failure the
  // "always exits 0" contract cannot absorb.
  var flags = fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK || 0);
  var fd = fs.openSync(p, flags);
  try {
    var st = fs.fstatSync(fd);
    if (!st.isFile()) return { ok: false, missing: false, err: 'not a regular file' };
    if (st.size > MAX_JSON_BYTES) return { ok: false, missing: false, err: 'larger than ' + MAX_JSON_BYTES + ' bytes' };
    return { ok: true, data: JSON.parse(fs.readFileSync(fd, 'utf8')) };
  } finally {
    // readFileSync does NOT close a descriptor it was handed, so this close is
    // the only one — do not remove it. The catch is defensive, not expected.
    try { fs.closeSync(fd); } catch (_) { /* nothing further to do */ }
  }
}
function readJson(p, guarded) {
  try {
    if (guarded) return readGuardedJson(p);
    return { ok: true, data: JSON.parse(fs.readFileSync(p, 'utf8')) };
  } catch (e) {
    if (e && e.code === 'ENOENT') return { ok: false, missing: true };
    return { ok: false, missing: false, err: readJsonReason(e) };
  }
}
function readJsonReason(e) {
  if (e && e.code) return 'unreadable (' + String(e.code) + ')';
  if (e instanceof SyntaxError) return 'invalid JSON';
  return 'unreadable';
}
function pluginDir() {
  if (env.ZENSU_DOCTOR_PLUGIN_DIR) return env.ZENSU_DOCTOR_PLUGIN_DIR;
  return path.resolve(__dirname, '..', '..');
}
function configFiles() {
  if (env.ZENSU_CONFIG) return [env.ZENSU_CONFIG];
  var files = [];
  if (env.HOME) files.push(path.join(env.HOME, '.zensu', 'config.json'));
  if (env.CLAUDE_PROJECT_DIR) files.push(path.join(env.CLAUDE_PROJECT_DIR, '.zensu', 'config.json'));
  return files;
}
function claudeSettingsFiles() {
  if (env.ZENSU_DOCTOR_CLAUDE_SETTINGS) return [env.ZENSU_DOCTOR_CLAUDE_SETTINGS];
  var files = [];
  if (env.HOME) files.push(path.join(env.HOME, '.claude', 'settings.json'));
  if (env.CLAUDE_PROJECT_DIR) {
    files.push(path.join(env.CLAUDE_PROJECT_DIR, '.claude', 'settings.json'));
    files.push(path.join(env.CLAUDE_PROJECT_DIR, '.claude', 'settings.local.json'));
  }
  return files;
}

function toolBlock() {
  block('CLI & tooling');
  var z = env.ZDOC_ZENSU || 'absent';
  if (z === 'authed') line(OK, 'zensu CLI: installed and authenticated');
  else if (z === 'present') line(WARN, 'zensu CLI: installed but not authenticated — run `zensu auth login`');
  else line(WARN, 'zensu CLI: not found on PATH — feature tracking commands will be unavailable');

  var n = env.ZDOC_NODE || '';
  if (n) line(OK, 'node: ' + n);
  else line(BAD, 'node: not found on PATH — the plugin hooks require node');

  // Forge CLI (code host): the bash wrapper detects the repo's provider through
  // the VCS driver and hands us ZDOC_FORGE_* — so we name the RIGHT CLI (gh for
  // GitHub, glab for GitLab) and its auth state, instead of hard-probing gh and
  // falsely telling a GitLab checkout that "gh is missing".
  var fp = env.ZDOC_FORGE_PROVIDER || 'unknown';
  var fc = env.ZDOC_FORGE_CLI || '';
  var fst = env.ZDOC_FORGE_STATE || 'missing';
  var fed = env.ZDOC_FORGE_EDITION || '';
  var pname = fp === 'github' ? 'GitHub' : (fp === 'gitlab' ? 'GitLab' : '');
  var plabel = pname + (fed && fed !== 'cloud' ? ' (' + fed + ')' : '');
  if (fp === 'unknown' || !fc || !pname) {
    line(WARN, 'forge CLI: no GitHub/GitLab remote detected — needs a repo with a GitHub (gh) or GitLab (glab) remote (or ZENSU_VCS_PROVIDER set for a self-hosted host)');
  } else if (fst === 'ready') {
    line(OK, plabel + ' CLI (' + fc + '): installed and authenticated');
  } else if (fst === 'unauthed') {
    line(WARN, plabel + ' CLI (' + fc + '): installed but not authenticated — run `' + fc + ' auth login` (needed to open/review PRs)');
  } else {
    line(WARN, plabel + ' CLI (' + fc + '): not found on PATH — PR create/review for ' + pname + ' will be unavailable');
  }

  var p = env.ZDOC_PLAYWRIGHT || 'absent';
  if (p === 'ready') line(OK, 'Playwright MCP: loaded and ready (/zensu:verify-feature and autopilot browser driver)');
  else if (p === 'configured') line(WARN, 'Playwright MCP: valid integrity-locked plugin config + npm present; first use installs the locked runtime, then restart/confirm MCP tools');
  else if (p === 'declared') line(WARN, 'Playwright MCP: valid integrity-locked plugin config but npm is missing from PATH');
  else if (p === 'present') line(WARN, 'Playwright: PATH binary found, but /zensu:verify-feature requires loaded Playwright MCP tools');
  else line(WARN, 'Playwright MCP: valid plugin config not detected — /zensu:verify-feature cannot drive the UI and autopilot browser validation may skip');
}

function pluginBlock() {
  block('Plugin integrity');
  var dir = pluginDir();
  var pj = readJson(path.join(dir, '.claude-plugin', 'plugin.json'));
  var mj = readJson(path.join(dir, '.claude-plugin', 'marketplace.json'));

  if (!pj.ok) {
    line(BAD, 'plugin.json: ' + (pj.missing ? 'missing' : pj.err));
  } else if (!mj.ok) {
    line(WARN, 'marketplace.json: ' + (mj.missing ? 'missing' : mj.err));
  } else {
    var name = pj.data && pj.data.name;
    var pv = pj.data && pj.data.version;
    var entry = null;
    var plugins = (mj.data && mj.data.plugins) || [];
    for (var i = 0; i < plugins.length; i++) {
      if (plugins[i] && plugins[i].name === name) { entry = plugins[i]; break; }
    }
    if (!entry) {
      line(WARN, 'version sync: plugin "' + name + '" not listed in marketplace.json');
    } else if (String(pv) !== String(entry.version)) {
      line(BAD, 'version sync: plugin.json ' + pv + ' != marketplace.json ' + entry.version + ' — bump both together');
    } else {
      line(OK, 'version sync: plugin.json and marketplace.json agree (' + pv + ')');
    }
  }

  var hj = readJson(path.join(dir, 'hooks', 'hooks.json'));
  if (!hj.ok) {
    line(BAD, 'hooks.json: ' + (hj.missing ? 'missing' : hj.err));
    return;
  }
  var wired = {};
  var events = (hj.data && hj.data.hooks) || {};
  Object.keys(events).forEach(function (ev) {
    var matchers = events[ev] || [];
    matchers.forEach(function (m) {
      (m && m.hooks || []).forEach(function (h) {
        var cmd = (h && typeof h.command === 'string') ? h.command : '';
        var mm = cmd.match(/\/hooks\/([A-Za-z0-9._-]+\.sh)/);
        if (mm) wired[mm[1]] = true;
      });
    });
  });
  var onDisk = {};
  try {
    fs.readdirSync(path.join(dir, 'hooks')).forEach(function (f) {
      if (/\.sh$/.test(f)) onDisk[f] = true;
    });
  } catch (e) { /* no hooks dir */ }

  var missing = Object.keys(wired).filter(function (f) { return !onDisk[f]; }).sort();
  var unwired = Object.keys(onDisk).filter(function (f) { return !wired[f]; }).sort();
  if (missing.length) {
    line(BAD, 'hooks wiring: ' + missing.length + ' referenced but missing on disk — ' + missing.join(', '));
  }
  if (unwired.length) {
    line(WARN, 'hooks wiring: ' + unwired.length + ' script(s) on disk not referenced in hooks.json — ' + unwired.join(', '));
  }
  if (!missing.length && !unwired.length) {
    line(OK, 'hooks wiring: all ' + Object.keys(wired).length + ' hooks referenced in hooks.json exist on disk');
  }
}

function walkQuotedBooleans(obj, prefix, hits) {
  if (obj === null || typeof obj !== 'object') return;
  Object.keys(obj).forEach(function (k) {
    if (k === '__proto__' || k === 'constructor' || k === 'prototype') return;
    var v = obj[k];
    var dotted = prefix ? prefix + '.' + k : k;
    if (typeof v === 'string' && (v === 'true' || v === 'false')) {
      hits.push(renderableKeyPath(dotted) + ' = "' + v + '"');
    } else if (v && typeof v === 'object' && !Array.isArray(v)) {
      walkQuotedBooleans(v, dotted, hits);
    }
  });
}
function autoModeDeclared(data) {
  var perms = data && data.permissions;
  return !!(perms && perms.defaultMode === 'auto');
}
function agentRuleNames(rule) {
  var open = rule.indexOf('(');
  if (open === -1) return rule === 'Agent' ? ['*'] : null;
  if (rule.slice(0, open).trim() !== 'Agent') return null;
  var close = rule.lastIndexOf(')');
  if (close < open) return null;
  return rule.slice(open + 1, close).split(',').map(function (n) { return n.trim(); });
}
function reviewerRuleHit(list) {
  return reviewerRuleMatch(list) !== '';
}
function autoModeMentionsReviewer(data) {
  var autoAllow = data && data.autoMode && data.autoMode.allow;
  if (!Array.isArray(autoAllow)) return false;
  for (var i = 0; i < autoAllow.length; i++) {
    if (typeof autoAllow[i] === 'string' && autoAllow[i].indexOf(REVIEWER_AGENT) !== -1) return true;
  }
  return false;
}
function reviewerRuleMatch(list) {
  if (!Array.isArray(list)) return '';
  for (var i = 0; i < list.length; i++) {
    if (typeof list[i] !== 'string') continue;
    var rule = list[i].trim();
    var names = agentRuleNames(rule);
    if (!names) continue;
    if (names.indexOf('*') !== -1 || names.indexOf(REVIEWER_AGENT) !== -1) return rule;
  }
  return '';
}
// The rule text comes from a settings file a clone can carry, and the doctor
// skill prints this table verbatim into the terminal and the model's context.
// Same drop-don't-print judgment zensu-doctor.sh already makes for the version
// pair: a rule that is not a plain one-line Agent(...) spelling is described,
// never echoed.
var SAFE_RULE_RE = /^Agent\([A-Za-z0-9:_*, .@\/-]{0,120}\)$/;
var SAFE_KEY_PATH_RE = /^[A-Za-z0-9_.$-]{1,120}$/;
function renderableRule(rule) {
  return SAFE_RULE_RE.test(rule) ? '"' + rule + '"' : 'an unprintable rule';
}
// Config keys come from the same clone-carried file class as a permission rule
// and land in the same verbatim-printed table; a key holding a newline would
// forge a row exactly as a rule could.
function renderableKeyPath(dotted) {
  return SAFE_KEY_PATH_RE.test(dotted) ? dotted : 'an unprintable key path';
}
function reviewerSpawnRow() {
  var autoDeclaredIn = '';
  var allowedIn = '';
  var mentionedIn = '';
  var unreadable = 0;
  var refusals = [];
  claudeSettingsFiles().forEach(function (f) {
    var r = readJson(f, true);
    if (r.missing) return;
    if (!r.ok) {
      unreadable++;
      line(WARN, 'reviewer spawn: Claude Code settings at ' + f + ' could not be read by Zensu — ' + r.err + '. Zensu therefore cannot tell whether that file declares a permission mode or a reviewer-spawn rule, so any row below (or its absence) does not account for it.');
      return;
    }
    var perms = r.data && r.data.permissions;
    if (!autoDeclaredIn && autoModeDeclared(r.data)) autoDeclaredIn = f;
    if (!allowedIn && perms && reviewerRuleHit(perms.allow)) allowedIn = f;
    if (perms) {
      var d = reviewerRuleMatch(perms.deny);
      if (d) refusals.push({ file: f, list: 'deny', rule: d });
      var a = reviewerRuleMatch(perms.ask);
      if (a) refusals.push({ file: f, list: 'ask', rule: a });
    }
    if (!mentionedIn && autoModeMentionsReviewer(r.data)) mentionedIn = f;
  });
  var refused = null;
  for (var i = 0; i < refusals.length; i++) {
    if (refusals[i].list === 'deny') { refused = refusals[i]; break; }
  }
  if (!refused && refusals.length) refused = refusals[0];
  var limits = ' This row is an exposure report, never a prediction: the classifier decides per session context rather than per agent type; Zensu reads ' + claudeSettingsFiles().length + ' settings file(s) as a union with no precedence applied; and managed settings plus a --permission-mode command-line override are invisible here' + (unreadable ? ', as is every unreadable file named above' : '') + ' — so the absence of a row proves nothing either.';
  var pendingAuto = autoDeclaredIn && !allowedIn;
  if (refused) {
    var effect = refused.list === 'deny'
      ? 'A deny rule outranks every allow rule, so the review chain cannot be closed from inside a session while it stands, and adding an allow entry will not help — remove or narrow that rule instead.'
      : 'An ask rule forces a confirmation prompt for that spawn, so an unattended or non-interactive run cannot complete the review chain. Remove or narrow that rule if the chain must run unattended.';
    line(WARN, 'reviewer spawn: ' + refused.file + ' carries the permissions.' + refused.list + ' rule ' + renderableRule(refused.rule) + ', which matches the ' + REVIEWER_AGENT + ' spawn. ' + effect
      + (refusals.length > 1 ? ' ' + (refusals.length - 1) + ' further matching rule(s) were found across the settings files; clearing this one may not be enough.' : '')
      + (pendingAuto ? ' A separate exposure also stands: ' + autoDeclaredIn + ' declares permissions.defaultMode "auto" with no allowance for that spawn, so clearing this rule alone will not silence the auto-mode row.' : '')
      + limits);
    return;
  }
  if (!pendingAuto) return;
  line(WARN, 'auto mode: ' + autoDeclaredIn + ' sets permissions.defaultMode "auto" and no settings file allows the ' + REVIEWER_AGENT + ' spawn — the auto-mode classifier can refuse it, and the review chain then cannot be closed from inside the session. Remedy: add "Agent(' + REVIEWER_AGENT + ')" to permissions.allow.' + (mentionedIn ? ' Note: ' + mentionedIn + ' has an autoMode.allow entry naming that agent, but such an entry is prose addressed to the classifier, not a permission rule, and Zensu cannot tell a permissive one from a restrictive one — read it yourself; it does not substitute for the permissions.allow entry.' : '') + limits);
}
function configBlock() {
  block('Config');
  var anyPresent = false;
  configFiles().forEach(function (f) {
    var r = readJson(f);
    if (r.missing) return;
    anyPresent = true;
    if (!r.ok) {
      line(BAD, 'config: ' + r.err + ' in ' + f + ' (the whole file is ignored, defaults apply)');
      return;
    }
    var hits = [];
    walkQuotedBooleans(r.data, '', hits);
    if (hits.length) {
      line(WARN, 'config: quoted boolean(s) in ' + f + ' are ignored by strict `===` checks — ' + hits.join('; ') + ' (drop the quotes)');
    } else {
      line(OK, 'config: valid JSON, no quoted-boolean traps in ' + f);
    }
  });
  if (!anyPresent) {
    line(OK, 'config: no config file present — built-in defaults apply');
  }
  reviewerSpawnRow();
}

function ttlHours() {
  var n = Number(env.ZDOC_TTL_HOURS);
  if (Number.isInteger(n) && n >= 0 && n <= TTL_HOURS_MAX) return n;
  return TTL_HOURS_FALLBACK;
}
function chainRows(entries) {
  if (!entries.length) return;
  var chain;
  try {
    chain = require(path.join(pluginDir(), 'hooks', 'lib', 'chain-recovery-v1.js'));
  } catch (e) {
    line(WARN, 'chain: chain-recovery-v1.js is unreadable — chain shapes cannot be classified');
    return;
  }
  var shapes = [];
  var unclassifiable = 0;
  var recoverable = [];
  var blocked = [];
  var deadEnds = [];
  entries.forEach(function (entry) {
    var report;
    try {
      report = chain.classifyChain(entry.state);
    } catch (e) {
      shapes.push(entry.session + ': unclassifiable');
      unclassifiable++;
      return;
    }
    shapes.push(entry.session + ': ' + report.shape
      + (report.recoveries ? ' (repaired ' + report.recoveries + '×)' : ''));
    if (report.deadEnd) {
      deadEnds.push(entry.session + ' → ' + report.nextCommand);
      return;
    }
    if (!report.wedged) return;
    if (report.recoverable) recoverable.push(entry.session + ' → ' + report.nextCommand);
    else blocked.push(entry.session + ' → ' + report.nextCommand);
  });
  line(
    unclassifiable ? WARN : OK,
    'chain: ' + shapes.length + ' review chain(s)'
      + (unclassifiable ? ', ' + unclassifiable + ' unclassifiable' : '')
      + ' — ' + truncatedList(shapes),
  );
  if (recoverable.length) {
    line(WARN, 'chain: ' + recoverable.length + ' wedged chain(s) that no supported command can advance — run /zensu:recover-chain from the owning session: ' + truncatedList(recoverable));
  }
  if (blocked.length) {
    line(WARN, 'chain: ' + blocked.length + ' chain(s) wedged but not recoverable in place — from the session that owns each chain: ' + truncatedList(blocked));
  }
  if (deadEnds.length) {
    line(WARN, 'chain: ' + deadEnds.length + ' chain(s) at a dead end — a fresh generation is the only exit, from the session that owns each chain: ' + truncatedList(deadEnds));
  }
}

function truncatedList(rows) {
  var listed = rows.slice(0, CHAIN_ROW_LIMIT);
  var overflow = rows.length - listed.length;
  return listed.join('; ') + (overflow ? '; +' + overflow + ' more' : '');
}

function bindingLine() {
  switch (env.ZDOC_BINDING) {
    case 'bound':
      return line(OK, 'binding: this session has a valid Session Control record — stateful tools can run');
    case 'unbound':
      return line(BAD, 'binding: this session has no valid Session Control record — every stateful Zensu tool fails closed; start a fresh Claude Code session');
    // A record that is valid in every other respect, pointing at a directory
    // that is gone. Naming the path matters: "re-create exactly that directory"
    // is only actionable if the user is told which one, and the generic unbound
    // line above would send them looking for a record that is right there.
    case 'orphaned-project-root':
      return line(BAD, 'binding: the project root recorded for this session no longer exists'
        + (env.ZDOC_BINDING_PROJECT_ROOT ? ' (' + env.ZDOC_BINDING_PROJECT_ROOT + ')' : '')
        + ' — a deleted or recycled worktree took the workflow state with it, so stateful Zensu tools fail closed while this read-only diagnostic still runs; re-create exactly that directory to resume, or start a fresh Claude Code session');
    // The record is INTACT and only the runtime serving it declares an
    // incompatible lineage — a plugin update that landed mid-session. Before this
    // row existed the state fell through to `unbound` above, whose line asserts
    // "no valid Session Control record": false, and it sends the user hunting for
    // a record sitting intact in plugin data. Naming both versions is what makes
    // the cause checkable rather than a claim the user has to take on faith, and
    // this is the only binding row whose remedy repairs the session in place.
    case 'incompatible-runtime':
      return line(BAD, 'binding: this session\'s Session Control record is intact, but the running Zensu installation declares an incompatible lineage'
        + (env.ZDOC_BINDING_RECORDED_VERSION && env.ZDOC_BINDING_EXECUTING_VERSION
          ? ' (record minted by ' + env.ZDOC_BINDING_RECORDED_VERSION + ', executing ' + env.ZDOC_BINDING_EXECUTING_VERSION + ')'
          : '')
        + ' — while the plugin is at major 0 the minor is the breaking axis, so stateful Zensu tools fail closed; run /zensu:adopt-session to see whether this session can be adopted in place, then /zensu:adopt-session --confirm');
    case 'unavailable':
      return line(BAD, 'binding: hooks/lib/zensu-session.sh is missing or symlinked — Session Control cannot bind');
    default:
      return undefined;
  }
}

function stateBlock(nowMs) {
  block('Session state');
  bindingLine();
  var projectRoot = path.resolve(env.CLAUDE_PROJECT_DIR || '.');
  var dir = path.join(projectRoot, '.zensu', 'state');
  var entries;
  try {
    entries = fs.readdirSync(dir);
  } catch (e) {
    line(OK, 'state: ' + dir + ' does not exist yet — nothing to clean');
    return;
  }
  try {
    fs.accessSync(dir, fs.constants.W_OK);
  } catch (e) {
    line(BAD, 'state: ' + dir + ' is not writable — chain markers cannot be recorded');
  }
  var workflowDocs = entries.filter(function (f) {
    return /^tdd-phase-scv1_[a-f0-9]{64}\.json$/.test(f);
  }).sort();
  if (!workflowDocs.length) {
    line(OK, 'state: no CAS workflow documents yet');
  } else {
    var core;
    var invalid = [];
    try {
      core = require(path.join(pluginDir(), 'hooks', 'lib', 'session-control-core-v1.js'));
    } catch (e) {
      invalid = workflowDocs.slice();
    }
    var states = [];
    if (core) {
      workflowDocs.forEach(function (file) {
        var match = /^tdd-phase-(scv1_[a-f0-9]{64})\.json$/.exec(file);
        try {
          states.push({
            session: match[1].slice(0, 13) + '…',
            state: core.readWorkflowState({ projectRoot: projectRoot, sessionId: match[1] }),
          });
        } catch (e) {
          invalid.push(file);
        }
      });
    }
    var valid = workflowDocs.length - invalid.length;
    if (valid) {
      line(OK, 'state: ' + valid + ' validated CAS workflow document(s); reviewRound/stopBlockCount are integrated fields');
    }
    if (invalid.length) {
      line(BAD, 'state: ' + invalid.length + ' invalid CAS workflow document(s) — hooks fail closed; inspect ' + invalid.join(', '));
    }
    chainRows(states);
  }
  var pr = path.join(dir, 'pending-review.json');
  try {
    var st = fs.statSync(pr);
    var ageH = (nowMs - st.mtimeMs) / 3600000;
    var ttl = ttlHours();
    if (ageH > ttl) {
      line(WARN, 'state: pending-review.json is ' + Math.floor(ageH) + 'h old (TTL ' + ttl + 'h) — expired, safe to clear');
    } else {
      line(OK, 'state: pending-review.json present and within its ' + ttl + 'h TTL');
    }
  } catch (e) { /* no pending-review marker */ }
}

function main() {
  var nowMs = Number(env.ZDOC_NOW_MS);
  if (!isFinite(nowMs) || nowMs <= 0) nowMs = Date.now();
  out.push('Zensu doctor — read-only setup diagnostics');
  toolBlock();
  pluginBlock();
  configBlock();
  stateBlock(nowMs);
  out.push('');
  if (badCount) out.push('Summary: ' + badCount + ' ' + BAD + '  ' + warnCount + ' ' + WARN + '  — resolve the ❌ items first.');
  else if (warnCount) out.push('Summary: ' + warnCount + ' ' + WARN + '  — no blockers; warnings are optional to address.');
  else out.push('Summary: all checks green ' + OK);
  process.stdout.write(out.join('\n') + '\n');
}

try { main(); } catch (e) {
  process.stdout.write('  ' + WARN + '  zensu-doctor: diagnostics renderer failed — ' + String((e && e.message) || e) + '\n');
}
process.exit(0);
