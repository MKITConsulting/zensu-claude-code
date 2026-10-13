# CLI and library verification rules (`cli`, `library`)

Loaded for rows whose driver is `cli` or `library`. These drivers need no running service unless the
command under test talks to one; then start that service through `SKILL.md` Phase 2 first. Every
resource the run creates goes through the run-resource helper (`rules/drivers.md` section 5).

## 1. Build the artifact from the worktree

- **Use the build the repository documents**: a Makefile target, a `package.json` script,
  `cargo build`, `go build`, a Gradle task. Record the command and the artifact path; the report
  states both as the build identity.
- **Build out of tree where the tool allows it**, for example `go build -o "$RUN_DIR/bin/<name>"`
  or `cargo build --target-dir "$RUN_DIR/target"`. A tool that can only write into the worktree
  writes its own ignored build directory only, and the report names that directory.
- **Never install or publish the artifact.** No `npm link`, `npm install -g`, `pip install
  --user`, `go install`, `cargo install`, `publishToMavenLocal`, and no publishing to a registry.

## 2. `cli`

- **Run the worktree's build, never an installed copy.** Call the artifact by its path, or the
  repository's documented dev runner (`npm run <script> --`, `cargo run --`, `go run ./cmd/<name>`,
  `python -m <module>`), which executes the worktree's code. A bare command name can resolve to a
  version the user installed.
- **Isolate each scenario.** Run it in a fresh working directory under `$RUN_DIR`. Point the
  tool's configuration and data at `$RUN_DIR` when it supports that: its own flag or variable,
  `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_CACHE_HOME`, or `HOME="$RUN_DIR/home"` for a tool
  that reads its dotfiles from `HOME`. Set these on the artifact's command, not on a build tool,
  which would lose its own caches. A command that can only write to a user-level location runs
  its read-only scenarios; the mutating ones are PARTIAL.
- **Non-interactive and bounded.** Feed stdin from a file or `/dev/null` and bound every call. A
  prompt that waits for input is a failed row, not a hang.
- **Assertions.** Exit code AND stdout or stderr AND the side effects the criterion names: files
  created or changed under `$RUN_DIR`, rows in a run-owned database. Compare exact text where the
  output is a contract (`--json`, machine-readable formats), substrings elsewhere.
- **Matrix dimensions**, only where the change touches them: required and optional arguments,
  invalid input and its exit code, usage and `--help` text, stdin and pipes, TTY versus non-TTY
  output (color, progress bars), environment variables, empty and large inputs, interrupt
  handling.

## 3. Terminal UIs

Drive a TUI in `tmux` on the run's own socket. Record the socket first, then start it with a fixed
size so captures stay comparable, and with `-f /dev/null` so the server loads none of the user's
configuration or plugins:

```bash
tmux -f /dev/null -L <prefix>-tui new-session -d -s main -x 120 -y 40 '<command>'
tmux -L <prefix>-tui send-keys -t main '<keys>' Enter
tmux -L <prefix>-tui capture-pane -p -t main
```

- The captured pane is the TUI's state plane and visual plane: capture it after every
  interaction, read it, and keep the capture in `$RUN_DIR` for the report.
- Teardown ends that server through the helper. Never `tmux kill-server` without `-L`, and never
  attach to or send keys into a `tmux` session the run did not start.
- **Without `tmux`**: an `expect` script in `$RUN_DIR` that spawns the command, sends the keys and
  writes its transcript with `log_file`. **Without either**: the platform's `script` command
  captures a non-interactive run, and the interactive rows are PARTIAL.

## 4. `library`

- **Prefer the repository's own examples, samples or doctests** when they exercise the changed API.
- **Otherwise build a throwaway consumer in `$RUN_DIR/consumer`** that depends on the worktree by
  path: a `file:` dependency for npm, a virtual environment in `$RUN_DIR` for Python, a `replace`
  directive for Go, a `path` dependency with the target directory in `$RUN_DIR` for Rust, a local
  package reference for Swift, the repository's own sample module for the JVM. A build backend
  that writes into the source tree writes its ignored build directories only, and the report
  names them.
- **Keep the consumer out of the repository's workspace.** `$RUN_DIR` lies inside the
  repository, so a workspace above it captures the consumer: give a Rust consumer an empty
  `[workspace]` table in its own `Cargo.toml`, and build a Go consumer with `GOWORK=off`.
- **Assertions.** The consumer returns or prints what the criterion names, and finishes without an
  exception or panic. For a typed language the consumer's build is itself evidence for a criterion
  about the API's shape. Deprecation warnings count when the change introduces them.
