#!/bin/bash

WO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WO_FAKE_JS="$WO_LIB_DIR/lib-fake-zensu-work.js"

wo_fake_install() {
  local bin_dir="$1"
  mkdir -p "$bin_dir" || return 1
  {
    printf '#!/bin/bash\n'
    printf 'exec node %q "$@"\n' "$WO_FAKE_JS"
  } > "$bin_dir/zensu" || return 1
  chmod +x "$bin_dir/zensu"
}

wo_fake_seed() {
  local state_file="$1" order_id="$2" client_session="$3" plan_approval="${4:-auto}" kind="${5:-implement}"
  STATE_FILE="$state_file" ORDER_ID="$order_id" CLIENT_SESSION="$client_session" \
    PLAN_APPROVAL="$plan_approval" KIND="$kind" node -e '
    const fs = require("fs");
    const now = Date.now();
    const state = {
      token: "zst_fake_session_token",
      printCodes: true,
      mode: "live",
      now: null,
      staleAttempt: false,
      runtimeCap: false,
      gateRefusal: null,
      confirmWindowSeconds: 120,
      failNext: [],
      approvals: [],
      events: [],
      historyEvents: [],
      questions: [],
      followups: [],
      policy: { plan_approval: process.env.PLAN_APPROVAL, lease_minutes: 30, max_questions_per_order: 5, max_order_runtime_minutes: 240 },
      plan: { id: "11111111-1111-4111-8111-111111111111", base_branch: "main", integration_branch: "main", repository: "github.com/acme/widgets" },
      order: {
        id: process.env.ORDER_ID,
        work_plan_id: "11111111-1111-4111-8111-111111111111",
        repository: "github.com/acme/widgets",
        kind: process.env.KIND,
        status: "claimed",
        blocked_kind: null,
        blocked_reason: null,
        attempt: 1,
        failed_attempts: 0,
        max_attempts: 3,
        client_session_id: process.env.CLIENT_SESSION,
        claim_confirmed_at: new Date(now).toISOString(),
        lease_expires_at: now + 1800000,
        heartbeat_at: null,
        spec_hash: "a".repeat(64),
        spec_stale: false,
        branch: null,
        pr_url: null,
        pr_number: null,
        head_sha: null,
        autopilot_run_id: null
      }
    };
    fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(state, null, 2) + "\n");
  '
}

wo_fake_set() {
  local state_file="$1" expression="$2"
  STATE_FILE="$state_file" EXPRESSION="$expression" node -e '
    const fs = require("fs");
    const state = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
    Function("state", process.env.EXPRESSION)(state);
    fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(state, null, 2) + "\n");
  '
}

wo_fake_get() {
  local state_file="$1" expression="$2"
  STATE_FILE="$state_file" EXPRESSION="$expression" node -e '
    const state = JSON.parse(require("fs").readFileSync(process.env.STATE_FILE, "utf8"));
    const value = Function("state", `return (${process.env.EXPRESSION})`)(state);
    process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
  '
}

wo_calls_matching() {
  local calls_file="$1" pattern="$2"
  [ -f "$calls_file" ] || { printf '0'; return 0; }
  CALLS="$calls_file" PATTERN="$pattern" node -e '
    const lines = require("fs").readFileSync(process.env.CALLS, "utf8").split("\n").filter(Boolean);
    const re = new RegExp(process.env.PATTERN);
    process.stdout.write(String(lines.map((line) => JSON.parse(line).argv.join(" ")).filter((line) => re.test(line)).length));
  '
}
