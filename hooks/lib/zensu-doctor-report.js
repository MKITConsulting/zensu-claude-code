#!/usr/bin/env node
// zensu-doctor-report.js — read-only diagnostics renderer for /zensu:doctor.
// Reads the plugin's own manifest/hooks, the effective config files, and the
// session state dir, then prints a four-block status table using ✅/⚠️/❌
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
var NOTE_MAX_BYTES = 4096;

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
function readJson(p) {
  try {
    return { ok: true, data: JSON.parse(fs.readFileSync(p, 'utf8')) };
  } catch (e) {
    if (e && e.code === 'ENOENT') return { ok: false, missing: true };
    return { ok: false, missing: false, err: String((e && e.message) || e) };
  }
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
    line(BAD, 'plugin.json: ' + (pj.missing ? 'missing' : 'invalid JSON — ' + pj.err));
  } else if (!mj.ok) {
    line(WARN, 'marketplace.json: ' + (mj.missing ? 'missing' : 'invalid JSON — ' + mj.err));
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
    line(BAD, 'hooks.json: ' + (hj.missing ? 'missing' : 'invalid JSON — ' + hj.err));
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
      hits.push(dotted + ' = "' + v + '"');
    } else if (v && typeof v === 'object' && !Array.isArray(v)) {
      walkQuotedBooleans(v, dotted, hits);
    }
  });
}
function configBlock() {
  block('Config');
  var anyPresent = false;
  configFiles().forEach(function (f) {
    var r = readJson(f);
    if (r.missing) return;
    anyPresent = true;
    if (!r.ok) {
      line(BAD, 'config: invalid JSON in ' + f + ' — ' + r.err + ' (the whole file is ignored, defaults apply)');
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

// The note sits in a directory the session itself can write, so it is read the
// way every other record there is: shape decided before the open, no symlink
// followed, no unbounded read. A file this cannot read is never counted as a
// refusal — that would let a planted empty file manufacture a row recommending
// the user widen permissions.
function readNoteJson(file) {
  var fd;
  try {
    var pre = fs.lstatSync(file);
    if (!pre.isFile() || pre.nlink !== 1 || pre.size > NOTE_MAX_BYTES) return null;
    var noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
      ? fs.constants.O_NOFOLLOW : 0;
    var nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
    fd = fs.openSync(file, fs.constants.O_RDONLY | noFollow | nonBlock);
    var st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > NOTE_MAX_BYTES) return null;
    var buf = Buffer.allocUnsafe(st.size);
    var read = fs.readSync(fd, buf, 0, st.size, 0);
    return JSON.parse(buf.toString('utf8', 0, read));
  } catch (e) {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (e) { /* already closed */ } }
  }
}

// The Stop chain-enforcer is the only place that can observe a reviewer spawn
// the host refused — it reads the transcript its payload points at, which this
// diagnostic never sees. The note it leaves behind is therefore the only way to
// report the cause outside the turn it happened in. The enforcer retires the
// note itself on every terminal path, but a session that never Stops again
// cannot, so a note also ages out against the same TTL as pending-review.
function reviewerDenialRows(entries, dir, nowMs) {
  var notes = entries.filter(function (f) {
    return /^reviewer-spawn-denied-scv1_[a-f0-9]{64}\.json$/.test(f);
  }).sort();
  if (!notes.length) return;
  // The `kind` is untrusted too: only values the writer itself issues are
  // accepted, and the tally is prototype-free so a key like `constructor`
  // cannot become the count it is rendered with.
  var allowed = [];
  try {
    var denial = require(path.join(pluginDir(), 'hooks', 'lib', 'reviewer-spawn-denial-v1.js'));
    if (Array.isArray(denial.DENIAL_MARKERS)) {
      allowed = denial.DENIAL_MARKERS.map(function (m) {
        return m && typeof m.kind === 'string' ? m.kind : '';
      }).filter(Boolean);
    }
  } catch (e) { /* every kind then reads as unrecognized */ }
  var kinds = Object.create(null);
  var ttl = ttlHours();
  var valid = 0;
  var stale = 0;
  var rejected = 0;
  // A plugin root without the classifier module cannot vet the kind, and losing
  // the kind must never cost the row: the refusal is the finding, the label is
  // decoration. The empty kind is the same case seen from the writer's side —
  // the enforcer emits it for a refusal whose form it could not classify, and
  // rejecting it would tell the user to delete the note describing a refusal the
  // block reason had just named correctly.
  var vettable = allowed.length > 0;
  notes.forEach(function (f) {
    var parsed = readNoteJson(path.join(dir, f));
    if (!parsed || parsed.schemaVersion !== 1 || typeof parsed.kind !== 'string'
      || !Number.isFinite(parsed.detectedAtMs)
      || (vettable && parsed.kind !== '' && allowed.indexOf(parsed.kind) === -1)) {
      rejected += 1;
      return;
    }
    // `0` DISABLES the TTL (docs/configuration.md), and the canonical
    // `_tdd_pending_file_stale` reads it the same way. Dropping this conjunct
    // would age every live note out instantly at that setting and suppress the
    // one actionable row this whole feature exists to render.
    if (ttl > 0 && (nowMs - parsed.detectedAtMs) / 3600000 > ttl) {
      stale += 1;
      return;
    }
    var kind = vettable ? (parsed.kind || 'unclassified') : 'unknown';
    kinds[kind] = (kinds[kind] || 0) + 1;
    valid += 1;
  });
  if (valid) {
    var summary = Object.keys(kinds).sort().map(function (k) {
      return k + '×' + kinds[k];
    }).join(', ');
    line(WARN, 'state: ' + valid + ' session(s) where the host permission layer refused the '
      + 'zensu:code-reviewer spawn (' + summary + ') — no review ran and the chain cannot close on its own. '
      + 'Allow it with the permissions.allow rule "Agent(zensu:code-reviewer)" in ~/.claude/settings.json '
      + '(all projects) or the project\'s .claude/settings.local.json (this one), or leave '
      + 'the permission mode that refused it, then re-run the review from the owning session. This note is '
      + 'retired automatically once a spawn succeeds or the chain closes.');
  }
  if (stale) {
    line(WARN, 'state: ' + stale + ' reviewer-spawn refusal note(s) older than ' + ttl + 'h — the session that '
      + 'wrote them never ended a turn again, so nothing retired them; they say nothing about the current state '
      + 'and are safe to delete.');
  }
  if (rejected) {
    line(WARN, 'state: ' + rejected + ' reviewer-spawn note(s) this plugin did not write (unreadable, oversized, '
      + 'or an unrecognized kind or schema) — NOT counted as refusals; delete them.');
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
  reviewerDenialRows(entries, dir, nowMs);
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
