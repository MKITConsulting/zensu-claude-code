# Acceptance checks: bounded diagnostics and shared runs

Read this file before the first exit-code check of a `--chain` run. It applies to the drivers an
exit code decides (`api`, `cli`, `async`, `iac`, `custom`, `library`) and to a Maestro flow run
through the evidence runner. It changes nothing about browser consent, the UI evidence planes or
the credential-blind rules of `SKILL.md`.

## 1. What a check may print

The evidence runner prints the tail of a check's output into this conversation and into its
record. Its tail limit is no sanitizer, and neither is the run-log redaction. So a check prints
nothing raw: no application or network output, no request or response body, no header, no
exception message or stack trace, no environment value, no credential, token, cookie or signed
URL, and no personal data. Keep such output inside the check: capture a child process's stdout
and stderr in the check itself, assert on them there, and never forward the buffers. A check that
needs no output at all keeps the plain form, `curl -fsS -o /dev/null http://127.0.0.1:<port>/…`
or `<command> >/dev/null 2>&1`.

A check against a target you proved unauthenticated, synthetic and free of secrets may instead
print bounded diagnostics, so that a failure shows which assertion broke. Prove it by reading the
check, its fixture and its inputs; a loopback port alone proves nothing. Print only these fields,
each chosen before the check runs:

- the literal criterion id, such as `AC-001`;
- a fixed check name, such as `total-rounding`, never built from input or output;
- `result=pass`, `result=fail` or `result=unverified`;
- on a failure, a fixed category: `assertion`, `exit-code`, `timeout`, `launch` or `setup`;
- the numeric exit status of a child process, when one was observed.

Print at most 20 such lines of at most 160 characters each. When more checks fail, print a count
of the omitted ones instead of more lines:

```text
AC-001 check=total-rounding result=pass
AC-002 check=invalid-quantity result=fail category=assertion
AC-003 check=packaged-bin result=fail category=exit-code exit=2
```

The check catches every unexpected exception, prints only its fixed category, and exits non-zero.
A test framework's own failure output is raw output too, because assertion libraries print the
values they compared, so capture it as well. Never redact a log with a pattern and call the rest
safe. When you cannot guarantee these bounds, keep the plain discarding form and name the fixed
category in the evidence text instead.

A diagnostic never replaces an assertion. The check still inspects the real interface — its
output, its errors and its side effects where the criterion needs them — and exits 0 only when
every assertion it claims ran and passed. A setup or launch failure does not show that the
criterion fails: record `partial` with its category.

## 2. One observed run, several recorded criteria

One check may assert several criteria. Run it once and record each criterion it covers on its
own, citing the same `er1_…` id:

1. Before the run, name in the evidence matrix which assertions of the check prove which
   `AC-###`. A smoke check or an unrelated suite proves no criterion, and an exit-code check never
   proves a criterion that needs a UI evidence plane.
2. Build or package once for the current tree, writing generated files outside the project or to
   a gitignored path, then run the check once through `--evidence-run --scope acceptance`. Never
   cite a full-suite record, another session's run or an earlier build.
3. Right after a passing run, record every criterion it covers, one `--acceptance-record` call
   each, with the same `--evidence-run <er1 id>` and evidence that names that criterion's own
   assertions. Change no file in between, and never run the identical check again per criterion
   only to get another record id.
4. The recorder checks the run's session, scope, completion, unchanged tree and exit code against
   each verdict, never which criterion the check asserted: keeping that mapping honest is yours.
   After any edit the run backs nothing; run the check again.
5. A failed run backs no `pass`. Record `fail` only for a criterion whose own assertion showed the
   defect, and `partial` for one the failure left unproven. A separate targeted check may still
   prove a criterion the shared run did not reach.
6. Finish with `--acceptance-status`: every active criterion must pass on the current tree,
   whether its records share a run or not.
