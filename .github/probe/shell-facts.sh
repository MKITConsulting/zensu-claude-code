#!/bin/bash
set -u
echo "BASH_VERSION=$BASH_VERSION"
echo "uname=$(uname -a)"
echo "shell pid=$$"
if [ -r "/proc/$$/winpid" ]; then
  echo "shell winpid=$(cat "/proc/$$/winpid")"
fi
for i in 1 2 3; do
  node -e 'process.stdout.write(`node run ${process.argv[1]}: pid=${process.pid} ppid=${process.ppid}\n`)' "$i"
done
keeper_source='process.stdout.write(`${process.pid} ${process.ppid}\n`); require("node:fs").readFileSync(0);'
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  eval 'coproc KEEPER { node -e "$keeper_source"; }'
  eval 'keeper_read_fd=${KEEPER[0]}; keeper_write_fd=${KEEPER[1]}; keeper_pid=$KEEPER_PID'
  read -r keeper_line <&"$keeper_read_fd"
  echo "coproc keeper node pid/ppid: $keeper_line (bash-side coproc pid: $keeper_pid)"
  eval "exec ${keeper_write_fd}>&-"
  wait "$keeper_pid" 2>/dev/null
fi
former_ppid="$(node -e 'process.stdout.write(String(process.ppid))')"
node -e '
  const pid = Number(process.argv[1]);
  let state;
  try {
    process.kill(pid, 0);
    state = "alive";
  } catch (error) {
    state = error.code;
  }
  process.stdout.write(`windows parent ${pid} of an exited node child: ${state}\n`);
' "$former_ppid"
for tool in powershell.exe pwsh.exe cscript.exe wmic.exe; do
  printf '%s -> %s\n' "$tool" "$(command -v "$tool" 2>/dev/null || echo absent)"
done
