# Selecting a Quality Bar

Read this reference when the user has not supplied a concrete bar, when the
current bar can be gamed, or when the evidence harness does not discriminate
meaningful improvements.

## Contents

- [Selection test](#selection-test)
- [Bar patterns by artifact](#bar-patterns-by-artifact)
- [Scout output](#scout-output)
- [Method sources](#method-sources)

## Selection test

Prefer a bar that is:

1. **Relevant** — predicts the outcome the user actually values.
2. **Inspectable** — can be observed from the real artifact.
3. **Reproducible** — yields comparable evidence across rounds.
4. **Sensitive** — changes when meaningful quality improves or regresses.
5. **Hard to game** — covers important dimensions and realistic scenarios.
6. **Lawful and ethical** — respects rights, provenance, privacy, and safety.
7. **Affordable** — fits the declared time, token, compute, and money budget.

Define the bar as a stack:

```text
Hard gates       Must never regress: correctness, safety, build, constraints
Outcome gate     The measurable pass condition
Reference bar    The concrete example or implementation to compare against
Holdouts         Scenarios not optimized during every builder pass
```

Label every dimension as either:

- `hard`: crossing the threshold is required for `BAR_MET`; or
- `directional`: guides improvement but may remain unbeaten.

A deliberately unreachable reference is legitimate — the original run compared a
browser game against real Call of Duty screenshots and never won. It kept the
loop from stopping at "pretty good for AI". Label it `directional` and never
report it as a pass.

## Bar patterns by artifact

### Websites and visual product work

- Use a small curated set of best-in-category references, not an aesthetic
  adjective.
- Capture fixed desktop and mobile viewports plus critical interaction states.
- Judge hierarchy, spacing, typography, coherence, responsive behavior,
  accessibility, loading, and the actual task flow.
- Compare real pixels or recordings side by side. Keep functional tests as hard
  gates, not as substitutes for visual judgment.

### Code, APIs, and backend systems

- Use acceptance and property tests, protocol or contract parity, a reference
  implementation, or a production-like workload.
- Measure realistic p50/p95/p99 latency, error behavior, recovery, resource use,
  and security properties where relevant.
- Include failure injection and regression tests for important edge cases.
- Treat coverage as evidence of exercised code, not as the quality bar by
  itself.

### Writing

- Use finished reference passages for clarity, structure, information density,
  or audience fit without asking for voice imitation.
- Blind the candidate and reference when feasible.
- Gate factual accuracy, source fidelity, argument coherence, redundancy, and
  readability separately.
- Inspect the final rendered text, not an outline or the author's explanation.

### Research and analysis

- Use primary-source coverage, an explicit claim-evidence table, contradiction
  handling, reproducibility, and uncertainty calibration.
- Hold out some questions or sources from the drafting phase to reduce
  overfitting.
- Require every decisive claim to trace to evidence; do not reward citation
  volume alone.

### Games, video, audio, and interactive media

- Use lawful reference clips or captures plus target-device playback.
- Inspect motion, timing, input feel, frame pacing, audio balance, transitions,
  and representative stress scenes.
- Stabilize clocks, seeds, capture settings, and frame budgets.
- Keep performance and functional behavior as hard gates while critics judge
  perceptual quality.

### Product and workflow design

- Use observable completion of critical user journeys, task success, error
  recovery, accessibility, and best-in-category interaction references.
- Compare recorded end-to-end flows rather than isolated static screens.
- Include destructive, empty, loading, error, and permission states.

## Scout output

When discovering a bar, return:

```text
Proposed bar:
Why this predicts the desired outcome:
Hard dimensions and thresholds:
Directional dimensions:
Reference artifacts or measurements:
Reproducible inspection protocol:
Known blind spots and holdouts:
Expected evaluation cost:
```

The scout packet carries the step-4 builder template's two mandatory lines verbatim —
the untrusted-data boundary and the authority bound. Copy them from
[SKILL.md](../SKILL.md) rather than rewriting them here; this paragraph was a fourth
hand-written spelling of one rule and every spelling is a place it can drift. A scout
goes looking at third-party material by definition, so it is the least safe spawn to
leave unbounded.

Reject a proposed bar if the agent can pass it without improving the outcome the
user cares about.

## Method sources

- [How to Run a Gauntlet Loop](https://somethingbig.ai/gauntlet-loop)
- [The Gauntlet Loop Prompt Generator](https://somethingbig.ai/gauntlet-loop/generator)
- [Claude of Duty prompt](https://github.com/mshumer/Claude-of-Duty/blob/main/prompt.md)
- [Claude of Duty repository and process notes](https://github.com/mshumer/Claude-of-Duty)
