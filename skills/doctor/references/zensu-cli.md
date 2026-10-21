# zensu CLI rows

Read this before you relay any `zensu CLI:` or `zensu CLI version:` row. The doctor finds the CLI
with `command -v zensu`, then asks `hooks/lib/zensu-cli-version-v1.js` for the version, and runs
`zensu auth status` only when that probe did not answer that `PATH` reaches `zensu` through an
empty or relative entry. Every `zensu` call runs with `ZENSU_NO_UPDATE_CHECK=1`, so the CLI's update
check neither calls GitHub nor writes `version-check.json`. `zensu auth status` may still store the
identity it decodes from a stored token in the CLI's own `hosts.json`.

- **✅ zensu CLI: installed and authenticated** → nothing to do.
- **⚠️ zensu CLI: installed but not authenticated** → `zensu auth login`. The CLI exits 0 and prints
  `Not logged in` when no login is stored; the doctor reads that as not authenticated.
- **⚠️ zensu CLI: PATH reaches zensu through an empty or relative entry** → the doctor ran nothing,
  so neither the login nor the version was checked. Tell the user to remove that entry from `PATH`,
  or to move it behind the directory that holds `zensu`. Do not run `zensu` in this session until
  that is done: the shell would run whatever binary that entry reaches.
- **⚠️ zensu CLI: not found on PATH** → relay the install commands the row names.
- **✅ zensu CLI version: … at or above …** → nothing to do.
- **⚠️ zensu CLI version: … is older than …** → relay the upgrade commands the row names. An older
  release still runs every command; the row says what it gets wrong.
- **⚠️ zensu CLI version: a development build** → the floor was not checked. Nothing to do unless
  the user expects a release.
- **⚠️ zensu CLI version: the shell found zensu but the version probe found none on PATH** → a
  shell function or alias named `zensu`; the floor was not checked.
- **⚠️ zensu CLI version: `zensu --version` printed no version this report could read** → the floor
  was not checked; suggest running `zensu --version` and relay what it prints.
- **⚠️ zensu CLI version: PATH reaches zensu through an empty or relative entry** → as the matching
  `zensu CLI:` row above.
- **⚠️ zensu CLI version: not judged** → the plugin's version module did not load; reinstall the
  plugin.

Never install, upgrade or log in on the user's behalf.
