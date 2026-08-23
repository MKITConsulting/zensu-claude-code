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
// top-level require would take the whole report down with it.
//
// Do NOT read the sentence above as a census of the tree. An earlier version named
// stop-chain-enforcer.sh's DENIAL_RULE as "a third copy" and CLAUDE.md turned that
// into "the three copies — check them by hand", which made the by-hand instruction
// unfollowable: the literal really lives in EIGHT files under hooks/ (27 occurrences,
// measured 2026-08-23 — the grep instruction below is one of them, so the occurrence
// number moves when this comment is edited while the FILE count does not; that is the
// second reason to trust the grep over any number written here), and two of them are
// functional comparisons a rename breaks
// silently — post-review-tdd-delegate.sh's SUBAGENT_TYPE test and
// claude-principal-v1.js's list entry. An enumeration in a comment goes stale the next
// time one is added, so the instruction is a GREP, not a list: before renaming this
// identity, `grep -rn 'zensu:code-reviewer' hooks/` and change every site.
// One pair IS machine-checked — P1by pins THIS constant against the exporting one, so
// the two spellings cannot drift apart unnoticed. The other six files are not pinned.
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
//   * the `Task` and `Task(` rule spellings, admitted by the LOW-CLAIM predicate only
//     and NOT verified against this build. They are listed here because a port must
//     re-decide them like every other spelling: this tree's own
//     reviewer-spawn-denial-v1.js treats `Task` as a name the spawn travels under in a
//     TRANSCRIPT, which is not the same thing as a permission-rule spelling. A host
//     where `Task` is not a rule form should drop the arm rather than keep a row it
//     cannot support.
//   * whether the host trims whitespace in a rule string. Unverified here, so
//     deny/ask trim (over-matching is safe) and allow does not — a port that
//     learns the real answer can collapse the asymmetry.
//   * the HOME/.claude/settings.json layout
//   * `RULE_LADDER` below, which IS that order. `FATAL_RULE_KEYS` is computed from
//     it — exactly the keys evaluated before `allow` — so a port reorders that one
//     array and the fatal/deferred split follows instead of drifting from it.
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
// Same closed failure vocabulary as readSettingsJson, and for the same reason: V8 quotes
// a ten-character window from the start of the input in its parse message — measured on
// node v23.11.0, `Unexpected token 's', "sk-CFGDECO"... is not valid JSON` — so passing
// the raw text through put the opening bytes of the file into a report the doctor skill
// tells the model to print verbatim.
//
// This reader used to be exempt, on the argument that it reads a different file class
// whose path the row already prints. That argument does not hold: printing the PATH and
// printing a slice of the CONTENT are different disclosures, and only the second is the
// hazard. It also assumed the file class was fixed, which it is not — configFiles()
// honours ZENSU_CONFIG as an unconstrained path override, so this reader can be aimed at
// any file, including the settings file the sibling reader exists to protect. One reader
// in a block with a closed vocabulary and one without is not a policy.
//
// The path stays in the row: it is a fact about the filesystem, not about the contents.
var CONFIG_MAX_BYTES = 1024 * 1024;
function readJson(p) {
  var text;
  var fd;
  try {
    // NON-BLOCKING plus a regular-file test, and deliberately NOTHING else from the settings
    // reader. ZENSU_CONFIG can aim this reader at any path, so a FIFO blocked
    // fs.readFileSync forever and the module header's "ALWAYS exits 0" contract was false
    // with no output saying so — measured, not assumed: the unhardened reader hung past a
    // 30 s bound and had to be killed. O_NONBLOCK plus isFile() closes exactly that.
    //
    // O_NOFOLLOW is deliberately ABSENT, and copying it here was a real regression: a
    // dotfile manager links a config routinely, the canonical reader (rd() in
    // hooks/lib/zensu-config.sh) uses readFileSync and follows the link, and the sibling
    // settings reader declines the flag for the same reason with P1ba pinning it. With the
    // flag, a file every hook reads fine rendered a ❌ claiming it was ignored.
    // `|| 0` is banned on BOTH flags — it hides an unavailable constant on a Windows build
    // instead of failing visibly. The win32 conjunct belongs ONLY to readNoteJson's
    // O_NOFOLLOW, and the portability inventory caps that spelling at one occurrence
    // file-wide, so do not add it here.
    var nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
    fd = fs.openSync(p, fs.constants.O_RDONLY | nonBlock);
    var st = fs.fstatSync(fd);
    // No `loaderFallback`, and the class is deliberately COARSE: one !isFile() covers a FIFO,
    // a directory and a socket alike. Only the FIFO's loader consequence is established — rd()'s
    // blocking readFileSync would HANG rather than fall back — while a directory or socket would
    // probably make it throw and return {}. Withholding the flag for all three costs precision,
    // never correctness: the check-limited wording is weaker than the loader verdict, so the
    // conflation can only under-claim. Split the class if the sub-cases are ever verified.
    if (!st.isFile()) return { ok: false, missing: false, io: true, err: 'not a regular file' };
    if (st.size > CONFIG_MAX_BYTES) {
      // `cap` is a FLAG for the same reason `io` is: the render site must not sniff this
      // message, or rewording it silently moves the row back into the branch that asserts a
      // loader verdict this class cannot support.
      return { ok: false, missing: false, io: true, cap: true,
        err: 'larger than ' + CONFIG_MAX_BYTES + ' bytes' };
    }
    var buf = Buffer.alloc(st.size);
    var read = 0;
    while (read < st.size) {
      var n = fs.readSync(fd, buf, read, st.size - read, read);
      if (n <= 0) break;
      read += n;
    }
    if (read !== st.size) {
      return { ok: false, missing: false, io: true, err: 'incomplete (short read)' };
    }
    // No BOM strip and no empty-file acceptance here, unlike the settings reader. Those two
    // are LENIENCY, not hardening, and this reader models a consumer that has neither: rd()
    // hands the raw string — BOM included — straight to JSON.parse and returns {} on throw.
    // Tolerating them would print a green row for a config every hook discards, which is the
    // divergence rule of this file applied backwards: fail toward "no rules found" UNLESS
    // the host would reject the file too. Here it does.
    text = buf.toString('utf8', 0, read);
  } catch (e) {
    if (e && e.code === 'ENOENT') return { ok: false, missing: true };
    // `io` is what the RENDER sites need and the message alone cannot give them. Widening
    // the vocabulary to include an I/O cause without widening the callers left every one
    // of them printing "invalid JSON — unreadable (EACCES)": a content verdict on a file
    // that was never read. The flag, not the string, is the discriminator — a caller that
    // sniffed the prefix would re-open the same defect the moment a wording changed.
    // `loaderFallback` is the THIRD discriminator, and a flag for the same reason as the
    // other two. It says what the CONSUMER does, which is the only thing that licenses the
    // "(the whole file is ignored, defaults apply)" clause: an open or read error makes
    // rd()'s readFileSync throw and return {}, so the clause is true here. A FIFO and a
    // short read do not fall back that way and carry no flag, so they get the
    // check-limited wording instead.
    return { ok: false, missing: false, io: true, loaderFallback: true,
      err: 'unreadable (' + ((e && e.code) ? e.code : 'unknown') + ')' };
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (e) { /* already closed */ } }
  }
  try {
    return { ok: true, data: JSON.parse(text) };
  } catch (e) {
    return { ok: false, missing: false, io: false, loaderFallback: true, err: 'unparseable JSON' };
  }
}
// THREE of the four render sites consume this: plugin.json, marketplace.json and
// hooks.json, which differ only in their subject. The config site does NOT — it embeds the
// path inside its lead-in, so it cannot take this signature without changing bytes that
// P1bt1/P1bt4 pin, and it re-spells the `io` test instead. That is a hand-copy, named here
// rather than hidden: change the decision below and the config site must move with it.
// An I/O failure names the operation that failed, a parse failure names the content.
function jsonFailure(r) {
  // The io:false vocabulary is a single value, so appending it after a lead-in that already
  // says the same thing produced "invalid JSON — unparseable JSON" at three sites. The lead-in
  // carries the meaning; the value adds nothing and is dropped for that class.
  return (r && r.io) ? r.err : 'invalid JSON';
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
    line(BAD, 'plugin.json: ' + (pj.missing ? 'missing' : jsonFailure(pj)));
  } else if (!mj.ok) {
    line(WARN, 'marketplace.json: ' + (mj.missing ? 'missing' : jsonFailure(mj)));
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
    line(BAD, 'hooks.json: ' + (hj.missing ? 'missing' : jsonFailure(hj)));
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
//
// "Suppress or forge a row" understates what a forged row IS, so say it plainly:
// every row names the display string ~/.claude/settings.json and never the path
// that was actually opened. Under a redirected HOME a planted deny entry produces
// a row asserting, in this plugin's own voice, that the user's REAL
// ~/.claude/settings.json denies the reviewer spawn, and telling them to go remove
// an entry that is not there — a misattribution, not merely a false positive. The
// inverse is quieter and worse: a planted allow rule silences the one proactive
// warning this check exists to produce, and skills/doctor/SKILL.md then has the
// model report the table as green. Naming the opened path instead would trade the
// misattribution for the disclosure this file refuses, so the display string stays.
//
// The bound that actually exists is the recognizer's, not this comment's:
// hooks/lib/zensu-doctor-invocation.js admits a CLOSED assignment allowlist —
// CLAUDE_PLUGIN_DATA, CLAUDE_PROJECT_DIR, ZDOC_PLAYWRIGHT_TOOLS — and neither HOME
// nor ZENSU_CONFIG is in it, so the RECOGNIZED doctor invocation cannot carry a
// redirect. Whether an ordinary Bash call in a healthy session can is UNVERIFIED:
// zensu-doctor.sh never reads or normalises HOME, and the Bash gates cover zensu
// mutations and source writes, neither of which a read-only doctor run is.
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
  var text;
  try {
    // The `: 0` arm is UNEXERCISED, and stating that is the whole mitigation taken
    // here. It is taken only where O_NONBLOCK is not an integer constant — i.e. not
    // on the POSIX hosts this suite runs on — and tests/structure/test-doctor.sh
    // appears in no shard of tests/profiles/windows-ci.v1.json and sits in the
    // `excluded` list of tests/profiles/windows-native-structure.v1.json. So the one
    // platform family the fallback exists for never runs this path, and whether
    // `O_RDONLY | 0` still behaves on a host without the flag has no CI evidence
    // anywhere. The alternative — adding a doctor entry to a Windows shard — is not
    // free wall clock (P1az4 writes 1.1 MB, P1bg polls a FIFO to a 30 s deadline) and
    // under CLAUDE.md it must be budgeted against a MEASURED figure, which nobody has
    // taken. Left unexercised deliberately; say "unverified", never "covered".
    var nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
    fd = fs.openSync(file, fs.constants.O_RDONLY | nonBlock);
    var st = fs.fstatSync(fd);
    if (!st.isFile()) return { ok: false, missing: false, io: true, err: 'not a regular file' };
    if (st.size > SETTINGS_MAX_BYTES) {
      return { ok: false, missing: false, io: true, err: 'larger than ' + SETTINGS_MAX_BYTES + ' bytes' };
    }
    // Buffer.alloc, not allocUnsafe, and the content class is the whole reason: this
    // buffer holds the user's settings file, which is exactly where an API key lives.
    // The bound below (`toString(..., 0, read)`) does keep uninitialised memory out of
    // the report today — but it is one token, on a path no ordinary fixture reaches, in
    // a report the doctor skill tells the model to print verbatim. The size is capped at
    // SETTINGS_MAX_BYTES two lines up and the renderer runs once per invocation, so the
    // zero-fill is unmeasurable against node's own startup.
    //
    // readNoteJson below deliberately keeps allocUnsafe: it reads this plugin's own
    // note in the state directory, not the user's credential file. The divergence is a
    // decision about content class, not an oversight — P1br1 pins the count.
    var buf = Buffer.alloc(st.size);
    var read = 0;
    while (read < st.size) {
      var n = fs.readSync(fd, buf, read, st.size - read, read);
      if (n <= 0) break;
      read += n;
    }
    // The loop exits on `n <= 0` as well as on completion, so reaching here does NOT
    // mean the file was read. Without this the truncated prefix went straight to
    // JSON.parse and the failure surfaced as `unparseable JSON` — a CONTENT fault
    // reported for an I/O truncation, which is the exact mirror of the mislabel the
    // `!shape.ok` branch below guards against. The two other bounded readers in this
    // tree (plan-payload-v1.js, session-control-core-v1.js) already carry this guard.
    if (read !== st.size) {
      return { ok: false, missing: false, io: true, err: 'incomplete (short read)' };
    }
    // This reader models a consumer whose parser it does not share, so every strictness
    // divergence should fail toward "no rules found" rather than toward "the check did
    // not run" — unless the host would reject the file too. Two such divergences, both
    // routine artefacts rather than corruption: JSON.parse rejects a leading U+FEFF as a
    // spec property, and it rejects empty input, which is what an interrupted write
    // leaves behind. Reporting either as a fault costs more than it buys: all three
    // permission rows share one prefix, so a user who learns to dismiss a false
    // did-not-run row dismisses the deny row with it.
    text = buf.toString('utf8', 0, read);
  } catch (e) {
    if (e && e.code === 'ENOENT') return { ok: false, missing: true };
    // A CLOSED vocabulary, never the raw exception text. JSON.parse embeds a
    // leading slice of its input in the message — measured on node 23:
    // `Unexpected token 'o', "notjson sk-"... is not valid JSON` — so passing it
    // through would put bytes of the user's settings file into a report the
    // doctor skill tells the model to print verbatim. An errno describes the
    // open; it is a fact about the filesystem, not about the file's contents.
    //
    // Only I/O reaches this handler now, so the reason is an I/O reason on every
    // path through it. `unknown` replaces what used to be a fall-through to
    // 'unparseable JSON': a code-less error from open/fstat/read is still an I/O
    // failure, and blaming it on the file's contents was the same mislabel in
    // miniature.
    return { ok: false, missing: false, io: true,
      err: 'unreadable (' + ((e && e.code) ? e.code : 'unknown') + ')' };
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (e) { /* already closed */ } }
  }
  // Parsing sits OUTSIDE the I/O try, and after the descriptor is closed. Sharing one
  // try meant the two failure classes were told apart by the ABSENCE of `e.code` — true
  // on current node, because V8 does not decorate SyntaxError, but a property of the
  // runtime rather than of this code. Now each handler covers exactly the operation it
  // wraps, and a code-bearing parse failure can no longer be reported as an I/O fault.
  //
  // The closed vocabulary is preserved verbatim on both sides: no exception text
  // reaches a row. That rule is LOCAL to this reader — see readJson.
  if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
  if (text.trim() === '') return { ok: true, data: {} };
  try {
    return { ok: true, data: JSON.parse(text) };
  } catch (e) {
    // io:false, and this is why the flag has to exist here too. The sibling reader gained it
    // one step earlier and this one did not, so a PARSE failure was announced under a "could
    // not be read" lead-in — the same cause/operation mislabel FR-003 and FR-005 removed,
    // running in the opposite direction. Naming the wrong cause sends the user hunting for a
    // filesystem problem that does not exist.
    return { ok: false, missing: false, io: false, err: 'unparseable JSON' };
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
// at depth 1 was the earlier defect: `matchesDenyOrAskRule` opens with an
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
// The evaluation ORDER is the single source; the fatal set is DERIVED from it here
// rather than asserted by a comment. As a literal, `['deny', 'ask']` claimed to be
// "exactly the keys evaluated before allow" while nothing performed that derivation
// and no pin observed it — so a port that reordered the ladder and left the constant
// alone shipped a wrong fatal/deferred split with every check still green. Reorder
// RULE_LADDER and the split follows. P1bi pins the derivation; P1bd2 pins that this
// array still agrees with the order the ladder actually dereferences, which is the
// half a constant can never state about itself.
var RULE_LADDER = ['deny', 'ask', 'allow'];
var FATAL_RULE_KEYS = RULE_LADDER.slice(0, RULE_LADDER.indexOf('allow'));
function settingsShape(raw) {
  var data = plainObject(raw);
  if (!data) return { ok: false, err: 'the settings root is not a JSON object' };
  var perms = data.permissions === undefined ? {} : plainObject(data.permissions);
  if (!perms) return { ok: false, err: 'permissions is present but not an object' };
  // NOT fatal, and the asymmetry is the lesson the autoMode.allow carrier already taught
  // one level down: the only claim that depends on this container is the prose guidance
  // row. Returning ok:false here withheld the deny, ask, could-not-judge and exposure
  // determinations — all of them fully computable from `permissions`, which was readable —
  // because a key none of them consults had the wrong type. FATAL_RULE_KEYS is exactly the
  // keys evaluated before `allow`; `autoMode` is not one of them, so it defers like any
  // other key whose row can be suppressed alone.
  var autoModeRaw = data.autoMode === undefined ? {} : plainObject(data.autoMode);
  var autoMode = autoModeRaw || {};
  for (var i = 0; i < FATAL_RULE_KEYS.length; i++) {
    var k = FATAL_RULE_KEYS[i];
    if (perms[k] !== undefined && !Array.isArray(perms[k])) {
      return { ok: false, err: 'permissions.' + k + ' is present but not an array' };
    }
  }
  // TWO deferred carriers, not one. A single carrier meant a malformed `autoMode.allow`
  // suppressed the EXPOSURE row — the primary output of this whole check — even though
  // that row's claim rests only on `permissions.allow` and `permissions.defaultMode`.
  // The exposure determination was fully computable and was thrown away. Each carrier
  // now suppresses exactly the row whose claim depends on it, and nothing else.
  var deferredExposure = '';
  if (perms.allow !== undefined && !Array.isArray(perms.allow)) {
    deferredExposure = 'permissions.allow is present but not an array';
  } else if (perms.defaultMode !== undefined && typeof perms.defaultMode !== 'string') {
    deferredExposure = 'permissions.defaultMode is present but not a string';
  }
  var deferredAutoMode = '';
  if (!autoModeRaw) {
    deferredAutoMode = 'autoMode is present but not an object';
  } else if (autoMode.allow !== undefined && !Array.isArray(autoMode.allow)) {
    deferredAutoMode = 'autoMode.allow is present but not an array';
  }
  return { ok: true, permissions: perms, autoMode: autoMode,
    deferredExposure: deferredExposure, deferredAutoMode: deferredAutoMode };
}
// TWO wordings, and the split is the point. The fatal site returns, so there "the
// reviewer-spawn permission check did not run" is simply true. The two DEFERRED sites do
// not return, and the deny, ask, could-not-judge and unreadable-entry branches have all
// already run and judged by the time they are reached — so the same sentence there printed
// a whole-check claim directly beneath a substantive finding and contradicted it. The
// second phrasing costs a carry into skills/doctor/SKILL.md, the operator docs and the
// P1be drift pin; that price buys a report that does not argue with itself.
//
// Both rows keep the "not an all-clear" doctrine and both keep naming the malformed key,
// because a reader who cannot see WHICH key is malformed cannot repair the file. Two
// malformed carriers therefore still render two rows — they differ, and dropping one
// would hide a real defect.
function shapeRow(err) {
  line(WARN, 'permissions: ~/.claude/settings.json has a shape this check cannot judge — ' + err
    + '; the reviewer-spawn permission check did not run. That is a missing check, not an all-clear.');
}
function deferredShapeRow(err, scope) {
  line(WARN, 'permissions: ~/.claude/settings.json has a shape this check cannot judge — ' + err
    + '; the ' + scope + ' could not be determined. That is a missing part of the check, not an '
    + 'all-clear.');
}
// Reused verbatim by the ask row and the exposure row. It shares its second
// clause — "a deny rule outranks an allow rule, so the deny has to go first" —
// with FIVE copies, none of which consumes this constant: the DENY row, the
// reactive row further down, DENIAL_REMEDY in hooks/stop-chain-enforcer.sh, the
// refused-spawn bullet in skills/doctor/SKILL.md, and `unjudgeableRow` below.
// Each states the same deny-before-allow precedence. TWO of these five carry the
// trailing clause verbatim — the reactive row and DENIAL_REMEDY — and a third, the
// SKILL.md bullet, carries only its first half. With this constant that is the three
// CLAUDE.md counts on its own base.
// `unjudgeableRow` deliberately does NOT reuse this constant: it tells the reader
// to go and READ the entry, while this text tells them to REMOVE a deny, so
// pasting it there would give the wrong instruction.
// CLAUDE.md counts the same class as SIX INCLUDING the constant. Five besides,
// six including — one membership, two bases. Keep both; do not "fix" one into the
// other. FOUR of the six carry a machine-pinned literal, and the pins work precisely
// BECAUSE the clause is shared verbatim rather than paraphrased: the constant (P1be),
// the reactive row (P1qr), DENIAL_REMEDY (the Stop routing suite), and the SKILL.md
// bullet (the grep -qF side of both doctor pins). The DENY row is pinned too, by its
// own clause: P1bv and P1bm3 match 'Deny is evaluated before ask and allow' literally,
// so five of the six are caught by something. `unjudgeableRow` ALONE is the copy
// nothing catches — greps for its own sentence return nothing — so it is the one to
// check by hand after any reword.
//
// Both allow-ward rows recommend an allow rule, and such a rule takes no effect
// behind a deny this check could not see or could not judge — a wildcard
// spelling, a deny in a settings source this file never opens. Saying so costs
// one clause and is true regardless of spelling, which is why it is preferred
// over guessing at the host's rule grammar.
var DENY_FIRST_CAVEAT = ' Remove any deny rule that names the Agent tool first — a deny rule '
  + 'outranks an allow rule, so the deny has to go first.';
// RESIDUAL, recorded because it is a channel and not a defect: the top-level handler at
// the bottom of this file interpolates `String(e.message)`. No reader here lets a parse
// throw escape to it — each one catches and maps into its own closed vocabulary — so no
// settings byte reaches it today. A future reader that omits that mapping would reopen
// the leak THERE rather than at its own call site, which is the harder place to notice.
// A new reader owns its own catch.
//
// The self-permission bar, carried by every row that INSTRUCTS a settings edit and by
// no other — five rows: deny, ask, could-not-judge, exposure, and the reactive
// refused-spawn row. "Every row except the OK one" was the earlier wording and it was
// false: the could-not-be-read row, all three shape rows, the autoMode.allow prose row,
// the HOME-unset row and the containment row instruct nothing and correctly omit it.
// It is deliberately the
// bare clause rather than a whole sentence, so each row supplies its own lead-in and
// all five call sites CONSUME it: two of them (the exposure row and the reactive
// refused-spawn row) previously spelled it inline, and their emitted bytes are
// unchanged, which is what keeps P1be and P1qr green. A shared constant with an
// unconsumed copy beside it is worse than either honest duplication or one source,
// because it advertises a single source that does not exist.
var SELF_PERMISSION_BAR = 'no agent may edit a settings file to widen its own permissions';
// Only the two spellings verified against a live permission decision on Claude
// Code SETTINGS_SOURCE_BUILD are accepted. A wildcard form may well work too,
// but it is not a verified spelling.
// TWO named predicates rather than one with a boolean flag, because the flag named
// the INPUT ("padded") while it decided the BEHAVIOUR, and `true` at a call site
// said nothing about which side of the asymmetry was meant. Whether the host trims a
// rule string is unverified against SETTINGS_SOURCE_BUILD, so trimming has to fall on
// the side where a wrong guess only over-warns: on deny/ask an extra match costs a row
// the user can dismiss, while on allow it SUPPRESSES the warning — the direction that
// leaves no diagnosis at all. The names now carry that asymmetry; do not collapse them
// back behind a parameter.
//
// Not widened to `Task(...)` on purpose, and the divergence is worth stating
// because the sibling module invites the opposite conclusion:
// reviewer-spawn-denial-v1.js declares SPAWN_TOOL_NAMES = ['Agent', 'Task'], but
// that set governs TRANSCRIPT tool names, not permission-rule spellings. Nothing
// in this tree verifies `Task(...)` as a permission-RULE spelling, so it stays out
// of THIS table, whose row asserts that every /zensu:tdd run wedges. It IS admitted
// by the low-claim predicate — see `namesReviewerSpawn`, whose 'shaped' arm claims
// only that the entry cannot be judged. Do not promote it here: what separates the
// two tables is the strength of the claim, not the spelling.
// ONE spelling test, consulted by every predicate that needs it. It used to be written
// out twice — here and again inside namesReviewerSpawn — where the second copy carried
// four lines apologising for being unreachable BECAUSE it duplicated the first. The
// branch is worth keeping; the hand-maintained duplicate was not.
function isVerifiedSpelling(entry) {
  return entry === 'Agent' || entry === 'Agent(' + REVIEWER_AGENT + ')';
}
function matchesDenyOrAskRule(rules) {
  if (!Array.isArray(rules)) return false;
  for (var i = 0; i < rules.length; i++) {
    if (typeof rules[i] !== 'string') continue;
    if (isVerifiedSpelling(rules[i].trim())) return true;
  }
  return false;
}
function matchesAllowRule(rules) {
  if (!Array.isArray(rules)) return false;
  for (var i = 0; i < rules.length; i++) {
    if (typeof rules[i] !== 'string') continue;
    if (isVerifiedSpelling(rules[i])) return true;
  }
  return false;
}
// A deny/ask entry that clearly means this spawn but is not one of the two
// verified spellings. Broadening matchesDenyOrAskRule to swallow it was rejected:
// the deny row makes a strong claim ("every /zensu:tdd run wedges at the review
// step") that must not fire for an unrelated agent, and a wildcard spelling is
// the same unverified host grammar moved onto the loud side. Reporting that the
// entry could not be JUDGED keeps the fall-through from ending at the allow
// remedy, without asserting what the entry does.
// Returns WHICH arm matched, never a bare boolean, because the two arms support
// different claims and the caller renders a sentence about the user's file.
//   'named'  — the entry really does contain REVIEWER_AGENT, in an unverified spelling
//   'shaped' — the entry scopes the Agent/Task TOOL and names some OTHER agent, or none
//   ''       — no entry in the list is relevant
// Collapsing these back into one boolean is what produced a row telling a user with
// `deny: ["Agent(docs-writer)"]` that the entry names zensu:code-reviewer. It does not,
// and warnCount then denies that user a green summary forever.
function namesReviewerSpawn(rules) {
  if (!Array.isArray(rules)) return '';
  // Scan the WHOLE list. Returning at the first match made position decide instead of
  // strength: `['Agent(*)', 'Agent(zensu:code-reviewer-canary)']` answered 'shaped' and
  // the report then told the user their entry names a different agent, which is false of
  // element 1. The cross-list reduction below could not repair it, because both lists are
  // already collapsed by the time it runs. 'named' still short-circuits — nothing outranks
  // it — so only the weaker verdict pays for the full scan.
  var shaped = false;
  for (var i = 0; i < rules.length; i++) {
    if (typeof rules[i] !== 'string') continue;
    var r = rules[i].trim();
    // Defensive and UNREACHABLE from the only caller, which reaches this
    // predicate solely after matchesDenyOrAskRule rejected the same list with the
    // same trim and the same spelling test. Kept so the predicate is correct
    // standing alone, not because a fixture covers it — and it now costs one
    // clause through the shared test rather than a hand-maintained copy.
    if (isVerifiedSpelling(r)) continue;
    if (r.indexOf(REVIEWER_AGENT) !== -1) return 'named';
    // Any OTHER `Agent(...)` rule. Without this the predicate did not do what the
    // comment above claims: a wildcard spelling names no agent, so it matched
    // neither this nor matchesDenyOrAskRule, and the ladder fell through — to the
    // wrong remedy in auto mode and to complete SILENCE in every other mode, for an
    // entry that plausibly blocks every run. `Agent(*)` is valid host grammar, so
    // that was a reachable green report, not a hypothetical. It stays on the
    // low-claim side deliberately: this row says only that the entry cannot be
    // judged, which is the fail-safe direction. Never move it into
    // matchesDenyOrAskRule — that row asserts every /zensu:tdd run wedges.
    if (r.indexOf('Agent(') === 0) { shaped = true; continue; }
    // The same treatment for the OTHER tool name the host uses for this spawn.
    // reviewer-spawn-denial-v1.js exports SPAWN_TOOL_NAMES = ['Agent', 'Task'], so
    // this tree's own code already treats `Task` as a name a reviewer spawn travels
    // under. Before this, `Task(zensu:code-reviewer)` matched by substring while a
    // bare `Task` matched nothing — an inconsistency by accident rather than by
    // decision. PORT NOTE, and it is why this stays on the low-claim side: whether
    // `Task` is an accepted permission-RULE spelling is NOT verified against
    // SETTINGS_SOURCE_BUILD. Exact equality plus a `Task(` prefix, so an unrelated
    // tool such as `TaskRunner(build)` is not swept in.
    if (r === 'Task' || r.indexOf('Task(') === 0) { shaped = true; }
  }
  return shaped ? 'shaped' : '';
}
// 'named' outranks 'shaped' across the two lists: a list holding an entry that really
// does name the reviewer must not be described by the weaker sentence just because the
// other list was scanned first.
function reviewerSpawnMention(deny, ask) {
  var a = namesReviewerSpawn(deny);
  var b = namesReviewerSpawn(ask);
  if (a === 'named' || b === 'named') return 'named';
  if (a === 'shaped' || b === 'shaped') return 'shaped';
  return '';
}
// settingsShape vets deny/ask as ARRAYS; this vets their ELEMENTS. Without it the
// original defect stayed open one level deeper: both predicates above skip a
// non-string, so `deny: [{"tool":"Agent"}]` read as "no deny rules" and the ladder
// fell through to the exposure row's allow remedy while an unevaluated deny sat in
// the same file — the confidently WRONG remedy the fatal/deferred split exists to
// remove. Deliberately NOT fatal and deliberately evaluated AFTER the two predicates:
// a list that also holds a matching string must still fire the deny row.
function hasUnreadableEntry(rules) {
  if (!Array.isArray(rules)) return false;
  for (var i = 0; i < rules.length; i++) {
    if (typeof rules[i] !== 'string') return true;
  }
  return false;
}
// One remedy tail, two causes. They are kept apart on purpose: an unverified SPELLING
// is a string this check read and declined to judge, while an unreadable ENTRY names
// nothing at all — telling the user the second is the first would be a false statement
// about their file, which is the failure class this whole feature exists to avoid.
function unjudgeableRow(cause) {
  line(WARN, 'permissions: ' + cause + ' Read the entry yourself before adding any '
    + 'permissions.allow rule: deny and ask are both evaluated before allow, so an entry that does '
    + 'block would make an allow rule take no effect. You have to apply this yourself — '
    + SELF_PERMISSION_BAR + '.');
}
// A FOURTH predicate, and deliberately not another spelling of the other three:
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
// The ladder proper. It emits a row when it has something to say and stays silent
// otherwise; permissionExposureRows below turns that silence into a statement, so no
// branch here has to remember to close itself out.
function permissionExposureLadder(file) {
  var r = readSettingsJson(file);
  if (r.missing) return;
  if (!r.ok) {
    line(WARN, 'permissions: ~/.claude/settings.json ' + (r.io ? ('could not be read — ' + r.err) : 'could not be parsed')
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
  if (matchesDenyOrAskRule(perms.deny)) {
    line(WARN, 'permissions: a permissions.deny entry in ~/.claude/settings.json matches the '
      + REVIEWER_AGENT + ' spawn. Deny is evaluated before ask and allow, so the review chain can never '
      + 'spawn its reviewer and every /zensu:tdd run wedges at the review step. Remove that entry '
      // Self-contained on purpose. This used to point at "the refused-spawn row
      // below", but that row renders only when a refusal note exists, so the
      // reference dangled in the ordinary case. Naming the RULE instead is true
      // whether or not the other row prints.
      + 'yourself if the block was not intended: while it stands, adding a permissions.allow rule for '
      + 'this spawn changes nothing — including the "Agent(' + REVIEWER_AGENT + ')" rule that a '
      + 'refused-spawn report recommends. You have to apply this yourself — ' + SELF_PERMISSION_BAR + '.');
    return;
  }
  if (matchesDenyOrAskRule(perms.ask)) {
    line(WARN, 'permissions: a permissions.ask entry in ~/.claude/settings.json matches the '
      + REVIEWER_AGENT + ' spawn. Ask is evaluated before allow, so the spawn prompts every time and a '
      + 'turn that cannot answer the prompt refuses it. Move the rule to permissions.allow yourself if '
      + 'you meant to grant it.' + DENY_FIRST_CAVEAT
      + ' You have to apply this yourself — ' + SELF_PERMISSION_BAR + '.');
    return;
  }
  // Before the fall-through: an entry that plainly names this spawn but is not a
  // spelling this check verified. Saying nothing here would drop straight to the
  // exposure row, which recommends an allow rule that such an entry may outrank.
  var mention = reviewerSpawnMention(perms.deny, perms.ask);
  if (mention === 'named') {
    unjudgeableRow('a permissions.deny or permissions.ask entry in ~/.claude/settings.json names '
      + REVIEWER_AGENT + ' in a spelling this check has not verified, so it cannot judge whether '
      + 'that entry blocks the spawn.');
    return;
  }
  // The weaker claim, and the only one the shape-only arms can support. Such an entry
  // names a DIFFERENT agent, or none at all — it is reported because an Agent/Task rule
  // of unknown reach may still outrank the allow rule the exposure row recommends, not
  // because it was found to mention this spawn.
  if (mention === 'shaped') {
    unjudgeableRow('a permissions.deny or permissions.ask entry in ~/.claude/settings.json scopes '
      + 'the Agent or Task tool in a spelling this check has not verified, so it cannot judge '
      + 'whether that entry blocks the ' + REVIEWER_AGENT + ' spawn.');
    return;
  }
  // Evaluated AFTER the spelling predicate so a list holding a readable, matching
  // string still reaches the row that names its real cause.
  if (hasUnreadableEntry(perms.deny) || hasUnreadableEntry(perms.ask)) {
    unjudgeableRow('permissions.deny or permissions.ask in ~/.claude/settings.json contains an '
      + 'entry this check cannot read — it is not a string, so this check cannot judge whether it '
      + 'blocks the spawn.');
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
  var granted = matchesAllowRule(perms.allow);
  // Each row is now gated by the carrier it actually depends on, and NEITHER branch
  // returns. The old single `deferred` set plus an early `return granted` produced two
  // suppressions, and exactly ONE of them was lifted here: a malformed `autoMode.allow`
  // no longer deletes the exposure row. The other one STAYS, by decision — a real grant
  // still suppresses the autoMode prose correction below, because that row exists to
  // correct a user who mistook prose guidance for a grant, and a user who holds the real
  // grant has nothing to correct. P1au3 pins that suppression as intended; do not
  // "restore" it. The conditions are spelled out per row, so adding a row cannot silently
  // inherit another row's suppression.
  //
  // What this still does NOT say, unchanged: a deny in a spelling this check declined
  // to judge can sit in the same file and outrank a grant, and no row reports that —
  // the deny-first caveat is not reachable from a granted state.
  if (shape.deferredExposure) {
    deferredShapeRow(shape.deferredExposure, 'auto-mode exposure of the reviewer spawn');
  } else if (!granted) {
    if (mode === 'auto') {
      line(WARN, 'permissions: permission mode "auto" is set in ~/.claude/settings.json and no '
        + 'permissions.allow entry there spells either "Agent(' + REVIEWER_AGENT + ')" or the bare "Agent" '
        + '— the auto-mode classifier can refuse the reviewer spawn, and a refused spawn leaves the review '
        + 'chain with no review it can close on. Add "Agent(' + REVIEWER_AGENT + ')" to permissions.allow in '
        + '~/.claude/settings.json yourself; ' + SELF_PERMISSION_BAR + '.'
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
  //
  // Its OWN deferred carrier comes first: when `autoMode.allow` is unreadable this row
  // cannot make its claim about it, and saying nothing there would be the silence this
  // check exists to remove. It is deliberately not gated on `granted` — the shape of
  // the file is a fact regardless of who holds which rule.
  if (shape.deferredAutoMode) {
    deferredShapeRow(shape.deferredAutoMode, 'autoMode.allow guidance row');
  } else if (!granted && mentionsReviewerAgent(autoMode.allow)) {
    line(WARN, 'permissions: an autoMode.allow entry in ~/.claude/settings.json mentions '
      + REVIEWER_AGENT + ', but autoMode.allow carries classifier guidance in prose — it is not a '
      + 'permission rule and does not grant the spawn. Only a permissions.allow entry spelling '
      + '"Agent(' + REVIEWER_AGENT + ')" or the bare "Agent" does.');
  }
}
// The check speaks on EVERY path. Silence used to be its default verdict and the one
// verdict it could not qualify: the not-an-all-clear doctrine hung entirely off rows
// that printed, so the ordinary reader saw nothing at all and — because a proactive
// permission check is advertised in the skill frontmatter — read that as "checked, and
// fine". Three prose restatements existed to compensate for what no artifact carried.
//
// Counting rows rather than threading a flag through the ladder's exits is
// deliberate: a branch added later cannot forget to close itself out, and the ladder
// keeps its early returns.
// Containment. The outer handler around main() discards the ENTIRE four-block report on
// any throw and still exits 0, so an escape from here would cost the hook-integrity
// rows, the session-state rows and the refused-spawn row — for a user who ran the
// doctor precisely because something is already broken, and with no trace that anything
// was lost. Every other risky reader in this file is individually contained; this is the
// newest and least-exercised code in it. No reachable throw is known: the reader wraps
// its own I/O and parse, and every predicate is guarded by Array.isArray plus a typeof
// test. This buys the cost of being wrong once, and it costs one row.
function permissionExposureRows() {
  try {
    permissionExposureRowsInner();
  } catch (e) {
    line(WARN, 'permissions: the reviewer-spawn permission check failed to run. That is a missing '
      + 'check, not an all-clear.');
  }
}
function permissionExposureRowsInner() {
  var file = claudeSettingsFile();
  if (!file) {
    // NOT the clean row. The check could not even locate its input, and an unset HOME
    // reported as "no exposure found" would be the exact false all-clear this change
    // exists to remove.
    line(WARN, 'permissions: HOME is not set, so ~/.claude/settings.json could not be located; '
      + 'the reviewer-spawn permission check did not run. That is a missing check, not an all-clear.');
    return;
  }
  var before = out.length;
  permissionExposureLadder(file);
  if (out.length !== before) return;
  line(OK, 'permissions: no reviewer-spawn exposure found in ~/.claude/settings.json — that is the '
    + 'only settings source this check reads, and the permission mode can be active for a session '
    + 'without being written there.');
}

function configBlock() {
  block('Config');
  var anyPresent = false;
  // KNOWN GAP, recorded rather than fixed: the axis here is PRESENT-ness, not effectiveness.
  // When BOTH defaults are present and both degrade to {} — both malformed, or one malformed and
  // one unreadable — presentCount is 2, so each row says "the other config source still applies"
  // while defaults actually apply. It is not a regression: the earlier candidate-count predicate
  // was wrong in that case too, so this strictly reduces the set of wrong answers. It is also
  // self-limiting, because the doctor prints a failure row for each broken file and the user sees
  // both faults. Closing it means counting entries that are present AND not `loaderFallback`,
  // which needs its own fixture; deliberately out of scope here.
  //
  // Read ONCE, then decide. `configFiles()` returns candidate PATHS, and gating the clause on
  // how many candidates exist was the mirror of the bug it replaced: both defaults are always
  // candidates when HOME and CLAUDE_PROJECT_DIR are set, so a lone broken project config
  // promised an "other config source" the report never prints a row for — while defaults
  // really did apply. PRESENT-ness decides it. Reading once also matters: a second readJson
  // pass would double the non-blocking opens the FIFO hardening exists for.
  var cfgReads = configFiles().map(function (f) { return { file: f, r: readJson(f) }; });
  var presentCount = cfgReads.filter(function (x) { return !x.r.missing; }).length;
  var soleSource = presentCount === 1;
  cfgReads.forEach(function (entry) {
    var f = entry.file;
    var r = entry.r;
    if (r.missing) return;
    anyPresent = true;
    if (!r.ok) {
      // The trailing clause asserts what the LOADER does, so it may only be said where that
      // is true. Every io class except the size cap makes rd() return {} — but the cap is the
      // DOCTOR's own memory bound and the loader has none, so an oversized well-formed config
      // is read and applied by every hook while this row would have claimed it was ignored.
      // Report the limit of the check there instead of a verdict about the loader.
      var capped = r.io && r.cap === true;
      if (capped) {
        // Everything here is knowable from the fstat alone. The doctor did NOT parse this
        // file, so it cannot say the loader applies it — an oversized MALFORMED config still
        // makes rd() return {}. What IS knowable: the loader has no size limit, so the file
        // is not skipped for its SIZE. Whether it parses is outside what this check saw.
        line(WARN, 'config: ' + f + ' is ' + r.err + ' — this check declined to read it and '
          + 'cannot judge it; the config loader has no size limit, so the file is not skipped '
          + 'for its size, but whether it parses is unknown to this check');
      } else {
        // The trailing clause is a LOADER verdict and is appended only where it holds.
        // `unreadable (<errno>)` and the parse class both make rd() return {}. A FIFO does
        // not: rd()'s blocking readFileSync would HANG rather than fall back — the very hazard
        // this reader's non-blocking open exists for. A short read is the doctor's own
        // truncation and says nothing about what the loader gets. Those two get the
        // check-limited wording instead.
        var loaderFallsBack = r.loaderFallback === true;
        if (loaderFallsBack) {
          // "the whole file is ignored" is always true here. "defaults apply" is NOT: the
          // loader MERGES a global config with a project one, so a broken overlay leaves the
          // other source's values in force. Say the second half only when this file is the
          // sole source — the ZENSU_CONFIG override, or a single-file install.
          line(BAD, 'config: ' + (r.io ? (f + ' is ' + r.err) : ('invalid JSON in ' + f))
            + (soleSource
              ? ' (the whole file is ignored, defaults apply)'
              : ' (the whole file is ignored; the other config source still applies)'));
        } else {
          line(BAD, 'config: ' + f + ' is ' + r.err + ' — this check could not read it and '
            + 'cannot say what the config loader gets from it');
        }
      }
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
    // The loop alone never made the comment above true: it breaks on a zero-length read
    // and the partial buffer was then parsed, which is exactly the "did not write it" row
    // the comment calls a defect. The guard is what closes it, and it must answer null
    // rather than a distinct sentinel — this reader's contract is "a note this plugin can
    // vouch for, or nothing", and an incomplete read cannot be vouched for.
    if (read !== st.size) return null;
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
      + 'You have to apply this yourself — ' + SELF_PERMISSION_BAR + '. '
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
