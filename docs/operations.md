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
false` switches the automatic path off. Until `/reload-plugins` runs, a session
keeps executing its previous version and nothing in it reaches the adoption.
Every release must use a new SemVer version and immutable `v<version>` source
tag.

The former `~/.zensu/plugin-root` locator is neither read, migrated, nor
rewritten during install or update. Delete it only once no Claude Code session
from an older Zensu plugin installation is still running in the same home; the
plugin never deletes it automatically.

## Platform Support

Hooks use `bash -c` and require a POSIX-compatible shell. Supported platforms:
- macOS
- Linux

Windows users need WSL or Git Bash. Native `cmd.exe` and PowerShell are not supported for hooks.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `zensu` CLI not found | Install the CLI (`curl -fsSL https://zensu.dev/install.sh \| sh`) and ensure it is on `PATH` — the session banner warns when it is missing |
| Backend unreachable / `zensu` command errors | Verify network connectivity to `https://api.zensu.dev` (or your self-hosted `ZENSU_API_URL` — see [Self-hosting](../README.md#self-hosting)), and that `zensu auth status` shows a logged-in session |
| Invalid API key | Verify `ZENSU_API_KEY` format (`zsk_...`) and re-run `echo "$ZENSU_API_KEY" \| zensu auth login --with-token -` — see [API Key (CI/CD)](../README.md#api-key-cicd) |
| Hook errors on Windows | Use WSL or Git Bash (see [Platform Support](#platform-support)) |
| Planning agent cannot mutate Zensu state | Expected: `zensu:zensu-plm` receives neutral `host-profile-v1` context but its agent definition and enforcement gate expose only `Read`/`Grep`/`Glob`. Return to the top-level interactive thread and invoke the matching `/zensu:bootstrap`, `/zensu:ghost-scan`, `/zensu:implement`, or `/zensu:security-review` skill there. If even the interactive thread is neutral, run `/zensu:doctor` and compare the installed Claude Code version with the pinned supported version; a host/runtime mismatch requires updating or restoring the supported host, then starting a fresh session. |
| OAuth login not opening | Check your default browser settings |
| Review chain will not advance (`--review-ticket` refuses, `--current-review-ticket` reports nothing, `/zensu:reset-review-limit` not applicable) | Run `zensu-log.sh --chain-status` (or `/zensu:doctor`) to read the chain shape and its supported next command. Only a receipt that disagrees with its own workflow document is a true wedge; `/zensu:recover-chain`, from the session that owns the chain, repairs exactly that and nothing else. Never arm a fresh chain to work around a lock or commit failure — those report their own message and leave the budget intact. |
| `/zensu:verify-feature` stops with PARTIAL before opening a browser (`navigation policy mode does not match`, `loopback-IP origins only`, or a rejected runtime recipe) | The Playwright broker reads its navigation policy from the environment that launched Claude Code, and a local run also needs an accepted runtime recipe. Exit Claude Code, export `ZENSU_VERIFY_NAVIGATION_POLICY_V1` in the launching shell, and start it again; a `Bash` call inside the session cannot set it. See [Verify a feature live](verify-feature.md). |
| TDD phase gate blocking a legitimate edit | Set `ZENSU_TDD_GATE=off` for that edit only, or let the top-level `/zensu:tdd` Skill declare the correct phase via `CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --phase <PHASE> --step <step_id>` first |
| Everything started failing closed right after a plugin update, and `/zensu:doctor` reports an incompatible lineage | The record is readable; the running installation declares an incompatible lineage (while the plugin is at major `0` the minor is the breaking axis). Zensu adopts such a record automatically on the first hook contact after `/reload-plugins`, so reaching this state means that adoption was refused, did not complete, or was switched off with `hooks.sessionAutoAdopt: false` — a gate's deny names the token and says which. Run `/zensu:adopt-session` — it prints the same refusal in full, or reports the record as adoptable when the automatic path was opted out — then `/zensu:adopt-session --confirm` to retry by hand (the manual form ignores the opt-out, so on an opted-out record ask the user first). Both stay reachable in that state, as does `/zensu:doctor`. The session binds again from the next tool call onward, so do **not** restart after a successful adoption. `workflow-schema-mismatch` means a persisted shape really did change and a fresh session is the only way forward; `executing-runtime-older` means the running installation is a downgrade, so re-install the newer version. Review-evidence leases minted before the update are set aside and their evidence has to be gathered again. |
| The same row, but `/zensu:doctor` says the recorded project root is **also** gone | Two disagreements hold at once — a worktree removed while the session was open, plus the update. The record is still readable and adoption still applies, so run the same two commands. What differs is what they buy: adoption clears the lineage break so READ-ONLY `Bash` and the read-only diagnostics work again, and it re-mints the record around the **same absent anchor**, so the session lands in the ordinary orphaned-project-root state where `Edit`, `Write` and any `Bash` command that WRITES stay denied. Do not read the row above as promising a full rebind here. To write again, re-create exactly that directory — `/zensu:doctor` names it — or start a fresh session. If it was moved rather than deleted, its state still exists there. |
| Stateful helper reports that its rendered Session Control binding is unavailable | Confirm Claude Code `2.1.211` or newer. If the plugin was updated normally, an already-running session keeps its previous version until `/reload-plugins` runs in it; running it is supported, and the record is adopted automatically on the next hook contact. Never overwrite a loaded cache directory; restore that session's previous cache bytes if that occurred. Do not source an internal binder or search for another plugin root. The retired `~/.zensu/plugin-root` locator is never consulted by the updated plugin. Delete it only once no Claude Code session from an older installation is still running; the plugin never deletes it automatically. |
