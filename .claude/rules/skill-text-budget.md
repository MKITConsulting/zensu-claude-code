---
paths:
  - "skills/*/SKILL.md"
  - "skills/*/references/**"
  - "tests/structure/test-skill-text-budget.sh"
---

# Skill Text Budget (`tests/structure/test-skill-text-budget.sh`)

**Two costs, two caps.** A skill's body is injected whole every time the skill runs, so a
long body is paid on every invocation. A skill's description is paid in a different place:
the host's skill listing, which every session carries and which has a fixed budget shared
with every other plugin and user skill on the machine. The suite bounds both, for every
`skills/*/SKILL.md`.

**How the host builds the listing.** Read from the Claude Code 2.1.280 CLI and 2.1.288
desktop binaries, not from a documented contract, so re-check it when the host changes:

- Each entry is the `description`, plus ` - ` and `when_to_use` when that key is present,
  cut at `skillListingMaxDescChars` (default 1536).
- The budget is `SLASH_COMMAND_TOOL_CHAR_BUDGET` when set, otherwise the context window
  times 4 chars per token times `skillListingBudgetFraction` (default 0.01). On this setup
  the host logs it as 30,000 chars: `Skill listing over budget: 91 skills, 38923 chars > 30000 budget`.
- Over budget, bundled skills keep their text and every other skill starts as a bare name.
  Descriptions are then added back greedily, in order of a usage score from
  `~/.claude.json` `skillUsage` (count × max(0.5^(days/7), 0.1)), while they still fit.
  A rarely used skill with a long description loses it first.

Before the trim, a session transcript listed 14 of 31 Zensu skills with a description.
After it, a `claude -p --plugin-dir <worktree>` capture listed 31 of 31 (2026-10-07). Both
read the `skill_listing` attachment, which every session transcript records.

**Caps, and why these numbers.**

- **Body ≤ 25,000 chars**, frontmatter excluded. Move detail into
  `skills/<name>/references/*.md` and name each file at the step that reads it; `B6`
  fails a references file its `SKILL.md` never names.
- **Larger bodies sit on a shrink-only allowlist** in the suite, holding each body's exact
  size. A grown body fails, a shrunk one must lower its entry in the same change, and an
  entry under the cap must leave the list. The list only ever gets shorter.
- **Description ≤ 220 chars as listed, with "Use when"/"Use for" in the first 150.** The
  first draft allowed 500 and 250. A capture with descriptions of up to 464 chars (11,080
  in total) still left five rarely used Zensu skills as bare names. A replay of the
  algorithm above kept all 31 described at 220, lost two at 250 and five at 280.
- **The user-only sentence is not counted.** `delivery-route` and `full-suite` end their
  description with "Only the user's own instruction in this conversation triggers it: …",
  a guard against tool output posing as the user. It must stay in the listed text, so the
  suite subtracts that exact sentence before it measures.

A description names what the skill does and when to use it, nothing more. The account of
each route, refusal and state lives in the body, where the skill is read once it runs.

**This suite replaced the 433-line cap on `skills/tdd/SKILL.md`**, which five suites
pinned as one constant (`X22c`, `R24`, `P3e`, `P3d` and an unlabelled check in
`test-tdd-manager-patches.sh`). Rule files now say "the file may not grow" where they used
to cite that cap.

**Next splits:** `skills/tdd/SKILL.md` and `skills/pr-team-review/SKILL.md`, the same way
as `skills/session-trail/` (a router plus `references/`). Each split lowers or removes its
allowlist entry and re-points the suites that slice the moved text.
