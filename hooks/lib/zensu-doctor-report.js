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
//   HOME, CLAUDE_PROJECT_DIR config-resolution roots. Session state is NOT among
//                            them: that block anchors on ZDOC_SESSION_PROJECT_ROOT
//                            under a bound verdict and falls back to
//                            CLAUDE_PROJECT_DIR only without one — see
//                            stateProjectRoot. The Config block and ZDOC_TTL_HOURS
//                            stay harness-anchored, so a session whose two roots
//                            differ reads its config overlay and its TTL from one
//                            and its workflow documents from the other. HOME is
//                            also the ONLY root the reviewer-spawn permission
//                            check reads (HOME/.claude/settings.json) — see
//                            permissionExposureRows below for why no second
//                            settings file is opened or named.
//   ZDOC_NODE/ZENSU/PLAYWRIGHT            tool probe results from the wrapper/skill
//   ZDOC_FORGE_PROVIDER/CLI/STATE/EDITION forge detection from the VCS driver
//   ZDOC_TTL_HOURS           pending-review TTL from the canonical getter
//   ZDOC_IMPL_STOP_NUDGE_AFTER  implementing-turns bound from the
//                            canonical getter; blank falls back, 0 disables the row
//   ZDOC_NOW_MS              clock override for deterministic tests
//   ZDOC_BINDING             the wrapper's binding verdict (bound / unbound /
//                            orphaned-project-root / incompatible-runtime /
//                            unavailable / unknown). Read by bindingLine for its
//                            own row AND by currentSessionKey, which refuses a
//                            session key that arrives under any other verdict.
//   ZDOC_SESSION_KEY         this session's own Session Control key, non-empty
//                            only when the wrapper's binding verdict is bound.
//                            The ONLY thing that tells a chain this session owns
//                            from one it does not; empty, malformed, or present
//                            under a non-bound ZDOC_BINDING means chainRows
//                            declines that row rather than reading every chain
//                            as foreign.
//   ZDOC_SESSION_PROJECT_ROOT the RECORD's own project anchor, from the same
//                            bind as ZDOC_SESSION_KEY, and the root the WHOLE
//                            Session state block reads when it is present under a
//                            bound verdict — every writer anchors there, so the
//                            harness value is the fallback and not the authority.
//
//   PORT NOTE — the foreign-chain row is FOUR halves and a port that takes three
//   gets a row that silently never renders: the wrapper must export both values
//   above out of its own bind AND clear both unconditionally rather than
//   :=-seeding them like every other ZDOC_*, the renderer must anchor the state block on the
//   recorded root and keep the predicate, the chain-shape OWNER must export
//   INERT_SHAPES, and the operator docs must carry the diagnose-only limit. Its premise is host-coupled: it presumes a
//   host that can mint a NEW session id mid-conversation while carrying the
//   history over. A host that cannot do that has nothing to diagnose here.

'use strict';
var fs = require('fs');
var path = require('path');

var OK = '✅';
var WARN = '⚠️';
var BAD = '❌';

// Mirror of hooks/lib/zensu-config.sh zensu_pending_review_ttl_hours: the wrapper
// passes the canonical value via ZDOC_TTL_HOURS; these apply only to a direct
// (test/no-wrapper) invocation and must stay in lockstep with that getter.
// PINNED by C57 in tests/structure/test-impl-stop-counter.sh, which derives both sides —
// these two constants against the getter's own operands, through `getter_operand`. The pair
// declared itself a mirror in prose and was pinned by nothing until the three duplicated
// getters collapsed onto one call shape that a single extractor could read.
var TTL_HOURS_FALLBACK = 6;
var TTL_HOURS_MAX = 8760;
// Mirror of hooks/lib/zensu-config.sh zensu_impl_stop_nudge_after (default 12,
// bounds 0..999999): the wrapper passes the canonical value via
// ZDOC_IMPL_STOP_NUDGE_AFTER; these apply only to a direct (test/no-wrapper)
// invocation and must stay in lockstep with that getter.
var IMPL_STOP_NUDGE_FALLBACK = 12;
// STRICTLY BELOW the counter's own storage ceiling. `_tdd_increment_counter_critical`
// refuses `current >= 1000000` before incrementing, so a configured threshold of
// exactly 1000000 could be reached once and never again — the notice firing a single
// time while this row kept rendering off the frozen value.
// PINNED, and by three checks with three different jobs: C14a and C31a compare the
// DEFAULT pair (`IMPL_STOP_NUDGE_FALLBACK` against the getter's `12`), and C31 compares
// the MAX pair. Each derives its side from source rather than restating a number, so
// neither literal can be edited alone. `C31` names one comparison throughout this block.
//
// WHAT it derives them from moved, and the old spelling is named here because a
// comment that sends a maintainer after bytes the code no longer carries is its own
// defect. The three duplicated getters collapsed onto `_zensu_config_bounded_int`, so
// `zensu_impl_stop_nudge_after` has no function body of its own any more — the bound
// comparison lives in the shared helper as `n<=Number(process.argv[4])` and the value
// travels as an operand of the one-line
// `_zensu_config_bounded_int implStopNudgeAfter 12 0 999999` call.
//
// C31 and C31a read that call through the single `getter_operand` extraction, and they read
// DIFFERENT operands: C31 takes the captured max (`999999`), C31a the captured default
// (`12`). C14a compares the same default by RUNNING the getter in a subshell rather than
// extracting an operand, which is why it is a separate check and not a third extraction.
// Naming one operand for all of them was wrong in the first revision of this sentence, and
// naming C29 among them was wrong in the second — C29 is a behavioural fallback check.
// The extraction is anchored on the getter's own definition line, so an unrelated bound
// elsewhere in that file cannot satisfy it.
var IMPL_STOP_NUDGE_MAX = 999999;
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

  var v = env.ZDOC_VERIFY || '';
  var vr = env.ZDOC_VERIFY_REASON || '';
  if (v === 'policy') line(OK, 'verify-feature: environment policy active — the parent-environment navigation policy governs every browser origin this session');
  else if (v === 'consent') line(OK, 'verify-feature: consent mode ready — no parent policy; the browser asks you per origin through the permission prompt, and a runtime recipe is present');
  else if (v === 'consent-no-recipe') line(WARN, 'verify-feature: consent mode ready, no runtime recipe — run /zensu:verify-feature --setup to write .zensu/runtime.yaml, or pass --attach=<loopback-origin> for an app you already run');
  else if (v === 'unavailable') line(BAD, 'verify-feature: cannot start (' + (vr || 'reason unknown') + ') — the consent hook pair, its module and the broker must ship together; reinstall the plugin or launch Claude Code with the parent-environment policy');
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

// Two hooks inject a rule read at RUN TIME from a one-line marker block under docs/,
// and both fail silent on every input fault: an absent, symlinked, oversized or
// malformed file exits 0 with no output. On an installed tree no suite runs, so an
// operator error — a hand-edited or re-wrapped block, a symlinked docs/, a partial
// install — persists indefinitely and is byte-identical to a healthy install from
// outside. `hooks wiring` above reports that the SCRIPT is on disk; it never looks at
// the data file that script depends on, so it goes green either way. That green is
// what makes this row necessary rather than merely nice.
//
// The marker parse is NOT re-implemented here. The row calls the same
// hooks/lib/rule-block-v1.js the hooks call, so the diagnostic cannot disagree with
// the thing it diagnoses — a hand-copied parser would report on bytes the hook would
// have refused. The require is lazy and guarded for the reason reviewerDenialRows
// states: a load fault costs this row, not the whole report.
var RULE_CARRIERS = [
  {
    id: 'best-solution-first',
    doc: 'docs/best-solution-first.md',
    open: '<!-- zensu:best-solution-first -->',
    close: '<!-- /zensu:best-solution-first -->',
    flag: 'bestSolutionFirst',
  },
  {
    id: 'evidence-discipline',
    doc: 'docs/evidence-discipline.md',
    open: '<!-- zensu:evidence-discipline -->',
    close: '<!-- /zensu:evidence-discipline -->',
    flag: null,
  },
];

// Every refusal the reader can name, worded as a remedy rather than as a code. An
// unknown reason renders as unknown rather than as health: a reason added to the
// module and not here must never read as "fine".
var RULE_REASON_TEXT = {
  'not-a-file': 'is not a regular file — a symlink or a directory, which the reader refuses',
  swapped: 'was replaced between the check and the read',
  'file-too-large': "exceeds the reader's file-size ceiling",
  'short-read': 'could not be read completely',
  unreadable: 'is absent or unreadable',
  'no-open-marker': 'has no opening marker',
  'no-close-marker': 'does not carry the block as exactly one line between the markers',
  'empty-block': 'has an empty block between the markers',
  'block-too-large': 'carries a block past the injection size ceiling',
};

// Precedence follows configFiles(), exactly as reviewerSpawnCheckDisabled documents:
// the project config is read last and wins over the global one, in both directions.
function hookFlagDisabled(cfgReads, key) {
  var disabled = false;
  cfgReads.forEach(function (entry) {
    var data = entry.r && entry.r.ok ? entry.r.data : null;
    if (!data || typeof data !== 'object') return;
    var hooks = data.hooks;
    if (!hooks || typeof hooks !== 'object') return;
    if (hooks[key] === false) disabled = true;
    else if (hooks[key] === true) disabled = false;
  });
  return disabled;
}

function ruleCarrierRows(cfgReads) {
  var mod = null;
  try {
    mod = require(path.join(pluginDir(), 'hooks', 'lib', 'rule-block-v1.js'));
  } catch (e) {
    line(WARN, 'rule carriers: hooks/lib/rule-block-v1.js could not be loaded ('
      + String((e && e.message) || e) + ') — carrier health was NOT checked');
    return;
  }
  if (typeof mod.readRuleBlock !== 'function') {
    line(WARN, 'rule carriers: hooks/lib/rule-block-v1.js exports no readRuleBlock — carrier health was NOT checked');
    return;
  }
  RULE_CARRIERS.forEach(function (c) {
    var out = null;
    try {
      out = mod.readRuleBlock(path.join(pluginDir(), c.doc), c.open, c.close);
    } catch (e) {
      line(WARN, 'rule carriers: ' + c.id + ' could not be checked ('
        + String((e && e.message) || e) + ')');
      return;
    }
    if (out && out.block) {
      if (c.flag && hookFlagDisabled(cfgReads, c.flag)) {
        line(WARN, 'rule carriers: ' + c.id + ' block is intact (' + out.block.length
          + ' chars) but hooks.' + c.flag + ' is false — the rule is not injected');
      } else {
        line(OK, 'rule carriers: ' + c.id + ' block is intact (' + out.block.length + ' chars)');
      }
      return;
    }
    var known = Object.prototype.hasOwnProperty.call(RULE_REASON_TEXT, String(out && out.reason));
    var why = known
      ? RULE_REASON_TEXT[out.reason]
      : 'was refused for an unrecognized reason (' + String(out && out.reason) + ')';
    line(BAD, 'rule carriers: ' + c.id + ' is NOT injecting — ' + c.doc + ' ' + why
      + '. The hook exits 0 silently, so nothing else reports this.');
  });
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
// These BUILD text and no longer emit it. Every row this check can produce is reached
// through ROW_TEXT below, so the roster of rows is a table a reader can enumerate rather
// than a set of emission points scattered through a branch ladder.
function shapeRowText(err) {
  return 'permissions: ~/.claude/settings.json has a shape this check cannot judge — ' + err
    + '; the reviewer-spawn permission check did not run. That is a missing check, not an all-clear.';
}
function deferredShapeRowText(err, scope) {
  return 'permissions: ~/.claude/settings.json has a shape this check cannot judge — ' + err
    + '; the ' + scope + ' could not be determined. That is a missing part of the check, not an '
    + 'all-clear.';
}
// Reused verbatim by the ask row, the exposure row and the granted exposure row — THREE
// consumers since the reviewer-spawn grant landed. Its second clause is now the
// constant DENY_OUTRANKS below, so the two IN-FILE copies — this caveat and the
// reactive row — SHARE one source instead of being byte-identical by hand. That was
// the remaining defect in this class: a shared constant sitting beside an unconsumed
// copy is worse than either honest duplication or one source, because a reader who
// rewords the constant reasonably believes both rows changed. They do now.
//
// It still shares that clause with THREE copies this file cannot reach: DENIAL_REMEDY
// in hooks/stop-chain-enforcer.sh, the refused-spawn bullet in skills/doctor/SKILL.md,
// and the DENY row here, which states the same precedence in its own words rather than
// with this clause. Each states the same deny-before-allow precedence.
// `unjudgeableRow` deliberately does NOT reuse this constant: it tells the reader
// to go and READ the entry, while this text tells them to REMOVE a deny, so
// pasting it there would give the wrong instruction.
// EVERY remaining member is machine-held, and the pins work precisely BECAUSE the
// clause is shared verbatim rather than paraphrased: DENY_OUTRANKS reaches the report
// through both in-file rows and is matched by P1be and P1qr; the SKILL.md bullets are
// matched by the grep -qF side of those pins and, per REGION, by P1bx; and
// DENIAL_REMEDY is matched by test-stop-enforcer-self-review-routing.sh, which greps
// 'A deny rule outranks an allow rule, so the deny has to go first' — note the CAPITAL
// A, because that copy opens a sentence. A review of this PR read that capital as
// evidence the copy escapes the case-sensitive needles; it does not, it has a needle of
// its own. The DENY row is held by its own clause instead: P1bv and P1bm3 match
// 'Deny is evaluated before ask and allow' literally.
// `unjudgeableRow` deliberately does NOT reuse DENY_OUTRANKS: it tells the reader to go
// and READ the entry, while this text tells them to REMOVE a deny, so pasting it there
// would give the wrong instruction. It is the one member whose own sentence no grep
// matches — check it by hand after any reword.
//
// Both allow-ward rows recommend an allow rule, and such a rule takes no effect
// behind a deny this check could not see or could not judge — a wildcard
// spelling, a deny in a settings source this file never opens. Saying so costs
// one clause and is true regardless of spelling, which is why it is preferred
// over guessing at the host's rule grammar.
var DENY_OUTRANKS = 'a deny rule outranks an allow rule, so the deny has to go first';
var DENY_FIRST_CAVEAT = ' Remove any deny rule that names the Agent tool first — ' + DENY_OUTRANKS + '.';
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
// The deny-first class gained a SEVENTH member outside this file:
// `REVIEWER_SPAWN_DENY_FIRST` in `hooks/stop-chain-enforcer.sh`, interpolated into the
// implementing-turns refused-spawn notice and pinned by `C27`. Named here because the
// census ABOVE — beside `DENY_OUTRANKS` — enumerates the copies this file cannot reach,
// and it was one short.
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
function unjudgeableRowText(cause) {
  return 'permissions: ' + cause + ' Read the entry yourself before adding any '
    + 'permissions.allow rule: deny and ask are both evaluated before allow, so an entry that does '
    + 'block would make an allow rule take no effect. You have to apply this yourself — '
    + SELF_PERMISSION_BAR + '.';
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
// The DECISION, and it holds no row text at all. It answers WHICH verdicts hold, in
// emission order; the caller turns each into a row through ROW_TEXT. That split is what
// removed the navigation comments this code used to need: the fact that the auto-mode
// verdict and the autoMode.allow verdict can BOTH hold is now visible in the return type
// — the list simply has two members — instead of being asserted in prose above an `else`,
// and the inventory of early exits is the run of single-member returns you can read off
// the page rather than a paragraph enumerating them.
function classifyPermissionExposure(shape, grantActive) {
  if (!shape.ok) {
    // NOT "could not be read": this verdict is reached only after the file was read and
    // parsed successfully, and naming the wrong cause sends the user hunting for a
    // filesystem problem that does not exist.
    return [{ kind: 'shape', err: shape.err }];
  }
  var perms = shape.permissions;
  var mode = typeof perms.defaultMode === 'string' ? perms.defaultMode : '';
  // Claude Code evaluates deny, then ask, then allow, and the first match wins —
  // so a deny is reported even when an allow rule for the same spawn is present,
  // and neither depends on the permission mode.
  if (matchesDenyOrAskRule(perms.deny)) return [{ kind: 'deny' }];
  if (matchesDenyOrAskRule(perms.ask)) return [{ kind: 'ask' }];
  // Before the fall-through: an entry that plainly names this spawn but is not a spelling
  // this check verified. Saying nothing here would drop straight to the exposure verdict,
  // which recommends an allow rule that such an entry may outrank. The weaker 'shaped'
  // verdict names a DIFFERENT agent, or none — it is reported because an Agent/Task rule
  // of unknown reach may still outrank that allow rule, not because it was found to
  // mention this spawn.
  var mention = reviewerSpawnMention(perms.deny, perms.ask);
  if (mention === 'named') return [{ kind: 'named' }];
  if (mention === 'shaped') return [{ kind: 'shaped' }];
  // AFTER the spelling predicate, so a list holding a readable, matching string still
  // reaches the verdict that names its real cause.
  if (hasUnreadableEntry(perms.deny) || hasUnreadableEntry(perms.ask)) return [{ kind: 'unreadable' }];
  // Resolved BEFORE the deferred branches, not inside them. A user who already holds the
  // rule must not be told to add it, and that has to hold on a deferred failure too. Safe
  // even when `permissions.allow` is itself the malformed key: the predicate opens with an
  // Array.isArray guard and simply answers false.
  var granted = matchesAllowRule(perms.allow);
  var verdicts = [];
  // TWO independent carriers, and each verdict is gated by the one its own claim rests on.
  // That is why a malformed `autoMode.allow` no longer deletes the exposure verdict. The
  // OTHER suppression stays by decision: a real grant still suppresses the autoMode prose
  // correction, because that row exists to correct a user who mistook prose guidance for a
  // grant, and a user holding the real grant has nothing to correct. P1au3 pins that
  // suppression as intended; do not "restore" it.
  if (shape.deferredExposure) {
    verdicts.push({ kind: 'deferred', err: shape.deferredExposure,
      scope: 'auto-mode exposure of the reviewer spawn' });
  } else if (!granted && mode === 'auto') {
    // The plugin's own PreToolUse grant admits the reviewer spawn before the classifier is
    // consulted, so telling this user to add a permissions.allow rule for it would be
    // advice for a problem they no longer have. It is a DIFFERENT verdict, not a dropped
    // one: the mode is still auto, every OTHER spawn is still classifier-subject, and a
    // deny or ask rule still outranks the grant.
    verdicts.push({ kind: grantActive ? 'auto-exposure-granted' : 'auto-exposure' });
  }
  // Its OWN deferred carrier comes first: when `autoMode.allow` is unreadable this verdict
  // cannot make its claim about it, and saying nothing there would be the silence this
  // check exists to remove. Deliberately not gated on `granted` — the shape of the file is
  // a fact regardless of who holds which rule.
  if (shape.deferredAutoMode) {
    verdicts.push({ kind: 'deferred', err: shape.deferredAutoMode,
      scope: 'autoMode.allow guidance row' });
  } else if (!granted && !grantActive && mentionsReviewerAgent(shape.autoMode.allow)) {
    // `!grantActive` for the same reason `!granted` is here: this row exists to correct a
    // user who mistook prose guidance for a grant, and a user who already HOLDS a grant has
    // nothing to correct. Without the conjunct both this row and `auto-exposure-granted`
    // fire together, and this one's closing sentence — only a permissions.allow entry
    // grants the spawn — flatly contradicts the other. It is also a WARN, so it would deny
    // a green summary for an exposure the grant already covers.
    verdicts.push({ kind: 'automode-prose' });
  }
  // What this still does NOT say, unchanged: a deny in a spelling this check declined to
  // judge can sit in the same file and outrank a grant, and no verdict reports that — the
  // deny-first caveat is not reachable from a granted state.
  return verdicts;
}
// The TEXT, keyed by verdict kind, and the only place a row is worded. Adding a row means
// adding a kind here and returning it above; neither half can grow a branch the other does
// not know about.
//
// THREE maps now, not two, and the third has the OPPOSITE totality contract: `ROW_LEVEL`
// below is consumed as `ROW_LEVEL[v.kind] || WARN`, so it MAY silently not know about a
// kind and that omission means WARN. A kind missing from `ROW_TEXT` throws instead, and the
// throw is swallowed by the wrapper, costing every exposure row. Keep the invariant above
// as stated for `ROW_TEXT`; do not extend it to `ROW_LEVEL`, whose default is deliberate.
var ROW_TEXT = {
  shape: function (v) { return shapeRowText(v.err); },
  deferred: function (v) { return deferredShapeRowText(v.err, v.scope); },
  deny: function () {
    return 'permissions: a permissions.deny entry in ~/.claude/settings.json matches the '
      + REVIEWER_AGENT + ' spawn. Deny is evaluated before ask and allow, so the review chain can never '
      + 'spawn its reviewer and every /zensu:tdd run wedges at the review step. Remove that entry '
      // Self-contained on purpose. This used to point at "the refused-spawn row
      // below", but that row renders only when a refusal note exists, so the
      // reference dangled in the ordinary case. Naming the RULE instead is true
      // whether or not the other row prints.
      + 'yourself if the block was not intended: while it stands, adding a permissions.allow rule for '
      + 'this spawn changes nothing — including the "Agent(' + REVIEWER_AGENT + ')" rule that a '
      + 'refused-spawn report recommends. You have to apply this yourself — ' + SELF_PERMISSION_BAR + '.';
  },
  ask: function () {
    return 'permissions: a permissions.ask entry in ~/.claude/settings.json matches the '
      + REVIEWER_AGENT + ' spawn. Ask is evaluated before allow, so the spawn prompts every time and a '
      + 'turn that cannot answer the prompt refuses it. Move the rule to permissions.allow yourself if '
      + 'you meant to grant it.' + DENY_FIRST_CAVEAT
      + ' You have to apply this yourself — ' + SELF_PERMISSION_BAR + '.';
  },
  named: function () {
    return unjudgeableRowText('a permissions.deny or permissions.ask entry in ~/.claude/settings.json names '
      + REVIEWER_AGENT + ' in a spelling this check has not verified, so it cannot judge whether '
      + 'that entry blocks the spawn.');
  },
  shaped: function () {
    return unjudgeableRowText('a permissions.deny or permissions.ask entry in ~/.claude/settings.json scopes '
      + 'the Agent or Task tool in a spelling this check has not verified, so it cannot judge '
      + 'whether that entry blocks the ' + REVIEWER_AGENT + ' spawn.');
  },
  unreadable: function () {
    return unjudgeableRowText('permissions.deny or permissions.ask in ~/.claude/settings.json contains an '
      + 'entry this check cannot read — it is not a string, so this check cannot judge whether it '
      + 'blocks the spawn.');
  },
  'auto-exposure': function () {
    return 'permissions: permission mode "auto" is set in ~/.claude/settings.json and no '
      + 'permissions.allow entry there spells either "Agent(' + REVIEWER_AGENT + ')" or the bare "Agent" '
      + '— the auto-mode classifier can refuse the reviewer spawn, and a refused spawn leaves the review '
      + 'chain with no review it can close on. Add "Agent(' + REVIEWER_AGENT + ')" to permissions.allow in '
      + '~/.claude/settings.json yourself; ' + SELF_PERMISSION_BAR + '.'
      + DENY_FIRST_CAVEAT
      + ' This row reports an exposure, never a prediction: the classifier decides per session context, and '
      + 'settings sources this check does not read may already grant it. The reverse holds too — the '
      + 'permission mode can be in effect for a session without being written into this file, so the '
      + 'absence of this row is not evidence that auto mode is inactive.';
  },
  // Self-contained: it used to end "the permissions.allow rule named above", which
  // dangles whenever the row above did not print — the same defect the deny row was
  // corrected for. Which verdicts precede it is now read off classifyPermissionExposure
  // rather than restated here.
  'auto-exposure-granted': function () {
    return 'permissions: permission mode "auto" is set in ~/.claude/settings.json and no '
      + 'permissions.allow entry there spells either "Agent(' + REVIEWER_AGENT + ')" or the bare '
      + '"Agent" — but this plugin admits its own confined reviewer spawns through the PreToolUse '
      + 'hook pre-agent-reviewer-allow.sh before the classifier is consulted, so no settings edit is '
      + 'needed for them. This covers the plugin\'s own reviewers only; every other spawn in this '
      + 'session is still classifier-subject.' + DENY_FIRST_CAVEAT;
  },
  'automode-prose': function () {
    return 'permissions: an autoMode.allow entry in ~/.claude/settings.json mentions '
      + REVIEWER_AGENT + ', but autoMode.allow carries classifier guidance in prose — it is not a '
      + 'permission rule and does not grant the spawn. Only a permissions.allow entry spelling '
      + '"Agent(' + REVIEWER_AGENT + ')" or the bare "Agent" does.';
  }
};
// Severity, keyed by the same verdict kind. WARN is the default because every verdict here
// reports something the reader has to act on — except the granted one, which reports that
// the action is already taken and would read as an open problem in a ⚠️ table. A kind
// missing from this map is a warning; only an explicit entry lowers it.
var ROW_LEVEL = {
  'auto-exposure-granted': OK
};
// Read, classify, render — three steps, and the branch ladder lives in exactly one of
// them. It emits when it has something to say and stays silent otherwise;
// permissionExposureRowsInner below turns that silence into a statement, so no branch
// here has to remember to close itself out.
function permissionExposureLadder(file, grantActive) {
  var r = readSettingsJson(file);
  if (r.missing) return;
  if (!r.ok) {
    line(WARN, 'permissions: ~/.claude/settings.json ' + (r.io ? ('could not be read — ' + r.err) : 'could not be parsed')
      + '; the reviewer-spawn permission check did not run. That is a missing check, not an all-clear.');
    return;
  }
  classifyPermissionExposure(settingsShape(r.data), grantActive).forEach(function (v) {
    line(ROW_LEVEL[v.kind] || WARN, ROW_TEXT[v.kind](v));
  });
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
// The OFF-SWITCH, and it is a CONFIG BOOLEAN rather than a path override on purpose.
// claudeSettingsFile above refuses a ZDOC_/ZENSU_ override because an agent-writable
// channel could aim a check ABOUT the agent's own permissions at a file that shows a
// grant. That argument is about INJECTION and it holds; it never answered SUPPRESSION,
// which is a real complaint from a real population: a user whose permissions come from a
// source that OUTRANKS the one file this check reads — managed settings, or the
// project-local carrier docs/configuration.md documents and this file deliberately never
// spells (see claudeSettingsFile; P1bc pins the absence) — with `defaultMode: "auto"` in
// their user file otherwise gets a permanent warning telling them to edit a file that is
// overridden, and no way to silence it. This
// closes that without conceding anything on the injection axis: it suppresses the ROW and
// can never redirect WHICH file is opened.
//
// Disabling does NOT produce silence, and that is the whole design. Silence is the one
// verdict this check cannot qualify — removing it is what the feature is for — so an
// off-switch that simply hid the rows would reintroduce the defect under a config key.
// The check reports that it was switched off instead, and says the row is not an
// all-clear, exactly as every other did-not-run row does.
//
// Strict `=== false`, matching every other boolean this tree reads: a QUOTED "false" does
// NOT disable, and the doctor's own quoted-boolean row is what tells the user why.
// Precedence follows configFiles(): the project config is read last and wins over the
// global one, in both directions, so a project may re-enable what a global config turned
// off. Reads the SAME cfgReads the config block already gathered — a second readJson pass
// would double the non-blocking opens the FIFO hardening exists for.
function reviewerSpawnCheckDisabled(cfgReads) {
  var disabled = false;
  cfgReads.forEach(function (entry) {
    var data = entry.r && entry.r.ok ? entry.r.data : null;
    if (!data || typeof data !== 'object') return;
    var hooks = data.hooks;
    if (!hooks || typeof hooks !== 'object') return;
    if (hooks.reviewerSpawnPermissionCheck === false) disabled = true;
    else if (hooks.reviewerSpawnPermissionCheck === true) disabled = false;
  });
  return disabled;
}
// Same permissive read as reviewerSpawnCheckDisabled, against the OTHER key. Two
// readers rather than one parameterised helper because the two flags govern opposite
// things — one suppresses a diagnostic, this one withdraws a capability grant — and a
// shared reader would invite a caller to pass the wrong key without the name saying so.
// Mirrors `zensu_hook_enabled_strict`, which is what actually enforces this key — NOT
// `zensu_hook_enabled`, and not the merged read. That reader is STICKY and FAIL-CLOSED:
// `false` in ANY candidate file withdraws the grant regardless of precedence, and a
// candidate that is present but unreadable or malformed withdraws it too. Mirroring the
// merge instead was wrong in both directions — a project overlay replacing the `hooks`
// node erased a global `false` here while the hook still granted, and an unreadable file
// read as "not disabled" while the hook declined.
// Three answers, not two. Folding every readJson failure into "disabled" made the only
// renderer of that boolean assert ONE cause — the config key — for a trailing comma the
// user never wrote, which is the failure this file's own doctrine forbids one function
// below. Worse for the SIZE class: readJson caps at CONFIG_MAX_BYTES while the enforcing
// zensu_hook_enabled_strict has no cap, so an oversized well-formed config is read and
// applied by the hook — which GRANTS — while the row claimed the grant was switched off.
// A cap is this reader's own bound, never a verdict about the config.
function reviewerSpawnAutoAllowDisabled(cfgReads) {
  var verdict = false;
  cfgReads.forEach(function (entry) {
    var r = entry.r;
    if (!r || r.missing) return;
    if (!r.ok) {
      // A check-limited failure (this reader's size cap, a non-regular file) establishes
      // nothing about the config — the enforcing reader has neither bound. A genuine parse
      // failure DOES decline there too, so the grant really is not in force; only the
      // reported CAUSE differs from an explicit key.
      raise(r.cap || r.io ? 'unjudgeable' : 'broken');
      return;
    }
    var data = r.data;
    if (!data || typeof data !== 'object' || Array.isArray(data)) { raise('broken'); return; }
    if (data.hooks === undefined) return;
    var hooks = data.hooks;
    if (!hooks || typeof hooks !== 'object' || Array.isArray(hooks)) { raise('broken'); return; }
    if (hooks.reviewerSpawnAutoAllow === false) raise('off');
  });
  return verdict;

  // An explicit key is the most informative answer, then a config that is present but
  // unusable, then a bound this check could not see past. Never let a weaker finding
  // overwrite a stronger one just because it was read later.
  function raise(next) {
    var rank = { unjudgeable: 1, broken: 2, off: 3 };
    if (!verdict || rank[next] > rank[verdict]) verdict = next;
  }
}
// Is the grant hook actually referenced by hooks.json? File presence alone is not the
// grant: an unwired script never runs, and the ✅ row would then assert a capability the
// harness never invokes.
// Three answers, not two. Collapsing "could not read hooks.json" into "not wired" would
// assert a specific cause the parse never established — the failure this file's own
// doctrine forbids one function below. Reads through the hardened `readJson`, whose header
// records the measured FIFO hang that the bare readFileSync used here at first gives up.
// The MATCHER is part of the answer: a hook registered under a matcher that does not test
// true for the spawn tool names is exactly as inert as an unregistered one.
function reviewerSpawnHookWired(root, spawnTools) {
  var r = readJson(path.join(root, 'hooks', 'hooks.json'));
  if (r.missing || !r.ok) return 'unknown';
  var data = r.data;
  if (!data || typeof data !== 'object') return 'unknown';
  var groups = (data.hooks && data.hooks.PreToolUse) || [];
  if (!Array.isArray(groups)) return 'unknown';
  var tools = Array.isArray(spawnTools) && spawnTools.length ? spawnTools : ['Agent', 'Task'];
  var wired = false;
  groups.forEach(function (g) {
    if (!g || !Array.isArray(g.hooks)) return;
    var named = g.hooks.some(function (h) {
      return h && typeof h.command === 'string'
        && h.command.indexOf('pre-agent-reviewer-allow.sh') !== -1;
    });
    if (!named) return;
    var re;
    try { re = new RegExp(typeof g.matcher === 'string' && g.matcher ? g.matcher : '.*'); }
    catch (e) { return; }
    if (tools.every(function (t) { return re.test(t); })) wired = true;
  });
  return wired ? 'wired' : 'unwired';
}
// The grant is a capability the plugin hands ITSELF, so it is reported whether it is on
// or off — a silent grant would be the same undisclosed widening this row exists to make
// visible. The agent list is read from the owning module through a LAZY, guarded require,
// exactly as reviewerDenialRows does: a load fault costs this row, never the whole report.
function reviewerSpawnGrantRows(disabled) {
  var root = pluginDir();
  // Absence of the HOOK means this installation predates the grant feature — there is no
  // grant, nothing to disclose, and the ordinary exposure rows below already give that
  // reader the right advice. Warning there would fire on every older plugin root. The
  // asymmetric case IS worth a row: the hook is installed but its decision module is not,
  // because then the hook loads nothing and silently declines while the reader has every
  // reason to believe the grant is in force.
  // lstat, not stat: pre-agent-reviewer-allow.sh refuses a symlinked decider outright
  // ([ -f ] && [ ! -L ]), so a report that follows links can assert a grant the hook
  // declines on every spawn. A symlinked hook is a BROKEN installation rather than one
  // predating the feature, so it must reach a row instead of the silent return below.
  var hookPath = path.join(root, 'hooks', 'pre-agent-reviewer-allow.sh');
  var hookInstalled = false;
  var hookIsLink = false;
  try {
    var hookStat = fs.lstatSync(hookPath);
    hookIsLink = hookStat.isSymbolicLink();
    hookInstalled = hookStat.isFile() || hookIsLink;
  } catch (e) { hookInstalled = false; }
  if (!hookInstalled) return false;
  if (hookIsLink) {
    line(WARN, 'permissions: hooks/pre-agent-reviewer-allow.sh is a symlink. The hook itself '
      + 'refuses a symlinked decision module and this report holds its own paths to the same '
      + 'standard, so no reviewer-spawn grant is in force. This is a broken installation, not a '
      + 'configuration choice.');
    return false;
  }
  var agents = null;
  var spawnTools = null;
  try {
    var modPath = path.join(root, 'hooks', 'lib', 'reviewer-spawn-allow-v1.js');
    if (!fs.lstatSync(modPath).isFile()) throw new Error('decision module is not a regular file');
    var allow = require(modPath);
    if (Array.isArray(allow.CONFINED_REVIEWER_AGENTS) && allow.CONFINED_REVIEWER_AGENTS.length) {
      agents = allow.CONFINED_REVIEWER_AGENTS.slice();
    }
    if (Array.isArray(allow.SPAWN_TOOL_NAMES) && allow.SPAWN_TOOL_NAMES.length) {
      spawnTools = allow.SPAWN_TOOL_NAMES.slice();
    }
  } catch (e) { agents = null; }
  var wiring = reviewerSpawnHookWired(root, spawnTools);
  if (wiring === 'unknown') {
    line(WARN, 'permissions: hooks/pre-agent-reviewer-allow.sh is installed but hooks/hooks.json '
      + 'could not be read or parsed, so whether the harness invokes it — and therefore whether '
      + 'any reviewer-spawn grant is in force — could not be judged by this check.');
    return false;
  }
  if (wiring === 'unwired') {
    line(WARN, 'permissions: hooks/pre-agent-reviewer-allow.sh is present on disk but hooks/hooks.json '
      + 'does not register it on a PreToolUse matcher covering the spawn tools, so the harness never '
      + 'invokes it for a spawn and no reviewer-spawn grant is in force. This is a broken '
      + 'installation, not a configuration choice.');
    return false;
  }
  if (!agents) {
    // Three distinct causes reach here — the module itself, either of the two siblings it
    // requires, and an empty derived set — so the row names the load rather than asserting
    // which file is absent. Naming the wrong cause is the failure this file's own doctrine
    // forbids one branch above.
    line(WARN, 'permissions: hooks/pre-agent-reviewer-allow.sh is installed but its decision module '
      + 'hooks/lib/reviewer-spawn-allow-v1.js could not be loaded — it, or one of the siblings it '
      + 'requires (reviewer-spawn-denial-v1.js, claude-principal-v1.js), is missing or unreadable, '
      + 'or the set it derives is empty. That hook then declines every spawn and no reviewer-spawn '
      + 'grant is in force. This is a broken installation, not a configuration choice.');
    return false;
  }
  if (disabled === 'unjudgeable') {
    line(WARN, 'permissions: a config source could not be read or parsed within this check\'s own '
      + 'bounds, so whether the reviewer-spawn grant is in force could not be judged. That is a '
      + 'missing check, not a configuration choice: the enforcing reader carries no size limit of '
      + 'its own, so it may well be granting on the same file.');
    return false;
  }
  if (disabled === 'broken') {
    line(WARN, 'permissions: a config source could not be read or parsed, so the enforcing reader '
      + 'declines and no reviewer-spawn grant is in force. That is a broken config file, not a '
      + 'configuration choice — no hooks.reviewerSpawnAutoAllow key was involved. Fix the file to '
      + 'get the grant back.');
    return false;
  }
  if (disabled === 'off') {
    line(WARN, 'permissions: the reviewer-spawn grant is switched off by hooks.reviewerSpawnAutoAllow '
      + 'in .zensu/config.json, so the host permission layer decides every reviewer spawn. Under '
      + 'permission mode "auto" the classifier can refuse one, and a refused spawn leaves the review '
      + 'chain with no review it can close on.');
    return false;
  }
  line(OK, 'permissions: this plugin admits its own read-only reviewer spawns (' + agents.join(', ')
    + ') through the PreToolUse hook pre-agent-reviewer-allow.sh, so the host permission layer — '
    + 'including the auto-mode classifier — is not consulted for them. Each is confined to '
    + 'Read/Grep/Glob by its agent frontmatter, and the grant covers only these plugin-scoped names. '
    + 'It admits the whole spawn CALL, not only the identity: other tool_input fields such as '
    + 'isolation travel unexamined, and the read-trio confinement bounds what the child may then do. '
    + 'Three conditions this check cannot see still apply per call: the spawn must come from the '
    + 'main thread; the session must bind to a valid Session Control record — in an unbound session '
    + 'the hook declines and no grant is in force, so read the binding rows in this report '
    + 'alongside this one; and the hook re-reads the flag fail-closed at call time, so a host where '
    + 'that read cannot run declines even though this row rendered. '
    + 'A permissions.deny or permissions.ask entry still overrides it. Turn it '
    + 'off with hooks.reviewerSpawnAutoAllow=false.');
  return true;
}
function permissionExposureRows(disabled, grantActive) {
  try {
    permissionExposureRowsInner(disabled, grantActive);
  } catch (e) {
    line(WARN, 'permissions: the reviewer-spawn permission check failed to run. That is a missing '
      + 'check, not an all-clear.');
  }
}
function permissionExposureRowsInner(disabled, grantActive) {
  if (disabled) {
    line(OK, 'permissions: the reviewer-spawn permission check is switched off by '
      + 'hooks.reviewerSpawnPermissionCheck in .zensu/config.json, so it did not run. That is a '
      + 'skipped check, not an all-clear. Turn it back on if your permissions are not governed by '
      + 'a settings source that outranks ~/.claude/settings.json.');
    return;
  }
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
  permissionExposureLadder(file, grantActive);
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
  // The grant row comes FIRST and its state is threaded into the exposure check below,
  // because the exposure check's auto-mode advice is only correct when the grant is not
  // already covering the spawn it recommends a rule for.
  var grantActive = reviewerSpawnGrantRows(reviewerSpawnAutoAllowDisabled(cfgReads));
  permissionExposureRows(reviewerSpawnCheckDisabled(cfgReads), grantActive);
  // Here rather than in pluginBlock() because the row needs the resolved flag, and
  // cfgReads is gathered in this block. It reports on plugin DATA, so it reads as a
  // continuation of `hooks wiring` above.
  ruleCarrierRows(cfgReads);
}

// ONE reader for every bounded `ZDOC_*` integer, because the rule below is what
// the two callers kept getting differently. An ABSENT or blank value falls back,
// and that distinction is load-bearing: `Number('')` is `0`, `0` passes the
// `n >= 0` bound, and for BOTH of these variables `0` is the documented value
// that DISABLES the guard. `zensu-doctor.sh` exports each of them unconditionally
// after a conditional resolve, so a wrapper fault reaches this file as an empty
// string — which used to switch the pending-review TTL off silently. The
// implementing-turns reader guarded it; its twin did not, so the class was named
// and one of its two instances repaired. Now there is one instance.
function boundedEnvInt(name, fallback, max) {
  var raw = env[name];
  if (typeof raw !== 'string' || raw.trim() === '') return fallback;
  var n = Number(raw);
  if (Number.isInteger(n) && n >= 0 && n <= max) return n;
  return fallback;
}

function ttlHours() {
  return boundedEnvInt('ZDOC_TTL_HOURS', TTL_HOURS_FALLBACK, TTL_HOURS_MAX);
}

function implStopThreshold() {
  return boundedEnvInt('ZDOC_IMPL_STOP_NUDGE_AFTER', IMPL_STOP_NUDGE_FALLBACK, IMPL_STOP_NUDGE_MAX);
}
// The shapes that carry no work forward. Taken from chain-recovery-v1.js, which
// OWNS the vocabulary and mints these literals a few lines from where it lists
// them. A hand-copy here was tried and was wrong in the one direction that
// matters: it compared against the `NEXT_COMMAND` lookup table, so renaming the
// literal `chainShape` RETURNS while leaving the table key in place kept the
// copy agreeing while a genuinely closed foreign chain rendered as an open one.
// A consumer cannot check the producer it does not own; asking the owner is the
// only version of this that works.
// The element check is not decoration. Arity alone accepts an export whose members
// are not the strings `chainShape` returns — a different type, or a different
// spelling — and `indexOf` then never matches, so every closed foreign chain
// renders as an open one with no row saying the check did not run. That is the
// silent wrong answer moving the set here was meant to remove; anything unusable
// falls through to `null` and the disclosed WARN.
function inertShapes(chain) {
  var shapes = chain && chain.INERT_SHAPES;
  if (!Array.isArray(shapes) || !shapes.length) return null;
  return shapes.every(function (s) { return typeof s === 'string' && s !== ''; }) ? shapes : null;
}

// The document's own age. `.zensu/state/` is writable from inside a session, so
// a bare `touch -t` would move a filesystem mtime out of the window without
// producing a document `validateWorkflowState` accepts — `updated_at` is a field
// that validator already requires to parse as a finite date, so it is the
// cheaper thing to trust. It narrows the forgery channel rather than closing it:
// `session_id_hash` is derivable from the file's own name, so a writer can still
// mint an accepted document carrying any stamp it likes.
//
// No mtime fallback: `readWorkflowState` throws unless `updated_at` parses
// finite, and a throw sends the file to `invalid` instead of into `states`, so
// an entry reaching here always carries one. A fallback would be dead code
// pretending to be a safety net.
//
// A stamp in the FUTURE is treated as out of window rather than absolute-valued.
// This is the sibling `reviewerDenialRows` policy one screen down, and for its
// reason: a negative age would sail under any `<= ttl` bound forever, so a
// clock-skewed or planted document would render this row until someone deleted
// it. Returning null rather than a number keeps "not in the window" and "could
// not be measured" one answer, which is all the caller needs.
function documentAgeMs(entry, nowMs) {
  var stamped = entry.state && entry.state.updated_at;
  var parsed = typeof stamped === 'string' ? Date.parse(stamped) : NaN;
  if (!Number.isFinite(parsed) || parsed > nowMs) return null;
  return nowMs - parsed;
}

// Shape-validated here as well as in the wrapper, because a malformed injected
// value must never be TREATED as the current key: every chain would then read as
// foreign and the row would accuse the session of stranding its own work.
//
// The BINDING verdict is required alongside it. The wrapper states that the key
// is empty for every verdict but `bound`, and it now clears the variable
// unconditionally so that holds — but the wrapper's whole resolution block is
// skipped when a caller supplies `ZDOC_BINDING`, so the reader enforces the
// invariant its producer only asserts. Without this, a report could print the ❌
// "no valid Session Control record" row and, below it, a row keyed on a session
// key it had just said does not exist.
function currentSessionKey() {
  var key = env.ZDOC_SESSION_KEY;
  if (env.ZDOC_BINDING !== 'bound') return '';
  return typeof key === 'string' && /^scv1_[a-f0-9]{64}$/.test(key) ? key : '';
}

// WHERE the workflow documents actually are. Every writer anchors on the RECORD:
// `zensu-log.sh` re-exports `CLAUDE_PROJECT_DIR` from `zensu_resolve_project_dir`,
// which resolves `ZENSU_PROJECT_ROOT` out of the immutable record, before any verb
// body runs. Reading the raw harness value here instead made this whole block look
// in a directory no writer uses whenever the two differ — and they differ in the
// ordinary case, a session whose cwd is a worktree while the harness reports the
// origin repo. That was not a rendering detail: `readWorkflowState` is rooted here
// too, so the documents were never read at all.
//
// An earlier attempt compared the two and withheld the row when they disagreed.
// That was worse: it withheld exactly the fork-in-a-worktree case the row exists
// for, and it did so silently. There is one authority; the caller's value is the
// fallback, and only because a session with no bound record has nothing better.
// Control bytes, refused wherever a value reaches the report or a shell. Declared
// here because `stateProjectRoot` below is the first consumer.
var CONTROL_BYTE_RE = /[\u0000-\u001f\u007f]/;

// The reader re-enforces the ONE invariant of its producer that has a consequence
// here, which is the rule `currentSessionKey` states one function up: a caller
// supplying `ZDOC_BINDING` skips the wrapper's whole resolution block, so a guard
// that lives only there is not a guard. `dir` is printed RAW in three rows, so a
// newline in the recorded root injects fabricated lines into a report the model
// reads back and summarizes.
//
// Deliberately NOT re-checked here: that the root is an existing directory. The
// wrapper refuses a non-directory, and adding the same test to this side would make
// an unreadable recorded root fall back to `CLAUDE_PROJECT_DIR` — silently scanning
// a DIFFERENT project, which is worse than letting `readdirSync` fail and say so.
// One missing directory should be reported, not routed around.
//
// Neither case is reachable through the shipped invocation (the wrapper clears both
// values unconditionally and the recognizer's assignment allowlist is closed). It is
// here for the PORT NOTE at the top of this file: a port that gets the clear-vs-seed
// rule right and the shape guard wrong lands the value here with nothing to catch it.
function stateProjectRoot() {
  var recorded = env.ZDOC_SESSION_PROJECT_ROOT;
  if (env.ZDOC_BINDING === 'bound' && typeof recorded === 'string' && recorded !== ''
    && !CONTROL_BYTE_RE.test(recorded)) {
    return path.resolve(recorded);
  }
  return path.resolve(env.CLAUDE_PROJECT_DIR || '.');
}

// A path is printed as a deletion target only when a shell can be handed it
// safely, because `skills/doctor/SKILL.md` Phase 3 feeds exactly these bytes to
// `rm`. Three conditions: NO component of the chain is a symlink — the scanned
// root included, which is why the walk starts from its canonical spelling rather
// than from the caller's; the resolved file is a plain, single-linked file inside
// that root; and the path carries no control byte. Any failure returns '' and the
// caller withholds the path rather than the finding.
//
// The value is emitted SHELL-QUOTED rather than filtered against a character
// class. An allowlist was tried first and was wrong in BOTH directions: it
// excluded `path.sep`, so on win32 no candidate could ever match and the cleanup
// was unreachable on that host entirely, and it excluded the space, so an ordinary
// `~/My Projects/...` was refused with a message blaming the user's filesystem.
// Inside single quotes every byte but the quote itself is literal, so quoting is
// the total answer the class was approximating. A control byte is still refused:
// quoting would make it harmless to the shell, but it would corrupt the report
// line a model reads back.
//
// `root` is canonicalized rather than compared against its own realpath. Requiring
// equality would refuse every macOS session under `/var/folders`, which is a
// symlink to `/private/var` — an ordinary temp root, not a hostile one. Resolving
// instead makes the stated invariant TRUE, and the printed path is then the one
// `rm` will actually act on.
function shellQuotePath(value) {
  return "'" + value.split("'").join("'\\''") + "'";
}

// Returns `{ path, reason }`. Exactly one is ever non-empty. The reason is
// rendered to the operator, because "the path is withheld" plus an unresolvable
// disjunction reads as a fault in their filesystem rather than as the specific
// condition the renderer actually hit.
function deletableTarget(file, root) {
  try {
    var rest = path.relative(root, file);
    if (rest === '' || rest === '..' || rest.startsWith('..' + path.sep) || path.isAbsolute(rest)) {
      return { path: '', reason: 'it resolves outside the scanned project root' };
    }
    var current = fs.realpathSync.native(root);
    var parts = rest.split(path.sep);
    for (var i = 0; i < parts.length; i++) {
      current = path.join(current, parts[i]);
      var st = fs.lstatSync(current);
      if (st.isSymbolicLink()) return { path: '', reason: 'a component of its path is a symlink' };
      if (i < parts.length - 1) {
        if (!st.isDirectory()) return { path: '', reason: 'a component of its path is not a directory' };
      } else if (!st.isFile()) {
        return { path: '', reason: 'it is not a plain file' };
      } else if (st.nlink !== 1) {
        return { path: '', reason: 'it has more than one hard link' };
      }
    }
    if (CONTROL_BYTE_RE.test(current)) return { path: '', reason: 'its path carries a control character' };
    return { path: shellQuotePath(current), reason: '' };
  } catch (e) {
    return { path: '', reason: 'it could not be examined (' + (e && e.code ? e.code : 'unknown error') + ')' };
  }
}

// The marker's OWN `ts` decides its age when it carries one, exactly as
// `_tdd_pending_file_stale` in `hooks/lib/zensu-tdd-phase.sh` decides staleness.
// Reading the filesystem mtime alone let this row print "safe to clear" for a
// marker the Stop enforcer still treats as LIVE: an mtime-preserving restore, a
// `cp -p` or a container layer moves the two apart without touching `ts`, and
// `.zensu/state/` is session-writable besides. Two readers of one file must not
// disagree about which markers are dead. The size bound keeps a planted file from
// turning a diagnostic row into an unbounded read.
function pendingReviewStamp(file, st) {
  try {
    if (st.size <= 65536) {
      var parsed = Date.parse(JSON.parse(fs.readFileSync(file, 'utf8')).ts);
      if (Number.isFinite(parsed)) return parsed;
    }
  } catch (e) { /* an absent or unreadable `ts` falls back to the filesystem stamp */ }
  return st.mtimeMs;
}

// `dirEntries` and `stateDir` are the raw `.zensu/state` listing and its path, and
// they are here for ONE question: does this session still stand refused? Without
// them the implementing-turns row recommended the completion verb on exactly the
// chain whose Stop notice had just qualified it, so the two surfaces contradicted
// each other in the same minute. Both are optional — a caller with no listing gets
// the previous behaviour, never a TypeError. **Accepted design debt, named rather
// than left to be discovered:** they are one datum split into an unchecked pair, and
// an omitted argument degrades to "no refusal" SILENTLY, which is the shape this file
// refuses everywhere else. There is exactly one caller and it passes both, so the
// degradation is unreachable today; make them required if a second caller appears.
function chainRows(entries, nowMs, dirEntries, stateDir) {
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
  var foreignOpen = [];
  // A STRING, not a list. The push is gated on `entry.key === ownKey` and each entry
  // carries a distinct key, so at most one chain can ever qualify — holding a single
  // value puts that invariant in the type instead of in a comment defending an array
  // that could only ever have one element.
  var parkedImpl = '';
  // The row states the MEASURED magnitude, so the count has to survive the loop.
  // Rendering `implThreshold` instead made the sentence read "across at least 12
  // turns" at turn 300 — the bound, not the finding.
  var parkedTurns = 0;
  var implThreshold = implStopThreshold();
  var ownKey = currentSessionKey();
  var ttl = ttlHours();
  // Gated on the same two conditions the only consumer needs. State the gate honestly:
  // it is WEAKER than the consumer's, which additionally requires the entry to be this
  // session's own chain at `implementing` with the counter at or past the bound — so a
  // bound session with a note and no implementing chain still pays one note read.
  // Resolved here rather than above, because it consumes the `ttl` on the line before.
  var ownRefused = implThreshold > 0 && ownKey !== ''
    && ownRefusalNoteLive(dirEntries || [], stateDir || '', ownKey, nowMs, ttl);
  var inert = inertShapes(chain);
  // Whether the foreign-open row can render AT ALL. Neither half depends on an
  // entry, so it is decided once here rather than re-tested per entry and then
  // re-spelled independently by the disclosures below.
  var rowArmed = ownKey !== '' && inert !== null;
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
    if (report.wedged) {
      if (report.recoverable) recoverable.push(entry.session + ' → ' + report.nextCommand);
      else blocked.push(entry.session + ' → ' + report.nextCommand);
      return;
    }
    // Below the two early returns, on the same side of the ordering contract as
    // the foreign-open push: a chain already named as wedged or dead-ended must
    // never be named a second time with a different instruction. Gated on the
    // session key ALONE — deliberately not on `rowArmed`, whose `inert` half
    // belongs to the foreign-open filter and would withhold this row for a reason
    // it does not depend on, silently.
    if (implThreshold > 0 && ownKey !== '' && entry.key === ownKey
      && report.shape === 'implementing') {
      // Read through the classifier, not off the raw document: that module owns
      // chain semantics, projects the sibling counters the same way, and serialises
      // the whole report as the `--chain-status` payload, so reaching around it
      // would leave that verb structurally blind to how long a chain has been parked.
      var parkedCount = report.implStopCount;
      if (Number.isSafeInteger(parkedCount) && parkedCount >= implThreshold) {
        // The command comes from the OWNING module, never hand-authored here: for
        // an Autopilot-bound chain `shapeCommand` returns the spelling carrying
        // --autopilot-run / --autopilot-attempt / --chain-id, and the bare verb is
        // refused outright for such a chain. Same rule the three sibling rows follow.
        parkedTurns = parkedCount;
        // The command is ALWAYS named. An earlier revision withheld it while a live
        // refusal note stood, and that was wrong twice over. First, the note is an
        // unauthenticated file in a session-writable directory, so withholding let
        // anything able to write there DELETE the row's only remedy and assert a
        // host refusal that never happened. Second, the note is minted only by a
        // Stop that gets all the way through the dirty-tree and threshold gates,
        // while this row renders off the persisted counter alone — so one clean-tree
        // turn cleared the note and silently restored the bare recommendation, which
        // is the exact contradiction the withholding was introduced to remove.
        // Qualifying instead is stable under both: a missing note costs the caveat,
        // never the remedy, and a planted one can only add a caveat.
        // `report.nextCommand` arrives UNQUOTED, and what makes that safe is named here
        // because a first version of this comment named the WRONG thing and was refuted
        // in review. The bound is `autopilotLinkage` in chain-recovery-v1.js:
        // `shapeCommand` only interpolates `runId` / `attempt` / `chainId` under
        // `linkage === 'bound'`, which requires `isLinkId` on both ids —
        // `/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/`, 1..128 characters, so no whitespace and no
        // shell metacharacter — and an integer attempt in 1..999. Every other producer
        // of `nextCommand` is a STATIC MODULE STRING: the two frozen tables, plus the
        // `STALE_RECEIPT_CAVEAT` literal one branch concatenates onto a table value. So this row carries no unbounded
        // dynamic text, and WIDENING `isLinkId` is what would open the channel.
        //
        // NOT the `entry.key === ownKey` gate above: that bounds only WHOSE document is
        // read and would not stop a self-written run id if the character class were
        // relaxed.
        //
        // And the Stop hook's `%q` is not evidence of a disagreement either — but state
        // WHY correctly, because a first revision of this sentence said that path has "no
        // `isLinkId` gate at all", and that is false. `tdd_chain_snapshot` in
        // `zensu-tdd-phase.sh` carries a character-identical copy of the predicate and
        // exits non-zero when either id fails it, and the Stop hook routes that failure to
        // its blocking arm. So both paths gate; the `%q` is defence in depth over a HAND
        // COPY of one predicate, not the only bound on an ungated read. That copy is the
        // thing to know when widening: the class is written out in several places under
        // `hooks/`, and at least one of them has already drifted (`zensu-autopilot-state.sh`
        // spells the same class with a minimum length of 3). Widening `isLinkId` is a
        // multi-site decision, not a one-file one.
        //
        // Quoting in `shapeCommand` as defence in depth would still be reasonable and is
        // deliberately not taken here: its output is `NEXT_COMMAND`, pinned by name in
        // chain-recovery-v1.test.js, test-chain-recover.sh and skills/recover-chain's
        // shape table, so it is its own change with its own pin updates.
        parkedImpl = entry.session + ': ' + parkedCount + ' turns → ' + report.nextCommand;
      }
    }
    // Reached only by a chain no row above already named. A wedged or dead-end
    // chain returns first on purpose: those rows carry their own remedy, and a
    // second row telling the reader to re-arm the same truncated key would
    // contradict it.
    // `rowArmed` is loop-INVARIANT and is named once, above, so the arming rule and
    // the disclosures below cannot drift apart. Only the two conditions that really
    // vary per entry are tested here.
    if (!rowArmed || entry.key === ownKey || inert.indexOf(report.shape) !== -1) return;
    // `0` disables the bound rather than shrinking it to nothing, which is what
    // this key means everywhere else it is read (docs/configuration.md, and
    // reviewerDenialRows below). At `0` no window is claimed, so nothing is
    // excluded on age at all: every entry reaching here carries an `updated_at`
    // that parses finite, because `validateWorkflowState` refuses any document
    // whose stamp does not and `stateBlock` routes that throw to `invalid`
    // instead of into `states`. A guard for the unreadable case would be dead
    // code pretending to be a safety net — the same argument documentAgeMs makes
    // one screen up for the absent mtime fallback.
    var ageMs = documentAgeMs(entry, nowMs);
    if (ttl > 0 && (ageMs === null || ageMs / 3600000 > ttl)) return;
    foreignOpen.push(entry.session + ': ' + report.shape);
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
  // Counted in TURNS, never in elapsed time. An age bound would report the
  // user's calendar rather than the model's behaviour: a powered-off machine, a
  // paused session and a holiday all accumulate wall clock with nothing wrong,
  // and they accumulate zero here. The shape alone is never enough either — it
  // is what every legitimately mid-implementation chain looks like — so the
  // count is what separates working from parked.
  if (parkedImpl !== '') {
    // Names ONE exit and names its preconditions with it. `--tdd-complete` refuses
    // without an edit-landing receipt and without a usable Requirements table, and
    // both gates arm on the same dirty tree this row requires, so naming the verb
    // bare would be a remedy that refuses in the same breath. The zero-change
    // terminus is deliberately NOT offered: from this shape it is the unqualified
    // no-ticket terminus, and after a mid-run commit it closes a chain nothing
    // reviewed. The command itself comes from the owning module, so a bound chain
    // gets its own spelling rather than the standalone one.
    // Says what the counter MEASURES. It advances only on a turn that ended with
    // a changed worktree, so the chains reaching the bound are the busiest ones —
    // "parked" asserted the opposite, and a reader on turn 13 of genuine work can
    // disprove that opening clause at a glance. The magnitude is the finding, so
    // the rendered number is the count, never the bound.
    line(WARN, 'chain: this session owns a chain that has ended ' + parkedTurns
      + ' turns at `implementing` with a changed worktree'
      + ' — the review chain has not asked for a reviewer, so nothing in it has been reviewed.'
      + ' (That is compatible with a spawn that WAS attempted: the caveat below reports one when'
      + ' a note records it.) Counted in turns,'
      + ' never in elapsed time, so a paused session or a powered-off machine never reaches this row.'
      + ' The exit is the review chain: run the /zensu:tdd Phase 6 step 5b edit-landing audit and give'
      + ' the plan a usable `## Requirements` table first, because the completion verb refuses without'
      + ' both while the tree is dirty.'
      // QUALIFIES, never withholds. The caveat is worded so that its absence costs
      // the reader nothing they can act wrongly on: with no live note the row is the
      // ordinary remedy it always was, and with one the reader is told to lift the
      // permission first. It says "a note records" rather than asserting the refusal
      // outright, because the note is unauthenticated — the row below grades it.
      + (ownRefused
        ? ' A note in this session\'s state directory records that the host permission layer'
          + ' refused its ' + REVIEWER_AGENT + ' spawn — see the refused-spawn row below. That permission'
          + ' has to be lifted before the exit is taken, or the chain moves to a gate it cannot pass.'
          // The BAR travels with the instruction, as it does at every other site in this file
          // that asks for a permission change. It was the one site without it, on a row the
          // skill orders relayed verbatim — and the note that triggers it is unauthenticated,
          // so anything able to write the state directory could otherwise attach a bar-less
          // "lift that permission" to the chain row.
          + ' You have to apply this yourself — ' + SELF_PERMISSION_BAR + '.'
        : '')
      + ' ' + parkedImpl);
  } else if (implThreshold >= IMPL_STOP_NUDGE_MAX) {
    // The value that reaches this arm is the getter's own MAXIMUM, and nothing stronger
    // should be claimed about it. A first wording said it was "at or above the counter's
    // storage ceiling", which is false — the ceiling is one HIGHER, as this file's own
    // IMPL_STOP_NUDGE_MAX comment says in the opposite direction — and it reached emitted
    // operator text the doctor skill orders relayed. What is true is that no session ends
    // that many turns, so the check cannot fire in practice; the literal `0` arm below was
    // the only disclosure there was, which made a config value a silent off-switch for a
    // review-integrity diagnostic, with no row and no bypass-ledger entry because no gate
    // was escaped. Disabling must disclose however it is spelled.
    line(OK, 'chain: the implementing-turns check cannot fire in practice — '
      + '`hooks.implStopNudgeAfter` is ' + implThreshold + ', the highest value the getter'
      + ' accepts, and no session ends that many turns. That is a switched-off check, not a'
      + ' clean one.');
  } else if (implThreshold === 0) {
    // Disabling must not produce silence — the same rule the reviewer-spawn
    // permission check follows. A reader who sees no row has to be able to tell
    // "nothing to report" from "this check did not run".
    //
    // The coordination with the missing-key disclosure below runs in ONE
    // direction, and it is this one: at threshold 0 the row is withheld because
    // the check is switched off, and would be withheld with a perfectly good key.
    // An earlier revision suppressed THIS row instead, which left the disclosure
    // below blaming the missing key for a row that configuration had turned off —
    // the wrong cause, and the exact confusion the coordination exists to prevent.
    line(OK, 'chain: the implementing-turns check is switched off'
      + ' (`hooks.implStopNudgeAfter` is 0), so no chain was measured for it.');
  }
  // BOTH halves of the row's contract disclose, and neither is conjoined on the
  // other. Gating the module half on `ownKey !== ''` meant a tree that broke both
  // printed NEITHER row: the inert disclosure was suppressed by the missing key,
  // and the key had no disclosure of its own. Silence is the one verdict this row
  // cannot qualify.
  if (inert === null) {
    line(WARN, 'chain: chain-recovery-v1.js exports no usable inert-shape set — an open chain'
      + ' not owned by this session cannot be told from a closed one, so that row did not run.'
      + ' That is a missing check, not an all-clear.');
  }
  // The wrapper half. A `bound` verdict with no session key is reachable through
  // the shipped wrapper whenever one of its shape guards drops the pair, and it
  // silently withheld the row while the report otherwise looked healthy.
  if (env.ZDOC_BINDING === 'bound' && ownKey === '') {
    // The implementing-turns clause is CONDITIONAL on the check being armed, and ARMED
    // means BOTH bounds, not just the lower one. At threshold 0 that row is withheld by
    // configuration, and at the getter's maximum it is withheld because the check cannot
    // fire — each has its own row above saying so, and claiming the missing key here as
    // well would give one absent row two contradictory causes in the same report. The
    // upper bound was missing when the cannot-fire row landed, which reproduced that
    // defect one literal over.
    line(WARN, 'chain: the session key did not reach this report — an open chain owned by'
      + ' another session cannot be identified, so that row did not run.'
      + (implThreshold > 0 && implThreshold < IMPL_STOP_NUDGE_MAX
        ? ' The implementing-turns row is withheld for the same reason, since without'
          + ' the key an own chain cannot be told from a foreign one.'
        : '')
      + ' That is a missing check, not an all-clear.');
  }
  if (foreignOpen.length) {
    // States the OBSERVATION, never the cause. This cannot tell a chain whose
    // session forked away from one a live sibling session is still driving, and
    // a live sibling is normal in this repository's own worktree workflow — so
    // asserting a fork would make a false claim about that session and tell the
    // reader to arm a competing chain.
    //
    // The CAUSE ORDER is deliberate and was corrected once. An earlier wording
    // named the fork as "the usual cause" and opened with "if those sessions are
    // still running, nothing is wrong here". Neither held: the predicate is every
    // open chain in this project not owned by this session and inside the TTL, and
    // the dominant member of that set is a session that ENDED without --chain-done,
    // for which nothing is running and the state IS stale. Naming the rare cause
    // first, then telling the reader the common case is fine, trains them to
    // dismiss the row.
    //
    // It stays WARN, and the cost is accepted rather than hidden: `line()` counts
    // WARN toward `warnCount` and `main()` gates "all checks green" on it, so a
    // second session in the SAME project root suppresses the green summary while
    // it runs. Demoting to OK was the alternative and is worse — an abandoned open
    // chain is real stale state the user should clear, and a row that can never
    // affect the summary is a row people stop reading. A sibling working in its own
    // worktree has its own .zensu/state and never triggers this.
    line(WARN, 'chain: ' + foreignOpen.length + ' open chain(s) not owned by this session'
      + (ttl > 0 ? ', touched within ' + ttl + 'h' : '')
      + ' — this session cannot advance them, and they cannot be moved to this key.'
      + ' Usually a session that ended without /zensu:tdd --chain-done, in which case the'
      + ' state is stale and re-arming here with /zensu:tdd is the exit. It can also be a'
      + ' live sibling session, where nothing is wrong, or a FORK — the host minting a new'
      + ' session id mid-conversation, which leaves the work armed under the old key'
      + ' unreachable. Check whether the owning session is still running before acting: '
      + truncatedList(foreignOpen));
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
// The `kind` is untrusted: only values the writer itself issues are accepted.
// Extracted from `reviewerDenialRows` because a SECOND consumer needs the same
// judgement — see `ownRefusalNoteLive` — and two copies of "which notes count"
// is precisely the two-surfaces-disagree failure this feature exists to remove.
function denialKindsAllowed() {
  try {
    var denial = require(path.join(pluginDir(), 'hooks', 'lib', 'reviewer-spawn-denial-v1.js'));
    if (Array.isArray(denial.DENIAL_MARKERS)) {
      return denial.DENIAL_MARKERS.map(function (m) {
        return m && typeof m.kind === 'string' ? m.kind : '';
      }).filter(Boolean);
    }
  } catch (e) { /* every kind then reads as unrecognized */ }
  return [];
}

// ONE verdict for a parsed note, returned as a WORD rather than a boolean so the
// counting consumer keeps its three buckets while the withholding consumer can
// test for one. A boolean here would have forced `reviewerDenialRows` to keep its
// own copy to tell `rejected` from `stale`, which is the copy this extraction
// removes. `allowed` is threaded rather than recomputed: a plugin root that cannot
// load the classifier vets no kind, and neither consumer may silently upgrade the
// other's judgement of that.
function classifyDenialNote(parsed, allowed, ttl, nowMs) {
  if (parsed === NOTE_MISSING) return 'missing';
  var vettable = allowed.length > 0;
  if (!parsed || parsed.schemaVersion !== 1 || typeof parsed.kind !== 'string'
    // Integer and positive, not merely finite: a timestamp the writer could
    // never have produced is not evidence about the present.
    || !Number.isInteger(parsed.detectedAtMs) || parsed.detectedAtMs <= 0
    || (vettable && parsed.kind !== '' && allowed.indexOf(parsed.kind) === -1)) return 'rejected';
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
      || (nowMs - parsed.detectedAtMs) / 3600000 > ttl)) return 'stale';
  return 'live';
}

// Does THIS session still stand refused? The implementing-turns row asks so it can
// QUALIFY its remedy — never to withhold it. State it that way: an earlier revision
// DID withhold the completion verb while a live note stood, and this comment still
// described that behaviour after the code reversed it. The row now always names the
// command and adds a caveat when a note records a refusal; the reasoning for that
// reversal, and the two defects withholding caused, are recorded at the row itself. The workflow-document sibling check `reviewerDenialRows` applies is not
// repeated — the key reaching this function came from a validated document, so the
// sibling exists by construction.
// `ttl` is THREADED, not re-read. `chainRows` already resolves it for its own use, and
// the section that advertises these consumers as sharing one implementation would
// otherwise be advertising one RULE resolved from three separate reads of the same
// environment variable. Same value today; the point is that the claim is literal.
function ownRefusalNoteLive(entries, dir, ownKey, nowMs, ttl) {
  if (!ownKey) return false;
  var name = 'reviewer-spawn-denied-' + ownKey + '.json';
  if (entries.indexOf(name) === -1) return false;
  // The SAME sibling-document anchor `reviewerDenialRows` applies, enforced here
  // rather than argued from the call site. It holds by construction today — the key
  // reaches this function from a validated `tdd-phase-<key>.json` — but that is a
  // property of ONE caller, and a comment asserting it would be inherited silently
  // by the next one. One line is cheaper than that risk.
  if (entries.indexOf('tdd-phase-' + ownKey + '.json') === -1) return false;
  return classifyDenialNote(readNoteJson(path.join(dir, name)), denialKindsAllowed(),
    ttl, nowMs) === 'live';
}

function reviewerDenialRows(entries, dir, nowMs) {
  var notes = entries.filter(function (f) {
    return /^reviewer-spawn-denied-scv1_[a-f0-9]{64}\.json$/.test(f);
  }).sort();
  if (!notes.length) return;
  var allowed = denialKindsAllowed();
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
    // The shape and freshness rules live in `classifyDenialNote`, shared with
    // `ownRefusalNoteLive`. The three buckets are why that helper returns a word
    // rather than a boolean.
    var verdict = classifyDenialNote(parsed, allowed, ttl, nowMs);
    // EXHAUSTIVE on purpose: only 'live' reaches the tally. The first spelling
    // handled 'rejected' and 'stale' and let everything else fall through to
    // `valid += 1`, so a 'missing' verdict would have been counted as a real
    // refusal — a fabricated row telling the user to widen a permission. It was
    // unreachable only because of the single early return above it, which is
    // exactly the kind of load-bearing accident a later edit removes.
    if (verdict !== 'live') {
      if (verdict === 'stale') stale += 1;
      else rejected += 1;
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
      + 'first removing any deny rule that names the Agent tool — ' + DENY_OUTRANKS
      + ' — or leave the permission mode that refused it, then re-run the '
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
  var projectRoot = stateProjectRoot();
  var dir = path.join(projectRoot, '.zensu', 'state');
  var entries;
  try {
    entries = fs.readdirSync(dir);
  } catch (e) {
    if (e && e.code === 'ENOENT') {
      line(OK, 'state: ' + dir + ' does not exist yet — nothing to clean');
    } else {
      // Every other errno is a check that did NOT run. Rendering it green hid the
      // whole Session state block behind an all-clear, which is the one verdict
      // this file refuses to fake anywhere else.
      line(WARN, 'state: ' + dir + ' could not be read (' + ((e && e.code) || 'unknown')
        + ') — the session-state checks did not run. That is a missing check, not an all-clear.');
    }
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
            key: match[1],
            state: core.readWorkflowState({ projectRoot: projectRoot, sessionId: match[1] }),
          });
        } catch (e) {
          invalid.push(file);
        }
      });
    }
    var valid = workflowDocs.length - invalid.length;
    if (valid) {
      line(OK, 'state: ' + valid + ' validated CAS workflow document(s); reviewRound/stopBlockCount/implStopCount are integrated fields');
    }
    if (invalid.length) {
      line(BAD, 'state: ' + invalid.length + ' invalid CAS workflow document(s) — hooks fail closed; inspect ' + invalid.join(', '));
    }
    // The listing and its directory travel with the states so the implementing-turns
    // row can ask whether this session still stands refused. `reviewerDenialRows`
    // below renders the refusal itself, which is why that row says "below".
    chainRows(states, nowMs, entries, dir);
  }
  reviewerDenialRows(entries, dir, nowMs);
  var pr = path.join(dir, 'pending-review.json');
  try {
    var st = fs.statSync(pr);
    var ageH = (nowMs - pendingReviewStamp(pr, st)) / 3600000;
    var ttl = ttlHours();
    if (ttl === 0) {
      // `0` DISABLES the guard — docs/configuration.md, `_tdd_pending_file_stale`,
      // `reviewerDenialRows` and the foreign-chain row all read it that way. This
      // row did not, and `ageH > 0` is true for every marker older than an instant,
      // so it called each one expired. Harmless while the row carried no path;
      // once it names a deletion target the skill acts on, it would have offered a
      // LIVE deferred-review claim for removal.
      line(OK, 'state: pending-review.json present; its TTL guard is disabled (pendingReviewTtlHours: 0)');
    } else if (ageH > ttl) {
      // The PATH, not just the verdict. The Session state block is anchored on the
      // record's project root, while the skill's confirmed cleanup used to derive
      // its target from CLAUDE_PROJECT_DIR — so where the two differ, the report
      // measured one file and the user was asked to delete another it had never
      // examined. A deletion offer has to name the thing it measured.
      //
      // The path is emitted ONLY when a shell can be handed it safely, and
      // SHELL-QUOTED so the skill can use it verbatim. `statSync` follows symlinks,
      // so a symlinked `.zensu` or `state` would point the confirmed `rm` outside
      // this project. A failing check drops the path and keeps the verdict — the
      // skill contracts that a row without a path offers no cleanup, so withholding
      // degrades safely while printing would not — and the row names WHICH check
      // failed, because an unresolvable disjunction reads as a fault in the user's
      // filesystem rather than as the condition the renderer actually hit.
      var target = deletableTarget(pr, projectRoot);
      line(WARN, 'state: pending-review.json is ' + Math.floor(ageH) + 'h old (TTL ' + ttl + 'h) — expired'
        + (target.path ? ', safe to clear: ' + target.path
          : '. The path is withheld because ' + target.reason + '. Clear it by hand.'));
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
