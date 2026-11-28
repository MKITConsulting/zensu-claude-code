#!/bin/bash
set -u
umask 022

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMINDER="$PLUGIN_DIR/hooks/user-prompt-tdd-reminder.sh"
PLANHOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-delivery-route.sh"
DOCTOR="$PLUGIN_DIR/hooks/lib/zensu-doctor.sh"
CONFIG_LIB="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
DIRECTIVE_LIB="$PLUGIN_DIR/hooks/lib/zensu-directive.sh"
LINKED_LIB="$PLUGIN_DIR/hooks/lib/zensu-linked-session.sh"
RESOLVER="$PLUGIN_DIR/hooks/lib/linked-session-v1.js"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0; SKIP=0
check() {
  case "$2" in
    (PASS) echo "  PASS  $1"; PASS=$((PASS+1)) ;;
    (SKIP) echo "  SKIP  $1"; SKIP=$((SKIP+1)) ;;
    (*) echo "  FAIL  $1"; FAIL=$((FAIL+1)) ;;
  esac
}
finish() {
  echo "----"
  echo "test-linked-session-route: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
  [ "$FAIL" -eq 0 ]
}

if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "L0 node and git are available" FAIL
  finish; exit
fi
PLATFORM="$(node -p process.platform 2>/dev/null)"
if [ "$PLATFORM" = win32 ]; then
  check "L0 the desktop store layout this suite builds is POSIX-only, so native Windows stays unverified" SKIP
  finish; exit
fi

echo "== Static: module, library, marker templates =="
{ [ -f "$RESOLVER" ] && [ -f "$LINKED_LIB" ] && bash -n "$LINKED_LIB" && node --check "$RESOLVER"; } >/dev/null 2>&1 \
  && check "L1 the resolver module and the shell library exist and parse" PASS \
  || check "L1 the resolver module or the shell library is missing or does not parse" FAIL
L2_BAD=""
for needle in '.zensu/state/inherited-route-' '.zensu/state/linked-session-'; do
  grep -qF "$needle" "$CONFIG_LIB" || L2_BAD="$L2_BAD [$needle missing from zensu-config.sh]"
done
[ -z "$L2_BAD" ] && check "L2 both new marker path templates live in zensu-config.sh, where R8k in test-delivery-route.sh holds every marker leaf in every file type under hooks/" PASS \
  || check "L2 marker templates:$L2_BAD" FAIL
L3_VOCAB="$(node -e '
  const m = require(process.argv[1]);
  process.stdout.write([Object.values(m.KINDS).sort().join(","), Object.values(m.REPOSITORY).sort().join(",")].join(" "));
' "$RESOLVER" 2>/dev/null)"
[ "$L3_VOCAB" = "linked,none,unresolved foreign,same,unknown" ] \
  && check "L3 the resolver answers only the documented kinds and repository verdicts" PASS \
  || check "L3 resolver vocabulary ($L3_VOCAB)" FAIL
L3B_OUT="$(node -e '
  const m = require(process.argv[1]);
  const show = (platform, env) => m.storeCandidates(platform, env).join("|");
  process.stdout.write([
    show("darwin", { HOME: "/h" }),
    show("win32", { HOME: "/h", APPDATA: "/a", LOCALAPPDATA: "/l" }),
    show("linux", { HOME: "/h", XDG_CONFIG_HOME: "/x" }),
    show("linux", { HOME: "/h", XDG_CONFIG_HOME: "relative" }),
    show("linux", {}) || "none",
  ].join("\n"));
' "$RESOLVER" 2>/dev/null)"
L3B_WANT="$(printf '%s\n' '/h/Library/Application Support/Claude/claude-code-sessions' \
  '/a/Claude/claude-code-sessions|/l/Claude/claude-code-sessions' \
  '/x/Claude/claude-code-sessions|/h/.config/Claude/claude-code-sessions' \
  '/h/.config/Claude/claude-code-sessions' 'none')"
[ "$L3B_OUT" = "$L3B_WANT" ] \
  && check "L3b the store candidates per platform: macOS Application Support, Windows APPDATA then LOCALAPPDATA, Linux XDG_CONFIG_HOME then ~/.config, never a relative base" PASS \
  || check "L3b store candidates ($(printf '%s' "$L3B_OUT" | tr '\n' ';'))" FAIL
L3C_OUT="$(node -e '
  const m = require(process.argv[1]);
  const show = (platform, env) => m.storeCandidates(platform, env).join("|") || "none";
  process.stdout.write([
    show("darwin", { HOME: "/h", ZENSU_CCD_STORE: " /s/store " }),
    show("linux", { HOME: "/h", XDG_CONFIG_HOME: "/x", ZENSU_CCD_STORE: "/s/store" }),
    show("win32", { APPDATA: "/a", ZENSU_CCD_STORE: "/d/store" }),
    show("linux", { HOME: "/h", ZENSU_CCD_STORE: "relative/store" }),
    show("darwin", { HOME: "/h", ZENSU_CCD_STORE: "   " }),
    show("darwin", { HOME: "/h", ZENSU_CCD_STORE: "/s/x/../store/" }),
  ].join("\n"));
' "$RESOLVER" 2>/dev/null)"
L3C_WANT="$(printf '%s\n' '/s/store' '/s/store' 'D:\store' 'none' '/h/Library/Application Support/Claude/claude-code-sessions' '/s/store')"
[ "$L3C_OUT" = "$L3C_WANT" ] \
  && check "L3c ZENSU_CCD_STORE is the only candidate when set, as session-trail reads it: trimmed, MSYS drive mapped on win32, resolved without a trailing separator, a relative value names no store, a blank one is ignored" PASS \
  || check "L3c store override ($(printf '%s' "$L3C_OUT" | tr '\n' ';'))" FAIL
L3M_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-hub-")));
  try {
    const profiles = path.join(scratch, "Library", "Application Support", "Zensu Session Hub", "Claude-Profile");
    for (const name of ["bbbbbbbb-2222-4222-8222-222222222222", "aaaaaaaa-1111-4111-8111-111111111111", "CCCCCCCC-3333-4333-8333-333333333333", "notes"]) {
      fs.mkdirSync(path.join(profiles, name), { recursive: true });
    }
    const show = (platform, env) => m.storeCandidates(platform, env).map((store) => store.split(scratch).join("~")).join("|") || "none";
    process.stdout.write([
      show("darwin", { HOME: scratch }),
      show("darwin", { HOME: scratch, ZENSU_CCD_EXTRA_STORES: " /n/one/ : relative/two ::/n/x/../three" }),
      show("linux", { HOME: scratch, ZENSU_CCD_EXTRA_STORES: "/n/one" }),
      show("win32", { APPDATA: "/a", ZENSU_CCD_EXTRA_STORES: "/d/named; /e/other ;" }),
      show("darwin", { HOME: scratch, ZENSU_CCD_EXTRA_STORES: "/n/one", ZENSU_CCD_STORE: "/s/store" }),
      show("darwin", { HOME: scratch, ZENSU_CCD_EXTRA_STORES: path.join(scratch, "Library", "Application Support", "Claude", "claude-code-sessions") }),
      show("darwin", { HOME: scratch, ZENSU_CCD_EXTRA_STORES: "  :  " }),
    ].join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" 2>/dev/null)"
L3M_DEFAULT='~/Library/Application Support/Claude/claude-code-sessions'
L3M_HUB='~/Library/Application Support/Zensu Session Hub/Claude-Profile/aaaaaaaa-1111-4111-8111-111111111111/claude-code-sessions|~/Library/Application Support/Zensu Session Hub/Claude-Profile/bbbbbbbb-2222-4222-8222-222222222222/claude-code-sessions'
L3M_WANT="$(printf '%s\n' "$L3M_DEFAULT|$L3M_HUB" "/n/one|/n/three|$L3M_DEFAULT|$L3M_HUB" '/n/one|~/.config/Claude/claude-code-sessions' \
  'D:\named|E:\other|/a/Claude/claude-code-sessions' '/s/store' "$L3M_DEFAULT|$L3M_HUB" "$L3M_DEFAULT|$L3M_HUB")"
[ "$L3M_OUT" = "$L3M_WANT" ] \
  && check "L3m the candidates are every store ZENSU_CCD_EXTRA_STORES names, split by the platform's list separator, trimmed, MSYS drive mapped on win32, resolved without a trailing separator, blank and relative entries naming none, then the platform's defaults, then on macOS every Session Hub profile whose folder name is a canonical lowercase UUID, each spelling once, and ZENSU_CCD_STORE still alone" PASS \
  || check "L3m named and profile stores ($(printf '%s' "$L3M_OUT" | tr '\n' ';'))" FAIL
L3D_LITERALS="$(grep -c 'zensu\.session-control' "$RESOLVER" 2>/dev/null || true)"
L3D_FROM_CORE="$(grep -cE 'controlCore\(\)\.SCHEMA\b.*controlCore\(\)\.SCHEMA_VERSION\b' "$RESOLVER" 2>/dev/null || true)"
[ "$L3D_LITERALS" = "0" ] && [ "${L3D_FROM_CORE:-0}" -ge 1 ] \
  && check "L3d the resolver spells no Session Control schema of its own and takes the name and version from the core" PASS \
  || check "L3d schema source (literals=$L3D_LITERALS from-core=$L3D_FROM_CORE)" FAIL
L3E_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const core = require(process.argv[2]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-hash-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const childHost = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const childCli = "55555555-5555-4555-8555-555555555555";
    const parentCli = "66666666-6666-4666-8666-666666666666";
    const store = path.join(scratch, "store");
    const desk = path.join(store, account, organization);
    fs.mkdirSync(desk, { recursive: true });
    fs.writeFileSync(path.join(desk, parentHost + ".json"), JSON.stringify({ sessionId: parentHost, cliSessionId: parentCli }));
    fs.writeFileSync(path.join(desk, childHost + ".json"), JSON.stringify({ sessionId: childHost, cliSessionId: childCli, spawnedFrom: { sessionId: parentHost } }));
    const records = path.join(scratch, "records");
    const root = path.join(scratch, "root");
    fs.mkdirSync(records);
    fs.mkdirSync(root);
    const record = path.join(records, core.sessionKey(parentCli) + ".json");
    const env = { CLAUDE_CODE_HOST_SESSION_ID: childHost, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: store };
    const resolve = (change) => {
      const context = { schema: core.SCHEMA, schema_version: core.SCHEMA_VERSION, host: "claude", session_id_hash: core.sessionIdHash(parentCli), project_root: root };
      change(context);
      fs.writeFileSync(record, JSON.stringify(context));
      const v = m.resolveLinkedSession({ env, sessionId: childCli, pluginData: scratch, deps: { recordsDirectory: () => records } });
      return v.kind + "/" + v.reason + "/" + (v.parentRoot === root ? "root" : "-");
    };
    process.stdout.write([
      resolve(() => {}),
      resolve((c) => { c.session_id_hash = core.sessionIdHash(childCli); }),
      resolve((c) => { delete c.session_id_hash; }),
      resolve((c) => { c.schema = "zensu.workflow-state"; }),
      resolve((c) => { delete c.schema; }),
      resolve((c) => { c.schema_version = core.SCHEMA_VERSION + 1; }),
      resolve((c) => { delete c.schema_version; }),
      resolve((c) => { c.host = "codex"; }),
      resolve((c) => { delete c.host; }),
    ].join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$CORE" 2>/dev/null)"
L3E_WANT="$(printf '%s\n' 'linked/resolved/root' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-')"
[ "$L3E_OUT" = "$L3E_WANT" ] \
  && check "L3e a parent record whose session hash, schema, schema version or host is another one or missing leaves the session linked and uninherited, while the matching record resolves" PASS \
  || check "L3e parent identity ($(printf '%s' "$L3E_OUT" | tr '\n' ';'))" FAIL
L3N_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const core = require(process.argv[2]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-stores-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const childHost = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const childCli = "55555555-5555-4555-8555-555555555555";
    const parentCli = "66666666-6666-4666-8666-666666666666";
    const support = path.join(scratch, "Library", "Application Support");
    const defaultStore = path.join(support, "Claude", "claude-code-sessions");
    const profile = path.join(support, "Zensu Session Hub", "Claude-Profile", "aaaaaaaa-1111-4111-8111-111111111111");
    const profileStore = path.join(profile, "claude-code-sessions");
    const named = path.join(scratch, "named");
    const desk = (store) => path.join(store, account, organization);
    for (const store of [defaultStore, profileStore, named]) fs.mkdirSync(desk(store), { recursive: true });
    const write = (store, host, cli, parent) => {
      const record = { sessionId: host, cliSessionId: cli };
      if (parent) record.spawnedFrom = { sessionId: parent };
      fs.writeFileSync(path.join(desk(store), host + ".json"), JSON.stringify(record));
    };
    const clear = (store) => {
      for (const host of [childHost, parentHost]) fs.rmSync(path.join(desk(store), host + ".json"), { force: true });
    };
    const records = path.join(scratch, "records");
    const root = path.join(scratch, "root");
    fs.mkdirSync(records);
    fs.mkdirSync(root);
    fs.writeFileSync(path.join(records, core.sessionKey(parentCli) + ".json"), JSON.stringify({ schema: core.SCHEMA, schema_version: core.SCHEMA_VERSION, host: "claude", session_id_hash: core.sessionIdHash(parentCli), project_root: root }));
    const resolve = (platform, extra) => {
      const env = Object.assign({ HOME: scratch, CLAUDE_CODE_HOST_SESSION_ID: childHost, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization }, extra || {});
      const v = m.resolveLinkedSession({ env, platform, sessionId: childCli, pluginData: scratch, deps: { recordsDirectory: () => records } });
      return v.kind + "/" + v.reason + "/" + (v.parentRoot === root ? "root" : "-");
    };
    const out = [];
    write(profileStore, childHost, childCli, parentHost);
    write(profileStore, parentHost, parentCli, null);
    out.push(resolve("darwin"));
    out.push(resolve("darwin", { ZENSU_CCD_STORE: defaultStore }));
    out.push(resolve("linux"));
    fs.symlinkSync(profile, path.join(scratch, "alias"));
    out.push(resolve("darwin", { ZENSU_CCD_EXTRA_STORES: path.join(scratch, "alias", "claude-code-sessions") }));
    write(named, childHost, childCli, parentHost);
    out.push(resolve("darwin", { ZENSU_CCD_EXTRA_STORES: named }));
    clear(profileStore);
    write(named, parentHost, parentCli, null);
    out.push(resolve("darwin", { ZENSU_CCD_EXTRA_STORES: named }));
    clear(named);
    write(profileStore, childHost, childCli, parentHost);
    write(profileStore, parentHost, parentCli, null);
    fs.chmodSync(profileStore, 0o775);
    out.push(resolve("darwin"));
    fs.chmodSync(profileStore, 0o755);
    fs.renameSync(profile, path.join(path.dirname(profile), "CCCCCCCC-3333-4333-8333-333333333333"));
    out.push(resolve("darwin"));
    write(named, childHost, childCli, parentHost);
    write(named, parentHost, parentCli, null);
    fs.symlinkSync(named, path.join(scratch, "named-link"));
    out.push(resolve("darwin", { ZENSU_CCD_EXTRA_STORES: path.join(scratch, "named-link") + path.sep }));
    out.push(resolve("darwin", { ZENSU_CCD_EXTRA_STORES: named + path.sep }));
    process.stdout.write(out.join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$CORE" 2>/dev/null)"
L3N_WANT="$(printf '%s\n' 'linked/resolved/root' 'unresolved/own-record-missing/-' 'none/no-session-store/-' 'linked/resolved/root' \
  'none/own-record-ambiguous/-' 'linked/resolved/root' 'unresolved/own-record-missing/-' 'unresolved/own-record-missing/-' \
  'unresolved/own-record-missing/-' 'linked/resolved/root')"
[ "$L3N_OUT" = "$L3N_WANT" ] \
  && check "L3n the own record is looked up in every usable store: a record only in a Session Hub profile store resolves beside a default store that lacks it, ZENSU_CCD_STORE still names the only store, Linux probes no profile, a profile reached through a linked folder counts once, a record two stores hold answers own-record-ambiguous, a record only in a named store resolves, a group-writable or upper-case profile is no store, and a named entry that reaches a store through a symbolic link with a trailing separator names no store while the store's own path with one does" PASS \
  || check "L3n lookup across stores ($(printf '%s' "$L3N_OUT" | tr '\n' ';'))" FAIL
L3O_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const { execFileSync } = require("child_process");
  const m = require(process.argv[1]);
  const trail = process.argv[2];
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-parity-")));
  try {
    const profiles = path.join(scratch, "Library", "Application Support", "Zensu Session Hub", "Claude-Profile");
    for (const name of ["bbbbbbbb-2222-4222-8222-222222222222", "aaaaaaaa-1111-4111-8111-111111111111", "CCCCCCCC-3333-4333-8333-333333333333", "notes"]) {
      fs.mkdirSync(path.join(profiles, name), { recursive: true });
    }
    const bare = path.join(scratch, "bare-home");
    fs.mkdirSync(bare);
    const one = path.join(scratch, "one");
    const layouts = [
      ["named", 5, { HOME: scratch, ZENSU_CCD_EXTRA_STORES: [one, path.join(scratch, "two") + path.sep, path.join(scratch, "Library", "Application Support", "Claude", "claude-code-sessions")].join(path.delimiter) }],
      ["override", 1, { HOME: scratch, ZENSU_CCD_STORE: "  " + path.join(scratch, "override") + path.sep + "  ", ZENSU_CCD_EXTRA_STORES: one }],
      ["blank-override", 4, { HOME: scratch, ZENSU_CCD_STORE: "   ", ZENSU_CCD_EXTRA_STORES: [" " + one + " ", "", " " + one + path.sep + " ", ""].join(path.delimiter) }],
      ["no-profiles", 2, { HOME: bare, ZENSU_CCD_EXTRA_STORES: one }],
    ];
    const otherPlatforms = new Set(["Windows APPDATA (unverified)", "Windows LOCALAPPDATA (unverified)", "XDG_CONFIG_HOME (unverified)", "Linux ~/.config (unverified)"]);
    const differ = [];
    for (const [name, length, env] of layouts) {
      const resolver = m.storeCandidates("darwin", env);
      let trailed;
      try {
        const report = JSON.parse(execFileSync(process.execPath, [trail, "lineage", "--diagnose", "--json", "--config-dir", path.join(scratch, ".claude")], { env: { PATH: process.env.PATH, ...env }, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }));
        trailed = report.probes.filter((probe) => !otherPlatforms.has(probe.source)).map((probe) => probe.dir);
      } catch (_) {
        differ.push(name + " trail-failed");
        continue;
      }
      if (resolver.length !== length || JSON.stringify(resolver) !== JSON.stringify(trailed)) differ.push(name + " resolver=" + JSON.stringify(resolver) + " trail=" + JSON.stringify(trailed));
    }
    process.stdout.write(differ.length === 0 ? "same" : "differ " + differ.join(" | "));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs" 2>/dev/null)"
[ "$L3O_OUT" = same ] \
  && check "L3o the resolver's macOS store candidates equal the probes of session-trail's lineage --diagnose in the same order once the other platforms' defaults are left out, in four layouts: named stores with a trailing separator and a named copy of the default store beside lower-case, upper-case and non-UUID profile folders; a padded ZENSU_CCD_STORE with a trailing separator that stays alone beside a named store; a blank ZENSU_CCD_STORE that names no store beside blank, padded and repeated named entries; and a home without a Session Hub profiles folder" PASS \
  || check "L3o store parity with session-trail ($L3O_OUT)" FAIL
L3Q_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const core = require(process.argv[2]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-detail-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const childHost = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const childCli = "55555555-5555-4555-8555-555555555555";
    const parentCli = "66666666-6666-4666-8666-666666666666";
    const support = path.join(scratch, "Library", "Application Support");
    const defaultStore = path.join(support, "Claude", "claude-code-sessions");
    const profiles = path.join(support, "Zensu Session Hub", "Claude-Profile");
    const profileStore = (name) => path.join(profiles, name, "claude-code-sessions");
    const empty = profileStore("aaaaaaaa-1111-4111-8111-111111111111");
    const holder = profileStore("bbbbbbbb-2222-4222-8222-222222222222");
    const shared = profileStore("dddddddd-4444-4444-8444-444444444444");
    const alias = path.join(scratch, "alias", "claude-code-sessions");
    const bare = path.join(scratch, "bare");
    const desk = (store) => path.join(store, account, organization);
    for (const store of [defaultStore, holder, shared]) fs.mkdirSync(desk(store), { recursive: true });
    for (const store of [empty, profileStore("CCCCCCCC-3333-4333-8333-333333333333"), profileStore("notes")]) fs.mkdirSync(store, { recursive: true });
    fs.mkdirSync(bare);
    fs.symlinkSync(path.join(support, "Claude"), path.join(scratch, "alias"));
    fs.chmodSync(shared, 0o775);
    const write = (host, cli, parent) => {
      const record = { sessionId: host, cliSessionId: cli };
      if (parent) record.spawnedFrom = { sessionId: parent };
      fs.writeFileSync(path.join(desk(holder), host + ".json"), JSON.stringify(record));
    };
    write(childHost, childCli, parentHost);
    write(parentHost, parentCli, null);
    const records = path.join(scratch, "records");
    const root = path.join(scratch, "root");
    fs.mkdirSync(records);
    fs.mkdirSync(root);
    fs.writeFileSync(path.join(records, core.sessionKey(parentCli) + ".json"), JSON.stringify({ schema: core.SCHEMA, schema_version: core.SCHEMA_VERSION, host: "claude", session_id_hash: core.sessionIdHash(parentCli), project_root: root }));
    const labels = new Map([[alias, "alias"], [defaultStore, "default"], [empty, "aaaa"], [holder, "bbbb"], [shared, "dddd"],
      [path.join(scratch, ".config", "Claude", "claude-code-sessions"), "linux-default"],
      [path.join(bare, "Library", "Application Support", "Claude", "claude-code-sessions"), "bare-default"]]);
    const label = (store) => (store ? labels.get(store) || "other" : "-");
    const show = (platform, extra) => {
      const env = Object.assign({ HOME: scratch, CLAUDE_CODE_HOST_SESSION_ID: childHost, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization }, extra || {});
      const v = m.resolveLinkedSession({ env, platform, sessionId: childCli, pluginData: scratch, detail: true, deps: { recordsDirectory: () => records } });
      const stores = v.stores.map((s) => [label(s.store), s.source, s.state, s.cause || (s.sameAs ? label(s.sameAs) : "")].filter(Boolean).join(":"));
      return [v.kind, v.reason, label(v.ownStore), v.parentSession === parentHost ? "parent" : "-", stores.join(",")].join(" ");
    };
    const out = [];
    out.push(show("darwin", { ZENSU_CCD_EXTRA_STORES: alias }));
    out.push(show("darwin", { ZENSU_CCD_STORE: holder, ZENSU_CCD_EXTRA_STORES: alias }));
    out.push(show("linux", { ZENSU_CCD_EXTRA_STORES: alias }));
    fs.rmSync(path.join(desk(holder), childHost + ".json"));
    out.push(show("darwin"));
    write(childHost, childCli, parentHost);
    out.push(show("darwin", { HOME: bare }));
    const getuid = process.getuid;
    process.getuid = () => getuid.call(process) + 1;
    try {
      out.push(show("darwin"));
    } finally {
      process.getuid = getuid;
    }
    process.stdout.write(out.join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$CORE" 2>/dev/null)"
L3Q_WANT="$(printf '%s\n' \
  'linked resolved bbbb parent alias:named:no-record,default:default:same-folder:alias,aaaa:hub-profile:no-folder,bbbb:hub-profile:holds-record,dddd:hub-profile:refused:shared-write' \
  'linked resolved bbbb parent bbbb:override:holds-record' \
  'unresolved own-record-missing - - alias:named:no-record,linux-default:default:no-folder' \
  'unresolved own-record-missing - - default:default:no-record,aaaa:hub-profile:no-folder,bbbb:hub-profile:no-record,dddd:hub-profile:refused:shared-write' \
  'none no-session-store - - bare-default:default:no-folder' \
  'none no-session-store - - default:default:refused:foreign-owner,aaaa:hub-profile:refused:foreign-owner,bbbb:hub-profile:refused:foreign-owner,dddd:hub-profile:refused:foreign-owner')"
[ "$L3Q_OUT" = "$L3Q_WANT" ] \
  && check "L3q the detail mode lists every store candidate in order with its source and state: a named store that reaches the default store's folder, the default store as the same folder, a Session Hub profile without this account's folder, the profile that holds the record and a group-writable profile; upper-case and non-UUID profile folders are no candidates; ZENSU_CCD_STORE stays the only store; Linux probes no profile; a record in no store answers own-record-missing; a home without stores answers no-session-store; and with every folder owned by another account every store is refused" PASS \
  || check "L3q detail states ($(printf '%s' "$L3Q_OUT" | tr '\n' ';'))" FAIL
L3R_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const { execFileSync } = require("child_process");
  const m = require(process.argv[1]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-race-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const host = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const cli = "55555555-5555-4555-8555-555555555555";
    const store = path.join(scratch, "store");
    const desk = path.join(store, account, organization);
    fs.mkdirSync(desk, { recursive: true });
    const own = path.join(desk, host + ".json");
    fs.writeFileSync(own, JSON.stringify({ sessionId: host, cliSessionId: cli, spawnedFrom: { sessionId: parentHost } }));
    const env = { HOME: scratch, CLAUDE_CODE_HOST_SESSION_ID: host, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: store };
    const out = [];
    const realLstat = fs.lstatSync;
    let seen = 0;
    fs.lstatSync = (target, ...rest) => {
      if (target === own) {
        seen += 1;
        if (seen > 1) {
          const gone = new Error("vanished");
          gone.code = "ENOENT";
          throw gone;
        }
      }
      return realLstat(target, ...rest);
    };
    try {
      const v = m.resolveLinkedSession({ env, sessionId: cli, pluginData: scratch });
      out.push(v.kind + "/" + v.reason + "/" + seen);
    } finally {
      fs.lstatSync = realLstat;
    }
    const plain = m.resolveLinkedSession({ env, sessionId: cli, pluginData: scratch, projectRoot: scratch });
    const detailed = m.resolveLinkedSession({ env, sessionId: cli, pluginData: scratch, projectRoot: scratch, detail: true });
    out.push(Object.keys(plain).sort().join(","));
    out.push(String(m.renderVerdict(plain) === m.renderVerdict(detailed)));
    out.push(String(Object.isFrozen(detailed) && Object.isFrozen(detailed.stores) && detailed.stores.every((entry) => Object.isFrozen(entry))));
    out.push(String(JSON.stringify(detailed.stores.map((entry) => entry.store)) === JSON.stringify(m.storeCandidates(process.platform, env))));
    const cliLine = execFileSync(process.execPath, [process.argv[1]], { env: Object.assign({ PATH: process.env.PATH, ZENSU_LINKED_SESSION_ID: cli, ZENSU_LINKED_PROJECT_ROOT: scratch, CLAUDE_PLUGIN_DATA: scratch }, env), encoding: "utf8" });
    out.push(String(cliLine === m.renderVerdict(plain) + "\n"));
    fs.rmSync(own);
    out.push(m.resolveLinkedSession({ env, sessionId: cli, pluginData: scratch }).reason);
    process.stdout.write(out.join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" 2>/dev/null)"
L3R_WANT="$(printf '%s\n' 'unresolved/own-record-unreadable/2' 'kind,parentKey,parentRoot,reason,repository,turn' true true true true own-record-missing)"
[ "$L3R_OUT" = "$L3R_WANT" ] \
  && check "L3r an own record that vanishes between the existence check and the read answers own-record-unreadable while a record in no store keeps own-record-missing, and the detail mode leaves the hook answer alone: the plain verdict keeps its six fields, renders the same line as the detailed one and as the module's own command line, and the detailed verdict lists exactly the store candidates, frozen" PASS \
  || check "L3r race remap and unchanged hook answer ($(printf '%s' "$L3R_OUT" | tr '\n' ';'))" FAIL
L3S_SCAN='
  const fs = require("fs");
  const path = require("path");
  const dir = process.argv[1];
  const readers = ["user-prompt-tdd-reminder.sh", "plan-approved-delegate.sh", "zensu-doctor.sh", "zensu-doctor-report.js", "linked-session-v1.js", "zensu-linked-session.sh"];
  const names = ["CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_ORGANIZATION_UUID"];
  let scanned = 0;
  const bad = [];
  for (const file of fs.readdirSync(dir).filter((name) => /^test-.*\.sh$/.test(name)).sort()) {
    const text = fs.readFileSync(path.join(dir, file), "utf8").replace(/\\\r?\n/g, " ");
    if (!readers.some((reader) => text.includes(reader))) continue;
    scanned += 1;
    const unsets = text.split(/\r?\n/).filter((line) => /^unset[ \t]/.test(line)).join(" ");
    const missing = names.filter((name) => !new RegExp("[ \\t]" + name + "(?=[ \\t]|$)").test(unsets));
    if (missing.length) bad.push(file + ":" + missing.join(","));
  }
  process.stdout.write(scanned + " " + (bad.length ? bad.join(" ") : "none"));
'
L3S_REAL="$(node -e "$L3S_SCAN" "$PLUGIN_DIR/tests/structure" 2>/dev/null)"
L3S_TREE="$(mktemp -d 2>/dev/null)"
L3S_PLANTED=""
if [ -n "$L3S_TREE" ] && [ -d "$L3S_TREE" ]; then
  printf '%s\n' '#!/bin/bash' 'bash "$P/hooks/lib/zensu-doctor.sh"' > "$L3S_TREE/test-a.sh"
  printf '%s\n' '#!/bin/bash' 'unset CLAUDE_CODE_HOST_SESSION_ID CLAUDE_CODE_ACCOUNT_UUID CLAUDE_CODE_ORGANIZATION_UUID' 'bash "$P/hooks/user-prompt-tdd-reminder.sh"' > "$L3S_TREE/test-b.sh"
  printf '%s\n' '#!/bin/bash' 'unset CLAUDE_CODE_HOST_SESSION_ID \' '  CLAUDE_CODE_ACCOUNT_UUID CLAUDE_CODE_ORGANIZATION_UUID' 'node "$P/hooks/lib/linked-session-v1.js"' > "$L3S_TREE/test-c.sh"
  printf '%s\n' '#!/bin/bash' 'scrub() {' '  unset CLAUDE_CODE_HOST_SESSION_ID CLAUDE_CODE_ACCOUNT_UUID CLAUDE_CODE_ORGANIZATION_UUID' '}' 'bash "$P/hooks/plan-approved-delegate.sh"' > "$L3S_TREE/test-d.sh"
  printf '%s\n' '#!/bin/bash' 'unset CLAUDE_CODE_HOST_SESSION_ID CLAUDE_CODE_ACCOUNT_UUID' '# unset CLAUDE_CODE_ORGANIZATION_UUID' 'node "$P/hooks/lib/zensu-doctor-report.js"' > "$L3S_TREE/test-e.sh"
  printf '%s\n' '#!/bin/bash' 'echo nothing to see' > "$L3S_TREE/test-f.sh"
  L3S_PLANTED="$(node -e "$L3S_SCAN" "$L3S_TREE" 2>/dev/null)"
  rm -rf "$L3S_TREE"
fi
L3S_PLANTED_WANT="5 test-a.sh:CLAUDE_CODE_HOST_SESSION_ID,CLAUDE_CODE_ACCOUNT_UUID,CLAUDE_CODE_ORGANIZATION_UUID test-d.sh:CLAUDE_CODE_HOST_SESSION_ID,CLAUDE_CODE_ACCOUNT_UUID,CLAUDE_CODE_ORGANIZATION_UUID test-e.sh:CLAUDE_CODE_ORGANIZATION_UUID"
if [ "${L3S_REAL% *}" -ge 30 ] 2>/dev/null && [ "${L3S_REAL#* }" = none ] && [ "$L3S_PLANTED" = "$L3S_PLANTED_WANT" ]; then
  check "L3s every structure suite that names a lineage reader (both ask-hooks, the doctor wrapper and renderer, the resolver and its shell library) unsets CLAUDE_CODE_HOST_SESSION_ID, CLAUDE_CODE_ACCOUNT_UUID and CLAUDE_CODE_ORGANIZATION_UUID at top level, so no developer's Claude Desktop identity reaches them, and the scan refuses a missing, an indented and a partial unset in a planted tree ($L3S_REAL)" PASS
else
  check "L3s desktop identity scrub (real='$L3S_REAL' planted='$L3S_PLANTED')" FAIL
fi
L3F_INNER='
  const cp = require("child_process");
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-fifo-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const host = "local_33333333-3333-4333-8333-333333333333";
    const desk = path.join(scratch, "store", account, organization);
    fs.mkdirSync(desk, { recursive: true });
    const own = path.join(desk, host + ".json");
    cp.execFileSync("mkfifo", [own]);
    const standIn = path.join(scratch, "stand-in.json");
    fs.writeFileSync(standIn, "{}", { mode: 0o600 });
    const realLstat = fs.lstatSync;
    const realOpen = fs.openSync;
    const regular = realLstat(standIn);
    let hits = 0;
    let opens = 0;
    fs.lstatSync = (target, ...rest) => {
      if (target !== own) return realLstat(target, ...rest);
      hits += 1;
      return regular;
    };
    fs.openSync = (target, ...rest) => {
      if (target === own) opens += 1;
      return realOpen(target, ...rest);
    };
    const env = { CLAUDE_CODE_HOST_SESSION_ID: host, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: path.join(scratch, "store") };
    const v = m.resolveLinkedSession({ env, sessionId: "55555555-5555-4555-8555-555555555555", pluginData: scratch });
    process.stdout.write(v.kind + "/" + v.reason + "/" + (hits > 0 ? "stubbed" : "unstubbed") + "/" + (opens > 0 ? "opened" : "unopened"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
'
L3F_OUT="$(node -e '
  const r = require("child_process").spawnSync(process.execPath, ["-e", process.argv[1], process.argv[2]], { encoding: "utf8", timeout: 20000 });
  process.stdout.write(r.error && r.error.code === "ETIMEDOUT" ? "blocked" : String(r.status) + ":" + r.stdout);
' "$L3F_INNER" "$RESOLVER" 2>/dev/null)"
[ "$L3F_OUT" = "0:none/own-record-refused/stubbed/opened" ] \
  && check "L3f a desktop record swapped for a FIFO after its lstat, which the stub saw, is opened without blocking and refused on the descriptor" PASS \
  || check "L3f FIFO swapped in after lstat ($L3F_OUT)" FAIL
L3G_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const core = require(process.argv[2]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-again-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const childHost = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const childCli = "55555555-5555-4555-8555-555555555555";
    const parentCli = "66666666-6666-4666-8666-666666666666";
    const store = path.join(scratch, "store");
    const desk = path.join(store, account, organization);
    fs.mkdirSync(desk, { recursive: true });
    fs.writeFileSync(path.join(desk, parentHost + ".json"), JSON.stringify({ sessionId: parentHost, cliSessionId: parentCli }));
    fs.writeFileSync(path.join(desk, childHost + ".json"), JSON.stringify({ sessionId: childHost, cliSessionId: childCli, spawnedFrom: { sessionId: parentHost } }));
    const records = path.join(scratch, "records");
    const root = path.join(scratch, "root");
    fs.mkdirSync(records);
    fs.mkdirSync(root);
    fs.writeFileSync(path.join(records, core.sessionKey(parentCli) + ".json"), JSON.stringify({ schema: core.SCHEMA, schema_version: core.SCHEMA_VERSION, host: "claude", session_id_hash: core.sessionIdHash(parentCli), project_root: root }));
    const env = { CLAUDE_CODE_HOST_SESSION_ID: childHost, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: store };
    const realRead = fs.readSync;
    const resolve = (failures) => {
      let left = failures;
      let thrown = 0;
      fs.readSync = (...args) => {
        if (left > 0) {
          left -= 1;
          thrown += 1;
          const error = new Error("resource temporarily unavailable");
          error.code = "EAGAIN";
          throw error;
        }
        return realRead(...args);
      };
      try {
        const v = m.resolveLinkedSession({ env, sessionId: childCli, pluginData: scratch, deps: { recordsDirectory: () => records } });
        return v.kind + "/" + v.reason + "/" + (v.parentRoot === root ? "root" : "-") + "/" + (thrown > 0 ? "stubbed" : "unstubbed");
      } finally {
        fs.readSync = realRead;
      }
    };
    process.stdout.write([resolve(3), resolve(Infinity)].join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$CORE" 2>/dev/null)"
L3G_WANT="$(printf '%s\n' 'linked/resolved/root/stubbed' 'unresolved/own-record-unreadable/-/stubbed')"
[ "$L3G_OUT" = "$L3G_WANT" ] \
  && check "L3g a read that answers would-block is retried: three EAGAIN answers still resolve, and one that never ends leaves the session unresolved for its one retry instead of refusing it for good" PASS \
  || check "L3g would-block reads ($(printf '%s' "$L3G_OUT" | tr '\n' ';'))" FAIL
L3H_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const core = require(process.argv[2]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-owner-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const childHost = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const childCli = "55555555-5555-4555-8555-555555555555";
    const parentCli = "66666666-6666-4666-8666-666666666666";
    const store = path.join(scratch, "store");
    const accountDir = path.join(store, account);
    const desk = path.join(accountDir, organization);
    fs.mkdirSync(desk, { recursive: true });
    const own = path.join(desk, childHost + ".json");
    const parent = path.join(desk, parentHost + ".json");
    fs.writeFileSync(parent, JSON.stringify({ sessionId: parentHost, cliSessionId: parentCli }));
    fs.writeFileSync(own, JSON.stringify({ sessionId: childHost, cliSessionId: childCli, spawnedFrom: { sessionId: parentHost } }));
    const records = path.join(scratch, "records");
    const root = path.join(scratch, "root");
    fs.mkdirSync(records);
    fs.mkdirSync(root);
    const record = path.join(records, core.sessionKey(parentCli) + ".json");
    fs.writeFileSync(record, JSON.stringify({ schema: core.SCHEMA, schema_version: core.SCHEMA_VERSION, host: "claude", session_id_hash: core.sessionIdHash(parentCli), project_root: root }));
    const env = { CLAUDE_CODE_HOST_SESSION_ID: childHost, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: store };
    const realLstat = fs.lstatSync;
    const realFstat = fs.fstatSync;
    const realOpen = fs.openSync;
    const foreign = (stat) => Object.assign(Object.create(Object.getPrototypeOf(stat)), stat, { uid: stat.uid + 1 });
    const resolve = () => {
      const v = m.resolveLinkedSession({ env, sessionId: childCli, pluginData: scratch, deps: { recordsDirectory: () => records } });
      return v.kind + "/" + v.reason + "/" + (v.parentRoot === root ? "root" : "-");
    };
    const withMode = (target, bits) => {
      const before = realLstat(target).mode & 0o7777;
      fs.chmodSync(target, before | bits);
      try {
        return resolve();
      } finally {
        fs.chmodSync(target, before);
      }
    };
    const withForeignLstat = (target) => {
      let hits = 0;
      fs.lstatSync = (file, ...rest) => {
        const stat = realLstat(file, ...rest);
        if (file !== target) return stat;
        hits += 1;
        return foreign(stat);
      };
      try {
        return resolve() + "/" + (hits > 0 ? "stubbed" : "unstubbed");
      } finally {
        fs.lstatSync = realLstat;
      }
    };
    const withForeignDescriptor = (target) => {
      const descriptors = new Set();
      let hits = 0;
      fs.openSync = (file, ...rest) => {
        const fd = realOpen(file, ...rest);
        if (file === target) descriptors.add(fd);
        return fd;
      };
      fs.fstatSync = (fd, ...rest) => {
        const stat = realFstat(fd, ...rest);
        if (!descriptors.has(fd)) return stat;
        hits += 1;
        return foreign(stat);
      };
      try {
        return resolve() + "/" + (hits > 0 ? "stubbed" : "unstubbed");
      } finally {
        fs.openSync = realOpen;
        fs.fstatSync = realFstat;
      }
    };
    process.stdout.write([
      resolve(),
      withMode(store, 0o020),
      withMode(store, 0o002),
      withMode(accountDir, 0o020),
      withMode(desk, 0o002),
      withMode(own, 0o020),
      withMode(own, 0o002),
      withMode(parent, 0o020),
      withMode(parent, 0o002),
      withMode(root, 0o022),
      withForeignLstat(store),
      withForeignLstat(accountDir),
      withForeignLstat(desk),
      withForeignLstat(own),
      withForeignLstat(parent),
      withForeignDescriptor(own),
      withForeignDescriptor(parent),
      withMode(record, 0o020),
      withMode(record, 0o002),
      withForeignLstat(record),
      withForeignDescriptor(record),
      resolve(),
    ].join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$CORE" 2>/dev/null)"
L3H_WANT="$(printf '%s\n' 'linked/resolved/root' \
  'none/no-session-store/-' 'none/no-session-store/-' 'none/no-session-store/-' 'none/no-session-store/-' \
  'none/own-record-refused/-' 'none/own-record-refused/-' \
  'linked/parent-record-unavailable/-' 'linked/parent-record-unavailable/-' \
  'linked/resolved/root' \
  'none/no-session-store/-/stubbed' 'none/no-session-store/-/stubbed' 'none/no-session-store/-/stubbed' \
  'none/own-record-refused/-/stubbed' 'linked/parent-record-unavailable/-/stubbed' \
  'none/own-record-refused/-/stubbed' 'linked/parent-record-unavailable/-/stubbed' \
  'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' \
  'linked/parent-context-unavailable/-/stubbed' 'linked/parent-context-unavailable/-/stubbed' \
  'linked/resolved/root')"
[ "$L3H_OUT" = "$L3H_WANT" ] \
  && check "L3h a store, account or organization directory, an own or parent desktop record and the parent's Session Control record that grant group or other write, or that another account owns, even only on the opened descriptor, answer the existing outcomes, while a group-writable parent root and the private store still resolve" PASS \
  || check "L3h owner and mode ($(printf '%s' "$L3H_OUT" | tr '\n' ';'))" FAIL
L3I_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const core = require(process.argv[2]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-win32-")));
  const platform = Object.getOwnPropertyDescriptor(process, "platform");
  const getuid = process.getuid;
  const realLstat = fs.lstatSync;
  const realFstat = fs.fstatSync;
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const childHost = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const childCli = "55555555-5555-4555-8555-555555555555";
    const parentCli = "66666666-6666-4666-8666-666666666666";
    const store = path.join(scratch, "store");
    const accountDir = path.join(store, account);
    const desk = path.join(accountDir, organization);
    fs.mkdirSync(desk, { recursive: true });
    const own = path.join(desk, childHost + ".json");
    const parent = path.join(desk, parentHost + ".json");
    fs.writeFileSync(parent, JSON.stringify({ sessionId: parentHost, cliSessionId: parentCli }));
    fs.writeFileSync(own, JSON.stringify({ sessionId: childHost, cliSessionId: childCli, spawnedFrom: { sessionId: parentHost } }));
    const records = path.join(scratch, "records");
    const root = path.join(scratch, "root");
    fs.mkdirSync(records);
    fs.mkdirSync(root);
    const record = path.join(records, core.sessionKey(parentCli) + ".json");
    fs.writeFileSync(record, JSON.stringify({ schema: core.SCHEMA, schema_version: core.SCHEMA_VERSION, host: "claude", session_id_hash: core.sessionIdHash(parentCli), project_root: root }));
    for (const directory of [store, accountDir, desk]) fs.chmodSync(directory, 0o777);
    for (const file of [own, parent, record]) fs.chmodSync(file, 0o666);
    const env = { CLAUDE_CODE_HOST_SESSION_ID: childHost, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: store };
    const foreign = (stat) => Object.assign(Object.create(Object.getPrototypeOf(stat)), stat, { uid: stat.uid + 1 });
    let hits = 0;
    fs.lstatSync = (...args) => {
      hits += 1;
      return foreign(realLstat(...args));
    };
    fs.fstatSync = (...args) => {
      hits += 1;
      return foreign(realFstat(...args));
    };
    const resolve = () => {
      const v = m.resolveLinkedSession({ env, platform: "linux", sessionId: childCli, pluginData: scratch, deps: { recordsDirectory: () => records } });
      return v.kind + "/" + v.reason + "/" + (v.parentRoot === root ? "root" : "-");
    };
    Object.defineProperty(process, "platform", { ...platform, value: "win32" });
    process.getuid = undefined;
    const windows = resolve();
    Object.defineProperty(process, "platform", platform);
    process.getuid = getuid;
    const posix = resolve();
    process.stdout.write([windows, posix, hits > 0 ? "stubbed" : "unstubbed"].join("\n"));
  } finally {
    Object.defineProperty(process, "platform", platform);
    process.getuid = getuid;
    fs.lstatSync = realLstat;
    fs.fstatSync = realFstat;
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$CORE" 2>/dev/null)"
L3I_WANT="$(printf '%s\n' 'linked/resolved/root' 'none/no-session-store/-' 'stubbed')"
[ "$L3I_OUT" = "$L3I_WANT" ] \
  && check "L3i with the host reported as win32 and no process.getuid, a world-writable store and records another account owns still resolve as before, and the same store refuses once the POSIX host is restored" PASS \
  || check "L3i win32 arm ($(printf '%s' "$L3I_OUT" | tr '\n' ';'))" FAIL

STORE_READ_LIB="$PLUGIN_DIR/hooks/lib/desktop-store-read-v1.js"
TRAIL_SCRIPT="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
L3J_BAD=""
grep -qF "require('./desktop-store-read-v1.js')" "$RESOLVER" || L3J_BAD="$L3J_BAD [the resolver does not require the module]"
grep -qF "'../../../hooks/lib/desktop-store-read-v1.js'" "$TRAIL_SCRIPT" || L3J_BAD="$L3J_BAD [trail.mjs does not load the module]"
for l3j_file in "$RESOLVER" "$TRAIL_SCRIPT"; do
  for l3j_fn in writableOnlyByCaller anyOwnerOrMode realDirectory ownedRegularFile readBoundedBytes readBoundedFile; do
    grep -qE "^function ${l3j_fn}\(" "$l3j_file" && L3J_BAD="$L3J_BAD [$(basename "$l3j_file") defines $l3j_fn]"
    grep -qE "^[[:space:]]*(const|let|var)[[:space:]]+${l3j_fn}[[:space:]]*=" "$l3j_file" && L3J_BAD="$L3J_BAD [$(basename "$l3j_file") binds $l3j_fn]"
  done
done
[ -z "$L3J_BAD" ] \
  && check "L3j the resolver and session-trail take the owner and mode rule and the bounded reader from hooks/lib/desktop-store-read-v1.js and define no copy of their own" PASS \
  || check "L3j one owner for the desktop-store rule:$L3J_BAD" FAIL

L3K_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const lines = [];
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-policy-")));
  try {
    try {
      m.realDirectory(dir);
      lines.push("no-throw");
    } catch (error) {
      lines.push(error instanceof TypeError ? "TypeError" : "other");
    }
    lines.push(String(m.realDirectory(dir, m.anyOwnerOrMode)));
    lines.push(String(m.realDirectory(dir, m.writableOnlyByCaller)));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  process.stdout.write(lines.join("\n"));
' "$STORE_READ_LIB" 2>/dev/null)"
L3K_CALLS="$(cat "$RESOLVER" "$TRAIL_SCRIPT" | grep -oE 'realDirectory\([^()]*\)')"
L3K_TOTAL="$(printf '%s\n' "$L3K_CALLS" | grep -c .)"
L3K_NAMED="$(printf '%s\n' "$L3K_CALLS" | grep -cE ', (writableOnlyByCaller|anyOwnerOrMode)\)$')"
L3K_RAW="$(cat "$RESOLVER" "$TRAIL_SCRIPT" | grep -oE 'realDirectory[[:space:]]*\(' | grep -c .)"
if [ "$L3K_OUT" = "$(printf '%s\n' TypeError true true)" ] \
  && grep -qxF 'function realDirectory(target, accept) {' "$STORE_READ_LIB" \
  && [ "${L3K_TOTAL:-0}" -ge 6 ] && [ "$L3K_NAMED" = "$L3K_TOTAL" ] && [ "$L3K_RAW" = "$L3K_TOTAL" ]; then
  check "L3k realDirectory has no default policy and throws a TypeError without one, and every call in the resolver and session-trail names writableOnlyByCaller or anyOwnerOrMode in a form this pin reads ($L3K_NAMED of $L3K_TOTAL, $L3K_RAW raw)" PASS
else
  check "L3k realDirectory policy (behavior=$(printf '%s' "$L3K_OUT" | tr '\n' ';') named=$L3K_NAMED total=$L3K_TOTAL raw=$L3K_RAW)" FAIL
fi

L3L_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const lines = [];
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-scratch-")));
  try {
    const big = path.join(dir, "big.json");
    const small = path.join(dir, "small.json");
    fs.writeFileSync(big, "a".repeat(100), { mode: 0o600 });
    fs.writeFileSync(small, "b".repeat(10), { mode: 0o600 });
    const scratch = {};
    const first = m.readBoundedBytes(big, 1000, scratch);
    lines.push(first.state + ":" + (first.state === "read" ? first.bytes.length : "-"));
    const held = scratch.buffer;
    const second = m.readBoundedBytes(small, 1000, scratch);
    lines.push(second.state + ":" + (second.state === "read" ? second.bytes.toString("latin1") : "-"));
    lines.push(String(Buffer.isBuffer(held) && scratch.buffer === held));
    const own = m.readBoundedBytes(small, 1000);
    const other = m.readBoundedBytes(small, 1000);
    own.bytes[0] = 0x7a;
    lines.push(other.bytes.toString("latin1"));
    lines.push(m.readBoundedFile(small, 1000).text);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  process.stdout.write(lines.join("\n"));
' "$STORE_READ_LIB" 2>/dev/null)"
if [ "$L3L_OUT" = "$(printf '%s\n' read:100 read:bbbbbbbbbb true bbbbbbbbbb bbbbbbbbbb)" ] \
  && grep -qF 'readBoundedBytes(file, DESKTOP_RECORD_MAX_BYTES, RECORD_SCRATCH)' "$TRAIL_SCRIPT" \
  && ! grep -qE 'readBoundedBytes\([^)]*,[^)]*,' "$RESOLVER"; then
  check "L3l the bounded reader reuses a caller's scratch buffer and returns only the bytes it read, session-trail passes one, and the resolver reads without one, so each of its reads gets its own buffer" PASS
else
  check "L3l scratch buffer (behavior=$(printf '%s' "$L3L_OUT" | tr '\n' ';'))" FAIL
fi

T="$(mktemp -d 2>/dev/null)" || T=""
if [ -z "$T" ] || [ ! -d "$T" ]; then
  check "L0 mktemp -d created a scratch directory" FAIL
  finish; exit
fi
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

unset CLAUDE_CODE_HOST_SESSION_ID CLAUDE_CODE_ACCOUNT_UUID CLAUDE_CODE_ORGANIZATION_UUID XDG_CONFIG_HOME ZENSU_CCD_STORE ZENSU_CCD_EXTRA_STORES \
  CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_CHAIN ZDOC_DELIVERY_ROUTE \
  2>/dev/null || true
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export HOME="$T/home"
mkdir -p "$HOME"
export ZENSU_TEST_PLUGIN_DATA="$T/plugin-data"
export CLAUDE_PLUGIN_DATA="$ZENSU_TEST_PLUGIN_DATA"
CFG_DEFAULT="$T/no-such-config.json"
CFG_NOREMIND="$T/cfg-noremind.json"
CFG_TDD="$T/cfg-tdd.json"
printf '%s' '{"hooks":{"tddReminder":false}}' > "$CFG_NOREMIND"
printf '%s' '{"hooks":{"defaultDeliveryRoute":"build"}}' > "$CFG_TDD"
export ZENSU_CONFIG="$CFG_DEFAULT"

git_q() {
  git -c user.email=fixture@example.invalid -c user.name=fixture -c init.defaultBranch=main \
    -c commit.gpgsign=false "$@" >/dev/null 2>&1
}
REPO="$T/repo"; WT="$T/worktree"; FOREIGN="$T/foreign"; NOGIT="$T/nogit"
mkdir -p "$REPO" "$FOREIGN" "$NOGIT"
if ! { git_q -C "$REPO" init && git_q -C "$REPO" commit --allow-empty -m init \
  && git_q -C "$REPO" worktree add -b linked "$WT" \
  && git_q -C "$FOREIGN" init && git_q -C "$FOREIGN" commit --allow-empty -m init; }; then
  check "L0 the git fixture (a repository, its worktree and a foreign repository) could be built" FAIL
  finish; exit
fi

case "$PLATFORM" in
  (darwin) STORE="$HOME/Library/Application Support/Claude/claude-code-sessions" ;;
  (*) STORE="$HOME/.config/Claude/claude-code-sessions" ;;
esac
ACCT="aaaaaaaa-1111-4111-8111-111111111111"
ORG="bbbbbbbb-2222-4222-8222-222222222222"
DESK="$STORE/$ACCT/$ORG"
mkdir -p "$DESK"

REAL_NODE="$(command -v node)"
SHIM="$T/shim"; TRACE="$T/node-trace.log"
mkdir -p "$SHIM"
cat > "$SHIM/node" <<SHIM_EOF
#!/bin/bash
printf '%s FIELD=%s\n' "\$*" "\${FIELD:-}" >> "$TRACE"
exec "$REAL_NODE" "\$@"
SHIM_EOF
chmod +x "$SHIM/node"
resolver_runs() { grep -c 'linked-session-v1.js' "$TRACE" 2>/dev/null || true; }
session_id_reads() { grep -c 'FIELD=session_id$' "$TRACE" 2>/dev/null || true; }

SEQ=0
next_id() { SEQ=$((SEQ+1)); ID="$(printf '%08x-0000-4000-8000-%012x' "$SEQ" "$SEQ")"; }
key_of() { "$REAL_NODE" "$CORE" session-key "$1"; }
register() {
  ( export CLAUDE_PROJECT_DIR="$2"; source "$BASELINE" "$1" ) >/dev/null 2>&1 \
    && [ -f "$CLAUDE_PLUGIN_DATA/session-control/v1/records/$(key_of "$1").json" ]
}
desk_record() {
  "$REAL_NODE" -e '
    const [file, host, cli, parent, turns] = process.argv.slice(1);
    const record = { sessionId: host, title: "fixture" };
    if (cli) record.cliSessionId = cli;
    if (parent) record.spawnedFrom = { sessionId: parent, taskId: "task_fixture", title: "fixture", sideSession: false, name: "fixture" };
    if (turns === "null") record.completedTurns = null;
    else if (turns) record.completedTurns = Number(turns);
    require("fs").writeFileSync(file, JSON.stringify(record));
  ' "$DESK/$1.json" "$1" "$2" "$3" "${4:-}"
}
session() {
  next_id; CLI="$ID"; HOST="local_$ID"
  register "$CLI" "$1" || return 1
  [ "${3:-}" = "--no-record" ] && return 0
  desk_record "$HOST" "$CLI" "${2:-}"
}
route() {
  CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$2" ZENSU_CONFIG="$CFG_DEFAULT" bash "$HELPER" "$3" 2>/dev/null
}
lib() { bash -c 'source "$0"; f="$1"; shift; "$f" "$@"' "$CONFIG_LIB" "$@"; }
linked_state() { lib zensu_linked_session_state "$1" "$(key_of "$2")"; }
inherited_state() { lib zensu_inherited_route_state "$1" "$(key_of "$2")"; }
linked_marker() { lib zensu_linked_session_marker_path "$1" "$(key_of "$2")"; }
ctx() {
  "$REAL_NODE" -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      try { process.stdout.write(JSON.parse(s).hookSpecificOutput.additionalContext || ""); } catch (_) {}
    });'
}
prompt_json() {
  "$REAL_NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",session_id:process.argv[1],prompt:process.argv[2]}))' "$1" "$2"
}
plan_json() {
  "$REAL_NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",session_id:process.argv[1],tool_name:"ExitPlanMode",tool_input:{plan:"Add a parser function to foo.js and call it from main."}}))' "$1"
}
HOOK_HOME="$HOME"
HOOK_ACCT="$ACCT"
hook() {
  local script="$1" root="$2" cli="$3" host="$4" payload="$5" config="${6:-$CFG_DEFAULT}"
  if [ -n "$host" ]; then
    printf '%s' "$payload" | HOME="$HOOK_HOME" CLAUDE_PROJECT_DIR="$root" CLAUDE_CODE_HOST_SESSION_ID="$host" \
      CLAUDE_CODE_ACCOUNT_UUID="$HOOK_ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" ZENSU_CONFIG="$config" \
      PATH="$SHIM:$PATH" bash "$script" 2>/dev/null | ctx
  else
    printf '%s' "$payload" | HOME="$HOOK_HOME" CLAUDE_PROJECT_DIR="$root" ZENSU_CONFIG="$config" \
      PATH="$SHIM:$PATH" bash "$script" 2>/dev/null | ctx
  fi
}
remind() { hook "$REMINDER" "$1" "$2" "$3" "$(prompt_json "$2" "$4")" "${5:-}"; }
approve() { hook "$PLANHOOK" "$1" "$2" "$3" "$(plan_json "$2")" "${4:-}"; }
last_field() { printf '%s' "$1" | grep -o 'ZENSU DELIVERY ROUTE: [^<]*' | tail -1 | sed 's/[[:space:]]*$//'; }
LEAD="$(bash -c 'source "$0"; printf "%s" "${ZENSU_LINKED_BRIEF_LEAD:-}"' "$DIRECTIVE_LIB" 2>/dev/null)"
lead_count() { [ -n "$LEAD" ] || { echo 0; return; }; printf '%s' "$1" | grep -oF "$LEAD" | grep -c . || true; }
opens_with_lead() { [ -n "$LEAD" ] && [ "${1#"$LEAD "}" != "$1" ]; }
INHERITED='ZENSU DELIVERY ROUTE: build (inherited from parent session)'
ASK='ZENSU DELIVERY ROUTE: ask'

[ -n "$LEAD" ] && check "L4 zensu-directive.sh defines the brief lead" PASS \
  || check "L4 ZENSU_LINKED_BRIEF_LEAD is empty or missing" FAIL
case "$LEAD" in
  (*"brief another session wrote"*"not the user's own text"*"'/zensu:build'"*"'no tdd'"*"decides nothing"*)
    check "L5 the lead says the prompt is another session's brief and that a route preference in it decides nothing in either direction" PASS ;;
  (*) check "L5 lead wording ($LEAD)" FAIL ;;
esac

echo "== AC-001, AC-004, AC-005, AC-006: a linked session inherits build =="
if ! session "$REPO" ""; then
  check "L0 the parent session's Session Control record could be registered" FAIL
  finish; exit
fi
P_CLI="$CLI"; P_HOST="$HOST"
route "$P_CLI" "$REPO" --build >/dev/null
session "$WT" "$P_HOST"; C_CLI="$CLI"; C_HOST="$HOST"
: > "$TRACE"
A1="$(remind "$WT" "$C_CLI" "$C_HOST" "no tdd: add a parser to foo.js")"
A1_RUNS="$(resolver_runs)"
: > "$TRACE"
A2="$(remind "$WT" "$C_CLI" "$C_HOST" "add a function to foo.js")"
A2_RUNS="$(resolver_runs)"
if [ "$(last_field "$A1")" = "$INHERITED" ] && [ "$(inherited_state "$WT" "$C_CLI")" = build ] \
  && [ "$(linked_state "$WT" "$C_CLI")" = linked ] \
  && printf '%s' "$A1" | grep -qF 'route decided by the field below' \
  && ! printf '%s' "$A1" | grep -qF 'AskUserQuestion'; then
  check "L6 a session started from a parent that recorded build opens with the inherited route and is not asked" PASS
else
  check "L6 inheritance (field='$(last_field "$A1")' inherited=$(inherited_state "$WT" "$C_CLI") linked=$(linked_state "$WT" "$C_CLI"))" FAIL
fi
{ opens_with_lead "$A1" && [ "$(lead_count "$A1")" = 1 ]; } \
  && check "L7 the brief prompt opens with the brief note exactly once, even when the brief says 'no tdd'" PASS \
  || check "L7 brief note on the brief prompt (count=$(lead_count "$A1"))" FAIL
{ [ "$(lead_count "$A2")" = 0 ] && [ "$(last_field "$A2")" = "$INHERITED" ]; } \
  && check "L8 the next prompt carries no brief note and keeps the inherited route" PASS \
  || check "L8 later prompt (count=$(lead_count "$A2") field='$(last_field "$A2")')" FAIL
{ [ "$A1_RUNS" = 1 ] && [ "$A2_RUNS" = 0 ]; } \
  && check "L9 the lineage resolves with one resolver process on the first prompt and none on the next" PASS \
  || check "L9 resolver processes (first=$A1_RUNS next=$A2_RUNS)" FAIL

session "$REPO" "$C_HOST"; G_CLI="$CLI"; G_HOST="$HOST"
B1="$(remind "$REPO" "$G_CLI" "$G_HOST" "add a function to foo.js")"
{ [ "$(last_field "$B1")" = "$INHERITED" ] && [ "$(inherited_state "$REPO" "$G_CLI")" = build ]; } \
  && check "L10 a session two levels down inherits through its parent's inherited route" PASS \
  || check "L10 two-level inheritance (field='$(last_field "$B1")')" FAIL

session "$WT" "$P_HOST" --no-record
desk_record "$HOST" "" "$P_HOST"
NOCLI_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
[ "$(last_field "$NOCLI_OUT")" = "$INHERITED" ] \
  && check "L11 an own desktop record without cliSessionId is still bound by its host id and inherits" PASS \
  || check "L11 record without cliSessionId (field='$(last_field "$NOCLI_OUT")')" FAIL

echo "== AC-002: what is never inherited =="
parent_case() {
  session "$REPO" "" || return 1
  PC_CLI="$CLI"; PC_HOST="$HOST"
  local marker
  marker="$(lib zensu_delivery_route_marker_path "$REPO" "$(key_of "$PC_CLI")")"
  case "$1" in
    (direct) route "$PC_CLI" "$REPO" --direct >/dev/null ;;
    (released) route "$PC_CLI" "$REPO" --build >/dev/null; route "$PC_CLI" "$REPO" --auto >/dev/null ;;
    (none) : ;;
    (garbage) mkdir -p "$REPO/.zensu/state"; printf '%s' '{"route":"build' > "$marker" ;;
    (symlink)
      mkdir -p "$REPO/.zensu/state"; printf '%s\n' '{"route":"build"}' > "$T/build-target.json"
      ln -s "$T/build-target.json" "$marker" 2>/dev/null || return 2 ;;
    (direct-over-inherited)
      route "$PC_CLI" "$REPO" --direct >/dev/null
      printf '%s\n' '{"route":"build"}' > "$(lib zensu_inherited_route_marker_path "$REPO" "$(key_of "$PC_CLI")")" ;;
  esac
  session "$WT" "$PC_HOST" || return 1
  PCASE_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
  PCASE_INHERITED="$(inherited_state "$WT" "$CLI")"
  PCASE_LINKED="$(linked_state "$WT" "$CLI")"
}
L12_BAD=""
for state in direct released none garbage symlink direct-over-inherited; do
  parent_case "$state"; rc=$?
  if [ "$rc" -eq 2 ]; then
    check "L12 parent marker '$state' (this host cannot create a symlink)" SKIP
    continue
  fi
  if [ "$rc" -ne 0 ] || [ "$(last_field "$PCASE_OUT")" != "$ASK" ] || [ "$PCASE_INHERITED" != none ] \
    || [ "$PCASE_LINKED" != linked ] || ! opens_with_lead "$PCASE_OUT"; then
    L12_BAD="$L12_BAD [$state: rc=$rc field='$(last_field "$PCASE_OUT")' inherited=$PCASE_INHERITED linked=$PCASE_LINKED]"
  fi
done
[ -z "$L12_BAD" ] \
  && check "L12 a parent's direct, released, absent, unreadable or symlinked marker, and a direct over an inherited build, pass nothing on, while the brief note still applies" PASS \
  || check "L12 parent states:$L12_BAD" FAIL

parent_case none
session "$WT" ""
UNLINKED="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
if [ "$PCASE_OUT" = "$LEAD $UNLINKED" ] && printf '%s' "$UNLINKED" | grep -qF 'AskUserQuestion'; then
  check "L13 on the full reminder the brief note is one opening sentence and changes nothing else" PASS
else
  check "L13 full-text shape (linked=${#PCASE_OUT} chars, unlinked=${#UNLINKED} chars, lead=${#LEAD} chars)" FAIL
fi

repo_case() {
  session "$1" "" || return 1
  route "$CLI" "$1" --build >/dev/null
  local parent="$HOST"
  session "$WT" "$parent" || return 1
  RCASE_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
  RCASE_INHERITED="$(inherited_state "$WT" "$CLI")"
}
repo_case "$FOREIGN"
{ [ "$(last_field "$RCASE_OUT")" = "$ASK" ] && [ "$RCASE_INHERITED" = none ] && opens_with_lead "$RCASE_OUT"; } \
  && check "L14 a parent that recorded build in another repository passes nothing on" PASS \
  || check "L14 foreign repository (field='$(last_field "$RCASE_OUT")' inherited=$RCASE_INHERITED)" FAIL
repo_case "$NOGIT"
{ [ "$(last_field "$RCASE_OUT")" = "$ASK" ] && [ "$RCASE_INHERITED" = none ]; } \
  && check "L15 a parent root that is not a git work tree passes nothing on" PASS \
  || check "L15 non-git parent root (field='$(last_field "$RCASE_OUT")' inherited=$RCASE_INHERITED)" FAIL

session "$WT" "local_$(printf '%08x-0000-4000-8000-%012x' 4095 4095)"
MISSING_PARENT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(last_field "$MISSING_PARENT")" = "$ASK" ] && [ "$(linked_state "$WT" "$CLI")" = linked ] \
  && opens_with_lead "$MISSING_PARENT"; } \
  && check "L16 a parent without a desktop record leaves the session linked, noted and uninherited" PASS \
  || check "L16 missing parent record (field='$(last_field "$MISSING_PARENT")' linked=$(linked_state "$WT" "$CLI"))" FAIL

NOUUID_PARENT="local_$(printf '%08x-0000-4000-8000-%012x' 4094 4094)"
desk_record "$NOUUID_PARENT" "not-a-uuid" ""
session "$WT" "$NOUUID_PARENT"
PARENT_NOUUID="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(last_field "$PARENT_NOUUID")" = "$ASK" ] && [ "$(linked_state "$WT" "$CLI")" = linked ]; } \
  && check "L17 a parent record whose cliSessionId is no UUID leaves the session linked and uninherited" PASS \
  || check "L17 parent cli id not a UUID (field='$(last_field "$PARENT_NOUUID")')" FAIL

GONE="$T/gone-root"
mkdir -p "$GONE"
session "$GONE" ""
route "$CLI" "$GONE" --build >/dev/null
GONE_PARENT="$HOST"
rm -rf "$GONE"
session "$WT" "$GONE_PARENT"
GONE_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(last_field "$GONE_OUT")" = "$ASK" ] && [ "$(inherited_state "$WT" "$CLI")" = none ] \
  && [ "$(linked_state "$WT" "$CLI")" = linked ] && opens_with_lead "$GONE_OUT"; } \
  && check "L17b a parent whose recorded project root was removed leaves the session linked, noted and uninherited" PASS \
  || check "L17b removed parent root (field='$(last_field "$GONE_OUT")' linked=$(linked_state "$WT" "$CLI"))" FAIL
next_id
UNREGISTERED_PARENT="local_$ID"
desk_record "$UNREGISTERED_PARENT" "$ID" ""
session "$WT" "$UNREGISTERED_PARENT"
NOCTX_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(last_field "$NOCTX_OUT")" = "$ASK" ] && [ "$(linked_state "$WT" "$CLI")" = linked ] \
  && opens_with_lead "$NOCTX_OUT"; } \
  && check "L17c a parent without a Session Control record leaves the session linked, noted and uninherited" PASS \
  || check "L17c parent without a Session Control record (field='$(last_field "$NOCTX_OUT")' linked=$(linked_state "$WT" "$CLI"))" FAIL

fault_case() {
  local label="$1" out state
  out="$2"; state="$3"
  if [ "$(last_field "$out")" = "$ASK" ] && [ "$(lead_count "$out")" = 0 ] && [ "$state" = none ]; then
    FAULT_GOOD="$FAULT_GOOD [$label]"
  else
    FAULT_BAD="$FAULT_BAD [$label: field='$(last_field "$out")' lead=$(lead_count "$out") state=$state]"
  fi
}
FAULT_GOOD=""; FAULT_BAD=""
session "$WT" ""
OUT_UNLINKED="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
fault_case not-linked "$OUT_UNLINKED" "$(linked_state "$WT" "$CLI")"
: > "$TRACE"
remind "$WT" "$CLI" "$HOST" "add a function to foo.js" >/dev/null
UNLINKED_RUNS="$(resolver_runs)"
session "$WT" "$P_HOST" --no-record
desk_record "$HOST" "$(printf '%08x-0000-4000-8000-%012x' 4093 4093)" "$P_HOST"
fault_case cli-mismatch "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
session "$WT" "$P_HOST"
fault_case malformed-host "$(remind "$WT" "$CLI" "local_NOT-A-UUID" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
session "$WT" "$P_HOST"
HOOK_ACCT="not-a-uuid"
fault_case malformed-account "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
HOOK_ACCT="$ACCT"
session "$WT" "$P_HOST" --no-record
desk_record "$HOST" "$CLI" "$P_HOST"
mv "$DESK/$HOST.json" "$T/own-record-target.json"
if ln -s "$T/own-record-target.json" "$DESK/$HOST.json" 2>/dev/null; then
  fault_case symlinked-record "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
else
  check "L18 a symlinked own record (this host cannot create a symlink)" SKIP
fi
session "$WT" "$P_HOST" --no-record
head -c 8388609 /dev/zero > "$DESK/$HOST.json"
fault_case oversized-record "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
rm -f "$DESK/$HOST.json"
HOME2="$T/home-linked-store"
case "$PLATFORM" in
  (darwin) STORE2_PARENT="$HOME2/Library/Application Support/Claude" ;;
  (*) STORE2_PARENT="$HOME2/.config/Claude" ;;
esac
mkdir -p "$STORE2_PARENT"
session "$WT" "$P_HOST"
if ln -s "$STORE" "$STORE2_PARENT/claude-code-sessions" 2>/dev/null; then
  HOOK_HOME="$HOME2"
  fault_case symlinked-store "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
  HOOK_HOME="$HOME"
else
  check "L18 a symlinked session store (this host cannot create a symlink)" SKIP
fi
session "$WT" "" --no-record
desk_record "$HOST" "$CLI" "$HOST"
fault_case self-parent "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
mkdir -p "$T/home-without-store"
session "$WT" "$P_HOST"
HOOK_HOME="$T/home-without-store"
fault_case no-store "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
HOOK_HOME="$HOME"
[ -z "$FAULT_BAD" ] \
  && check "L18 every own-side lineage fault answers none, final, with no note and today's route:$FAULT_GOOD" PASS \
  || check "L18 lineage faults:$FAULT_BAD" FAIL
[ "$UNLINKED_RUNS" = 0 ] \
  && check "L19 a resolved unlinked session starts no resolver process on its next prompt" PASS \
  || check "L19 unlinked session next prompt ran the resolver $UNLINKED_RUNS time(s)" FAIL

parent_case none
CFG_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js" "$CFG_TDD")"
{ [ "$(last_field "$CFG_OUT")" = "ZENSU DELIVERY ROUTE: build (hooks.defaultDeliveryRoute)" ] \
  && [ "$(inherited_state "$WT" "$CLI")" = none ]; } \
  && check "L20 a linked session that inherits nothing still takes the configured default" PASS \
  || check "L20 configured default (field='$(last_field "$CFG_OUT")')" FAIL

echo "== D8: a missing own record is retried once =="
session "$WT" "$P_HOST" --no-record
R_CLI="$CLI"; R_HOST="$HOST"
: > "$TRACE"
R1="$(remind "$WT" "$R_CLI" "$R_HOST" "add a function to foo.js")"
R1_STATE="$(linked_state "$WT" "$R_CLI")"
desk_record "$R_HOST" "$R_CLI" "$P_HOST"
R2="$(remind "$WT" "$R_CLI" "$R_HOST" "add a function to foo.js")"
R_RUNS="$(resolver_runs)"
if [ "$R1_STATE" = unresolved ] && [ "$(last_field "$R1")" = "$ASK" ] && [ "$(lead_count "$R1")" = 0 ] \
  && [ "$(last_field "$R2")" = "$INHERITED" ] && [ "$(lead_count "$R2")" = 0 ] \
  && [ "$(linked_state "$WT" "$R_CLI")" = linked ] && [ "$R_RUNS" = 2 ]; then
  check "L21 a record that appears after the first prompt is picked up on the retry, which inherits and adds no brief note" PASS
else
  check "L21 retry (first=$R1_STATE '$(last_field "$R1")' second='$(last_field "$R2")' lead=$(lead_count "$R2") runs=$R_RUNS)" FAIL
fi
session "$WT" "$P_HOST" --no-record
: > "$TRACE"
remind "$WT" "$CLI" "$HOST" "add a function to foo.js" >/dev/null
remind "$WT" "$CLI" "$HOST" "add a function to foo.js" >/dev/null
TWICE_STATE="$(linked_state "$WT" "$CLI")"
remind "$WT" "$CLI" "$HOST" "add a function to foo.js" >/dev/null
TWICE_RUNS="$(resolver_runs)"
{ [ "$TWICE_STATE" = none ] && [ "$TWICE_RUNS" = 2 ]; } \
  && check "L22 a record still missing on the retry is given up as none, so a third prompt starts no resolver" PASS \
  || check "L22 bounded retry (state=$TWICE_STATE runs=$TWICE_RUNS)" FAIL
session "$WT" "$P_HOST" --no-record
printf '%s' '{"sessionId":' > "$DESK/$HOST.json"
UNPARSED="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(linked_state "$WT" "$CLI")" = unresolved ] && [ "$(lead_count "$UNPARSED")" = 0 ] \
  && [ "$(last_field "$UNPARSED")" = "$ASK" ]; } \
  && check "L22b an own record that does not parse is held as unresolved for the one retry, with no note" PASS \
  || check "L22b unparsable own record (state=$(linked_state "$WT" "$CLI") field='$(last_field "$UNPARSED")')" FAIL

echo "== AC-005, AC-006: outside the desktop app =="
session "$WT" "$P_HOST"
: > "$TRACE"
TERM_OUT="$(remind "$WT" "$CLI" "" "add a function to foo.js")"
TERM_RUNS="$(resolver_runs)"
TERM_MARKER="$(linked_marker "$WT" "$CLI")"
{ [ "$TERM_RUNS" = 0 ] && [ ! -e "$TERM_MARKER" ] && [ "$(lead_count "$TERM_OUT")" = 0 ] \
  && [ "$(last_field "$TERM_OUT")" = "$ASK" ]; } \
  && check "L23 a session without CLAUDE_CODE_HOST_SESSION_ID starts no resolver, writes no marker and gets no note" PASS \
  || check "L23 terminal session (runs=$TERM_RUNS marker=$([ -e "$TERM_MARKER" ] && echo present || echo absent))" FAIL

echo "== AC-003, AC-007: override, release and disclosure =="
session "$WT" "$P_HOST"; H_CLI="$CLI"; H_HOST="$HOST"
remind "$WT" "$H_CLI" "$H_HOST" "add a function to foo.js" >/dev/null
H_STATUS="$(route "$H_CLI" "$WT" --status)"
H_DOCTOR="$(CLAUDE_CODE_SESSION_ID="$H_CLI" CLAUDE_PROJECT_DIR="$WT" ZENSU_CONFIG="$CFG_DEFAULT" bash "$DOCTOR" 2>/dev/null)"
[ "$H_STATUS" = "build (inherited from parent session)" ] \
  && check "L24 /zensu:delivery-route --status names the inherited source" PASS \
  || check "L24 --status ($H_STATUS)" FAIL
printf '%s' "$H_DOCTOR" | grep -F 'delivery route: build (inherited from parent session)' | grep -qF '✅' \
  && check "L25 the /zensu:doctor session row names the inherited source, green" PASS \
  || check "L25 doctor row ($(printf '%s' "$H_DOCTOR" | grep -o 'delivery route: [^—]*' | head -1))" FAIL
route "$H_CLI" "$WT" --direct >/dev/null
H_DIRECT_FIELD="$(last_field "$(remind "$WT" "$H_CLI" "$H_HOST" "add a function to foo.js")")"
H_DIRECT_STATUS="$(route "$H_CLI" "$WT" --status)"
route "$H_CLI" "$WT" --auto >/dev/null
H_AUTO_FIELD="$(last_field "$(remind "$WT" "$H_CLI" "$H_HOST" "add a function to foo.js")")"
H_AUTO_STATUS="$(route "$H_CLI" "$WT" --status)"
{ [ "$H_DIRECT_FIELD" = "ZENSU DELIVERY ROUTE: direct (session marker)" ] && [ "$H_DIRECT_STATUS" = "direct (session)" ]; } \
  && check "L26 the linked session's own marker outranks the inherited route" PASS \
  || check "L26 own marker over inherited (field='$H_DIRECT_FIELD' status='$H_DIRECT_STATUS')" FAIL
{ [ "$H_AUTO_FIELD" = "$ASK" ] && [ "$H_AUTO_STATUS" = "ask (default, session choice released)" ] \
  && [ "$(inherited_state "$WT" "$H_CLI")" = build ]; } \
  && check "L27 --auto in the linked session releases the inherited route too, back to the question" PASS \
  || check "L27 release (field='$H_AUTO_FIELD' status='$H_AUTO_STATUS')" FAIL

echo "== D8, D14: the plan gate resolves the lineage when the reminder is off =="
session "$WT" "$P_HOST"; Q_CLI="$CLI"; Q_HOST="$HOST"
Q_REMIND="$(remind "$WT" "$Q_CLI" "$Q_HOST" "add a function to foo.js" "$CFG_NOREMIND")"
: > "$TRACE"
Q_PLAN="$(approve "$WT" "$Q_CLI" "$Q_HOST" "$CFG_NOREMIND")"
Q_READS="$(session_id_reads)"; Q_RUNS="$(resolver_runs)"
{ [ -z "$Q_REMIND" ] && printf '%s' "$Q_PLAN" | grep -qF "$INHERITED" && [ "$(lead_count "$Q_PLAN")" = 0 ] \
  && [ "$(linked_state "$WT" "$Q_CLI")" = linked ]; } \
  && check "L28 with tddReminder off the plan gate resolves the lineage, dispatches on the inherited route and adds no brief note" PASS \
  || check "L28 plan gate (reminder='${Q_REMIND:0:40}' field='$(last_field "$Q_PLAN")' lead=$(lead_count "$Q_PLAN") linked=$(linked_state "$WT" "$Q_CLI"))" FAIL
{ [ "$Q_READS" = 1 ] && [ "$Q_RUNS" = 1 ]; } \
  && check "L28b the resolving plan approval reads the payload session id once and starts one resolver" PASS \
  || check "L28b resolving approval (session-id reads=$Q_READS resolver=$Q_RUNS)" FAIL

echo "== R1-F1: the plan gate starts no process for a lineage that is not pending =="
session "$WT" ""; W_CLI="$CLI"
: > "$TRACE"
approve "$WT" "$W_CLI" "" >/dev/null
W_READS="$(session_id_reads)"; W_RUNS="$(resolver_runs)"
{ [ "$W_READS" = 1 ] && [ "$W_RUNS" = 0 ]; } \
  && check "L31 a plan approval outside the desktop app reads the payload session id once and starts no resolver" PASS \
  || check "L31 terminal approval (session-id reads=$W_READS resolver=$W_RUNS)" FAIL
: > "$TRACE"
approve "$WT" "$C_CLI" "$C_HOST" >/dev/null
V_READS="$(session_id_reads)"; V_RUNS="$(resolver_runs)"
{ [ "$V_READS" = 1 ] && [ "$V_RUNS" = 0 ]; } \
  && check "L32 a plan approval in a session whose lineage is resolved reads the payload session id once and starts no resolver" PASS \
  || check "L32 resolved approval (session-id reads=$V_READS resolver=$V_RUNS)" FAIL

echo "== R1-F11: the brief note follows the desktop's completed turns =="
session "$WT" "$P_HOST"; N_CLI="$CLI"; N_HOST="$HOST"
remind "$WT" "$N_CLI" "$N_HOST" "add a function to foo.js" >/dev/null
desk_record "$N_HOST" "$N_CLI" "$P_HOST" 1
rm -f "$(linked_marker "$WT" "$N_CLI")" "$(lib zensu_inherited_route_marker_path "$WT" "$(key_of "$N_CLI")")"
N_AGAIN="$(remind "$WT" "$N_CLI" "$N_HOST" "add a function to foo.js")"
{ [ "$(lead_count "$N_AGAIN")" = 0 ] && [ "$(last_field "$N_AGAIN")" = "$INHERITED" ] \
  && [ "$(linked_state "$WT" "$N_CLI")" = linked ]; } \
  && check "L29 a lineage resolved again after its markers vanished, with a completed turn on record, inherits and adds no brief note" PASS \
  || check "L29 lost markers (lead=$(lead_count "$N_AGAIN") field='$(last_field "$N_AGAIN")' linked=$(linked_state "$WT" "$N_CLI"))" FAIL
next_id; K_CLI="$ID"
if register "$K_CLI" "$WT"; then
  desk_record "$N_HOST" "$K_CLI" "$P_HOST" 2
  K_OUT="$(remind "$WT" "$K_CLI" "$N_HOST" "add a function to foo.js")"
  { [ "$(lead_count "$K_OUT")" = 0 ] && [ "$(last_field "$K_OUT")" = "$INHERITED" ]; } \
    && check "L30 a new CLI session id under the same desktop session inherits and adds no brief note" PASS \
    || check "L30 re-keyed session (lead=$(lead_count "$K_OUT") field='$(last_field "$K_OUT")')" FAIL
else
  check "L30 the re-keyed session's Session Control record could be registered" FAIL
fi

echo "== R1-F13: a plugin data root reached through a symlinked parent =="
if ln -s "$T" "$T/alias-root" 2>/dev/null; then
  session "$WT" "$P_HOST"; S_CLI="$CLI"; S_HOST="$HOST"
  S_OUT="$(export CLAUDE_PLUGIN_DATA="$T/alias-root/plugin-data"; remind "$WT" "$S_CLI" "$S_HOST" "add a function to foo.js")"
  { [ "$(last_field "$S_OUT")" = "$INHERITED" ] && [ "$(inherited_state "$WT" "$S_CLI")" = build ]; } \
    && check "L33 a CLAUDE_PLUGIN_DATA reached through a symlinked parent directory still finds the parent's record and inherits" PASS \
    || check "L33 aliased plugin data (field='$(last_field "$S_OUT")' inherited=$(inherited_state "$WT" "$S_CLI"))" FAIL
else
  check "L33 a plugin data root behind a symlinked parent (this host cannot create a symlink)" SKIP
fi

echo "== R1-F2: ZENSU_CCD_STORE names the desktop store, as /zensu:session-trail reads it =="
session "$WT" "$P_HOST"; O_CLI="$CLI"; O_HOST="$HOST"
O_OUT="$(export ZENSU_CCD_STORE="$STORE"; HOOK_HOME="$T/home-without-store"; remind "$WT" "$O_CLI" "$O_HOST" "add a function to foo.js")"
{ [ "$(last_field "$O_OUT")" = "$INHERITED" ] && [ "$(linked_state "$WT" "$O_CLI")" = linked ]; } \
  && check "L34 ZENSU_CCD_STORE names the desktop store when the home directory holds none, and the session inherits" PASS \
  || check "L34 store override (field='$(last_field "$O_OUT")' linked=$(linked_state "$WT" "$O_CLI"))" FAIL
mkdir -p "$T/empty-store"
session "$WT" "$P_HOST"; E_CLI="$CLI"; E_HOST="$HOST"
E_OUT="$(export ZENSU_CCD_STORE="$T/empty-store"; remind "$WT" "$E_CLI" "$E_HOST" "add a function to foo.js")"
{ [ "$(last_field "$E_OUT")" = "$ASK" ] && [ "$(linked_state "$WT" "$E_CLI")" = none ] && [ "$(lead_count "$E_OUT")" = 0 ]; } \
  && check "L35 an override naming a directory without the store is authoritative: no fallback to the home store, answered none" PASS \
  || check "L35 authoritative override (field='$(last_field "$E_OUT")' linked=$(linked_state "$WT" "$E_CLI"))" FAIL

echo "== R1-F3: the substitution fallback keeps the brief note =="
FAILNODE="$T/failnode"
mkdir -p "$FAILNODE"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$FAILNODE/node"
chmod +x "$FAILNODE/node"
L36_BAD=""
for body in '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "Reminder. ZENSU DELIVERY ROUTE: __ZENSU_DELIVERY_ROUTE__"}}' \
  '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Reminder. ZENSU DELIVERY ROUTE: __ZENSU_DELIVERY_ROUTE__"}}'; do
  L36_OUT="$(printf '%s' "$body" | PATH="$FAILNODE:$PATH" bash -c 'source "$1"; zensu_delivery_route_substitute ask "$2" "$3"' _ "$DIRECTIVE_LIB" cmd "$LEAD" 2>/dev/null | ctx)"
  [ "$L36_OUT" = "$LEAD Reminder. ZENSU DELIVERY ROUTE: ask" ] || L36_BAD="$L36_BAD [${L36_OUT:0:60}]"
done
[ -z "$L36_BAD" ] \
  && check "L36 when node cannot substitute, the fallback still opens the context with the brief note, in both opener spellings" PASS \
  || check "L36 fallback lead:$L36_BAD" FAIL

echo "== R1-F4: an unwritable lineage cache starts no resolver =="
RO="$T/ro-worktree"
if git_q -C "$REPO" worktree add -b ro "$RO" && session "$RO" "$P_HOST"; then
  RO_CLI="$CLI"; RO_HOST="$HOST"
  mkdir -p "$RO/.zensu/state"
  chmod 500 "$RO/.zensu/state"
  if [ -w "$RO/.zensu/state" ]; then
    chmod 700 "$RO/.zensu/state"
    check "L37 an unwritable lineage cache (this host lets the suite write into a mode-500 directory)" SKIP
  else
    : > "$TRACE"
    RO_1="$(remind "$RO" "$RO_CLI" "$RO_HOST" "add a function to foo.js")"
    remind "$RO" "$RO_CLI" "$RO_HOST" "add a function to foo.js" >/dev/null
    RO_3="$(remind "$RO" "$RO_CLI" "$RO_HOST" "add a function to foo.js")"
    RO_RUNS="$(resolver_runs)"
    chmod 700 "$RO/.zensu/state"
    { [ "$RO_RUNS" = 0 ] && [ "$(last_field "$RO_1")" = "$ASK" ] && [ "$(lead_count "$RO_1")" = 0 ] \
      && [ "$(last_field "$RO_3")" = "$ASK" ]; } \
      && check "L37 a session whose lineage cache cannot be written starts no resolver over three prompts and keeps today's route without a note" PASS \
      || check "L37 unwritable cache (runs=$RO_RUNS first='$(last_field "$RO_1")' lead=$(lead_count "$RO_1") third='$(last_field "$RO_3")')" FAIL
  fi
else
  check "L37 the second worktree and its Session Control record could be built" FAIL
fi

echo "== R1-F5: which prompt origins carry the brief note =="
session "$WT" "$P_HOST"; SL_CLI="$CLI"; SL_HOST="$HOST"
SL_OUT="$(remind "$WT" "$SL_CLI" "$SL_HOST" "/zensu:build add a parser to foo.js")"
{ opens_with_lead "$SL_OUT" && [ "$(lead_count "$SL_OUT")" = 1 ] && [ "$(last_field "$SL_OUT")" = "$INHERITED" ]; } \
  && check "L38 a brief that is a slash command with arguments opens with the brief note once" PASS \
  || check "L38 slash-command brief (lead=$(lead_count "$SL_OUT") field='$(last_field "$SL_OUT")')" FAIL
session "$WT" "$P_HOST"; SB_CLI="$CLI"; SB_HOST="$HOST"
SB_OUT="$(remind "$WT" "$SB_CLI" "$SB_HOST" $'Background (from the session that started this one):\nThe parent session found a parser bug.\n\nTask:\nadd a parser to foo.js')"
{ opens_with_lead "$SB_OUT" && [ "$(lead_count "$SB_OUT")" = 1 ] && [ "$(last_field "$SB_OUT")" = "$INHERITED" ]; } \
  && check "L45 a brief that opens with the app's Background line, which classifies as session-brief, opens with the brief note once" PASS \
  || check "L45 session-brief brief (lead=$(lead_count "$SB_OUT") field='$(last_field "$SB_OUT")')" FAIL
session "$WT" "$P_HOST"; CM_CLI="$CLI"; CM_HOST="$HOST"
CM_1="$(remind "$WT" "$CM_CLI" "$CM_HOST" "<ci-monitor-event>CI failed on pull request 1</ci-monitor-event>")"
CM_STATE="$(linked_state "$WT" "$CM_CLI")"
CM_2="$(remind "$WT" "$CM_CLI" "$CM_HOST" "add a function to foo.js")"
{ [ "$CM_STATE" = linked ] && [ "$(lead_count "$CM_1")" = 0 ] && [ "$(lead_count "$CM_2")" = 0 ] \
  && [ "$(last_field "$CM_1")" = "$INHERITED" ] && [ "$(last_field "$CM_2")" = "$INHERITED" ]; } \
  && check "L39 a CI-monitor event that resolves the lineage carries no brief note, and neither does the next typed prompt" PASS \
  || check "L39 CI-monitor first (state=$CM_STATE lead=$(lead_count "$CM_1")/$(lead_count "$CM_2") field='$(last_field "$CM_1")')" FAIL
session "$WT" "$P_HOST"; PF_CLI="$CLI"; PF_HOST="$HOST"
: > "$TRACE"
PF_PLAN="$(approve "$WT" "$PF_CLI" "$PF_HOST")"
PF_NEXT="$(remind "$WT" "$PF_CLI" "$PF_HOST" "add a function to foo.js")"
PF_RUNS="$(resolver_runs)"
{ [ "$(linked_state "$WT" "$PF_CLI")" = linked ] && [ "$(lead_count "$PF_PLAN")" = 0 ] && [ "$(lead_count "$PF_NEXT")" = 0 ] \
  && [ "$(last_field "$PF_NEXT")" = "$INHERITED" ] && [ "$PF_RUNS" = 1 ]; } \
  && check "L40 with the reminder on, a plan approval that resolves the lineage first leaves no brief note for the next typed prompt" PASS \
  || check "L40 plan gate first (linked=$(linked_state "$WT" "$PF_CLI") lead=$(lead_count "$PF_NEXT") field='$(last_field "$PF_NEXT")' runs=$PF_RUNS)" FAIL

echo "== R2-F3: a record that counts no completed turn yet, and the plan gate's retry =="
L41_BAD=""
for turns in 0 null; do
  session "$WT" "$P_HOST" --no-record; Z_CLI="$CLI"; Z_HOST="$HOST"
  desk_record "$Z_HOST" "$Z_CLI" "$P_HOST" "$turns"
  Z_OUT="$(remind "$WT" "$Z_CLI" "$Z_HOST" "add a function to foo.js")"
  { opens_with_lead "$Z_OUT" && [ "$(lead_count "$Z_OUT")" = 1 ]; } || L41_BAD="$L41_BAD [completedTurns=$turns lead=$(lead_count "$Z_OUT")]"
done
[ -z "$L41_BAD" ] \
  && check "L41 an own record whose completedTurns is 0 or null still counts as the first turn and carries the brief note" PASS \
  || check "L41 first-turn values:$L41_BAD" FAIL
session "$WT" "$P_HOST"; U_CLI="$CLI"; U_HOST="$HOST"
mkdir -p "$WT/.zensu/state"
printf '%s\n' '{"state":"unresolved"}' > "$(linked_marker "$WT" "$U_CLI")"
: > "$TRACE"
U_PLAN="$(approve "$WT" "$U_CLI" "$U_HOST" "$CFG_NOREMIND")"
U_RUNS="$(resolver_runs)"
{ [ "$(linked_state "$WT" "$U_CLI")" = linked ] && printf '%s' "$U_PLAN" | grep -qF "$INHERITED" \
  && [ "$U_RUNS" = 1 ] && [ "$(lead_count "$U_PLAN")" = 0 ]; } \
  && check "L42 with the reminder off, the plan gate retries an unresolved lineage once, links it and dispatches on the inherited route" PASS \
  || check "L42 plan gate retry (linked=$(linked_state "$WT" "$U_CLI") runs=$U_RUNS)" FAIL

echo "== Owner and mode: a desktop store another account can write is never read =="
session "$WT" "$P_HOST"; GW_CLI="$CLI"; GW_HOST="$HOST"
chmod g+w "$STORE"
GW_OUT="$(export ZENSU_CCD_STORE="$STORE"; HOOK_HOME="$T/home-without-store"; remind "$WT" "$GW_CLI" "$GW_HOST" "add a function to foo.js")"
chmod g-w "$STORE"
session "$WT" "$P_HOST"; GP_CLI="$CLI"; GP_HOST="$HOST"
GP_OUT="$(export ZENSU_CCD_STORE="$STORE"; HOOK_HOME="$T/home-without-store"; remind "$WT" "$GP_CLI" "$GP_HOST" "add a function to foo.js")"
{ [ "$(last_field "$GW_OUT")" = "$ASK" ] && [ "$(linked_state "$WT" "$GW_CLI")" = none ] \
  && [ "$(inherited_state "$WT" "$GW_CLI")" = none ] && [ "$(lead_count "$GW_OUT")" = 0 ] \
  && [ "$(last_field "$GP_OUT")" = "$INHERITED" ] && [ "$(linked_state "$WT" "$GP_CLI")" = linked ]; } \
  && check "L43 ZENSU_CCD_STORE naming a group-writable store answers none, with no note and nothing inherited, and the same store made private again inherits" PASS \
  || check "L43 group-writable store (field='$(last_field "$GW_OUT")' linked=$(linked_state "$WT" "$GW_CLI") lead=$(lead_count "$GW_OUT") private='$(last_field "$GP_OUT")')" FAIL
if [ "$(id -u)" != 0 ]; then
  check "L44 desktop records another account owns (this host cannot create one: the suite does not run as root)" SKIP
elif ! session "$WT" "$P_HOST"; then
  check "L44 the root-run linked session's Session Control record could be registered" FAIL
elif ! chown 65534 "$DESK/$HOST.json" 2>/dev/null; then
  check "L44 desktop records another account owns (this host refuses a chown to another uid)" SKIP
else
  FO_CLI="$CLI"; FO_HOST="$HOST"
  FO_OUT="$(remind "$WT" "$FO_CLI" "$FO_HOST" "add a function to foo.js")"
  session "$WT" "$P_HOST"; FP_CLI="$CLI"; FP_HOST="$HOST"
  chown 65534 "$DESK/$P_HOST.json"
  FP_OUT="$(remind "$WT" "$FP_CLI" "$FP_HOST" "add a function to foo.js")"
  chown "$(id -u)" "$DESK/$P_HOST.json"
  session "$WT" "$P_HOST"; FR_CLI="$CLI"; FR_HOST="$HOST"
  FR_OUT="$(remind "$WT" "$FR_CLI" "$FR_HOST" "add a function to foo.js")"
  { [ "$(last_field "$FO_OUT")" = "$ASK" ] && [ "$(linked_state "$WT" "$FO_CLI")" = none ] && [ "$(lead_count "$FO_OUT")" = 0 ] \
    && [ "$(last_field "$FP_OUT")" = "$ASK" ] && [ "$(linked_state "$WT" "$FP_CLI")" = linked ] \
    && [ "$(inherited_state "$WT" "$FP_CLI")" = none ] && opens_with_lead "$FP_OUT" \
    && [ "$(last_field "$FR_OUT")" = "$INHERITED" ]; } \
    && check "L44 an own desktop record another account owns answers none, a parent record another account owns leaves the session linked, noted and uninherited, and the parent record back in the caller's hands passes build on again" PASS \
    || check "L44 foreign-owned records (own='$(last_field "$FO_OUT")' linked=$(linked_state "$WT" "$FO_CLI") parent='$(last_field "$FP_OUT")' linked=$(linked_state "$WT" "$FP_CLI") restored='$(last_field "$FR_OUT")')" FAIL
fi

echo "== Stores of their own: a Session Hub profile store and a store ZENSU_CCD_EXTRA_STORES names =="
DEFAULT_DESK="$DESK"
if [ "$PLATFORM" != darwin ]; then
  check "L46 a linked session whose records sit only in a Session Hub profile store (the profile path is the macOS one)" SKIP
else
  DESK="$HOME/Library/Application Support/Zensu Session Hub/Claude-Profile/cccccccc-3333-4333-8333-333333333333/claude-code-sessions/$ACCT/$ORG"
  mkdir -p "$DESK"
  session "$REPO" ""; HP_CLI="$CLI"; HP_HOST="$HOST"
  route "$HP_CLI" "$REPO" --build >/dev/null
  session "$WT" "$HP_HOST"; HC_CLI="$CLI"; HC_HOST="$HOST"
  HUB_DESK="$DESK"; DESK="$DEFAULT_DESK"
  HUB_OUT="$(remind "$WT" "$HC_CLI" "$HC_HOST" "add a function to foo.js")"
  { [ -f "$HUB_DESK/$HC_HOST.json" ] && [ -f "$HUB_DESK/$HP_HOST.json" ] \
    && [ ! -e "$DESK/$HC_HOST.json" ] && [ ! -e "$DESK/$HP_HOST.json" ] \
    && [ "$(last_field "$HUB_OUT")" = "$INHERITED" ] && [ "$(inherited_state "$WT" "$HC_CLI")" = build ] \
    && [ "$(linked_state "$WT" "$HC_CLI")" = linked ]; } \
    && check "L46 a linked session whose own and parent records sit only in a Session Hub profile store, beside a default store that holds the same account and organization folders without them, inherits build" PASS \
    || check "L46 Session Hub profile store (field='$(last_field "$HUB_OUT")' inherited=$(inherited_state "$WT" "$HC_CLI") linked=$(linked_state "$WT" "$HC_CLI"))" FAIL
fi
NAMED_STORE="$T/named-store"
DESK="$NAMED_STORE/$ACCT/$ORG"
mkdir -p "$DESK"
session "$REPO" ""; NP_CLI="$CLI"; NP_HOST="$HOST"
route "$NP_CLI" "$REPO" --build >/dev/null
session "$WT" "$NP_HOST"; NC_CLI="$CLI"; NC_HOST="$HOST"
session "$WT" "$NP_HOST"; NX_CLI="$CLI"; NX_HOST="$HOST"
NAMED_DESK="$DESK"; DESK="$DEFAULT_DESK"
NAMED_OUT="$(export ZENSU_CCD_EXTRA_STORES="$T/no-such-store:$NAMED_STORE"; remind "$WT" "$NC_CLI" "$NC_HOST" "add a function to foo.js")"
UNNAMED_OUT="$(remind "$WT" "$NX_CLI" "$NX_HOST" "add a function to foo.js")"
{ [ -f "$NAMED_DESK/$NC_HOST.json" ] && [ -f "$NAMED_DESK/$NX_HOST.json" ] \
  && [ ! -e "$DESK/$NC_HOST.json" ] && [ ! -e "$DESK/$NP_HOST.json" ] \
  && [ "$(last_field "$NAMED_OUT")" = "$INHERITED" ] && [ "$(inherited_state "$WT" "$NC_CLI")" = build ] \
  && [ "$(linked_state "$WT" "$NC_CLI")" = linked ] \
  && [ "$(last_field "$UNNAMED_OUT")" != "$INHERITED" ] && [ "$(inherited_state "$WT" "$NX_CLI")" = none ] \
  && [ "$(linked_state "$WT" "$NX_CLI")" = unresolved ]; } \
  && check "L47 a linked session whose records sit only in a store ZENSU_CCD_EXTRA_STORES names, after an entry that names no store, inherits build, while the same layout without the variable stays unresolved and inherits nothing" PASS \
  || check "L47 named store (field='$(last_field "$NAMED_OUT")' inherited=$(inherited_state "$WT" "$NC_CLI") linked=$(linked_state "$WT" "$NC_CLI") unnamed='$(last_field "$UNNAMED_OUT")' unnamed-inherited=$(inherited_state "$WT" "$NX_CLI") unnamed-linked=$(linked_state "$WT" "$NX_CLI"))" FAIL
echo "== The /zensu:doctor linked session row =="
linked_row() {
  local cli="$1" host="$2" cached="$3" home="$4" binding="${5:-bound}"
  ( cd "$PLUGIN_DIR/hooks/lib" && env HOME="$home" ZDOC_BINDING="$binding" ZDOC_SESSION_KEY="$(key_of "$cli")" \
      ZDOC_SESSION_PROJECT_ROOT="$WT" ZDOC_LINKED_SESSION="$cached" ZDOC_INHERITED_ROUTE="${ROW_INHERITED:-none}" \
      ZDOC_DELIVERY_ROUTE="${ROW_ROUTE:-ask}" CLAUDE_CODE_SESSION_ID="${ROW_SESSION_ID-$cli}" CLAUDE_CODE_HOST_SESSION_ID="$host" \
      CLAUDE_CODE_ACCOUNT_UUID="${ROW_ACCT:-$ACCT}" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" \
      CLAUDE_PLUGIN_DATA="${ROW_PLUGIN_DATA:-$CLAUDE_PLUGIN_DATA}" NODE_OPTIONS="${ROW_NODE_OPTIONS:-${NODE_OPTIONS:-}}" \
      ZENSU_CONFIG="$CFG_DEFAULT" "$REAL_NODE" ./zensu-doctor-report.js 2>/dev/null ) \
    | grep -F 'linked session:' || true
}
row_has() {
  local row="$1" glyph="$2" phrase
  shift 2
  [ "$(printf '%s\n' "$row" | grep -c 'linked session:')" = 1 ] || return 1
  printf '%s' "$row" | grep -qF "$glyph" || return 1
  for phrase in "$@"; do
    printf '%s' "$row" | grep -qF -- "$phrase" || return 1
  done
}
session "$REPO" ""; DP_CLI="$CLI"; DP_HOST="$HOST"
session "$WT" "$DP_HOST"; DR_CLI="$CLI"; DR_HOST="$HOST"
DR_ROW="$(linked_row "$DR_CLI" "$DR_HOST" absent "$HOME")"
DN_ROW="$(linked_row "$DR_CLI" "$DR_HOST" none "$HOME")"
DU_ROW="$(linked_row "$DR_CLI" "$DR_HOST" unresolved "$HOME")"
row_has "$DR_ROW" '✅' "started from $DP_HOST, whose project root ($REPO) is in the same repository" \
    "so the hooks inherit that session's build route if it has recorded one by the time they settle this lineage" \
    "both desktop records are in $STORE" \
  && row_has "$DN_ROW" '⚠️' "started from $DP_HOST, whose project root ($REPO) is in the same repository" \
    'keeps that answer, so it inherits nothing' '/zensu:delivery-route --build records the workflow route for this session' \
  && row_has "$DU_ROW" '✅' 'look once more on a later one' \
  && check "L48 a resolved linked session renders a green row naming its parent, the parent's project root in a parenthetical of its own, the shared repository and the store, a cached none turns it into a warning that the session keeps that answer and names /zensu:delivery-route --build, and a cached unresolved says the hooks look once more" PASS \
  || check "L48 resolved row (fresh='$DR_ROW' cached-none='$DN_ROW' cached-unresolved='$DU_ROW')" FAIL
session "$WT" ""; DL_CLI="$CLI"; DL_HOST="$HOST"
DL_ROW="$(linked_row "$DL_CLI" "$DL_HOST" absent "$HOME")"
session "$WT" "$DP_HOST" --no-record; DM_CLI="$CLI"; DM_HOST="$HOST"
DM_ROW="$(linked_row "$DM_CLI" "$DM_HOST" none "$HOME")"
DS_ROW="$(linked_row "$DM_CLI" "$DM_HOST" none "$T/home-without-store")"
DMA_ROW="$(linked_row "$DM_CLI" "$DM_HOST" absent "$HOME")"
DZ_ROW="$(export ZENSU_CCD_STORE="relative/store"; linked_row "$DM_CLI" "$DM_HOST" absent "$HOME")"
DY_ROW="$(linked_row "$DM_CLI" "$DM_HOST" absent "")"
KEPT_NONE='settled its lineage as none on an earlier prompt and keeps that answer'
REACH='helps only a session whose lineage is still open when the change reaches its hooks'
row_has "$DL_ROW" '✅' 'not started from another session' "own desktop record is in $STORE" \
  && row_has "$DM_ROW" '⚠️' "$DM_HOST" '(own-record-missing)' 'Searched: ' "$STORE (no record of this session)" \
    'ZENSU_CCD_EXTRA_STORES' 'ZENSU_CCD_STORE replaces every other store' "$REACH" "$KEPT_NONE" \
  && row_has "$DS_ROW" '⚠️' '(no-session-store)' 'no folder for this account and organization' 'ZENSU_CCD_EXTRA_STORES' "$KEPT_NONE" \
  && row_has "$DMA_ROW" '⚠️' '(own-record-missing)' 'the hooks have not settled this lineage yet' \
  && ! printf '%s' "$DMA_ROW" | grep -qF "$KEPT_NONE" \
  && row_has "$DZ_ROW" '⚠️' 'there is no desktop session store to search (no-session-store)' \
    'ZENSU_CCD_STORE names no absolute path, and while it is set no other store is searched' \
    'Point ZENSU_CCD_STORE at the claude-code-sessions directory that holds this session' "$REACH" \
  && ! printf '%s' "$DZ_ROW" | grep -qF 'Searched: ' && ! printf '%s' "$DZ_ROW" | grep -qF 'APPDATA' \
  && row_has "$DY_ROW" '⚠️' 'there is no desktop session store to search (no-session-store)' \
    "ZENSU_CCD_EXTRA_STORES names no absolute path and the platform's data directory is unknown" \
    'APPDATA or LOCALAPPDATA on Windows' 'ZENSU_CCD_STORE replaces every other store' \
  && check "L49 a session not started from another one renders green, and a store miss renders a warning that names the miss reason, every store searched with its state and the ZENSU_CCD_EXTRA_STORES remedy, for a store without the record and for a home without any store; with a cached none the row adds that this session keeps that answer and the remedy says it helps only an open lineage, with no cached answer it says the hooks have not settled yet, and with no store at all it names the one cause that holds: an override that names no absolute path, or neither a named store nor a known data directory" PASS \
  || check "L49 not-linked and miss rows (not-linked='$DL_ROW' missing='$DM_ROW' missing-unsettled='$DMA_ROW' no-store='$DS_ROW' override-relative='$DZ_ROW' no-home='$DY_ROW')" FAIL
AMB_STORE="$T/ambiguous-store"
mkdir -p "$AMB_STORE/$ACCT/$ORG"
cp "$DESK/$DR_HOST.json" "$AMB_STORE/$ACCT/$ORG/$DR_HOST.json"
DA_ROW="$(export ZENSU_CCD_EXTRA_STORES="$AMB_STORE"; linked_row "$DR_CLI" "$DR_HOST" linked "$HOME")"
rm -f "$AMB_STORE/$ACCT/$ORG/$DR_HOST.json"
DF_ROW="$(export ZENSU_CCD_STORE="$T/forged : store"; linked_row "$DM_CLI" "$DM_HOST" none "$HOME")"
DH_ROW="$(linked_row "$DR_CLI" "" absent "$HOME")"
DB_ROW="$(linked_row "$DR_CLI" "$DR_HOST" absent "$HOME" unbound)"
row_has "$DA_ROW" '⚠️' '(own-record-ambiguous)' "$AMB_STORE (holds this session's record)" "$STORE (holds this session's record)" \
    'resolved its lineage as linked on an earlier prompt and keeps that answer' \
  && row_has "$DF_ROW" '⚠️' '(no-session-store)' '\u003a store' \
  && ! printf '%s' "$DF_ROW" | grep -qF 'forged : store' \
  && printf '%s' "$DF_ROW" | grep -qF 'ZENSU_CCD_STORE is set, so it is the only store searched and ZENSU_CCD_EXTRA_STORES is not read' \
  && ! printf '%s' "$DF_ROW" | grep -qF 'name that folder' \
  && [ -z "$DH_ROW" ] && [ -z "$DB_ROW" ] \
  && check "L50 a record two stores hold renders an ambiguity warning naming both stores and the linked answer the session keeps, a store path that spells a label-value pair is folded, an override in force is named as the only store with the remedy to point it elsewhere or unset it instead of the ZENSU_CCD_EXTRA_STORES remedy, and no row renders without CLAUDE_CODE_HOST_SESSION_ID or a bound session" PASS \
  || check "L50 ambiguous, folded and withheld rows (ambiguous='$DA_ROW' folded='$DF_ROW' no-host='$DH_ROW' unbound='$DB_ROW')" FAIL
if [ "$PLATFORM" != darwin ]; then
  check "L51 the row names Session Hub profile stores by their profile folder (the profile path is the macOS one)" SKIP
else
  HUB_ROW="$(linked_row "$HC_CLI" "$HC_HOST" linked "$HOME")"
  HUB_STORE="$HOME/Library/Application Support/Zensu Session Hub/Claude-Profile/cccccccc-3333-4333-8333-333333333333/claude-code-sessions"
  row_has "$HUB_ROW" '✅' "started from $HP_HOST, whose project root ($REPO) is in the same repository" "both desktop records are in $HUB_STORE" \
    && row_has "$DM_ROW" '⚠️' 'Session Hub profile cccccccc-3333-4333-8333-333333333333 (no record of this session)' \
      "the Session Hub profiles live under $HOME/Library/Application Support/Zensu Session Hub/Claude-Profile" \
    && check "L51 a session whose records sit in a Session Hub profile store renders that store, and a store miss names each profile by its folder" PASS \
    || check "L51 profile rows (resolved='$HUB_ROW' missing='$DM_ROW')" FAIL
fi
session "$WT" "$DP_HOST" --no-record; DW_CLI="$CLI"; DW_HOST="$HOST"
remind "$WT" "$DW_CLI" "$DW_HOST" "add a function to foo.js" >/dev/null
DW_CACHED="$(linked_state "$WT" "$DW_CLI")"
desk_record "$DW_HOST" "$DW_CLI" "$DP_HOST"
DW_ROW="$(HOME="$HOME" CLAUDE_CODE_SESSION_ID="$DW_CLI" CLAUDE_PROJECT_DIR="$WT" CLAUDE_CODE_HOST_SESSION_ID="$DW_HOST" \
  CLAUDE_CODE_ACCOUNT_UUID="$ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" ZENSU_CONFIG="$CFG_DEFAULT" bash "$DOCTOR" 2>/dev/null \
  | grep -F 'linked session:' || true)"
CW_ROW="$(HOME="$HOME" CLAUDE_CODE_SESSION_ID="$C_CLI" CLAUDE_PROJECT_DIR="$WT" CLAUDE_CODE_HOST_SESSION_ID="$C_HOST" \
  CLAUDE_CODE_ACCOUNT_UUID="$ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" ZENSU_CONFIG="$CFG_DEFAULT" bash "$DOCTOR" 2>/dev/null \
  | grep -F 'linked session:' || true)"
[ "$DW_CACHED" = unresolved ] \
  && row_has "$DW_ROW" '✅' "started from $DP_HOST, whose project root ($REPO) is in the same repository" 'look once more on a later one' \
  && [ "$(inherited_state "$WT" "$C_CLI")" = build ] \
  && row_has "$CW_ROW" '✅' "started from $P_HOST, whose project root ($REPO) is in the same repository" \
    'and this session inherited the build route that session had recorded' \
  && check "L52 the real /zensu:doctor wrapper binds the session, reads its cached lineage answer and its inherited route through the shared marker readers and renders the live row beside them: an unsettled answer says the hooks look once more, and a session that inherited build says so" PASS \
  || check "L52 wrapper row (cached=$DW_CACHED row='$DW_ROW' inherited=$(inherited_state "$WT" "$C_CLI") inheriting-row='$CW_ROW')" FAIL
ARM_BAD=""
arm() {
  local label="$1" row="$2" glyph="$3"
  shift 3
  row_has "$row" "$glyph" "$@" || ARM_BAD="$ARM_BAD [$label: '$row']"
}
arm_lacks() {
  printf '%s' "$2" | grep -qF -- "$3" && ARM_BAD="$ARM_BAD [$1 names '$3': '$2']"
  return 0
}
NH_ROW="$(linked_row "$DR_CLI" "local_NOT-A-UUID" absent "$HOME")"
arm malformed-host "$NH_ROW" '⚠️' 'linked session: not checked — CLAUDE_CODE_HOST_SESSION_ID is not in the form' \
  'a missing check rather than an all-clear'
NA_ROW="$(ROW_ACCT=not-a-uuid; linked_row "$DR_CLI" "$DR_HOST" absent "$HOME")"
arm malformed-account "$NA_ROW" '⚠️' 'CLAUDE_CODE_ACCOUNT_UUID or CLAUDE_CODE_ORGANIZATION_UUID is missing or not a UUID'
NI_ROW="$(ROW_SESSION_ID=; linked_row "$DR_CLI" "$DR_HOST" absent "$HOME")"
arm no-session-id "$NI_ROW" '⚠️' 'no CLAUDE_CODE_SESSION_ID reached this report'
session "$WT" "$DP_HOST" --no-record; UR_CLI="$CLI"; UR_HOST="$HOST"
printf '%s' 'not a JSON object' > "$DESK/$UR_HOST.json"
UR_ROW="$(linked_row "$UR_CLI" "$UR_HOST" absent "$HOME")"
arm unreadable "$UR_ROW" '⚠️' "own desktop record in $STORE could not be read" '(own-record-unreadable)'
session "$WT" "$DP_HOST"; RF_CLI="$CLI"; RF_HOST="$HOST"
chmod 664 "$DESK/$RF_HOST.json"
RF_ROW="$(linked_row "$RF_CLI" "$RF_HOST" absent "$HOME")"
arm refused "$RF_ROW" '⚠️' "own desktop record in $STORE was refused" '(own-record-refused)'
session "$WT" "$DP_HOST" --no-record; MM_CLI="$CLI"; MM_HOST="$HOST"
next_id
desk_record "local_$ID" "$MM_CLI" "$DP_HOST"
mv "$DESK/local_$ID.json" "$DESK/$MM_HOST.json"
MM_ROW="$(linked_row "$MM_CLI" "$MM_HOST" absent "$HOME")"
arm mismatch "$MM_ROW" '⚠️' '(own-record-mismatch)'
session "$WT" "$DP_HOST" --no-record; CM_CLI="$CLI"; CM_HOST="$HOST"
desk_record "$CM_HOST" "$(printf '%08x-0000-4000-8000-%012x' 4092 4092)" "$DP_HOST"
CM_ROW="$(linked_row "$CM_CLI" "$CM_HOST" absent "$HOME")"
arm cli-mismatch "$CM_ROW" '⚠️' '(cli-session-mismatch)'
session "$WT" "local_NOT-A-UUID"; MP_CLI="$CLI"; MP_HOST="$HOST"
MP_ROW="$(linked_row "$MP_CLI" "$MP_HOST" absent "$HOME")"
arm malformed-parent "$MP_ROW" '⚠️' '(malformed-parent)'
ABSENT_PARENT="local_$(printf '%08x-0000-4000-8000-%012x' 4091 4091)"
session "$WT" "$ABSENT_PARENT"; PR_CLI="$CLI"; PR_HOST="$HOST"
PR_ROW="$(linked_row "$PR_CLI" "$PR_HOST" absent "$HOME")"
arm parent-record "$PR_ROW" '⚠️' "started from $ABSENT_PARENT, whose desktop record is not readable beside this session's own" \
  '(parent-record-unavailable)'
session "$WT" "$NOUUID_PARENT"; PU_CLI="$CLI"; PU_HOST="$HOST"
PU_ROW="$(linked_row "$PU_CLI" "$PU_HOST" absent "$HOME")"
arm parent-session "$PU_ROW" '⚠️' '(parent-session-unknown)'
RU_ROW="$(ROW_PLUGIN_DATA="$T/no-such-plugin-data"; linked_row "$DR_CLI" "$DR_HOST" absent "$HOME")"
arm records "$RU_ROW" '⚠️' '(records-unavailable)' 'a missing check rather than an all-clear'
session "$WT" "$UNREGISTERED_PARENT"; PX_CLI="$CLI"; PX_HOST="$HOST"
PX_ROW="$(linked_row "$PX_CLI" "$PX_HOST" absent "$HOME")"
arm parent-context "$PX_ROW" '✅' '(parent-context-unavailable)'
session "$WT" "$GONE_PARENT"; PG_CLI="$CLI"; PG_HOST="$HOST"
PG_ROW="$(linked_row "$PG_CLI" "$PG_HOST" absent "$HOME")"
arm parent-root "$PG_ROW" '✅' '(parent-root-unavailable)'
session "$FOREIGN" ""; FP_HOST="$HOST"
session "$WT" "$FP_HOST"; FC_CLI="$CLI"; FC_HOST="$HOST"
FC_ROW="$(linked_row "$FC_CLI" "$FC_HOST" absent "$HOME")"
arm foreign "$FC_ROW" '✅' "started from $FP_HOST, whose project root ($FOREIGN) is in another repository, and a route is never inherited across repositories, so a resolution made now inherits nothing"
session "$NOGIT" ""; UG_PARENT="$HOST"
session "$WT" "$UG_PARENT"; UG_CLI="$CLI"; UG_HOST="$HOST"
UG_ROW="$(linked_row "$UG_CLI" "$UG_HOST" absent "$HOME")"
arm unknown-repository "$UG_ROW" '⚠️' "started from $UG_PARENT, whose project root ($NOGIT) could not be compared with this session's" \
  'a missing check rather than an all-clear'
[ -z "$ARM_BAD" ] \
  && check "L53 every resolver answer renders its own row: the three not-checked arms, an unreadable, refused, mismatching or cli-mismatching own record, a malformed parent, a parent record that is missing or names no session, unreadable Session Control records, a parent context or root that is gone, a parent in another repository, and a repository comparison that could not be made, which is a missing check" PASS \
  || check "L53 resolver answers:$ARM_BAD" FAIL

ARM_BAD=""
RS="$T/refusal-stores"
mkdir -p "$RS/shared/$ACCT/$ORG" "$RS/account/$ACCT/$ORG" "$RS/organization/$ACCT/$ORG" "$RS/target"
chmod 775 "$RS/shared" "$RS/account/$ACCT" "$RS/organization/$ACCT/$ORG"
: > "$RS/file"
ln -s "$RS/target" "$RS/link"
ln -s "$(dirname "$STORE")" "$T/store-alias"
RS_ROW="$(export ZENSU_CCD_EXTRA_STORES="$RS/shared:$RS/account:$RS/organization:$RS/link:$RS/file:$T/store-alias/claude-code-sessions"; linked_row "$DM_CLI" "$DM_HOST" absent "$HOME")"
arm store-states "$RS_ROW" '⚠️' '(own-record-missing)' \
  "$RS/shared (refused: the store folder is writable by group or others)" \
  "$RS/account (refused: its folder for this account is writable by group or others)" \
  "$RS/organization (refused: its folder for this organization is writable by group or others)" \
  "$RS/link (refused: the store folder is a symbolic link)" \
  "$RS/file (refused: the store folder is not a directory)" \
  "$T/store-alias/claude-code-sessions (no record of this session)" \
  "$STORE (the same folder as an earlier store)"
STUB="$T/getuid-stub.js"
printf '%s\n' 'const getuid = process.getuid; process.getuid = () => getuid.call(process) + 1;' > "$STUB"
FO_ROW="$(ROW_NODE_OPTIONS="--require=$STUB"; linked_row "$DM_CLI" "$DM_HOST" absent "$HOME")"
arm foreign-owner "$FO_ROW" '⚠️' "$STORE (refused: the store folder is owned by another account)"
if [ "$(id -u)" = 0 ]; then
  UI_NOTE=" (the uninspectable folder is not checked as root, which may read any folder)"
else
  UI_NOTE=""
  mkdir -p "$RS/locked/store"
  chmod 000 "$RS/locked"
  UI_ROW="$(export ZENSU_CCD_EXTRA_STORES="$RS/locked/store"; linked_row "$DM_CLI" "$DM_HOST" absent "$HOME")"
  chmod 755 "$RS/locked"
  arm uninspectable "$UI_ROW" '⚠️' "$RS/locked/store (refused: the store folder could not be inspected)"
fi
[ -z "$ARM_BAD" ] \
  && check "L54 every store state and refusal cause renders its own text, a refused account or organization folder is named as that folder instead of as its store, and a store that reaches an earlier store's folder is named as the same folder$UI_NOTE" PASS \
  || check "L54 store states:$ARM_BAD" FAIL

ARM_BAD=""
IB_ROW="$(ROW_INHERITED=build; linked_row "$DR_CLI" "$DR_HOST" linked "$HOME")"
arm inherited-build "$IB_ROW" '✅' 'and this session inherited the build route that session had recorded'
IN_ROW="$(ROW_INHERITED=none; linked_row "$DR_CLI" "$DR_HOST" linked "$HOME")"
arm inherited-none "$IN_ROW" '✅' \
  'but nothing was inherited when this session settled its lineage, and a route that session records later does not reach this one'
IU_ROW="$(ROW_INHERITED=unjudged; linked_row "$DR_CLI" "$DR_HOST" linked "$HOME")"
arm inherited-unread "$IU_ROW" '⚠️' 'but whether this session inherited a route could not be read' 'a missing check rather than an all-clear'
CJ_ROW="$(linked_row "$DR_CLI" "$DR_HOST" unjudged "$HOME")"
arm cached-unread "$CJ_ROW" '⚠️' 'the answer the hooks kept for this session could not be read' 'a missing check rather than an all-clear'
UL_ROW="$(linked_row "$UR_CLI" "$UR_HOST" linked "$HOME")"
arm unreadable-kept-linked "$UL_ROW" '⚠️' '(own-record-unreadable)' 'resolved its lineage as linked on an earlier prompt and keeps that answer'
arm_lacks unreadable-kept-linked "$UL_ROW" 'look once more'
UN_ROW="$(linked_row "$UR_CLI" "$UR_HOST" none "$HOME")"
arm unreadable-kept-none "$UN_ROW" '⚠️' '(own-record-unreadable)' "$KEPT_NONE" \
  '/zensu:delivery-route --build records the workflow route for this session'
arm_lacks unreadable-kept-none "$UN_ROW" 'look once more'
UU_ROW="$(linked_row "$UR_CLI" "$UR_HOST" unresolved "$HOME")"
arm unreadable-unsettled "$UU_ROW" '⚠️' '(own-record-unreadable)' 'look once more on a later one'
UA_ROW="$UR_ROW"
arm unreadable-unanswered "$UA_ROW" '⚠️' 'the hooks have not settled this lineage yet'
KEPT_LINKED='resolved its lineage as linked on an earlier prompt and keeps that answer'
STRAY_BUILD='the hooks also kept an inherited build route for this session although they kept no linked lineage answer'
GB_ROW="$(ROW_INHERITED=build; linked_row "$PG_CLI" "$PG_HOST" linked "$HOME")"
arm gone-root-kept-build "$GB_ROW" '✅' '(parent-root-unavailable), so a resolution made now inherits nothing' \
  "$KEPT_LINKED, and with it the build route it inherited from its parent then"
arm_lacks gone-root-kept-build "$GB_ROW" '⚠️'
GN_ROW="$(linked_row "$PG_CLI" "$PG_HOST" linked "$HOME")"
arm gone-root-kept-none "$GN_ROW" '✅' "$KEPT_LINKED, and nothing was inherited then"
GU_ROW="$(ROW_INHERITED=unjudged; linked_row "$PG_CLI" "$PG_HOST" linked "$HOME")"
arm gone-root-kept-unread "$GU_ROW" '⚠️' "$KEPT_LINKED, but whether it inherited a route then could not be read" \
  'a missing check rather than an all-clear'
AB_ROW="$(ROW_INHERITED=build; linked_row "$PR_CLI" "$PR_HOST" linked "$HOME")"
arm absent-parent-kept-build "$AB_ROW" '⚠️' '(parent-record-unavailable), so a resolution made now inherits nothing' \
  "$KEPT_LINKED, and with it the build route it inherited from its parent then"
AU_ROW="$(ROW_INHERITED=unjudged; linked_row "$PR_CLI" "$PR_HOST" linked "$HOME")"
arm absent-parent-kept-unread "$AU_ROW" '⚠️' "$KEPT_LINKED, but whether it inherited a route then could not be read"
INHERITED_FIELD='build (inherited from parent session)'
OWN_FIELD='build (session marker)'
CONFIG_FIELD='direct (hooks.defaultDeliveryRoute)'
SET_ASIDE="$STRAY_BUILD, and this session's own marker sets it aside"
SB_ROW="$(ROW_INHERITED=build; ROW_ROUTE="$INHERITED_FIELD"; linked_row "$DR_CLI" "$DR_HOST" none "$HOME")"
arm stray-build-kept-none "$SB_ROW" '⚠️' 'keeps that answer, while a session started from now on resolves its parent' \
  "$STRAY_BUILD, and the delivery route follows it"
arm_lacks stray-build-kept-none "$SB_ROW" 'so it inherits nothing'
arm_lacks stray-build-kept-none "$SB_ROW" '/zensu:delivery-route --build records'
SA_ROW="$(ROW_INHERITED=build; ROW_ROUTE="$INHERITED_FIELD"; linked_row "$UR_CLI" "$UR_HOST" absent "$HOME")"
arm stray-build-unsettled "$SA_ROW" '⚠️' 'the hooks have not settled this lineage yet' "$STRAY_BUILD, and the delivery route follows it"
SR_ROW="$(ROW_INHERITED=build; linked_row "$DR_CLI" "$DR_HOST" none "$HOME")"
arm released-stray-build "$SR_ROW" '⚠️' 'keeps that answer, so it inherits nothing' \
  '/zensu:delivery-route --build records the workflow route for this session' "$SET_ASIDE"
arm_lacks released-stray-build "$SR_ROW" 'the delivery route follows it'
SO_ROW="$(ROW_INHERITED=build; ROW_ROUTE="$OWN_FIELD"; linked_row "$DR_CLI" "$DR_HOST" absent "$HOME")"
arm own-route-stray-build "$SO_ROW" '✅' "$SET_ASIDE"
arm_lacks own-route-stray-build "$SO_ROW" '⚠️'
OM_ROW="$(ROW_ROUTE="$OWN_FIELD"; linked_row "$DR_CLI" "$DR_HOST" none "$HOME")"
arm own-route-kept-none "$OM_ROW" '✅' \
  "keeps that answer, so it inherits nothing, while a session started from now on resolves its parent; the route this session has, $OWN_FIELD, decides instead"
arm_lacks own-route-kept-none "$OM_ROW" '⚠️'
arm_lacks own-route-kept-none "$OM_ROW" '/zensu:delivery-route --build records'
OD_ROW="$(ROW_ROUTE="$CONFIG_FIELD"; linked_row "$DR_CLI" "$DR_HOST" none "$HOME")"
arm config-route-kept-none "$OD_ROW" '✅' "the route this session has, $CONFIG_FIELD, decides instead"
arm_lacks config-route-kept-none "$OD_ROW" '⚠️'
OS_ROW="$(ROW_ROUTE="$OWN_FIELD"; linked_row "$DM_CLI" "$DM_HOST" none "$HOME")"
arm own-route-kept-none-miss "$OS_ROW" '⚠️' '(own-record-missing)' \
  "$KEPT_NONE, so it inherits nothing; the route this session has, $OWN_FIELD, decides instead"
arm_lacks own-route-kept-none-miss "$OS_ROW" '/zensu:delivery-route --build records'
NX_ROW="$(ROW_INHERITED=unjudged; linked_row "$PG_CLI" "$PG_HOST" none "$HOME")"
arm kept-none-unread "$NX_ROW" '⚠️' "$KEPT_NONE" 'whether the hooks kept an inherited route for this session could not be read'
arm_lacks kept-none-unread "$NX_ROW" 'so it inherits nothing'
[ -z "$ARM_BAD" ] \
  && check "L55 a resolved lineage states what the hooks kept: the build route it inherited, that nothing was inherited, or that the inherited route could not be read; a kept linked beside any other live answer, a gone parent root or an absent parent record among them, states the route it inherited then, or that nothing was inherited, or a missing check; a build route kept without a linked answer is a warning only while the delivery route follows it, and green with 'sets it aside' once the session's own marker outranks or releases it; a kept none is green and names the session's own route instead of the remedy once the delivery route comes from the session marker or hooks.defaultDeliveryRoute; an answer or snapshot the hooks kept that could not be read is a missing check; and an unreadable own record promises another look only while the hooks have not kept an answer" PASS \
  || check "L55 kept answers:$ARM_BAD" FAIL

PAREN_WT="$T/paren) Note. forged"
PAREN_FOREIGN="$T/foreign) Note. forged"
UNDELIMITABLE='whose project root (not rendered — the recorded value carries a parenthesis this row cannot delimit)'
if git_q -C "$REPO" worktree add -b paren "$PAREN_WT" && mkdir -p "$PAREN_FOREIGN" \
  && git_q -C "$PAREN_FOREIGN" init && git_q -C "$PAREN_FOREIGN" commit --allow-empty -m init \
  && session "$PAREN_WT" "" && PS_PARENT="$HOST" && session "$PAREN_FOREIGN" "" && PF_PARENT="$HOST" \
  && session "$WT" "$PS_PARENT" && PS_CLI="$CLI" && PS_HOST="$HOST" \
  && session "$WT" "$PF_PARENT" && PF_CLI="$CLI" && PF_HOST="$HOST"; then
  PS_ROW="$(linked_row "$PS_CLI" "$PS_HOST" absent "$HOME")"
  PF_ROW="$(linked_row "$PF_CLI" "$PF_HOST" absent "$HOME")"
  { row_has "$PS_ROW" '✅' "started from $PS_PARENT, $UNDELIMITABLE is in the same repository" \
    && row_has "$PF_ROW" '✅' "started from $PF_PARENT, $UNDELIMITABLE is in another repository" \
    && ! printf '%s\n%s' "$PS_ROW" "$PF_ROW" | grep -qF 'Note. forged'; } \
    && check "L56 a parent project root that carries a parenthesis is withheld with a reason in both the same-repository and the other-repository row, so it can never close the row's own parenthetical" PASS \
    || check "L56 parenthesized parent root (same='$PS_ROW' foreign='$PF_ROW')" FAIL
else
  check "L56 the parenthesized parent fixtures (a worktree and a repository whose path carries a parenthesis) could be built" FAIL
fi

L57_OUT="$("$REAL_NODE" -e '
  const fs = require("fs");
  const m = require(process.argv[1]);
  const src = fs.readFileSync(process.argv[2], "utf8");
  const body = (name) => {
    const start = src.indexOf("\nfunction " + name + "(");
    if (start === -1) return "";
    const next = src.indexOf("\nfunction ", start + 1);
    return src.slice(start, next === -1 ? src.length : next);
  };
  const text = body("linkedSessionText");
  const states = body("linkedStoreState");
  const folders = body("linkedFolderSubject");
  const missing = [];
  for (const key of Object.keys(m.REASONS)) if (!text.includes("case R." + key + ":")) missing.push("reason:" + key);
  for (const key of Object.keys(m.STORE_STATES)) if (!states.includes("S." + key)) missing.push("state:" + key);
  for (const key of Object.keys(m.STORE_FOLDERS)) if (!folders.includes("F." + key)) missing.push("folder:" + key);
  process.stdout.write(missing.sort().join(" "));
' "$RESOLVER" "$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js" 2>&1)"
[ "$L57_OUT" = "reason:NO_HOST_SESSION reason:RESOLVER_FAILED" ] \
  && check "L57 the doctor row has an arm for every reason the resolver can answer it, every store state and every store folder, keyed on the resolver's exported constants; the only reasons without one are no-host-session, for which no row renders, and resolver-failed, which only the module's command line answers" PASS \
  || check "L57 reasons, states and folders without a row text ($L57_OUT)" FAIL

LINKED_REF="$PLUGIN_DIR/skills/doctor/references/linked-session.md"
LINKED_ROWS="$(printf '%s\n' "$DR_ROW" "$DN_ROW" "$DU_ROW" "$DL_ROW" "$DM_ROW" "$DMA_ROW" "$DS_ROW" "$DZ_ROW" "$DY_ROW" "$DA_ROW" "$DF_ROW" \
  "$NH_ROW" "$NA_ROW" "$NI_ROW" "$UR_ROW" "$RF_ROW" "$MM_ROW" "$CM_ROW" "$MP_ROW" "$PR_ROW" "$PU_ROW" "$RU_ROW" "$PX_ROW" \
  "$PG_ROW" "$FC_ROW" "$UG_ROW" "$RS_ROW" "$FO_ROW" "$IB_ROW" "$IN_ROW" "$IU_ROW" "$CJ_ROW" "$UL_ROW" "$UN_ROW" "$UU_ROW" \
  "$GB_ROW" "$GN_ROW" "$GU_ROW" "$AB_ROW" "$AU_ROW" "$SB_ROW" "$SA_ROW" "$NX_ROW" \
  "$SR_ROW" "$SO_ROW" "$OM_ROW" "$OD_ROW" "$OS_ROW")"
L58_BAD=""
for phrase in 'linked session: started from' 'whose project root' 'is in the same repository' 'is in another repository' \
  'could not be compared with this session' 'keeps that answer' 'look once more on a later one' \
  'the hooks have not settled this lineage yet' 'inherited the build route that session had recorded' \
  'nothing was inherited when this session settled its lineage' 'whether this session inherited a route could not be read' \
  'the answer the hooks kept for this session could not be read' \
  '/zensu:delivery-route --build records the workflow route for this session' \
  'resolved its lineage as linked on an earlier prompt' 'settled its lineage as none on an earlier prompt' \
  'linked session: not started from another session' 'linked session: not checked —' 'a missing check rather than an all-clear' \
  '(own-record-missing)' '(no-session-store)' '(own-record-ambiguous)' '(own-record-unreadable)' '(own-record-refused)' \
  '(own-record-mismatch)' '(cli-session-mismatch)' '(malformed-parent)' '(parent-record-unavailable)' \
  '(parent-session-unknown)' '(records-unavailable)' '(parent-context-unavailable)' '(parent-root-unavailable)' \
  'there is no desktop session store to search' 'ZENSU_CCD_STORE names no absolute path' \
  "the platform's data directory is unknown" 'no folder for this account and organization' 'no record of this session' \
  "holds this session's record" 'the same folder as an earlier store' 'refused: the store folder' \
  'its folder for this account' 'its folder for this organization' 'is writable by group or others' 'is a symbolic link' \
  'is not a directory' 'is owned by another account' 'ZENSU_CCD_EXTRA_STORES' 'ZENSU_CCD_STORE replaces every other store' \
  'ZENSU_CCD_STORE is set, so it is the only store searched' 'helps only a session whose lineage is still open' \
  'a resolution made now inherits nothing' 'a resolution made now cannot inherit' \
  'a route is never inherited across repositories' 'whether a resolution made now inherits its build route was not checked' \
  'and with it the build route it inherited from its parent then' 'and nothing was inherited then' \
  'but whether it inherited a route then could not be read' \
  'the hooks also kept an inherited build route for this session although they kept no linked lineage answer' \
  'whether the hooks kept an inherited route for this session could not be read' \
  'the route this session has,' ', decides instead' "this session's own marker sets it aside"; do
  printf '%s' "$LINKED_ROWS" | grep -qF -- "$phrase" || L58_BAD="$L58_BAD [not emitted: $phrase]"
  grep -qF -- "$phrase" "$LINKED_REF" 2>/dev/null || L58_BAD="$L58_BAD [not documented: $phrase]"
done
grep -qF 'could not be inspected' "$LINKED_REF" 2>/dev/null || L58_BAD="$L58_BAD [not documented: could not be inspected]"
grep -qF 'references/linked-session.md' "$PLUGIN_DIR/skills/doctor/SKILL.md" || L58_BAD="$L58_BAD [no pointer in SKILL.md]"
[ -z "$L58_BAD" ] \
  && check "L58 every linked session row phrase is both emitted and documented in the doctor skill's reference, which SKILL.md names" PASS \
  || check "L58 linked session row documentation:$L58_BAD" FAIL

echo "== Budget: the reminder prints its route field within its deadline =="
DEADLINE_LIB="$PLUGIN_DIR/hooks/lib/zensu-prompt-deadline.sh"
BSHIM="$T/budget-shim"; BTRACE="$T/budget-trace.log"; BPIDS="$T/budget-hung.pids"
mkdir -p "$BSHIM"
cat > "$BSHIM/node" <<SHIM_EOF
#!/bin/bash
case "\$*" in
  (*'core.readContext({ recordsDir, sessionId: key })'*) kind=verify ;;
  (*linked-session-v1.js*) kind=resolver ;;
  (*ZENSU_DIRECTIVE_PLACEHOLDERS*) kind=substitute ;;
  (*classifyPreToolPayload*) kind=principal ;;
  (*'j.hooks.defaultDeliveryRoute'*) kind=config ;;
  (*) kind=other ;;
esac
printf '%s\n' "\$kind" >> "$BTRACE"
if [ -n "\${ZT_HANG:-}" ] && [ "\$kind" = "\$ZT_HANG" ]; then
  printf '%s\n' "\$\$" >> "$BPIDS"
  exec sleep "\${ZT_HANG_FOR:-120}"
fi
exec "$REAL_NODE" "\$@"
SHIM_EOF
chmod +x "$BSHIM/node"
budget_count() { grep -cx "$1" "$BTRACE" 2>/dev/null || true; }
budget_hook() {
  local root="$1" cli="$2" host="$3" prompt="$4" hang="${5:-}" deadline="${6:-}" config="${7:-$CFG_DEFAULT}" entry="${8:-cli}"
  prompt_json "$cli" "$prompt" | HOME="$HOOK_HOME" CLAUDE_PROJECT_DIR="$root" CLAUDE_CODE_HOST_SESSION_ID="$host" \
    CLAUDE_CODE_ACCOUNT_UUID="$HOOK_ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" ZENSU_CONFIG="$config" \
    CLAUDE_CODE_ENTRYPOINT="$entry" ZT_HANG="$hang" ZENSU_PROMPT_DEADLINE_SECONDS="$deadline" PATH="$BSHIM:$PATH" bash "$REMINDER" 2>/dev/null
}
hung_alive() {
  local pid tries alive=0
  [ -s "$BPIDS" ] || { echo 0; return; }
  while IFS= read -r pid; do
    tries=0
    while [ "$tries" -lt 30 ] && ps -p "$pid" -o command= 2>/dev/null | grep -qF 'sleep 120'; do
      sleep 0.1
      tries=$((tries + 1))
    done
    ps -p "$pid" -o command= 2>/dev/null | grep -qF 'sleep 120' && alive=$((alive + 1))
  done < "$BPIDS"
  echo "$alive"
}

session "$WT" "$P_HOST"; BP_CLI="$CLI"; BP_HOST="$HOST"
: > "$BTRACE"
BP_OUT="$(budget_hook "$WT" "$BP_CLI" "$BP_HOST" "add a function to foo.js" | ctx)"
BP_ALL="$(grep -c . "$BTRACE" 2>/dev/null || true)"; BP_VERIFY="$(budget_count verify)"; BP_RESOLVER="$(budget_count resolver)"
{ [ "$(last_field "$BP_OUT")" = "$INHERITED" ] && opens_with_lead "$BP_OUT" \
  && [ "$BP_VERIFY" = 1 ] && [ "$BP_RESOLVER" = 1 ] && [ "${BP_ALL:-99}" -le 9 ]; } \
  && check "L59 a linked first prompt verifies the project root once and starts at most nine node children, and still inherits with the brief note (node=$BP_ALL)" PASS \
  || check "L59 process budget (node=$BP_ALL verify=$BP_VERIFY resolver=$BP_RESOLVER field='$(last_field "$BP_OUT")')" FAIL

session "$WT" "$P_HOST"; BH_CLI="$CLI"; BH_HOST="$HOST"
: > "$BTRACE"; : > "$BPIDS"
BH_START=$SECONDS
BH_OUT="$(budget_hook "$WT" "$BH_CLI" "$BH_HOST" "add a function to foo.js" resolver 12 | ctx)"
BH_TOOK=$((SECONDS - BH_START))
BH_ALIVE="$(hung_alive)"
{ [ "$(last_field "$BH_OUT")" = "$ASK" ] && printf '%s' "$BH_OUT" | grep -qF 'AskUserQuestion' \
  && ! printf '%s' "$BH_OUT" | grep -qF 'shortened' && [ "$(lead_count "$BH_OUT")" = 0 ] \
  && [ "$(budget_count resolver)" = 1 ] && [ ! -e "$(linked_marker "$WT" "$BH_CLI")" ] \
  && [ "$(inherited_state "$WT" "$BH_CLI")" = none ] && [ "$BH_TOOK" -le 20 ] && [ "$BH_ALIVE" = 0 ]; } \
  && check "L60 a resolver that does not answer within the lineage budget is stopped, the full reminder takes its field from the ordinary ladder, and no lineage answer is cached (${BH_TOOK}s)" PASS \
  || check "L60 hung resolver (field='$(last_field "$BH_OUT")' took=${BH_TOOK}s alive=$BH_ALIVE marker=$([ -e "$(linked_marker "$WT" "$BH_CLI")" ] && echo present || echo absent))" FAIL
session "$WT" "$P_HOST"; BO_CLI="$CLI"; BO_HOST="$HOST"
route "$BO_CLI" "$WT" --direct >/dev/null
session "$WT" "$P_HOST"; BG_CLI="$CLI"; BG_HOST="$HOST"
: > "$BTRACE"; : > "$BPIDS"
BO_OUT="$(budget_hook "$WT" "$BO_CLI" "$BO_HOST" "add a function to foo.js" resolver 12 | ctx)"
BG_OUT="$(budget_hook "$WT" "$BG_CLI" "$BG_HOST" "add a function to foo.js" resolver 12 "$CFG_TDD" | ctx)"
BO_ALIVE="$(hung_alive)"
{ [ "$(last_field "$BO_OUT")" = "ZENSU DELIVERY ROUTE: direct (session marker)" ] \
  && [ "$(last_field "$BG_OUT")" = "ZENSU DELIVERY ROUTE: build (hooks.defaultDeliveryRoute)" ] \
  && [ "$(budget_count resolver)" = 2 ] && [ "$BO_ALIVE" = 0 ] \
  && [ ! -e "$(linked_marker "$WT" "$BO_CLI")" ] && [ ! -e "$(linked_marker "$WT" "$BG_CLI")" ] \
  && [ "$(inherited_state "$WT" "$BO_CLI")" = none ] && [ "$(inherited_state "$WT" "$BG_CLI")" = none ]; } \
  && check "L60b under a deferred lineage the session's own marker and the configured default still decide the field" PASS \
  || check "L60b ladder under deferral (own='$(last_field "$BO_OUT")' config='$(last_field "$BG_OUT")' resolver=$(budget_count resolver) alive=$BO_ALIVE)" FAIL
: > "$BTRACE"
BH_NEXT="$(budget_hook "$WT" "$BH_CLI" "$BH_HOST" "add a function to foo.js" | ctx)"
{ [ "$(last_field "$BH_NEXT")" = "$INHERITED" ] && [ "$(linked_state "$WT" "$BH_CLI")" = linked ] \
  && [ "$(budget_count resolver)" = 1 ]; } \
  && check "L61 the next prompt after a deferred lineage resolves it again and inherits build" PASS \
  || check "L61 retry after deferral (field='$(last_field "$BH_NEXT")' linked=$(linked_state "$WT" "$BH_CLI"))" FAIL
session "$WT" "$P_HOST"; BZ_CLI="$CLI"; BZ_HOST="$HOST"
: > "$BTRACE"
BZ_ANSWER="$(CLAUDE_CODE_HOST_SESSION_ID="$BZ_HOST" CLAUDE_CODE_ACCOUNT_UUID="$HOOK_ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" \
  PATH="$BSHIM:$PATH" bash -c 'source "$0"; source "$1"; zensu_linked_session_resolve "$2" "$3" "$4" 0' \
  "$CONFIG_LIB" "$LINKED_LIB" "$WT" "$(key_of "$BZ_CLI")" "$BZ_CLI" 2>/dev/null)"
{ [ "$BZ_ANSWER" = deferred ] && [ "$(budget_count resolver)" = 0 ] && [ ! -e "$(linked_marker "$WT" "$BZ_CLI")" ]; } \
  && check "L61b a spent lineage budget answers deferred without starting the resolver or writing a marker" PASS \
  || check "L61b zero budget (answer='$BZ_ANSWER' resolver=$(budget_count resolver))" FAIL

FB_DIR="$T/fallback"; mkdir -p "$FB_DIR"
fb_run() {
  local name="$1" start=$SECONDS
  shift
  budget_hook "$@" > "$FB_DIR/$name.raw"
  printf '%s\n' "$((SECONDS - start))" > "$FB_DIR/$name.took"
}
fb_ctx() { ctx < "$FB_DIR/$1.raw"; }
fb_took() { cat "$FB_DIR/$1.took" 2>/dev/null || echo 99; }
fb_has() { printf '%s' "$1" | grep -qF -- "$2"; }
ledger_entries() { ls -A "$CLAUDE_PLUGIN_DATA/prompt-ledger/v1/$(key_of "$1")" 2>/dev/null | grep -c '^tdd-'; }
SKILL_FALLBACK="$(bash -c 'source "$0"; printf "%s" "${ZENSU_DELIVERY_ROUTE_SKILL_FALLBACK:-}"' "$DIRECTIVE_LIB" 2>/dev/null)"
SKILL_RENDERED="$(CLAUDE_PLUGIN_DATA= bash -c 'source "$0"; zensu_delivery_route_record_command' "$DIRECTIVE_LIB" 2>/dev/null)"
fb_record_hit() {
  local needle
  for needle in 'zensu-delivery-route.sh' '__ZENSU_ROUTE_COMMAND__' ' --build' "$SKILL_FALLBACK"; do
    fb_has "$1" "$needle" && { printf '%s' "$needle"; return 0; }
  done
  return 1
}
FB_PROMPT="add a function to foo.js"
FB_CI_EVENT='<ci-monitor-event>CI failed on the pull request.</ci-monitor-event>'
session "$WT" "$P_HOST"; FT_CLI="$CLI"
session "$WT" "$P_HOST"; FU_CLI="$CLI"
session "$WT" "$P_HOST"; FD_CLI="$CLI"
route "$FD_CLI" "$WT" --build >/dev/null
session "$WT" "$P_HOST"; FL_CLI="$CLI"; FL_HOST="$HOST"
session "$WT" "$P_HOST"; FC_CLI="$CLI"
session "$WT" "$P_HOST"; FR_CLI="$CLI"
session "$WT" "$P_HOST"; FS_CLI="$CLI"
: > "$BPIDS"
fb_run typed "$WT" "$FT_CLI" "" "$FB_PROMPT" substitute 20 &
fb_run unread "$WT" "$FU_CLI" "" "$FB_PROMPT" config 20 "$CFG_DEFAULT" sdk-ts &
fb_run decided "$WT" "$FD_CLI" "" "$FB_PROMPT" substitute 20 &
fb_run brief "$WT" "$FL_CLI" "$FL_HOST" "$FB_PROMPT" substitute 20 &
fb_run ci "$WT" "$FC_CLI" "" "$FB_CI_EVENT" substitute 20 "$CFG_TDD" &
fb_run ciunread "$WT" "$FR_CLI" "" "$FB_CI_EVENT" config 20 &
fb_run silent "$WT" "$FS_CLI" "" "$FB_PROMPT" principal 20 &
wait
FB_ALIVE="$(hung_alive)"
FB_TYPED="$(fb_ctx typed)"
{ [ "$(last_field "$FB_TYPED")" = "$ASK" ] && fb_has "$FB_TYPED" 'shortened because this hook did not finish within its 20s budget' \
  && fb_has "$FB_TYPED" 'ZENSU HUMAN PRESENT: yes' && fb_has "$FB_TYPED" 'Rank on your own reading of the request' \
  && fb_has "$FB_TYPED" 'offers no /zensu:autopilot, so never run it from this reminder' && fb_has "$FB_TYPED" 'TDD-MODE: strict' \
  && fb_has "$FB_TYPED" 'never states a preference' && fb_has "$FB_TYPED" "The user's own instructions outrank this advice" \
  && ! fb_has "$FB_TYPED" 'was not read' && ! fb_has "$FB_TYPED" 'No person is confirmed present' \
  && [ -n "$SKILL_FALLBACK" ] && [ "$SKILL_RENDERED" = "$SKILL_FALLBACK" ] && ! fb_record_hit "$FB_TYPED" >/dev/null \
  && fb_has "$BH_OUT" 'zensu-delivery-route.sh' && fb_has "$BH_OUT" ' --build' \
  && [ "$(ledger_entries "$FT_CLI")" = 0 ] && [ "$(ledger_entries "$BH_CLI")" -ge 1 ] \
  && [ "$(fb_took typed)" -le 32 ] && [ "$FB_ALIVE" = 0 ]; } \
  && check "L62 a reminder whose work outlives the deadline after reading the route still prints the ask field, the human-present field and the ask safeguards, names neither the route record command, its placeholder, its --build argument nor the skill sentence the directive library renders in its place, and marks no prompt ledger, while the full reminder of L60 names the command with --build and marks the ledger, and no hung child of the seven fallback runs survives ($(fb_took typed)s)" PASS \
  || check "L62 deadline fallback (field='$(last_field "$FB_TYPED")' took=$(fb_took typed)s alive=$FB_ALIVE record='$(fb_record_hit "$FB_TYPED")' skill=$([ -n "$SKILL_FALLBACK" ] && [ "$SKILL_RENDERED" = "$SKILL_FALLBACK" ] && echo read || echo unread) ledger=$(ledger_entries "$FT_CLI")/$(ledger_entries "$BH_CLI") ctx='${FB_TYPED:0:80}')" FAIL
FB_UNREAD="$(fb_ctx unread)"
{ [ "$(last_field "$FB_UNREAD")" = "$ASK" ] && fb_has "$FB_UNREAD" "The session's delivery route was not read" \
  && fb_has "$FB_UNREAD" 'ZENSU HUMAN PRESENT: unknown' && fb_has "$FB_UNREAD" 'No person is confirmed present, so the Yes option comes first' \
  && ! fb_has "$FB_UNREAD" 'Rank on your own reading' && fb_has "$FB_UNREAD" 'offers no /zensu:autopilot' \
  && [ "$(fb_took unread)" -le 32 ]; } \
  && check "L62b a deadline before the route was read says so, and without a confirmed person the fallback puts the workflow first" PASS \
  || check "L62b unread route fallback (field='$(last_field "$FB_UNREAD")' took=$(fb_took unread)s ctx='${FB_UNREAD:0:80}')" FAIL
FB_DECIDED="$(fb_ctx decided)"
{ [ "$(last_field "$FB_DECIDED")" = "ZENSU DELIVERY ROUTE: build (session marker)" ] \
  && fb_has "$FB_DECIDED" 'shortened because this hook' && fb_has "$FB_DECIDED" 'route decided by the field below' \
  && ! fb_has "$FB_DECIDED" 'ZENSU HUMAN PRESENT' && ! fb_has "$FB_DECIDED" 'AskUserQuestion' \
  && [ "$(fb_took decided)" -le 32 ]; } \
  && check "L62c a deadline after the worker read a decided route prints that route's decided line with the real field" PASS \
  || check "L62c decided fallback (field='$(last_field "$FB_DECIDED")' took=$(fb_took decided)s ctx='${FB_DECIDED:0:80}')" FAIL
FB_BRIEF="$(fb_ctx brief)"
{ opens_with_lead "$FB_BRIEF" && [ "$(lead_count "$FB_BRIEF")" = 1 ] && [ "$(last_field "$FB_BRIEF")" = "$INHERITED" ] \
  && fb_has "$FB_BRIEF" 'shortened because this hook' && [ "$(linked_state "$WT" "$FL_CLI")" = linked ] \
  && [ "$(fb_took brief)" -le 32 ]; } \
  && check "L62d a deadline after a linked session's brief was recognized keeps the brief note and the inherited field" PASS \
  || check "L62d brief fallback (lead=$(lead_count "$FB_BRIEF") field='$(last_field "$FB_BRIEF")' linked=$(linked_state "$WT" "$FL_CLI") took=$(fb_took brief)s)" FAIL
FB_CI="$(fb_ctx ci)"
{ [ "$(last_field "$FB_CI")" = "ZENSU DELIVERY ROUTE: build (hooks.defaultDeliveryRoute)" ] && fb_has "$FB_CI" 'CI-monitor event' \
  && ! fb_has "$FB_CI" 'was not read' && ! fb_has "$FB_CI" 'AskUserQuestion' && [ "$(fb_took ci)" -le 32 ]; } \
  && check "L63 a CI-monitor event whose work outlives the deadline gets the CI note with the field the worker read, never the ask-first text" PASS \
  || check "L63 CI deadline fallback (field='$(last_field "$FB_CI")' took=$(fb_took ci)s ctx='${FB_CI:0:60}')" FAIL
FB_CIU="$(fb_ctx ciunread)"
{ [ "$(last_field "$FB_CIU")" = "$ASK" ] && fb_has "$FB_CIU" 'CI-monitor event' && fb_has "$FB_CIU" 'the delivery route was not read' \
  && fb_has "$FB_CIU" 'run the Zensu workflow (the Skill tool with skill zensu:build' && ! fb_has "$FB_CIU" 'AskUserQuestion' \
  && [ "$(fb_took ciunread)" -le 32 ]; } \
  && check "L63b a CI-monitor event whose route was not read gets the ask field and the sentence that a code change runs the Zensu workflow" PASS \
  || check "L63b unread CI fallback (field='$(last_field "$FB_CIU")' took=$(fb_took ciunread)s ctx='${FB_CIU:0:60}')" FAIL
{ [ ! -s "$FB_DIR/silent.raw" ] && [ "$(fb_took silent)" -le 32 ]; } \
  && check "L64 a prompt the reminder has not classified by the deadline gets no output at all ($(fb_took silent)s)" PASS \
  || check "L64 unclassified prompt (took=$(fb_took silent)s raw='$(head -c 60 "$FB_DIR/silent.raw" 2>/dev/null)')" FAIL

B_REG="$(node -e '
  const { registeredHooks } = require(process.argv[1]);
  const manifest = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
  const hit = (registeredHooks(manifest, "UserPromptSubmit") || []).find(({ command }) => /user-prompt-tdd-reminder\.sh/.test(command || ""));
  process.stdout.write(hit && Number.isInteger(hit.timeout) ? String(hit.timeout) : "none");
' "$PLUGIN_DIR/hooks/lib/hook-registration-v1.js" "$PLUGIN_DIR/hooks/hooks.json" 2>/dev/null)"
B_CLAMP="$(for v in unset '' 1 0 007 015 99 abc 1234567; do
  if [ "$v" = unset ]; then bash -c 'source "$0"; zensu_prompt_deadline_seconds' "$DEADLINE_LIB"
  else ZENSU_PROMPT_DEADLINE_SECONDS="$v" bash -c 'source "$0"; zensu_prompt_deadline_seconds' "$DEADLINE_LIB"; fi
done 2>/dev/null | tr '\n' ' ')"
B_MAX="$(bash -c 'source "$0"; printf "%s" "$ZENSU_PROMPT_DEADLINE_MAX_SECONDS"' "$DEADLINE_LIB" 2>/dev/null)"
{ [ "$B_CLAMP" = "20 20 10 10 10 15 20 20 20 " ] && [ -n "$B_MAX" ] && [ "$B_REG" != none ] && [ "$B_REG" -ge $((B_MAX + 10)) ]; } \
  && check "L65 the deadline defaults to 20s and clamps to 10-20s, and the reminder's host timeout (${B_REG}s) is at least the ceiling plus 10s" PASS \
  || check "L65 deadline bounds (clamp='$B_CLAMP' max=$B_MAX registration=$B_REG)" FAIL


echo "== Budget: the deadline library supervises a worker =="
PD="$T/prompt-deadline"; mkdir -p "$PD/mark" "$PD/tmp" "$PD/shim"
PD_REAL_SLEEP="$(command -v sleep)"
PD_SLACK=3
cat > "$PD/shim/sleep" <<SHIM_EOF
#!/bin/bash
printf '%s\n' "\$\$" > "\${MARK_DIR:-$PD/mark}/sleep.\$1"
printf '%s\n' "\$PPID" > "\${MARK_DIR:-$PD/mark}/parent.\$1"
exec "$PD_REAL_SLEEP" "\$@"
SHIM_EOF
chmod +x "$PD/shim/sleep"
cat > "$PD/driver.sh" <<'EOF'
#!/bin/bash
set -u
source "$1"
zensu_prompt_deadline_seconds() { printf '%s\n' "$DRIVER_DEADLINE"; }
pd_fallback() {
  printf 'FALLBACK kind=%s deadline=%s route=%s multi=%s long=%s bad=%s\n' "$1" "$2" "$(zensu_prompt_recorded route)" \
    "$(zensu_prompt_recorded multi)" "$(zensu_prompt_recorded long)" "$(zensu_prompt_recorded Bad)"
}
zensu_prompt_supervise "$2" "$3" pd_fallback
EOF
cat > "$PD/worker-hang.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--zensu-prompt-worker" ] || exit 97
source "$PD_LIB"
zensu_prompt_worker_enter "$@"
printf '%s\n' "$$" >"$MARK_DIR/worker.pid"
sleep 600 &
printf '%s\n' "$!" >"$MARK_DIR/grandchild.pid"
[ -n "${PD_KIND:-}" ] && zensu_prompt_classified "$PD_KIND"
[ -n "${PD_RAW_KIND:-}" ] && printf '%s\n' "$PD_RAW_KIND" >"$3/classified"
zensu_prompt_record route 'build (session marker)'
zensu_prompt_record multi "$(printf 'a\nb')"
zensu_prompt_record long "$(printf '%0300d' 0)"
zensu_prompt_record Bad refused
printf 'partial stdout'
printf 'partial stderr\n' >&2
sleep 600
EOF
cat > "$PD/worker-delivered.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--zensu-prompt-worker" ] || exit 97
source "$PD_LIB"
zensu_prompt_worker_enter "$@"
zensu_prompt_classified prompt
printf '{"delivered":true}\n'
zensu_prompt_delivered
sleep 600
EOF
cat > "$PD/worker-fast.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--zensu-prompt-worker" ] || exit 97
source "$PD_LIB"
zensu_prompt_worker_enter "$@"
cat >"$MARK_DIR/stdin.copy"
seen() {
  local i=0
  while [ "$i" -le "$PD_SLACK" ]; do
    [ -s "$MARK_DIR/sleep.$((PD_WATCH - i))" ] && return 0
    i=$((i + 1))
  done
  return 1
}
tries=0
while ! seen && [ "$tries" -lt 100 ]; do
  sleep 0.1
  tries=$((tries + 1))
done
printf 'fast stdout'
printf 'fast stderr\n' >&2
exit 2
EOF
cat > "$PD/worker-lineage.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--zensu-prompt-worker" ] || exit 97
source "$PD_LIB"
zensu_prompt_worker_enter "$@"
printf '%s\n' "$$" >"$MARK_DIR/worker.pid"
source "$PD_CONFIG_LIB"
source "$PD_LINKED_LIB"
answer="$(zensu_linked_session_resolve "$PD_ROOT" "$PD_KEY" "$PD_CLI" "$PD_BUDGET")"
printf '%s\n' "$answer" >"$MARK_DIR/answer"
sleep 600
EOF
pd_drive() {
  TMPDIR="$PD/tmp" DRIVER_DEADLINE="$1" MARK_DIR="$PD/mark" PD_LIB="$DEADLINE_LIB" PD_KIND="${4:-}" PD_RAW_KIND="${5:-}" \
    PD_WATCH="$1" PD_SLACK="$PD_SLACK" PATH="$PD/shim:$PATH" bash "$PD/driver.sh" "$DEADLINE_LIB" "$2" "$3"
}
pd_alive() { kill -0 "$(cat "$PD/mark/$1.pid" 2>/dev/null)" 2>/dev/null && echo yes || echo no; }
pd_watchdog() {
  local i=0
  while [ "$i" -le "$PD_SLACK" ]; do
    cat "$PD/mark/sleep.$(($1 - i))" 2>/dev/null && return 0
    i=$((i + 1))
  done
  return 1
}
pd_watchdog_state() {
  local pid
  pid="$(pd_watchdog "$1")"
  if [ -z "$pid" ]; then echo never
  elif kill -0 "$pid" 2>/dev/null; then echo alive
  else echo gone
  fi
}
pd_tmp_left() { ls -A "$PD/tmp" | wc -l | tr -d ' '; }
pd_wait_for() {
  local tries=0
  while [ ! -s "$1" ] && [ "$tries" -lt 100 ]; do sleep 0.1; tries=$((tries + 1)); done
  [ -s "$1" ]
}

rm -f "$PD/mark/"*.pid
PD_T0=$SECONDS
pd_drive 2 "$PD/worker-hang.sh" '{"p":1}' prompt >"$PD/d.out" 2>"$PD/d.err"; PD_RC=$?
PD_TOOK=$((SECONDS - PD_T0))
{ [ "$PD_RC" = 0 ] && [ "$(cat "$PD/d.out")" = "FALLBACK kind=prompt deadline=2 route=build (session marker) multi= long= bad=" ] \
  && [ ! -s "$PD/d.err" ] && [ "$PD_TOOK" -le 12 ] && [ "$(pd_alive worker)" = no ] && [ "$(pd_alive grandchild)" = no ] \
  && [ "$(pd_tmp_left)" = 0 ]; } \
  && check "L66 a classified worker past the deadline is stopped with its process group, its partial output is dropped, and the fallback gets the kind, the deadline and only the single-line facts it may read (${PD_TOOK}s)" PASS \
  || check "L66 hung classified worker (rc=$PD_RC out='$(cat "$PD/d.out")' worker=$(pd_alive worker) grandchild=$(pd_alive grandchild) tmp=$(pd_tmp_left))" FAIL

PD_NAMES="$(LC_ALL=en_US.UTF-8 bash -c '
  shopt -u globasciiranges 2>/dev/null
  source "$1" >/dev/null 2>&1 || exit 9
  for name in prompt ok-1 "$4" Bad "$2" bad_name "$3" 1abc -abc a/b .. a.b "" "$5"; do
    if _zensu_prompt_name_ok "$name"; then printf a; else printf r; fi
  done
  case B in ([a-z]) printf :collating ;; (*) printf :ascii ;; esac
' _ "$DEADLINE_LIB" "$(printf '\303\251')" "$(printf '%033d' 0 | tr 0 a)" "$(printf '%032d' 0 | tr 0 a)" "a$(printf '\303\251')" 2>/dev/null)"
PD_SCREEN="$(bash -c 'source "$1" >/dev/null 2>&1 && declare -f _zensu_prompt_name_ok' _ "$DEADLINE_LIB" 2>/dev/null)"
PD_RANGES=unread
case "$PD_SCREEN" in
  (*'[abcdefghijklmnopqrstuvwxyz]'*)
    case "$PD_SCREEN" in (*'[!abcdefghijklmnopqrstuvwxyz0123456789-]'*) PD_RANGES=no ;; esac ;;
esac
printf '%s' "$PD_SCREEN" | grep -qE '[[:alnum:]]-[[:alnum:]]' && PD_RANGES=yes
case "$PD_RANGES:$PD_NAMES" in
  (no:aaarrrrrrrrrrr:collating)
    check "L66b the name screen spells both of its character classes out with no bracket range, accepts a 32-character name and refuses upper-case, accented, underscored, over-long, leading-digit, leading-hyphen, slash, dot, empty and accented-tail names, here also under a locale whose bracket ranges collate" PASS ;;
  (no:aaarrrrrrrrrrr:ascii)
    check "L66b the name screen spells both of its character classes out with no bracket range and accepts and refuses the same names; bracket ranges did not collate under en_US.UTF-8 in this shell, so only the parse check could tell a range from a spelled-out class here" PASS ;;
  (*)
    check "L66b name screen (ranges=$PD_RANGES got '$PD_NAMES', want aaarrrrrrrrrrr)" FAIL ;;
esac

rm -f "$PD/mark/"*.pid
pd_drive 2 "$PD/worker-hang.sh" '{}' '' 'Not A Kind' >"$PD/d.out" 2>"$PD/d.err"; PD_RC=$?
{ [ "$PD_RC" = 0 ] && [ ! -s "$PD/d.out" ] && [ ! -s "$PD/d.err" ] && [ "$(pd_alive grandchild)" = no ] && [ "$(pd_tmp_left)" = 0 ]; } \
  && check "L67 a classified file that does not hold a kind the library accepts gets no fallback" PASS \
  || check "L67 refused kind (rc=$PD_RC out='$(cat "$PD/d.out")' grandchild=$(pd_alive grandchild) tmp=$(pd_tmp_left))" FAIL

pd_drive 2 "$PD/worker-delivered.sh" '{}' >"$PD/d.out" 2>"$PD/d.err"; PD_RC=$?
{ [ "$PD_RC" = 0 ] && [ "$(cat "$PD/d.out")" = '{"delivered":true}' ] && [ "$(pd_tmp_left)" = 0 ]; } \
  && check "L68 a worker that marked its output delivered before the deadline is forwarded with exit 0, never replaced by the fallback" PASS \
  || check "L68 delivered worker (rc=$PD_RC out='$(cat "$PD/d.out")' tmp=$(pd_tmp_left))" FAIL

PD_PAYLOAD='{"hook_event_name":"UserPromptSubmit","prompt":"tab	and \"quote\" and trailing spaces  "}'
rm -f "$PD/mark/"sleep.*
pd_drive 4271 "$PD/worker-fast.sh" "$PD_PAYLOAD" >"$PD/d.out" 2>"$PD/d.err"; PD_RC=$?
sleep 1
{ [ "$PD_RC" = 2 ] && [ "$(cat "$PD/d.out")" = "fast stdout" ] && [ "$(cat "$PD/d.err")" = "fast stderr" ] \
  && [ "$(cat "$PD/mark/stdin.copy")" = "$PD_PAYLOAD" ] && [ "$(pd_watchdog_state 4271)" = gone ] && [ "$(pd_tmp_left)" = 0 ]; } \
  && check "L69 a worker that finishes in time has stdin, stdout, stderr and its exit code passed through, and the watchdog recorded while it ran is gone afterwards, with no private directory left behind" PASS \
  || check "L69 pass-through (rc=$PD_RC out='$(cat "$PD/d.out")' err='$(cat "$PD/d.err")' watchdog=$(pd_watchdog_state 4271) tmp=$(pd_tmp_left))" FAIL

rm -f "$PD/mark/"*.pid
PD_T0=$SECONDS
TMPDIR="$PD/tmp" DRIVER_DEADLINE=4 MARK_DIR="$PD/mark" PD_LIB="$DEADLINE_LIB" PD_KIND=prompt \
  bash "$PD/driver.sh" "$DEADLINE_LIB" "$PD/worker-hang.sh" '{}' >/dev/null 2>&1 &
PD_DRIVER=$!
pd_wait_for "$PD/mark/grandchild.pid"
kill -KILL "$PD_DRIVER" 2>/dev/null
wait "$PD_DRIVER" 2>/dev/null
PD_GONE=no
kill -0 "$PD_DRIVER" 2>/dev/null || PD_GONE=yes
PD_BEFORE="$(pd_alive worker)"
while [ $((SECONDS - PD_T0)) -lt 8 ]; do sleep 1; done
{ [ "$PD_GONE" = yes ] && [ "$PD_BEFORE" = yes ] && [ "$(pd_alive worker)" = no ] && [ "$(pd_alive grandchild)" = no ] \
  && [ "$(pd_tmp_left)" = 0 ]; } \
  && check "L70 a supervisor killed by SIGKILL still has its worker group stopped at the deadline and its private directory removed, by the watchdog it left behind" PASS \
  || check "L70 orphaned worker (supervisor gone=$PD_GONE worker before=$PD_BEFORE after=$(pd_alive worker) grandchild=$(pd_alive grandchild) tmp=$(pd_tmp_left))" FAIL

rm -f "$PD/mark/"*.pid "$PD/mark/"sleep.*
TMPDIR="$PD/tmp" DRIVER_DEADLINE=37 MARK_DIR="$PD/mark" PD_LIB="$DEADLINE_LIB" PD_KIND=prompt PATH="$PD/shim:$PATH" \
  bash "$PD/driver.sh" "$DEADLINE_LIB" "$PD/worker-hang.sh" '{}' >"$PD/d.out" 2>&1 &
PD_DRIVER=$!
pd_wait_for "$PD/mark/grandchild.pid"
PD_TRIES=0
while [ "$(pd_watchdog_state 37)" = never ] && [ "$PD_TRIES" -lt 100 ]; do sleep 0.1; PD_TRIES=$((PD_TRIES + 1)); done
PD_WATCH_BEFORE="$(pd_watchdog_state 37)"
kill -TERM "$PD_DRIVER" 2>/dev/null
wait "$PD_DRIVER"
PD_RC=$?
sleep 1
{ [ "$PD_RC" = 143 ] && [ ! -s "$PD/d.out" ] && [ "$(pd_alive worker)" = no ] && [ "$(pd_alive grandchild)" = no ] \
  && [ "$PD_WATCH_BEFORE" = alive ] && [ "$(pd_watchdog_state 37)" = gone ] && [ "$(pd_tmp_left)" = 0 ]; } \
  && check "L71 SIGTERM to the supervisor stops the worker group and the watchdog that was sleeping at once, prints nothing and exits 143" PASS \
  || check "L71 SIGTERM (rc=$PD_RC worker=$(pd_alive worker) grandchild=$(pd_alive grandchild) watchdog=$PD_WATCH_BEFORE/$(pd_watchdog_state 37) tmp=$(pd_tmp_left))" FAIL

PD_LINEAGE_BUDGET=10
pd_lineage() {
  local dir="$PD/lineage-$1" cli="$2" host="$3" hang="$4"
  TMPDIR="$PD/tmp" DRIVER_DEADLINE=3 MARK_DIR="$dir" PD_LIB="$DEADLINE_LIB" PD_CONFIG_LIB="$CONFIG_LIB" \
    PD_LINKED_LIB="$LINKED_LIB" PD_ROOT="$WT" PD_KEY="$(key_of "$cli")" PD_CLI="$cli" PD_BUDGET="$PD_LINEAGE_BUDGET" \
    CLAUDE_CODE_HOST_SESSION_ID="$host" CLAUDE_CODE_ACCOUNT_UUID="$HOOK_ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" \
    ZT_HANG=resolver ZT_HANG_FOR="$hang" PATH="$PD/shim:$BSHIM:$PATH" \
    bash "$PD/driver.sh" "$DEADLINE_LIB" "$PD/worker-lineage.sh" '{}' >"$dir/driver.out" 2>&1
}
pd_mark() { cat "$PD/lineage-$1/$2" 2>/dev/null; }
pd_pgid() { [ -n "$1" ] && ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }
pd_up() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || { echo down; return; }
  case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in
    (Z*) echo down ;;
    (*) echo up ;;
  esac
}
pd_down_within() {
  local tries=0
  while [ "$tries" -lt "$2" ] && [ "$(pd_up "$1")" = up ]; do sleep 0.1; tries=$((tries + 1)); done
  pd_up "$1"
}
pd_reap() { [ -n "$1" ] && ps -p "$1" -o command= 2>/dev/null | grep -qF -- "$2" && kill -KILL "$1" 2>/dev/null; }
mkdir -p "$PD/lineage-hung" "$PD/lineage-answer"
session "$WT" "$P_HOST"; LH_CLI="$CLI"; LH_HOST="$HOST"
session "$WT" "$P_HOST"; LA_CLI="$CLI"; LA_HOST="$HOST"
PD_L0=$SECONDS
pd_lineage hung "$LH_CLI" "$LH_HOST" 120 &
LH_DRIVER=$!
pd_lineage answer "$LA_CLI" "$LA_HOST" 5 &
LA_DRIVER=$!
PD_TRIES=0
while [ "$PD_TRIES" -lt 100 ] && { [ ! -s "$PD/lineage-hung/parent.$PD_LINEAGE_BUDGET" ] || [ ! -s "$PD/lineage-hung/sleep.120" ] \
  || [ ! -s "$PD/lineage-answer/parent.$PD_LINEAGE_BUDGET" ] || [ ! -s "$PD/lineage-answer/sleep.5" ]; }; do
  sleep 0.1; PD_TRIES=$((PD_TRIES + 1))
done
PD_R=$SECONDS
LH_WORKER="$(pd_mark hung worker.pid)"; LH_RESOLVER="$(pd_mark hung sleep.120)"
LH_SLEEP="$(pd_mark hung "sleep.$PD_LINEAGE_BUDGET")"; LH_WATCH="$(pd_mark hung "parent.$PD_LINEAGE_BUDGET")"
LA_WORKER="$(pd_mark answer worker.pid)"; LA_RESOLVER="$(pd_mark answer sleep.5)"
LA_SLEEP="$(pd_mark answer "sleep.$PD_LINEAGE_BUDGET")"; LA_WATCH="$(pd_mark answer "parent.$PD_LINEAGE_BUDGET")"
wait "$LH_DRIVER"; LH_RC=$?
wait "$LA_DRIVER"; LA_RC=$?
LH_GROUPS="$(pd_pgid "$LH_RESOLVER")/$(pd_pgid "$LH_WATCH")"
LA_GROUPS="$(pd_pgid "$LA_RESOLVER")/$(pd_pgid "$LA_WATCH")"
LH_A="$(pd_up "$LH_WORKER") $(pd_up "$LH_RESOLVER") $(pd_up "$LH_SLEEP") $(pd_up "$LH_WATCH")"
LA_A="$(pd_up "$LA_WORKER") $(pd_up "$LA_RESOLVER") $(pd_up "$LA_SLEEP") $(pd_up "$LA_WATCH")"
while [ $((SECONDS - PD_R)) -lt 7 ]; do sleep 0.5; done
LA_B="$(pd_down_within "$LA_RESOLVER" 10) $(pd_up "$LA_SLEEP") $(pd_up "$LA_WATCH")"
while [ $((SECONDS - PD_R)) -lt 12 ]; do sleep 0.5; done
LH_C="$(pd_down_within "$LH_RESOLVER" 30) $(pd_down_within "$LH_SLEEP" 30) $(pd_down_within "$LH_WATCH" 30)"
LA_C="$(pd_down_within "$LA_SLEEP" 30) $(pd_down_within "$LA_WATCH" 30)"
PD_LTOOK=$((SECONDS - PD_L0))
{ [ "$LH_RC" = 0 ] && [ -n "$LH_WORKER" ] && [ -n "$LH_RESOLVER" ] && [ -n "$LH_SLEEP" ] && [ -n "$LH_WATCH" ] \
  && [ "$LH_GROUPS" = "$LH_RESOLVER/$LH_WATCH" ] && [ "$LH_A" = "down up up up" ] && [ "$LH_C" = "down down down" ] \
  && [ ! -e "$PD/lineage-hung/answer" ] && [ ! -e "$(linked_marker "$WT" "$LH_CLI")" ]; } \
  && check "L72 a deadline during a lineage read stops the worker's group but neither the resolver nor its watchdog, each the leader of a process group of its own, and the watchdog still stops a hung resolver at the lineage budget and then exits, with no lineage answer cached (both lineage cases ${PD_LTOOK}s)" PASS \
  || check "L72 deadline during a hung lineage read (rc=$LH_RC groups=$LH_GROUPS want $LH_RESOLVER/$LH_WATCH after-deadline='$LH_A' after-budget='$LH_C' answered=$([ -e "$PD/lineage-hung/answer" ] && echo yes || echo no))" FAIL
{ [ "$LA_RC" = 0 ] && [ -n "$LA_WORKER" ] && [ -n "$LA_RESOLVER" ] && [ -n "$LA_SLEEP" ] && [ -n "$LA_WATCH" ] \
  && [ "$LA_GROUPS" = "$LA_RESOLVER/$LA_WATCH" ] && [ "$LA_A" = "down up up up" ] && [ "$LA_B" = "down up up" ] \
  && [ "$LA_C" = "down down" ] && [ ! -e "$PD/lineage-answer/answer" ] && [ ! -e "$(linked_marker "$WT" "$LA_CLI")" ]; } \
  && check "L72b a resolver that answers after the deadline exits on its own while its orphaned watchdog sleeps out the lineage budget and then exits, and the answer is cached nowhere" PASS \
  || check "L72b deadline before a lineage answer (rc=$LA_RC groups=$LA_GROUPS want $LA_RESOLVER/$LA_WATCH after-deadline='$LA_A' after-answer='$LA_B' after-budget='$LA_C' answered=$([ -e "$PD/lineage-answer/answer" ] && echo yes || echo no))" FAIL
[ "$LH_C" = "down down down" ] || { pd_reap "$LH_RESOLVER" sleep; pd_reap "$LH_SLEEP" sleep; pd_reap "$LH_WATCH" worker-lineage.sh; }
[ "$LA_C" = "down down" ] || { pd_reap "$LA_RESOLVER" sleep; pd_reap "$LA_SLEEP" sleep; pd_reap "$LA_WATCH" worker-lineage.sh; }

finish
