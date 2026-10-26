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
