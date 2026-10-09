import Foundation
import LLMProviderKit
import NovelDocumentCore
import Testing
@testable import StoryworldFactory

@Suite("Factory diversity and recoverable batches")
struct FactoryDiversityRecoveryTests {
  @Test func laterBatchesSeeEarlierCharactersAndResumeReusesImmutableContextWithoutRequests() async throws {
    let f = try await fixture(count: 3)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let transport = DiversityTransport()
    let runner = makeRunner(transport)
    let first = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    let prompts = await transport.prompts
    #expect(prompts.count == 3)
    #expect(prompts[0].contains("候选标题（仅供减少重复，按标题统计，不等于实体合并）：暂无"))
    #expect(prompts[1].contains("候选标题（仅供减少重复，按标题统计，不等于实体合并）：林舟"))
    #expect(prompts[1].contains("protagonist=1"))
    #expect(prompts[2].contains("protagonist=1"))
    #expect(first.analysis.proposals.count == 1)
    #expect(first.analysis.proposals[0].content.contains("第3处"))
    #expect(first.analysis.proposals[0].archetype == .protagonist)
    #expect(first.analysis.proposals[0].evidence.count == 3)
    #expect(first.analysis.decisions.count == 1 && first.analysis.decisions[0].evidence.count == 3)
    let second = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(await transport.prompts.count == 3)
    #expect(first.analysis == second.analysis)
  }

  @Test func concurrentlyDispatchedLaterBatchesSeeCompletedOnesAndResumeReusesFrozenContext() async throws {
    let f = try await fixture(count: 3)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let transport = DiversityTransport()
    let runner = makeRunner(transport, concurrency: 2)
    let first = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    let prompts = await transport.prompts
    #expect(prompts.count == 3)
    // 首组同时派发的两批各自以空快照冻结；之后派发的批次必须消费已完成批次的角色。
    #expect(prompts.filter { $0.contains("暂无") }.count == 2)
    let fed = prompts.filter { !$0.contains("暂无") }
    #expect(fed.count == 1)
    #expect(fed.first?.contains("林舟") == true)
    #expect(fed.first?.contains("protagonist=1") == true)
    #expect(first.analysis.coveredChapterIDs == ["c1", "c2", "c3"])
    // 并发运行后续跑仍复用已冻结的批次上下文与结果，不新增请求。
    let second = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(await transport.prompts.count == 3)
    #expect(first.analysis == second.analysis)
  }

  @Test func contextIsJobLocalBoundedAndDoesNotInventMissingArchetypes() async throws {
    let context = FactoryDiversityContext()
    let proposals = (0..<90).map { index in
      BatchProposal(kind: "character", title: "人物\(index)", content: "源内事实", activationKeys: [],
        alwaysActive: false, evidence: [], archetype: index < 2 ? .mentor : nil)
    }
    await context.ingest(.init(coveredChapterIDs: [], proposals: proposals, decisions: []), batchIndex: 0)
    let prompt = await context.snapshot()
    #expect(prompt.contains("mentor=2") && prompt.contains("另有 26"))
    #expect(prompt.utf8.count <= 24_576)
    #expect(prompt.contains("不得为凑类型编造角色"))
    #expect(await FactoryDiversityContext().snapshot().contains("暂无"))
  }

  @Test func missingCoverageMergePreservesOriginalAndNewChapterSummaries() async throws {
    let f = try await fixture(count: 2)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let transport = DiversityTransport(mode: .partial)
    let runner = makeRunner(transport, maximum: 50_000)
    let result = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(await transport.prompts.count == 2)
    #expect(result.analysis.coveredChapterIDs == ["c1", "c2"])
    #expect(result.analysis.chapterSummaries.map(\.chapterID) == ["c1", "c2"])
    #expect(result.analysis.chapterSummaries.map(\.summary) == ["林舟在第1处渡口调查。", "林舟在第2处渡口调查。"])
  }

  @Test func unknownCoverageOutcomeSurvivesRepeatedRunsUntilExactRequestApproval() async throws {
    let f = try await fixture(count: 2)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let transport = DiversityTransport(mode: .unknownCoverage)
    let runner = makeRunner(transport, maximum: 50_000)
    let first = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(first.analysis.coveredChapterIDs == ["c1"])
    #expect(first.analysis.chapterSummaries.count == 1)
    let approval = try await f.store.pendingRequestRetry(f.job.id)
    #expect(approval.requestCount == 1)
    #expect(approval.entries[0].relativePath.contains("coverage"))
    let second = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(second.analysis.coveredChapterIDs == ["c1"])
    #expect(await transport.prompts.count == 2)
    await #expect(throws: (any Error).self) { try await f.store.authorizeRequestRetry(f.job.id, approval: nil) }
    #expect(try await f.store.pendingRequestRetry(f.job.id) == approval)
    try await f.store.authorizeRequestRetry(f.job.id, approval: approval)
    #expect(try await f.store.pendingRequestRetry(f.job.id).requestCount == 0)
    await transport.allowCompletion()
    let third = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(await transport.prompts.count == 3)
    #expect(third.analysis.coveredChapterIDs == ["c1", "c2"])
    #expect(third.analysis.chapterSummaries.count == 2)
    let root = try await f.store.workspaceURL(jobID: f.job.id)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("retry-approved").path).count == 1)
  }

  @Test func changedCheckpointCannotUseStaleOrAnotherJobsApproval() async throws {
    let f = try await fixture(count: 1)
    let other = try await fixture(count: 1)
    defer {
      try? FileManager.default.removeItem(at: f.root)
      try? FileManager.default.removeItem(at: other.root)
    }
    let path = try await f.store.workspaceURL(jobID: f.job.id, relativePath: "analysis/batches/0001.inflight.json")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("old".utf8).write(to: path)
    let old = try await f.store.pendingRequestRetry(f.job.id)
    try Data("new".utf8).write(to: path)
    await #expect(throws: FactoryRequestRetryError.self) { try await f.store.authorizeRequestRetry(f.job.id, approval: old) }
    await #expect(throws: FactoryRequestRetryError.self) { try await other.store.authorizeRequestRetry(other.job.id, approval: old) }
    #expect(try Data(contentsOf: path) == Data("new".utf8))
    // Malformed/mismatched records are uncertainty, never permission to send.
    #expect(throws: FactoryWorkerError.self) {
      try FactoryAnalysisPipeline.loadCheckpoint(at: path, contentHash: f.manifest.contentHash,
        chapterIDs: ["c1"], runFingerprint: "test", fileManager: .default)
    }
  }

  @Test func promptAndEndpointChangesInvalidateCompletedCachesButNotUncertainRequestProtection() async throws {
    let f = try await fixture(count: 2)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let transport = DiversityTransport()
    let one = makeRunner(transport)
    _ = try await one.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    let different = makeRunner(transport, executor: "new-prompt")
    _ = try await different.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(await transport.prompts.count == 4)
    let path = try await f.store.workspaceURL(jobID: f.job.id, relativePath: "analysis/batches/0001.inflight.json")
    try JSONEncoder().encode(BatchCheckpoint(contentHash: f.manifest.contentHash,
      chapterIDs: ["c1"], sessionID: "synthetic", runFingerprint: "old-model")).write(to: path)
    #expect(throws: FactoryWorkerError.uncertainPriorRequest(0)) {
      try FactoryAnalysisPipeline.loadCheckpoint(at: path, contentHash: f.manifest.contentHash,
        chapterIDs: ["c1"], runFingerprint: "new-model", fileManager: .default)
    }
    let a = DirectLLMFactoryWorker(provider: FingerprintProvider(endpoint: "https://a.example/v1"))
    let b = DirectLLMFactoryWorker(provider: FingerprintProvider(endpoint: "https://b.example/v1"))
    #expect(await a.executorVersion != b.executorVersion)
  }

  @Test func requestReviewDoesNotFollowDirectoriesOutsideTheJob() async throws {
    let f = try await fixture(count: 1)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let outside = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("0001.inflight.json")
    try Data("keep".utf8).write(to: sentinel)
    let directory = try await f.store.workspaceURL(jobID: f.job.id, relativePath: "analysis")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("batches"),
      withDestinationURL: outside)
    await #expect(throws: FactoryRequestRetryError.self) { try await f.store.pendingRequestRetry(f.job.id) }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  }

  @Test func summaryOnlyContinuationReusesCandidatesAndRequestsOnlyTheMissingSummary() async throws {
    let f = try await fixture(count: 2)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let transport = DiversityTransport(mode: .summaryMissing)
    let runner = makeRunner(transport, maximum: 50_000)
    let first = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(await transport.prompts.count == 1)
    #expect(first.analysis.coveredChapterIDs.count == 2)
    #expect(first.analysis.chapterSummaries.count == 1)
    #expect(FactoryCoverageSummary(manifest: f.manifest, analysis: first.analysis).needsSupplement)
    let second = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    let prompts = await transport.prompts
    #expect(prompts.count == 2)
    #expect(prompts[1].contains("仅补全主线摘要"))
    #expect(!prompts[1].contains(#"<chapter id="c1""#))
    #expect(prompts[1].contains(#"<chapter id="c2""#))
    #expect(second.analysis.proposals == first.analysis.proposals)
    #expect(second.analysis.decisions == first.analysis.decisions)
    #expect(second.analysis.chapterSummaries.count == 2)
    #expect(!second.analysis.warnings.contains { $0.contains("缺少主线摘要") || $0.contains("缺少完整主线摘要") })
    #expect(!FactoryCoverageSummary(manifest: f.manifest, analysis: second.analysis).needsSupplement)
    _ = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(await transport.prompts.count == 2)
  }

  @Test func supplementationKeepsAllPreviouslyValidatedCandidatesAcrossCacheReloads() async throws {
    let f = try await fixture(count: 2)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let transport = DiversityTransport(mode: .crowdedPartial)
    let runner = makeRunner(transport, maximum: 50_000)
    let first = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(first.analysis.proposals.count == 20)
    #expect(Set(first.analysis.proposals.map(\.title)).contains("c1人物9"))
    #expect(Set(first.analysis.proposals.map(\.title)).contains("c2人物9"))
    let second = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    #expect(await transport.prompts.count == 2)
    #expect(second.analysis.proposals == first.analysis.proposals)
  }

  @Test func missingPartialCacheDoesNotBypassUnknownSupplementRequest() async throws {
    let f = try await fixture(count: 2)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let transport = DiversityTransport(mode: .unknownCoverage)
    let runner = makeRunner(transport, maximum: 50_000)
    _ = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    let approval = try await f.store.pendingRequestRetry(f.job.id)
    let cache = try await f.store.workspaceURL(jobID: f.job.id, relativePath: "analysis/batches/0001.json")
    try FileManager.default.removeItem(at: cache)
    await #expect(throws: (any Error).self) {
      _ = try await runner.run(jobID: f.job.id, manifest: f.manifest, snapshotURL: f.snapshot) { _ in }
    }
    #expect(await transport.prompts.count == 2)
    #expect(try await f.store.pendingRequestRetry(f.job.id) == approval)
  }

  private func makeRunner(_ transport: DiversityTransport, maximum: Int = 10_000,
    executor: String = "synthetic-v2", concurrency: Int = 1) -> FactoryAnalysisRunner {
    .init(transport: transport, maximumBatchUTF16Length: maximum, executorVersion: executor,
      concurrency: concurrency, fileManager: .default)
  }
  private func fixture(count: Int) async throws -> DiversityFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("factory-diversity-\(UUID())")
    let chapters = (1...count).map { i in
      NovelChapter(id: "c\(i)", ordinal: i - 1, title: "第\(i)章",
        content: "林舟在第\(i)处渡口调查石塔。\n" + String(repeating: "背景。\n", count: 1_800))
    }
    let doc = NovelDocument(id: UUID(), title: "合成小说", sourceFormat: .text,
      sourceFileName: "fixture.txt", contentHash: "synthetic-\(count)", chapters: chapters)
    let store = FactoryJobStore(rootURL: root)
    let job = try await store.create(document: doc)
    return .init(root: root, store: store, job: job, manifest: try await store.inputManifest(job.id),
      snapshot: try await store.workspaceURL(jobID: job.id, relativePath: "input"))
  }
}

private struct DiversityFixture {
  let root: URL
  let store: FactoryJobStore
  let job: FactoryJob
  let manifest: FactoryInputManifest
  let snapshot: URL
}
private actor DiversityTransport: FactoryBatchTransport {
  enum Mode { case complete, partial, unknownCoverage, summaryMissing, crowdedPartial }
  var mode: Mode
  var prompts: [String] = []
  init(mode: Mode = .complete) { self.mode = mode }
  func allowCompletion() { mode = .complete }
  func beginRequest(title: String) async throws -> String { UUID().uuidString }
  func recoverInflight(checkpointToken: String) async throws -> String? { nil }
  func cancel() async {}
  func send(checkpointToken: String, systemPrompt: String, prompt: String) async throws -> String {
    prompts.append(prompt)
    if mode == .unknownCoverage, prompts.count > 1 { throw URLError(.networkConnectionLost) }
    let regex = try NSRegularExpression(pattern: #"<chapter id="(c\d+)""#)
    let ns = prompt as NSString
    var ids = regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    if [.partial, .unknownCoverage, .crowdedPartial].contains(mode), prompts.count == 1 {
      ids = Array(ids.prefix(1))
    }
    let summaryIDs = mode == .summaryMissing && prompts.count == 1 ? Array(ids.prefix(1)) : ids
    let summaries: [[String: Any]] = summaryIDs.map {
      ["chapter_id": $0, "summary": "林舟在第\($0.dropFirst())处渡口调查。"]
    }
    var proposals: [[String: Any]] = ids.map {
      ["kind": "character", "title": "林舟", "content": "林舟在第\($0.dropFirst())处渡口调查。",
       "archetype": "protagonist", "activation_keys": ["林舟"], "always_active": false,
       "evidence": [["chapter_id": $0, "quote": "林舟在第\($0.dropFirst())处渡口调查石塔。"]]]
    }
    if mode == .summaryMissing && prompts.count > 1 {
      proposals = proposals.map { var value = $0; value["content"] = "不应覆盖已有候选"; return value }
    }
    if mode == .crowdedPartial {
      proposals = ids.flatMap { id in (0..<10).map { index in
        ["kind": "character", "title": "\(id)人物\(index)", "content": "原文中出现林舟",
         "activation_keys": ["林舟"], "always_active": false,
         "evidence": [["chapter_id": id, "quote": "林舟在第\(id.dropFirst())处渡口调查石塔。"]]] as [String: Any]
      }}
    }
    let decisions: [[String: Any]] = ids.map {
      ["question": "如何继续调查？", "recommendation": "从石塔调查",
       "evidence": [["chapter_id": $0, "quote": "林舟在第\($0.dropFirst())处渡口调查石塔。"]]]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: [
      "covered_chapter_ids": ids, "chapter_summaries": summaries, "proposals": proposals, "decisions": decisions,
    ]), as: UTF8.self)
  }
}
private struct FingerprintProvider: LLMProvider {
  let endpoint: String
  var profile: ProviderProfile {
    .init(displayName: "same", kind: .openAICompatible, baseURL: URL(string: endpoint), modelID: "same", credentialReference: "same")
  }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { $0.finish() }
  }
}
