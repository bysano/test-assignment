import Flutter
import Foundation
import Network

/// Bridges `NWPathMonitor` onto an `EventChannel`.
///
/// `NWPathMonitor` invokes `pathUpdateHandler` with the current path as soon
/// as it starts, which is what lets the Dart side promise that listening
/// yields the present status rather than only future changes.
final class ReachabilityStreamHandler: NSObject, FlutterStreamHandler {
  private var monitor: NWPathMonitor?
  private let queue = DispatchQueue(label: "com.finonex.pulse.reachability")

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    monitor?.cancel()

    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { path in
      let status = path.status == .satisfied ? "online" : "offline"
      // Event sinks must only be touched from the platform thread.
      DispatchQueue.main.async { events(status) }
    }
    monitor.start(queue: queue)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    monitor?.cancel()
    monitor = nil
    return nil
  }
}
