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
INSTALL_PROBE="$PLUGIN_DIR/.github/scripts/session-hub-install-probe.sh"
ORDER_SCRIPT="$PLUGIN_DIR/.github/scripts/session-hub-release-order.sh"
HUB_README="$HUB_DIR/README.md"
release_discipline() {
  node -e '
    const fs = require("fs");
    const [rel, plm] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
    const q = String.fromCharCode(39);
    const bad = [];
    const job = (name) => {
      const lines = rel.split("\n");
      const start = lines.indexOf("  " + name + ":");
      if (start < 0) return "";
      let end = lines.findIndex((l, i) => i > start && /^  [A-Za-z0-9_-]+:\s*$/.test(l));
      if (end < 0) end = lines.length;
      return lines.slice(start, end).join("\n") + "\n";
    };
    const steps = (text) => text.split(/\n(?=      - (?:name|uses): )/);
    const at = (list, needle) => list.findIndex((s) => s.includes(needle));
    const lines = rel.split("\n").map((l) => l.trim());
    const tagLines = lines.filter((l) => /\bclaude\s+plugin\s+tag\b/.test(l) && !/^- name: /.test(l) && !/^echo\s/.test(l));
    if (tagLines.length !== 1 || tagLines[0] !== "claude plugin tag plugins/session-hub" || /\bclaude\s+plugin\s+tag\b[^\n]*--push/.test(rel)) bad.push("tag-command");
    if (/\bgit\s+tag\b(?!\s+-l\b)/.test(rel)) bad.push("git-tag");
    const pushes = lines.filter((l) => /\bgit\b.*\bpush\b/.test(l));
    const allowedPushes = ["git -c core.hooksPath=/dev/null push origin \"refs/heads/$BR:refs/heads/$BR\"", "git -c core.hooksPath=/dev/null push origin \"refs/tags/$TAG\""];
    if (pushes.length !== allowedPushes.length || allowedPushes.some((p) => pushes.filter((l) => l === p).length !== 1)) bad.push("other-push");
    if (!job("prepare-push").includes(allowedPushes[0]) || !job("publish").includes(allowedPushes[1])) bad.push("push-job");
    if (/\bgit\/(refs|tags)\b/.test(rel)) bad.push("git-data-api");
    for (const m of rel.matchAll(/gh release create[^\n]*/g)) {
      if (!m[0].includes("--verify-tag")) bad.push("release-without-verify-tag");
      if (!m[0].includes("--latest=false")) bad.push("release-marked-latest");
    }
    const token = /GH_TOKEN|GITHUB_TOKEN|github\.token|secrets\./;
    const head = rel.indexOf("\njobs:\n");
    if (head < 0 || token.test(rel.slice(0, head))) bad.push("workflow-token");
    for (const name of ["prepare-commit", "publish-gate"]) {
      const t = job(name);
      if (!t) { bad.push("missing-" + name); continue; }
      if (!/\n    permissions:\n      contents: read\n/.test(t)) bad.push(name + "-permissions");
      if (token.test(t)) bad.push(name + "-token");
    }
    for (const name of ["prepare-push", "publish"]) {
      const t = job(name);
      if (!t) { bad.push("missing-" + name); continue; }
      if (!/\n    permissions:\n      contents: write\n/.test(t)) bad.push(name + "-permissions");
      const runs = t.split("\n").filter((l) => !/^\s*(?:- )?name: /.test(l) && !/^\s*echo /.test(l)).join("\n");
      if (/\bnpm\b|\bnpx\b|git-cliff|setup-node|session-hub-install-claude-code\.sh|session-hub-release-gate\.sh|session-hub-install-probe\.sh/.test(runs) || /(^|[\s;&|(])claude\s/m.test(runs)) bad.push(name + "-runs-tooling");
      for (const m of t.matchAll(/^\s*- uses: (\S+)/gm)) if (!/^actions\/(checkout|download-artifact)@[0-9a-f]{40}$/.test(m[1])) bad.push(name + "-uses-" + m[1].split("@")[0]);
    }
    const checkouts = [...rel.matchAll(/- uses: actions\/checkout@[^\n]*\n((?: {8,}[^\n]*\n)*)/g)];
    if (checkouts.length !== 4 || checkouts.some((m) => !m[1].includes("persist-credentials: false"))) bad.push("checkout-credentials");
    if (!/\n    needs: prepare-commit\n/.test(job("prepare-push"))) bad.push("prepare-push-needs");
    if (!/\n    needs: publish-gate\n/.test(job("publish"))) bad.push("publish-needs");
    const gs = steps(job("publish-gate"));
    const guard = at(gs, "if [ \"$DRY_RUN\" = true ]");
    const resolveCall = "bash .github/scripts/session-hub-release-target.sh \"$RUNNER_TEMP/target.env\" \"$RUNNER_TEMP/release/notes.md\"";
    const target = at(gs, resolveCall);
    const order = at(gs, "bash .github/scripts/session-hub-release-order.sh");
    const gate = at(gs, "bash .github/scripts/session-hub-release-gate.sh");
    const tag = at(gs, "claude plugin tag plugins/session-hub");
    if ([guard, target, gate, tag].some((v) => v < 0) || !(guard < target && target < gate && gate < tag) || order !== target) bad.push("publish-gate-order");
    if (target >= 0) {
      const s = gs[target];
      const checkout = s.indexOf("git checkout --quiet --detach \"$TARGET\"");
      if (checkout < 0 || !(s.indexOf(resolveCall) < checkout && checkout < s.indexOf("bash .github/scripts/session-hub-release-order.sh"))) bad.push("target-not-checked-out");
    }
    if (guard >= 0 && !gs[guard].includes("if [ \"$SUPERSEDE\" = true ]; then")) bad.push("supersede-publish");
    const pc = job("prepare-commit");
    if (!pc.includes("SUPERSEDE: ${{ inputs.supersede }}") || !pc.includes("bash .github/scripts/session-hub-release-version.sh \"$VERSION_TYPE\" \"$SUPERSEDE\" \"$RUNNER_TEMP/version.env\"") || !pc.includes("bash .github/scripts/session-hub-release-supersede.sh \"$SUPERSEDED\" \"$VER\" plugins/session-hub/CHANGELOG.md")) bad.push("supersede-wiring");
    const ps = steps(job("publish"));
    const verify = at(ps, "git fetch --no-tags \"$BUNDLE\" \"refs/tags/$TAG:refs/tags/$TAG\"");
    const immutable = at(ps, "bash .github/scripts/session-hub-require-immutable-releases.sh");
    const push = at(ps, "push origin \"refs/tags/$TAG\"");
    const create = at(ps, "gh release create");
    if ([verify, immutable, push, create].some((v) => v < 0) || !(verify < immutable && immutable < push && push < create)) bad.push("publish-order");
    if (create >= 0 && ps[create].split("commits/$TAG").length - 1 < 2) bad.push("no-relock-check");
    if (verify >= 0 && !ps[verify].includes("test \"$(git rev-parse \"refs/tags/$TAG\")\" = \"$TAG_OBJECT\"")) bad.push("tag-object-unchecked");
    if (verify >= 0) {
      const v = ps[verify];
      const shown = v.indexOf("git show \"$TARGET:plugins/session-hub/CHANGELOG.md\" > \"$RUNNER_TEMP/CHANGELOG.target.md\"");
      const rebuilt = v.indexOf("bash .github/scripts/session-hub-release-notes.sh \"$VER\" \"$RUNNER_TEMP/CHANGELOG.target.md\" \"$RUNNER_TEMP/notes.md\"");
      const compared = v.indexOf("cmp -s \"$RUNNER_TEMP/notes.md\" \"$RUNNER_TEMP/release/notes.md\" || {");
      if (shown < 0 || rebuilt < shown || compared < rebuilt) bad.push("notes-unverified");
      if (!v.includes("test \"$(git cat-file tag \"refs/tags/$TAG\" | sed " + q + "1,/^$/d" + q + ")\" = \"session-hub $VER\"")) bad.push("tag-message-unchecked");
    }
    if (create >= 0 && (!ps[create].includes("NOTES=\"$RUNNER_TEMP/notes.md\"") || ps[create].includes("release/notes.md"))) bad.push("notes-from-artifact");
    const pp = steps(job("prepare-push"));
    const ppVerify = at(pp, "git fetch --no-tags \"$BUNDLE\" \"refs/heads/$BR:refs/heads/$BR\"");
    const ppPush = at(pp, "push origin \"refs/heads/$BR:refs/heads/$BR\"");
    if (ppVerify < 0 || ppPush < 0 || ppVerify > ppPush) bad.push("prepare-push-order");
    if (ppPush >= 0) {
      const s = pp[ppPush];
      const ls = s.indexOf("git ls-remote --exit-code --heads origin");
      if (ls < 0 || ls > s.indexOf("push origin")) bad.push("prepare-push-overwrites");
    }
    const hub = "chore(release): bump session-hub to";
    const plmPrefix = "chore(release): bump version to";
    if (!rel.includes("startsWith(github.event.head_commit.message, " + q + hub + q + ")")) bad.push("publish-trigger");
    if (rel.split("git commit -m \"" + hub + " $VER\"").length - 1 !== 2) bad.push("prepare-subject");
    if (!plm.includes(plmPrefix) || hub.startsWith(plmPrefix) || plmPrefix.startsWith(hub)) bad.push("prefix-overlap");
    process.stdout.write(bad.join(" "));
  ' "$1" "$PLM_WF" 2>&1
}
mutated_release() {
  node -e '
    const fs = require("fs");
    const [src, mode, out] = process.argv.slice(1);
    let t = fs.readFileSync(src, "utf8");
    const q = String.fromCharCode(39);
    const swap = (a, b) => { if (!t.includes(a)) throw new Error("anchor missing: " + a); t = t.split(a).join(b); };
    const once = (a, b) => { const i = t.indexOf(a); if (i < 0) throw new Error("anchor missing: " + a); t = t.slice(0, i) + b + t.slice(i + a.length); };
    const exchange = (a, b) => { if (!t.includes(a) || !t.includes(b)) throw new Error("anchor missing: " + (t.includes(a) ? b : a)); t = t.split(a).join("\u0000").split(b).join(a).split("\u0000").join(b); };
    const reorder = (first, second, after) => {
      const a = t.indexOf(first); const b = t.indexOf(second); const c = t.indexOf(after);
      if (a < 0 || b < a || c < b) throw new Error("steps missing: " + first);
      t = t.slice(0, a) + t.slice(b, c) + t.slice(a, b) + t.slice(c);
    };
    const tagEnv = "          TARGET: ${{ steps.target.outputs.target }}\n          CLAUDE_CONFIG_DIR:";
    const tagToken = (line) => swap(tagEnv, tagEnv.replace("          CLAUDE_CONFIG_DIR:", "          " + line + "\n          CLAUDE_CONFIG_DIR:"));
    const writeStep = "      - name: Push the tag\n";
    if (mode === "hand-push") t += "          git push --tags origin\n";
    if (mode === "force-push") swap("git -c core.hooksPath=/dev/null push origin \"refs/heads/$BR:refs/heads/$BR\"", "git -c core.hooksPath=/dev/null push -f origin \"refs/heads/$BR:refs/heads/$BR\"");
    if (mode === "gh-token") tagToken("GH_TOKEN: ${{ steps.target.outputs.tag }}");
    if (mode === "github-token-env") tagToken("GITHUB_TOKEN: ${{ steps.target.outputs.tag }}");
    if (mode === "github-dot-token") tagToken("AUTH: ${{ github.token }}");
    if (mode === "secrets-ref") tagToken("AUTH: ${{ secrets.ANY_SECRET }}");
    if (mode === "prepare-token") swap("      - name: Install the pinned Claude Code\n        if: ${{ !inputs.dry_run }}\n", "      - name: Install the pinned Claude Code\n        if: ${{ !inputs.dry_run }}\n        env:\n          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n");
    if (mode === "workflow-env-token") once("\njobs:\n", "\nenv:\n  GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n\njobs:\n");
    if (mode === "write-gate") swap("      contents: read\n    outputs:\n      version: ${{ steps.target.outputs.version }}\n", "      contents: write\n    outputs:\n      version: ${{ steps.target.outputs.version }}\n");
    if (mode === "push-flag") swap("          claude plugin tag plugins/session-hub\n", "          claude plugin tag plugins/session-hub --push\n");
    if (mode === "no-immutable") {
      const from = t.indexOf("      - name: Require repository Immutable Releases before the tag goes out\n");
      const to = t.indexOf(writeStep);
      if (from < 0 || to < from) throw new Error("immutable step missing");
      t = t.slice(0, from) + t.slice(to);
    }
    if (mode === "npm-in-write") swap(writeStep, "      - name: Install a tool\n        run: npm ci\n\n" + writeStep);
    if (mode === "claude-in-write") swap("          git merge-base --is-ancestor \"$TARGET\" \"$GITHUB_SHA\"\n", "          git merge-base --is-ancestor \"$TARGET\" \"$GITHUB_SHA\"\n          claude plugin validate .\n");
    if (mode === "cliff-in-write") swap(writeStep, "      - name: Generate notes\n        run: git-cliff --unreleased\n\n" + writeStep);
    if (mode === "no-persist") once("          persist-credentials: false\n", "");
    if (mode === "latest") swap("--verify-tag --latest=false", "--verify-tag");
    if (mode === "no-dry-run-guard") swap("          if [ \"$DRY_RUN\" = true ]; then\n", "          if false; then\n");
    if (mode === "push-swap") exchange("git -c core.hooksPath=/dev/null push origin \"refs/heads/$BR:refs/heads/$BR\"", "git -c core.hooksPath=/dev/null push origin \"refs/tags/$TAG\"");
    if (mode === "foreign-action") swap(writeStep, "      - uses: actions/cache@0000000000000000000000000000000000000000\n        with:\n          path: x\n          key: x\n\n" + writeStep);
    if (mode === "node-in-write") swap(writeStep, "      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4\n        with:\n          node-version: 22\n\n" + writeStep);
    if (mode === "gate-in-write") swap("      - name: Push the release branch and print the PR link\n", "      - name: Run the gate\n        run: bash .github/scripts/session-hub-release-gate.sh\n\n      - name: Push the release branch and print the PR link\n");
    if (mode === "trigger-prefix") swap("startsWith(github.event.head_commit.message, " + q + "chore(release): bump session-hub to" + q + ")", "startsWith(github.event.head_commit.message, " + q + "chore(release): bump" + q + ")");
    if (mode === "prepare-subject") once("git commit -m \"chore(release): bump session-hub to $VER\"", "git commit -m \"chore(release): release session-hub $VER\"");
    if (mode === "gate-tag-swap") reorder("      - name: Run the companion release gate against the release target\n", "      - name: Create the tag through claude plugin tag\n", "      - name: Upload the release notes and the tag bundle\n");
    if (mode === "push-before-immutable") reorder("      - name: Require repository Immutable Releases before the tag goes out\n", writeStep, "      - name: Publish the GitHub Release and verify it is immutable\n");
    if (mode === "no-notes-compare") once("          cmp -s \"$RUNNER_TEMP/notes.md\" \"$RUNNER_TEMP/release/notes.md\" || {\n", "          true || {\n");
    if (mode === "notes-from-artifact") swap("          NOTES=\"$RUNNER_TEMP/notes.md\"\n", "          NOTES=\"$RUNNER_TEMP/release/notes.md\"\n");
    if (mode === "no-tag-message") once("            test \"$(git cat-file tag \"refs/tags/$TAG\" | sed " + q + "1,/^$/d" + q + ")\" = \"session-hub $VER\"\n", "");
    if (mode === "no-supersede-guard") once("          if [ \"$SUPERSEDE\" = true ]; then\n", "          if false; then\n");
    if (mode === "no-supersede-wiring") once("bash .github/scripts/session-hub-release-supersede.sh", "true");
    if (mode === "no-cliff-pin") swap("          version: v2.13.1\n          config: plugins/session-hub/cliff.toml\n", "          config: plugins/session-hub/cliff.toml\n");
    fs.writeFileSync(out, t);
  ' "$REL_WF" "$1" "$2" 2>&1
}
DISCIPLINE_BAD="$(release_discipline "$REL_WF")"
[ -z "$DISCIPLINE_BAD" ] \
  && check "H10 release-session-hub.yml keeps every write credential away from Claude Code, npm and git-cliff: prepare-commit and publish-gate have read-only permissions, pass no token to any step and build the release commit or the tag, prepare-push and publish run none of them and verify the bundle before they push, publish rebuilds the notes from the changelog at the target, checks the tag message, requires Immutable Releases before the tag goes out and releases with --verify-tag --latest=false, every checkout drops its credentials, supersede is wired into prepare and refused by publish, and the one tag comes from claude plugin tag plugins/session-hub at the commit the release-target script resolves" PASS \
  || check "H10 the companion release workflow breaks its release discipline: $DISCIPLINE_BAD" FAIL
TAG_PROBE="$WORK/tag-probe"
mkdir -p "$TAG_PROBE"
for spec in "hand-push|other-push|a hand-pushed tag" "force-push|other-push|a force-pushed release branch" \
  "gh-token|publish-gate-token|a GH_TOKEN in the tag job" "github-token-env|publish-gate-token|a GITHUB_TOKEN in the tag job" \
  "github-dot-token|publish-gate-token|a github.token in the tag job" "secrets-ref|publish-gate-token|a secrets reference in the tag job" \
  "prepare-token|prepare-commit-token|a token in the job that builds the release commit" "workflow-env-token|workflow-token|a token in the workflow env" \
  "write-gate|publish-gate-permissions|a tag job that may write" "push-flag|tag-command|claude plugin tag with --push" \
  "no-immutable|publish-order|a push without the Immutable Releases check" "npm-in-write|publish-runs-tooling|an npm install in the publish job" \
  "claude-in-write|publish-runs-tooling|a claude call in the publish job" "cliff-in-write|publish-runs-tooling|git-cliff in the publish job" \
  "no-persist|checkout-credentials|a checkout that keeps its credentials" "latest|release-marked-latest|a release marked as the latest" \
  "no-dry-run-guard|publish-gate-order|a publish dispatch that accepts dry_run" \
  "push-swap|push-job|the two pushes swapped between their jobs" "foreign-action|publish-uses-actions/cache|another action in the publish job" \
  "node-in-write|publish-runs-tooling|a Node setup in the publish job" "gate-in-write|prepare-push-runs-tooling|the release gate in the job that pushes the branch" \
  "trigger-prefix|publish-trigger|a push trigger on a shorter subject prefix" "prepare-subject|prepare-subject|one release commit with another subject" \
  "gate-tag-swap|publish-gate-order|a tag created before the gate runs" "push-before-immutable|publish-order|a tag pushed before the Immutable Releases check" \
  "no-notes-compare|notes-unverified|a publish job that does not compare the handed-on notes" "notes-from-artifact|notes-from-artifact|a release whose notes are the handed-on file" \
  "no-tag-message|tag-message-unchecked|a tag whose message is not read" "no-supersede-guard|supersede-publish|a publish dispatch that accepts supersede" \
  "no-supersede-wiring|supersede-wiring|a supersede that never marks the old changelog section"; do
  mode="${spec%%|*}"; rest="${spec#*|}"; want="${rest%%|*}"; what="${rest#*|}"
  MUTATE_ERR="$(mutated_release "$mode" "$TAG_PROBE/$mode.yml")"
  if [ -n "$MUTATE_ERR" ]; then
    check "H10-control $what could not be built ($MUTATE_ERR)" FAIL
    continue
  fi
  case " $(release_discipline "$TAG_PROBE/$mode.yml") " in
    (*" $want "*) check "H10-control $what fails the discipline check as $want" PASS ;;
    (*) check "H10-control $what passes the discipline check" FAIL ;;
  esac
done

pin_facts() {
  node -e '
    const fs = require("fs");
    const path = require("path");
    const root = process.argv[1];
    const read = (f) => fs.readFileSync(path.join(root, f), "utf8");
    const q = String.fromCharCode(39);
    const bad = new Set();
    const semver = /^[0-9]+\.[0-9]+\.[0-9]+$/;
    const tool = (dir) => {
      let m, l;
      try { m = JSON.parse(read(dir + "/package.json")); l = JSON.parse(read(dir + "/package-lock.json")); } catch (_) { bad.add(dir + "-unreadable"); return ""; }
      const deps = m.dependencies || {};
      const pin = deps["@anthropic-ai/claude-code"];
      if (m.private !== true || Object.keys(deps).length !== 1 || typeof pin !== "string" || !semver.test(pin) || m.scripts || m.devDependencies || m.optionalDependencies) bad.add(dir + "-manifest");
      const pk = l.packages || {};
      if (l.lockfileVersion !== 3 || JSON.stringify((pk[""] || {}).dependencies || {}) !== JSON.stringify(deps)) bad.add(dir + "-lock-root");
      if ((pk["node_modules/@anthropic-ai/claude-code"] || {}).version !== pin) bad.add(dir + "-lock-version");
      for (const [k, p] of Object.entries(pk)) if (k && (!/^sha512-[A-Za-z0-9+\/]{86}==$/.test(p.integrity || "") || !String(p.resolved || "").startsWith("https://registry.npmjs.org/@anthropic-ai/claude-code"))) bad.add(dir + "-lock-integrity");
      if (Object.entries(pk).filter(([, p]) => p.hasInstallScript).map(([k]) => k).join(" ") !== "node_modules/@anthropic-ai/claude-code") bad.add(dir + "-install-scripts");
      return semver.test(pin || "") ? pin : "";
    };
    const pin = tool(".github/tools/claude-code");
    const floor = tool(".github/tools/claude-code-floor");
    for (const dir of [".github/workflows", ".github/scripts"]) for (const f of fs.readdirSync(path.join(root, dir)).sort()) {
      if (!fs.statSync(path.join(root, dir, f)).isFile()) continue;
      if (/@anthropic-ai\/claude-code@|\bnpm\s+(?:i|install|add|exec)\b[^\n]*claude-code|\bnpx\b[^\n]*claude-code/.test(read(dir + "/" + f))) bad.add("unlocked-install:" + f);
    }
    const job = (text, name) => {
      const lines = text.split("\n");
      const start = lines.indexOf("  " + name + ":");
      if (start < 0) return "";
      let end = lines.findIndex((l, i) => i > start && /^  [A-Za-z0-9_-]+:\s*$/.test(l));
      if (end < 0) end = lines.length;
      return lines.slice(start, end).join("\n") + "\n";
    };
    const count = (t, s) => t.split(s).length - 1;
    const readOnly = (t) => /\n    permissions:\n      contents: read\n/.test(t);
    const installRun = (dir) => "run: bash .github/scripts/session-hub-install-claude-code.sh " + dir + "\n";
    const ci = read(".github/workflows/ci.yml");
    const rel = read(".github/workflows/release-session-hub.yml");
    const gate = read(".github/scripts/session-hub-release-gate.sh");
    const probe = read(".github/scripts/session-hub-install-probe.sh");
    const install = read(".github/scripts/session-hub-install-claude-code.sh");
    const readme = read("plugins/session-hub/README.md");
    const validate = job(ci, "plugin-validate");
    const floorJob = job(ci, "plugin-floor");
    if (count(validate, installRun(".github/tools/claude-code")) !== 1 || !validate.includes("run: bash .github/scripts/session-hub-release-gate.sh\n") || !readOnly(validate)) bad.add("validate-job");
    if (count(floorJob, installRun(".github/tools/claude-code-floor")) !== 1 || !floorJob.includes("run: bash .github/scripts/session-hub-install-probe.sh .github/tools/claude-code-floor\n") || !readOnly(floorJob)) bad.add("floor-job");
    if (count(ci, "session-hub-install-claude-code.sh") !== 2) bad.add("ci-installs");
    if (count(rel, installRun(".github/tools/claude-code")) !== 2 || count(rel, "session-hub-install-claude-code.sh") !== 2 || rel.includes("claude-code-floor")) bad.add("release-installs");
    if (count(rel, "bash .github/scripts/session-hub-release-gate.sh") !== 2) bad.add("release-gate-runs");
    if (!gate.includes("CLAUDE_CODE_TOOL=\".github/tools/claude-code\"\n") || !gate.includes("bash .github/scripts/session-hub-install-probe.sh \"$CLAUDE_CODE_TOOL\"") || gate.includes("CLAUDE_CODE_VERSION")) bad.add("gate-tool");
    const pinOwner = read(".github/scripts/session-hub-claude-code-pin.sh");
    if (!pinOwner.includes("  (.github/tools/claude-code|.github/tools/claude-code-floor) ;;\n") || !pinOwner.includes("(m.dependencies || {})[\"@anthropic-ai/claude-code\"]")) bad.add("pin-owner");
    const ownsPin = (t) => t.includes(".github/tools/claude-code|") || /dependencies/.test(t);
    if (!install.includes("WANT=\"$(bash \"$REPO_ROOT/.github/scripts/session-hub-claude-code-pin.sh\" \"$TOOL\")\" || {") || ownsPin(install)) bad.add("installer-own-pin");
    if (!probe.includes("WANT=\"$(bash .github/scripts/session-hub-claude-code-pin.sh \"$TOOL\")\" || {") || ownsPin(probe) || !probe.includes("\"$WANT (Claude Code)\"")) bad.add("probe-own-pin");
    const ciAt = install.indexOf("npm ci --ignore-scripts");
    const scriptedAt = install.indexOf("[ \"$SCRIPTED\" != \"node_modules/@anthropic-ai/claude-code\" ]");
    const runAt = install.indexOf("node node_modules/@anthropic-ai/claude-code/install.cjs");
    if (ciAt < 0 || scriptedAt < ciAt || runAt < scriptedAt || !install.includes("\"$WANT (Claude Code)\"")) bad.add("install-script");
    const older = (a, b) => { const x = a.split(".").map(Number); const y = b.split(".").map(Number); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i]; return false; };
    if (pin && floor) {
      if (!older(floor, pin)) bad.add("floor-not-older");
      if (!readme.includes("Claude Code " + floor + " or newer")) bad.add("readme-floor");
      if (!readme.includes("tested with Claude Code " + floor + " and " + pin)) bad.add("readme-tested");
    }
    process.stdout.write(bad.size ? [...bad].join(" ") : "ok " + pin + " floor " + floor);
  ' "$1" 2>&1
}
PIN_FACTS="$(pin_facts "$PLUGIN_DIR")"
case "$PIN_FACTS" in
  ("ok "*) check "H11 every Claude Code install under .github/ runs session-hub-install-claude-code.sh from a committed manifest and lockfile with one exact pin, sha512 integrity, claude-code packages only and one install script, session-hub-claude-code-pin.sh alone holds the tool list and reads that pin for the installer and the probe, the gate names the tool, the floor job probes an older one, both CI jobs read only, and the README names both (${PIN_FACTS#ok })" PASS ;;
  (*) check "H11 the Claude Code installs are not locked, disagree or are not run: $PIN_FACTS" FAIL ;;
esac
PIN_PROBE="$WORK/pin-probe"
for spec in "literal-install|unlocked-install:ci.yml|an npm install of a versioned Claude Code in ci.yml" \
  "second-script|.github/tools/claude-code-install-scripts|a lockfile that gives a second package an install script" \
  "floating-pin|.github/tools/claude-code-manifest|a manifest with a version range" \
  "probe-own-pin|probe-own-pin|a probe that reads the pin itself again"; do
  mode="${spec%%|*}"; rest="${spec#*|}"; want="${rest%%|*}"; what="${rest#*|}"
  mkdir -p "$PIN_PROBE/$mode/.github" "$PIN_PROBE/$mode/plugins/session-hub"
  cp -R "$PLUGIN_DIR/.github/workflows" "$PLUGIN_DIR/.github/scripts" "$PLUGIN_DIR/.github/tools" "$PIN_PROBE/$mode/.github/"
  cp "$HUB_README" "$PIN_PROBE/$mode/plugins/session-hub/README.md"
  MUTATE_ERR="$(node -e '
    const fs = require("fs");
    const [dir, mode] = process.argv.slice(1);
    const q = String.fromCharCode(39);
    const edit = (f, fn) => { const p = dir + "/" + f; const before = fs.readFileSync(p, "utf8"); const after = fn(before); if (after === before) throw new Error("no change: " + f); fs.writeFileSync(p, after); };
    if (mode === "literal-install") edit(".github/workflows/ci.yml", (t) => t + "      - run: npm install -g @anthropic-ai/claude-code@2.1.317\n");
    if (mode === "second-script") edit(".github/tools/claude-code/package-lock.json", (t) => { const l = JSON.parse(t); l.packages["node_modules/@anthropic-ai/claude-code-linux-x64"].hasInstallScript = true; return JSON.stringify(l, null, 2) + "\n"; });
    if (mode === "floating-pin") edit(".github/tools/claude-code/package.json", (t) => t.replace(/("@anthropic-ai\/claude-code": ")([0-9])/, "$1^$2"));
    if (mode === "probe-own-pin") edit(".github/scripts/session-hub-install-probe.sh", (t) => t.split("WANT=\"$(bash .github/scripts/session-hub-claude-code-pin.sh \"$TOOL\")\" || {").join("WANT=\"$(jq -r " + q + ".dependencies[\"@anthropic-ai/claude-code\"]" + q + " \"$TOOL/package.json\")\" || {"));
  ' "$PIN_PROBE/$mode" "$mode" 2>&1)"
  if [ -n "$MUTATE_ERR" ]; then
    check "H11-control $what could not be built ($MUTATE_ERR)" FAIL
    continue
  fi
  case " $(pin_facts "$PIN_PROBE/$mode") " in
    (*" $want "*) check "H11-control $what fails the pin check as $want" PASS ;;
    (*) check "H11-control $what passes the pin check" FAIL ;;
  esac
done

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
  && check "H8 prepare-commit and publish-gate both run the release-order script, prepare-commit before its bump, and both release workflows pin git-cliff v2.13.1" PASS \
  || check "H8 the release order or the git-cliff pin is not wired: $ORDER_WIRING" FAIL
MUTATE_ERR="$(mutated_release no-cliff-pin "$TAG_PROBE/no-cliff-pin.yml")"
case " $MUTATE_ERR $(order_wiring "$TAG_PROBE/no-cliff-pin.yml") " in
  (*" release-session-hub-cliff-version "*) check "H8-control a git-cliff step without its version pin fails the wiring check" PASS ;;
  (*) check "H8-control a git-cliff step without its version pin passes the wiring check" FAIL ;;
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

PROBE_REPO="$WORK/probe-repo"
STUB_BIN="$WORK/probe-stub"
mkdir -p "$PROBE_REPO/.github/scripts" "$PROBE_REPO/.github/tools/claude-code" "$PROBE_REPO/.claude-plugin" "$PROBE_REPO/plugins" "$STUB_BIN" "$WORK/probe-tmp"
cp "$INSTALL_PROBE" "$PLUGIN_DIR/.github/scripts/session-hub-claude-code-pin.sh" "$PROBE_REPO/.github/scripts/"
cp "$PLUGIN_DIR/.github/tools/claude-code/package.json" "$PROBE_REPO/.github/tools/claude-code/"
cp "$MARKETPLACE" "$PROBE_REPO/.claude-plugin/"
cp -R "$HUB_DIR" "$PROBE_REPO/plugins/session-hub"
probe_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$PROBE_REPO" \
    -c user.name=probe -c user.email=probe@localhost -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
probe_git init -q
probe_git add -A
probe_git commit -q -m "probe fixture"
cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
MODE="$(cat "$HERE/mode")"
json() {
  node -e 'const v = process.argv[2].split(".").reduce((o, k) => o[k], JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))); process.stdout.write(String(v));' "$1" "$2"
}
case "$*" in
  ("--version") printf '%s (Claude Code)\n' "$(cat "$HERE/version")" ;;
  ("plugin validate "*) ;;
  ("plugin marketplace add "*)
    if [ "$MODE" = catalog ] && [ "$(json "$4/.claude-plugin/marketplace.json" name)" = zensu-catalog-probe ]; then
      echo "stub claude: catalog refused" >&2
      exit 1
    fi
    mkdir -p "$CLAUDE_CONFIG_DIR/stub-markets"
    printf '%s' "$4" > "$CLAUDE_CONFIG_DIR/stub-markets/$(json "$4/.claude-plugin/marketplace.json" name)"
    ;;
  ("plugin tag plugins/session-hub")
    VER="$(json plugins/session-hub/.claude-plugin/plugin.json version)"
    if [ "$MODE" = retag ]; then
      git commit -q --allow-empty -m retag
    fi
    if [ "$MODE" = lightweight ]; then
      git tag "session-hub--v$VER"
    elif [ "$MODE" = message ]; then
      git tag -a "session-hub--v$VER" -m "Release session-hub $VER"
    else
      git tag -a "session-hub--v$VER" -m "session-hub $VER"
    fi
    ;;
  ("plugin install session-hub@"*)
    [ "$MODE" = noinstall ] && exit 0
    MARKET_NAME="${3#session-hub@}"
    MARKET="$(cat "$CLAUDE_CONFIG_DIR/stub-markets/$MARKET_NAME")"
    node -e '
      const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const e = m.plugins.find((p) => p.name === "session-hub").source;
      process.stdout.write([e.url, e.path, e.ref].join("\n") + "\n");
    ' "$MARKET/.claude-plugin/marketplace.json" > "$CLAUDE_CONFIG_DIR/stub-entry"
    { read -r URL; read -r SUB; read -r REF; } < "$CLAUDE_CONFIG_DIR/stub-entry"
    SRC="$CLAUDE_CONFIG_DIR/stub-src"
    rm -rf "$SRC"
    git -c advice.detachedHead=false clone --quiet --no-local --branch "$REF" "$URL" "$SRC"
    VER="$(json "$SRC/$SUB/.claude-plugin/plugin.json" version)"
    DEST="$CLAUDE_CONFIG_DIR/plugins/cache/$MARKET_NAME/session-hub/$VER"
    mkdir -p "$(dirname "$DEST")"
    cp -R "$SRC/$SUB" "$DEST"
    rm -rf "$SRC"
    case "$MODE" in
      (drop) rm "$DEST/CHANGELOG.md" ;;
      (byte) node -e 'const fs = require("fs"); const b = fs.readFileSync(process.argv[1]); b[0] ^= 1; fs.writeFileSync(process.argv[1], b);' "$DEST/README.md" ;;
      (optout) mkdir -p "$HOME/.zensu" && printf '%s\n' '{"hooks":{"sessionHubReceipt":false}}' > "$HOME/.zensu/config.json" ;;
    esac
    ;;
  (*) echo "stub claude: unmodelled call: $*" >&2; exit 64 ;;
esac
STUB
chmod +x "$STUB_BIN/claude"
command -v node > "$STUB_BIN/real-node"
cat > "$STUB_BIN/node" <<'STUB'
#!/bin/bash
HERE="$(cd "$(dirname "$0")" && pwd -P)"
REAL="$(cat "$HERE/real-node")"
MODE="$(cat "$HERE/mode")"
case "$MODE:${1:-}" in
  (noisy:*/hooks/lib/session-hub-receipt-v1.mjs|loose:*/hooks/lib/session-hub-receipt-v1.mjs|forged:*/hooks/lib/session-hub-receipt-v1.mjs) ;;
  (*) exec "$REAL" "$@" ;;
esac
"$REAL" "$@"
RC=$?
RECEIPTS="$CLAUDE_CONFIG_DIR/zensu/session-hub/v1/receipts"
case "$MODE" in
  (noisy) printf 'x' ;;
  (loose) chmod 644 "$RECEIPTS"/*.json ;;
  (forged) "$REAL" -e 'const fs = require("fs"); for (const f of fs.readdirSync(process.argv[1])) { if (!f.endsWith(".json")) continue; const p = process.argv[1] + "/" + f; const r = JSON.parse(fs.readFileSync(p, "utf8")); r.plugin = "0.0.0"; fs.writeFileSync(p, JSON.stringify(r) + "\n"); }' "$RECEIPTS" ;;
esac
exit "$RC"
STUB
chmod +x "$STUB_BIN/node"
PROBE_PIN="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).dependencies["@anthropic-ai/claude-code"]))' "$PROBE_REPO/.github/tools/claude-code/package.json")"
hub_probe() {
  printf '%s' "$1" > "$STUB_BIN/mode"
  printf '%s' "$2" > "$STUB_BIN/version"
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR PATH="$STUB_BIN:$PATH" RUNNER_TEMP="$WORK/probe-tmp" \
    bash "$PROBE_REPO/.github/scripts/session-hub-install-probe.sh" .github/tools/claude-code 2>&1
}
if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "H15 jq and git are on PATH for the install probe" FAIL
else
  PROBE_OUT="$(hub_probe faithful "$PROBE_PIN")"; PROBE_RC=$?
  PROBE_TAGS="$(probe_git tag -l)"
  if [ "$PROBE_RC" -eq 0 ] && [ -z "$PROBE_TAGS" ]; then
    check "H15 the install probe passes against a stub claude that installs the git-subdir entry faithfully, and leaves the probed repository without a tag" PASS
  else
    check "H15 the install probe does not pass a faithful stub install (rc=$PROBE_RC tags=${PROBE_TAGS:-none}: $(printf '%s' "$PROBE_OUT" | tail -n 4 | tr '\n' ' '))" FAIL
  fi
  for spec in "drop|$PROBE_PIN|::error::the installed session-hub|an installed copy without one file" \
    "byte|$PROBE_PIN|::error::the installed session-hub|an installed copy with one byte changed" \
    "faithful|0.0.1|::error::the install probe needs Claude Code $PROBE_PIN, found: 0.0.1 (Claude Code)|a Claude Code of another version" \
    "lightweight|$PROBE_PIN|::error::claude plugin tag plugins/session-hub did not create the annotated tag|a lightweight tag" \
    "retag|$PROBE_PIN|::error::claude plugin tag plugins/session-hub did not create the annotated tag|an annotated tag on another commit" \
    "message|$PROBE_PIN|::error::claude plugin tag plugins/session-hub wrote a tag message other than session-hub|an annotated tag with another message" \
    "catalog|$PROBE_PIN|::error::Claude Code $PROBE_PIN refuses the unfiltered marketplace catalog|a refused unfiltered catalog" \
    "noinstall|$PROBE_PIN|::error::claude plugin install left no session-hub|an install that lands nothing" \
    "optout|$PROBE_PIN|::error::the installed receipt entry did not land exactly one silent receipt|an installed entry that lands no receipt" \
    "noisy|$PROBE_PIN|::error::the installed receipt entry did not land exactly one silent receipt|an installed entry that prints output" \
    "loose|$PROBE_PIN|::error::the receipt the installed entry landed is not a 0600 receipt|a receipt readable by others" \
    "forged|$PROBE_PIN|::error::the receipt the installed entry landed is not a 0600 receipt for its token from session-hub|a receipt that names another plugin version"; do
    mode="${spec%%|*}"; rest="${spec#*|}"; version="${rest%%|*}"; rest="${rest#*|}"; want="${rest%%|*}"; what="${rest#*|}"
    PROBE_OUT="$(hub_probe "$mode" "$version")"; PROBE_RC=$?
    case "$PROBE_OUT" in
      (*"$want"*) [ "$PROBE_RC" -ne 0 ] && check "H15-control the probe refuses $what with its own error" PASS \
        || check "H15-control the probe prints the error for $what but exits 0" FAIL ;;
      (*) check "H15-control the probe does not refuse $what with its own error (rc=$PROBE_RC: $(printf '%s' "$PROBE_OUT" | tail -n 4 | tr '\n' ' '))" FAIL ;;
    esac
  done
  PROBE_VER="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version))' "$PROBE_REPO/plugins/session-hub/.claude-plugin/plugin.json")"
  node -e '
    const fs = require("fs");
    const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    m.plugins.find((p) => p.name === "session-hub").source.ref = "session-hub--v0.0.0";
    fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
  ' "$PROBE_REPO/.claude-plugin/marketplace.json"
  probe_git commit -q -a -m "entry names another tag"
  PROBE_OUT="$(hub_probe faithful "$PROBE_PIN")"; PROBE_RC=$?
  probe_git reset -q --hard HEAD~1
  case "$PROBE_OUT" in
    (*"::error::the session-hub marketplace entry does not point at session-hub--v$PROBE_VER"*) [ "$PROBE_RC" -ne 0 ] && check "H15-control the probe refuses an entry whose ref names another tag with its own error" PASS \
      || check "H15-control the probe prints the error for an entry whose ref names another tag but exits 0" FAIL ;;
    (*) check "H15-control the probe does not refuse an entry whose ref names another tag with its own error (rc=$PROBE_RC: $(printf '%s' "$PROBE_OUT" | tail -n 4 | tr '\n' ' '))" FAIL ;;
  esac
fi

PLM_TRAIL="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
trail_parity() {
  node -e '
    const fs = require("fs");
    const [plmFile, hubFile, extra] = process.argv.slice(1);
    const allowed = new Map([
      ["parseArgs", "the --anchor flag of the write-anchor feature is gone"],
      ["COMMAND_FLAGS", "the --anchor flag of the write-anchor feature is gone"],
      ["refuseForeignFlags", "the --anchor flag of the write-anchor feature is gone"],
      ["cmdShow", "show prints PLM_GATE_SHOW_LINES instead of the write-anchor and continuation lines, and its --json carries neither key"],
      ["cmdTakeover", "the takeover brief carries plmGateCaution instead of writeAnchorCaution, and its --json carries neither writes nor continuation"],
      ["cmdHandoff", "the handoff brief carries plmGateCaution instead of writeAnchorCaution"],
      ["canonicalPair", "paths go through hostPath, because the GATE probe of bash-source-write-parse.js is gone"],
      ["whereAdviceLines", "the branch for an unloaded GATE probe is gone with the probe"],
      ["worktreeKeepModules", "the keep key comes from keepSessionKey, because the Session Control core is gone, and worktree-keep loads through a literal path"],
      ["cmdRelease", "its incomplete-tree refusal names worktree-keep-v1.js alone, because the Session Control core is gone"],
      ["hostPath", "throws instead of exiting through fail, so an importer can catch a missing claude-path-v1.js and main reports it after its flush"],
      ["main", "resolves the roots inside the dispatch guard, so a throw from hostPath is reported like a handler throw"],
    ]);
    if (extra) allowed.set(extra, "planted");
    const strip = (t) => {
      const out = [];
      let block = false;
      for (const line of t.split("\n")) {
        const s = line.trim();
        if (block) { if (s.includes("*/")) block = false; continue; }
        if (s.startsWith("/*")) { if (!s.includes("*/")) block = true; continue; }
        if (s.startsWith("//") || s === "") continue;
        out.push(line.replace(/\s+$/, ""));
      }
      return out;
    };
    const named = (t) => t.split("/session-hub:session-trail").join("/zensu:session-trail").split("session-hub:session-trail").join("zensu:session-trail").split("Zensu Session Hub plugin").join("Zensu plugin");
    const decl = /^(?:export\s+)?(?:async\s+)?function\*?\s+([\w$]+)|^(?:export\s+)?(?:const|let|var|class)\s+([\w$]+)/;
    const chunks = (lines) => {
      const map = new Map();
      let name = null;
      let body = [];
      const flush = () => { if (name !== null) map.set(map.has(name) ? name + "#dup" : name, body.join("\n")); };
      for (const line of lines) {
        if (/^[^\s})\]]/.test(line)) {
          flush();
          const m = decl.exec(line);
          name = m ? (m[1] || m[2]) : "~" + line;
          body = [line];
        } else body.push(line);
      }
      flush();
      return map;
    };
    const plm = chunks(strip(fs.readFileSync(plmFile, "utf8")));
    const hub = chunks(strip(named(fs.readFileSync(hubFile, "utf8"))));
    const bad = [];
    let shared = 0;
    for (const [k, body] of plm) {
      if (k.startsWith("~") || !hub.has(k)) continue;
      shared += 1;
      const same = body === hub.get(k);
      if (!same && !allowed.has(k)) bad.push("drift:" + k);
      if (same && allowed.has(k)) bad.push("stale:" + k);
    }
    for (const k of allowed.keys()) if (!plm.has(k) || !hub.has(k)) bad.push("absent:" + k);
    for (const k of [...plm.keys(), ...hub.keys()]) if (k.endsWith("#dup")) bad.push("duplicate:" + k);
    process.stdout.write(bad.length ? bad.join(" ") : "ok " + shared + " " + allowed.size);
  ' "$@" 2>&1
}
PARITY="$(trail_parity "$PLM_TRAIL" "$HUB_TRAIL")"
case "$PARITY" in
  ("ok "*) PARITY_COUNTS="${PARITY#ok }"
    check "H16 the companion's trail.mjs equals PLM's frozen copy in all ${PARITY_COUNTS%% *} top-level declarations both define, once comments are removed and the command names are mapped, apart from ${PARITY_COUNTS#* } reviewed differences" PASS ;;
  (*) check "H16 the two trail.mjs copies drifted apart outside the reviewed differences: $PARITY" FAIL ;;
esac
DRIFT_ERR="$(node -e '
  const fs = require("fs");
  const [src, out] = process.argv.slice(1);
  const t = fs.readFileSync(src, "utf8");
  const anchor = "session-trail: ${msg}";
  if (!t.includes(anchor)) throw new Error("anchor missing: " + anchor);
  fs.writeFileSync(out, t.replace(anchor, "session-trail:: ${msg}"));
' "$HUB_TRAIL" "$WORK/trail-drift.mjs" 2>&1)"
if [ -n "$DRIFT_ERR" ]; then
  check "H16-control the planted drift could not be built ($DRIFT_ERR)" FAIL
else
  case " $(trail_parity "$PLM_TRAIL" "$WORK/trail-drift.mjs") " in
    (*" drift:fail "*) check "H16-control a one-character change to a shared function of the companion's copy fails the parity check" PASS ;;
    (*) check "H16-control a one-character change to a shared function of the companion's copy passes the parity check" FAIL ;;
  esac
fi
case " $(trail_parity "$PLM_TRAIL" "$HUB_TRAIL" fail) " in
  (*" stale:fail "*) check "H16-stale-control an allowlist entry for a declaration both copies hold equal fails the parity check" PASS ;;
  (*) check "H16-stale-control an allowlist entry for a declaration both copies hold equal passes the parity check" FAIL ;;
esac

TARGET_REPO="$WORK/target-repo"
mkdir -p "$TARGET_REPO/.github/scripts" "$TARGET_REPO/.claude-plugin" "$TARGET_REPO/plugins/session-hub/.claude-plugin"
cp "$PLUGIN_DIR/.github/scripts/session-hub-release-target.sh" "$PLUGIN_DIR/.github/scripts/session-hub-release-notes.sh" "$TARGET_REPO/.github/scripts/"
tgit() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$TARGET_REPO" \
    -c user.name=probe -c user.email=probe@localhost -c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
hub_commit() {
  local ver="$1" extra="$2"
  shift 2
  printf '{"name":"session-hub","version":"%s"%s}\n' "$ver" "$extra" > "$TARGET_REPO/plugins/session-hub/.claude-plugin/plugin.json"
  printf '{"name":"zensu","plugins":[{"name":"session-hub","version":"%s","source":{"source":"git-subdir","url":"https://github.com/MKITConsulting/zensu-claude-code.git","path":"plugins/session-hub","ref":"session-hub--v%s"}}]}\n' "$ver" "$ver" > "$TARGET_REPO/.claude-plugin/marketplace.json"
  { printf '# Changelog\n\n## [Unreleased]\n\n'; for s in "$@"; do printf '%s\n\n' "$s"; done; } > "$TARGET_REPO/plugins/session-hub/CHANGELOG.md"
  tgit add -A
  tgit commit -q -m "session-hub $ver$extra"
  tgit rev-parse HEAD
}
section() {
  printf '## [%s] - 2026-11-1%s\n\n- change %s' "$1" "$2" "$1"
}
target_of() {
  local script="$1" event="$2" at="$3" out
  tgit checkout -q --detach "$at"
  rm -f "$WORK/target.env" "$WORK/target-notes.md"
  out="$(cd "$TARGET_REPO" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR GITHUB_EVENT_NAME="$event" \
    bash "$script" "$WORK/target.env" "$WORK/target-notes.md" 2>&1)" || { printf 'refused:%s' "$out"; return 0; }
  printf '%s' "$(sed -n 's/^target=//p' "$WORK/target.env"):$(sed -n 's/^tagged=//p' "$WORK/target.env")"
}
TGT="$TARGET_REPO/.github/scripts/session-hub-release-target.sh"
if ! command -v jq >/dev/null 2>&1; then
  check "H17 jq is on PATH for the release-target script" FAIL
else
  tgit init -q
  T_A="$(hub_commit 1.0.0 "" "$(section 1.0.0 0)")"
  T_B="$(hub_commit 1.0.0 ',"description":"touched"' "$(section 1.0.0 0)")"
  T_C="$(hub_commit 1.0.1 "" "$(section 1.0.1 1)" "$(section 1.0.0 0)")"
  T_D="$(hub_commit 1.0.0 "" "$(section 1.0.0 0)")"
  T_E="$(hub_commit 1.0.1 ',"description":"again"' "$(section 1.0.1 1)" "$(section 1.0.0 0)")"
  tgit checkout -q -b side "$T_E"
  T_F="$(hub_commit 1.0.2 "" "$(section 1.0.2 2)" "$(section 1.0.1 1)")"
  tgit checkout -q --detach "$T_E"
  printf 'other\n' > "$TARGET_REPO/other.txt"
  tgit add -A
  tgit commit -q -m other
  tgit merge -q --no-ff -m "merge side" side
  T_M="$(tgit rev-parse HEAD)"
  T_H="$(hub_commit 1.0.3 "" "$(section 1.0.2 2)")"
  T_I="$(hub_commit 1.0.4 "" "## [1.0.4] - 2026-11-14" "$(section 1.0.2 2)")"
  T_J="$(hub_commit 1.0.5 "" "$(section 1.0.5 5)")"
  R_DISPATCH="$(target_of "$TGT" workflow_dispatch "$T_B")"
  R_PUSH_LATE="$(target_of "$TGT" push "$T_B")"
  R_PUSH="$(target_of "$TGT" push "$T_A")"
  R_REBUMP="$(target_of "$TGT" workflow_dispatch "$T_E")"
  R_MERGE="$(target_of "$TGT" workflow_dispatch "$T_M")"
  R_MISSING="$(target_of "$TGT" workflow_dispatch "$T_H")"
  R_EMPTY="$(target_of "$TGT" workflow_dispatch "$T_I")"
  tgit tag -a session-hub--v1.0.5 -m "session-hub 1.0.5" "$T_I"
  R_ELSEWHERE="$(target_of "$TGT" workflow_dispatch "$T_J")"
  tgit tag -d session-hub--v1.0.5 >/dev/null
  tgit tag -a session-hub--v1.0.5 -m "session-hub 1.0.5" "$T_J"
  R_TAGGED="$(target_of "$TGT" workflow_dispatch "$T_J")"
  NOTES_OK="$(grep -c -F -- '- change 1.0.5' "$WORK/target-notes.md")"
  H17_BAD=""
  [ "$R_DISPATCH" = "$T_A:false" ] || H17_BAD="$H17_BAD dispatch=$R_DISPATCH"
  case "$R_PUSH_LATE" in (refused:*"does not introduce session-hub 1.0.0"*) ;; (*) H17_BAD="$H17_BAD push-late=$R_PUSH_LATE" ;; esac
  [ "$R_PUSH" = "$T_A:false" ] || H17_BAD="$H17_BAD push=$R_PUSH"
  [ "$R_REBUMP" = "$T_E:false" ] || H17_BAD="$H17_BAD rebump=$R_REBUMP"
  [ "$R_MERGE" = "$T_M:false" ] || H17_BAD="$H17_BAD merge=$R_MERGE"
  case "$R_MISSING" in (refused:*"carries no ## [1.0.3]"*) ;; (*) H17_BAD="$H17_BAD missing=$R_MISSING" ;; esac
  case "$R_EMPTY" in (refused:*"section of plugins/session-hub/CHANGELOG.md is empty"*) ;; (*) H17_BAD="$H17_BAD empty=$R_EMPTY" ;; esac
  case "$R_ELSEWHERE" in (refused:*"already exists at $T_I"*) ;; (*) H17_BAD="$H17_BAD elsewhere=$R_ELSEWHERE" ;; esac
  [ "$R_TAGGED" = "$T_J:true" ] || H17_BAD="$H17_BAD tagged=$R_TAGGED"
  [ "$NOTES_OK" = 1 ] || H17_BAD="$H17_BAD notes=$NOTES_OK"
  [ -z "$H17_BAD" ] \
    && check "H17 the release-target script picks the commit that introduced the version on the first-parent line, past a later touch, after a revert and re-bump and at a merge, refuses a pushed head that did not introduce it, a missing or empty changelog section and a tag at another commit, and accepts the tag at the target" PASS \
    || check "H17 the release-target script decided:$H17_BAD" FAIL
  for spec in "continue|$T_E|rebump|a loop that skips a commit of another version" "first-parent|$T_M|merge|a log that leaves the first-parent line"; do
    mode="${spec%%|*}"; rest="${spec#*|}"; at="${rest%%|*}"; rest="${rest#*|}"; case_name="${rest%%|*}"; what="${rest#*|}"
    MUT="$TARGET_REPO/.github/scripts/target-$mode.sh"
    if [ "$mode" = continue ]; then sed 's/ || break$/ || continue/' "$TGT" > "$MUT"; else sed 's/git log --first-parent --format=%H/git log --format=%H/' "$TGT" > "$MUT"; fi
    if cmp -s "$TGT" "$MUT"; then
      check "H17-control $what could not be planted" FAIL
      continue
    fi
    R_MUT="$(target_of "$MUT" workflow_dispatch "$at")"
    [ "$R_MUT" != "$at:false" ] \
      && check "H17-control $what picks another target for the $case_name case ($R_MUT)" PASS \
      || check "H17-control $what still picks the right target for the $case_name case" FAIL
  done
fi

VERSION_REPO="$WORK/version-repo"
mkdir -p "$VERSION_REPO/.github/scripts" "$VERSION_REPO/plugins/session-hub/.claude-plugin"
cp "$PLUGIN_DIR/.github/scripts/session-hub-release-version.sh" "$PLUGIN_DIR/.github/scripts/session-hub-release-supersede.sh" "$PLUGIN_DIR/.github/scripts/session-hub-release-notes.sh" "$VERSION_REPO/.github/scripts/"
vgit() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$VERSION_REPO" \
    -c user.name=probe -c user.email=probe@localhost -c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
VS="$VERSION_REPO/.github/scripts/session-hub-release-version.sh"
version_of() {
  local script="$1" current="$2" type="$3" supersede="$4" out tag
  shift 4
  printf '{"name":"session-hub","version":"%s"}\n' "$current" > "$VERSION_REPO/plugins/session-hub/.claude-plugin/plugin.json"
  vgit add -A
  vgit commit -q --allow-empty -m "at $current"
  for tag in $(vgit tag -l 'session-hub--v*'); do vgit tag -d "$tag" > /dev/null; done
  for tag in "$@"; do vgit tag "session-hub--v$tag"; done
  rm -f "$WORK/version.env"
  out="$(cd "$VERSION_REPO" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    bash "$script" "$type" "$supersede" "$WORK/version.env" 2>&1)" || { printf 'refused:%s' "$out"; return 0; }
  printf '%s/%s' "$(sed -n 's/^version=//p' "$WORK/version.env")" "$(sed -n 's/^superseded=//p' "$WORK/version.env")"
}
if ! command -v jq >/dev/null 2>&1; then
  check "H18 jq is on PATH for the release-version script" FAIL
else
  vgit init -q
  H18_BAD=""
  R="$(version_of "$VS" 1.0.0 patch false)"
  case "$R" in (refused:*"publish 1.0.0 first"*) ;; (*) H18_BAD="$H18_BAD untagged=$R" ;; esac
  R="$(version_of "$VS" 1.0.0 patch true)"; [ "$R" = 1.0.1/1.0.0 ] || H18_BAD="$H18_BAD first-supersede=$R"
  R="$(version_of "$VS" 1.0.0 minor false 1.0.0)"; [ "$R" = 1.1.0/ ] || H18_BAD="$H18_BAD bump=$R"
  R_TAGGED_SUPERSEDE="$(version_of "$VS" 1.0.0 patch true 1.0.0)"
  case "$R_TAGGED_SUPERSEDE" in (refused:*"supersede applies only while"*) ;; (*) H18_BAD="$H18_BAD tagged-supersede=$R_TAGGED_SUPERSEDE" ;; esac
  R="$(version_of "$VS" 1.0.1 patch true 1.0.0)"; [ "$R" = 1.0.2/1.0.1 ] || H18_BAD="$H18_BAD supersede=$R"
  R_NEWER="$(version_of "$VS" 1.0.0 patch true 1.1.0)"
  case "$R_NEWER" in (refused:*"is not older than 1.0.0"*) ;; (*) H18_BAD="$H18_BAD newer-tag=$R_NEWER" ;; esac
  R="$(version_of "$VS" 1.0.10 patch true 1.0.9)"; [ "$R" = 1.0.11/1.0.10 ] || H18_BAD="$H18_BAD version-sort=$R"
  R="$(version_of "$VS" 1.2.3 major false 1.2.3)"; [ "$R" = 2.0.0/ ] || H18_BAD="$H18_BAD major=$R"
  R="$(version_of "$VS" 1.0.0 nightly false 1.0.0)"
  case "$R" in (refused:*"unknown version_type"*) ;; (*) H18_BAD="$H18_BAD type=$R" ;; esac
  SUP_LOG="$WORK/supersede-changelog.md"
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.1] - 2026-11-12\n\n- change 1.0.1\n\n## [1.0.0] - 2026-11-10\n\n- change 1.0.0\n' > "$SUP_LOG"
  cp "$SUP_LOG" "$WORK/supersede-before.md"
  SUP_RC=0; bash "$VERSION_REPO/.github/scripts/session-hub-release-supersede.sh" 1.0.0 1.0.1 "$SUP_LOG" > /dev/null 2>&1 || SUP_RC=$?
  SUP_DIFF="$(diff "$WORK/supersede-before.md" "$SUP_LOG" | grep -c '^[<>]')"
  SUP_LINE="$(grep -cxF -- '## [1.0.0] - 2026-11-10 (superseded by 1.0.1, never published)' "$SUP_LOG")"
  NOTES_OLD=0; bash "$VERSION_REPO/.github/scripts/session-hub-release-notes.sh" 1.0.0 "$SUP_LOG" "$WORK/supersede-notes.md" > /dev/null 2>&1 || NOTES_OLD=$?
  NOTES_NEW=0; bash "$VERSION_REPO/.github/scripts/session-hub-release-notes.sh" 1.0.1 "$SUP_LOG" "$WORK/supersede-notes.md" > /dev/null 2>&1 || NOTES_NEW=$?
  [ "$SUP_RC:$SUP_DIFF:$SUP_LINE:$NOTES_OLD:$NOTES_NEW" = "0:2:1:1:0" ] || H18_BAD="$H18_BAD mark=$SUP_RC:$SUP_DIFF:$SUP_LINE:$NOTES_OLD:$NOTES_NEW"
  printf '# Changelog\n\n## [1.0.1] - 2026-11-12\n\n- change 1.0.1\n' > "$WORK/supersede-none.md"
  printf '# Changelog\n\n## [1.0.0] - 2026-11-10\n\n- a\n\n## [1.0.0] - 2026-11-11\n\n- b\n' > "$WORK/supersede-twice.md"
  for f in supersede-none supersede-twice; do
    OUT="$(bash "$VERSION_REPO/.github/scripts/session-hub-release-supersede.sh" 1.0.0 1.0.1 "$WORK/$f.md" 2>&1)" \
      && H18_BAD="$H18_BAD $f=accepted"
    case "$OUT" in (*"carries no single ## [1.0.0] - YYYY-MM-DD section"*) ;; (*) H18_BAD="$H18_BAD $f=${OUT:0:80}" ;; esac
  done
  [ -z "$H18_BAD" ] \
    && check "H18 the release-version script bumps a tagged version, refuses an untagged one unless supersede is set, refuses supersede for a tagged version or below a newer tag, sorts versions numerically, and the supersede script marks exactly the old section, which the notes script then refuses, and refuses a changelog without exactly one such section" PASS \
    || check "H18 the release-version or supersede script decided:$H18_BAD" FAIL
  for spec in "tagged|elif [ \"\$SUPERSEDE\" = true ]; then|elif false; then|1.0.0 patch true 1.0.0|a supersede of a tagged version" \
    "newer|if [ -n \"\$LATEST\" ] && [|if false && [|1.0.0 patch true 1.1.0|a supersede below a newer tag"; do
    mode="${spec%%|*}"; rest="${spec#*|}"; from="${rest%%|*}"; rest="${rest#*|}"; to="${rest%%|*}"; rest="${rest#*|}"; args="${rest%%|*}"; what="${rest#*|}"
    MUT="$VERSION_REPO/.github/scripts/version-$mode.sh"
    if ! node -e '
      const fs = require("fs");
      const [src, out, from, to] = process.argv.slice(1);
      const t = fs.readFileSync(src, "utf8");
      if (!t.includes(from)) process.exit(1);
      fs.writeFileSync(out, t.split(from).join(to));
    ' "$VS" "$MUT" "$from" "$to"; then
      check "H18-control $what could not be planted" FAIL
      continue
    fi
    set -f
    R_MUT="$(version_of "$MUT" $args)"
    set +f
    case "$R_MUT" in
      (refused:*) check "H18-control a version script that accepts $what still refuses it" FAIL ;;
      (*) check "H18-control a version script that accepts $what is caught ($R_MUT)" PASS ;;
    esac
  done
fi

IMMUTABLE_SCRIPT="$PLUGIN_DIR/.github/scripts/session-hub-require-immutable-releases.sh"
GH_STUB="$WORK/gh-stub"
mkdir -p "$GH_STUB"
cat > "$GH_STUB/gh" <<'STUB'
#!/bin/bash
ANSWER="$(cat "$(dirname "$0")/answer")"
if [ "$ANSWER" = fail ]; then
  echo "gh: HTTP 403: Resource not accessible" >&2
  exit 1
fi
printf '%s\n' "$ANSWER"
STUB
chmod +x "$GH_STUB/gh"
immutable_run() {
  printf '%s' "$1" > "$GH_STUB/answer"
  env PATH="$GH_STUB:$PATH" GH_TOKEN="$2" GITHUB_REPOSITORY=owner/repo bash "$3" "$4" 2>&1
}
H19_BAD=""
OUT="$(immutable_run true token "$IMMUTABLE_SCRIPT" "caller message")"; RC=$?
[ "$RC" -eq 0 ] || H19_BAD="$H19_BAD enabled=$RC"
OUT="$(immutable_run false token "$IMMUTABLE_SCRIPT" "caller message")"; RC=$?
case "$RC:$OUT" in (1:*"::error::caller message"*) ;; (*) H19_BAD="$H19_BAD disabled=$RC" ;; esac
OUT="$(immutable_run fail token "$IMMUTABLE_SCRIPT" "caller message")"; RC=$?
case "$RC:$OUT" in (1:*"::error::caller message (the Immutable Releases setting could not be read)"*) ;; (*) H19_BAD="$H19_BAD unreadable=$RC" ;; esac
OUT="$(immutable_run true "" "$IMMUTABLE_SCRIPT" "caller message")"; RC=$?
case "$RC:$OUT" in (1:*"IMMUTABLE_RELEASES_ADMIN_TOKEN"*) ;; (*) H19_BAD="$H19_BAD no-token=$RC" ;; esac
OUT="$(immutable_run true token "$IMMUTABLE_SCRIPT" "")"; RC=$?
case "$RC:$OUT" in (1:*"usage: session-hub-require-immutable-releases.sh"*) ;; (*) H19_BAD="$H19_BAD no-message=$RC" ;; esac
[ -z "$H19_BAD" ] \
  && check "H19 the Immutable Releases script passes only when the setting reads true, and refuses a disabled or unreadable setting with the caller's message, a missing token and a missing message" PASS \
  || check "H19 the Immutable Releases script decided:$H19_BAD" FAIL
node -e '
  const fs = require("fs");
  const [src, out] = process.argv.slice(1);
  const t = fs.readFileSync(src, "utf8");
  const from = t.indexOf(")\" || {\n");
  const to = from < 0 ? -1 : t.indexOf("\n}\n", from);
  fs.writeFileSync(out, from < 0 || to < 0 ? t : t.slice(0, from) + ")\"" + t.slice(to + 2));
' "$IMMUTABLE_SCRIPT" "$WORK/immutable-unguarded.sh"
OUT="$(immutable_run fail token "$WORK/immutable-unguarded.sh" "caller message")"
if cmp -s "$IMMUTABLE_SCRIPT" "$WORK/immutable-unguarded.sh"; then
  check "H19-control the read-failure branch could not be removed" FAIL
else
  case "$OUT" in
    (*"::error::caller message"*) check "H19-control a copy without the read-failure branch still prints the caller's message" FAIL ;;
    (*) check "H19-control a copy without the read-failure branch loses the caller's message on an unreadable setting" PASS ;;
  esac
fi

report
[ "$FAIL" -eq 0 ]
