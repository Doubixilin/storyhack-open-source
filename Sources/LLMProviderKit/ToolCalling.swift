import Foundation

public struct LLMToolDefinition: Equatable, Sendable {
  public let name: String
  public let description: String
  /// JSON Schema owned by the caller; never constructed from model output.
  public let parameters: Data
  public init(name: String, description: String, parameters: Data) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

public struct LLMToolCall: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let arguments: String
  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
  public var isBounded: Bool {
    !id.isEmpty && id.utf8.count <= 128 && Self.validName(name) && arguments.utf8.count <= 8_192
  }
  static func validName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 64
      && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
  }
}

public enum LLMToolChoice: String, Sendable { case auto, none, required }

public enum LLMToolError: String, Error, Equatable, LocalizedError {
  case invalidRequest, invalidCall, unexpectedCall, outputTruncated
  public var errorDescription: String? {
    switch self {
    case .invalidRequest: "工具请求格式不完整或超过限制。"
    case .invalidCall: "模型工具调用不完整或超过限制。"
    case .unexpectedCall: "模型在未允许工具调用时返回了工具请求，本轮未提交。"
    case .outputTruncated: "模型回复达到输出上限或被截断，本轮未提交。"
    }
  }
}

public enum LLMToolSupport: String, Sendable { case supported, unsupported, unavailable }

/// Session-local capability checks use only a synthetic nonce, never book content.
/// The flag in ProviderCapabilities enables checking; it is not proof of support.
public actor LLMToolCapabilityProbe {
  public static let shared = LLMToolCapabilityProbe()
  private struct Entry {
    let id: UUID
    let task: Task<LLMToolSupport, Never>
    let createdAt: Date
    var result: LLMToolSupport?
  }
  private var entries: [String: Entry] = [:]
  public init() {}

  public func invalidate(profileID: UUID) {
    let prefix = profileID.uuidString + "|"
    for key in entries.keys.filter({ $0.hasPrefix(prefix) }) {
      entries.removeValue(forKey: key)?.task.cancel()
    }
  }

  public func recordDefinitiveRejection(_ profile: ProviderProfile) {
    invalidate(profileID: profile.id)
    if entries.count >= 32, let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
      entries.removeValue(forKey: oldest)?.task.cancel()
    }
    entries[Self.key(profile)] = Entry(id: UUID(), task: Task { .unsupported },
      createdAt: Date(), result: .unsupported)
  }

  private static func key(_ profile: ProviderProfile) -> String {
    [profile.id.uuidString, profile.baseURL?.absoluteString ?? "", profile.modelID,
      profile.credentialReference].joined(separator: "|")
  }

  public func check(_ provider: any LLMProvider) async -> LLMToolSupport {
    guard provider.profile.kind == .openAICompatible, provider.profile.capabilities.toolCalling else {
      return .unsupported
    }
    let profile = provider.profile
    let key = Self.key(profile)
    let entry: Entry
    if let cached = entries[key],
      Date().timeIntervalSince(cached.createdAt) < (cached.result == .unavailable ? 30 : 600) {
      entry = cached
    } else {
      if entries.count >= 32, let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
        entries.removeValue(forKey: oldest)?.task.cancel()
      }
      entry = Entry(id: UUID(), task: Task { await Self.perform(provider) }, createdAt: Date())
      entries[key] = entry
    }
    let result = await withTaskCancellationHandler {
      await entry.task.value
    } onCancel: { entry.task.cancel() }
    // Transient failures get a short cooldown, not a permanent unsupported verdict.
    if entries[key]?.id == entry.id {
      if Task.isCancelled { entries.removeValue(forKey: key) }
      else { entries[key]?.result = result }
    }
    return result
  }

  public static func isDefinitiveRejection(_ error: any Error) -> Bool {
    guard case OpenAICompatibleError.httpStatus(let code, let body) = error,
      [400, 404, 422].contains(code) else { return false }
    let text = body.lowercased()
    return ["tool", "function_call"].contains(where: text.contains)
      && ["unsupported", "not support", "not supported", "unknown parameter", "unrecognized", "not available", "不支持"]
        .contains(where: text.contains)
  }

  private static func perform(_ provider: any LLMProvider) async -> LLMToolSupport {
    let nonce = UUID().uuidString.lowercased()
    let definition = LLMToolDefinition(name: "worldbook_tool_probe",
      description: "Echo this synthetic nonce to test tool support. No files or user data are involved.",
      parameters: Data(#"{"type":"object","properties":{"nonce":{"type":"string"}},"required":["nonce"],"additionalProperties":false}"#.utf8))
    let messages = [LLMMessage(role: .user, content: "Call worldbook_tool_probe once with nonce \(nonce).")]
    do {
      var calls: [LLMToolCall] = []
      var text = ""
      var completed = false
      for try await event in provider.stream(.init(requestID: UUID(), messages: messages,
        modelOptions: .init(maximumOutputTokens: 256), tools: [definition], toolChoice: .auto)) {
        try Task.checkCancellation()
        switch event {
        case .textDelta(let part):
          text += part
          guard text.utf8.count <= 4_096 else { return .unavailable }
        case .toolCall(let call):
          calls.append(call)
          guard calls.count <= 1, call.isBounded else { return .unavailable }
        case .completed: completed = true
        }
      }
      guard completed, calls.count == 1, calls[0].name == definition.name,
        let args = try? JSONDecoder().decode([String: String].self, from: Data(calls[0].arguments.utf8)),
        args == ["nonce": nonce] else { return .unavailable }
      let followup = messages + [
        .init(role: .assistant, content: text, toolCalls: calls),
        .init(role: .tool, content: "The probe succeeded. Reply briefly with OK.", toolCallID: calls[0].id),
      ]
      var finalText = ""
      completed = false
      for try await event in provider.stream(.init(requestID: UUID(), messages: followup,
        modelOptions: .init(maximumOutputTokens: 128), tools: [definition], toolChoice: LLMToolChoice.none)) {
        try Task.checkCancellation()
        switch event {
        case .toolCall: return .unavailable
        case .textDelta(let part):
          finalText += part
          guard finalText.utf8.count <= 4_096 else { return .unavailable }
        case .completed: completed = true
        }
      }
      return completed && !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .supported : .unavailable
    } catch {
      return isDefinitiveRejection(error) ? .unsupported : .unavailable
    }
  }
}
