#!/bin/bash

# Trusted-payload principal check for hooks that carry main-thread authority.
# Explicit, partial, empty, or malformed agent metadata can never be promoted
# into main-v1 by ambient environment. Keep the classifier centralized with
# Session Control and bind it to the hook event that owns the authority.
zensu_hook_principal() {
  local payload="${1:-}" expected_event="${2:-}" lib_dir principal_lib
  [ -n "$expected_event" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  principal_lib="$lib_dir/claude-principal-v1.js"
  [ -f "$principal_lib" ] && [ ! -L "$principal_lib" ] || return 1
  (
    cd -P -- "$lib_dir" || exit 1
    printf '%s' "$payload" | EXPECTED_EVENT="$expected_event" node -e '
    try {
      const payload=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");
      if(!payload||typeof payload!=="object"||Array.isArray(payload))process.exit(2);
      if(payload.hook_event_name!==process.env.EXPECTED_EVENT)process.exit(2);
      const principals=require("./claude-principal-v1.js");
      process.stdout.write(principals.classifyPreToolPayload(payload));
    } catch (_) { process.exit(2); }
    ' 2>/dev/null
  )
}

zensu_hook_is_main_principal() {
  [ "$(zensu_hook_principal "${1:-}" "${2:-}" 2>/dev/null)" = "main-v1" ]
}

export -f zensu_hook_principal zensu_hook_is_main_principal 2>/dev/null || true
