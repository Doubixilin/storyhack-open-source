import Foundation
import LibraryCore
import NovelDocumentCore
import StoryworldCore
import Testing

@testable import StoryworldFactory

@Suite("Factory versioned publication")
struct FactoryPublicationTests {
  @Test func partialPlotlineAndGapNoticeSurviveCandidatePublicationAndLaterCompletion() async throws {
    let f = try await PublicationFixture.make(sourceText:
      "第一章 出发\n林舟来到港口，准备调查旧塔。\n\n第二章 山路\n林舟来到山路。\n\n第三章 石塔\n林舟来到石塔。")
    defer { f.clean() }
    let manifest = try await f.store.inputManifest(f.job.id)
    #expect(manifest.chapters.count == 3)
    let saved = try #require(try await f.store.analysis(f.job.id))
    let summaries = manifest.chapters.map {
      FactoryChapterSummary(chapterID: $0.id, chapterOrdinal: $0.ordinal,
        chapterTitle: $0.title, segmentIndex: 1, segmentCount: 1, summary: "林舟调查\($0.title)。")
    }
    func analysis(_ summaries: [FactoryChapterSummary]) -> FactoryAnalysis {
      .init(sourceContentHash: saved.sourceContentHash, coveredChapterIDs: saved.coveredChapterIDs,
        proposals: saved.proposals, decisions: saved.decisions, chapterSummaries: summaries)
    }
    try await f.store.saveAnalysis(analysis([summaries[0], summaries[2]]), jobID: f.job.id)
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(try await f.store.validation(f.job.id)?.warnings.contains { $0.contains("主线摘要完整 2/3 章") } == true)
    _ = try await f.coordinator.publish(jobID: f.job.id)
    let old = try await f.worlds.load(storyworldID: f.job.id)
    #expect(old.plotline?.nodes.map(\.order) == [1, 3])
    #expect(old.plotline?.coverage?.gaps.map(\.chapterID) == [manifest.chapters[1].id])
    try await f.store.saveAnalysis(analysis(summaries), jobID: f.job.id)
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    _ = try await f.coordinator.publish(jobID: f.job.id)
    let new = try await f.worlds.load(storyworldID: f.job.id)
    #expect(new.plotline?.nodes.map(\.order) == [1, 2, 3])
    for node in old.plotline?.nodes ?? [] { #expect(new.plotline?.node(id: node.id) == node) }
    #expect(new.plotline?.coverage?.notice == nil)
  }

  @Test func publicationInvalidatesInFlightTurnAndOwnedOptionalFilesCanBeRemoved() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    let candidate = try await f.candidate()
    let old = try GeneratedPackageRevision.load(at: candidate)
    try StoryworldCoding.makeEncoder().encode(StoryTimeline(beats: [], source: "factory")).write(
      to: candidate.appendingPathComponent("timeline.json"))
    // Install a version that owned timeline.json through the lower-level
    // publisher, then regenerate from the saved analysis which has no timeline.
    try GeneratedPackageRevision.make(at: candidate, inputFingerprint: old.inputFingerprint).write(
      to: candidate)
    let target = StoryworldAssociationTarget(
      documentID: f.job.documentID, contentHash: f.job.sourceContentHash)
    _ = try await f.worlds.publishGeneratedPackage(from: candidate, associateWith: target)
    let package = try await f.worlds.managedPackageURL(storyworldID: f.job.id)
    let runtime = await StoryworldRuntimeStoreRegistry.shared.store(forPackageURL: package)
    let line = try await runtime.createPlaythrough(title: "在途回合")
    let snapshot = try await runtime.load(address: line.address)
    let document = try await f.worlds.load(storyworldID: f.job.id)
    let token = try await runtime.requireCanon(
      address: line.address, document: document,
      bindingID: snapshot.context.playthrough.canonBinding?.id)
    try await f.changeAndGenerate("新开局")
    _ = try await f.coordinator.publish(jobID: f.job.id)
    #expect(
      !FileManager.default.fileExists(atPath: package.appendingPathComponent("timeline.json").path))
    await #expect(throws: CanonBindingError.changedDuringTurn) {
      try await runtime.commitTurn(
        address: line.address, turnID: UUID(), userMessage: "旧请求",
        narrative: "旧模型结果", expectedEventSequence: 0, expectedStateHash: snapshot.state.stateHash,
        expectedCanon: token)
    }
    #expect(try await runtime.load(address: line.address).turns.isEmpty)
  }

  @Test func manifestTamperingAndUnsafeOwnedPathsAreRejected() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    let candidate = try await f.candidate()
    var manifest = try StoryworldPackageValidator().validate(at: candidate)
    manifest.title = "未审阅的候选标题"
    try StoryworldCoding.makeEncoder().encode(manifest).write(
      to: candidate.appendingPathComponent("manifest.json"))
    await #expect(throws: FactoryCoordinatorError.candidateChanged) {
      try await f.coordinator.publish(jobID: f.job.id)
    }
    #expect(try StoryworldPackageValidator().validate(at: candidate).title != manifest.title)
    let injected = candidate.appendingPathComponent("playthroughs/injected.json")
    try FileManager.default.createDirectory(
      at: injected.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: injected)
    await #expect(throws: FactoryCoordinatorError.candidateChanged) {
      try await f.coordinator.publish(jobID: f.job.id)
    }
    #expect(!FileManager.default.fileExists(atPath: injected.path))
    let path = candidate.appendingPathComponent(GeneratedPackageRevision.relativePath)
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    var assets = try #require(object["assets"] as? [String: String])
    assets["playthroughs/overwrite.json"] = "unsafe"
    object["assets"] = assets
    try JSONSerialization.data(withJSONObject: object).write(to: path)
    #expect(throws: GeneratedPackageError.invalidRevision) {
      try GeneratedPackageRevision.load(at: candidate)
    }
    #expect(try await f.worlds.list().isEmpty)
  }

  @Test func changedDecisionRebuildsAndRepeatPublicationIsANoop() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    let candidate = try await f.candidate()
    let original = try GeneratedPackageRevision.load(at: candidate)
    let first = try await f.coordinator.publish(jobID: f.job.id)
    try await f.coordinator.acceptRecommendation(decisionID: f.decision.id, jobID: f.job.id)
    #expect(try await f.store.load(f.job.id).stage == .completed)
    let repeatPublish = try await f.coordinator.publish(jobID: f.job.id)
    #expect(repeatPublish == first)
    #expect(try await f.worlds.listBackups(storyworldID: f.job.id).isEmpty)
    try await f.coordinator.answerDecision(
      decisionID: f.decision.id, jobID: f.job.id, answer: "从港口出发")
    #expect(try await f.store.load(f.job.id).stage == .waitingForUser)
    #expect(try await f.store.preview(f.job.id) == nil)
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    let next = try GeneratedPackageRevision.load(at: candidate)
    #expect(next.inputFingerprint != original.inputFingerprint)
    let updated = try await f.coordinator.publish(jobID: f.job.id)
    #expect(updated.id == first.id)
    #expect(updated.manifest.revision == first.manifest.revision + 1)
    #expect(updated.manifest.createdAt == first.manifest.createdAt)
    #expect(
      try await f.worlds.load(storyworldID: f.job.id).lorebook.entries.last?.content.contains(
        "从港口出发") == true)
    #expect(try await f.worlds.listBackups(storyworldID: f.job.id).count == 1)
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    #expect(try GeneratedPackageRevision.load(at: candidate) == next)
    #expect(try await f.coordinator.publish(jobID: f.job.id) == updated)
  }

  @Test func editedCandidateOrChangedAnalysisIsRebuiltForReview() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    try await f.coordinator.generateCandidate(jobID: f.job.id)
    let candidate = try await f.candidate()
    var lore = try StoryworldCoding.makeDecoder().decode(
      Lorebook.self,
      from: Data(contentsOf: candidate.appendingPathComponent("lorebook/lorebook.json")))
    lore.entries[0].content = "过期候选被改写"
    try StoryworldCoding.makeEncoder().encode(lore).write(
      to: candidate.appendingPathComponent("lorebook/lorebook.json"))
    await #expect(throws: FactoryCoordinatorError.candidateChanged) {
      try await f.coordinator.publish(jobID: f.job.id)
    }
    #expect(try await f.store.load(f.job.id).stage == .readyToPublish)
    #expect(try await f.worlds.list().isEmpty)
    _ = try await f.coordinator.publish(jobID: f.job.id)
    let first = try await f.worlds.load(storyworldID: f.job.id)
    #expect(!first.lorebook.entries[0].content.contains("过期候选"))
    // Simulate a saved analysis from a newer process, leaving an old preview.
    let old = try #require(try await f.store.analysis(f.job.id))
    let changed = FactoryAnalysis(
      sourceContentHash: old.sourceContentHash,
      coveredChapterIDs: old.coveredChapterIDs, proposals: old.proposals,
      decisions: try await f.store.decisions(f.job.id), warnings: ["补全结果有新说明"])
    try await f.store.saveAnalysis(changed, jobID: f.job.id)
    await #expect(throws: FactoryCoordinatorError.candidateChanged) {
      try await f.coordinator.publish(jobID: f.job.id)
    }
    #expect(try await f.worlds.load(storyworldID: f.job.id) == first)
  }

  @Test func republishPreservesRuntimeBindingsAndUnownedFiles() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    let (package, runtime) = try await f.publishAndOpen()
    let line = try await runtime.createPlaythrough(title: "保留的游玩线")
    _ = try await runtime.commitTurn(
      address: line.address, turnID: UUID(), userMessage: "出发", narrative: "旧设定正文")
    let save = try await runtime.createSave(address: line.address, title: "保留的存档")
    let fork = try await runtime.forkBranch(address: line.address, title: "保留的分支")
    _ = try await runtime.commitTurn(
      address: fork.address, turnID: UUID(), userMessage: "转身", narrative: "分支正文")
    let before = try await runtime.load(address: fork.address)
    let eventsPath = package.appendingPathComponent(
      "playthroughs/\(line.address.playthroughID.uuidString.lowercased())/branches/\(fork.address.branchID.uuidString.lowercased())/events.jsonl"
    )
    let events = try Data(contentsOf: eventsPath)
    let custom = package.appendingPathComponent("visual/keep.txt")
    try FileManager.default.createDirectory(
      at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("自有资料".utf8).write(to: custom)
    let mediaWriter = try FileHandle(forWritingTo: custom)
    defer { try? mediaWriter.close() }
    try mediaWriter.seekToEnd()
    let profile = MaterialProfile(primaryGenre: "fantasy", confidence: 0.8, source: "manual")
    try await f.worlds.saveMaterialProfile(profile, storyworldID: f.job.id)
    try await f.changeAndGenerate("从港口出发")
    _ = try await f.coordinator.publish(jobID: f.job.id)
    // An already-open media writer must still write into the live package,
    // rather than into the backup of a replaced directory.
    try mediaWriter.write(contentsOf: Data("，写入继续".utf8))
    let after = try await runtime.load(address: fork.address)
    #expect(after.effectiveTurns == before.effectiveTurns)
    #expect(after.state == before.state)
    #expect(after.context == before.context)
    #expect(after.canonStatus?.state == .changed)
    #expect(try Data(contentsOf: eventsPath) == events)
    #expect(try String(contentsOf: custom, encoding: .utf8) == "自有资料，写入继续")
    #expect(try await f.worlds.load(storyworldID: f.job.id).materialProfile == profile)
    #expect(
      try await runtime.listSaves(address: line.address).contains(where: { $0.id == save.id }))
    let backup = try #require(try await f.worlds.listBackups(storyworldID: f.job.id).first)
    #expect(
      try await StoryworldRuntimeStore(packageURL: backup).load(address: fork.address)
        .effectiveTurns == before.effectiveTurns)
  }

  @Test func concurrentCommitsSurvivePublicationAndRecoveryReads() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    let (_, runtime) = try await f.publishAndOpen()
    let line = try await runtime.createPlaythrough(title: "并发记录")
    try await f.changeAndGenerate("改写开局")
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<24 {
        group.addTask {
          _ = try await runtime.commitTurn(
            address: line.address, turnID: UUID(),
            userMessage: "行动\(index)", narrative: "记录\(index)")
        }
        if index.isMultiple(of: 4) {
          group.addTask { _ = try await f.worlds.list() }
        }
      }
      group.addTask { _ = try await f.coordinator.publish(jobID: f.job.id) }
      try await group.waitForAll()
    }
    let after = try await runtime.load(address: line.address)
    #expect(after.turns.count == 24)
    #expect(Set(after.turns.map(\.userMessage)).count == 24)
    #expect(after.turns.map(\.sequence) == Array(1...24))
    #expect(after.state.lastEventSequence == 24)
    #expect(try await f.worlds.load(storyworldID: f.job.id).manifest.revision == 2)
  }

  @Test func userEditedGeneratedFilesArePreservedAndUpdateStops() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    let (package, _) = try await f.publishAndOpen()
    try await f.worlds.addEntry(
      LoreEntry(title: "手工设定", content: "不能丢失"), categoryName: nil, storyworldID: f.job.id)
    let before = try Data(contentsOf: package.appendingPathComponent("lorebook/lorebook.json"))
    _ = try await f.coordinator.publish(jobID: f.job.id)  // unchanged publication preserves manual edits
    try await f.changeAndGenerate("新解释")
    await #expect(throws: GeneratedPackageError.editedGeneratedContent) {
      try await f.coordinator.publish(jobID: f.job.id)
    }
    #expect(
      try Data(contentsOf: package.appendingPathComponent("lorebook/lorebook.json")) == before)
    #expect(try await f.worlds.listBackups(storyworldID: f.job.id).isEmpty)
  }

  @Test func legacyPublishedPackageAndMissingCandidateCanBeRecovered() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    let (package, runtime) = try await f.publishAndOpen()
    let line = try await runtime.createPlaythrough(title: "旧工坊产物")
    try FileManager.default.removeItem(
      at: package.appendingPathComponent(GeneratedPackageRevision.relativePath))
    try await f.changeAndGenerate("使用新的解释")
    #expect(try await f.store.preview(f.job.id)?.legacyUpdate == true)
    _ = try await f.coordinator.publish(jobID: f.job.id)
    #expect(try await runtime.load(address: line.address).turns.isEmpty)
    #expect(try await f.worlds.load(storyworldID: f.job.id).manifest.revision == 2)
    try FileManager.default.removeItem(at: await f.candidate())
    await #expect(throws: FactoryCoordinatorError.candidateChanged) {
      try await f.coordinator.publish(jobID: f.job.id)
    }
    #expect(try await f.store.load(f.job.id).stage == .readyToPublish)
  }

  @Test func duplicateGenerationIsRejectedWithoutCorruptingCandidate() async throws {
    let f = try await PublicationFixture.make()
    defer { f.clean() }
    // All callers enter through the same actor guard before the first await.
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for _ in 0..<12 {
        group.addTask {
          do {
            try await f.coordinator.generateCandidate(jobID: f.job.id)
            return true
          } catch FactoryCoordinatorError.duplicateRun { return false } catch {
            Issue.record(error)
            return false
          }
        }
      }
      var values: [Bool] = []
      for await value in group { values.append(value) }
      return values
    }
    #expect(results.contains(true))
    #expect(results.contains(false))
    #expect(try await f.store.load(f.job.id).stage == .readyToPublish)
    let candidate = try await f.candidate()
    #expect(try GeneratedPackageRevision.load(at: candidate).matchesFiles(at: candidate))
  }
}

private struct PublicationFixture: Sendable {
  let root: URL
  let worlds: StoryworldLibrary
  let store: FactoryJobStore
  let coordinator: FactoryCoordinator
  let job: FactoryJob
  let decision: FactoryDecision

  static func make(sourceText: String = "第一章 出发\n林舟来到港口，准备调查旧塔。") async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "publication-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("合成小说.txt")
    try Data(sourceText.utf8).write(to: source)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.importDocument(from: source)
    let worlds = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("factory"))
    var job = try await store.create(document: record.document)
    let chapter = try #require(record.document.chapters.first)
    let evidence = FactoryEvidence(
      chapterTitle: chapter.title,
      anchor: TextAnchor(
        contentHash: record.document.contentHash, chapterID: chapter.id,
        range: .init(location: 0, length: 2)),
      excerpt: String(chapter.content.prefix(2)))
    let decision = FactoryDecision(
      jobID: job.id, question: "从哪里出发？", recommendation: "从旧塔出发",
      rationale: "有两处地点", impact: "影响开局", evidence: [evidence],
      resolution: .acceptedRecommendation, answer: "从旧塔出发", resolvedAt: Date())
    let analysis = FactoryAnalysis(
      sourceContentHash: record.document.contentHash,
      coveredChapterIDs: record.document.chapters.map(\.id),
      proposals: [
        .init(
          id: "linzhou", kind: .character, title: "林舟", content: "来到港口，准备调查旧塔。",
          evidence: [evidence])
      ],
      decisions: [decision])
    try await store.saveAnalysis(analysis, jobID: job.id)
    job.stage = .waitingForUser
    try await store.save(job)
    let coordinator = FactoryCoordinator(
      library: library, storyworldLibrary: worlds, store: store, worker: UnusedWorker())
    return Self(
      root: root, worlds: worlds, store: store, coordinator: coordinator, job: job,
      decision: decision)
  }

  func clean() { try? FileManager.default.removeItem(at: root) }
  func candidate() async throws -> URL {
    let path = try #require(try await store.load(job.id).candidatePackageRelativePath)
    return try await store.workspaceURL(jobID: job.id, relativePath: path)
  }
  func changeAndGenerate(_ answer: String) async throws {
    try await coordinator.answerDecision(decisionID: decision.id, jobID: job.id, answer: answer)
    try await coordinator.generateCandidate(jobID: job.id)
  }
  func publishAndOpen() async throws -> (URL, StoryworldRuntimeStore) {
    try await coordinator.generateCandidate(jobID: job.id)
    _ = try await coordinator.publish(jobID: job.id)
    let url = try await worlds.managedPackageURL(storyworldID: job.id)
    let runtime = await StoryworldRuntimeStoreRegistry.shared.store(forPackageURL: url)
    return (url, runtime)
  }
}

private struct UnusedWorker: FactoryAnalysisWorker {
  func analyze(
    jobID: UUID, manifest: FactoryInputManifest, snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void
  ) async throws -> FactoryWorkerResult {
    throw FactoryCoordinatorError.missingAnalysis
  }
  func cancel(jobID: UUID) async {}
}
