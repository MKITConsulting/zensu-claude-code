# Main-thread TDD review-chain self-check

This deterministic suite pins the current review-chain architecture:

- `/zensu:tdd` implements and fixes in the top-level interactive thread;
- neutral workers may return read-only analysis packets but never implement;
- `zensu:code-reviewer` completion routes findings back into that main thread;
- the Stop hook guarantees reviewer and self-review completion;
- the retired `tdd-manager` agent and its completion delegate remain absent;
- the RED → IMPL → GREEN log grammar still accepts and rejects the checked-in
  positive and negative fixtures.

Run it without Claude or API credentials:

```bash
bash evals/tdd-review-chain/run-self-check.sh
# equivalent compatibility entrypoint
bash evals/tdd-review-chain/run-eval.sh --self-check
```

`tests/run-all.sh` executes this self-check in the deterministic lane.
