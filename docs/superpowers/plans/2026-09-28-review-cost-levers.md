# Review Cost Levers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the `/zensu:tdd` post-implementation cost and time by more than half at the new defaults, and fingerprint full-suite evidence on the work tree the suite actually ran in.

**Architecture:** Two pull requests in `zensu-claude-code`. PR A fixes the evidence fingerprint for nested worktrees and removes the skill text that makes vanilla fix rounds run the full suite. PR B changes the review chain defaults: one fix round, a failing-test requirement for CRITICAL findings of a re-review, and a lean three-perspective panel with the judge on the first review only. A measurement gate in the author's private benchmark kit decides whether PR B is released.

**Tech Stack:** Bash hooks, Node.js (CommonJS, `node:test`), Markdown skills and agent definitions, grep-based structure tests in `tests/structure/*.sh`.

**Spec:** `docs/superpowers/specs/2026-09-28-review-cost-levers-design.md` (copied in Task 0 from the session handoff).

## Global Constraints

- English only in code, docs, tests, commit messages and plan files (`CLAUDE.md` § Language).
- Add no code comments. An existing comment that states a changed default is corrected, not extended.
- Reviewer agents keep `model: inherit`. No model or effort change anywhere.
- No manual version bump in either PR. Release through Actions → Release: PR A as `patch`, PR B as `minor` (`CLAUDE.md` § Version Bumps).
- Never edit `hooks/`, `agents/`, `skills/`, `docs/`, `templates/` or `scripts/` while a suite runs (`CLAUDE.md` § Runtime Lineage).
- Conventional commits; no Claude attribution lines in commits or PR bodies.
- Before every push: `gh pr view <num> --json state,mergedAt`; abort on `MERGED` or `CLOSED` (`CLAUDE.md` § Pull Request Workflow).
- Run every command from the task's worktree root. Unit files: `node --test tests/structure/<name>.test.js`. Shell structure tests: `bash tests/structure/<name>.sh`. Full offline suite before each PR: `bash tests/run-all.sh`.
- PR B starts after PR A is merged: both edit the fix-round directive in `hooks/post-review-tdd-delegate.sh`.

---

## Task 0: Workspace and design documents

**Files:**
- Create: `docs/superpowers/specs/2026-09-28-review-cost-levers-design.md`
- Create: `docs/superpowers/plans/2026-09-28-review-cost-levers.md`

- [ ] **Step 1: Anchor the implementing session so it contains the worktree.** A session started in the repository's main checkout contains every `.claude/worktrees/*` below it, so the Zensu source-write gate allows commits there; a session anchored elsewhere may instead nest the worktree under its own anchor. A session whose anchor does not contain the worktree can edit but not commit.

- [ ] **Step 2: Create the PR A worktree**

```bash
git fetch origin
git worktree add .claude/worktrees/evidence-tree-root --no-track -b fix/evidence-tree-root origin/main
```

- [ ] **Step 3: Copy the design documents**

```bash
W=.claude/worktrees/evidence-tree-root
mkdir -p "$W/docs/superpowers/plans"
cp "$HANDOFF/2026-09-28-review-cost-levers-design.md" "$W/docs/superpowers/specs/"
cp "$HANDOFF/2026-09-28-review-cost-levers-plan.md" "$W/docs/superpowers/plans/2026-09-28-review-cost-levers.md"
```

- [ ] **Step 4: Commit**

```bash
cd .claude/worktrees/evidence-tree-root
git add docs/superpowers/specs/2026-09-28-review-cost-levers-design.md docs/superpowers/plans/2026-09-28-review-cost-levers.md
git commit -m "docs(review): add the review cost levers design and plan"
```

---

## PR A — `fix/evidence-tree-root`

> Rebased onto 0.23.0 before review. That release added full suites in CI (`deferred-ci`) and already
> re-worded the fix rounds of `skills/tdd/SKILL.md` and the vanilla fix discipline, so Task A2 shrank to the
> max-rounds close: one `CLOSE_SUITE_STEP` runs the full suite with `--if-stale` in a local chain and the
> affected suite in a CI chain. Task A1 also covers `scoped` runs, because a CI chain closes on them, and
> `decideCi` compares each record with the tree of its own directory. An `acceptance` run keeps the
> project-root fingerprint.

### Task A1: Fingerprint the work tree the suite ran in

> Superseded in part: the Interfaces bullets and the code blocks of Steps 3 to 5 show the first draft. The implemented design is the one in the two refinement notes below and in the spec's D5.

**Files:**
- Modify: `hooks/lib/evidence-run-v1.js` — add `fingerprintRoot` after `computeTree` (ends near line 377); `verdict` (lines 505–575); `run` (the `--if-stale` call near line 791, `treeStart` near line 811, `treeEnd` near line 899); `module.exports`
- Test: `tests/structure/evidence-run-v1.test.js`

**Interfaces:**
- Produces: `fingerprintRoot(cwd: string, projectRoot: string, limits?: object): string`, exported. Returns `git -C <cwd> rev-parse --show-toplevel` when that differs from the project root's own top level; otherwise `projectRoot`.
- Produces: `verdict(options)` accepts an optional `options.cwd: string`.
- Refined during implementation: `fingerprintRoot` leaves the project root only for a work tree nested strictly inside the project root's own work tree at a path `git check-ignore` reports as ignored, so a run from an unrelated clone, a submodule or an untracked nested repository keeps the project-root fingerprint. The `--if-stale` call passes the run's cwd as `options.runCwd` instead of `options.cwd`, because the verdict CLI's transport always fills `options.cwd` with the project root and would hide the newest record's cwd from the terminus. More unit tests (among them the verdict CLI on the nested layout and a run from an unrelated clone) and the end-to-end checks F16 and F17 in `tests/structure/test-full-suite-gate.sh` pin both.
- Refined after review: the a3 runs started the runner at the project root with `cd <worktree>/<dir> && …` in `--cmd`, so following only the cwd would not have fixed them. `commandDirectory` now reads a leading literal `cd` from the command, `fingerprintRoot` drops the `git check-ignore` condition, and a run in a nested work tree is fingerprinted by `computeFingerprint` as a combined `git mktree --missing` tree of the project and that work tree, so an edit to the project root after a worktree run also reads stale. `fingerprintChanges` lists nested paths with their location. Unit tests for the leading `cd`, the combined tree, a project edit after a worktree run, `runCwd` and a mutating suite in the worktree, plus the end-to-end checks F18 and F19, pin it.

- [ ] **Step 1: Add the helper and four failing tests** at the end of `tests/structure/evidence-run-v1.test.js`

```js
function nestedWorktree(root) {
  fs.writeFileSync(path.join(root, '.gitignore'), '.claude/worktrees/\n');
  sh(root, 'git add .gitignore && git commit -q -m ignore-worktrees');
  sh(root, 'git worktree add -q .claude/worktrees/wt -b wt');
  return fs.realpathSync(path.join(root, '.claude', 'worktrees', 'wt'));
}

test('a full run in a nested ignored worktree fingerprints that worktree', async () => {
  const root = gitRepo();
  const tree = nestedWorktree(root);
  const data = pluginData();
  await runIn(root, data, { cwd: tree, command: 'true' });
  fs.writeFileSync(path.join(tree, 'a.txt'), 'edited in the worktree\n');
  await runIn(root, data, { cwd: tree, command: 'true' });
  const [first, second] = recordsOf(data);
  const scratch = tempDir('scratch');
  assert.notEqual(first.tree_end, second.tree_end);
  assert.equal(second.tree_end, evr.computeTree(tree, scratch).tree);
  assert.notEqual(second.tree_end, evr.computeTree(root, scratch).tree);
});

test('the terminus reads stale after an edit in the nested worktree', async () => {
  const root = gitRepo();
  const tree = nestedWorktree(root);
  const data = pluginData();
  await runIn(root, data, { cwd: tree, command: 'true' });
  assert.equal(verdictFor(root, data).state, 'pass');
  fs.writeFileSync(path.join(tree, 'a.txt'), 'edited after the run\n');
  const result = verdictFor(root, data);
  assert.equal(result.state, 'stale');
  assert.match(result.lines[0], /files changed since: a\.txt/);
});

test('if-stale runs again after an edit in the nested worktree', async () => {
  const root = gitRepo();
  const tree = nestedWorktree(root);
  const data = pluginData();
  await runIn(root, data, { cwd: tree, command: 'true' });
  const skipped = await runIn(root, data, { cwd: tree, command: 'true', ifStale: true });
  assert.match(skipped.stdout, /skipped \(--if-stale\)/);
  fs.writeFileSync(path.join(tree, 'a.txt'), 'edit\n');
  await runIn(root, data, { cwd: tree, command: 'true', ifStale: true });
  assert.equal(recordsOf(data).length, 2);
});

test('a record fingerprinted at the project root reads stale for an edited nested worktree', () => {
  const root = gitRepo();
  const tree = nestedWorktree(root);
  const data = pluginData();
  const scratch = tempDir('scratch');
  const projectTree = evr.computeTree(root, scratch).tree;
  const locations = evr.storeLocations(data, SESSION);
  evr.writeRecordAtomic(locations.records, baseRecord({ project_root: root, cwd: tree, tree_start: projectTree, tree_end: projectTree }));
  fs.writeFileSync(path.join(tree, 'a.txt'), 'edited in the worktree\n');
  assert.equal(verdictFor(root, data).state, 'stale');
});
```

- [ ] **Step 2: Run them and confirm all four fail**

Run: `node --test tests/structure/evidence-run-v1.test.js`
Expected: the four new tests FAIL (the first on `notEqual`, the next two because the verdict still reads the project root and returns `pass` or skips, the last with `pass` instead of `stale`); every existing test passes.

- [ ] **Step 3: Add `fingerprintRoot`** directly after `computeTree` in `hooks/lib/evidence-run-v1.js`

```js
function fingerprintRoot(cwd, projectRoot, limits = LIMITS) {
  if (typeof cwd !== 'string' || cwd === '' || cwd === projectRoot) return projectRoot;
  const own = git(projectRoot, ['rev-parse', '--show-toplevel'], { timeoutMs: limits.gitTimeoutMs });
  const other = git(cwd, ['rev-parse', '--show-toplevel'], { timeoutMs: limits.gitTimeoutMs });
  if (!own.ok || !other.ok) return projectRoot;
  const ownTop = own.stdout.trim();
  const otherTop = other.stdout.trim();
  return otherTop !== '' && otherTop !== ownTop ? otherTop : projectRoot;
}

function newestFullCwd(entries) {
  const full = entries.filter((entry) => entry.record && entry.record.scope === 'full');
  return full.length > 0 ? full[full.length - 1].record.cwd : null;
}
```

- [ ] **Step 4: Use it in `run`.** After `const projectRoot = options.projectRoot;` add

```js
    const treeRoot = fingerprintRoot(options.cwd || projectRoot, projectRoot, limits);
```

In the `--if-stale` `verdict({ … })` call add the property `cwd: options.cwd || projectRoot,`. In the `treeStart` and `treeEnd` lines replace `computeTree(projectRoot, locations.scratch, limits)` with `computeTree(treeRoot, locations.scratch, limits)`. The record keeps `project_root: projectRoot` and `cwd: options.cwd || projectRoot` unchanged.

- [ ] **Step 5: Use it in `verdict`.** Declare `let treeRoot = projectRoot;` next to `let currentTree`. Inside the `try`, replace

```js
      currentTree = computeTree(projectRoot, locations.scratch, limits);
```

with

```js
      treeRoot = fingerprintRoot(options.cwd || newestFullCwd(entries) || projectRoot, projectRoot, limits);
      currentTree = computeTree(treeRoot, locations.scratch, limits);
```

In the `stale` and `mutated-during-run` cases replace `changedPaths(projectRoot, …)` with `changedPaths(treeRoot, …)`. Add `fingerprintRoot` to `module.exports` next to `computeTree`.

- [ ] **Step 6: Run the file and confirm everything passes**

Run: `node --test tests/structure/evidence-run-v1.test.js`
Expected: all tests PASS, including `a nested project root fingerprints its own subtree`.

- [ ] **Step 7: Run the dependent shell suites**

Run: `bash tests/structure/test-evidence-run.sh && bash tests/structure/test-full-suite-gate.sh`
Expected: both end with `0 FAIL`.

- [ ] **Step 8: Commit**

```bash
git add hooks/lib/evidence-run-v1.js tests/structure/evidence-run-v1.test.js
git commit -m "fix(evidence-run): fingerprint the work tree the suite ran in"
```

### Task A2: One full suite per chain, stated consistently

> Superseded in part: the gates.md sentence of Step 5 is the first draft; `docs/gates.md` carries the implemented "Which tree." bullet.

**Files:**
- Modify: `skills/tdd/SKILL.md:203`
- Modify: `hooks/post-review-tdd-delegate.sh` (both `MSG=` variants, lines 468 and 470)
- Modify: `docs/gates.md` (§ Full-Suite Gate, one sentence on the fingerprint root)
- Test: `tests/structure/test-full-suite-gate.sh`
- Refined during implementation: the vanilla `FIX_DISCIPLINE_ALL` of `hooks/post-review-tdd-delegate.sh` also told every routed fix round to run the full suite; it now names the round's own scoped suites, pinned by `FS-A5` and `FS-A6`.

- [ ] **Step 1: Add failing checks** before the `finish` call of `tests/structure/test-full-suite-gate.sh`, reusing that file's `check` helper and its path variables (define `TDD_MD="$ROOT/skills/tdd/SKILL.md"`, `DELEGATE="$ROOT/hooks/post-review-tdd-delegate.sh"` and `GATES_DOC="$ROOT/docs/gates.md"` if the file lacks them)

```bash
check "FS-A1 vanilla fix rounds no longer run the full suite" "$(grep -qF 'keep logging CHECKPOINT lines and running the full suite through the evidence runner' "$TDD_MD" && echo FAIL || echo PASS)"
check "FS-A2 vanilla fix rounds re-run their own scoped suites" "$(grep -qF 're-run only the round'"'"'s own scoped suites through the evidence runner' "$TDD_MD" && echo PASS || echo FAIL)"
check "FS-A3 both fix-round directives state the one-full-suite rule" "$([ "$(grep -cF 'In this fix round re-run only its own scoped suites; the full suite runs once at convergence with --if-stale' "$DELEGATE")" -eq 2 ] && echo PASS || echo FAIL)"
check "FS-A4 the gate doc names the fingerprint root" "$(grep -qF 'fingerprints the work tree that contains the run'"'"'s cwd' "$GATES_DOC" && echo PASS || echo FAIL)"
```

- [ ] **Step 2: Run and confirm the four checks fail**

Run: `bash tests/structure/test-full-suite-gate.sh`
Expected: `FS-A1` … `FS-A4` FAIL, every earlier check PASS.

- [ ] **Step 3: Edit `skills/tdd/SKILL.md:203`.** Replace

```text
keep logging CHECKPOINT lines and running the full suite through the evidence runner
```

with

```text
keep logging CHECKPOINT lines, re-run only the round's own scoped suites through the evidence runner, and leave the full suite to the convergence branch (`--if-stale`) and the self-review fix round
```

- [ ] **Step 4: Edit both directives.** In each `MSG=` string of `hooks/post-review-tdd-delegate.sh`, directly after `Do NOT spawn a tdd subagent — TDD now runs in this main thread.`, insert ` In this fix round re-run only its own scoped suites; the full suite runs once at convergence with --if-stale and again only in the self-review fix round.`

- [ ] **Step 5: Edit `docs/gates.md` § Full-Suite Gate.** Add the sentence: `The runner fingerprints the work tree that contains the run's cwd when it is a different work tree than the project root's, so a suite run in a nested, ignored worktree is bound to that worktree; otherwise it fingerprints the project root as before.`

- [ ] **Step 6: Run and confirm everything passes**

Run: `bash tests/structure/test-full-suite-gate.sh && bash tests/structure/test-tdd-skill-review-fanout.sh`
Expected: both end with `0 FAIL`.

- [ ] **Step 7: Commit, run the full suite, open PR A**

```bash
git add skills/tdd/SKILL.md hooks/post-review-tdd-delegate.sh docs/gates.md tests/structure/test-full-suite-gate.sh
git commit -m "fix(tdd): run the full suite once per chain in vanilla fix rounds too"
bash tests/run-all.sh
```

Write the PR body from `templates/pr-body.md` into `/tmp/pr-a-body.md`, with one Acceptance Criteria row per bullet of spec § D5, then:

```bash
gh pr view fix/evidence-tree-root --json state 2>/dev/null
git push -u origin fix/evidence-tree-root
gh pr create --base main --title "fix: bind full-suite evidence to the nested work tree it measured and run the full suite once per chain" --body-file /tmp/pr-a-body.md
```

After merge, release as `patch`.

---

## PR B — `feat/lean-review-loop` (after PR A is merged)

- [ ] **Setup:** `git fetch origin && git worktree add .claude/worktrees/lean-review-loop --no-track -b feat/lean-review-loop origin/main`, then work inside it.

### Task B1: One fix round by default

**Files:**
- Modify: `hooks/lib/zensu-config.sh:517`, `hooks/post-review-tdd-delegate.sh:11` (existing comment's default), `config.example.json:10`, `docs/configuration.md:58`, `docs/tdd-manager-workflow.md:99` and `:442`, `skills/setup/SKILL.md:114`
- Modify: `tests/structure/test-stop-enforcer-self-review-routing.sh`, `tests/structure/test-stop-enforcer-escapes.sh`, `tests/structure/test-smoke-main-thread-chain.sh` (they assume the old default of 5)
- Test: `tests/structure/test-review-convergence.sh`

- [ ] **Step 1: Add failing checks** before `finish` in `tests/structure/test-review-convergence.sh`

```bash
check "LC1 the default auto-fix budget is one fix round" "$(grep_ok "$ROOT/hooks/lib/zensu-config.sh" '_zensu_config_bounded_int autoFixMaxRounds 1 1 99')"
check "LC1b configuration.md documents the default of one fix round" "$(grep_ok "$CONFIG_DOC" 'Integer loop guard (default `1`')"
check "LC1c config.example.json ships one fix round" "$(node -e 'process.stdout.write(require(process.argv[1]).hooks.autoFixMaxRounds===1?"PASS":"FAIL")' "$CONFIG_EX")"
```

- [ ] **Step 2: Run and confirm LC1, LC1b and LC1c fail**

Run: `bash tests/structure/test-review-convergence.sh`

- [ ] **Step 3: Change the default.** `hooks/lib/zensu-config.sh:517` becomes

```bash
zensu_autofix_max_rounds()        { _zensu_config_bounded_int autoFixMaxRounds 1 1 99; }
```

Set `"autoFixMaxRounds": 1` in `config.example.json`. In `docs/configuration.md:58` change `default \`5\`` to `default \`1\``, and add: `One fix round is followed by one verification review and the self-review stage; set 5 for the pre-0.23 loop.` In `docs/tdd-manager-workflow.md` change `max 5 rounds` (line 99) to `max 1 round by default` and `runs up to 5 rounds` (line 442) to `runs one fix round by default`. In `hooks/post-review-tdd-delegate.sh:11` change `(default 5)` to `(default 1)`. In `skills/setup/SKILL.md:114` change the presets `3` / `5` / `8` to `1` / `2` / `5`.

- [ ] **Step 4: Pin the three default-dependent suites to 5.** Each of them writes or points at a Zensu config; make that config contain `{"hooks":{"autoFixMaxRounds":5}}` the way `tests/structure/test-reset-review-limit-transaction.sh:26` does, and correct their comments that say the default is 5. Their assertions then stay unchanged.

- [ ] **Step 5: Run and confirm everything passes**

Run: `bash tests/structure/test-review-convergence.sh && bash tests/structure/test-stop-enforcer-self-review-routing.sh && bash tests/structure/test-stop-enforcer-escapes.sh && bash tests/structure/test-smoke-main-thread-chain.sh && bash tests/structure/test-setup-skill.sh && bash tests/structure/test-autopilot-post-review-max-rounds.sh`
Expected: all end with `0 FAIL`.

- [ ] **Step 6: Commit**

```bash
git add hooks/lib/zensu-config.sh hooks/post-review-tdd-delegate.sh config.example.json docs/configuration.md docs/tdd-manager-workflow.md skills/setup/SKILL.md tests/structure
git commit -m "feat(review): default the auto-fix loop to one fix round"
```

### Task B2: A re-review CRITICAL routes only when a failing test reproduces it

**Files:**
- Modify: `hooks/post-review-tdd-delegate.sh` (flag near line 335, `CONVERGENCE_CLAUSE` near line 367, the max-rounds `CONV_MSG`)
- Modify: `skills/tdd/SKILL.md:423` (step 4c), `skills/self-review/SKILL.md`, `docs/review-severity.md` (prose above the rubric block), `docs/configuration.md` (new row), `config.example.json`
- Test: `tests/structure/test-review-convergence.sh`

**Interfaces:**
- Produces: config key `hooks.criticalReproduction` (boolean, default `true`, read with `zensu_hook_enabled`).
- Produces: run-log line `FINDING REPRODUCTION — <ledger-id> <REPRODUCED|NOT-REPRODUCED|NOT-TESTABLE> <record id or one-line reason>`.

- [ ] **Step 1: Add failing checks** before `finish` in `tests/structure/test-review-convergence.sh`

```bash
check "LC2 the delegate reads hooks.criticalReproduction" "$(grep_ok "$DELEGATE" 'zensu_hook_enabled criticalReproduction')"
check "LC2b the convergence clause requires a reproduction for a re-review CRITICAL" "$(grep_ok "$DELEGATE" 'routes only after /zensu:tdd step 4c stage 3 reproduced it')"
check "LC2c step 4c carries stage 3" "$(grep_ok "$TDD_MD" '**Stage 3 (reproduction, re-reviews only, config-gated).**')"
check "LC2d the log line is named" "$(grep_ok "$TDD_MD" 'FINDING REPRODUCTION — <ledger-id> <REPRODUCED|NOT-REPRODUCED|NOT-TESTABLE>')"
check "LC2e self-review fixes only reproduced re-review CRITICALs" "$(grep_ok "$SELF_REVIEW_MD" 'CRITICAL finding from a re-review is a must-fix only when its FINDING REPRODUCTION line reads REPRODUCED')"
check "LC2f the rubric doc states the rule" "$(grep_ok "$RUBRIC_DOC" 'a CRITICAL finding of a re-review routes only when a failing test reproduces it')"
check "LC2g configuration.md documents criticalReproduction" "$(grep_ok "$CONFIG_DOC" '| `criticalReproduction` |')"
check "LC2h config.example.json ships criticalReproduction" "$(node -e 'process.stdout.write(require(process.argv[1]).hooks.criticalReproduction===true?"PASS":"FAIL")' "$CONFIG_EX")"
```

- [ ] **Step 2: Run and confirm LC2 … LC2h fail**

Run: `bash tests/structure/test-review-convergence.sh`

- [ ] **Step 3: Delegate.** After `if zensu_hook_enabled reviewConvergence; then CONVERGENCE_ON=1; fi` add

```bash
REPRODUCTION_ON=0
if zensu_hook_enabled criticalReproduction; then REPRODUCTION_ON=1; fi
REPRODUCTION_RULE=""
if [ "$REPRODUCTION_ON" = "1" ]; then
  REPRODUCTION_RULE=" A CRITICAL finding of that re-review routes only after /zensu:tdd step 4c stage 3 reproduced it with a failing test run through the evidence runner with --scope scoped and logged 'FINDING REPRODUCTION — <ledger-id> REPRODUCED <record>'; a NOT-REPRODUCED one is downgraded to IMPORTANT and deferred, and a NOT-TESTABLE one keeps CRITICAL and is deferred to ## Open for a human."
fi
```

Interpolate `${REPRODUCTION_RULE}` in `CONVERGENCE_CLAUSE` directly after the interpolation of `IMPORTANT_RULE`. In the max-rounds `CONV_MSG`, when `REPRODUCTION_ON` is `1`, append ` A CRITICAL finding from a re-review is a self-review must-fix only when its FINDING REPRODUCTION line reads REPRODUCED.`

- [ ] **Step 4: Step 4c of `skills/tdd/SKILL.md`.** Directly before the sentence that begins `Log \`FINDING VERIFICATION —`, insert

```markdown
**Stage 3 (reproduction, re-reviews only, config-gated).** Resolve the flag the same way with `zensu_hook_enabled criticalReproduction`. On `on` (the default), and only when this review is a re-review (the post-review directive named a fix round), reproduce every CRITICAL finding that Stage 2 graded `VERIFIED` before it may route: write or extend a test that exercises the cited behavior and must fail on the current tree, run it with `CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --evidence-run --scope scoped --cmd '<that test>' --log {log_file}`, and log `FINDING REPRODUCTION — <ledger-id> <REPRODUCED|NOT-REPRODUCED|NOT-TESTABLE> <record id or one-line reason>` through the heredoc form the ledger lines use. `REPRODUCED` — the run failed for the cited reason: the finding routes, and the test stays as its regression test. `NOT-REPRODUCED` — the run passed: retitle the finding `[Not reproduced — do not fix]`, set it to IMPORTANT, defer it, list it under `## Open` as `CRITICAL (not reproduced)`, and keep the test only when it asserts behavior the spec requires. `NOT-TESTABLE` — no test can express it, for example a secret written to a log: keep CRITICAL, defer it, and list it under `## Open` with the one-line reason for a human. Never delete a finding here. Flag disabled → re-review CRITICAL findings route as before.
```

- [ ] **Step 5: `skills/self-review/SKILL.md`.** In the paragraph that decides whether a must-fix surfaces, add: `A CRITICAL finding from a re-review is a must-fix only when its FINDING REPRODUCTION line reads REPRODUCED; NOT-REPRODUCED and NOT-TESTABLE findings go to ## Open.`

- [ ] **Step 6: `docs/review-severity.md`.** In the prose paragraph that begins `The scale decides what the auto-fix loop routes.` (above the delimited rubric block, which stays unchanged), add: `While hooks.criticalReproduction is enabled (the default), a CRITICAL finding of a re-review routes only when a failing test reproduces it; see /zensu:tdd step 4c stage 3.`

- [ ] **Step 7: Config docs.** Add to the hooks table of `docs/configuration.md`:

```markdown
| `criticalReproduction` | `post-review-tdd-delegate.sh` convergence clause · `/zensu:tdd` step 4c stage 3 · `/zensu:self-review` | When `false`, a CRITICAL finding of a re-review routes as soon as the Finding Verification Gate grades it `VERIFIED`. While enabled (the default), it routes only after the main thread reproduces it with a failing test run through the evidence runner (`FINDING REPRODUCTION — … REPRODUCED`); a `NOT-REPRODUCED` finding is downgraded to IMPORTANT and deferred, and a `NOT-TESTABLE` one stays CRITICAL and is deferred to `## Open`. The first review is unaffected. |
```

Add `"criticalReproduction": true` to the `hooks` object of `config.example.json`.

- [ ] **Step 8: Run and confirm everything passes**

Run: `bash tests/structure/test-review-convergence.sh && bash tests/structure/test-self-review-skill.sh && bash tests/structure/test-post-review-self-review-handoff.sh`
Expected: all end with `0 FAIL`.

- [ ] **Step 9: Commit**

```bash
git add hooks/post-review-tdd-delegate.sh skills/tdd/SKILL.md skills/self-review/SKILL.md docs/review-severity.md docs/configuration.md config.example.json tests/structure/test-review-convergence.sh
git commit -m "feat(review): route a re-review CRITICAL only when a failing test reproduces it"
```

### Task B3: Lean panel in the activation library

**Files:**
- Modify: `hooks/lib/aspect-activation-v1.js` (constants near line 53, `activate`, `cliMain`, the CLI block, `module.exports`)
- Test: `tests/structure/aspect-activation-v1.test.js`

**Interfaces:**
- Produces: `LEAN_ASPECTS = ["correctness", "design", "security"]`, `PANELS = ["lean", "full"]`, `ROUNDS = ["first", "re"]`, all exported.
- Produces: `activate(files: string[], options?: { panel?: "lean"|"full", round?: "first"|"re" })` → `{ kind, panel, round, verdicts }`; defaults `lean` / `first`.
- Produces: `cliMain(stdinText: string, argv?: string[])`; CLI flags `--panel lean|full` and `--round first|re`. Output format unchanged (`spawn <aspect>`, `skip <aspect> <reason>`, `summary …`).

- [ ] **Step 1: Point the existing tests at the full panel.** Replace the `spawned` helper with

```js
function spawned(files, options = { panel: 'full' }) {
  return activation
    .activate(files, options)
    .verdicts.filter((v) => v.spawn)
    .map((v) => v.aspect)
    .sort();
}
```

Every other existing `activation.activate(files)` call gets `{ panel: 'full' }` as its second argument.

- [ ] **Step 2: Add failing tests** at the end of the file

```js
test('the lean panel is correctness, design and security', () => {
  assert.deepEqual([...activation.LEAN_ASPECTS], ['correctness', 'design', 'security']);
});

test('the default panel is lean and the default round is first', () => {
  assert.deepEqual(spawned(['src/a.ts'], {}), ['correctness', 'design', 'security']);
});

test('a lean first review of documentation only skips security', () => {
  assert.deepEqual(spawned(['README.md'], { panel: 'lean', round: 'first' }), ['correctness', 'design']);
});

test('a lean re-review spawns correctness only', () => {
  const report = activation.activate(['src/a.ts'], { panel: 'lean', round: 're' });
  assert.deepEqual(report.verdicts.filter((v) => v.spawn).map((v) => v.aspect), ['correctness']);
  assert.deepEqual(report.verdicts.filter((v) => !v.spawn).map((v) => v.reason), ['re-review-lean-panel', 're-review-lean-panel']);
});

test('lean activation fails open to the whole first-review panel', () => {
  assert.deepEqual(spawned([], { panel: 'lean', round: 'first' }), ['correctness', 'design', 'security']);
});

test('the CLI reads --panel and --round', () => {
  const out = activation.cliMain('src/a.ts\n', ['--panel', 'lean', '--round', 're']);
  assert.match(out, /^spawn correctness$/m);
  assert.match(out, /^skip design re-review-lean-panel$/m);
});
```

- [ ] **Step 3: Run and confirm the new tests fail**

Run: `node --test tests/structure/aspect-activation-v1.test.js`
Expected: the six new tests FAIL; the adapted existing tests PASS.

- [ ] **Step 4: Implement.** Below `const ASPECTS = …` add

```js
const LEAN_ASPECTS = ["correctness", "design", "security"];
const PANELS = ["lean", "full"];
const ROUNDS = ["first", "re"];
```

Replace `activate` with

```js
function activate(files, options = {}) {
  const panel = PANELS.includes(options.panel) ? options.panel : "lean";
  const round = ROUNDS.includes(options.round) ? options.round : "first";
  const { kind } = classify(files);
  const docsOnly = kind === "docs-only";
  if (panel === "lean") {
    const verdicts = LEAN_ASPECTS.map((aspect) => {
      if (aspect === "correctness") return { aspect, spawn: true, reason: "" };
      if (round === "re") return { aspect, spawn: false, reason: "re-review-lean-panel" };
      if (aspect === "security" && docsOnly) return { aspect, spawn: false, reason: "documentation-only-changeset" };
      return { aspect, spawn: true, reason: "" };
    });
    return { kind, panel, round, verdicts };
  }
  const noProductionCode = docsOnly || kind === "tests-only" || kind === "docs-and-tests";
  const verdicts = ASPECTS.map((aspect) => {
    if (aspect === "conventions" || aspect === "bugs") {
      return { aspect, spawn: true, reason: "" };
    }
    if (aspect === "tests" || aspect === "security") {
      return docsOnly
        ? { aspect, spawn: false, reason: "documentation-only-changeset" }
        : { aspect, spawn: true, reason: "" };
    }
    return noProductionCode
      ? { aspect, spawn: false, reason: "no-production-code-in-changeset" }
      : { aspect, spawn: true, reason: "" };
  });
  return { kind, panel, round, verdicts };
}
```

Replace `cliMain` with

```js
function optionsFrom(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--panel") options.panel = argv[index + 1];
    if (argv[index] === "--round") options.round = argv[index + 1];
  }
  return options;
}

function cliMain(stdinText, argv = []) {
  const text = String(stdinText == null ? "" : stdinText);
  return render(activate(text.split("\n"), optionsFrom(argv)));
}
```

In the `require.main === module` block change `cliMain(over ? "" : buf)` to `cliMain(over ? "" : buf, process.argv.slice(2))`. Add `LEAN_ASPECTS`, `PANELS` and `ROUNDS` to `module.exports`.

- [ ] **Step 5: Run and confirm everything passes**

Run: `node --test tests/structure/aspect-activation-v1.test.js`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add hooks/lib/aspect-activation-v1.js tests/structure/aspect-activation-v1.test.js
git commit -m "feat(review): add the lean three-perspective panel to aspect activation"
```

### Task B4: Wire the lean panel into the chain

**Files:**
- Modify: `hooks/lib/zensu-config.sh` (new getter after `zensu_autofix_include_suggestions`)
- Modify: `agents/review-aspect.md:24` and `:45-49`, `agents/code-reviewer.md:59`
- Modify: `skills/tdd/SKILL.md:420` (step 3), `:421` (step 4), `:422` (step 4b)
- Modify: `hooks/post-review-tdd-delegate.sh` (both `MSG=` variants: the re-review fan-out and judge sentences)
- Modify: `docs/configuration.md` (rows `aspectActivation`, `reviewJudge`, new `reviewPanel`), `docs/review-chain.md:11-13` and `:81-83`, `docs/architecture.md:171-176`, `config.example.json`
- Test: `tests/structure/test-review-aspect-agent.sh`, `test-tdd-skill-review-fanout.sh`, `test-review-judge.sh`, `test-incremental-review-rounds.sh`, `test-review-convergence.sh`

**Interfaces:**
- Consumes: `activate` / CLI flags from Task B3.
- Produces: `zensu_review_panel` — prints `lean` (default, also on any unreadable config) or `full`.
- Produces: config key `hooks.reviewPanel` (`"lean"` | `"full"`).

- [ ] **Step 1: Add failing checks** before `finish` in `tests/structure/test-review-convergence.sh`

```bash
check "LC3 the panel getter exists and defaults to lean" "$(bash -c 'source "$1/hooks/lib/zensu-config.sh"; ZENSU_CONFIG=/nonexistent zensu_review_panel' _ "$ROOT" | grep -qx lean && echo PASS || echo FAIL)"
LC3_CFG="$(mktemp)"
printf '%s\n' '{"hooks":{"reviewPanel":"full"}}' > "$LC3_CFG"
check "LC3a the panel getter reads full" "$(bash -c 'source "$1/hooks/lib/zensu-config.sh"; ZENSU_CONFIG="$2" zensu_review_panel' _ "$ROOT" "$LC3_CFG" | grep -qx full && echo PASS || echo FAIL)"
rm -f "$LC3_CFG"
check "LC3b step 3 resolves the panel" "$(grep_ok "$TDD_MD" 'aspect-activation-v1.js" --panel <panel> --round first')"
check "LC3c the fix-round directive re-reviews with the round flag" "$([ "$(grep -cF 'aspect-activation-v1.js --panel ${PANEL} --round re' "$DELEGATE")" -eq 2 ] && echo PASS || echo FAIL)"
check "LC3d the judge re-runs only on the full panel" "$([ "$(grep -cF 're-run the zensu:review-judge second pass only when hooks.reviewJudge is enabled and hooks.reviewPanel is full' "$DELEGATE")" -eq 2 ] && echo PASS || echo FAIL)"
check "LC3e step 4b skips the judge on a lean re-review" "$(grep_ok "$TDD_MD" 'On a re-review with the lean panel, skip this step')"
check "LC3f the aspect agent knows correctness" "$(grep_ok "$ASPECT_MD" '   - correctness: control flow, boundaries, null/error paths, races, resource handling, plus test-source assertions')"
check "LC3g the aspect agent knows design" "$(grep_ok "$ASPECT_MD" '   - design: dependency direction, layering, module boundaries, integration contracts, plus repository guidance')"
check "LC3h configuration.md documents reviewPanel" "$(grep_ok "$CONFIG_DOC" '| `reviewPanel` |')"
check "LC3i config.example.json ships the lean panel" "$(node -e 'process.stdout.write(require(process.argv[1]).hooks.reviewPanel==="lean"?"PASS":"FAIL")' "$CONFIG_EX")"
```

`ZENSU_CONFIG` is the full-override config path `hooks/lib/zensu-config.sh` documents (lines 7–10); a missing file reads as an empty config.

- [ ] **Step 2: Run and confirm LC3 … LC3i fail**

Run: `bash tests/structure/test-review-convergence.sh`

- [ ] **Step 3: Config getter** in `hooks/lib/zensu-config.sh`, after `zensu_autofix_include_suggestions`

```bash
zensu_review_panel() {
  command -v node >/dev/null 2>&1 || { printf 'lean'; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var p=j.hooks&&j.hooks.reviewPanel;process.stdout.write(p==="full"?"full":"lean")' 2>/dev/null)
  [ -z "$val" ] && val="lean"
  printf '%s' "$val"
}
```

- [ ] **Step 4: Agent definitions.** In `agents/review-aspect.md:24` extend the list to `` `correctness`, `design`, `conventions`, `bugs`, `architecture`, `tests`, or `security` ``. Above the existing five focus lines (45–49) add

```markdown
   - correctness: control flow, boundaries, null/error paths, races, resource handling, plus test-source assertions and coverage and consistency with supplied evidence
   - design: dependency direction, layering, module boundaries, integration contracts, plus repository guidance, i18n, registration and file/layout conventions — never formatting or lint-level style, which the lint evidence run covers
```

In `agents/code-reviewer.md:59` replace `Do not re-run the five perspectives` with `Do not re-run the panel's perspectives`. Leave the standalone five-perspective walk (line 24) unchanged.

- [ ] **Step 5: Skill step 3 (`skills/tdd/SKILL.md:420`).** Replace

```text
FIVE `zensu:review-aspect` agents — one per perspective: `conventions`, `bugs`, `architecture`, `tests`, `security` — but when `hooks.aspectActivation` is enabled (the default) pipe THIS packet's `changed_files` (one path per line) into `node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/aspect-activation-v1.js"` first and spawn only the perspectives it answers `spawn`. It skips at most `architecture` on a change set carrying no production code and `tests`/`security` on a documentation-only one, and fails OPEN to all five on empty or unclassifiable input
```

with

```text
one `zensu:review-aspect` agent per perspective of the panel that `bash -c 'source "$1/hooks/lib/zensu-config.sh"; zensu_review_panel' _ "${CLAUDE_PLUGIN_ROOT}"` prints — `lean` (the default): `correctness`, `design`, `security`; `full`: `conventions`, `bugs`, `architecture`, `tests`, `security` — and when `hooks.aspectActivation` is enabled (the default) pipe THIS packet's `changed_files` (one path per line) into `node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/aspect-activation-v1.js" --panel <panel> --round first` first and spawn only the perspectives it answers `spawn`. The lean panel skips `security` on a documentation-only change set; the full panel skips at most `architecture` on a change set carrying no production code and `tests`/`security` on a documentation-only one; both fail OPEN to the whole panel on empty or unclassifiable input
```

In the same paragraph replace the words "and spawn all five — PLUS" with "and spawn the whole panel — PLUS". In step 4 (line 421) replace the words "Collect the five" with "Collect every" and "findings lists" with "findings list". At the start of step 4b (line 422), directly after its bold title, insert the sentence "On a re-review with the lean panel, skip this step: the judge reviews the first review only."

- [ ] **Step 6: Delegate directives.** Add `PANEL="$(zensu_review_panel)"` next to the other flag reads (near line 335). Both `MSG=` values are double-quoted Bash strings, so the inserted text carries no double quote. In both, replace the parenthetical `five perspectives, fewer when hooks.aspectActivation skips one` with `the perspectives hooks/lib/aspect-activation-v1.js --panel ${PANEL} --round re answers spawn for this round's changed_files`, and replace `re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled` with `re-run the zensu:review-judge second pass only when hooks.reviewJudge is enabled and hooks.reviewPanel is full`. The existing directive already names `hooks/lib/review-round-scope-v1.js` by that relative path, so the new path follows the same form.

- [ ] **Step 7: Docs and example config.** Add to `docs/configuration.md`:

```markdown
| `reviewPanel` | `/zensu:tdd` step 3 fan-out · `post-review-tdd-delegate.sh` fix-round directive | `lean` (the default) spawns three built-in perspectives on the first review — `correctness` (bugs and tests), `design` (architecture and repository conventions, never lint-level style) and `security` — with the judge, and re-reviews each fix round's delta with `correctness` only and no judge. `full` restores the five perspectives `conventions`, `bugs`, `architecture`, `tests`, `security` and a judge on every review. Any other value reads as `lean`. |
```

In the `aspectActivation` row add: `On the lean panel it skips only security, on a documentation-only change set.` In the `reviewJudge` row add: `On the lean panel the judge runs on the first review only.` Update `docs/review-chain.md:11-13` and `:81-83` and `docs/architecture.md:171-176` wherever they state that every round spawns five aspects, so they name the lean default and `reviewPanel: full`. Add `"reviewPanel": "lean"` to the `hooks` object of `config.example.json`.

- [ ] **Step 8: Update the text pins.** Run the four suites below; every failing check pins old wording. Change its literal to the new wording from Steps 4–6, and keep checks that guard behavior (fail-open, skip logging, persona handling) intact.

Run: `bash tests/structure/test-tdd-skill-review-fanout.sh; bash tests/structure/test-review-judge.sh; bash tests/structure/test-incremental-review-rounds.sh; bash tests/structure/test-review-aspect-agent.sh`

- [ ] **Step 9: Run and confirm everything passes**

Run: `bash tests/structure/test-review-convergence.sh && bash tests/structure/test-tdd-skill-review-fanout.sh && bash tests/structure/test-review-judge.sh && bash tests/structure/test-incremental-review-rounds.sh && bash tests/structure/test-review-aspect-agent.sh && node --test tests/structure/aspect-activation-v1.test.js`
Expected: all end with `0 FAIL` or all tests PASS.

- [ ] **Step 10: Commit**

```bash
git add hooks/lib/zensu-config.sh agents skills/tdd/SKILL.md hooks/post-review-tdd-delegate.sh docs config.example.json tests/structure
git commit -m "feat(review): make the lean panel the default and judge the first review only"
```

### Task B5: Full suite and PR B

- [ ] **Step 1:** `bash tests/run-all.sh` — expected: no failures.
- [ ] **Step 2:** Write the PR body from `templates/pr-body.md` into `/tmp/pr-b-body.md`, with one Acceptance Criteria row per bullet of spec § D1, § D2 and § D4. Open PR B as a draft; it stays a draft until Task C2 passes.

```bash
git push -u origin feat/lean-review-loop
gh pr create --draft --base main --title "feat(review): lean review loop by default" --body-file /tmp/pr-b-body.md
```

---

## Part C — outside the repository

### Task C1: Suggestions stay out of the fix loop (spec § D3)

- [ ] **Step 1:** With the user's approval, set `"autoFixIncludeSuggestions": false` in `~/.zensu/config.json` (or remove the key; the default is `false`).
- [ ] **Step 2:** Verify:

```bash
node -e 'const c=require(require("os").homedir()+"/.zensu/config.json");process.stdout.write(String(c.hooks.autoFixIncludeSuggestions===true))'
```

Expected: `false`.

### Task C2: Measurement gate (spec § 5)

This task runs in the author's private benchmark kit, outside this repository, and decides whether PR B is released. The kit's operator runbook holds the exact commands; the steps below fix what they must achieve.

- [ ] **Step 1: Experiment config.** Set `hooks.autoFixIncludeSuggestions` to `false` in the kit's copied Zensu config without re-running the kit's context preparation, which would rebuild the context from the current global `CLAUDE.md` and memory and change the experiment's constants. Regenerate the context checksum file and confirm exactly one changed line, the Zensu config.

- [ ] **Step 2: Config override.** The base commit of the benchmark project tracks a project overlay `.zensu/config.json` with `{"hooks":{"autoFixIncludeSuggestions":true}}`, and a project overlay wins per key over the global file. Do not edit the repository at the base commit. Pass `ZENSU_CONFIG` through the kit's compose file instead, so that `ZENSU_CONFIG=/home/node/.zensu/config.json` makes Zensu in the container read only its global file.

- [ ] **Step 3: Image.** Build the desktop image from the pushed `feat/lean-review-loop` branch (the Dockerfile clones with `--branch`, which needs a branch or tag name) with the Rust toolchain pinned to `1.98.1`. Verify inside the image that the plugin's `config.example.json` contains `reviewPanel` and that the copied Zensu config reads `"autoFixIncludeSuggestions": false`; if either check fails, prune the BuildKit source cache and build again.

- [ ] **Step 4: Two headless runs.** Run arm A of the benchmark feature twice (`a4`, `a5`) with `ZENSU_CONFIG=/home/node/.zensu/config.json` and the new image, and confirm the variable inside each container. Wait for `/work/run.exit` with a bounded background waiter that keeps the host awake. Record the override and the compose change in both operator logs and in the kit README.

- [ ] **Step 5: Evaluate each run** exactly like the earlier benchmark runs: collect the results, run the hidden tests and the full suite against the run's checkout, compute the metrics, stop the containers, and then run the Codex blind judge and its verification, pairing each lean run with a plain run (`a4` with `b1`, `a5` with `b2`).

- [ ] **Step 6: Decide**

Release PR B (mark ready, merge, Actions → Release `minor`) only if all hold:
- at most one hidden-test failure across `a4` and `a5`;
- Codex rubric mean at least 3.3 and at most 2 verified CRITICAL defects per run;
- at most 50 USD API-equivalent and at most 180 net minutes per run (the run's metrics file, cost from the last `result` event of its stream log).

Otherwise keep PR B as a draft and report which criterion failed. In both cases add a section on the lean runs to the kit's benchmark analysis, a README addendum with the config change and the changed checksum, and state that two runs are a small sample.
