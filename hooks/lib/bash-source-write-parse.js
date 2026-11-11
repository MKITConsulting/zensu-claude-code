"use strict";

// Parser for pre-bash-source-write-gate.sh. Reads the PreToolUse(Bash) payload
// from $PAYLOAD, walks the command, and decides whether any write through a
// gated channel (redirect / tee / sed -i / dd of= / heredoc) hits a source file
// that must not be clobbered, or whether a git command mutates a repository
// outside the session root. Prints the deny reason on stdout, or nothing.
//
// FOUR behaviors, selected by BSWG_MODE. Each judging caller pins the variable
// explicitly so an ambient value can never flip its behavior:
//   (unset)  the deny path below — pre-bash-source-write-gate.sh, anchored. The
//            deny caller pins BSWG_MODE= for exactly that reason.
//   detect   emit the write channels present in the command (one per line, no
//            git checks, no path policy). `detectChannels()` is consumed
//            IN-PROCESS by hooks/lib/secret-scan-decide.js; the BSWG_MODE=detect
//            CLI form exists so tests/structure/test-secret-scan-gate.sh can
//            drive it standalone. A TEXT matcher; see its own contract below.
//   control  emit a Session Control rebind reason via detectControlMutation() —
//            pre-bash-source-write-gate.sh runs it FIRST, ahead of the config
//            check and every escape hatch, because that is the real trust
//            boundary.
//   targets  report the resolved write OPERAND instead of judging it against a
//            project root — pre-bash-source-write-gate.sh's no-project-root
//            branch, the one state where no root exists to judge against.
//
// Kept in its own file (like hooks/lib/session-control-core-v1.js) so the logic uses
// normal quoting instead of being escaped inside a bash single-quoted node -e.
//
// COMMAND TOKENS are resolved LEXICALLY (path.resolve/path.relative, no realpath),
// so a symlink inside the project pointing at a sibling/main checkout resolves as
// "within project" and slips the (B)/(C) escape rules. Likewise `tee >(proc) realfile`
// is not caught — the process-substitution `(` severs the real file operand that
// follows `)`.
//
// Only the comparison roots are canonicalized, once, via `canonical()`: the project
// root and the payload cwd eagerly (two realpath calls per invocation — untimed,
// unlike `tracked()`, so a hung mount as cwd would stall the hook) and the temp
// roots lazily, on the first isTemp miss.
//
// Rule (C) has more accepted gaps of its own: `lex()` splits on
// `&`/`;`/`|` without quote awareness, so a quoted global-option operand holding
// one of them severs the segment before the subcommand is seen
// (`git -C X -c user.name="A & B" commit`), and only assignments written in the
// command itself supply GIT_DIR/GIT_WORK_TREE — an `export` in an earlier segment
// of the SAME command counts, but one exported by the user's shell before Claude
// Code started does not, because the hook inherits that environment and must not
// deny on it. Biggest of all: a token the shell has yet to expand (`"$REPO"`,
// `$(git rev-parse …)`) carries no location. In `-C` or `--work-tree` that leaves
// nothing judgeable and the whole command is recorded UNRESOLVED; in `--git-dir` it
// drops only that candidate, so a literal `-C ../sibling` beside it still denies.
// `path.resolve` would otherwise splice the literal `$REPO` under the cwd and call
// it in-project.
// Rule (C) also anchors on `program`, and the command reader sees through the WRAP
// names, their own options and the reserved words before a command, so a wrapper
// outside WRAP or the coproc keyword hides the verb: `timeout 5 git …`,
// `xargs git …`, `coproc git …`. That is
// pre-existing (`sed -i` and `dd` share the anchor) and is not the drifted-cwd
// incident rule (C) exists for, so it is accepted rather than closed. A linked
// worktree's admin dir may likewise ride along on an in-project --work-tree even
// when it belongs to a FOREIGN repo — lexically the two are indistinguishable.
// One more comes from the shared reader and binds rules (B) and (C) alike: `cd`
// tracking reads the word right after `cd`, so `cd -- ../sibling` and
// `cd -P ../sibling` move the cwd to `<proj>/--` and `<proj>/-P` instead of the
// sibling.
// Finally, `worktree remove|move` given a bare worktree NAME rather than a path
// is unjudgeable — git resolves the name against a worktree list this parser
// deliberately never reads — so that spelling passes.
// Three more are specific to Windows, where the gate compares a project root MSYS
// already converted against a payload cwd and command tokens it never touched (see
// msysToDrive below). It assumes the MSYS mount convention instead of probing
// MSYSTEM, so on a win32 host whose shell is not Git Bash the shell would read
// `/d/a/x` against a different drive than this does. The drive prefix is rewritten
// before `..` resolution, so `/d/../a/x` clamps at the drive root — the same
// location the pre-fix drive-relative splice produced, so unchanged rather than
// new. And drive-relative `D:rel` on the project's own drive resolves against the
// base and reads as in-project, so it is allowed even though the shell may resolve
// it elsewhere.
// All accepted rare-idiom gaps: this is a convention-nudge with an env escape
// hatch, not a security boundary.

const path = require("path");
const fs = require("fs");
const { execFileSync } = require("child_process");
// The ONLY sibling require in this file, and a deliberate one: the MSYS drive
// rule has to be identical to the one the session-control path boundary applies,
// and the program-name reading to the one the other gates are to share, so a
// shared total function is the way to guarantee that instead of a hand-copy held
// by a lockstep pin. The module is side-effect-free and already required by its
// peers in this directory. If it were missing the parser
// would fail to load and its hook would deny — the fail-closed direction, and the
// same posture tests/structure/test-msys-runtime-boundaries.sh already pins for
// the sibling MSYS helper.
const { msysDrivePrefix, programName: sharedProgramName } = require("./claude-path-v1.js");

const SRC = new Set(
  "rs ts tsx js jsx mjs cjs py java kt kts go rb c cc cpp cxx h hh hpp cs php swift scala vue svelte".split(" ")
);

const SHELL_WRAP = new Set(["command", "builtin"]);
const RESERVED_WORDS = new Set("! { } if then else elif fi do done while until".split(" "));
const SHELL_ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?(\+?)=/;
const MAX_SPLITS = 8;
const WRAPPER_OPTIONS = Object.assign(Object.create(null), {
  env: {
    flags: "0iv",
    operands: "uCSPLU",
    optional: "",
    long: {
      "ignore-environment": 0, null: 0, debug: 0, help: 0, version: 0, "list-signal-handling": 0,
      unset: 1, chdir: 1, "split-string": 1, "block-signal": 2, "default-signal": 2, "ignore-signal": 2
    },
    effects: {
      i: "clear", "ignore-environment": "clear", u: "unset", unset: "unset",
      C: "chdir", chdir: "chdir", S: "split", "split-string": "split"
    }
  },
  sudo: {
    flags: "AbBEeHiKklNnPSsVv",
    operands: "aCcDgpRrTtUu",
    optional: "h",
    long: {
      askpass: 0, background: 0, bell: 0, edit: 0, "set-home": 0, help: 0, login: 0, "remove-timestamp": 0,
      "reset-timestamp": 0, list: 0, "non-interactive": 0, "preserve-groups": 0, stdin: 0, shell: 0, version: 0,
      validate: 0, "close-from": 1, chdir: 1, group: 1, host: 1, prompt: 1, chroot: 1, role: 1, type: 1,
      "command-timeout": 1, "other-user": 1, user: 1, "preserve-env": 2
    },
    effects: { D: "chdir", chdir: "chdir" }
  },
  nice: { flags: "", operands: "n", optional: "", long: { adjustment: 1, help: 0, version: 0 }, effects: {} },
  nohup: { flags: "", operands: "", optional: "", long: { help: 0, version: 0 }, effects: {} },
  time: {
    flags: "ahlpqv",
    operands: "fo",
    optional: "",
    long: { format: 1, output: 1, append: 0, portability: 0, quiet: 0, verbose: 0, help: 0, version: 0 },
    effects: {}
  },
  command: { flags: "pvV", operands: "", optional: "", long: {}, effects: {} },
  builtin: { flags: "", operands: "", optional: "", long: {}, effects: {} },
  exec: { flags: "cl", operands: "a", optional: "", long: {}, effects: { c: "clear" } }
});
// Transparent command wrappers — skipped so `env sed -i …` / `sudo dd of=…`
// still resolve to the real verb (mirrors pre-bash-zensu-gate.sh).
const WRAP = new Set(Object.keys(WRAPPER_OPTIONS));
const ENV_SPLIT_ESCAPES = { f: "\f", n: "\n", r: "\r", t: "\t", v: "\v" };
const SED_LONG_OPTIONS = {
  "in-place": 2, expression: 1, file: 1, "line-length": 1, "follow-symlinks": 0, "null-data": 0,
  "zero-terminated": 0, posix: 0, quiet: 0, silent: 0, "regexp-extended": 0, separate: 0, sandbox: 0,
  unbuffered: 0, debug: 0, help: 0, version: 0
};
const ANSI_C_ESCAPES = Object.assign(Object.create(null), {
  a: "\x07", b: "\b", e: "\x1b", E: "\x1b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v",
  "\\": "\\", "'": "'", "\"": "\"", "?": "?"
});

// Git subcommands that rewrite a repository's index or working tree. Rule (C)
// denies these ONLY when the target repository escapes the session root, so the
// list can stay broad without touching normal in-worktree git work. Everything
// absent from it passes: reads (status/log/diff/rev-parse/…) and unknown verbs
// alike, mirroring pre-bash-zensu-gate.sh — a deny-list, because an allow-list
// would deny unknown and future verbs in the user's OWN repository, the far
// worse failure for a nudge. `worktree` is listed for `remove`/`move` only; its
// other subverbs are read-only forms below, so `git worktree add` — which
// legitimately targets a path outside the current root — stays ungated.
const GIT_MUTATIONS = new Set(
  ("add am apply bisect checkout checkout-index cherry-pick clean commit merge mv pull read-tree " +
    "rebase reset restore revert rm sparse-checkout stash submodule switch update-index worktree").split(" ")
);

// A token the shell would expand before git sees it. `path.resolve` would splice
// the literal `$REPO` under the cwd and report it as in-project, so such a token
// carries no location this parser may judge either way.
const UNEXPANDED = /[$`]/;

// Non-mutating spellings of otherwise-gated verbs. Denying `stash list` with a
// message asserting it "rewrites another session's index" would simply be false.
// Each predicate reads the verb's own arguments (everything after the subcommand).
// Prototype-free so a subcommand named `constructor` or `toString` cannot reach
// an inherited member and classify itself read-only.
const GIT_READONLY_FORMS = Object.assign(Object.create(null), {
  // `--check` and the reporting flags all turn applying off, and an explicit
  // `--apply` turns it back on after any of them. Likewise git's parse-options auto-negation
  // means a later `--no-dry-run` cancels an earlier `-n`, so every dry-run
  // exemption is last-wins rather than presence-only.
  // `--apply` is presence-only rather than last-wins: git documents no `--no-apply`,
  // and if one exists the miss is fail-CLOSED (an over-deny clearable by the hatch).
  apply: (a) => !a.includes("--apply")
    && (a.includes("--check") || a.some((t) => /^--(stat|numstat|summary)$/.test(t))),
  bisect: (a) => /^(log|view|visualize|help)$/.test(firstOperand(a)),
  mv: (a) => dryRun(a),
  "sparse-checkout": (a) => /^(list)$/.test(firstOperand(a)),
  // `foreach` is NOT here: it runs an arbitrary command inside every submodule
  // working tree, so exempting it would be the one entry whose claim is false.
  submodule: (a) => /^(status|summary)$/.test(firstOperand(a)),
  // Only clusters built from clean's own boolean flags count, so `-nd` reads as
  // a dry run while `-enode` (an -e exclude pattern) does not.
  clean: (a) => dryRun(a, (t) => /^-[dfnqxX]+$/.test(t) && t.indexOf("n") !== -1),
  rm: (a) => dryRun(a),
  stash: (a) => /^(list|show)$/.test(firstOperand(a)),
  worktree: (a) => !/^(remove|move)$/.test(firstOperand(a))
});

// A linked worktree's admin directory always sits at <repo>/.git/worktrees/<name>.
// That path is outside the session root by construction, so it is the one foreign
// `--git-dir` an in-project `--work-tree` may legitimately accompany.
// Tested against a slash-normalized copy: path.resolve emits `\` on win32.
const LINKED_WORKTREE_GIT_DIR = /\/\.git\/worktrees\/[^/]+$/;
const isLinkedWorktreeGitDir = (d) => LINKED_WORKTREE_GIT_DIR.test(d.replace(/\\/g, "/"));

// Git GLOBAL options that consume a separate operand unless spelled `--opt=value`.
const GIT_OPTS_WITH_OPERAND = new Set(
  "-C -c --git-dir --work-tree --namespace --super-prefix --exec-path --config-env --attr-source".split(" ")
);

const OPT_IN_NOTE =
  " This gate is opt-in and runs because hooks.bashWriteGate is true in the Zensu config; " +
  "if the command is intended, ask the user to run it or to switch the gate off.";

function stripSlash(p) {
  return p && p.length > 1 && p.endsWith("/") ? p.replace(/\/+$/, "") : p;
}

// Same containment predicate hooks/lib/reviewer-capability-v1.js uses, and that
// session-control-core-v1.js and review-evidence-lease-v1.js each hand-copy,
// alongside the copy in hooks/lib/state-path-safety-v1.js, the tdd-phase path walk.
// It sits at MODULE scope and is EXPORTED, so a consumer in this process can
// call it rather than growing a sixth copy — `skills/session-trail/scripts/
// trail.mjs` (`writeAnchor`) took the seam first, and `hooks/lib/
// plugin-data-guard-v1.js` is the SECOND consumer. That one changes the blast
// radius of this export list: removing `within` or `msysToDrive` no longer only
// degrades a skill's rendering, it degrades a PreToolUse DENY gate to allow via
// its `GUARD_UNAVAILABLE` fault direction. The path-walk copy keeps its own body:
// it runs in every Stop-path lease and loads only node built-ins, never this parser.
// The `..` test must be anchored on a separator and on the exact `..`: a bare
// startsWith("..") also rejects a legitimately nested `..bak`, whose relative
// path is `..bak`, and the empty relative path means "is the root itself".
// It closes over nothing but `stripSlash` and `path`, which is what made the
// hoist free — moving it changed no verdict, only who can reach it.
function within(root, p) {
  const rel = path.relative(stripSlash(root), p);
  return rel === "" || (rel !== ".." && !rel.startsWith(".." + path.sep) && !path.isAbsolute(rel));
}

// Git Bash and the native Windows Node this hook launches spell the same
// absolute path in two namespaces, and only ONE side is converted: MSYS rewrites
// an EXPORTED variable — which is why `CLAUDE_PROJECT_DIR` arrives as
// `D:\a\proj`, and why the hook has to exclude CLAUDE_ENV_FILE from that
// conversion by hand — but it never touches the payload cwd or a command token,
// both of which reach us over stdin still spelled `/d/a/proj`. `path.resolve`
// does not bridge the two: on win32 a leading `/` is drive-RELATIVE, so the
// whole POSIX path is spliced under the current drive (`D:\d\a\proj`). The
// session's own root then compares as an escape, and rule (C) denies every git
// verb inside it while rule (B) denies every new-file write. Rewriting the MSYS
// drive prefix before any resolution is what keeps both spellings comparable.
//
// `isWindows` is a parameter rather than a `process.platform` read inside the
// function so the unit layer can drive both branches from any host. On POSIX
// this is a no-op by construction: there `/d/a/x` is a legitimate path, not a
// drive. The drive letter is upper-cased to match the spelling MSYS produces,
// so a deny reason cannot quote one location in two namespaces. Purely lexical,
// like every other resolution here — no filesystem probe.
//
// MSYS_DRIVE is a deliberate HAND-COPY of the MSYS branch in
// claude-path-v1.js's `msysDrivePrefix`, the SHARED rule — this file deliberately
// keeps no copy of it. That module's `normalizeHostPathInput` layers a
// fail-closed-by-THROWING policy on top for the session-control trust boundary it
// was written for; that policy is wrong here, because this parser RETURNS a deny
// reason and an exception would exit non-zero, making the hook deny every Bash
// call in the session rather than the one command. `/var/folders/x` — a DEFAULT
// entry of the temp list below — is one of the spellings it throws on, so the
// distinction is not theoretical. Sharing the total function and declining the
// policy is what lets one rule serve both. W3c pins that every resolution site
// still routes through this adapter; W3d pins that no private copy reappears.
//
// Leaving an unconverted token in its raw spelling changes no verdict: every
// rooted spelling that module's policy rejects resolves OUTSIDE the session root,
// so `within()` reports an escape for it. Whether the escape is then DENIED is a
// separate question this function does not decide — `/tmp/x` and `/var/folders/x`
// are members of the default temp list, so `isTemp()` allows them by design and
// always did; only a spelling outside every temp root, such as a complete UNC, is
// actually denied. The one spelling where the raw pass-through is not fail-closed
// is drive-relative `D:rel`: on the project's own drive path.resolve models it
// against the base, so it lands inside and is allowed, and if the shell's real
// cwd on that drive is elsewhere the write escapes. That behavior is unchanged by
// this normalizer (`D:rel` has no leading slash, so the rule never sees it) and is
// pinned in git-repo-escape.test.js so the judgment stays visible.
//
// This rule's accepted gaps are stated in the header block at the top of the file,
// which is the window W192 actually reads — do not restate them here, or one copy
// will drift unpinned. Two notes that belong with the code instead: narrowing the
// guard to `process.platform === "win32" && !!process.env.MSYSTEM` is NOT a safe
// unilateral fix — if MSYSTEM does not reach the native child it would restore the
// all-deny defect, so it needs a Windows host to settle. And this file still holds
// two MSYS drive rules of its own: the ungated, lower-casing `controlPathNamespace`
// pair below, which serve the separate CLAUDE_ENV_FILE comparison namespace and are
// deliberately NOT unified with the shared one. W3d pins that the count stays two.
//
// The boolean parameter is kept rather than the module's platform string so the
// call sites and the unit suite read unchanged.
function msysToDrive(value, isWindows) {
  return msysDrivePrefix(value, isWindows ? "win32" : "posix");
}
const IS_WINDOWS = process.platform === "win32";

// A temp entry that must never become a carve-out, for either of two reasons.
// A whole VOLUME exempts everything on it, and `TEMP_SAFE` cannot catch that on
// win32: a root on ANOTHER drive does not lexically contain the project, so `C:\`
// would survive while the project sits on `D:` and carve out that entire drive —
// user profile and sibling checkouts included — with no bypass-ledger entry. A
// DRIVE-RELATIVE entry (`C:`, `C:rel`) carries no root at all, so node resolves it
// against that drive's own current directory, an arbitrary location this parser
// cannot know; the carve-out would then point somewhere nobody declared.
// `filter(Boolean)` does not remove those — `Boolean("C:")` is true.
// The caller applies this predicate at BOTH stages of the TEMP pipeline because
// neither stage sees every unsafe entry: drive-relative survives only until
// `path.resolve` fully qualifies it away, so it can be caught only BEFORE, while a
// RELATIVE entry such as `..` or `.` becomes a root only after resolving against
// the process cwd, so it can be caught only AFTER. A drive root spelled `/c`
// becomes `C:/` at the raw stage and is therefore caught at either.
// Takes the path implementation so the win32 judgment is drivable from POSIX.
function isUnsafeTempEntry(value, pathImpl) {
  if (!value) return false;
  if (pathImpl.sep === "\\" && /^[A-Za-z]:(?![\\/])/.test(value)) return true;
  return pathImpl.parse(value).root === value;
}

// ZENSU_BSWGATE_TEMP_DIRS is a LIST, and on Windows both list conventions reach
// us: MSYS converts an exported POSIX `:` list, while an operator may supply a
// native one — `;`-separated, entries drive-qualified with either separator.
// (`hooks/lib/zensu-host-path.sh` renders drive-qualified FORWARD-slash paths and
// is not wired to this variable; it is the shape to expect, not a producer of it.)
// A plain `.split(":")` shreds a drive-qualified entry into `["D", "\\a\\tmp"]`,
// so the intended root never enters TEMP at all and the rule (B) carve-out
// silently stops applying. A colon separates entries EXCEPT when it is a drive
// colon, which sits at index 1 of an entry and follows a single letter.
function splitTempList(value, isWindows) {
  if (!isWindows) return value.split(":");
  const out = [];
  for (const chunk of value.split(";")) {
    let start = 0;
    for (let i = 0; i < chunk.length; i++) {
      if (chunk[i] !== ":") continue;
      if (i - start === 1 && /[A-Za-z]/.test(chunk[start])) continue;
      out.push(chunk.slice(start, i));
      start = i + 1;
    }
    out.push(chunk.slice(start));
  }
  return out;
}

function unquote(t) {
  return t.replace(/^['"]+|['"]+$/g, "");
}

function programName(word, isWindows = IS_WINDOWS) {
  return sharedProgramName(String(word || ""), isWindows ? "win32" : "posix", "always");
}

function ansiC(text, start) {
  let end = start;
  while (end < text.length && text[end] !== "'") end += text[end] === "\\" ? 2 : 1;
  end = Math.min(end, text.length);
  const body = text.slice(start, end);
  let value = "";
  let cut = false;
  let i = 0;
  while (i < body.length) {
    let ch = body[i];
    let next = i + 1;
    if (ch === "\\" && i + 1 < body.length) {
      const c = body[i + 1];
      const rest = body.slice(i + 2);
      next = i + 2;
      let m = null;
      if (ANSI_C_ESCAPES[c] !== undefined) {
        ch = ANSI_C_ESCAPES[c];
      } else if (/[0-7]/.test(c)) {
        m = /^[0-7]{0,2}/.exec(rest);
        ch = String.fromCharCode(parseInt(c + m[0], 8) & 0xff);
        next += m[0].length;
      } else if (c === "x" && (m = /^[0-9A-Fa-f]{1,2}/.exec(rest))) {
        ch = String.fromCharCode(parseInt(m[0], 16));
        next += m[0].length;
      } else if ((c === "u" || c === "U") && (m = (c === "u" ? /^[0-9A-Fa-f]{1,4}/ : /^[0-9A-Fa-f]{1,8}/).exec(rest))
        && parseInt(m[0], 16) <= 0x10ffff) {
        ch = String.fromCodePoint(parseInt(m[0], 16));
        next += m[0].length;
      } else if (c === "c" && rest.length > 0) {
        ch = String.fromCharCode(rest.charCodeAt(0) & 0x1f);
        next += rest[0] === "\\" && rest[1] === "\\" ? 2 : 1;
      } else {
        ch = "\\" + c;
      }
    }
    if (ch.indexOf("\0") !== -1) {
      value += cut ? "" : ch.slice(0, ch.indexOf("\0"));
      cut = true;
    } else if (!cut) {
      value += ch;
    }
    i = next;
  }
  return { value, end };
}

function braceEnd(text, start, quoted, bashQuotes) {
  const stack = [quoted ? "quoted" : "brace"];
  let k = start + 2;
  while (k < text.length && stack.length) {
    const c = text[k];
    const top = stack[stack.length - 1];
    if (c === "\\") {
      k += 2;
    } else if (top === "string") {
      if (c === "\"") stack.pop();
      else if (c === "$" && text[k + 1] === "$") k++;
      else if (c === "$" && text[k + 1] === "{") { stack.push("quoted"); k++; }
      k++;
    } else if (c === "}") {
      stack.pop();
      k++;
    } else if (c === "$" && text[k + 1] === "$") {
      k += 2;
    } else if (c === "$" && text[k + 1] === "{") {
      stack.push(top);
      k += 2;
    } else if (c === "\"") {
      stack.push("string");
      k++;
    } else if (c === "$" && text[k + 1] === "'" && top === "brace") {
      k += 2;
      while (k < text.length && text[k] !== "'") k += text[k] === "\\" ? 2 : 1;
      k++;
    } else if (c === "'" && (top === "brace" || (bashQuotes && top === "quoted"))) {
      const close = text.indexOf("'", k + 1);
      k = close === -1 ? text.length : close + 1;
    } else {
      k++;
    }
  }
  return Math.min(k, text.length);
}

function redirectOperator(text, i) {
  const two = text.substr(i, 2);
  if (text.substr(i, 3) === "<<<") return "<<<";
  if (two === "<<") return text[i + 2] === "-" ? "<<-" : "<<";
  if (text[i] === "<") return two === "<>" || two === "<&" ? two : "<";
  return /^&?>>?&?[|!]?/.exec(text.substr(i, 5))[0];
}

function segmentWords(text, bashQuotes) {
  const words = [];
  const n = text.length;
  let word = null;
  let i = 0;
  const close = (to) => {
    if (word) words.push({ raw: text.slice(word.start, to), value: word.value });
    word = null;
  };
  while (i < n) {
    const c = text[i];
    if (/\s/.test(c)) {
      close(i);
      i++;
      continue;
    }
    if (c === "&" && text[i + 1] === ">") {
      close(i);
      const raw = redirectOperator(text, i);
      i += raw.length;
      words.push({ raw, value: raw, op: raw });
      continue;
    }
    if (c === ">" || c === "<") {
      const prefix = word === null ? "" : text.slice(word.start, i);
      const fd = /^(?:\d+|\{[A-Za-z_][A-Za-z0-9_]*\})$/.test(prefix);
      const start = fd ? word.start : i;
      if (fd) word = null;
      else close(i);
      i += redirectOperator(text, i).length;
      const raw = text.slice(start, i);
      const token = { raw, value: raw, op: fd ? raw.slice(prefix.length) : raw };
      if (fd && prefix[0] === "{") token.fdName = prefix.slice(1, -1);
      words.push(token);
      continue;
    }
    if (!word) word = { start: i, value: "" };
    if (c === "\\") {
      word.value += i + 1 < n ? text[i + 1] : c;
      i += 2;
    } else if (c === "'") {
      const end = text.indexOf("'", i + 1);
      word.value += text.slice(i + 1, end === -1 ? n : end);
      i = end === -1 ? n : end + 1;
    } else if (c === "$" && text[i + 1] === "$") {
      word.value += "$$";
      i += 2;
    } else if (c === "$" && text[i + 1] === "'") {
      const decoded = ansiC(text, i + 2);
      word.value += decoded.value;
      i = decoded.end + 1;
    } else if (c === "\"" || (c === "$" && text[i + 1] === "\"")) {
      let k = i + (c === "$" ? 2 : 1);
      while (k < n && text[k] !== "\"") {
        if (text[k] === "\\" && k + 1 < n && "$`\"\\\n".indexOf(text[k + 1]) !== -1) {
          word.value += text[k + 1];
          k += 2;
        } else if (text[k] === "$" && (text[k + 1] === "$" || text[k + 1] === "{")) {
          const stop = text[k + 1] === "$" ? k + 2 : braceEnd(text, k, true, bashQuotes);
          word.value += text.slice(k, stop);
          k = stop;
        } else {
          word.value += text[k];
          k++;
        }
      }
      i = k + 1;
    } else if (c === "$" && text[i + 1] === "{") {
      const stop = braceEnd(text, i, false, bashQuotes);
      word.value += text.slice(i, stop);
      i = stop;
    } else {
      word.value += c;
      i++;
    }
  }
  close(Math.min(i, n));
  return words;
}

function scanLine(line, quote, edge) {
  let q = quote;
  let boundary = edge;
  let dollar = false;
  for (let k = 0; k < line.length; k++) {
    const c = line[k];
    if (q === "'") {
      if (c === "'") q = "";
      continue;
    }
    if (c === "\\") {
      if (k === line.length - 1) return { quote: q, continues: true, edge: boundary };
      k++;
      boundary = false;
      dollar = false;
      continue;
    }
    if (q !== "") {
      if (c === (q === "\"" ? "\"" : "'")) q = "";
      continue;
    }
    if (c === "#" && boundary) return { quote: "", continues: false, edge: true };
    if (c === "'") q = dollar ? "$'" : "'";
    else if (c === "\"") q = "\"";
    boundary = /[\s;&|()]/.test(c);
    dollar = c === "$";
  }
  return { quote: q, continues: false, edge: boundary };
}

function heredocWord(line, start) {
  let value = "";
  let quoted = false;
  let k = start;
  while (k < line.length && !/[ \t\n;&|()<>]/.test(line[k])) {
    const c = line[k];
    if (c === "\\") {
      value += line[k + 1] || "";
      k += 2;
      quoted = true;
    } else if (c === "$" && line[k + 1] === "'") {
      const decoded = ansiC(line, k + 2);
      value += decoded.value;
      k = decoded.end + 1;
      quoted = true;
    } else if (c === "$" && line[k + 1] === "\"") {
      k++;
    } else if (c === "'" || c === "\"") {
      const close = line.indexOf(c, k + 1);
      const end = close === -1 ? line.length : close;
      value += line.slice(k + 1, end);
      k = end + 1;
      quoted = true;
    } else {
      value += c;
      k++;
    }
  }
  return { value, end: Math.min(k, line.length), quoted };
}

function heredocDelimiters(line) {
  const docs = [];
  let quote = "";
  let depth = 0;
  let boundary = true;
  let dollar = false;
  for (let k = 0; k < line.length; k++) {
    const c = line[k];
    if (quote === "'") {
      if (c === "'") quote = "";
      continue;
    }
    if (c === "\\") {
      k++;
      boundary = false;
      dollar = false;
      continue;
    }
    if (quote !== "") {
      if (c === (quote === "\"" ? "\"" : "'")) quote = "";
      continue;
    }
    if (depth > 0) {
      if (line.startsWith("))", k)) {
        depth--;
        k++;
      } else if (line.startsWith("((", k)) {
        depth++;
        k++;
      }
      continue;
    }
    if (c === "#" && boundary) break;
    if (c === "$" && (line[k + 1] === "{" || line[k + 1] === "[")) {
      k = (line[k + 1] === "{" ? braceEnd(line, k, false, false) : bracketEnd(line, k + 1)) - 1;
      boundary = false;
      dollar = false;
      continue;
    }
    if (line.startsWith("((", k)) {
      depth++;
      k++;
      continue;
    }
    if (line.startsWith("<<<", k)) {
      k += 2;
      boundary = false;
      continue;
    }
    if (line.startsWith("<<", k)) {
      let j = k + 2;
      const tabs = line[j] === "-";
      if (tabs) j++;
      while (line[j] === " " || line[j] === "\t") j++;
      const word = heredocWord(line, j);
      if (word.end > j) docs.push({ delim: word.value, tabs, quoted: word.quoted });
      k = Math.max(word.end, j) - 1;
      boundary = false;
      dollar = false;
      continue;
    }
    if (c === "'") quote = dollar ? "$'" : "'";
    else if (c === "\"") quote = "\"";
    boundary = /[\s;&|()]/.test(c);
    dollar = c === "$";
  }
  return docs;
}

function skipHeredocs(lines, i, docs) {
  let next = i;
  for (const doc of docs) {
    while (next < lines.length && (doc.tabs ? lines[next].replace(/^\t+/, "") : lines[next]) !== doc.delim) next++;
    if (next < lines.length) next++;
  }
  return next;
}

function keepHeredocs(lines, i, docs, out) {
  let next = i;
  for (const doc of docs) {
    while (next < lines.length) {
      let line = lines[next++];
      while (!doc.quoted && /(?:^|[^\\])(?:\\\\)*\\$/.test(line) && next < lines.length) line = line.slice(0, -1) + lines[next++];
      out.push(line);
      if ((doc.tabs ? line.replace(/^\t+/, "") : line) === doc.delim) break;
    }
  }
  return next;
}

function logicalText(text, skipBodies, keepBodies) {
  const lines = text.split("\n");
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const parts = [];
    let quote = "";
    let edge = true;
    for (;;) {
      const line = lines[i++];
      const scan = scanLine(line, quote, edge);
      quote = scan.quote;
      edge = scan.edge;
      if (scan.continues) {
        parts.push(line.slice(0, -1));
        if (i < lines.length) continue;
      } else {
        parts.push(line);
        if (quote !== "" && i < lines.length) {
          parts.push("\n");
          edge = false;
          continue;
        }
      }
      break;
    }
    const logical = parts.join("");
    out.push(logical);
    if (skipBodies) i = skipHeredocs(lines, i, heredocDelimiters(logical));
    else if (keepBodies) i = keepHeredocs(lines, i, heredocDelimiters(logical), out);
  }
  return out.join("\n");
}

function joinContinuations(text) {
  return logicalText(text, false);
}

function joinedText(text) {
  return logicalText(text, false, true);
}

function commandText(cmd) {
  return logicalText(cmd, true);
}

function splitRedirects(segment) {
  const words = [];
  const writes = [];
  for (let k = 0; k < segment.length; k++) {
    const w = segment[k];
    if (!w.op) {
      words.push(w);
      continue;
    }
    const target = k + 1 < segment.length && !segment[k + 1].op ? segment[k + 1] : null;
    if (target) k++;
    const base = w.op.replace(/[|!]$/, "");
    const duplicate = /^>>?&$/.test(base) && /^(?:\d+|-)$/.test(target ? target.value : "");
    const readWrite = w.op === "<>" && /^\d+<>$/.test(w.raw) && !/^0+<>$/.test(w.raw);
    if (target && ((/^(?:&>>?|>>?&?)$/.test(base) && !duplicate) || readWrite)) writes.push(target);
  }
  return { words, writes };
}

function longOption(table, given) {
  const names = Object.keys(table);
  if (names.indexOf(given) !== -1) return given;
  const hits = names.filter((name) => name.startsWith(given));
  return given !== "" && hits.length === 1 ? hits[0] : null;
}

function envSplit(text) {
  const words = [];
  let value = null;
  let quote = "";
  const finish = () => {
    if (value !== null) words.push({ raw: value, value, split: true });
    value = null;
  };
  for (let k = 0; k < text.length; k++) {
    const c = text[k];
    const next = text[k + 1];
    if (quote === "'") {
      if (c === "\\" && (next === "\\" || next === "'")) {
        value += next;
        k++;
      } else if (c === "'") {
        quote = "";
      } else {
        value += c;
      }
      continue;
    }
    if (c === "\\") {
      k++;
      if (next === undefined || (next === "c" && quote === "")) break;
      if (next === "_" && quote === "") finish();
      else value = (value || "") + (next === "_" ? " " : ENV_SPLIT_ESCAPES[next] || next);
      continue;
    }
    if (quote === "\"") {
      if (c === "\"") quote = "";
      else value += c;
      continue;
    }
    if (/\s/.test(c)) {
      finish();
    } else if (c === "#" && value === null) {
      break;
    } else if (c === "'" || c === "\"") {
      quote = c;
      value = value || "";
    } else {
      value = (value || "") + c;
    }
  }
  finish();
  return words;
}

function wrapperArguments(name, words, start, out) {
  const spec = WRAPPER_OPTIONS[name];
  if (!spec) return start;
  const apply = (key, value, at, source) => {
    const kind = Object.prototype.hasOwnProperty.call(spec.effects, key) ? spec.effects[key] : "";
    if (kind === "clear") out.ops.push({ kind });
    else if (value === undefined) return;
    else if (kind === "unset" || kind === "chdir") out.ops.push({ kind, name: value });
    else if (kind === "split" && out.splits++ < MAX_SPLITS) {
      const literal = Boolean(source && (source.split || /['\\]/.test(source.raw)));
      words.splice(at, 0, ...envSplit(value).map((w) => Object.assign(w, { literal })));
    }
    else if (kind === "split") out.overflow = true;
  };
  let i = start;
  while (i < words.length) {
    const word = words[i].value;
    if (word === "--") {
      i++;
      break;
    }
    if (name === "env" && word === "-") {
      out.ops.push({ kind: "clear" });
      i++;
      continue;
    }
    if (name === "nice" && /^-\d+$/.test(word)) {
      i++;
      continue;
    }
    if (word.length < 2 || word[0] !== "-") break;
    const found = [];
    let used = 1;
    if (word[1] === "-") {
      const eq = word.indexOf("=");
      const key = longOption(spec.long, eq === -1 ? word.slice(2) : word.slice(2, eq));
      let value = eq === -1 ? undefined : word.slice(eq + 1);
      let source = words[i];
      if (key !== null && spec.long[key] === 1 && value === undefined && i + 1 < words.length) {
        value = words[i + 1].value;
        source = words[i + 1];
        used = 2;
      }
      if (key !== null) found.push([key, value, source]);
    } else {
      for (let k = 1; k < word.length; k++) {
        const letter = word[k];
        if (spec.operands.indexOf(letter) !== -1 || (spec.optional.indexOf(letter) !== -1 && k + 1 < word.length)) {
          let value = word.slice(k + 1);
          let source = words[i];
          if (value === "" && i + 1 < words.length) {
            value = words[i + 1].value;
            source = words[i + 1];
            used = 2;
          }
          found.push([letter, value === "" ? undefined : value, source]);
          break;
        }
        found.push([letter, undefined]);
      }
    }
    i += used;
    for (const [key, value, source] of found) apply(key, value, i, source);
  }
  while (i < words.length && words[i].value.indexOf("=") > 0) {
    const value = words[i].value;
    out.ops.push({ kind: "set", name: value.slice(0, value.indexOf("=")), value: value.slice(value.indexOf("=") + 1) });
    i++;
  }
  const named = (value) => value[0] === "-" || value.indexOf("=") <= 0 ? value : value.slice(0, value.indexOf("="));
  if (words.slice(start, i + 1).some((w) => w.split && w.literal && named(w.value).indexOf("${") !== -1)) out.dynamic = true;
  return i;
}

function commandWords(segment) {
  const words = segment.slice();
  const out = { words, index: 0, word: "", leading: [], ops: [], inShell: true, splits: 0, overflow: false, dynamic: false };
  let i = 0;
  for (;;) {
    while (i < words.length && RESERVED_WORDS.has(words[i].raw)) i++;
    if (i < words.length && words[i].raw === "time") {
      i++;
      while (i < words.length && (words[i].raw === "-p" || words[i].raw === "--")) i++;
      continue;
    }
    break;
  }
  while (i < words.length) {
    const m = SHELL_ASSIGNMENT.exec(words[i].raw);
    if (!m) break;
    const value = segmentWords(words[i].raw.slice(m[0].length)).map((w) => w.value).join("");
    out.leading.push({ name: m[1], plain: !m[2] && !m[3], value, subscript: m[2] ? m[2].slice(1, -1) : "" });
    i++;
  }
  while (i < words.length && WRAP.has(programName(words[i].value))) {
    if (!SHELL_WRAP.has(words[i].value)) out.inShell = false;
    i = wrapperArguments(programName(words[i].value), words, i + 1, out);
  }
  out.index = i;
  out.word = i < words.length ? words[i].value : "";
  return out;
}

function sedInPlace(args) {
  for (let k = 0; k < args.length; k++) {
    const a = args[k];
    if (a === "--") return false;
    if (a.startsWith("--")) {
      const eq = a.indexOf("=");
      const key = longOption(SED_LONG_OPTIONS, eq === -1 ? a.slice(2) : a.slice(2, eq));
      if (key === "in-place") return true;
      if (key !== null && SED_LONG_OPTIONS[key] === 1 && eq === -1) k++;
      continue;
    }
    if (a.length < 2 || a[0] !== "-") continue;
    for (let c = 1; c < a.length; c++) {
      if (a[c] === "i" || a[c] === "I") return true;
      if (a[c] === "e" || a[c] === "f") {
        if (c === a.length - 1) k++;
        break;
      }
    }
  }
  return false;
}

// Absoluteness probe for a RAW spelling. A tilde only resolves to a fixed
// location when HOME is non-empty — with an empty HOME `expand()` yields "",
// and path.resolve(base, "") returns the base, i.e. position-DEPENDENT.
function expandTilde(p) {
  if (p !== "~" && !p.startsWith("~/")) return p;
  return process.env.HOME ? "/" : p;
}

function firstOperand(args) {
  const t = args.find((a) => a.charAt(0) !== "-");
  return t === undefined ? "" : t;
}

// Last-wins dry-run detection: git's parse-options lets a later `--no-dry-run`
// cancel an earlier `-n`, so presence alone would exempt a real mutation.
function dryRun(args, alsoDry) {
  let dry = false;
  for (const t of args) {
    if (t === "-n" || t === "--dry-run" || (alsoDry && alsoDry(t))) dry = true;
    else if (t === "--no-dry-run") dry = false;
  }
  return dry;
}

// The pure half of rule (C): read a git invocation's repository addressing and
// its subcommand out of the tokens that follow `git`. Exported so the option
// lattice is unit-testable without spawning this file with a PAYLOAD envelope.
// `resolve(base, value)` is supplied by the caller so path resolution keeps ONE
// definition shared with rule (B). Nothing here touches the filesystem.
function gitTargets(args, base, resolve, isWindows) {
  const windows = isWindows === undefined ? IS_WINDOWS : isWindows;
  let repo = base;
  let sub = "";
  let subIndex = -1;
  let unresolved = false;
  let absoluteBase = false;
  const workTrees = [];
  const gitDirs = [];
  // Resolved candidates whose RAW spelling was already absolute. Those resolve
  // identically for every possible expansion of an unresolved `-C`, so they stay
  // judgeable when the base does not. Absoluteness of the resolved value proves
  // nothing — path.resolve makes everything absolute.
  const absolute = [];
  for (let k = 0; k < args.length; k++) {
    const t = unquote(args[k]);
    if (t.charAt(0) !== "-") { sub = t; subIndex = k; break; }
    const eq = t.indexOf("=");
    const name = eq === -1 ? t : t.slice(0, eq);
    // Unquote AFTER the split: `--git-dir="/x"` leaves a leading quote when the
    // whole token is unquoted first, and a value starting with `"` is not
    // absolute, so it would resolve back inside the project and slip the rule.
    let value = eq === -1 ? "" : unquote(t.slice(eq + 1));
    if (eq === -1 && GIT_OPTS_WITH_OPERAND.has(name) && args[k + 1] !== undefined) {
      value = unquote(args[++k]);
    }
    if (!value) continue;
    // Only these three address a repository. A `$` anywhere else — say
    // `-c core.excludesFile=$HOME/.gitignore` — says nothing about which repo is
    // addressed and must never disarm a literal `-C ../sibling` beside it.
    if (name !== "-C" && name !== "--work-tree" && name !== "--git-dir") continue;
    // An unexpanded token would splice `$REPO` under the cwd and read as
    // in-project. Record that the addressing is unresolved and judge nothing
    // from it, rather than manufacturing a false in-project candidate.
    // Scope the suppression to what the token actually invalidates. `-C` moves the
    // base every later path resolves against and `--work-tree` names the tree that
    // gets mutated, so an unexpanded one leaves nothing judgeable. `--git-dir` only
    // adds a candidate, so an unexpanded one drops THAT candidate and leaves a
    // literal `-C ../sibling` beside it still judgeable.
    if (UNEXPANDED.test(value)) {
      // ONLY `-C` re-bases every later resolution, so only it leaves nothing
      // judgeable. An unexpanded `--work-tree` or `--git-dir` drops just its own
      // candidate — a literal `-C ../sibling` beside it is still an escape.
      if (name === "-C") { unresolved = true; absoluteBase = false; }
      continue;
    }
    // Multiple -C are cumulative, each resolved against the previous one, and
    // git applies them before anything else — so the designations below resolve
    // against the POST- -C directory.
    if (name === "-C") {
      repo = resolve(repo, value);
      absoluteBase = path.isAbsolute(expandTilde(value));
    } else {
      (name === "--work-tree" ? workTrees : gitDirs).push(value);
      if (path.isAbsolute(expandTilde(value))) absolute.push(value);
    }
  }
  const operands = subIndex === -1 ? [] : args.slice(subIndex + 1).map(unquote);
  // Stop at the first bare `--`: everything after it is a pathspec, so a FILE
  // named `-n` must not read as clean's dry-run flag and disarm the verb.
  const dashDash = operands.indexOf("--");
  const flags = dashDash === -1 ? operands : operands.slice(0, dashDash);
  // `worktree remove|move` names the tree it destroys as an operand, not through
  // -C — judging only the addressed repository would miss the whole point of
  // gating it. `move` names source and destination; both are candidates.
  // Derived from `operands`, NOT `flags`: everything after a bare `--` is a path
  // here, so truncating would make `worktree remove --force -- <tree>` fall back
  // to judging the repository — fail-open in exactly the case this exists for.
  // A bare worktree NAME (`worktree remove pr-42`) is not a path — resolving it
  // against a foreign `repo` would deny a command that actually removes a tree
  // elsewhere, teaching the escape hatch for no gain. Nor is a token the shell
  // has yet to expand. Only literal path spellings become candidates.
  // On Windows a path spelling need not contain a forward slash at all, and the
  // backslash arm stays win32-only on purpose: a POSIX filename may legally
  // contain `\`, and treating one as a path would deny a bare worktree NAME. This
  // matters more since the namespace fix: the deny reason now quotes the correctly
  // resolved native path, so without this arm re-issuing the command with the very
  // spelling the gate just printed would pass.
  const isPathish = (t) =>
    !UNEXPANDED.test(t) && (t.indexOf("/") !== -1
      || (windows && (t.indexOf("\\") !== -1 || /^[A-Za-z]:/.test(t)))
      || t === "." || t === ".." || t === "~");
  const pathRaw = sub === "worktree" && /^(remove|move)$/.test(firstOperand(flags))
    ? operands.filter((t) => t !== "--" && t.charAt(0) !== "-").slice(1).filter(isPathish)
    : [];
  const paths = pathRaw.map((v) => resolve(repo, v));
  return {
    sub,
    repo,
    paths,
    unresolved,
    absolute: (absoluteBase ? [repo] : []).concat(absolute.map((v) => resolve(repo, v)))
      .concat(paths.filter((_, i) => path.isAbsolute(expandTilde(pathRaw[i])))),
    readOnly: !!(GIT_READONLY_FORMS[sub] && GIT_READONLY_FORMS[sub](flags)),
    workTrees: workTrees.map((v) => resolve(repo, v)),
    gitDirs: gitDirs.map((v) => resolve(repo, v))
  };
}

// Drop heredoc bodies so their content (which may contain `>` or `*.rs` text)
// cannot be misread as commands. The intro line is kept, so `cat > FILE <<EOF`
// still surfaces its `> FILE` redirect.
function stripHeredocs(s) {
  const lines = s.split("\n");
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i++];
    out.push(line);
    i = skipHeredocs(lines, i, heredocDelimiters(line));
  }
  return out.join("\n");
}

// Split into command segments while tracking subshell scope. `(`/`$(` emit an
// "enter" event and `)` a "leave" event so the caller can save/restore the cwd
// across a subshell — a `cd` inside `( … )` must not leak to later commands.
// Backtick is treated as a plain boundary. `&&`/`||`/`;`/`|`/newline/`&` split.
function escapedAt(s, i) {
  let k = i - 1;
  while (k >= 0 && s[k] === "\\") k--;
  return (i - 1 - k) % 2 === 1;
}

function lex(s, wholeRedirects = true) {
  const ev = [];
  let buf = "";
  let depth = 0;
  const flush = () => { ev.push({ t: "seg", text: buf }); buf = ""; };
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    const two = s.substr(i, 2);
    if (two === "$(") { flush(); ev.push({ t: "enter" }); depth++; i++; continue; }
    if (c === "(") { flush(); ev.push({ t: "enter" }); depth++; continue; }
    if (c === ")") { flush(); if (depth > 0) { ev.push({ t: "leave" }); depth--; } continue; }
    if (c === "`") { flush(); continue; }
    if (two === "&&" || two === "||") { flush(); i++; continue; }
    const afterRedirect = (s[i - 1] === ">" || (c === "&" && s[i - 1] === "<")) && !escapedAt(s, i - 1);
    const afterDuplicate = c === "|" && s[i - 1] === "&" && s[i - 2] === ">" && !escapedAt(s, i - 2);
    if (wholeRedirects && ((c === "&" && (afterRedirect || s[i + 1] === ">")) || (c === "|" && afterRedirect) || afterDuplicate)) {
      buf += c;
      continue;
    }
    // `|` and `&` put the next command in a subshell, so an `export` or `cd`
    // does NOT carry across them; `;` and newline do carry.
    if (c === "|" || c === "&") { flush(); ev.push({ t: "reset" }); continue; }
    if (c === ";" || c === "\n") { flush(); continue; }
    buf += c;
  }
  flush();
  return ev;
}

// BSWG_MODE=detect — channel-detection mode for pre-write-secret-scan.sh: emit
// the write channels present in the command (one per line, deduped), with NO
// git/tracked checks, NO path policy, and NO deny reasons. Heredoc intro lines
// count as a channel here (their bodies are the secret-scan payload) even
// though the deny path strips them. Over-detection is safe FOR THAT CONSUMER —
// it only widens what gets scanned; fd dups (2>&1, >&2, >&-) are NOT channels.
// Default mode is byte-identical.
//
// Its patterns are a TEXT matcher with no operand resolution and no quote
// awareness, so they report `redirect` for `git commit -m "fix: A -> B"` and `tee`
// for a commit message containing that word; a second pass reads each command's
// program word through commandWords, after the shell's quote removal. Any
// consumer that DENIES on a hit refuses those.
//
// TWO consumers, and only one of them scans:
//   - pre-write-secret-scan.sh SCANS on a hit, so over-detection is safe there.
//   - detectControlMutation() below DENIES on a hit, in the
//     `refersToEnvFile && detectChannels(cmd)` conjunct. That deny is emitted
//     ahead of the config switch and every escape hatch, so it has no opt-out,
//     and it inherits this detector's false positives: a heredoc BODY that
//     merely mentions CLAUDE_ENV_FILE trips it, because that test reads the raw
//     command. Deliberately left over-detecting — for a trust boundary that is
//     the safer failure direction, and narrowing it is a separate decision.
// So widening this detector widens a deny, not just a scan. Weigh both.
//
// A third consumer wanted a deny and did NOT use this: the no-project-root
// branch of pre-bash-source-write-gate.sh uses BSWG_MODE=targets, which resolves
// operands. Keep it that way — it denies ordinary read-only commands otherwise.
function detectChannels(cmd) {
  const found = new Set();
  const collapsed = stripHeredocs(cmd)
    .replace(/>\|/g, ">")
    .replace(/(\d*)(>>?)&(?=\s*[^\s0-9&|;<>(\-])/g, "$1$2");
  const REDIR = /(\d*)>>?(?!\s*&\s*[\d-])(?!\s*['"]?\/dev\/(?:null|stdout|stderr|tty)\b)/;
  const VERB = "(^|\\s|;|\\||&|/|\\\\|\\(|`|'|\")";
  if (REDIR.test(collapsed)) found.add("redirect");
  if (new RegExp(VERB + "tee(\\.exe)?['\"]?(\\s|$)", "iu").test(cmd)) found.add("tee");
  if (new RegExp(VERB + "sed(\\.exe)?['\"]?\\s+(-\\S*\\s+)*(-[A-Za-z]*i|--i)", "iu").test(cmd)) found.add("sed -i");
  if (new RegExp(VERB + "dd(\\.exe)?['\"]?\\s+[^\\n]*of=", "iu").test(cmd)) found.add("dd of=");
  if (/(?<!<)<<(?!<)[-~]?\s*['"]?[A-Za-z_]/.test(cmd)) found.add("heredoc");
  for (const segment of readings(cmd).flat()) {
    const read = commandWords(splitRedirects(segment).words);
    const program = programName(read.word);
    const args = read.words.slice(read.index + 1).map((w) => w.value);
    if (program === "tee") found.add("tee");
    if (program === "sed" && sedInPlace(args)) found.add("sed -i");
    if (program === "dd" && args.some((a) => a.startsWith("of="))) found.add("dd of=");
  }
  return Array.from(found).join("\n");
}

const CONTROL_BINDINGS = new Set([
  "CLAUDE_ENV_FILE",
  "CLAUDE_CODE_SESSION_ID",
  "ZENSU_CLAUDE_PLUGIN_ROOT",
  "ZENSU_SESSION_KEY",
  "ZENSU_SESSION_CONTEXT",
  "ZENSU_RUNTIME_DIGEST",
  "ZENSU_PROJECT_ROOT"
]);

function bindingFromAssignment(word) {
  const m = SHELL_ASSIGNMENT.exec(word);
  return m && CONTROL_BINDINGS.has(m[1]) ? m[1] : "";
}

function foldPath(value) {
  return value.normalize("NFC").toUpperCase().toLowerCase();
}

// Git Bash and native Windows processes can spell the same absolute path in
// different namespaces. In particular, the Bash command in the hook payload
// keeps `/d/work/file`, while MSYS converts an exported CLAUDE_ENV_FILE to
// `D:\\work\\file` before launching native Node. Normalize both spellings to a
// drive-qualified, slash-separated comparison namespace. This is deliberately
// lexical: the SessionStart exporter has already canonicalized and validated
// CLAUDE_ENV_FILE, and the mutation gate must not follow an attacker-controlled
// command path through the filesystem merely to compare its spelling.
function controlPathNamespace(value) {
  if (typeof value !== "string" || !value || /[\u0000-\u001f]/.test(value)) return "";
  let normalized = value.replace(/\\/g, "/");
  normalized = normalized.replace(/^\/\/\?\/([A-Za-z]:\/)/, "$1");
  normalized = normalized.replace(/^\/([A-Za-z])(?=\/)/, "$1:");
  if (!/^[A-Za-z]:\//.test(normalized)) return foldPath(normalized);
  const drive = normalized.slice(0, 2);
  const tail = path.posix.normalize("/" + normalized.slice(3));
  return foldPath(drive + tail);
}

function commandRefersToControlPath(cmd, envFile) {
  const target = controlPathNamespace(envFile);
  if (!target) return false;

  // Normalize drive-root spellings wherever a shell token may begin. Keeping
  // token boundaries in the comparison prevents `.claude-env.backup` from
  // being mistaken for the protected file while still covering glued redirects
  // such as `>>/d/work/.claude-env` and quoted paths containing spaces.
  // Letter case and Unicode normalization are folded on every platform: macOS
  // and Windows resolve both by default, and the parser cannot know the volume
  // that holds the env file.
  const normalizedCommand = foldPath(cmd
    .replace(/\\/g, "/")
    .replace(/(^|[\s"'`=<>|&;(])\/([A-Za-z])(?=\/)/g, "$1$2:"));
  let offset = 0;
  while (offset <= normalizedCommand.length - target.length) {
    const index = normalizedCommand.indexOf(target, offset);
    if (index === -1) return false;
    const before = index === 0 ? "" : normalizedCommand[index - 1];
    const afterIndex = index + target.length;
    const after = afterIndex === normalizedCommand.length ? "" : normalizedCommand[afterIndex];
    const startsAtBoundary = !before || /[\s"'`=<>|&;(]/.test(before);
    const endsAtBoundary = !after || /[\s"'`<>|&;)]/.test(after);
    if (startsAtBoundary && endsAtBoundary) return true;
    offset = index + 1;
  }
  return false;
}

function readings(cmd) {
  const segments = lex(commandText(cmd)).filter((event) => event.t === "seg").map((event) => event.text);
  return [false, true].map((bashQuotes) => segments.map((text) => segmentWords(text, bashQuotes)));
}

function wordsReferToControlPath(cmd, envFile) {
  const target = controlPathNamespace(envFile);
  return !!target && readings(cmd).flat(2).some((w) => !w.op && controlPathNamespace(w.value) === target);
}

// Claude's host session selector and Zensu's helper-private bindings must not
// be rebound by a model-issued Bash call. Likewise, model commands may not
// write CLAUDE_ENV_FILE and poison later Bash environments. This check is
// deliberately independent of the source-write config and escape hatches.
function detectControlMutation(cmd) {
  if (!cmd) return "";
  const envFile = process.env.CLAUDE_ENV_FILE || "";
  // Keep the symbolic reference check independent from path normalization: a
  // command that writes through $CLAUDE_ENV_FILE must stay denied even if the
  // ambient value is missing, native Windows, or otherwise uncomparable.
  const refersToEnvFile = /\$\{?CLAUDE_ENV_FILE\}?/.test(cmd)
    || commandRefersToControlPath(cmd, envFile)
    || wordsReferToControlPath(cmd, envFile);
  if (refersToEnvFile && detectChannels(cmd)) {
    return "Blocked a Bash write to CLAUDE_ENV_FILE. Model commands must not alter the environment inherited by later Claude Code Bash calls.";
  }

  const found = controlFinding(cmd);
  if (!found) return "";
  if (found.kind === "unread") {
    return "Blocked a Bash command with more than " + MAX_SPLITS + " env -S split strings, which this check does not read. Write the command without nesting env -S.";
  }
  if (found.kind === "dynamic") {
    return "Blocked a Bash command that builds the name of a variable it assigns or removes at run time, which this check cannot read. Write the variable name literally.";
  }
  if (found.kind === "nameref") {
    return "Blocked a Bash nameref declaration, which this check cannot follow to the variable it names. Assign the variable by its literal name instead.";
  }
  if (found.kind === "deep") {
    return "Blocked a Bash command nested deeper than this check reads. Write the command with fewer nested substitutions.";
  }
  return found.kind === "removal"
    ? "Blocked removal of protected Session Control input " + found.name + ". Start a fresh Claude Code session instead."
    : "Blocked a Bash rebind of protected Session Control input " + found.name + ". Start a fresh Claude Code session instead.";
}

function readControlMutation(cmd) {
  for (const segment of readings(cmd).flat()) {
    const descriptor = segment.find((w) => w.fdName && CONTROL_BINDINGS.has(w.fdName));
    if (descriptor) return { kind: "rebind", name: descriptor.fdName };
    const read = commandWords(splitRedirects(segment).words);
    if (read.overflow) return { kind: "unread", name: "" };
    const set = read.leading.concat(read.ops.filter((op) => op.kind === "set"))
      .find((assignment) => CONTROL_BINDINGS.has(assignment.name));
    if (set) return { kind: "rebind", name: set.name };
    const unset = read.ops.find((op) => op.kind === "unset" && CONTROL_BINDINGS.has(op.name));
    if (unset) return { kind: "removal", name: unset.name };
    if (read.index >= read.words.length) continue;
    const cmd0 = read.word.split("/").pop();
    const args = read.words.slice(read.index + 1).map((w) => w.value);
    const found = baseControlMutation(cmd0, args, bindingFromAssignment);
    if (found) return found;
  }
  return null;
}

function wordSplitControlMutation(cmd) {
  const plainBinding = (word) => {
    const m = unquote(word).match(/^([A-Za-z_][A-Za-z0-9_]*)=/);
    return m && CONTROL_BINDINGS.has(m[1]) ? m[1] : "";
  };
  for (const event of lex(stripHeredocs(cmd), false)) {
    if (event.t !== "seg") continue;
    const toks = event.text.trim().split(/\s+/).filter(Boolean);
    let i = 0;
    let name = "";
    const assignments = () => {
      for (; i < toks.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i]); i++) {
        name = plainBinding(toks[i]);
        if (name) return true;
      }
      return false;
    };
    if (assignments()) return { kind: "rebind", name };
    while (i < toks.length && WRAP.has(programName(unquote(toks[i])))) {
      i++;
      if (assignments()) return { kind: "rebind", name };
    }
    if (i >= toks.length) continue;
    const found = baseControlMutation(unquote(toks[i]).split("/").pop(), toks.slice(i + 1).map(unquote), plainBinding);
    if (found) return found;
  }
  return null;
}

function baseControlMutation(cmd0, args, binding) {
  if (["export", "readonly", "declare", "typeset", "local"].includes(cmd0)) {
    for (const arg of args) {
      const name = binding(arg);
      if (name) return { kind: "rebind", name };
    }
    const unexports = cmd0 === "export"
      ? args.some((a) => /^-[A-Za-z]*n/.test(a))
      : args.some((a) => /^(?:\+[A-Za-z]*x|-[A-Za-z]*[aA])/.test(a));
    const name = unexports ? args.map(protectedName).find(Boolean) : "";
    if (name) return { kind: "removal", name };
  }
  if (cmd0 === "unset") {
    const name = args.map(protectedName).find(Boolean);
    if (name) return { kind: "removal", name };
  }
  if (cmd0 === "printf") {
    for (let k = 0; k < args.length; k++) {
      const name = protectedName(args[k] === "-v" ? args[k + 1] || "" : /^-v./.test(args[k]) ? args[k].slice(2) : "");
      if (name) return { kind: "rebind", name };
    }
  }
  if (cmd0 === "read") {
    const name = args.map(protectedName).find(Boolean);
    if (name) return { kind: "rebind", name };
  }
  if (["for", "select", "foreach"].includes(cmd0)) {
    for (const arg of args) {
      if (arg === "in" || arg === "do" || arg.startsWith("(")) break;
      const name = protectedName(arg);
      if (name) return { kind: "rebind", name };
    }
  }
  return null;
}

function builtinControlMutation(cmd0, args) {
  const base = baseControlMutation(cmd0, args, bindingFromAssignment);
  if (base) return base;
  if (["export", "readonly", "declare", "typeset", "local"].includes(cmd0)) {
    if (["declare", "typeset", "local"].includes(cmd0) && args.some((a) => /^-[A-Za-z]*n/.test(a))) {
      return { kind: "nameref", name: "" };
    }
    const found = args.map(subscriptFinding).find(Boolean);
    if (found) return found;
    const converts = ["declare", "typeset", "local"].includes(cmd0) && args.some((a) => /^-[A-Za-z0-9]*[TiEFluLRZ]/.test(a));
    const name = converts ? args.filter((a) => !/^[-+]/.test(a)).map(protectedName).find(Boolean) : "";
    if (name) return { kind: "rebind", name };
  }
  if (OPTION_BUILTINS.has(cmd0)) {
    let built = false;
    for (let k = 0; k < args.length && /^[-+$`]/.test(args[k]); k++) built = built || /[$`]/.test(args[k]);
    if (built && args.some((a) => protectedName(a) || protectedName(a.slice(a.indexOf("=") + 1)))) return { kind: "dynamic", name: "" };
  }
  const operands = (list, kind) => list.map((arg) => operandFinding(arg, kind)).find(Boolean) || null;
  if (cmd0 === "integer" || cmd0 === "float") {
    const found = operands(args.filter((a) => !/^[-+]/.test(a)).map((a) => a.replace(/=[\s\S]*$/, "")), "rebind");
    if (found) return found;
  }
  if (cmd0 === "unset") {
    const found = args.some((a) => /^-[A-Za-z]*m/.test(a))
      ? args.filter((a) => !/^-/.test(a)).map(patternFinding).find(Boolean)
      : operands(args, "removal");
    if (found) return found;
  }
  if (cmd0 === "test" || cmd0 === "[") {
    for (let k = 0; k + 1 < args.length; k++) {
      const found = args[k] === "-v" ? subscriptFinding(args[k + 1]) : null;
      if (found) return found;
    }
  }
  const nameOption = cmd0 === "printf" || cmd0 === "print" ? "v" : cmd0 === "wait" ? "p" : cmd0 === "read" ? "a" : cmd0 === "compgen" ? "V" : "";
  if (nameOption) {
    const option = new RegExp("^-[A-Za-z]*?" + nameOption + "([\\s\\S]*)$");
    for (let k = 0; k < args.length; k++) {
      const m = option.exec(args[k]);
      const found = m ? operandFinding(m[1] || args[k + 1] || "", cmd0 === "compgen" ? "removal" : "rebind") : null;
      if (found) return found;
    }
  }
  if (cmd0 === "set") {
    for (let k = 0; k < args.length; k++) {
      const m = /^[-+][A-Za-z]*?A([\s\S]*)$/.exec(args[k]);
      const found = m ? operandFinding(m[1] || args[k + 1] || "", "rebind") : null;
      if (found) return found;
    }
  }
  if (["read", "getopts", "mapfile", "readarray", "wait", "vared", "getln"].includes(cmd0)) {
    const found = operands(cmd0 === "read" ? args.map((a) => a.replace(/\?[\s\S]*$/, "")) : args, "rebind");
    if (found) return found;
  }
  if (["let", "repeat", "shift", "return", "break", "continue"].includes(cmd0)) {
    const found = args.map((a) => arithmeticFinding(a)).find(Boolean);
    if (found) return found;
  }
  return null;
}

function patternFinding(pattern) {
  let source = "";
  for (let k = 0; k < pattern.length; k++) {
    const c = pattern[k];
    if (c === "*") source += "[\\s\\S]*";
    else if (c === "?") source += "[\\s\\S]";
    else if (c === "(" || c === ")" || c === "|") source += c === "(" ? "(?:" : c;
    else if (c === "[") {
      const close = pattern.indexOf("]", k + 2);
      if (close === -1) return { kind: "dynamic", name: "" };
      source += "[" + pattern.slice(k + 1, close).replace(/^[!^]/, "^").replace(/\\/g, "\\\\") + "]";
      k = close;
    } else if (/[A-Za-z0-9_]/.test(c)) source += c;
    else return { kind: "dynamic", name: "" };
  }
  let matcher;
  try {
    matcher = new RegExp("^(?:" + source + ")$");
  } catch (_) {
    return { kind: "dynamic", name: "" };
  }
  const name = Array.from(CONTROL_BINDINGS).find((binding) => matcher.test(binding));
  return name ? { kind: "removal", name } : null;
}

function protectedName(arg) {
  const name = arg.replace(/\[.*$/, "");
  return CONTROL_BINDINGS.has(name) ? name : "";
}

function subscriptFinding(operand) {
  const m = /^[A-Za-z_][A-Za-z0-9_]*\[([^\]]*)\]/.exec(operand);
  return m ? arithmeticFinding(m[1]) : null;
}

function operandFinding(operand, kind) {
  const name = protectedName(operand);
  return name ? { kind, name } : subscriptFinding(operand);
}

const ARITH_OPERATOR = /\s*(?:(?:\*\*|<<|>>|&&|\|\||\^\^|[-+*/%&^|])?=(?!=)|\+\+|--)/y;

function arithmeticReference(text, k) {
  if (text[k] === "`") {
    const close = text.indexOf("`", k + 1);
    return close === -1 ? text.length : close + 1;
  }
  const open = text[k + 1];
  if (open === "{" || open === "(") {
    let depth = 0;
    for (let j = k + 1; j < text.length; j++) {
      if (text[j] === open) depth++;
      else if (text[j] === (open === "{" ? "}" : ")") && --depth === 0) return j + 1;
    }
    return text.length;
  }
  PARAMETER_REFERENCE.lastIndex = k + 1;
  const m = PARAMETER_REFERENCE.exec(text);
  return k + 1 + (m ? m[0].length : 0);
}

function arithmeticFinding(expr, depth = 0) {
  if (depth > MAX_NESTING) return { kind: "deep", name: "" };
  const text = expr.replace(/["']/g, "");
  const end = bracketPairs(text);
  for (let k = 0; k < text.length;) {
    const start = k;
    let name = "";
    if (/[A-Za-z_]/.test(text[k]) && !/[A-Za-z0-9_$]/.test(text[k - 1] || "")) {
      while (k < text.length && /[A-Za-z0-9_]/.test(text[k])) k++;
      name = text.slice(start, k);
    } else if (text[k] === "$" || text[k] === "`") {
      k = arithmeticReference(text, k);
    } else {
      k++;
      continue;
    }
    let open = k;
    while (/\s/.test(text[open] || "")) open++;
    const close = text[open] === "[" ? end(open) : k;
    let before = start - 1;
    while (before > 0 && /\s/.test(text[before])) before--;
    ARITH_OPERATOR.lastIndex = close;
    if (ARITH_OPERATOR.test(text) || (before > 0 && /^(?:\+\+|--)$/.test(text.slice(before - 1, before + 1)))) {
      if (!name) return { kind: "dynamic", name: "" };
      if (CONTROL_BINDINGS.has(name)) return { kind: "rebind", name };
    }
    const inner = close > k ? arithmeticFinding(text.slice(open + 1, Math.max(open + 1, close - 1)), depth + 1) : null;
    if (inner) return inner;
    k = close;
  }
  return null;
}

const MAX_NESTING = 64;
const PAREN_HEADS = new Set("! if then else elif do while until for time coproc".split(" "));
const COPROC_BODIES = new Set("case if while until for select".split(" "));
const OPTION_BUILTINS = new Set("export readonly declare typeset local printf print wait set compgen read".split(" "));
const PARAMETER_REFERENCE = /[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]/y;
const DECLARATION_WORDS = new Set("export readonly declare typeset local integer float".split(" "));

function cooked(text) {
  return text.replace(/\\([\s\S])/g, (pair, c) => (c === "\n" ? "" : pair));
}

function bracketEnd(text, start) {
  let depth = 0;
  for (let k = start; k < text.length; k++) {
    const c = text[k];
    if (c === "\\") {
      k++;
    } else if (c === "'" || c === "\"") {
      const close = text.indexOf(c, k + 1);
      if (close === -1) return text.length;
      k = close;
    } else if (c === "[") {
      depth++;
    } else if (c === "]" && --depth === 0) {
      return k + 1;
    }
  }
  return text.length;
}

function bracketPairs(text) {
  const pairs = new Map();
  const open = [];
  for (let k = 0; k < text.length; k++) {
    const c = text[k];
    if (c === "\\") {
      k++;
    } else if (c === "'" || c === "\"") {
      const close = text.indexOf(c, k + 1);
      if (close === -1) break;
      k = close;
    } else if (c === "[") {
      open.push(k);
    } else if (c === "]" && open.length) {
      pairs.set(open.pop(), k + 1);
    }
  }
  return (k) => pairs.get(k) || text.length;
}

function zshFlagsEnd(body) {
  const pairs = { "(": ")", "[": "]", "{": "}", "<": ">" };
  for (let k = 1; k < body.length; k++) {
    if (body[k] === ")") return k;
    if ("jlrsZ_Ig".indexOf(body[k]) === -1 || k + 1 >= body.length || /[A-Za-z0-9)]/.test(body[k + 1])) continue;
    const open = body[k + 1];
    const close = pairs[open] || open;
    k++;
    while (body[k] === open) {
      const end = body.indexOf(close, k + 1);
      if (end === -1) return -1;
      k = end + 1;
    }
    k--;
  }
  return -1;
}

function parameterFinding(body) {
  let k = 0;
  let flags = "";
  if (body[0] === "(") {
    const close = zshFlagsEnd(body);
    if (close === -1) return arithmeticFinding(body);
    flags = body.slice(1, close);
    k = close + 1;
  }
  const m = /^([#!^=~+]*)([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])/.exec(body.slice(k));
  if (!m) return /^[$`"]/.test(body.slice(k)) ? null : arithmeticFinding(body);
  let end = k + m[0].length;
  let subscript = "";
  if (body[end] === "[") {
    const close = bracketEnd(body, end);
    subscript = body.slice(end + 1, Math.max(end + 1, close - 1));
    end = close;
  }
  const rest = body.slice(end);
  if (/^:{0,2}=/.test(rest)) {
    if (flags.indexOf("P") !== -1 || m[1].indexOf("!") !== -1) return { kind: "dynamic", name: "" };
    if (CONTROL_BINDINGS.has(m[2])) return { kind: "rebind", name: m[2] };
  }
  const offset = /^:(?![-=?+:#%/^,~])/.test(rest) ? rest.slice(1) : "";
  return (subscript ? arithmeticFinding(subscript) : null) || (offset ? arithmeticFinding(offset) : null);
}

function arrayFinding(literal) {
  const end = bracketPairs(literal);
  for (let k = 0; k < literal.length; k++) {
    if (literal[k] !== "[" || (k > 0 && !/\s/.test(literal[k - 1]))) continue;
    const close = end(k);
    const found = literal[close] === "=" || literal.startsWith("+=", close)
      ? arithmeticFinding(literal.slice(k + 1, Math.max(k + 1, close - 1)))
      : null;
    if (found) return found;
    k = Math.max(k, close - 1);
  }
  return null;
}

function conditionalFinding(tokens) {
  for (let k = 0; k < tokens.length; k++) {
    const raw = tokens[k].raw;
    const found = /^-(?:eq|ne|lt|le|gt|ge)$/.test(raw)
      ? arithmeticFinding(k > 0 ? tokens[k - 1].value : "") || arithmeticFinding(k + 1 < tokens.length ? tokens[k + 1].value : "")
      : raw === "-v" && k + 1 < tokens.length ? subscriptFinding(tokens[k + 1].value) : null;
    if (found) return found;
  }
  return null;
}

function commandFinding(words) {
  if (!words.length) return null;
  const read = commandWords(words);
  if (read.overflow) return { kind: "unread", name: "" };
  if (read.dynamic) return { kind: "dynamic", name: "" };
  const set = read.leading.concat(read.ops.filter((op) => op.kind === "set"))
    .find((assignment) => CONTROL_BINDINGS.has(assignment.name));
  if (set) return { kind: "rebind", name: set.name };
  const indexed = read.leading.map((assignment) => arithmeticFinding(assignment.subscript)).find(Boolean);
  if (indexed) return indexed;
  const unset = read.ops.find((op) => op.kind === "unset" && CONTROL_BINDINGS.has(op.name));
  if (unset) return { kind: "removal", name: unset.name };
  if (read.index >= read.words.length) return null;
  const cmd0 = read.word.split("/").pop();
  if (cmd0 === "coproc") {
    const rest = read.words.slice(read.index + 1);
    const name = rest.length ? protectedName(rest[0].value) : "";
    return name ? { kind: "rebind", name } : commandFinding(rest);
  }
  return builtinControlMutation(cmd0, read.words.slice(read.index + 1).map((w) => w.value));
}

function shellFinding(source, bashQuotes) {
  const deep = { kind: "deep", name: "" };
  const limit = 32 * source.length + 65536;
  let steps = 0;
  const spent = (n) => (steps += n) > limit;

  function part(text, k, depth) {
    const c = text[k];
    const next = text[k + 1];
    if (c === "\\") return { end: k + 2, value: next === undefined ? "" : next, found: null };
    if (c === "'") {
      const close = text.indexOf("'", k + 1);
      const end = close === -1 ? text.length : close;
      return { end: Math.min(end + 1, text.length), value: text.slice(k + 1, end), found: null };
    }
    if (c === "$" && next === "'") {
      const decoded = ansiC(text, k + 2);
      return { end: Math.min(decoded.end + 1, text.length), value: decoded.value, found: null };
    }
    if (c === "\"" || (c === "$" && next === "\"")) return double(text, k + (c === "$" ? 2 : 1), depth);
    if (c === "$" || c === "`") {
      const read = c === "$" ? dollar(text, k, false, depth) : backtick(text, k, false, depth);
      return { end: read.end, value: text.slice(k, read.end), found: read.found };
    }
    return { end: k + 1, value: c, found: null };
  }

  function double(text, start, depth) {
    let value = "";
    let k = start;
    while (k < text.length && text[k] !== "\"") {
      if (spent(1)) return { end: text.length, value, found: deep };
      const c = text[k];
      if (c === "\\") {
        const next = text[k + 1];
        if (next !== "\n") value += next !== undefined && "$`\"\\".indexOf(next) !== -1 ? next : c + (next || "");
        k += 2;
      } else if (c === "$" || c === "`") {
        const read = c === "$" ? dollar(text, k, true, depth) : backtick(text, k, true, depth);
        if (read.found) return { end: text.length, value, found: read.found };
        value += text.slice(k, read.end);
        k = read.end;
      } else {
        value += c;
        k++;
      }
    }
    return { end: Math.min(k + 1, text.length), value, found: null };
  }

  function dollar(text, k, quoted, depth) {
    const next = text[k + 1];
    if (next === "(" && text[k + 2] === "(") {
      const read = arithmetic(text, k + 3, quoted, depth + 1);
      if (read) return read;
    }
    if (next === "(") {
      const read = commands(text, k + 2, ")", depth + 1);
      return { end: Math.min(read.end + 1, text.length), found: read.found };
    }
    if (next === "{" && /[\s|]/.test(text[k + 2] || "")) {
      const read = commands(text, k + (text[k + 2] === "|" ? 3 : 2), "}", depth + 1);
      return { end: Math.min(read.end + 1, text.length), found: read.found };
    }
    if (next === "{") {
      const end = braceEnd(text, k, quoted, bashQuotes);
      if (spent(end - k)) return { end: text.length, found: deep };
      const body = text.slice(k + 2, text[end - 1] === "}" ? end - 1 : end);
      return { end, found: parameterFinding(cooked(body)) || expansions(body, depth + 1) };
    }
    if (next === "[") {
      const close = bracketEnd(text, k + 1);
      if (spent(close - k)) return { end: text.length, found: deep };
      const inner = text.slice(k + 2, Math.max(k + 2, close - 1));
      return { end: close, found: arithmeticFinding(cooked(inner)) || expansions(inner, depth + 1) };
    }
    PARAMETER_REFERENCE.lastIndex = k + 1;
    const m = PARAMETER_REFERENCE.exec(text);
    const end = k + 1 + (m ? m[0].length : 0);
    if (!m || text[end] !== "[") return { end, found: null };
    const close = bracketEnd(text, end);
    if (spent(close - end)) return { end: text.length, found: deep };
    const inner = text.slice(end + 1, Math.max(end + 1, close - 1));
    return { end, found: text[close - 1] === "]" ? arithmeticFinding(cooked(inner)) : null };
  }

  function arithmetic(text, start, quoted, depth) {
    if (depth > MAX_NESTING) return { end: text.length, found: deep };
    let level = 0;
    let found = null;
    for (let k = start; k < text.length;) {
      if (spent(1)) return { end: text.length, found: deep };
      const c = text[k];
      if (c === "\\") {
        k += 2;
      } else if (c === "'") {
        const close = text.indexOf("'", k + 1);
        k = close === -1 ? text.length : close + 1;
      } else if (c === "\"" || c === "$" || c === "`") {
        const read = c === "\"" ? double(text, k + 1, depth) : c === "$" ? dollar(text, k, quoted, depth) : backtick(text, k, quoted, depth);
        found = found || read.found;
        k = read.end;
      } else if (c === "(") {
        level++;
        k++;
      } else if (c !== ")") {
        k++;
      } else if (level > 0) {
        level--;
        k++;
      } else {
        return text[k + 1] === ")" ? { end: k + 2, found: found || arithmeticFinding(cooked(text.slice(start, k))) } : null;
      }
    }
    return null;
  }

  function backtick(text, k, quoted, depth) {
    let end = k + 1;
    while (end < text.length && text[end] !== "`") end += text[end] === "\\" ? 2 : 1;
    end = Math.min(end, text.length);
    if (spent(end - k)) return { end: text.length, found: deep };
    const inner = text.slice(k + 1, end).replace(quoted ? /\\([$`\\"])/g : /\\([$`\\])/g, "$1");
    return { end: Math.min(end + 1, text.length), found: commands(inner, 0, "", depth + 1).found };
  }

  function expansions(text, depth) {
    if (depth > MAX_NESTING) return deep;
    for (let k = 0; k < text.length;) {
      if (spent(1)) return deep;
      const c = text[k];
      if (c === "\\") {
        k += 2;
      } else if (c === "$" || c === "`") {
        const read = c === "$" ? dollar(text, k, true, depth) : backtick(text, k, true, depth);
        if (read.found) return read.found;
        k = read.end;
      } else {
        k++;
      }
    }
    return null;
  }

  function bodies(text, start, docs, depth) {
    let k = start;
    for (const doc of docs) {
      let line = k;
      while (line < text.length) {
        const stop = text.indexOf("\n", line);
        const end = stop === -1 ? text.length : stop;
        const raw = text.slice(line, end);
        if ((doc.tabs ? raw.replace(/^\t+/, "") : raw) === doc.delim) break;
        line = end + 1;
      }
      if (spent(Math.min(line, text.length) - k)) return { end: text.length, found: deep };
      const found = doc.quoted ? null : expansions(cooked(text.slice(k, Math.min(line, text.length))), depth + 1);
      if (found) return { end: text.length, found };
      if (line >= text.length) return { end: text.length, found: null };
      const stop = text.indexOf("\n", line);
      k = stop === -1 ? text.length : stop + 1;
    }
    return { end: k, found: null };
  }

  function parenWord(text, start, depth, comments) {
    let level = 0;
    let kept = "";
    for (let k = start; k < text.length;) {
      if (spent(1)) return { end: text.length, found: deep, kept };
      const c = text[k];
      if (comments && c === "#" && /[\s(]/.test(text[k - 1])) {
        const stop = text.indexOf("\n", k);
        k = stop === -1 ? text.length : stop;
      } else if (c === "(" || c === ")") {
        level += c === "(" ? 1 : -1;
        k++;
        if (level === 0) return { end: k, found: null, kept };
        kept += c;
      } else if ("\\'\"$`".indexOf(c) !== -1) {
        const read = part(text, k, depth);
        if (read.found) return { end: text.length, found: read.found, kept };
        kept += text.slice(k, read.end);
        k = read.end;
      } else {
        kept += c;
        k++;
      }
    }
    return { end: text.length, found: null, kept };
  }

  function conditional(text, start, depth) {
    if (depth > MAX_NESTING) return { end: text.length, found: deep };
    const tokens = [];
    let word = null;
    let fallback = null;
    let newline = -1;
    for (let k = start; k < text.length;) {
      if (spent(1)) return { end: text.length, found: deep };
      const c = text[k];
      if (c === "\\" && text[k + 1] === "\n") {
        k += 2;
        continue;
      }
      if (c === "#" && !word) {
        const stop = text.indexOf("\n", k);
        k = stop === -1 ? text.length : stop;
        continue;
      }
      const regex = tokens.length > 0 && tokens[tokens.length - 1].raw === "=~";
      if (c === "(" && (word ? regex || /[@!+*?]$/.test(text.slice(word.start, k)) : regex)) {
        if (!word) word = { start: k, value: "" };
        const read = parenWord(text, k, depth);
        if (read.found) return { end: text.length, found: read.found };
        word.value += text.slice(k, read.end);
        k = read.end;
        continue;
      }
      if (c === "|" && word && regex) {
        word.value += c;
        k++;
        continue;
      }
      if (/\s/.test(c) || "()<>;&|".indexOf(c) !== -1) {
        if (word) tokens.push({ raw: text.slice(word.start, k), value: word.value });
        word = null;
        if (tokens.length && tokens[tokens.length - 1].raw === "]]") return { end: k, found: conditionalFinding(tokens), broken: fallback ? fallback.end : -1 };
        if (/\s/.test(c)) {
          if (c === "\n" && newline === -1) newline = k;
          k++;
        } else if ((c === "&" || c === "|") && text[k + 1] === c) {
          tokens.push({ raw: c + c, value: c + c });
          k += 2;
        } else {
          if ("()<>".indexOf(c) === -1 && !fallback) fallback = { end: k, tokens: tokens.slice() };
          tokens.push({ raw: c, value: c });
          k++;
        }
        continue;
      }
      if (!word) word = { start: k, value: "" };
      const read = part(text, k, depth);
      if (read.found) return { end: text.length, found: read.found };
      word.value += read.value;
      k = read.end;
    }
    if (word) tokens.push({ raw: text.slice(word.start), value: word.value });
    if (tokens.length && tokens[tokens.length - 1].raw === "]]") return { end: text.length, found: conditionalFinding(tokens), broken: fallback ? fallback.end : -1 };
    if (fallback) return { end: fallback.end, found: conditionalFinding(fallback.tokens), broken: -1 };
    return { end: text.length, found: conditionalFinding(tokens), broken: newline };
  }

  function commands(text, start, closer, depth) {
    if (depth > MAX_NESTING) return { end: text.length, found: deep };
    const stack = [];
    let words = [];
    let word = null;
    let target = false;
    let piped = false;
    let redirected = false;
    let held = null;
    let docs = [];
    const top = () => stack[stack.length - 1];
    const inCase = (state) => top() !== undefined && top().kind === "case" && top().state === state;
    const commandStart = () => {
      let k = 0;
      let timed = piped;
      for (;;) {
        while (k < words.length && RESERVED_WORDS.has(words[k].raw)) k++;
        if (k < words.length && words[k].raw === "coproc") {
          k++;
          timed = true;
          continue;
        }
        if (!timed && k < words.length && words[k].raw === "time") {
          k++;
          timed = true;
          if (k < words.length && words[k].raw === "-p") k++;
          if (k < words.length && words[k].raw === "--") k++;
          continue;
        }
        return k;
      }
    };
    const atCommand = () => !(redirected && bashQuotes) && commandStart() === words.length;
    const assignPos = () => {
      for (let k = commandStart(); k < words.length; k++) {
        if (!SHELL_ASSIGNMENT.test(words[k].raw)) return DECLARATION_WORDS.has(words[k].value);
      }
      return true;
    };
    const coprocName = () => words.length >= 2 && words[words.length - 2].raw === "coproc"
      && commandStart() === words.length - 1 && /^[A-Za-z_][A-Za-z0-9_]*$/.test(words[words.length - 1].raw);
    const closeWord = (to) => {
      if (!word) return;
      const w = { raw: text.slice(word.start, to), value: word.value };
      word = null;
      if (target) {
        target = false;
        return;
      }
      if (inCase("pattern")) {
        const alternative = top().alternative;
        top().alternative = false;
        if (w.raw === "esac" && !alternative) stack.pop();
        return;
      }
      if (atCommand() && w.raw === "esac" && inCase("body")) {
        stack.pop();
        return;
      }
      if (coprocName() && COPROC_BODIES.has(w.raw)) {
        const name = words[words.length - 1].raw;
        if (CONTROL_BINDINGS.has(name)) held = { kind: "rebind", name };
        words = [];
      }
      if (atCommand() && w.raw === "case") stack.push({ kind: "case", state: "head" });
      words.push(w);
      if (inCase("head") && words.length >= 3 && w.raw === "in") {
        top().state = "pattern";
        words = [];
      }
      if (words.length === 2 && words[0].raw === "function") words = [];
    };
    const finish = (to) => {
      closeWord(to);
      target = false;
      redirected = false;
      if (inCase("head")) return null;
      const found = commandFinding(words);
      words = [];
      return found;
    };
    let i = start;
    while (i < text.length) {
      if (held) return { end: text.length, found: held };
      if (spent(1)) return { end: text.length, found: deep };
      const c = text[i];
      const next = text[i + 1];
      if (c === "\\" && next === "\n") {
        i += 2;
        continue;
      }
      if (c === " " || c === "\t") {
        closeWord(i);
        i++;
        continue;
      }
      if (c === "#" && !word) {
        const stop = text.indexOf("\n", i);
        i = stop === -1 ? text.length : stop;
        continue;
      }
      if (!word && (c === "{" || c === "}") && !inCase("pattern") && (i + 1 >= text.length || /[\s;&|()<>]/.test(next))) {
        if (c === "{" && (atCommand() || coprocName())) {
          const found = atCommand() ? null : finish(i);
          if (found) return { end: text.length, found };
          stack.push({ kind: "group" });
          piped = false;
          words.push({ raw: c, value: c });
          i++;
          continue;
        }
        if (c === "}" && atCommand() && top() && top().kind === "group") {
          stack.pop();
          words.push({ raw: c, value: c });
          i++;
          continue;
        }
        if (c === "}" && atCommand() && closer === "}") return { end: i, found: finish(i) || held };
      }
      if (c === "[" && next === "[" && !word && !inCase("pattern") && (atCommand() || coprocName()) && /\s/.test(text[i + 2] || "")) {
        const read = conditional(text, i + 2, depth + 1);
        if (read.found) return { end: text.length, found: read.found };
        const prior = (read.broken === -1 ? null : commands(text, read.broken, closer, depth + 1).found) || commandFinding(words);
        if (prior) return { end: text.length, found: prior };
        words = [];
        i = read.end;
        continue;
      }
      if (c === "(" && !word) {
        if (inCase("pattern")) {
          top().alternative = true;
          i++;
          continue;
        }
        const read = next === "(" ? arithmetic(text, i + 2, false, depth + 1) : null;
        if (read && read.found) return { end: text.length, found: read.found };
        if (read) {
          i = read.end;
          continue;
        }
        if (!atCommand()) {
          let j = i + 1;
          while (text[j] === " " || text[j] === "\t") j++;
          if (text[j] === ")") {
            words = [];
            i = j + 1;
            continue;
          }
        }
        const found = finish(i);
        if (found) return { end: text.length, found };
        stack.push({ kind: "paren" });
        piped = false;
        i++;
        continue;
      }
      if (c === ")") {
        closeWord(i);
        if (inCase("pattern")) {
          top().state = "body";
          words = [];
          piped = false;
          i++;
          continue;
        }
        let at = stack.length - 1;
        while (at >= 0 && stack[at].kind !== "paren") at--;
        const paren = at >= 0;
        if (paren) stack.length = at;
        const found = finish(i);
        if (!paren && closer === ")") return { end: i, found: found || held };
        if (found) return { end: text.length, found };
        i++;
        continue;
      }
      if ((c === "<" || c === ">") && next === "(") {
        const read = commands(text, i + 2, ")", depth + 1);
        if (read.found) return { end: text.length, found: read.found };
        if (!word) word = { start: i, value: "" };
        word.value += text.slice(i, Math.min(read.end + 1, text.length));
        i = Math.min(read.end + 1, text.length);
        continue;
      }
      if (c === "<" || c === ">" || (c === "&" && next === ">")) {
        if (word) {
          const prefix = text.slice(word.start, i);
          const fd = /^\{([A-Za-z_][A-Za-z0-9_]*)\}$/.exec(prefix);
          if (fd && CONTROL_BINDINGS.has(fd[1])) return { end: text.length, found: { kind: "rebind", name: fd[1] } };
          if (fd || /^\d+$/.test(prefix)) word = null;
          else closeWord(i);
        }
        if (commandStart() === words.length) redirected = true;
        const op = redirectOperator(text, i);
        i += op.length;
        if (op === "<<" || op === "<<-") {
          let j = i;
          while (text[j] === " " || text[j] === "\t") j++;
          const doc = heredocWord(text, j);
          if (doc.end > j) docs.push({ delim: doc.value, tabs: op === "<<-", quoted: doc.quoted });
          i = Math.max(doc.end, j);
        } else {
          target = true;
        }
        continue;
      }
      if (c === ";" || c === "&" || c === "|" || c === "\n") {
        if ((c === "|" && next !== "|" && inCase("pattern")) || (c === "\n" && inCase("head"))) {
          closeWord(i);
          if (c === "|" && inCase("pattern")) top().alternative = true;
          i++;
          continue;
        }
        if (c !== "\n" && inCase("head")) stack.pop();
        const found = finish(i);
        if (found) return { end: text.length, found };
        piped = c === "|" && next !== "|";
        if (c === ";" && (next === ";" || next === "&")) {
          i += next === ";" && text[i + 2] === "&" ? 3 : 2;
          let at = stack.length - 1;
          while (at >= 0 && stack[at].kind !== "case") at--;
          if (at >= 0) {
            stack.length = at + 1;
            Object.assign(top(), { state: "pattern", alternative: false });
          }
          continue;
        }
        if ((c === "&" && next === "&") || (c === "|" && (next === "|" || next === "&"))) {
          i += 2;
          continue;
        }
        i++;
        if (c === "\n" && docs.length) {
          const read = bodies(text, i, docs, depth);
          docs = [];
          if (read.found) return { end: text.length, found: read.found };
          i = read.end;
        }
        continue;
      }
      if (c === "(" && word) {
        const prefix = text.slice(word.start, i);
        const coprocHead = words.length > 0 && words[words.length - 1].raw === "coproc" && atCommand() && /^[A-Za-z_][A-Za-z0-9_]*$/.test(prefix);
        if (word.value === prefix && !inCase("pattern") && ((atCommand() && PAREN_HEADS.has(prefix)) || (prefix === "in" && inCase("head")) || coprocHead)) {
          closeWord(i);
          continue;
        }
        let j = i + 1;
        while (text[j] === " " || text[j] === "\t") j++;
        if (text[j] === ")" && prefix.indexOf("=") === -1 && (atCommand() || (words.length === 1 && words[0].raw === "function"))) {
          word = null;
          words = [];
          i = j + 1;
          continue;
        }
        const literal = /^[A-Za-z_][A-Za-z0-9_]*\+?=$/.test(prefix);
        const read = prefix === "=" ? commands(text, i + 1, ")", depth + 1) : parenWord(text, i, depth, literal);
        if (read.found) return { end: text.length, found: read.found };
        const end = prefix === "=" ? Math.min(read.end + 1, text.length) : read.end;
        const found = literal ? arrayFinding(cooked(read.kept.slice(1))) : null;
        if (found) return { end: text.length, found };
        word.value += text.slice(i, end);
        i = end;
        continue;
      }
      if (c === "[" && word && /^[A-Za-z_][A-Za-z0-9_]*$/.test(text.slice(word.start, i)) && assignPos()) {
        const close = bracketEnd(text, i);
        if (spent(close - i)) return { end: text.length, found: deep };
        if (text[close] === "=" || text.startsWith("+=", close)) {
          const name = text.slice(word.start, i);
          const inner = text.slice(i + 1, Math.max(i + 1, close - 1));
          const found = CONTROL_BINDINGS.has(name) ? { kind: "rebind", name } : arithmeticFinding(cooked(inner)) || expansions(inner, depth + 1);
          if (found) return { end: text.length, found };
          word.value += text.slice(i, close);
          i = close;
          continue;
        }
      }
      if (!word) word = { start: i, value: "" };
      const read = part(text, i, depth);
      if (read.found) return { end: text.length, found: read.found };
      word.value += read.value;
      i = read.end;
    }
    const found = finish(text.length);
    return { end: text.length, found: held || found };
  }

  return commands(source, 0, "", 0).found;
}

function shellControlMutation(cmd) {
  const found = shellFinding(cmd, false) || shellFinding(cmd, true);
  if (found || cmd.indexOf("\\\n") === -1) return found;
  const joined = joinedText(cmd);
  return shellFinding(joined, false) || shellFinding(joined, true);
}

function controlFinding(cmd) {
  return readControlMutation(cmd) || wordSplitControlMutation(cmd) || shellControlMutation(cmd);
}

const POWERSHELL_CONTROL_MAIN =
  "This check keeps model commands from rebinding Claude Code's Session Control inputs and from writing " +
  "the file behind CLAUDE_ENV_FILE, and it refuses a PowerShell command it cannot rule out doing either. " +
  "Rewrite the command without that construct, or run it through the Bash tool; a rebind is refused there as well.";
const POWERSHELL_CONTROL_CHILD =
  "This check keeps model commands from rebinding Claude Code's Session Control inputs and from writing " +
  "the file behind CLAUDE_ENV_FILE, and it refuses a PowerShell command it cannot rule out doing either. " +
  "Do not retry it; report the need to the main thread instead.";

const POWERSHELL_UNLOADED =
  "the PowerShell analyzer hooks/lib/powershell-command-v1.js could not be loaded";

function powershellUnloadedVerdict(mode, child) {
  if (mode === "control") {
    return "Blocked a PowerShell command because " + POWERSHELL_UNLOADED + ", so this check cannot rule out that " +
      "the command rebinds a Session Control input. " +
      (child ? "Do not retry it; report the need to the main thread instead."
        : "Run the command through the Bash tool, and reinstall the plugin to restore the check.");
  }
  if (mode === "targets") return "WRITE-TARGET (unevaluated: " + POWERSHELL_UNLOADED + ")";
  return "Blocked a PowerShell command because " + POWERSHELL_UNLOADED + ". " +
    "Run it through the Bash tool, or change files with Edit or Write, and reinstall the plugin." + OPT_IN_NOTE;
}

function powershellVerdict(cmd, mode, child) {
  let powershell = null;
  try {
    powershell = require("./powershell-command-v1.js");
  } catch (_error) {
    return powershellUnloadedVerdict(mode, child);
  }
  if (mode === "control") {
    const envFile = process.env.CLAUDE_ENV_FILE || "";
    const reason = powershell.controlVerdict(cmd, {
      names: Array.from(CONTROL_BINDINGS),
      refersToEnvFile: (text) => commandRefersToControlPath(text, envFile)
    });
    if (!reason) return "";
    return "Blocked a PowerShell command because " + reason + ". " +
      (child ? POWERSHELL_CONTROL_CHILD : POWERSHELL_CONTROL_MAIN);
  }
  const verdict = powershell.readOnlyVerdict(cmd);
  if (verdict.readOnly) return "";
  if (mode === "targets") {
    return "WRITE-TARGET (unevaluated: a PowerShell command this check cannot prove read-only, because " + verdict.reason + "; run a read-only command through the Bash tool)";
  }
  return "Blocked a PowerShell command that the source-write rules cannot judge, because " + verdict.reason + ". " +
    "Rules (A), (B) and (C) read Bash commands only, so a PowerShell command passes this gate only when it is " +
    "provably read-only. Run it through the Bash tool, or change files with Edit or Write." + OPT_IN_NOTE;
}

function payloadFields(raw) {
  try {
    const j = JSON.parse(raw || "{}");
    return {
      cmd: j.tool_input && typeof j.tool_input.command === "string" ? j.tool_input.command : "",
      cwd0: typeof j.cwd === "string" ? j.cwd : "",
      tool: typeof j.tool_name === "string" ? j.tool_name : "",
      child: [j.agent_id, j.agent_type].some((v) => typeof v === "string" && v !== "")
    };
  } catch (e) {
    return null;
  }
}

function controlVerdict(raw) {
  const fields = payloadFields(raw);
  if (!fields || !fields.cmd) return "";
  if (fields.tool === "PowerShell") return powershellVerdict(fields.cmd, "control", fields.child);
  return detectControlMutation(fields.cmd);
}

function main() {
  let cmd = "";
  let cwd0 = "";
  // PAYLOAD wins when non-empty, stdin otherwise. Every call site in the hook
  // pins `PAYLOAD=` explicitly so the stdin path is the one that runs — an
  // ambient PAYLOAD must never be parsed in place of the real payload, and
  // handing a ~1MB heredoc through the environment risks E2BIG, which with the
  // caller's fail-closed exit would turn the largest legitimate writes into a
  // permanent deny. Same reason hooks/lib/secret-scan-decide.js reads stdin.
  // The env branch remains for tests/structure/test-secret-scan-gate.sh, whose
  // detect() helper supplies the payload with no stdin redirect.
  let raw = process.env.PAYLOAD;
  if (raw === undefined || raw === "") {
    try { raw = fs.readFileSync(0, "utf8"); } catch (e) { raw = ""; }
  }
  const fields = payloadFields(raw);
  if (!fields) return "";
  cmd = fields.cmd;
  cwd0 = fields.cwd0;
  const tool = fields.tool;
  const child = fields.child;
  if (!cmd) return "";
  if (process.env.BSWG_MODE === "detect") return detectChannels(cmd);
  if (tool === "PowerShell") return powershellVerdict(cmd, process.env.BSWG_MODE || "", child);
  if (process.env.BSWG_MODE === "control") return detectControlMutation(cmd);
  // `targets` runs the FULL default parse and diverges at exactly TWO points —
  // check both when changing either:
  //   1. decide() reports the resolved write operand instead of judging it
  //      against a project root (the two rules that need a root are skipped).
  //   2. the MAX_TARGETS guard fails CLOSED with a synthetic unevaluated
  //      answer, where the anchored path fails open.
  // The inline ZENSU_BASH_WRITE_GATE=off / ZENSU_MCP_GATE=off escapes surface
  // as __bypass__ markers on every path EXCEPT that budget-exhaustion return,
  // which drops any accumulated markers by design. Reachable shape: an escape
  // in one segment plus more than MAX_TARGETS operands in a later one — targets
  // mode denies it, the anchored path allows and ledgers it. Deliberate: this
  // caller has no project root, so fail-closed is the only safe direction.
  const targetsOnly = process.env.BSWG_MODE === "targets";
  const reanchorHint = process.env.BSWG_REANCHOR === "1"
    ? " If this session now works for good in the worktree this command targets, /zensu:adopt-session --reanchor, run from inside it, " +
      "reports whether this session's anchor can move there; it refuses a worktree in which it finds another live session."
    : "";

  const HOME = process.env.HOME || "";
  // The comparison namespace. The hook hands over a project root it already
  // canonicalized (`realpathSync.native` when bound, `cd -P && pwd -P` when not)
  // while the payload cwd arrives exactly as the host spelled it, so the two can
  // sit in different namespaces — on macOS a `/var/folders/...` cwd against a
  // `/private/var/folders/...` root. Lexically those never overlap, so `within`
  // reports an escape for a directory that IS the project: rule (B) then denies
  // every new-file write and rule (C) every git verb in the user's own tree.
  // Canonicalizing all three inputs once here is what keeps them comparable.
  // The payload cwd is host-supplied metadata, not a model-issued token, so
  // resolving it does not weaken the lexical rule that governs command tokens.
  function canonical(p) {
    const abs = stripSlash(path.resolve(msysToDrive(p, IS_WINDOWS)));
    try {
      return stripSlash(fs.realpathSync.native(abs));
    } catch (e) {
      return abs;
    }
  }
  // The payload cwd must never become the project authority — a drifted checkout
  // would then be its own root and rules (B)/(C) would pass everything. The hook
  // refuses this state in both branches; enforce it here too so the invariant
  // holds for every caller, not only by convention.
  //
  // EXCEPT in targets mode, whose entire contract IS the no-project-root branch:
  // there the root is never used as a BOUNDARY — that is the pair of rules
  // decide() skips. It does remain the cwd fallback for operand resolution, so
  // it still affects the temp-root filter and the path reported back, and the
  // extension check that gates every operand is basename-only. Requiring an
  // anchor here would put the diagnostic back behind the very defect it reports.
  if (!targetsOnly && !process.env.CLAUDE_PROJECT_DIR) {
    process.exitCode = 1;
    return "";
  }
  const projectRoot = canonical(process.env.CLAUDE_PROJECT_DIR || cwd0 || process.cwd());
  let curdir = cwd0 ? canonical(cwd0) : projectRoot;

  // Temp roots are exempt from the (B) escape rule. ZENSU_BSWGATE_TEMP_DIRS (a
  // colon-separated list) overrides the default set when present — an advanced
  // customization seam, also used by the test harness for deterministic paths.
  const tempOverride = process.env.ZENSU_BSWGATE_TEMP_DIRS;
  const TEMP = (tempOverride !== undefined
    ? splitTempList(tempOverride, IS_WINDOWS)
    : [process.env.TMPDIR || "", "/tmp", "/private/tmp", "/var/folders"]
  )
    .filter(Boolean)
    // Judge the RAW entry as well as the resolved one: neither stage sees every
    // unsafe spelling. `path.resolve` fully qualifies its output, so a
    // drive-relative `C:` would reach the second filter already turned into
    // whatever that drive's current directory is and pass as an ordinary path —
    // that arm can fire only here. A RELATIVE entry such as `..` is the opposite:
    // it becomes a root only after resolving, so it can be caught only below. A
    // drive root spelled `/c` becomes `C:/` here and is caught at either stage.
    // Both spellings became reachable once msysToDrive started normalizing them,
    // so both guards travel with it.
    .filter((p) => !isUnsafeTempEntry(msysToDrive(p, IS_WINDOWS), path))
    .map((p) => stripSlash(path.resolve(msysToDrive(p, IS_WINDOWS))))
    .filter((t) => !isUnsafeTempEntry(t, path));
  // A temp root that CONTAINS the project would exempt the project itself and
  // switch all three rules off — with no bypass-ledger entry, unlike the
  // documented escape hatches. `/` as an entry is the degenerate case.
  const TEMP_SAFE = () => TEMP.filter((t) => !within(t, projectRoot));
  // The canonical spellings are computed ONCE, on the first isTemp call the raw
  // list does not satisfy — which in practice means the first in-project
  // candidate, since those are under no temp root either. Replacing the raw list
  // instead of extending it would break the documented `/tmp` carve-out wherever
  // `/tmp` is a symlink into `/private`.
  let TEMP_REAL = null;

  function expand(p) {
    if (p === "~") return HOME;
    if (p.startsWith("~/")) return HOME + p.slice(1);
    return p;
  }
  function resolveFrom(base, p) {
    return stripSlash(path.resolve(base, msysToDrive(expand(p), IS_WINDOWS)));
  }
  function abspath(p) {
    return resolveFrom(curdir, p);
  }
  function extOf(p) {
    const b = path.basename(p);
    const i = b.lastIndexOf(".");
    return i > 0 ? b.slice(i + 1).toLowerCase() : "";
  }
  function isTemp(p) {
    const safe = TEMP_SAFE();
    if (safe.some((t) => p === t || within(t, p))) return true;
    if (TEMP_REAL === null) {
      // The realpath'd list needs the SAME two guards as the raw one. Without
      // them an entry that merely POINTS at a root or at an ancestor of the
      // project — a `/tmp/scratch` symlinked to `/`, say — passes both filters
      // above in its raw spelling and only widens once canonical() resolves it,
      // switching rules (B) and (C) off for every path with no ledger entry.
      TEMP_REAL = safe.map(canonical).filter((t, i, a) =>
        t !== safe[i] && a.indexOf(t) === i && !isUnsafeTempEntry(t, path) && !within(t, projectRoot));
    }
    return TEMP_REAL.some((t) => p === t || within(t, p));
  }

  // git missing (ENOENT) or hung (2s timeout) → fail-open, so the gate cannot be
  // turned into a wedge or invert the gitignore carve-out on a git-less host.
  function bail(e) {
    return !!(e && (e.killed || e.signal === "SIGTERM" || e.code === "ETIMEDOUT" || e.code === "ENOENT"));
  }
  // In a git repo: true iff the path is tracked. In a real dir that is not a repo:
  // true (protect any existing source file, per the spec). git is invoked via
  // execFileSync arg-array (no shell), so an attacker-influenced path after `--`
  // cannot be reinterpreted as a flag.
  function tracked(p) {
    const dir = path.dirname(p);
    const opts = { stdio: "ignore", timeout: 2000 };
    try {
      execFileSync("git", ["-C", dir, "ls-files", "--error-unmatch", "--", p], opts);
      return true;
    } catch (e1) {
      if (bail(e1)) return false;
      try {
        execFileSync("git", ["-C", dir, "rev-parse", "--is-inside-work-tree"], opts);
        return false;
      } catch (e2) {
        if (bail(e2)) return false;
        return true;
      }
    }
  }

  function decide(value, channel, base) {
    if (base === null && !path.isAbsolute(msysToDrive(expand(value), IS_WINDOWS))) {
      return targetsOnly && SRC.has(extOf(value))
        ? "WRITE-TARGET " + value + " (via " + channel + ", under a directory named at run time)"
        : "";
    }
    const p = resolveFrom(base === null || base === undefined ? curdir : base, value);
    if (!SRC.has(extOf(p))) return "";
    if (isTemp(p)) return "";
    // BSWG_MODE=targets — report the RESOLVED write operand instead of judging
    // it. Same tokenization and the same source-extension and temp-root
    // filters as the deny path; only the two project-root rules below are
    // skipped, because this mode exists precisely for the caller that has no
    // usable project root. Answering "does this command write a source file"
    // needs an operand, not a channel token: detectChannels matches text, so
    // it reports `redirect` for `git commit -m "fix: A -> B"`.
    if (targetsOnly) return "WRITE-TARGET " + p + " (via " + channel + ")";
    if (!within(projectRoot, p)) {
      return (
        "Blocked a Bash write to a source file OUTSIDE this session's worktree/project root (" +
        p +
        ", via " +
        channel +
        "). Writing source into a sibling or main checkout corrupts another session's working tree — " +
        "the cross-session contamination this gate prevents. Edit files through the Edit/Write tools inside " +
        "your own worktree." + reanchorHint + OPT_IN_NOTE
      );
    }
    // The budget bounds the SYNCHRONOUS GIT CALLS, so it is spent here rather than
    // per candidate target: counting targets decide() discards on extension or temp
    // let 200 `>> a.txt` redirects buy a free `>> src/app.rs` at the end.
    // Past the budget the git call is skipped, so the target is treated as
    // tracked rather than waved through — otherwise 200 pre-created untracked
    // source files would buy one free clobber of real tracked source.
    if (fs.existsSync(p) && (++evaluated > MAX_TARGETS || Date.now() > DEADLINE || tracked(p))) {
      return (
        "Blocked a Bash write that would overwrite an existing git-tracked source file (" +
        p +
        ", via " +
        channel +
        "). A raw shell write to tracked source bypasses the Edit/Write tools and the review/TDD discipline " +
        "that watch them — route the change through Edit/Write instead. New files, gitignored/untracked files, " +
        "and non-source files are unaffected." + OPT_IN_NOTE
      );
    }
    return "";
  }

  // Rule (C): a git command whose TARGET REPOSITORY escapes the session root.
  // Same cross-checkout contamination as (B), reached through a channel (B)
  // cannot see — `git add`/`commit`/`checkout` rewrite another worktree's index
  // and files without naming any path this parser would read as a write target.
  // `args` are the tokens after `git`; resolution is lexical, so no git
  // subprocess runs and the rule has no fail-open branch of its own.
  function decideGit(args, env) {
    const t = gitTargets(args, curdir, resolveFrom);
    // `t.unresolved` means the addressing was written with a token the shell
    // expands later, so no candidate derived from it would mean anything.
    if (!GIT_MUTATIONS.has(t.sub) || t.readOnly) return "";
    // An unresolved base makes RELATIVE candidates meaningless, but an absolute
    // one resolves identically for every possible expansion — `worktree remove
    // --force /abs/foreign/wt` destroys that tree whatever `-C "$REPO"` becomes.
    const judgeable = t.unresolved ? ((p) => t.absolute.indexOf(p) !== -1) : (() => true);
    const escapes = (p) => !isTemp(p) && !within(projectRoot, p);
    const workTrees = t.workTrees.slice();
    const gitDirs = t.gitDirs.slice();
    // Env-sourced designations obey the same UNEXPANDED contract as their flag
    // twins: an unexpanded GIT_WORK_TREE leaves nothing judgeable, and an
    // unexpanded GIT_DIR drops only its own candidate. Pushing the raw token
    // would resolve to a bogus IN-PROJECT work tree, which would then satisfy
    // `workTreeInProject` and silently drop a real foreign git dir.
    if (env.GIT_WORK_TREE && !UNEXPANDED.test(env.GIT_WORK_TREE)) {
      workTrees.push(resolveFrom(t.repo, env.GIT_WORK_TREE));
    }
    if (env.GIT_DIR && !UNEXPANDED.test(env.GIT_DIR)) gitDirs.push(resolveFrom(t.repo, env.GIT_DIR));
    // A LINKED worktree keeps its git dir at <main-checkout>/.git/worktrees/<name>,
    // permanently outside the session root — so an explicitly in-project work tree
    // makes the accompanying git dir a false positive, not an escape. Without a
    // work tree a foreign git dir still receives the commit, so it stays a candidate.
    const workTreeInProject = workTrees.length > 0 && workTrees.every((w) => within(projectRoot, w));
    // `worktree remove|move` never touches the addressed repository's own working
    // tree — only its worktree bookkeeping and the tree named as an operand. So it
    // is judged on that operand INSTEAD of on `repo`: removing a scratch worktree
    // whose bookkeeping lives in the main checkout is the ordinary flow (it is what
    // skills/pr-team-review does), and denying it would only teach the escape hatch.
    const addressed = t.sub === "worktree" ? t.paths : [t.repo];
    const candidates = addressed.concat(
      workTrees,
      workTreeInProject ? gitDirs.filter((d) => !isLinkedWorktreeGitDir(d)) : gitDirs
    );
    const hit = candidates.filter(judgeable).find(escapes);
    if (hit === undefined) return "";
    // Each remedy has to actually clear the deny it accompanies: adding -C does
    // nothing for a designated --work-tree/--git-dir or for an operand path, since
    // both re-resolve to the same escaping location.
    let remedy;
    if (t.paths.indexOf(hit) !== -1) {
      remedy = "Name a worktree inside this session root (or under a temp root) instead — adding -C does not change which tree is destroyed.";
    } else if (hit === t.repo) {
      remedy = "Re-pointing the command at a different checkout does not help: it would " + t.sub +
        " there, not in the tree this command addressed." + reanchorHint;
    } else {
      remedy = "Point --work-tree/--git-dir inside this session root, or drop them — re-running with -C alone " +
        "keeps the same escaping designation and denies again." + reanchorHint;
    }
    return (
      "Blocked `git " + t.sub + "` against a repository OUTSIDE this session's worktree/project root (" +
      hit +
      "). Staging, committing or restoring in a sibling or main checkout rewrites another session's " +
      "index and working tree — the cross-session contamination this gate prevents. " + remedy + OPT_IN_NOTE
    );
  }

  // Bound the work: a crafted command with thousands of `>> a.rs >> b.rs …`
  // targets would otherwise fan out into thousands of synchronous git calls.
  const MAX_TARGETS = 200;
  let evaluated = 0;
  // `tracked()` may spend 2 x 2s per target, so the target budget alone allows a
  // worst case far beyond the 60s the hooks.json entry declares. A wall-clock
  // deadline keeps the hook inside its own budget on a degraded mount.
  const DEADLINE = Date.now() + 20000;

  // Bypass-ledger markers: when an inline env prefix (unquoted OR quoted —
  // envp values are read after quote removal) suppresses this gate for a segment, the
  // fact is reported to the caller as `__bypass__\t<VAR>` lines — but only
  // when no deny reason wins. Detection thereby shares the ONE code path that
  // decides the bypass, instead of a shell-side textual re-parse.
  const bypassed = [];
  const bypassMarkers = () =>
    bypassed.map((v) => "__bypass__\t" + v).join("\n");

  const events = lex(commandText(cmd));
  const startDir = curdir;
  function scan(bashQuotes) {
    curdir = startDir;
    evaluated = 0;
    const stack = [];
    // Snapshot taken at the START of each segment. A `|`/`&` boundary discards
    // only what the stage that just ended did, so rewinding to the command's
    // initial cwd would erase an earlier `cd ../sibling &&` — the drift this rule
    // exists for — on any command with a pipe before the git verb.
    let segCwd = curdir;
    let segEnv = {};
    let carryEnv = {};
    for (const e of events) {
      // The env carry is scoped exactly like the cwd: a binding made inside `( … )`
      // dies with the subshell and must not deny a later in-project command.
      // A pipeline stage and a backgrounded command run in a subshell, so neither
      // an `export` nor a `cd` made INSIDE that stage carries past it.
      if (e.t === "reset") { curdir = segCwd; carryEnv = segEnv; continue; }
      if (e.t === "enter") { stack.push([curdir, Object.assign({}, carryEnv)]); continue; }
      if (e.t === "leave") {
        const f = stack.pop();
        if (f) { curdir = f[0]; carryEnv = f[1]; }
        continue;
      }

      const split = splitRedirects(segmentWords(e.text, bashQuotes));
      if (!split.words.length && !split.writes.length) continue;
      segCwd = curdir;
      segEnv = Object.assign({}, carryEnv);

      // Skip transparent wrappers (env/sudo/command/exec/…) and env's VAR=val args
      // so a wrapped program still resolves to its real verb for the program gates.
      // `env VAR=val git …` carries its assignments in read.ops rather than in envp. They
      // are collected separately so rule (C) can read GIT_DIR/GIT_WORK_TREE off both
      // spellings without widening which prefixes count as an escape hatch.
      const read = commandWords(split.words);
      const envp = {};
      for (const assignment of read.leading) {
        if (assignment.plain) envp[assignment.name] = assignment.value;
      }
      if (read.index >= read.words.length && !split.writes.length) continue;
      const word = read.word;
      const cmd0 = read.inShell && word.indexOf("/") === -1 ? word : "";
      const program = programName(word);
      const args = read.words.slice(read.index + 1).map((w) => w.value);

      // `cd` updates the scoped cwd BEFORE the escape-hatch check — an escaped
      // segment may still change the directory for the commands that follow it.
      if (cmd0 === "cd" && args[0] !== undefined) {
        curdir = abspath(args[0]);
        continue;
      }
      if (envp.ZENSU_BASH_WRITE_GATE === "off" || envp.ZENSU_MCP_GATE === "off") {
        if (envp.ZENSU_BASH_WRITE_GATE === "off" && bypassed.indexOf("ZENSU_BASH_WRITE_GATE") < 0) bypassed.push("ZENSU_BASH_WRITE_GATE");
        if (envp.ZENSU_MCP_GATE === "off" && bypassed.indexOf("ZENSU_MCP_GATE") < 0) bypassed.push("ZENSU_MCP_GATE");
        continue;
      }

      // `export GIT_WORK_TREE=… && git add -A` is the third spelling of the same
      // designation, and detectControlMutation already treats these builtins this
      // way for its own bindings — carry it to the next segment in this command.
      // `declare`/`typeset` only reach git's environment with -x; plain `export` always
      // does. Harvest and then FALL THROUGH — a redirect in the same segment is still
      // a write channel rules (A)/(B) must see.
      if (cmd0 === "export"
        || (["declare", "typeset"].indexOf(cmd0) !== -1 && args.some((a) => /^-[A-Za-z]*x/.test(a)))) {
        for (const arg of args) {
          const eq = arg.indexOf("=");
          const name = eq > 0 ? arg.slice(0, eq) : "";
          if (name === "GIT_DIR" || name === "GIT_WORK_TREE") carryEnv[name] = arg.slice(eq + 1);
        }
      }

      // Rule (C) is one of the two rules that need a project root, so targets mode
      // skips it — there is no root to judge "escapes the session root" against.
      // Before canonicalization this arm only passed by coincidence: projectRoot
      // and curdir were byte-identical strings, so every repo looked in-project. A
      // root that cannot be realpath'd (it was DELETED — the state this mode exists
      // for) now stays in the unresolved namespace while the payload cwd resolves,
      // and every git verb in the user's own tree would read as an escape.
      const dirs = read.ops.filter((op) => op.kind === "chdir").map((op) => op.name);
      if (program === "git" && !targetsOnly) {
        let gitEnv = Object.assign({}, carryEnv, envp);
        for (const op of read.ops) {
          if (op.kind === "clear") gitEnv = {};
          else if (op.kind === "unset") delete gitEnv[op.name];
          else if (op.kind === "set") gitEnv[op.name] = op.value;
        }
        const g = decideGit(dirs.flatMap((dir) => ["-C", dir]).concat(args), {
          GIT_DIR: gitEnv.GIT_DIR,
          GIT_WORK_TREE: gitEnv.GIT_WORK_TREE
        });
        if (g) return g;
      }

      const runDir = dirs.some((dir) => UNEXPANDED.test(dir)) ? null : dirs.reduce((base, dir) => resolveFrom(base, dir), curdir);
      const targets = split.writes.map((w) => [w.value, "redirect", curdir]);
      const teeIdx = program === "tee" ? read.index : read.words.findIndex((w) => w.value === "tee");
      if (teeIdx !== -1) {
        const base = program === "tee" ? runDir : curdir;
        for (const w of read.words.slice(teeIdx + 1)) {
          if (w.value.charAt(0) !== "-") targets.push([w.value, "tee", base]);
        }
      }
      if (program === "sed" && sedInPlace(args)) {
        for (const a of args) {
          if (a.charAt(0) !== "-" && SRC.has(extOf(a))) targets.push([a, "sed -i", runDir]);
        }
      }
      if (program === "dd") {
        for (const a of args) {
          if (/^of=./.test(a)) targets.push([a.slice(3), "dd of=", runDir]);
        }
      }

      for (let x = 0; x < targets.length; x++) {
        // The ANCHORED path spends this budget inside decide(), where exhaustion
        // is treated as tracked and therefore DENIES — otherwise 200 pre-created
        // untracked source files would buy one free clobber of real tracked
        // source. targets mode never reaches that branch (decide() reports the
        // operand and returns first), so without a guard here the cap would be the
        // only rule left standing, and `printf x > a1.txt … > a200.txt >
        // src/app.ts` would walk a source write straight through a branch whose
        // contract is "deny writes". Fail closed, the same way that branch treats
        // a parser that cannot run at all. Counted only in targets mode so the two
        // budgets never double-spend the same MAX_TARGETS.
        if (targetsOnly && ++evaluated > MAX_TARGETS) {
          return "WRITE-TARGET (unevaluated: target budget exceeded)";
        }
        const r = decide(targets[x][0], targets[x][1], targets[x][2]);
        if (r) return r;
      }
    }
    return "";
  }
  const reread = (text) => JSON.stringify(segmentWords(text, false)) !== JSON.stringify(segmentWords(text, true));
  for (const bashQuotes of events.some((e) => e.t === "seg" && reread(e.text)) ? [false, true] : [false]) {
    const verdict = scan(bashQuotes);
    if (verdict) return verdict;
  }
  return bypassMarkers();
}

function heredocBodies(s) {
  const lines = s.split("\n");
  const bodies = [];
  let i = 0;
  while (i < lines.length) {
    for (const doc of heredocDelimiters(lines[i++])) {
      const start = i;
      i = skipHeredocs(lines, i, [doc]);
      const closed = i > start && (doc.tabs ? lines[i - 1].replace(/^\t+/, "") : lines[i - 1]) === doc.delim;
      bodies.push({ quoted: doc.quoted, body: lines.slice(start, closed ? i - 1 : i).join("\n") });
    }
  }
  return bodies;
}

if (require.main === module) {
  process.stdout.write(main());
} else {
  // Copies, not the live tables. Object.freeze does NOT protect a Set — its
  // entries live in an internal slot, so a frozen Set still accepts .delete()
  // and an in-process consumer could neuter rule (C) for that process.
  module.exports = {
    OPT_IN_NOTE,
    controlVerdict,
    detectChannels,
    detectControlMutation,
    stripHeredocs,
    heredocBodies,
    gitTargets,
    msysToDrive,
    programName,
    segmentWords,
    joinContinuations,
    splitRedirects,
    commandWords,
    sedInPlace,
    within,
    isUnsafeTempEntry,
    splitTempList,
    GIT_MUTATIONS: Object.freeze(Array.from(GIT_MUTATIONS)),
    GIT_OPTS_WITH_OPERAND: Object.freeze(Array.from(GIT_OPTS_WITH_OPERAND)),
    GIT_READONLY_FORMS: Object.freeze(Object.keys(GIT_READONLY_FORMS))
  };
}
