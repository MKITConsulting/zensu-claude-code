#!/usr/bin/env bash
# zensu-safe-render.sh — ONE screen for every claim-derived value this plugin
# renders into a verdict a model is told to relay.
#
# WHY IT IS SOURCED RATHER THAN COPIED. It lived as two 25-line near-duplicates,
# `render_claim_root` in zensu-edit-landing.sh and `_tc_render_stem` in
# zensu-log.sh, documented as carrying the same rules — and they had already
# diverged on the empty-value arm, which one withheld and the other rendered
# raw. Both were also wrong in the same two ways at once, so a cross-file pin
# comparing them would have reported agreement about a rule set that did not
# match its own owner. One implementation is what removes the class; a pin over
# two copies only reports it.
#
# THE RULES, and the RESPONSE is part of each rule rather than a uniform one.
# The owner is `forgesReportRow` in hooks/lib/zensu-doctor-report.js, which
# tests FIVE rules inside one fail-closed catch, with the control byte and the
# backtick layered on by `claimRootRenderable`. This is a SUBSET: the three
# named Unicode row-forgery classes (separator-adjacent modifier letter,
# Default_Ignorable, orphan combining mark) need a JS regex a POSIX shell `case`
# cannot express. Say subset, never parity, and never a numeral — the two
# previous comments said SEVEN and enumerated six.
#
#   ESCAPED, because the value is still worth reading:
#     `:` -> `:`   — the pair separator. The owner rule is `/ :|: /`, and
#                          every emit here spells `label: value` with no space
#                          before the colon, so the old `" : "` arm guarded the
#                          one spelling the emits do not use. Escaping rather
#                          than withholding matters because the channel exists
#                          to name a file the author must go and land: a colon
#                          in a filename is ordinary, and withholding costs the
#                          reader the only thing the line is for.
#     runs of spaces collapsed to one — the double-space rule, same reasoning.
#
#   WITHHELD, because the value cannot be rendered at all:
#     a backtick, and a control byte. The control class is spelled BY BYTE and
#     not as `[[:cntrl:]]`: under the `LC_ALL=C` pinned below that class is C0
#     plus DEL only, while the owner covers C1 and U+2028/U+2029 and its comment
#     names those as "the ones a forged report line would use".
#
# THE LOCALE IS PINNED. `${#v}` and `${v:0:N}` count and cut CHARACTERS under a
# UTF-8 locale and BYTES under C, and `[[:cntrl:]]` matches the C1 range under
# an ISO8859 one — so unpinned, the same code did different things on the same
# input, and a non-interactive shell with no `LANG` took the byte branch. bash
# applies an assignment to `LC_ALL` immediately without an export, so `local`
# scopes the pin to the call.

ZENSU_RENDER_MAX=200

zensu_safe_render() {
  local v="$1" LC_ALL=C
  case "$v" in
    ''|*[[:cntrl:]\`]*|*$'\302'[$'\200'-$'\237']*|*$'\342\200\250'*|*$'\342\200\251'*)
      printf '%s' "(withheld — unsafe to render)"; return 0 ;;
  esac
  # Escape before the bound, so the bound applies to what is rendered.
  v="${v//:/\\u003a}"
  while :; do
    case "$v" in
      *"  "*) v="${v//  / }" ;;
      *) break ;;
    esac
  done
  if [ "${#v}" -gt "$ZENSU_RENDER_MAX" ]; then
    v="${v:0:$ZENSU_RENDER_MAX}"
    # Put back a UTF-8 sequence the byte cut split. State this exactly, because
    # the two previous comments asserted the opposite: a COMPLETE character
    # also ends in a continuation byte, so this loop can remove a whole valid
    # character as well as an incomplete tail. That is acceptable — one
    # character off a value already marked truncated with `…` — and it is the
    # price of not emitting an invalid sequence. It is never more than one.
    while [ -n "$v" ]; do
      case "$v" in
        *[$'\200'-$'\277']) v="${v%?}" ;;
        *[$'\300'-$'\377']) v="${v%?}"; break ;;
        *) break ;;
      esac
    done
    printf '%s…' "$v"
    return 0
  fi
  printf '%s' "$v"
}
