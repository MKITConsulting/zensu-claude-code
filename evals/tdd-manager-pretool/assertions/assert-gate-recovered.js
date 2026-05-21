module.exports = ({ output }) => {
  const txt = typeof output === "string" ? output : JSON.stringify(output);
  const fired = /TDD-Phase-Gate/.test(txt) && /permissionDecision\W+deny/.test(txt);
  const recovered = /RED .* — FAIL/.test(txt) && /GREEN — PASS/.test(txt);
  return {
    pass: fired && recovered,
    reason: `fired=${fired} recovered=${recovered}`
  };
};
