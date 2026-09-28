#!/bin/bash
set -u

# The three suites that exercise skills/session-trail/scripts/*.mjs, driven as ONE
# process tree so a single c8 run measures all of them.
#
# This is a FILE rather than a `bash -c "…"` argument inside the npm script, and
# the reason is the one that made the include glob a finding in the first place:
# npm runs a script through `sh -c` on POSIX and through cmd.exe on Windows, and
# the two disagree about every quoting form there is. The double-quoted inline
# command reached c8 as a single FILENAME and it tried to open it; a single-quoted
# one would be literal characters to cmd.exe. A file name needs no quoting on
# either host.
#
# Deliberately NOT named `test-*.sh`: tests/run-all.sh discovers that prefix, and
# this only drives suites the runner already finds on their own — registering it
# would run all three a second time in every tree run.

HERE="$(cd "$(dirname "$0")" && pwd)"

RC=0
# Spelled out rather than built from a `for suite in lineage verdict skill` loop:
# the coverage pin in test-session-trail-lineage.sh reads THIS file to check which
# suites the measured run actually drives, and an interpolated name is invisible to
# it. Greppability is the point of the list.
for suite in \
  "$HERE/test-session-trail-lineage.sh" \
  "$HERE/test-session-trail-verdict.sh" \
  "$HERE/test-session-trail-skill.sh"
do
  # Every suite runs even when an earlier one fails. A report assembled from a
  # partial run understates exactly the lines the failing suite covers, and `&&`
  # would have made that the normal outcome on a red tree — the moment the number
  # is most likely to be read.
  bash "$suite" || RC=1
done
exit "$RC"
