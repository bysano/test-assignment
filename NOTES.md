# Pulse — notes

## What this is

A Flutter watchlist over the provided SSE feed, built against the **default
chaotic mode**. ~3,400 lines of Dart and ~200 of Swift, 174 tests.

Run instructions are in [README.md](README.md). The native piece targets
**iOS**.

---

## The two decisions everything else follows from

### 1. Prices do not live in bloc state

`WatchlistBloc` owns the instrument list and the connection status. It never
sees a price. Ticks go from `FeedConnection` straight into a `QuoteStore`,
which exposes **one `ValueListenable` per symbol**; each row is a
`ValueListenableBuilder` inside a `RepaintBoundary`. The bloc wires the two
together once at startup and then stays out of the way.

This is a deliberate deviation from textbook bloc, so it deserves its
justification. The brief makes a full-list rebuild per tick a stated fail
condition, and the honest way to guarantee that is for a tick to have no path
to the list at all. The alternative — keeping a `Map<String, Quote>` in bloc
state and selecting per row with `BlocSelector` — also passes if conflated,
but it copies a 40-entry map and runs 40 selectors per emission to arrive at
the same place. Per-symbol listenables are the standard idiom in trading UIs
for exactly this reason.

Two tests pin the claim rather than asserting it in prose:

- `price_row_rebuild_test.dart` wraps every row in a `_BuildSpy` that counts
  rebuilds *from above*. A 220-tick burst across four symbols moves the
  counters **zero** times. If a tick ever started rebuilding the list, the row,
  or anything enclosing the price cell, that test goes red.
- `watchlist_bloc_test.dart` asserts 200 ticks produce **zero** bloc emissions.

Within a row the same discipline continues: only the price cell is inside the
`ValueListenableBuilder`, and the flash is an `AnimatedBuilder` whose subtree
is passed as `child`, so sixty animation frames repaint a coloured box without
rebuilding the price text once.

**Measured**, over 3,322 frames of the chaotic feed on an iPhone 17 Pro
simulator, in *debug* mode (asserts on, no AOT — profile is only faster):

```
build  p50 1.72ms   p95 4.50ms   p99 7.02ms
raster p50 0.88ms   p95 1.33ms   p99 1.58ms
frames over 16.7ms: 2   (both inside the first 300 frames, at startup)
```

Reproduce with `flutter run --debug --dart-define=PULSE_FRAME_STATS=true`.

### 2. Conflation at 100ms

`QuoteStore` keeps only the newest tick per symbol and flushes every 100ms.
The burst is ~220 ticks in ~100ms concentrated on the five `rate == 0`
instruments; conflation turns that into at most five notifications.

Why 100ms specifically:

- The flash animation runs 250ms. A faster cadence cannot be perceived — it
  would only cut flashes short.
- In calm conditions the busiest instruments tick ~8/s, so at 10Hz normal
  trading loses almost nothing. The rate only bites during the bursts it
  exists for.
- It bounds the worst case: 10 notifications/second/symbol regardless of what
  the feed does.

The flush timer is **one-shot**, armed by the first dirty tick, so a quiet feed
schedules no timers at all (asserted in `quote_store_test.dart`).

One consequence worth naming: flash direction is computed against the last
price the user *saw*, not the last tick received. A spike that arrived and was
superseded inside one window was never on screen, and flashing green for it
would report a move nobody witnessed.

---

## What "no data loss" can and cannot mean here

It cannot mean "every tick is displayed", and it shouldn't:

- **Conflation drops ticks on purpose.** Within a 100ms window only the newest
  price per symbol survives. That is a feature — the intermediate values were
  never renderable at 60fps anyway.
- **The server buffers 1000 events** (`feed_server.dart:119`). We reconnect
  with `Last-Event-ID` and the server replays what it still holds, but a stall
  of ~25s at burst rates can produce more than 1000 events. Past that the
  server sends `event: gap` and we have genuinely, irrecoverably missed data.
  No client can do better; the honest response is to say so, which the app
  does via the `gaps` counter.
- **Stale ticks are dropped, not shown.** An out-of-order tick is data we
  received and deliberately discarded.

What the app *does* guarantee: nothing displayed is older than what it
replaced (per-symbol timestamp guard), nothing is displayed twice (dedup by
event id), and the user is never shown a frozen price while the UI claims to
be live.

### Dedup: why an integer comparison is enough

The server assigns `++seq` at emit time (`feed_server.dart:115`), so ids are
strictly increasing on the wire even when the *timestamps inside them* are
not — `outOfOrder()` sends an old `ts` under a **fresh** id. `duplicate()`
replays stored text verbatim, original id and all. So `id <= maxSeen` is an
exact duplicate test in O(1), with no set of seen ids to bound.

That means the two hazards need two independent guards: dedup on the id
catches re-sends, and only a per-symbol `ts` comparison can catch replays.
Dedup runs first, so a duplicate can never flash a row twice. The cursor
advances on *receipt* rather than acceptance — otherwise reconnecting would
ask the server to replay ticks we had deliberately dropped.

---

## Resilience specifics

| Behaviour | Choice | Why |
|---|---|---|
| Backoff | exponential, equal jitter (half fixed, half random), 500ms → 15s cap | The fixed half means we never spin; the random half stops a fleet dropped by one restart from returning in lockstep. The cap is "don't wait forever" — a user walking back into coverage is never stranded. |
| Stall detection | warn at 6s of silence, force reconnect at 8s | Heartbeats are ~5s, so 6s of *total* silence is already anomalous. The server's stall suppresses heartbeats too, which is exactly what makes it detectable. Its stalls last ~25s, so waiting one out costs far more than resuming from `Last-Event-ID`. |
| Watchdog reset | any frame, comments included | During a quiet market a `: ping` is the only proof of life. |
| Token expiry | renew 10s early; one refresh-and-retry on 401, then backoff | The server checks expiry every second and connecting takes a moment, so handing over a token with 2s left invites an instant 401. The retry keeps the expected case (60s TTL dying mid-stream) off the backoff path; capping it at one stops a ping-pong with a server that keeps saying no. Owned by the interceptors — see below. |
| Offline | stop attempting entirely; resume immediately with backoff reset | Past failures predict nothing about a new network. |
| Malformed | counted and dropped, never fatal | The parser dispatches garbage as an event rather than swallowing it, so the layer above can count it. |

`NetworkStatus` is deliberately **tri-state**. `unknown` maps to *online*:
treating "we cannot tell" as offline would stop reconnection forever on any
platform whose channel is missing or broken, which is far worse than a few
doomed attempts.

A generation counter invalidates callbacks from superseded connection
attempts, so the paired `onError` + `onDone` of a dying socket cannot schedule
two reconnects.

### Where authentication lives

One token serves both transports, so exactly one component should know how to
attach and renew it. First cut had that policy written **twice** — once in
`WatchlistBloc`, once in `FeedConnection` — with the two already differing on
what to do after a second 401. Two copies of a security-adjacent rule is one
copy too many.

It now lives at the transport boundary, in the shape each transport allows:

| | |
|---|---|
| REST | `AuthenticatedClient extends http.BaseClient` — every request funnels through one `send()` |
| Stream | `AuthorizedSseTransport` decorating the raw `SseTransport` |

`http.BaseClient` *is* Dart's interceptor seam, so no new dependency was
needed; `dio` would have given the same thing with more machinery and a
rewrite of the HTTP layer. The stream cannot use that seam — it runs on
`dart:io` for its abort semantics — so it gets the same policy by decoration
instead. Same rule, two mechanisms, one definition.

Both take a `TokenSource`, not the repository, so neither transport depends on
the auth layer. What that bought:

- `FeedConnection` **lost its token dependency entirely** — no
  `FeedTokenProvider`, no `_onUnauthorized`, no `_authRetries` to reset. It is
  now purely backoff, stalls and reachability. An `UnauthorizedException`
  reaching it has already spent its refresh, so it is just another reason to
  back off.
- `WatchlistBloc` **lost its dependency on `AuthRepository` altogether**, and
  `InstrumentsApi.fetch()` no longer takes a token.
- `AuthApi` is deliberately left on the **raw** client. `/login` is how a token
  is obtained; routing it through the thing that refreshes tokens would
  recurse. The DI module says so at the wiring.

Two details that only matter in production:

**`refreshAfter(rejected)` takes the dead token** rather than nothing. If the
REST client and the stream 401 at the same moment — which they will, since one
token expiry kills both — the second one to arrive is handed the replacement
the first already obtained instead of triggering a second login. A burst of
401s costs one login.

**The retry is a copy, not a replay.** A `BaseRequest` is finalized when sent,
so re-sending the original silently drops the body; the client builds a fresh
`Request` with the same method, body and headers. Requests whose body has
already been consumed (`StreamedRequest`) are not retried at all — the 401 is
returned honestly rather than papered over. Retrying is safe for any method
including `POST`, because a 401 means the server rejected us before doing any
work.

### Session boundaries

`QuoteStore` and `FeedConnection` are both singletons, so they outlive any one
`WatchlistBloc`. That makes signing out and back in a real boundary that has
to be swept, and the rule is: **a reconnect keeps everything, a new session
keeps nothing.**

A reconnect must retain the resume cursor and the per-symbol timestamps — the
cursor is exactly what makes replay work. A new sign-in must not: it should
show current market state, and its counters should describe its own traffic.
So `FeedConnection.stop()` resets the pipeline, and the bloc clears the quote
store both when it closes *and* at the start of the next session. The second
of those is what actually guarantees the invariant, because it holds even if
the previous bloc was never closed cleanly.

Caught in review, not by me. Before the fix, a second sign-in went `Live` on
its first heartbeat while rows still showed the previous session's prices —
the frozen-prices-look-live failure, arriving through the one door I had not
checked. Four tests in `watchlist_bloc_test.dart` now cover it; all four fail
if either clear is removed.

Signing out mid-load is the same boundary from the other side, and it was
broken too. `_load()` awaits the network and then dispatches, so a sign-out
landing in between hit a disposed bloc: `add()` threw, the broad `catch`
swallowed that `StateError` as though it were a network fault, and answered it
with a *second* `add()` that nothing was left to catch. `_load()` now resolves
to one outcome and dispatches it exactly once, guarded, with the `try`
covering only the awaits — so a dispatch failure can no longer be mistaken for
a network failure. Five more tests cover it.

The guard is `!_closing && !isClosed` rather than `isClosed` alone.
`Bloc.close()` shuts its event controller first and only flips `isClosed`
three awaits later in `super.close()`, so a continuation resuming in between
would find `isClosed == false` and still throw. In fairness that window is
narrow and my tests never land in it — the flag is reasoned from bloc's
source, not driven by a red test — but the failure mode is an unhandled
exception, so it stays.

### Two bugs that only running against the real server found

**Bouncing the server froze the app while it still said "Live"** — the exact
failure this brief is about. A restarted server counts ids from 1, far below
our cursor, so every event was discarded as a duplicate: 1301 dupes and
climbing, zero accepted. My gap-based re-baseline could not save it, because
the server sends *no gap* in this case — its fresh buffer is non-empty, so
`lastId >= buffer.first - 1` passes, it takes the replay branch, finds nothing
above our cursor, and says nothing at all.

`TickPipeline` now also treats **20 consecutive duplicates with nothing
accepted between them** as a restarted sequence. A genuine duplicate run is
length one (the server re-sends exactly one buffered event per misbehaviour),
so twenty in a row is not a coincidence. Resequencing also clears the
per-symbol timestamps, since a server behind on wall-clock time would
otherwise have every tick rejected as stale — swapping one silent freeze for
another. Verified live: dupes stop at 20, one gap is reported, prices resume.

**A restored session logged the user out a minute after launch.** See below.

---

## The Keychain, and a tradeoff I want to flag

The `StoredSession` written to the Keychain holds the token, its expiry, **and
the credentials**. Storing a password deserves an explicit defence.

This server issues no refresh token and its tokens live 60 seconds. Storing
only the token means that on any cold start more than a minute after the last
one, the stored value is already dead — the feature is decorative. Worse, my
first version *did* restore such a session, and then discovered a minute later
that it had no way to renew it and dumped the user at a login screen they had
never seen. That is a worse experience than not restoring at all.

So the credentials go in the Keychain, which is precisely the kind of secret a
Keychain exists for — `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so
it neither syncs to iCloud nor restores onto another device. `restore()`
succeeds on the credentials rather than on token freshness; a live token is
adopted as a bonus, a dead one is left behind and the next `currentToken()`
mints a replacement.

**In a real system I would want a refresh token instead**, and would not store
the password. I would rather make that visible than quietly ship a
half-working "stay signed in".

---

## Structure

```
lib/feed/          the state machine, dedup, ordering   ← zero Flutter imports
lib/data/          transport, SSE parser, REST, models
lib/auth/          token lifecycle + AuthBloc
lib/watchlist/     QuoteStore + WatchlistBloc + UI
packages/pulse_native/   the plugin (Dart API + Swift)
```

`lib/feed/` imports no Flutter at all, not even `foundation`. It declares its
own `NetworkGate` port and an adapter in `lib/data/platform/` maps the plugin
onto it — which is what keeps the feed layer from depending on the plugin, and
lets the reconnect tests drive connectivity by hand.

DI is `get_it` + `injectable`, using explicit `@module` factory methods rather
than constructor annotations: several of these types take injectable clocks
and randoms with sensible defaults, and spelling the wiring out keeps that
visible instead of forcing a registration for `DateTime Function()`.

The plugin's public API says nothing about Keychain or `NWPathMonitor`.
`PulseNative` is the single place that knows which platforms exist. Adding
Android means one `pubspec` platform entry, Kotlin classes answering the same
channel names, and one branch — no Dart above that file changes.

---

## Tests — 174, and why these

Connection lifecycle runs on `fake_async` against a `FakeSseTransport`: no
server, no sockets, no real time. A full reconnect saga executes in
microseconds.

| File | n | Covers |
|---|---|---|
| `feed_connection_test.dart` | 26 | backoff schedule and reset, stall → warn → forced reconnect carrying `Last-Event-ID`, 401 → refresh → retry with no user action, offline suppression and immediate resume, malformed frames not killing the stream |
| `tick_pipeline_test.dart` | 23 | dedup, per-symbol ordering, cursor advancement, gap handling, the resequence backstop |
| `sse_parser_test.dart` | 21 | frame assembly across **six different chunk sizes** over the same input, CRLF split across chunks, multi-line data, heartbeats, garbage |
| `auth_repository_test.dart` | 19 | early renewal, concurrent-refresh collapsing, restore semantics, Keychain failures degrading to a login prompt |
| `quote_store_test.dart` | 13 | conflation ratios, no timers while idle, flash direction against the displayed price |
| `watchlist_bloc_test.dart` | 10 | startup, retry, 401-then-retry, status mapping, **zero emissions under 200 ticks** |
| `price_row_rebuild_test.dart` | 9 | **rebuild counts under a 220-tick burst**, per-instrument precision, flash behaviour |
| `authenticated_client_test.dart` | 8 | bearer attached, one refresh-and-retry, faithful replay of method/body/headers, credentials propagated not swallowed |
| `authorized_sse_transport_test.dart` | 7 | same policy on the stream, resume cursor preserved across the retry, no refresh for a non-auth failure |
| `api_test.dart`, `secure_token_store_test.dart`, `platform_network_gate_test.dart`, `tick_test.dart` | 29 | REST contracts, MethodChannel contract, tri-state reachability mapping, payload decoding |

The bias is toward things that are **hard to notice when broken**: an
off-by-one in a resume cursor, a duplicate that double-flashes, a stall that
reads as a quiet market, a rebuild count that quietly triples.

---

## Cut for time, and what I would do next

**Cut deliberately:**

- **The stretch detail screen** (session high/low + sparkline). Skipped by
  agreement to keep the core solid. It needs a bounded per-symbol ring buffer
  in `QuoteStore`, which is a small addition on the existing structure.
- **The Android half of the plugin.** One platform was the requirement; the
  Dart API is already platform-agnostic, so this is Kotlin plus one `pubspec`
  entry.
- **Integration tests against the real server.** The lifecycle is covered on
  virtual time, which is faster and deterministic; an end-to-end smoke test
  would still be worth having in CI.
- **Localisation and accessibility beyond basics.** The status badge has a
  `Semantics` label; a real trading app needs far more.

**Next, in order:**

1. Persist the last known prices so a cold start shows something (clearly
   marked stale) instead of forty em dashes.
2. Pre-emptively reconnect a few seconds before token expiry, so the
   expected 60s drop becomes invisible instead of merely brief.
3. A refresh-token flow, which removes the password-in-Keychain tradeoff.
4. Wire the frame-stats reporter into CI as a regression gate on p99.

## Known gaps

- **Reconnect countdown is static.** The banner shows the delay that was
  scheduled, not a live countdown. Honest, but less polished than ticking.
- **The stalled state is inferred, never confirmed.** 6s of silence is a
  heuristic. On a very slow network a healthy connection could in principle be
  declared stalled and cycled — the cost is one reconnect, and the resume
  cursor means no data loss, but the thresholds assume the ~5s heartbeat holds.
- **`InMemorySecureTokenStore` is not secure**, by name and by design. It is
  the non-iOS fallback so the app still runs and tests still pass; on iOS it is
  never reached.
- **No pull-to-refresh or manual reconnect button** on the watchlist. Retry
  exists only on the instrument-load failure screen; everywhere else recovery
  is automatic, which is the intent, but a user who wants to force it cannot.
- **Instruments are fetched once per session.** If the list changed
  server-side, the app would not notice until the next sign-in.

---

## How I used AI tools

This was built with Claude Code doing the bulk of the typing, driven
conversationally, and I want to be precise about the division of labour
because it is not "it wrote the app".

**Mine:** the architecture — the decision to keep prices out of bloc state and
what that buys, the port/adapter boundary that keeps `lib/feed/` Flutter-free,
the two-guard dedup/ordering split, the conflation rate and its justification,
the watchdog thresholds, and the choice of what to test.

**The model's:** most of the code, the test bodies once I had said what to
test, and the mechanical work — pubspec resolution, the Swift Keychain
boilerplate, DI wiring.

**Found by running it, not by writing it.** Three bugs are worth calling out
because they show where AI-assisted work needs a human at the wheel:

1. `_flash.forward(from: 1)` started the animation controller already at its
   upper bound, so it completed instantly and every row stayed permanently
   tinted. Compiles, passes analysis, looks plausible. Obvious in one
   screenshot.
2. The server-restart freeze described above — invisible to every unit test,
   because the fakes were written against my model of the server rather than
   the server. Only bouncing the real process found it.
3. A price-cell layout overflow that the simulator's font metrics hid and the
   widget tests exposed.

The pattern: the model is reliable at things with a specification, and
unreliable at things that need looking. Every non-obvious decision in the code
carries a comment explaining *why*, which is also how I kept the model from
quietly re-litigating a decision three files later.
