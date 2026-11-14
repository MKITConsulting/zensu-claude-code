---
paths:
  - "hooks/lib/verify-consent-v1.js"
  - "hooks/lib/verify-navigation-floor-v1.js"
  - "hooks/lib/hook-registration-v1.js"
  - "hooks/lib/playwright-cli-version-v1.js"
  - "hooks/lib/zensu-browser-consent-prefilter.sh"
  - "hooks/pre-browser-navigation-consent.sh"
  - "hooks/post-browser-navigation-consent.sh"
  - "hooks/checks/pre-browser-navigation-consent.sh"
  - "hooks/checks/post-browser-navigation-consent.sh"
  - "hooks/lib/hook-dispatch-v1.js"
  - "scripts/verify-browser-config.js"
  - "skills/verify-feature/**"
  - "skills/doctor/**"
  - "hooks/lib/zensu-doctor.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "tests/structure/test-verify-consent.sh"
  - "tests/structure/test-verify-feature-skill.sh"
  - "tests/structure/verify-consent-v1.test.js"
  - "tests/structure/verify-navigation-floor-v1.test.js"
  - "tests/structure/verify-browser-config.test.js"
  - "tests/structure/playwright-cli-version-v1.test.js"
  - "tests/structure/fixtures/playwright-cli-argv.v1.json"
  - "tests/structure/fixtures/record-playwright-cli-argv.js"
  - ".github/workflows/playwright-cli-drift.yml"
  - ".github/scripts/playwright-cli-drift.sh"
  - "tests/structure/test-playwright-cli-drift.sh"
  - "docs/verify-feature.md"
  - "docs/verify-feature-consent-spec.md"
  - "evals/verify-feature/**"
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

The controls the MCP-era capability broker held moved into two places: a PreToolUse/PostToolUse pair of
hook-dispatcher checks on the `Bash|PowerShell` matcher (`browser-consent` and
`browser-consent-recorder`, whose bodies `hooks/checks/pre-browser-navigation-consent.sh` and
`hooks/checks/post-browser-navigation-consent.sh` are thin wrappers around
`hooks/lib/verify-consent-v1.js` modes `pre`/`post`; the entry points `hooks/pre-browser-navigation-consent.sh`
and `hooks/post-browser-navigation-consent.sh` run only their own check), and the per-run config
file the browser is opened with, written by `scripts/verify-browser-config.js`.

**The dispatcher decides first whether a body runs at all.** `consentMarked` in
`hooks/lib/hook-dispatch-v1.js` starts the check body only for a payload it marks, so it is a third
copy of the marker test beside the library and `commandMarkers`. It must mark every payload the
library marks, and it is broader on purpose: either marker alone, in the raw payload, in the
library's normalization or in the fallback's, and for a PowerShell payload also `wright`,
`verify` or `u{`. A narrower `consentMarked` lets a gated call through with no check at all.
The consent case of `tests/structure/hook-dispatch-v1.test.js` holds the spellings it must mark.

**A PowerShell call is refused, not judged.** The lexer reads Bash, so a PowerShell call that
carries both markers denies with `POWERSHELL_NOT_JUDGED`, one that names the CLI with a run
directory or a config denies with `POWERSHELL_OFF_SESSION_NOT_JUDGED`, both naming the Bash tool
and the Grep tool, and the recorder skips a PowerShell call (`powershell-call`). The markers are
read over `spellings()` of `hooks/lib/powershell-command-v1.js`, which decodes backtick and
Unicode escapes and joins string literals in both the Windows PowerShell 5.1 and the PowerShell 7
reading, and a call that reaches node while that module cannot load is refused. For a PowerShell
payload the prefilter's one `tr -d` pass also drops `+`, parentheses, `$`, blanks and the bytes of
the typographic quotes U+2018 to U+201E, and its one `sed` pass also drops the JSON escapes `\n`,
`\r`, `\t` and `‘` to `„`, so literals joined by `+` read as one word on one line or
across lines (`'play' + 'wri' + 'ght-cli'`); it forwards a text that names `verify` or `config`,
or holds `u{`, and every PowerShell call while the hook environment's `PLAYWRIGHT_CLI_SESSION`
names a `zensu-verify-` session, because a split spelling never names `playwright-cli` literally
and node's `spellings()` decides. `consentMarked` and the pre hook's fallback drop the same
characters for a PowerShell payload and count any of `wright`, `verify`, `config` or `u{` as
marked; `consentMarked` also counts that session variable, which the fallback never reads (H17d).
V70 to V70g, V72, V72b, V72f to V72h and H17g5 to H17g8 pin both halves: V72f and H17g7 split a
marker with raw typographic quotes, V72g and H17g8 with their JSON escapes, and V72h drives the
session-variable arm with a control. `diff_passes_ps` clears an inherited `PLAYWRIGHT_CLI_SESSION`
unless a case names one, because that arm marks every PowerShell call.

**SCOPE is `zensu-verify-*` sessions only, and that is a decision, not an omission.** Gating every
`playwright-cli` call would deny a user's own browser skills — which legitimately use `eval`,
`run-code`, cookies and state files — in every session, which is the overreach the MCP-era matcher
already produced against a user's own `playwright` server. The cost is stated wherever the gate is
described: a model that opens a browser under a session name it chose itself is outside the gate,
and the skill's instruction to use only the printed session is prose, not a boundary. **One
exception, decided after a measured bypass:** a call on any session is judged when its text
names a `verify-feature-runs` directory or passes a config, because a signed-in run config opened
outside the gate restores its state unjudged (see "Other sessions" below). That exception costs a
user's own browser skills something, stated here so it is not rediscovered as a defect: on every
session their own config that restores a state, an INI config, a config the gate cannot read, a
config held in a variable and a relative config handed to a wrapper are refused, and
`STATE_CONFIG_OFF_SESSION` tells them a config of their own must leave the key out.

**The order of judgement is the contract.**

1. **Prefilter, in ONE sourced library, before the module's `node` starts:** both check bodies source
   `hooks/lib/zensu-browser-consent-prefilter.sh` and call its `zensu_browser_consent_marked`. It
   normalizes the payload with ONE `LC_ALL=C sed` pass that first pairs every JSON-escaped
   backslash — so an escaped backslash before `n` is never read as a line break — and then joins
   a JSON-encoded backslash-newline or backslash-CR-LF line continuation, and ONE `LC_ALL=C tr -d`
   pass that removes every quote, backslash, backtick and pairing sentinel, then matches
   case-insensitively. The backtick matters for Bash too: an empty command substitution splits a
   marker without changing what runs, so ``` playwright-cl``i ``` runs `playwright-cli`; `H16q` and
   `H16r` hold that through the real pre hook and the module-absent copy.
   It must name `playwright-cli` or `@playwright/cli` AND a `zensu-verify-` session, a
   `verify-feature-runs` directory, `--config` or `playwright_mcp_config` — or name the CLI while
   the hook environment's `PLAYWRIGHT_CLI_SESSION` names one. For a PowerShell payload the same
   `tr -d` pass also drops `+`, parentheses, `$`, blanks and the typographic quote bytes, the
   `sed` pass also drops the JSON line and quote escapes, and its PowerShell arm forwards `verify`,
   `config` or `u{`, and every call while that variable names a session. The third `case` arm, the
   JSON-escaped `\/` spelling, only matters on the fallback to the raw payload when either pass fails.
   Every other Bash call exits 0 with no output — which is what keeps the pair off the hot path of
   every Bash call and out of every bind-failure state for unrelated commands. It is also why the
   node-unavailable, module-absent-or-symlinked and module-failure arms act on marked payloads
   only. **When the library cannot be sourced**, or sourcing it defines no
   `zensu_browser_consent_marked`, each wrapper falls back to its own test: one `LC_ALL=C sed`
   pass drops the JSON escapes `\n`, `\r` and `\t` WITHOUT first pairing escaped backslashes, one
   `LC_ALL=C tr -d` pass removes quotes, backslashes and backticks, and EITHER marker alone — `playwright` or
   `zensu-verify`, in any letter case, in that text or in the raw payload — counts as marked. That
   text is the whole hook payload, not only the command, so a working directory that names either
   marker marks every Bash call of that project. The pre hook then
   denies `prefilter library unavailable` after the plugin-root check and the `zensu_doctor_allowed`
   exemption, before the `node` check; the recorder skips with the same cause; every call whose
   payload names neither marker still exits 0 silently. A missing library therefore costs false
   denials of unrelated calls whose payload names either marker — in such a project every Bash
   call except the recognized `/zensu:doctor` and adoption commands — AND it lets a gated call
   through unjudged when a backslash before `n`, `r` or `t` splits each marker the test reads:
   `playw\right-cli -s=ze\nsu-verify-x` reaches the scan as `playwight-cli -s=zesu-verify-x`, while
   bash runs `playwright-cli -s=zensu-verify-x`; under the environment arm, splitting
   `playwright-cli` alone suffices, because the fallback never reads `PLAYWRIGHT_CLI_SESSION`. The
   library pairs escaped backslashes first and is not affected (see Known gaps).
   `H17g`–`H17g4`, `V56-control` and `V62-control` pin the fallback. In the PRE wrapper alone, and on a POSIX host with `node` — the recognizer refuses on
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
   `bash -c`, a command string handed to another program, a wrapper `commandPosition` does not
   know (`stdbuf`), which leaves the CLI outside command position, or a word that names the CLI in
   any other command — `scanSegments` skips the words of the call itself, so
   `playwright-cli -s=zensu-verify-x fill e1 playwright-cli` passes this test; a function named
   `playwright-cli` that the command defines (matched
   case-insensitively and checked first — `REDEFINITION_RE` reads the command string, so a
   function or alias the shell already has is invisible); an environment builtin; `PLAYWRIGHT_MCP_*`/`PWTEST_*` text in the raw or the
   quote-stripped command; and a session name or argument that is not a literal. A `-c` or `eval`
   body inherits the outer command's assignments and wrappers, so `env -i bash -c '…'` is judged as
   if the wrapper sat on the inner call. The lexer marks as unexpanded an unquoted brace, glob,
   leading `~` or leading `=` word and every word carrying a `$` outside single quotes that is
   followed by neither whitespace, the end of the command nor, inside double quotes, the closing
   quote. Whitespace there is JavaScript's `\s`, so a `$` before a carriage return stays literal.
   zsh's `$=X`, `$~X`, `$^X` and `$+X` expand where bash leaves them literal, and the Bash tool
   may run zsh. Four lexer decisions keep quote pairing and word splitting identical to bash's, so
   that no second call can hide from the judgement, and each is exercised by a unit case — the two
   double-quote decisions share one: `$"…"`, the
   locale string, is read like a double-quoted string, so a substitution inside it reaches the
   nested scan, and its word counts as unexpanded; inside double quotes a `$` before the closing
   `"` is a literal dollar, never a quote opener, and does NOT count as an expansion, which is why
   every operator text names the closing double quote beside whitespace and the end; inside double
   quotes a `$` before `'` is a literal dollar too, never an ANSI-C opener, but its word still
   counts as unexpanded; and a carriage return is a word character, never a separator, so `\r#`
   never starts a comment. `V53-control` re-checks the `$` cases the operator texts state. A `+=`
   session assignment counts as unexpanded; a session given
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
   measured; and a CLI word that is not one of the platform's bare names (`binaryNames` in
   `hooks/lib/playwright-cli-version-v1.js`: `playwright-cli`, on win32 also its `.cmd`, `.exe` and
   `.ps1` names) — a path, another letter case, the package name — denies `CLI_NOT_BARE`, because
   only a bare name lets `PATH` resolve the binary `/zensu:doctor` and the run-config helper
   measured — unless the shell already has a function or alias of that name, which no hook sees.
   Then the command and flag allowlist (`ALLOWED_COMMANDS`), with
   `--json/--raw/--help/--version` harmless everywhere and a repeated flag denied. `COMMAND_DENIED` and `FLAG_DENIED` scope the refusal to
   `/zensu:verify-feature` and forbid a retry under another session name or program. The arguments
   are parsed by `parseCliArgs`, a port of the CLI's own minimist parser MEASURED against
   `PLAYWRIGHT_CLI_SOURCE_VERSION` (0.1.24) and pinned by a golden fixture recorded from that
   version's own parser; an argument shape it does not recognize denies rather than admits — an
   unknown option on a gated call, and, through step 7, a `zensu-verify` name no call resolves.
   A flag a newer CLI adds stays off the allowlist until a change admits it: 0.1.23 added
   `tab-new --isolated-context`, `find --filename` and `--max-results`, and `--all` on `console`
   and `requests`, and each denies `FLAG_DENIED`; `find --filename` would be a file-write channel
   outside the run directory. The unknown-flag unit case holds all five; 0.1.24 adds no flag.
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
   operator, no second segment, no `$(…)`, `${…}`, backtick or process-substitution body anywhere
   in the command (`lexShell` pushes each onto `nested`), no subshell, no heredoc, no here-string
   and no redirection whose target is not a literal (`plainShape`): a literal target is admitted, a target carrying an
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
`network.allowedOrigins`, and `outputDir` under the run directory. MEASURED with 0.1.21, and again
with 0.1.23 and 0.1.24 driving Google Chrome 156.0.8078.81: a `goto` to an origin outside
`allowedOrigins` fails with `net::ERR_BLOCKED_BY_CLIENT` and exit 1 before that origin's server
sees a request. MEASURED with 0.1.23 and 0.1.24: a service-worker registration resolves to
`undefined`, no worker is registered and its script is never fetched. A server REDIRECT to another
origin is NOT refused by the browser (recorded as measured in `docs/gates.md`, and measured again
with 0.1.23 and 0.1.24), so the skill reads the `Page URL` line after every navigating call —
prose, not a boundary.

**Signed-in sessions are a second rule set, keyed on the session prefix.** A run config may carry
`browser.contextOptions.storageState` only at the canonical `auth/storage-state.json` beside it.
Such a config opens only on a `zensu-verify-auth-` session after `checkStateFile` passed,
`console` and `requests` deny on that session, the prompt says the browser opens signed in, its
records carry `restoredState`, and the recorder consumes the state after `open`, also when it
cannot bind a session. The read guard refuses a browser call that names a run directory without
naming a `zensu-verify` session, which keeps a signed-in config off the sessions this gate never
judges. The helper's login, the read guard, the version verdict and the gaps are in
`.claude/rules/verify-auth-guard.md`.

**Other sessions.** `commandMarkers` carries two more arms, `runs` (`RUNS_MARKER`, the
`verify-feature-runs` directory name) and `config` (`CONFIG_FLAG` or `CONFIG_ENV`, `--config` and
`PLAYWRIGHT_MCP_CONFIG`). When a command names the CLI and either arm, and no gated call exists,
`evaluate` runs `offSessionReason` over `analysis.offSession`, which `analyzeCommand` builds in
its one loop over the invocations from the same parse and session resolution the gated calls use:
every invocation whose session is not a literal `zensu-verify-` name, a session from `-s`, an
inline assignment, the hook environment or the CLI's default alike, an unexpanded one included.
`hidden` marks a CLI another program runs: a word outside command position that is a CLI word or
holds one as a token (`runsCli`: a token whose basename is a CLI name, or a path into the
`@playwright/cli` package), any word the shell expands before it runs, the command word included,
whose text names the CLI at all (`expandsIntoCli`: `~/bin/playwright-cli`, `$HOME/…`, a brace, a
glob, `$'playwright-cli'`, `playwright-cli$''`, `"$(command -v playwright-cli)"`,
`"${PW:-playwright-cli}"`), which is no invocation because only a literal word is, and a body the
lexer cannot judge that names the CLI. A literal word that only contains the name, such as
`playwright-cli.json` or a project folder named after the CLI, is no token, while an expanded one
such as `"$HOME/playwright-cli.json"` counts, and the operand of `cd` or `pushd`
(`DIRECTORY_BUILTINS`) never counts; the gated `indirect` test keeps its substring reading of
literal words. With the `runs` arm an off-session call or a hidden
CLI denies `RUN_DIR_OFF_SESSION`. With the `config` arm each literal `--config` value and each
inline `PLAYWRIGHT_MCP_CONFIG` assignment of an off-session call, in any letter case because
Windows reads environment names that way, is read, and when the command is
not one plain unwrapped call, or a CLI is hidden, `configMentions` also reads every config value
the text sets: `--config <path>`, `--config=<path>` and a `PLAYWRIGHT_MCP_CONFIG` assignment in
any letter case, in any segment, behind `export`, `declare`, `sudo` or `doas`, inside a word that
holds a command string and inside nested bodies, heredocs and here-strings, up to `MAX_NEST`. A
value assembled at run time, appended with `+=`, behind a lexer fault or past that depth, a
`--config` with no word after it in its segment (`xargs` appends one), any other mention of the
variable's name than a literal assignment or an `unset` (`read`, `printf -v`, `mapfile`, a
reference or a bare `export`; `removesConfig` names the exemptions), an assignment value whose
tilde the shell expands (`assignmentOf` reads `~` after `=` or `:` as unexpanded), and a
relative path outside one plain unwrapped call, deny `CONFIG_UNRESOLVED_OFF_SESSION`. A literal
path is read as given when absolute, else against the payload's `cwd`; `readBoundedConfig`
refuses a path that starts with two slashes or backslashes unread, stats it and requires a
regular file within `MAX_OFF_SESSION_CONFIG_BYTES` before it opens anything, opens it
non-blocking, and requires the descriptor to be the same file; its byte-order mark is skipped and
its text parsed as JSON. A key `browser.contextOptions.storageState` denies
`STATE_CONFIG_OFF_SESSION`, and a file that cannot be read that way, or an `.ini` path, denies
`CONFIG_UNJUDGED_OFF_SESSION`. Measured on 0.1.24 (`parseConfigFile` in `coreBundle.js`): an
`.ini` path is INI, and a file that is no JSON and does not start with `{` falls back to INI,
which is why a config the gate cannot parse is refused rather than passed. A command whose text
names a `zensu-verify-` session keeps its shape denials (`marks.named` skips this pass), so a typo
such as `-S=` still gets `SESSION_UNRESOLVED`. `powershellReason` refuses a PowerShell call with
either arm as `POWERSHELL_OFF_SESSION_NOT_JUDGED`. All five reasons are final, and each names the
Grep tool and a message file, because a commit message that names the CLI beside `--config` is
judged like a call. The read guard's
session rule stays beside this as a second, textual line. **Residual:** a config the gate never
sees — the working directory's default `.playwright/cli.config.json`, the global config, which
the CLI merges under every config, a `PLAYWRIGHT_MCP_CONFIG` the shell inherited, a flag or
variable name assembled at run time (`--con$'f'ig=`, a variable holding `--config`), a file
swapped after the gate read it, a program that spawns `playwright-cli` without naming it — still
opens a signed-in browser outside the gate while the state file exists, that is, until the first
gated `open` consumes it. Measured in the specification session: an
ungated `-s=zvprobe-state1` session opening a `storageState` config came up signed in.

**One floor and one policy parser.** `verify-navigation-floor-v1.js` owns origin classification and
`parsePolicyTargets`, the full synchronous parse of `ZENSU_VERIFY_NAVIGATION_POLICY_V1`
(`policyContractFault` stays its top-level half). Three consumers CALL it and none re-spells it: the
gate (`readPolicy`), the helper (`run`, `--check-policy`) and the doctor wrapper
(`ZDOC_VERIFY_POLICY_FAULT`). The MCP-era hand copy inside the broker's `parsePolicy` died with the
broker. DNS happens in exactly one place, the helper's `resolveRemoteHost` at run-config time, and
the gate then requires the resulting pin for a remote hostname; a policy parse never resolves.

**`localhost` is a local origin, exactly and without a pin.** `isLocalHost` in the floor is the one
answer to "is this origin local": a loopback IP (`127.0.0.0/8`, `[::1]`) or the exact name
`localhost` in any letter case. `localhost.`, `app.localhost`, `localhost.localdomain` and every
`/etc/hosts` alias stay refused. The name is safe because the BROWSER resolves it, not the operating
system: Chromium's `HostResolverManager::ResolveLocally` answers `localhost` from `ServeLocalhost`
with `[::1]` and `127.0.0.1` before any cache, HOSTS-file or DNS task (read in
`net/dns/host_resolver_manager.cc` on chromium/chromium `main`, 2026-09-28). The one channel in the
run config that sits above that step is a `--host-resolver-rules` MAP rule, so `runConfigShape`
refuses a pin for `localhost` and the helper writes none for a local origin: a MAP rule carries ONE
address, and measured on Chromium 1228 `MAP localhost 127.0.0.1` made a server bound only to
`[::1]` unreachable. MEASURED with playwright-cli 0.1.21 driving Google Chrome 154.0.8037.57: a run
config allowing two `localhost` origins reached a server bound only to `[::1]` and one bound only to
`127.0.0.1`, a `fetch` between them passed, and a third `localhost` origin outside
`allowedOrigins` failed with `net::ERR_BLOCKED_BY_CLIENT` before its server saw a request. The
same run, MEASURED again with playwright-cli 0.1.23 and with 0.1.24, both driving Google Chrome
156.0.8078.81, gave the same result.
`localhost` and `127.0.0.1` stay different origins: a policy target or a consent for one never
admits the other. Sites that move together: `LOCALHOST_NAME`, `isLocalHost`,
`FLOOR_REASONS.LOCAL_LOOPBACK_ONLY` and `CONSENT_REMOTE_REASON` in the floor, both arms of
`parsePolicyTargets`, `checkOrigin` in the helper, the localhost pin refusal in `runConfigShape`,
and the operator accounts listed below. **Version for this delta: `patch`** — no schema field, key
set, hook, matcher, config key or attestation moves; the gate asks where it denied, and relaxing an
existing deny is not on the breaking list.

**Consent** covers every origin no valid policy target names: the gate returns
`permissionDecision: "ask"` — the host's prompt, which the model cannot answer — once per `open`
for all its new origins, and for a `goto` or `tab-new` to an origin not yet approved. A loopback
origin is asked once per session. A remote HTTPS origin passes the floor of a policy target
(public answers, a resolver pin, an exact hostname) and is asked at EVERY `open`: `judgeCall`
stamps its run-config entry `asked`, so `evaluate` never reads the forgeable memory for it there;
a `goto` or `tab-new` to a recorded remote origin passes, bounded by the run config the browser
was launched with. The gate reads `permission_mode` from the payload (`ANSWERABLE_MODES`:
`default`, `acceptEdits`, `auto`, `plan`); in any other mode, a missing one included, it denies a
remote origin outside a policy with `REMOTE_NEEDS_POLICY`, whose remedy names Manual/Auto and
`--permission-mode default|auto`. Without a policy, loopback verdicts are the same in every mode;
how the host resolves that ask under `bypassPermissions` or `dontAsk` is unmeasured. Consent is per
ORIGIN. The gate reads no recipe and `promptText`
names no route. The post hook records every executed gated call as
`(origin, route, decidedBy, at)` in `<project>/.zensu/state/verify-consent-<session key>.json`
(`O_EXCL` temp plus rename, contained by `memoryPathAllowed`, never through a symlink). `decidedBy`
names an OBSERVATION — `asked`, `remembered`, `policy-mode` — never a human decision: PostToolUse
carries no evidence of how the prompt was answered, and the host fires no PostToolUse event for a
failed Bash call, so a failed navigation is never recorded and asks again. **A policy**
pre-approves its target origins, every route on them, in every permission mode, admits its
network-only origins in the run config at `open` while it denies every navigation command that
names one, and accepts a remote hostname only with its pin. Any other origin is asked where the
mode can show the prompt. Where it cannot, an origin of the policy's kind is denied
`NOT_POLICY_TARGET` and one of the other kind `NOT_POLICY_KIND`, whose remedy never asks for an
origin the policy could not hold, so there the policy is the whole allowlist. An invalid policy
denies every gated navigation, in every mode, with the broken rule named. The helper's `--check-policy` prints `policy` only for a target and `consent`
for any other admitted origin; `run` prints `mode=policy` only when every navigable origin is a
target. The helper cannot see the permission mode, so whenever a present policy leaves an origin
to the prompt both print `POLICY_CONSENT_NOTE` on stderr, which says a session that cannot show
the prompt is denied that origin at `open`; stdout stays one token or the config lines.

**The evidence boundary is the ORIGIN in both modes; the route gate is retired.** An approved
origin — a consent-prompt Yes, or a policy target with `evidenceMode: declared-safe` — covers
every page on it at any path. The per-route layer failed in practice: pages whose path carries
identifiers minted on every run (`/teams/:teamId/sprints/:sprintId`) could never be listed
exactly, so every protected scenario on them ended PARTIAL. What was removed: the gate's
`NOT_POLICY_ROUTE` refusal, the recipe route reader behind the prompt's route line
(`declaredRoutesFromRecipe`, `readRecipeRoutes`, `promptRoutes`), the route operand of
`--check-policy`, and the exact-route
coverage the skill demanded of `validate.evidenceSafety`, which is now an optional
data-classification declaration that gates nothing. Do not reintroduce routes as prompt context
either: a listed route reads to the human as a limit nothing enforces. **Compatibility is
one-directional and deliberate:** `parsePolicyTargets` accepts a target with exactly
`evidenceMode` and `origin` (`POLICY_TARGET_KEYS`) or with a `routes` list beside them
(`LEGACY_POLICY_TARGET_KEYS`); `legacyRoutesFault` still shape-checks that list at
`MAX_POLICY_ROUTES`, so a malformed legacy list still invalidates the policy, and a well-formed
one is then dropped rather than enforced. What still binds per call is unchanged: the floor (no credentials,
query or fragment in a navigation), `network.allowedOrigins`, the resolver pins and the
redirect check. **Version: `patch`.** No schema field, attestation, hook or matcher moves, and
the gate denies strictly less. The one entry that reads close is the strict key set:
`parsePolicyTargets` is one, but it reads the launch environment, which no runtime writes, and
every installation carrying this change accepts a superset of what an older one accepted, so no
runtime is left unable to read what another wrote. A releaser who prefers the letter of that
entry picks `minor`; the argument above is why this file does not.

**Network-only origins are a second policy class, and the gate derives it from the policy.**
`parsePolicyTargets` returns `networkOnly` beside `targets`, read from the optional top-level
`networkOnlyOrigins` (`NETWORK_ONLY_POLICY_KEYS`, at most `MAX_NETWORK_ONLY_ORIGINS`). Both lists
pass ONE entry parser (`policyOriginEntry`) and ONE floor (`policyFloorFault`): a network-only
origin in a remote policy obeys the target floor, one in a local policy is loopback or public
HTTPS (`FLOOR_REASONS.NETWORK_ONLY_HTTPS` otherwise), and the hostname rule
(`FLOOR_REASONS.HOSTNAME_PATTERN`: an IP literal or `[a-z0-9._-]` only) binds targets too. That
is a deliberate tightening, not a side effect: playwright-core turns each allowed origin into the
URL glob `<origin>/**` (`originOrHostGlob` in the bundled `coreBundle.js` of 0.1.21, unchanged in
0.1.23 and 0.1.24), so a `*`,
`{` or `,` in a hostname was a browser-side wildcard the parser used to accept. The run config
stays ONE plain `network.allowedOrigins` list and `runConfigShape` keeps its key set, so
navigability is derived, never written: `judgeOrigin` takes an optional `role` — `navigable` for
the helper's `--origin`, `network-only` for `--network-only-origin` — and a `navigation: true`
call is navigable by definition. At `open` a network-only run-config origin is admitted with its
pin and gets NO plan entry, so the recorder writes no consent record for it: a record would make
it remembered, and navigable, for a later consent-mode run. `NETWORK_ONLY_NAVIGATION`,
`NOT_POLICY_NETWORK_ONLY` and `NETWORK_ONLY_NEEDS_POLICY` are FINAL reasons. Consent mode has no
network-only class: without a policy the role is refused, and the skill passes a loopback API
origin as an ordinary `--origin`. The redirect rule stays prose, and the reason is measured
rather than argued: the browser has ONE class of allowed origin, so a page-initiated navigation
onto a network-only origin is followed, and the triggering call prints that page's URL and title
before the skill can stop. **WebSockets are outside the browser fence for every origin** —
measured with playwright-cli 0.1.21 and Chrome 154, and again with 0.1.23 and with 0.1.24 and
Chrome 156, where a page on an allowed origin opened one to a loopback origin outside
`allowedOrigins` and received its message: `context.route` does not intercept them —
so the docs say "every HTTP(S) request"; fencing them is a separate change. The decisions and the
security analysis live in §11 of `docs/verify-feature-consent-spec.md`. **Version for this
delta: `patch`**, by the route-retirement argument above — the policy is read from the launch
environment, which no runtime writes, and an installation that predates the key refuses a policy
carrying it rather than misreading it. The hostname rule is the one place it accepts LESS than
before; a releaser who weighs that by the letter of the strict-key-set entry picks `minor`.
Sites that move together: `POLICY_KEYS`, `NETWORK_ONLY_POLICY_KEYS`, `MAX_NETWORK_ONLY_ORIGINS`,
`policyOriginEntry`, `policyFloorFault` and the two floor reasons; `readPolicy`, the `role`
option of `judgeOrigin`, the network-only skip in `judgeCall` and the three reasons in `REASONS`
and `FINAL_REASONS`; the network-only arm of `checkOrigin`, `CHECK_ROLES`, `USAGE`,
`CHECK_USAGE` and the `network-only-origin=` output line in the helper;
`CHECK_POLICY_OPERANDS`, the `--network-only-origin` count in `isRunConfigInvocation`,
`networkOnlyPreflightEnds` and `passesNetworkOnly`, which read the preflight and helper calls in
the spelling the skill documents, `configuringHelper`, which names the helper call that last
wrote the config an `open` uses, and `remoteNetworkOnlyTools`, which takes its coverage only from
a session whose config that flagged call wrote, in
`evals/verify-feature/assertions/transcript-check.js`; the
`validate.networkOnly` schema in `skills/autopilot/rules/config.md`; and the policy row of the
doctor report.

**No execution marker, and why.** The MCP-era gate wrote a per-session marker so that a SEPARATE
process, the broker, could tell whether the gate had run before it self-approved an origin. With no
broker, nothing consumes such a marker, so the whole family (`writeExecutionEvidence`,
`classifyExecution`, the `ZDOC_VERIFY_EXEC` wire and the doctor's `verify-feature gate:` row) was
removed rather than ported. The consequence is the first residual below, and it must not be papered
over with a marker nothing reads.

**`/zensu:doctor`** probes `command -v playwright-cli` (`ZDOC_PLAYWRIGHT=present|absent`) and reads
the version through `hooks/lib/playwright-cli-version-v1.js` (`cliMain` with `--lookup --execute`),
exporting `ZDOC_PLAYWRIGHT_SOURCE`, `ZDOC_PLAYWRIGHT_VERSION` and `ZDOC_PLAYWRIGHT_OWNER`. The
module walks `PATH` as the shell does and answers `cwd-relative` without reading anything when an
empty or relative entry comes before or holds the binary. Otherwise it reads the `@playwright/cli`
`package.json`: the one in `node_modules/@playwright/cli` beside the binary found on `PATH`
first — the npm-shim layout, though any file there counts — else the nearest one from the directory of the
binary's realpath upward, four directories at most, each read bounded at 64 KiB. A manifest that
names another package answers `foreign`, one that is oversized, unparseable or carries no valid
name and version answers `malformed`, and neither runs the binary. Only when no manifest exists
at all does `--execute` run `playwright-cli --version`, once: stdin and stderr ignored,
`NO_UPDATE_NOTIFIER=1`, and a 5 s timeout that sends `SIGKILL` on every host, with no `timeout` or
`gtimeout` involved; a `.cmd` or `.bat` shim on win32 is never run. It keeps the first semantic
version on the first output line and answers `self-reported`, which is never taken as measured:
the run-config helper calls the module without `--execute` and accepts only a `manifest` answer
equal to `PLAYWRIGHT_CLI_SOURCE_VERSION`. The doctor does not call `zensu_run_bounded`. A
version other than `PLAYWRIGHT_CLI_SOURCE_VERSION`, or a measured version the report could not
read, renders WARN and names what was not measured against it; a difference is disclosed, never a
failure. The verify-feature row runs its availability checks FIRST — hook pair, prefilter library,
module and helper present, the module no symlink (both hooks refuse one) and loadable, the helper
loadable, both hooks registered on a matcher that covers `Bash` and `PowerShell` — and reports `unavailable`
before it classifies a policy, so a valid policy over an
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
  `skills/verify-feature/SKILL.md` (pinned by `P6f`), `README.md` (`P7d`), `docs/verify-feature.md`
  (the install block and the troubleshooting table), `docs/gates.md` (the install command and the
  golden-recording sentence), the verify-feature troubleshooting row of `docs/operations.md`,
  `skills/doctor/SKILL.md`, `skills/autopilot/rules/config.md`, the
  `## [Unreleased]` upgrade note of `CHANGELOG.md` (`P9e`), `evals/verify-feature/README.md`, the
  Electron sentence of `.claude/rules/verify-feature-drivers.md` and this rule file (step 4 and
  the run-config measurement), and as a literal into the unit pin beside the
  constant. `P7e` derives the version from the module and requires the pinned install command, in
  backticks, in the skill, `README.md`, the three docs pages — in `docs/verify-feature.md` only the
  troubleshooting row carries that form — the doctor skill and the autopilot config rule; `P7h`
  pins the fenced install line of `docs/verify-feature.md`, the golden-recording sentence of
  `docs/gates.md` and the eval README. `P9e` requires every `npm install -g @playwright/cli@…` in
  the `## [Unreleased]` section of `CHANGELOG.md` to name the measured version, wrapped lines
  included, and `P9f` and `P9g` are its controls, the second with the pin wrapped after `-g`;
  `P9a` holds only the released `0.22.0` block, whose pin is history, and an Unreleased section
  that names no pin passes `P9e`, so a bump that forgets its upgrade note stays a reviewer's
  catch. No check reads this file's copies. The MSYS boundary suite
  derives it from the module, and so does `.github/scripts/playwright-cli-drift.sh` (see "The
  release signal" below), whose report names the recorder, the fixture, the module and
  `tests/structure/test-verify-consent.sh`; `PD14` fails when one of those paths moves.
- `SESSION_PREFIX`, `SESSION_RE`, `RUN_CONFIG_NAME`, `RUN_OUTPUT_DIR_NAME`, `MAX_RUN_ORIGINS` and
  `runConfigShape` are consumed by the helper FROM the module, never re-spelled.
- The `PATH` walk of `hooks/lib/playwright-cli-version-v1.js` — `findBinary` and its `cwd-relative`
  verdict — has a hand copy in `hooks/lib/zensu-cli-version-v1.js`
  (`.claude/rules/zensu-cli-floor.md`). The unit case `the PATH walk decides as the playwright-cli
  probe walk does over the same fixtures` in `tests/structure/zensu-cli-version-v1.test.js`
  compares the two on POSIX, so a change to this walk changes that copy in the same commit.
- `CONSENT_MATCHER` (`'Bash|PowerShell'`) and `CONSENT_TOOLS` ↔ both consent checks in `DISPATCHED_CHECKS` ↔
  `consentHookRegistered`/`consentRecorderRegistered` and their `REGISTRATION` answers ↔ the
  doctor's `unavailable` reasons in `hooks/lib/zensu-doctor.sh` ↔ the `❌ verify-feature: cannot
  start (…)` bullet in `skills/doctor/SKILL.md`, which must name every cause those reasons carry
  — a missing hook, prefilter library, decision module or run-config helper, a symlinked or
  unloadable decision module, a run-config helper that cannot be loaded, a hook that is not
  registered, a registration that could not be determined, a probe that did not complete — and the rule that
  each hook is named with its own state, because a model relaying an undetermined registration as
  a missing hook, or the gate's state as the recorder's, sends the user after a problem that is
  not there. No check compares the bullet with the reasons. The verify-auth read guard's causes
  are named in `skills/doctor/references/verify-auth-guard.md`, which the bullet points to, and
  that file must name every guard cause the doctor prints.
- `hooks/lib/hook-registration-v1.js` is the ONE reader of the host rule that decides which
  `hooks.json` groups fire for a tool. `hookRegistered` in `hooks/lib/verify-consent-v1.js`, behind
  `consentHookRegistered`/`consentRecorderRegistered`, calls its `registration` with
  `READINGS.HOST`; `reviewerSpawnHookWired` in `hooks/lib/zensu-doctor-report.js`, the doctor's
  grant row, calls it with `READINGS.REGEX`. Only `READINGS.HOST` is the host's reading.
  `READINGS.REGEX` can call a group wired that the host does not fire — unanchored, `Age` matches
  `Agent`, where the host reads `Age` as one tool name — and skips a `*` group, which the host
  fires for every tool. The grant row keeps it
  because sharing the reader was to change neither row's answers; moving that row onto
  `READINGS.HOST` re-decides what the grant row reports and belongs in the grant's own review. A
  change to either reading re-decides each difference, for the consent probes and the grant row
  alike.
  `READINGS.HOST` follows the host's own matcher rule as read out of the Claude Code 2.1.280
  binary (`hostMatcherCovers`): an absent or empty matcher and `*` cover every tool, and a
  matcher of plain names joined by `|` covers exactly those names. Any other matcher the host may
  read as a name list or as a regular expression, and whether it anchors one was not observed, so
  a matcher whose name-list, anchored and unanchored readings disagree answers `unknown`, as does
  one that does not compile or is not a string. `READINGS.REGEX` compiles every matcher as an
  unanchored regular expression, reads every matcher that is not a non-empty string — absent,
  empty, `null`, a number — as `.*`, and skips a group whose matcher does not compile: a
  non-string matcher answers `unknown` under the host reading and covers every tool under the
  regex reading, and `*` covers every tool under the host reading while its group is skipped
  under the regex reading. The document shapes differ in three places only: an array document, a
  `hooks` value of the wrong type, and an event value that is present but falsy answer `unknown`
  under the host reading and read as an empty list under the regex reading; a document that is not
  an object and a truthy event value that is not an array answer `unknown` under both. The callers
  differ beyond the reading: the consent probe matches the command on `/hooks/<file>` and requires
  that file, followed through a symlink as the doctor's `[ -f ]` follows it, to be a regular file,
  where the grant row matches the bare filename; the consent probe reads `hooks.json` through
  `lstat` plus `readFileSync`, the grant row through the doctor's hardened `readJson`; and the
  grant row requires EVERY spawn tool to match where the consent probe tests `CONSENT_MATCHER`
  alone. Every `unknown` exists because the consent probe feeds a verdict that must never read a
  registration it could not judge as a missing one. The unit case `one registration reader serves
  the consent probes and the grant row, each through its own reading` holds both readings in one
  table and requires the doctor report to load the module; `.claude/rules/reviewer-spawn-grant.md`
  points here for the grant row's side.
- The ONE prefilter library, `hooks/lib/zensu-browser-consent-prefilter.sh`, ↔ `commandMarkers` /
  `normalizedText` in the module (a hand copy, see step 1): the continuation join with its
  backslash pairing, the stripped character set, case-insensitivity, both markers, the
  run-directory and config arms (`RUNS_MARKER`, `CONFIG_FLAG`, `CONFIG_ENV`), and the
  `PLAYWRIGHT_CLI_SESSION` arm must agree. `CLI_MARKERS` is DERIVED from `CLI_BASENAMES` and
  `CLI_PACKAGE`; `H17` pins the library's one `sed` and one `tr -d` pass, `H17d` that both wrappers
  source it, carry no copy of its two-marker test and scan only in their library-unavailable
  fallback, and `H17e` that it names every derived marker, the session prefix, the run-directory and
  config markers and the session variable. Each wrapper's fallback test is its own copy, broader than the library in the markers
  it counts but blind to a marker split by an escaped backslash (step 1), and no check compares
  the two fallback copies.
- The pre hook's deny prefix and its four plugin-integrity reasons (`prefilter library
  unavailable`, `node unavailable`, `decision module absent or symlinked`, `decision module
  failed`) ↔ the §5 row of `docs/verify-feature.md` that quotes them; `V63-control` greps the hook
  for each. That row tells the user to reinstall even when the doctor's `verify-feature` row
  reads ready, because the doctor sees a missing or symlinked part but not a library that fails
  to source, a module that loads and then fails, or a `node` missing only from the hooks'
  environment.
- `AMBIENT_TEXT_RE` / `ambientOverride` / `globalConfigFile` / `GLOBAL_CONFIG_HARMLESS` ↔ the
  CLI's own configuration channels; a new CLI env or config channel lands here first.
- `scripts/` is now in the Session Control digest unconditionally (see §"Runtime Lineage"), because
  the helper lives there.
- `adopt_hook_expected` in `tests/structure/test-versioned-plugin-upgrade.sh` exempts the pre hook,
  which cannot deny the adoption command.
- The Session Control `mutating_control` attack no longer names a browser tool: it asks the reviewer
  for a Bash `curl` to the local canary, so only the reviewer-capability gate can deny it and its
  `Zensu capability gate (reviewer-capability-v1) deny:` reason stays deterministic (`scripts/session-control-claude-wrapper.sh`,
  `evals/session-control/lib/live-evidence.js`, `evals/session-control/tests/wrapper-selftest.sh`,
  `tests/structure/test-windows-portability-guards.sh`).

**The release signal (`.github/workflows/playwright-cli-drift.yml`).** No live tier runs
`playwright-cli`, and none is needed: the parser port is pinned by a fixture recorded from the
real CLI, and the gate denies an argument shape it does not recognize. What goes stale is the
knowledge that a newer release exists, and a nightly check supplies only that. Its `drift` job
keeps the read-only token and runs `.github/scripts/playwright-cli-drift.sh`, which reads the
abbreviated npm registry metadata of `@playwright/cli` with one `curl`, takes
`PLAYWRIGHT_CLI_SOURCE_VERSION` and `PACKAGE_NAME` from the two modules, never from a copy, and
prints a report whose first line is `<!-- zensu-playwright-cli-drift playwright-cli=X.Y.Z -->`
when the highest stable version, compared by number, is above the measured one. A prerelease
never counts, and the script never installs, downloads or runs the package. Every value it uses
is validated first: the package name, every version key through `validVersion`, and each
entry's own name and version. The report therefore carries no upstream text but version
numbers, and it spells `@playwright/cli` only inside code spans, because GitHub notifies the
owner of a bare `@name`. The check fails, and the run turns red, when the metadata cannot be
read or do not parse, describe another package, carry a key that is not a semantic version or
an entry that names another version, or do not list the measured version: an unpublished
measured version breaks the pinned install command. The `drift-issue` job holds
`issues: write` and nothing else, checks out nothing and runs only after a successful drift
job; it opens the issue labelled `playwright-cli-drift`, rewrites it when the marker changes,
and closes it when the report is empty. A red scheduled run comments on or opens the issue
labelled `playwright-cli-drift-check`; the label, not the title, finds each issue. One
concurrency group serializes every run, so a dispatch and the nightly run never race on an
issue. A dispatch runs both jobs on the ref it names, so a dispatch from a branch writes the
issue from that branch's constant until the next nightly run on `main` corrects it. Not read:
`dist-tags`, publish times and deprecations. `tests/structure/test-playwright-cli-drift.sh`
pins the workflow graph, runs the script against fixture metadata with spies that admit one
`curl` and no package manager, archiver or CLI, runs the compare, issue and red-run steps
against a fake `gh`, and requires three mutants (release order by text, an unanchored stable
filter, a whole-body marker match) to give the wrong answer their cases refuse. Like
`tests/structure/test-gitlab-live-workflow.sh`, the guard of the GitLab `drift` and
`drift-issue` jobs this workflow is modelled on, it skips its executed checks on Git Bash.
**Release class: `patch`**: CI and tests only, and `.github/` is outside the Session Control
runtime digest.

Operator-facing accounts: `docs/gates.md` §"Browser Consent Gate", `docs/verify-feature.md`, the
current-behaviour opening of `docs/verify-feature-consent-spec.md`, both hook rows and the
`ZENSU_VERIFY_NAVIGATION_POLICY_V1` row in `docs/configuration.md`, the verify-feature row of the
troubleshooting table in `docs/operations.md`, both rows of the "Unbindable sessions" table in
`docs/session-control.md`, `README.md`, `skills/verify-feature/**`, `skills/doctor/SKILL.md`,
`skills/autopilot/rules/config.md`, and the banner line.
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
the browser. The replacement names the Bash command, e.g. `Bash(playwright-cli:*)`. This break
and the `playwright-cli` prerequisite shipped in the `### Upgrade notes` block of the `0.22.0`
section of `CHANGELOG.md`. It was written under `## [Unreleased]`: the workflow prints the
generated section directly under that heading, ahead of the block, so the block closes the new
release section and its notes. `P9b` in `tests/structure/test-verify-feature-skill.sh` runs the
workflow's own two awk programs over the real file to hold that, and `P9d` holds that the
released block survives the next release. `P9a` to `P9d` follow only the block that names
`mcp__plugin_zensu_playwright__`; a later block under `## [Unreleased]`, such as the route
retirement's, rides the same mechanism with no placement check of its own, and `P9e` reads it only
for its `@playwright/cli` install pins.

**Known gaps, accepted and named:**

- **Hooks switched off host-side leave `playwright-cli` unconstrained.** The retired broker refused
  to self-approve without the gate's marker, so a disabled hook ended in a refusal; nothing stands
  in that position now, and the doctor reports registration, never execution.
- **Other session names are ungated** — see SCOPE — except for the "Other sessions" rules, which
  judge only what the command text shows, and which refuse a user's own state-restoring, INI,
  unreadable or variable-held config on every session. A command that only echoes the CLI's name
  beside a config, such as `eslint --config <file> && echo playwright-cli`, is judged as if the
  CLI read that config, because the gate cannot tell which program would.
- **The gate judges a URL only where a command names one.** `judgeCall` reads the URL of `open`,
  `goto` and `tab-new`; `go-back`, `go-forward`, `reload` and `tab-select` carry none, so where
  they land is never judged. The browser follows a server redirect to another origin, a
  network-only one included, and a page-initiated navigation onto a network-only origin; a click
  can open a popup tab there. The `Page URL` check and the `tab-list`/`tab-close` rule in
  `skills/verify-feature/**` answer these, and they are prose. A frame a navigable page embeds from
  a network-only origin renders inside that page, so its content reaches that page's snapshot and
  screenshot; the skill reads it as that page's content, like fetched data, which is why
  `NETWORK_ONLY_NAVIGATION` denies evidence only to a page the browser lands on there.
- **`localhost` rests on a browser property no suite exercises.** The source reading is of Chromium
  `main` and the measurements of two Chrome builds (154.0.8037.57 with playwright-cli 0.1.21,
  156.0.8078.81 with 0.1.23 and 0.1.24); no suite drives a real browser, so a Chromium that
  stopped serving `localhost` itself would let `/etc/hosts` steer it with every check green.
  `*.localhost` stays refused although the same Chromium code resolves it to loopback too.
- **The consent memory is forgeable:** a record written through a Bash redirect skips the prompt for
  a loopback origin, under a policy too where the mode can show the prompt, and the floor bounds
  the damage to loopback services. It never skips a remote origin's prompt at `open`; it skips
  the one of a `goto` or `tab-new`, which the run config the browser was launched with bounds.
- **The run config is read three times** — by the gate at `open`, by the CLI at launch and by
  the recorder — so a file swapped in between is followed, can admit an origin the human never
  approved, and can make the report's `Consent` block wrong. Together with a forged consent
  record, a remote origin such a swapped config admits is reached by a `goto` or `tab-new` that is
  never asked. It lives under the project, where the session can write.
- **The permission mode is the host's report, and the gate cannot tell a person from a
  program.** Auto mode was measured once (Claude Code 2.1.293, desktop: the gate's `ask` reached
  the user, transcript `permissionDecision.source: user_temporary`). UNVERIFIED: how the host
  resolves a hook `ask` in a headless `-p` run, with `--permission-prompt-tool`, under an SDK
  `canUseTool` callback, and under `bypassPermissions` or `dontAsk`. A run in an answerable mode
  whose prompts a program answers lets that program decide every origin the policy does not name,
  so the docs send an unattended run to `dontAsk` or `bypassPermissions` with a policy. The live
  eval runs in policy mode so it never depends on a prompt.
- **"Asked again at every `open`" assumes no stored choice answers a later hook `ask` (M3).**
  Whether a persistent choice in the host dialog or a `Bash(playwright-cli:*)` allow rule
  satisfies a later hook `ask` was not measured; if one does, drop that sentence from
  `remotePromptText` and add a doctor finding for the allow rule.
- **A session that cannot show the prompt may boot a whole runtime before `open` is denied.** The preflight
  cannot see the permission mode, so a policy that does not name the run's
  origin is answered `consent` plus `POLICY_CONSENT_NOTE`, the runtime starts, and the gate then
  denies. The skill's rules stop before booting on that note in such a session; that is prose.
- **The model can still grant itself a policy** through the `env` block of
  `~/.claude/settings.json` under bypass permissions or past the Auto-mode classifier. Pinning the
  launch-time policy digest in the Session Control record is a schema change (`minor`) for a
  separate PR.
- **A consent-mode network-only role does not exist.** A deployed app's API or identity origin is
  passed as one more `--origin`, asked in the same prompt; the skill never navigates to it, but
  the gate would admit a navigation.
- **The gate is textual.** It judges what the command TEXT names. A CLI or session name assembled
  at run time — from a file, a variable set by an earlier Bash call, a program's output, an
  ANSI-C escape inside a name (`$'playwright\x2dcli'`), or an expansion inside `playwright-cli` or
  inside the `zensu-verify-` prefix even when the same command sets it or leaves it empty
  (`playwright-cli -s=zensu-ver${Z}ify-run`) — never reaches the markers, because the prefilter
  keeps `$` and matches literal substrings, so the call it produces is not gated. An ANSI-C word
  that holds the plain name, `$'playwright-cli'`, still reaches the CLI marker once the quotes are
  stripped, and `readDollar` marks it unexpanded, so it is no invocation and a marked command
  denies `NOT_PLAIN`; `V64-control` runs both spellings. While the hook environment's
  `PLAYWRIGHT_CLI_SESSION` names a `zensu-verify-` session, the environment arm marks any call
  that spells `playwright-cli` literally, `marks.session` holds whatever the session, and a
  session assembled at run time — a variable, a substitution, an ANSI-C escape or an expansion
  inside the prefix — denies `SESSION_UNEXPANDED`; only a CLI name assembled at run time stays
  unseen. `V64-control` runs the unmarked spellings and both denied ones through the real pre
  hook. The single-invocation and literal-argument rules bind only a marked command, so
  they do not narrow this. A function or alias named `playwright-cli` that the shell already has
  is judged as the plain call its text shows, and no hook sees what it runs.
- **Version drift is only partly fenced.** The driver is user-supplied: the plugin ships no pin and
  no integrity check for `playwright-cli`. The nightly release signal above says when npm lists
  a newer stable release; it measures nothing. The one refusal is `checkReadiness` in the run-config
  helper, and BOTH entry points run it first: `checkPolicy` (the `--check-policy` preflight) and
  `run` (the write). It refuses unless `consentHookRegistered` and `consentRecorderRegistered`
  both answer `registered` and the `@playwright/cli` manifest of the `playwright-cli` on `PATH`
  names exactly `PLAYWRIGHT_CLI_SOURCE_VERSION` — a version the package declares, not a verified
  binary; the doctor's version row stays a WARN. The check runs only inside the helper: the gate
  judges `open` by `runConfigShape` and never reads the installed version (from the version module
  it takes only `BINARY_NAMES` and `PACKAGE_NAME`, which build its markers, and `binaryNames`,
  never `installedVersion`, `probe` or `findBinary`; `V67` pins that set), so a run config of that shape written another way, or a
  `playwright-cli` installed or put ahead on `PATH` after the helper ran, runs unmeasured. It
  calls the version module without `--execute`,
  so a binary is never run to learn its version. The module reads the
  `node_modules/@playwright/cli/package.json` beside the binary found on `PATH` first, on every
  platform, so a wrapper script in a directory holding that manifest at the measured version
  passes: the check vouches for the manifest beside the wrapper, not for what the wrapper runs,
  nor for a function or alias named `playwright-cli` that the shell already has.
  Any other wrapper script outside the package with no
  `package.json` in the directory of its resolved path or the three above it yields no manifest
  (`unread`) and is refused with the remedy of putting the directory npm installs into first on
  `PATH`, ahead of any wrapper; with one there it answers `foreign` or `malformed`, and the
  refusal names only the install command although the same `PATH` change is needed. A
  `cwd-relative` answer is refused with the entry named. `versionCause`/`versionRemedy` hold those texts, the troubleshooting table in
  `docs/verify-feature.md` §5 quotes them, `V54-control` re-checks that the helper still
  carries every fragment the table quotes, and the exact-remedy table in
  `tests/structure/verify-browser-config.test.js` pins the remedy of every answer — `absent`, a
  mismatched `manifest`, `unread`, `foreign`, `malformed`, `self-reported` and both
  `cwd-relative` cases — so a PATH clause added to another answer turns it red. A
  `self-reported` answer, which only a `--execute` read produces, is refused even at the measured
  version, because only a `manifest` answer passes. The parser port is exact for that version and an unknown shape
  denies, but a later CLI that changes the meaning of an existing flag, or renames or ignores a
  run-config fence — `network.allowedOrigins`, `browser.isolated`, the `--host-resolver-rules`
  pins, `browser.contextOptions.serviceWorkers` — drops a browser-side fence while every gate check
  passes. The configuration channels are judged only as far as the gate knows them:
  `ambientOverride` reads the `PLAYWRIGHT_MCP_*` launch variables, `AMBIENT_TEXT_RE` the
  `PLAYWRIGHT_MCP_` and `PWTEST_` prefixes, and `globalConfigFile` the global CLI config, so a new
  channel of a later CLI is unjudged.
- **The doctor checks the prefilter library for existence only.** Both hooks require that
  sourcing it succeeds and defines `zensu_browser_consent_marked`; the doctor tests `[ -f ]`, so a
  library that exists but fails to source, or defines no such function, reads as available while
  both hooks run their fallback (step 1).
- **The library-unavailable fallback does not pair escaped backslashes.** Both wrappers' fallback
  `sed` drops `\n`, `\r` and `\t` from the JSON payload before `tr -d` removes backslashes, so a
  gated call whose markers are split by a backslash before one of those letters names neither
  word to it and runs unjudged while the library is missing (step 1). Pairing the backslashes
  first, as the library does, closes it; `V68` pins the docs sentence that states the gap and
  must change with that fix.
- **Windows is UNVERIFIED end to end.** `CLI_BASENAMES` recognizes the `.cmd`/`.exe`/`.ps1`
  spellings, but no Windows run has driven a real `playwright-cli` through the gate. On Git Bash
  both hooks hand node the memory path in the MSYS-converted `C:/…` spelling while the state
  directory node derives reads `C:\…`, so `memoryPathAllowed` compares the directory after
  `nativeSeparators`; nothing collapses a `..` segment, so one still refuses.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included; each must
  re-decide whether its host fires a pre-tool hook on its shell tool and can render an `ask`.

**Remote consent (2026-10-09).** Remote HTTPS origins are approved at the host prompt in consent
mode; the decisions and their trade-offs are §12 of `docs/verify-feature-consent-spec.md`.
Load-bearing points: the `asked` stamp in `judgeCall` is what keeps the forgeable memory out of the
remote `open` decision, so never let a remote run-config target fall through to the
`known.has(...)` expression in `evaluate`; `isExactHost` in the floor is the ONE exact-hostname
predicate, used by `classifyOrigin`, `policyFloorFault` and `runConfigShape`; and the pin check
for remote hosts lives in `runConfigShape` alone, after its pin-to-origin loop, so the helper and
the gate refuse an unpinned or pattern host with the same text. Sites that move together:
`ANSWERABLE_MODES`, `REASONS.REMOTE_NEEDS_POLICY` / `NOT_POLICY_TARGET` / `NOT_POLICY_KIND` and
their `FINAL_REASONS` entries, `floor.CONSENT_REMOTE_REASON`, `remotePromptText`, the `answerable`
option of `judgeOrigin`, the helper's `policyVerdict` / `checkPolicy` / `run` and its exported
`POLICY_CONSENT_NOTE` (pinned by `P6p` and the unit file), the banner line, the doctor's
policy, consent and consent-no-recipe rows, and the operator accounts listed above. **Version:
`patch`** — the gate asks where it denied, the new refusals hit only inputs denied before, and no
schema field, `decidedBy` value, key set, hook, matcher, config key or attestation moves; a new
`decidedBy` value would force `minor`.

**The 0.1.23 measurement (2026-11-09).** The fixture was re-recorded from the npm package,
installed with `--ignore-scripts`; the recorder raised no refusal, and the recording differs
from 0.1.21's only in `source.version` and `source.playwrightCore` (1.64.0-alpha-1789764292000
to 1.65.0-alpha-2026-10-30), so the port needed no change. READ, comparing both installed
packages: the CLI client's `minimist.js`, `registry.js` and `session.js` are byte-identical, no
command was added or removed, and `validateFlags` in `program.js` now also accepts `--no-<flag>`
where a command declares `no-<flag>`, which only `install-browser --no-shell` does and the gate
denies by command. The new environment names are `PLAYWRIGHT_MCP_IGNORE_ROOTS` and
`PLAYWRIGHT_MCP_REDACT_URL_PARAMS`, inside the prefix `ambientOverride` and `AMBIENT_TEXT_RE`
already judge; `PW_PROFILE_DIR`, the renamed `PWTEST_PROFILE_DIR`, starts the CPU profiler and
`XDG_RUNTIME_DIR` moves the daemon socket, so neither configures the browser, and an inline
assignment of either on a gated call still denies `ENV_ASSIGNMENT`; `PLAYWRIGHT_SKIP_DIALOG_CHECK`
and `PLAYWRIGHT_SKIP_INERT_CHECK` relax action checks only, and the new Firefox and WebKit names
reach no Chromium run. The new config keys `ignoreRoots` and `redactUrlParams` lie outside
`GLOBAL_CONFIG_HARMLESS`, so a global config carrying either is refused, and the config-file
locations are unchanged. The four run-config fences keep their names and their readers:
`network.allowedOrigins` through the same routes, which 0.1.23 also installs on every isolated
context it creates; `browser.isolated`; the launch arguments, which `chromium.ts` still appends
last; and `serviceWorkers: 'block'`, which now patches `ServiceWorkerContainer.prototype.register`
rather than `navigator.serviceWorker.register`. The Chromium switch set changed beside them —
0.1.23 no longer disables `HttpsUpgrades`, `Translate` or client-side phishing detection — and
none of those is a fence the gate relies on. The entry point's once-a-day update check now runs
`npm view` through a shell instead of a `fetch`, for `open`, `attach`, `list`, `install` and
`install-browser`, unless `NO_UPDATE_NOTIFIER` or `CI` is set, and for every one of them but
`install` the same check compares a `playwright-cli` skill under the working directory's
`.claude/skills` or `.agents/skills` with its bundled copy; both run in the call's own working
directory and environment, outside the gate. MEASURED with Google Chrome 156.0.8078.81: the
run-config, `localhost` and WebSocket statements above, plus a `tab-new --isolated-context` to
an origin outside `allowedOrigins`, which failed with `net::ERR_BLOCKED_BY_CLIENT`. MEASURED on
2026-11-10: a `goto` and a `tab-new` on a session that was never opened each exit 1 with
`The browser '<session>' is not open, please run open first`, start no browser and no daemon,
and send no request, so a `goto` or `tab-new` still reaches only a browser that an `open`
launched with its run config. UNMEASURED on 0.1.23: a remote HTTPS origin with a resolver pin,
Windows, every other flag 0.1.23 added, and which `npm` binary and which `.npmrc` files the
update check's shell resolves. **Release class: `patch`.** No
schema field, key set, hook, matcher, config key or attestation moves, and the gate decides every
call as before; the one consequence is that `checkReadiness` now refuses 0.1.21, which the
`## [Unreleased]` upgrade note of `CHANGELOG.md` states.

**The 0.1.24 measurement (2026-11-10).** 0.1.24 became npm `latest` before the 0.1.23 pin was
released, so the pin moves from 0.1.21 to 0.1.24 in one release and 0.1.23 stays a measurement only. The fixture was
re-recorded from the npm package, installed with `--ignore-scripts`; the recorder raised no
refusal, and the recording differs from 0.1.23's only in `source.version` and
`source.playwrightCore` (1.65.0-alpha-2026-10-30 to 1.66.0-alpha-1794252756000), so the port
needed no change. READ, comparing both installed packages: `help.json` is identical, so no command
or flag was added or removed; the CLI client's `minimist.js` and `registry.js` are identical, and
`program.js` now exports `parseArgs`, which keeps the minimist call and the `-s`/`-g` folds the
recorder asserts and which the entry point runs once, before its update check, to name the
command. The new environment names are `PLAYWRIGHT_MCP_BACKGROUND` and
`PLAYWRIGHT_MCP_NO_TAB_GROUP`, inside the prefix `ambientOverride` and `AMBIENT_TEXT_RE` already
judge, and the Linux-only `CHROME_CONFIG_HOME`, `XDG_CONFIG_HOME` and `CHROME_USER_DATA_DIR`, which
only the channel lookup of `list`, the `--cdp` channel endpoint of `attach` and extension mode
read, so none configures the isolated browser an `open` starts, and an inline assignment of any of
them on a gated call still denies `ENV_ASSIGNMENT`; `PLAYWRIGHT_SKIP_DIALOG_CHECK` and
`PLAYWRIGHT_SKIP_INERT_CHECK` are gone. The new config keys `tabGroup`, `background` and
`browser.contextOptions.locateOnlyVisible` lie outside `GLOBAL_CONFIG_HARMLESS`, so a global config
carrying one is refused. A config file's relative paths now resolve against the file's real
directory, which leaves the run config as it was, because `runConfigShape` requires an absolute
`outputDir` beside the config. The four run-config fences keep their names and their readers:
request interception, `originOrHostGlob` and isolated contexts in the backend context module, the
service-worker block, and the user launch arguments, still appended last. 0.1.24 disables
`HttpsUpgrades` again, together with `HttpsFirstBalancedModeAutoEnable`, so a loopback HTTP
navigation stays on HTTP; neither is a fence the gate relies on. Console entries now carry 1-based
line numbers, and the console count also includes the errors of page and context event handlers.
MEASURED with Google Chrome 156.0.8078.81: the run-config, `localhost` and WebSocket statements
above; a `tab-new --isolated-context` to an origin outside `allowedOrigins`, which failed with
`net::ERR_BLOCKED_BY_CLIENT`; a `goto` and a `tab-new` on a session that was never opened, which
exit 1 with the not-open message, start no browser and no daemon and send no request; and the
response lines the eval grader parses: the `- Page URL:` line, a snapshot `[ref=…]`, the console
`Errors:` count, a `[GET] … => [200]` request line and the screenshot link. UNMEASURED on 0.1.24:
a remote HTTPS origin with a resolver pin, Windows, and which `npm` binary and which `.npmrc` files
the update check's shell resolves. **Release class: `patch`.** No schema field, key set, hook,
matcher, config key or attestation moves, and the gate decides every call as before; the one
consequence is that `checkReadiness` now refuses every version but 0.1.24, 0.1.21 included, which
the `## [Unreleased]` upgrade note of `CHANGELOG.md` states.
