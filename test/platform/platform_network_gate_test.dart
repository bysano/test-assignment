import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse/data/platform/platform_network_gate.dart';
import 'package:pulse_native/pulse_native.dart';

class _FakeReachability implements Reachability {
  final StreamController<NetworkStatus> controller =
      StreamController<NetworkStatus>.broadcast();

  @override
  Stream<NetworkStatus> changes() => controller.stream;
}

void main() {
  late _FakeReachability reachability;
  late PlatformNetworkGate gate;
  late List<bool> transitions;

  setUp(() {
    reachability = _FakeReachability();
    gate = PlatformNetworkGate(reachability);
    transitions = [];
    gate.changes.listen(transitions.add);
  });

  tearDown(() async {
    await gate.dispose();
    await reachability.controller.close();
  });

  test('starts optimistic, before the platform has said anything', () {
    expect(gate.isOnline, isTrue);
  });

  test('goes offline only when the platform is certain', () async {
    reachability.controller.add(NetworkStatus.offline);
    await pumpEventQueue();

    expect(gate.isOnline, isFalse);
    expect(transitions, [false]);
  });

  test('comes back online', () async {
    reachability.controller
      ..add(NetworkStatus.offline)
      ..add(NetworkStatus.online);
    await pumpEventQueue();

    expect(gate.isOnline, isTrue);
    expect(transitions, [false, true]);
  });

  // The whole point of the tri-state: a platform that cannot tell must not be
  // mistaken for one that is offline, or reconnection stops forever.
  test('treats unknown as online', () async {
    reachability.controller.add(NetworkStatus.unknown);
    await pumpEventQueue();

    expect(gate.isOnline, isTrue);
    expect(transitions, isEmpty);
  });

  test('recovers to online when the platform stops being sure', () async {
    reachability.controller
      ..add(NetworkStatus.offline)
      ..add(NetworkStatus.unknown);
    await pumpEventQueue();

    expect(gate.isOnline, isTrue);
    expect(transitions, [false, true]);
  });

  test('emits transitions only, not repeats', () async {
    reachability.controller
      ..add(NetworkStatus.online)
      ..add(NetworkStatus.online)
      ..add(NetworkStatus.offline)
      ..add(NetworkStatus.offline)
      ..add(NetworkStatus.online);
    await pumpEventQueue();

    expect(transitions, [false, true]);
  });

  test(
    'a channel error leaves us optimistic rather than stuck offline',
    () async {
      reachability.controller
        ..add(NetworkStatus.offline)
        ..addError(Exception('channel died'));
      await pumpEventQueue();

      expect(gate.isOnline, isTrue);
    },
  );
}
