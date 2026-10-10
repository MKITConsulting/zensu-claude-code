#!/bin/bash
skill_text_file() {
  local dir="$1" out
  [ -f "$dir/SKILL.md" ] || return 1
  out="$(mktemp "${TMPDIR:-/tmp}/zensu-skill-text.XXXXXX")" || return 1
  if [ -d "$dir/references" ]; then
    cat "$dir/SKILL.md" "$dir"/references/*.md > "$out" || { rm -f "$out"; return 1; }
  else
    cat "$dir/SKILL.md" > "$out" || { rm -f "$out"; return 1; }
  fi
  printf '%s\n' "$out"
}
