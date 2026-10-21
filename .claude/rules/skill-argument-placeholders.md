---
paths:
  - "skills/*/SKILL.md"
  - "skills/tdd/references/review-chain.md"
  - "skills/pr-team-review/references/debate.md"
  - "tests/structure/test-skill-workflow-markers.sh"
---

# Skill Argument Placeholders (`test-skill-workflow-markers.sh` AP checks)

When a skill is invoked with arguments, Claude Code rewrites its `SKILL.md` body before the model
reads it, and a shell snippet that uses a positional parameter is rewritten with it. **The rule:
never write `$0`–`$9`, a longer `$<digits>`, `$ARGUMENTS` or a name the `arguments` frontmatter
declares in a skill body, unless the skill consumes its arguments there. Pass a value into a
`bash -c` snippet through a named environment variable instead:**
`ZENSU_ROOT="${CLAUDE_PLUGIN_ROOT}" bash -c 'source "$ZENSU_ROOT/hooks/lib/zensu-config.sh"; …'`.

**What the loader substitutes.** The documentation (`code.claude.com/docs/en/skills`, "Available
string substitutions") names `$ARGUMENTS`, `$ARGUMENTS[N]`, `$N` and `$name` for a declared name,
beside the `${CLAUDE_*}` variables. The substitution function of Claude Code 2.1.286, read out of
the installed binary and run in Node, settles the edges the documentation leaves open:

- A declared name is replaced first, then `$ARGUMENTS[N]`, then `$N`, then `$ARGUMENTS` as a
  plain substring, so `$ARGUMENTSX` is hit as well.
- `$N` is `\$(\d+)(?!\w)`: multi-digit, so `$12` means index 12, while `$1abc` and `$12_x` are left
  alone. `${1}` is left alone too, but it is outside the documented grammar, so do not rely on it.
- A declared name matches `\$name(?![\[\w])`.
- An indexed placeholder without an argument at its index stays literal, so a skill invoked with
  one argument keeps its `$1`. The damage starts at the second argument.
- With no arguments at all the body is returned untouched, so the documented backslash escape
  (`\$1`) is not processed then and reaches the model with its backslash. The escape is no fix for
  a snippet that must run either way.
- Any substitution suppresses the `ARGUMENTS: <value>` line the loader otherwise appends, so a
  stray placeholder also hides the arguments themselves.

**What it cost.** Rendered through that function: `/zensu:self-review` invoked with
`SELF-REVIEW-TICKET: rt_…` put the ticket where the reviewConvergence probe expected the plugin
root, the probe printed `off`, and the ticket line was not appended. `/zensu:tdd` with a spec of two
or more words put the spec's second word into the judge and finding-verification probes and dropped
the spec's `ARGUMENTS:` line. `plan-review` and `pr-team-review` broke the same way from the second
argument on, and `verify-feature` replaced the `"$12"` example of its quoting rule from the
thirteenth word on.

**Where the rule binds.** Only `skills/*/SKILL.md` bodies reach the loader in this plugin. There is
no `commands/` directory; agent definitions in `agents/*.md` are never substituted, because the
2.1.286 binary calls the function only from the skill and command loaders, one built-in command and
the prompt and agent hook runners; and this plugin registers command hooks only. Frontmatter is not
substituted. Supporting files under `skills/<name>/` are read with `Read`, never substituted, which
is why `skills/verify-feature/rules/browser-verification.md` keeps its `"$12"` example while the
skill body says `"$price"`.

**The guard.** `AP1` in `tests/structure/test-skill-workflow-markers.sh` writes a Node probe that
marks code spans (backtick runs paired by length inside one block, where a list item, heading,
quote or table row starts a new block) and fenced blocks (backticks or tildes), scans each body with
the loader's grammar, and fails on every placeholder inside code. A deliberate consumer goes into
`PH_ALLOW` as `<path> <token> <count>`, and the count is exact: one use more or fewer, or any other
placeholder in the same skill, fails. Today the list holds `skills/pilot/SKILL.md $ARGUMENTS 1` and
`skills/pr-fix-findings/SKILL.md $ARGUMENTS 2`. `AP2`–`AP10` pin every grammar arm and every near
miss on fixtures, and `AP10` requires the exact finding count, so a probe that over-reports fails
too. Each arm was bite-tested: ignoring the digit lookahead, the code mask, the allowlist, the
declared names or the fence marking turns its own check red.

**The probes read the bound project's config.** `cfg()` in `hooks/lib/zensu-config.sh` overlays a
project `.zensu/config.json` only from `CLAUDE_PROJECT_DIR`, and the model's Bash tool does not carry
that variable, so every probe passes it. The anchor is the Session Control record's project root, the
path `zensu-log.sh --project-root` prints, because the hooks read the same keys there:
`post-review-tdd-delegate.sh` exports it from `zensu_resolve_project_dir` before it reads
`reviewPanel`, `findingVerification` and `criticalReproduction`, and the `zensu-log.sh` bind exports
it before `--external-review` reads `reviewJudge`. `/zensu:tdd` passes `{project_root}` from Phase 0.
`/zensu:plan-review` and `/zensu:pr-team-review` resolve it inline through `$(… zensu-log.sh
--project-root)`, never from their `$REPO`: plan-review's is the working directory, which after
`/zensu:adopt-session --reanchor` is not the bound root, and pr-team-review's is the reviewed
repository, which can be a clone outside the session whose committed config would then switch the
Finding Verification Gate off for a review published under the user's name. `/zensu:self-review`
passes `$TOP`, the top level of the bound root's work tree.

**Coupled sites.** The probes, and the checks that pin each: `skills/self-review/SKILL.md` Phase 3
(`R25f` in `tests/structure/test-review-convergence.sh`, the flag tail only);
`skills/tdd/references/review-chain.md` step 3 (`LC3k`, same suite), step 4b (`P3h` in
`tests/structure/test-review-judge.sh`, and `P3h2` runs it against a project overlay), the second
run in step 4b (`P3j`, "the same way"), step 4c (`P2c` in `tests/structure/test-finding-verification.sh`)
and its stage 3 (`LC2k`, "the same way"); `skills/plan-review/SKILL.md` step 3b and
`skills/pr-team-review/references/debate.md` step 4b (`P4i`). Every pin but `R25f` holds the whole
command, so a probe that drops the `CLAUDE_PROJECT_DIR` assignment fails it. The operator accounts
are item 2 of the resolution order in `docs/configuration.md` (`P5f`) and the `{project_root}`
paragraph of `docs/tdd-manager-workflow.md` (unpinned). `ZENSU_ROOT` is read by
nothing else in the plugin; pick another name if that ever changes, because the probe hands it to
every child the sourced library starts.

**Version: `patch`.** Skill text and a structure check: no schema field, key set, hook, matcher,
config key or attestation moves.

**Known gaps, accepted and named:**

- **Prose is not linted.** The loader substitutes prose as well. With fourteen arguments every
  skill renders unchanged except the two allowlisted consumers, measured through the 2.1.286
  function; a later prose placeholder is a reviewer's catch.
- **The grammar is one version's.** A later loader that widens it, for example to braces, stays
  unseen until this rule and the probe follow.
- **Declared names are parsed, not YAML-loaded.** The probe reads an inline list, a space-separated
  string and a block list; any other YAML form of `arguments` goes unread.
- **Indented code blocks are not code to the probe**, because list continuation lines in these
  skills are indented the same way.
- **A refused `--project-root` reads the global config only.** In plan-review and pr-team-review
  the substitution is then empty, `cfg()` skips the overlay and the probe answers from
  `~/.zensu/config.json` and `ZENSU_CONFIG`, as it did before the probes passed the root, with the
  verb's refusal on stderr. The verb refuses when the binding is unavailable, which both skills
  already needed for their review-evidence lease, and for a root holding a double quote, a dollar
  sign, a backtick or a backslash.
- **Self-review reads `$TOP`.** A session recorded in a subdirectory that carries its own
  `.zensu/config.json` has its self-review probe read the work-tree top's file while the hooks
  read the subdirectory's (`.claude/rules/review-convergence.md`).
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not checked.
