// Checks for HybridCore.swift (the bridge logic without Flutter or model SDKs).
// Run with ./run.sh on a Mac. Uses a fake engine only: no
// model, network or Firebase call is made.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Harness

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
  checks += 1
  if !condition() {
    failures += 1
    print("FAIL (line \(line)): \(what)")
  }
}

final class FakeEngine: HybridEngine {
  var localSupported = true
  var cloudSupported = true
  var local: LocalStatus = .available
  var ready = true
  var reply = "ok"
  var error: Error?
  var delayNs: UInt64 = 0
  /// Keep running after cancellation, like an SDK that cannot be interrupted.
  var ignoreCancel = false
  var calls: [(route: Route, plan: PromptPlan, maxOutputTokens: Int)] = []
  var cloudModelsSeen: [String?] = []
  let lock = NSLock()

  func localStatus() -> LocalStatus { local }
  func cloudReady(cloudModel: String?) -> Bool {
    cloudModelsSeen.append(cloudModel)
    return ready && cloudModel != nil
  }
  func generate(
    route: Route, plan: PromptPlan, maxOutputTokens: Int, cloudModel: String?
  ) async throws -> EngineReply {
    lock.lock()
    calls.append((route, plan, maxOutputTokens))
    lock.unlock()
    if delayNs > 0 {
      if ignoreCancel {
        // Not cancellable: a detached sleep the caller cannot cancel.
        await Task.detached { [delayNs] in try? await Task.sleep(nanoseconds: delayNs) }.value
      } else {
        try await Task.sleep(nanoseconds: delayNs)
      }
    }
    if let error { throw error }
    return EngineReply(text: reply)
  }
  func mapError(_ error: Error, route: Route) -> HybridError {
    HybridError(.network, "mapped \(route)")
  }
}

struct OtherError: Error {}

func request(
  id: String = "r1", mode: HybridMode = .preferOnDevice, text: String = "hello",
  system: Any? = nil, parts: [[String: Any]]? = nil, schema: Any? = nil,
  maxOutputTokens: Int = 64, timeoutMs: Int = 2000
) -> [String: Any] {
  var m: [String: Any] = [
    "requestId": id, "mode": mode.rawValue, "feature": "pantry_scan",
    "parts": parts ?? [["type": "text", "text": text]],
    "maxOutputTokens": maxOutputTokens, "timeoutMs": timeoutMs,
  ]
  m["systemInstruction"] = system ?? NSNull()
  m["jsonSchema"] = schema ?? NSNull()
  return m
}

func run(_ bridge: HybridBridge, _ args: [String: Any]) async -> Result<[String: Any], HybridError> {
  await withCheckedContinuation { cont in
    bridge.generate(args, bytes: { $0 as? Data }) { cont.resume(returning: $0) }
  }
}

func errorCode(_ r: Result<[String: Any], HybridError>) -> HybridErrorCode? {
  if case .failure(let e) = r { return e.code }
  return nil
}

func value(_ r: Result<[String: Any], HybridError>) -> [String: Any]? {
  if case .success(let m) = r { return m }
  return nil
}

func png(width: Int, height: Int) -> Data {
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let image = ctx.makeImage()!
  let out = NSMutableData()
  let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
  return out as Data
}

func imagePart(_ data: Data, mime: String = "image/png") -> [String: Any] {
  ["type": "inlineData", "mimeType": mime, "bytes": data]
}

// MARK: - Checks

@main
struct CoreChecks {
  static func main() async {
    capabilitiesAndAvailability()
    prepare()
    await parsing()
    await routing()
    await media()
    await schemaAndText()
    await timeoutAndCancel()
    await errors()
    pureHelpers()
    print("\(checks - failures)/\(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
  }

  static func capabilitiesAndAvailability() {
    let engine = FakeEngine()
    let bridge = HybridBridge(engine: engine)
    var caps = bridge.capabilities()
    expect(caps["platform"] as? String == "ios", "platform ios")
    expect(
      caps["supportedModes"] as? [String] == ["preferOnDevice", "onlyOnDevice", "onlyInCloud"],
      "modes when both models are supported, never preferInCloud")
    let local = caps["local"] as? [String: Any]
    expect(local?["modelFamily"] as? String == "Apple Foundation Models", "family")
    expect(local?["maxTotalTokens"] as? Int == 4096, "4096 tokens")
    expect(local?["defaultOutputReserve"] as? Int == 256, "reserve 256")
    expect(local?["supportsImage"] as? Bool == false, "no local image")
    expect(local?["supportsJsonSchema"] as? Bool == false, "no local schema")
    expect(local?["validatedLanguages"] as? [String] == ["en"], "en only")
    expect(local?["imageTokenEstimate"] as? Int != nil, "imageTokenEstimate present")
    expect(caps["maxImages"] as? Int == 1, "1 image")
    expect(caps["maxImageBytes"] as? Int == 1024 * 1024, "1 MB")
    expect(caps["maxImageDimension"] as? Int == 768, "768 px")

    engine.cloudSupported = false
    caps = bridge.capabilities()
    expect(
      caps["supportedModes"] as? [String] == ["preferOnDevice", "onlyOnDevice"],
      "no onlyInCloud without a native cloud model")
    engine.localSupported = false
    caps = bridge.capabilities()
    expect(caps["local"] is NSNull, "local null without Foundation Models")
    expect((caps["supportedModes"] as? [String])?.isEmpty == true, "no modes at all")

    engine.localSupported = true
    engine.local = .available
    expect(bridge.availability(["withImage": false])["status"] as? String == "available", "text available")
    let img = bridge.availability(["withImage": true])
    expect(img["status"] as? String == "unavailable", "image never local")
    expect(img["reason"] as? String == "image_not_supported_locally", "image reason")
    for reason in ["device_not_eligible", "apple_intelligence_off", "model_not_ready"] {
      engine.local = .unavailable(reason: reason)
      let a = bridge.availability(["withImage": false])
      expect(a["status"] as? String == "unavailable" && a["reason"] as? String == reason, reason)
      expect(a["modelLabel"] == nil, "no invented model label")
    }
  }

  static func prepare() {
    let engine = FakeEngine()
    let bridge = HybridBridge(engine: engine)
    expect(bridge.prepare(["withImage": false]) == nil, "ready model: complete")
    expect(
      bridge.prepare(["withImage": true])
        == HybridError(.unavailable, "image_not_supported_locally"), "image prepare fails")
    engine.local = .unavailable(reason: "model_not_ready")
    expect(
      bridge.prepare(["withImage": false]) == HybridError(.unavailable, "model_not_ready"),
      "unusable model never reads as ready")
  }

  static func parsing() async {
    let engine = FakeEngine()
    let bridge = HybridBridge(engine: engine)
    bridge.configure(["cloudModel": "gemini-x", "androidModel": "preview", "languages": ["en"]])
    let got1 = await run(bridge, ["requestId": "x"])
    expect(errorCode(got1) == .failed, "malformed → failed")
    var args = request()
    args["mode"] = "sideways"
    let got2 = await run(bridge, args)
    expect(errorCode(got2) == .unsupportedMode, "unknown mode")
    args = request(parts: [["type": "fileData", "uri": "gs://x"]])
    let got3 = await run(bridge, args)
    expect(errorCode(got3) == .unsupportedInput, "unknown part type")
    args = request()
    args["timeoutMs"] = 0
    let got4 = await run(bridge, args)
    expect(errorCode(got4) == .failed, "zero timeout rejected")
    args = request(parts: [["type": "text", "text": ""]])
    let got5 = await run(bridge, args)
    expect(errorCode(got5) == .unsupportedInput, "no text")
    expect(engine.calls.isEmpty, "no SDK call for rejected requests")

    // Invalid names never reach FirebaseAI (which would fatalError).
    for bad in ["", "models/gemini", "has space"] {
      bridge.configure(["cloudModel": bad])
      _ = await run(bridge, request(mode: .onlyInCloud))
      expect(engine.cloudModelsSeen.last! == nil, "invalid cloud model '\(bad)' ignored")
    }
    bridge.configure(nil)
    _ = await run(bridge, request(mode: .onlyInCloud))
    expect(engine.cloudModelsSeen.last! == nil, "missing configure → no cloud")
  }

  static func routing() async {
    let engine = FakeEngine()
    let bridge = HybridBridge(engine: engine)
    bridge.configure(["cloudModel": "gemini-x"])

    var r = await run(bridge, request(mode: .preferInCloud))
    expect(errorCode(r) == .unsupportedMode, "preferInCloud unsupported")

    r = await run(bridge, request(id: "a", mode: .preferOnDevice))
    expect(value(r)?["source"] as? String == "onDevice", "preferOnDevice local first")
    expect(value(r)?["requestId"] as? String == "a", "requestId echoed")
    expect(value(r)?["modelLabel"] == nil, "no model label claimed")
    expect(engine.calls.last?.route == .local, "local route")

    engine.local = .unavailable(reason: "apple_intelligence_off")
    r = await run(bridge, request(mode: .preferOnDevice))
    expect(value(r)?["source"] as? String == "cloud", "preferOnDevice falls back to cloud")

    engine.ready = false
    r = await run(bridge, request(mode: .preferOnDevice))
    expect(errorCode(r) == .unavailable, "no local, no cloud → unavailable")

    let before = engine.calls.count
    engine.ready = true
    r = await run(bridge, request(mode: .onlyOnDevice))
    expect(errorCode(r) == .unavailable, "onlyOnDevice never widens to cloud")
    if case .failure(let e) = r { expect(e.message == "apple_intelligence_off", "reason kept") }
    expect(engine.calls.count == before, "no SDK call")

    engine.local = .available
    let big = String(repeating: "x", count: 4 * 4096)
    r = await run(bridge, request(mode: .onlyOnDevice, text: big))
    expect(errorCode(r) == .unsupportedInput, "onlyOnDevice over budget rejected")
    r = await run(bridge, request(mode: .preferOnDevice, text: big))
    expect(value(r)?["source"] as? String == "cloud", "preferOnDevice over budget → cloud")

    r = await run(bridge, request(mode: .onlyOnDevice))
    expect(value(r)?["source"] as? String == "onDevice", "onlyOnDevice local")
    r = await run(bridge, request(mode: .onlyInCloud))
    expect(value(r)?["source"] as? String == "cloud", "onlyInCloud cloud")
    expect(engine.calls.last?.route == .cloud, "cloud route")
    engine.ready = false
    r = await run(bridge, request(mode: .onlyInCloud))
    expect(errorCode(r) == .unavailable, "onlyInCloud without native cloud → unavailable")
  }

  static func media() async {
    let engine = FakeEngine()
    let bridge = HybridBridge(engine: engine)
    bridge.configure(["cloudModel": "gemini-x"])
    let small = png(width: 64, height: 48)
    expect(imagePixelSize(small).map { [$0.width, $0.height] } == [64, 48], "png size read")
    for mode in [HybridMode.onlyInCloud, .preferOnDevice, .onlyOnDevice] {
      let r = await run(
        bridge,
        request(mode: mode, parts: [["type": "text", "text": "what is this"], imagePart(small)]))
      expect(errorCode(r) == .rejectedBeforeSend, "image with \(mode) → rejectedBeforeSend")
    }
    let audio: [String: Any] = ["type": "inlineData", "mimeType": "audio/wav", "bytes": Data([1, 2])]
    var r = await run(bridge, request(parts: [["type": "text", "text": "x"], audio]))
    expect(errorCode(r) == .rejectedBeforeSend, "audio → rejectedBeforeSend")
    r = await run(bridge, request(parts: [["type": "text", "text": "x"], imagePart(small), imagePart(small)]))
    if case .failure(let e) = r { expect(e.message.contains("At most"), "two images: limit message") }
    expect(errorCode(r) == .rejectedBeforeSend, "two images: rejectedBeforeSend")
    r = await run(bridge, request(parts: [["type": "text", "text": "x"], imagePart(png(width: 800, height: 10))]))
    if case .failure(let e) = r { expect(e.message.contains("px"), "dimension limit") }
    expect(errorCode(r) == .rejectedBeforeSend, "dimension limit: rejectedBeforeSend")
    r = await run(bridge, request(parts: [["type": "text", "text": "x"], imagePart(Data(count: 1024 * 1024 + 1))]))
    if case .failure(let e) = r { expect(e.message.contains("bytes"), "byte limit") }
    expect(errorCode(r) == .rejectedBeforeSend, "byte limit: rejectedBeforeSend")
    // The dispatcher test's JPEG bytes (not a readable image) are refused
    // before send too.
    r = await run(bridge, request(mode: .onlyInCloud, parts: [["type": "text", "text": "x"], ["type": "inlineData", "mimeType": "image/jpeg", "bytes": Data([1, 2, 3])]]))
    expect(errorCode(r) == .rejectedBeforeSend, "unreadable image: rejectedBeforeSend")
    let pdf: [String: Any] = ["type": "inlineData", "mimeType": "application/pdf", "bytes": Data([1])]
    r = await run(bridge, request(parts: [["type": "text", "text": "x"], pdf]))
    expect(errorCode(r) == .rejectedBeforeSend, "other attachment types rejected before send")
    expect(engine.calls.isEmpty, "no media request reached an SDK")
  }

  static func schemaAndText() async {
    let engine = FakeEngine()
    let bridge = HybridBridge(engine: engine)
    let schema: [String: Any] = [
      "type": "object", "properties": ["items": ["type": "array", "items": ["type": "string"]]],
      "required": ["items"],
    ]
    engine.reply = "```json\n{\"items\":[\"egg\"]}\n```"
    var r = await run(
      bridge, request(mode: .onlyOnDevice, text: "list", system: "Be brief.", schema: schema, maxOutputTokens: 99))
    expect(value(r)?["text"] as? String == "{\"items\":[\"egg\"]}", "fence stripped for JSON")
    let plan = engine.calls.last?.plan
    expect(plan?.instructions == "Be brief.", "system instruction kept as instructions")
    expect(plan?.prompt.hasPrefix("list\n\n") == true, "user text first")
    expect(plan?.prompt.contains("\"required\":[\"items\"]") == true, "schema appended to prompt")
    expect(engine.calls.last?.maxOutputTokens == 99, "output limit passed")

    engine.reply = "```keep```"
    r = await run(bridge, request(id: "t"))
    expect(value(r)?["text"] as? String == "```keep```", "plain text untouched")
    expect(engine.calls.last?.plan.prompt == "hello", "no schema text without a schema")

    engine.reply = "  \n"
    r = await run(bridge, request(id: "e"))
    expect(errorCode(r) == .failed, "empty reply → failed")
  }

  static func timeoutAndCancel() async {
    let engine = FakeEngine()
    let bridge = HybridBridge(engine: engine)
    engine.delayNs = 600_000_000
    engine.ignoreCancel = true

    let start = Date()
    var r = await run(bridge, request(id: "slow", timeoutMs: 100))
    expect(errorCode(r) == .timeout, "timeout")
    expect(Date().timeIntervalSince(start) < 0.5, "timeout is not held up by the SDK")
    expect(bridge.runningCount == 0, "timed-out call removed")

    // Cancel: completes `cancelled` at once; the late result is discarded.
    var completions = 0
    let done = await withCheckedContinuation { (cont: CheckedContinuation<Result<[String: Any], HybridError>, Never>) in
      bridge.generate(request(id: "c1", timeoutMs: 5000), bytes: { $0 as? Data }) { result in
        completions += 1
        if completions == 1 { cont.resume(returning: result) }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
        bridge.cancel(["requestId": "c1"])
      }
    }
    expect(errorCode(done) == .cancelled, "cancel → cancelled")
    try? await Task.sleep(nanoseconds: 800_000_000)
    expect(completions == 1, "late result discarded")
    expect(bridge.runningCount == 0, "cancelled call removed")
    bridge.cancel(["requestId": "unknown"])
    bridge.cancel(nil)

    // A cooperative SDK sees the cancellation.
    engine.ignoreCancel = false
    engine.delayNs = 2_000_000_000
    async let first = run(bridge, request(id: "dup", timeoutMs: 5000))
    try? await Task.sleep(nanoseconds: 50_000_000)
    r = await run(bridge, request(id: "dup", timeoutMs: 5000))
    expect(errorCode(r) == .busy, "duplicate running requestId → busy")
    bridge.cancelAll()
    let firstResult = await first
    expect(errorCode(firstResult) == .cancelled, "cancelAll ends running calls")

    // A finished id can run again.
    engine.delayNs = 0
    r = await run(bridge, request(id: "dup"))
    expect(value(r) != nil, "requestId reusable after completion")
  }

  static func errors() async {
    let engine = FakeEngine()
    let bridge = HybridBridge(engine: engine)
    engine.error = CancellationError()
    let got6 = await run(bridge, request(id: "1"))
    expect(errorCode(got6) == .cancelled, "CancellationError → cancelled")
    engine.error = HybridError(.blocked, "x")
    let got7 = await run(bridge, request(id: "2"))
    expect(errorCode(got7) == .blocked, "HybridError passes through")
    engine.error = OtherError()
    let r = await run(bridge, request(id: "3"))
    expect(errorCode(r) == .network, "other errors go through the engine's mapper")
    if case .failure(let e) = r { expect(e.message == "mapped local", "mapper told the route") }
  }

  static func pureHelpers() {
    expect(mapCloudAPIError(status: 429, code: "", message: "", detail: "").code == .quota, "429 quota")
    expect(
      mapCloudAPIError(status: 400, code: "RESOURCE_EXHAUSTED", message: "", detail: "").code == .quota,
      "RESOURCE_EXHAUSTED quota")
    expect(mapCloudAPIError(status: 401, code: "", message: "", detail: "").code == .attestation, "401")
    expect(
      mapCloudAPIError(status: 403, code: "PERMISSION_DENIED", message: "App Check token invalid", detail: "").code
        == .attestation, "403 App Check")
    expect(
      mapCloudAPIError(status: 403, code: "PERMISSION_DENIED", message: "API not enabled", detail: "").code
        == .failed, "other 403 is not attestation")
    expect(mapCloudAPIError(status: 503, code: "", message: "", detail: "").code == .network, "5xx network")
    expect(mapCloudAPIError(status: 400, code: "INVALID_ARGUMENT", message: "", detail: "").code == .failed, "400")

    expect(stripCodeFence("```json\n[1]\n```") == "[1]", "fence with info string")
    expect(stripCodeFence("```\n{}\n```") == "{}", "bare fence")
    expect(stripCodeFence(" {\"a\":1} ") == "{\"a\":1}", "trim only")

    // Same formula as the Dart policy: ceil(chars / 4) + output.
    let parsed = try! BridgeRequest.parse(
      request(text: "abcde", system: "xyz", schema: ["type": "string"], maxOutputTokens: 10),
      bytes: { $0 as? Data })
    // "abcde" 5 + "xyz" 3 + {"type":"string"} 17 = 25 chars → 7 tokens.
    expect(estimateLocalTokens(parsed) == 17, "token estimate \(estimateLocalTokens(parsed))")
    expect(parsed.jsonSchemaText == "{\"type\":\"string\"}", "compact schema")
  }
}
