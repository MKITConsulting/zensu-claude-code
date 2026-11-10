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
  check "H1 plugins/session-hub holds exactly the allowlisted files: the manifest, the hooks, the vendored libraries, the session-trail skill and its docs" PASS
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

VENDORED='hooks/lib/claude-path-v1.js:hooks/lib/claude-path-v1.js
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
[ "$IDENTITY_N" = "7" ] && [ -z "$IDENTITY_BAD" ] \
  && check "H4 the four vendored libraries, the usage-feed module, its contract and the lineage ledger module are byte-identical to their PLM sources ($IDENTITY_N files)" PASS \
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
    for (const file of files) {
      const text = fs.readFileSync(file, "utf8");
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
  && check "H5 nothing under plugins/session-hub requires, imports or sources a file outside it, and every hook argument and module resolves inside it" PASS \
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

DESC_FACTS="$(node -e '
  const text = require("fs").readFileSync(process.argv[1], "utf8");
  const m = /^description: >\n((?:  .*\n)+)/m.exec(text);
  if (!m) { process.stdout.write("none"); process.exit(0); }
  const d = m[1].split("\n").map((s) => s.trim()).filter(Boolean).join(" ");
  process.stdout.write(d.length + " " + d.indexOf("Use when"));
' "$HUB_SKILL" 2>&1)"
DESC_LEN="${DESC_FACTS%% *}"; DESC_USE="${DESC_FACTS##* }"
case "$DESC_LEN:$DESC_USE" in
  (*[!0-9:-]*|:*|*:) check "H8 the companion skill description could not be measured ($DESC_FACTS)" FAIL ;;
  (*) if [ "$DESC_LEN" -le 220 ] && [ "$DESC_USE" -ge 0 ] && [ "$DESC_USE" -lt 150 ]; then
        check "H8 the companion skill description fits the listing budget ($DESC_LEN chars, Use when at $DESC_USE)" PASS
      else
        check "H8 the companion skill description is $DESC_LEN chars with Use when at $DESC_USE, want at most 220 and before 150" FAIL
      fi ;;
esac

cliff_split() {
  node -e '
    const fs = require("fs");
    const [rootFile, hubFile] = process.argv.slice(1);
    const lines = (file) => fs.readFileSync(file, "utf8").split("\n").filter((l) => !l.startsWith("#"));
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
  && check "H9 cliff.toml leaves plugins/session-hub out of PLM's changelog on v* tags, and the companion's cliff.toml lists only commits that touch it on session-hub--v* tags, with the same body and parsers" PASS \
  || check "H9 the changelog path filters disagree: $CLIFF_BAD" FAIL
CLIFF_PROBE="$(mktemp -d -t hub-cliff-XXXXXX)"
grep -v '^include_paths = ' "$HUB_DIR/cliff.toml" > "$CLIFF_PROBE/hub.toml"
case "$(cliff_split "$PLUGIN_DIR/cliff.toml" "$CLIFF_PROBE/hub.toml")" in
  (*hub-include-paths*) check "H9-control a companion config without its path filter fails the comparison" PASS ;;
  (*) check "H9-control a companion config without its path filter passes the comparison" FAIL ;;
esac
rm -rf "$CLIFF_PROBE"

REL_WF="$PLUGIN_DIR/.github/workflows/release-session-hub.yml"
PLM_WF="$PLUGIN_DIR/.github/workflows/release.yml"
CI_WF="$PLUGIN_DIR/.github/workflows/ci.yml"
GATE="$PLUGIN_DIR/.github/scripts/session-hub-release-gate.sh"
tag_discipline() {
  node -e '
    const fs = require("fs");
    const [rel, plm] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
    const bad = [];
    const lines = rel.split("\n").map((l) => l.trim());
    if (lines.filter((l) => l === "claude plugin tag plugins/session-hub --push").length !== 1) bad.push("tag-command");
    if (/\bgit\s+tag\b(?!\s+-l\b)/.test(rel)) bad.push("git-tag");
    if (/\bgit\s+push\b(?![^\n]*"\$BR")/.test(rel)) bad.push("other-push");
    if (/\bgit\/(refs|tags)\b/.test(rel)) bad.push("git-data-api");
    for (const m of rel.matchAll(/gh release create[^\n]*/g)) if (!m[0].includes("--verify-tag")) bad.push("release-without-verify-tag");
    const hub = "chore(release): bump session-hub to";
    const plmPrefix = "chore(release): bump version to";
    if (!rel.includes("startsWith(github.event.head_commit.message, \u0027" + hub + "\u0027)")) bad.push("publish-trigger");
    if (!rel.includes("git commit -m \"" + hub + " $VER\"")) bad.push("prepare-subject");
    if (!plm.includes(plmPrefix) || hub.startsWith(plmPrefix) || plmPrefix.startsWith(hub)) bad.push("prefix-overlap");
    process.stdout.write(bad.join(" "));
  ' "$1" "$PLM_WF" 2>&1
}
TAG_BAD="$(tag_discipline "$REL_WF")"
[ -z "$TAG_BAD" ] \
  && check "H10 release-session-hub.yml creates the companion tag only through claude plugin tag plugins/session-hub --push, and its release subject never starts PLM's publish" PASS \
  || check "H10 the companion release workflow breaks its tag discipline: $TAG_BAD" FAIL
TAG_PROBE="$(mktemp -d -t hub-tag-XXXXXX)"
{ cat "$REL_WF"; printf '%s\n' '          git push origin "refs/tags/$TAG"'; } > "$TAG_PROBE/release.yml"
case "$(tag_discipline "$TAG_PROBE/release.yml")" in
  (*other-push*) check "H10-control a hand-pushed tag in the companion release workflow fails the discipline check" PASS ;;
  (*) check "H10-control a hand-pushed tag in the companion release workflow passes the discipline check" FAIL ;;
esac
rm -rf "$TAG_PROBE"

PIN_FACTS="$(node -e '
  const fs = require("fs");
  const [ci, rel, gate] = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8"));
  const installs = (t) => [...t.matchAll(/@anthropic-ai\/claude-code@([^\s"]+)/g)].map((m) => m[1]);
  const checks = (t) => [...t.matchAll(/"([0-9][^"\s]*) \(Claude Code\)"/g)].map((m) => m[1]);
  const gatePin = [...gate.matchAll(/^CLAUDE_CODE_VERSION="([^"]+)"$/gm)].map((m) => m[1]);
  const parts = { ciInstall: installs(ci), ciCheck: checks(ci), releaseInstall: installs(rel), gatePin };
  const all = Object.values(parts).flat();
  const empty = Object.entries(parts).filter(([, v]) => v.length === 0).map(([k]) => k);
  const distinct = [...new Set(all)];
  const ok = empty.length === 0 && distinct.length === 1 && /^[0-9]+\.[0-9]+\.[0-9]+$/.test(distinct[0]);
  process.stdout.write(ok ? "ok " + distinct[0] : "missing=" + empty.join(",") + " versions=" + distinct.join(","));
' "$CI_WF" "$REL_WF" "$GATE" 2>&1)"
case "$PIN_FACTS" in
  ("ok "*) check "H11 the CI validate job, the companion release workflow and its gate pin one exact Claude Code (${PIN_FACTS#ok })" PASS ;;
  (*) check "H11 the Claude Code pins disagree or float: $PIN_FACTS" FAIL ;;
esac

report
[ "$FAIL" -eq 0 ]
