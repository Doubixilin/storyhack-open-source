import Foundation
import LLMProviderKit
import StoryMaterialKit
import StorySessionCore
import StoryworldCore
import Testing

@Suite("EndingReport")
struct EndingReportTests {
  @Test("统计按投影有效历史、整张分支图与全部存档计数")
  func statisticsUseEffectiveHistoryAndWholeGraph() async throws {
    let fixture = try await makeEndingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let saves = fixture.graph.nodes.flatMap { $0.saves.map(\.save) }
    let statistics = EndingReportBuilder.build(
      effectiveTurns: fixture.snapshot.effectiveTurns,
      branchGraph: fixture.graph,
      saves: saves
    )

    #expect(fixture.snapshot.turns.count == 1)
    #expect(statistics.turnCount == 2)
    #expect(statistics.narrativeCharacterCount == 5)
    #expect(statistics.turnsWithChoicesCount == 1)
    #expect(statistics.branchCount == 2)
    #expect(statistics.saveCount == 2)
  }

  @Test("统计模板只渲染有数据源的维度")
  func statisticTemplatesDoNotInventUnsupportedDimensions() async {
    let statistics = EndingReportStatistics(
      turnCount: 12,
      narrativeCharacterCount: 3456,
      turnsWithChoicesCount: 7,
      branchCount: 3,
      saveCount: 2
    )
    let lines = await EndingReportBuilder.renderedStatisticLines(statistics: statistics)

    #expect(lines.count == 5)
    #expect(lines.contains { $0.contains("12") })
    #expect(lines.contains { $0.contains("3456") })
    #expect(lines.contains { $0.contains("7") })
    #expect(lines.contains { $0.contains("3") })
    #expect(lines.contains { $0.contains("2") })
    #expect(!lines.contains { $0.localizedCaseInsensitiveContains("days") || $0.contains("天数") })
  }

  @Test("判词提示落实禁词、classic、题材收尾、两条 few-shot 与输入预算")
  func oratorRequestContractWithProfile() async throws {
    let fixture = try await makeEndingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let profiled = StoryworldDocument(
      manifest: fixture.storyworld.manifest,
      lorebook: fixture.storyworld.lorebook,
      timeline: fixture.storyworld.timeline,
      plotline: fixture.storyworld.plotline,
      materialProfile: MaterialProfile(
        primaryGenre: "xianxia",
        confidence: 1,
        source: "test"
      )
    )
    let request = await EndingOrator().makeRequest(
      storyworld: profiled,
      snapshot: fixture.snapshot
    )
    let system = try #require(request.messages.first?.content)
    let user = try #require(request.messages.last?.content)

    for term in EndingOrator.forbiddenProductTerms {
      #expect(system.contains(term))
    }
    #expect(system.contains("classic"))
    #expect(system.contains("情色笔法明确排除"))
    #expect(system.contains("150–350"))
    #expect(system.contains("诗词般的判词收尾"))
    #expect(system.contains("非世界事实，只学笔法"))
    #expect(system.components(separatedBy: "参照 ").count - 1 == 2)
    #expect(user.count <= EndingOrator.maximumInputCharacterCount)
  }

  @Test("无 material profile 时不注入判词 few-shot")
  func oratorRequestWithoutProfileHasNoFewShot() async throws {
    let fixture = try await makeEndingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = await EndingOrator().makeRequest(
      storyworld: fixture.storyworld,
      snapshot: fixture.snapshot
    )
    let system = try #require(request.messages.first?.content)
    #expect(!system.contains("非世界事实，只学笔法"))
    #expect(!system.contains("参照 1"))
  }

  @Test("报告持久化后重复打开不调用模型，重新生成才调用")
  func workflowPersistsReusesAndRegenerates() async throws {
    let fixture = try await makeEndingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = RecordingEndingProvider(responses: [
      .text("第一份判词。"),
      .text("第二份判词。"),
    ])
    let workflow = EndingReportWorkflow()

    let first = try await collect(
      workflow.open(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: fixture.snapshot,
        branchGraph: fixture.graph
      )
    )
    #expect(provider.callCount == 1)
    #expect(first.contains { if case .textDelta = $0 { true } else { false } })
    let persisted = try #require(
      try await fixture.runtime.loadEndingReport(address: fixture.snapshot.context.address)
    )
    #expect(persisted.verdict == "第一份判词。")
    #expect(persisted.generatedAtEffectiveTurnCount == 2)

    let second = try await collect(
      workflow.open(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: fixture.snapshot,
        branchGraph: fixture.graph
      )
    )
    #expect(provider.callCount == 1)
    #expect(second.contains {
      if case .completed(_, reusedExisting: true) = $0 { true } else { false }
    })

    let regenerated = try await collect(
      workflow.open(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: fixture.snapshot,
        branchGraph: fixture.graph,
        regenerate: true
      )
    )
    #expect(provider.callCount == 2)
    #expect(regenerated.contains {
      if case .completed(let report, reusedExisting: false) = $0 {
        report.verdict == "第二份判词。"
      } else { false }
    })
  }

  @Test("判词失败自动重试一次并保持流式事件")
  func workflowRetriesOnce() async throws {
    let fixture = try await makeEndingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = RecordingEndingProvider(responses: [
      .failure(TestEndingError.failed),
      .text("重试后的判词。"),
    ])
    let events = try await collect(
      EndingReportWorkflow().open(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: fixture.snapshot,
        branchGraph: fixture.graph,
        regenerate: true
      )
    )
    #expect(provider.callCount == 2)
    #expect(events.filter { if case .resetVerdict = $0 { true } else { false } }.count == 2)
    #expect(events.contains { if case .textDelta("重试后的判词。") = $0 { true } else { false } })
  }

  @Test("少于十回需确认，十回起直接进入")
  func readinessThreshold() {
    #expect(EndingReadiness(effectiveTurnCount: 9).requiresConfirmation)
    #expect(!EndingReadiness(effectiveTurnCount: 10).requiresConfirmation)
  }
}

private struct EndingFixture {
  let root: URL
  let runtime: StoryworldRuntimeStore
  let storyworld: StoryworldDocument
  let snapshot: StorySessionSnapshot
  let graph: StoryBranchGraph
}

private func makeEndingFixture() async throws -> EndingFixture {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("ending-report-tests-\(UUID().uuidString)", isDirectory: true)
  let library = StoryworldLibrary(rootURL: root.appendingPathComponent("library"))
  let record = try await library.create(
    lorebook: Lorebook(title: "测试世界", entries: [])
  )
  let packageURL = try await library.managedPackageURL(storyworldID: record.id)
  let runtime = StoryworldRuntimeStore(packageURL: packageURL)
  let context = try await runtime.createPlaythrough(title: "一生")
  _ = try await runtime.commitTurn(
    address: context.address,
    turnID: UUID(),
    userMessage: "出发",
    narrative: "甲乙",
    choices: ["向东", "向西"]
  )
  _ = try await runtime.createSave(address: context.address, title: "旧日")
  let child = try await runtime.forkBranch(address: context.address, title: "后路")
  _ = try await runtime.commitTurn(
    address: child.address,
    turnID: UUID(),
    userMessage: "继续",
    narrative: "丙丁戊"
  )
  _ = try await runtime.createSave(address: child.address, title: "此刻")
  return EndingFixture(
    root: root,
    runtime: runtime,
    storyworld: try await library.load(storyworldID: record.id),
    snapshot: try await runtime.load(address: child.address),
    graph: try await runtime.loadBranchGraph(playthroughID: context.playthrough.id)
  )
}

private func collect(
  _ stream: AsyncThrowingStream<EndingReportWorkflowEvent, Error>
) async throws -> [EndingReportWorkflowEvent] {
  var events: [EndingReportWorkflowEvent] = []
  for try await event in stream { events.append(event) }
  return events
}

private enum TestEndingError: Error {
  case failed
}

private final class RecordingEndingProvider: LLMProvider, @unchecked Sendable {
  enum Response {
    case text(String)
    case failure(any Error)
  }

  private let lock = NSLock()
  private var responses: [Response]
  private var calls = 0

  init(responses: [Response]) {
    self.responses = responses
  }

  var callCount: Int {
    lock.withLock { calls }
  }

  var profile: ProviderProfile {
    ProviderProfile(
      displayName: "结局测试",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "test",
      credentialReference: "test"
    )
  }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    let response = lock.withLock { () -> Response in
      calls += 1
      return responses.removeFirst()
    }
    return AsyncThrowingStream { continuation in
      switch response {
      case .text(let text):
        continuation.yield(.textDelta(text))
        continuation.yield(.completed)
        continuation.finish()
      case .failure(let error):
        continuation.finish(throwing: error)
      }
    }
  }
}
