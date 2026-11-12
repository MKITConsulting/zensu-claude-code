# Evidence report conformance corpus, schema version 1

Each directory under `cases/` is one report bundle and its expected outcome:

- `manifest.json`: the manifest as a host wrote it.
- `files/<sha256>.<ext>`: the evidence files the manifest names.
- `case.json`: `description`, `inScope` (the criterion ids the run must report on) and
  `expect`, which is either `{"rendering": "sha256:<hex>"}`, the SHA-256 digest of the UTF-8
  bytes of the `index.html` the renderer writes for the bundle, or `{"refusal": [{"code", "at"}]}`,
  every fault the renderer must name, by its stable code and the manifest path it points at.

`hooks/lib/evidence-report-v1.js` reads a case through `renderDirectory(<case directory>,
{ inScope })`, and `tests/structure/evidence-report-v1.test.js` runs every case. A port carries
the core module unchanged and passes this corpus unchanged.

A rendering digest changes only with a deliberate change to the renderer, made in the same
commit as the new digest. A refusal names codes, never message text, so a reworded message
keeps every case green.
