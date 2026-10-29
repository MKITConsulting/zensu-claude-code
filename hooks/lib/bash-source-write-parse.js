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

// Transparent command wrappers — skipped so `env sed -i …` / `sudo dd of=…`
// still resolve to the real verb (mirrors pre-bash-zensu-gate.sh).
const WRAP = new Set("command builtin exec env sudo nohup nice time".split(" "));
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
  let value = "";
  let cut = false;
  let i = start;
  while (i < text.length && text[i] !== "'") {
    let ch = text[i];
    let next = i + 1;
    if (ch === "\\" && i + 1 < text.length) {
      const c = text[i + 1];
      const rest = text.slice(i + 2);
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
        next += 1;
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
  return { value, end: i };
}

function redirectOperator(text, i) {
  const two = text.substr(i, 2);
  if (text.substr(i, 3) === "<<<") return "<<<";
  if (two === "<<") return text[i + 2] === "-" ? "<<-" : "<<";
  if ([">>", ">|", ">&", "<>", "<&"].indexOf(two) !== -1) return two;
  return text[i];
}

function segmentWords(text) {
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
    if (c === ">" || c === "<") {
      const fd = word !== null && /^(?:\d+|&)$/.test(text.slice(word.start, i));
      const start = fd ? word.start : i;
      if (fd) word = null;
      else close(i);
      i += redirectOperator(text, i).length;
      const raw = text.slice(start, i);
      words.push({ raw, value: raw, op: raw.replace(/^\d+/, "") });
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
        } else {
          word.value += text[k];
          k++;
        }
      }
      i = k + 1;
    } else if (c === "$" && text[i + 1] === "{") {
      const end = text.indexOf("}", i + 2);
      const stop = end === -1 ? n : end + 1;
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

function joinContinuations(text) {
  const out = [];
  let joined = "";
  for (const line of text.split("\n")) {
    const tail = /\\+$/.exec(line);
    if (tail && tail[0].length % 2 === 1 && !/(^|[\s;&|()])#/.test(joined + line)) {
      joined += line.slice(0, -1);
      continue;
    }
    out.push(joined + line);
    joined = "";
  }
  if (joined) out.push(joined);
  return out.join("\n");
}

function commandText(cmd) {
  return joinContinuations(stripHeredocs(cmd))
    .replace(/>\|/g, ">")
    .replace(/(\d*)(>>?)&(?=\s*[^\s0-9&|;<>(\-])/g, "$1$2");
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
    if (target && /^(?:&?>>?|>\|)$/.test(w.op)) writes.push(target);
  }
  return { words, writes };
}

function longOption(table, given) {
  const names = Object.keys(table);
  if (names.indexOf(given) !== -1) return given;
  const hits = names.filter((name) => name.startsWith(given));
  return given !== "" && hits.length === 1 ? hits[0] : null;
}

function wrapperArguments(name, words, start, out) {
  const spec = WRAPPER_OPTIONS[name];
  const apply = (key, value, at) => {
    const kind = Object.prototype.hasOwnProperty.call(spec.effects, key) ? spec.effects[key] : "";
    if (kind === "clear") out.ops.push({ kind });
    else if (value === undefined) return;
    else if (kind === "unset" || kind === "chdir") out.ops.push({ kind, name: value });
    else if (kind === "split" && out.splits++ < MAX_SPLITS) {
      words.splice(at, 0, ...segmentWords(value).filter((w) => !w.op));
    }
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
      if (key !== null && spec.long[key] === 1 && value === undefined && i + 1 < words.length) {
        value = words[i + 1].value;
        used = 2;
      }
      if (key !== null) found.push([key, value]);
    } else {
      for (let k = 1; k < word.length; k++) {
        const letter = word[k];
        if (spec.operands.indexOf(letter) !== -1 || (spec.optional.indexOf(letter) !== -1 && k + 1 < word.length)) {
          let value = word.slice(k + 1);
          if (value === "" && i + 1 < words.length) {
            value = words[i + 1].value;
            used = 2;
          }
          found.push([letter, value === "" ? undefined : value]);
          break;
        }
        found.push([letter, undefined]);
      }
    }
    i += used;
    for (const [key, value] of found) apply(key, value, i);
  }
  while (i < words.length && words[i].value.indexOf("=") > 0) {
    const value = words[i].value;
    out.ops.push({ kind: "set", name: value.slice(0, value.indexOf("=")), value: value.slice(value.indexOf("=") + 1) });
    i++;
  }
  return i;
}

function commandWords(segment) {
  const words = segment.slice();
  const out = { words, index: 0, word: "", leading: [], ops: [], inShell: true, splits: 0 };
  let i = 0;
  for (;;) {
    while (i < words.length && RESERVED_WORDS.has(words[i].raw)) i++;
    if (i < words.length && words[i].raw === "time") {
      i++;
      while (i < words.length && words[i].raw === "-p") i++;
      continue;
    }
    break;
  }
  while (i < words.length) {
    const m = SHELL_ASSIGNMENT.exec(words[i].raw);
    if (!m) break;
    const value = segmentWords(words[i].raw.slice(m[0].length)).map((w) => w.value).join("");
    out.leading.push({ name: m[1], plain: !m[2] && !m[3], value });
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
// still surfaces its `> FILE` redirect. The `(?<!<)<<(?!<)` guard excludes
// here-strings (`<<<WORD`), which are not heredocs and must not swallow lines.
function stripHeredocs(s) {
  const lines = s.split("\n");
  const out = [];
  let i = 0;
  while (i < lines.length) {
    out.push(lines[i]);
    const hm = lines[i].match(/(?<!<)<<(?!<)[-~]?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/);
    if (hm) {
      const delim = hm[2];
      i++;
      while (i < lines.length && lines[i].trim() !== delim) i++;
      if (i < lines.length) i++;
      continue;
    }
    i++;
  }
  return out.join("\n");
}

// Split into command segments while tracking subshell scope. `(`/`$(` emit an
// "enter" event and `)` a "leave" event so the caller can save/restore the cwd
// across a subshell — a `cd` inside `( … )` must not leak to later commands.
// Backtick is treated as a plain boundary. `&&`/`||`/`;`/`|`/newline/`&` split.
function lex(s) {
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
    if (c === "&" && (s[i - 1] === ">" || s[i - 1] === "<" || s[i + 1] === ">")) { buf += c; continue; }
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
  for (const event of lex(commandText(cmd))) {
    if (event.t !== "seg") continue;
    const read = commandWords(splitRedirects(segmentWords(event.text)).words);
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

function wordsReferToControlPath(cmd, envFile) {
  const target = controlPathNamespace(envFile);
  return !!target && lex(commandText(cmd)).some((event) => event.t === "seg"
    && segmentWords(event.text).some((w) => !w.op && controlPathNamespace(w.value) === target));
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

  const rebind = (name) => "Blocked a Bash rebind of protected Session Control input " + name + ". Start a fresh Claude Code session instead.";
  const removal = (name) => "Blocked removal of protected Session Control input " + name + ". Start a fresh Claude Code session instead.";
  for (const event of lex(commandText(cmd))) {
    if (event.t !== "seg") continue;
    const read = commandWords(splitRedirects(segmentWords(event.text)).words);
    const set = read.leading.concat(read.ops.filter((op) => op.kind === "set"))
      .find((assignment) => CONTROL_BINDINGS.has(assignment.name));
    if (set) return rebind(set.name);
    const unset = read.ops.find((op) => op.kind === "unset" && CONTROL_BINDINGS.has(op.name));
    if (unset) return removal(unset.name);
    if (read.index >= read.words.length) continue;
    const cmd0 = read.word.split("/").pop();
    const args = read.words.slice(read.index + 1).map((w) => w.value);
    if (["export", "readonly", "declare", "typeset", "local"].includes(cmd0)) {
      for (const arg of args) {
        const name = bindingFromAssignment(arg);
        if (name) return rebind(name);
      }
      const unexports = cmd0 === "export" ? args.some((a) => /^-[A-Za-z]*n/.test(a)) : args.some((a) => /^\+[A-Za-z]*x/.test(a));
      const name = unexports ? args.find((arg) => CONTROL_BINDINGS.has(arg)) : undefined;
      if (name) return removal(name);
    }
    if (cmd0 === "unset") {
      const name = args.find((arg) => CONTROL_BINDINGS.has(arg));
      if (name) return removal(name);
    }
    if (cmd0 === "printf") {
      for (let k = 0; k < args.length; k++) {
        const name = args[k] === "-v" ? args[k + 1] : /^-v./.test(args[k]) ? args[k].slice(2) : undefined;
        if (name !== undefined && CONTROL_BINDINGS.has(name)) return rebind(name);
      }
    }
    if (cmd0 === "read") {
      const name = args.find((arg) => CONTROL_BINDINGS.has(arg));
      if (name) return rebind(name);
    }
  }
  return "";
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
    return "WRITE-TARGET (unevaluated: a PowerShell command this check cannot prove read-only, because " + verdict.reason + ")";
  }
  return "Blocked a PowerShell command that the source-write rules cannot judge, because " + verdict.reason + ". " +
    "Rules (A), (B) and (C) read Bash commands only, so a PowerShell command passes this gate only when it is " +
    "provably read-only. Run it through the Bash tool, or change files with Edit or Write." + OPT_IN_NOTE;
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
  let tool = "";
  let child = false;
  try {
    const j = JSON.parse(raw || "{}");
    if (j.tool_input && typeof j.tool_input.command === "string") cmd = j.tool_input.command;
    if (typeof j.cwd === "string") cwd0 = j.cwd;
    if (typeof j.tool_name === "string") tool = j.tool_name;
    child = [j.agent_id, j.agent_type].some((v) => typeof v === "string" && v !== "");
  } catch (e) {
    return "";
  }
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
    ? " If this session now works in that worktree for good, /zensu:adopt-session --reanchor, run from inside it, " +
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
    if (base === null && !path.isAbsolute(msysToDrive(expand(value), IS_WINDOWS))) return "";
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

  // `>|` (noclobber override) and `>&FILE`/`>>&FILE` (redirect-all-to-file) are
  // just `>`/`>>` with the same target; collapse them before lexing so the bare
  // `|`/`&` is not taken as a boundary that severs the redirect from its file.
  // fd dups (`>&2`, `>&-`, `2>&1` — a digit or `-` after `&`) are left intact.
  const stack = [];
  // Snapshot taken at the START of each segment. A `|`/`&` boundary discards
  // only what the stage that just ended did, so rewinding to the command's
  // initial cwd would erase an earlier `cd ../sibling &&` — the drift this rule
  // exists for — on any command with a pipe before the git verb.
  let segCwd = curdir;
  let segEnv = {};
  let carryEnv = {};
  const pre = commandText(cmd);
  for (const e of lex(pre)) {
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

    const split = splitRedirects(segmentWords(e.text));
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
  return bypassMarkers();
}

if (require.main === module) {
  process.stdout.write(main());
} else {
  // Copies, not the live tables. Object.freeze does NOT protect a Set — its
  // entries live in an internal slot, so a frozen Set still accepts .delete()
  // and an in-process consumer could neuter rule (C) for that process.
  module.exports = {
    OPT_IN_NOTE,
    detectChannels,
    detectControlMutation,
    stripHeredocs,
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
