# Evidence report conformance corpus, schema version 1

Each directory under `cases/` is one report bundle and its expected outcome:

- `manifest.json`: the manifest as a host wrote it. In `refuse-manifest-unreadable` it is a
  directory, kept by a `.gitkeep`, so a reader that cannot read the manifest as a file refuses it.
- `files/<sha256>.<ext>`: the evidence files the manifest names.
- `case.json`: `description`, `inScope` (the criterion ids the run must report on), an optional
  `limits` object whose one key, `maxManifestBytes`, lowers the 1 MiB manifest cap for this case
  alone, so a case proves the cap without a manifest of that size, and `expect`, which is either `{"rendering": "sha256:<hex>"}`,
  the SHA-256 digest of the UTF-8 bytes of the `index.html` the renderer writes for the bundle,
  or `{"refusal": [{"code", "at"}]}`, every fault the renderer must name, by its stable code and
  the manifest path it points at.

`hooks/lib/evidence-report-v1.js` reads a case through `renderDirectory(<case directory>,
{ inScope, limits })`, and `tests/structure/evidence-report-v1.test.js` runs every case and
refuses a `case.json` key outside these four and a `limits` key other than `maxManifestBytes`. A
port carries the core module unchanged and passes this corpus unchanged, reading each case with
the cap its `limits` names.

The module exports every fault code it can raise as `FAULT_CODES`. The corpus holds at least one
case for each, and the unit file fails when a code has no case or when the module raises a code
it does not export.

A rendering digest changes only with a deliberate change to the renderer, made in the same
commit as the new digest. A refusal names codes, never message text, so a reworded message
keeps every case green.
