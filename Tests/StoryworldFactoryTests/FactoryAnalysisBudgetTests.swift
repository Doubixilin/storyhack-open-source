import Foundation
import LLMProviderKit
import NovelDocumentCore
import Testing
@testable import StoryworldFactory

@Suite("Factory full request budgets")
struct FactoryAnalysisBudgetTests {
  @Test func longChineseAndCombinedCharactersKeepEverySourceOffset() throws {
    let text = (0..<1_800).map { "第\($0)条：林舟👩🏽‍🚀走过石桥，看到 cafe\u{301} 的门。\n" }.joined()
    let chapter = unit(text)
    for window in [8_192, 16_384, 32_768] {
      let budget = try FactoryAnalysisBudget(profile: profile(window: window, output: 1_024))
      let plan = try budget.plan([chapter, unit(" \n", id: "empty")], maximumUTF16Length: 50_000)
      #expect(plan.units.count > 1)
      #expect(plan.units.map(\.text).joined() == text)
      #expect(plan.automaticallyCoveredChapterIDs == ["empty"])
      var offset = 0
      for (index, part) in plan.units.enumerated() {
        #expect(part.utf16Offset == offset)
        #expect(part.segmentIndex == index + 1 && part.segmentCount == plan.units.count)
        #expect(part.fullText == text)
        #expect(Range(NSRange(location: offset, length: part.text.utf16.count), in: text) != nil)
        #expect((text as NSString).substring(with: NSRange(location: offset, length: part.text.utf16.count)) == part.text)
        offset += part.text.utf16.count
      }
      let batches = try budget.batches(plan.units, maximumUTF16Length: 50_000)
      #expect(batches.flatMap { $0 }.map(\.analysisID) == plan.units.map(\.analysisID))
      #expect(batches.allSatisfy {
        budget.fits(system: FactoryAnalysisPrompts.analysisSystem,
          prompt: budget.planningPrompt($0), reserve: budget.diversityLimit)
      })
    }
  }

  @Test func shortChaptersReserveRepeatedHeadersAndSummaryOutput() throws {
    let chapters = (0..<120).map { unit("林舟进入城门。", id: "c\($0)", title: String(repeating: "章节标题", count: 30)) }
    let budget = try FactoryAnalysisBudget(profile: profile(window: 8_192, output: 1_024))
    let plan = try budget.plan(chapters, maximumUTF16Length: 50_000)
    let batches = try budget.batches(plan.units, maximumUTF16Length: 50_000)
    #expect(batches.count > 20)
    #expect(batches.flatMap { $0 }.map(\.analysisID) == chapters.map(\.analysisID))
    #expect(batches.allSatisfy {
      budget.fits(system: FactoryAnalysisPrompts.analysisSystem,
        prompt: budget.planningPrompt($0), reserve: budget.diversityLimit)
    })
    let longID = unit("原文。", id: String(repeating: "章节标识", count: 100))
    #expect(throws: FactoryAnalysisBudgetError.self) {
      try budget.batches([longID], maximumUTF16Length: 50_000)
    }
  }

  @Test func diversityDropsWholeTitlesWithinTokenAllowanceAndKeepsConstraints() async throws {
    let context = FactoryDiversityContext()
    let names = (0..<64).map { "人物\(String(format: "%02d", $0))" + String(repeating: "甲", count: 70) }
    let proposals = names.map {
      BatchProposal(kind: "character", title: $0, content: "事实", activationKeys: [],
        alwaysActive: false, evidence: [], archetype: .ally)
    }
    await context.ingest(.init(coveredChapterIDs: [], proposals: proposals, decisions: []), batchIndex: 0)
    let text = await context.snapshot(maximumTokens: 1_024)
    #expect(LLMTokenEstimate.tokens(text) <= 1_024 && !text.isEmpty)
    #expect(text.contains("不得为凑类型编造角色"))
    #expect(text.contains(names[0]) && !text.contains(names.last!))
    #expect(await context.snapshot(maximumTokens: 10) == "")
  }

  @Test func directRequestsCoverSegmentsAndReuseCacheAtSmallWindow() async throws {
    let text = (0..<750).map { "第\($0)处，林舟在青石镇检查城门。\n" }.joined()
    let f = try await fixture([text])
    defer { try? FileManager.default.removeItem(at: f.root) }
    let provider = BudgetProvider(profile: profile(window: 8_192, output: 1_024))
    let worker = DirectLLMFactoryWorker(provider: provider, concurrency: 1)
    let first = try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    let requests = provider.requests
    #expect(requests.count > 1)
    #expect(first.analysis.coveredChapterIDs == ["c1"])
    #expect(first.analysis.chapterSummaries.count == requests.count)
    #expect(requests.flatMap { BudgetProvider.chapters($0).map(\.text) }.joined() == text)
    for evidence in first.analysis.proposals.flatMap(\.evidence) {
      #expect(evidence.anchor.chapterID == "c1")
      #expect((text as NSString).substring(with: NSRange(location: evidence.anchor.range.location,
        length: evidence.anchor.range.length)) == evidence.excerpt)
    }
    assertBudgets(requests, profile: provider.profile)
    let second = try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(provider.requests.count == requests.count)
    #expect(second.analysis == first.analysis)
  }

  @Test func coverageAndFormatRepairUseCapsAndRetainRepairedSummaries() async throws {
    let f = try await fixture(["林舟进入青石镇。", "林舟修好了旧城门。"])
    defer { try? FileManager.default.removeItem(at: f.root) }
    let repaired = BudgetProvider.output([("c2", "林舟修好了旧城门。")])
    let provider = BudgetProvider(profile: profile(window: 8_192, output: 2_048)) { request, index in
      if index == 0 { return .success(BudgetProvider.output(Array(BudgetProvider.chapters(request).prefix(1)))) }
      if index == 1 { return .success("坏 JSON") }
      return .success(repaired)
    }
    let worker = DirectLLMFactoryWorker(provider: provider, concurrency: 1)
    let result = try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(provider.requests.count == 3)
    #expect(BudgetProvider.chapters(provider.requests[1]).map(\.id) == ["c2"])
    #expect(provider.requests[2].messages[0].content == FactoryAnalysisPrompts.repairSystem)
    #expect(result.analysis.chapterSummaries.map(\.chapterID) == ["c1", "c2"])
    assertBudgets(provider.requests, profile: provider.profile)
    _ = try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(provider.requests.count == 3)
    #expect(try await f.store.pendingRequestRetry(f.id).requestCount == 0)
  }

  @Test func summaryOnlyContinuationUsesCapsWithoutReplacingCandidates() async throws {
    let f = try await fixture(["林舟进入青石镇。"])
    defer { try? FileManager.default.removeItem(at: f.root) }
    let provider = BudgetProvider(profile: profile(window: 8_192, output: 1_024)) { request, index in
      .success(BudgetProvider.output(BudgetProvider.chapters(request), summaries: index > 0))
    }
    let worker = DirectLLMFactoryWorker(provider: provider)
    let first = try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(provider.requests.count == 1 && first.analysis.chapterSummaries.isEmpty)
    let second = try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(provider.requests.count == 2)
    #expect(provider.requests[1].messages[1].content.contains("仅补全主线摘要"))
    #expect(second.analysis.chapterSummaries.count == 1 && second.analysis.proposals == first.analysis.proposals)
    assertBudgets(provider.requests, profile: provider.profile)
  }

  @Test func invalidSettingsOrOversizedHeaderNeverCreatePaidCheckpoints() async throws {
    for p in [profile(window: 4_096, output: 4_096), profile(window: 2_048, output: 512),
      profile(window: 8_192, output: 1_024)] {
      let f = try await fixture(["林舟进入青石镇。"], title: String(repeating: "过长标题", count: 2_000))
      defer { try? FileManager.default.removeItem(at: f.root) }
      let provider = BudgetProvider(profile: p)
      let worker = DirectLLMFactoryWorker(provider: provider)
      await #expect(throws: FactoryAnalysisBudgetError.self) {
        try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
      }
      #expect(provider.requests.isEmpty)
      #expect(try await f.store.pendingRequestRetry(f.id).requestCount == 0)
    }
  }

  @Test func oversizedRepairStopsWithoutAutomaticResendOrFalseUncertainty() async throws {
    for count in [5_000, 100_001] {
      let f = try await fixture(["林舟进入青石镇。"])
      defer { try? FileManager.default.removeItem(at: f.root) }
      let provider = BudgetProvider(profile: profile(window: 8_192, output: 1_024)) { _, _ in
        .success(String(repeating: "坏", count: count))
      }
      let worker = DirectLLMFactoryWorker(provider: provider)
      await #expect(throws: FactoryAnalysisBudgetError.self) {
        try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
      }
      #expect(provider.requests.count == 1)
      #expect(try await f.store.pendingRequestRetry(f.id).requestCount == 0)
    }
  }

  @Test func repairDisconnectPreservesParentCheckpointAcrossResumption() async throws {
    let f = try await fixture(["林舟进入青石镇。"])
    defer { try? FileManager.default.removeItem(at: f.root) }
    let provider = BudgetProvider(profile: profile(window: 8_192, output: 1_024)) { _, index in
      index == 0 ? .success("坏 JSON") : .failure(URLError(.networkConnectionLost))
    }
    let worker = DirectLLMFactoryWorker(provider: provider)
    await #expect(throws: FactoryWorkerError.self) {
      try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    }
    let pending = try await f.store.pendingRequestRetry(f.id)
    #expect(provider.requests.count == 2 && pending.requestCount == 1)
    await #expect(throws: FactoryWorkerError.self) {
      try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    }
    #expect(provider.requests.count == 2)
    #expect(try await f.store.pendingRequestRetry(f.id) == pending)
  }

  @Test func orphanOrOldConfigurationCheckpointStopsAllRequestsBeforeReplanning() async throws {
    for filename in ["0009.inflight.json", "0001.inflight.json"] {
      let f = try await fixture(["林舟进入青石镇。"])
      defer { try? FileManager.default.removeItem(at: f.root) }
      let url = f.snapshot.deletingLastPathComponent().appendingPathComponent("analysis/batches/" + filename)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let bytes = try JSONEncoder().encode(BatchCheckpoint(contentHash: f.manifest.contentHash,
        chapterIDs: ["c1"], sessionID: "synthetic", runFingerprint: "direct-llm/2/old"))
      try bytes.write(to: url)
      let provider = BudgetProvider(profile: profile(window: 8_192, output: 1_024))
      let worker = DirectLLMFactoryWorker(provider: provider)
      await #expect(throws: FactoryWorkerError.self) {
        try await worker.analyze(jobID: f.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
      }
      #expect(provider.requests.isEmpty)
      #expect(try Data(contentsOf: url) == bytes)
    }
  }

  @Test func transportDefaultHasOutputCapAndRejectsOversizedDirectCall() async throws {
    let provider = BudgetProvider(profile: .init(displayName: "Default", kind: .openAICompatible,
      modelID: "synthetic", credentialReference: "unused")) { _, _ in .success("{}") }
    let transport = DirectLLMBatchTransport(provider: provider)
    _ = try await transport.send(checkpointToken: UUID().uuidString, systemPrompt: "分析", prompt: "合成文本")
    #expect(provider.requests[0].modelOptions.maximumOutputTokens == 4_096)
    await #expect(throws: FactoryAnalysisBudgetError.self) {
      try await transport.send(checkpointToken: UUID().uuidString, systemPrompt: "分析",
        prompt: String(repeating: "文本", count: 10_000))
    }
    #expect(provider.requests.count == 1)
    // Cancelling between batches must also prevent a later request from starting.
    await transport.cancel()
    await #expect(throws: CancellationError.self) { try await transport.beginRequest(title: "下一批") }
    await #expect(throws: CancellationError.self) {
      try await transport.send(checkpointToken: UUID().uuidString, systemPrompt: "分析", prompt: "合成文本")
    }
    #expect(provider.requests.count == 1)
  }

  private func profile(window: Int, output: Int) -> ProviderProfile {
    .init(displayName: "Budget", kind: .openAICompatible, modelID: "synthetic", credentialReference: "unused",
      capabilities: .init(contextWindow: window), maximumOutputTokens: output)
  }
  private func unit(_ text: String, id: String = "c1", title: String = "章节") -> FactoryChapterText {
    .init(descriptor: .init(id: id, ordinal: 0, title: title, relativePath: id + ".txt", utf16Length: text.utf16.count),
      analysisID: id, text: text, fullText: text, utf16Offset: 0, segmentIndex: 1, segmentCount: 1)
  }
  private func assertBudgets(_ requests: [LLMRequest], profile: ProviderProfile) {
    let window = profile.capabilities.contextWindow!
    for request in requests {
      #expect(request.modelOptions.maximumOutputTokens == profile.maximumOutputTokens)
      #expect(LLMTokenEstimate.inputTokens(request) + profile.maximumOutputTokens! + max(512, window / 20) <= window)
    }
  }
  private func fixture(_ texts: [String], title: String = "章节") async throws -> BudgetFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("factory-budget-\(UUID())")
    let store = FactoryJobStore(rootURL: root)
    let document = NovelDocument(id: UUID(), title: "合成小说", sourceFormat: .text, sourceFileName: "synthetic.txt",
      contentHash: String(repeating: "b", count: 64), chapters: texts.enumerated().map {
        .init(id: "c\($0.offset + 1)", ordinal: $0.offset, title: title, content: $0.element)
      })
    let job = try await store.create(document: document)
    return .init(root: root, store: store, id: job.id, manifest: try await store.inputManifest(job.id),
      snapshot: try await store.workspaceURL(jobID: job.id, relativePath: "input"))
  }
}

private struct BudgetFixture {
  let root: URL
  let store: FactoryJobStore
  let id: UUID
  let manifest: FactoryInputManifest
  let snapshot: URL
}

private final class BudgetProvider: LLMProvider, @unchecked Sendable {
  let profile: ProviderProfile
  private let lock = NSLock()
  private var recorded: [LLMRequest] = []
  private let respond: @Sendable (LLMRequest, Int) -> Result<String, Error>
  var requests: [LLMRequest] { lock.withLock { recorded } }
  init(profile: ProviderProfile,
    respond: @escaping @Sendable (LLMRequest, Int) -> Result<String, Error> = { request, _ in
      .success(BudgetProvider.output(BudgetProvider.chapters(request)))
    }) {
    self.profile = profile
    self.respond = respond
  }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
    let index = lock.withLock {
      let index = recorded.count
      recorded.append(request)
      return index
    }
    return AsyncThrowingStream { continuation in
      switch respond(request, index) {
      case .success(let text):
        continuation.yield(.textDelta(text)); continuation.yield(.completed); continuation.finish()
      case .failure(let error): continuation.finish(throwing: error)
      }
    }
  }
  static func chapters(_ request: LLMRequest) -> [(id: String, text: String)] {
    let prompt = request.messages.last!.content as NSString
    let regex = try! NSRegularExpression(pattern: #"<chapter id="([^"]+)" title="[^"]*">\n([\s\S]*?)\n</chapter>"#)
    return regex.matches(in: prompt as String, range: NSRange(location: 0, length: prompt.length)).map {
      (prompt.substring(with: $0.range(at: 1)), prompt.substring(with: $0.range(at: 2)))
    }
  }
  static func output(_ chapters: [(id: String, text: String)], summaries: Bool = true) -> String {
    let output = BatchOutput(coveredChapterIDs: chapters.map(\.id), chapterSummaries: summaries ? chapters.map {
      .init(chapterID: $0.id, summary: String($0.text.prefix(30)))
    } : [], proposals: chapters.prefix(1).map {
      .init(kind: "character", title: "林舟", content: "正在调查城门", activationKeys: ["林舟"], alwaysActive: false,
        evidence: [.init(chapterID: $0.id, quote: String($0.text.prefix(20)))], archetype: .protagonist)
    }, decisions: [])
    return String(data: try! JSONEncoder().encode(output), encoding: .utf8)!
  }
}
