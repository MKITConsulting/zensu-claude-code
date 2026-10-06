---
paths:
  - "skills/*/SKILL.md"
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

**Coupled sites.** The five probes — `skills/self-review/SKILL.md` Phase 3, `skills/tdd/references/review-chain.md`
steps 4b and 4c, `skills/plan-review/SKILL.md` step 3b and `skills/pr-team-review/SKILL.md` step 4b
— keep the substrings `R25f`, `P3h`, `P2c` and `P4i` pin. `ZENSU_ROOT` is read by nothing else in
the plugin; pick another name if that ever changes, because the probe hands it to every child the
sourced library starts.

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
- **Three probes never see the project config.** The tdd, plan-review and pr-team-review probes run
  without `CLAUDE_PROJECT_DIR`, which the Bash tool does not carry, so a project-level
  `hooks.reviewJudge` or `hooks.findingVerification` is ignored. The self-review probe sets it from
  `$TOP`. That predates this change and is not fixed by it.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not checked.
