// Flutter glue for the iOS bridge. The protocol is DESIGN.md §4 "Wire format";
// the Dart side is MethodChannelHybridInference. All logic is in HybridBridge.

import Flutter
import Foundation

public class AiLogicHybridPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static let methodChannelName = "dev.soussight/ai_logic_hybrid"
  static let prepareChannelName = "dev.soussight/ai_logic_hybrid/prepare"

  private let bridge: HybridBridge

  init(bridge: HybridBridge) {
    self.bridge = bridge
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = AiLogicHybridPlugin(bridge: HybridBridge(engine: FoundationModelsEngine()))
    let channel = FlutterMethodChannel(
      name: methodChannelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let prepare = FlutterEventChannel(
      name: prepareChannelName, binaryMessenger: registrar.messenger())
    prepare.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      bridge.configure(call.arguments)
      result(nil)
    case "capabilities":
      result(bridge.capabilities())
    case "availability":
      result(bridge.availability(call.arguments))
    case "generate":
      bridge.generate(call.arguments, bytes: Self.bytes) { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case .success(let map): result(map)
          case .failure(let error): result(Self.flutterError(error))
          }
        }
      }
    case "cancel":
      bridge.cancel(call.arguments)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: FlutterStreamHandler (prepare)

  /// iOS has nothing to download: a usable model completes the stream at
  /// once with no fractions; an unusable one fails the `listen` call with
  /// `unavailable` and the reason code as the message.
  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    if let error = bridge.prepare(arguments) {
      return Self.flutterError(error)
    }
    DispatchQueue.main.async { events(FlutterEndOfEventStream) }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    nil
  }

  // MARK: Helpers

  private static func bytes(_ value: Any) -> Data? {
    if let typed = value as? FlutterStandardTypedData { return typed.data }
    return value as? Data
  }

  private static func flutterError(_ error: HybridError) -> FlutterError {
    FlutterError(code: error.code.rawValue, message: error.message, details: nil)
  }
}
