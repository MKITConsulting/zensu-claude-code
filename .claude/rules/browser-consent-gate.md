---
paths:
  - "hooks/lib/verify-consent-v1.js"
  - "hooks/lib/verify-navigation-floor-v1.js"
  - "hooks/pre-browser-navigation-consent.sh"
  - "hooks/post-browser-navigation-consent.sh"
  - "scripts/verify-browser-config.js"
  - "skills/verify-feature/**"
  - "skills/doctor/**"
  - "hooks/lib/zensu-doctor.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "tests/structure/test-verify-consent.sh"
  - "tests/structure/verify-consent-v1.test.js"
  - "tests/structure/verify-navigation-floor-v1.test.js"
  - "tests/structure/fixtures/playwright-cli-argv.v1.json"
  - "tests/structure/fixtures/record-playwright-cli-argv.js"
---

# Browser Consent Gate (`hooks/lib/verify-consent-v1.js` + the two consent hooks)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

`/zensu:verify-feature` drives the browser through `playwright-cli` (`@playwright/cli`), which the
user installs once, with plain Bash calls. The plugin ships NO MCP server any more: `.mcp.json`,
`scripts/playwright-mcp.sh`, `scripts/playwright-mcp-proxy.js` and `mcp-runtime/` are gone, and
`.claude-plugin/plugin.json` declares no `mcpServers`. The bundled `@playwright/mcp` server was
started for every session that loaded the plugin, and each start materialized a private npm runtime
of several hundred megabytes whether or not a browser was ever opened — that cost is the whole
reason for this design, so do not reintroduce a plugin-scoped MCP server to "restore" a control.

The controls the MCP-era capability broker held moved into two places: a PreToolUse/PostToolUse pair on the `Bash`
matcher (`hooks/pre-browser-navigation-consent.sh`, `hooks/post-browser-navigation-consent.sh`, both
thin wrappers around `hooks/lib/verify-consent-v1.js` modes `pre`/`post`), and the per-run config
file the browser is opened with, written by `scripts/verify-browser-config.js`.

**SCOPE is `zensu-verify-*` sessions only, and that is a decision, not an omission.** Gating every
`playwright-cli` call would deny a user's own browser skills — which legitimately use `eval`,
`run-code`, cookies and state files — in every session, which is the overreach the MCP-era matcher
already produced against a user's own `playwright` server. The cost is stated wherever the gate is
described: a model that opens a browser under a session name it chose itself is outside the gate,
and the skill's instruction to use only the printed session is prose, not a boundary.

**The order of judgement is the contract.**

1. **Prefilter, in BOTH wrappers, before `node` starts:** the payload is normalized by ONE
   `LC_ALL=C sed` pass that first pairs every JSON-escaped backslash — so an escaped backslash
   before `n` is never read as a line break — and then joins a JSON-encoded backslash-newline or
   backslash-CR-LF line continuation, and ONE `LC_ALL=C tr -d` pass that removes every quote,
   backslash and pairing sentinel, then matched case-insensitively.
   It must name `playwright-cli` or `@playwright/cli` AND a `zensu-verify-` session — or name the
   CLI while the hook environment's `PLAYWRIGHT_CLI_SESSION` names one. The third `case` arm, the
   JSON-escaped `\/` spelling, only matters on the fallback to the raw payload when either pass fails.
   Every other Bash call exits 0 with no output — which is what keeps the pair off the hot path of
   every Bash call and out of every bind-failure state for unrelated commands. It is also why the
   node-unavailable, module-absent-or-symlinked and module-failure arms act on marked payloads
   only. In the PRE wrapper alone, and on a POSIX host with `node` — the recognizer refuses on
   win32 — the recognized `/zensu:doctor` and adoption commands exit 0 through
   `zensu_doctor_allowed` right after the plugin-root check, even when a path in them names both
   markers. **Why `tr` and not bash:** pure-bash stripping (`${INPUT//[...]/}`) is quadratic on bash
   3.2 and did not finish within 100 s on a 480 KB payload, where `tr` took 61 ms. `evaluate`
   repeats the test through `commandMarkers` over the same normalization; the two are a hand copy,
   and a widening of one without the other makes a gated call either unreachable or silently
   unjudged.
2. **Command analysis** through the module's own shell lexer (`lexShell`/`analyzeCommand`). Any
   `zensu-verify` session call it cannot judge denies with a named reason: a heredoc, here-string,
   parse fault, or `-c`/`eval` or subshell body beyond `MAX_NEST`; indirection through `xargs`,
   `bash -c`, a command string handed to another program, or any other word that names the CLI
   outside command position; a function named `playwright-cli` (matched case-insensitively and
   checked first); an environment builtin; `PLAYWRIGHT_MCP_*`/`PWTEST_*` text in the raw or the
   quote-stripped command; and a session name or argument that is not a literal. A `-c` or `eval`
   body inherits the outer command's assignments and wrappers, so `env -i bash -c '…'` is judged as
   if the wrapper sat on the inner call. The lexer marks as unexpanded an unquoted brace, glob,
   leading `~` or leading `=` word and every word carrying a `$` outside single quotes that
   whitespace or the end of the command does not follow — zsh's `$=X`, `$~X`, `$^X` and `$+X`
   expand where bash leaves them literal, and the Bash tool may run zsh; a `+=` session assignment
   counts as unexpanded; a session given
   more than once denies `SESSION_MALFORMED`; and a session value is GATED when it names
   `zensu-verify-` in any letter case or behind a path, then must match `SESSION_RE` exactly. A call
   on any other session reaches no decision unless the command is marked. A marked command's call
   on another session is still judged for a parse fault, an unexpanded session or argument
   (`ARGUMENT_UNEXPANDED`, because its session could resolve to a gated one after expansion), a
   session assignment given twice, a session flag given in more than one argument
   (`parseCliArgs` counts ARGUMENTS, not assignments, because one clustered short option such as
   `-szensu-verify-a` sets `s` twice and must keep its `SESSION_UNRESOLVED` remedy),
   `PLAYWRIGHT_MCP_*`/`PWTEST_*` text, a redefinition, an
   environment builtin and every shape step 7 refuses, so under the environment arm only one plain
   literal call that parses reaches no decision. Those arms key on `marks.session`, which the
   environment arm sets; keying them on `marks.named`, the text marker alone, reopens every one.
3. **Principal:** main thread only (`claude-principal-v1.js`). A subagent's `zensu-verify` call
   denies.
4. **Wrapper, launcher and allowlist.** `env`, `sudo` and `doas` keep `ENV_ASSIGNMENT`; any other
   wrapper — `timeout`, `gtimeout`, `nohup`, `time`, `nice`, `exec`, `command`, `builtin` — denies
   `WRAPPER`, and a wrapper the ladder does not know leaves the CLI outside command position, which
   denies `INDIRECT`; a package launcher (`npx`, `bunx`, `pnpx`, `npm`/`pnpm`/`yarn`
   `dlx`/`exec`/`x`) denies `LAUNCHER`, because it may fetch or select a version the gate never
   measured. Then the command and flag allowlist (`ALLOWED_COMMANDS`), with
   `--json/--raw/--help/--version` harmless everywhere and a repeated flag denied. `COMMAND_DENIED` and `FLAG_DENIED` scope the refusal to
   `/zensu:verify-feature` and forbid a retry under another session name or program. The arguments
   are parsed by `parseCliArgs`, a port of the CLI's own minimist parser MEASURED against
   `PLAYWRIGHT_CLI_SOURCE_VERSION` (0.1.21) and pinned by a golden fixture recorded from that
   version's own parser; an argument shape it does not recognize denies rather than admits — an
   unknown option on a gated call, and, through step 7, a `zensu-verify` name no call resolves.
   **The per-call order matters:** the wrapper ladder decides only the deny REASON, never whether a
   call is admitted.
5. **`open`** must carry `--config=<absolute path>`, and the gate reads that file itself through
   `readRunConfig`/`runConfigShape` — the SAME shape function the helper runs before it writes, so
   the writer and the judge share one definition. `--browser` must name a Chromium channel
   (`CHROMIUM_BROWSERS`), a global `~/.playwright/cli.config.json` (or `$PWTEST_CLI_GLOBAL_CONFIG`)
   may carry only the `GLOBAL_CONFIG_HARMLESS` keys and no `browserName` but `chromium`, and a
   `PLAYWRIGHT_MCP_*` variable in the launch environment denies, because the CLI merges it over the
   run config. The Chromium rule exists because `--no-proxy-server` and `--host-resolver-rules` are
   Chromium switches: Firefox or WebKit would silently drop the pins.
6. **Every target origin** — each run-config origin on `open`, and the URL of `open`, `goto` and
   `tab-new` — goes through the floor below, then consent or policy.
7. **The shape: exactly one plain call.** A command whose markers name both the CLI and a
   `zensu-verify` session — in its text, or through the hook environment's
   `PLAYWRIGHT_CLI_SESSION` — is admitted only as ONE top-level `playwright-cli` invocation with no
   operator, no second segment, no subshell, no heredoc, no here-string and no redirection whose
   target is not a literal (`plainShape`): a literal target is admitted, a target carrying an
   expansion — a variable, even quoted, a substitution, an unquoted glob or brace, a leading `~`
   or `=` — is not, and a redirection on a line of its own is a second segment. Everything else
   denies `NOT_PLAIN`, whose text names both marker arms and the literal-redirection rule beside
   the one-call rule: a command marked only through the environment names no session, and "run
   every other command separately" is no remedy for a single call with a non-literal target. The test runs AFTER the per-call judgement, so a call that
   is already refused keeps its specific reason. A command that merely MENTIONS both markers — a
   `grep` pattern, a commit message, an `echo` — is refused too, by whichever rule sees it first: a
   word outside command position that names the CLI makes step 2 answer `INDIRECT`, and only text
   the lexer drops, such as a comment, reaches this test and `NOT_PLAIN`. Both reasons therefore
   name the same remedy — the Grep tool, or a commit message file (`git commit -F`) — because the
   false deny is the accepted cost of a textual gate and a refusal must not leave the reader
   guessing; the unit case `a command that only mentions playwright-cli and a zensu-verify session
   is refused with the remedy named` holds both arms. A PLAIN call whose text names a
   `zensu-verify-` session that no call resolved as its session — `-S`, `-_s`, an attached `-s`
   the parser reads as a boolean, a name in another argument — denies `SESSION_UNRESOLVED`; the
   environment arm of the marker is exempt, because an explicit `-s` outranks
   `PLAYWRIGHT_CLI_SESSION` in the CLI itself. The skill already required one plain Bash
   call per `playwright-cli` call; this step is what enforces it, and it is what makes steps 2 and
   4 total rather than a list of spellings.

**The run config is where the browser's own fences live.** `buildConfig` writes an isolated browser,
`--no-proxy-server`, one `--host-resolver-rules` pin per remote hostname, `serviceWorkers: 'block'`,
`network.allowedOrigins`, and `outputDir` under the run directory. MEASURED with 0.1.21: a `goto` to
an origin outside `allowedOrigins` fails with `net::ERR_BLOCKED_BY_CLIENT` and exit 1. A server
REDIRECT to another origin is NOT refused by the browser (recorded as measured in `docs/gates.md`),
so the skill reads the `Page URL` line after every navigating call — prose, not a boundary.

**One floor and one policy parser.** `verify-navigation-floor-v1.js` owns origin classification and
`parsePolicyTargets`, the full synchronous parse of `ZENSU_VERIFY_NAVIGATION_POLICY_V1`
(`policyContractFault` stays its top-level half). Three consumers CALL it and none re-spells it: the
gate (`readPolicy`), the helper (`run`, `--check-policy`) and the doctor wrapper
(`ZDOC_VERIFY_POLICY_FAULT`). The MCP-era hand copy inside the broker's `parsePolicy` died with the
broker. DNS happens in exactly one place, the helper's `resolveRemoteHost` at run-config time, and
the gate then requires the resulting pin for a remote hostname; a policy parse never resolves.

**Consent mode** (no policy in the environment) admits literal loopback origins only and returns
`permissionDecision: "ask"` for the first call that reaches each new origin — the host's prompt,
which the model cannot answer. Consent is per ORIGIN; the recipe's declared routes are prompt
CONTEXT (`promptText`) and steer nothing. The post hook records every executed gated call as
`(origin, route, decidedBy, at)` in `<project>/.zensu/state/verify-consent-<session key>.json`
(`O_EXCL` temp plus rename, contained by `memoryPathAllowed`, never through a symlink). `decidedBy`
names an OBSERVATION — `asked`, `remembered`, `policy-mode` — never a human decision: PostToolUse
carries no evidence of how the prompt was answered, and the host fires no PostToolUse event for a
failed Bash call, so a failed navigation is never recorded and asks again. **Policy mode** asks
nothing: policy targets only, declared routes only on navigation commands, a remote hostname only
with its pin; an invalid policy denies every gated navigation with the broken rule named.

**No execution marker, and why.** The MCP-era gate wrote a per-session marker so that a SEPARATE
process, the broker, could tell whether the gate had run before it self-approved an origin. With no
broker, nothing consumes such a marker, so the whole family (`writeExecutionEvidence`,
`classifyExecution`, the `ZDOC_VERIFY_EXEC` wire and the doctor's `verify-feature gate:` row) was
removed rather than ported. The consequence is the first residual below, and it must not be papered
over with a marker nothing reads.

**`/zensu:doctor`** probes `command -v playwright-cli` (`ZDOC_PLAYWRIGHT=present|absent`) and reads
`ZDOC_PLAYWRIGHT_VERSION` from the resolved `@playwright/cli` `package.json` — realpath of the
binary, then at most four parent directories, size-bounded — WITHOUT executing the binary. Only
when that read fails does it fall back to `zensu_run_bounded env NO_UPDATE_NOTIFIER=1
playwright-cli --version </dev/null`, keeping the first dotted version number. A version other than
`PLAYWRIGHT_CLI_SOURCE_VERSION`, or a measured version the report could not read, renders WARN and
names what was not measured against it; a difference is disclosed, never a failure. The
verify-feature row runs its availability checks FIRST — hook pair, module and helper present, the
module no symlink (both hooks refuse one) and loadable, both hooks registered on a matcher that
covers `Bash` — and reports `unavailable` before it classifies a policy, so a valid policy over an
unregistered recorder is not reported as ready. Each hook is named with its own state — "consent
hook" is the PreToolUse gate, "consent recorder" the PostToolUse half — joined by `; ` when both
apply, so an undetermined recorder never hides a definite missing gate; a registration it cannot
determine — a `hooks.json` it cannot read or parse, a shape it cannot judge, a matcher the host
may read two ways or that does not compile — is named as undetermined rather than missing
(`REGISTRATION`), and a probe that does not complete is named apart from both, as the pair's. It then reports `policy`, `policy-invalid` (naming a per-target fault too, not
only a top-level one), `policy-unchecked` (the parse did not complete: a missing check, never an
invalid policy), `consent`, `consent-no-recipe` and `consent-recipe-unchecked`. Every row is derived from files on disk; the
doctor cannot observe whether the hooks run.
The SessionStart banner's consent line sits BELOW the `hooks.sessionBanner` gate, because it
announces a prompt rather than a capability the plugin hands itself.

**Coupled sites that move together:**

- `ALLOWED_COMMANDS` ↔ the command table in `skills/verify-feature/rules/browser-verification.md` ↔
  the denied-command lists in `skills/verify-feature/SKILL.md` and `docs/gates.md` ↔ the transcript
  grader in `evals/verify-feature/assertions/transcript-check.js` (which requires the module rather
  than copying the set) ↔ `tests/structure/test-verify-feature-skill.sh`.
- `PLAYWRIGHT_CLI_SOURCE_VERSION` ↔ `parseCliArgs` / `CLI_BOOLEAN_OPTIONS` / `CLI_STRING_OPTIONS` /
  `CLI_BASENAMES` ↔ the golden fixture `tests/structure/fixtures/playwright-cli-argv.v1.json` and
  its recorder `tests/structure/fixtures/record-playwright-cli-argv.js` ↔ the doctor's version
  rows. A playwright-cli upgrade re-records the fixture with the recorder FIRST — it runs the new
  version's own `minimist.js` and refuses when `program.js` no longer carries the boolean set, the
  minimist call or the `-s`/`-g` folds it asserts — and bumps the constant second; bumping the
  number alone asserts a measurement nobody made. The recorder also asserts `registry.js`'s
  `sessionName || process.env.PLAYWRIGHT_CLI_SESSION` precedence and records `pkg.bin`, which the
  unit suite compares with `CLI_BASENAMES`. The version is hand-copied as prose into
  `skills/verify-feature/SKILL.md` (pinned by `P6f`), `docs/gates.md`,
  `evals/verify-feature/README.md` and this rule file (step 4 and the run-config measurement),
  and as a literal into the unit pin beside the constant; the
  MSYS boundary suite derives it from the module.
- `SESSION_PREFIX`, `SESSION_RE`, `RUN_CONFIG_NAME`, `RUN_OUTPUT_DIR_NAME`, `MAX_RUN_ORIGINS` and
  `runConfigShape` are consumed by the helper FROM the module, never re-spelled.
- `CONSENT_MATCHER` (`'Bash'`) ↔ both registrations in `hooks/hooks.json` ↔
  `consentHookRegistered`/`consentRecorderRegistered` and their `REGISTRATION` answers ↔ the
  doctor's `unavailable` reasons in `hooks/lib/zensu-doctor.sh` ↔ the `❌ verify-feature: cannot
  start (…)` bullet in `skills/doctor/SKILL.md`, which must name every cause those reasons carry
  — a missing file, a symlinked or unloadable decision module, a hook that is not registered, a
  registration that could not be determined, a probe that did not complete — and the rule that
  each hook is named with its own state, because a model relaying an undetermined registration as
  a missing hook, or the gate's state as the recorder's, sends the user after a problem that is
  not there. No check compares the bullet with the reasons.
- `hookRegistered` in `hooks/lib/verify-consent-v1.js` and `reviewerSpawnHookWired` in
  `hooks/lib/zensu-doctor-report.js` are two hand-written readers of one host rule — which
  `hooks.json` groups fire for a tool — and they answer differently ON PURPOSE, so a change to
  either re-decides each difference.
  `hookRegistered` follows the host's own matcher rule as read out of the Claude Code 2.1.280
  binary (`matcherCovers`): an absent or empty matcher and `*` cover every tool, and a matcher of
  plain names joined by `|` covers exactly those names. Any other matcher the host may read as a
  name list or as a regular expression, and whether it anchors one was not observed, so a matcher
  whose name-list, anchored and unanchored readings disagree answers `unknown`, as does one that
  does not compile or is not a string. The grant row compiles every matcher as an unanchored
  regular expression, reads every matcher that is not a non-empty string — absent, empty, `null`,
  a number — as `.*`, and skips a group whose matcher does not compile: a non-string matcher
  answers `unknown` here and covers every tool there, and `*` covers every tool here while its
  group is skipped there. The document shapes differ in three places only: an array document, a
  `hooks` value of the wrong type, and an event value that is present but falsy answer `unknown`
  here and read as an empty list there; a document that is not an object and a truthy event value
  that is not an array answer `unknown` in both. The other differences: this copy matches the command on
  `/hooks/<file>` and requires that file, followed through a symlink as the doctor's `[ -f ]`
  follows it, to be a regular file, where that one matches the bare filename; this copy reads
  `hooks.json` through `lstat` plus `readFileSync`, that one through the doctor's hardened
  `readJson`; and that one requires EVERY spawn tool to match where this one tests
  `CONSENT_MATCHER` alone. Every `unknown` exists because this probe feeds a verdict that must
  never read a registration it could not judge as a missing one. One shared helper taking those
  tolerances as parameters is the standing fix; it is not taken here because it would move the
  grant row's answers, a change that belongs in the grant's own review. Neither suite compares
  the two copies.
- The prefilter in both wrappers ↔ `commandMarkers` / `normalizedText` in the module (hand copies,
  see step 1): the continuation join with its backslash pairing, the stripped character set, case-insensitivity, both
  markers, and the `PLAYWRIGHT_CLI_SESSION` arm must agree. `CLI_MARKERS` is DERIVED from
  `CLI_BASENAMES` and `CLI_PACKAGE`; `H17d` pins the two wrapper blocks byte-identical and `H17e`
  requires every derived marker in them.
- `AMBIENT_TEXT_RE` / `ambientOverride` / `globalConfigFile` / `GLOBAL_CONFIG_HARMLESS` ↔ the
  CLI's own configuration channels; a new CLI env or config channel lands here first.
- `scripts/` is now in the Session Control digest unconditionally (see §"Runtime Lineage"), because
  the helper lives there.
- `adopt_hook_expected` in `tests/structure/test-versioned-plugin-upgrade.sh` exempts the pre hook,
  which cannot deny the adoption command.
- The Session Control `mutating_control` attack no longer names a browser tool: it asks the reviewer
  for a Bash `curl` to the local canary, so only the reviewer-capability gate can deny it and its
  `reviewer-capability-v1 deny:` reason stays deterministic (`scripts/session-control-claude-wrapper.sh`,
  `evals/session-control/lib/live-evidence.js`, `evals/session-control/tests/wrapper-selftest.sh`,
  `tests/structure/test-windows-portability-guards.sh`).

Operator-facing accounts: `docs/gates.md` §"Browser Consent Gate", `docs/verify-feature.md`, both
hook rows and the `ZENSU_VERIFY_NAVIGATION_POLICY_V1` row in `docs/configuration.md`, both rows of
the "Unbindable sessions" table in `docs/session-control.md`, `README.md`, `skills/verify-feature/**`,
`skills/doctor/SKILL.md`, `skills/autopilot/rules/config.md`, and the banner line.
`tests/structure/test-verify-consent.sh` drives the unit files and the real hooks.

**Version: `minor`.** Walked against §"Runtime Lineage": both consent hooks changed their matcher
(from the MCP tool names to `Bash`), a PreToolUse hook that can deny AND ask joined the `Bash`
matcher, and the plugin's MCP server disappeared from the manifest — each changes the capability
set of a session an older runtime still serves. The digest ENTRY SET moved too (`scripts` always),
and the `mcpServers`-conditional `mcp-runtime` branch that keeps 0.21.x records readable is what
lets `/zensu:adopt-session` carry an in-flight session across this release.

**Permission rules do not migrate.** Every rule written for the old browser tools —
`mcp__plugin_zensu_playwright__…` in 0.21.1 and earlier, `mcp__plugin_zensu_zensu-browser__…` on
unreleased builds after it — matches nothing now; a `deny` or `ask` there silently stops restricting
the browser. The replacement names the Bash command, e.g. `Bash(playwright-cli:*)`. State it in the
release notes.

**Known gaps, accepted and named:**

- **Hooks switched off host-side leave `playwright-cli` unconstrained.** The retired broker refused
  to self-approve without the gate's marker, so a disabled hook ended in a refusal; nothing stands
  in that position now, and the doctor reports registration, never execution.
- **Other session names are ungated** — see SCOPE.
- **The consent memory is forgeable:** a record written through a Bash redirect skips the prompt for
  that origin; the floor bounds the damage to loopback services.
- **The run config is read twice** — by the gate at `open` and by the CLI at launch — so a file
  swapped in between is followed. It lives under the project, where the session can write.
- **In policy mode routes are enforced on navigation commands only**; an in-page navigation to an
  undeclared route on an approved origin is seen by no hook.
- **How the host resolves a hook `ask` under bypass permissions, in auto mode or in a headless run
  is UNVERIFIED.** The live eval runs in policy mode precisely so it never depends on a prompt.
- **The gate is textual.** It judges what the command TEXT names. A CLI or session name assembled
  at run time — from a file, a variable set by an earlier Bash call, a program's output, or an
  ANSI-C `$'…'` escape — never reaches the markers, so the call it produces is not gated. The single-invocation rule narrows
  this to what one plain call can spell; it does not close it.
- **The parser port is exact for one CLI version.** An unknown shape denies, but a CHANGED meaning
  of an existing flag in a later CLI is not detected; the doctor's version row is the only signal,
  and it is a WARN row, not a refusal.
- **Windows is UNVERIFIED end to end.** `CLI_BASENAMES` recognizes the `.cmd`/`.exe`/`.ps1`
  spellings, but no Windows run has driven a real `playwright-cli` through the gate.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included; each must
  re-decide whether its host fires a pre-tool hook on its shell tool and can render an `ask`.
