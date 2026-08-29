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
// SEVEN RESIDUALS, stated rather than implied, because the sentence "the store
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
//
// THERE IS NO ESCAPE. No ZENSU_*=off variable disables this, deliberately: the
// evidence-discipline hook is the precedent for a control with no switch, and a
// switch here would hand back exactly the capability the guard removes. That is
// also why ESCAPE_STEMS in tests/structure/test-gauntlet-loop-skill.sh and
// ZENSU_BYPASS_GATE_ALLOWLIST stay untouched by this feature — there is nothing
// to spell and nothing to ledger.
//
// FAULT DIRECTION: every fault in THIS module allows. An absent, empty or
// unresolvable CLAUDE_PLUGIN_DATA, an unparseable payload, a tool this module
// does not know, a payload with no path field, and a failure to load the sibling
// parser all return `{deny:false}`. The guard protects one directory; a fault
// that denied would instead block ordinary in-project work, which is strictly
// worse than the hole it closes. State it as "in this module", never as "every
// fault": the shell wrapper's shared plugin-root identity guard still refuses
// with exit 2, exactly as every sibling gate does, and on this matcher that
// refusal blocks the call.
//
// THREE faults are reported on stderr, and the labels matter: the containment
// module failing to load (`GUARD_UNAVAILABLE`), a payload this module cannot read
// (`UNREADABLE` — a PAYLOAD fault, not a load fault), and an unusable store
// (`NO_STORE`), which is the one that turns the control OFF completely. THREE
// further faults are SILENT and cannot be reached from here at all, because
// the shell wrapper returns before `node` runs: a missing `node`, a `hooks/lib`
// its `cd -P` cannot enter, and a `plugin-data-guard-v1.js` that is absent or is
// a symlink.
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
  // On a bound overrun the walk returns the PREFIX it has resolved so far, never
  // the lexical spelling: `path.resolve(raw)` is exactly the collapse that two of
  // the measured bypasses exploited, so falling back to it would make the bound
  // an escape hatch for anyone able to plant enough links. State BOTH directions,
  // because the prefix is not a guarantee either: if the walk was already inside
  // the store it stays deny, but a budget exhausted while the prefix is still
  // OUTSIDE allows, even when the full resolution would have landed inside.
  // Reaching either shape needs enough planted links to spend 4096 segments,
  // which is residual 1's channel.
  const root = path.parse(raw).root;

  let pending = splitSegments(raw.slice(root.length), isWindows);
  let resolved = root;
  let hops = 0;
  let steps = 0;

  while (pending.length > 0) {
    steps += 1;
    if (steps > MAX_COMPONENTS) return resolved;
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
      if (hops > MAX_LINK_HOPS) return resolved;
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
  return resolved;
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

// `cwd` resolves a RELATIVE target. The payload's own cwd is preferred over the
// process cwd because a hook does not necessarily run where the tool call was
// issued; an absolute target ignores both.
function baseOf(payload, fallback) {
  const cwd = payload && typeof payload === "object" ? payload.cwd : null;
  if (typeof cwd === "string" && cwd.trim() !== "" && path.isAbsolute(cwd)) return cwd;
  return typeof fallback === "string" && fallback !== "" ? fallback : process.cwd();
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
  // turn the guard off. This mirrors baseOf() below, which already separates
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
  let store;
  try {
    store = fs.realpathSync.native(path.resolve(containment.msysToDrive(rawStore, isWindows)));
  } catch (_) {
    return { deny: false, reason: REASONS.NO_STORE };
  }
  // A store that IS a filesystem root would deny every write in the session, and
  // there is no switch to recover with — the fail direction of this one value is
  // the opposite of every other fault here. The sibling parser rejects the same
  // shape in its temp list for the mirror-image reason.
  if (path.parse(store).root === store) return { deny: false, reason: REASONS.NO_STORE };

  const rawTargets = targetsOf(payload);
  if (rawTargets.length === 0) return { deny: false, reason: REASONS.NO_TARGET };

  const base = containment.msysToDrive(baseOf(payload, opts.cwd), isWindows);
  // The raw spelling and the base travel separately: resolving them together
  // here would collapse `..` before resolveTargetPath could read a link.
  let lastTarget = "";
  for (const rawTarget of rawTargets) {
    const target = resolveTargetPath(containment.msysToDrive(rawTarget, isWindows), base, isWindows);
    lastTarget = target;
    if (containment.within(store, target)) {
      return { deny: true, reason: REASONS.DENY, store, target };
    }
  }
  return { deny: false, reason: REASONS.OUTSIDE, store, target: lastTarget };
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

// The faults whose silence would be indistinguishable from a clean allow. The
// two load faults mean the guard did not run; NO_STORE means it ran with no
// boundary to enforce, which is the same thing from the operator's side.
const SILENT_FAULT_IS_A_LIE = new Set([
  REASONS.GUARD_UNAVAILABLE,
  REASONS.UNREADABLE,
  REASONS.NO_STORE,
]);

module.exports = {
  decide, denyReason, describe, REASONS, WRITE_TOOLS, PATH_FIELDS, resolveTargetPath, targetsOf,
  SILENT_FAULT_IS_A_LIE,
};

if (require.main === module) {
  let raw = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => { raw += chunk; });
  process.stdin.on("end", () => {
    let payload = null;
    try {
      payload = JSON.parse(raw || "{}");
    } catch (_) {
      payload = null;
    }
    const verdict = decide({ payload, pluginData: process.env.CLAUDE_PLUGIN_DATA || "" });
    if (!verdict.deny) {
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
  });
}
