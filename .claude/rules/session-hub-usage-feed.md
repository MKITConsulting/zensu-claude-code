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
UUID or nothing is written), `observedAt` (`$.clock.now()`, integer milliseconds) and
`rateLimits`: at most eight unique `{kind, percentUsed, resetsAt}` entries, `kind` matching
`^[a-z][a-z0-9_]{0,31}$`, `percentUsed` finite and not negative (an exceeded spend limit passes
100), `resetsAt` an ISO 8601 timestamp or `null`. A reading left with no valid window writes
nothing, so every record carries at least one. U6 holds the module to the six engine calls the
feed needs and to the two environment names, so any new `$` call fails CI until it is reviewed.

**When it writes.** Only on `session.measure`, after `next(e)`, and on every measure whose
`e.changed` names `cost` or `rateLimits`. The types define `cost` as US dollars "summed over every
priced API response this session" and `rateLimits` as "the rate-limit windows the last response
reported", so a measure that names `cost` follows a fresh response, and the measure at the end of
a main-thread turn carries that turn's reading. A measure that names only `context` came without a
priced response, for example after a local command, and its windows are an earlier response's;
writing it would stamp an old reading with a fresh `observedAt`, so it writes nothing. Nothing is
written on `session.start` either: `$.session.usage()` there holds the engine's last response,
which the live check below found to be minutes or hours old. An idle engine writes nothing, so its
record ages and the Hub judges it by `observedAt` and `resetsAt`. `/clear` fires no new
`session.start`, and the next write lands under the new session id because the module asks
`$.session.id()` at every write.

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

**It never disturbs the session.** Every hook awaits `next(e)` first and catches everything it
does after, so each event keeps the engine's answer and nothing is printed. A module whose
`register` throws leaves the classic hooks and skills running, measured on 2.1.299.

## Tests

- `tests/mods/usage-feed.test.ts` runs under `claude plugin test .`: the record's exact fields,
  nothing written on `session.start`, nothing written while the directory is missing or is a file
  or link, the `changed` filter (`cost` or `rateLimits` writes, `context` alone does not),
  malformed session ids, the config-root ladder, malformed windows, and a failing write. An op
  answered by a test hook returns `{ value }` or `{ deny }`. `claude plugin test` does not descend
  into `node_modules` (measured on 2.1.301 with a planted failing test). CI has no Claude Code, so
  CI never runs this file.
- `tests/structure/test-session-hub-usage-feed.sh`, in `ciStructureTests`, reads the module as
  text: U1 contract bytes, U2 the `modules` entry, U3 constants, U4 the sibling receipt directory,
  U5 the literals, U6 the calls and environment names, U7 the one event, U8 type-only imports, U9
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
matcher, and adds no config key. `hooks/hooks.json` gains a top-level key, and every reader of
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
- The `cost` signal rests on the engine's cost ledger. A host without one leaves `cost` out of
  `changed`, and the module then writes only when a window moves. The types say the CLI always
  keeps one, and the live re-check below saw it move on subscription turns.
- `$.fs.write` is not atomic; the Hub treats an unparsable file as not yet written.
- The directory can vanish between the check and the write, and the write then re-creates it
  with default modes. `$.fs.stat` reports no mode or owner, so the module cannot check the Hub's
  0700, and only the last path component is checked for a link.
- A `CLAUDE_CONFIG_DIR` other than the root the Hub reads moves the records where the Hub does not
  look, as it does for receipts.
- A config root that is not a POSIX absolute path writes nothing, which covers native Windows;
  the Hub is a macOS app.
