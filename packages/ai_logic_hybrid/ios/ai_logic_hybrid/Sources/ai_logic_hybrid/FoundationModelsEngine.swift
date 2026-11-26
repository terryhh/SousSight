// The real engine: Apple's Foundation Models for the local model and
// FirebaseAILogic's GeminiLanguageModel for the cloud model.
//
// Firebase Apple SDK 13.0.0 removed HybridModel, SystemLanguageModel (the
// Firebase wrapper), GenerativeModelSession and the "apple-foundation-models-
// system-language-model" modelVersion report that DESIGN.md §3 describes.
// 13.1.1 (the version FlutterFire pins) offers `FirebaseAI.geminiLanguageModel
// (name:)`, a Foundation Models `LanguageModel` used with Apple's own
// `LanguageModelSession` (iOS 27+, built only by a Swift 6.4 compiler). So each
// request runs a new single-model session, and its source is the one model
// that session was built with.

import Foundation
import FirebaseAILogic
import FirebaseCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

#if compiler(>=6.4) && canImport(FoundationModels) && canImport(GeminiLanguageModel)
  import GeminiLanguageModel
#endif

final class FoundationModelsEngine: HybridEngine {
  var localSupported: Bool {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 26.0, *) { return true }
    #endif
    return false
  }

  var cloudSupported: Bool {
    #if compiler(>=6.4) && canImport(FoundationModels)
      if #available(iOS 27.0, macOS 27.0, *) { return true }
    #endif
    return false
  }

  func localStatus() -> LocalStatus {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
          return .available
        case .unavailable(let reason):
          switch reason {
          case .deviceNotEligible:
            return .unavailable(reason: AvailabilityReason.deviceNotEligible)
          case .appleIntelligenceNotEnabled:
            return .unavailable(reason: AvailabilityReason.appleIntelligenceOff)
          case .modelNotReady:
            return .unavailable(reason: AvailabilityReason.modelNotReady)
          @unknown default:
            return .unavailable(reason: AvailabilityReason.unknown)
          }
        }
      }
    #endif
    return .unavailable(reason: AvailabilityReason.osUnsupported)
  }

  func cloudReady(cloudModel: String?) -> Bool {
    guard cloudSupported, cloudModel != nil else { return false }
    // FirebaseAI.firebaseAI() calls fatalError without a configured default
    // app, project ID or API key; check first. On iOS the app is configured
    // when Dart calls Firebase.initializeApp.
    guard let app = FirebaseApp.app(), app.options.projectID != nil,
      app.options.apiKey != nil
    else { return false }
    return true
  }

  func generate(
    route: Route, plan: PromptPlan, maxOutputTokens: Int, cloudModel: String?
  ) async throws -> EngineReply {
    switch route {
    case .local:
      #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
          let session = LanguageModelSession(
            model: SystemLanguageModel.default, instructions: plan.instructions)
          let response = try await session.respond(
            to: plan.prompt,
            options: GenerationOptions(maximumResponseTokens: maxOutputTokens))
          return EngineReply(text: response.content)
        }
      #endif
      throw HybridError(.unavailable, AvailabilityReason.osUnsupported)
    case .cloud:
      #if compiler(>=6.4) && canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
          guard let cloudModel, cloudReady(cloudModel: cloudModel) else {
            throw HybridError(.unavailable, "No native cloud model is ready")
          }
          // Same backend as the app's Dart clients (FirebaseAI.googleAI()).
          let ai = FirebaseAI.firebaseAI(backend: .googleAI())
          let model = ai.geminiLanguageModel(name: cloudModel)
          let session = LanguageModelSession(model: model, instructions: plan.instructions)
          let response = try await session.respond(
            to: plan.prompt,
            options: GenerationOptions(maximumResponseTokens: maxOutputTokens))
          return EngineReply(text: response.content)
        }
      #endif
      throw HybridError(.unavailable, "No native cloud model in this build or OS")
    }
  }

  func mapError(_ error: Error, route: Route) -> HybridError {
    let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    if let e = error as? HybridError { return e }
    if error is CancellationError { return HybridError(.cancelled, "Cancelled") }

    #if compiler(>=6.4) && canImport(FoundationModels) && canImport(GeminiLanguageModel)
      if #available(iOS 27.0, macOS 27.0, *), let e = error as? GeminiLanguageModel.Error {
        switch e {
        case .networkFailure, .serviceUnavailable:
          return HybridError(.network, detail)
        case .apiError(let api):
          return mapCloudAPIError(
            status: api.statusCode, code: api.code, message: api.message, detail: detail)
        default:
          return HybridError(.failed, detail)
        }
      }
    #endif

    #if compiler(>=6.4) && canImport(FoundationModels)
      if #available(iOS 27.0, macOS 27.0, *) {
        if let e = error as? LanguageModelError {
          switch e {
          case .rateLimited:
            // On device this is Apple's per-app throttle; in the cloud it is
            // an HTTP 429 from the Gemini API.
            return HybridError(route == .local ? .busy : .quota, detail)
          case .guardrailViolation, .refusal:
            return HybridError(.blocked, detail)
          case .contextSizeExceeded, .unsupportedCapability, .unsupportedTranscriptContent,
            .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
            return HybridError(.unsupportedInput, detail)
          case .timeout:
            return HybridError(.timeout, detail)
          default:
            return HybridError(.failed, detail)
          }
        }
        if let e = error as? SystemLanguageModel.Error {
          switch e {
          case .assetsUnavailable:
            return HybridError(.unavailable, AvailabilityReason.modelNotReady)
          @unknown default:
            return HybridError(.unavailable, detail)
          }
        }
        if let e = error as? LanguageModelSession.Error {
          switch e {
          case .concurrentRequests:
            return HybridError(.busy, detail)
          default:
            return HybridError(.failed, detail)
          }
        }
      }
    #endif

    #if canImport(FoundationModels)
      if #available(iOS 26.0, macOS 26.0, *),
        let e = error as? LanguageModelSession.GenerationError
      {
        switch e {
        case .exceededContextWindowSize, .unsupportedLanguageOrLocale:
          return HybridError(.unsupportedInput, detail)
        case .assetsUnavailable:
          return HybridError(.unavailable, AvailabilityReason.modelNotReady)
        case .guardrailViolation, .refusal:
          return HybridError(.blocked, detail)
        case .rateLimited, .concurrentRequests:
          return HybridError(.busy, detail)
        case .unsupportedGuide, .decodingFailure:
          return HybridError(.failed, detail)
        @unknown default:
          return HybridError(.failed, detail)
        }
      }
    #endif

    if let e = error as? URLError {
      return HybridError(e.code == .timedOut ? .timeout : .network, detail)
    }
    return HybridError(.failed, detail)
  }
}
