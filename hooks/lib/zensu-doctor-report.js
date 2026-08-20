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
//                            is always CLAUDE_PROJECT_DIR/.zensu/state. HOME is
//                            also the ONLY root the reviewer-spawn permission
//                            check reads (HOME/.claude/settings.json) — see
//                            permissionExposureRows below for why no second
//                            settings file is opened or named.
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
var SETTINGS_MAX_BYTES = 1048576;
// A hand-copy of REVIEWER_SUBAGENT_TYPE in hooks/lib/reviewer-spawn-denial-v1.js,
// which exports it. Deliberate, not an oversight: that module is required lazily
// inside reviewerDenialRows and a load failure there degrades one row, while a
// top-level require would take the whole report down with it. The twin literal
// in stop-chain-enforcer.sh's DENIAL_RULE is a third copy of the same identity.
var REVIEWER_AGENT = 'zensu:code-reviewer';
// The Claude Code build (2.1.235) whose settings shape and permission-rule
// grammar the check below was read against. Recorded for the same reason
// DENIAL_MARKERS_SOURCE_BUILD is: only a named build lets a human re-verify
// instead of assume. The parenthesised form above is the ONE spelling of the
// version in this comment — the structure suite extracts the constant below and
// requires exactly it, and a second prose copy would sit outside that
// line-oriented check and could go stale unnoticed.
//
// Every item below is host-coupled, and a port (zensu-codex, zensu-kiro,
// zensu-antigravity) must re-decide each against its own harness:
//   * `permissions.{defaultMode,allow,deny,ask}` and the `auto` value
//   * `autoMode.allow`
//   * the `Agent(<name>)` rule spelling AND the bare tool name `Agent` as a
//     wildcard grant. The bare form matters more than it looks: on the allow
//     list a match SUPPRESSES the exposure row, so a host that does not treat
//     it as a grant inherits a silently-suppressing check.
//   * whether the host trims whitespace in a rule string. Unverified here, so
//     deny/ask trim (over-matching is safe) and allow does not — a port that
//     learns the real answer can collapse the asymmetry.
//   * the HOME/.claude/settings.json layout
//   * `FATAL_RULE_KEYS` below, whose membership is DERIVED from that order — it
//     is exactly the keys evaluated before `allow`. A port that reorders the
//     ladder and leaves this constant alone ships a wrong fatal/deferred split.
//   * the deny -> ask -> allow evaluation order, first match wins. This one is
//     listed separately because its failure mode is the opposite of the others':
//     a rename makes the check fall silent, which is merely useless, while a
//     REORDER leaves every row still rendering and turns the deny row's
//     "adding a permissions.allow rule changes nothing" into a false statement.
var SETTINGS_SOURCE_BUILD = '2.1.235';

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
// The reviewer-spawn permission check. `reviewerDenialRows` below is REACTIVE —
// it counts refusal notes the Stop enforcer already wrote, so it can only speak
// after a chain has wedged. This one is proactive: it reads the settings that
// decide the refusal and reports the exposure beforehand.
//
// It opens exactly ONE path and names exactly one path, both of them
// ~/.claude/settings.json. The project-local spelling is deliberately absent for
// the reason stop-chain-enforcer.sh gives where it builds the same remedy: that
// file sits inside the session root and is a path the agent itself could write,
// so printing it beside the exact rule that grants the refused capability is an
// invitation. These rows are read by the model too.
// Deliberately NOT given a ZDOC_/ZENSU_ override of its own, unlike every other
// input this file takes. An override would be a second agent-writable channel
// able to aim a check ABOUT the agent's own permissions at a file that shows a
// grant. Stated honestly, this NARROWS the channel rather than closing it: HOME
// is itself settable, so a redirect can still suppress or forge a row. What it
// cannot do is disclose anything, because the failure vocabulary below is
// closed — no byte of whatever file it lands on reaches the report. Adding a
// dedicated override would widen the surface for no gain; the structure suite
// sandboxes HOME wholesale for the same reason.
function claudeSettingsFile() {
  if (!env.HOME) return null;
  return path.join(env.HOME, '.claude', 'settings.json');
}
// No O_NOFOLLOW: unlike a refusal note this is the user's own file in the user's
// own home, and Claude Code itself follows a symlink there. A dotfile manager
// (stow, chezmoi) links it routinely, and refusing to follow would report a ⚠️
// did-not-run row for a healthy setup. The descriptor-side discipline IS kept — decide shape
// and size from the DESCRIPTOR, not from a second path resolution, open
// non-blocking so a path swapped to a FIFO cannot hang a process contracted to
// always exit 0, and read bounded to the size that was actually vetted. Two of
// readNoteJson's guards are deliberately absent, not overlooked: O_NOFOLLOW, for
// the symlink reason above, and its `nlink !== 1` hard-link refusal, which
// belongs to a file in a session-writable directory rather than to the user's
// own home.
function readSettingsJson(file) {
  var fd;
  try {
    var nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
    fd = fs.openSync(file, fs.constants.O_RDONLY | nonBlock);
    var st = fs.fstatSync(fd);
    if (!st.isFile()) return { ok: false, missing: false, err: 'not a regular file' };
    if (st.size > SETTINGS_MAX_BYTES) {
      return { ok: false, missing: false, err: 'larger than ' + SETTINGS_MAX_BYTES + ' bytes' };
    }
    var buf = Buffer.allocUnsafe(st.size);
    var read = 0;
    while (read < st.size) {
      var n = fs.readSync(fd, buf, read, st.size - read, read);
      if (n <= 0) break;
      read += n;
    }
    return { ok: true, data: JSON.parse(buf.toString('utf8', 0, read)) };
  } catch (e) {
    if (e && e.code === 'ENOENT') return { ok: false, missing: true };
    // A CLOSED vocabulary, never the raw exception text. JSON.parse embeds a
    // leading slice of its input in the message — measured on node 23:
    // `Unexpected token 'o', "notjson sk-"... is not valid JSON` — so passing it
    // through would put bytes of the user's settings file into a report the
    // doctor skill tells the model to print verbatim. An errno describes the
    // open; it is a fact about the filesystem, not about the file's contents.
    //
    // This rule is LOCAL to this reader and is deliberately not retrofitted onto
    // readJson above, which still prints the raw parser message for the plugin's
    // own config files. That is a separate decision about a different file class
    // (whose path the row already prints anyway) and belongs to its own change —
    // do not read this file as having one uniform policy.
    if (e && e.code) return { ok: false, missing: false, err: 'unreadable (' + e.code + ')' };
    return { ok: false, missing: false, err: 'unparseable JSON' };
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (e) { /* already closed */ } }
  }
}
// A present-but-wrong shape is a check that could not run, never an all-clear:
// `typeof [] === 'object'`, so without the Array test `"permissions": []` would
// read exactly like a settings file with no permissions key at all.
function plainObject(v) {
  return (v && typeof v === 'object' && !Array.isArray(v)) ? v : null;
}
// An ABSENT key is a fact about the settings ({} reads correctly as "no rules");
// a PRESENT key of the wrong shape is not, and must reach the did-not-run row
// rather than silently render as an empty rule set.
//
// The vetting goes to the RULE LISTS, not just to the two containers. Stopping
// at depth 1 was the earlier defect: `matchesReviewerSpawn` opens with an
// Array.isArray guard, so a `deny` written as an object read as "no deny rules"
// and the exposure row then recommended an allow rule while an unevaluated deny
// key sat in the same file — a confidently WRONG remedy, which is worse than the
// silence this doctrine exists to remove.
//
// Returns the same `{ ok: ... }` discriminator readJson and readSettingsJson use.
// An untagged union would make a forgotten check a property read on undefined,
// and a throw here costs the whole report, not one row.
// The unjudgeable keys split by CONSEQUENCE, not by depth — and the consequence
// is NOT whether the exposure row survives. BOTH classes suppress that row, since
// neither can support an allow remedy. What they differ in is the deny/ask rows:
// a malformed `deny` or `ask` is FATAL and takes those down with it, because the
// determination itself is unreadable. Everything else is DEFERRED and is reported
// only AFTER the deny/ask branches have had their say, because those two do not
// depend on it — swallowing the deny row over an unrelated malformed key would
// drop the highest-value row this check emits.
var FATAL_RULE_KEYS = ['deny', 'ask'];
function settingsShape(raw) {
  var data = plainObject(raw);
  if (!data) return { ok: false, err: 'the settings root is not a JSON object' };
  var perms = data.permissions === undefined ? {} : plainObject(data.permissions);
  if (!perms) return { ok: false, err: 'permissions is present but not an object' };
  var autoMode = data.autoMode === undefined ? {} : plainObject(data.autoMode);
  if (!autoMode) return { ok: false, err: 'autoMode is present but not an object' };
  for (var i = 0; i < FATAL_RULE_KEYS.length; i++) {
    var k = FATAL_RULE_KEYS[i];
    if (perms[k] !== undefined && !Array.isArray(perms[k])) {
      return { ok: false, err: 'permissions.' + k + ' is present but not an array' };
    }
  }
  var deferred = '';
  if (perms.allow !== undefined && !Array.isArray(perms.allow)) {
    deferred = 'permissions.allow is present but not an array';
  } else if (perms.defaultMode !== undefined && typeof perms.defaultMode !== 'string') {
    deferred = 'permissions.defaultMode is present but not a string';
  } else if (autoMode.allow !== undefined && !Array.isArray(autoMode.allow)) {
    deferred = 'autoMode.allow is present but not an array';
  }
  return { ok: true, permissions: perms, autoMode: autoMode, deferred: deferred };
}
// One wording for both the fatal and the deferred case. A second phrasing would
// have to be carried into the skill, the operator docs and the drift pin.
function shapeRow(err) {
  line(WARN, 'permissions: ~/.claude/settings.json has a shape this check cannot judge — ' + err
    + '; the reviewer-spawn permission check did not run. That is a missing check, not an all-clear.');
}
// Reused verbatim by the ask row and the exposure row. It shares its second
// clause — "a deny rule outranks an allow rule, so the deny has to go first" —
// with THREE copies, none of which consumes this constant: the reactive row
// further down, DENIAL_REMEDY in hooks/stop-chain-enforcer.sh, and the
// refused-spawn bullet in skills/doctor/SKILL.md. Only the last is machine-pinned
// (P1be and P1qr); the other two are by-hand. Reword one and check them.
//
// Both allow-ward rows recommend an allow rule, and such a rule takes no effect
// behind a deny this check could not see or could not judge — a wildcard
// spelling, a deny in a settings source this file never opens. Saying so costs
// one clause and is true regardless of spelling, which is why it is preferred
// over guessing at the host's rule grammar.
var DENY_FIRST_CAVEAT = ' Remove any deny rule that names the Agent tool first — a deny rule '
  + 'outranks an allow rule, so the deny has to go first.';
// Only the two spellings verified against a live permission decision on Claude
// Code SETTINGS_SOURCE_BUILD are accepted. A wildcard form may well work too,
// but it is not a verified spelling.
// `padded` is the deny/ask spelling and is deliberately NOT used for allow.
// Whether the host trims a rule string is unverified against SETTINGS_SOURCE_BUILD,
// so trimming has to fall on the side where a wrong guess only over-warns: on
// deny/ask an extra match costs a row the user can dismiss, while on allow it
// SUPPRESSES the warning — the direction that leaves no diagnosis at all.
//
// Not widened to `Task(...)` on purpose, and the divergence is worth stating
// because the sibling module invites the opposite conclusion:
// reviewer-spawn-denial-v1.js declares SPAWN_TOOL_NAMES = ['Agent', 'Task'], but
// that set governs TRANSCRIPT tool names, not permission-rule spellings. Nothing
// in this tree verifies `Task(...)` as a rule, so it stays out of both lists —
// do not "fix" one table into the other.
function matchesReviewerSpawn(rules, padded) {
  if (!Array.isArray(rules)) return false;
  for (var i = 0; i < rules.length; i++) {
    if (typeof rules[i] !== 'string') continue;
    var r = padded ? rules[i].trim() : rules[i];
    if (r === 'Agent' || r === 'Agent(' + REVIEWER_AGENT + ')') return true;
  }
  return false;
}
// A deny/ask entry that clearly means this spawn but is not one of the two
// verified spellings. Broadening matchesReviewerSpawn to swallow it was rejected:
// the deny row makes a strong claim ("every /zensu:tdd run wedges at the review
// step") that must not fire for an unrelated agent, and a wildcard spelling is
// the same unverified host grammar moved onto the loud side. Reporting that the
// entry could not be JUDGED keeps the fall-through from ending at the allow
// remedy, without asserting what the entry does.
function namesReviewerSpawn(rules) {
  if (!Array.isArray(rules)) return false;
  for (var i = 0; i < rules.length; i++) {
    if (typeof rules[i] !== 'string') continue;
    var r = rules[i].trim();
    // Defensive and UNREACHABLE from the only caller, which reaches this
    // predicate solely after matchesReviewerSpawn(..., true) rejected the same
    // list with the same trim and the same two comparisons. Kept so the
    // predicate is correct standing alone, not because a fixture covers it.
    if (r === 'Agent' || r === 'Agent(' + REVIEWER_AGENT + ')') continue;
    if (r.indexOf(REVIEWER_AGENT) !== -1) return true;
  }
  return false;
}
// A THIRD predicate, and deliberately not a fourth spelling of the other two:
// this one scans `autoMode.allow`, which holds classifier guidance in PROSE
// rather than permission rules. So it does not trim (there is no rule to
// normalize) and it does not exclude the two verified spellings (a prose line
// that happens to quote one still is not a grant). Collapsing it into
// namesReviewerSpawn would import both of those behaviours and make this row
// silent on exactly the sentence it exists to correct.
function mentionsReviewerAgent(rules) {
  if (!Array.isArray(rules)) return false;
  for (var i = 0; i < rules.length; i++) {
    if (typeof rules[i] === 'string' && rules[i].indexOf(REVIEWER_AGENT) !== -1) return true;
  }
  return false;
}
function permissionExposureRows() {
  var file = claudeSettingsFile();
  if (!file) return;
  var r = readSettingsJson(file);
  if (r.missing) return;
  if (!r.ok) {
    line(WARN, 'permissions: ~/.claude/settings.json could not be read — ' + r.err
      + '; the reviewer-spawn permission check did not run. That is a missing check, not an all-clear.');
    return;
  }
  var shape = settingsShape(r.data);
  if (!shape.ok) {
    // NOT "could not be read": this branch is reached only after the file was
    // read and parsed successfully, and naming the wrong cause sends the user
    // hunting for a filesystem problem that does not exist.
    shapeRow(shape.err);
    return;
  }
  var perms = shape.permissions;
  var autoMode = shape.autoMode;
  var mode = typeof perms.defaultMode === 'string' ? perms.defaultMode : '';
  // Claude Code evaluates deny, then ask, then allow, and the first match wins —
  // so a deny is reported even when an allow rule for the same spawn is present,
  // and neither depends on the permission mode.
  if (matchesReviewerSpawn(perms.deny, true)) {
    line(WARN, 'permissions: a permissions.deny entry in ~/.claude/settings.json matches the '
      + REVIEWER_AGENT + ' spawn. Deny is evaluated before ask and allow, so the review chain can never '
      + 'spawn its reviewer and every /zensu:tdd run wedges at the review step. Remove that entry '
      // Self-contained on purpose. This used to point at "the refused-spawn row
      // below", but that row renders only when a refusal note exists, so the
      // reference dangled in the ordinary case. Naming the RULE instead is true
      // whether or not the other row prints.
      + 'yourself if the block was not intended: while it stands, adding a permissions.allow rule for '
      + 'this spawn changes nothing — including the "Agent(' + REVIEWER_AGENT + ')" rule that a '
      + 'refused-spawn report recommends.');
    return;
  }
  if (matchesReviewerSpawn(perms.ask, true)) {
    line(WARN, 'permissions: a permissions.ask entry in ~/.claude/settings.json matches the '
      + REVIEWER_AGENT + ' spawn. Ask is evaluated before allow, so the spawn prompts every time and a '
      + 'turn that cannot answer the prompt refuses it. Move the rule to permissions.allow yourself if '
      + 'you meant to grant it.' + DENY_FIRST_CAVEAT);
    return;
  }
  // Before the fall-through: an entry that plainly names this spawn but is not a
  // spelling this check verified. Saying nothing here would drop straight to the
  // exposure row, which recommends an allow rule that such an entry may outrank.
  if (namesReviewerSpawn(perms.deny) || namesReviewerSpawn(perms.ask)) {
    line(WARN, 'permissions: a permissions.deny or permissions.ask entry in ~/.claude/settings.json '
      + 'names ' + REVIEWER_AGENT + ' in a spelling this check has not verified, so it cannot judge '
      + 'whether that entry blocks the spawn. Read the entry yourself before adding any '
      + 'permissions.allow rule: deny and ask are both evaluated before allow, so an entry that does '
      + 'block would make an allow rule take no effect.');
    return;
  }
  // Only now: the deferred half of the shape check. Reporting it earlier would
  // have swallowed the deny/ask rows above, which do not depend on any of it.
  //
  // Resolved BEFORE the deferred branch, not inside it. A user who already holds
  // the rule must not be told to add it, and that has to hold on a deferred
  // failure too — where the old inline return was unreachable. Safe even when
  // `permissions.allow` is itself the malformed key: the predicate opens with an
  // Array.isArray guard and simply answers false.
  var granted = matchesReviewerSpawn(perms.allow, false);
  // An else-guard rather than a `return`, and the difference is the autoMode row
  // below. A deferred failure suppresses the exposure row — the deferred set
  // covers `permissions.allow` and `permissions.defaultMode`, which that row's
  // claim rests on — but the autoMode row reads `autoMode.allow` and says only
  // that it is not a permission rule. Returning here suppressed that too.
  //
  // Accepted asymmetry: `autoMode.allow` is ALSO in the deferred set, so a
  // malformed one costs the exposure row even though that row does not depend on
  // it. P1az6 pins the current behaviour; splitting `deferred` into two carriers
  // would fix it, and that is recorded as a known gap rather than done here.
  if (shape.deferred) {
    shapeRow(shape.deferred);
  } else {
    // Nothing below applies to a session that already holds the rule. Note what
    // this exit does NOT say: a deny in a spelling this check declined to judge
    // can sit in the same file and still outrank that grant, and no row reports
    // it — the caveat clause is not reachable from here.
    if (granted) return;
    if (mode === 'auto') {
      line(WARN, 'permissions: permission mode "auto" is set in ~/.claude/settings.json and no '
        + 'permissions.allow entry there spells either "Agent(' + REVIEWER_AGENT + ')" or the bare "Agent" '
        + '— the auto-mode classifier can refuse the reviewer spawn, and a refused spawn leaves the review '
        + 'chain with no review it can close on. Add "Agent(' + REVIEWER_AGENT + ')" to permissions.allow in '
        + '~/.claude/settings.json yourself; no agent may edit a settings file to widen its own permissions.'
        + DENY_FIRST_CAVEAT
        + ' This row reports an exposure, never a prediction: the classifier decides per session context, and '
        + 'settings sources this check does not read may already grant it. The reverse holds too — the '
        + 'permission mode can be in effect for a session without being written into this file, so the '
        + 'absence of this row is not evidence that auto mode is inactive.');
    }
  }
  // Self-contained: it used to end "the permissions.allow rule named above",
  // which dangles whenever the row above did not print — the same defect the
  // deny row was corrected for. Suppressed by a real grant, and by every earlier
  // `return` in this function — unset HOME, absent file, unreadable file, fatal
  // shape, deny, ask, could-not-judge all return before it is reached.
  if (!granted && mentionsReviewerAgent(autoMode.allow)) {
    line(WARN, 'permissions: an autoMode.allow entry in ~/.claude/settings.json mentions '
      + REVIEWER_AGENT + ', but autoMode.allow carries classifier guidance in prose — it is not a '
      + 'permission rule and does not grant the spawn. Only a permissions.allow entry spelling '
      + '"Agent(' + REVIEWER_AGENT + ')" or the bare "Agent" does.');
  }
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
  permissionExposureRows();
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
// Distinct from `null` on purpose. The enforcer retires notes from every one of
// its terminal paths, so a note disappearing between this report's directory
// listing and this open is the DESIGN working, not a planted file — and the
// rejected row tells the user the plugin did not write it and to delete it.
// Accusing our own artifact over an expected race is the worse failure.
var NOTE_MISSING = {};

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
    // Loop rather than a single readSync, matching readTail in
    // reviewer-spawn-denial-v1.js. A short read would truncate the JSON, throw in
    // JSON.parse, and land this plugin's own note in the "did not write it" row.
    var read = 0;
    while (read < st.size) {
      var n = fs.readSync(fd, buf, read, st.size - read, read);
      if (n <= 0) break;
      read += n;
    }
    return JSON.parse(buf.toString('utf8', 0, read));
  } catch (e) {
    if (e && e.code === 'ENOENT') return NOTE_MISSING;
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
    // Retired between the directory listing and the open — count nothing.
    if (parsed === NOTE_MISSING) return;
    // A note is only this plugin's word if a session that could have written it
    // still exists. Without this the note stands entirely on its own contents,
    // and the state directory is writable from inside the session — so anything
    // able to write there could mint a row telling the user to widen
    // permissions for the very spawn the writer wants. The workflow document is
    // the one sibling the writer cannot fabricate on its own.
    var owner = /^reviewer-spawn-denied-(scv1_[a-f0-9]{64})\.json$/.exec(f);
    if (!owner || entries.indexOf('tdd-phase-' + owner[1] + '.json') === -1) {
      rejected += 1;
      return;
    }
    if (!parsed || parsed.schemaVersion !== 1 || typeof parsed.kind !== 'string'
      // Integer and positive, not merely finite: a timestamp the writer could
      // never have produced is not evidence about the present.
      || !Number.isInteger(parsed.detectedAtMs) || parsed.detectedAtMs <= 0
      || (vettable && parsed.kind !== '' && allowed.indexOf(parsed.kind) === -1)) {
      rejected += 1;
      return;
    }
    // `0` DISABLES the TTL (docs/configuration.md), and the canonical
    // `_tdd_pending_file_stale` reads it the same way. Dropping this conjunct
    // would age every live note out instantly at that setting and suppress the
    // one actionable row this whole feature exists to render.
    //
    // The future-timestamp arm closes the other side: a negative age never
    // exceeds the TTL, so without it a clock that stepped backwards — or a
    // planted stamp — makes the note immortal and keeps recommending a
    // permission change for a refusal that is not current. Stale is the honest
    // bucket: its own text already says the note says nothing about now.
    if (ttl > 0 && (parsed.detectedAtMs > nowMs
        || (nowMs - parsed.detectedAtMs) / 3600000 > ttl)) {
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
      // Names ONLY the user-scoped file, for the reason stop-chain-enforcer.sh
      // gives where it builds the same remedy: the project-local spelling sits
      // inside the session root and is a path the agent itself could write, so
      // printing it beside the exact rule that grants the refused capability is
      // an invitation. This row is read by the model too.
      + 'Allow it with the permissions.allow rule "Agent(' + REVIEWER_AGENT + ')" in ~/.claude/settings.json, '
      // The deny caveat has to live here too, not only in the Config-block deny
      // row: that row reads one file, so a deny in any source it cannot see
      // leaves this remedy standing alone. stop-chain-enforcer.sh words the same
      // remedy with the same caveat.
      + 'first removing any deny rule that names the Agent tool — a deny rule outranks an allow rule, '
      + 'so the deny has to go first — or leave the permission mode that refused it, then re-run the '
      + 'review from the owning session. '
      + 'You have to apply this yourself — no agent may edit a settings file to widen its own permissions. '
      + 'This note is retired automatically once a spawn succeeds or the chain closes.');
  }
  if (stale) {
    line(WARN, 'state: ' + stale + ' reviewer-spawn refusal note(s) older than ' + ttl + 'h — the session that '
      + 'wrote them never ended a turn again, so nothing retired them; they say nothing about the current state '
      + 'and are safe to delete.');
  }
  if (rejected) {
    line(WARN, 'state: ' + rejected + ' reviewer-spawn note(s) this plugin did not write (unreadable, oversized, '
      + 'an unrecognized kind or schema, an impossible timestamp, or no matching session) — NOT counted as '
      + 'refusals; delete them.');
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
