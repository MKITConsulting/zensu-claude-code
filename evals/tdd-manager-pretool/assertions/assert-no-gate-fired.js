module.exports = ({ output }) => {
  const txt = typeof output === "string" ? output : JSON.stringify(output);
  const denyHits = (txt.match(/permissionDecision\W+deny/g) || []).length;
  const gateHits = (txt.match(/TDD-Phase-Gate/g) || []).length;
  return {
    pass: denyHits === 0 && gateHits === 0,
    reason: `denyHits=${denyHits} gateHits=${gateHits}`
  };
};
