#!/bin/bash
set -euo pipefail

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
