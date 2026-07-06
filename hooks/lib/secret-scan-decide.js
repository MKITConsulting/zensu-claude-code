"use strict";

// Decision logic for pre-write-secret-scan.sh, kept in its own file (like
// bash-source-write-parse.js) so it uses normal quoting instead of a bash
// single-quoted node -e, and so pathExempt is unit-testable. Reads the
// PreToolUse payload from STDIN (not env — a ~1MB Write via env risks E2BIG
// and would fail open exactly on the largest payloads). Prints the matched
// rule names on stdout, or nothing. Fail-open paths note themselves on stderr
// and exit 0.
//
// Tool dispatch:
//   Write        — scan content            (path allowlist on file_path)
//   Edit         — scan new_string         (path allowlist on file_path)
//   MultiEdit    — scan edits[].new_string (path allowlist on file_path)
//   NotebookEdit — scan new_source         (path allowlist on notebook_path)
//   Bash         — scan the command text when the shared parser reports a
//                  write channel (detectChannels); an inline
//                  ZENSU_SECRET_SCAN=off prefix skips the scan (parity with
//                  the sibling gates' inline escape hatches; checked against
//                  heredoc-STRIPPED text so a scanned payload cannot smuggle
//                  the escape inside a heredoc body). The path allowlist does
//                  NOT apply to Bash — targets are not resolved here; use the
//                  marker, a placeholder, or the escape hatch instead.
//
// pathExempt covers test(s)/, __tests__/, spec(s)/, testdata/, evals/,
// fixtures/ segments (case-insensitive) and *.example.* files.

const path = require("path");
const { scan } = require(path.join(__dirname, "secret-patterns.js"));
const { detectChannels, stripHeredocs } = require(path.join(__dirname, "bash-source-write-parse.js"));

function pathExempt(p) {
  if (typeof p !== "string" || !p) return false;
  const norm = p.replace(/\\/g, "/");
  if (/(^|\/)(__tests__|tests?|specs?|testdata|evals|fixtures)\//i.test(norm)) return true;
  if (/\.example\./.test(path.basename(norm))) return true;
  return false;
}

function main() {
  let raw = "";
  try {
    raw = require("fs").readFileSync(0, "utf8");
  } catch (e) {
    process.stderr.write("zensu secret-scan: stdin read failed, failing open\n");
    return "";
  }
  let j;
  try {
    j = JSON.parse(raw || "{}");
  } catch (e) {
    process.stderr.write("zensu secret-scan: payload parse failed, failing open\n");
    return "";
  }
  const tool = j.tool_name || "";
  const ti = j.tool_input || {};
  const candidates = [];

  if (tool === "Write") {
    if (!pathExempt(ti.file_path)) candidates.push(ti.content);
  } else if (tool === "Edit") {
    if (!pathExempt(ti.file_path)) candidates.push(ti.new_string);
  } else if (tool === "MultiEdit") {
    if (!pathExempt(ti.file_path) && Array.isArray(ti.edits)) {
      for (const e of ti.edits) candidates.push(e && e.new_string);
    }
  } else if (tool === "NotebookEdit") {
    if (!pathExempt(ti.notebook_path)) candidates.push(ti.new_source);
  } else if (tool === "Bash") {
    const cmd = typeof ti.command === "string" ? ti.command : "";
    if (!cmd) return "";
    if (/(^|\s)ZENSU_SECRET_SCAN=off(\s|$)/.test(stripHeredocs(cmd))) return "";
    let channels = "";
    try {
      channels = detectChannels(cmd);
    } catch (e) {
      process.stderr.write("zensu secret-scan: channel detection failed, failing open\n");
      return "";
    }
    if (channels) candidates.push(cmd);
  } else {
    return "";
  }

  const rules = new Set();
  for (const c of candidates) {
    if (typeof c !== "string" || !c) continue;
    for (const m of scan(c).matches) rules.add(m.rule);
  }
  return Array.from(rules).join(", ");
}

process.stdout.write(main());
