# Review Chain

The agents that review your code, how a repo extends them, and the artifact
skeletons they anchor on.

### Agents (6)

| Agent | Role | How It Works |
|-------|------|--------------|
| **zensu-plm** | Read-only planning analyst | Explains and decomposes Zensu lifecycle work. It receives neutral context but exposes only `Read`, `Grep`, and `Glob`; the matching skill performs mutations in the interactive main thread. |
| **code-reviewer** | Quality Review | Consolidates the review. Standalone: walks 5 specialist perspectives (conventions, bugs, architecture, tests, security) in a single READ-ONLY agent. In the `/zensu:tdd` chain: runs in **fan-out consume mode**, emitting the report the main thread merged from five parallel `review-aspect` agents (no re-read, no build/test). |
| **review-aspect** | Single-Perspective Review | READ-ONLY reviewer scoped to ONE perspective. The `/zensu:tdd` chain spawns five in a single parallel batch (one per perspective), then merges their findings in the main thread. Runs zero build/test commands — the suite already ran in the Phase 6 audit. |
| **review-judge** | Independent Second Pass | READ-ONLY judge spawned AFTER the five-aspect merge (gated by `hooks.reviewJudge`, default on). Re-reads the changed files fresh and covers the panel's structural blind spots: cross-cutting integration, requirement drift against the plan's stable AC-###/FR-### IDs, missed edge cases, and panel quality — a false-positive panel finding gets a `Panel-FP:` meta-verdict that the main thread neutralizes before fix routing. Emits `JUDGE-*` deltas; never repeats panel findings, never runs build/test. |
| **plan-review-worker** | Confined plan validator | Dedicated `/zensu:plan-review` worker with only `Read`, `Grep`, and `Glob`. It reads a private, immutable evidence lease and returns one raw `kind:"plan-review"` JSON object as its final message; only the main thread validates and materializes that result. |
| **pr-review-worker** | Confined PR persona | Dedicated `/zensu:pr-team-review` worker with only `Read`, `Grep`, and `Glob`. It reviews a leased role/area evidence shard and returns one raw `kind:"pr-review"` JSON object; it cannot write files, mutate tasks, message agents, spawn agents, run commands, or publish. |

The built-in reviewer boundary uses each agent's exact
`tools: Read, Grep, Glob` allowlist. There is no shell or Git exception and no
control/agent tool. The first all-tool `PreToolUse` hook is the fail-closed
enforcement point: it revalidates the immutable Session Control context on every
tool call, recognizes Claude Code's plugin-scoped `zensu:code-reviewer`,
`zensu:review-aspect`, `zensu:review-judge`, `zensu:plan-review-worker`, and
`zensu:pr-review-worker` identities (plus exact bare
`--agents` fixtures), then repeats the exact three-tool reviewer allowlist. The
plugin-scoped `zensu:zensu-plm` receives the same strict allowlist. Every other
neutral `host-profile-v1` child may retain ordinary non-command host tools, but
cannot invoke `Bash`, `shell`, `exec`, `exec_command`, `terminal`, or `command`.

The two review-worker identities add a private evidence lease on top of that
three-tool profile. The interactive main thread creates one immutable generation
containing exact files and narrow search roots, records each host worker id, and
never exposes the lease id or plugin-data path to the worker. Each tool call
revalidates canonical paths, symlink/path identity, and the creation snapshot so
TOCTOU replacement fails closed. PR leases also bind the exact
`core.quotePath=false` name-status manifest; ambiguous quoted/backslash paths and
findings outside that changed-path set fail closed. `SubagentStop` captures the
worker's one raw JSON result; collection requires the exact worker id, result
kind, and role.
Only then may the main thread write a debug JSON file, and it closes the lease on
success and failure. Repository instructions, diffs, source text, overlays, and
refinement context remain untrusted data and cannot widen this contract.

> **Implementation is no longer delegated to an agent.** Since 0.4.0 `/zensu:tdd` runs in the **main thread** — vanilla by default, with strict RED→GREEN available when configured — because the old `tdd-manager` subagent lost too much implementation context. Since 0.6.0 the review chain fans out to five parallel `review-aspect` subagents, optionally runs `review-judge`, and consolidates through one consume-mode `code-reviewer`, while preserving the round counter, auto-fix loop, and self-review terminus.

#### Custom review personas (repo-local)

Projects extend the review panel without forking the plugin: drop agent definitions at `.claude/agents/zensu-review-*.md` (standard agent frontmatter + body prompt; Claude Code registers them at session start — a file added mid-session is not yet spawnable and gets logged as `PERSONA SKIPPED — <name> (not registered)`). The frontmatter `name:` must equal the filename stem and match `zensu-review-[A-Za-z0-9_-]+` — anything else is skipped as malformed. An optional `activation:` field holds comma-separated glob patterns (items may be quoted) matched against the changed-file paths — `**` crosses directory separators on segment boundaries (`"**/domain/**"` matches `src/domain/x.ts` but not `src/subdomain/x.ts`), `*`/`?` stay within one segment, and a pattern without `/` also matches the basename. Project-agnostic examples: `"**/domain/**"` (DDD rules), `"**/*.tf"` (infrastructure), `"**/*.component.ts"` (frontend components). A persona with no `activation:` field always joins; one whose globs match nothing is skipped AND named in the run log (`PERSONA SKIPPED — <name> (no activation match)`) — never silently omitted; malformed files (bad frontmatter, name/stem mismatch, symlinks) are skipped with a log line and never abort the chain. Extra personas are capped at five per run — glob-matched personas take slots before always-join ones (relevance wins), each group lexicographic; overflow is logged as dropped. **Output contract:** a persona reports exactly like a built-in aspect — `## Aspect: <persona-name>` header with `- [SEVERITY] file:line — finding` bullets — except every finding is prefixed with the persona's uppercased `<NAME>-<n>` ID for provenance. **Trust boundary:** a persona file is a repo-controlled prompt at the same trust level as any `.claude/agents` definition or a checked-in `CLAUDE.md` — the read-only/no-build contract is carried by the spawn prompt and the persona's own `tools:` frontmatter, not by promotion to the built-in reviewer principal. Custom personas stay neutral `host-profile-v1`: the all-tool gate prevents Session Control/workflow-root access and `main-v1` impersonation, but their ordinary host tools remain governed by their own frontmatter. Audit `zensu-review-*.md` files in third-party repos before running `/zensu:tdd` or `/zensu:plan-review` (both spawn personas from the local working checkout; `/zensu:pr-team-review` is base-scoped). Matching is decided deterministically by `hooks/lib/persona-activation.js` (changed files on stdin, personas dir as argv; verdict lines `spawn`/`skip`/`drop`).

Here, “ordinary host tools” means non-command tools only: neutral personas are
denied every shell/command alias regardless of their frontmatter.
**Three consumers, one file.** The same `.claude/agents/zensu-review-*.md` persona feeds three review flows: `/zensu:tdd`'s Phase 6 fan-out, `/zensu:pr-team-review`'s cast, and `/zensu:plan-review`'s cast. A persona file declares only the *concern* (its body) plus its *activation globs* (frontmatter) and stays **output-format-agnostic**; each flow injects its own output contract at spawn — `/zensu:tdd` wants the `## Aspect: <persona-name>` markdown above, while the two team-review skills want structured JSON (`$WORKDIR/<name>.json` per their shared schema). A body that hardcodes one format still runs under the others (the injected contract wins), but keeping the body format-neutral lets one file serve all three. **Trust boundary for PR review:** `/zensu:pr-team-review` reviews an untrusted PR head, so it discovers personas from the reviewed repo's **base checkout** (`$REPO/.claude/agents`), never the PR-head worktree — a PR cannot introduce its own reviewer. `/zensu:plan-review` and `/zensu:tdd` run against the trusted local working checkout and discover from its git toplevel.
**Inline anchors.** When `/zensu:pr-team-review` publishes, every inline comment anchor is pre-validated against the diff by `hooks/lib/valid-diff-lines.js`, with nearest-line remap, so a finding whose line is not commentable is relocated rather than lost.

#### Skill overlays (additive-only)

Three skills carry an overlay anchor (`<!-- zensu:overlay <name> -->`): `tdd`, `cover`, and `pr-team-review`. A repo drops team guidance at `.zensu/overlays/<name>.md` (resolved at the git toplevel of the working checkout, worktree-aware, same anchor as templates and personas) and the skill injects it at that point. The contract is **additive-only**: an overlay may ADD conventions, extra checks, and stack particularities; it can NEVER disable, replace, weaken, or reorder the skill's mandatory phases (discipline gates, evidence audits, review chain, chain terminus) — on any conflict the skill text wins and the run surfaces one line naming the ignored overlay directive. Missing or empty file = no-op. **Trust boundary:** overlays are repo-controlled prompts at the same trust level as `.claude/agents` personas or a checked-in `CLAUDE.md` — the additive-only rule is carried by the skill instruction, not enforced by code; audit `.zensu/overlays/` in third-party repos before running. Example overlay (`.zensu/overlays/tdd.md`):

```markdown
- Team convention: every new module gets an ADR reference in its header.
- Extra check: flag any new dependency added without a lockfile update.
```

#### Templates (repo-overridable)

Four artifact skeletons ship as plugin defaults under `templates/` and resolve with the repo winning: a consumer uses `.zensu/templates/<name>.md` at the git toplevel of the working checkout (`git rev-parse --show-toplevel` — worktree-aware, same anchor as persona discovery) when it exists, else `<absolute-plugin-root>/templates/<name>.md`. The top-level Skill obtains that concrete root from Claude's native `${CLAUDE_PLUGIN_ROOT}` substitution; a supporting file loaded with `Read` must receive the already-resolved value from its parent instead of expecting another substitution pass. An override REPLACES the default wholesale — it MUST keep the mandatory sections, because the Phase 5/6 audits and `/zensu:converge` anchor on them (a structure test can only pin the plugin defaults, so for overrides this is a documented contract):

| Template | Consumer | Mandatory sections |
|----------|----------|--------------------|
| `tdd-plan.md` | `/zensu:tdd` Phase 2 | `## Requirements` (ID/Covers), `## Preconditions`, `## Cross-Layer Value Flow Pairings`, Status Legend, Steps table with Status+Covers, `## Final Verification` |
| `autopilot-spec.md` | `/zensu:autopilot` Phase 0.C | numbered stable `AC-###` criteria, out-of-scope section, resolved recipe |
| `autopilot-pr-body.md` | `/zensu:autopilot` step 3 | per-AC checklist table (deprecated rows kept), `Gates bypassed during build:` audit line |
| `pr-body.md` | `/zensu:pilot` "Commit + open PR" (shared default for any PR opener) | `## Acceptance criteria` table filled from the feature's `## Requirements` rows, with a stub-row fallback |

#### Code Reviewer — 5 Sequential Specialist Perspectives

The code-reviewer agent is a single READ-ONLY agent (no `Edit` / `Write` / `Task` tools) that walks five perspectives in order:

> In the `/zensu:tdd` review chain (since 0.6.0) these five perspectives are fanned out to parallel `review-aspect` subagents and merged in the main thread; the sequential walk described here is what a direct standalone `code-reviewer` invocation does.

| Reviewer | Scope |
|----------|-------|
| conventions-checker | CLAUDE.md compliance, naming, formatting |
| bug-hunter | Logic errors, off-by-one, null checks, race conditions |
| architecture-reviewer | Layer separation, dependency direction, patterns |
| test-analyzer | Coverage gaps, assertion quality, missing scenarios |
| security-reviewer | Secrets, injection, auth checks, input validation |

Anti-hallucination rules: every finding requires file:line reference, confidence >= 80, must Read the file before reporting. Those rules are directives the reviewer is asked to follow; the **Finding Verification Gate** (`hooks.findingVerification`, default on) is what mechanically checks them afterwards — the main thread grades every merged finding against the real source via the model-free `hooks/lib/finding-verify-v1.js` plus its own read, and marks whatever does not hold up `[Unverified — do not fix]` instead of routing it to a fix or publishing it.
