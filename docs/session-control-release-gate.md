# Session Control installed-plugin release gate

The Claude Code nightly and release gates validate what an end user actually
runs: a plugin installed by the Claude Plugin CLI, not a source checkout passed
through `--plugin-dir`.

## Trust chain

1. The runner requires a clean checkout at the exact
   `ZENSU_EXPECTED_SOURCE_REVISION` Git SHA and Claude Code CLI `2.1.211`.
2. The production marketplace entry must use the official GitHub source object
   and pin `MKITConsulting/zensu-claude-code` at the immutable `v<plugin
   version>` ref. A mutable branch source is rejected before provisioning.
3. `create-local-marketplace-fixture.js` makes a no-hardlink local clone of the
   clean source checkout, detaches it at the exact expected SHA, rechecks both
   trees for drift, and writes a separate private marketplace whose only source
   override is `./plugin`. The production marketplace inside the clone remains
   unchanged and the clone keeps the expected Git HEAD.
4. `provision-installed-plugin.sh` creates a private, isolated `HOME`, registers
   that ephemeral marketplace, installs `zensu@zensu` at user scope, and parses
   `claude plugin list --json`. It never registers the source worktree directly.
5. The install is accepted only when there is exactly one enabled user-scope
   entry, its physical `installPath` lies below the isolated Claude cache, and
   settings plus `installed_plugins.json` identify that same path and Git SHA.
6. Source and installed manifests must identify the same plugin version. Their
   Session Control runtime digests must be byte-identical; missing and additional
   runtime files both fail.
7. The wrapper launches Claude with the isolated HOME and no `--plugin-dir`.
   The real `SessionStart` must create the immutable record and bind its
   `plugin_root` to the installed cache. `source_revision` is content-addressed
   and must equal `runtime_digest`; Git SHA remains separate wrapper evidence.
8. The wrapper re-hashes source, installed runtime, stream, configuration, and
   state before emitting exactly one canonical control attestation. The receipt
   records the clean source SHA, source/cache roots, and both runtime digests.
9. All isolated HOME, fixture clone, cache, plugin data, evidence, and contention state is
   deleted on completion or failure.

## Behavioral proof

- The live suite runs a fresh main session, a real `zensu:review-aspect`, and a
  normal `zensu:zensu-plm` subagent. The normal child attempts a structured Bash
  probe and must receive the exact neutral `host-profile-v1` denial; it never
  receives `main-v1` or Session Control access. The reviewer derives a marker only from injected
  reviewer context and proves it with a structured `Read`, without reading the
  Session Control record.
- The concurrency suite starts 12 independent wrapper processes. A dynamic
  barrier forms three generations of exactly four distinct live participants;
  each generation releases only after all four are ready. Duplicate identities,
  timeout, crash, fifth-participant corruption, or residual successful-run lock,
  ready, or release artifacts fail closed.
- The adversarial suite executes six reviewer attack categories five times each
  and accepts only structured nested tool attempts plus host denials/errors.

## Commands

```bash
npm run session-control:selfcheck
npm run session-control:contract

ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 \
ZENSU_EXPECTED_SOURCE_ROOT="$PWD" \
ZENSU_EXPECTED_SOURCE_REVISION="$(git rev-parse HEAD)" \
ANTHROPIC_API_KEY='…' \
npm run session-control:release
```

The live command is intentionally credential-blind beyond forwarding the
explicit credential to Claude. Plugin marketplace/install/list commands run
with Claude credentials removed from their environment. Missing credentials,
CLI drift, dirty source, registry ambiguity, runtime drift, or incomplete host
evidence fails instead of skipping.

## Automated release ordering

The `Release` workflow has two exact-SHA gates:

1. A non-dry `prepare` run bumps the plugin version and the production
   marketplace source ref together, then creates the release commit locally
   before any live validation. The created `git rev-parse HEAD` becomes the sole
   `ZENSU_EXPECTED_SOURCE_REVISION`; the checkout must be completely clean
   before and after `npm run session-control:release`. The prospective tag does
   not need to exist: the gate installs the exact commit through its private
   local fixture, while preserving the production tag-pinned marketplace.
2. The prepare job requires `ANTHROPIC_API_KEY` or
   `CLAUDE_CODE_OAUTH_TOKEN`, sets
   `ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1`, and installs Claude Code CLI exactly
   `2.1.211`. Missing credentials, a different HEAD, a dirty checkout, CLI
   drift, installation mistargeting, or any failed profile stops the workflow
   before the release branch can be pushed.
3. Each profile writes a sanitized receipt below the release artifact's
   `suites/` directory. After the complete gate passes, the workflow also writes
   a summary receipt containing the exact Git SHA, runtime digest, plugin
   version, and CLI version. It uploads the complete tree as
   `session-control-release-<created-commit-sha>` before pushing the branch.
4. Landing the reviewed release commit on `main` does **not** make the new
   plugin version live. The catalog now points to an as-yet unavailable tag.
5. Before any paid validation, the publish job reads the repository's
   `immutable-releases` setting through the GitHub REST contract dated
   `2026-03-10`, with the separate
   `IMMUTABLE_RELEASES_ADMIN_TOKEN` and requires `enabled:true`. It verifies
   marketplace version and `ref`, rejects a pre-existing tag at another SHA,
   repeats the complete gate against the exact clean `${{ github.sha }}`, and
   uploads `session-control-publish-${{ github.sha }}`.
6. Immediately before publication it rechecks that setting with the same
   read-only administrative token. Publication itself uses only the job's
   contents-write token: create or validate an exact-SHA draft, attach exactly
   one named asset, verify its uploaded state and SHA-256 digest, then publish
   the draft. Publication polls at most ten times, two seconds apart, until
   GitHub reports both `immutable:true` and the expected asset digest. A retry
   accepts a published release only when GitHub reports
   `immutable:true`, the tag resolves to the exact main SHA, and the sole asset
   still matches. Mutable published releases fail closed and are never repaired.
7. Publishing the draft creates `v<plugin version>` at `${{ github.sha }}`.
   Tag creation makes the production marketplace source resolvable and is the
   go-live event; the final REST verification proves the release is immutable.

`dry_run: true` is deliberately offline: deterministic tests, version
calculation, and release-note rendering still run, but it creates no release
commit, consumes no Claude credential, runs no paid live profile, uploads no
release evidence, and pushes nothing. A dry run is a preview, never a release
authorization.
