module.exports = ({ output, context } = {}) => {
  const paths = (context && context.vars && context.vars.expected_paths) || [];
  if (!Array.isArray(paths) || paths.length === 0) {
    return {
      pass: false,
      score: 0,
      reason:
        'expected_paths var must be set in scenario vars (array of paths relative to working_dir)'
    };
  }

  const transcript = typeof output === 'string' ? output : String(output || '');
  const toolUseLineRe = /^\[tool_use:\s*(Write|Edit|MultiEdit|NotebookEdit)\]\s+input=(.*)$/i;
  const filePathRe = /"file_path"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/;
  const notebookPathRe = /"notebook_path"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"/;

  const writeTargets = [];
  for (const line of transcript.split(/\r?\n/)) {
    const m = line.match(toolUseLineRe);
    if (!m) continue;
    const tail = m[2];
    const fp = tail.match(filePathRe);
    if (fp) {
      writeTargets.push(fp[1]);
      continue;
    }
    const np = tail.match(notebookPathRe);
    if (np) {
      writeTargets.push(np[1]);
      continue;
    }
    writeTargets.push(tail);
  }

  const missing = paths.filter((p) => {
    return !writeTargets.some(
      (t) =>
        t === p ||
        t.endsWith('/' + p) ||
        t.endsWith('\\' + p) ||
        (p.includes('/') && t.endsWith(p))
    );
  });

  const pass = missing.length === 0;
  return {
    pass,
    score: pass ? 1 : 0,
    reason: pass
      ? `All ${paths.length} expected file path(s) found in tool_use Write/Edit/MultiEdit/NotebookEdit transcript: ${paths.join(', ')}`
      : `Transcript contains no Write/Edit/MultiEdit/NotebookEdit tool_use marker for: ${missing.join(', ')}`
  };
};
