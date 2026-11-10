#!/bin/bash

work_tree_fault_stub() {
  local dir="$1"
  WORK_TREE_FAULT_REAL_MKTEMP="$(command -v mktemp)" || return 1
  export WORK_TREE_FAULT_REAL_MKTEMP
  mkdir -p "$dir" || return 1
  cat > "$dir/mktemp" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "-d" ]; then
  d="$("$WORK_TREE_FAULT_REAL_MKTEMP" -d)" || exit 1
  mkdir "$d/work-tree-fault" || exit 1
  printf '%s\n' "$d"
  exit 0
fi
exec "$WORK_TREE_FAULT_REAL_MKTEMP" "$@"
STUB
  chmod +x "$dir/mktemp"
}
