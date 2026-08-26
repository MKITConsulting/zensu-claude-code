'use strict';

// Display-safety rules for values this plugin renders into a terminal and into the
// model's context. HOST-NEUTRAL and DEPENDENCY-FREE by contract: it requires
// nothing, not even node builtins, and nothing here touches the filesystem.
//
// WHY IT IS ITS OWN FILE. `safe` lived in `session-adopt-report-v1.js`, which is a
// FEATURE COMMAND's report module — it carries five module-scope requires of its
// own, including the session-control core, the lease sweep and the hook binder. The
// doctor renderer needed the same fold and reached for it with a guarded lazy
// require plus a private, NARROWER fallback regex. That put a display rule in two
// implementations with the owner in the wrong module, and it made
// `/zensu:doctor` — the tool whose entire job is to speak in a damaged installation
// — depend on a four-file load chain to fold one string. A leaf module gives one
// rule one owner and shrinks the chain that can fail to a file with no dependencies.
//
// ONE rule, `safeDisplayValue`, and deliberately only one. It adds the pair-forgery
// guard (a two-space run, or a ` : ` sequence, would let the value fake a further row
// beneath the one it sits on) on top of a positive letter/number/mark allowlist. Both
// callers need it: the adoption report and the doctor report each render
// `label : value` rows the model is told to read verbatim, and the doctor's binding
// line is prose sitting in a report made of such pairs, where a forged pair is exactly
// as convincing.
//
// A SECOND, narrower export lived here for one review round — `foldDisplayHiders`,
// which removed only the bidi and line-separator characters. It was written for the
// doctor's load-failure fallback, that fallback was then changed to drop the value
// instead of folding it, and the export was left behind with no consumer and no
// executed case anywhere while this file is named in CLAUDE.md as a core-half port
// obligation. Four review seats found it independently. It is gone: an exported rule
// that is strictly weaker than the real one, unexercised, and reachable by a future
// caller who mistakes it for the fold is worse than no export at all. If a narrow
// fold is ever genuinely needed, add it WITH its consumer and its case, in one change.

// The alphabet is deliberately WIDE — \p{L}\p{N}\p{M} rather than ASCII — so an
// ordinary non-ASCII home directory renders as itself instead of as an escape soup,
// which would land the noise on exactly the developers whose paths are not ASCII.
// Every named threat still folds, because none of them is a letter, a number or a
// combining mark: the bidi overrides are \p{Cf}, U+2028/2029 are \p{Zl}/\p{Zp}, and
// U+007F is \p{Cc}.
const SAFE_DISPLAY = /^[\p{L}\p{N}\p{M} _.,:;/\\@+~()=-]*$/u;
const DOUBLE_SPACE = / {2}/;
// The class admits a space AND a colon, and DOUBLE_SPACE only rejects two ADJACENT
// spaces — so a value with single spaces and colons passed through raw and could
// forge a further `label : value` pair after the line it sits on. That needs no local
// privilege: context.project_root is minted from the SessionStart cwd and
// validateContext rejects only NUL, CR and LF in it, so anyone who supplies the
// directory name the user opens Claude Code in controls this substring. A real path
// containing " : " renders JSON-quoted instead, which is still readable.
const PAIR_SEPARATOR = / : /;
// The allowlist above admits \p{L}, and some LETTERS are Default_Ignorable — U+3164
// HANGUL FILLER, U+115F, U+1160, U+FFA0 — which render as blank in a terminal. A value
// like `/tmp/x<U+3164>:<U+3164>y` therefore matches the class, contains NO space at
// all so neither DOUBLE_SPACE nor PAIR_SEPARATOR fires, and would be returned raw
// while LOOKING like a further `label : value` row. The header's argument ("none of
// them is a letter, a number or a combining mark") does not cover an invisible letter.
// The escaping branch already folds these through NON_ASCII, so the fix is to route
// them there rather than to widen the fold.
const INVISIBLE = /\p{Default_Ignorable_Code_Point}/u;
const NON_ASCII = new RegExp('[\\u007f-\\uffff]', 'g');
const SPACE_RUN = / {2,}/g;

const safeDisplayValue = (value) => {
  const text = String(value);
  if (SAFE_DISPLAY.test(text) && !INVISIBLE.test(text) && !DOUBLE_SPACE.test(text) && !PAIR_SEPARATOR.test(text)) {
    return text;
  }
  return JSON.stringify(text)
    .replace(NON_ASCII, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'))
    // The DOUBLE_SPACE invariant applies to BOTH branches. It used to guard only the
    // fast path, so `/tmp/a"b  project : x` was rendered through JSON.stringify with
    // the two-space run and the colon intact — the exact forgery the fast-path guard
    // exists to stop, arriving through the branch meant to be the safer one. Single
    // spaces survive, so an ordinary quoted path stays readable.
    .replace(SPACE_RUN, (run) => '\\u0020'.repeat(run.length));
};

// SAFE_DISPLAY is read BY NAME by tests/structure/session-adopt-report-v1.test.js,
// through the adoption report's re-export surface, which is why it is public.
// DOUBLE_SPACE and NON_ASCII are exported only to KEEP that re-export surface intact —
// the report's export list carried them before the rule moved here, and removing them
// would be an unrelated break. They are internals of safeDisplayValue, not public
// rules, and no test reads either of them: an earlier version of this comment claimed
// the suite "pins all three by name", which was false for two of the three.
module.exports = {
  SAFE_DISPLAY,
  DOUBLE_SPACE,
  NON_ASCII,
  safeDisplayValue,
};
