# Pulse

A live market watchlist over an intentionally unreliable SSE feed.

Design decisions, tradeoffs and known gaps are in **[NOTES.md](NOTES.md)**.

## Requirements

| | |
|---|---|
| Flutter | **3.41.0** (stable) |
| Dart | **3.11.0** |
| Xcode | 26.0.1 (any recent version should do) |
| Native piece targets | **iOS** — Keychain + `NWPathMonitor` |

Only the iOS platform folder exists; the native piece is Swift. On any other
platform the app still runs, with an in-memory token store and an "unknown"
network — see `PulseNative` in `packages/pulse_native/lib/pulse_native.dart`.

## Run it

**1. Start the feed server** (from the repo root, chaotic mode — the one to
build against):

```bash
dart run "Finonex home assignment July 2026/feed_server.dart"
```

Add `--calm` to turn the misbehaviour off while poking at the UI.

**2. Run the app** on an iOS simulator:

```bash
flutter run
```

Sign in with `trader` / `password123` — the fields come pre-filled.

The base URL defaults to `http://localhost:8080`, which is what an iOS
simulator needs. On a **physical device**, point it at your Mac's LAN address:

```bash
flutter run --dart-define=PULSE_BASE_URL=http://192.168.1.20:8080
```

(`Info.plist` already carries `NSAllowsLocalNetworking` and a local-network
usage description, so ATS will not block cleartext to a local host.)

## Tests

```bash
flutter test
```

149 tests. Connection lifecycle — reconnect, backoff, stall detection, token
refresh, offline gating — runs on `fake_async` against a fake transport, so it
needs neither a server nor real time.

## Frame timings

The list must stay smooth during bursts, so that is measurable rather than
asserted:

```bash
flutter run --debug --dart-define=PULSE_FRAME_STATS=true
```

Prints build and raster percentiles every ~5s. Measured numbers are in
[NOTES.md](NOTES.md).

## What to look at first

| | |
|---|---|
| `lib/feed/feed_connection.dart` | reconnect, stall watchdog, token refresh, offline gate |
| `lib/feed/tick_pipeline.dart` | dedup and ordering — the correctness core |
| `lib/watchlist/quote_store.dart` | conflation and per-symbol listenables |
| `lib/watchlist/widgets/price_row.dart` | the only widget a tick can rebuild |
| `packages/pulse_native/` | the plugin: Dart API plus Swift |

## Regenerating DI

```bash
dart run build_runner build
```
