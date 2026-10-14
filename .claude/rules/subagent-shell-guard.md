---
paths:
  - "hooks/lib/subagent-shell-guard-v1.js"
  - "hooks/lib/reviewer-capability-v1.js"
  - "hooks/pre-bash-zensu-gate.sh"
  - "tests/structure/subagent-shell-guard-v1.test.js"
  - "tests/structure/test-reviewer-capability-gate.sh"
  - "skills/gauntlet-loop/SKILL.md"
  - "skills/gauntlet-loop/references/harness.md"
---

# Subagent Shell Guard (`hooks/lib/subagent-shell-guard-v1.js`)

A named neutral `host-profile-v1` subagent may run `Bash`, and `Bash` is the only command tool
it may run. The grant sits in `hostProfileToolViolation` in `reviewer-capability-v1.js`, inside
the allowlist `.claude/rules/reviewer-capability-gate.md` describes: a call that `isShellCall`
accepts (`tool_name` exactly `Bash`) goes through `shellViolation` before the `COMMAND_TOOLS`
check, so the other five names keep `COMMAND_TOOL_DENY` and its search remedy, the literal
`test-gauntlet-loop-skill.sh` G8 pins. Every other tool outside the allowlist stays denied, and
an MCP tool other than the two named Context7 tools and the Zensu MCP tools whose last name
segment `MCP_COMMAND_SEGMENT_RE` matches gets the command deny. The operator
account is in `docs/configuration.md` and `docs/session-control.md`.

**The grant.** `grantRefusal` refuses, in this order: an `agent_type` that is absent, blank,
longer than 512 characters or contains a NUL, carriage return or line feed; a present `agent_id`
of the same unusable shape (an absent one is accepted); a read-only Zensu identity by exact name
(`READ_ONLY_TYPES`, the reviewer, PLM and evidence-worker names of `claude-principal-v1.js`); a
`zensu-review-*` persona, bare or plugin-scoped and in any letter case (`PERSONA_RE`); and a
withdrawn `hooks.subagentShell`. Through the gate a read-only identity never reaches this branch:
`parsePayload` denies a present but unusable `agent_id` or `agent_type`, and `judgePrincipal`
routes the reviewers, the PLM and the evidence workers to their own profiles. The name check is
defence in depth for the module on its own, where `classifySubagent` maps a reviewer with an
unusable `agent_id` to `host-profile-v1`.

**The flag reader.** `strictFlagEnabled` ports `_ZENSU_STRICT_JS` from `zensu-config.sh`: the same
candidates (the `ZENSU_CONFIG` file alone when it is set, else the global file and the project
overlay) and a sticky `false`. An absent candidate is skipped. A present candidate that cannot be
read or parsed, a top-level or `hooks` value that is not an object, and an empty candidate list
each withdraw the grant. The port also withdraws for a candidate that is relative or carries a
line break: a relative `ZENSU_CONFIG` resolves against whichever directory a reader runs in, and
the gate's own process runs in `hooks/lib`. A differential unit test pins `strictFlagEnabled`
against `zensu_hook_enabled_strict`.

**Deny texts.** Every reason reaches the model behind the `reviewer-capability-v1 deny: ` prefix.

- A refused grant: `host-profile-v1 cannot invoke command-execution tools: <cause>. <search
  remedy> Report the need to the main thread instead.` It is `COMMAND_TOOL_DENY`, the
  `grantRefusal` cause, `searchRemedy` and `GRANT_TAIL`.
- A guard refusal: `host-profile-v1 shell guard: <rule>. The guard prevents accidents and is not
  a sandbox; report the need to the main thread instead.` The rule is a `REASONS` entry or the
  git operation it names, the tail is `GUARD_TAIL`, and it carries no search remedy.
- A neutral child's file edit of a config layer: `host-profile-v1 cannot change a Zensu
  configuration layer, because the layers decide the subagent shell grant; report the need to the
  main thread instead`.

**The config layers are authorities.** `configAuthorities` names `~/.zensu` and its
`config.json`, the `ZENSU_CONFIG` file and the `.zensu` overlay of `CLAUDE_PROJECT_DIR` with its
`config.json`, every layer at once rather than the strict candidates. `neutralViolation` denies a
neutral child every `MUTATING_FILE_TOOLS` call below them, because an edit there would re-arm a
withdrawn shell. `configLayerViolation` compares the requested and the resolved spelling of each
path, case-folded on darwin and win32, with each layer resolved against the project root, the
subagent's working directory and `CLAUDE_PROJECT_DIR`, which covers a relative `ZENSU_CONFIG`.
Naming the files as well as the directories puts the target of a linked `config.json` under the
rule. Reads stay allowed. The shell guard protects the same layers through the `.zensu` rule and
by adding each absolute layer file, in its declared and its resolved spelling, to its protected
forms; a layer file adds no protected parents.

**Protected forms.** The state forms are the private plugin data, the installed plugin and the
session record from the trusted binding, plus `CLAUDE_PLUGIN_DATA` and `CLAUDE_PLUGIN_ROOT` when
they are absolute; the config forms are the absolute config layer files. Each counts in its
spelled and its resolved form. The protected parents are the parents of the state forms that are
at least two levels deep, short of `HOME` and its ancestors, and neither the project root nor one
of its ancestors.

**The guard** (`accidentReason`) refuses `run_in_background: true` and
`dangerouslyDisableSandbox: true` outright. It then scans every string of the tool input as text,
after it normalizes backslashes, quotes, `$HOME` and `~`, the `$PWD` and
`git rev-parse --show-toplevel` spellings and MSYS drives, case-folded on darwin and win32: a
mention of a protected form, a `.zensu` segment, or a `/proc/<pid>/environ` path. A raw U+0001 or
U+0002 in the `command` field, the characters the parse uses as its `DYNAMIC` and `PWD_MARK`
markers, becomes U+FFFD first, so only the parse writes a marker; then the field's comments are
blanked. Then `parseScript` parses the `command` field as shell:
single and double quotes, `$'…'`, backslash escapes, `$(…)`, backticks and process substitution,
parameter and arithmetic expansion (a command substitution inside either is a nested script, and
inside an unquoted parameter expansion only single quotes and `$'…'` outside double quotes hide
one), comments, brace expansion, redirections (kept apart from the
command words), heredocs (data with the escapes of an unquoted heredoc, parsed as a script only
when a shell reads them and as code only when an interpreter does, while a `$(…)` in an unquoted
heredoc is judged) and `(`/`)` subshells. Per simple command, in every working directory it may
run in, it checks, in this order:

- a selector assignment in front of the command;
- every word and redirection target, resolved against that directory, in its spelled and its
  resolved form (the longest existing prefix through `realpath`): inside a protected form, equal
  to a protected parent, an unquoted glob that can expand to a protected form or parent or to a
  path inside one (`globReach` matches it segment by segment from its literal directory, with
  the leading-dot rule, and a `..` after a glob segment drops that segment), or an unquoted
  dot-glob that matches `.zensu`. A glob that reaches a protected form is `protectedPath`, one
  that reaches only a protected parent `protectedParent`;
- the command rules, after `env`, `sudo`, `nohup`, `xargs`, `timeout` and their kin are
  unwrapped, with `env -C` and `sudo -D` moving the inner command's directory: `setsid`,
  `disown` and `coproc`, an `eval` body, a Zensu helper name outside `READ_ONLY_COMMANDS`, a
  shell's `-c` body (also when the outer shell expands part of it: the reparse keeps such a part
  unknown, and `$PWD` and `$(pwd)` arrive as the absolute directory the outer shell expanded them
  in), heredoc or here-string, interpreter code that dumps the environment or reads
  a selector (`node`/`bun -e|-p`, `python -c`, `ruby` and `perl -e`, `php -r`, `deno eval`,
  `pwsh -c`, an `awk` or `jq` program, and the heredoc or here-string an interpreter reads as its
  script), a selector builtin or `test -v`, an environment dump (also redirected into a file), a
  destructive git operation (a whole-tree `checkout`, `restore` or `rm` also through an operand
  that resolves to the project root or a parent from the `-C` directory), `claude plugin`, `rm`,
  `rmdir`, `unlink` or `mv` of the project
  root or a parent (a glob is matched segment by segment against the root's components), and a
  `find` that deletes from the root without a name or path test that filters (a negated test or a
  match-all pattern does not);
- the nested scripts of the command.

The parameter expansions the parse records decide the selector rule, so a selector in single
quotes or a quoted heredoc passes. A background job (`&`, a backgrounded subshell included)
without a later `wait` in the same shell is a background shell, like `run_in_background`.

**The working directory** is a set of candidates, because a `cd` can fail. A `cd` or `pushd`
joined by `&&` replaces the set for the rest of that list; any other separator adds the new
directories to the old ones. `cd x || exit` and a `cd` under `set -e` keep only the new
directory. `cd -`, `popd` and a dynamic target fall back to every directory seen so far,
`command cd` and `builtin cd` count, and a subshell restores the set it started with.
`$(git rev-parse --show-toplevel)` stands for the project root. `$PWD`, `$(pwd)` and a `${PWD…}`
whose operator keeps a set value (`:-`, `-`, `:=`, `=`, `:?`, `?`, `VALUE_KEEPING_RE`) stand for
the absolute directory of the command whose word holds them, and `${HOME…}` with those operators
for `HOME`: the parse writes `PWD_MARK`, and `materialized` replaces it per candidate directory
before any rule reads the word, so a `-c` or `eval` body that changes directory and a `git -C` or
`env -C` operand still see the directory the outer shell expanded them in. The text of a heredoc
or here-string that a shell reads is materialized the same way in the command's own directory,
before `env -C` or `sudo -D` moves the inner shell (`shellInput`, built in
`commandItemViolation`), because the outer shell expands it when it sets up the redirection; for
an unquoted heredoc that text is its heredoc-mode parse (`heredoc.expanded`). A command whose set
grows past 64 directories is denied (`directories`).

**Decisions.**

- `Bash` only. The five other shell names have no guard, G8 pins the six-name `COMMAND_TOOLS`
  set and its arity, and `isShellCall` matches `Bash` alone. `Monitor` stays outside the grant:
  the allowlist leaves it out, and `test-reviewer-capability-gate.sh` pins the allowlist deny for
  a named neutral child's `Monitor` command.
- Accident prevention, not confinement. A parse of the command text cannot confine a shell, which
  is why the gate denied every command tool before this grant. A deliberately obfuscated command
  such as `d=.zen; ls "$d"su/state` passes the guard. An OS sandbox is the real boundary.
- A helper name counts only in a command outside `READ_ONLY_COMMANDS` (a `find` with `-exec` is
  outside it), so reading this repository's own hooks and writing a commit message that names one
  stay allowed.
- Code-level environment dumps and selector accessors (`process.env`, `os.environ`, `%ENV`, …)
  are judged inside interpreter code only, so a search, a commit message or a file written
  through a heredoc may name `process.env`. A `/proc/<pid>/environ` path stays a text rule.
- `ZENSU_CONFIG` adds only its own file, and the project root and its ancestors are never
  protected parents: a config file beside the project would otherwise make the project's
  parent untouchable, and removing those directories is the project-root rule's case.
- The CLI gate ignores the inline `ZENSU_MCP_GATE=off` prefix for a subagent, its deny reason
  for a subagent leaves the prefix out, and the guard also denies that assignment.
- `mcpGate: false` and a host-environment `ZENSU_MCP_GATE=off` switch the CLI gate off for the
  subagent too. The operator chose that; the guard does not re-implement the CLI map.
- The CLI gate gates every invocation that `commandInvocations`, this module's walker over
  `parseScript`, or its own token scan finds, on the main thread too. The walker resolves
  reserved words, assignments, `WRAPPERS` with their options, `-c` bodies, a heredoc or
  here-string a shell reads, `eval` and substitutions the same way in both hooks, and an
  assignment in front of a wrapper or a shell reaches the command inside it. The token scan splits
  the text at separators whatever the quoting and keeps every deny it made before, such as a
  `zensu` call after `&&` inside an `ssh` or `su -c` command string, which the walker does not
  run, and its false positive on a heredoc line fed to `cat`. The gate
  runs the walker only when the command holds `zensu` as a word of its own, runs the token scan
  alone when the module cannot load, and keeps only the first line of a verb word, so a word that
  decodes to a line break cannot add a line to its tab-separated output. Its node child emits each
  distinct line once (a `Set`), because the walker and the token scan find the same invocation, and
  the shell resolves the workflow's tools once per run (`zensu_workflow_tools`), so the cost of a
  call no longer grows with repeated invocations. Before either reading runs it compares the
  payload with the binder's exported `MAX_PAYLOAD_BYTES` and turns an oversized `zensu` command
  into the size deny of `zensu_emit_oversized_payload_deny`.
- The parse stays linear in the command length. `braceSpan` is one stack pass that keeps the
  leftmost brace group holding a comma, `endWord` keeps a per-command flag for leading
  assignments, the shell `-c` flag in the walker and in `commandItemViolation` goes through
  `shortFlagsInclude`, `withoutComments` blanks every comment in one join, and the gate trims
  quotes with `unquoted`. Two stars around a literal in one
  regex, or a rescan from every opening character, is the shape to avoid. The unit test "the
  parser stays linear on adversarial input" and B44 in `tests/structure/test-bash-zensu-gate.sh`
  run each shape under a 15 s budget.
- Guidance stays conservative. Skill text keeps every gate, every test whose result counts as
  evidence, every commit and every `zensu` call with the main thread, because the grant can be
  switched off, the guard can refuse, and the guard's helper rule refuses a subagent
  `zensu-log.sh`, the entry point of the evidence runner, so a worker cannot record Zensu
  workflow state.

**Coupled sites.**

- `COMMAND_TOOL_DENY`: G8, `test-reviewer-capability-gate.sh`, and the exact alias reason in
  `evals/session-control/lib/contract-provider.js`.
- The grant refusal: `test-reviewer-capability-gate.sh` (the unnamed child, the withdrawn flag
  and the main-thread tail) and `tests/structure/subagent-shell-guard-v1.test.js`.
- The guard deny and the `REASONS` strings: `test-reviewer-capability-gate.sh`,
  `subagent-shell-guard-v1.test.js`, `contract-provider.js` (`guardTail`, `guardRules`),
  `evals/session-control/lib/live-evidence.js`,
  `evals/session-control/tests/live-evidence-negative.test.js` and the stub denial in
  `evals/session-control/tests/wrapper-selftest.sh`.
- The config-layer deny: `test-reviewer-capability-gate.sh`.
- The neutral sentence of `renderHostContext` in `hooks/lib/session-control-core-v1.js`: pinned
  verbatim in `tests/structure/test-session-control-claude.sh` and
  `evals/session-control/tests/wrapper-selftest.sh`; `test-reviewer-capability-gate.sh` parses
  its allowlist back and compares it with the module's exports.
- The C39 contract marker
  `Contract:GeneralPurpose:host-profile-v1:AllowlistedToolsAllowed:GuardedShell:OtherCommandAndUnlistedToolsDenied`:
  `contract-provider.js`, `evals/session-control/tests/contract-provider.test.js` and
  `evals/session-control/scenarios/catalog.yaml`. The same contract drives the guard deny for
  environment, selector and helper commands, the two documented obfuscation gaps as allowed, and
  the allowlist deny for unlisted tools.
- `commandInvocations`: `hooks/pre-bash-zensu-gate.sh` requires it by path, B38 in
  `tests/structure/test-bash-zensu-gate.sh` drives it, B39a-B39c drive the token scan alone
  through a bound plugin copy without the module, P5n3 in `tests/structure/test-bypass-ledger.sh`
  pins the line-break guard, and the walker test in `subagent-shell-guard-v1.test.js` pins what
  it finds.
- `tests/structure/test-gauntlet-loop-skill.sh`: G0 requires the guard module, G8 pairs the
  skill's guarded-`Bash` claim and its two conditions with `isShellCall`, `CONFIG_KEY` and the
  `agent_type` refusal, G15 pins the allowlist bound, and G16 and G19 hold the skill's and the
  harness's wording about what a critic runs.
- Operator prose: the capability-gate and `subagentShell` rows and the plugin-data guard
  residuals of `docs/configuration.md`, `docs/session-control.md`, the inline-prefix sentence of
  `docs/gates.md` §"CLI Write-Gate" and its plugin-data guard residuals, `docs/review-chain.md`,
  `docs/tdd-manager-workflow.md`, the neutral item and L04 in
  `docs/session-control-release-gate.md`, the C39 summary in `evals/session-control/README.md`,
  `skills/gauntlet-loop/SKILL.md`, `skills/gauntlet-loop/references/harness.md`,
  `skills/ghost-scan/SKILL.md`, `skills/cover/SKILL.md`, `skills/docs/SKILL.md` and the two
  session-trail references `limits.md` and `takeover.md`. Each of them that
  mentions the grant must say that the guard prevents accidents and is not a sandbox.

**Known gaps.**

- The guard is not a sandbox, and obfuscation passes: a variable-assembled path or helper name,
  an unlisted interpreter, code piped into an interpreter or read from a file, a `find -exec`
  command, a pipe into a shell, a command read from a file, `CDPATH`, or a construct the parser
  does not model, such as a `case` pattern inside `$(…)`. `test-reviewer-capability-gate.sh` and
  the C39 contract pin two such commands as allowed.
- A `find … -name … -delete` or `-exec rm` with a name test, started at the project root, can
  still reach `.zensu`.
- A protected parent is denied on a read too (`ls ~/.claude`), and a word that only looks like
  a path is resolved against the working directory like one.
- A `${PWD…}` or `${HOME…}` whose operator can change the value (`%`, `#`, `/`, `:+`, a
  substring) is unknown, so `rm -rf "${PWD%/}"` is not judged as the directory it names.
- The directory set over-approximates: a `||` list such as `cd a || cd b && …` is judged in
  directories it never reaches, and `cd "$X" && rm -rf *` is denied when the session started
  in the project root.
- No hook payload of a Claude Code workflow agent was captured, so the `agent_type` it reports
  is unmeasured; a child without one gets no shell. The agent's transcript meta file names its
  type `workflow-subagent` (read on 2026-10-11), which suggests the payload carries one. L04
  accepts both deny reasons, so it does not measure this either.
- No banner or `/zensu:doctor` row discloses the grant.
- The unit file runs natively on the Windows CI shard; on POSIX hosts its Windows spellings are
  tested with a stub filesystem only.
- On Windows the guard resolves `/` through `realpathSync.native`, which answers the root of the
  drive its own process runs on: under the gate, the drive of the installed plugin's `hooks/lib`.
  So `rm -rf /` counts as a parent of the project only when the project sits on that drive. The
  unit file asserts that drive rule, on the host and through a stub filesystem for both drives,
  instead of an unconditional deny. Its shell-reader differential runs the no-HOME scenario on
  POSIX hosts only, because Git Bash may supply a HOME the test did not pass; that was not
  measured.
- The CLI gate does not see a `zensu` name assembled from variables, a call made from interpreter
  code, a `find -exec` command, a pipe into a shell or a command read from a file. It sees a call
  that `ssh`, `su`, `docker exec` or `kubectl exec` runs only when a separator such as `&&`
  precedes the call in the command text. When the module cannot load, its token scan alone misses
  wrapped, loop and `-c` forms.

**Version: `minor`.** A named neutral child gains `Bash`, and the gates deny more in three places:
a neutral child's file edit of a Zensu config layer, a subagent's `zensu` CLI mutation behind
the inline `ZENSU_MCP_GATE=off` prefix, and a `zensu` mutation the CLI gate now finds behind a
wrapper, in a loop or `-c` body or in `eval`, on the main thread too. A gate that refuses more changes the capability set of
every session a newer installation would serve, which `.claude/rules/runtime-lineage.md` makes
breaking. No persisted shape, strict key set or hook registration changes.
