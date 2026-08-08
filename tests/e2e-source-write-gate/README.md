# e2e-source-write-gate

End-to-end coverage for the PreToolUse(Bash) source-write gate
(`hooks/pre-bash-source-write-gate.sh` + `hooks/lib/bash-source-write-parse.js`).
Complements the exhaustive deterministic unit suite
(`tests/structure/test-bash-source-write-gate.sh`) by proving the hook
fires and blocks a **real** Bash tool call inside a live `claude --print` session.

## Layers

`run.sh [mode]`:

- `--self-check` — structural skeleton only, no claude: hook present + executable,
  parser `node --check`s, hook registered on the `hooks.json` PreToolUse `Bash`
  matcher. Runs under `tests/run-all.sh --self-check`, a local deterministic mode;
  the `--ci` gate does not invoke this suite at all.
- `--offline` — deterministic hook-contract assertions ONLY (the structural
  skeleton above runs under `--self-check` and exits there, so the two layers
  never run in one invocation): real
  PreToolUse(Bash) payloads driven straight through the hook against a throwaway
  git project + sibling checkout (D1 clobber→DENY, D2 new file→ALLOW, D3
  escape→DENY, D4 escape-hatch→ALLOW, D5 non-source→ALLOW, and for the
  git-repository-escape rule D6 foreign-repo mutation→DENY, D7 in-project
  mutation→ALLOW, D8 foreign-repo read→ALLOW, D9 the D6 deny reason really is
  rule (C)). No API. The harness scrubs `ZENSU_*` and points `CLAUDE_PLUGIN_DATA`
  at an empty per-run directory, so it *enforces* the **unbound** hook path
  instead of inheriting whatever the caller's environment happens to be. The same
  unbound DENY/ALLOW pair is also pinned as W123/W124 in
  `tests/structure/test-bash-source-write-gate.sh`; what this layer adds is the
  end-to-end shape — a throwaway checkout and a real payload, no fixture scaffolding.
  **D1-D9 are local-only:** `tests/run-all.sh --ci` invokes this suite in no mode,
  and `--self-check` stops before the D layer. The structure suite is the CI gate.
- (no arg / `full`) — the deterministic layer plus **live** `claude --print` runs in the
  fixture git project:
  - L1 the session replies (plugin loaded, hook active);
  - L2 the gate's deny-reason surfaces when the model is asked to `echo >>` a
    tracked source file;
  - L3 the tracked file is unchanged on disk (the bash write did not land);
  - L4 a bash write that creates a **new** file is allowed end to end (no
    false-positive deny).
  Live checks skip gracefully when the API is unavailable and OBSERVE (do not
  fail) on model phrasing variance / Edit-tool fallback.

## Run

```bash
./setup-fixtures.sh          # generate the git fixture (git-ignored)
./run.sh --self-check        # CI skeleton, no API
./run.sh --offline           # deterministic hook asserts, no API
./run.sh                     # full, incl. live claude --print (costs API credits)
```

`ZENSU_BSWGATE_E2E_TIMEOUT` overrides the per-prompt live timeout (default 180s).
Generated `fixtures/` and `results/` are git-ignored.
