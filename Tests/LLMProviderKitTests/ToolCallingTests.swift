import Foundation
import Testing
@testable import LLMProviderKit

struct ToolCallingTests {
  private let tool = LLMToolDefinition(name: "search_chapter_cards", description: "Read cards",
    parameters: Data(#"{"type":"object","properties":{"query":{"type":"string"}}}"#.utf8))

  @Test func wireContainsStandardToolPairsAndPlainRequestsRemainPlain() throws {
    let provider = try OpenAICompatibleProvider(profile: profile(), apiKey: "fixture")
    let call = LLMToolCall(id: "call_1", name: tool.name, arguments: #"{"query":"渡口"}"#)
    let request = LLMRequest(requestID: UUID(), messages: [
      .init(role: .user, content: "回读"),
      .init(role: .assistant, content: "", toolCalls: [call]),
      .init(role: .tool, content: "卡片", toolCallID: call.id),
    ], tools: [tool], toolChoice: LLMToolChoice.none)
    let body = try #require(provider.makeURLRequest(request).httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["tool_choice"] as? String == "none")
    #expect(object["parallel_tool_calls"] as? Bool == false)
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages[1]["content"] is NSNull)
    let calls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
    #expect(calls[0]["id"] as? String == "call_1")
    #expect((calls[0]["function"] as? [String: String])?["arguments"] == call.arguments)
    #expect(messages[2]["tool_call_id"] as? String == call.id)
    let plain = try #require(provider.makeURLRequest(.init(requestID: UUID(),
      messages: [.init(role: .user, content: "正文")])).httpBody)
    let plainObject = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
    #expect(plainObject["tools"] == nil)
    #expect(plainObject["tool_choice"] == nil)
    #expect(plainObject["parallel_tool_calls"] == nil)
  }

  @Test func wireRejectsOrphansDuplicatesUnfinishedCallsAndForeignDefinitions() throws {
    let provider = try OpenAICompatibleProvider(profile: profile(), apiKey: "fixture")
    let call = LLMToolCall(id: "a", name: tool.name, arguments: "{}")
    let cases: [[LLMMessage]] = [
      [.init(role: .tool, content: "x", toolCallID: "orphan")],
      [.init(role: .assistant, content: "", toolCalls: [call])],
      [.init(role: .assistant, content: "", toolCalls: [call, call])],
      [.init(role: .user, content: "", toolCalls: [call])],
      [.init(role: .assistant, content: "", toolCalls: [call]),
       .init(role: .user, content: "interleaved"), .init(role: .tool, content: "x", toolCallID: "a")],
    ]
    for messages in cases {
      #expect(throws: LLMToolError.invalidRequest) {
        try provider.makeURLRequest(.init(requestID: UUID(), messages: messages, tools: [tool]))
      }
    }
    #expect(throws: LLMToolError.invalidRequest) {
      try provider.makeURLRequest(.init(requestID: UUID(), messages: [],
        tools: [LLMToolDefinition(name: "../file", description: "", parameters: Data("{}".utf8))]))
    }
  }

  @Test func splitAndOutOfOrderToolFragmentsAssembleOnceByIndex() throws {
    var parser = OpenAICompatibleSSEParser()
    let lines = [
      #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"search_","arguments":"{\"query\":"}},{"index":0,"id":"a","type":"function","function":{"name":"search_chapter_cards","arguments":"{}"}}]}}]}"#,
      #"{"choices":[{"index":1,"delta":{"content":"ignored"}},{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"name":"chapter_cards","arguments":"\"渡口\"}"}}]}}]}"#,
      #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
    ]
    let bytes = Data((lines.map { "data: " + $0 + "\n" }.joined() + "data: [DONE]\n").utf8)
    var events: [LLMStreamEvent] = []
    for byte in bytes { events += try parser.append(Data([byte])) }
    events += try parser.finish()
    #expect(events == [
      .toolCall(.init(id: "a", name: tool.name, arguments: "{}")),
      .toolCall(.init(id: "b", name: tool.name, arguments: #"{"query":"渡口"}"#)), .completed,
    ])
  }

  @Test func invalidOrTruncatedToolsNeverComplete() throws {
    let pending = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"search_chapter_cards","arguments":"{}"}}]}}]}"#
    for reason in ["stop", "length", "content_filter", "function_call"] {
      var parser = OpenAICompatibleSSEParser()
      _ = try parser.append(Data(("data: " + pending + "\n").utf8))
      #expect(throws: (any Error).self) {
        try parser.append(Data(("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"" + reason + "\"}]}\n").utf8))
      }
    }
    for fragment in [
      #"{"index":8,"id":"a","function":{"name":"x","arguments":"{}"}}"#,
      #"{"index":0,"id":"a","type":"file","function":{"name":"x","arguments":"{}"}}"#,
      #"{"index":1,"id":"a","function":{"name":"x","arguments":"{}"}}"#,
      #"{"index":0,"function":{"name":"x","arguments":"{}"}}"#,
    ] {
      var parser = OpenAICompatibleSSEParser()
      #expect(throws: LLMToolError.invalidCall) {
        try parser.append(Data(("data: {\"choices\":[{\"delta\":{\"tool_calls\":[" + fragment
          + "]},\"finish_reason\":\"tool_calls\"}]}\n").utf8))
      }
    }
    var parser = OpenAICompatibleSSEParser()
    #expect(throws: OpenAICompatibleError.invalidServerEvent) {
      try parser.append(Data(repeating: 65, count: 524_289))
    }
  }

  @Test func unsolicitedCallsAreRejectedByProvider() async throws {
    let bytes = Data(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"search_chapter_cards","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#.utf8)
    let provider = try OpenAICompatibleProvider(profile: profile(), apiKey: "fixture",
      transport: ToolTransport(bytes: bytes))
    for choice in [nil, LLMToolChoice.none] {
      await #expect(throws: LLMToolError.unexpectedCall) {
        for try await _ in provider.stream(.init(requestID: UUID(), messages: [],
          tools: choice == nil ? [] : [tool], toolChoice: choice)) {}
      }
    }
  }

  @Test func capabilityProbeRequiresRoundTripAndCachesByProfile() async {
    let responder = ProbeResponder()
    let provider = ProbeProvider(profile: profile(), responder: responder)
    let probe = LLMToolCapabilityProbe()
    async let first = probe.check(provider)
    async let second = probe.check(provider)
    #expect(await first == .supported)
    #expect(await second == .supported)
    #expect(await responder.count == 2)
    #expect(await probe.check(provider) == .supported)
    #expect(await responder.count == 2)
    await probe.invalidate(profileID: provider.profile.id)
    #expect(await probe.check(provider) == .supported)
    #expect(await responder.count == 4)
    await probe.recordDefinitiveRejection(provider.profile)
    #expect(await probe.check(provider) == .unsupported)
    #expect(await responder.count == 4)
  }

  @Test func cancellationStopsProbeAndDoesNotCacheAnUnsupportedVerdict() async throws {
    let responder = ProbeResponder(mode: .waiting)
    let profile = profile()
    let probe = LLMToolCapabilityProbe()
    let task = Task { await probe.check(ProbeProvider(profile: profile, responder: responder)) }
    for _ in 0..<100 {
      if await responder.count > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await responder.count == 1)
    task.cancel()
    #expect(await task.value == .unavailable)
    let ready = ProbeResponder()
    #expect(await probe.check(ProbeProvider(profile: profile, responder: ready)) == .supported)
    #expect(await ready.count == 2)
  }

  @Test func outputLimitDoesNotMasqueradeAsNormalTextCompletion() throws {
    var parser = OpenAICompatibleSSEParser()
    #expect(try parser.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n".utf8)) == [.textDelta("partial")])
    #expect(throws: LLMToolError.outputTruncated) {
      try parser.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n".utf8))
    }
  }

  @Test func probeDistinguishesUnsupportedFromUncertainAndHonorsOptOut() async {
    for mode in [ProbeResponder.Mode.reject, .noCall, .secondFails] {
      let responder = ProbeResponder(mode: mode)
      let probe = LLMToolCapabilityProbe()
      let provider = ProbeProvider(profile: profile(), responder: responder)
      let expected: LLMToolSupport = mode == .reject ? .unsupported : .unavailable
      #expect(await probe.check(provider) == expected)
      let count = await responder.count
      #expect(await probe.check(provider) == expected)
      #expect(await responder.count == count)
    }
    let responder = ProbeResponder()
    var off = profile()
    off.capabilities.toolCalling = false
    #expect(await LLMToolCapabilityProbe().check(ProbeProvider(profile: off, responder: responder)) == .unsupported)
    #expect(await responder.count == 0)
    #expect(!LLMToolCapabilityProbe.isDefinitiveRejection(OpenAICompatibleError.httpStatus(401, "tools unsupported")))
    #expect(!LLMToolCapabilityProbe.isDefinitiveRejection(OpenAICompatibleError.httpStatus(429, "tools unsupported")))
  }

  private func profile() -> ProviderProfile {
    .init(displayName: "fixture", kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1"), modelID: "fixture",
      credentialReference: UUID().uuidString, capabilities: .init(toolCalling: true))
  }
}

private struct ToolTransport: OpenAICompatibleStreamingTransport {
  let bytes: Data
  func stream(request: URLRequest) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { $0.yield(bytes); $0.finish() }
  }
}
private actor ProbeResponder {
  enum Mode { case valid, reject, noCall, secondFails, waiting }
  let mode: Mode
  var count = 0
  init(mode: Mode = .valid) { self.mode = mode }
  func respond(_ request: LLMRequest) async throws -> [LLMStreamEvent] {
    count += 1
    if mode == .waiting { try await Task.sleep(for: .seconds(10)) }
    if mode == .reject { throw OpenAICompatibleError.httpStatus(400, "tools unsupported") }
    if request.toolChoice == LLMToolChoice.none {
      if mode == .secondFails { throw OpenAICompatibleError.incompleteStream }
      return [.textDelta("OK"), .completed]
    }
    if mode == .noCall { return [.textDelta("OK"), .completed] }
    let text = request.messages[0].content
    let nonce = String(text.split(separator: " ").last!.dropLast())
    return [.toolCall(.init(id: UUID().uuidString, name: "worldbook_tool_probe",
      arguments: #"{"nonce":""# + nonce + #""}"#)), .completed]
  }
}
private struct ProbeProvider: LLMProvider {
  let profile: ProviderProfile
  let responder: ProbeResponder
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for event in try await responder.respond(request) { continuation.yield(event) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
