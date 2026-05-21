const fs = require("fs");
const path = require("path");

const ALLOWED = {
  UNINITIALIZED: ["RED_WRITE"],
  RED_WRITE:     ["RED_RUN"],
  RED_RUN:       ["RED_FAIL", "RED_WRITE"],
  RED_FAIL:      ["IMPL", "RED_WRITE"],
  IMPL:          ["GREEN_RUN"],
  GREEN_RUN:     ["GREEN_PASS", "IMPL"],
  GREEN_PASS:    ["RED_WRITE", "REFACTOR"],
  REFACTOR:      ["RED_WRITE", "GREEN_PASS"],
};

module.exports = ({ context }) => {
  const wd = (context.providerOptions && context.providerOptions.working_dir) || ".";
  const stateDir = path.join(wd, ".zensu/state");
  if (!fs.existsSync(stateDir)) {
    return { pass: false, reason: `state dir missing: ${stateDir}` };
  }
  const files = fs.readdirSync(stateDir).filter((f) => f.startsWith("tdd-phase-") && f.endsWith(".json"));
  if (files.length === 0) return { pass: false, reason: "no phase state file present" };
  const latest = files
    .map((f) => ({ f, mtime: fs.statSync(path.join(stateDir, f)).mtime.getTime() }))
    .sort((a, b) => b.mtime - a.mtime)[0].f;
  const state = JSON.parse(fs.readFileSync(path.join(stateDir, latest), "utf8"));
  const hist = Array.isArray(state.history) ? state.history : [];

  let prev = "UNINITIALIZED";
  for (const entry of hist) {
    const next = entry.phase;
    if (!ALLOWED[prev] || !ALLOWED[prev].includes(next)) {
      if (next === "RED_WRITE" && prev === "GREEN_PASS") {
        prev = next;
        continue;
      }
      return { pass: false, reason: `illegal transition ${prev} -> ${next}` };
    }
    prev = next;
  }
  return { pass: true, reason: `${hist.length} transitions valid` };
};
