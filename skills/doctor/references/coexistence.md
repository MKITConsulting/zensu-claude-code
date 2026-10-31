# Coexistence rows

These rows tell the user what Zensu changes about their own setup and how to switch it off.
Relay each one plainly; none of them is an error unless it says so.

## subagents:

The capability gate decides what a subagent may do. For a neutral subagent, which is every
subagent except Zensu's own read-only reviewers, the PLM and the evidence workers, it blocks only
what reaches Zensu's own state and commands that would run outside Bash, where Zensu's command
gates cannot see them. Everything else a subagent does is decided by the user's own
permission rules.

- **✅ subagents: a neutral subagent may use every tool except what reaches Zensu's own state … A named neutral subagent may run Bash commands behind an accident guard** → the default. Relay the boundary as the row states it: Session Control and workflow paths, `.zensu/`, writes to the installed plugin or its private data, Zensu configuration layers, Zensu MCP mutations, `PowerShell`, the shell aliases, `Monitor` commands and tools whose name marks them as running commands or code are denied, because Zensu's command gates see only Bash and PowerShell commands, and a tool whose inputs the gate does not know may not name that state. Say that the guard prevents accidents and is not a sandbox, and that `hooks.subagentShell=false` turns the shell off.
- **✅ subagents: … The subagent shell is off (hooks.subagentShell=false)** → the user switched the shell off, so every subagent `Bash` command is denied. Nothing to do.
- **⚠️ subagents: the subagent shell is withdrawn although no config file this check read sets hooks.subagentShell=false** → a config layer that cannot be read, parsed or resolved, or no layer at all, withdraws the shell fail-closed. Point the user at the config row that flags the file. Do not say the shell was switched off on purpose.
- **⚠️ subagents: the capability gate is installed but its shell-guard module** → a broken installation. Tell the user to reinstall the plugin. Do not describe what a subagent may run, because the report could not judge it.

## zen-mode

zen-mode is on by default: every session gets low-noise answers until the user leaves the
mode. It is advice that yields to the user, so their own CLAUDE.md, their output style or a
style mode they chose outranks it. The `zen-mode default:` row says how the configuration sets
it up, and the `zen-mode:` row says what this session resolves.

- **✅ zen-mode default: on (hooks.zenModeDefault)** → the shipped default. Relay that every session gets low-noise answers, that the user's own CLAUDE.md, output style or a style mode they chose outranks it, that "zen off" leaves it for one session, and that `hooks.zenModeDefault=false` makes it opt-in.
- **✅ zen-mode default: opt-in (hooks.zenModeDefault=false)** → a session gets the mode only after `/zensu:zen-mode`.
- **✅ zen-mode default: off for every session (hooks.zenMode=false)** → the hook is switched off, so no prompt receives the low-noise contract.
- **✅ zen-mode: on (session marker)** or **✅ zen-mode: on (hooks.zenModeDefault)** → the mode is active in this session. Relay the source the row names, that the user's own instructions outrank it, and that "zen off" leaves it.
- **✅ zen-mode: off (session marker)**, **✅ zen-mode: off (hooks.zenModeDefault)** or **✅ zen-mode: off (hooks.zenMode=false)** → the mode is not active in this session. Relay the source and the way back the row names.
- **⚠️ zen-mode: off (unreadable state)** → the marker path is a symlink, is not a regular file, or sits under a directory that cannot be searched, or the marker itself cannot be read or records no choice, so the hook resolves the mode off whatever was recorded. `/zensu:zen-mode` replaces a marker that cannot be read or records no choice; for a link, a stray entry or a directory's permissions, tell the user to repair that path by hand first.
- **⚠️ zen-mode: not checked**, **⚠️ zen-mode: could not be read** or **⚠️ zen-mode: state not recognized** → a missing check, never an all-clear. Do not say whether the mode is on or off.
