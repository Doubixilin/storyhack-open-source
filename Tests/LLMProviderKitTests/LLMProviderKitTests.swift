import Foundation
import Testing

@testable import LLMProviderKit

struct LLMProviderKitTests {
  @Test func contextBudgetRoundTripsAndRejectsImpossibleOutput() async throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: container) }
    let store = ProviderProfileStore(rootURL: container, credentialStore: MemoryCredentialStore())
    var profile = ProviderProfile(
      displayName: "small", kind: .openAICompatible, baseURL: URL(string: "https://example.com/v1"),
      modelID: "test", credentialReference: "test", capabilities: .init(contextWindow: 8_192),
      maximumOutputTokens: 1_024)
    try await store.save(profile: profile, apiKey: "secret")
    #expect(try await store.list() == [profile])
    profile.maximumOutputTokens = 8_000
    await #expect(throws: ProviderConfigurationError.invalidContextBudget) {
      try await store.save(profile: profile, apiKey: nil)
    }
    let saved = try #require(try await store.list().first)
    #expect(saved.maximumOutputTokens == 1_024)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
    object.removeValue(forKey: "maximum_output_tokens")
    let old = try JSONDecoder().decode(ProviderProfile.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.maximumOutputTokens == nil)
  }

  @Test
  func providerProfilesPersistWithoutAPIKey() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let credentials = MemoryCredentialStore()
    let store = ProviderProfileStore(rootURL: container, credentialStore: credentials)
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test"
    )

    try await store.save(profile: profile, apiKey: "secret-value")

    let data = try Data(contentsOf: container.appendingPathComponent("profiles.json"))
    let persisted = try #require(String(data: data, encoding: .utf8))
    #expect(persisted.contains("credential-test"))
    #expect(!persisted.contains("secret-value"))
    #expect(try await store.list() == [profile])
    #expect(try await store.apiKey(for: profile.id) == "secret-value")
  }

  @Test
  func openAICompatibleRequestUsesChatCompletionsAndBearerCredential() throws {
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test"
    )
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: "secret-value",
      transport: FakeStreamingTransport(chunks: [])
    )
    let request = try provider.makeURLRequest(
      LLMRequest(
        requestID: UUID(),
        messages: [LLMMessage(role: .user, content: "你好")],
        responseContract: .init(mode: .jsonObject),
        modelOptions: .init(temperature: 0.2, maximumOutputTokens: 512)
      )
    )

    #expect(request.url?.absoluteString == "https://example.com/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value")
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "example-model")
    #expect(object["stream"] as? Bool == true)
    #expect(object["temperature"] as? Double == 0.2)
    #expect(object["max_tokens"] as? Int == 512)
    #expect((object["response_format"] as? [String: String])?["type"] == "json_object")
    #expect(request.value(forHTTPHeaderField: "X-Worldbook-Request-ID") != nil)
    #expect(request.value(forHTTPHeaderField: "X-Worldbook-Turn-ID") == nil)
  }

  @Test
  func openAICompatibleProviderParsesSplitSSEStream() async throws {
    let chunks = [
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"},\"finish_reason\":null}]}\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":null}]}\n\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n".utf8),
      Data("data: [DONE]\n".utf8),
    ]
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test"
    )
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: "secret-value",
      transport: FakeStreamingTransport(chunks: chunks)
    )
    let request = LLMRequest(
      requestID: UUID(),
      messages: [LLMMessage(role: .user, content: "你好")]
    )

    var events: [LLMStreamEvent] = []
    for try await event in provider.stream(request) {
      events.append(event)
    }

    #expect(events == [.textDelta("你"), .textDelta("好"), .completed])
  }

  @Test
  func streamWithoutCompletionMarkerThrowsIncompleteStream() async throws {
    // 干净 EOF 但既没有 [DONE] 也没有 finish_reason：内容可能被截断，
    // 必须抛错而不是伪装完成（partial delta 仍应先送达）。
    let chunks = [
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"},\"finish_reason\":null}]}\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":null}]}\n\n".utf8),
    ]
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test"
    )
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: "secret-value",
      transport: FakeStreamingTransport(chunks: chunks)
    )
    let request = LLMRequest(
      requestID: UUID(),
      messages: [LLMMessage(role: .user, content: "你好")]
    )

    var events: [LLMStreamEvent] = []
    await #expect(throws: OpenAICompatibleError.incompleteStream) {
      for try await event in provider.stream(request) {
        events.append(event)
      }
    }
    #expect(events == [.textDelta("你"), .textDelta("好")])
  }

  @Test
  func streamWithFinishReasonButWithoutDoneCompletes() async throws {
    // 部分服务只发 finish_reason 不发 [DONE]，仍应判定为正常完成
    let chunks = [
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":null}]}\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n".utf8),
    ]
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test"
    )
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: "secret-value",
      transport: FakeStreamingTransport(chunks: chunks)
    )
    let request = LLMRequest(
      requestID: UUID(),
      messages: [LLMMessage(role: .user, content: "你好")]
    )

    var events: [LLMStreamEvent] = []
    for try await event in provider.stream(request) {
      events.append(event)
    }
    #expect(events == [.textDelta("好"), .completed])
  }

  @Test
  func storyEnvelopeRequiresNarrativeAndJSONObjectPatch() throws {
    let response = """
      <STORY>你推开了档案室的门。</STORY>
      <STATE_PATCH>{"location":"档案室"}</STATE_PATCH>
      """
    let envelope = try StoryResponseEnvelopeParser.parse(response)
    #expect(envelope.narrative == "你推开了档案室的门。")
    #expect(envelope.beatID == nil)
    let patch = try #require(
      JSONSerialization.jsonObject(with: envelope.statePatchData) as? [String: Any]
    )
    #expect(patch["location"] as? String == "档案室")
    #expect(throws: StoryResponseEnvelopeError.missingStatePatch) {
      try StoryResponseEnvelopeParser.parse("<STORY>只有故事</STORY>")
    }
    #expect(throws: StoryResponseEnvelopeError.invalidStatePatch) {
      try StoryResponseEnvelopeParser.parse(
        "<STORY>故事</STORY><STATE_PATCH>[]</STATE_PATCH>"
      )
    }
  }

  @Test
  func storyEnvelopeParsesBoundedChoicesWithoutBlockingNarrative() throws {
    let envelope = try StoryResponseEnvelopeParser.parse(
      """
      <STORY>雨幕里出现了两条路。</STORY>
      <CHOICES>["沿原著线索追向旧码头","绕去钟楼寻找新的盟友","绕去钟楼寻找新的盟友"]</CHOICES>
      <STATE_PATCH>{}</STATE_PATCH>
      """
    )
    #expect(envelope.choices == ["沿原著线索追向旧码头", "绕去钟楼寻找新的盟友"])

    let malformed = try StoryResponseEnvelopeParser.parseRecovering(
      "<STORY>仍可继续。</STORY><CHOICES>{bad}</CHOICES><STATE_PATCH>{}</STATE_PATCH>"
    )
    #expect(malformed.narrative == "仍可继续。")
    #expect(malformed.choices.isEmpty)
  }

  @Test
  func providerErrorsUseFriendlyMessagesWithoutRawPayloads() {
    let balance = ProviderErrorMessage.message(
      for: OpenAICompatibleError.httpStatus(
        402,
        #"{"error":{"message":"Insufficient Balance","code":"invalid_request_error"}}"#
      )
    )
    #expect(balance == "模型账户余额不足，请充值后重试。")
    #expect(!balance.contains("402"))
    #expect(!balance.contains("{"))
    #expect(
      ProviderErrorMessage.message(for: OpenAICompatibleError.httpStatus(429, "rate limit"))
        == "请求太频繁，模型服务正在限流，请稍等片刻再试。"
    )
    #expect(
      ProviderErrorMessage.message(for: URLError(.notConnectedToInternet))
        == "无法连接模型服务，请检查网络和服务地址后重试。"
    )
  }

  @Test
  func modelResponseParseFailureBuildsBoundedReadableSummaries() {
    #expect(ModelResponseParseFailure(rawResponse: "").responseSummary == "（空回复）")
    #expect(ModelResponseParseFailure(rawResponse: " \n\t ").responseSummary == "（空回复）")
    #expect(
      ModelResponseParseFailure(rawResponse: #"{"error":"refused"}"#).responseSummary
        == #"{"error":"refused"}"#
    )
    #expect(
      ModelResponseParseFailure(rawResponse: "<STORY>半截输出").responseSummary
        == "<STORY>半截输出"
    )
    #expect(
      ModelResponseParseFailure(rawResponse: "第一行 \n  第二行\r\n\t第三行").responseSummary
        == "第一行 第二行 第三行"
    )
    #expect(ModelResponseParseFailure(rawResponse: String(repeating: "字", count: 121)).responseSummary.count == 120)
  }

  @Test
  func providerErrorMessageExplicitlyPreservesParseSummaryContainingJSONBraces() {
    let message = ProviderErrorMessage.message(
      for: ModelResponseParseFailure(rawResponse: #"{"finish_reason":"content_filter"}"#)
    )
    #expect(message == #"模型这次没有给出可用回复，可重试；摘要：{"finish_reason":"content_filter"}"#)
  }

  @Test
  func storyEnvelopeParsesOptionalBeatTag() throws {
    let withBeat = try StoryResponseEnvelopeParser.parse(
      """
      <STORY>你随众人入了英雄大宴。</STORY>
      <STATE_PATCH>{"location":"陆家庄"}</STATE_PATCH>
      <BEAT>beat-hero-feast</BEAT>
      """
    )
    #expect(withBeat.beatID == "beat-hero-feast")

    let withNone = try StoryResponseEnvelopeParser.parse(
      """
      <STORY>你在后山闲逛。</STORY>
      <STATE_PATCH>{}</STATE_PATCH>
      <BEAT>none</BEAT>
      """
    )
    #expect(withNone.beatID == nil)

    let recovered = try StoryResponseEnvelopeParser.parseRecovering(
      "自由探索。<BEAT>beat-free-roam</BEAT>"
    )
    #expect(recovered.beatID == "beat-free-roam")
  }

  @Test
  func storyEnvelopeParsesOptionalPlotTag() throws {
    let withPlot = try StoryResponseEnvelopeParser.parse(
      """
      <STORY>你继续赶路。</STORY>
      <STATE_PATCH>{}</STATE_PATCH>
      <BEAT>none</BEAT>
      <PLOT>plot-0007</PLOT>
      """
    )
    #expect(withPlot.plotNodeID == "plot-0007")

    let withoutPlot = try StoryResponseEnvelopeParser.parse(
      """
      <STORY>你原地休息。</STORY>
      <STATE_PATCH>{}</STATE_PATCH>
      """
    )
    #expect(withoutPlot.plotNodeID == nil)

    let recovered = try StoryResponseEnvelopeParser.parseRecovering(
      "继续探索。<PLOT>plot-0003</PLOT>"
    )
    #expect(recovered.plotNodeID == "plot-0003")

    let nonePlot = try StoryResponseEnvelopeParser.parse(
      """
      <STORY>停留。</STORY>
      <STATE_PATCH>{}</STATE_PATCH>
      <PLOT>none</PLOT>
      """
    )
    #expect(nonePlot.plotNodeID == nil)
  }

  @Test
  func storyEnvelopeRecoversReadableNarrativeWithoutDiscardingTheTurn() throws {
    let plainNarrative = """
      少年伏在冬青之后，望着陆家庄内的动静，心中仍在犹豫是否出手。

      厅内又传来一声惊呼，李莫愁的拂尘已经扬起。
      """
    let recovered = try StoryResponseEnvelopeParser.parseRecovering(plainNarrative)
    #expect(recovered.narrative == plainNarrative)
    #expect(recovered.statePatchData == Data("{}".utf8))
    // 缺少 <STORY> 包装不再打扰用户：只剩"未提供状态补丁"一条警告
    #expect(recovered.recoveryWarnings.count == 1)
    #expect(recovered.recoveryWarnings.allSatisfy { !$0.contains("<STORY>") })

    let invalidPatch = try StoryResponseEnvelopeParser.parseRecovering(
      "<STORY>你推开院门。</STORY><STATE_PATCH>[]</STATE_PATCH>"
    )
    #expect(invalidPatch.narrative == "你推开院门。")
    #expect(invalidPatch.statePatchData == Data("{}".utf8))
    #expect(invalidPatch.recoveryWarnings.count == 1)

    #expect(throws: StoryResponseEnvelopeError.missingNarrative) {
      try StoryResponseEnvelopeParser.parseRecovering(
        "<STATE_PATCH>{\"location\":\"陆家庄\"}</STATE_PATCH>"
      )
    }
  }

  @Test
  func legacyProfileJSONWithoutTimeoutFieldsDecodesWithDefaults() throws {
    let legacyJSON = """
      {
        "id": "5A1A2D39-0F13-4E6B-9B22-9E0E2C1E7A10",
        "display_name": "旧配置",
        "kind": "openai_compatible",
        "base_url": "https://example.com/v1",
        "model_id": "example-model",
        "credential_reference": "credential-test",
        "capabilities": {
          "streaming": true,
          "structured_output": false,
          "tool_calling": false,
          "image_input": false
        }
      }
      """
    let profile = try JSONDecoder().decode(ProviderProfile.self, from: Data(legacyJSON.utf8))
    #expect(profile.requestTimeoutInterval == nil)
    #expect(profile.stallTimeoutInterval == nil)
    #expect(
      profile.requestTimeoutInterval ?? ProviderProfile.defaultRequestTimeoutInterval == 120
    )
    #expect(
      profile.stallTimeoutInterval ?? ProviderProfile.defaultStallTimeoutInterval == 300
    )
    // 旧 JSON 没有 factory_concurrency 字段：解码为 nil，生效值为默认 3
    #expect(profile.factoryConcurrency == nil)
    #expect(profile.effectiveFactoryConcurrency == ProviderProfile.defaultFactoryConcurrency)
  }

  @Test
  func factoryConcurrencyDecodesAndClampsToValidRange() throws {
    let base = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test"
    )
    #expect(base.effectiveFactoryConcurrency == 3)

    var tuned = base
    tuned.factoryConcurrency = 8
    let data = try JSONEncoder().encode(tuned)
    let decoded = try JSONDecoder().decode(ProviderProfile.self, from: data)
    #expect(decoded.factoryConcurrency == 8)
    #expect(decoded.effectiveFactoryConcurrency == 8)
    #expect(String(data: data, encoding: .utf8)?.contains("\"factory_concurrency\":8") == true)

    var tooHigh = base
    tooHigh.factoryConcurrency = 999
    #expect(tooHigh.effectiveFactoryConcurrency == 16)
    var tooLow = base
    tooLow.factoryConcurrency = 0
    #expect(tooLow.effectiveFactoryConcurrency == 1)
  }

  @Test
  func reasoningEffortOnlyAppearsInRequestBodyWhenSet() throws {
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test"
    )
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: "secret-value",
      transport: FakeStreamingTransport(chunks: [])
    )
    func bodyObject(_ options: LLMModelOptions) throws -> [String: Any] {
      let request = try provider.makeURLRequest(
        LLMRequest(
          requestID: UUID(),
          messages: [LLMMessage(role: .user, content: "你好")],
          modelOptions: options
        )
      )
      let body = try #require(request.httpBody)
      return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // 设置思考强度：请求体携带 reasoning_effort
    let withEffort = try bodyObject(.init(reasoningEffort: "low"))
    #expect(withEffort["reasoning_effort"] as? String == "low")
    // 不设置：请求体不出现该 key，保持对其它 OpenAI-compatible 服务的兼容
    let withoutEffort = try bodyObject(.init(temperature: 0.2))
    #expect(withoutEffort["reasoning_effort"] == nil)
  }

  @Test
  func openAICompatibleRequestTimeoutIsConfigurable() throws {
    let baseURL = URL(string: "https://example.com/v1")!
    let defaultProfile = ProviderProfile(
      displayName: "默认配置",
      kind: .openAICompatible,
      baseURL: baseURL,
      modelID: "example-model",
      credentialReference: "credential-test"
    )
    let customProfile = ProviderProfile(
      displayName: "自定义配置",
      kind: .openAICompatible,
      baseURL: baseURL,
      modelID: "example-model",
      credentialReference: "credential-test",
      requestTimeoutInterval: 45,
      stallTimeoutInterval: 60
    )
    let llmRequest = LLMRequest(
      requestID: UUID(),
      messages: [LLMMessage(role: .user, content: "你好")]
    )

    let defaultProvider = try OpenAICompatibleProvider(
      profile: defaultProfile,
      apiKey: "secret-value",
      transport: FakeStreamingTransport(chunks: [])
    )
    #expect(try defaultProvider.makeURLRequest(llmRequest).timeoutInterval == 120)

    let customProvider = try OpenAICompatibleProvider(
      profile: customProfile,
      apiKey: "secret-value",
      transport: FakeStreamingTransport(chunks: [])
    )
    #expect(try customProvider.makeURLRequest(llmRequest).timeoutInterval == 45)
  }

  @Test
  func stalledStreamThrowsStallTimeout() async throws {
    let chunks = [
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"},\"finish_reason\":null}]}\n".utf8)
    ]
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test",
      stallTimeoutInterval: 0.1
    )
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: "secret-value",
      transport: DelayedStreamingTransport(chunks: chunks, hangAfterLastYield: true)
    )
    let request = LLMRequest(
      requestID: UUID(),
      messages: [LLMMessage(role: .user, content: "你好")]
    )

    var events: [LLMStreamEvent] = []
    var thrown: (any Error)?
    do {
      for try await event in provider.stream(request) {
        events.append(event)
      }
    } catch {
      thrown = error
    }

    #expect(events == [.textDelta("你")])
    #expect(thrown as? OpenAICompatibleError == .stallTimeout(seconds: 0.1))
  }

  @Test
  func stallWatchdogAlsoCoversTheWaitForTheFirstEvent() async throws {
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test",
      stallTimeoutInterval: 0.1
    )
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: "secret-value",
      transport: DelayedStreamingTransport(chunks: [], hangAfterLastYield: true)
    )
    let request = LLMRequest(
      requestID: UUID(),
      messages: [LLMMessage(role: .user, content: "你好")]
    )

    var thrown: (any Error)?
    do {
      for try await _ in provider.stream(request) {}
    } catch {
      thrown = error
    }

    #expect(thrown as? OpenAICompatibleError == .stallTimeout(seconds: 0.1))
  }

  @Test
  func reasoningHeartbeatChunksKeepTheStreamAliveWithoutTriggeringTheWatchdog() async throws {
    let chunks = [
      Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"思考\"},\"finish_reason\":null}]}\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"继续\"},\"finish_reason\":null}]}\n".utf8),
      Data("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\n".utf8),
      Data("data: [DONE]\n".utf8),
    ]
    let profile = ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test",
      stallTimeoutInterval: 0.5
    )
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: "secret-value",
      transport: DelayedStreamingTransport(chunks: chunks, delayBetweenChunks: 0.05)
    )
    let request = LLMRequest(
      requestID: UUID(),
      messages: [LLMMessage(role: .user, content: "你好")]
    )

    var events: [LLMStreamEvent] = []
    for try await event in provider.stream(request) {
      events.append(event)
    }

    #expect(events == [.textDelta("你好"), .completed])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["WORLDBOOK_SSE_PROBE_URL"] != nil))
  func liveURLSessionSSETransportWhenProbeURLIsConfigured() async throws {
    guard let value = ProcessInfo.processInfo.environment["WORLDBOOK_SSE_PROBE_URL"],
      let baseURL = URL(string: value)
    else { return }
    let profile = ProviderProfile(
      displayName: "本机 SSE 验收",
      kind: .openAICompatible,
      baseURL: baseURL,
      modelID: "probe-model",
      credentialReference: "probe"
    )
    let provider = try OpenAICompatibleProvider(profile: profile, apiKey: "probe-key")
    let request = LLMRequest(
      requestID: UUID(),
      messages: [LLMMessage(role: .user, content: "probe")]
    )

    var events: [LLMStreamEvent] = []
    for try await event in provider.stream(request) { events.append(event) }
    #expect(events == [.textDelta("本机"), .textDelta("流式"), .completed])
  }
}

private struct FakeStreamingTransport: OpenAICompatibleStreamingTransport {
  let chunks: [Data]

  func stream(request _: URLRequest) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
  }
}

private struct DelayedStreamingTransport: OpenAICompatibleStreamingTransport {
  let chunks: [Data]
  var delayBetweenChunks: TimeInterval = 0
  var hangAfterLastYield: Bool = false

  func stream(request _: URLRequest) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        for chunk in chunks {
          if delayBetweenChunks > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayBetweenChunks * 1_000_000_000))
          }
          guard !Task.isCancelled else { return }
          continuation.yield(chunk)
        }
        if hangAfterLastYield {
          try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
          guard !Task.isCancelled else { return }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private final class MemoryCredentialStore: ProviderCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]

  func save(_ secret: String, reference: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values[reference] = secret
  }

  func load(reference: String) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard let value = values[reference] else {
      throw ProviderConfigurationError.missingCredential(reference)
    }
    return value
  }

  func delete(reference: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values.removeValue(forKey: reference)
  }
}
