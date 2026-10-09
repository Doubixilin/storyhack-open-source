import Foundation
import LLMProviderKit
import StoryworldCore
import Testing
@testable import StorySessionCore

@Suite("Scoped chapter tools")
struct ChapterToolTests {
  private static let final = #"<STORY>你回想渡口旧事，继续在塔下等待。</STORY><CHOICES>["继续等待","询问眼前的人"]</CHOICES><STATE_PATCH>{}</STATE_PATCH><MEMORY_PATCH>{}</MEMORY_PATCH>"#
  private static func call(_ id: String, _ args: String = "{}") -> LLMStreamEvent {
    .toolCall(.init(id: id, name: StoryChapterSearch.definition.name, arguments: args))
  }
  private static let plot = StoryPlotline(nodes: [
    .init(id: "p1", title: "渡口旧章", summary: "旧章原著钥匙", order: 1, chapterOrdinal: 0),
    .init(id: "p2", title: "跳过的密室", summary: "未到过的密码甲", order: 2, chapterOrdinal: 1),
    .init(id: "p3", title: "山路旧章", summary: "旧章原著路标", order: 3, chapterOrdinal: 2),
    .init(id: "p4", title: "跳过的谷底", summary: "未到过的密码乙", order: 4, chapterOrdinal: 3),
    .init(id: "p5", title: "当前石塔", summary: "原著石塔场景", order: 5, chapterOrdinal: 4),
    .init(id: "p6", title: "未来之门", summary: "未来秘密丙", order: 6, chapterOrdinal: 5),
  ], source: "synthetic")

  @Test func searchUsesRecordedEffectiveNodesAndNeverOpensSkippedOrFutureChapters() async throws {
    let f = try await fixture()
    defer { f.clean() }
    try await commit(f, node: 1)
    let child = try await f.runtime.forkBranch(address: f.address, atEventSequence: 1, title: "child")
    try await commit(f, node: 3)
    try await commit(f, node: 5)
    _ = try await f.runtime.commitTurn(address: child.address, turnID: UUID(), userMessage: "跳至石塔",
      narrative: "来到塔下", statePatchData: Data(#"{"plot":{"node":5}}"#.utf8))
    let parent = StoryChapterSearch(snapshot: try await f.runtime.load(address: f.address), plotline: Self.plot)
    let branch = StoryChapterSearch(snapshot: try await f.runtime.load(address: child.address), plotline: Self.plot)
    #expect(parent.cards.map(\.id) == ["p1", "p3"])
    #expect(branch.cards.map(\.id) == ["p1"])
    let all = try branch.execute(.init(id: "a", name: StoryChapterSearch.definition.name, arguments: "{}"))
    #expect(all.cardIDs == ["p1"])
    #expect(!all.text.contains("密码") && !all.text.contains("未来") && !all.text.contains("路标"))
    let future = try branch.execute(.init(id: "a", name: StoryChapterSearch.definition.name,
      arguments: #"{"chapter_ids":["p6"]}"#))
    let missing = try branch.execute(.init(id: "a", name: StoryChapterSearch.definition.name,
      arguments: #"{"chapter_ids":["not-present"]}"#))
    #expect(future.text == missing.text)
    #expect(try parent.execute(.init(id: "a", name: StoryChapterSearch.definition.name,
      arguments: #"{"query":"渡口"}"#)).cardIDs == ["p1"])
  }

  @Test func searchIsBoundedAndInvalidInputCannotReadPathsOrPartialCards() async throws {
    let f = try await fixture()
    defer { f.clean() }
    try await commit(f, node: 1)
    try await commit(f, node: 3)
    try await commit(f, node: 5)
    let snapshot = try await f.runtime.load(address: f.address)
    var plot = Self.plot
    plot.nodes[2].summary = String(repeating: "超长摘要", count: 2_000)
    let search = StoryChapterSearch(snapshot: snapshot, plotline: plot)
    let result = try search.execute(.init(id: "a", name: StoryChapterSearch.definition.name, arguments: "{}"))
    #expect(result.cardIDs == ["p1"])
    #expect(!result.text.contains("超长"))
    #expect(result.text.utf8.count <= 2_048 && StoryContextCompiler.estimatedTokens(result.text) <= 768)
    for args in [#"{"path":"/etc/passwd"}"#, #"{"limit":100}"#, #"{"chapter_ids":"p1"}"#, "[]"] {
      let invalid = try search.execute(.init(id: "a", name: StoryChapterSearch.definition.name, arguments: args))
      #expect(invalid.cardIDs.isEmpty && invalid.text.contains("invalid_query"))
    }
    #expect(throws: LLMToolError.invalidCall) {
      try search.execute(.init(id: "a", name: "read_file", arguments: "{}"))
    }
    #expect(throws: LLMToolError.invalidCall) {
      try search.execute(.init(id: "a", name: StoryChapterSearch.definition.name, arguments: String(repeating: "a", count: 513)))
    }
  }

  @Test func spaceSeparatedKeywordsMatchIndividuallyAndRequireAllTerms() async throws {
    let f = try await fixture()
    defer { f.clean() }
    try await commit(f, node: 1)
    try await commit(f, node: 3)
    try await commit(f, node: 5)
    let search = StoryChapterSearch(snapshot: try await f.runtime.load(address: f.address), plotline: Self.plot)
    // 含完整标题加多余关键词的查询：整串不是连续子串，但逐词均命中 p3。
    let hit = try search.execute(.init(id: "a", name: StoryChapterSearch.definition.name,
      arguments: #"{"query":"山路旧章 原著 路标"}"#))
    #expect(hit.cardIDs == ["p3"])
    // 全角空格同样按分隔符处理；任一关键词缺失时不得命中。
    let fullWidth = try search.execute(.init(id: "a", name: StoryChapterSearch.definition.name,
      arguments: #"{"query":"山路旧章　原著路标"}"#))
    #expect(fullWidth.cardIDs == ["p3"])
    let miss = try search.execute(.init(id: "a", name: StoryChapterSearch.definition.name,
      arguments: #"{"query":"山路旧章 不存在的词"}"#))
    #expect(miss.cardIDs.isEmpty)
    // 多关键词叠加章节 ID 过滤仍同时生效。
    let scoped = try search.execute(.init(id: "a", name: StoryChapterSearch.definition.name,
      arguments: #"{"query":"旧章 钥匙","chapter_ids":["p3","p1"]}"#))
    #expect(scoped.cardIDs == ["p1"])
    // 空数组是“不限定章节”，不得当作限定为空集而零命中。
    let unscoped = try search.execute(.init(id: "a", name: StoryChapterSearch.definition.name,
      arguments: #"{"query":"山路旧章","chapter_ids":[]}"#))
    #expect(unscoped.cardIDs == ["p3"])
  }

  @Test func promptsOmitUnrecordedMetadataAndDoNotCallPreviousOrderAlreadyHappened() async throws {
    let f = try await fixture()
    defer { f.clean() }
    try await commit(f, node: 1)
    try await commit(f, node: 5)
    let snapshot = try await f.runtime.load(address: f.address)
    let doc = try await f.library.load(storyworldID: f.world)
    let request = try await StoryTurnEngine().makeRequest(turnID: UUID(), userMessage: "继续",
      snapshot: snapshot, storyworld: doc, isCorrectionRetry: false)
    let system = request.messages[0].content
    #expect(system.contains("渡口旧章") && system.contains("当前石塔"))
    #expect(!system.contains("跳过") && !system.contains("未来秘密") && !system.contains("未记录节拍"))
    #expect(!system.contains("前一章（已发生）"))
    #expect(!request.messages.contains { $0.role == .tool })
  }

  @Test func engineProbesThenReadsTwoRoundsAndCommitsOnlyFinalNarrative() async throws {
    let f = try await fixture()
    defer { f.clean() }
    try await commit(f, node: 1)
    try await commit(f, node: 3)
    try await commit(f, node: 5)
    let provider = ChapterProvider(responses: [
      [.textDelta("中间工具说明"), Self.call("a", #"{"query":"渡口"}"#), .completed],
      [Self.call("b", #"{"chapter_ids":["p3"]}"#), .completed],
      [.textDelta(Self.final), .completed],
    ])
    let visible = NarrativeRecorder()
    let result = try await run(f, provider: provider, visible: visible)
    #expect(provider.requests.count == 5)
    let requests = provider.storyRequests
    #expect(requests.count == 3 && requests[2].toolChoice == LLMToolChoice.none)
    #expect(requests[1].messages.contains { $0.role == .tool && $0.content.contains("旧章原著钥匙") })
    #expect(requests[2].messages.contains { $0.role == .tool && $0.content.contains("旧章原著路标") })
    #expect(requests.allSatisfy { StoryContextCompiler.estimatedInputTokens($0) <= 27_034 })
    #expect(visible.values.allSatisfy { !$0.contains("中间工具说明") && !$0.contains("旧章原著") })
    #expect(result.snapshot.turns.count == 4)
    #expect(result.snapshot.turns.last?.narrative == "你回想渡口旧事，继续在塔下等待。")
    #expect(result.warnings.contains { $0.contains("回读 2 次") })
    #expect(!result.snapshot.turns.last!.narrative.contains("tool"))
  }

  @Test func unsupportedServiceFallsBackOnceAndSmallBudgetSkipsProbe() async throws {
    for tiny in [false, true] {
      let f = try await fixture()
      defer { f.clean() }
      try await commit(f, node: 1)
      try await commit(f, node: 5)
      let provider = ChapterProvider(responses: tiny
        ? [[.textDelta(Self.final), .completed]]
        : [[.textDelta(Self.final), .completed]], window: tiny ? 8_192 : 32_768,
        rejectFirstStoryTools: !tiny)
      let result = try await run(f, provider: provider)
      #expect(result.snapshot.turns.count == 3)
      if tiny {
        #expect(provider.requests.count == 1 && provider.storyRequests[0].tools.isEmpty)
        #expect(result.warnings.contains { $0.contains("没有足够") })
      } else {
        #expect(provider.requests.count == 4 && provider.storyRequests.count == 2)
        #expect(provider.storyRequests.last?.tools.isEmpty == true)
        #expect(!provider.storyRequests.last!.messages.contains { $0.role == .tool })
        #expect(result.warnings.contains { $0.contains("回退") })
      }
    }
  }

  @Test func finalToolProtocolResidueNeverReachesVisibleOrPersistedNarrative() async throws {
    let f = try await fixture()
    defer { f.clean() }
    try await commit(f, node: 1)
    try await commit(f, node: 5)
    let prose = "你回想铜钥匙的来历，停在塔下。"
    _ = try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "记录位置",
      narrative: "站在塔下。", statePatchData: Data(#"{"location":"塔下"}"#.utf8))
    let raw = "<STORY>" + prose + "</｜｜DSML｜｜parameter>\n</｜｜DSML｜｜invoke>\n</｜｜DSML｜｜tool_calls>"
    let provider = ChapterProvider(responses: [
      [Self.call("a"), .completed],
      [Self.call("b"), .completed],
      raw.map { .textDelta(String($0)) } + [.completed],
      [.textDelta("<STATE_PATCH>{}</STATE_PATCH>"), .completed],
    ])
    let visible = NarrativeRecorder()
    let result = try await run(f, provider: provider, visible: visible)
    #expect(provider.storyRequests.count == 4)
    #expect(result.snapshot.turns.count == 4)
    #expect(result.snapshot.turns.last?.narrative == prose)
    #expect(try await f.runtime.load(address: f.address).turns.last?.narrative == prose)
    #expect(visible.values.allSatisfy { prose.hasPrefix($0) })
    #expect(result.warnings.contains { $0.contains("工具协议") })
    #expect(!result.warnings.contains { $0.contains("模型未提供状态补丁") })
  }

  @Test func toolLoopAndCallCountLimitsRejectWithoutCommitting() async throws {
    let scripts: [[[LLMStreamEvent]]] = [
      [[Self.call("a"), .completed], [Self.call("b"), .completed], [Self.call("c"), .completed]],
      [[Self.call("a"), Self.call("b"), Self.call("c"), Self.call("d"), Self.call("e"), .completed]],
      [[Self.call("a"), .completed], [Self.call("a"), .completed]],
    ]
    for script in scripts {
      let f = try await fixture()
      defer { f.clean() }
      try await commit(f, node: 1)
      try await commit(f, node: 5)
      let provider = ChapterProvider(responses: script)
      await #expect(throws: LLMToolError.invalidCall) { try await run(f, provider: provider) }
      #expect(try await f.runtime.load(address: f.address).turns.count == 2)
      #expect(provider.storyRequests.count <= 3)
    }
  }

  @Test func canonChangedDuringToolReadRejectsFinalCommit() async throws {
    let f = try await fixture()
    defer { f.clean() }
    try await commit(f, node: 1)
    try await commit(f, node: 5)
    let provider = ChapterProvider(responses: [
      [Self.call("a"), .completed], [.textDelta(Self.final), .completed],
    ], onStoryRequest: { index in
      if index == 1 {
        var changed = Self.plot
        changed.nodes[0].summary = "改变后的原著"
        try StoryworldCoding.makeEncoder().encode(changed).write(to: f.package.appendingPathComponent("plotline.json"))
      }
    })
    await #expect(throws: (any Error).self) { try await run(f, provider: provider) }
    #expect(try await f.runtime.load(address: f.address).turns.count == 2)
  }

  @Test func cancellationDuringToolFollowupLeavesHistoryUntouched() async throws {
    let f = try await fixture()
    defer { f.clean() }
    try await commit(f, node: 1)
    try await commit(f, node: 5)
    let provider = ChapterProvider(responses: [
      [Self.call("a"), .completed], [.textDelta(Self.final), .completed],
    ], onStoryRequest: { index in
      if index == 1 { throw CancellationError() }
    })
    await #expect(throws: CancellationError.self) { try await run(f, provider: provider) }
    #expect(try await f.runtime.load(address: f.address).turns.count == 2)
    #expect(provider.storyRequests.count == 2)
  }

  @Test func commonKeywordCannotRevealAnUnrecordedBeatViaFallbackOrEventMetadata() async throws {
    let f = try await fixture()
    defer { f.clean() }
    let provider = ChapterProvider(responses: [
      [.textDelta("<STORY>你回到渡口。</STORY><STATE_PATCH>{}</STATE_PATCH><MEMORY_PATCH>{}</MEMORY_PATCH><BEAT>unseen</BEAT>"), .completed],
      [.textDelta("修复无有效选项"), .completed],
    ])
    let result = try await run(f, provider: provider)
    #expect(result.snapshot.turns.last?.beatID == nil)
    #expect(!result.choices.joined().contains("未记录节拍"))
    let doc = try await f.library.load(storyworldID: f.world)
    let next = try await StoryTurnEngine().makeRequest(turnID: UUID(), userMessage: "继续",
      snapshot: result.snapshot, storyworld: doc, isCorrectionRetry: false)
    #expect(!next.messages[0].content.contains("不应注入的后续事"))
  }

  private func fixture() async throws -> MemoryFixture {
    let f = try await MemoryFixture.make()
    try StoryworldCoding.makeEncoder().encode(Self.plot).write(to: f.package.appendingPathComponent("plotline.json"))
    let timeline = StoryTimeline(beats: [
      .init(id: "unseen", title: "未记录节拍", summary: "不应注入的后续事", order: 1, keywords: ["渡口"]),
    ], source: "synthetic")
    try StoryworldCoding.makeEncoder().encode(timeline).write(to: f.package.appendingPathComponent("timeline.json"))
    let status = try await f.runtime.canonStatus(address: f.address)
    try await f.runtime.confirmCanonBinding(address: f.address, expectedCurrent: #require(status.current),
      expectedBindingID: status.bindingID)
    return f
  }
  private func commit(_ f: MemoryFixture, node: Int) async throws {
    _ = try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "测试行动",
      narrative: "合成历史片段", statePatchData: Data("{\"plot\":{\"node\":\(node)}}".utf8))
  }
  private func run(_ f: MemoryFixture, provider: ChapterProvider,
    visible: NarrativeRecorder = NarrativeRecorder()) async throws -> StoryTurnResult {
    let snapshot = try await f.runtime.load(address: f.address)
    let doc = try await f.library.load(storyworldID: f.world)
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine(recapInterval: 0).runTurn(provider: provider, runtime: f.runtime,
      storyworld: doc, snapshot: snapshot, userMessage: "回想旧事", turnID: UUID(), isCorrectionRetry: false) {
      switch event {
      case .narrative(let text): visible.append(text)
      case .completed(let value): result = value
      }
    }
    return try #require(result)
  }
}

private final class NarrativeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  var values: [String] { lock.withLock { recorded } }
  func append(_ value: String) { lock.withLock { recorded.append(value) } }
}
private final class ChapterProvider: LLMProvider, @unchecked Sendable {
  let profile: ProviderProfile
  private let lock = NSLock()
  private var recorded: [LLMRequest] = []
  private var responses: [[LLMStreamEvent]]
  private var storyCount = 0
  private let rejectFirstStoryTools: Bool
  private let onStoryRequest: @Sendable (Int) async throws -> Void
  init(responses: [[LLMStreamEvent]], window: Int = 32_768,
    rejectFirstStoryTools: Bool = false,
    onStoryRequest: @escaping @Sendable (Int) async throws -> Void = { _ in }) {
    self.responses = responses
    self.rejectFirstStoryTools = rejectFirstStoryTools
    self.onStoryRequest = onStoryRequest
    self.profile = .init(displayName: "synthetic", kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1"), modelID: "synthetic",
      credentialReference: UUID().uuidString, capabilities: .init(toolCalling: true, contextWindow: window),
      maximumOutputTokens: 2_048)
  }
  var requests: [LLMRequest] { lock.withLock { recorded } }
  var storyRequests: [LLMRequest] { requests.filter { $0.tools.first?.name != "worldbook_tool_probe" } }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    lock.withLock { recorded.append(request) }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let events: [LLMStreamEvent]
          if request.tools.first?.name == "worldbook_tool_probe" {
            if request.toolChoice == LLMToolChoice.none { events = [.textDelta("OK"), .completed] }
            else {
              let nonce = String(request.messages[0].content.split(separator: " ").last!.dropLast())
              events = [.toolCall(.init(id: UUID().uuidString, name: "worldbook_tool_probe",
                arguments: #"{"nonce":""# + nonce + #""}"#)), .completed]
            }
          } else {
            let index = lock.withLock { let n = storyCount; storyCount += 1; return n }
            try await onStoryRequest(index)
            if rejectFirstStoryTools && index == 0 {
              throw OpenAICompatibleError.httpStatus(400, "tools unsupported")
            }
            events = lock.withLock { responses.isEmpty ? [.completed] : responses.removeFirst() }
          }
          for event in events { try Task.checkCancellation(); continuation.yield(event) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
