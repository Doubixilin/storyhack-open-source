import Foundation

public enum LLMProviderKind: String, Codable, CaseIterable, Sendable {
  case openAICompatible = "openai_compatible"
  case anthropic
  case gemini
}

public struct ProviderCapabilities: Codable, Equatable, Sendable {
  public var streaming: Bool
  public var structuredOutput: Bool
  public var toolCalling: Bool
  public var imageInput: Bool
  public var contextWindow: Int?

  public init(
    streaming: Bool = true,
    structuredOutput: Bool = false,
    toolCalling: Bool = false,
    imageInput: Bool = false,
    contextWindow: Int? = nil
  ) {
    self.streaming = streaming
    self.structuredOutput = structuredOutput
    self.toolCalling = toolCalling
    self.imageInput = imageInput
    self.contextWindow = contextWindow
  }

  enum CodingKeys: String, CodingKey {
    case streaming
    case structuredOutput = "structured_output"
    case toolCalling = "tool_calling"
    case imageInput = "image_input"
    case contextWindow = "context_window"
  }
}

public struct ProviderProfile: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var displayName: String
  public var kind: LLMProviderKind
  public var baseURL: URL?
  public var modelID: String
  public var credentialReference: String
  public var capabilities: ProviderCapabilities
  public var requestTimeoutInterval: TimeInterval?
  public var stallTimeoutInterval: TimeInterval?
  /// 世界书工坊批次并发数；nil 表示默认 3，读取时按 1–16 clamp。
  public var factoryConcurrency: Int?
  /// Story turn output reservation; nil uses the application default.
  public var maximumOutputTokens: Int?

  public static let defaultRequestTimeoutInterval: TimeInterval = 120
  public static let defaultStallTimeoutInterval: TimeInterval = 300
  public static let defaultFactoryConcurrency: Int = 3
  public static let factoryConcurrencyRange: ClosedRange<Int> = 1...16

  /// 生效的工坊并发数：缺省 3，越界按 1–16 收敛。
  public var effectiveFactoryConcurrency: Int {
    min(
      Self.factoryConcurrencyRange.upperBound,
      max(
        Self.factoryConcurrencyRange.lowerBound,
        factoryConcurrency ?? Self.defaultFactoryConcurrency
      )
    )
  }

  public init(
    id: UUID = UUID(),
    displayName: String,
    kind: LLMProviderKind,
    baseURL: URL? = nil,
    modelID: String,
    credentialReference: String,
    capabilities: ProviderCapabilities = .init(),
    requestTimeoutInterval: TimeInterval? = nil,
    stallTimeoutInterval: TimeInterval? = nil,
    factoryConcurrency: Int? = nil,
    maximumOutputTokens: Int? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.baseURL = baseURL
    self.modelID = modelID
    self.credentialReference = credentialReference
    self.capabilities = capabilities
    self.requestTimeoutInterval = requestTimeoutInterval
    self.stallTimeoutInterval = stallTimeoutInterval
    self.factoryConcurrency = factoryConcurrency
    self.maximumOutputTokens = maximumOutputTokens
  }

  enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case kind
    case baseURL = "base_url"
    case modelID = "model_id"
    case credentialReference = "credential_reference"
    case capabilities
    case requestTimeoutInterval = "request_timeout_interval"
    case stallTimeoutInterval = "stall_timeout_interval"
    case factoryConcurrency = "factory_concurrency"
    case maximumOutputTokens = "maximum_output_tokens"
  }
}

public struct LLMMessage: Codable, Equatable, Sendable, Identifiable {
  public enum Role: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
  }

  public let id: UUID
  public let role: Role
  public let content: String
  public let toolCalls: [LLMToolCall]?
  public let toolCallID: String?

  public init(id: UUID = UUID(), role: Role, content: String,
    toolCalls: [LLMToolCall]? = nil, toolCallID: String? = nil) {
    self.id = id
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }
}

public struct LLMResponseContract: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Sendable {
    case text
    case jsonObject = "json_object"
  }

  public var mode: Mode

  public init(mode: Mode = .text) { self.mode = mode }
}

public struct LLMModelOptions: Codable, Equatable, Sendable {
  public var temperature: Double?
  public var maximumOutputTokens: Int?
  /// 思考强度（如 "low"/"high"/"max"）；nil 时请求体不携带该字段，
  /// 保持对其它 OpenAI-compatible 服务的兼容。
  public var reasoningEffort: String?

  public init(
    temperature: Double? = nil,
    maximumOutputTokens: Int? = nil,
    reasoningEffort: String? = nil
  ) {
    self.temperature = temperature
    self.maximumOutputTokens = maximumOutputTokens
    self.reasoningEffort = reasoningEffort
  }
}

public struct LLMRequest: Sendable {
  public let requestID: UUID
  public let messages: [LLMMessage]
  public let responseContract: LLMResponseContract
  public let modelOptions: LLMModelOptions
  public let tools: [LLMToolDefinition]
  public let toolChoice: LLMToolChoice?

  public init(
    requestID: UUID,
    messages: [LLMMessage],
    responseContract: LLMResponseContract = .init(),
    modelOptions: LLMModelOptions = .init(),
    tools: [LLMToolDefinition] = [],
    toolChoice: LLMToolChoice? = nil
  ) {
    self.requestID = requestID
    self.messages = messages
    self.responseContract = responseContract
    self.modelOptions = modelOptions
    self.tools = tools
    self.toolChoice = toolChoice
  }
}

public enum LLMStreamEvent: Equatable, Sendable {
  case textDelta(String)
  /// Fully assembled, bounded call. No operation has been executed by the provider.
  case toolCall(LLMToolCall)
  case completed
}

public protocol LLMProvider: Sendable {
  var profile: ProviderProfile { get }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
}
