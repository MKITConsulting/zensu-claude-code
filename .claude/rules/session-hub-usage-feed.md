---
paths:
  - "hooks/usage-feed.ts"
  - "hooks/usage-feed-contract.json"
  - "tests/mods/usage-feed.test.ts"
  - "tests/structure/test-session-hub-usage-feed.sh"
---

# Session Hub Usage Feed (`hooks/usage-feed.ts` + `hooks/usage-feed-contract.json`)

The Zensu Session Hub reads each Claude account's five-hour and weekly limits by pressing
Claude's usage popover, one foreground change per account. This plugin's one hooks module
writes each running engine's latest rate-limit reading into a directory the Hub owns, so an
account that works in Claude Code keeps current limits without that press. The popover read
stays the Hub's default, and the Hub works without the plugin.

**`hooks/usage-feed-contract.json` is the Hub's contract with this module.** The Hub byte-copies
it to its own `tests/fixtures/usage-feed-contract.json` and pins it there, the way it mirrors
`skills/session-trail/handover-contract.json`; `test-session-hub-usage-feed.sh` U1 pins it here.
Changing the directory, the schema version or either key list is a contract change: raise
`usage.schemaVersion`, and the `v1` path segment with it when the layout changes, and change the
Hub in step. U3 and U5 hold the module's constants and its two object literals to the file.

**Opt-in is the Hub's directory.** The module writes only while
`<config root>/zensu/session-hub/v1/usage` exists as a real directory and not as a link.
`$.fs.write` creates missing directories, so the module checks with `$.fs.exists` and
`$.fs.stat` first and never creates one. The config root is `CLAUDE_CONFIG_DIR`, trimmed, when it
names an absolute path; a relative one writes nothing and never falls back to `HOME`; otherwise it
is `$HOME/.claude`. The receipt hook resolves the same root through `path.resolve` and
`os.homedir()`, which the module does not have; the two agree for every absolute root on macOS
and Linux. The `exists` call is not needed for correctness, because `stat` rejects a missing
path and the rejection is caught; it keeps the common case, a machine without the Hub, free of
rejected calls.

**What a record holds.** `schemaVersion`, `sessionId` (`$.session.id()`, a lowercase hyphenated
UUID or nothing is written), `observedAt` (integer milliseconds of `$.clock.now()` at the moment
the module last proved the reading new, see When it writes) and
`rateLimits`: at most eight unique `{kind, percentUsed, resetsAt}` entries, `kind` matching
`^[a-z][a-z0-9_]{0,31}$`, `percentUsed` finite and not negative (an exceeded spend limit passes
100), `resetsAt` an ISO 8601 timestamp or `null`. A reading left with no valid window writes
nothing, so every record carries at least one. U6 holds the module to the six engine calls the
feed needs and to the two environment names, so any new `$` call fails CI until it is reviewed.

**When it writes.** The module writes a reading only once it has proven it new, because a measure
says nothing about the age of its windows. Two events prove it. The `turn.complete` hook, after
`next(e)`, reads the clock when a turn of the main loop or of a subagent ended with
`reason: 'answer'` and `usage`: that turn's last response has just arrived, and its headers
carried the windows. The `session.measure` hook, after `next(e)`, reads the clock when a window
differs from the reading of the measure before it: another percentage or reset, or a kind that was
not there. Only a response changes the windows, and the engine raises a measure as it applies a
move of a whole point, which is every move, because subscriptions report whole percentages (755
windows in the Hub's folder on 2026-11-02, none with a fraction). A window that only left, because
its reset passed, proves nothing. A measure writes when the newest proof is later than the one its
last record carried, and stamps the record with that proof's time; a measure that follows no newer
proof writes nothing, whatever `e.changed` names. The first measure after a load proves nothing,
because it has no reading to compare with. The state lives in the closure of `register`, one per
loaded module in each engine process, as the windows are one per process: a reload starts it over,
so an idle engine writes nothing after a reload, and `/clear` keeps it, so the new session id gets
a record only after a new proof, because the module asks `$.session.id()` at every write. A write
that fails or finds no directory leaves the proof unwritten, and the next measure writes it.
Nothing is written on `session.start` either: `$.session.usage()` there holds the engine's last
response, which the live check below found to be minutes or hours old. An idle engine writes
nothing, so its record ages and the Hub judges it by `observedAt` and `resetsAt`.

**Never `turn.step`.** A `turn.step` hook could date a reading by the send time of its request, but
whenever any plugin hooks `turn.step`, Claude Code 2.1.316 routes every model request of the
session through its function-hook stream layer. This plugin would do that on every machine it is
installed on, with or without the Hub, for a feature only the Hub reads. U7 holds the module to
`turn.complete` and `session.measure`.

**Out-of-date records, 2026-10-29.** Before this rule the module wrote on every measure whose
`e.changed` named `cost` or `rateLimits` and stamped the time of the write. On 2026-10-29 fifteen
sessions of three accounts wrote within 90 seconds, the sessions of each account at one and the
same second, weekly readings 5 to 26 points below a report their own account had made 30 to 143
minutes earlier (joined to accounts through Claude Desktop's session records on 2026-11-02). Read
from the Claude Code 2.1.316 binary on 2026-11-02: the engine raises `session.measure` at the end
of a turn when a unit moved and on every change of the account's limit status, a change of the
status alone counts as `rateLimits` changed, and the input's `rateLimits` are always the windows of
the last response the engine applied. The engine also changes the status without a response, for
example when it takes over limits a remote session reports or when a usage-limit wall ends, so
such a measure carried windows of any age and the old rule gave them a fresh time. What changed the
status of those sessions at once is not known.

**Live check, 2026-10-18.** Run by the session that started this work, with the owner's approval:
the module installed as a throwaway plugin from a local directory marketplace into the real
`~/.claude`, the usage directory created by hand at 0700. Within two minutes 31 Claude Desktop
engines (2.1.299) that were already running loaded it live, with no prompt and no restart, so the
plan's assumption that a running engine loads a newly installed module only after
`/reload-plugins` is wrong. Each wrote a record from `session.start`, and those records carried
each engine's last API response: in one account, records written within 80 seconds ranged from
13 % / 63 % (an engine idle since 16:38) to 37 % / 70 % (the only busy engine), and only the busy
engine matched `get_usage` (37 % / 70 %, same resets). That is why `session.start` writes nothing
now. Every record joined `~/.claude/sessions/<pid>.json` by `sessionId`, and six distinct weekly
reset times showed engines of at least six accounts.

**Live re-check, 2026-10-18 19:54–20:05.** The same session ran the fixed module as probe version
0.1.1 and reloaded it in every running Desktop engine through `claude plugin disable` and
`enable`. No idle engine wrote anything after the reload, so no burst of start records appeared;
only the about eleven busy engines wrote, at their turns. Three of them each wrote two consecutive
records with identical percentages (48 % / 73 % at 19:55:49 and again at 19:57:13, for one), so
`cost` moves on subscription turns and `observedAt` advances without a whole-point move. All
engines of one account showed the same values at each moment, and that account's newest record
(51 % / 73 % at 20:04:50) matched `get_usage` (51 % / 74 %, same resets) within one point.

**It never disturbs the session.** Both hooks await `next(e)` first and catch everything they do
after, so each event keeps the engine's answer, no hook sits on the model's stream, and nothing is
printed. A module whose `register` throws leaves the classic hooks and skills running, measured on
2.1.299.

## Tests

- `tests/mods/usage-feed.test.ts` runs under `claude plugin test .`: the record's exact fields and
  its stamp, the end of the answered turn rather than the write; nothing written without a newer
  proof, the status change of 2026-10-29 and the first measure after a load included; a moved,
  appeared or reset window proving a reading and a window that only left proving nothing; every
  answered turn, a subagent's too, writing again at steady windows; an interrupted, failed or
  refused turn and one without `usage` proving nothing; `/clear`; a directory that appears later
  keeping the reading's time; nothing written on `session.start` or while the directory is missing
  or is a file or link; malformed session ids; the config-root ladder; malformed windows; and a
  failed write that the next measure repeats. An op answered by a test hook returns `{ value }` or
  `{ deny }`. The file passed on 2.1.301, 2.1.305 and 2.1.316 on 2026-11-02, and 8 of its 15 tests
  failed against the module before this rule. `claude plugin test` does not descend into
  `node_modules` (measured on 2.1.301 with a planted failing test). CI has no Claude Code, so CI
  never runs this file.
- `tests/structure/test-session-hub-usage-feed.sh`, in `ciStructureTests`, reads the module as
  text: U1 contract bytes, U2 the `modules` entry, U3 constants, U4 the sibling receipt directory,
  U5 the literals, U6 the calls and environment names, U7 the two events, U8 type-only imports, U9
  the module test's presence, U10 one documented Claude Code minimum.
- `claude plugin validate .` reports the hooks, calls and environment reads the engine sees.

## Coupled sites

The `modules` entry in `hooks/hooks.json`; the contract and the Hub's fixture copy; the
constants and literals U3 and U5 extract (`SCHEMA_VERSION`, `USAGE_DIRECTORY`, `const record`,
`readings.push`); and the documented minimum, `MIN_CLAUDE_CODE` in the suite against both
statements in `README.md`, the troubleshooting row in `docs/operations.md` and the module
paragraph in `docs/configuration.md`, which U10 reads, plus the CHANGELOG upgrade note.

## Version

`patch`, walked against `.claude/rules/runtime-lineage.md`: the module writes no Zensu session
state, joins no strict key set, returns no `permissionDecision`, renames no hook and changes no
matcher, and adds no config key; its `turn.complete` hook registers no classic hook and changes no
answer. `hooks/hooks.json` gains a top-level key, and every reader of
that file in this tree reads `.hooks` alone. The raised Claude Code minimum is a host
requirement, stated in the docs and the upgrade notes, and no lineage change.

## Known gaps

- The module API is early access and can change in any Claude Code release, and Anthropic's
  remote flag `tengu_plugin_hooks_modules` can switch modules of installed plugins off. The feed
  then writes nothing and the Hub keeps its popover read.
- Nothing enforces the 2.1.296 minimum, and an older engine skips the module. With the plugin
  installed from a marketplace, which is how users get it, 2.1.280 printed nothing into
  `claude -p` output and named the reason only in its `--debug-file` log: the
  `tengu_plugin_hooks_modules` rollout flag was off by default, its GrowthBook cache still cold.
  Loaded through `--plugin-dir`, as in local development, the same engine printed a
  `hooks module not loaded` notice into the `-p` output instead.
- The module ran under `claude plugin test` on 2.1.301, 2.1.305 and 2.1.316, and those engines set
  a turn's `reason` alike. 2.1.296 to 2.1.300 were no longer installed to check; an engine that
  cannot load the module writes nothing.
- A stamp can be later than the measurement. The end of an answered turn comes after its last
  response and after the Stop hooks that follow it. A move of less than a whole point raises no
  measure, so a later measure stamps it when it comes, which needs a reading with a fraction.
- A step a plugin answers itself, with `usage` and without `next`, makes its turn count as
  answered although no request reached the API.
- A session's first reading waits for the end of its first answered turn, because the first
  measure after a load only sets the reading to compare with.
- `$.fs.write` is not atomic; the Hub treats an unparsable file as not yet written.
- The directory can vanish between the check and the write, and the write then re-creates it
  with default modes. `$.fs.stat` reports no mode or owner, so the module cannot check the Hub's
  0700, and only the last path component is checked for a link.
- A `CLAUDE_CONFIG_DIR` other than the root the Hub reads moves the records where the Hub does not
  look, as it does for receipts.
- A config root that is not a POSIX absolute path writes nothing, which covers native Windows;
  the Hub is a macOS app.
