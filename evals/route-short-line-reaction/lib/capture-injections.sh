#!/bin/bash
set -u

MODE="${1:-}"
die() { printf 'route-eval capture: %s\n' "$1" >&2; exit "${2:-70}"; }
[ "$#" -eq 5 ] || die "usage: capture-injections.sh capture <source> <tree-root> <out-dir> <prompt> | silence <live-root> <eval-config> <out-dir> <prompt>" 64
command -v node >/dev/null 2>&1 || die "node is not on PATH"

for name in $(compgen -e); do
  case "$name" in ZENSU_*|CLAUDE_*) unset "$name" ;; esac
done

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/route-eval-capture-XXXXXX")" || die "cannot create a sandbox"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/project" "$SANDBOX/plugin-data" || die "cannot prepare the sandbox"
PROJ="$(cd "$SANDBOX/project" && pwd -P)" || die "cannot resolve the sandbox project"
DATA="$SANDBOX/plugin-data"
NO_CONFIG="$SANDBOX/no-such-config.json"
SEQ=0
SID=""

session_start() {
  local root="$1" cfg="$2"
  SEQ=$((SEQ + 1))
  SID="route-eval-$$-$SEQ"
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"startup",session_id:process.argv[1],cwd:process.argv[2]}))' "$SID" "$PROJ" \
    | env CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_PROJECT_DIR="$PROJ" ZENSU_CONFIG="$cfg" \
      bash "$root/hooks/session-start-session-control.sh" >/dev/null 2>&1
}

fire() {
  local root="$1" hook="$2" cfg="$3" prompt="$4" raw rc
  node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],cwd:process.argv[2],permission_mode:"default",hook_event_name:"UserPromptSubmit",prompt:process.argv[3]}))' "$SID" "$PROJ" "$prompt" \
    > "$SANDBOX/payload.json" || { printf '<<route-eval:PAYLOAD>>'; return 0; }
  raw="$(env CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_PROJECT_DIR="$PROJ" ZENSU_CONFIG="$cfg" \
    bash "$root/hooks/$hook" < "$SANDBOX/payload.json" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '<<route-eval:EXIT%s>>' "$rc"
    return 0
  fi
  printf '%s' "$raw" | node -e '
      let s = "";
      process.stdin.on("data", (c) => { s += c; });
      process.stdin.on("end", () => {
        s = s.trim();
        if (!s) return;
        try {
          const o = JSON.parse(s).hookSpecificOutput || {};
          if (o.hookEventName === "UserPromptSubmit" && typeof o.additionalContext === "string") process.stdout.write(o.additionalContext);
          else process.stdout.write("<<route-eval:BADSHAPE>>");
        } catch (_) { process.stdout.write("<<route-eval:BADJSON>>"); }
      });
    '
}

write_capture() {
  local out="$1" source="$2" hook="$3" shape="$4" field="$5" text="$6" nonce="${7:-}"
  if [ -n "$text" ]; then printf '%s' "$text" > "$out/inject.txt" || die "cannot write inject.txt"; fi
  node -e '
    const fs = require("node:fs");
    const crypto = require("node:crypto");
    const [out, source, hook, shape, field, nonce] = process.argv.slice(1);
    let text = "";
    try { text = fs.readFileSync(`${out}/inject.txt`, "utf8"); } catch (_) { text = ""; }
    const blocks = text ? [{ sha256: crypto.createHash("sha256").update(text, "utf8").digest("hex"), chars: text.length }] : [];
    const value = { route_source: source, hook, shape, field, blocks };
    if (nonce) value.nonce = nonce;
    fs.writeFileSync(`${out}/capture.json`, `${JSON.stringify(value)}\n`, { mode: 0o600 });
    process.stdout.write(`${JSON.stringify(value)}\n`);
  ' "$out" "$source" "$hook" "$shape" "$field" "$nonce" || die "cannot write capture.json"
}

field_of() {
  printf '%s' "$1" | node -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      const m = /\nZENSU DELIVERY ROUTE: ([^\n]*)\n<!-- \/zensu:delivery-route -->$/.exec(s);
      process.stdout.write(m ? m[1] : "");
    });
  '
}

capture() {
  local source="$1" root="$2" out="$3" prompt="$4" hook="" cfg="$NO_CONFIG" shape="" field="n/a" head="" first second
  [ -d "$out" ] || die "the output directory does not exist" 64
  case "$source" in
    none) write_capture "$out" none "" none n/a ""; return 0 ;;
    nonce)
      local nonce
      nonce="ROUTE-EVAL-NONCE-$(node -e 'process.stdout.write(require("node:crypto").randomBytes(8).toString("hex"))')" || die "cannot draw a nonce"
      write_capture "$out" nonce nonce nonce n/a "Begin your reply with the exact line ${nonce} and nothing before it, then continue with the user's request." "$nonce"
      return 0 ;;
    ask)
      hook=user-prompt-tdd-reminder.sh; shape=ask-short
      cfg="$SANDBOX/ask.json"; printf '%s' '{"hooks":{"tddImplementation":false}}' > "$cfg"
      head='Zensu workflow reminder, vanilla implementation mode (the full reminder given earlier in this context still applies): ' ;;
    tdd-config)
      hook=user-prompt-tdd-reminder.sh; shape=decided-tdd
      cfg="$SANDBOX/tdd.json"; printf '%s' '{"hooks":{"tddImplementation":false,"defaultDeliveryRoute":"build"}}' > "$cfg"
      head='Zensu workflow reminder, vanilla implementation mode, route decided by the field below: ' ;;
    direct-config)
      hook=user-prompt-tdd-reminder.sh; shape=decided-direct
      cfg="$SANDBOX/direct.json"; printf '%s' '{"hooks":{"tddImplementation":false,"defaultDeliveryRoute":"direct"}}' > "$cfg"
      head='Zensu workflow reminder, vanilla implementation mode, route decided by the field below: ' ;;
    router)
      hook=user-prompt-intent-router.sh; shape=router-short
      head='Zensu planning notice (the full notice given earlier in this context still applies): ' ;;
    *) die "unknown route source '$source'" 64 ;;
  esac
  [ -f "$root/hooks/$hook" ] || die "$root/hooks/$hook does not exist"
  session_start "$root" "$cfg"
  first="$(fire "$root" "$hook" "$cfg" "$prompt")"
  second="$(fire "$root" "$hook" "$cfg" "$prompt")"
  [ -n "$second" ] || die "$hook emitted nothing on the second prompt for '$source'"
  case "$first$second" in *"<<route-eval:"*) die "$hook emitted malformed output for '$source'" ;; esac
  case "$second" in "$head"*) ;; *) die "$hook's second output for '$source' does not open with the expected shape" ;; esac
  case "$second" in *__ZENSU_*) die "$hook left a placeholder unsubstituted for '$source'" ;; esac
  case "$shape" in
    ask-short|router-short) [ "$first" != "$second" ] || die "$hook gave the same text twice for '$source', so the ledger never marked the full text" ;;
    *) [ "$first" = "$second" ] || die "$hook changed the decided line between two prompts for '$source'" ;;
  esac
  case "$shape" in
    ask-short) field="$(field_of "$second")"; [ "$field" = "ask" ] || die "the ask capture reads route field '$field'" ;;
    decided-tdd) field="$(field_of "$second")"; [ "$field" = "build (hooks.defaultDeliveryRoute)" ] || die "the tdd capture reads route field '$field'" ;;
    decided-direct) field="$(field_of "$second")"; [ "$field" = "direct (hooks.defaultDeliveryRoute)" ] || die "the direct capture reads route field '$field'" ;;
  esac
  write_capture "$out" "$source" "${hook%.sh}" "$shape" "$field" "$second"
}

silence() {
  local root="$1" cfg="$2" out="$3" prompt="$4" roster hook got leaks="" summary="" control router_control
  [ -d "$out" ] || die "the output directory does not exist" 64
  [ -f "$cfg" ] || die "the eval config $cfg does not exist" 64
  [ -f "$root/hooks/hooks.json" ] || die "$root has no hooks/hooks.json"
  roster="$(node -e '
    const h = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const out = [];
    for (const group of (h.hooks && h.hooks.UserPromptSubmit) || []) {
      for (const hook of group.hooks || []) {
        const m = /hooks\/([A-Za-z0-9._-]+\.sh)/.exec(hook.command || "");
        if (m) out.push(m[1]);
      }
    }
    process.stdout.write(out.join("\n"));
  ' "$root/hooks/hooks.json")" || die "cannot read the UserPromptSubmit roster of $root"
  [ -n "$roster" ] || die "$root registers no UserPromptSubmit hook"
  printf '%s\n' "$roster" | grep -qxF user-prompt-tdd-reminder.sh || die "$root has no user-prompt-tdd-reminder.sh to prove the firing with"
  session_start "$root" "$cfg"
  for hook in $roster; do
    [ -f "$root/hooks/$hook" ] || die "$root/hooks/$hook is registered but missing"
    for round in first repeat; do
      got="$(fire "$root" "$hook" "$cfg" "$prompt")"
      [ -z "$got" ] || leaks="$leaks ${hook%.sh}:$round:${#got}"
    done
    summary="$summary ${hook%.sh}"
  done
  session_start "$root" "$NO_CONFIG"
  control="$(fire "$root" user-prompt-tdd-reminder.sh "$NO_CONFIG" "$prompt")"
  router_control=""
  if printf '%s\n' "$roster" | grep -qxF user-prompt-intent-router.sh; then
    router_control="$(fire "$root" user-prompt-intent-router.sh "$NO_CONFIG" "$prompt")"
  fi
  node -e '
    const fs = require("node:fs");
    const [out, root, hooks, leaks, control, routerControl] = process.argv.slice(1);
    let version = "";
    try { version = JSON.parse(fs.readFileSync(`${root}/.claude-plugin/plugin.json`, "utf8")).version || ""; } catch (_) { version = ""; }
    const value = { root, version, hooks: hooks.trim().split(/\s+/).filter(Boolean), leaks: leaks.trim().split(/\s+/).filter(Boolean), control: { hook: "user-prompt-tdd-reminder", chars: Number(control) }, router_control: { hook: "user-prompt-intent-router", chars: Number(routerControl) } };
    fs.writeFileSync(`${out}/silence.json`, `${JSON.stringify(value)}\n`, { mode: 0o600 });
    process.stdout.write(`${JSON.stringify(value)}\n`);
  ' "$out" "$root" "$summary" "$leaks" "${#control}" "${#router_control}" || die "cannot write silence.json"
  [ -z "$leaks" ] || die "the live runtime injects context under the eval config:$leaks"
  case "$control$router_control" in *"<<route-eval:"*) die "a positive control failed when fired without the eval config, so the silence check proves nothing" ;; esac
  [ "${#control}" -gt 0 ] || die "the positive control fired user-prompt-tdd-reminder.sh without the eval config and got nothing, so the silence check proves nothing"
}

case "$MODE" in
  capture) capture "$2" "$3" "$4" "$5" ;;
  silence) silence "$2" "$3" "$4" "$5" ;;
  *) die "unknown mode '$MODE'" 64 ;;
esac
