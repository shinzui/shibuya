---
id: 47
slug: add-configurable-cross-origin-access-to-the-metrics-server
title: "Add configurable cross-origin access to the metrics server"
kind: exec-plan
created_at: 2026-09-30T23:27:06Z
intention: "intention_01m3ta8zgtebmaz00g0snjzy5a"
master_plan: "docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:27:06Z
---


# Add configurable cross-origin access to the metrics server

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Today a web page served from any address other than the metrics server itself cannot read
a single byte from `shibuya-metrics`. Browsers enforce a rule called the same-origin policy:
a page loaded from one origin (a scheme, host, and port, such as `https://ops.example.com`)
may not read the response of an HTTP request to a different origin unless that other server
opts in through response headers. The opt-in mechanism is CORS, Cross-Origin Resource
Sharing. `shibuya-metrics` sets no CORS headers, so an operations page hosted anywhere but
on the metrics port is blocked from `/metrics`, `/health`, and every other route before the
response body is even parsed. That is the first item of
`docs/improvement-requests/harden-shibuya-metrics-for-browser-clients-cors-tests-and-ws-convention-alignment.md`
(IR-5), and it is the enabling change for every other feature in
`docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`: without it,
nothing the initiative adds is visible to a browser.

After this plan, a host application lists the origins its operations page is served from in
`MetricsServerConfig`, and the server answers those origins with the right headers on every
route, answers the browser's preflight `OPTIONS` probes, and applies the same allow list to
WebSocket upgrade requests. A server with no origins configured stays byte-for-byte
identical to today's server, which is provable because this plan first pins that
headerless behavior in a test. Every error body on the surface also gains a stable `code`
member beside its existing human-readable `error` message, so a browser client can switch on
outcomes without parsing prose. You can see the change working by starting the example
application, sending `curl -i -H 'Origin: https://ops.example.com' http://127.0.0.1:9090/metrics`
against a server configured with that origin, and reading `Access-Control-Allow-Origin:
https://ops.example.com` in the response.

This plan delivers only the cross-origin item of IR-5. The request's test-suite item was
delivered by `docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`,
and its WebSocket convention item and the closure of the request belong to
`docs/plans/48-align-the-metrics-websocket-protocol-with-bounded-delivery-and-in-band-errors.md`.


## Progress


- [ ] Milestone 1: Characterize the headerless server in a test, add `Shibuya.Metrics.Error` with `errorResponse`, and retrofit additive `code` members onto the existing 404 bodies.
- [ ] Milestone 2: Add `corsAllowedOrigins` to the configuration with validation, implement `Shibuya.Metrics.Cors.corsMiddleware`, wrap the HTTP side of `combinedApp`, and cover all four IR-5 cases in `CorsSpec`.
- [ ] Milestone 3: Validate the `Origin` header of WebSocket upgrade requests by the same allow list before a connection slot is acquired, with real loopback tests.
- [ ] Milestone 4: Update the Haddock protocol reference, the user guide, the capability record and its log, both changelogs, and record wire-load sanity numbers.


## Surprises & Discoveries


(None yet.)


## Decision Log


- Decision: Represent the policy as a plain list of allowed origins, `corsAllowedOrigins ::
  [Text]`, where the empty list means disabled, and reject the literal `*` at configuration
  time.
  Rationale: `docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
  requires cross-origin access to be off by default, explicit, and incapable of expressing
  the forbidden wildcard-with-credentials combination. The server never sends credentials
  headers, and refusing `*` makes a host name every origin it trusts.
  Date: 2026-09-30

- Decision: Hand-write the middleware in a new module rather than adding a CORS dependency.
  Rationale: The required behavior is small and specific: an exact allow list, preflight
  answers, header echo, and the same list applied to a WebSocket upgrade, which no WAI CORS
  package does. A dependency would add a version bound to maintain for a few dozen lines.
  Date: 2026-09-30

- Decision: Add the `code` member to the three existing 404 bodies in this plan, additively,
  and update the exact-JSON test expectations deliberately.
  Rationale: ADR-0007 gives every error body the shape `error` plus `code`; this plan owns
  the helper that renders it, so it retrofits the published bodies once instead of leaving
  two vintages of error object on the surface. The `error` and `processor` members and the
  404 status are unchanged, so the change is additive on the wire.
  Date: 2026-09-30

- Decision: A disallowed origin on a preflight gets `403` with an error body, while a
  disallowed origin on an ordinary request passes through with no CORS headers.
  Rationale: The browser blocks both cases identically, but a person debugging with `curl`
  learns nothing from a headerless `200`. The preflight is a browser-only probe, so answering
  it with a structured refusal costs nothing on the published routes.
  Date: 2026-09-30

- Decision: Reject a WebSocket upgrade whose `Origin` is not allowed before
  `websocketApp` acquires a connection slot, and leave upgrades without an `Origin` header
  untouched.
  Rationale: `docs/adr/0004-make-websocket-lifecycle-and-terminal-delivery-explicit.md`
  brackets the slot from one masked acquisition to release; a rejection that never touches
  the slot cannot leak one. Non-browser clients send no `Origin`, and the request asks for
  the upgrade to follow the same rule as HTTP, which for a request without an origin is to
  pass through.
  Date: 2026-09-30


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


`shibuya-metrics` is the optional package that exposes Shibuya's in-process processor
metrics over HTTP, Prometheus text, and a WebSocket. Its entry point for the network is
`combinedApp` in `shibuya-metrics/src/Shibuya/Metrics/Server.hs`, a WAI `Application`. WAI,
the Web Application Interface, is the standard Haskell interface between web servers such as
Warp and web applications: an `Application` is a function from a request and a response
callback to an `IO` action, and a `Middleware` is a function from one `Application` to
another, which is how behavior is wrapped around every request. `combinedApp` today reads:

```haskell
combinedApp config master wsState depChecks =
  if config.enableWebSocket
    then
      WaiWS.websocketsOr
        WS.defaultConnectionOptions
        (websocketApp config master wsState)
        fallback
    else fallback
  where
    fallback = httpApp config master depChecks
```

`httpApp` in the same file routes `/metrics/prometheus`, `/metrics`, `/metrics/<id>`,
`/health`, `/health/live`, and `/health/ready` by the `enablePrometheus` and `enableJSON`
flags, answers a plain HTTP request to `/ws` with a 404 whose body is
`{"error":"WebSocket endpoint - use ws:// protocol"}`, and answers anything else with
`{"error":"Not found"}` through the local helper `notFoundResponse`. The JSON routes live in
`shibuya-metrics/src/Shibuya/Metrics/JSON.hs`, whose `routeRequest` answers an unknown
processor with `{"error":"Processor not found","processor":"<id>"}` and an unknown path with
`{"error":"Not found"}`. There is no module for error bodies; each site builds its own
`object`. `validateConfig` in `Server.hs` is a chain of guards that `fail` with a message
naming the offending field, run by `startMetricsServerWithDeps` before Warp starts.

`MetricsServerConfig` in `shibuya-metrics/src/Shibuya/Metrics/Config.hs` has the fields
`host`, `port`, `enableJSON`, `enablePrometheus`, `enableWebSocket`, `wsPushIntervalUs`,
`wsMaxConnections`, `wsMaxSubscriptions`, `livenessTimeoutMicros`,
`dependencyTimeoutMicros`, and `stuckThreshold`, with `defaultConfig` binding to
`127.0.0.1` on port 9090. The package uses `NoFieldSelectors`, `OverloadedRecordDot`,
`OverloadedStrings`, `DuplicateRecordFields`, and `DerivingStrategies` as default
extensions, so fields are read as `config.host` and every deriving clause names a strategy.

`websocketApp` in `shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs` is a websockets
`ServerApp`, a function from a `PendingConnection` to `IO ()`. Its first action is `mask $
\restore -> atomically (acquireConnection wsState)`; a rejection for capacity or shutdown
happens after that acquisition and the slot is released in a `finally`. Nothing inspects the
upgrade request's headers. The websockets package in the current solver plan
(`dist-newstyle/cache/plan.json`) is 0.13.0.0, with wai-websockets 3.0.1.2, warp 3.4.16, wai
3.2.5, wai-extra 3.1.18, and http-types 0.12.6. The websockets package is not registered in
Mori; its source was read from the cabal package cache at
`~/.cabal/packages/hackage.haskell.org/websockets/0.13.0.0/websockets-0.13.0.0.tar.gz`. It
confirms the names this plan uses: `pendingRequest :: PendingConnection -> RequestHead`,
`requestHeaders :: RequestHead -> Headers` where `Headers` is a list of case-insensitive
name and value pairs, `rejectRequestWith :: PendingConnection -> RejectRequest -> IO ()`,
and `defaultRejectRequest` with the record fields `rejectCode` (400 by default),
`rejectMessage`, `rejectHeaders`, and `rejectBody`. The client side offers `runClientWith ::
String -> Int -> String -> ConnectionOptions -> Headers -> ClientApp a -> IO a`, whose fifth
argument is the list of extra request headers a test needs to send an `Origin`.
wai-websockets is registered under `yesodweb/wai` at
`/Users/shinzui/Keikaku/hub/haskell/wai-project`; its `websocketsOr` decides whether a request
is an upgrade and hands the `PendingConnection` to the `ServerApp` unchanged.

The test suite `shibuya-metrics-test` (`shibuya-metrics/shibuya-metrics.cabal`, modules under
`shibuya-metrics/test/Shibuya/Metrics/`, listed in `shibuya-metrics/test/Main.hs`) runs
in-process HTTP requests through `Network.Wai.Test` and real WebSocket clients against
`Warp.testWithApplication`. `TestSupport.hs` provides `withMaster`, `registerIdleProcessor`,
`getResponse app path`, and `assertGolden`. A golden fixture is a checked-in file holding
exact expected output; the two under `shibuya-metrics/test/golden/` cover processor JSON and
Prometheus text and contain no error bodies, so this plan does not touch them.
`ServerSpec.hs` asserts the three 404 bodies with exact `object` comparisons; those
expectations change deliberately in Milestone 1. `WebSocketSpec.hs` shows the loopback
pattern: `withServer config master $ \port -> WS.runClient "127.0.0.1" port "/ws" $ \conn ->
...`, and its "rejects WebSocket upgrades when disabled" example shows that a refused
upgrade surfaces to the client as an exception. The wire-load fixture
`shibuya-metrics/bench/WireLoad.hs`, executable `metrics-wire-load`, reads `SCENARIO`
(`health` or `websocket`), `ITERATIONS`, and `OUTPUT_JSON` from the environment and writes
one JSON report with p50, p95, and p99 latencies.

Three ADRs govern this work.
`docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
is the shared contract of the initiative: published shapes are frozen and grow additively,
JSON members are camelCase while codes are snake_case, every error body carries `error` and
`code`, cross-origin access is an explicit origin list that is disabled by default with no
wildcard and no credentials, the same list validates WebSocket upgrades when non-empty, and
the server remains unauthenticated behind a trusted network or reverse proxy.
`docs/adr/0004-make-websocket-lifecycle-and-terminal-delivery-explicit.md` owns the
connection-slot bracket that the origin guard must not disturb.
`docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` supplies the rule that a
test for new behavior is trusted only after it has been seen to fail, which Milestones 2 and
3 follow by running their specs before the code that satisfies them. No new ADR is written
here; the decisions above are applications of ADR-0007.

Two terms recur below. A preflight is the `OPTIONS` request a browser sends on its own,
before a cross-origin request that uses a method other than `GET`, `HEAD`, or `POST` with a
simple content type, or that carries non-simple headers; it carries
`Access-Control-Request-Method` and sometimes `Access-Control-Request-Headers`, and the
browser sends the real request only if the answer allows it. An origin is the exact
`scheme://host[:port]` string a browser puts in the `Origin` request header: lowercase
scheme and host, and a port only when it is not the scheme's default, so a page at
`https://ops.example.com/dashboard` sends `Origin: https://ops.example.com`.


## Plan of Work


Milestone 1 pins today's behavior and prepares the error helper without changing any
header. First, add examples to `shibuya-metrics/test/Shibuya/Metrics/ServerSpec.hs` (or a
new `CorsSpec.hs` created now and grown in Milestone 2) that build the default
`combinedApp`, send each published route twice, once with no `Origin` header and once with
`Origin: https://ops.example.com`, and assert that the two responses' `simpleHeaders` lists
are equal, that no header name starts with `access-control-` when compared
case-insensitively, and that no `Vary` header is present. Because these examples describe
the unconfigured server, they must keep passing after every later milestone; they are the
proof that "disabled" means unchanged. Then create
`shibuya-metrics/src/Shibuya/Metrics/Error.hs` exporting

```haskell
errorResponse :: Status -> Text -> Text -> [Pair] -> Response
```

whose result has status as given, header `Content-Type: application/json`, and a body that
is the JSON object `{"error": <message>, "code": <code>}` extended with the extra pairs, in
that order (message first, then code, then extras). Add the module to `exposed-modules` in
`shibuya-metrics/shibuya-metrics.cabal`. Replace `notFoundResponse` in `Server.hs` with two
calls: the unknown path becomes `errorResponse status404 "Not found" "not_found" []` and the
plain-HTTP `/ws` case becomes `errorResponse status404 "WebSocket endpoint - use ws://
protocol" "websocket_upgrade_required" []`. In `JSON.hs`, the unknown-processor branch
becomes `errorResponse status404 "Processor not found" "processor_not_found" ["processor" .=
procIdText]` and the fallthrough becomes `errorResponse status404 "Not found" "not_found" []`.
The `error` strings, the `processor` member, and the statuses are unchanged. Update the three
exact expectations in `ServerSpec.hs` to include the `code` member, and add one example that
decodes a body through `errorResponse` and checks the member order and content type.
Acceptance: `cabal test shibuya-metrics` passes with the new header-equality examples and
the updated 404 examples, and `cabal build all` succeeds.

Milestone 2 adds the policy for HTTP. In `Config.hs` add `corsAllowedOrigins :: ![Text]`
after `enableWebSocket`, defaulting to `[]`, with Haddock stating that the empty list
disables cross-origin support entirely, that entries are compared byte-for-byte against the
browser's `Origin` header and must be written exactly as browsers send them, and that the
wildcard is refused. In `validateConfig` add one guard per invalid entry: an entry is
invalid when it equals `*`, is empty, contains any whitespace character, ends with `/`, or
is not of the form `<scheme>://<host>` where the scheme is non-empty and consists of ASCII
letters, digits, `+`, `-`, or `.` starting with a letter, and the remainder after `://` is
non-empty and contains none of `/`, `?`, or `#`. The failure message names the field and the
entry, in the style of the existing guards.

Create `shibuya-metrics/src/Shibuya/Metrics/Cors.hs` exporting

```haskell
corsMiddleware :: [Text] -> Middleware
isAllowedOrigin :: [Text] -> ByteString -> Bool
```

`isAllowedOrigin` encodes each configured origin as UTF-8 and compares it to the header
value with plain byte equality; no normalization, no prefix matching. `corsMiddleware []` is
the identity middleware and returns the wrapped application untouched, so the disabled path
allocates nothing per request. For a non-empty list the middleware reads the `Origin`
request header. Absent: run the wrapped application unchanged. Present and allowed: if the
method is `OPTIONS` and `Access-Control-Request-Method` is present, respond `204` with no
body and exactly these headers, `Access-Control-Allow-Origin` set to the request's origin,
`Vary: Origin`, `Access-Control-Allow-Methods: GET, POST, OPTIONS`,
`Access-Control-Allow-Headers` set to the value of `Access-Control-Request-Headers` when
present and to `Content-Type` otherwise, and `Access-Control-Max-Age: 600`; for any other
request, run the wrapped application and append `Access-Control-Allow-Origin` (the
request's origin) and `Vary: Origin` to whatever response it produces, including 404 and 503
bodies, using `mapResponseHeaders`. Present and not allowed: a preflight gets
`errorResponse status403 "Origin not allowed" "origin_not_allowed" []` with no CORS headers;
any other request runs the wrapped application unchanged and gains no headers. The header
`Access-Control-Allow-Credentials` is never emitted anywhere. In `Server.hs` wrap the HTTP
side, `fallback = corsMiddleware config.corsAllowedOrigins (httpApp config master depChecks)`,
so that both the WebSocket-enabled and WebSocket-disabled branches serve the same HTTP
behavior. Add `Shibuya.Metrics.Cors` to `exposed-modules`.

Write `shibuya-metrics/test/Shibuya/Metrics/CorsSpec.hs`, add it to `other-modules` and
`test/Main.hs`, and give it these examples using `Network.Wai.Test` with
`defaultRequest {requestMethod = ..., requestHeaders = ...}` passed through `setPath`: with
`corsAllowedOrigins = ["https://ops.example.com"]`, a preflight `OPTIONS /metrics` from that
origin returns 204 with the five headers above and an empty body; a `GET /metrics` from that
origin returns 200 with `Access-Control-Allow-Origin: https://ops.example.com` and `Vary:
Origin` and still the published JSON body; a `GET /metrics/missing` from that origin returns
the published 404 body with the two headers appended; a preflight and a `GET` from
`https://evil.example.com` return no `Access-Control-*` header and no `Vary`, the preflight
being 403 with code `origin_not_allowed`; a preflight carrying
`Access-Control-Request-Headers: x-trace-id` gets that value echoed in
`Access-Control-Allow-Headers`; no response anywhere carries
`Access-Control-Allow-Credentials`; and `startMetricsServer` with `corsAllowedOrigins =
["*"]`, `[""]`, `["https://ops.example.com/"]`, and `["ops.example.com"]` each throws. Write
the spec before the middleware, run it, and record in Surprises & Discoveries which examples
failed against the unwrapped application, then implement until green. Acceptance: all of
`CorsSpec` passes, the Milestone 1 header-equality examples still pass, and `cabal test
shibuya-core` is unaffected.

Milestone 3 applies the same list to WebSocket upgrades. In `Cors.hs` add

```haskell
originGuard :: [Text] -> WS.ServerApp -> WS.ServerApp
```

which, for an empty list, returns the inner application unchanged and otherwise looks up
the case-insensitive `Origin` header in `WS.requestHeaders (WS.pendingRequest pending)`.
When the header is absent it calls the inner application; when present and allowed it calls
the inner application; when present and not allowed it calls `WS.rejectRequestWith pending
WS.defaultRejectRequest {rejectCode = 403, rejectMessage = "Forbidden", rejectHeaders =
[("Content-Type", "application/json")], rejectBody = <the same JSON as errorResponse would
render for "Origin not allowed" and code origin_not_allowed>}` and returns without ever
calling `websocketApp`, so `acquireConnection` never runs. In `Server.hs` wrap the upgrade
application: `WaiWS.websocketsOr WS.defaultConnectionOptions (originGuard
config.corsAllowedOrigins (websocketApp config master wsState)) fallback`. Add examples to
`WebSocketSpec.hs` that start a real server with `Warp.testWithApplication` and connect with
`WS.runClientWith "127.0.0.1" port "/ws" WS.defaultConnectionOptions [("Origin", origin)]`:
an allowed origin receives the initial `snapshot`; a disallowed origin throws (as the
existing "rejects WebSocket upgrades when disabled" example asserts, with `anyException`);
a client sending no `Origin` connects when the list is non-empty; any origin connects when
the list is empty; and after a rejected upgrade against a `WebSocketState` built with
`newWebSocketState 1`, `connectionCount` is zero within one second and a following allowed
client connects, which proves the slot was never taken. Run the examples before the guard
exists and record the failures. Acceptance: `cabal test shibuya-metrics` passes end to end
with the new examples.

Milestone 4 records the change everywhere a reader would look. Extend the Haddock header of
`shibuya-metrics/src/Shibuya/Metrics.hs` with a "Cross-origin access" paragraph naming the
field and the preflight behavior, and with the error codes `not_found`,
`processor_not_found`, `websocket_upgrade_required`, and `origin_not_allowed` beside the
routes that return them; re-export `corsMiddleware` and `errorResponse` from that module so
hosts that mount `combinedApp` inside their own server can reuse them. In
`docs/user/getting-started.md`, under "Monitoring & Metrics", add a "Cross-origin access"
subsection showing the configuration, stating that the default is disabled and headerless,
that the wildcard is refused, that the server still performs no authentication and expects a
trusted network or an authenticating reverse proxy, and that serving the page and the API
from one origin behind a reverse proxy is a supported deployment that needs no origin list
at all. (`docs/USAGE_GUIDE.md` is an index that points at that file.) In
`docs/capabilities/metrics-endpoints.md`, read `docs/capabilities/profile.dhall` and the
existing records first, then replace the limit that says cross-origin access is unsupported
with a sentence describing the configurable allow list and upgrade validation, add an
evidence entry of kind `test` for `shibuya-metrics/test/Shibuya/Metrics/CorsSpec.hs`, keep
the sentence that WebSocket convention alignment remains open, and append a dated entry to
`docs/capabilities/log.md` with `okf log add`. Add entries under an `Unreleased` heading in
`CHANGELOG.md` and `shibuya-metrics/CHANGELOG.md`: direct construction of
`MetricsServerConfig` must now supply `corsAllowedOrigins` (breaking for record
construction, as the 0.10.0.0 entries phrased it), the additive `code` member on error
bodies, and the new modules `Shibuya.Metrics.Cors` and `Shibuya.Metrics.Error`. Do not
choose a version number. Finally run the wire-load health scenario once on the commit before
Milestone 1 and once on the final commit, store both JSON reports under
`docs/audits/lifecycle-release/artifacts/ep47-cors-wire-load/`, and copy the p95 figures into
Surprises & Discoveries; the middleware adds one header lookup per request, so a p95 increase
above 10% is not expected and must be explained if it appears. Acceptance: `nix fmt` is
clean, `okf validate` passes for the capability bundle, and every command in Concrete Steps
exits zero.


## Concrete Steps


Run every command from the repository root,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, inside the Nix development shell
if `cabal` or `okf` is not on your path (`nix develop`).

Before Milestone 1, capture the sanity baseline:

```bash
mkdir -p docs/audits/lifecycle-release/artifacts/ep47-cors-wire-load
SCENARIO=health ITERATIONS=5000 \
  OUTPUT_JSON=docs/audits/lifecycle-release/artifacts/ep47-cors-wire-load/before.json \
  cabal run shibuya-metrics:metrics-wire-load
```

The executable prints its report and exits zero; the JSON file contains
`latencyP95Micros` among other members.

Build and test after each milestone:

```bash
cabal build all
cabal test shibuya-metrics --test-show-details=direct
cabal test shibuya-core
nix fmt
```

A passing metrics run ends with a line of the form `N examples, 0 failures` where `N` is
larger than the 48 examples the suite had before this plan; the core command runs three
suites and must also report zero failures. Before implementing Milestones 2 and 3, run only
the new spec to record the expected failures:

```bash
cabal test shibuya-metrics --test-show-details=direct --test-options='-m "cross-origin"'
```

Use the `describe` label you gave the new examples in place of `cross-origin`; the run must
report failures for the not-yet-implemented behavior and pass after implementation.

Milestone 3 headers for a manual check against a running example:

```bash
cabal run shibuya-example
curl -i -X OPTIONS -H 'Origin: https://ops.example.com' \
  -H 'Access-Control-Request-Method: GET' http://127.0.0.1:9090/metrics
```

With the example's configuration extended to `corsAllowedOrigins = ["https://ops.example.com"]`
the transcript contains `HTTP/1.1 204 No Content`, `Access-Control-Allow-Origin:
https://ops.example.com`, and `Vary: Origin`; against the unmodified example it contains a
`404` with `{"error":"Not found","code":"not_found"}` and no `Access-Control-` line.

Milestone 4 records:

```bash
okf log add docs/capabilities --kind Update \
  -m "CAP-10 gains configurable cross-origin access with WebSocket upgrade origin validation; CorsSpec added as evidence."
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
SCENARIO=health ITERATIONS=5000 \
  OUTPUT_JSON=docs/audits/lifecycle-release/artifacts/ep47-cors-wire-load/after.json \
  cabal run shibuya-metrics:metrics-wire-load
```

`okf validate` prints the concept count and no errors; a profile-recommended `reviews`
advisory on pre-existing records is inherited and not a failure of this plan.

Commit after each milestone with a conventional commit subject such as `feat(metrics): add
configurable cross-origin access` and this trailer block:

```text
MasterPlan: docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md
ExecPlan: docs/plans/47-add-configurable-cross-origin-access-to-the-metrics-server.md
Intention: intention_01m3ta8zgtebmaz00g0snjzy5a
```

The pre-commit hook runs treefmt; if it rewrites a file, `git add` it again and repeat the
commit.


## Validation and Acceptance


With `corsAllowedOrigins = []` (the default), every published route answers a request that
carries `Origin: https://ops.example.com` with exactly the headers it answers a request
without that header, no header name beginning with `Access-Control-` appears, and no
`Vary` header appears; the test proves this by comparing the two header lists for equality.
With `corsAllowedOrigins = ["https://ops.example.com"]`, an `OPTIONS /metrics` carrying
`Origin: https://ops.example.com` and `Access-Control-Request-Method: GET` returns status
204, an empty body, `Access-Control-Allow-Origin: https://ops.example.com`, `Vary: Origin`,
`Access-Control-Allow-Methods: GET, POST, OPTIONS`, `Access-Control-Allow-Headers:
Content-Type`, and `Access-Control-Max-Age: 600`; a `GET /metrics` from that origin returns
the published JSON body with the allow-origin and `Vary` headers appended; the same requests
from `https://evil.example.com` receive no CORS header, the preflight answering 403 with body
`{"error":"Origin not allowed","code":"origin_not_allowed"}`; and a WebSocket upgrade from
the allowed origin receives the initial `snapshot` frame while one from the disallowed
origin is refused with 403 and never counts against `wsMaxConnections`. No response in any
example carries `Access-Control-Allow-Credentials`. These are the four acceptance cases of
IR-5's first criterion, each an example in `CorsSpec.hs` or `WebSocketSpec.hs`.

The three existing 404 bodies now read `{"error":"Not found","code":"not_found"}`,
`{"error":"Processor not found","code":"processor_not_found","processor":"<id>"}`, and
`{"error":"WebSocket endpoint - use ws:// protocol","code":"websocket_upgrade_required"}`,
with unchanged statuses and content type. `startMetricsServer` refuses a configuration
containing `*`, an empty entry, an entry with a trailing slash, or an entry without a scheme,
with a message naming `corsAllowedOrigins`.

`cabal test shibuya-metrics` and `cabal test shibuya-core` exit zero with a nonzero example
count; `cabal build all`, `nix fmt`, and the capability bundle validation exit zero; the
example application answers the manual `curl` transcript above. The `before.json` and
`after.json` wire-load reports exist and their `latencyP95Micros` values are recorded in
this plan.


## Idempotence and Recovery


Every build, test, and validation command is safe to repeat. Writing a spec before its
implementation and observing it fail is safe because nothing is committed red: commit the
spec together with the code that makes it pass. `okf log add` appends a new dated entry on
every invocation, so run it once per change and check `docs/capabilities/log.md` before
re-running after a failed validation. The wire-load fixture writes only the file named in
`OUTPUT_JSON`; re-running overwrites that file, which is intended. If a milestone must be
abandoned, `git checkout -- <paths>` on the touched files restores the previous state; do not
reset the checkout or discard unrelated edits. Nothing here contacts a database, a broker, or
the network beyond loopback.


## Interfaces and Dependencies


New at the end of Milestone 1, in `shibuya-metrics/src/Shibuya/Metrics/Error.hs`:

```haskell
errorResponse :: Status -> Text -> Text -> [Pair] -> Response
```

with `Status` from `Network.HTTP.Types`, `Text` from `Data.Text`, `Pair` from `Data.Aeson`,
and `Response` from `Network.Wai`.

New at the end of Milestone 2, in `shibuya-metrics/src/Shibuya/Metrics/Config.hs` the field
`corsAllowedOrigins :: ![Text]` of `MetricsServerConfig` with default `[]`, and in
`shibuya-metrics/src/Shibuya/Metrics/Cors.hs`:

```haskell
corsMiddleware :: [Text] -> Middleware
isAllowedOrigin :: [Text] -> ByteString -> Bool
```

with `Middleware` from `Network.Wai` and `ByteString` the strict type from
`Data.ByteString`.

New at the end of Milestone 3, in the same module:

```haskell
originGuard :: [Text] -> WS.ServerApp -> WS.ServerApp
```

with `ServerApp` from `Network.WebSockets`.

Modules touched: `Shibuya.Metrics.Config`, `Shibuya.Metrics.Server`,
`Shibuya.Metrics.JSON`, `Shibuya.Metrics` (Haddock and re-exports), the new
`Shibuya.Metrics.Error` and `Shibuya.Metrics.Cors`, the cabal file, `test/Main.hs`, the new
`Shibuya.Metrics.CorsSpec`, `Shibuya.Metrics.ServerSpec`, and
`Shibuya.Metrics.WebSocketSpec`. No new package dependency is added; `wai`, `wai-websockets`,
`websockets`, `http-types`, `aeson`, `bytestring`, and `text` are already in the library's
`build-depends`, and `wai-extra` (for `Network.Wai.Test`) is already a test dependency.
`Shibuya.Metrics.WebSocket` and everything in `shibuya-core` are untouched.

Consumers of these interfaces:
`docs/plans/52-expose-gated-pause-and-resume-control-endpoints.md` uses `errorResponse` for
its `control_disabled`, `processor_not_found`, `processor_terminal`,
`processor_not_controllable`, and `method_not_allowed` bodies and relies on
`corsMiddleware` already allowing `POST` and answering the `OPTIONS` preflight that a
browser sends before a cross-origin `POST`; its endpoint milestone must not begin before this
plan's Milestone 1 helper exists.
`docs/plans/48-align-the-metrics-websocket-protocol-with-bounded-delivery-and-in-band-errors.md`
cites `corsAllowedOrigins` in its conformance mapping and closes IR-5 only after this plan is
Complete. This plan has no hard dependency and no soft dependency on any other child.
