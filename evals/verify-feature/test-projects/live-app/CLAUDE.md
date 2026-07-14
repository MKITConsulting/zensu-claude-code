# Verify-feature live eval fixture

This repository is a disposable Promptfoo fixture for `/zensu:verify-feature`.

- The application is an unauthenticated inventory dashboard at `/`.
- Use `.zensu/autopilot.yaml` as the runtime recipe.
- `./scripts/fixture-runtime.sh up` starts one loopback-only Node process on a private ephemeral
  port. The parent keeps the exact public policy port bound throughout the run and begins
  forwarding it only after the token/acknowledgement handoff identifies that private port.
- `./scripts/fixture-runtime.sh ready` is the readiness probe.
- `./scripts/fixture-runtime.sh url` prints the run-specific browser base URL.
- `./scripts/fixture-runtime.sh down` stops only the exact PID recorded by this fixture.
- Always run the exact down command as its own standalone Bash invocation, byte-for-byte,
  including after a browser or assertion failure. Run additional cleanup in separate calls.
- Do not edit source files. This fixture exists only for live verification.

The supplied acceptance criteria are authoritative even when the initialized fixture repository
has a clean diff.
