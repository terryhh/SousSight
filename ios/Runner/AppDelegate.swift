import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pcmChannel: FlutterMethodChannel?
  private var pcmPlayer: PcmPlayer?
  private var pcmToken = 0

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "dev.soussight/pcm_player",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handlePcm(call, result: result)
    }
    pcmChannel = channel
  }

  /// Streaming playback of the Live coach's PCM16 voice. Calls from a closed
  /// session carry an old token and are ignored.
  private func handlePcm(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let current = (args["token"] as? Int) == pcmToken && pcmPlayer != nil
    switch call.method {
    case "open":
      pcmPlayer?.close()
      pcmPlayer = nil
      let sampleRate = (args["sampleRate"] as? NSNumber)?.doubleValue ?? 24000
      do {
        pcmPlayer = try PcmPlayer(sampleRate: sampleRate)
        pcmToken += 1
        result(pcmToken)
      } catch {
        result(
          FlutterError(code: "pcm_player", message: error.localizedDescription, details: nil))
      }
    case "feed":
      if current, let pcm = args["pcm"] as? FlutterStandardTypedData {
        pcmPlayer?.feed(pcm.data)
      }
      result(nil)
    case "interrupt":
      if current { pcmPlayer?.interrupt() }
      result(nil)
    case "close":
      if current {
        pcmPlayer?.close()
        pcmPlayer = nil
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

enum PcmPlayerError: Error {
  case unsupportedFormat
}

/// Plays PCM16 little-endian mono through AVAudioEngine. [interrupt] drops
/// every scheduled buffer at once.
///
/// The `record` plugin starts first and sets the shared session to
/// play-and-record on the speaker; this only sets it when nobody has, with the
/// same options, so it never reconfigures a running recorder.
final class PcmPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let format: AVAudioFormat
  private var configurationObserver: NSObjectProtocol?

  init(sampleRate: Double) throws {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
        interleaved: false)
    else { throw PcmPlayerError.unsupportedFormat }
    self.format = format

    let session = AVAudioSession.sharedInstance()
    if session.category != .playAndRecord {
      try session.setCategory(
        .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
    }
    try session.setActive(true)

    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    engine.prepare()
    try engine.start()
    node.play()

    // A route change (headphones, a call) stops the engine; resume quietly.
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      self?.resume()
    }
  }

  deinit {
    close()
  }

  func feed(_ data: Data) {
    let frames = data.count / 2
    guard frames > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
      let channel = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    data.withUnsafeBytes { raw in
      for index in 0..<frames {
        let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
        channel[index] = Float(sample) / 32768
      }
    }
    resume()
    node.scheduleBuffer(buffer, completionHandler: nil)
  }

  func interrupt() {
    node.stop()
    node.play()
  }

  func close() {
    if let observer = configurationObserver {
      NotificationCenter.default.removeObserver(observer)
      configurationObserver = nil
    }
    node.stop()
    engine.stop()
    // The session stays active: the recorder may still be using it.
  }

  private func resume() {
    if !engine.isRunning {
      try? engine.start()
    }
    if engine.isRunning && !node.isPlaying {
      node.play()
    }
  }
}
