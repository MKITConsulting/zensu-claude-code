#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HUB_DIR="$PLUGIN_DIR/plugins/session-hub"
MANIFEST="$HUB_DIR/.claude-plugin/plugin.json"
HUB_HOOKS_JSON="$HUB_DIR/hooks/hooks.json"
HUB_TRAIL="$HUB_DIR/skills/session-trail/scripts/trail.mjs"
HUB_SKILL="$HUB_DIR/skills/session-trail/SKILL.md"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
MARKETPLACE="$PLUGIN_DIR/.claude-plugin/marketplace.json"
WORK="$(mktemp -d -t session-hub-plugin-XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
report() {
  echo "----"
  echo "test-session-hub-plugin: $PASS PASS / $FAIL FAIL"
}

if ! command -v node >/dev/null 2>&1; then
  check "H0 node is on PATH" FAIL
  report; exit 1
fi
if [ ! -d "$HUB_DIR" ] || [ ! -f "$MANIFEST" ]; then
  check "H0 plugins/session-hub and its manifest exist" FAIL
  report; exit 1
fi

ALLOWED='.claude-plugin/plugin.json
CHANGELOG.md
LICENSE
README.md
cliff.toml
hooks/hooks.json
hooks/lib/claude-path-v1.js
hooks/lib/desktop-store-read-v1.js
hooks/lib/git-environment-v1.js
hooks/lib/session-hub-receipt-v1.mjs
hooks/lib/worktree-keep-v1.js
hooks/usage-feed-contract.json
hooks/usage-feed.ts
skills/session-trail/SKILL.md
skills/session-trail/handover-contract.json
skills/session-trail/references/archive.md
skills/session-trail/references/commands.md
skills/session-trail/references/disclosure.md
skills/session-trail/references/gotchas.md
skills/session-trail/references/handoff.md
skills/session-trail/references/limits.md
skills/session-trail/references/takeover.md
skills/session-trail/scripts/linked-sessions-v1.mjs
skills/session-trail/scripts/session-lineage-v1.mjs
skills/session-trail/scripts/trail.mjs'

if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$PLUGIN_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  LISTED="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$PLUGIN_DIR" ls-files --cached --others --exclude-standard -- plugins/session-hub \
    | sed 's|^plugins/session-hub/||' | LC_ALL=C sort -u)"
else
  LISTED="$(cd "$HUB_DIR" && find . -type f | sed 's|^\./||' | LC_ALL=C sort -u)"
fi
WANT="$(printf '%s\n' "$ALLOWED" | LC_ALL=C sort -u)"
if [ "$LISTED" = "$WANT" ]; then
  check "H1 plugins/session-hub holds exactly the allowlisted files: the manifest, the license, the hooks, the vendored libraries, the session-trail skill and its docs" PASS
else
  EXTRA="$(LC_ALL=C comm -13 <(printf '%s\n' "$WANT") <(printf '%s\n' "$LISTED") | tr '\n' ' ')"
  MISSING="$(LC_ALL=C comm -23 <(printf '%s\n' "$WANT") <(printf '%s\n' "$LISTED") | tr '\n' ' ')"
  check "H1 the companion tree differs from the allowlist (extra: ${EXTRA:-none}; missing: ${MISSING:-none})" FAIL
fi

MANIFEST_BAD="$(node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const bad = [];
  const keys = ["name", "version", "displayName", "description", "author", "homepage", "repository", "license", "keywords", "skills"];
  if (JSON.stringify(Object.keys(m)) !== JSON.stringify(keys)) bad.push("keys=" + Object.keys(m).join(","));
  if (m.name !== "session-hub") bad.push("name");
  if (m.displayName !== "Zensu Session Hub") bad.push("displayName");
  if (m.license !== "FSL-1.1-Apache-2.0") bad.push("license");
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(m.version || "")) bad.push("version");
  if (JSON.stringify(m.skills) !== JSON.stringify(["./skills/session-trail"])) bad.push("skills");
  if (!String(m.description || "").includes("/session-hub:session-trail")) bad.push("description");
  process.stdout.write(bad.join(" "));
' "$MANIFEST" 2>&1)"
[ -z "$MANIFEST_BAD" ] \
  && check "H2 the manifest names session-hub, Zensu Session Hub, FSL-1.1-Apache-2.0, a semver version and only the session-trail skill, with no agents, commands, MCP servers or hooks key" PASS \
  || check "H2 the companion manifest: $MANIFEST_BAD" FAIL

ENTRY_VERSION="$(node -e '
  const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const hits = (doc.plugins || []).filter((p) => p && p.name === "session-hub");
  process.stdout.write(hits.length === 1 ? String(hits[0].version) : "entries=" + hits.length);
' "$MARKETPLACE" 2>/dev/null)"
MANIFEST_VERSION="$(node -p 'require(process.argv[1]).version' "$MANIFEST" 2>/dev/null)"
[ -n "$MANIFEST_VERSION" ] && [ "$ENTRY_VERSION" = "$MANIFEST_VERSION" ] \
  && check "H2b the marketplace's one session-hub entry carries the manifest's version ($MANIFEST_VERSION)" PASS \
  || check "H2b the marketplace's session-hub entry version is ${ENTRY_VERSION:-<absent>}, the manifest's ${MANIFEST_VERSION:-<absent>}" FAIL

ENTRY_SOURCE="$(node -e '
  const fs = require("fs");
  const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const hits = (doc.plugins || []).filter((p) => p && p.name === "session-hub");
  if (hits.length !== 1) { process.stdout.write("entries=" + hits.length); process.exit(0); }
  const want = {
    source: "git-subdir",
    url: "https://github.com/MKITConsulting/zensu-claude-code.git",
    path: "plugins/session-hub",
    ref: "session-hub--v" + manifest.version,
  };
  process.stdout.write(JSON.stringify(hits[0].source) === JSON.stringify(want) ? "ok" : JSON.stringify(hits[0].source));
' "$MARKETPLACE" "$MANIFEST" 2>&1)"
[ "$ENTRY_SOURCE" = ok ] \
  && check "H2c the session-hub entry installs plugins/session-hub of this repository through git-subdir at the immutable tag session-hub--v<manifest version>, with no sha" PASS \
  || check "H2c the session-hub entry source is ${ENTRY_SOURCE:-<unreadable>}" FAIL

HOOKS_SHAPE="$(node -e '
  const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const want = { hooks: { UserPromptSubmit: [{ hooks: [{ type: "command", command: "node", args: ["${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-hub-receipt-v1.mjs"], timeout: 10 }] }] }, modules: ["./usage-feed.ts"] };
  process.stdout.write(JSON.stringify(doc) === JSON.stringify(want) ? "ok" : JSON.stringify(doc));
' "$HUB_HOOKS_JSON" 2>&1)"
[ "$HOOKS_SHAPE" = "ok" ] \
  && check "H3 hooks.json registers one UserPromptSubmit entry that runs the receipt module in exec form, plus the usage-feed module, and nothing else" PASS \
  || check "H3 the companion hooks.json is $HOOKS_SHAPE" FAIL

VENDORED='LICENSE:LICENSE
hooks/lib/claude-path-v1.js:hooks/lib/claude-path-v1.js
hooks/lib/desktop-store-read-v1.js:hooks/lib/desktop-store-read-v1.js
hooks/lib/git-environment-v1.js:hooks/lib/git-environment-v1.js
hooks/lib/worktree-keep-v1.js:hooks/lib/worktree-keep-v1.js
hooks/usage-feed-contract.json:hooks/usage-feed-contract.json
hooks/usage-feed.ts:hooks/usage-feed.ts
skills/session-trail/scripts/session-lineage-v1.mjs:skills/session-trail/scripts/session-lineage-v1.mjs'
same_bytes() { [ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2"; }
IDENTITY_BAD=""
IDENTITY_N=0
while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  hub="${pair%%:*}"; source="${pair#*:}"
  IDENTITY_N=$((IDENTITY_N + 1))
  same_bytes "$HUB_DIR/$hub" "$PLUGIN_DIR/$source" || IDENTITY_BAD="$IDENTITY_BAD $hub"
done <<EOF
$VENDORED
EOF
[ "$IDENTITY_N" = "8" ] && [ -z "$IDENTITY_BAD" ] \
  && check "H4 the license, the four vendored libraries, the usage-feed module, its contract and the lineage ledger module are byte-identical to their PLM sources ($IDENTITY_N files)" PASS \
  || check "H4 a vendored file differs from its PLM source or the list is incomplete ($IDENTITY_N files):$IDENTITY_BAD" FAIL
cp "$HUB_DIR/hooks/lib/git-environment-v1.js" "$WORK/flipped.js"
node -e '
  const fs = require("fs");
  const b = fs.readFileSync(process.argv[1]);
  b[Math.floor(b.length / 2)] ^= 1;
  fs.writeFileSync(process.argv[1], b);
' "$WORK/flipped.js"
cp "$HUB_DIR/hooks/lib/git-environment-v1.js" "$WORK/copied.js"
if ! same_bytes "$WORK/flipped.js" "$PLUGIN_DIR/hooks/lib/git-environment-v1.js" && same_bytes "$WORK/copied.js" "$PLUGIN_DIR/hooks/lib/git-environment-v1.js"; then
  check "H4-control the identity comparison fails on a one-byte change and passes on an exact copy" PASS
else
  check "H4-control the identity comparison does not tell a one-byte change from an exact copy" FAIL
fi

scan_loads() {
  node -e '
    const fs = require("fs");
    const path = require("path");
    const root = fs.realpathSync(process.argv[1]);
    const files = process.argv.slice(2);
    const bad = [];
    const patterns = [
      /\brequire(?:FromHere)?\(\s*([\x27"])([^\x27"]+)\1\s*\)/g,
      /^(?:import|export)\s[^;]*?\sfrom\s+([\x27"])([^\x27"\n]+)\1/gm,
      /^import\s+([\x27"])([^\x27"\n]+)\1/gm,
      /\bimport\(\s*([\x27"])([^\x27"]+)\1\s*\)/g,
      /\bnew URL\(\s*([\x27"])(\.[^\x27"]*)\1\s*,\s*import\.meta\.url\s*\)/g,
    ];
    const q = String.fromCharCode(39);
    const computed = [
      new RegExp("\\b(?:require|requireFromHere)\\(\\s*(?![" + q + "\"])([^)\\n]{0,80})", "g"),
      new RegExp("\\bimport\\(\\s*(?![" + q + "\"])([^)\\n]{0,80})", "g"),
    ];
    for (const file of files) {
      const text = fs.readFileSync(file, "utf8");
      for (const pattern of computed) {
        for (const m of text.matchAll(pattern)) bad.push(path.relative(root, file) + ":computed:" + m[1].trim());
      }
      for (const pattern of patterns) {
        for (const m of text.matchAll(pattern)) {
          const spec = m[2];
          if (spec.startsWith("node:") || spec === "claude-code") continue;
          if (!spec.startsWith(".")) { bad.push(path.relative(root, file) + ":bare:" + spec); continue; }
          const target = path.resolve(path.dirname(file), spec);
          const rel = path.relative(root, target);
          if (rel === "" || rel.startsWith("..") || path.isAbsolute(rel)) { bad.push(path.relative(root, file) + ":outside:" + spec); continue; }
          if (!fs.existsSync(target)) bad.push(path.relative(root, file) + ":missing:" + spec);
        }
      }
    }
    process.stdout.write(bad.join(" "));
  ' "$@"
}
CODE_FILES="$(cd "$HUB_DIR" && find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' \) | sed "s|^\./|$HUB_DIR/|" | LC_ALL=C sort)"
LOAD_BAD="$(scan_loads "$HUB_DIR" $CODE_FILES 2>&1)"
SHELL_FILES="$(cd "$HUB_DIR" && find . -type f -name '*.sh' | tr '\n' ' ')"
ARGS_BAD="$(node -e '
  const path = require("path");
  const fs = require("fs");
  const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const root = fs.realpathSync(process.argv[2]);
  const bad = [];
  for (const groups of Object.values(doc.hooks || {})) for (const g of groups) for (const h of g.hooks || []) for (const a of h.args || []) {
    const target = path.resolve(root, String(a).replace("${CLAUDE_PLUGIN_ROOT}/", ""));
    if (path.relative(root, target).startsWith("..") || !fs.existsSync(target)) bad.push(a);
  }
  for (const m of doc.modules || []) if (!fs.existsSync(path.resolve(root, "hooks", m))) bad.push(m);
  process.stdout.write(bad.join(" "));
' "$HUB_HOOKS_JSON" "$HUB_DIR" 2>&1)"
[ -n "$CODE_FILES" ] && [ -z "$LOAD_BAD" ] && [ -z "$SHELL_FILES" ] && [ -z "$ARGS_BAD" ] \
  && check "H5 nothing under plugins/session-hub requires, imports or sources a file outside it or by a computed path, and every hook argument and module resolves inside it" PASS \
  || check "H5 the companion reaches outside its tree: loads ${LOAD_BAD:-none}; shell files ${SHELL_FILES:-none}; hook targets ${ARGS_BAD:-none}" FAIL
mkdir -p "$WORK/probe/hooks/lib" "$WORK/probe/skills/x"
printf '%s\n' "import { a } from '../../hooks/lib/inside.mjs';" "const b = require('../../../hooks/lib/outside.js');" "const c = require('fs');" > "$WORK/probe/skills/x/probe.mjs"
printf '%s\n' "export const a = 1;" > "$WORK/probe/hooks/lib/inside.mjs"
PROBE_BAD="$(scan_loads "$WORK/probe" "$WORK/probe/skills/x/probe.mjs" 2>&1)"
case "$PROBE_BAD" in
  *"outside:../../../hooks/lib/outside.js"*"bare:fs"*|*"bare:fs"*"outside:../../../hooks/lib/outside.js"*)
    case "$PROBE_BAD" in *inside.mjs*) check "H5-control the load scan flags a path inside the tree ($PROBE_BAD)" FAIL ;; *) check "H5-control the load scan flags a load outside the tree and a bare specifier, and passes one inside it" PASS ;; esac ;;
  *) check "H5-control the load scan missed a load outside the tree or a bare specifier ($PROBE_BAD)" FAIL ;;
esac
printf '%s\n' "const lib = '../../hooks/lib';" "const d = requireFromHere(path.join(lib, 'inside.mjs'));" "const e = await import(spec);" "const f = require(\`./\${name}.js\`);" > "$WORK/probe/skills/x/computed.mjs"
COMPUTED_BAD="$(scan_loads "$WORK/probe" "$WORK/probe/skills/x/computed.mjs" 2>&1)"
COMPUTED_MISSED=""
for needle in "computed:path.join(lib" "computed:spec" "computed:\`./"; do
  case "$COMPUTED_BAD" in *"$needle"*) ;; *) COMPUTED_MISSED="$COMPUTED_MISSED [$needle]" ;; esac
done
[ -z "$COMPUTED_MISSED" ] \
  && check "H5-control the load scan flags a computed require, a computed import and a template-literal require" PASS \
  || check "H5-control the load scan missed a computed load:$COMPUTED_MISSED ($COMPUTED_BAD)" FAIL

PLM_ONLY_BAD=""
TRAIL_CODE="$(grep -vE '^[[:space:]]*//' "$HUB_TRAIL")"
for needle in 'bash-source-write-parse' 'GATE_READY' 'const GATE' 'function writeAnchor' 'function writesLines' 'function continuationPlan' 'function writeAnchorCaution' "'--anchor'" 'session-control-core-v1.js'; do
  case "$TRAIL_CODE" in *"$needle"*) PLM_ONLY_BAD="$PLM_ONLY_BAD [$needle]" ;; esac
done
ZENSU_COMMAND_HITS="$(grep -rlF '/zensu:session-trail' "$HUB_DIR/.claude-plugin" "$HUB_DIR/hooks" "$HUB_DIR/skills" 2>/dev/null | sed "s|^$HUB_DIR/||" | tr '\n' ' ')"
[ -z "$PLM_ONLY_BAD" ] && [ -z "$ZENSU_COMMAND_HITS" ] \
  && check "H6 the companion's trail.mjs carries no write-anchor feature, no GATE probe and no Session Control core, and no file the companion runs or loads names /zensu:session-trail" PASS \
  || check "H6 PLM-only surface in the companion:${PLM_ONLY_BAD:- none} files naming /zensu:session-trail: ${ZENSU_COMMAND_HITS:-none}" FAIL

keep_key_compare() {
  node -e '
    const fs = require("fs");
    const vm = require("vm");
    const crypto = require("crypto");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
    const start = lines.findIndex((l) => l.startsWith("const KEEP_KEY_DOMAIN = "));
    const fnStart = lines.findIndex((l) => l.startsWith("function keepSessionKey("));
    const end = lines.findIndex((l, i) => i > fnStart && l === "}");
    if (start < 0 || fnStart < 0 || end < 0) { process.stdout.write("not-extracted"); process.exit(0); }
    const source = lines.slice(start, end + 1).join("\n") + "\nkeepSessionKey;";
    const local = vm.runInNewContext(source, { Buffer, crypto });
    const core = require(process.argv[2]);
    const inputs = ["abc", "0f8fad5b-d9cb-469f-a165-70867728950e", " padded ", "unicode-äö", "scv1_" + "a".repeat(64), "sha256:" + "b".repeat(64), "scv1_" + "A".repeat(64), "sha256:short"];
    const outcome = (fn, value) => { try { return "ok:" + fn(value); } catch (error) { return "throws"; } };
    const bad = [];
    for (const value of [...inputs, "", "   ", null, 7]) {
      if (outcome(local, value) !== outcome(core.sessionKey, value)) bad.push(JSON.stringify(value));
    }
    process.stdout.write(bad.length ? bad.join(" ") : "equal");
  ' "$1" "$CORE"
}
KEEP_RESULT="$(keep_key_compare "$HUB_TRAIL" 2>&1)"
[ "$KEEP_RESULT" = "equal" ] \
  && check "H7 the companion's local keep key equals session-control-core-v1.js sessionKey for raw ids, UUIDs, scv1 and sha256 forms, and both refuse an empty or non-string id" PASS \
  || check "H7 the companion's keep key differs from core's sessionKey for: $KEEP_RESULT" FAIL
sed 's|zensu.session-control/v1/session-id|zensu.session-control/v1/session-ix|' "$HUB_TRAIL" > "$WORK/mutated-trail.mjs"
MUTATED_RESULT="$(keep_key_compare "$WORK/mutated-trail.mjs" 2>&1)"
case "$MUTATED_RESULT" in
  equal|not-extracted) check "H7-control a changed hash domain is not detected ($MUTATED_RESULT)" FAIL ;;
  *) check "H7-control a changed hash domain makes the comparison fail" PASS ;;
esac

cliff_split() {
  node -e '
    const fs = require("fs");
    const [rootFile, hubFile] = process.argv.slice(1);
    const lines = (file) => {
      let inBody = false;
      return fs.readFileSync(file, "utf8").split("\n").filter((l) => {
        const keep = inBody || !l.startsWith("#");
        if ((l.split("\"\"\"").length - 1) % 2 === 1) inBody = !inBody;
        return keep;
      });
    };
    const root = lines(rootFile);
    const hub = lines(hubFile);
    const bad = [];
    const one = (list, line, label) => { if (list.filter((l) => l === line).length !== 1) bad.push(label); };
    one(root, "tag_pattern = '"'"'^v[0-9]+\\.[0-9]+\\.[0-9]+$'"'"'", "root-tag-pattern");
    one(root, "exclude_paths = [\"plugins/session-hub/**\"]", "root-exclude-paths");
    one(hub, "tag_pattern = '"'"'^session-hub--v[0-9]+\\.[0-9]+\\.[0-9]+$'"'"'", "hub-tag-pattern");
    one(hub, "include_paths = [\"plugins/session-hub/**\"]", "hub-include-paths");
    if (root.some((l) => l.startsWith("include_paths"))) bad.push("root-include-paths");
    if (hub.some((l) => l.startsWith("exclude_paths"))) bad.push("hub-exclude-paths");
    const header = (list) => list.filter((l) => l.startsWith("## [")).length;
    if (header(root) !== 1 || header(hub) !== 1) bad.push("body-header");
    const shared = (list) => list
      .filter((l) => !/^(tag_pattern|exclude_paths|include_paths) = /.test(l))
      .map((l) => l.replace("trim_start_matches(pat=\"session-hub--v\")", "trim_start_matches(pat=\"v\")"))
      .join("\n").trim();
    if (shared(root) !== shared(hub)) bad.push("body-or-parsers-differ");
    process.stdout.write(bad.join(" "));
  ' "$1" "$2" 2>&1
}
CLIFF_BAD="$(cliff_split "$PLUGIN_DIR/cliff.toml" "$HUB_DIR/cliff.toml")"
[ -z "$CLIFF_BAD" ] \
  && check "H9 cliff.toml leaves plugins/session-hub out of PLM's changelog on v* tags, and the companion's cliff.toml lists only commits that touch it on session-hub--v* tags, with the same body, its version header included, and the same parsers" PASS \
  || check "H9 the changelog path filters disagree: $CLIFF_BAD" FAIL
CLIFF_PROBE="$(mktemp -d -t hub-cliff-XXXXXX)"
grep -v '^include_paths = ' "$HUB_DIR/cliff.toml" > "$CLIFF_PROBE/hub.toml"
case "$(cliff_split "$PLUGIN_DIR/cliff.toml" "$CLIFF_PROBE/hub.toml")" in
  (*hub-include-paths*) check "H9-control a companion config without its path filter fails the comparison" PASS ;;
  (*) check "H9-control a companion config without its path filter passes the comparison" FAIL ;;
esac
sed 's/ | trim_start_matches(pat="session-hub--v")//' "$HUB_DIR/cliff.toml" > "$CLIFF_PROBE/hub-header.toml"
case "$(cliff_split "$PLUGIN_DIR/cliff.toml" "$CLIFF_PROBE/hub-header.toml")" in
  (*body-or-parsers-differ*) check "H9-header-control a companion version header without its tag-prefix trim fails the comparison" PASS ;;
  (*) check "H9-header-control a companion version header without its tag-prefix trim passes the comparison" FAIL ;;
esac
rm -rf "$CLIFF_PROBE"

REL_WF="$PLUGIN_DIR/.github/workflows/release-session-hub.yml"
PLM_WF="$PLUGIN_DIR/.github/workflows/release.yml"
CI_WF="$PLUGIN_DIR/.github/workflows/ci.yml"
GATE="$PLUGIN_DIR/.github/scripts/session-hub-release-gate.sh"
INSTALL_PROBE="$PLUGIN_DIR/.github/scripts/session-hub-install-probe.sh"
ORDER_SCRIPT="$PLUGIN_DIR/.github/scripts/session-hub-release-order.sh"
HUB_README="$HUB_DIR/README.md"
tag_discipline() {
  node -e '
    const fs = require("fs");
    const [rel, plm] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
    const q = String.fromCharCode(39);
    const bad = [];
    const lines = rel.split("\n").map((l) => l.trim());
    const tagLines = lines.filter((l) => /\bclaude\s+plugin\s+tag\b/.test(l) && !/^- name: /.test(l) && !/^echo\s/.test(l));
    if (tagLines.length !== 1 || tagLines[0] !== "claude plugin tag plugins/session-hub" || /\bclaude\s+plugin\s+tag\b[^\n]*--push/.test(rel)) bad.push("tag-command");
    if (/\bgit\s+tag\b(?!\s+-l\b)/.test(rel)) bad.push("git-tag");
    const pushes = lines.filter((l) => /\bgit\s+push\b/.test(l));
    const allowedPushes = ["git push -f origin \"$BR\"", "git push origin \"refs/tags/$TAG\""];
    if (pushes.length !== allowedPushes.length || allowedPushes.some((p) => pushes.filter((l) => l === p).length !== 1)) bad.push("other-push");
    if (/\bgit\/(refs|tags)\b/.test(rel)) bad.push("git-data-api");
    for (const m of rel.matchAll(/gh release create[^\n]*/g)) if (!m[0].includes("--verify-tag")) bad.push("release-without-verify-tag");
    const steps = rel.split(/\n(?=      - (?:name|uses): )/);
    const publish = steps.findIndex((s) => s.includes("Reject a publish dispatch outside main"));
    const after = (from, needle) => steps.findIndex((s, i) => i > from && s.includes(needle));
    const verify = after(publish, "tr -d " + q + "[:space:]" + q + " < \"$RUNNER_TEMP/notes.md\"");
    const order = after(publish, "bash .github/scripts/session-hub-release-order.sh");
    const gate = after(publish, "bash .github/scripts/session-hub-release-gate.sh");
    const tag = after(publish, "claude plugin tag plugins/session-hub");
    const recheck = after(tag, "immutable-releases");
    const push = after(publish, "git push origin \"refs/tags/$TAG\"");
    const create = after(publish, "gh release create");
    const ordered = [publish, verify, gate, tag, recheck, push, create];
    if (publish < 0 || ordered.some((v, i) => v < 0 || (i > 0 && v <= ordered[i - 1])) || order !== verify) bad.push("publish-order");
    if (tag >= 0 && /GH_TOKEN|secrets\./.test(steps[tag])) bad.push("tag-token");
    if (create >= 0 && steps[create].split("commits/$TAG").length - 1 < 2) bad.push("no-relock-check");
    const hub = "chore(release): bump session-hub to";
    const plmPrefix = "chore(release): bump version to";
    if (!rel.includes("startsWith(github.event.head_commit.message, " + q + hub + q + ")")) bad.push("publish-trigger");
    if (!rel.includes("git commit -m \"" + hub + " $VER\"")) bad.push("prepare-subject");
    if (!plm.includes(plmPrefix) || hub.startsWith(plmPrefix) || plmPrefix.startsWith(hub)) bad.push("prefix-overlap");
    process.stdout.write(bad.join(" "));
  ' "$1" "$PLM_WF" 2>&1
}
mutated_release() {
  node -e '
    const fs = require("fs");
    const [src, mode, out] = process.argv.slice(1);
    let t = fs.readFileSync(src, "utf8");
    const swap = (a, b) => { if (!t.includes(a)) throw new Error("anchor missing: " + a); t = t.split(a).join(b); };
    if (mode === "hand-push") t += "          git push --tags origin\n";
    if (mode === "token") swap("          TAG: ${{ steps.target.outputs.tag }}\n          CLAUDE_CONFIG_DIR:", "          TAG: ${{ steps.target.outputs.tag }}\n          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n          CLAUDE_CONFIG_DIR:");
    if (mode === "push-flag") swap("          claude plugin tag plugins/session-hub\n", "          claude plugin tag plugins/session-hub --push\n");
    if (mode === "no-recheck") {
      const from = t.indexOf("      - name: Re-check repository Immutable Releases before the tag goes out\n");
      const to = t.indexOf("      - name: Push the tag\n");
      if (from < 0 || to < from) throw new Error("re-check step missing");
      t = t.slice(0, from) + t.slice(to);
    }
    if (mode === "no-cliff-pin") swap("          version: v2.13.1\n          config: plugins/session-hub/cliff.toml\n", "          config: plugins/session-hub/cliff.toml\n");
    fs.writeFileSync(out, t);
  ' "$REL_WF" "$1" "$2" 2>&1
}
TAG_BAD="$(tag_discipline "$REL_WF")"
[ -z "$TAG_BAD" ] \
  && check "H10 release-session-hub.yml creates the companion tag only through claude plugin tag plugins/session-hub with no token, after the notes, order and gate checks, re-checks Immutable Releases before a step of its own pushes it, re-resolves it once the release locks it, and its release subject never starts PLM's publish" PASS \
  || check "H10 the companion release workflow breaks its tag discipline: $TAG_BAD" FAIL
TAG_PROBE="$WORK/tag-probe"
mkdir -p "$TAG_PROBE"
for spec in "hand-push|other-push|a hand-pushed tag" "token|tag-token|a token in the claude plugin tag step" "push-flag|tag-command|claude plugin tag with --push" "no-recheck|publish-order|a push without the second Immutable Releases check"; do
  mode="${spec%%|*}"; rest="${spec#*|}"; want="${rest%%|*}"; what="${rest#*|}"
  MUTATE_ERR="$(mutated_release "$mode" "$TAG_PROBE/$mode.yml")"
  if [ -n "$MUTATE_ERR" ]; then
    check "H10-control $what could not be built ($MUTATE_ERR)" FAIL
    continue
  fi
  case " $(tag_discipline "$TAG_PROBE/$mode.yml") " in
    (*" $want "*) check "H10-control $what fails the discipline check as $want" PASS ;;
    (*) check "H10-control $what passes the discipline check" FAIL ;;
  esac
done

PIN_FACTS="$(node -e '
  const fs = require("fs");
  const [ci, rel, gate, probe, readme] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
  const job = (text, name) => {
    const lines = text.split("\n");
    const start = lines.indexOf("  " + name + ":");
    if (start < 0) return "";
    let end = lines.findIndex((l, i) => i > start && /^  [A-Za-z0-9_-]+:\s*$/.test(l));
    if (end < 0) end = lines.length;
    return lines.slice(start, end).join("\n") + "\n";
  };
  const installs = (t) => [...t.matchAll(/@anthropic-ai\/claude-code@([^\s"]+)/g)].map((m) => m[1]);
  const semver = /^[0-9]+\.[0-9]+\.[0-9]+$/;
  const readOnly = (t) => /\n    permissions:\n      contents: read\n/.test(t);
  const validate = job(ci, "plugin-validate");
  const floor = job(ci, "plugin-floor");
  const bad = [];
  const pins = { validate: installs(validate), release: installs(rel), gate: [...gate.matchAll(/^CLAUDE_CODE_VERSION="([^"]+)"$/gm)].map((m) => m[1]) };
  const pin = [...new Set(Object.values(pins).flat())];
  if (Object.values(pins).some((v) => v.length === 0) || pin.length !== 1 || !semver.test(pin[0])) bad.push("pins=" + JSON.stringify(pins));
  if (pins.release.length !== 2) bad.push("release-installs=" + pins.release.length);
  if (!validate.includes("run: bash .github/scripts/session-hub-release-gate.sh\n")) bad.push("validate-runs-no-gate");
  if (!readOnly(validate)) bad.push("validate-permissions");
  if (rel.split("bash .github/scripts/session-hub-release-gate.sh").length - 1 !== 2) bad.push("release-gate-runs");
  if (!gate.includes("bash .github/scripts/session-hub-install-probe.sh \"$CLAUDE_CODE_VERSION\"")) bad.push("gate-runs-no-probe");
  if (!probe.includes("\"$WANT (Claude Code)\"")) bad.push("probe-version-check");
  const floorPin = installs(floor);
  if (floorPin.length !== 1 || !semver.test(floorPin[0])) bad.push("floor=" + floorPin.join(","));
  else {
    const f = floorPin[0];
    const older = (a, b) => { const x = a.split(".").map(Number); const y = b.split(".").map(Number); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i]; return false; };
    if (!floor.includes("run: bash .github/scripts/session-hub-install-probe.sh " + f + "\n")) bad.push("floor-probe");
    if (!readOnly(floor)) bad.push("floor-permissions");
    if (pin.length === 1 && !older(f, pin[0])) bad.push("floor-not-older");
    if (!readme.includes("Claude Code " + f + " or newer")) bad.push("readme-floor");
    if (pin.length === 1 && !readme.includes("tested with Claude Code " + f + " and " + pin[0])) bad.push("readme-tested");
  }
  process.stdout.write(bad.length ? bad.join(" ") : "ok " + pin[0] + " floor " + floorPin[0]);
' "$CI_WF" "$REL_WF" "$GATE" "$INSTALL_PROBE" "$HUB_README" 2>&1)"
case "$PIN_FACTS" in
  ("ok "*) check "H11 the CI gate job, the companion release workflow and its gate pin one exact Claude Code, the floor job probes an older one, both jobs read only, and the README names both (${PIN_FACTS#ok })" PASS ;;
  (*) check "H11 the Claude Code pins disagree, float or are not run: $PIN_FACTS" FAIL ;;
esac

COPY="$WORK/copy/session-hub"
mkdir -p "$WORK/copy" "$WORK/copy-home" "$WORK/copy-config"
cp -R "$HUB_DIR" "$COPY"
COPY_TOKEN="$(node -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))')"
COPY_SESSION="$(node -e 'process.stdout.write(require("crypto").randomUUID())')"
COPY_PAYLOAD="$(node -e '
  const [session, token, cwd] = process.argv.slice(1);
  process.stdout.write(JSON.stringify({ session_id: session, cwd, hook_event_name: "UserPromptSubmit", prompt: "/session-hub:session-trail takeover " + session + " --all --receipt " + token }));
' "$COPY_SESSION" "$COPY_TOKEN" "$WORK/copy-home")"
COPY_OUT="$(printf '%s' "$COPY_PAYLOAD" | env HOME="$WORK/copy-home" USERPROFILE="$WORK/copy-home" CLAUDE_CONFIG_DIR="$WORK/copy-config" CLAUDE_PLUGIN_ROOT="$COPY" node "$COPY/hooks/lib/session-hub-receipt-v1.mjs" 2>&1)"; COPY_RC=$?
COPY_LIST_RC=0
env HOME="$WORK/copy-home" USERPROFILE="$WORK/copy-home" CLAUDE_CONFIG_DIR="$WORK/copy-config" ZENSU_CCD_STORE="$WORK/copy-home/no-store" \
  node "$COPY/skills/session-trail/scripts/trail.mjs" list --json > "$WORK/copy-list.json" 2> "$WORK/copy-list.err" || COPY_LIST_RC=$?
COPY_LIST_JSON="$(node -e 'try { JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write("ok"); } catch (_) { process.stdout.write("bad"); }' "$WORK/copy-list.json")"
if [ "$COPY_RC" -eq 0 ] && [ -z "$COPY_OUT" ] && [ -f "$WORK/copy-config/zensu/session-hub/v1/receipts/$COPY_TOKEN.json" ] \
  && [ "$COPY_LIST_RC" -eq 0 ] && [ "$COPY_LIST_JSON" = ok ]; then
  check "H12 a copy of plugins/session-hub outside this repository lands a receipt for the takeover command and runs trail.mjs list --json" PASS
else
  check "H12 a copy of plugins/session-hub outside this repository does not run on its own (receipt rc=$COPY_RC out=${COPY_OUT:0:120}; list rc=$COPY_LIST_RC json=$COPY_LIST_JSON: $(head -c 200 "$WORK/copy-list.err"))" FAIL
fi

PLM_LINKED="$PLUGIN_DIR/skills/session-trail/scripts/linked-sessions-v1.mjs"
HUB_LINKED="$HUB_DIR/skills/session-trail/scripts/linked-sessions-v1.mjs"
linked_equal() {
  node -e '
    const fs = require("fs");
    const [plm, hub] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
    const named = (t) => t.split("/session-hub:session-trail").join("/zensu:session-trail").split("session-hub:session-trail").join("zensu:session-trail").split("Zensu Session Hub plugin").join("Zensu plugin");
    process.stdout.write(hub !== plm && named(hub) === plm ? "equal" : hub === plm ? "unrenamed" : "differ");
  ' "$1" "$2" 2>&1
}
LINKED_RESULT="$(linked_equal "$PLM_LINKED" "$HUB_LINKED")"
[ "$LINKED_RESULT" = equal ] \
  && check "H13 the companion's linked-sessions-v1.mjs equals PLM's frozen copy except for the command and plugin names" PASS \
  || check "H13 the two linked-sessions-v1.mjs copies drifted apart beyond the names ($LINKED_RESULT)" FAIL
node -e '
  const fs = require("fs");
  const t = fs.readFileSync(process.argv[1], "utf8");
  const i = t.indexOf("const ");
  fs.writeFileSync(process.argv[2], i < 0 ? t + "\n" : t.slice(0, i) + "let " + t.slice(i + 6));
' "$HUB_LINKED" "$WORK/linked-drift.mjs"
[ "$(linked_equal "$PLM_LINKED" "$WORK/linked-drift.mjs")" = differ ] \
  && check "H13-control a one-word change to the companion's copy fails the comparison" PASS \
  || check "H13-control a one-word change to the companion's copy passes the comparison" FAIL

order_wiring() {
  node -e '
    const fs = require("fs");
    const [rel, plm] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
    const bad = [];
    const run = "bash .github/scripts/session-hub-release-order.sh";
    if (rel.split(run).length - 1 !== 2) bad.push("order-runs");
    const first = rel.indexOf(run);
    const bump = rel.indexOf("node .github/scripts/bump-marketplace-entry.js");
    if (first < 0 || bump < 0 || first > bump) bad.push("order-after-bump");
    for (const [name, t] of [["release-session-hub", rel], ["release", plm]]) {
      const blocks = [...t.matchAll(/uses: orhun\/git-cliff-action@[^\n]*\n((?: {8,}[^\n]*\n)+)/g)].map((m) => m[1]);
      if (blocks.length !== 1 || !blocks[0].includes("          version: v2.13.1\n")) bad.push(name + "-cliff-version");
    }
    process.stdout.write(bad.join(" "));
  ' "$1" "$PLM_WF" 2>&1
}
ORDER_WIRING="$(order_wiring "$REL_WF")"
[ -z "$ORDER_WIRING" ] \
  && check "H14 both companion release jobs run the release-order script, prepare before its bump, and both release workflows pin git-cliff v2.13.1" PASS \
  || check "H14 the release order or the git-cliff pin is not wired: $ORDER_WIRING" FAIL
MUTATE_ERR="$(mutated_release no-cliff-pin "$TAG_PROBE/no-cliff-pin.yml")"
case " $MUTATE_ERR $(order_wiring "$TAG_PROBE/no-cliff-pin.yml") " in
  (*" release-session-hub-cliff-version "*) check "H14-control a git-cliff step without its version pin fails the wiring check" PASS ;;
  (*) check "H14-control a git-cliff step without its version pin passes the wiring check" FAIL ;;
esac

ORDER_REPO="$WORK/order-repo"
mkdir -p "$ORDER_REPO/hooks" "$ORDER_REPO/plugins/session-hub/hooks"
order_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$ORDER_REPO" \
    -c user.name=order -c user.email=order@localhost -c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
order_run() {
  (cd "$ORDER_REPO" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR bash "$ORDER_SCRIPT" >/dev/null 2>&1)
  printf '%s' "$?"
}
order_git init -q
printf '%s\n' 'export default {};' > "$ORDER_REPO/hooks/usage-feed.ts"
printf '%s\n' '{"schemaVersion":1}' > "$ORDER_REPO/hooks/usage-feed-contract.json"
cp "$ORDER_REPO/hooks/usage-feed.ts" "$ORDER_REPO/hooks/usage-feed-contract.json" "$ORDER_REPO/plugins/session-hub/hooks/"
order_git add -A && order_git commit -q -m "feed"
NO_TAG="$(order_run)"
order_git tag v0.9.0
NO_NOTICE="$(order_run)"
printf '%s\n' '#!/bin/bash' > "$ORDER_REPO/hooks/user-prompt-session-hub-takeover-notice.sh"
order_git add -A && order_git commit -q -m "notice"
STALE_TAG="$(order_run)"
order_git tag v0.10.0
READY="$(order_run)"
order_git tag v1.0.0-rc.1 HEAD~1
PRERELEASE="$(order_run)"
printf '%s\n' 'export default { changed: true };' > "$ORDER_REPO/plugins/session-hub/hooks/usage-feed.ts"
FEED_DRIFT="$(order_run)"
cp "$ORDER_REPO/hooks/usage-feed.ts" "$ORDER_REPO/plugins/session-hub/hooks/usage-feed.ts"
printf '%s\n' '{"schemaVersion":2}' > "$ORDER_REPO/plugins/session-hub/hooks/usage-feed-contract.json"
CONTRACT_DRIFT="$(order_run)"
ORDER_RESULT="$NO_TAG $NO_NOTICE $STALE_TAG $READY $PRERELEASE $FEED_DRIFT $CONTRACT_DRIFT"
[ "$ORDER_RESULT" = "1 1 1 0 0 1 1" ] \
  && check "H14 the release-order script refuses without a Zensu tag, while the newest one by version lacks the takeover notice, and while the companion's usage feed or its contract differs from it, ignores a pre-release tag, and passes once Zensu released both" PASS \
  || check "H14 the release-order script decided no-tag, no-notice, stale-tag, ready, pre-release, feed-drift, contract-drift as $ORDER_RESULT, want 1 1 1 0 0 1 1" FAIL

report
[ "$FAIL" -eq 0 ]
