# verify-feature: verify-auth read guard causes

Read this when the `❌ verify-feature: cannot start (…)` row names the verify-auth read guard. The
guard keeps every tool the model calls out of the `auth/` directory of a signed-in
`/zensu:verify-feature` run. It runs in-process in the hook dispatcher
(`hooks/lib/verify-auth-guard-v1.js`), and the run-config helper refuses `--login-recipe` unless
`hooks/hooks.json` registers its entry point `hooks/pre-verify-auth-guard.sh` on a matcher that
covers every tool. The probe tries the nine file, search and shell tools, an MCP tool, `Agent`,
`WebFetch`, `TodoWrite`, `LSP` and a name no host defines, so a registration that lists tools
reads as not registered, while a pattern that excludes only one other tool is not detected.
The causes block different runs, so relay the one the parenthesis names:

| The parenthesis names | What it blocks |
|---|---|
| `the verify-auth read guard hook or its module missing from the plugin` | Depends on the file. A missing `hooks/lib/verify-auth-guard-v1.js` makes the dispatcher refuse every call that names a verify-feature run directory, so no run can open a browser or clean up. A missing `hooks/pre-verify-auth-guard.sh` alone blocks only a signed-in run, because the helper refuses `--login-recipe`; the guard itself still runs. Check which of the two files exists before you say which runs are blocked. |
| `the verify-auth read guard module is a symlink, which the guard refuses` | Every call that names a verify-feature run directory, so no run can open a browser or clean up. |
| `the verify-auth read guard module could not be loaded` | The same, refused as `its decision module failed`. |
| `verify-auth guard not registered on a matcher that covers every tool` | Only a signed-in run, because the helper refuses `--login-recipe`. A plain run still works, unguarded on the tools the registration misses. |
| `verify-auth guard registration in hooks/hooks.json could not be determined` | Only a signed-in run, as above. This is a check that could not be made: relay it that way, never as "not registered". |

Every cause is fixed by reinstalling the plugin. Until then a signed-in scenario uses visible
manual login or is reported PARTIAL. The doctor probes the guard's registration only after both
consent hooks answer registered, so a consent-hook cause the row names first can hide an
unregistered guard; run `/zensu:doctor` again once that row clears.
