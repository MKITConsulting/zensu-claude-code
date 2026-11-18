# Verify-Feature Fence Probe

`probe.mjs` measures what the browser of `/zensu:verify-feature` can reach. A person runs it.
No suite and no CI job starts it, and `tests/run-all.sh` never does: it drives a real browser.

Run it when the pinned `playwright-cli` version moves, when a new Chrome channel is to be
admitted, and before a change to the fence arguments ships. The measurements it produced are
recorded, with their versions, in `.claude/rules/browser-consent-gate.md`. The design is in
`docs/verify-feature-network-fence-spec.md`.

## What it does

One Node process serves approved listeners and unapproved sinks on loopback, a probe page that
runs every check against its own path, and a small application whose service worker changes
between two loads. The browser is opened through the real `playwright-cli`, on a session name
the probe owns (`fenceprobe-…`, or the `zensu-verify-…` name the run-config helper prints in
gated mode). The probe closes that session and never touches another one.

A check counts as *reached* when a sink logged the connection, whatever the page saw.

```bash
node tests/integration/verify-fence/probe.mjs matrix
node tests/integration/verify-fence/probe.mjs matrix legacy routes-only
node tests/integration/verify-fence/probe.mjs remote
node tests/integration/verify-fence/probe.mjs gated
node tests/integration/verify-fence/probe.mjs pairing --released-root=<plugin root>
```

| Mode | What runs | Leaves loopback |
|---|---|---|
| `matrix` | The loopback checks under each named variant. `fence` (both layers) and `fence-alone` (the launch arguments without `network.allowedOrigins`) are judged; `routes-only` and `legacy` are reference columns that show what the routes hold without the network fence. `fence-alone` is the column that shows a drift of the launch arguments, because the routes hide it for HTTP(S) requests. | no in the judged columns; in the reference columns the browser's own start-up request goes out, as it does without the fence, and one WebSocket names an unmapped `.test` host, so one resolver lookup for a reserved name leaves the browser |
| `remote` | `https://example.com` approved with a resolver pin, `https://example.org` not approved, requested from the approved page over `https` and `wss` beside a loopback sink. | yes, to `example.com` only when the fence holds |
| `gated` | The run-config helper of this checkout writes the config, the consent gate of this checkout judges every call before it runs, and a `zensu-verify` session loads the probe page and the worker-update fixture. | no |
| `pairing` | The run config of this checkout under the gate of another installation, and the reverse. Starts no browser. | no |

Options: `--browser=<channel>`, `--headed`, `--out=<dir>`, `--budget=<ms>` and, for `matrix`
and `remote`, `--extra=<chromium switch>`.

- `--browser=chromium` runs the bundled Chrome for Testing build, headless or headed.
  `--browser=headless-shell` runs the bundled shell binary, which the CLI launches when a config
  names `chromium` without a channel. They are two binaries, so measure both.
- `--budget` is the time one page check may take, 6000 ms by default. A slow host can overrun
  it under request interception with nothing refused: the full build did so in a container,
  with and without the fence. Raise the budget there to tell a slow request from a refused one.

## What counts as passed

A judged run passes when every approved check works, no sink logs a connection, and the run's
net-log holds no resolver request for a name outside the run config, no resolver lookup at all
and no TCP connect attempt outside the run config. The probe prints the resolver event types
the browser wrote, so a platform whose resolver writes other events is read off the output and
not assumed: run a reference column first, where the lookup for the unmapped `.test` host shows
which events a real lookup writes there. A run whose net-log shows no resolver request at all
fails, because the count would then prove nothing.

WebRTC over UDP is outside the fence. The probe reports the datagrams the unapproved STUN sink
received and does not judge them.

A gated run writes no net-log: the run config admits exactly the fence arguments, so the
net-log checks belong to `matrix` and `remote`.

The last line is `fence-probe: PASS`, `fence-probe: FAIL` or `fence-probe: SKIP <reason>`. A
skip exits 0, so read the line and not only the exit status. The probe skips where
`playwright-cli` is not on `PATH`, where the browser channel cannot be launched, where
`example.com` does not resolve, and on Windows, where it has not been run.

## Where its output goes

Into a fresh directory under the operating system's temp directory, or into `--out`. Each
variant leaves its run config, a result file and, outside gated mode, a Chromium net-log. A
net-log holds the browser's own request URLs, so keep the directory out of a repository.
