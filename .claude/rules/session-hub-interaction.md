---
paths:
  - "plugins/session-hub/hooks/interaction-contract.json"
  - "plugins/session-hub/hooks/lib/session-hub-courier-v1.mjs"
  - "plugins/session-hub/.claude-plugin/plugin.json"
  - "tests/structure/session-hub-courier-v1.test.js"
  - "tests/structure/test-session-hub-interaction.sh"
---

# Session Hub Interaction Channel (`hooks/lib/session-hub-courier-v1.mjs` + `hooks/interaction-contract.json`)

The Zensu Session Hub opens a channel that a session's hook or hooks module can reach: the plugin
starts the courier, a small signed program inside the Session Hub app, which connects to the Hub
over a Unix socket, checks that the Hub is at the other end and relays one line each way. This is
step 2 of the Hub's plan for answering a waiting session from the Hub; the Hub side is described in
`docs/session-interaction.md` of `MKITConsulting/zensu-session-hub`. The companion ships the
contract file and the launcher in this step and wires neither into a hook or module: step 3 adds a
`PermissionRequest` hook that uses the launcher, and a later step the module side.

**`hooks/interaction-contract.json` is the Hub's contract with this plugin.** The Hub byte-copies it
to its own `tests/fixtures/interaction-contract.json`, and its `plugin.rs` reads this file of every
installed copy of the plugin and shows the capability in its move dialogs only while every copy
that applies declares contract 1 with protocol 1, the pointer path, the 262144-byte line bound and
the courier's identifier and team. `test-session-hub-interaction.sh` I1 pins it here byte for byte.
Changing any field is a contract change: raise `interaction.contract` and change the Hub in step.
The unit file holds the launcher's constants to the file.

**Who trusts whom.** The launcher trusts the courier only after
`/usr/bin/codesign --verify --strict -R=<requirement> <courier>` exits 0, where the requirement is
`anchor apple generic and certificate leaf[subject.OU] = "3P6C5C4S5B" and identifier
"dev.zensu.session-hub.courier"`, the one the Hub's packaging signs the courier for. The `-R=` and
the requirement text travel as one argument: codesign reads an argument that starts with `=` as
requirement text, so `-R==…` is a syntax error. Measured on 2026-11-28 with an empty environment,
as the launcher runs it: `/bin/ls` against `anchor apple` exited 0 and against the courier's
requirement exited 3. The courier trusts the Hub only through the audit token of the socket's peer,
and the Hub trusts the courier through the same check and through the courier's process chain,
which must lead to the engine of a live session the Hub samples. The pointer the Hub writes is only
a hint: a courier that fails the check is never started, whatever the pointer names.

**The option.** `allow_unsigned_courier`, a boolean that is off by default, admits a courier that
fails the codesign check, but only under its own file name, `zensu-session-hub-courier`, which is
the rule the Hub's debug builds apply to their peers. It exists because a development build of the
Hub runs with a courier that Cargo built without the release signature, and it belongs only on
development Macs. Claude
Code keeps it under `pluginConfigs["session-hub@zensu"]` in the user's settings and ignores project
and local entries, so a cloned repository cannot switch it on. The launcher reads no environment
for it: the caller passes `allowUnsigned`, a hook from `CLAUDE_PLUGIN_OPTION_ALLOW_UNSIGNED_COURIER`
and a module from `options.allow_unsigned_courier`, and `unsignedAllowed` accepts only `true` and
`"true"`.

**The pointer.** `<config root>/zensu/session-hub/v1/hub.json`, with the config root of the usage
feed: `CLAUDE_CONFIG_DIR`, trimmed, when it names an absolute path, nothing for a relative one, and
`$HOME/.claude` otherwise. The launcher opens it with `O_NOFOLLOW` and `O_NONBLOCK`, reads it only
when it is a regular file of at most 64 KiB owned by the user, and takes `socket` (absolute, at most
103 bytes, the limit of a Unix socket address) and `courier` (absolute) only while `schemaVersion`
and `protocol` are 1. Unknown fields are ignored.

**The relay.** `relay(request, settings)` turns the request into one line, `{"v":1,…}` with a
newline, at most 262144 bytes, and refuses another `v`; reads the pointer; checks the courier; and
only then starts it as `<courier> --socket <socket> --wait <seconds>` (1 to 3600, default 10) with
an empty environment, the line on standard input and standard error discarded. It reads at most
262144 bytes of standard output and stops the courier when the reply is longer or when the wait
and a 5-second start allowance have passed. It answers `{ ok: true, reply, trust }`, with `trust`
`signed` or `unsigned`, or `{ ok: false, reason }`: `request`, `no-pointer`, `untrusted`, `spawn`,
`usage` (exit 64), `no-hub` (69), `transport` (74), `unverified` (77), `exit` (any other exit),
`reply` (not exactly one protocol-1 object on one line) or `timeout`. A reply is accepted only as one
line that ends in a newline and holds an object with `"v": 1`. The launcher writes nothing.

## Tests

- `tests/structure/session-hub-courier-v1.test.js` (22 cases): the constants against the contract
  and the manifest's option, the config root ladder, the pointer path and every refusal of the
  pointer, the request and reply line rules, the codesign arguments, bound and empty environment,
  a real refusal of `/bin/ls`, which also holds on Linux, where no `codesign` exists, the trust
  rule, and the relay against a stand-in courier that a test runs through `process.execPath`:
  its arguments and environment, every exit, every malformed reply, a courier that never answers
  and one that cannot start, and that nothing starts before the request, the pointer and the
  courier passed.
- `tests/structure/test-session-hub-interaction.sh`, in `ciStructureTests` and in
  `.github/scripts/session-hub-release-gate.sh`: I1 the contract bytes, I2 the unit file, I3 the
  manifest's `userConfig`, I4 the launcher's static `node:` imports. `test-session-hub-plugin.sh`
  H1 lists the two new files and H2 the manifest's `userConfig` key.

## Coupled sites

The contract here, the Hub's `tests/fixtures/interaction-contract.json` and `interaction_of` in its
`src-tauri/src/plugin.rs`; the requirement, which the Hub spells in `src-tauri/src/courier/peer.rs`
and signs for in `scripts/release-policy.mjs`; the courier's exit codes, `courier::Failure` in the
Hub; the socket bound, `wire::MAX_SOCKET_PATH`; the line bound, `wire::MAX_LINE`; and the pointer's
fields, which the Hub's `src-tauri/src/interaction.rs` writes.

## Version

A minor release of the companion: a new contract file, a new library module and a new user option,
and no change to what a hook or the module does. Nothing in PLM's tree changes, so PLM's runtime
lineage is untouched.

## Known gaps

- Between the codesign check and the start lies a short window in which the file can be replaced.
  The Hub's plan accepts it: whoever can do that can already change Claude's own configuration.
- The check has not yet met a courier from a signed Session Hub release, because no release carries
  one yet; the Hub's packaging verifies the bundled courier against the same requirement.
- The spelling Claude Code gives a boolean option in `CLAUDE_PLUGIN_OPTION_*` is not measured; step
  3 measures it when its hook first reads the option.
- With the option on, any file named `zensu-session-hub-courier` passes, which is why the option is
  for development Macs only.
- A `CLAUDE_CONFIG_DIR` other than the root the Hub writes under finds no pointer, as it finds no
  receipt; the Hub also samples sessions only below `$HOME/.claude`.
