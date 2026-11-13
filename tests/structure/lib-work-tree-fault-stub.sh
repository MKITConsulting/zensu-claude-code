#!/bin/bash

transport_fault_stub() {
  local dir="$1" name="$2"
  case "$name" in
    (''|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  WORK_TREE_FAULT_REAL_MKTEMP="$(command -v mktemp)" || return 1
  export WORK_TREE_FAULT_REAL_MKTEMP
  mkdir -p "$dir" || return 1
  printf '#!/bin/sh\nTRANSPORT_FAULT_NAME=%s\n' "$name" > "$dir/mktemp" || return 1
  cat >> "$dir/mktemp" <<'STUB'
if [ "${1:-}" = "-d" ]; then
  d="$("$WORK_TREE_FAULT_REAL_MKTEMP" -d)" || exit 1
  mkdir "$d/$TRANSPORT_FAULT_NAME" || exit 1
  printf '%s\n' "$d"
  exit 0
fi
exec "$WORK_TREE_FAULT_REAL_MKTEMP" "$@"
STUB
  chmod +x "$dir/mktemp"
}

work_tree_fault_stub() {
  transport_fault_stub "$1" work-tree-fault
}
