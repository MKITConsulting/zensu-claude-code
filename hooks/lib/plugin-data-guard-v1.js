// plugin-data-guard-v1.js — decides whether a file-mutating tool call targets
// the plugin's own private data store.
//
// WHY THIS EXISTS. The store named by CLAUDE_PLUGIN_DATA holds the immutable
// Session Control records (<plugin data>/session-control/v1/) and the
// review-evidence leases. Until this module landed the session could rewrite them
// through the ordinary Edit/Write tools. They are not "the anchors every gate
// binds to" — `<project>/.zensu/state/` holds the workflow document and is NOT
// covered here; see residual 2 below. Measured 2026-08-28 and recorded in
// docs/multi-repo-chains-spec.md §6.1.2: all three PreToolUse hooks that match a
// `Write` — pre-reviewer-capability-gate.sh on the `.*` matcher, plus
// pre-edit-tdd-reminder.sh and pre-write-secret-scan.sh on
// `Edit|Write|MultiEdit` — answered `allow` for a target inside the store, in
// every chain state: no chain armed, a vanilla chain armed, and a strict chain
// at RED_WRITE. None of them performs a containment check of any kind.
//
// ON THE MAIN THREAD. That qualifier is load-bearing and was missing from the
// first draft. `hooks/lib/reviewer-capability-v1.js` already denies every
// NON-main principal a write into this store (`protectedRoots`,
// `immutableRuntimeRoots`) and returns early for `main-v1`. So the net delta of
// this gate is exactly main-thread Edit/Write/MultiEdit/NotebookEdit — which is
// the channel the measurement found open, and the reason the feature stands.
// Never justify it with "every principal": that is true of the hook's own
// behaviour and false as a description of what it ADDS.
//
// SCOPE IS DELIBERATELY NARROW, and the asymmetry is accepted rather than
// overlooked. Only the store is protected. A write anywhere else outside the
// project root stays allowed here, even though the Bash source-write gate's
// rule (B) denies exactly that for a shell redirect (temp roots excepted). The
// wider rule would need a temp carve-out of its own and would refuse ordinary
// work on files outside the project; closing the measured hole does not.
//
// ELEVEN RESIDUALS, stated rather than implied, because the sentence "the store
// is protected" is false without them:
//   1. The BASH CHANNEL is not covered at all. This gate is on the Edit matcher.
//      `bash-source-write-parse.js` filters candidate targets through `SRC`,
//      which carries no `json` extension, and `mv`/`cp` are documented as out of
//      scope — so a shell redirect, copy, move or link into the store passes
//      every Bash gate. Anything holding `Bash` still reaches the store.
//   2. `<project>/.zensu/state/` is NOT in the store and is NOT covered ON THE
//      MAIN THREAD. The workflow document, the frozen `vanilla` flag and the
//      bypass ledger live there, and `pre-edit-tdd-reminder.sh` returns early
//      while no chain is armed. For a non-main principal
//      `reviewer-capability-v1.js` already protects it. Do not describe this
//      guard as protecting "the anchors every gate binds to"; it protects the
//      Session Control record and the leases.
//   3. A HARD LINK outside the store to a file inside it is judged by its own
//      path and therefore allowed ON THE MAIN THREAD — `reviewer-capability-v1.js`
//      refuses one for a non-main principal. Creating one needs `ln`, i.e.
//      residual 1.
//   4. Only the FOUR tool names in `WRITE_TOOLS` are judged. `apply_patch` is in
//      `reviewer-capability-v1.js`'s `MUTATING_FILE_TOOLS` and is NOT here, and no
//      MCP write tool is matched either; an unknown tool returns `NOT_A_WRITE`
//      and allows. Covering `apply_patch` means parsing a patch body, which this
//      change does not do — so it is named rather than silently absent.
//   5. The store's LOCATION comes from the ambient `CLAUDE_PLUGIN_DATA`, not from
//      the bound Session Control record, which carries an authoritative
//      `plugin_data`. A wrong or absent value disarms the gate (disclosed on
//      stderr, see below). Binding the record here would add a deny path to a
//      control whose entire fault direction is allow, so the ambient read is
//      deliberate — and stated, because "no escape exists" would otherwise read
//      as stronger than it is.
//
//   6. The plugin ROOT (`CLAUDE_PLUGIN_ROOT`) is NOT covered — only the data
//      store is. `reviewer-capability-v1.js` protects BOTH trees for a non-main
//      principal (`immutableRuntimeRoots`), so its protected ROOT SET is a
//      superset of this one — but it resolves with a WEAKER walk
//      (`canonicalCandidate` still collapses `..` lexically, measured bypass #2
//      here), so on that spelling this gate denies where the sibling allows.
//      "Superset" describes the roots, never the enforced boundary. On the main
//      thread an Edit of the executing hook sources is ungated.
//   7. The decision is TAKEN AT PreToolUse and the tool opens the file
//      afterwards, so a component swapped in between is followed. No PreToolUse
//      hook can hold a path across the host's own open, so this is a property of
//      the shape rather than a defect in the walk — it is listed so the gate is
//      never described as a guarantee. Planting the swap needs `ln`, i.e.
//      residual 1.
//   8. COMPOSING 1 AND 6: this gate's own decision module lives inside the
//      unprotected plugin root. One ungated main-thread `Edit` — or anything
//      holding `Bash`, by residual 1 — removes or replaces
//      `plugin-data-guard-v1.js`, and the wrapper then declines for the rest of
//      the session. Neither parent residual says this on its own, which is why
//      it is listed rather than left for the reader to compose. It is DISCLOSED
//      rather than silent: the wrapper's stderr note is the only thing that
//      separates "the gate did not run" from a clean allow, and `G11i` pins it.
//   9. THE MIRROR OF 3: a symlink INSIDE the store whose target is outside is
//      judged by its resolved location and ALLOWED. Both resolution paths agree
//      on it — the fast path follows the leaf, and the walk re-splits an absolute
//      link target from its own root — so one `ln -s` planted through residual
//      1's channel converts into ongoing Edit-channel control over what a reader
//      gets back from that record path. The store's own bytes stay untouched,
//      which is why this is a residual and not a defect in the walk.
//  10. NOTHING BOUNDS THE PROJECT ROOT. The over-arm valve fires whenever the
//      store contains or equals it, so a project root naming a directory INSIDE
//      the store carves that subtree out. It is a residual of the valve, not a
//      regression: the total disarm this replaced allowed the WHOLE store in the
//      same configuration. Bounding it means teaching this module the store's own
//      layout, which couples the decision to a shape it does not own; stated
//      rather than done. AND THE EQUALITY CASE IS THE MAXIMUM: at
//      `store === projectRoot` the carve-out is the WHOLE store and the gate
//      denies nothing at all, because the two are the same directory and every
//      in-store target is therefore in-project. Say "never more permissive than
//      the total disarm it replaced", never "strictly stricter" — at equality
//      the two are identical.
//  11. THE VALVE'S PROJECT ROOT IS THE AMBIENT `CLAUDE_PROJECT_DIR`, which this
//      repository records as NOT the authoritative project anchor — every writer
//      resolves the bound record's `project_root` instead. Where the two diverge,
//      the ordinary case for a session whose cwd is a worktree, the valve carves
//      out the harness root while the session writes somewhere else: a worktree
//      inside the store but outside that root denies, and `overArmUnchecked`
//      stays false because the root DID resolve. Binding the record here would
//      put a session lookup on every `Edit`, so this is stated rather than
//      closed.
//
// THERE IS NO ESCAPE. No ZENSU_*=off variable disables this, deliberately: the
// evidence-discipline hook is the precedent for a control with no switch, and a
// switch here would hand back exactly the capability the guard removes. That is
// also why ESCAPE_STEMS in tests/structure/test-gauntlet-loop-skill.sh and
// ZENSU_BYPASS_GATE_ALLOWLIST stay untouched by this feature — there is nothing
// to spell and nothing to ledger.
//
// FAULT DIRECTION: every fault in THIS module allows, and there is exactly one
// deny that is not a proven containment — `TRUNCATED`, taken when a resolution
// hits an internal bound, because "outside" is a claim the walk did not earn.
// Say "two exceptions" wherever the shell wrapper's exit-2 identity guard is
// named beside it. Otherwise: every fault in THIS module allows. An absent, empty or
// unresolvable CLAUDE_PLUGIN_DATA, an unparseable payload, a tool this module
// does not know, a payload with no path field, and a failure to load the sibling
// parser all return `{deny:false}`. The guard protects one directory; a fault
// that denied would instead block ordinary in-project work, which is strictly
// worse than the hole it closes. State it as "in this module", never as "every
// fault": the shell wrapper's shared plugin-root identity guard still refuses
// with exit 2, exactly as every sibling gate does, and on this matcher that
// refusal blocks the call.
//
// FOUR faults are reported on stderr, and the labels matter: the containment
// module failing to load (`GUARD_UNAVAILABLE`), a payload this module cannot read
// (`UNREADABLE` — a PAYLOAD fault, not a load fault), an unusable store
// (`NO_STORE`), which is the one that turns the control OFF completely, and a
// payload carrying no path field (`NO_TARGET`), which is what a renamed or
// restructured host field looks like from here. Say FOUR: the set is
// `SILENT_FAULT_IS_A_LIE` and it has four members, while every carrier of this
// sentence said three. A FIFTH note is not a fault — `overArmUnchecked` reports
// that an armed decision was taken without a project root, so the over-arm valve
// could not be evaluated. THREE
// further faults cannot be reached from HERE at all, because the shell wrapper
// returns before `node` runs: a missing `node`, a `hooks/lib` its `cd -P` cannot
// enter, and a `plugin-data-guard-v1.js` that is absent or is a symlink. They are
// NOT SILENT. The wrapper writes its own stderr note at each of the three, and at
// both of its exit-2 plugin-root branches as well (self-resolution failure and
// inherited-root mismatch — two distinct messages, so name them in the plural). What cannot reach them is this module's
// TYPED reason — a limit on the channel, never on whether the operator is told.
// The earlier wording said "cannot carry a note", which named a structural limit
// where there was only a choice, and `cannot` is the word that stops the next
// maintainer from fixing it.
//
// CONTAINMENT IS NOT RE-IMPLEMENTED. `within` and `msysToDrive` come from
// hooks/lib/bash-source-write-parse.js, the module that owns the rule. This
// repository already tracks a hand-copied within()/isInside() family and its
// `..bak` defect. No further copy is added here — deliberately without an ordinal,
// because this repository's own rule for that family is that a prose census goes
// stale and the control is `grep`, not a number.

const fs = require("fs");
const path = require("path");

const WRITE_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);
// Both spellings are read because the matcher covers both families:
// Edit/Write/MultiEdit carry `file_path`, NotebookEdit carries `notebook_path`.
// A tool that grows a third field is invisible here and allows — the fault
// direction above, not an oversight.
const PATH_FIELDS = ["file_path", "notebook_path"];

const REASONS = Object.freeze({
  DENY: "target-inside-plugin-data",
  NO_STORE: "plugin-data-unset-or-unresolvable",
  NOT_A_WRITE: "tool-does-not-mutate-a-file",
  NO_TARGET: "payload-carries-no-path",
  UNREADABLE: "payload-unreadable",
  GUARD_UNAVAILABLE: "containment-rule-unavailable",
  OUTSIDE: "target-outside-plugin-data",
  TRUNCATED: "target-resolution-truncated",
  // The store contains the project, so an IN-PROJECT target is carved out while
  // everything else in the store still denies. Borrowing NO_STORE for this made
  // the host print "guard did not run" on every ordinary write in that
  // configuration — false on both counts, and it trains the operator to ignore
  // the one channel that also carries the real faults.
  SCOPED_IN_PROJECT: "target-in-project-under-containing-store",
});

function loadContainment() {
  try {
    const parser = require("./bash-source-write-parse.js");
    if (typeof parser.within !== "function" || typeof parser.msysToDrive !== "function") return null;
    return { within: parser.within, msysToDrive: parser.msysToDrive };
  } catch (_) {
    return null;
  }
}

// RESOLUTION MUST IMITATE THE KERNEL, COMPONENT BY COMPONENT. Two bypasses of
// the same class were measured here before this walk existed, and both came from
// resolving the spelling before resolving the links:
//   - a leaf that is a DANGLING symlink into the store: `realpath` cannot resolve
//     a destination that does not exist yet, so the canonical spelling stayed
//     outside while the tool's own open(O_CREAT) followed the link in;
//   - `<symlink-into-store>/../x`: `path.resolve` collapses `..` LEXICALLY, so the
//     link was never read and the judged path stayed outside, while the kernel
//     resolves the link first and applies `..` to its real parent.
// So walk left to right: follow a symlink at every component, and apply `..` to
// the ALREADY RESOLVED prefix. A component that does not exist is simply appended
// — a Write creates it, and the kernel would too.
//
// Bounded twice over: the component count, and the number of link hops. On any
// fault the walk falls back to the lexical spelling, which is the allow direction.
const MAX_COMPONENTS = 4096;
const MAX_LINK_HOPS = 64;

// The separator class is PLATFORM-CONDITIONAL. A backslash is a legal character
// in a POSIX filename, so treating it as a separator there decomposes the path
// differently from the kernel: a symlink literally named `a\b` was split into two
// components, never lstat'ed, and the store it pointed into was judged outside —
// measured as ALLOWED before this gate was conditional. On win32 the backslash
// IS a separator and must stay one.
function splitSegments(rest, isWindows) {
  const pattern = isWindows ? /[\\/]+/ : /\/+/;
  return rest.split(pattern).filter((seg) => seg !== "" && seg !== ".");
}

function resolveTargetPath(spelling, base, isWindows) {
  // NOT path.resolve()/path.join() on the way in: both normalize `..` away before
  // a single link has been read, which is the whole defect this walk exists to
  // remove. Make the spelling absolute by CONCATENATION only, keeping every `..`.
  const anchor = typeof base === "string" && base !== "" ? base : process.cwd();
  const raw = path.isAbsolute(spelling) ? spelling : anchor + path.sep + spelling;
  // FAST PATH. When the whole spelling already exists the kernel resolves it in
  // one call, and its answer is what the walk below reproduces component by
  // component: every intermediate link followed, every `..` applied to the
  // already-resolved prefix, and the on-disk case restored. It is an
  // optimisation ONLY — an Edit of an existing file spends one syscall here
  // instead of an lstat plus a realpath per component — and it changes no
  // verdict, because a complete resolution cannot be truncated: neither bound
  // was reached, so `truncated` is null by construction rather than by
  // omission.
  //
  // It cannot swallow the cases the walk exists for. A target that does not yet
  // exist (the ordinary Write), a dangling leaf link, a broken intermediate
  // component and a link cycle all make realpath throw, and every one of them
  // falls through to the walk unchanged. Do NOT extend this to the PARENT
  // directory: realpath'ing the parent and rejoining the basename would leave a
  // final symlink unfollowed, which is exactly the dangling-link bypass the
  // walk was written to close.
  try {
    return { path: fs.realpathSync.native(raw), truncated: null };
  } catch (_) {
    // Incomplete on disk, or unreadable. The walk decides.
  }

  const root = path.parse(raw).root;

  let pending = splitSegments(raw.slice(root.length), isWindows);
  let resolved = root;
  let hops = 0;
  let steps = 0;

  while (pending.length > 0) {
    steps += 1;
    // A bound is reached with the walk INCOMPLETE, so the prefix built so far is
    // not a resolution — it is where we gave up. Returning it bare made "we could
    // not decide" indistinguishable from "we decided it is outside", and the
    // caller then allowed. Measured: /tmp + 2100 `a/../` pairs + a climb into the
    // store was ALLOWED at 4218 segments while the identical spelling at 24 was
    // DENIED. No symlink and no Bash are involved, so the comment that once
    // attributed this shape to the planted-link residual was wrong about it.
    // The PREFIX is returned, never the lexical spelling: `path.resolve(raw)` is
    // exactly the collapse two of the measured bypasses exploited, so falling
    // back to it would make the bound an escape hatch for anyone able to plant
    // enough links. And the prefix is not an ANSWER — it travels with
    // `truncated`, and `decide` refuses rather than reporting "outside" from a
    // walk that did not finish. An earlier wording said such a case ALLOWS and
    // blamed residual 1's planted links; both were refuted by the measurement
    // recorded below, which needs no symlink and no `Bash`.
    if (steps > MAX_COMPONENTS) return { path: resolved, truncated: "components" };
    const segment = pending.shift();
    if (segment === "..") {
      resolved = path.dirname(resolved);
      continue;
    }
    const candidate = path.join(resolved, segment);
    let stat;
    try {
      stat = fs.lstatSync(candidate);
    } catch (_) {
      // Does not exist yet — a Write creates it. The PREFIX is already canonical,
      // which is what the containment test needs.
      resolved = candidate;
      continue;
    }
    if (stat.isSymbolicLink()) {
      hops += 1;
      if (hops > MAX_LINK_HOPS) return { path: resolved, truncated: "link-hops" };
      let link;
      try {
        link = fs.readlinkSync(candidate);
      } catch (_) {
        resolved = candidate;
        continue;
      }
      // The link TARGET re-enters this same walk rather than being resolved in
      // one step: resolving it wholesale left its own intermediate components
      // unchecked and collapsed any `..` inside it lexically, which is the very
      // defect this function exists for, reintroduced one level down. Measured:
      // `L -> p/q` with `p -> <store>` was ALLOWED before this re-split.
      if (path.isAbsolute(link)) {
        const linkRoot = path.parse(link).root;
        pending = splitSegments(link.slice(linkRoot.length), isWindows).concat(pending);
        resolved = linkRoot;
      } else {
        pending = splitSegments(link, isWindows).concat(pending);
      }
      continue;
    }
    // An existing, ordinary component is CANONICALIZED. Without this the walk
    // keeps the caller's spelling, and on a case-insensitive volume (macOS by
    // default) a case-variant of the store prefix lstats fine, stays uncanonical,
    // and `within` — a pure string comparison — reports it outside while the
    // kernel writes inside. Measured: a case-flipped store prefix was ALLOWED.
    // The sibling resolver in reviewer-capability-v1.js carries the same line for
    // the same reason; the two must not drift.
    try {
      resolved = fs.realpathSync.native(candidate);
    } catch (_) {
      resolved = candidate;
    }
  }
  return { path: resolved, truncated: null };
}

// EVERY path-bearing field is returned, not the first. First-match-wins is the
// unsafe direction for a deny gate: a payload carrying a benign `file_path`
// beside a store-targeting `notebook_path` would be judged on the wrong one. The
// sibling reviewer-capability-v1.js collects them all for the same reason.
function targetsOf(payload) {
  const input = payload && typeof payload === "object" ? payload.tool_input : null;
  if (!input || typeof input !== "object") return [];
  const out = [];
  for (const field of PATH_FIELDS) {
    const value = input[field];
    if (typeof value === "string" && value.trim() !== "") out.push(value);
  }
  return out;
}

// `cwd` resolves a RELATIVE target, and the three sources are RANKED. The
// payload's own cwd wins because a hook does not necessarily run where the tool
// call was issued. The caller's fallback comes second: the wrapper `cd -P`s into
// hooks/lib to require this module, so `process.cwd()` names the plugin tree
// rather than the caller's directory, and a relative target would resolve outside
// the store here while the tool resolved it inside. `process.cwd()` is last and
// exists only so a direct caller that supplies neither still gets an anchor.
// Both supplied sources must be ABSOLUTE: a relative anchor would itself be
// resolved against `process.cwd()` further down, reinstating the same defect one
// call later. An absolute target ignores all three.
function baseOf(payload, fallback) {
  const cwd = payload && typeof payload === "object" ? payload.cwd : null;
  if (typeof cwd === "string" && cwd.trim() !== "" && path.isAbsolute(cwd)) return cwd;
  if (typeof fallback === "string" && fallback.trim() !== "" && path.isAbsolute(fallback)) {
    return fallback;
  }
  return process.cwd();
}

// An ANCHOR is resolved by the same rule as a target, and never by
// `path.resolve`. Two reasons, both measured elsewhere in this file. First,
// `path.resolve` collapses `..` before a single link is read — bypass #2, applied
// to the anchor instead of the target, which points the gate at a directory that
// is not the store so every real store write reads as OUTSIDE. Second, it makes a
// RELATIVE value absolute against `process.cwd()`, which the wrapper has already
// moved to <plugin root>/hooks/lib; a relative anchor is a misconfiguration, not
// a path to resolve, so it is refused rather than pointed somewhere arbitrary.
//
// The anchor must also EXIST as a directory. The walk tolerates components that
// do not exist yet — a target is often about to be created — but an anchor that
// is not there cannot contain anything, and arming on it would be arming on a
// guess.
function resolveAnchor(raw, containment, isWindows) {
  if (typeof raw !== "string" || raw.trim() === "" || !path.isAbsolute(containment.msysToDrive(raw, isWindows))) {
    return "";
  }
  const walk = resolveTargetPath(containment.msysToDrive(raw, isWindows), "", isWindows);
  if (walk.truncated) return "";
  try {
    if (!fs.lstatSync(walk.path).isDirectory()) return "";
  } catch (_) {
    return "";
  }
  return walk.path;
}

function decide(options) {
  const opts = options || {};
  const payload = opts.payload;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return { deny: false, reason: REASONS.UNREADABLE };
  }
  if (!WRITE_TOOLS.has(payload.tool_name)) {
    return { deny: false, reason: REASONS.NOT_A_WRITE };
  }
  // Presence is decided on the trimmed value; the value itself travels
  // UNTRIMMED, because a trailing space is a legal POSIX directory name and
  // trimming it would name a different path, throw in realpath, and silently
  // turn the guard off. This mirrors baseOf() above, which already separates
  // the two.
  const storePresent = typeof opts.pluginData === "string" && opts.pluginData.trim() !== "";
  if (!storePresent) return { deny: false, reason: REASONS.NO_STORE };
  const rawStore = opts.pluginData;

  const containment = opts.containment || loadContainment();
  if (!containment) return { deny: false, reason: REASONS.GUARD_UNAVAILABLE };

  // PARTIAL by design, and stated so the signature does not imply portability it
  // does not provide: this override reaches the separator class and `msysToDrive`,
  // but every `path.*` call in the walk stays bound to the host implementation.
  // Driving the win32 branch from POSIX would need a `pathImpl` parameter as well,
  // the way the sibling parser takes one for its temp-entry judgment.
  const isWindows = typeof opts.isWindows === "boolean" ? opts.isWindows : process.platform === "win32";
  const store = resolveAnchor(rawStore, containment, isWindows);
  if (store === "") return { deny: false, reason: REASONS.NO_STORE };
  // A store that IS a filesystem root would deny every write in the session, and
  // there is no switch to recover with — the fail direction of this one value is
  // the opposite of every other fault here. The sibling parser rejects the same
  // shape in its temp list for the mirror-image reason.
  if (path.parse(store).root === store) return { deny: false, reason: REASONS.NO_STORE };

  const rawTargets = targetsOf(payload);
  if (rawTargets.length === 0) return { deny: false, reason: REASONS.NO_TARGET };

  const base = containment.msysToDrive(baseOf(payload, opts.cwd), isWindows);
  // A store that STRICTLY CONTAINS the project is not a store, it is a
  // misconfiguration — and arming on it denies every write in the session. The
  // filesystem-root check above catches only the degenerate case; one step below
  // it ($HOME, the project's parent) produced the same unrecoverable state,
  // because this gate ships with no config flag and no env escape, so the session
  // cannot edit the file that would fix it. The sibling parser's temp list uses
  // exactly this containment test rather than a root test, which is what the
  // comment above meant to claim and did not.
  //
  // The anchor is the PROJECT ROOT, never the payload cwd. Keying on the cwd was
  // tried and is a bypass: the caller supplies it, so standing inside the store
  // would have disarmed the gate — the exact spelling G8 exists to deny. The
  // project root is ambient and not part of the judged payload.
  // The anchor comes ONLY from the caller. Reading CLAUDE_PROJECT_DIR here put a
  // Claude-specific environment name inside the host-neutral half, invisible to a
  // port reading module.exports, and made the valve's availability depend on
  // something no caller could see. The host half now supplies it, and an armed
  // decision that could not evaluate the valve says so through
  // `overArmUnchecked` rather than skipping it in silence.
  // The anchor is resolved UNCONDITIONALLY and the flag keys on the OUTCOME.
  // Keying it on the raw string being empty reported only one of the four ways
  // the valve can be skipped: a whitespace-only value, a relative one, a
  // truncated walk and a directory that is gone all resolve to "" while the flag
  // stayed false and the host said nothing. A removed worktree is the ordinary
  // case of the last one, and it is exactly when the operator needs the line.
  const rawProjectRoot = typeof opts.projectRoot === "string" ? opts.projectRoot : "";
  const projectRoot = resolveAnchor(rawProjectRoot, containment, isWindows);
  const overArmUnchecked = projectRoot === "";
  let workspace = "";
  {
    // NOT `projectRoot !== store`. `within` is already true at equality, and that
    // conjunct excluded exactly the case store === project root — where the gate
    // armed and denied every write in the session, with no config flag and no env
    // escape to recover with. That is the unrecoverable state this valve exists
    // to prevent, so equality must disarm like any other containing store.
    if (projectRoot !== "" && containment.within(store, projectRoot)) {
      // KNOWN RESIDUAL, and not a regression: nothing bounds where the project
      // root may point, so one naming a directory INSIDE the store carves that
      // subtree out, and at `store === projectRoot` the carve-out is the whole
      // store. The scoped form is NEVER MORE PERMISSIVE than the total disarm it
      // replaced, but it is not strictly stricter either — at equality the two
      // are identical. Residual 10 carries both halves.
      // SCOPED, not total. Returning here for every target allowed the records
      // directory itself — the thing this gate exists for — in exactly the
      // configuration where the operator has no way to notice. What the
      // usability argument above actually requires is that IN-PROJECT writes keep
      // working; everything else inside the store stays protected.
      workspace = projectRoot;
    }
  }
  // The raw spelling and the base travel separately: resolving them together
  // here would collapse `..` before resolveTargetPath could read a link.
  // "Outside" is a claim this module must EARN. The truncation branch below is
  // the ONE deny that is not a proven containment, and it is safe because no
  // legitimate input reaches a bound: MAX_COMPONENTS is far above what PATH_MAX
  // permits, and MAX_LINK_HOPS is above the kernel's own ELOOP ceiling.
  let lastTarget = "";
  let scopedInProject = false;
  let scopedTarget = "";
  for (const rawTarget of rawTargets) {
    const walk = resolveTargetPath(containment.msysToDrive(rawTarget, isWindows), base, isWindows);
    const target = walk.path;
    lastTarget = target;
    // FIRST, before containment. On an overrun `target` is the prefix the walk
    // reached, not where the path leads, so judging containment on it answers a
    // question the walk did not settle: a prefix inside the carve-out was
    // scoped-ALLOWED while the unresolved remainder climbed into the store.
    if (walk.truncated) {
      return { deny: true, reason: REASONS.TRUNCATED, store, target, overArmUnchecked };
    }
    if (containment.within(store, target)) {
      if (workspace !== "" && containment.within(workspace, target)) {
        // CONTINUE, never return. Every path-bearing field is judged, because
        // first-match-wins is the unsafe direction for a deny gate — a benign
        // `file_path` beside a store-targeting `notebook_path` would otherwise
        // decide the call. The scoped outcome is remembered and answered after
        // the loop, so a later field can still deny.
        scopedInProject = true;
        scopedTarget = target;
        continue;
      }
      return { deny: true, reason: REASONS.DENY, store, target, overArmUnchecked };
    }
  }
  if (scopedInProject) {
    // The target that EARNED the verdict, not whatever the loop saw last. On a
    // two-field payload `lastTarget` can name a path that is neither in the store
    // nor in the project, so the reason and the target would contradict each
    // other in an exported contract.
    return { deny: false, reason: REASONS.SCOPED_IN_PROJECT, store, target: scopedTarget, overArmUnchecked };
  }
  return { deny: false, reason: REASONS.OUTSIDE, store, target: lastTarget, overArmUnchecked };
}

// The wording names the store and points at the helpers, because the model that
// reads this is the one that has to do something else instead. It deliberately
// does not name an escape: there is none.
// Only the ECHOED spelling is bounded, never the judged one: a control byte in a
// path must not be able to break the line a model reads back, but REJECTING the
// target on the way in would return NO_TARGET and ALLOW — the wrong direction for
// this gate, and the opposite of what the sibling resolver does with the same
// input class.
function displayTarget(target) {
  return typeof target === "string" ? target.replace(/[\u0000-\u001f\u007f]/g, "?") : "(unknown)";
}

function denyReason(verdict) {
  // A truncated walk is a DIFFERENT refusal and must not borrow the sentence
  // above: that one asserts the target is inside the store, which is exactly what
  // this branch could not establish. Saying it anyway would be a false claim in
  // the one message a model reads back.
  if (verdict && verdict.reason === REASONS.TRUNCATED) {
    return (
      "Plugin-Data-Guard: refused because the target's resolution hit an internal"
      + " bound (" + REASONS.TRUNCATED + ") before containment could be decided ("
      + displayTarget(verdict.target)
      + "). No legitimate path reaches that bound, so this is not a limit you need"
      + " to work around — shorten the spelling, or write through the plugin's own"
      + " helpers (hooks/lib/zensu-log.sh and the skills that call it)."
    );
  }
  return (
    "Plugin-Data-Guard: writing into the Zensu plugin's private data store is blocked ("
    + displayTarget(verdict.target)
    + "). That store holds this session's immutable Session Control record and the"
    + " review-evidence leases, so a gate would end up reading its own boundary from a"
    + " file the gated party rewrote. Legitimate state"
    + " changes go through the plugin's own helpers (hooks/lib/zensu-log.sh and the"
    + " skills that call it), never through a file edit."
  );
}

function describe(verdict) {
  return verdict && typeof verdict.reason === "string" ? verdict.reason : REASONS.UNREADABLE;
}

// The faults whose silence would be indistinguishable from a clean allow: ONE
// load fault (`GUARD_UNAVAILABLE`), TWO payload faults (`UNREADABLE` and
// `NO_TARGET`, which are payload faults and not load faults — the header says so
// and every carrier repeats it), and `NO_STORE`, which means the guard ran with
// no boundary to enforce, which is the same thing from the operator's side.
const SILENT_FAULT_IS_A_LIE = new Set([
  REASONS.GUARD_UNAVAILABLE,
  REASONS.UNREADABLE,
  REASONS.NO_STORE,
  // Once the tool name has matched WRITE_TOOLS the call carries a target by
  // construction, so an absent path field is not an ordinary outcome — it is
  // what a host that renamed or restructured the field looks like. In that state
  // this gate allows every write on every call, which is precisely the shape
  // that must not render as a healthy allow. TRUNCATED is deliberately NOT here:
  // it now denies, and a deny is visible on its own.
  REASONS.NO_TARGET,
]);

// The payload decision, separated from the stream plumbing so it can be driven
// directly. It is the one place that turns "what arrived on stdin" into "what
// this module will judge", and its failure direction is the whole point: a read
// that did NOT complete must yield NO payload, never an empty one.
//
// The earlier spelling cleared the buffer on a throw and let the `end` handler
// parse `"{}"`. That succeeded, `tool_name` was undefined, and the verdict was
// NOT_A_WRITE — a reason deliberately absent from SILENT_FAULT_IS_A_LIE, so the
// call was allowed and rendered byte-identical to a healthy allow. Padding
// `content` past V8's string limit was then exactly the size-decides-the-verdict
// bypass this module refuses to build, relocated from a configured cap to an
// engine limit. `null` here lands on the DISCLOSED `UNREADABLE` instead.
//
// An EMPTY read still yields `{}`, which is not the same case: nothing failed,
// the harness simply sent nothing, and that has always allowed with a name.
function payloadFromRaw(raw, accumulationFailed) {
  if (accumulationFailed) return null;
  try {
    return JSON.parse(raw || "{}");
  } catch (_) {
    return null;
  }
}

module.exports = {
  decide, denyReason, describe, REASONS, WRITE_TOOLS, PATH_FIELDS, resolveTargetPath, targetsOf,
  SILENT_FAULT_IS_A_LIE, payloadFromRaw,
};

if (require.main === module) {
  let raw = "";
  process.stdin.setEncoding("utf8");
  // The append is guarded because a failure here — V8's max string length on a
  // very large tool payload, or an allocation failure — would throw INSIDE an
  // event handler, exit non-zero, and surface as a stack trace rather than as one
  // of this module's typed reasons. Every other fault here allows with a name; a
  // crash is the one that does not.
  //
  // Deliberately NOT a size cap. A cap that routed an over-cap payload to an
  // allowing reason would be a bypass: pad `content` past it and the store write
  // is permitted. Size must never decide the verdict, so an unreadable
  // accumulation simply leaves `raw` at what arrived and the parse below answers.
  let accumulationFailed = false;
  const accumulate = (chunk) => {
    if (accumulationFailed) return;
    try {
      raw += chunk;
    } catch (_) {
      accumulationFailed = true;
      raw = "";
    }
  };
  process.stdin.on("data", (chunk) => { accumulate(chunk); });
  // A stream fault is the same class as a failed append, and without this
  // listener Node re-throws the `error` event: the process exits non-zero with
  // a stack trace and emits no verdict at all — the crash the accumulation
  // guard exists to prevent, reached through the other door. Routing it to the
  // same flag lands it on the DISCLOSED `UNREADABLE` instead.
  // ONE verdict, from whichever event arrives. A readable destroyed by an
  // `error` emits `close`, not `end`, so a handler registered only on `end`
  // never runs: the process would exit 0 having written neither a decision nor
  // a note — strictly worse than the unhandled error it replaced, which at
  // least surfaced a non-zero exit. The once-guard is what keeps `close`
  // arriving after `end` from producing a second verdict.
  let settled = false;
  const finalize = () => {
    if (settled) return;
    settled = true;
    try {
      decideAndEmit();
    } catch (_) {
      // The sibling `accumulate` is guarded for exactly this reason: a throw
      // inside an event handler exits non-zero with a stack trace instead of one
      // of this module's typed reasons. `process.stdout` carries no error
      // listener, so an EPIPE on the deny write is the realistic trigger — and
      // there the deny is lost as well.
      process.stderr.write("zensu: plugin-data guard did not run (" + REASONS.UNREADABLE + ")\n");
    }
  };
  const decideAndEmit = () => {
      const payload = payloadFromRaw(raw, accumulationFailed);
      // All three anchors are read HERE, in the ENTRY POINT — this file's HOST
      // half, and the only part of it that names a harness variable. The DECISION
      // below names none, so a port re-decides these three reads without editing
      // it. Do not call the FILE host-neutral: two of the three names are
      // Claude's own and only the third is rendered by the wrapper. ZENSU_GUARD_CALLER_CWD is the
      // wrapper's own directory, captured before its `cd -P` into hooks/lib;
      // without it a relative target anchors in the plugin tree instead of where
      // the tool call was issued.
      const verdict = decide({
        payload,
        pluginData: process.env.CLAUDE_PLUGIN_DATA || "",
        cwd: process.env.ZENSU_GUARD_CALLER_CWD || "",
        projectRoot: process.env.CLAUDE_PROJECT_DIR || "",
      });
      // The over-arm valve could not be evaluated. The verdict stands either way
      // — this is a disclosure, not a decision — but a gate armed on an unchecked
      // store is exactly what an operator has to be told about, because the state
      // it guards against has no in-session escape.
      // SCOPED to the verdicts the valve could have flipped. Attached to OUTSIDE it
    // fired on every ordinary allowed write for the whole session, which is the
    // "trains the operator to ignore the channel" defect the SCOPED_IN_PROJECT
    // reason was introduced to remove, reappearing one line over.
    if (verdict.overArmUnchecked
      && (verdict.reason === REASONS.DENY || verdict.reason === REASONS.TRUNCATED)) {
        process.stderr.write(
          "zensu: plugin-data guard armed without a project root — "
          + "the over-arm check was not performed (set CLAUDE_PROJECT_DIR)\n",
        );
      }
      if (!verdict.deny) {
        // The CARVE-OUT is disclosed too, and it is the only weakened-boundary state
    // that had no signal at all: the strictly safer state (the valve could not be
    // evaluated, so the gate denies everything in the store) printed a line while
    // the permissive one — valve evaluated, a subtree actively carved out — was
    // byte-identical to a clean allow. It gets its OWN sentence rather than the
    // "did not run" one, because the guard did run and is still enforcing.
    if (verdict.reason === REASONS.SCOPED_IN_PROJECT) {
      process.stderr.write(
        "zensu: plugin-data guard carved out the project — the store "
        + String(verdict.store) + " contains or equals the project root, so "
        + "in-project targets are allowed and everything else in the store is "
        + "still denied\n",
      );
    }
    if (SILENT_FAULT_IS_A_LIE.has(verdict.reason)) {
          process.stderr.write("zensu: plugin-data guard did not run (" + describe(verdict) + ")\n");
        }
        return;
      }
      // No process.exit() after this write. stdout is the decision channel and a
      // pipe is asynchronous on darwin; exiting from the write's own turn can
      // truncate the payload, and a truncated deny is read as an allow. Let the
      // stream drain and the process end on its own — the exit code is already 0.
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: denyReason(verdict),
        },
      }));
  };
  process.stdin.on("error", () => { accumulationFailed = true; raw = ""; finalize(); });
  process.stdin.on("end", finalize);
  process.stdin.on("close", finalize);
}
