import Foundation

public enum OpenAICompatibleError: Error, Equatable, LocalizedError {
  case invalidBaseURL
  case invalidHTTPResponse
  case httpStatus(Int, String)
  case invalidServerEvent
  case serverMessage(String)
  case stallTimeout(seconds: TimeInterval)
  /// 流干净结束（EOF）但从未收到 `[DONE]` 或 `finish_reason`：
  /// 响应可能被截断，结果不得当作完成提交。
  case incompleteStream

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      "OpenAI-compatible Base URL 无效"
    case .invalidHTTPResponse:
      "模型服务返回了无效的 HTTP 响应"
    case .httpStatus(let status, let body):
      body.isEmpty ? "模型服务返回 HTTP \(status)" : "模型服务返回 HTTP \(status)：\(body)"
    case .invalidServerEvent:
      "模型服务返回了无法解析的流式事件"
    case .serverMessage(let message):
      message
    case .stallTimeout(let seconds):
      "模型服务超过 \(Int(seconds.rounded())) 秒没有返回任何数据，流式响应已中断"
    case .incompleteStream:
      "模型响应流未正常结束（缺少完成标记），内容可能被截断"
    }
  }
}

public protocol OpenAICompatibleStreamingTransport: Sendable {
  func stream(request: URLRequest) -> AsyncThrowingStream<Data, any Error>
}

public struct URLSessionStreamingTransport: OpenAICompatibleStreamingTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func stream(request: URLRequest) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: request)
          guard let response = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.invalidHTTPResponse
          }
          guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            for try await byte in bytes {
              if body.count >= 64 * 1_024 { break }
              body.append(byte)
            }
            throw OpenAICompatibleError.httpStatus(
              response.statusCode,
              String(data: body, encoding: .utf8) ?? ""
            )
          }
          for try await line in bytes.lines {
            try Task.checkCancellation()
            continuation.yield(Data((line + "\n").utf8))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

public struct OpenAICompatibleProvider: LLMProvider {
  public let profile: ProviderProfile

  private let apiKey: String
  private let transport: any OpenAICompatibleStreamingTransport

  public init(
    profile: ProviderProfile,
    apiKey: String,
    transport: any OpenAICompatibleStreamingTransport = URLSessionStreamingTransport()
  ) throws {
    guard profile.kind == .openAICompatible,
      let baseURL = profile.baseURL,
      let scheme = baseURL.scheme?.lowercased(),
      let host = baseURL.host?.lowercased(),
      scheme == "https"
        || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    else {
      throw OpenAICompatibleError.invalidBaseURL
    }
    self.profile = profile
    self.apiKey = apiKey
    self.transport = transport
  }

  public func stream(
    _ request: LLMRequest
  ) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeURLRequest(request)
          // 防御性 clamp：profiles.json 可能被手工改出非法数值，
          // 保存时校验 + 这里兜底，绝不让 NaN/负数进入看门狗
          let stallTimeout = Self.sanitizedTimeout(
            profile.stallTimeoutInterval,
            fallback: ProviderProfile.defaultStallTimeoutInterval
          )
          let rawStream = withStallWatchdog(
            transport.stream(request: urlRequest),
            timeout: stallTimeout
          )
          var parser = OpenAICompatibleSSEParser()
          var completed = false
          for try await chunk in rawStream {
            for event in try parser.append(chunk) {
              try validate(event, for: request)
              if event == .completed { completed = true }
              continuation.yield(event)
            }
            if completed { break }
          }
          for event in try parser.finish() {
            try validate(event, for: request)
            if event == .completed { completed = true }
            continuation.yield(event)
          }
          // 未收到 [DONE] 或 finish_reason 的干净 EOF 视为截断：
          // 不得伪造完成，否则截断的叙事/JSON 会被当作完整结果提交。
          if !completed { throw OpenAICompatibleError.incompleteStream }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// 把可能来自手工编辑 JSON 的非法超时收敛到安全范围：
  /// 非有限值/非正数回落到默认值，超大值截到 1 小时上限。
  static func sanitizedTimeout(_ value: TimeInterval?, fallback: TimeInterval) -> TimeInterval {
    guard let value, value.isFinite, value > 0 else { return fallback }
    return min(value, 3_600)
  }

  func makeURLRequest(_ request: LLMRequest) throws -> URLRequest {
    guard let baseURL = profile.baseURL else {
      throw OpenAICompatibleError.invalidBaseURL
    }
    let endpoint: URL
    if baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .hasSuffix("chat/completions")
    {
      endpoint = baseURL
    } else {
      endpoint = baseURL.appendingPathComponent("chat/completions")
    }

    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = Self.sanitizedTimeout(
      profile.requestTimeoutInterval,
      fallback: ProviderProfile.defaultRequestTimeoutInterval
    )
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue(request.requestID.uuidString, forHTTPHeaderField: "X-Worldbook-Request-ID")
    let body = try JSONEncoder().encode(
      ChatCompletionRequest(
        model: profile.modelID,
        messages: request.messages.map {
          .init(role: $0.role.rawValue, content: $0.content)
        },
        temperature: request.modelOptions.temperature,
        maximumOutputTokens: request.modelOptions.maximumOutputTokens,
        reasoningEffort: request.modelOptions.reasoningEffort,
        responseFormat: request.responseContract.mode == .jsonObject
          ? .init(type: "json_object") : nil
      )
    )
    urlRequest.httpBody = try OpenAIToolWire.encode(request, baseBody: body)
    return urlRequest
  }

  private func validate(_ event: LLMStreamEvent, for request: LLMRequest) throws {
    if case .toolCall(let call) = event {
      guard request.toolChoice != LLMToolChoice.none,
        request.tools.contains(where: { $0.name == call.name }) else {
        throw LLMToolError.unexpectedCall
      }
    }
  }
}

private final class StreamIteratorBox: @unchecked Sendable {
  var iterator: AsyncThrowingStream<Data, any Error>.Iterator

  init(iterator: AsyncThrowingStream<Data, any Error>.Iterator) {
    self.iterator = iterator
  }
}

private func withStallWatchdog(
  _ stream: AsyncThrowingStream<Data, any Error>,
  timeout: TimeInterval
) -> AsyncThrowingStream<Data, any Error> {
  AsyncThrowingStream { continuation in
    let task = Task {
      let box = StreamIteratorBox(iterator: stream.makeAsyncIterator())
      do {
        while true {
          let next: Data? = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await box.iterator.next() }
            group.addTask {
              try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
              throw OpenAICompatibleError.stallTimeout(seconds: timeout)
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
          }
          guard let chunk = next else { break }
          continuation.yield(chunk)
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}

private struct ChatCompletionRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }

  struct ResponseFormat: Encodable {
    let type: String
  }

  let model: String
  let messages: [Message]
  let temperature: Double?
  let maximumOutputTokens: Int?
  let reasoningEffort: String?
  let responseFormat: ResponseFormat?
  let stream = true

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case temperature
    case maximumOutputTokens = "max_tokens"
    case reasoningEffort = "reasoning_effort"
    case responseFormat = "response_format"
    case stream
  }
}

struct OpenAICompatibleSSEParser {
  private struct Chunk: Decodable {
    struct Choice: Decodable {
      struct Delta: Decodable {
        struct ToolDelta: Decodable {
          struct Function: Decodable {
            let name: String?
            let arguments: String?
          }
          let index: Int
          let id: String?
          let type: String?
          let function: Function?
        }
        let content: String?
        let toolCalls: [ToolDelta]?
        enum CodingKeys: String, CodingKey {
          case content
          case toolCalls = "tool_calls"
        }
      }

      let delta: Delta
      let index: Int?
      let finishReason: String?

      enum CodingKeys: String, CodingKey {
        case delta
        case index
        case finishReason = "finish_reason"
      }
    }

    struct APIError: Decodable {
      let message: String
    }

    let choices: [Choice]?
    let error: APIError?
  }

  private var buffer = Data()
  private var didComplete = false
  private struct PendingCall {
    var id = ""
    var name = ""
    var arguments = ""
  }
  private var pending: [Int: PendingCall] = [:]

  mutating func append(_ data: Data) throws -> [LLMStreamEvent] {
    guard data.count <= 524_288, buffer.count + data.count <= 524_288 else {
      throw OpenAICompatibleError.invalidServerEvent
    }
    buffer.append(data)
    var events: [LLMStreamEvent] = []
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      let lineData = buffer[..<newlineIndex]
      buffer.removeSubrange(...newlineIndex)
      events.append(contentsOf: try parseLine(Data(lineData)))
    }
    return events
  }

  mutating func finish() throws -> [LLMStreamEvent] {
    guard !buffer.isEmpty else { return [] }
    defer { buffer.removeAll(keepingCapacity: false) }
    return try parseLine(buffer)
  }

  private mutating func parseLine(_ data: Data) throws -> [LLMStreamEvent] {
    guard !didComplete else { return [] }
    guard var line = String(data: data, encoding: .utf8) else {
      throw OpenAICompatibleError.invalidServerEvent
    }
    if line.hasSuffix("\r") { line.removeLast() }
    guard line.hasPrefix("data:") else { return [] }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    guard !payload.isEmpty else { return [] }
    if payload == "[DONE]" {
      return try completeOnce(reason: "stop")
    }

    let chunk: Chunk
    do {
      chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
    } catch {
      throw OpenAICompatibleError.invalidServerEvent
    }
    if let message = chunk.error?.message {
      throw OpenAICompatibleError.serverMessage(message)
    }

    var events: [LLMStreamEvent] = []
    for choice in chunk.choices ?? [] where (choice.index ?? 0) == 0 {
      if let content = choice.delta.content, !content.isEmpty {
        events.append(.textDelta(content))
      }
      for fragment in choice.delta.toolCalls ?? [] {
        guard (0..<8).contains(fragment.index),
          fragment.type == nil || fragment.type == "function" else { throw LLMToolError.invalidCall }
        var call = pending[fragment.index] ?? PendingCall()
        if let id = fragment.id {
          guard call.id.isEmpty || call.id == id else { throw LLMToolError.invalidCall }
          call.id = id
        }
        call.name += fragment.function?.name ?? ""
        call.arguments += fragment.function?.arguments ?? ""
        guard call.id.utf8.count <= 128, call.name.utf8.count <= 64,
          call.arguments.utf8.count <= 8_192 else { throw LLMToolError.invalidCall }
        pending[fragment.index] = call
      }
      if let reason = choice.finishReason {
        events.append(contentsOf: try completeOnce(reason: reason))
      }
    }
    return events
  }

  private mutating func completeOnce(reason: String) throws -> [LLMStreamEvent] {
    guard !didComplete else { return [] }
    if ["length", "content_filter"].contains(reason) { throw LLMToolError.outputTruncated }
    guard reason == "stop" || reason == "tool_calls" else { throw LLMToolError.invalidCall }
    guard (reason == "tool_calls") == !pending.isEmpty else { throw LLMToolError.invalidCall }
    var calls: [LLMToolCall] = []
    for index in 0..<pending.count {
      guard let call = pending[index] else { throw LLMToolError.invalidCall }
      let assembled = LLMToolCall(id: call.id, name: call.name, arguments: call.arguments)
      guard assembled.isBounded, !calls.contains(where: { $0.id == assembled.id }) else {
        throw LLMToolError.invalidCall
      }
      calls.append(assembled)
    }
    didComplete = true
    return calls.map(LLMStreamEvent.toolCall) + [.completed]
  }
}
