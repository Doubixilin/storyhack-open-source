import Foundation
import DirectoryJournalCore
import LibraryCore
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore

public enum FactoryCoordinatorError: Error, Equatable, LocalizedError {
  case invalidStage(FactoryStage)
  case unresolvedDecisions(Int)
  case missingAnalysis
  case missingCandidate
  case sourceChanged
  case incompleteAnalysis
  case duplicateRun
  case candidateChanged
  case staleDecision

  public var errorDescription: String? {
    switch self {
    case .invalidStage(let stage): "当前任务阶段不能执行此操作：\(stage.rawValue)"
    case .unresolvedDecisions(let count): "仍有 \(count) 个问题需要确认"
    case .missingAnalysis: "任务缺少可恢复的分析结果"
    case .missingCandidate: "任务缺少通过校验的候选世界书"
    case .sourceChanged: "小说内容版本已经变化，请新建工坊任务"
    case .incompleteAnalysis: "分析尚未形成可用且有原文依据的世界书内容"
    case .duplicateRun: "这个工坊任务已经在运行"
    case .candidateChanged: "候选已按最新分析和决策重新生成，请查看更新后的预览再发布。"
    case .staleDecision: "这项决策已变化，请重新读取后再作答。"
    }
  }
}

public actor FactoryCoordinator {
  public let store: FactoryJobStore

  private let library: NovelLibrary
  private let storyworldLibrary: StoryworldLibrary
  private let worker: any FactoryAnalysisWorker
  private let tasteStore: PlayerTasteStore
  private let commandLineTaste: PlayerTasteOverrides
  private let fileManager: FileManager
  private var activeJobIDs = Set<UUID>()
  private var operationLeases: [UUID: DirectoryProcessLease] = [:]
  private var cancelledOperationIDs = Set<UUID>()

  public init(
    library: NovelLibrary,
    storyworldLibrary: StoryworldLibrary,
    store: FactoryJobStore = FactoryJobStore(),
    worker: any FactoryAnalysisWorker,
    tasteStore: PlayerTasteStore = .shared,
    commandLineTaste: PlayerTasteOverrides = .init(),
    fileManager: FileManager = .default
  ) {
    self.library = library
    self.storyworldLibrary = storyworldLibrary
    self.store = store
    self.worker = worker
    self.tasteStore = tasteStore
    self.commandLineTaste = commandLineTaste
    self.fileManager = fileManager
  }

  @discardableResult
  public func createJob(documentID: UUID) async throws -> FactoryJob {
    let record = try await library.load(documentID: documentID)
    return try await store.create(document: record.document)
  }

  public func recoverInterruptedJobs() async throws -> [FactoryJob] {
    try await store.recoverInterruptedJobs()
  }

  public func globalTaste() async throws -> PlayerTasteSnapshot { try await tasteStore.load() }

  public func saveGlobalTaste(_ profile: PlayerTasteProfile, replacing previous: PlayerTasteSnapshot) async throws {
    try await tasteStore.save(profile, replacing: previous)
  }

  public func tasteSettings(jobID: UUID) async throws -> FactoryTasteSettings {
    let job = try await store.load(jobID)
    let inherited = try await commandLineTaste.applying(to: tasteStore.load().profile)
    return .init(jobID: jobID, configuration: job.tasteConfiguration, inherited: inherited)
  }

  public func updateTasteSettings(_ reviewed: FactoryTasteSettings, overrides: PlayerTasteOverrides) async throws {
    try beginJobOperation(reviewed.jobID)
    defer { endJobOperation(reviewed.jobID) }
    var job = try await store.load(reviewed.jobID)
    guard !job.stage.isRunning else { throw FactoryCoordinatorError.invalidStage(job.stage) }
    let overrides = try overrides.validated()
    guard job.tasteConfiguration == reviewed.configuration else { throw PlayerTasteError.staleEdit }
    guard (job.tasteConfiguration?.overrides ?? .init()) != overrides else { return }
    job.tasteConfiguration = try .init(overrides: overrides)
    if try await store.analysis(job.id) != nil {
      job.stage = .waitingForUser; job.progress = 0.82; job.failure = nil; job.resumeStage = nil
    }
    job.updatedAt = Date()
    try await store.save(job)
    try await store.clearCandidateReports(job.id)
  }

  private func effectiveTaste(_ job: FactoryJob) async throws -> PlayerTasteProfile {
    try await PlayerTasteOverrides.resolve(defaults: tasteStore.load().profile,
      commandLine: commandLineTaste, job: job.tasteConfiguration?.overrides ?? .init())
  }

  public func startAnalysis(jobID: UUID) async throws {
    try await runAnalysis(
      jobID: jobID,
      allowedStages: [.queued, .failed, .cancelled],
      preservesUsableAnalysis: false
    )
  }

  public func supplementAnalysis(jobID: UUID, requestApproval: FactoryRequestRetryApproval? = nil) async throws {
    try await runAnalysis(
      jobID: jobID,
      allowedStages: [.waitingForUser, .readyToPublish, .completed],
      preservesUsableAnalysis: true,
      requestApproval: requestApproval
    )
  }

  private func runAnalysis(
    jobID: UUID,
    allowedStages: Set<FactoryStage>,
    preservesUsableAnalysis: Bool,
    operationAlreadyActive: Bool = false,
    requestApproval: FactoryRequestRetryApproval? = nil
  ) async throws {
    if !operationAlreadyActive { try beginJobOperation(jobID) }
    defer { if !operationAlreadyActive { endJobOperation(jobID) } }
    var job = try await store.load(jobID)
    guard allowedStages.contains(job.stage) else {
      throw FactoryCoordinatorError.invalidStage(job.stage)
    }
    try await store.authorizeRequestRetry(jobID, approval: requestApproval, kind: .analysis)
    let previousDecisions = preservesUsableAnalysis ? try await store.decisions(jobID) : []
    let storedPreviousAnalysis = preservesUsableAnalysis ? try await store.analysis(jobID) : nil
    let previousAnalysis = storedPreviousAnalysis.map {
      preservingDecisionResolutions(in: $0, previousDecisions: previousDecisions)
    }
    do {
      try await store.clearCandidateReports(jobID)
      job.failure = nil
      job.resumeStage = nil
      try await transition(&job, to: .parsing, progress: 0.01)
      let record = try await library.load(documentID: job.documentID)
      try verifySource(job: job, document: record.document)

      try await transition(&job, to: .indexing, progress: 0.04)
      let manifest = try await store.inputManifest(jobID)
      guard manifest.contentHash == job.sourceContentHash,
        manifest.chapters.count == record.document.chapters.count
      else { throw FactoryCoordinatorError.sourceChanged }

      try await transition(&job, to: .analyzing, progress: 0.08)
      let snapshotURL = try await store.workspaceURL(
        jobID: jobID,
        relativePath: job.sourceSnapshotRelativePath
      )
      let store = self.store
      let result = try await worker.analyze(
        jobID: jobID,
        manifest: manifest,
        snapshotURL: snapshotURL
      ) { progress in
        do {
          var latest = try await store.load(jobID)
          guard latest.stage == .analyzing else { return }
          latest.progress = 0.08 + progress.fraction * 0.72
          if let version = progress.executorVersion { latest.executorVersion = version }
          if let sessionID = progress.sessionID { latest.executorSessionID = sessionID }
          latest.updatedAt = Date()
          try await store.save(latest)
        } catch {
          // A transient progress write must not discard completed model output.
        }
      }
      guard !cancelledOperationIDs.contains(jobID) else { throw CancellationError() }
      let analysis = preservingDecisionResolutions(
        in: result.analysis,
        previousDecisions: previousDecisions
      )
      try validateAnalysis(analysis, manifest: manifest)
      try await store.saveAnalysis(analysis, jobID: jobID)
      job = try await store.load(jobID)
      job.executorVersion = result.executorVersion
      job.executorSessionID = result.sessionID
      try await transition(&job, to: .waitingForUser, progress: 0.82)
    } catch is CancellationError {
      await worker.cancel(jobID: jobID)
      job = (try? await store.load(jobID)) ?? job
      if let previousAnalysis {
        let restored = analysisByAppendingWarning(
          previousAnalysis,
          "补全已取消，现有结果仍可继续使用。"
        )
        try? await store.saveAnalysis(restored, jobID: jobID)
        job.stage = .waitingForUser
        job.progress = 0.82
        job.failure = nil
        job.updatedAt = Date()
        try? await store.save(job)
        return
      }
      job.stage = .cancelled
      job.progress = min(job.progress, 0.99)
      job.failure = FactoryFailure(category: .cancelled, message: "用户已取消任务。", retryable: true)
      job.updatedAt = Date()
      try? await store.save(job)
      throw CancellationError()
    } catch {
      job = (try? await store.load(jobID)) ?? job
      if let previousAnalysis {
        let restored = analysisByAppendingWarning(
          previousAnalysis,
          "本次补全未完成，现有结果仍可继续使用；请检查工坊执行器与模型配置后再试。"
        )
        try? await store.saveAnalysis(restored, jobID: jobID)
        job.stage = .waitingForUser
        job.progress = 0.82
        job.failure = nil
        job.updatedAt = Date()
        try? await store.save(job)
        return
      }
      job.stage = .failed
      job.failure = classify(error)
      job.updatedAt = Date()
      try? await store.save(job)
      throw error
    }
  }

  public func acceptRecommendation(decisionID: UUID, jobID: UUID) async throws {
    try beginJobOperation(jobID)
    defer { endJobOperation(jobID) }
    try await requireDecisionEditingStage(jobID)
    var decisions = try await store.decisions(jobID)
    guard let index = decisions.firstIndex(where: { $0.id == decisionID }) else {
      throw FactoryCoordinatorError.missingAnalysis
    }
    decisions[index].resolution = .acceptedRecommendation
    decisions[index].answer = decisions[index].recommendation
    decisions[index].resolvedAt = Date()
    try await saveEditedDecisions(decisions, jobID: jobID)
  }

  /// A CLI/file review must apply to the exact decision the author inspected,
  /// not whichever recommendation now occupies the same stable ID.
  public func answerReviewedDecision(_ reviewed: FactoryDecision, answer: String?) async throws {
    try beginJobOperation(reviewed.jobID)
    defer { endJobOperation(reviewed.jobID) }
    try await requireDecisionEditingStage(reviewed.jobID)
    var decisions = try await store.decisions(reviewed.jobID)
    guard let index = decisions.firstIndex(where: { $0.id == reviewed.id }), decisions[index] == reviewed else {
      throw FactoryCoordinatorError.staleDecision
    }
    let value = (answer ?? reviewed.recommendation).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 10_000 else { throw FactoryCoordinatorError.staleDecision }
    decisions[index].resolution = answer == nil ? .acceptedRecommendation : .customAnswer
    decisions[index].answer = value
    decisions[index].resolvedAt = Date()
    try await saveEditedDecisions(decisions, jobID: reviewed.jobID)
  }

  public func answerDecision(
    decisionID: UUID,
    jobID: UUID,
    answer: String
  ) async throws {
    let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    try beginJobOperation(jobID)
    defer { endJobOperation(jobID) }
    try await requireDecisionEditingStage(jobID)
    var decisions = try await store.decisions(jobID)
    guard let index = decisions.firstIndex(where: { $0.id == decisionID }) else {
      throw FactoryCoordinatorError.missingAnalysis
    }
    decisions[index].resolution = .customAnswer
    decisions[index].answer = value
    decisions[index].resolvedAt = Date()
    try await saveEditedDecisions(decisions, jobID: jobID)
  }

  /// 允许用户撤销已确认项并重新选择；候选尚未生成时不丢失分析结果。
  public func reopenDecision(decisionID: UUID, jobID: UUID) async throws {
    try beginJobOperation(jobID)
    defer { endJobOperation(jobID) }
    try await requireDecisionEditingStage(jobID)
    var decisions = try await store.decisions(jobID)
    guard let index = decisions.firstIndex(where: { $0.id == decisionID }) else {
      throw FactoryCoordinatorError.missingAnalysis
    }
    decisions[index].resolution = .unanswered
    decisions[index].answer = nil
    decisions[index].resolvedAt = nil
    try await saveEditedDecisions(decisions, jobID: jobID)
  }

  public func acceptAllRecommendations(jobID: UUID) async throws {
    try beginJobOperation(jobID)
    defer { endJobOperation(jobID) }
    try await requireDecisionEditingStage(jobID)
    var decisions = try await store.decisions(jobID)
    for index in decisions.indices where decisions[index].resolution == .unanswered {
      decisions[index].resolution = .acceptedRecommendation
      decisions[index].answer = decisions[index].recommendation
      decisions[index].resolvedAt = Date()
    }
    try await saveEditedDecisions(decisions, jobID: jobID)
  }

  private func beginJobOperation(_ jobID: UUID) throws {
    guard activeJobIDs.insert(jobID).inserted else { throw FactoryCoordinatorError.duplicateRun }
    do { operationLeases[jobID] = try store.acquireOperation(jobID) }
    catch { activeJobIDs.remove(jobID); throw error }
    cancelledOperationIDs.remove(jobID)
  }

  private func endJobOperation(_ jobID: UUID) {
    operationLeases.removeValue(forKey: jobID)?.release()
    activeJobIDs.remove(jobID)
  }

  private func requireDecisionEditingStage(_ jobID: UUID) async throws {
    let job = try await store.load(jobID)
    guard [.waitingForUser, .readyToPublish, .completed, .failed].contains(job.stage) else {
      throw FactoryCoordinatorError.invalidStage(job.stage)
    }
  }

  private func saveEditedDecisions(_ decisions: [FactoryDecision], jobID: UUID) async throws {
    let previous = try await store.decisions(jobID)
    // Same answer/resolution is a no-op, including its original audit timestamp.
    let unchanged = zip(previous, decisions).allSatisfy { a, b in
      a.id == b.id && a.answer == b.answer && a.resolution == b.resolution
    } && previous.count == decisions.count
    guard !unchanged else { return }
    try await store.saveDecisions(decisions, jobID: jobID)
    var job = try await store.load(jobID)
    job.stage = .waitingForUser
    job.failure = nil
    job.updatedAt = Date()
    try await store.save(job)
    try await store.clearCandidateReports(jobID)
  }

  public func generateCandidate(jobID: UUID, requestApproval: FactoryRequestRetryApproval? = nil) async throws {
    try beginJobOperation(jobID)
    defer { endJobOperation(jobID) }
    try await store.authorizeRequestRetry(jobID, approval: requestApproval, kind: .bake)
    try await generateCandidateUnlocked(jobID: jobID)
  }

  private func generateCandidateUnlocked(jobID: UUID, allowRequests: Bool = true) async throws {
    var job = try await store.load(jobID)
    guard [.waitingForUser, .failed, .cancelled, .readyToPublish, .completed].contains(job.stage) else {
      throw FactoryCoordinatorError.invalidStage(job.stage)
    }
    do {
      let analysis = try await store.analysis(jobID)
      guard let analysis else { throw FactoryCoordinatorError.missingAnalysis }
      let decisions = try await store.decisions(jobID)
      let unresolved = decisions.filter { $0.resolution == .unanswered }.count
      guard unresolved == 0 else {
        throw FactoryCoordinatorError.unresolvedDecisions(unresolved)
      }
      let current = try await library.load(documentID: job.documentID)
      try verifySource(job: job, document: current.document)

      let playerTaste = try await effectiveTaste(job)
      try await store.clearCandidateReports(jobID)
      job.resumeStage = .generating
      try await transition(&job, to: .generating, progress: 0.84)
      try validateAnalysis(analysis, manifest: FactoryInputManifest(document: current.document))
      let candidateRelativePath = "candidate/\(job.id.uuidString.lowercased()).storyworld"
      let candidateURL = try await store.workspaceURL(
        jobID: jobID,
        relativePath: candidateRelativePath
      )
      let sourceFingerprint = try FactoryCandidateFingerprint.make(job: job, document: current.document,
        analysis: analysis, decisions: decisions, playerTaste: playerTaste)
      let bake: FactoryBakeReport
      let savedBake = try await store.bakeReport(jobID)
      if !allowRequests, let savedBake,
        (try? savedBake.validate(sourceFingerprint: sourceFingerprint, proposals: analysis.proposals,
          decisions: decisions, playerTaste: playerTaste)) != nil {
        bake = savedBake
      } else if decisions.isEmpty && playerTaste.isDefault {
        bake = .make(sourceFingerprint: sourceFingerprint, executor: "none", targets: [],
          rewrites: [], decisions: [], warnings: [])
      } else if !allowRequests {
        bake = .retained(sourceFingerprint: sourceFingerprint, proposals: analysis.proposals,
          decisions: decisions, reason: "输入或偏好已变化，发布未发起模型请求；请先生成候选，或核对保留的原候选。",
          playerTaste: playerTaste)
      } else {
        let workspace = try await store.workspaceURL(jobID: jobID)
        guard !cancelledOperationIDs.contains(jobID) else { throw CancellationError() }
        bake = try await worker.bake(.init(jobID: jobID, sourceContentHash: job.sourceContentHash,
          sourceFingerprint: sourceFingerprint, proposals: analysis.proposals,
          decisions: decisions, workspaceURL: workspace, playerTaste: playerTaste), allowRequests: true) { [store] update in
            guard var latest = try? await store.load(jobID), latest.stage == .generating else { return }
            latest.progress = 0.84 + update.fraction * 0.08
            try? await store.save(latest)
          }
      }
      try bake.validate(sourceFingerprint: sourceFingerprint, proposals: analysis.proposals,
        decisions: decisions, playerTaste: playerTaste)
      let latestDocument = try await library.load(documentID: job.documentID).document
      guard let latestAnalysis = try await store.analysis(jobID) else { throw FactoryCoordinatorError.missingAnalysis }
      let latestDecisions = try await store.decisions(jobID)
      let latestJob = try await store.load(jobID)
      let latestTaste = try await effectiveTaste(latestJob)
      guard !cancelledOperationIDs.contains(jobID) else { throw CancellationError() }
      guard try FactoryCandidateFingerprint.make(job: latestJob, document: latestDocument,
        analysis: latestAnalysis, decisions: latestDecisions, playerTaste: latestTaste) == sourceFingerprint else {
        throw FactoryBakeError.changedDuringGeneration
      }
      try await store.saveBakeReport(bake, jobID: jobID)
      guard !cancelledOperationIDs.contains(jobID) else { throw CancellationError() }
      let fingerprint = try FactoryCandidateFingerprint.compiled(source: sourceFingerprint, bake: bake)
      if !candidateIsCurrent(at: candidateURL, fingerprint: fingerprint, jobID: jobID) {
        try buildCandidate(job: job, document: current.document, analysis: analysis,
          decisions: decisions, bake: bake, playerTaste: playerTaste, inputFingerprint: fingerprint, destination: candidateURL)
      }
      job.candidatePackageRelativePath = candidateRelativePath
      try await transition(&job, to: .validating, progress: 0.93)
      let manifest = try StoryworldPackageValidator().validate(at: candidateURL)
      guard manifest.storyworldID == job.id else {
        throw FactoryCoordinatorError.missingCandidate
      }
      let report = FactoryValidationReport(
        sourceContentHash: job.sourceContentHash,
        lorebookEntryCount: analysis.proposals.count + bake.unresolvedDecisionIDs.count,
        resolvedDecisionCount: decisions.count,
        warnings: analysis.warnings + bake.warnings + [FactoryPlotlineBuilder.assess(analysis: analysis,
          manifest: FactoryInputManifest(document: current.document)).coverage.notice].compactMap { $0 },
        bakeReport: bake,
        playerTaste: playerTaste.isDefault ? nil : playerTaste
      )
      try await store.saveValidation(report, jobID: jobID)
      let target = StoryworldAssociationTarget(
        documentID: job.documentID,
        contentHash: job.sourceContentHash
      )
      let existing = try await storyworldLibrary.listAssociated(with: target)
      let publishedURL = try? await storyworldLibrary.managedPackageURL(storyworldID: job.id)
      let legacyUpdate = publishedURL.map {
        !fileManager.fileExists(atPath: $0.appendingPathComponent(GeneratedPackageRevision.relativePath).path)
      } ?? false
      let preview = FactoryDiffPreview(
        title: current.document.title + " · 世界书",
        newEntryTitles: analysis.proposals.map(\.title).sorted(),
        existingStoryworldCount: existing.count,
        existingEntryCount: existing.reduce(0) { $0 + $1.lorebookEntryCount },
        resolvedDecisionCount: decisions.count,
        candidateFingerprint: fingerprint,
        updatesExistingWorld: publishedURL != nil,
        legacyUpdate: legacyUpdate
      )
      try await store.savePreview(preview, jobID: jobID)
      guard !cancelledOperationIDs.contains(jobID) else { throw CancellationError() }
      job.resumeStage = nil
      try await transition(&job, to: .readyToPublish, progress: 1)
    } catch {
      job = (try? await store.load(jobID)) ?? job
      job.stage = error is CancellationError || cancelledOperationIDs.contains(jobID) ? .cancelled : .failed
      job.failure = classify(error)
      job.updatedAt = Date()
      try? await store.save(job)
      throw error
    }
  }

  private func candidateIsCurrent(at url: URL, fingerprint: String, jobID: UUID) -> Bool {
    guard let manifest = try? StoryworldPackageValidator().validate(at: url),
      manifest.storyworldID == jobID,
      let revision = try? GeneratedPackageRevision.load(at: url),
      revision.inputFingerprint == fingerprint,
      (try? revision.matchesFiles(at: url)) == true else { return false }
    // A newly injected generated file is also a candidate edit.
    return (try? GeneratedPackageRevision.make(at: url, inputFingerprint: fingerprint)) == revision
  }

  @discardableResult
  public func publish(jobID: UUID) async throws -> StoryworldLibraryRecord {
    try beginJobOperation(jobID)
    defer { endJobOperation(jobID) }
    var job = try await store.load(jobID)
    guard [.readyToPublish, .completed].contains(job.stage),
      let relativePath = job.candidatePackageRelativePath
    else { throw FactoryCoordinatorError.invalidStage(job.stage) }
    do {
      let current = try await library.load(documentID: job.documentID)
      try verifySource(job: job, document: current.document)
      guard let analysis = try await store.analysis(jobID) else { throw FactoryCoordinatorError.missingAnalysis }
      try validateAnalysis(analysis, manifest: FactoryInputManifest(document: current.document))
      let decisions = try await store.decisions(jobID)
      let unresolved = decisions.filter { $0.resolution == .unanswered }.count
      guard unresolved == 0 else { throw FactoryCoordinatorError.unresolvedDecisions(unresolved) }
      let playerTaste = try await effectiveTaste(job)
      let sourceFingerprint = try FactoryCandidateFingerprint.make(job: job, document: current.document,
        analysis: analysis, decisions: decisions, playerTaste: playerTaste)
      let bake = try await store.bakeReport(jobID)
      let validBake = bake.flatMap {
        (try? $0.validate(sourceFingerprint: sourceFingerprint, proposals: analysis.proposals,
          decisions: decisions, playerTaste: playerTaste)) != nil ? $0 : nil
      }
      let fingerprint = try validBake.map { try FactoryCandidateFingerprint.compiled(source: sourceFingerprint, bake: $0) } ?? ""
      let candidateURL = try await store.workspaceURL(jobID: jobID, relativePath: relativePath)
      if !candidateIsCurrent(at: candidateURL, fingerprint: fingerprint, jobID: jobID) {
        try await generateCandidateUnlocked(jobID: jobID, allowRequests: false)
        throw FactoryCoordinatorError.candidateChanged
      }
      let record = try await storyworldLibrary.publishGeneratedPackage(from: candidateURL,
        associateWith: StoryworldAssociationTarget(documentID: job.documentID, contentHash: job.sourceContentHash))
      job.stage = .completed
      job.progress = 1
      job.publishedStoryworldID = record.id
      job.failure = nil
      job.updatedAt = Date()
      try await store.save(job)
      return record
    } catch FactoryCoordinatorError.candidateChanged {
      // The refreshed preview is ready for review, not a failed generation.
      throw FactoryCoordinatorError.candidateChanged
    } catch {
      job.stage = .failed
      job.failure = FactoryFailure(category: .publishing, message: error.localizedDescription, retryable: true)
      job.updatedAt = Date()
      try? await store.save(job)
      throw error
    }
  }

  public func hasPublishedPackage(jobID: UUID) async -> Bool {
    (try? await storyworldLibrary.load(storyworldID: jobID)) != nil
  }

  public func cancel(jobID: UUID) async {
    // A different coordinator/process cannot cancel our worker or rewrite a
    // live task's state. Queued or orphaned jobs can still be cancelled locally.
    let acquired = !activeJobIDs.contains(jobID)
    if acquired {
      do { try beginJobOperation(jobID) } catch { return }
    }
    defer { if acquired { endJobOperation(jobID) } }
    guard let operationLease = operationLeases[jobID],
      let current = try? await store.load(jobID), operationLeases[jobID] === operationLease,
      [.queued, .parsing, .indexing, .analyzing, .generating, .validating].contains(current.stage) else { return }
    cancelledOperationIDs.insert(jobID)
    await worker.cancel(jobID: jobID)
    guard operationLeases[jobID] === operationLease,
      var job = try? await store.load(jobID), operationLeases[jobID] === operationLease,
      [.queued, .parsing, .indexing, .analyzing, .generating, .validating].contains(job.stage) else { return }
    job.stage = .cancelled
    job.failure = FactoryFailure(category: .cancelled, message: "用户已取消任务。", retryable: true)
    job.updatedAt = Date()
    try? await store.save(job)
  }

  public func retry(jobID: UUID, requestApproval: FactoryRequestRetryApproval? = nil) async throws {
    try beginJobOperation(jobID)
    defer { endJobOperation(jobID) }
    var job = try await store.load(jobID)
    guard job.stage == .failed || job.stage == .cancelled else {
      throw FactoryCoordinatorError.invalidStage(job.stage)
    }
    if job.failure?.category == .publishing,
      job.candidatePackageRelativePath != nil
    {
      job.stage = .readyToPublish
      job.failure = nil
      job.updatedAt = Date()
      try await store.save(job)
      return
    }
    if job.resumeStage == .generating {
      try await store.authorizeRequestRetry(jobID, approval: requestApproval, kind: .bake)
      try await generateCandidateUnlocked(jobID: jobID)
      return
    }
    try await store.authorizeRequestRetry(jobID, approval: requestApproval, kind: .analysis)
    job.retryCount += 1
    job.stage = .queued
    job.progress = 0
    job.failure = nil
    job.updatedAt = Date()
    try await store.save(job)
    try await runAnalysis(jobID: jobID, allowedStages: [.queued], preservesUsableAnalysis: false,
      operationAlreadyActive: true)
  }

  private func transition(_ job: inout FactoryJob, to stage: FactoryStage, progress: Double)
    async throws
  {
    job.stage = stage
    job.progress = min(max(progress, 0), 1)
    job.updatedAt = Date()
    try await store.save(job)
  }

  private func verifySource(job: FactoryJob, document: NovelDocument) throws {
    guard document.id == job.documentID, document.contentHash == job.sourceContentHash else {
      throw FactoryCoordinatorError.sourceChanged
    }
  }

  private func validateAnalysis(
    _ analysis: FactoryAnalysis,
    manifest: FactoryInputManifest
  ) throws {
    let expected = Set(manifest.chapters.map(\.id))
    let actual = Set(analysis.coveredChapterIDs)
    guard analysis.schemaVersion == FactoryJob.outputSchemaVersion,
      analysis.sourceContentHash == manifest.contentHash,
      actual.isSubset(of: expected),
      actual.count == analysis.coveredChapterIDs.count,
      !analysis.proposals.isEmpty,
      analysis.proposals.allSatisfy({ !$0.evidence.isEmpty })
    else { throw FactoryCoordinatorError.incompleteAnalysis }
  }

  private func preservingDecisionResolutions(
    in analysis: FactoryAnalysis,
    previousDecisions: [FactoryDecision]
  ) -> FactoryAnalysis {
    let previousByContent = Dictionary(grouping: previousDecisions) {
      [$0.jobID.uuidString, $0.question, $0.recommendation]
    }
    let decisions = analysis.decisions.map { decision in
      let matches = previousByContent[[decision.jobID.uuidString, decision.question, decision.recommendation]] ?? []
      // Stable identity wins. Legacy random IDs can migrate only when the
      // question AND recommendation have one unambiguous previous decision.
      let exact = matches.filter { $0.id == decision.id }
      guard let previous = exact.count == 1 ? exact.first : (matches.count == 1 ? matches.first : nil),
        previous.resolution != .unanswered
      else { return decision }
      return FactoryDecision(
        id: decision.id,
        jobID: decision.jobID,
        question: decision.question,
        recommendation: decision.recommendation,
        rationale: decision.rationale,
        impact: decision.impact,
        evidence: decision.evidence,
        resolution: previous.resolution,
        answer: previous.answer,
        resolvedAt: previous.resolvedAt
      )
    }
    return FactoryAnalysis(
      sourceContentHash: analysis.sourceContentHash,
      coveredChapterIDs: analysis.coveredChapterIDs,
      proposals: analysis.proposals,
      decisions: decisions,
      warnings: analysis.warnings,
      chapterSummaries: analysis.chapterSummaries
    )
  }

  private func analysisByAppendingWarning(
    _ analysis: FactoryAnalysis,
    _ warning: String
  ) -> FactoryAnalysis {
    FactoryAnalysis(
      sourceContentHash: analysis.sourceContentHash,
      coveredChapterIDs: analysis.coveredChapterIDs,
      proposals: analysis.proposals,
      decisions: analysis.decisions,
      warnings: Array(Set(analysis.warnings + [warning])).sorted(),
      chapterSummaries: analysis.chapterSummaries
    )
  }

  private func buildCandidate(
    job: FactoryJob,
    document: NovelDocument,
    analysis: FactoryAnalysis,
    decisions: [FactoryDecision],
    bake: FactoryBakeReport,
    playerTaste: PlayerTasteProfile,
    inputFingerprint: String,
    destination: URL
  ) throws {
    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(
      ".staging-\(UUID().uuidString).storyworld", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }
    let lorebookURL = staging.appendingPathComponent("lorebook", isDirectory: true)
    let provenanceURL = staging.appendingPathComponent("factory", isDirectory: true)
    try fileManager.createDirectory(at: lorebookURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: provenanceURL, withIntermediateDirectories: true)

    let categoryIDs = Set(analysis.proposals.map { $0.kind.rawValue })
    let categories = categoryIDs.sorted().map { LorebookCategory(id: $0, name: categoryName($0)) }
    var entries = bake.applying(to: analysis.proposals).map { proposal in
      LoreEntry(
        id: proposal.id,
        title: proposal.title,
        content: proposal.content,
        activationKeys: proposal.activationKeys,
        alwaysActive: proposal.alwaysActive,
        categoryID: proposal.kind.rawValue
      )
    }
    entries += bake.fallbackEntries(decisions: decisions, proposals: analysis.proposals)
    let title = document.title + " · 世界书"
    let lorebook = Lorebook(id: job.id, title: title, entries: entries, categories: categories)
    try LorebookValidator().validate(lorebook)
    let manifest = StoryworldManifest(
      storyworldID: job.id,
      title: title,
      sourceReference: StoryworldSourceReference(
        contentHash: document.contentHash,
        sourceFormat: document.sourceFormat.rawValue,
        sourceFileName: document.sourceFileName,
        title: document.title
      )
    )
    let provenance = FactoryCandidateProvenance(
      jobID: job.id,
      sourceContentHash: document.contentHash,
      proposals: analysis.proposals,
      decisions: decisions,
      coveredChapterIDs: analysis.coveredChapterIDs,
      warnings: analysis.warnings,
      bakeReport: bake,
      playerTaste: playerTaste.isDefault ? nil : playerTaste
    )
    try StoryworldCoding.makeEncoder().encode(manifest).write(
      to: staging.appendingPathComponent("manifest.json"),
      options: .atomic
    )
    try StoryworldCoding.makeEncoder().encode(lorebook).write(
      to: lorebookURL.appendingPathComponent("lorebook.json"),
      options: .atomic
    )
    try StoryworldCoding.makeEncoder().encode(provenance).write(
      to: provenanceURL.appendingPathComponent("provenance.json"),
      options: .atomic
    )
    // 可选产物：原著节拍线（时间线候选条目推导，无新增 LLM 调用）
    if let timeline = FactoryTimelineBuilder.makeTimeline(
      analysis: analysis,
      document: document
    ) {
      try StoryworldCoding.makeEncoder().encode(timeline).write(
        to: staging.appendingPathComponent(StoryworldPackageLayout.timeline),
        options: .atomic
      )
    }
    // 可选产物：原著主线（逐章摘要拼接，无新增 LLM 调用）；
    // 保留完整摘要节点及明确的缺章清单；节点 ID/顺序绑定原文章序，
    // 补全缺口不会给已经发布的节点重新编号。
    if let plotline = FactoryPlotlineBuilder.makePlotline(
      analysis: analysis,
      manifest: FactoryInputManifest(document: document)
    ) {
      try StoryworldCoding.makeEncoder().encode(plotline).write(
        to: staging.appendingPathComponent(StoryworldPackageLayout.plotline),
        options: .atomic
      )
    }
    _ = try StoryworldPackageValidator().validate(at: staging)
    try GeneratedPackageRevision.make(at: staging, inputFingerprint: inputFingerprint).write(to: staging)
    try GeneratedPackageRevision.installCandidate(from: staging, to: destination)
  }

  private func categoryName(_ id: String) -> String {
    switch FactoryLoreProposal.Kind(rawValue: id) {
    case .character: "人物"
    case .location: "地点"
    case .rule: "世界规则"
    case .timeline: "时间线"
    case .relationship: "关系"
    case .foreshadowing: "伏笔"
    case .scene: "名场面"
    case .overview: "总览"
    case nil: id
    }
  }

  private func classify(_ error: Error) -> FactoryFailure {
    if error is CancellationError {
      return FactoryFailure(category: .cancelled, message: "任务已取消。", retryable: true)
    }
    if error as? FactoryCoordinatorError == .sourceChanged {
      return FactoryFailure(
        category: .sourceChanged, message: error.localizedDescription, retryable: false)
    }
    if case FactoryWorkerError.authentication = error {
      return FactoryFailure(
        category: .authentication,
        message: ProviderErrorMessage.message(statusCode: 401),
        retryable: true
      )
    }
    if case FactoryWorkerError.uncertainPriorRequest = error {
      return FactoryFailure(
        category: .invalidOutput,
        message: error.localizedDescription,
        retryable: false
      )
    }
    if error is FactoryWorkerError || error is FactoryAnalysisBudgetError {
      return FactoryFailure(category: .model, message: error.localizedDescription, retryable: true)
    }
    if error is OpenAICompatibleError || error is URLError {
      return FactoryFailure(
        category: .model,
        message: ProviderErrorMessage.message(for: error),
        retryable: true
      )
    }
    if error is StoryworldPackageValidationError || error is LorebookValidationError {
      return FactoryFailure(
        category: .validation, message: error.localizedDescription, retryable: true)
    }
    return FactoryFailure(
      category: .unknown,
      message: "世界书工坊遇到未预期的错误，请重试；若持续失败，请更换模型或稍后再试。",
      retryable: true
    )
  }
}
