# Cross-Component Deep Journey Pass

Read this when Phase 5b starts: every component of a multi-component product is scanned and applied, so all features exist.

A single metadata pass over feature titles yields plausible-but-unverified journeys; real cross-component journeys must be **traced through the actual code and the existing E2E specs**, then cross-checked adversarially. Structure the pass as a fan-out → debate → synthesize workflow (the house pattern — drive it with the Workflow tool or a parallel `Agent` batch of read-only `Explore` lenses).

**A — Explore (parallel read-only lenses).** Each lens reads the whole repo set + the full feature catalog and proposes 2-5 candidate journeys. **Every step must be grounded in a REAL catalogued feature slug plus a concrete code/test evidence string** (a route/handler, a CLI verb, a UI nav target, an event/webhook, or a test that exercises the transition). Core lenses:
- **entry-points** — routes/controllers, CLI verbs, UI nav, MCP tools, webhooks → where journeys start + the real step-to-step transitions.
- **test-derived** (highest signal) — read the existing E2E specs + flow tests; they already encode real, team-validated user journeys. Reconstruct each onto catalogued slugs, citing the spec + test name.
- **data-flow** — trace writer→reader across components (e.g. agent heartbeat POST → backend ingest → frontend dashboard) for genuine sequential dependencies.
- **cross-component-bridge** — session hand-off, deep-links, shared auth/redirects → the seams that let a journey cross a component boundary.
- **persona lenses** — one per persona (new-user/admin, developer/API consumer, security-engineer/SRE) → that persona's end-to-end path.

**B — Consolidate + adversarially verify.** Merge/dedupe the candidates into a master list (collapse overlapping step-sets, keep distinct personas). Then, per master journey, spawn a **skeptic** that tries to REFUTE each step transition against the code: it must find evidence that in the running product an actor genuinely moves from step k to step k+1 (a nav link, a returned id consumed by the next call, an event, a test doing exactly this). **Trim unevidenced steps, or split the journey, rather than fabricate a link.** A completeness critic names the personas/paths/components left uncovered.

**C — Synthesize + create.** Emit the final evidenced journeys — carry each step's code/test citation into the step `--description` so the evidence lives in Zensu. That `--description` is plain text: Zensu does not render Markdown there, so do not use Markdown syntax. A citation can hold a `$` or an apostrophe, so pass it as `--description "$(cat "$f")"` from its own file, as Phase 5 step 5 shows. Present the table for user approval, then create via the Phase 5 step-5 mechanic (`journeys create` / `journeys step <id> --feature <UUID>` / `journeys health`). **Real catalogued slugs ONLY** — never invent one; if a wanted step has no catalogued feature, record it as a gap.

Discipline: ground every step in code, prefer ≥2 components per journey, and honestly leave a component uncovered (with a logged reason) rather than forcing an invented cross-component step. Journey-health scores reflect the underlying features' readiness (docs + security), not the wiring.
