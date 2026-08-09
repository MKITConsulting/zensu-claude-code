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
// Rule (C) also anchors on `cmd0`, and the wrapper skip advances over WRAP names
// and VAR=val only, so a wrapper's OWN flag or a shell keyword hides the verb:
// `sudo -u me git …`, `nice -n 10 git …`, `for f in a b; do git …; done`. That is
// pre-existing (`sed -i` and `dd` share the anchor) and is not the drifted-cwd
// incident rule (C) exists for, so it is accepted rather than closed. A linked
// worktree's admin dir may likewise ride along on an in-project --work-tree even
// when it belongs to a FOREIGN repo — lexically the two are indistinguishable.
// Two more come from the shared lexer and bind rules (B) and (C) alike: `cd`
// tracking reads the token right after `cd`, so `cd -- ../sibling` and
// `cd -P ../sibling` move the cwd to `<proj>/--` and `<proj>/-P` instead of the
// sibling; and tokens split on whitespace, so a quoted path containing a space
// (`git -C "/foo bar" add .`) leaves a fragment where the subcommand should be.
// Finally, `worktree remove|move` given a bare worktree NAME rather than a path
// is unjudgeable — git resolves the name against a worktree list this parser
// deliberately never reads — so that spelling passes.
// All accepted rare-idiom gaps: this is a convention-nudge with an env escape
// hatch, not a security boundary.

const path = require("path");
const fs = require("fs");
const { execFileSync } = require("child_process");

const SRC = new Set(
  "rs ts tsx js jsx mjs cjs py java kt kts go rb c cc cpp cxx h hh hpp cs php swift scala vue svelte".split(" ")
);

// Transparent command wrappers — skipped so `env sed -i …` / `sudo dd of=…`
// still resolve to the real verb (mirrors pre-bash-zensu-gate.sh).
const WRAP = new Set("command builtin exec env sudo nohup nice time".split(" "));

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

function stripSlash(p) {
  return p && p.length > 1 && p.endsWith("/") ? p.replace(/\/+$/, "") : p;
}

function unquote(t) {
  return t.replace(/^['"]+|['"]+$/g, "");
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
function gitTargets(args, base, resolve) {
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
  const isPathish = (t) =>
    !UNEXPANDED.test(t) && (t.indexOf("/") !== -1 || t === "." || t === ".." || t === "~");
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
// This is a TEXT matcher with no operand resolution and no quote awareness, so
// it reports `redirect` for `git commit -m "fix: A -> B"` and `tee` for a commit
// message containing that word. Any consumer that DENIES on a hit refuses those.
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
  const VERB = "(^|\\s|;|\\||&|/)";
  if (REDIR.test(collapsed)) found.add("redirect");
  if (new RegExp(VERB + "tee(\\s|$)").test(cmd)) found.add("tee");
  if (new RegExp(VERB + "sed\\s+(-[A-Za-z]*\\s+)*-i").test(cmd)) found.add("sed -i");
  if (new RegExp(VERB + "dd\\s+[^\\n]*of=").test(cmd)) found.add("dd of=");
  if (/(?<!<)<<(?!<)[-~]?\s*['"]?[A-Za-z_]/.test(cmd)) found.add("heredoc");
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

function bindingFromAssignment(raw) {
  const m = unquote(raw).match(/^([A-Za-z_][A-Za-z0-9_]*)=/);
  return m && CONTROL_BINDINGS.has(m[1]) ? m[1] : "";
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
  if (!/^[A-Za-z]:\//.test(normalized)) return normalized;
  const drive = normalized.slice(0, 2).toLowerCase();
  const tail = path.posix.normalize("/" + normalized.slice(3));
  return (drive + tail).toLowerCase();
}

function commandRefersToControlPath(cmd, envFile) {
  const target = controlPathNamespace(envFile);
  if (!target) return false;
  const windowsDriveTarget = /^[a-z]:\//.test(target);

  // Normalize drive-root spellings wherever a shell token may begin. Keeping
  // token boundaries in the comparison prevents `.claude-env.backup` from
  // being mistaken for the protected file while still covering glued redirects
  // such as `>>/d/work/.claude-env` and quoted paths containing spaces.
  let normalizedCommand = cmd
    .replace(/\\/g, "/")
    .replace(/(^|[\s"'`=<>|&;(])\/([A-Za-z])(?=\/)/g, "$1$2:");
  // Drive-letter paths are case-insensitive; POSIX paths are not. Lowercase
  // only for the Windows namespace so the existing Unix exact-path behavior
  // remains case-sensitive.
  if (windowsDriveTarget) normalizedCommand = normalizedCommand.toLowerCase();
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
    || commandRefersToControlPath(cmd, envFile);
  if (refersToEnvFile && detectChannels(cmd)) {
    return "Blocked a Bash write to CLAUDE_ENV_FILE. Model commands must not alter the environment inherited by later Claude Code Bash calls.";
  }

  for (const event of lex(stripHeredocs(cmd))) {
    if (event.t !== "seg") continue;
    const toks = event.text.trim().split(/\s+/).filter(Boolean);
    if (!toks.length) continue;
    let i = 0;
    while (i < toks.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i])) {
      const name = bindingFromAssignment(toks[i]);
      if (name) return "Blocked a Bash rebind of protected Session Control input " + name + ". Start a fresh Claude Code session instead.";
      i++;
    }
    while (i < toks.length && WRAP.has(unquote(toks[i]).split("/").pop())) {
      i++;
      while (i < toks.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i])) {
        const name = bindingFromAssignment(toks[i]);
        if (name) return "Blocked a Bash rebind of protected Session Control input " + name + ". Start a fresh Claude Code session instead.";
        i++;
      }
    }
    if (i >= toks.length) continue;
    const cmd0 = unquote(toks[i]).split("/").pop();
    const args = toks.slice(i + 1).map(unquote);
    if (["export", "readonly", "declare", "typeset", "local"].includes(cmd0)) {
      for (const arg of args) {
        const name = bindingFromAssignment(arg);
        if (name) return "Blocked a Bash rebind of protected Session Control input " + name + ". Start a fresh Claude Code session instead.";
      }
    }
    if (cmd0 === "unset") {
      const name = args.find((arg) => CONTROL_BINDINGS.has(arg));
      if (name) return "Blocked removal of protected Session Control input " + name + ". Start a fresh Claude Code session instead.";
    }
    if (cmd0 === "printf") {
      const vi = args.indexOf("-v");
      if (vi !== -1 && CONTROL_BINDINGS.has(args[vi + 1])) {
        return "Blocked a Bash rebind of protected Session Control input " + args[vi + 1] + ". Start a fresh Claude Code session instead.";
      }
    }
    if (cmd0 === "read") {
      const name = args.find((arg) => CONTROL_BINDINGS.has(arg));
      if (name) return "Blocked a Bash rebind of protected Session Control input " + name + ". Start a fresh Claude Code session instead.";
    }
  }
  return "";
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
  try {
    const j = JSON.parse(raw || "{}");
    if (j.tool_input && typeof j.tool_input.command === "string") cmd = j.tool_input.command;
    if (typeof j.cwd === "string") cwd0 = j.cwd;
  } catch (e) {
    return "";
  }
  if (!cmd) return "";
  if (process.env.BSWG_MODE === "detect") return detectChannels(cmd);
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
    const abs = stripSlash(path.resolve(p));
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
    ? tempOverride.split(":")
    : [process.env.TMPDIR || "", "/tmp", "/private/tmp", "/var/folders"]
  )
    .filter(Boolean)
    .map((p) => stripSlash(path.resolve(p)));
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
    return stripSlash(path.resolve(base, expand(p)));
  }
  function abspath(p) {
    return resolveFrom(curdir, p);
  }
  function extOf(p) {
    const b = path.basename(p);
    const i = b.lastIndexOf(".");
    return i > 0 ? b.slice(i + 1).toLowerCase() : "";
  }
  // Same containment predicate hooks/lib/reviewer-capability-v1.js uses. The
  // `..` test must be anchored on a separator and on the exact `..`: a bare
  // startsWith("..") also rejects a legitimately nested `..bak`, whose relative
  // path is `..bak`, and the empty relative path means "is the root itself".
  function within(root, p) {
    const rel = path.relative(stripSlash(root), p);
    return rel === "" || (rel !== ".." && !rel.startsWith(".." + path.sep) && !path.isAbsolute(rel));
  }
  function isTemp(p) {
    const safe = TEMP_SAFE();
    if (safe.some((t) => p === t || within(t, p))) return true;
    if (TEMP_REAL === null) {
      TEMP_REAL = safe.map(canonical).filter((t, i, a) => t !== safe[i] && a.indexOf(t) === i);
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

  function decide(raw, channel) {
    const p = abspath(unquote(raw));
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
        "your own worktree. Deliberate one-off: prefix the command with ZENSU_BASH_WRITE_GATE=off."
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
        "and non-source files are unaffected. Deliberate one-off: prefix the command with ZENSU_BASH_WRITE_GATE=off."
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
      remedy = "Address your own worktree explicitly instead: git -C '" + projectRoot + "' " + t.sub + " … .";
    } else {
      remedy = "Point --work-tree/--git-dir inside this session root, or drop them and run " +
        "git -C '" + projectRoot + "' " + t.sub + " … — re-running with -C alone keeps the same escaping designation and denies again.";
    }
    return (
      "Blocked `git " + t.sub + "` against a repository OUTSIDE this session's worktree/project root (" +
      hit +
      "). Staging, committing or restoring in a sibling or main checkout rewrites another session's " +
      "index and working tree — the cross-session contamination this gate prevents. " + remedy +
      " Deliberate one-off: prefix the command with ZENSU_BASH_WRITE_GATE=off."
    );
  }

  const REDIR = /^(&|\d*)(>>?)(\|?)(.*)$/; // >  >>  &>  2>  >|  (and glued target)

  // Bound the work: a crafted command with thousands of `>> a.rs >> b.rs …`
  // targets would otherwise fan out into thousands of synchronous git calls.
  const MAX_TARGETS = 200;
  let evaluated = 0;
  // `tracked()` may spend 2 x 2s per target, so the target budget alone allows a
  // worst case far beyond the 60s the hooks.json entry declares. A wall-clock
  // deadline keeps the hook inside its own budget on a degraded mount.
  const DEADLINE = Date.now() + 20000;

  // Bypass-ledger markers: when an inline env prefix (unquoted OR quoted —
  // envp values are unquote()d below) suppresses this gate for a segment, the
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
  const pre = stripHeredocs(cmd)
    .replace(/>\|/g, ">")
    .replace(/(\d*)(>>?)&(?=\s*[^\s0-9&|;<>(\-])/g, "$1$2");
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

    const toks = e.text.trim().split(/\s+/).filter(Boolean);
    if (!toks.length) continue;
    segCwd = curdir;
    segEnv = Object.assign({}, carryEnv);

    let i = 0;
    const envp = {};
    while (i < toks.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i])) {
      const a = toks[i];
      const eq = a.indexOf("=");
      envp[a.slice(0, eq)] = unquote(a.slice(eq + 1));
      i++;
    }
    const rest = toks.slice(i).filter((t) => t !== "");
    if (!rest.length) continue;

    // Skip transparent wrappers (env/sudo/command/exec/…) and env's VAR=val args
    // so a wrapped builtin still resolves to its real verb for the cmd0 gates.
    // `env VAR=val git …` carries its assignments here rather than in envp. They
    // are collected separately so rule (C) can read GIT_DIR/GIT_WORK_TREE off both
    // spellings without widening which prefixes count as an escape hatch.
    let ci = 0;
    const wrapEnv = {};
    while (ci < rest.length && WRAP.has(unquote(rest[ci]).split("/").pop())) {
      ci++;
      while (ci < rest.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(rest[ci])) {
        const eq = rest[ci].indexOf("=");
        wrapEnv[rest[ci].slice(0, eq)] = unquote(rest[ci].slice(eq + 1));
        ci++;
      }
    }
    const cmd0 = ci < rest.length ? unquote(rest[ci]).split("/").pop() : "";

    // `cd` updates the scoped cwd BEFORE the escape-hatch check — an escaped
    // segment may still change the directory for the commands that follow it.
    if (cmd0 === "cd" && rest[ci + 1] !== undefined) {
      curdir = abspath(unquote(rest[ci + 1]));
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
      || (["declare", "typeset"].indexOf(cmd0) !== -1 && rest.indexOf("-x") !== -1)) {
      for (const raw of rest.slice(ci + 1)) {
        // Unquote AFTER the split, as the option and inline-prefix paths do:
        // unquoting the whole token first leaves `GIT_WORK_TREE="/sib"` as
        // `"/sib`, which is not absolute and resolves back inside the project.
        const eq = unquote(raw).indexOf("=") >= 0 ? raw.replace(/^['"]/, "").indexOf("=") : -1;
        if (eq <= 0) continue;
        const bare = raw.replace(/^['"]/, "");
        const name = unquote(bare.slice(0, eq));
        if (name === "GIT_DIR" || name === "GIT_WORK_TREE") carryEnv[name] = unquote(bare.slice(eq + 1));
      }
    }

    // Rule (C) is one of the two rules that need a project root, so targets mode
    // skips it — there is no root to judge "escapes the session root" against.
    // Before canonicalization this arm only passed by coincidence: projectRoot
    // and curdir were byte-identical strings, so every repo looked in-project. A
    // root that cannot be realpath'd (it was DELETED — the state this mode exists
    // for) now stays in the unresolved namespace while the payload cwd resolves,
    // and every git verb in the user's own tree would read as an escape.
    if (cmd0 === "git" && !targetsOnly) {
      const pick = (k) => {
        if (wrapEnv[k] !== undefined) return wrapEnv[k];
        if (envp[k] !== undefined) return envp[k];
        return carryEnv[k];
      };
      const g = decideGit(rest.slice(ci + 1), {
        GIT_DIR: pick("GIT_DIR"),
        GIT_WORK_TREE: pick("GIT_WORK_TREE")
      });
      if (g) return g;
    }

    const targets = [];
    for (let k = 0; k < rest.length; k++) {
      const m = rest[k].match(REDIR);
      if (m) {
        if (m[4]) targets.push([m[4], "redirect"]);
        else if (rest[k + 1] !== undefined) { targets.push([rest[k + 1], "redirect"]); k++; }
      }
    }
    const teeIdx = rest.findIndex((t) => unquote(t) === "tee");
    if (teeIdx !== -1) {
      for (let k = teeIdx + 1; k < rest.length; k++) {
        const t = rest[k];
        if (t.charAt(0) === "-") continue;            // flag
        const rm = t.match(REDIR);
        if (rm) { if (!rm[4]) k++; continue; }         // skip a redirect operator (+ its operand)
        targets.push([t, "tee"]);
      }
    }
    if (cmd0 === "sed" && rest.some((t) => /^-i/.test(unquote(t)))) {
      for (const t of rest) {
        const u = unquote(t);
        if (u.charAt(0) !== "-" && SRC.has(extOf(abspath(u)))) targets.push([t, "sed -i"]);
      }
    }
    if (cmd0 === "dd") {
      for (const t of rest) {
        const m = t.match(/^of=(.+)$/);
        if (m) targets.push([m[1], "dd of="]);
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
      const r = decide(targets[x][0], targets[x][1]);
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
    detectChannels,
    detectControlMutation,
    stripHeredocs,
    gitTargets,
    GIT_MUTATIONS: Object.freeze(Array.from(GIT_MUTATIONS)),
    GIT_OPTS_WITH_OPERAND: Object.freeze(Array.from(GIT_OPTS_WITH_OPERAND)),
    GIT_READONLY_FORMS: Object.freeze(Object.keys(GIT_READONLY_FORMS))
  };
}
