import 'dart:async';
import 'dart:math';

import 'package:pulse/data/sse/sse_frame.dart';
import 'package:pulse/data/sse/sse_transport.dart';
import 'package:pulse/feed/feed_connection.dart';
import 'package:pulse/feed/network_gate.dart';

/// One `connect()` call, so tests can assert on resume cursors and tokens.
final class ConnectCall {
  const ConnectCall(this.token, this.lastEventId);

  final String token;
  final int? lastEventId;
}

/// A transport the test drives by hand: no sockets, no server, no real time.
class FakeSseTransport implements SseTransport {
  final List<ConnectCall> calls = [];
  final List<FakeSseSubscription> subscriptions = [];

  /// Errors to throw from the next connects, one per entry, in order. An empty
  /// queue means connect succeeds.
  final List<Object> failures = [];

  FakeSseSubscription? get current =>
      subscriptions.isEmpty ? null : subscriptions.last;

  @override
  Future<SseSubscription> connect({
    required String token,
    int? lastEventId,
  }) async {
    calls.add(ConnectCall(token, lastEventId));
    if (failures.isNotEmpty) throw failures.removeAt(0);
    final subscription = FakeSseSubscription();
    subscriptions.add(subscription);
    return subscription;
  }
}

class FakeSseSubscription implements SseSubscription {
  final StreamController<SseFrame> _frames = StreamController<SseFrame>();
  bool cancelled = false;

  @override
  Stream<SseFrame> get frames => _frames.stream;

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!_frames.isClosed) await _frames.close();
  }

  void emit(SseFrame frame) {
    if (!_frames.isClosed) _frames.add(frame);
  }

  void emitTick({
    required int id,
    String symbol = 'EURUSD',
    double bid = 1.08123,
    double ask = 1.08141,
    required int ts,
  }) => emit(
    SseEvent(
      id: id,
      event: 'tick',
      data: '{"s":"$symbol","b":$bid,"a":$ask,"ts":$ts}',
    ),
  );

  void emitHeartbeat() => emit(const SseComment('ping'));

  /// The server closing the stream on us.
  void endStream() {
    if (!_frames.isClosed) _frames.close();
  }

  /// A socket-level failure.
  void failStream(Object error) {
    if (!_frames.isClosed) _frames.addError(error);
  }
}

class FakeTokenProvider implements FeedTokenProvider {
  String token = 'token-0';
  int refreshCount = 0;

  /// Thrown by [refreshToken] when set — used to simulate rejected credentials.
  Object? refreshError;

  @override
  Future<String> currentToken() async => token;

  @override
  Future<String> refreshToken() async {
    final error = refreshError;
    if (error != null) throw error;
    refreshCount++;
    token = 'token-$refreshCount';
    return token;
  }
}

class FakeNetworkGate implements NetworkGate {
  FakeNetworkGate({bool online = true}) : _online = online;

  bool _online;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  bool get isOnline => _online;

  @override
  Stream<bool> get changes => _changes.stream;

  void setOnline(bool value) {
    _online = value;
    _changes.add(value);
  }
}

/// Removes jitter so backoff delays are exact and assertable. The production
/// path uses a real [Random]; the arithmetic under test is the same either way.
class NoJitterRandom implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}
