# Verify-Feature Network-Level Browser Fence — Specification

Status: proposed on 2026-11-18, not built. Nothing below is implemented, and §12 lists the
decisions the owner takes first. Until a build lands, the current behaviour is the one
[gates.md §Browser Consent Gate](gates.md#browser-consent-gate) and
[verify-feature.md](verify-feature.md) describe.

Every claim about the code was read from `4b10a44d`. Every measurement was made on 2026-11-17 or
2026-11-18 with `playwright-cli` 0.1.24 (playwright-core 1.66.0-alpha-1794252756000) driving
Google Chrome 157.0.8103.52 on macOS, headless, against loopback servers only, unless it says
otherwise. Chromium source was read from `main` on 2026-11-18: `net/docs/proxy.md`,
`net/base/host_mapping_rules.cc` and `net/dns/mapped_host_resolver.cc`. "Read" below means read
in source and not measured.

## 1. Problem

`/zensu:verify-feature` opens its browser with a run config that
`scripts/verify-browser-config.js` writes and the browser consent gate reads again at `open`
(`runConfigShape` in `hooks/lib/verify-consent-v1.js`). The config fences the browser to the
run's origins with `network.allowedOrigins`. `playwright-cli` turns that list into Playwright
routes: one that aborts every request and one per origin that lets it continue (read in the
0.1.24 bundle, `_setupRequestInterception`). Routes sit above the browser's network stack. They
see what Playwright's request interception sees and nothing else.

Two problems follow from that one cause.

**The fence has holes, and the list is longer than the docs say.** The docs name two exceptions:
a WebSocket connection and a server redirect the browser follows. Measured, these classes reach
a target outside the run config today (§6.1): a WebSocket from a page or a worker, every request
of a shared worker, a `fetch` or a navigation that follows a server redirect, and WebRTC over
UDP and TCP. A refused navigation still opens a TCP connection to its target, without sending a
request. The browser's own start-up traffic to a vendor host goes out too.

**The service-worker block makes real behaviour unverifiable.** The run config sets
`serviceWorkers: 'block'`, so that no worker answers a request where the routes cannot see it.
A criterion that depends on a service worker (a PWA update prompt, an offline cache, push,
background sync) can therefore never be observed. PR #639, merged as `4b10a44d`, names that
limit a *driver fence* and announces it at planning time and in the consent question. It changes
no fence. Measured with 0.1.24, the block is not what fences a service worker's HTTP requests
any more: with service workers allowed, the routes refuse them. Its WebSocket passes, like a
page's.

The durable remedy for both is a fence below every page and worker: in the network stack.

## 2. What it does

The run config stops relying on Playwright to watch requests and tells Chromium where it may
connect.

- **A proxy that cannot exist.** `--proxy-server=http://zensu-fence.invalid:9` sends every
  connection of the browser to a proxy whose name never resolves. Chromium has no fallback to a
  direct connection for one manually set proxy (read: its doc adds `direct://` to the list to
  get one), so the connection fails with `net::ERR_PROXY_CONNECTION_FAILED` (measured).
- **A bypass list that is the allowlist.** `--proxy-bypass-list=<-loopback>;<host:port>;…` names
  the host and port of every approved origin. Only those connect directly. `<-loopback>` removes
  Chromium's built-in direct path to `localhost`, loopback and link-local addresses, so a
  loopback port outside the list is refused like any other target.
- **A resolver that knows only the run's hosts.** `--host-resolver-rules` keeps today's pin per
  remote hostname and gains a catch-all, `MAP * ^NOTFOUND`, with one `EXCLUDE` per approved
  `localhost` or IP-literal host. No other name resolves, and no DNS query leaves for one.
- **The routes stay as a second layer** (decision 2 in §12). `network.allowedOrigins` keeps
  holding HTTP(S) requests to exact origins, and it stays the one origin list the gate reads.
- **Service workers run** (decision 1 in §12): the config says `serviceWorkers: 'allow'`.

```
page, frame, dedicated worker, shared worker, service worker, the browser's own requests
  │
  ▼  layer 2, kept: Playwright routes from network.allowedOrigins (exact origin, HTTP(S) only)
  ▼  layer 1, new:  Chromium proxy resolution, for every connection
       host:port in the bypass list ──► direct ──► resolver: pin, localhost or IP literal
       anything else ──► the fence proxy ──► its name never resolves ──► connection refused
```

## 3. Who it is for

- A user who verifies a progressive web app: the update prompt, the cache a worker fills, a
  page a worker controls.
- A user whose application opens WebSockets, shared workers or follows redirects: these get the
  fence that `fetch` has today, instead of none.
- An operator who reads the security account: one statement about every connection replaces
  "HTTP(S) only, with exceptions".
- An unattended run (`/zensu:autopilot` VALIDATE), which relies on the fence and not on a person
  watching the browser.

## 4. Who it is NOT for

- An application whose pages need a target the run does not declare. That now includes a
  WebSocket endpoint on another port and the target of a server redirect, both of which pass
  silently today. Each is declared as an origin, like an API origin.
- A machine that reaches the target only through an HTTP proxy. Today's `--no-proxy-server`
  already refuses that path.
- Firefox and WebKit. The switches are Chromium switches, and the gate keeps refusing another
  `--browser`.
- WebRTC. It stays outside both layers (§6.7).
- A user's own `playwright-cli` sessions. The gate's scope stays `zensu-verify-*` sessions.
- The ports `zensu-codex`, `zensu-kiro` and `zensu-antigravity`, which are not included.

## 5. Success criteria

1. Every TCP connection class of §6.1 to a host and port outside the run config is refused
   before the target sees a connection: from a page, a frame, a dedicated, shared or service
   worker, as HTTP(S) or WebSocket, direct or behind a server redirect.
2. Approved origins work as today: an IPv4 or IPv6 literal, `localhost` on either address
   family, a pinned remote hostname. A WebSocket to an approved host and port works.
3. With decision 1 taken as recommended, a service worker registers and controls the page, and
   an updated worker script is found.
4. The helper and the gate share one derivation of the launch arguments. A run config whose
   arguments differ from that derivation in any byte is refused at `open`.
5. No DNS query carries a name that a page chose.
6. The two mixed pairings of an old and a new installation (§10) fail closed at `open`.
7. Every sentence listed in §9 is true after the change, and each structure check that pins one
   pins the new wording.
8. Every measurement §8 marks as blocking has passed and is recorded, with its versions, in
   `.claude/rules/browser-consent-gate.md`.

## 6. Design

### 6.1 Measured starting point

Method: one process serves approved listeners and unapproved sinks on loopback. A probe page
runs every check against its own path. A check counts as *reached* when a sink logged the
connection, whatever the page saw. The browser is opened through the real CLI on a session of
its own, with a file shaped like a run config. Hostnames are `.test` names that resolver rules
map to loopback, so no DNS query leaves for them. The probe is not in the repository; step 1 of
§7 adds it.

Columns: **today** is `--no-proxy-server`, routes and `serviceWorkers: 'block'`. **Workers
allowed** is today with `serviceWorkers: 'allow'`. **Network fence** is the shape of §6.2, with
routes and service workers allowed. **Fence alone** is that shape without
`network.allowedOrigins`. Both fence columns were run with either spelling of the resolver
token (§6.3), and the results agree wherever both were measured.

| Traffic to a target outside the run config | Today | Workers allowed | Network fence | Fence alone |
|---|---|---|---|---|
| Page `fetch`, image, `sendBeacon`, frame navigation (IPv4, `localhost`, IPv6, hostname) | refused | refused | refused | refused |
| Dedicated worker `fetch` | refused | refused | refused | refused |
| WebSocket from a page or a dedicated worker | reached | reached | refused | refused |
| WebSocket or `fetch` to a TLS port | reached: the sink logged TLS handshakes, not separated per request | not measured | refused | refused |
| Shared worker `fetch` and WebSocket | reached | reached | refused | refused |
| Service worker HTTP: start-up `fetch`, `importScripts`, a `fetch` on a message, a `fetch` in the fetch handler | no worker | refused | refused | refused |
| Service worker WebSocket | no worker | reached | refused | refused |
| `fetch` or frame navigation that follows a server redirect | reached | reached | refused | refused |
| `goto` to the target | exit 1, `net::ERR_BLOCKED_BY_CLIENT`; the sink still logged a TCP connection without a request | same | exit 1, `net::ERR_BLOCKED_BY_CLIENT`, no connection | exit 1, `net::ERR_PROXY_CONNECTION_FAILED`, no connection |
| `goto` to an approved URL that redirects to the target | followed: exit 0, `Page URL` on the target | followed | exit 1, `net::ERR_PROXY_CONNECTION_FAILED` | same |
| WebRTC, TURN over TCP | reached | reached | refused | refused |
| WebRTC, STUN over UDP | reached | reached | reached | reached |
| The browser's own start-up request (`www.gstatic.com`) | DNS queries sent and answered | same | sent to the fence proxy and failed; no DNS transaction in the run | same |

What kept working in every column: a `fetch` across approved origins (an IPv4 literal, an IPv6
literal, `localhost` served only on `127.0.0.1`, `localhost` served only on `[::1]`, a hostname
pinned to loopback), a WebSocket to an approved host and port, and navigation to each of them.
With service workers allowed, the worker registered, took control of the page, and its own
`fetch` and WebSocket to an approved origin worked. A hostname that only ends in an approved
hostname was refused in every column. Every refused check failed inside the probe's six-second
budget; none hung.

Three findings are new against the docs and against the first measurement of 2026-11-17:

- **Redirects leak for subresources too.** A `fetch` to an approved URL whose server redirects
  it reaches the redirect target today, not only a navigation.
- **WebRTC is a fourth unfenced class.** Page code can send UDP and open TCP connections to a
  host and port of its choice through a peer connection's server list. Routes do not see it.
- **A refused navigation still connects.** Today the browser opens a TCP connection to the
  target of a `goto` the routes refuse. No request is sent on it.

### 6.2 The run-config shape

Today (`buildConfig`):

```json
{
  "browser": {
    "isolated": true,
    "launchOptions": { "args": ["--no-proxy-server", "--host-resolver-rules=MAP app.example.com 93.184.216.34"] },
    "contextOptions": { "serviceWorkers": "block" }
  },
  "network": { "allowedOrigins": ["https://app.example.com", "http://localhost:9090"] },
  "outputDir": "<run dir>/browser"
}
```

Proposed, for the same origins:

```json
{
  "browser": {
    "isolated": true,
    "launchOptions": { "args": [
      "--proxy-server=http://zensu-fence.invalid:9",
      "--proxy-bypass-list=<-loopback>;app.example.com:443;localhost:9090",
      "--host-resolver-rules=MAP app.example.com 93.184.216.34,MAP * ^NOTFOUND,EXCLUDE localhost"
    ] },
    "contextOptions": { "serviceWorkers": "allow" }
  },
  "network": { "allowedOrigins": ["https://app.example.com", "http://localhost:9090"] },
  "outputDir": "<run dir>/browser"
}
```

Rules of the shape:

- **The key set does not move.** `browser`, `network`, `outputDir`; `isolated`, `launchOptions`,
  `contextOptions`; `args`; `serviceWorkers` and the optional `storageState`. What moves is the
  set of values the strict validator accepts, which is what makes the change `minor` (§10).
- **Exactly three launch arguments, in this order**: the proxy, the bypass list, the resolver
  rules. `--no-proxy-server` leaves the shape: the two proxy switches cannot both hold.
- **The arguments are derived, never free.** One function, `fenceArgs(origins, pins)` in
  `hooks/lib/verify-consent-v1.js`, returns the three strings. `buildConfig` calls it to write
  them. `runConfigShape` reads the pins out of the resolver argument, checks each as it does
  today (a public address, a host among the origins, no pin for `localhost` or an address
  literal, none twice), calls the same function and requires the arguments to equal its result.
  The writer and the judge keep one definition, as they do for the rest of the shape.
- **Raw arguments, not Playwright's `launchOptions.proxy`.** Read in the 0.1.24 bundle:
  Playwright's own translation of a `proxy.bypass` list drops `<-loopback>` as soon as the list
  names a loopback host, appends it last otherwise, and obeys the environment variable
  `PLAYWRIGHT_DISABLE_FORCED_CHROMIUM_PROXIED_LOOPBACK`. It cannot say "proxy loopback except
  these ports". The launcher appends the config's `args` after its own default switches and
  after any proxy switch of its own, so the raw arguments are what Chromium receives.
- **One proxy identifier, nothing after it.** A comma-separated list ending in `direct://` is
  how Chromium is given a fallback, so the argument is compared as one fixed string.
- **`serviceWorkers` is written, not left to a default**, so a later driver default cannot
  change it unseen.

### 6.3 Bypass list, resolver rules and `localhost`

Each approved origin yields one bypass entry and, depending on its host, one resolver rule:

| Approved origin | Bypass entry | Resolver rule |
|---|---|---|
| `http://127.0.0.1:4200` | `127.0.0.1:4200` | `EXCLUDE 127.0.0.1` |
| `http://[::1]:4200` | `[::1]:4200` | `EXCLUDE ::1` |
| `http://localhost:4200` | `localhost:4200` | `EXCLUDE localhost`, never a `MAP` |
| `https://app.example.com` | `app.example.com:443` | `MAP app.example.com <public address>` |
| `https://93.184.216.34` (a public literal) | `93.184.216.34:443` | `EXCLUDE 93.184.216.34` |

- **`<-loopback>` comes first, always**, also when the run names no loopback origin. Chromium
  evaluates the list from left to right (read), and the entries after it re-admit single
  loopback ports. Without it every loopback, link-local and unspecified address bypasses the
  proxy (read; measured for loopback on 2026-11-17).
- **The port is always written**, the scheme's default included. An entry without a port would
  admit every port of that host.
- **No scheme.** An entry matches any scheme on that host and port (read), so the application's
  own WebSocket on an approved port works (measured). Layer 1 therefore fences by host and
  port, while layer 2 and consent stay per origin. A scheme prefix restricts an entry to that
  scheme (read), so it would refuse `ws://` to an approved port and buy nothing: another scheme
  on the same port reaches the same listener.
- **Hostname entries match the URL's host as written**, before any resolution (read). The
  entry admits the name; the pin then decides the address. That is how the bypass list and the
  pins combine: neither replaces the other.
- **No address ranges.** A range rule matches only URLs that name an address literal (read), so
  it could never stand for a hostname, and the shape never writes one.
- **A hostname must not start with a dot.** The bypass grammar reads a leading dot as "every
  subdomain" (read), and today's exact-hostname rule (`isExactHost`) admits such a host because
  it holds no pattern character. The rule gains that case, for the floor and the shape alike.
- **`localhost` keeps no pin.** The rule of `.claude/rules/browser-consent-gate.md` stands: the
  browser resolves the name itself to `[::1]` and `127.0.0.1`, and a `MAP` rule carries one
  address. What changes is that the catch-all would swallow the name, so an approved
  `localhost` gets an `EXCLUDE`, which leaves it to the browser (measured: without it both
  `localhost` listeners failed with `net::ERR_NAME_NOT_RESOLVED`, with it both families
  answered). A run with no `localhost` origin writes no exclusion, and the name then fails.
- **The catch-all also swallows address literals.** Measured: with `MAP * ~NOTFOUND` and no
  exclusion, the page on `127.0.0.1` failed with `net::ERR_NAME_NOT_RESOLVED`. So every approved
  literal host gets its `EXCLUDE`, an IPv6 literal without brackets (measured: `EXCLUDE ::1`).
- **Rule order.** Pins first, in the order their hosts first appear in the origin list, then
  the catch-all, then the exclusions in that same order. Chromium takes the first matching `MAP`
  rule and checks exclusions for it regardless of position (read), so the order is fixed for
  the comparison in `runConfigShape`, not for Chromium.
- **`^NOTFOUND`, not `~NOTFOUND`.** Chromium `main` documents and compares `^NOTFOUND` only
  (read). Measured on Chrome 157, both spellings refuse, but they differ: with `^NOTFOUND` the
  resolver is never asked, while `~NOTFOUND` reaches it as a host named `~notfound`. A caret is
  not a valid character of a URL host and a tilde is, so the caret spelling also fails where a
  browser does not know it as a token.

### 6.4 The route layer stays as the second layer

Default: keep `network.allowedOrigins` and its routes.

- **It is the origin list.** The gate needs origins, with their scheme, for consent and policy.
  The bypass list holds hosts and ports only. Deriving the arguments from the one list keeps
  navigability and the fence in one place.
- **It covers a drift of layer 1.** The driver is user-supplied and its version is only partly
  fenced. A later Chrome that changes `<-loopback>`, the fallback rule or the resolver token
  would open layer 1 with every gate check green. The routes then still hold what they hold
  today.
- **It keeps today's guarantees where layer 1 is unmeasured.** Windows and the channels §8
  leaves open lose nothing against today.
- **It is exact about the scheme** for HTTP(S), which a host-and-port entry is not.
- **It keeps the familiar failure.** A page `fetch` or a `goto` to an undeclared origin still
  ends in `net::ERR_BLOCKED_BY_CLIENT`, the text the troubleshooting table keys on. What only
  layer 1 refuses (a WebSocket, a shared worker's request, a redirect target) ends in
  `net::ERR_PROXY_CONNECTION_FAILED`, and the table gains that row.

Cost: request interception stays on, exactly as today, and a refused request has one of two
error texts. Dropping the routes is the alternative of decision 2: one layer, one error text,
and a fence that rests on three Chromium switches alone.

### 6.5 Service workers

**What the block guarantees today.** No worker answers a page's request, so every request is one
the routes see. It is a script-level patch of `ServiceWorkerContainer.prototype.register`
(`.claude/rules/browser-consent-gate.md`): a registration resolves to `undefined`.

**What replaces it.** Layer 1 does not depend on which context sends a request. A worker's
connection is resolved against the same proxy configuration as a page's, so a worker cannot
reach a target a page cannot. Measured for a service worker's start-up `fetch`, `importScripts`,
a `fetch` on a message, a `fetch` inside its fetch handler and its WebSocket, with and without
the routes.

**What the gate adds.** `PLAYWRIGHT_DISABLE_SERVICE_WORKER_NETWORK` in the launch environment
detaches Playwright's request interception from service workers (read). With layer 1 it opens
nothing, but it would hollow layer 2, so `open` refuses a launch environment that sets it, as
it refuses a `PLAYWRIGHT_MCP_*` variable today.

**What changes for a verification.** A page under a worker's control can be answered from the
worker's cache. Each run starts with an empty profile, so the first load always comes from the
network, and what follows is the application's real behaviour. `rules/browser-verification.md`
gains one rule: when a scenario asserts fresh server content, say whether the response came from
the network.

**What stays unobservable.** The gated command set has no command that takes the browser
offline (`network-state-set` is denied), so an offline fallback and background sync cannot be
driven. A push message needs a push service outside the run config; whether a subscription
fails under the fence is unmeasured. §9 says how the driver-fence text treats them.

### 6.6 Gate changes

- `runConfigShape`: the argument rules of §6.2 and §6.3, the `serviceWorkers` value, the
  leading-dot rule, and fault texts that name the remedy for a config of the old shape: write
  the run config again with the run-config helper of this installation.
- `buildConfig` in the helper: calls `fenceArgs`.
- `ambientOverride`: also names `PLAYWRIGHT_DISABLE_SERVICE_WORKER_NETWORK` (§6.5).
- `REASONS.BROWSER_NOT_CHROMIUM` and `GLOBAL_BROWSER_NOT_CHROMIUM`: say that the fence, not only
  the pins, is made of Chromium switches.
- `CHROMIUM_BROWSERS`: unchanged, unless measurement M2 of §8 fails or is not made, in which
  case `chromium` leaves the list.
- Unchanged: the command allowlist, consent, the policy parser, the floor's address rules, the
  consent memory, the signed-in rules, the helper's output lines, and the three reads of the
  run config.

### 6.7 What stays open

- **WebRTC.** UDP is outside any proxy, and measured it reaches a target in every column. The
  one switch tried, `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`, changed nothing
  in the installed Chrome: the same UDP datagrams arrived and the same candidates were
  gathered. TCP through WebRTC is refused by layer 1. Closing UDP is a follow-up (§11).
- **Navigation between approved origins.** The browser still has one class of allowed target, so
  a page can navigate itself onto a network-only origin, and `go-back`, `go-forward`, `reload`
  and `tab-select` still name no URL. The `Page URL` rule stays, as prose.
- **Host and port, not origin, at layer 1.** Any scheme on an approved host and port passes it.
- **Three switches carry layer 1.** The version-drift gap now names them: the proxy switch, the
  bypass list with `<-loopback>`, and the resolver rules with their token.
- **A managed browser policy.** Whether a managed proxy policy outranks the switches is unread
  and unmeasured. The same question exists for `--no-proxy-server` today.
- **The shape is still all the gate judges.** A run config of the right shape written another
  way opens, as today, and the config is still read three times.
- **The browser's own traffic now fails.** Nothing a run needed broke in the probe. A feature
  under test that depends on a vendor service of the browser would.
- **The browser's own DNS probe.** A top-level navigation that ends in a name error makes Chrome
  query a fixed vendor name through DNS, outside the resolver rules. Measured once, in a control
  run that left an approved `localhost` without its exclusion. With the derived rules no
  approved host ends in a name error and a refused target ends in a proxy or client error, so
  the probe ran in no fenced column. It carries no page data.

## 7. Build steps, decisions, defaults

1. **The probe becomes a repository tool.** The probe behind §6.1 lived in a session scratchpad
   twice and was rebuilt once. Default: ship it under `tests/integration/` as a script a person
   runs, like the fixture recorder: its own session name, loopback servers only, a named skip
   where the CLI or a Chromium channel is missing, never part of `tests/run-all.sh`. The pin-bump
   procedure in `.claude/rules/browser-consent-gate.md` gains "run the probe" beside "re-record
   the fixture".
2. **The blocking measurements of §8 that need no build** (M1 to M4) run before any gate code
   changes. Decision: a failure stops the build and goes back to the owner; a failure of M2
   alone removes one channel instead.
3. **One derivation, then the shape.** `fenceArgs` and the new `runConfigShape` (§6.2, §6.3).
   Decision: a hard switch. The gate accepts the new shape only, because accepting both would
   let a hand-written config pick the weaker fence. Default sink: `zensu-fence.invalid`, a name
   in a reserved top-level domain that the catch-all also refuses, over a closed loopback port,
   where a listener could appear.
4. **The helper** writes the new shape through `fenceArgs`. Its flags and output lines stay.
5. **The gate's texts and the launch environment** (§6.6).
6. **Unit cases and structure pins**: the shape cases of
   `tests/structure/verify-consent-v1.test.js` and `verify-browser-config.test.js`, the checks
   §9 names, and the counts in `tests/profiles/unit-files.v1.json` when a case is added.
7. **Skill and doc text** (§9), in the commit that changes the helper, because `P10o` fails as
   soon as the helper stops writing `serviceWorkers: 'block'`. `skills/verify-feature/SKILL.md`
   sits on the shrink-only allowlist and pins lines: sentences are replaced by shorter or equal
   ones, never added.
8. **The rule file**: `.claude/rules/browser-consent-gate.md` gets the new fence paragraph, a
   dated measurement paragraph with versions, the widened version-drift list, and its version
   verdict.
9. **Release class and notes.** `minor`, chosen at release time. No manual version bump. An
   `### Upgrade notes` entry under `## [Unreleased]` says what a user meets: a WebSocket
   endpoint or redirect target outside the run must be declared, service workers now run, and
   a session that was open across the update keeps its old fence until it ends.
10. **The gated path, end to end** (M5, M6): the real helper and gate on a `zensu-verify`
    session against the probe's servers, a fixture application with a changing worker script,
    and the local live eval of `evals/verify-feature`, whose remote scenarios drive the new
    shape against a real host.

## 8. Measurements owed

"Probe" is the tool of step 1, on a session of its own. A probe run counts as passed when the
approved checks work and no sink logs a connection.

| # | Not measured yet | How to run it | Blocks the change |
|---|---|---|---|
| M1 | `https` and `wss` against a real remote host with a resolver pin | Probe with `https://example.com` approved (bypass `example.com:443`, a pin to the address the helper resolves) and `https://example.org` not approved, the hosts the live eval already uses. From the approved page, request the unapproved host over `https` and `wss` and a loopback sink. Passed: the approved page loads with its certificate, the unapproved requests fail, the sink logs nothing | yes |
| M2 | The bundled `chromium` channel, which ships a separate headless-shell binary | Probe with `--browser=chromium`, after `playwright-cli install-browser`, a download the user approves | yes, for keeping `chromium` in `CHROMIUM_BROWSERS` |
| M3 | Headed mode | Probe with `--headed`. It opens a visible window | yes: a visible manual login runs headed |
| M4 | Linux | Probe in a container or on a Linux host with 0.1.24 and a Chromium channel | yes: unattended runs live there |
| M5 | The gated path | After the build: the helper writes the config, the gate admits `open`, a `zensu-verify` session loads the probe page | yes |
| M6 | A worker update | A fixture application whose worker script changes between two loads. Passed: the new worker is found and the page's prompt appears | yes, for decision 1 as recommended |
| M7 | A service worker that stopped and started again | Probe: unregister and register again, then repeat the worker checks. An attached debugger may keep a worker alive, so plain idle expiry may never occur under the CLI; say which was observed | no: layer 1 does not depend on the worker's life cycle |
| M8 | Windows | Probe on Windows | no: it stays in "Windows is unverified end to end", and layer 2 keeps today's guarantees there |
| M9 | `msedge` and the prerelease Chrome channels | Probe with `--browser=<channel>` where installed | no: disclosed, as today |
| M10 | DNS hints on other platforms | The probe's net-log. On macOS no DNS transaction occurred in a fenced run with the full rule set, and a `dns-prefetch` hint left no event in any column. Repeat with M2 and M4 | no |
| M11 | A push subscription under the fence | Probe: subscribe from the worker and record the outcome | no: it only decides one sentence of §9 |
| M12 | A managed proxy policy | Read Chromium's precedence rules, then measure on a managed profile | no: disclosed, and not new |

Measured in this work and no longer owed: WebRTC over UDP and TCP, `https` and `wss` targets
outside the run config (a TLS sink on loopback), and the resolver catch-all with its exclusions.

## 9. Text that changes

Every site is named by its sentence, not its line. "→" gives what the sentence has to say after
the change; the wording is the build's.

**Sites that describe the fence.**

| File | Sentence today | After |
|---|---|---|
| `skills/verify-feature/SKILL.md`, Phase 0 | "an isolated browser, the run's origins as `network.allowedOrigins`, service workers blocked, artifacts inside the run directory" | → names the network fence; drops the block |
| same | "**Redirects are not filtered by the browser.** `network.allowedOrigins` blocks a direct navigation and every HTTP(S) subresource request outside the run config, but the browser follows a server redirect to another origin." | → a redirect to a target outside the run config now fails; the `Page URL` rule stays for network-only origins and as the second line. Pinned by `P4s` |
| `skills/verify-feature/rules/browser-verification.md` §1 | "the browser refuses every HTTP(S) request to an origin outside the run config; a WebSocket connection is not fenced by the run config, which is an open gap" | → every connection, with WebRTC as the named exception. Pinned by `P10n` |
| same, step 2 | "An origin outside the run config means a server redirect left the approved set" | → a navigating call that fails with a proxy error means the application left the run config; report PARTIAL with it |
| same, signed-in rule 7 | "**A redirect to a login page** or to an identity provider on another origin means the state did not sign in" | → adds the navigation that fails because the identity provider is outside the run config |
| `skills/autopilot/rules/config.md` | "The browser refuses every HTTP(S) request to an origin outside the run config — a WebSocket connection is not fenced by it, which is an open gap" and "A server redirect is NOT filtered by the browser" | → as above |
| same | "because the browser turns each allowed origin into a URL glob and would read `*`, `{` or `,` as" | → adds the leading dot of the bypass grammar |
| `docs/gates.md`, `open` bullet | "`--no-proxy-server` plus, for remote hosts, one `--host-resolver-rules` pin per hostname to a public address, service workers blocked" and "because the resolver pins and the proxy switch are Chromium switches" | → the three arguments of §6.2 |
| `docs/gates.md`, floor paragraph | "The browser itself refuses every HTTP(S) request to an origin outside `network.allowedOrigins`; it does NOT fence a WebSocket connection … Nor does it refuse a server redirect to another origin" | → the two layers and what each refuses |
| `docs/gates.md`, residuals | "The browser also follows a server redirect to another origin, a network-only one included" | → to another approved origin only |
| `docs/gates.md`, version drift | "`network.allowedOrigins`, `browser.isolated`, the `--host-resolver-rules` pins, `browser.contextOptions.serviceWorkers`" | → the new fence list. Pinned by `V49` |
| `docs/verify-feature.md`, "How the browser is fenced" | "restricts every HTTP(S) request to the run's origins (`network.allowedOrigins`) except a server redirect the browser follows — a WebSocket connection is not fenced by it, which is an open gap — blocks service workers" | → the network fence in one statement, WebRTC named |
| `docs/verify-feature.md` §0 | "the browser sends no HTTP(S) request to an origin outside the run config, except by following a server redirect (below). A WebSocket connection is not fenced by the run config, which is an open gap." and "And the browser follows a server redirect to another origin even though it refuses every other HTTP(S) request there" | → as above |
| `docs/verify-feature.md`, network-only limits | "The fence covers HTTP(S) only: page code can open a WebSocket connection to any origin, listed or not." | → to a listed host and port only |
| `docs/verify-feature.md`, recipe rules | "The browser requests nothing over HTTP(S) from an origin outside `allowedOrigins`, a followed server redirect aside" | → adds: a WebSocket endpoint on another port and a redirect target are declared too |
| `docs/verify-feature.md` §5 | the row "the page loads, but its API calls fail with `net::ERR_BLOCKED_BY_CLIENT`" and the row "PARTIAL; the scenario left the approved origins" | → a second error text, `net::ERR_PROXY_CONNECTION_FAILED`, for a WebSocket, a worker or a redirect; the redirect row describes a failed navigation |
| `docs/verify-feature.md` §6 and `.claude/rules/verify-auth-guard.md` | "a sibling host a redirect reaches" and "a sibling host a redirect lands on" | → an approved sibling host only |
| `docs/verify-feature-consent-spec.md`, opening | — | → one dated paragraph that points here; D12 and §11.3 stay as history |
| `.claude/rules/browser-consent-gate.md` | step 5 ("`--no-proxy-server` and `--host-resolver-rules` are Chromium switches"), "The run config is where the browser's own fences live", the `localhost` paragraph and its site list, "WebSockets are outside the browser fence for every origin", the known gaps on redirects and version drift | → the design of §6, a measurement paragraph, the verdict of §10 |
| `hooks/lib/verify-consent-v1.js` | the shape faults "the run config launch arguments must be --no-proxy-server and at most one resolver pin list" and "the run config must block service workers and set nothing else on the context" | → §6.6 |
| `CHANGELOG.md` | — | → the upgrade note of step 9 |

`docs/verify-feature-auth-state-spec.md` is not edited: its header already defers to the
operator docs.

**The driver-fence text of PR #639.** The category stays: a state the driver can never show,
whoever drives it. The service-worker block stops being its instance, at every site
`.claude/rules/acceptance-verification-gate.md` lists under "A driver fence is a cause of its
own":

- `skills/verify-feature/rules/acceptance-consent.md`: "Today there is one: the `browser`
  driver's run config blocks service workers…" and the parenthesis of the question rule.
- `skills/verify-feature/rules/drivers.md` §3: the bullet "A driver fence is never worked
  around."
- `skills/verify-feature/rules/browser-verification.md` §1: its last paragraph, which becomes
  the cache rule of §6.5.
- `skills/build/references/planning.md`, Phase 1.5 and step 4b.
- `skills/autopilot/rules/validate.md` and `templates/autopilot-spec.md`: the parenthesis "(the
  `browser` driver blocks service workers)". The cell value `driver fence` stays there and in
  `templates/zensu-plan.md`.
- `docs/configuration.md` (the `--verdict` row), `docs/gates.md` (two sentences),
  `docs/verify-feature.md` (the chain paragraph and "Blocking service workers has a cost to plan
  for").
- `.claude/rules/acceptance-verification-gate.md`, `.claude/rules/browser-consent-gate.md` and
  `.claude/rules/verify-feature-drivers.md`: the sentences that tie the text to
  `serviceWorkers: 'block'`.

Their pins move in the same commit: `P10o` and `P10p` in
`tests/structure/test-verify-feature-skill.sh`, `A0k`, `A0l` and `A0m` in
`tests/structure/test-acceptance-gate.sh`. `P10o` keeps a pin on the helper, now on the value it
writes after the change.

Default for what the text names instead: say what was measured. An update prompt, a filled
cache and a controlled page are observable. A push message is named as the instance only if M11
shows that the fence rules it out. An offline scenario is not a driver fence by the rule PR #639
wrote: it fails on a command the gate denies, and that rule gives a gate refusal no category.
The text says so in one sentence rather than naming a way around it.

**Tripwire.** `P10o` fails once the helper stops writing `serviceWorkers: 'block'`. That is by
design: it is what forces this list into the helper's commit.

## 10. Version and migration

**`minor`.** Walked against `.claude/rules/runtime-lineage.md`: the run-config validator is
strict, and the values it accepts change in both directions. An older gate refuses a config the
new helper writes, and the new gate refuses a config an older helper writes. The gate also
refuses more than before: a launch environment that sets one more variable, and a hostname with
a leading dot. No context-record or workflow-state field, no hook, no matcher, no config key and
no attestation moves. `main` already carries an unreleased change whose own verdict is `minor`
(#633), so the next release has that class either way.

**Migration for a running session.** Nothing stored migrates. A run config lives for one run:
the helper writes it at the start of every run, and no gate reads a config that outlived its
run.

- A session that was open across the update keeps the installation it started with, helper and
  gate together. It keeps today's fence until it ends, and nothing breaks.
- A new or resumed session runs the new pair.
- The two mixed pairings fail closed at `open`. A config from the new helper under an older
  gate is refused with that gate's shape fault, whose text cannot name the cause. A config from
  an older helper under the new gate, such as one left in a kept run directory, is refused with
  a fault that says to write it again with this installation's helper. The upgrade note names
  the remedy for both: start a new session.
- No dual acceptance. A gate that took both shapes would let a config written by hand choose
  the weaker one.

## 11. Out of scope

- **Closing WebRTC.** The candidates are an init script that removes the peer-connection
  constructors, or a profile preference written before launch. Each needs its own measurement
  and its own gate rule.
- **An offline command.** Admitting `network-state-set` would make an offline fallback and
  background sync observable. It is an allowlist change with its own review.
- **A consent-mode network-only class**, route-level rules, and the textual gaps of the gate.
- **A proxy for reaching the target.** The fence proxy is a sink, never a route.
- **Windows verification** and the ports.

## 12. Decisions for the owner

1. **What ships.**
   - **(a) Recommended: the network fence and the lifted service-worker block in one `minor`,**
     once the blocking measurements of §8 pass. It is the only option that ends both problems
     of §1 with one shape change. Cost: the largest single change; an application that
     registers a worker in the build under test behaves differently in every verify run from
     that release on (a cache filled on first load, a reload when a worker takes over); the
     text of PR #639 is rewritten once.
   - (b) The network fence now, the block stays, a second `minor` lifts it later. Cost: two
     shape changes and two releases, the limit of PR #639 for one more release, its text
     rewritten twice.
   - (c) The network fence, and service workers only where a recipe asks for them. Cost: a
     permanent switch, a shape with two values, and a verify browser that keeps differing from
     a user's by default.
   - (d) Neither. Cost: every class of §6.1 stays open, and worker-dependent behaviour stays
     unverifiable.
2. **Routes as a second layer.**
   - **(a) Recommended: keep them** (§6.4). Cost: request interception stays on as today, and a
     refused request has one of two error texts.
   - (b) Drop them. Cost: the fence rests on three Chromium switches alone, with nothing behind
     them on a platform or channel nobody measured.
3. **The delivery route for the build.**
   - **(a) Recommended: `/zensu:build`** (vanilla implementation, evidence audits, review
     chain) in a fresh session anchored in a worktree of this repository, with every review
     agent on Sonnet from the start, the configuration under which earlier reviews of this gate
     completed. Cost: the review rounds.
   - (b) `/zensu:autopilot`. Cost: an unattended run whose review stops halfway has nobody to
     pick another model.
   - (c) Direct implementation without the review chain. Cost: a security gate changed without
     the review that found defects in it before.

## 13. Proposed requirements

The build's plan takes these rows over, or replaces them. Each is a check a unit case or one
probe run answers.

| ID | Requirement |
|---|---|
| AC-001 | `fenceArgs` returns the three arguments of §6.2 for the origin kinds of §6.3: an IPv4 literal, an IPv6 literal, `localhost`, a pinned hostname, a default port. |
| AC-002 | `buildConfig` writes exactly those arguments and `serviceWorkers: 'allow'`, and `runConfigShape` accepts what it wrote. |
| AC-003 | `runConfigShape` refuses a config of the old shape, a fourth argument, a proxy list with a fallback, a bypass list without `<-loopback>` first, an entry without a port, an entry or rule that names no origin of the list, and a hostname with a leading dot, each with a fixed fault. |
| AC-004 | `open` on a `zensu-verify` session is denied when the launch environment sets `PLAYWRIGHT_DISABLE_SERVICE_WORKER_NETWORK`. |
| AC-005 | A probe run on the built shape passes: every approved check works and no sink logs a connection, WebRTC over UDP excepted. |
| AC-006 | On a fixture application with a changing worker script, a `zensu-verify` session observes the registered worker and the update. |
| AC-007 | Every sentence §9 lists reads as §9 says, and `P4s`, `P10n`, `P10o`, `P10p`, `V49`, `A0k`, `A0l` and `A0m` pin the new wording. |
| AC-008 | `.claude/rules/browser-consent-gate.md` records the measurements M1 to M6 with the versions they were made on. |
