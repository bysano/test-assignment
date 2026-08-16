import Flutter
import UIKit

/// Registers Pulse's two platform channels:
///
/// - `pulse/secure_token_store` (MethodChannel) — Keychain-backed token storage
/// - `pulse/reachability` (EventChannel) — NWPathMonitor reachability events
public class PulseNativePlugin: NSObject, FlutterPlugin {
  private let tokenStore = KeychainTokenStore()

  /// The event channel and its handler are retained here for the lifetime of
  /// the process. Letting either fall out of scope silently kills the stream,
  /// and a reachability stream that stops reporting is worse than none at all:
  /// the app would sit believing whatever it last heard.
  private static var reachabilityChannel: FlutterEventChannel?
  private static var reachabilityHandler: ReachabilityStreamHandler?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "pulse/secure_token_store",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(PulseNativePlugin(), channel: methodChannel)

    let handler = ReachabilityStreamHandler()
    let eventChannel = FlutterEventChannel(
      name: "pulse/reachability",
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(handler)
    reachabilityChannel = eventChannel
    reachabilityHandler = handler
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "write":
        guard
          let arguments = call.arguments as? [String: Any],
          let token = arguments["token"] as? String
        else {
          result(
            FlutterError(
              code: "bad_arguments",
              message: "write expects a 'token' string",
              details: nil
            )
          )
          return
        }
        try tokenStore.write(token)
        result(nil)

      case "read":
        result(try tokenStore.read())

      case "delete":
        try tokenStore.delete()
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    } catch KeychainError.unexpectedStatus(let status) {
      result(
        FlutterError(
          code: "keychain_error",
          message: "OSStatus \(status)",
          details: nil
        )
      )
    } catch {
      result(
        FlutterError(
          code: "keychain_error",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }
}
