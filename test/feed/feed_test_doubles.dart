import 'dart:async';
import 'dart:math';

import 'package:pulse/data/sse/authorized_sse_transport.dart';
import 'package:pulse/data/sse/sse_frame.dart';
import 'package:pulse/data/sse/sse_transport.dart';
import 'package:pulse/feed/network_gate.dart';

/// One `open()` call, so tests can assert on resume cursors.
final class ConnectCall {
  const ConnectCall(this.lastEventId);

  final int? lastEventId;
}

/// An already-authorized stream the test drives by hand: no sockets, no
/// server, no real time. Tokens are the decorator's problem, not the feed's,
/// and are covered in `authorized_sse_transport_test.dart`.
class FakeSseTransport implements AuthorizedStream {
  final List<ConnectCall> calls = [];
  final List<FakeSseSubscription> subscriptions = [];

  /// Errors to throw from the next connects, one per entry, in order. An empty
  /// queue means connect succeeds.
  final List<Object> failures = [];

  FakeSseSubscription? get current =>
      subscriptions.isEmpty ? null : subscriptions.last;

  @override
  Future<SseSubscription> open({int? lastEventId}) async {
    calls.add(ConnectCall(lastEventId));
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
