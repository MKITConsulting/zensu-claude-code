"use strict";

// Single source of truth for secret detection, consumed by
// hooks/pre-write-secret-scan.sh. Curated provider-token rules plus a
// Shannon-entropy assignment heuristic — deliberately NOT a naive
// key/secret/password catch-all, which drowns the gate in false positives.
//
// Dual mode:
//   CLI    — stdin: candidate text; stdout: JSON {"matches":[{rule,line}]}
//   module — require(...).scan(text) returns the same object
//
// Exemptions handled here (content-level): a line carrying the literal
// zensu-secret-allow marker, and obvious placeholder values (EXAMPLE,
// PLACEHOLDER, CHANGE_ME, YOUR_, XXXX, ..., <angle>, {{template}}, ${var}).
// Path-level exemptions (tests/evals/fixtures/*.example.*) are the caller's
// job — this engine never sees file paths.

const RULES = [
  { rule: "aws-access-key-id", re: /\bAKIA[0-9A-Z]{16}\b/ },
  {
    rule: "aws-secret-access-key",
    re: /\baws_?secret_?access_?key\b\s*[:=]\s*['"]?[A-Za-z0-9/+=]{40}(?![A-Za-z0-9/+=])/i,
  },
  { rule: "github-token", re: /\bgh[pousr]_[A-Za-z0-9]{36}\b/ },
  { rule: "github-fine-grained-pat", re: /\bgithub_pat_[A-Za-z0-9_]{22,}\b/ },
  { rule: "slack-token", re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/ },
  { rule: "stripe-live-key", re: /\b[sr]k_live_[A-Za-z0-9]{16,}\b/ },
  {
    rule: "private-key-pem",
    re: /-----BEGIN (?:(?:RSA|EC|DSA|OPENSSH|PGP|ENCRYPTED) )?PRIVATE KEY-----/,
  },
];

const ENTROPY_ASSIGN =
  /\b[A-Za-z0-9_-]*(?:key|secret|token|password|passwd|credential)[A-Za-z0-9_-]*\s*[:=]\s*(?:['"]([^'"\s]{16,})['"]|([A-Za-z0-9+/_=-]{16,})(?=\s|$))/i;
const ENTROPY_THRESHOLD = 3.5;
const MAX_LINE_LENGTH = 2048;

const PLACEHOLDER =
  /EXAMPLE|PLACEHOLDER|CHANGE_?ME|YOUR_|XXXX|\.\.\.|<[^>]*>|\{\{|\$\{/i;

const ALLOW_MARKER = "zensu-secret-allow";

function shannonEntropy(s) {
  const freq = {};
  for (const c of s) freq[c] = (freq[c] || 0) + 1;
  let h = 0;
  for (const k in freq) {
    const p = freq[k] / s.length;
    h -= p * Math.log2(p);
  }
  return h;
}

function entropyCandidate(value) {
  if (value.length < 16) return false;
  if (!/[0-9]/.test(value) || !/[A-Za-z]/.test(value)) return false;
  if (PLACEHOLDER.test(value)) return false;
  return shannonEntropy(value) >= ENTROPY_THRESHOLD;
}

function scan(text) {
  const matches = [];
  if (typeof text !== "string" || text.length === 0) return { matches };
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    if (line.indexOf(ALLOW_MARKER) !== -1) continue;
    if (line.length > MAX_LINE_LENGTH) line = line.slice(0, MAX_LINE_LENGTH);
    for (const { rule, re } of RULES) {
      const g = new RegExp(re.source, re.flags.indexOf("g") === -1 ? re.flags + "g" : re.flags);
      for (const m of line.matchAll(g)) {
        if (!PLACEHOLDER.test(m[0])) {
          matches.push({ rule, line: i + 1 });
          break;
        }
      }
    }
    const eg = new RegExp(ENTROPY_ASSIGN.source, ENTROPY_ASSIGN.flags + "g");
    for (const em of line.matchAll(eg)) {
      if (entropyCandidate(em[1] !== undefined ? em[1] : em[2])) {
        matches.push({ rule: "high-entropy-assignment", line: i + 1 });
        break;
      }
    }
  }
  return { matches };
}

if (require.main === module) {
  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (d) => (input += d));
  process.stdin.on("end", () => {
    process.stdout.write(JSON.stringify(scan(input)));
  });
} else {
  module.exports = { scan, ALLOW_MARKER };
}
