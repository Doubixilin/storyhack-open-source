import Foundation
import LibraryCore
import NovelDocumentCore
import StoryworldCore
@testable import StoryworldFactory
import Testing
@testable import WorldbookUI

@MainActor
struct FactoryRetryUITests {
  @Test func generationRetryReviewsOnlyBakeRequestsAndPreservesAnalysisCheckpoint() async throws {
    let f = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let result = try await f.worker.analyze(jobID: f.job.id, manifest: await f.store.inputManifest(f.job.id),
      snapshotURL: await f.store.workspaceURL(jobID: f.job.id, relativePath: "input")) { _ in }
    let decision = FactoryDecision(jobID: f.job.id, question: "渡口如何调查？", recommendation: "留在渡口",
      evidence: result.analysis.proposals[0].evidence, resolution: .acceptedRecommendation, answer: "留在渡口")
    try await f.store.saveAnalysis(.init(sourceContentHash: result.analysis.sourceContentHash,
      coveredChapterIDs: result.analysis.coveredChapterIDs, proposals: result.analysis.proposals,
      decisions: [decision]), jobID: f.job.id)
    var job = try await f.store.load(f.job.id)
    job.resumeStage = .generating
    try await f.store.save(job)
    let checkpoint = try await f.store.workspaceURL(jobID: job.id, relativePath: "bake/batches/pending.inflight.json")
    try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("pending-bake".utf8).write(to: checkpoint)
    await f.model.initialize()
    await f.model.retry()
    let captured = try #require(f.model.pendingRetry)
    #expect(captured.approval.requestCount == 1)
    #expect(await f.worker.bakeCalls.isEmpty)
    f.model.pendingRetry = nil
    await f.model.confirmRetry(captured)
    #expect(await f.worker.bakeCalls == [job.id])
    #expect(await f.worker.calls == [job.id])
    #expect(try await f.store.load(job.id).stage == .readyToPublish)
    #expect(try Data(contentsOf: f.checkpoint) == Data("uncertain-request".utf8))
    #expect(f.model.errorMessage == nil)
  }

  @Test func dismissedDialogKeepsCapturedApprovalAndDoesNotRetryBeforeConfirmation() async throws {
    let f = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.initialize()
    await f.model.retry()
    #expect(await f.worker.calls.isEmpty)
    let captured = try #require(f.model.pendingRetry)
    #expect(captured.approval.requestCount == 1 && captured.approval.jobID == f.job.id)
    // SwiftUI can dismiss the dialog before its asynchronous action begins.
    f.model.pendingRetry = nil
    await f.model.confirmRetry(captured)
    #expect(await f.worker.calls == [f.job.id])
    #expect(try await f.store.load(f.job.id).stage == .waitingForUser)
    #expect(try await f.store.pendingRequestRetry(f.job.id).requestCount == 0)
    #expect(f.model.errorMessage == nil)
  }

  @Test func changedRequestKeepsConfirmationStaleAndDoesNotStartWorker() async throws {
    let f = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    await f.model.initialize()
    await f.model.retry()
    let captured = try #require(f.model.pendingRetry)
    try Data("changed-request".utf8).write(to: f.checkpoint)
    f.model.pendingRetry = nil
    await f.model.confirmRetry(captured)
    #expect(await f.worker.calls.isEmpty)
    #expect(f.model.errorMessage?.contains("已变化") == true)
    #expect(try await f.store.load(f.job.id).stage == .failed)
    #expect(try Data(contentsOf: f.checkpoint) == Data("changed-request".utf8))
  }

  private func makeFixture() async throws -> RetryUIFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-ui-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("synthetic.txt")
    try Data("第一章 渡口\n林舟来到渡口，决定调查石塔。这里是合成测试小说。\n".utf8).write(to: input)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.importDocument(from: input)
    let worker = RetryUIWorker(document: record.document)
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("jobs"))
    let coordinator = FactoryCoordinator(library: library,
      storyworldLibrary: StoryworldLibrary(rootURL: root.appendingPathComponent("worlds")),
      store: store, worker: worker)
    var job = try await coordinator.createJob(documentID: record.id)
    job.stage = .failed
    try await store.save(job)
    let checkpoint = try await store.workspaceURL(jobID: job.id, relativePath: "analysis/batches/0001.inflight.json")
    try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("uncertain-request".utf8).write(to: checkpoint)
    let model = FactoryViewModel(coordinator: coordinator, store: store)
    return .init(root: root, store: store, job: job, checkpoint: checkpoint, model: model, worker: worker)
  }
}

private struct RetryUIFixture {
  let root: URL
  let store: FactoryJobStore
  let job: FactoryJob
  let checkpoint: URL
  let model: FactoryViewModel
  let worker: RetryUIWorker
}
private actor RetryUIWorker: FactoryAnalysisWorker {
  let document: NovelDocument
  var calls: [UUID] = []
  var bakeCalls: [UUID] = []
  init(document: NovelDocument) { self.document = document }
  func analyze(jobID: UUID, manifest: FactoryInputManifest, snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryWorkerResult {
    calls.append(jobID)
    let chapter = try #require(document.chapters.first)
    let quote = String(chapter.content.prefix(12))
    let anchor = try TextAnchor(document: document, chapter: chapter,
      range: .init(location: 0, length: quote.utf16.count))
    return .init(analysis: .init(sourceContentHash: document.contentHash,
      coveredChapterIDs: manifest.chapters.map(\.id),
      proposals: [.init(id: "synthetic", kind: .location, title: "渡口", content: "调查地点",
        evidence: [.init(chapterTitle: chapter.title, anchor: anchor, excerpt: quote)])],
      decisions: []), executorVersion: "synthetic")
  }
  func cancel(jobID: UUID) async {}
  func bake(_ input: FactoryBakeInput, allowRequests: Bool,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void) async throws -> FactoryBakeReport {
    bakeCalls.append(input.jobID)
    return .retained(sourceFingerprint: input.sourceFingerprint, proposals: input.proposals,
      decisions: input.decisions, reason: "synthetic")
  }
}
