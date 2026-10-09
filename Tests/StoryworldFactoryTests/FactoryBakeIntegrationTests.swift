import Foundation
import DirectoryJournalCore
import LibraryCore
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore
import Testing
@testable import StoryworldFactory

@Suite("Factory decision editing integration")
struct FactoryBakeIntegrationTests {
  @Test func lateCancellationCannotCancelAnotherCoordinatorsResumedRun() async throws {
    let f = try await BakeIntegrationFixture.make(paused: true)
    defer { f.clean() }
    let worker = LateCancelWorker(base: DirectLLMFactoryWorker(provider: f.provider))
    let library = NovelLibrary(rootURL: f.root.appendingPathComponent("library"))
    let owner = FactoryCoordinator(library: library, storyworldLibrary: f.worlds, store: f.store,
      worker: worker, tasteStore: f.tasteStore)
    let first = Task { try await owner.generateCandidate(jobID: f.job.id) }
    try await f.provider.waitForRequest()
    let cancellation = Task { await owner.cancel(jobID: f.job.id) }
    try await worker.waitUntilCancelling()
    await #expect(throws: (any Error).self) { try await first.value }
    let approval = try await f.store.pendingRequestRetry(f.job.id, kind: .bake)
    let provider = BakeIntegrationProvider(paused: true)
    let other = FactoryCoordinator(library: library, storyworldLibrary: f.worlds, store: f.store,
      worker: DirectLLMFactoryWorker(provider: provider), tasteStore: f.tasteStore)
    let resumed = Task { try await other.retry(jobID: f.job.id, requestApproval: approval) }
    try await provider.waitForRequest()
    let pending = try await f.store.pendingRequestRetry(f.job.id, kind: .bake)
    await worker.finishCancellation()
    await cancellation.value
    #expect(try await f.store.load(f.job.id).stage == .generating)
    #expect(try await f.store.pendingRequestRetry(f.job.id, kind: .bake) == pending)
    provider.resume()
    try await resumed.value
    #expect(try await f.store.load(f.job.id).stage == .readyToPublish)
  }

  @Test func anotherCoordinatorCannotRecoverCancelOrOverwriteALiveTask() async throws {
    let f = try await BakeIntegrationFixture.make(paused: true)
    defer { f.clean() }
    let otherStore = FactoryJobStore(rootURL: f.root.appendingPathComponent("jobs"))
    let other = FactoryCoordinator(library: NovelLibrary(rootURL: f.root.appendingPathComponent("library")),
      storyworldLibrary: f.worlds, store: otherStore, worker: DirectLLMFactoryWorker(provider: f.provider), tasteStore: f.tasteStore)
    let task = Task { try await f.coordinator.generateCandidate(jobID: f.job.id) }
    try await f.provider.waitForRequest()
    #expect(try await other.recoverInterruptedJobs().isEmpty)
    #expect(try await otherStore.load(f.job.id).stage == .generating)
    await #expect(throws: DirectoryProcessLockError.busy) { try await other.generateCandidate(jobID: f.job.id) }
    await #expect(throws: DirectoryProcessLockError.busy) {
      try await other.answerDecision(decisionID: f.analysis.decisions[0].id, jobID: f.job.id, answer: "另一操作")
    }
    await other.cancel(jobID: f.job.id)
    #expect(try await otherStore.load(f.job.id).stage == .generating)
    #expect(f.provider.requests.count == 1)
    f.provider.resume()
    try await task.value
    try await other.generateCandidate(jobID: f.job.id)
    #expect(f.provider.requests.count == 1)
    #expect(try await otherStore.load(f.job.id).stage == .readyToPublish)
  }

  @Test func directProviderPublishesEditedContentAndKeepsOriginalEvidenceAndDecisionReceipt() async throws {
    let f = try await BakeIntegrationFixture.make()
    defer { f.clean() }
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    let request = try #require(f.provider.requests.first)
    #expect(f.provider.requests.count == 1)
    #expect(request.modelOptions.maximumOutputTokens == 4_096)
    #expect(request.modelOptions.reasoningEffort == "low")
    #expect(LLMTokenEstimate.inputTokens(request) <= 32_768 - 4_096 - 32_768 / 20)
    let validation = try #require(try await f.store.validation(f.job.id))
    #expect(validation.bakeReport?.rewrites.count == 1 && validation.bakeReport?.isComplete == true)
    #expect(validation.lorebookEntryCount == 1)
    let candidate = try await f.candidate()
    let provenance = try StoryworldCoding.makeDecoder().decode(FactoryCandidateProvenance.self,
      from: Data(contentsOf: candidate.appendingPathComponent("factory/provenance.json")))
    #expect(provenance.proposals == f.analysis.proposals)
    #expect(provenance.decisions == f.analysis.decisions)
    #expect(provenance.bakeReport == validation.bakeReport)
    _ = try await f.coordinator.publish(jobID: f.job.id)
    let world = try await f.worlds.load(storyworldID: f.job.id)
    #expect(world.lorebook.entries[0].content == "林舟留在渡口守候，这是人工确认的改编。")
    #expect(world.lorebook.entries[0].activationKeys == ["林舟"])
    #expect(!world.lorebook.entries.contains { $0.id == "factory-decisions" || $0.title.hasPrefix("待核对") })
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(f.provider.requests.count == 1)
  }

  @Test func publicationRebuildsTamperedOrStaleCandidatesWithoutAnyNewModelRequest() async throws {
    let f = try await BakeIntegrationFixture.make()
    defer { f.clean() }
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    let candidate = try await f.candidate()
    let path = candidate.appendingPathComponent("lorebook/lorebook.json")
    var lore = try StoryworldCoding.makeDecoder().decode(Lorebook.self, from: Data(contentsOf: path))
    lore.entries[0].content = "未审阅的更改"
    try StoryworldCoding.makeEncoder().encode(lore).write(to: path)
    await #expect(throws: FactoryCoordinatorError.candidateChanged) { try await f.coordinator.publish(jobID: f.job.id) }
    #expect(f.provider.requests.count == 1)
    var decision = f.analysis.decisions[0]
    decision.answer = "返回山路"
    try await f.store.saveDecisions([decision], jobID: f.job.id)
    await #expect(throws: FactoryCoordinatorError.candidateChanged) { try await f.coordinator.publish(jobID: f.job.id) }
    #expect(f.provider.requests.count == 1)
    #expect(try await f.store.validation(f.job.id)?.bakeReport?.isComplete == false)
    #expect(try await f.store.load(f.job.id).stage == .readyToPublish)
    #expect(try await f.worlds.list().isEmpty)
  }

  @Test func cancellingBakePreservesCheckpointAndRetryResumesGenerationInsteadOfAnalysis() async throws {
    let f = try await BakeIntegrationFixture.make(paused: true)
    defer { f.clean() }
    let original = try await f.store.analysis(f.job.id)
    let task = Task { try await f.coordinator.generateCandidate(jobID: f.job.id) }
    try await f.provider.waitForRequest()
    await f.coordinator.cancel(jobID: f.job.id)
    await #expect(throws: (any Error).self) { try await task.value }
    let job = try await f.store.load(f.job.id)
    #expect(job.stage == .cancelled && job.resumeStage == .generating)
    let approval = try await f.store.pendingRequestRetry(job.id, kind: .bake)
    #expect(approval.requestCount == 1)
    #expect(try await f.store.analysis(job.id) == original)
    f.provider.resume()
    try await f.coordinator.retry(jobID: job.id, requestApproval: approval)
    #expect(try await f.store.load(job.id).stage == .readyToPublish)
    #expect(f.provider.requests.count == 2)
    #expect(f.provider.requests.allSatisfy { $0.messages.last?.content.contains("<bake_input>") == true })
    #expect(try await f.store.analysis(job.id) == original)
  }

  @Test func decisionChangeDuringModelRequestCannotInstallStaleRewrite() async throws {
    let f = try await BakeIntegrationFixture.make(paused: true)
    defer { f.clean() }
    let task = Task { try await f.coordinator.generateCandidate(jobID: f.job.id) }
    try await f.provider.waitForRequest()
    var decision = f.analysis.decisions[0]
    decision.answer = "返回山路"
    try await f.store.saveDecisions([decision], jobID: f.job.id)
    f.provider.resume()
    await #expect(throws: FactoryBakeError.self) { try await task.value }
    #expect(try await f.store.load(f.job.id).stage == .failed)
    #expect(try await f.store.bakeReport(f.job.id) == nil)
    #expect(try await f.worlds.list().isEmpty)
  }
}

@Suite("Factory player taste integration")
struct FactoryTasteIntegrationTests {
  @Test func overridesResolvePerDimensionAndExplicitEmptyValuesClearInheritance() throws {
    let defaults = PlayerTasteProfile(pace: .unhurried, style: .vivid, detail: .rich,
      styleIntensity: 5, avoidElements: ["虫群"], notes: "默认文字")
    let value = try PlayerTasteOverrides.resolve(defaults: defaults,
      commandLine: .init(pace: .brisk, style: .concise, styleIntensity: 4),
      job: .init(style: .balanced, detail: .brief, avoidElements: [], notes: ""),
      decisions: .init(styleIntensity: 1))
    #expect(value == .init(pace: .brisk, style: .balanced, detail: .brief, styleIntensity: 1))
    #expect(defaults.styleIntensity == 5 && defaults.avoidElements == ["虫群"])
    #expect(throws: PlayerTasteError.invalidProfile) {
      try PlayerTasteOverrides.resolve(defaults: defaults, job: .init(styleIntensity: 6))
    }
    #expect(try PlayerTasteOverrides(avoidElements: [" 虫群 ", "虫群"], notes: " ").validated()
      == .init(avoidElements: ["虫群"], notes: ""))
  }

  @Test func taskEditsPersistWithoutChangingAnalysisAndOldEditorsCannotOverwrite() async throws {
    let f = try await BakeIntegrationFixture.make()
    defer { f.clean() }
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    let original = try await f.store.analysis(f.job.id)
    let decisions = try await f.store.decisions(f.job.id)
    let reviewed = try await f.coordinator.tasteSettings(jobID: f.job.id)
    try await f.coordinator.updateTasteSettings(reviewed, overrides: .init(styleIntensity: 1))
    let saved = try await f.store.load(f.job.id)
    #expect(saved.stage == .waitingForUser && saved.tasteConfiguration?.overrides.styleIntensity == 1)
    #expect(try await f.store.analysis(f.job.id) == original)
    #expect(try await f.store.decisions(f.job.id) == decisions)
    #expect(try await f.store.preview(f.job.id) == nil)
    #expect(f.provider.requests.count == 1)
    await #expect(throws: PlayerTasteError.staleEdit) {
      try await f.coordinator.updateTasteSettings(reviewed, overrides: .init(styleIntensity: 2))
    }
    let latest = try await f.coordinator.tasteSettings(jobID: f.job.id)
    try await f.coordinator.updateTasteSettings(latest, overrides: .init())
    await #expect(throws: PlayerTasteError.staleEdit) {
      try await f.coordinator.updateTasteSettings(reviewed, overrides: .init(styleIntensity: 3))
    }
    let other = try await f.store.create(document: f.document)
    #expect(try await f.coordinator.tasteSettings(jobID: other.id).overrides.isEmpty)
    // Legacy job JSON omits the field and remains readable.
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(f.job)
    #expect(!String(decoding: data, as: UTF8.self).contains("tasteConfiguration"))
    #expect(try decoder.decode(FactoryJob.self, from: data).tasteConfiguration == nil)
  }

  @Test func nonDefaultPreferencesGenerateWithoutDecisionsAndOnlyEffectiveChangesMissCache() async throws {
    let f = try await BakeIntegrationFixture.make(withDecisions: false,
      commandLineTaste: .init(pace: .brisk, style: .concise))
    defer { f.clean() }
    let initial = try await f.tasteStore.load()
    var global = PlayerTasteProfile(style: .vivid, styleIntensity: 5, notes: "保留人物停顿。")
    var saved = try await f.tasteStore.save(global, replacing: initial)
    let settings = try await f.coordinator.tasteSettings(jobID: f.job.id)
    try await f.coordinator.updateTasteSettings(settings, overrides: .init(style: .balanced, styleIntensity: 1))
    let expected = PlayerTasteProfile(pace: .brisk, styleIntensity: 1, notes: "保留人物停顿。")
    #expect(try await f.coordinator.tasteSettings(jobID: f.job.id).effective == expected)
    let analysisBytes = try Data(contentsOf: await f.store.workspaceURL(jobID: f.job.id, relativePath: "analysis.json"))
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(f.provider.requests.count == 1)
    let prompt = try #require(f.provider.requests.first?.messages.last?.content)
    #expect(prompt.contains(try expected.promptSupplement(forGeneration: true)))
    #expect(prompt.contains("不把偏好写成世界规则") && prompt.contains("人工确认的具体任务决策优先"))
    let report = try #require(try await f.store.bakeReport(f.job.id))
    #expect(report.isComplete && report.targets.count == 1 && report.targets[0].decisionIDs.isEmpty)
    let provenance = try StoryworldCoding.makeDecoder().decode(FactoryCandidateProvenance.self,
      from: Data(contentsOf: try await f.candidate().appendingPathComponent("factory/provenance.json")))
    #expect(provenance.playerTaste == expected && provenance.decisions.isEmpty)
    #expect(try await f.store.validation(f.job.id)?.playerTaste == expected)
    #expect(provenance.proposals == f.analysis.proposals)
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(f.provider.requests.count == 1)
    global.style = .concise; global.styleIntensity = 4
    saved = try await f.tasteStore.save(global, replacing: saved)
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(f.provider.requests.count == 1) // Both changed dimensions are shadowed by the job.
    global.notes = "突出环境声音。"
    _ = try await f.tasteStore.save(global, replacing: saved)
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(f.provider.requests.count == 2)
    #expect(try Data(contentsOf: await f.store.workspaceURL(jobID: f.job.id, relativePath: "analysis.json")) == analysisBytes)
  }

  @Test func changingPreferencesBeforePublishRebuildsPreviewWithoutPaidRequest() async throws {
    let f = try await BakeIntegrationFixture.make(withDecisions: false)
    defer { f.clean() }
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(f.provider.requests.isEmpty)
    _ = try await f.tasteStore.save(.init(style: .vivid), replacing: .init())
    await #expect(throws: FactoryCoordinatorError.candidateChanged) {
      try await f.coordinator.publish(jobID: f.job.id)
    }
    #expect(f.provider.requests.isEmpty)
    #expect(try await f.worlds.list().isEmpty)
    #expect(try await f.store.validation(f.job.id)?.bakeReport?.isComplete == false)
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(f.provider.requests.count == 1)
    _ = try await f.coordinator.publish(jobID: f.job.id)
    #expect(f.provider.requests.count == 1)
  }

  @Test func preferencesChangedDuringRequestCannotInstallOldCandidate() async throws {
    for changeJob in [false, true] {
      let f = try await BakeIntegrationFixture.make(paused: true)
      defer { f.clean() }
      let task = Task { try await f.coordinator.generateCandidate(jobID: f.job.id) }
      try await f.provider.waitForRequest()
      if changeJob {
        var current = try await f.store.load(f.job.id)
        current.tasteConfiguration = try .init(overrides: .init(style: .vivid))
        try await f.store.save(current)
      } else { _ = try await f.tasteStore.save(.init(style: .vivid), replacing: .init()) }
      f.provider.resume()
      await #expect(throws: FactoryBakeError.self) { try await task.value }
      #expect(try await f.store.bakeReport(f.job.id) == nil)
      #expect(try await f.store.preview(f.job.id) == nil)
      #expect(try await f.store.analysis(f.job.id) == f.analysis)
      #expect(try await f.worlds.list().isEmpty)
      try await f.coordinator.retry(jobID: f.job.id)
      #expect(f.provider.requests.count == 2)
      #expect(try await f.store.load(f.job.id).stage == .readyToPublish)
    }
  }
}

private actor LateCancelWorker: FactoryAnalysisWorker {
  let base: DirectLLMFactoryWorker
  var cancelling = false
  var resume: CheckedContinuation<Void, Never>?
  init(base: DirectLLMFactoryWorker) { self.base = base }
  func analyze(jobID: UUID, manifest: FactoryInputManifest, snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryWorkerResult {
    try await base.analyze(jobID: jobID, manifest: manifest, snapshotURL: snapshotURL, progress: progress)
  }
  func bake(_ input: FactoryBakeInput, allowRequests: Bool,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryBakeReport {
    try await base.bake(input, allowRequests: allowRequests, progress: progress)
  }
  func cancel(jobID: UUID) async {
    await base.cancel(jobID: jobID)
    await withCheckedContinuation { cancelling = true; resume = $0 }
  }
  func waitUntilCancelling() async throws {
    for _ in 0..<500 {
      if cancelling { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FactoryWorkerError.healthCheckFailed
  }
  func finishCancellation() { resume?.resume(); resume = nil }
}

private struct BakeIntegrationFixture {
  let root: URL
  let store: FactoryJobStore
  let worlds: StoryworldLibrary
  let coordinator: FactoryCoordinator
  let job: FactoryJob
  let analysis: FactoryAnalysis
  let provider: BakeIntegrationProvider
  let tasteStore: PlayerTasteStore
  let document: NovelDocument

  static func make(paused: Bool = false, withDecisions: Bool = true,
    commandLineTaste: PlayerTasteOverrides = .init()) async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bake-integration-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("synthetic.txt")
    try Data("第一章 渡口\n林舟来到渡口，打算前往旧塔。".utf8).write(to: source)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.importDocument(from: source)
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("jobs"))
    var job = try await store.create(document: record.document)
    let chapter = try #require(record.document.chapters.first)
    let quote = "林舟来到渡口"
    let range = (chapter.content as NSString).range(of: quote)
    let evidence = FactoryEvidence(chapterTitle: chapter.title,
      anchor: try .init(document: record.document, chapter: chapter,
        range: .init(location: range.location, length: range.length)), excerpt: quote)
    let decision = FactoryDecision(jobID: job.id, question: "林舟是否前往旧塔？", recommendation: "留在渡口守候",
      evidence: [evidence], resolution: .acceptedRecommendation, answer: "留在渡口守候")
    let analysis = FactoryAnalysis(sourceContentHash: record.document.contentHash,
      coveredChapterIDs: record.document.chapters.map(\.id), proposals: [
        .init(id: "linzhou", kind: .character, title: "林舟", content: "林舟打算前往旧塔。",
          activationKeys: ["林舟"], evidence: [evidence])
      ], decisions: withDecisions ? [decision] : [])
    try await store.saveAnalysis(analysis, jobID: job.id)
    job.stage = .waitingForUser
    try await store.save(job)
    let worlds = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let provider = BakeIntegrationProvider(paused: paused)
    let tasteStore = PlayerTasteStore(rootURL: root.appendingPathComponent("taste"))
    return .init(root: root, store: store, worlds: worlds,
      coordinator: .init(library: library, storyworldLibrary: worlds, store: store,
        worker: DirectLLMFactoryWorker(provider: provider), tasteStore: tasteStore,
        commandLineTaste: commandLineTaste), job: job, analysis: analysis, provider: provider,
      tasteStore: tasteStore, document: record.document)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func candidate() async throws -> URL {
    let path = try #require(try await store.load(job.id).candidatePackageRelativePath)
    return try await store.workspaceURL(jobID: job.id, relativePath: path)
  }
}

private final class BakeIntegrationProvider: LLMProvider, @unchecked Sendable {
  typealias Continuation = AsyncThrowingStream<LLMStreamEvent, any Error>.Continuation
  let profile = ProviderProfile(displayName: "synthetic", kind: .openAICompatible,
    baseURL: URL(string: "https://synthetic.example/v1"), modelID: "synthetic", credentialReference: "none",
    capabilities: .init(contextWindow: 32_768), maximumOutputTokens: 4_096)
  private let lock = NSLock()
  private var recorded: [LLMRequest] = []
  private var paused: Bool
  private var pending: [(LLMRequest, Continuation)] = []
  init(paused: Bool) { self.paused = paused }
  var requests: [LLMRequest] { lock.withLock { recorded } }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let shouldPause = lock.withLock {
        recorded.append(request)
        if paused { pending.append((request, continuation)) }
        return paused
      }
      if !shouldPause { complete(request, continuation) }
    }
  }
  func resume() {
    let items = lock.withLock { paused = false; let items = pending; pending = []; return items }
    for (request, continuation) in items { complete(request, continuation) }
  }
  func waitForRequest() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while requests.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!requests.isEmpty)
  }
  private func complete(_ request: LLMRequest, _ continuation: Continuation) {
    do {
      let prompt = request.messages.last?.content ?? ""
      let raw = prompt.components(separatedBy: "<bake_input>").last!.components(separatedBy: "</bake_input>")[0]
      let object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
      let entries = try #require(object["entries"] as? [[String: Any]])
      let result = entries.map { entry in
        ["id": entry["id"]!, "content": (entry["decisionIDs"] as? [String])?.isEmpty == true
          ? "林舟打算前往旧塔。" : "林舟留在渡口守候，这是人工确认的改编。", "decision_ids": entry["decisionIDs"]!]
      }
      let text = String(decoding: try JSONSerialization.data(withJSONObject: ["entries": result]), as: UTF8.self)
      continuation.yield(.textDelta(text)); continuation.yield(.completed); continuation.finish()
    } catch { continuation.finish(throwing: error) }
  }
}
