# Session Hub interaction channel: the companion's side (step 2)

## Goal

Step 2 of the Zensu Session Hub's plan for answering a waiting session from the Hub
(`docs/plans/2026-11-19-session-interaktion-plan-1.md` in `MKITConsulting/zensu-session-hub`)
builds the channel between the companion plugin `session-hub@zensu` and the Hub. The Hub side
(the courier binary, the socket server, the pointer and the contract reader) lands in the Hub's
own pull request. This plan covers the companion's side: the contract file the Hub reads, the
option that admits an unsigned development courier, and the launcher a later hook and the module
use to start the courier. Nothing a user sees changes; no hook or module starts the launcher yet.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Contract file | `plugins/session-hub/hooks/interaction-contract.json`, one line, byte-identical to the Hub's `tests/fixtures/interaction-contract.json` | The Hub's `plugin.rs` reads it like the handover contract's `linkedSessions` and shows the capability in its move dialogs. |
| Courier check | `/usr/bin/codesign --verify --strict -R=<requirement>` before every start, with an empty environment and a 10-second bound | "Trust the signature, never the pointer." The requirement is the one the Hub's packaging signs the courier for. |
| Development option | `userConfig.allow_unsigned_courier`, a boolean, off by default | The Hub's plan puts it under `pluginConfigs` in the user's settings; Claude Code ignores project and local entries. With it on, a courier that fails the check passes only under its own file name, the rule the Hub's debug builds use. |
| Who reads the option | The caller passes `allowUnsigned`; the launcher reads no environment | A hook reads `CLAUDE_PLUGIN_OPTION_ALLOW_UNSIGNED_COURIER`, the module `options.allow_unsigned_courier`. |
| Config root | The usage feed's ladder: an absolute `CLAUDE_CONFIG_DIR`, else `$HOME/.claude` | One rule for every Hub file the companion touches. |
| Tests | A new suite `test-session-hub-interaction.sh` with the unit file `session-hub-courier-v1.test.js` | Step 3 extends the same suite with its hook. |

## Requirements

| ID | Requirement | Evidence |
|---|---|---|
| AC-P1 | The companion ships `hooks/interaction-contract.json` byte-identical to the Hub's fixture, pinned here. | `cmp` against the Hub's `tests/fixtures/interaction-contract.json`; I1. |
| AC-P2 | The manifest declares exactly one option, `allow_unsigned_courier`, a boolean that is off by default, and `claude plugin validate` accepts the manifest. | I3; unit case 2; `claude plugin validate plugins/session-hub` on 2.1.332 passed. CI repeats it on 2.1.296 and 2.1.317. |
| AC-P3 | The launcher starts the courier only after the pointer and the codesign check passed, with the pointer's socket, a bounded wait and an empty environment, and maps every courier exit and malformed reply to a reason. | Unit cases 16 to 22. |
| AC-P4 | An unsigned courier is admitted only with the option on and only under its own file name. | Unit cases 5, 15 and 22. |
| AC-P5 | The new suite runs in CI and in the companion's release gate, and the registry, the classification and the overview agree. | `ciStructureTests`, `unit-files.v1.json`, `session-hub-release-gate.sh`; `lib-unit-registry.js` census, drivers and render checks exit 0; `test-unit-registry.sh` 22/22. |

## Steps

| Step | Status | What |
|---|---|---|
| P1 | done | Contract file, copied from the Hub's fixture. |
| P2 | done | `userConfig` option; H1 and H2 of `test-session-hub-plugin.sh`. |
| P3 | done | `hooks/lib/session-hub-courier-v1.mjs`. |
| P4 | done | Unit file and suite; classification, registry, overview, release gate. |
| P5 | done | README section, `.claude/rules/session-hub-interaction.md`, the CLAUDE.md index line. |

## Evidence

- `node --test tests/structure/session-hub-courier-v1.test.js` on Node 26.13.1: 22/22.
- `bash tests/structure/test-session-hub-interaction.sh`: 5/5.
- `bash tests/structure/test-session-hub-plugin.sh`: 88/88.
- `bash tests/structure/test-unit-registry.sh`: 22/22.
- `claude plugin validate plugins/session-hub` with Claude Code 2.1.332: passed, one pre-existing
  icon warning.
- `env -i /usr/bin/codesign --verify --strict '-R=anchor apple' /bin/ls` exited 0 and the same
  call with the courier's requirement exited 3.

## Not verified

- The full `tests/run-all.sh --ci` and the release gate with its install probe were left to CI.
- The check against a courier from a signed Session Hub release: no release carries one yet.
- The spelling Claude Code gives a boolean option in `CLAUDE_PLUGIN_OPTION_*`; step 3 measures it.
- This repository keeps no `VALIDATION.md`; this plan and the pull request hold the evidence.
