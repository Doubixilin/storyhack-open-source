import Combine
import Foundation
import LibraryCore
import StoryworldFactory
import StoryworldCore

public struct FactoryPendingRetry: Sendable {
  public enum Action: Sendable { case retry, supplement, generate }
  public let approval: FactoryRequestRetryApproval
  public let action: Action
}

@MainActor
public final class FactoryViewModel: ObservableObject {
  @Published public private(set) var jobs: [FactoryJob] = []
  @Published public var selectedJobID: UUID?
  @Published public private(set) var decisions: [FactoryDecision] = []
  @Published public private(set) var analysis: FactoryAnalysis?
  @Published public private(set) var manifest: FactoryInputManifest?
  @Published public private(set) var preview: FactoryDiffPreview?
  @Published public private(set) var validation: FactoryValidationReport?
  @Published public private(set) var tasteSettings: FactoryTasteSettings?
  @Published public private(set) var isBusy = false
  @Published public var errorMessage: String?
  @Published public var pendingRetry: FactoryPendingRetry?
  @Published public private(set) var publishedStoryworldID: UUID?

  private let coordinator: FactoryCoordinator
  private let store: FactoryJobStore
  private var didRecover = false
  private var pollTask: Task<Void, Never>?

  /// 发布成功后回调（RootView 接线到世界书列表刷新，避免要重启才能看到新世界）
  public var onStoryworldPublished: ((UUID) -> Void)?

  public init(coordinator: FactoryCoordinator, store: FactoryJobStore) {
    self.coordinator = coordinator
    self.store = store
  }

  public var selectedJob: FactoryJob? {
    jobs.first { $0.id == selectedJobID }
  }

  public func tasteForEditing() async -> FactoryTasteSettings? {
    guard !isBusy, let selectedJobID else { return nil }
    do {
      let settings = try await coordinator.tasteSettings(jobID: selectedJobID)
      guard self.selectedJobID == selectedJobID else { return nil }
      return settings
    } catch { errorMessage = error.localizedDescription; return nil }
  }

  public func saveTaste(_ overrides: PlayerTasteOverrides, replacing reviewed: FactoryTasteSettings) async -> String? {
    guard !isBusy, selectedJobID == reviewed.jobID else { return "工坊任务已切换或正在运行，请重新打开偏好设置。" }
    do {
      try await coordinator.updateTasteSettings(reviewed, overrides: overrides)
      await reload()
      return nil
    } catch { return error.localizedDescription }
  }

  public func globalTasteForEditing() async -> PlayerTasteSnapshot? {
    do { return try await coordinator.globalTaste() }
    catch { errorMessage = error.localizedDescription; return nil }
  }

  public func saveGlobalTaste(_ profile: PlayerTasteProfile, replacing previous: PlayerTasteSnapshot) async -> String? {
    do { try await coordinator.saveGlobalTaste(profile, replacing: previous); await reload(); return nil }
    catch { return error.localizedDescription }
  }

  public var coverage: FactoryCoverageSummary? {
    guard let manifest, let analysis else { return nil }
    return FactoryCoverageSummary(manifest: manifest, analysis: analysis)
  }

  public func initialize() async {
    if !didRecover {
      didRecover = true
      do { _ = try await coordinator.recoverInterruptedJobs() } catch {
        errorMessage = error.localizedDescription
      }
    }
    await reload()
  }

  public func prepare(record: NovelLibraryRecord, requestID: UUID) async {
    if preparedRequestID == requestID { return }
    preparedRequestID = requestID
    do {
      let job = try await coordinator.createJob(documentID: record.id)
      selectedJobID = job.id
      await reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public func reload() async {
    do {
      jobs = try await store.list()
      if selectedJobID == nil || !jobs.contains(where: { $0.id == selectedJobID }) {
        selectedJobID = jobs.first?.id
      }
      try await reloadSelection()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public func select(_ jobID: UUID) async {
    pendingRetry = nil
    selectedJobID = jobID
    do { try await reloadSelection() } catch { errorMessage = error.localizedDescription }
  }

  public func start() async {
    guard let selectedJobID else { return }
    await performLongOperation {
      try await self.coordinator.startAnalysis(jobID: selectedJobID)
    }
  }

  public func retry() async {
    guard let selectedJobID else { return }
    if selectedJob?.failure?.category != .publishing,
      await requireRetryConfirmation(jobID: selectedJobID, action: .retry) { return }
    await performLongOperation {
      try await self.coordinator.retry(jobID: selectedJobID)
    }
  }

  public func supplement() async {
    guard let selectedJobID else { return }
    if await requireRetryConfirmation(jobID: selectedJobID, action: .supplement) { return }
    await performLongOperation {
      try await self.coordinator.supplementAnalysis(jobID: selectedJobID)
    }
  }

  private func requireRetryConfirmation(jobID: UUID, action: FactoryPendingRetry.Action) async -> Bool {
    do {
      let kind: FactoryRequestKind = action == .generate
        || (action == .retry && selectedJob?.resumeStage == .generating) ? .bake : .analysis
      let approval = try await store.pendingRequestRetry(jobID, kind: kind)
      guard approval.requestCount > 0 else { return false }
      pendingRetry = .init(approval: approval, action: action)
    } catch { errorMessage = error.localizedDescription }
    return true
  }

  public func confirmRetry(_ request: FactoryPendingRetry) async {
    pendingRetry = nil
    await performLongOperation {
      if request.action == .generate {
        try await self.coordinator.generateCandidate(jobID: request.approval.jobID,
          requestApproval: request.approval)
      } else if request.action == .supplement {
        try await self.coordinator.supplementAnalysis(jobID: request.approval.jobID,
          requestApproval: request.approval)
      } else {
        try await self.coordinator.retry(jobID: request.approval.jobID,
          requestApproval: request.approval)
      }
    }
  }

  public func cancel() async {
    guard let selectedJobID else { return }
    await coordinator.cancel(jobID: selectedJobID)
    await reload()
  }

  public func accept(_ decisionID: UUID) async {
    guard let selectedJobID else { return }
    do {
      try await coordinator.acceptRecommendation(decisionID: decisionID, jobID: selectedJobID)
      await reload()
    } catch { errorMessage = error.localizedDescription }
  }

  public func answer(_ decisionID: UUID, value: String) async {
    guard let selectedJobID else { return }
    do {
      try await coordinator.answerDecision(
        decisionID: decisionID,
        jobID: selectedJobID,
        answer: value
      )
      await reload()
    } catch { errorMessage = error.localizedDescription }
  }

  public func reopen(_ decisionID: UUID) async {
    guard let selectedJobID else { return }
    do {
      try await coordinator.reopenDecision(decisionID: decisionID, jobID: selectedJobID)
      await reload()
    } catch { errorMessage = error.localizedDescription }
  }

  public func acceptAll() async {
    guard let selectedJobID else { return }
    do {
      try await coordinator.acceptAllRecommendations(jobID: selectedJobID)
      await reload()
    } catch { errorMessage = error.localizedDescription }
  }

  public func generate() async {
    guard let selectedJobID else { return }
    if await requireRetryConfirmation(jobID: selectedJobID, action: .generate) { return }
    await performLongOperation {
      try await self.coordinator.generateCandidate(jobID: selectedJobID)
    }
  }

  public func publish() async {
    guard let selectedJobID else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      let record = try await coordinator.publish(jobID: selectedJobID)
      publishedStoryworldID = record.id
      onStoryworldPublished?(record.id)
      await reload()
    } catch {
      errorMessage = error.localizedDescription
      await reload()
    }
  }

  public func clearPublishedStoryworld() {
    publishedStoryworldID = nil
  }

  private var preparedRequestID: UUID?
  /// 运行中轮询时上次已加载重型产物的阶段；阶段不变就只刷新轻量 job.json
  private var lastPolledStage: FactoryStage?

  private func reloadSelection() async throws {
    guard let selectedJobID else {
      decisions = []
      analysis = nil
      manifest = nil
      preview = nil
      validation = nil
      tasteSettings = nil
      return
    }
    decisions = try await store.decisions(selectedJobID)
    analysis = try await store.analysis(selectedJobID)
    manifest = try await store.inputManifest(selectedJobID)
    preview = try await store.preview(selectedJobID)
    validation = try await store.validation(selectedJobID)
    tasteSettings = try await coordinator.tasteSettings(jobID: selectedJobID)
  }

  /// 运行中轮询：每 500ms 只重读轻量的 job.json 列表；analysis/decisions/
  /// manifest/preview/validation 等重型产物仅在阶段变化时重读，
  /// 避免运行期间每 500ms 全量解码一遍。
  private func reloadDuringOperation() async {
    do {
      jobs = try await store.list()
      if selectedJobID == nil || !jobs.contains(where: { $0.id == selectedJobID }) {
        selectedJobID = jobs.first?.id
      }
      let stage = selectedJob?.stage
      if stage != lastPolledStage {
        lastPolledStage = stage
        try await reloadSelection()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performLongOperation(
    _ operation: @escaping @MainActor () async throws -> Void
  ) async {
    isBusy = true
    lastPolledStage = nil
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { break }
        await self?.reloadDuringOperation()
      }
    }
    defer {
      pollTask?.cancel()
      pollTask = nil
      isBusy = false
    }
    do {
      try await operation()
    } catch is CancellationError {
      // Cancellation state is persisted by the coordinator.
    } catch {
      errorMessage = error.localizedDescription
    }
    await reload()
  }
}
