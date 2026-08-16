import 'dart:async';
import 'dart:math';

import '../data/api/api_exception.dart';
import '../data/models/tick.dart';
import '../data/sse/authorized_sse_transport.dart';
import '../data/sse/sse_frame.dart';
import '../data/sse/sse_transport.dart';
import 'feed_config.dart';
import 'feed_status.dart';
import 'feed_update.dart';
import 'network_gate.dart';
import 'tick_pipeline.dart';

/// Raised internally when the stall watchdog kills a silent connection.
final class FeedStalledException implements Exception {
  const FeedStalledException();

  @override
  String toString() => 'FeedStalledException: no data or heartbeat';
}

/// Keeps a live SSE stream up in the face of everything the feed does to it.
///
/// Responsibilities: disconnects (reconnect with jittered exponential
/// backoff), silent stalls (watchdog that warns then forces a reconnect),
/// device offline (stop retrying rather than spin), and gaps (resume from
/// `Last-Event-ID`, report what was lost).
///
/// Notably *not* a responsibility: tokens. [AuthorizedStream] hands back a
/// stream that is already authorized and has already spent its one refresh, so
/// an [UnauthorizedException] arriving here is a genuine failure to back off
/// from rather than an expiry to paper over.
///
/// Pure Dart. No Flutter, no widgets, and every clock it uses is a [Timer] so
/// `fake_async` can run a whole reconnect saga in microseconds.
class FeedConnection {
  FeedConnection({
    required AuthorizedStream stream,
    NetworkGate network = const AlwaysOnlineGate(),
    FeedConfig config = const FeedConfig(),
    Random? random,
  }) : _stream = stream,
       _network = network,
       _config = config,
       _random = random ?? Random();

  final AuthorizedStream _stream;
  final NetworkGate _network;
  final FeedConfig _config;
  final Random _random;

  final TickPipeline _pipeline = TickPipeline();
  final StreamController<FeedStatus> _statuses =
      StreamController<FeedStatus>.broadcast();
  final StreamController<Tick> _ticks = StreamController<Tick>.broadcast();
  final StreamController<FeedGapDetected> _gaps =
      StreamController<FeedGapDetected>.broadcast();

  /// Cold path: drives the connection badge.
  Stream<FeedStatus> get statuses => _statuses.stream;

  /// Hot path: accepted ticks only, straight to the quote store.
  Stream<Tick> get ticks => _ticks.stream;

  /// Rare: the server could not replay everything we missed.
  Stream<FeedGapDetected> get gaps => _gaps.stream;

  FeedStats get stats => _pipeline.stats;

  FeedStatus get status => _status;
  FeedStatus _status = const FeedIdle();

  bool _running = false;
  SseSubscription? _subscription;
  StreamSubscription<SseFrame>? _frames;
  StreamSubscription<bool>? _networkChanges;
  Timer? _watchdog;
  Timer? _retry;

  /// Consecutive failed attempts; drives the backoff curve. Reset the moment a
  /// connection proves itself by delivering a frame.
  int _attempt = 0;

  /// Invalidates callbacks from superseded attempts. Bumped by [_teardown], so
  /// the paired onError+onDone of a dying socket can only be acted on once.
  int _generation = 0;

  void start() {
    if (_running) return;
    _running = true;
    _networkChanges = _network.changes.listen(_onNetworkChanged);
    unawaited(_connect());
  }

  /// Tears down the connection but leaves the object reusable.
  ///
  /// Synchronous on purpose. Callers need the state to be correct the instant
  /// they ask for it — waiting on socket cleanup would leave a window where a
  /// stopped feed still reported itself live.
  void stop() {
    if (!_running) return;
    _running = false;
    unawaited(_networkChanges?.cancel());
    _networkChanges = null;
    _teardown();
    _attempt = 0;
    // stop() ends a session, not a connection — reconnects never come through
    // here. So the resume cursor and the counters go too: the next sign-in
    // wants current market state, and a diagnostics line describing the
    // previous user's session would be reporting stale numbers as current.
    _pipeline.reset();
    _emit(const FeedIdle());
  }

  Future<void> dispose() async {
    stop();
    await _statuses.close();
    await _ticks.close();
    await _gaps.close();
  }

  // ---------------------------------------------------------------- connect

  Future<void> _connect() async {
    if (!_running) return;
    if (!_network.isOnline) {
      _emit(const FeedOffline());
      return; // a network change will restart us
    }

    _emit(FeedConnecting(_attempt));
    final generation = ++_generation;

    try {
      final subscription = await _stream.open(
        lastEventId: _pipeline.lastEventId,
      );
      // Stopped or superseded while the socket was opening.
      if (!_running || generation != _generation) {
        await subscription.cancel();
        return;
      }

      _subscription = subscription;
      _frames = subscription.frames.listen(
        (frame) {
          if (generation == _generation) _onFrame(frame);
        },
        onError: (Object error) {
          if (generation == _generation) _onDisconnected(error);
        },
        onDone: () {
          if (generation == _generation) _onDisconnected(null);
        },
      );
      _armWatchdog();
    } on InvalidCredentialsException {
      // No token can be obtained at all. Only the user can fix this.
      _fail('Sign-in was rejected. Please log in again.');
    } catch (error) {
      // Includes an UnauthorizedException that already survived a refresh —
      // by then it is just another reason the connection failed.
      if (generation == _generation) _scheduleReconnect(error);
    }
  }

  void _onFrame(SseFrame frame) {
    // Any frame is proof of life — a heartbeat comment counts exactly as much
    // as a tick, and during quiet markets it is the only thing arriving.
    _armWatchdog();

    if (_status is! FeedLive) {
      // The connection has demonstrably worked, so forget past failures.
      _attempt = 0;
      _emit(const FeedLive());
    }

    if (frame is! SseEvent) return;

    switch (_pipeline.process(frame)) {
      case TickAccepted(:final tick):
        _ticks.add(tick);
      case final FeedGapDetected gap:
        _gaps.add(gap);
      case TickRejected():
        break; // counted in stats; nothing reaches the screen
    }
  }

  void _onDisconnected(Object? error) {
    _teardown();
    _scheduleReconnect(error);
  }

  // --------------------------------------------------------------- watchdog

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_config.staleAfter, _onStale);
  }

  void _onStale() {
    // Still connected, but silent. Say so immediately: the user must not read
    // these prices as live while we wait to see if it recovers.
    _emit(const FeedStalled());
    final grace = _config.killAfter - _config.staleAfter;
    _watchdog = Timer(grace.isNegative ? Duration.zero : grace, () {
      _teardown();
      _scheduleReconnect(const FeedStalledException());
    });
  }

  // ------------------------------------------------------------ reconnecting

  void _scheduleReconnect(Object? cause) {
    if (!_running) return;
    if (_status is FeedFatal) return;
    if (!_network.isOnline) {
      _emit(const FeedOffline());
      return;
    }

    final delay = _backoffFor(_attempt);
    _attempt++;
    _emit(FeedReconnecting(attempt: _attempt, delay: delay));
    _retry?.cancel();
    _retry = Timer(delay, () => unawaited(_connect()));
  }

  /// Exponential backoff with equal jitter: half the delay is fixed, half is
  /// random. The fixed half guarantees we never spin; the random half stops a
  /// fleet of clients dropped by one server restart from returning in lockstep.
  Duration _backoffFor(int attempt) {
    final exponent = attempt.clamp(0, 20);
    final scaled = _config.backoffBase * (1 << exponent);
    final capped = scaled > _config.backoffCap ? _config.backoffCap : scaled;
    final half = capped.inMilliseconds ~/ 2;
    return Duration(milliseconds: half + _random.nextInt(half + 1));
  }

  void _fail(String message) {
    _teardown();
    _running = false;
    unawaited(_networkChanges?.cancel());
    _networkChanges = null;
    _emit(FeedFatal(message));
  }

  // ---------------------------------------------------------------- network

  void _onNetworkChanged(bool online) {
    if (!_running) return;

    if (!online) {
      // The socket is already dead; make the UI honest about it immediately
      // and stop burning retries on a network that cannot carry them.
      _retry?.cancel();
      _teardown();
      _emit(const FeedOffline());
      return;
    }

    if (_subscription != null) return; // already connected, nothing to do

    // A different network entirely — past failures predict nothing about it,
    // so drop the backoff and go straight away.
    _attempt = 0;
    _retry?.cancel();
    unawaited(_connect());
  }

  // ----------------------------------------------------------------- shared

  void _teardown() {
    _generation++; // invalidate every callback from the attempt being dropped
    _watchdog?.cancel();
    _watchdog = null;
    _retry?.cancel();
    _retry = null;
    unawaited(_frames?.cancel());
    _frames = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _emit(FeedStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }
}
