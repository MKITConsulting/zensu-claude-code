"use strict";

const fs = require("node:fs");
const path = require("node:path");

const CLAIM_MARKERS = Object.freeze([
  "IMPL completed — files:",
  "IMPL completed – files:",
  "IMPL completed - files:",
  "WIRED — files:",
  "WIRED – files:",
  "WIRED - files:",
  "WIRED (verified, no change)",
]);
const VERIFIED_MARKER = "WIRED (verified, no change)";
const VERDICT_HEADS = Object.freeze([
  "EDIT LANDED ",
  "EDIT NOT LANDED ",
  "EDIT LANDING AUDIT ",
  "PENDING PREDICATE ",
  "UNVERIFIED ",
  "RECEIPT REFUSED ",
  "CLAIM CORRECTED ",
  "CLAIM CORRECTION IGNORED ",
  "CLAIM RETRACTED ",
]);
const CORRECTION_HEAD = "CLAIM CORRECTED ";
const CORRECTION = /^CLAIM CORRECTED [—–-] (.+?) \(line ([1-9][0-9]{0,8})\):(.*)$/;
const NOT_CLAIMED = /^not claimed:(.*)$/;
const LABEL_TOKEN_BUDGET = 5;
const BRACE_MEMBER_BUDGET = 256;
const GLOB_MATCH_BUDGET = 500;
const GLOB_CHARS = /[*?]/;
const WRAPPED = /^(?:"[^"]*"|'[^']*'|`[^`]*`|\([^()]*\))$/;
const IGNORE_REASONS = Object.freeze([
  "malformed-line",
  "target-not-earlier",
  "target-not-a-claim",
  "label-mismatch",
  "nothing-to-correct",
  "malformed-entry",
  "not-a-candidate",
  "duplicate-entry",
  "incomplete",
  "superseded",
]);
const ROW_KINDS = Object.freeze(["G", "M", "P", "T", "W", "V", "R", "I", "N"]);

function entryOf(line) {
  let entry = String(line == null ? "" : line).replace(/^\s+/, "");
  if (entry.startsWith("[")) {
    const close = entry.indexOf("]");
    if (close > 0) entry = entry.slice(close + 1).replace(/^\s+/, "");
  }
  return entry;
}

function claimLine(line) {
  const entry = entryOf(line);
  if (VERDICT_HEADS.some((head) => entry.startsWith(head))) return null;
  let marker = null;
  let at = -1;
  for (const candidate of CLAIM_MARKERS) {
    const found = entry.indexOf(candidate);
    if (found >= 0 && (at < 0 || found < at)) {
      marker = candidate;
      at = found;
    }
  }
  if (marker !== null) {
    const lead = entry.slice(0, at);
    const tokens = lead.split(/\s+/).filter((token) => token !== "");
    if (!/['"|]/.test(lead) && tokens.length <= LABEL_TOKEN_BUDGET) {
      const label = tokens.length ? tokens.join(" ") : "(none)";
      if (marker === VERIFIED_MARKER) return { kind: "verified", label };
      const after = entry.slice(at + marker.length);
      const bar = after.indexOf("|");
      return {
        kind: "files",
        label,
        text: bar < 0 ? after : after.slice(0, bar),
        tail: bar < 0 ? "" : after.slice(bar),
        head: String(line).slice(0, String(line).length - entry.length) + entry.slice(0, at + marker.length),
      };
    }
  }
  const step = entry.split(/\s/, 1)[0];
  if (step === "" || !entry.slice(step.length).replace(/^\s+/, "").startsWith("WIRED")) return null;
  return { kind: "wired", label: step };
}

function splitFiles(text) {
  const tokens = [];
  let braces = 0;
  let parens = 0;
  let current = "";
  for (const ch of String(text == null ? "" : text)) {
    if (ch === "{") braces += 1;
    else if (ch === "}") braces = Math.max(0, braces - 1);
    else if (ch === "(") parens += 1;
    else if (ch === ")") parens = Math.max(0, parens - 1);
    if (ch === "," && braces === 0 && parens === 0) {
      tokens.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  tokens.push(current);
  return tokens.map((token) => token.trim()).filter((token) => token !== "");
}

function matchingBrace(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i += 1) {
    if (text[i] === "{") depth += 1;
    else if (text[i] === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function topLevelParts(content) {
  const parts = [];
  let depth = 0;
  let current = "";
  for (const ch of content) {
    if (ch === "{") depth += 1;
    else if (ch === "}") depth -= 1;
    if (ch === "," && depth === 0) {
      parts.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  parts.push(current);
  return parts;
}

function rangeItems(content) {
  const numeric = /^(-?[0-9]+)\.\.(-?[0-9]+)$/.exec(content);
  if (numeric) {
    const from = Number(numeric[1]);
    const to = Number(numeric[2]);
    if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to)) return null;
    if (Math.abs(to - from) + 1 > BRACE_MEMBER_BUDGET) return null;
    const padded = /^-?0[0-9]/.test(numeric[1]) || /^-?0[0-9]/.test(numeric[2]);
    const width = padded ? Math.max(numeric[1].replace("-", "").length, numeric[2].replace("-", "").length) : 0;
    const step = from <= to ? 1 : -1;
    const items = [];
    for (let value = from; ; value += step) {
      items.push((value < 0 ? "-" : "") + String(Math.abs(value)).padStart(width, "0"));
      if (value === to) break;
    }
    return items;
  }
  const letters = /^([A-Za-z])\.\.([A-Za-z])$/.exec(content);
  if (letters) {
    const from = letters[1].charCodeAt(0);
    const to = letters[2].charCodeAt(0);
    const step = from <= to ? 1 : -1;
    const items = [];
    for (let code = from; ; code += step) {
      items.push(String.fromCharCode(code));
      if (code === to) break;
    }
    return items;
  }
  return undefined;
}

function expandInto(text, members, from) {
  for (let i = from; i < text.length; i += 1) {
    if (text[i] !== "{") continue;
    const close = matchingBrace(text, i);
    if (close < 0) break;
    const content = text.slice(i + 1, close);
    const parts = topLevelParts(content);
    let alternatives = null;
    if (parts.length > 1) {
      alternatives = parts;
    } else {
      const range = rangeItems(content);
      if (range === null) return false;
      if (range !== undefined) alternatives = range;
      else if (content.includes("..")) return false;
    }
    if (alternatives === null) continue;
    const prefix = text.slice(0, i);
    const suffix = text.slice(close + 1);
    for (const alternative of alternatives) {
      if (!expandInto(prefix + alternative + suffix, members, i)) return false;
      if (members.length > BRACE_MEMBER_BUDGET) return false;
    }
    return true;
  }
  members.push(text);
  return members.length <= BRACE_MEMBER_BUDGET;
}

function expandBraces(token) {
  const members = [];
  return expandInto(String(token == null ? "" : token), members, 0) ? members : null;
}

function tokenClass(token) {
  const text = String(token == null ? "" : token);
  if (/\s/.test(text) || WRAPPED.test(text)) return "prose";
  const members = expandBraces(text);
  if (members === null) return "pattern";
  if (members.length !== 1 || members[0] !== text) return "brace";
  return GLOB_CHARS.test(text) ? "glob" : "path";
}

function globRegex(pattern) {
  const segments = String(pattern).split("/");
  let source = "^";
  segments.forEach((segment, index) => {
    const last = index === segments.length - 1;
    if (segment === "**") {
      source += last ? ".*" : "(?:[^/]*/)*";
      return;
    }
    for (const ch of segment) {
      if (ch === "*") source += "[^/]*";
      else if (ch === "?") source += "[^/]";
      else source += ch.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
    }
    if (!last) source += "/";
  });
  return new RegExp(source + "$");
}

function stripDotSlash(value) {
  let text = String(value);
  while (text.startsWith("./")) text = text.slice(2);
  return text;
}

function relativePattern(pattern, ctx) {
  let text = stripDotSlash(pattern);
  if (text.startsWith("<project>/")) {
    if (!ctx.project) return null;
    text = path.join(ctx.project, text.slice("<project>/".length));
  }
  if (path.isAbsolute(text)) {
    for (const root of ctx.roots) {
      if (text.startsWith(root + "/")) return text.slice(root.length + 1);
    }
    return null;
  }
  return text;
}

function globMatches(pattern, ctx) {
  if (!ctx.listed) return null;
  const rel = relativePattern(pattern, ctx);
  if (rel === null) return [];
  const regex = globRegex(rel);
  const matches = [];
  for (const candidate of ctx.listed) {
    if (regex.test(candidate)) matches.push(candidate);
  }
  return matches.sort();
}

function patternAccepts(pattern, value, ctx) {
  const rel = relativePattern(pattern, ctx);
  const candidate = relativePattern(value, ctx);
  if (rel === null || candidate === null) return false;
  return globRegex(rel).test(candidate);
}

function trimWord(word) {
  return String(word).replace(/^[("'`]+/, "").replace(/[)"'`,;:.]+$/, "");
}

function knownPath(word, ctx) {
  const rel = stripDotSlash(word);
  if (ctx.changed && ctx.changed.has(rel)) return true;
  if (ctx.listed && ctx.listed.has(rel)) return true;
  try {
    if (path.isAbsolute(rel)) return fs.existsSync(rel);
    if (rel.startsWith("<project>/")) return Boolean(ctx.project) && fs.existsSync(path.join(ctx.project, rel.slice("<project>/".length)));
    return ctx.roots.length > 0 && fs.existsSync(path.join(ctx.roots[0], rel));
  } catch (_) {
    return false;
  }
}

function pathShaped(word, ctx) {
  if (word.includes("/")) return true;
  if (/[^.\s]\.[^.\s]/.test(word) || /^\.[^.\s/]/.test(word)) return true;
  return knownPath(word, ctx);
}

function normalizeOpaque(value) {
  return String(value).replace(/\s+/g, " ").trim();
}

function unitsOf(token, ctx) {
  const kind = tokenClass(token);
  if (kind === "path" || (ctx && knownPath(token, ctx))) return [{ type: "literal", value: token }];
  if (kind === "brace") {
    return expandBraces(token).map((member) => (GLOB_CHARS.test(member)
      ? { type: "glob", value: member }
      : { type: "literal", value: member }));
  }
  if (kind === "glob") return [{ type: "glob", value: token }];
  if (kind === "prose") return [{ type: "prose", value: token }];
  return [{ type: "pattern", value: token }];
}

function globRequirements(pattern, ctx) {
  const matches = globMatches(pattern, ctx);
  if (matches === null) return { requirements: [{ kind: "opaque", value: pattern }], accept: [pattern], unlisted: true };
  if (matches.length === 0) return { requirements: [{ kind: "glob-empty", value: pattern }], accept: [pattern] };
  if (matches.length > GLOB_MATCH_BUDGET) return { requirements: [{ kind: "glob-over", value: pattern }], accept: [pattern] };
  return { requirements: matches.map((value) => ({ kind: "path", value })), accept: [pattern] };
}

function proseCandidates(token, ctx) {
  const requirements = [];
  const accept = [];
  for (const raw of String(token).split(/\s+/)) {
    const word = trimWord(raw);
    if (word === "" || /^\.+$/.test(word) || stripDotSlash(word) === "" || !pathShaped(word, ctx)) continue;
    for (const unit of unitsOf(word, ctx)) {
      if (unit.type === "literal") {
        requirements.push({ kind: "path", value: stripDotSlash(unit.value) });
      } else if (unit.type === "glob") {
        const glob = globRequirements(unit.value, ctx);
        requirements.push(...glob.requirements);
        accept.push(...glob.accept);
      } else {
        requirements.push({ kind: "opaque", value: unit.value });
      }
    }
  }
  if (requirements.length === 0) requirements.push({ kind: "opaque", value: normalizeOpaque(token) });
  return { requirements: dedupeRequirements(requirements), accept };
}

function dedupeRequirements(requirements) {
  const seen = new Set();
  const kept = [];
  for (const requirement of requirements) {
    const key = requirement.kind + "\0" + requirement.value;
    if (seen.has(key)) continue;
    seen.add(key);
    kept.push(requirement);
  }
  return kept;
}

function unitRequirements(unit, ctx) {
  if (unit.type === "glob") return globRequirements(unit.value, ctx);
  if (unit.type === "prose") return proseCandidates(unit.value, ctx);
  if (unit.type === "pattern") return { requirements: [{ kind: "opaque", value: normalizeOpaque(unit.value) }], accept: [] };
  return { requirements: [], accept: [] };
}

function parseCorrection(line) {
  const entry = entryOf(line);
  if (!entry.startsWith(CORRECTION_HEAD)) return null;
  const match = CORRECTION.exec(entry);
  if (!match) return { ok: false, reason: "malformed-line" };
  const label = match[1].trim();
  const target = Number(match[2]);
  const body = match[3];
  const bar = body.indexOf("|");
  const listedText = bar < 0 ? body : body.slice(0, bar);
  const restText = bar < 0 ? "" : body.slice(bar + 1).trim();
  let retractedText = "";
  if (restText !== "") {
    const notClaimed = NOT_CLAIMED.exec(restText);
    if (!notClaimed) return { ok: false, reason: "malformed-line" };
    retractedText = notClaimed[1];
  }
  return {
    ok: true,
    label,
    target,
    listed: splitFiles(listedText).map(stripDotSlash),
    retracted: splitFiles(retractedText).map(normalizeOpaque),
  };
}

function lineUnits(claim, ctx) {
  const units = [];
  for (const token of splitFiles(claim.text)) {
    for (const unit of unitsOf(token, ctx)) units.push(unit);
  }
  return units;
}

function checkCorrection(correction, number, claim, ctx) {
  if (!correction.ok) return { ok: false, reason: correction.reason };
  if (correction.target >= number) return { ok: false, reason: "target-not-earlier" };
  if (!claim || claim.kind !== "files") return { ok: false, reason: "target-not-a-claim" };
  if (claim.label !== correction.label) return { ok: false, reason: "label-mismatch" };
  const correctable = lineUnits(claim, ctx).filter((unit) => unit.type !== "literal");
  if (correctable.length === 0) return { ok: false, reason: "nothing-to-correct" };
  let requirements = [];
  const accept = [];
  for (const unit of correctable) {
    const found = unitRequirements(unit, ctx);
    requirements.push(...found.requirements);
    accept.push(...found.accept);
  }
  requirements = dedupeRequirements(requirements);
  if (correction.listed.length + correction.retracted.length === 0) return { ok: false, reason: "incomplete" };
  const listed = new Set();
  for (const value of correction.listed) {
    if (tokenClass(value) !== "path") return { ok: false, reason: "malformed-entry" };
    if (listed.has(value)) return { ok: false, reason: "duplicate-entry" };
    const isPath = requirements.some((requirement) => requirement.kind === "path" && requirement.value === value);
    const accepted = accept.some((pattern) => patternAccepts(pattern, value, ctx));
    if (!isPath && !accepted) return { ok: false, reason: "not-a-candidate" };
    listed.add(value);
  }
  const retracted = new Set();
  for (const value of correction.retracted) {
    if (retracted.has(value) || listed.has(value)) return { ok: false, reason: "duplicate-entry" };
    if (!requirements.some((requirement) => normalizeOpaque(requirement.value) === value)) {
      return { ok: false, reason: "not-a-candidate" };
    }
    retracted.add(value);
  }
  for (const requirement of requirements) {
    const value = requirement.value;
    if (requirement.kind === "path" && !listed.has(value) && !retracted.has(value)) return { ok: false, reason: "incomplete" };
    if (requirement.kind === "opaque" && !retracted.has(normalizeOpaque(value))) return { ok: false, reason: "incomplete" };
    if (requirement.kind === "glob-over" && !retracted.has(value)) return { ok: false, reason: "incomplete" };
    if (requirement.kind === "glob-empty" && !retracted.has(value)
      && ![...listed].some((entry) => patternAccepts(value, entry, ctx))) return { ok: false, reason: "incomplete" };
  }
  return { ok: true, listed: [...listed], retracted: [...retracted] };
}

function graded(unit, number, label, ctx, rows) {
  if (unit.type === "literal") {
    rows.push(["G", number, label, unit.value]);
    return;
  }
  if (unit.type === "glob") {
    const matches = globMatches(unit.value, ctx);
    if (matches === null) {
      rows.push(["P", number, label, unit.value]);
      return;
    }
    if (matches.length === 0) {
      rows.push(["M", number, label, "glob-none", unit.value, "0"]);
      return;
    }
    if (matches.length > GLOB_MATCH_BUDGET) {
      rows.push(["M", number, label, "glob-over", unit.value, "0"]);
      return;
    }
    for (const match of matches) rows.push(["G", number, label, match]);
    return;
  }
  if (unit.type === "prose") {
    const found = proseCandidates(unit.value, ctx);
    const paths = found.requirements.filter((requirement) => requirement.kind === "path").map((requirement) => requirement.value);
    const complete = paths.length === found.requirements.length ? "1" : "0";
    rows.push(["M", number, label, "prose", unit.value, complete, ...paths]);
    return;
  }
  rows.push(["M", number, label, "pattern", unit.value, "0"]);
}

function readList(file) {
  if (!file) return null;
  const text = fs.readFileSync(file, "utf8");
  return new Set(text.split("\n").map((line) => line.replace(/\r$/, "")).filter((line) => line !== ""));
}

function context(options) {
  const roots = [];
  for (const root of options.roots || []) {
    if (!root) continue;
    roots.push(root);
    try {
      const real = fs.realpathSync(root);
      if (!roots.includes(real)) roots.push(real);
    } catch (_) {}
  }
  const changed = options.changed instanceof Set ? options.changed : readList(options.changed);
  let listed = options.paths instanceof Set ? options.paths : readList(options.paths);
  if (listed && changed) listed = new Set([...listed, ...changed]);
  return { roots, project: options.project || "", changed, listed };
}

function auditRows(text, options) {
  const ctx = context(options || {});
  const lines = String(text == null ? "" : text).split("\n").map((line) => line.replace(/\r$/, ""));
  const claims = new Map();
  const corrections = new Map();
  lines.forEach((line, index) => {
    const number = index + 1;
    const correction = parseCorrection(line);
    if (correction) {
      corrections.set(number, correction);
      return;
    }
    const claim = claimLine(line);
    if (claim) claims.set(number, claim);
  });
  if (!ctx.listed && options && options.onDemand) {
    for (const claim of claims.values()) {
      if (claim.kind === "files" && lineUnits(claim, ctx).some((unit) => unit.type === "glob"
        || (unit.type === "prose" && GLOB_CHARS.test(unit.value)))) return [["N"]];
    }
  }
  const outcome = new Map();
  const applied = new Map();
  for (const [number, correction] of corrections) {
    const claim = correction.ok ? claims.get(correction.target) : undefined;
    const verdict = checkCorrection(correction, number, claim, ctx);
    outcome.set(number, verdict);
    if (verdict.ok) {
      const earlier = applied.get(correction.target);
      if (earlier !== undefined) outcome.set(earlier, { ok: false, reason: "superseded" });
      applied.set(correction.target, number);
    }
  }
  const rows = [];
  lines.forEach((_, index) => {
    const number = index + 1;
    const claim = claims.get(number);
    if (claim) {
      if (claim.kind === "verified") rows.push(["V", number]);
      else if (claim.kind === "wired") rows.push(["W", number, claim.label]);
      else {
        const corrected = applied.has(number);
        for (const unit of lineUnits(claim, ctx)) {
          if (corrected && unit.type !== "literal") rows.push(["T", number, claim.label, unit.value]);
          else graded(unit, number, claim.label, ctx, rows);
        }
      }
    }
    const correction = corrections.get(number);
    if (correction) {
      const verdict = outcome.get(number);
      if (!verdict.ok) {
        rows.push(["I", number, verdict.reason]);
      } else {
        for (const value of verdict.listed) rows.push(["G", number, correction.label, value]);
        for (const value of verdict.retracted) rows.push(["R", number, correction.label, correction.target, value]);
      }
    }
  });
  return rows;
}

function sanitizeField(value) {
  return String(value).replace(/[\u0000-\u001f\u007f]/g, "\u007f");
}

function renderRows(rows) {
  return rows.map((row) => row.map(sanitizeField).join("\t")).join("\n") + (rows.length ? "\n" : "");
}

function existsAsWritten(token, roots) {
  const text = stripDotSlash(token);
  try {
    if (path.isAbsolute(text)) return fs.existsSync(text);
    return roots.some((root) => root && fs.existsSync(path.join(root, text)));
  } catch (_) {
    return false;
  }
}

function suggestedTokens(token) {
  const kind = tokenClass(token);
  if (kind === "brace") {
    const members = expandBraces(token);
    return members.every((member) => !GLOB_CHARS.test(member)) ? members : null;
  }
  if (kind === "prose") {
    const words = token.split(/\s+/).filter((word) => word !== "").map((word) => stripDotSlash(trimWord(word)));
    return words.length > 0 && words.every((word) => word !== "" && tokenClass(word) === "path" && (word.includes("/") || /[^.]\.[^.]/.test(word))) ? words : null;
  }
  return null;
}

function appendCheck(message, options) {
  const opts = options || {};
  const roots = (opts.roots || []).filter(Boolean);
  const entry = entryOf(message);
  if (entry.startsWith(CORRECTION_HEAD)) {
    const correction = parseCorrection(message);
    if (!correction.ok) return { ok: false, kind: "correction", reason: correction.reason };
    if (correction.listed.some((value) => tokenClass(value) !== "path")) return { ok: false, kind: "correction", reason: "malformed-entry" };
    if (correction.listed.length + correction.retracted.length === 0) return { ok: false, kind: "correction", reason: "incomplete" };
    if (Array.isArray(opts.logLines)) {
      if (correction.target > opts.logLines.length) return { ok: false, kind: "correction", reason: "target-not-earlier" };
      const claim = claimLine(opts.logLines[correction.target - 1]);
      if (!claim || claim.kind !== "files") return { ok: false, kind: "correction", reason: "target-not-a-claim" };
      if (claim.label !== correction.label) return { ok: false, kind: "correction", reason: "label-mismatch" };
      if (!lineUnits(claim, context({ roots })).some((unit) => unit.type !== "literal")) return { ok: false, kind: "correction", reason: "nothing-to-correct" };
    }
    return { ok: true };
  }
  const claim = claimLine(message);
  if (!claim || claim.kind !== "files") return { ok: true };
  const tokens = splitFiles(claim.text);
  const offending = [];
  for (const token of tokens) {
    const kind = tokenClass(token);
    if (kind === "path" || existsAsWritten(token, roots)) continue;
    offending.push({ kind, token });
  }
  if (offending.length === 0) return { ok: true };
  let fix = null;
  const rebuilt = [];
  let exact = true;
  for (const token of tokens) {
    if (!offending.some((item) => item.token === token)) {
      rebuilt.push(token);
      continue;
    }
    const replacement = suggestedTokens(token);
    if (!replacement) {
      exact = false;
      break;
    }
    rebuilt.push(...replacement);
  }
  if (exact && rebuilt.length > 0) {
    const tail = claim.tail ? " " + claim.tail.replace(/^\s*/, "") : "";
    fix = claim.head + " " + rebuilt.join(", ") + tail;
  }
  return { ok: false, kind: "claim", offending, fix };
}

function cliArgs(argv) {
  const options = { roots: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === "--on-demand") {
      options.onDemand = true;
      continue;
    }
    if (["--log", "--root", "--changed", "--paths", "--project", "--message-file"].includes(flag)) {
      if (value === undefined) throw new Error(flag + " requires a value");
      if (flag === "--root") options.roots.push(value);
      else options[flag.slice(2).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase())] = value;
      i += 1;
      continue;
    }
    throw new Error("unknown argument " + flag);
  }
  return options;
}

function main(argv) {
  const command = argv[0];
  let options;
  try {
    options = cliArgs(argv.slice(1));
  } catch (error) {
    process.stderr.write("edit-landing-claims-v1.js: " + error.message + "\n");
    return 2;
  }
  if (command === "rows") {
    if (!options.log) {
      process.stderr.write("edit-landing-claims-v1.js: rows requires --log\n");
      return 2;
    }
    let rows;
    try {
      rows = auditRows(fs.readFileSync(options.log, "utf8"), options);
    } catch (error) {
      process.stderr.write("edit-landing-claims-v1.js: " + (error && error.code ? error.code : "the run log could not be read") + "\n");
      return 2;
    }
    process.stdout.write(renderRows(rows));
    return 0;
  }
  if (command === "check-append") {
    let message;
    let logLines;
    try {
      message = options.messageFile ? fs.readFileSync(options.messageFile, "utf8").replace(/\n+$/, "") : "";
      if (options.log && fs.existsSync(options.log)) {
        const text = fs.readFileSync(options.log, "utf8");
        logLines = text.split("\n").map((line) => line.replace(/\r$/, ""));
        if (logLines.length && logLines[logLines.length - 1] === "") logLines.pop();
      }
    } catch (error) {
      process.stderr.write("edit-landing-claims-v1.js: " + (error && error.code ? error.code : "an input could not be read") + "\n");
      return 2;
    }
    const messageLines = message.split("\n");
    let verdict = { ok: true };
    for (const [index, messageLine] of messageLines.entries()) {
      verdict = appendCheck(messageLine, { roots: options.roots, logLines: logLines && logLines.concat(messageLines.slice(0, index)) });
      if (!verdict.ok) break;
    }
    if (verdict.ok) return 0;
    if (messageLines.length > 1) verdict.fix = null;
    const out = [];
    if (verdict.kind === "correction") out.push(["reason", verdict.reason]);
    else {
      for (const item of verdict.offending) out.push(["token", item.kind, item.token]);
      if (verdict.fix) out.push(["fix", verdict.fix]);
    }
    process.stdout.write(renderRows(out));
    return 1;
  }
  process.stderr.write("edit-landing-claims-v1.js: unknown command " + String(command) + "\n");
  return 2;
}

module.exports = {
  CLAIM_MARKERS,
  VERDICT_HEADS,
  LABEL_TOKEN_BUDGET,
  BRACE_MEMBER_BUDGET,
  GLOB_MATCH_BUDGET,
  IGNORE_REASONS,
  ROW_KINDS,
  entryOf,
  claimLine,
  splitFiles,
  expandBraces,
  tokenClass,
  globRegex,
  globMatches,
  proseCandidates,
  parseCorrection,
  checkCorrection,
  auditRows,
  renderRows,
  appendCheck,
  main,
};

if (require.main === module) process.exitCode = main(process.argv.slice(2));
