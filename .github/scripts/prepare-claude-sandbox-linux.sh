#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"

if [ "$(uname -s)" != Linux ]; then
  echo 'Claude sandbox preparation requires a Linux runner' >&2
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
  echo 'Claude sandbox preparation requires apt-get and sudo' >&2
  exit 1
fi

sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends bubblewrap socat

test "$(command -v bwrap)" = /usr/bin/bwrap
command -v socat >/dev/null
bwrap --version | grep -Eq '^bubblewrap [0-9]+\.[0-9]+'
socat -V 2>&1 | grep -Eq '^socat version [0-9]+\.[0-9]+'
dpkg-query -W -f='${binary:Package}=${Version}\n' bubblewrap socat

APPARMOR_USERNS=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
if [ -e "$APPARMOR_USERNS" ]; then
  APPARMOR_RESTRICT="$(cat "$APPARMOR_USERNS")"
  case "$APPARMOR_RESTRICT" in
    0)
      ;;
    1)
      command -v apparmor_parser >/dev/null
      sudo tee /etc/apparmor.d/bwrap >/dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF
      sudo apparmor_parser -r /etc/apparmor.d/bwrap
      ;;
    *)
      echo "Unexpected AppArmor user-namespace policy: $APPARMOR_RESTRICT" >&2
      exit 1
      ;;
  esac
fi

# A version probe is insufficient: exercise both a basic sandbox and the
# network namespace Claude uses for Bash isolation.
/usr/bin/bwrap --ro-bind / / /bin/true
/usr/bin/bwrap --unshare-net --ro-bind / / /bin/true

# Exercise the exact production builder with its narrow read-only runtime
# surface. The smoke proves the shared-network sandbox has usable NSS/resolver
# inputs without depending on external DNS availability.
node "$REPO_ROOT/evals/session-control/tests/linux-sandbox-runtime-smoke.js"

# Prove the properties the upgrade gate relies on: sensitive sandbox arguments
# travel through a private descriptor instead of the host command line, and a
# detached, TERM-ignoring grandchild cannot outlive the PID namespace's initial
# process.
ESCAPE_PROBE_ROOT="$(mktemp -d)"
ESCAPE_BWRAP_PID=
escape_probe_cleanup() {
  if [ -n "${ESCAPE_BWRAP_PID:-}" ] &&
    kill -0 "$ESCAPE_BWRAP_PID" 2>/dev/null; then
    kill "$ESCAPE_BWRAP_PID" 2>/dev/null || true
    wait "$ESCAPE_BWRAP_PID" 2>/dev/null || true
  fi
  rm -rf "$ESCAPE_PROBE_ROOT"
}
trap escape_probe_cleanup EXIT
ESCAPE_SENTINEL="$ESCAPE_PROBE_ROOT/escaped"
ESCAPE_READY="$ESCAPE_PROBE_ROOT/ready"
ESCAPE_SECRET="zensu-bwrap-fd3-canary-${RANDOM}-${RANDOM}-$$"

# Bubblewrap's --args input expands options, not the trailing command. Keep the
# command on the host argv exactly as the production builder does, while the
# sensitive environment options cross only the inherited descriptor.
# The quoted variables below intentionally expand only inside the sandbox.
# shellcheck disable=SC2016
/usr/bin/bwrap \
  --unshare-user \
  --unshare-pid \
  --die-with-parent \
  --new-session \
  --ro-bind / / \
  --dev /dev \
  --bind "$ESCAPE_PROBE_ROOT" "$ESCAPE_PROBE_ROOT" \
  --args 3 \
  -- /bin/sh -c \
  'case "${ANTHROPIC_API_KEY:-}" in zensu-bwrap-fd3-canary-*) ;; *) exit 97 ;; esac
   setsid /bin/sh -c '"'"'trap "" TERM HUP INT; sleep 4; echo escaped > "$1"'"'"' sh "$1" >/dev/null 2>&1 &
   echo ready > "$2"
   sleep 2' \
  sh "$ESCAPE_SENTINEL" "$ESCAPE_READY" \
  3< <(
    printf '%s\0' \
      --clearenv \
      --setenv PATH /usr/bin:/bin \
      --setenv ANTHROPIC_API_KEY "$ESCAPE_SECRET"
  ) &
ESCAPE_BWRAP_PID=$!

for _ in $(seq 1 100); do
  if [ -e "$ESCAPE_READY" ]; then
    break
  fi
  if ! kill -0 "$ESCAPE_BWRAP_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [ ! -e "$ESCAPE_READY" ]; then
  kill "$ESCAPE_BWRAP_PID" 2>/dev/null || true
  wait "$ESCAPE_BWRAP_PID" 2>/dev/null || true
  ESCAPE_BWRAP_PID=
  echo 'Bubblewrap FD argument probe did not become ready' >&2
  exit 1
fi

ESCAPE_CMDLINE="$(tr '\0' '\n' < "/proc/$ESCAPE_BWRAP_PID/cmdline")"
if grep -Fq -- "$ESCAPE_SECRET" <<<"$ESCAPE_CMDLINE"; then
  echo 'Bubblewrap FD argument probe leaked its credential into argv' >&2
  exit 1
fi
if ! grep -Fxq -- '--args' <<<"$ESCAPE_CMDLINE" ||
  ! grep -Fxq -- '3' <<<"$ESCAPE_CMDLINE"; then
  echo 'Bubblewrap FD argument probe did not retain the expected host argv' >&2
  exit 1
fi

for _ in $(seq 1 100); do
  if ! kill -0 "$ESCAPE_BWRAP_PID" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if kill -0 "$ESCAPE_BWRAP_PID" 2>/dev/null; then
  kill "$ESCAPE_BWRAP_PID" 2>/dev/null || true
  wait "$ESCAPE_BWRAP_PID" 2>/dev/null || true
  ESCAPE_BWRAP_PID=
  echo 'Bubblewrap FD argument probe exceeded its bounded runtime' >&2
  exit 1
fi
if ! wait "$ESCAPE_BWRAP_PID"; then
  ESCAPE_BWRAP_PID=
  echo 'Bubblewrap FD argument probe failed' >&2
  exit 1
fi
ESCAPE_BWRAP_PID=

for _ in $(seq 1 60); do
  if [ -e "$ESCAPE_SENTINEL" ]; then
    break
  fi
  sleep 0.05
done
test ! -e "$ESCAPE_SENTINEL"

# Nested namespaces are required because the outer namespace contains Claude
# while every candidate hook gets a second networkless PID boundary.
/usr/bin/bwrap \
  --unshare-user \
  --unshare-pid \
  --die-with-parent \
  --new-session \
  --ro-bind / / \
  --proc /proc \
  --dev /dev \
  /usr/bin/bwrap \
    --unshare-user \
    --unshare-pid \
    --unshare-net \
    --die-with-parent \
    --new-session \
    --ro-bind / / \
    --proc /proc \
    --dev /dev \
    /bin/true
