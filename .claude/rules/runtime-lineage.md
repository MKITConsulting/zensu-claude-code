---
paths:
  - "hooks/lib/session-control-core-v1.js"
  - "hooks/lib/claude-hook-session-v1.js"
  - "hooks/lib/claude-session-control-v1.js"
  - ".claude-plugin/*.json"
  - ".github/workflows/release.yml"
  - "tests/structure/test-versioned-plugin-upgrade.sh"
---

# Runtime Lineage (`version_type` is load-bearing)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

A plugin update that lands while a session is running leaves the Session Control
record naming the installation that minted it. The running installation may
still **serve** that record when the two share a lineage —
`servesRecordedRuntime` / `runtimeLineageCompatible` in
`hooks/lib/session-control-core-v1.js`. It is the ONE implementation all five
call sites share: `resolveHookSession` and its `resolveOrphanedProjectRoot`
mirror in `hooks/lib/claude-hook-session-v1.js`, `currentClaudeSessionContext`,
and both the SessionStart-resume and SubagentStart branches of
`hooks/lib/claude-session-control-v1.js`. `relatedClaudeSessionContexts` is
deliberately excluded: it compares two records against each other, not a record
against the executing runtime. The axis:

- **same major**, and **while major is `0`, the same minor as well** — `0.17.1 ↔
  0.17.2` compatible, `0.17.x ↔ 0.18.0` not. Without the second clause "same
  major" would make `0.9.2` compatible with `0.17.2`.
- **never backwards**: the executing version must be at least the recorded one.
- the executing root must be a **sibling** of the recorded one, which is what
  keeps a `--plugin-dir` checkout from adopting an installed session's record.

**While the plugin is at major `0`, MINOR is therefore the breaking axis.** A
breaking change costs a `minor` release and a non-breaking feature is a `patch`.
The list below is signed: entries are breaking unless the entry says otherwise.
A breaking one forces the bump because a running session would otherwise be
served by a runtime that cannot read what it wrote; the two marked NOT are
carve-outs kept here so a releaser meets them where they will look:

- the context record or workflow-state **schema** (`SCHEMA_VERSION`, any field
  added, removed or retyped);
- **any strict key set** — `reviewRearm`'s `exactKeys`,
  `deferredReviewCancellation`, and every other validator that rejects an
  unknown or missing key rather than ignoring it;
- **removing or renaming a registered hook, or changing a hook's matcher**;
  **adding** one is NOT in this list and is a `patch`. **Provenance, because it
  matters here:** this exemption and the config-key one below were WRITTEN BY the
  change that needed them — the release that added the best-solution-first hook and
  its `bestSolutionFirst` key. A commit amending the policy that classifies it is
  the shape that deserves a second reader, so it got one: the exemption was
  challenged in review and survived on the argument below, not on the author's own
  say-so. Anyone widening either exemption should expect the same standard. The
  argument has two halves
  and the second is the load-bearing one. First, `runtimeLineageCompatible`
  compares version tuples only and never inspects the hook inventory, an older
  harness never loads a hook its own `hooks.json` does not declare, and the new
  hook is invoked from the tree that declares it. Second — and this is the part a
  reader will otherwise miss — adding a file DOES change the runtime digest, since
  `manifestRuntimeEntries` folds `hooks` and `docs` in wholesale; what keeps an
  in-flight bind alive is that `readContextInternal` measures the **recorded**
  root, and the upgraded case re-measures the executing tree against the caller's
  claim rather than against the record. Do not over-bump defensively; do
  re-derive this if the added hook writes session state, participates in a strict
  key set, **or can return a `permissionDecision` of ANY kind — deny, ask OR allow**.
  The list said only DENY until the reviewer-spawn grant landed, and a releaser
  matching on it would have found no entry covering a hook that GRANTS and
  classified `patch`. The exemption's own closing test already settles it without
  the list: the exempt shape is an ADVISORY hook "whose only output is
  `additionalContext`", which a hook emitting a `permissionDecision` is not, in
  either direction. The third disqualifier is the one an earlier wording
  left out, and it is the one that matters: a hook that can refuse a tool call
  changes the capability set of every session an older runtime is still serving,
  which is exactly what makes a matcher change breaking in the bullet above. A new
  `PreToolUse` entry on the existing `Bash` matcher returning
  `permissionDecision: deny` writes no session state and touches no strict key
  set, so it passed both original tests while being as breaking as anything in
  this list. The test is CAPABILITY, not storage: an ADVISORY hook — one whose
  only output is `additionalContext` — is the exempt shape, and that is what the
  two hooks this exemption was written for are;
- **adding a permissively-read config key** is likewise NOT in this list and is
  a `patch`, for a reason unrelated to the hook inventory: `zensu_hook_enabled` tests only
  `j.hooks[key] === false`, so an older runtime ignores a key it does not know
  rather than failing on it. A key read by a STRICT VALIDATOR is the opposite
  case and belongs under the strict-key-set bullet above — but read that bullet's
  own definition before matching on the word "strict": its members REJECT an
  unknown or missing key. `zensu_hook_enabled_strict` does no such thing. It reads
  one key by name, grants when it is absent, and is strict about the VALUE and the
  READ, not about the key SET — so `hooks.reviewerSpawnAutoAllow` keeps the `patch`
  argument above. The reason it survives is worth stating, because it is not the
  obvious one: the strictness lives in a NEW reader that older runtimes do not
  have, never in a validator they run, so a config carrying that key degrades to a
  no-op there exactly as an unknown key always did. Strict value reading is not
  strict key-set validation; do not conflate them and over-bump;
- the **attestation shape**, which is itself a schema two versions must agree
  on. A change to it has to ship in the release that *introduces* the policy it
  serves, never one release later.

Consequence: the `Release` workflow's `version_type` input carries meaning, not
just a number. Choosing `patch` for a change in that list ships a compatibility
claim the code cannot honour. The predicate encodes what the numbers *mean*; it
cannot verify that this policy was followed.

**Practical consequence for anyone RUNNING a suite: never edit the plugin tree while
one is in flight.** `manifestRuntimeEntries` folds `hooks`, `agents`, `skills`, `docs`,
`templates` and `scripts` in wholesale, so a suite that mints a Session Control record and then invokes a
stateful verb measures the digest TWICE — and an edit to any file under those six directories
between the two measurements makes the second disagree with the first. The verb then refuses
the binding, and the failure surfaces far from its cause: measured here, a one-paragraph edit to
`skills/doctor/SKILL.md` during a `test-doctor.sh` run made `--tdd-begin` fail to arm, so the
chain rendered `no-session` and `P1mc` failed while every check around it stayed green. Nothing
in the failure text names the digest. `CLAUDE.md` and `.claude/rules/` are NOT in that set and
are safe to edit mid-run; the six directories are not. `scripts` joined the set unconditionally when the Playwright
MCP server was removed: it used to be digested only while the manifest declared `mcpServers`, and
the skills and hooks execute helpers from it either way. The `mcpServers`-conditional half STAYS for
`mcp-runtime/package.json` and `mcp-runtime/package-lock.json`, although this plugin no longer
declares a server, and it must not be "cleaned up": the reader re-measures the RECORDED root with
the executing code, so an installation that dropped it computed a different digest for every
0.21.x root, refused those records as `context runtime digest mismatch`, and thereby blocked
`/zensu:adopt-session` at its condition 1 as well. Measured: the executing core reproduces a live
0.21.1 record's `runtime_digest` byte for byte with the branch in place.
`evals/session-control/lib/upgrade-independent-verifier.js` carries the same rule and moves with it. When a suite must run while you keep working, run it from
a detached `git worktree` instead.

**The release that introduces this policy is itself a `minor`**, because it adds
`executing_plugin_root` and `executing_runtime_digest` to the attestation. It is
the last release before the policy binds, so nothing is served across it.

**Known gap 1 — the review-evidence lease is NOT lineage-relaxed.**
`hooks/lib/review-evidence-lease-v1.js` still compares its recorded
`plugin_root` strictly, so a lease minted before an upgrade is refused after it.
Because `listRecords` validates every record and propagates the first failure,
that one lease then fails every later lease operation for the session. Closing it
needs a lease-schema change — the lease record carries no `plugin_version`, so
there is nothing to judge a lineage against. It is pinned as CURRENT behavior in
`tests/structure/test-versioned-plugin-upgrade.sh` rather than left accidental,
so changing it silently fails loudly. **Adoption works around it, it does not
close it:** `discardSupersededLeases` moves every entry `listRecords` would REJECT
— broader than "names the previous installation", narrower than "everything that
reader rejects"; the entry script's header states the exact selector — OUT of the
records directory (into a sibling `superseded/<key>/`,
because `listRecords` fails on any non-`.json` entry, so setting one aside in
place would be strictly worse). The count is reported, never absorbed.

`docs/session-control.md` "Unbindable sessions" carries the operator-facing
account, including the pin this weakens and the two attestation fields that
state the executing runtime. `tests/session-control/session-control-core-v1.test.js`
pins the axis and the sibling rule;
`tests/structure/test-versioned-plugin-upgrade.sh` pins the end-to-end verdicts
across synthetic installs, including that serving a record never rewrites it and
that a capability gate DENYING on an incompatible lineage leaves every record in
the shared store byte-identical.
