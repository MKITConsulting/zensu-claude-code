# Operations

Installing a new version safely, what the upgrade path guarantees, which
platforms are supported, and what to do when something does not fire.

## Install and version resolution

The marketplace entry uses Claude Code's GitHub source object and pins the
plugin to the immutable tag matching its manifest version (`v<plugin version>`).
A release commit landing on `main` is therefore not itself an activation: the
new version becomes resolvable only after the publish workflow validates that
exact main SHA, uploads its evidence, and creates the referenced tag. The normal
install and update commands stay unchanged for end users.

## Updating

Already installed an earlier version? Pull the latest release:

```bash
claude plugin marketplace update zensu   # refresh the catalog to the latest release
claude plugin update zensu@zensu         # pull the new version into the installed plugin
```

[Claude Code installs each plugin version into a separate cache directory](https://code.claude.com/docs/en/plugins-reference#plugin-caching-and-file-resolution).
An already-running session keeps its previous `CLAUDE_PLUGIN_ROOT`; fresh
sessions load the new version and create that version's immutable Session
Control binding. Claude retains orphaned previous-version directories for
about 14 days so concurrent sessions can finish; those roots are ephemeral and
must never store persistent state. This is the supported zero-downtime upgrade
path. Claude may add only its own root-level `.in_use/<pid>` and
`.orphaned_at` lifecycle metadata to those cached copies; Zensu runtime payload
bytes remain immutable.

Never replace bytes under an already-published version/cache directory. Running
`/reload-plugins` in an open session IS supported: it switches that session's
hooks, MCP servers and skills to the newly installed version, and the first hook
contact afterwards adopts the session's Session Control record automatically
when the persisted schemas still match — the previous record is kept as
`<session-key>.superseded-<version>.json`, the takeover is written into the
workflow history, and review-evidence leases from before the update are set
aside (a review in flight has to be re-gathered). A refusal — an older executing
version, a persisted shape that really changed, a non-sibling checkout — denies
with the refusal named; `/zensu:adopt-session` prints it in full and
`/zensu:adopt-session --confirm` retries by hand. `hooks.sessionAutoAdopt:
false` switches the automatic path off, in EITHER config layer — for this key
`false` is sticky, so a project overlay cannot switch it back on. Afterwards
`/zensu:doctor` shows the adoption as a `✅ state:` row when a workflow document
recorded it. Until `/reload-plugins` runs, a session
keeps executing its previous version and nothing in it reaches the adoption.
Every release must use a new SemVer version and immutable `v<version>` source
tag.

The former `~/.zensu/plugin-root` locator is neither read, migrated, nor
rewritten during install or update. Delete it only once no Claude Code session
from an older Zensu plugin installation is still running in the same home; the
plugin never deletes it automatically.

## Platform Support

Every hook but one is registered as `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`
and runs a bash script that also calls standard POSIX tools such as `sed` and
`awk`. The exception is the hook dispatcher, which runs nine checks around every
tool call in one process: it is registered in exec form, `"command": "node"` with
the module path as its first argument, so Claude Code starts `node` directly,
without a shell. When a check needs its bash body, the dispatcher starts it with
Git Bash on Windows, found the way Claude Code finds it. Keep `node` on the
`PATH` of the environment that starts Claude Code, on every platform: without it,
Claude Code cannot start the dispatcher, and because its `PreToolUse`
registration sets `"onFailure": "block"`, every tool call is refused with Claude
Code's own error about the failed start; many other hooks skip their checks.

| Platform | Status |
|----------|--------|
| macOS, Linux | Supported. |
| Native Windows with Git for Windows | Supported, with the known gaps below. Once Claude Code finds Git Bash, it runs every hook there, whichever terminal starts `claude`: PowerShell, CMD or Git Bash. |
| Windows with WSL | Install and start `claude` inside the WSL terminal, not from PowerShell or CMD; Claude Code then runs its Linux build. CI tests Linux, not WSL itself. |
| Native Windows without Git Bash | Not supported: Claude Code then runs the hooks in PowerShell. |

On native Windows with Git for Windows, two environment variables matter. Set
them either in the environment that starts Claude Code or in the `env` block of
your user settings file `~/.claude/settings.json`, which applies in every
project (write each backslash of a Windows path twice there):

- `CLAUDE_CODE_GIT_BASH_PATH`, the path of Git Bash's `bash.exe`, but only if
  Claude Code cannot find Git Bash on its own.
- `CLAUDE_CODE_USE_POWERSHELL_TOOL=0`, optional. For claude.ai and Console
  accounts, Claude Code turns its
  [PowerShell tool](https://code.claude.com/docs/en/tools-reference#powershell-tool)
  on by default once Git for Windows is installed, and Claude then routes shell
  commands through it. The default arrives with Claude Code's feature flags, so
  the first session after an install or upgrade can lack the tool while later
  sessions have it. Set the variable to keep Claude on the Bash tool.

Zensu's shell hooks see a command that Claude runs through the PowerShell tool
as well. The [CLI write-gate](gates.md#cli-write-gate), the Session Control
rebind check and the opt-in [source-write gate](gates.md#source-write-gate) that
share one hook, the [secret scan](gates.md#secret-scan), the
[browser consent gate](gates.md#browser-consent-gate), the path redaction that
runs after a shell command and the work-order gate each judge a PowerShell
command or refuse it, and every refusal names the Bash tool, which stays
available. [Shell Tools](gates.md#shell-tools) says what each gate does with a
PowerShell command. The same holds wherever the PowerShell tool is turned on,
including macOS, Linux and WSL, where it is opt-in.

Known gaps on native Windows:
- `/zensu:doctor` and `/zensu:adopt-session` are not exempt when Session Control
  fails closed; the exemption that [Gates](gates.md) and the troubleshooting rows
  below describe holds on macOS and Linux only. If a session fails closed there,
  for example after a plugin update that Zensu could not adopt automatically,
  start a fresh session.
- [Work-order mode](work-order-mode.md) is unverified.
- The browser consent gate behind `/zensu:verify-feature` has not been tested end
  to end with a real `playwright-cli`.

On pull requests, CI runs the deterministic test suite on Ubuntu and a subset of
it on Windows under Git Bash; a broader set of suites runs on Windows once a
week. No CI job starts Claude Code itself, none runs on macOS, and none uses WSL.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `zensu` CLI not found, or older than 0.10.0 | Install zensu-cli 0.10.0 or later with `brew install --cask mkitconsulting/tap/zensu` (upgrade: `brew upgrade --cask zensu`), `curl -fsSL https://zensu.dev/install.sh \| sh`, or on Windows `irm https://zensu.dev/install.ps1 \| iex`, and ensure it is on `PATH` — the session banner and `/zensu:doctor` warn when it is missing or older |
| Backend unreachable / `zensu` command errors | Verify network connectivity to `https://api.zensu.dev` (or your self-hosted `ZENSU_API_URL` — see [Self-hosting](../README.md#self-hosting)), and that `zensu auth status` shows a logged-in session |
| Invalid API key | Verify `ZENSU_API_KEY` format (`zsk_...`) and re-run `echo "$ZENSU_API_KEY" \| zensu auth login --with-token -` — see [API Key (CI/CD)](../README.md#api-key-cicd) |
| Hook errors on Windows, or a Zensu gate that does not fire there | Run Claude Code inside WSL, or install Git for Windows so that Claude Code runs the hooks through Git Bash; if it cannot find Git Bash, set `CLAUDE_CODE_GIT_BASH_PATH`. When a Zensu gate refuses a PowerShell command, run it through the Bash tool, or set `CLAUDE_CODE_USE_POWERSHELL_TOOL=0` to keep Claude on the Bash tool. Make sure your shell profile prints nothing: Git Bash sources it for hook commands too, and output ahead of a hook's JSON makes Claude Code ignore that JSON decision. If every tool call is refused because Claude Code cannot start `node`, or with `zensu: reviewer capability gate unavailable`, check that `node` is on the `PATH` of the environment that starts Claude Code. See [Platform Support](#platform-support). |
| Planning agent cannot mutate Zensu state | Expected: `zensu:zensu-plm` receives neutral `host-profile-v1` context but its agent definition exposes only `Read`/`Grep`/`Glob`, and the enforcement gate adds nothing beyond them except the host's `SubagentHandback` report tool and the workflow result tool `StructuredOutput`. Return to the top-level interactive thread and invoke the matching `/zensu:bootstrap`, `/zensu:ghost-scan`, `/zensu:implement`, or `/zensu:security-review` skill there. If even the interactive thread is neutral, run `/zensu:doctor` and compare the installed Claude Code version with the pinned supported version; a host/runtime mismatch requires updating or restoring the supported host, then starting a fresh session. |
| OAuth login not opening | Check your default browser settings |
| Review chain will not advance (`--review-ticket` refuses, `--current-review-ticket` reports nothing, `/zensu:reset-review-limit` not applicable) | Run `zensu-log.sh --chain-status` (or `/zensu:doctor`) to read the chain shape and its supported next command. Only a receipt that disagrees with its own workflow document is a true wedge; `/zensu:recover-chain`, from the session that owns the chain, repairs exactly that and nothing else. Never arm a fresh chain to work around a lock or commit failure — those report their own message and leave the budget intact. |
| `/zensu:verify-feature` stops with PARTIAL before opening a browser (`loopback origins only`, a remote target in a session that cannot show the permission prompt, `playwright-cli` not found, `the browser consent gate is not ready (…)`, a reason ending in `so no run config is written; …`, or a rejected runtime recipe) | The browser consent gate reads the navigation policy from the environment that launched Claude Code, a local run also needs an accepted runtime recipe, and the browser needs `playwright-cli` on `PATH` (`npm install -g @playwright/cli@0.1.21`, the version the browser consent gate was measured against; `brew install playwright-cli` is unpinned). The run-config helper also refuses, in its preflight and before it writes a run config, unless both consent hooks are registered, the `@playwright/cli` manifest of that `playwright-cli` names that version and no empty or relative `PATH` entry comes before or holds it; for those refusals run `/zensu:doctor` and follow section 5 of [Verify a feature live](verify-feature.md). For a remote target, switch the session to Manual or Auto so the permission prompt can ask you; for a policy, exit Claude Code, export `ZENSU_VERIFY_NAVIGATION_POLICY_V1` in the launching shell, and start it again; a `Bash` call inside the session cannot set it. See [Verify a feature live](verify-feature.md). |
| `/zensu:verify-feature` reports a non-browser scenario PARTIAL for a missing tool (`xcrun`, `xcodebuild`, `adb`, `emulator`, `maestro`, `tmux`, …), or names a `kept` resource | Every driver other than `browser` needs its own toolchain on `PATH`, and the skill never installs one without asking: install the missing tool and re-run, or accept the lower rung the report names. Teardown removes only the devices, processes, clusters, containers and `tmux` sockets the run recorded, after re-checking that each is the run's own; for a kept resource, check that it carries the run's `zensu-verify-<run>` prefix before removing it yourself. See [What it can verify](verify-feature.md#what-it-can-verify). |
| TDD phase gate blocking a legitimate edit | A tool call cannot lift the gate: `ZENSU_TDD_GATE` is read from the environment Claude Code was started in, so `ZENSU_TDD_GATE=off` there disables it for the whole session and the bypass ledger records it. To leave the chain instead, run `CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --tdd-reset`. For an edit that belongs to the chain, let the top-level `/zensu:build` Skill declare the correct phase via `CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --phase <PHASE> --step <step_id>` first |
| Everything started failing closed right after a plugin update, and `/zensu:doctor` reports an incompatible lineage | The record is readable; the running installation declares an incompatible lineage (while the plugin is at major `0` the minor is the breaking axis). Zensu adopts such a record automatically on the first hook contact after `/reload-plugins`, so reaching this state means that adoption was refused, did not complete, or was switched off with `hooks.sessionAutoAdopt: false` — a gate's deny names the token and says which. Run `/zensu:adopt-session` — it prints the same refusal in full and names a superseded record file when one blocks the adoption; when it reports the record as adoptable instead, the automatic path was either opted out or did not complete (a lock timeout, or a fault inside the adoption itself) — then `/zensu:adopt-session --confirm` to retry by hand (the manual form ignores the opt-out, so on an opted-out record ask the user first). Both stay reachable in that state, as does `/zensu:doctor`. The session binds again from the next tool call onward, so do **not** restart after a successful adoption. `workflow-schema-mismatch` means a persisted shape really did change and a fresh session is the only way forward; `executing-runtime-older` means the running installation is a downgrade, so re-install the newer version. Review-evidence leases minted before the update are set aside and their evidence has to be gathered again. |
| The same row, but `/zensu:doctor` says the recorded project root is **also** gone | Two disagreements hold at once — a worktree removed while the session was open, plus the update. The record is still readable and adoption still applies, so run the same two commands. What differs is what they buy: adoption clears the lineage break so `Bash`, except a `zensu` CLI call, whose gate needs a binding, and the read-only diagnostics work again, and it re-mints the record around the **same absent anchor**, so the session lands in the ordinary orphaned-project-root state where `Edit`, `Write` and `MultiEdit` stay denied, and so does any `Bash` command the source-write gate can attribute as a write while that opt-in gate is on (`hooks.bashWriteGate: true`) and no usable `CLAUDE_PROJECT_DIR` remains. Do not read the row above as promising a full rebind here. To restore `Edit`, `Write` and `MultiEdit`, run `/zensu:adopt-session --restore-root --confirm` **afterwards** — the order matters, because that repair requires the running installation to SERVE the record, which the adoption is what establishes. It re-creates exactly that directory (`/zensu:doctor` names it) **and** rebuilds the workflow document the removal took with it; a bare `mkdir` leaves the second half missing and every tool denied. It restores the anchor, not the work: the directory comes back empty, it is not a git worktree, and the chain that lived there is gone — a forecast of what it plants, which the report withholds when another run wins the race and creates the directory first, and which `/zensu:doctor` replaces afterwards with a probe of the recorded root. Starting a fresh session remains the alternative. If it was moved rather than deleted, its state still exists there, and moving it back is better than re-creating it. |
| Stateful helper reports that its rendered Session Control binding is unavailable | Confirm Claude Code `2.1.296` or newer. If the plugin was updated normally, an already-running session keeps its previous version until `/reload-plugins` runs in it; running it is supported, and the record is adopted automatically on the next hook contact. Never overwrite a loaded cache directory; restore that session's previous cache bytes if that occurred. Do not source an internal binder or search for another plugin root. The retired `~/.zensu/plugin-root` locator is never consulted by the updated plugin. Delete it only once no Claude Code session from an older installation is still running; the plugin never deletes it automatically. |
