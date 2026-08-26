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
// TWO exports because there are genuinely TWO rules, and conflating them was part of
// the original defect:
//
//   safeDisplayValue — the FULL rule, and the one BOTH shipped callers use. It adds
//     the pair-forgery guard (a two-space run, or a ` : ` sequence, would let the
//     value fake a further row beneath the one it sits on) on top of a positive
//     letter/number/mark allowlist. Both the adoption report and the doctor report
//     render `label : value` rows the model is told to read verbatim, so both need
//     it — the doctor's binding line is prose, but it sits in a report whose other
//     rows are pairs, and a forged pair there is exactly as convincing.
//
//   foldDisplayHiders — the NARROW rule, and STRICTLY WEAKER. It removes only the
//     characters that can hide or reorder the rest of a line and leaves everything
//     else readable. It is NOT a substitute for the rule above; it exists because
//     the doctor renderer previously carried this fold as a private fallback copy,
//     and naming it here is what keeps it from being re-authored a third time.
//
// Do not reach for the narrow rule to avoid JSON-quoting an ugly path. Losing
// readability is a worse message; losing the pair guard is a wrong one.

// Bidi overrides and isolates (\p{Cf}) plus the line and paragraph separators
// (\p{Zl}/\p{Zp}). These are the characters that can HIDE the rest of a line.
const DISPLAY_HIDERS = new RegExp('[\\u202a-\\u202e\\u2066-\\u2069\\u2028\\u2029]', 'g');

const foldDisplayHiders = (value) => String(value == null ? '' : value).replace(DISPLAY_HIDERS, '?');

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
const NON_ASCII = new RegExp('[\\u007f-\\uffff]', 'g');
const SPACE_RUN = / {2,}/g;

const safeDisplayValue = (value) => {
  const text = String(value);
  if (SAFE_DISPLAY.test(text) && !DOUBLE_SPACE.test(text) && !PAIR_SEPARATOR.test(text)) {
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

// DOUBLE_SPACE and NON_ASCII are exported for the same reason SAFE_DISPLAY is:
// tests/structure/session-adopt-report-v1.test.js pins all three by name through the
// adoption report's own export surface, and that surface now re-exports them from
// here. They are internals of safeDisplayValue, not a second public rule.
module.exports = {
  DISPLAY_HIDERS,
  foldDisplayHiders,
  SAFE_DISPLAY,
  DOUBLE_SPACE,
  NON_ASCII,
  safeDisplayValue,
};
