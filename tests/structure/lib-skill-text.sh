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

skill_text_control_assignments() {
  local dir="$1" parser="$2"
  [ -f "$dir/SKILL.md" ] || return 1
  if [ -d "$dir/references" ]; then
    set -- "$dir/SKILL.md" "$dir"/references/*.md
  else
    set -- "$dir/SKILL.md"
  fi
  node - "$dir" "$parser" "$@" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [dir, parser, ...files] = process.argv.slice(2);
const { detectControlMutation } = require(path.resolve(parser));
const refused = (name) => detectControlMutation(`${name}=x true`) !== '';
if (!refused('CLAUDE_CODE_SESSION_ID')) process.exit(3);
const verdict = new Map();
const hits = [];
for (const file of files) {
  const rel = path.relative(dir, file).split(path.sep).join('/');
  fs.readFileSync(file, 'utf8').split('\n').forEach((line, i) => {
    for (const [, name] of line.matchAll(/(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=/g)) {
      if (!verdict.has(name)) verdict.set(name, refused(name));
      if (verdict.get(name)) hits.push(`${rel}:${i + 1}: ${name}`);
    }
  });
}
if (hits.length) process.stdout.write(`${hits.join('\n')}\n`);
NODE
}
