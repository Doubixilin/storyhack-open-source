import Foundation
import LLMProviderKit
import WritingCore

public enum AdaptationExecutionError: Error, Equatable, LocalizedError {
  case invalidBudget
  case inputTooLarge
  case requestLimitReached
  case incompleteStream
  case authentication
  case rateLimited
  case invalidSelection
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .invalidBudget: "模型窗口或输出预算无效，请调整模型设置。"
    case .inputTooLarge: "固定要求或最小原文片段超过完整请求预算，尚未发送模型请求。"
    case .requestLimitReached: "已达到本次新请求数量上限，完成结果已保留，可继续处理后续部分。"
    case .incompleteStream: "模型回复未完整结束，已保留待核对请求。"
    case .authentication: "模型认证被拒绝，请检查模型设置。"
    case .rateLimited: "模型请求被限流，已保存此前结果，可稍后继续。"
    case .invalidSelection: "章节或聚焦人物范围无效。"
    case .invalidResponse: "提取回复结构或原文证据无效，已保留有效部分与缺口。"
    }
  }
}

public struct AdaptationRequestBudget: Sendable {
  public let window: Int
  public let maximumOutputTokens: Int
  public var maximumInputTokens: Int { window - maximumOutputTokens - max(512, window / 20) }
  public init(profile: ProviderProfile) throws {
    window = profile.capabilities.contextWindow ?? 32_768
    maximumOutputTokens = profile.maximumOutputTokens ?? 4_096
    guard (2_048...2_000_000).contains(window), (512...65_536).contains(maximumOutputTokens),
      maximumOutputTokens < window - max(512, window / 20) else { throw AdaptationExecutionError.invalidBudget }
  }
  public func fits(system: String, prompt: String) -> Bool {
    LLMTokenEstimate.tokens(system) + LLMTokenEstimate.tokens(prompt) + 64 <= maximumInputTokens
  }
}

struct AdaptationRequestExecutor: Sendable {
  let provider: any LLMProvider
  let store: AdaptationJobStore

  var budget: AdaptationRequestBudget { get throws { try .init(profile: provider.profile) } }
  var fingerprint: String {
    get throws {
      let profile = provider.profile
      // Credentials, request IDs, display names and timeouts are not generation
      // inputs. The endpoint is hashed, never written in plaintext here.
      return try AdaptationCoding.fingerprint([
        "adaptation-direct-v1", profile.kind.rawValue, profile.baseURL?.absoluteString ?? "", profile.modelID,
        String(try budget.window), String(try budget.maximumOutputTokens),
        String(profile.capabilities.structuredOutput), "reasoning-low",
      ])
    }
  }
  func identity(sourceHash: String, purpose: String, unitID: String,
    system: String, prompt: String) throws -> AdaptationRequestIdentity {
    .init(sourceSnapshotHash: sourceHash, purpose: purpose, unitID: unitID,
      executorFingerprint: try fingerprint, inputFingerprint: try AdaptationCoding.fingerprint([system, prompt]))
  }

  func response(jobID: UUID, identity: AdaptationRequestIdentity, system: String,
    prompt: String, allowNewRequest: Bool) async throws -> (record: AdaptationResponseRecord, fromCache: Bool) {
    let budget = try budget
    guard budget.fits(system: system, prompt: prompt) else { throw AdaptationExecutionError.inputTooLarge }
    guard identity.executorFingerprint == (try fingerprint),
      identity.inputFingerprint == (try AdaptationCoding.fingerprint([system, prompt])) else {
      throw AdaptationExecutionError.invalidSelection
    }
    try Task.checkCancellation()
    if let pending = try await store.pendingRequest(jobID) { throw AdaptationRequestError.uncertain(pending) }
    if let cached = try await store.cachedResponse(jobID: jobID, identity: identity) { return (cached, true) }
    guard allowNewRequest else { throw AdaptationExecutionError.requestLimitReached }
    let start = try await store.beginRequest(jobID: jobID, identity: identity)
    switch start {
    case .cached(let record): return (record, true)
    case .send(let checkpoint):
      do {
      let request = LLMRequest(requestID: checkpoint.id, messages: [
        .init(role: .system, content: system), .init(role: .user, content: prompt),
      ], responseContract: .init(mode: provider.profile.capabilities.structuredOutput ? .jsonObject : .text),
        modelOptions: .init(maximumOutputTokens: budget.maximumOutputTokens, reasoningEffort: "low"))
      var text = "", bytes = 0, completed = false
      do {
        try Task.checkCancellation()
        stream: for try await event in provider.stream(request) {
          try Task.checkCancellation()
          switch event {
          case .textDelta(let delta):
            bytes += delta.utf8.count
            guard bytes <= 1_048_576 else { throw AdaptationRequestError.responseTooLarge }
            text += delta
          case .toolCall: throw LLMToolError.unexpectedCall
          case .completed: completed = true; break stream
          }
        }
      } catch let OpenAICompatibleError.httpStatus(code, _) where [401, 403, 429].contains(code) {
        try await store.recordRejectedRequest(checkpoint, statusCode: code)
        throw code == 429 ? AdaptationExecutionError.rateLimited : AdaptationExecutionError.authentication
      }
      try Task.checkCancellation()
      guard completed else { throw AdaptationExecutionError.incompleteStream }
      return (try await store.completeRequest(checkpoint, text: text), false)
      } catch {
        // URLSession may surface cancellation as URLError.cancelled rather
        // than CancellationError. Keep the checkpoint, but report the user's
        // cancellation consistently to App and CLI callers.
        throw AdaptationRequestAttemptError(underlying: Task.isCancelled ? CancellationError() : error)
      }
    }
  }
}

/// Distinguishes a newly registered attempt from cache reads and preflight
/// failures. It is not a token/billing receipt from the provider.
struct AdaptationRequestAttemptError: Error {
  let underlying: any Error
}
