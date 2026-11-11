# Partial criteria in chain mode

Read this when a `--chain` criterion comes out `partial`: this environment could observe it only
in part, because it needs credentials, an account, a non-loopback host, a signed build or a fact no
driver can see. No code change turns it, so it is never a fix step.

1. A criterion that the chain's plan lists in its `## Manual Acceptance` table with the user's
   consent needs no question: record it `partial` with the reason.
2. Otherwise ask ONE `AskUserQuestion` that names each such criterion and why it could not be
   observed, with these options in this order:
   - **Provide access now**: a visible manual login, a test account, or a service the user
     starts. Verify the criterion again once the user is done.
   - **Accept as partial**: record it `partial` with the reason and name it in your report as
     accepted by the user, so the calling stage adds its `## Manual Acceptance` row and closes the
     chain with `--accept-partial` for exactly those ids.
   - **Leave the chain open**: record it `partial` with the reason and name it in your report as
     left open.
3. Never offer, set or mention a way to switch the acceptance gate off.
