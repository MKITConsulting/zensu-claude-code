#!/bin/bash

_ZENSU_AUTOPILOT_LEASE_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/hooks/lib/session-control-core-v1.js"

with_autopilot_lease() {
  local root="$1"
  shift
  node -e '
    const path = require("node:path");
    const { spawnSync } = require("node:child_process");
    const [corePath, root, command, ...args] = process.argv.slice(1);
    const core = require(corePath);
    const stateDir = path.join(root, ".zensu", "state");
    const binding = { lockDirectory: stateDir, resourcePath: path.join(stateDir, "autopilot"), ownerPid: process.pid };
    const lease = core.acquireExternalProcessLock(binding);
    let result;
    try {
      result = spawnSync(command, args, { stdio: "inherit" });
    } finally {
      core.releaseExternalProcessLock({ ...binding, token: lease.token });
    }
    process.exit(typeof result.status === "number" ? result.status : 1);
  ' "$_ZENSU_AUTOPILOT_LEASE_CORE" "$root" "$@"
}

autopilot_lease_hold_start() {
  local root="$1" signal_dir="$2" tries=0
  mkdir -p "$signal_dir" || return 1
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const [corePath, root, signalDir] = process.argv.slice(1);
    const core = require(corePath);
    const stateDir = path.join(root, ".zensu", "state");
    const binding = { lockDirectory: stateDir, resourcePath: path.join(stateDir, "autopilot"), ownerPid: process.pid };
    const lease = core.acquireExternalProcessLock(binding);
    fs.writeFileSync(path.join(signalDir, "ready"), String(process.pid));
    const pause = new Int32Array(new SharedArrayBuffer(4));
    const deadline = Date.now() + 120000;
    while (!fs.existsSync(path.join(signalDir, "release")) && Date.now() < deadline) {
      Atomics.wait(pause, 0, 0, 50);
    }
    core.releaseExternalProcessLock({ ...binding, token: lease.token });
    fs.writeFileSync(path.join(signalDir, "done"), "released");
  ' "$_ZENSU_AUTOPILOT_LEASE_CORE" "$root" "$signal_dir" </dev/null >/dev/null 2>&1 &
  while [ ! -f "$signal_dir/ready" ] && [ "$tries" -lt 600 ]; do
    tries=$((tries + 1))
    sleep 0.05
  done
  [ -f "$signal_dir/ready" ]
}

autopilot_lease_hold_stop() {
  local signal_dir="$1" tries=0
  : > "$signal_dir/release"
  while [ ! -f "$signal_dir/done" ] && [ "$tries" -lt 600 ]; do
    tries=$((tries + 1))
    sleep 0.05
  done
  [ -f "$signal_dir/done" ]
}
