#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
source "$ROOT/tests/structure/lib-unit-registry.sh"
unit_run "$ROOT/tests/structure/ai-work-capture.test.js"
unit_registry_done
