// The iOS side of the bridge contract (DESIGN.md §4), with no Flutter and no
// model SDK in it, so `ios/core_check/run.sh` can compile and exercise it on a
// Mac with only the command line tools.

import Foundation
import ImageIO

// MARK: - Contract names (must match packages/ai_logic_hybrid/lib/src/contract.dart)

enum HybridErrorCode: String {
  case unavailable, unsupportedInput, unsupportedMode, busy, quota, blocked
  case network, attestation, timeout, cancelled, failed
  /// Refused by this bridge's own validation before any SDK call: nothing
  /// was sent (contract.dart `rejectedBeforeSend`).
  case rejectedBeforeSend
}

struct HybridError: Error, Equatable {
  let code: HybridErrorCode
  let message: String
  init(_ code: HybridErrorCode, _ message: String) {
    self.code = code
    self.message = message
  }
}

enum HybridMode: String, CaseIterable {
  case preferOnDevice, onlyOnDevice, preferInCloud, onlyInCloud
}

enum InferenceSource: String {
  case onDevice, cloud
}

/// Stable availability reason codes (DESIGN.md §4, `HybridAvailability.reason`).
enum AvailabilityReason {
  static let deviceNotEligible = "device_not_eligible"
  static let appleIntelligenceOff = "apple_intelligence_off"
  static let modelNotReady = "model_not_ready"
  static let imageNotSupportedLocally = "image_not_supported_locally"
  /// This build or OS has no Foundation Models framework (iOS < 26, or an
  /// Xcode without the framework).
  static let osUnsupported = "os_unsupported"
  static let unknown = "unknown"
}

/// What the local model can do right now, as read from the platform.
enum LocalStatus: Equatable {
  case available
  case unavailable(reason: String)
}

/// Fixed facts about the local model (Apple Foundation Models, text only).
enum LocalLimits {
  static let modelFamily = "Apple Foundation Models"
  static let maxTotalTokens = 4096
  static let defaultOutputReserve = 256
  /// Images never run locally on iOS; this only keeps the field populated.
  static let imageTokenEstimate = 1000
  static let validatedLanguages = ["en"]
}

/// Attachment limits for every route.
enum AttachmentLimits {
  static let maxImages = 1
  static let maxImageBytes = 1024 * 1024
  static let maxImageDimension = 768
}

// MARK: - Requests

enum RequestPart: Equatable {
  case text(String)
  case inlineData(mimeType: String, bytes: Data)
}

struct BridgeRequest {
  let requestId: String
  let mode: HybridMode
  let feature: String
  let systemInstruction: String?
  let parts: [RequestPart]
  /// The schema as received, and its compact serialization.
  let jsonSchema: [String: Any]?
  let jsonSchemaText: String?
  let maxOutputTokens: Int
  let timeoutMs: Int

  var hasInlineData: Bool {
    parts.contains { if case .inlineData = $0 { return true } else { return false } }
  }

  /// Parses the `generate` arguments. `bytes` turns a channel value
  /// (FlutterStandardTypedData on device, Data in checks) into Data.
  static func parse(_ raw: Any?, bytes: (Any) -> Data?) throws -> BridgeRequest {
    guard let args = raw as? [String: Any] else {
      throw HybridError(.failed, "Malformed request: arguments are not a map")
    }
    guard let requestId = args["requestId"] as? String, !requestId.isEmpty else {
      throw HybridError(.failed, "Malformed request: requestId")
    }
    guard let modeName = args["mode"] as? String else {
      throw HybridError(.failed, "Malformed request: mode")
    }
    guard let mode = HybridMode(rawValue: modeName) else {
      throw HybridError(.unsupportedMode, "Unknown mode \(modeName)")
    }
    guard let feature = args["feature"] as? String else {
      throw HybridError(.failed, "Malformed request: feature")
    }
    let systemInstruction: String?
    switch args["systemInstruction"] {
    case nil, is NSNull: systemInstruction = nil
    case let s as String: systemInstruction = s.isEmpty ? nil : s
    default: throw HybridError(.failed, "Malformed request: systemInstruction")
    }
    guard let rawParts = args["parts"] as? [Any] else {
      throw HybridError(.failed, "Malformed request: parts")
    }
    var parts: [RequestPart] = []
    for rawPart in rawParts {
      guard let part = rawPart as? [String: Any], let type = part["type"] as? String else {
        throw HybridError(.failed, "Malformed request: part")
      }
      switch type {
      case "text":
        guard let text = part["text"] as? String else {
          throw HybridError(.failed, "Malformed request: text part")
        }
        parts.append(.text(text))
      case "inlineData":
        guard let mime = part["mimeType"] as? String, let value = part["bytes"],
          let data = bytes(value)
        else {
          throw HybridError(.failed, "Malformed request: inlineData part")
        }
        parts.append(.inlineData(mimeType: mime, bytes: data))
      default:
        throw HybridError(.unsupportedInput, "Unsupported part type \(type)")
      }
    }
    var schema: [String: Any]? = nil
    var schemaText: String? = nil
    switch args["jsonSchema"] {
    case nil, is NSNull: break
    case let s as [String: Any]:
      schema = s
      schemaText = try compactJSON(s)
    default: throw HybridError(.failed, "Malformed request: jsonSchema")
    }
    guard let maxOutputTokens = args["maxOutputTokens"] as? Int, maxOutputTokens > 0 else {
      throw HybridError(.failed, "Malformed request: maxOutputTokens")
    }
    guard let timeoutMs = args["timeoutMs"] as? Int, timeoutMs > 0 else {
      throw HybridError(.failed, "Malformed request: timeoutMs")
    }
    return BridgeRequest(
      requestId: requestId, mode: mode, feature: feature,
      systemInstruction: systemInstruction, parts: parts,
      jsonSchema: schema, jsonSchemaText: schemaText,
      maxOutputTokens: maxOutputTokens, timeoutMs: timeoutMs)
  }
}

func compactJSON(_ value: Any) throws -> String {
  guard JSONSerialization.isValidJSONObject(value),
    let data = try? JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
    let text = String(data: data, encoding: .utf8)
  else {
    throw HybridError(.failed, "Malformed request: jsonSchema is not JSON")
  }
  return text
}

// MARK: - Attachment limits and token budget

/// Pixel size of an encoded image, read from its header only.
func imagePixelSize(_ data: Data) -> (width: Int, height: Int)? {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let width = props[kCGImagePropertyPixelWidth] as? Int,
    let height = props[kCGImagePropertyPixelHeight] as? Int
  else { return nil }
  return (width, height)
}

/// Enforces the every-route attachment limits before any SDK call (§4).
func checkAttachmentLimits(_ request: BridgeRequest) throws {
  var images = 0
  for part in request.parts {
    guard case let .inlineData(mime, bytes) = part else { continue }
    if mime.hasPrefix("image/") {
      images += 1
      if images > AttachmentLimits.maxImages {
        throw HybridError(.unsupportedInput, "At most \(AttachmentLimits.maxImages) image")
      }
      if bytes.count > AttachmentLimits.maxImageBytes {
        throw HybridError(.unsupportedInput, "Image larger than \(AttachmentLimits.maxImageBytes) bytes")
      }
      guard let size = imagePixelSize(bytes) else {
        throw HybridError(.unsupportedInput, "Image could not be read")
      }
      if max(size.width, size.height) > AttachmentLimits.maxImageDimension {
        throw HybridError(.unsupportedInput, "Image larger than \(AttachmentLimits.maxImageDimension) px")
      }
    } else if !mime.hasPrefix("audio/") {
      throw HybridError(.unsupportedInput, "Unsupported attachment type \(mime)")
    }
  }
}

/// DESIGN.md §4 token budget, computed the same way as the Dart policy's
/// `estimateLocalTokens` (UTF-16 length / 4, rounded up, plus output).
func estimateLocalTokens(_ request: BridgeRequest) -> Int {
  var chars = request.systemInstruction?.utf16.count ?? 0
  var images = 0
  for part in request.parts {
    switch part {
    case .text(let t): chars += t.utf16.count
    case .inlineData(let mime, _): if mime.hasPrefix("image/") { images += 1 }
    }
  }
  chars += request.jsonSchemaText?.utf16.count ?? 0
  return (chars + 3) / 4 + images * LocalLimits.imageTokenEstimate + request.maxOutputTokens
}

// MARK: - Prompt shaping

struct PromptPlan: Equatable {
  let instructions: String?
  let prompt: String
}

/// Neither the local model nor the Foundation Models cloud session takes the
/// contract's JSON Schema directly, so the schema travels in the prompt and
/// the Dart caller validates the reply (DESIGN.md §4 "iOS local").
func buildPrompt(_ request: BridgeRequest) throws -> PromptPlan {
  var texts: [String] = []
  for part in request.parts {
    if case .text(let t) = part, !t.isEmpty { texts.append(t) }
  }
  guard !texts.isEmpty else {
    throw HybridError(.unsupportedInput, "No text in the request")
  }
  var prompt = texts.joined(separator: "\n\n")
  if let schema = request.jsonSchemaText {
    prompt += """


      Reply with only one JSON value that conforms to the JSON Schema below. \
      Do not use markdown code fences and do not add any other text.
      JSON Schema: \(schema)
      """
  }
  return PromptPlan(instructions: request.systemInstruction, prompt: prompt)
}

/// Removes one surrounding markdown code fence from a JSON reply. Validation
/// stays with the Dart caller; this only undoes a common wrapping.
func stripCodeFence(_ text: String) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6 else {
    return trimmed
  }
  var body = trimmed.dropFirst(3).dropLast(3)
  if let newline = body.firstIndex(of: "\n") {
    // Drop an info string such as `json`.
    body = body[body.index(after: newline)...]
  } else {
    return trimmed
  }
  return body.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Routing (DESIGN.md §4 mode mapping, adapted to SDK 13.1.1)

enum Route: Equatable {
  case local, cloud

  var source: InferenceSource { self == .local ? .onDevice : .cloud }
}

/// Picks the single model a request runs on. Modes are never widened: an
/// `onlyOnDevice` request never gets `.cloud`.
func planRoute(
  _ request: BridgeRequest, local: LocalStatus, cloudReady: Bool
) throws -> Route {
  if request.mode == .preferInCloud {
    throw HybridError(.unsupportedMode, "preferInCloud is not supported on iOS")
  }
  try checkAttachmentLimits(request)
  if request.hasInlineData {
    // The local model is text only, and the Foundation Models cloud session
    // rejects attachment segments (GeminiTranscriptTranslator), so no iOS
    // route can carry media. The dispatcher sends onlyInCloud media with its
    // Dart cloud client.
    // No SDK has been called yet, so the ledger can record that nothing left.
    throw HybridError(.rejectedBeforeSend, "iOS hybrid sessions are text only")
  }
  let fits = estimateLocalTokens(request) <= LocalLimits.maxTotalTokens
  switch request.mode {
  case .onlyOnDevice:
    guard fits else {
      throw HybridError(.unsupportedInput, "Request exceeds the local token budget")
    }
    guard case .available = local else {
      if case .unavailable(let reason) = local { throw HybridError(.unavailable, reason) }
      throw HybridError(.unavailable, AvailabilityReason.unknown)
    }
    return .local
  case .preferOnDevice:
    if fits, case .available = local { return .local }
    if cloudReady { return .cloud }
    if case .unavailable(let reason) = local { throw HybridError(.unavailable, reason) }
    throw HybridError(.unavailable, "Request exceeds the local token budget and no cloud model is ready")
  case .onlyInCloud:
    guard cloudReady else {
      throw HybridError(.unavailable, "No native cloud model is ready")
    }
    return .cloud
  case .preferInCloud:
    throw HybridError(.unsupportedMode, "preferInCloud is not supported on iOS")
  }
}

// MARK: - Engine seam

struct EngineReply {
  let text: String
}

/// The model SDKs behind the bridge. The real one wraps Foundation Models and
/// FirebaseAILogic; checks use a fake.
protocol HybridEngine: AnyObject {
  /// The Foundation Models framework is present in this build and OS.
  var localSupported: Bool { get }
  /// This build and OS can run a FirebaseAILogic cloud session at all.
  var cloudSupported: Bool { get }
  func localStatus() -> LocalStatus
  /// A cloud session can be created now (Firebase app configured, model set).
  func cloudReady(cloudModel: String?) -> Bool
  func generate(
    route: Route, plan: PromptPlan, maxOutputTokens: Int, cloudModel: String?
  ) async throws -> EngineReply
  /// Maps an SDK error to the contract. `route` tells local from cloud.
  func mapError(_ error: Error, route: Route) -> HybridError
}

// MARK: - In-flight requests: timeout and cancel

/// One running `generate`. Whichever of result, timeout or cancel arrives
/// first completes the call; later arrivals are discarded.
final class InFlight {
  private let lock = NSLock()
  private var done = false
  private var completion: ((Result<[String: Any], HybridError>) -> Void)?
  private var tasks: [Task<Void, Never>] = []
  /// Runs once, before the completion, when the call finishes.
  var onDone: (() -> Void)?

  init(completion: @escaping (Result<[String: Any], HybridError>) -> Void) {
    self.completion = completion
  }

  /// Keeps `task` so a finish cancels it; cancels it now if already finished.
  func attach(_ task: Task<Void, Never>) {
    lock.lock()
    if done {
      lock.unlock()
      task.cancel()
      return
    }
    tasks.append(task)
    lock.unlock()
  }

  /// Returns false when the call had already completed.
  @discardableResult
  func finish(_ result: Result<[String: Any], HybridError>) -> Bool {
    lock.lock()
    guard !done, let completion else {
      lock.unlock()
      return false
    }
    done = true
    self.completion = nil
    let tasks = self.tasks
    self.tasks = []
    let onDone = self.onDone
    self.onDone = nil
    lock.unlock()
    for task in tasks { task.cancel() }
    onDone?()
    completion(result)
    return true
  }
}

// MARK: - The bridge

/// Everything the method channel does, minus Flutter types.
final class HybridBridge {
  private let engine: HybridEngine
  private let lock = NSLock()
  private var cloudModel: String?
  private var inFlight: [String: InFlight] = [:]

  init(engine: HybridEngine) {
    self.engine = engine
  }

  // configure: {cloudModel, androidModel, languages}. Never fatal: a missing
  // or invalid model name just leaves the native cloud route unready.
  func configure(_ raw: Any?) {
    let args = raw as? [String: Any]
    let name = (args?["cloudModel"] as? String)?.trimmingCharacters(in: .whitespaces)
    let valid = name.map { n in
      !n.isEmpty && n.allSatisfy { !$0.isWhitespace && !$0.isNewline && $0 != "/" }
    } ?? false
    lock.lock()
    cloudModel = valid ? name : nil
    lock.unlock()
  }

  private var currentCloudModel: String? {
    lock.lock()
    defer { lock.unlock() }
    return cloudModel
  }

  func capabilities() -> [String: Any] {
    var modes: [HybridMode] = []
    if engine.localSupported || engine.cloudSupported { modes.append(.preferOnDevice) }
    if engine.localSupported { modes.append(.onlyOnDevice) }
    if engine.cloudSupported { modes.append(.onlyInCloud) }
    let local: Any =
      engine.localSupported
      ? [
        "modelFamily": LocalLimits.modelFamily,
        "supportsImage": false,
        "supportsJsonSchema": false,
        "maxTotalTokens": LocalLimits.maxTotalTokens,
        "defaultOutputReserve": LocalLimits.defaultOutputReserve,
        "imageTokenEstimate": LocalLimits.imageTokenEstimate,
        "validatedLanguages": LocalLimits.validatedLanguages,
      ] as [String: Any]
      : NSNull()
    return [
      "platform": "ios",
      "local": local,
      "maxImages": AttachmentLimits.maxImages,
      "maxImageBytes": AttachmentLimits.maxImageBytes,
      "maxImageDimension": AttachmentLimits.maxImageDimension,
      "supportedModes": modes.map(\.rawValue),
    ]
  }

  /// Per modality (§4): the local model is text only.
  func availability(_ raw: Any?) -> [String: Any] {
    let withImage = ((raw as? [String: Any])?["withImage"] as? Bool) ?? false
    if withImage {
      return ["status": "unavailable", "reason": AvailabilityReason.imageNotSupportedLocally]
    }
    switch engine.localStatus() {
    case .available:
      return ["status": "available"]
    case .unavailable(let reason):
      return ["status": "unavailable", "reason": reason]
    }
  }

  /// Nothing to download on iOS. Ready → complete; not usable → error, so a
  /// listener never mistakes an unusable model for a ready one.
  func prepare(_ raw: Any?) -> HybridError? {
    let withImage = ((raw as? [String: Any])?["withImage"] as? Bool) ?? false
    if withImage {
      return HybridError(.unavailable, AvailabilityReason.imageNotSupportedLocally)
    }
    if case .unavailable(let reason) = engine.localStatus() {
      return HybridError(.unavailable, reason)
    }
    return nil
  }

  /// Completes exactly once, within the request's timeout.
  func generate(
    _ raw: Any?, bytes: (Any) -> Data?,
    completion: @escaping (Result<[String: Any], HybridError>) -> Void
  ) {
    let request: BridgeRequest
    let route: Route
    let plan: PromptPlan
    let model = currentCloudModel
    do {
      request = try BridgeRequest.parse(raw, bytes: bytes)
      route = try planRoute(
        request, local: engine.localStatus(),
        cloudReady: engine.cloudReady(cloudModel: model))
      plan = try buildPrompt(request)
    } catch let e as HybridError {
      completion(.failure(e))
      return
    } catch {
      completion(.failure(HybridError(.failed, "\(error)")))
      return
    }

    let requestId = request.requestId
    let call = InFlight(completion: completion)
    call.onDone = { [weak self, weak call] in
      if let call { self?.remove(requestId, call) }
    }
    lock.lock()
    if inFlight[requestId] != nil {
      lock.unlock()
      completion(.failure(HybridError(.busy, "Request \(requestId) is already running")))
      return
    }
    inFlight[requestId] = call
    lock.unlock()

    let engine = self.engine
    let maxOutputTokens = request.maxOutputTokens
    let wantsJSON = request.jsonSchemaText != nil
    let mode = request.mode
    // Single turn: the engine builds a new session for every request.
    let work = Task.detached(priority: .userInitiated) {
      do {
        let reply = try await engine.generate(
          route: route, plan: plan, maxOutputTokens: maxOutputTokens, cloudModel: model)
        let text = wantsJSON ? stripCodeFence(reply.text) : reply.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          call.finish(.failure(HybridError(.failed, "Empty response")))
          return
        }
        let source = route.source
        if mode == .onlyOnDevice && source != .onDevice {
          call.finish(.failure(HybridError(.failed, "onlyOnDevice reached the cloud")))
          return
        }
        // modelLabel is omitted: neither SDK reports the model that answered.
        call.finish(.success([
          "requestId": requestId,
          "text": text,
          "source": source.rawValue,
        ]))
      } catch is CancellationError {
        call.finish(.failure(HybridError(.cancelled, "Cancelled")))
      } catch let e as HybridError {
        call.finish(.failure(e))
      } catch {
        call.finish(.failure(engine.mapError(error, route: route)))
      }
    }
    call.attach(work)
    let timeoutMs = request.timeoutMs
    let timer = Task.detached {
      try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
      if Task.isCancelled { return }
      call.finish(.failure(HybridError(.timeout, "Timed out after \(timeoutMs) ms")))
    }
    call.attach(timer)
  }

  /// Stops the SDK work where it honours cancellation and completes the call
  /// with `cancelled` either way; a late result is discarded.
  func cancel(_ raw: Any?) {
    guard let requestId = (raw as? [String: Any])?["requestId"] as? String else { return }
    lock.lock()
    let call = inFlight[requestId]
    lock.unlock()
    call?.finish(.failure(HybridError(.cancelled, "Cancelled")))
  }

  /// Ends every running call, e.g. when the engine detaches.
  func cancelAll() {
    lock.lock()
    let calls = Array(inFlight.values)
    lock.unlock()
    for call in calls { call.finish(.failure(HybridError(.cancelled, "Cancelled"))) }
  }

  var runningCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return inFlight.count
  }

  private func remove(_ requestId: String, _ call: InFlight) {
    lock.lock()
    if inFlight[requestId] === call { inFlight[requestId] = nil }
    lock.unlock()
  }
}

/// Cloud HTTP failures. 401 and App Check rejections are attestation
/// failures; 429 / RESOURCE_EXHAUSTED is quota.
func mapCloudAPIError(status: Int?, code: String, message: String, detail: String) -> HybridError {
  let lowered = message.lowercased()
  if status == 429 || code == "RESOURCE_EXHAUSTED" {
    return HybridError(.quota, detail)
  }
  if status == 401 || code == "UNAUTHENTICATED"
    || (status == 403 && (lowered.contains("app check") || lowered.contains("attestation")))
  {
    return HybridError(.attestation, detail)
  }
  if let status, status >= 500 {
    return HybridError(.network, detail)
  }
  return HybridError(.failed, detail)
}
