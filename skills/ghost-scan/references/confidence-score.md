# Confidence Score Heuristic

Read this before you assign the first candidate's `confidenceScore` in Phase 2.

Confidence scores are heuristic estimates, not ML predictions. Use them to prioritize review, not as ground truth.

| Tier | Range | Criteria |
|------|-------|----------|
| High | >= 0.7 | Dedicated tests + clear module boundary (own package) |
| Medium | 0.4-0.7 | Either tests OR docs present, or clear boundary without tests |
| Low | < 0.4 | No tests, no docs, unclear boundary |

Building blocks:
- Dedicated test files: +0.3
- Documentation present: +0.2
- Clear directory boundary (own package/module, >= 3 source files): +0.3
- README mention or config reference: +0.2
- Single file / unclear boundary: -0.2
- Utils/helpers/infrastructure code: -0.3
