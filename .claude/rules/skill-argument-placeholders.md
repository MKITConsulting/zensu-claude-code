---
paths:
  - "skills/*/SKILL.md"
  - "skills/*/references/**"
  - "skills/*/rules/**"
  - "skills/build/references/review-chain.md"
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
root, the probe printed `off`, and the ticket line was not appended. `/zensu:build` with a spec of two
or more words put the spec's second word into the judge and finding-verification probes and dropped
the spec's `ARGUMENTS:` line. `plan-review` and `pr-team-review` broke the same way from the second
argument on, and `verify-feature` replaced the `"$12"` example of its quoting rule from the
thirteenth word on.

**Where the rule binds.** Only `skills/*/SKILL.md` bodies reach the loader in this plugin, and
`plugins/*/skills/*/SKILL.md` bodies in a companion plugin such as `session-hub@zensu`, whose
`/session-hub:session-trail` is one; `AP1` scans both. There is
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
`reviewPanel`, `findingVerification` and `criticalReproduction`, and the review packet gate's
`reviewPacketGate` and `reviewJudge`, and the `zensu-log.sh` bind exports it before
`--external-review` reads `reviewJudge`. `/zensu:build` passes `{project_root}` from Phase 0.
`/zensu:plan-review` and `/zensu:pr-team-review` resolve it inline through `$(… zensu-log.sh
--project-root)`, never from their `$REPO`: plan-review's is the working directory, which after
`/zensu:adopt-session --reanchor` is not the bound root, and pr-team-review's is the reviewed
repository, which can be a clone outside the session whose committed config would then switch the
Finding Verification Gate off for a review published under the user's name. `/zensu:self-review`
passes the `PROJECT_ROOT` its Phase 1 reads from `zensu-log.sh --project-root`.

**Coupled sites.** The probes, and the checks that pin each: `skills/self-review/SKILL.md` Phase 3
(`R25f` in `tests/structure/test-review-convergence.sh`); `skills/build/references/review-chain.md`
step 3 (`LC3k`, same suite, for the panel probe; `I11` in
`tests/structure/test-incremental-review-rounds.sh` for the `hooks.aspectActivation` probe, and
`I11c` and `I11d` run it against a project overlay), step 4b (`P3h` in
`tests/structure/test-review-judge.sh`, and `P3h2` runs it against a project overlay), step 4c
(`P2c` in `tests/structure/test-finding-verification.sh`);
`skills/plan-review/SKILL.md` step 3b and `skills/pr-team-review/references/debate.md` step 4b
(`P4i`). Each of those pins holds the whole command, so a probe that drops the `CLAUDE_PROJECT_DIR`
assignment fails it. The second run in step 4b and stage 3 of step 4c resolve their flags "the
same way" as the probe before them, and `P3j` and `LC2k` pin that wording. The operator accounts
are item 2 of the resolution order in `docs/configuration.md` (`P5f`) and the `{project_root}`
paragraph of `docs/build-workflow.md` (unpinned). `ZENSU_ROOT` is read by nothing else in
the plugin; pick another name if that ever changes, because the probe hands it to every child the
sourced library starts.

**Free text never goes into a command line (`FT1`–`FT7`).** A skill that sends model-written
Markdown, JSON, a plan document, review findings or conditions writes the text to a temporary
file through a heredoc with a quoted delimiter and passes `"$(cat "$f")"`:

```bash
f="$(mktemp)" || exit 1
trap 'rm -f "$f"' EXIT
cat >| "$f" <<'ZENSU_TEXT_<hex>'
<authored-markdown>
ZENSU_TEXT_<hex>
grep -qI '[^[:space:]]' -- "$f" || exit 1
zensu link docs <feature-id> --doc-type <type> --content "$(cat "$f")"
```

Inside double quotes the shell runs every backtick span of the text and expands every
`$NAME`; a single quote ends at the first apostrophe, and the rest of the text becomes shell
words. The quoted delimiter keeps the heredoc body literal, and the shell inserts the output of
`"$(cat "$f")"` as one argument without expanding it again. Measured under macOS `/bin/bash`
3.2.57 and `/bin/zsh` with backticks, `$(…)`, `$HOME`, an apostrophe and parentheses in the text:
every character arrived unchanged. The heredoc stays OUTSIDE `$( )` on purpose: bash 3.2.57
refuses `x="$(cat <<'EOF'` with an apostrophe in the body (`unexpected EOF while looking for
matching`), the same parser hazard as `.claude/rules/bash32-command-substitution.md`. The
redirect also makes the text a write channel the Bash secret scan inspects: `detectChannels`
reports `redirect` and `heredoc` for the file form and nothing for the old inline
`--content "…"`. zensu-cli has no stdin or file form for `--content`, `--candidates`,
`--result`, `--children`, `--tiers`, `--findings` or `--conditions` (read from its
`internal/cmd/*.go` at `bffa3ae`), nor for `--description`, `--expected-result`,
`--scope-summary` and `--scope-details` (read from the zensu-cli 0.16.0 `--help`), which is why
the round trip through a file exists.

Four rules make the recipe safe to repeat. The delimiter is random: `<hex>` stands for eight
hex digits picked anew for each call and written the same on both lines, because a fixed
delimiter ends the heredoc at the first text line that spells it, and the shell then runs every
line after it as a command. A plan document, or a page that documents this recipe, can hold
that line. A plan document that is already a Markdown or plain-text file goes in by path, never
retyped into a heredoc and never under the `trap`, which would delete it: `p` holds an absolute
or `$HOME/…` path, never `~/…`, which double quotes leave unexpanded, and
`[ -f "$p" ] && grep -qI '[^[:space:]]' -- "$p" || exit 1` runs before
`--content "$(cat "$p")"`. A PDF or Word document is read and goes through the heredoc as text.
`>|` writes even under `noclobber`, which a shell profile may set: `mktemp` has already created
the file, so a plain `>` fails with exit 1, the file stays empty and the command still runs with
an empty value. `grep -qI '[^[:space:]]' -- "$f" || exit 1` stops the call before that. The
content check is `grep` because each weaker test lets something through: `cat` of a wrong path,
a `~/…` path, a directory or an unreadable file hands on an empty value; `-s` passes a
directory, an unreadable file and a file of blank lines; and `grep` without `-I` passes a binary
file. `[ -f "$p" ]` stays in front because `grep` would block on a FIFO. Measured under macOS
`/bin/bash` 3.2.57 and `/bin/zsh` with BSD grep 2.6.0, in the C and the `en_US.UTF-8` locale:
with `noclobber` set the plain `>` failed and left 0 bytes, `>|` wrote the file, and a text line
spelling another delimiter stayed text; `grep -qI` returned 1 for an empty, a blank and a binary
file, 2 for an unreadable file and a directory, and 0 for text, a line of umlauts and a single
character between blanks; `-s` passed a directory and `-f` did not, `grep` on a FIFO waited until
a 3-second alarm ended it while `-f` stopped the FIFO, and a `~/…` path in double quotes stayed
literal, so `cat` read nothing. GNU grep was not measured; its manual gives `-q`,
`-I` and `[:space:]` the same meaning. Last, one recipe runs per Bash call,
with one `mktemp` per variable and one `trap` that names every file: a second `trap` replaces the
first, and a second `mktemp` into the same variable leaves the first file behind.

`FT1` scans every Markdown file under `skills/`, references and rules included, and fails on a
`--flag` whose value is a placeholder naming Markdown, JSON, a document, a description, findings
or conditions, whether unquoted, double-quoted, single-quoted or joined with `=`. `FT2` requires the
whole recipe, `>|`, the `<hex>` delimiter, the content check, the `trap` and `"$(cat "$f")"`, in
the seven skills that send free text: docs, implement, bootstrap, ghost-scan, security-review,
autopilot and change. `FT3` and `FT4` pin the five flagged spellings and five near misses on
fixtures. `FT5` pins the text-format sentence at each of the thirteen free-text field sites of
bootstrap, ghost-scan, security-review and implement, and the file form at each flag site among
them: a Markdown field says Zensu renders headings, lists and code, a plain-text field says Zensu
does not render Markdown there. `FT6` fails on any Markdown file under `skills/` that spells the
retired fixed delimiter `ZENSU_TEXT_END`, writes a heredoc into a temporary file with a plain
`>` or checks it with the weaker `[ -s "$f" ] || exit 1`, and bites all three on a fixture.
`FT7` requires bootstrap's by-path plan form to run
`[ -f "$p" ] && grep -qI '[^[:space:]]' -- "$p" || exit 1` before `--content "$(cat "$p")"` and
to spell no `~/` path inside double quotes. The formats come from the Zensu web app, which renders
product, component, feature, sub-feature and journey descriptions and security findings and
conditions as Markdown, and renders no Markdown in the tier description, the journey step fields,
the revision scope fields or a ghost candidate's reject reason. A ghost candidate's description
shows unrendered on the scan's review page and rendered in the feature apply creates from it, so
the skill writes it as Markdown. `B52` and `B52b` in `tests/structure/test-bash-zensu-gate.sh` drive the
whole form through the CLI write-gate: it passes inside a window that declares its tool and
stays a denied mutation outside one.

Known gaps: a positional free-text argument and a placeholder with another name are not
judged; short titles (`--title "<title>"`), a journey's `--persona`, the wiki
`--change-summary` and the work-order `--rationale` stay double-quoted, so a backtick in them
still runs; nothing checks that a model picks a fresh delimiter, so one that types `<hex>`
literally or reuses an earlier value has a fixed delimiter again; the CLI write-gate's token scan
reads each heredoc line as a command
(`.claude/rules/subagent-shell-guard.md`), so a text line that opens with a `zensu` mutation the
window does not declare is denied; and the text still travels as one command-line argument, so
the operating system's argument-size limits apply exactly as they did inline. A zensu-cli flag
that reads stdin or a file would remove both the round trip and that limit; it is a CLI change.

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
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not checked.
