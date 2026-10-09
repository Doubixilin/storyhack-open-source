import Combine
import Foundation
import LLMProviderKit
import StorySessionCore
import StoryworldCore

public enum StorySessionLifecycleState: Equatable, Sendable {
  case active
  case inactive
  case background
  case memoryPressure
}

struct ArchivedPlaythroughSummary: Identifiable {
  var id: UUID { playthrough.id }
  let playthrough: PlaythroughDescriptor
  let branchCount: Int
  let saveCount: Int
}

struct StoryworldArchiveGroup: Identifiable {
  let id: UUID
  let title: String
  let playthroughs: [ArchivedPlaythroughSummary]
}

@MainActor
public final class StorySessionViewModel: ObservableObject {
  @Published public private(set) var storyworldID: UUID?
  @Published public private(set) var storyworld: StoryworldDocument?
  @Published public private(set) var playthroughs: [PlaythroughDescriptor] = []
  @Published public private(set) var branches: [RuntimeBranchDescriptor] = []
  @Published public private(set) var branchGraph: StoryBranchGraph?
  @Published public private(set) var snapshot: StorySessionSnapshot?
  @Published public private(set) var providerProfiles: [ProviderProfile] = []
  @Published public private(set) var directiveProfiles = DirectiveProfile.builtins
  @Published public var selectedProviderID: UUID?
  @Published public var draft = ""
  @Published public private(set) var streamingNarrative = ""
  @Published public private(set) var pendingUserMessage: String?
  @Published public private(set) var isStreaming = false
  @Published public private(set) var recoveryNotice: String?
  @Published public var errorMessage: String?
  @Published public private(set) var endingReport: StoryEndingReport?
  @Published public private(set) var endingStatistics: EndingReportStatistics?
  @Published public private(set) var endingStatisticLines: [String] = []
  @Published public private(set) var streamingEndingVerdict = ""
  @Published public private(set) var isGeneratingEndingReport = false
  @Published public private(set) var endingReportError: String?
  @Published private(set) var archiveGroups: [StoryworldArchiveGroup] = []
  @Published private(set) var isArchiveCatalogLoading = false

  private struct RetryTurn {
    let id: UUID
    let userMessage: String
    let commitUserMessage: String?
    let showsPendingUserMessage: Bool
  }

  private let storyworldLibrary: StoryworldLibrary
  private let providerStore: ProviderProfileStore
  private let directiveStore: DirectiveProfileStore
  private let tasteStore: PlayerTasteStore
  private var runtime: StoryworldRuntimeStore?
  private var streamTask: Task<Void, Never>?
  private var endingTask: Task<Void, Never>?
  private var retryTurn: RetryTurn?

  public init(
    storyworldLibrary: StoryworldLibrary,
    providerStore: ProviderProfileStore,
    directiveStore: DirectiveProfileStore = .shared,
    tasteStore: PlayerTasteStore = .shared
  ) {
    self.storyworldLibrary = storyworldLibrary
    self.providerStore = providerStore
    self.directiveStore = directiveStore
    self.tasteStore = tasteStore
  }

  public func playerTasteForEditing() async -> PlayerTasteSnapshot? {
    do { return try await tasteStore.load() }
    catch { errorMessage = error.localizedDescription; return nil }
  }

  public func savePlayerTaste(_ profile: PlayerTasteProfile, replacing previous: PlayerTasteSnapshot) async -> String? {
    do { try await tasteStore.save(profile, replacing: previous); return nil }
    catch { return error.localizedDescription }
  }

  public func reloadDirectiveProfiles() async {
    do { directiveProfiles = try await directiveStore.list() }
    catch { errorMessage = error.localizedDescription }
  }

  public func applyDirectiveProfile(_ profile: DirectiveProfile, address: SessionAddress,
    revision: UUID?) async -> String? {
    guard !isStreaming, let runtime, snapshot?.context.address == address else {
      return "生成进行中或游玩线已切换，请重新选择档案。"
    }
    do {
      try await runtime.setDirectiveProfile(profile, address: address, expectedRevision: revision)
      let updated = try await runtime.load(address: address)
      if snapshot?.context.address == address { snapshot = updated; retryTurn = nil }
      playthroughs = try await runtime.listPlaythroughs()
      return nil
    } catch {
      let updated = try? await runtime.load(address: address)
      if snapshot?.context.address == address, let updated { snapshot = updated }
      return error.localizedDescription
    }
  }

  public func saveDirectiveProfile(_ profile: DirectiveProfile, replacing previous: DirectiveProfile?) async -> String? {
    do {
      try await directiveStore.save(profile, replacing: previous)
      directiveProfiles = try await directiveStore.list()
      return nil
    } catch { return error.localizedDescription }
  }

  public func deleteDirectiveProfile(_ profile: DirectiveProfile) async -> String? {
    do {
      try await directiveStore.delete(profile)
      directiveProfiles = try await directiveStore.list()
      return nil
    } catch { return error.localizedDescription }
  }

  public var canRetry: Bool { retryTurn != nil && !isStreaming }

  public func proposeCalibration(_ draft: ContinuityCalibrationDraft, id: UUID,
    reviewed: StorySessionSnapshot) async -> String? {
    let address = reviewed.context.address
    guard let runtime, snapshot?.context.address == address, let base = reviewed.continuity else {
      return "分支已切换或连续性记录不可用，请刷新后重试。"
    }
    do {
      try await runtime.proposeContinuityCalibration(address: address, id: id, draft: draft,
        expectedEventSequence: reviewed.state.lastEventSequence,
        expectedStateHash: reviewed.state.stateHash, expectedContinuityHash: base.hash)
      let updated = try await runtime.load(address: address)
      if snapshot?.context.address == address { snapshot = updated }
      return nil
    } catch { return error.localizedDescription }
  }

  public func decideCalibration(id: UUID, decision: ContinuityCalibrationDecision,
    address: SessionAddress) async -> String? {
    guard let runtime, snapshot?.context.address == address else { return "分支已切换，请刷新后重试。" }
    do {
      try await runtime.decideContinuityCalibration(address: address, id: id, decision: decision)
      let updated = try await runtime.load(address: address)
      if snapshot?.context.address == address { snapshot = updated }
      return nil
    } catch {
      let updated = try? await runtime.load(address: address)
      if snapshot?.context.address == address, let updated { snapshot = updated }
      return error.localizedDescription
    }
  }

  public func saveAnchor(_ anchor: StoryAnchor, address: SessionAddress, revision: UUID?) async -> String? {
    guard let runtime, snapshot?.context.address == address else { return "游玩线或分支已切换，请重新选择回合。" }
    do {
      try await runtime.saveAnchor(anchor, address: address, expectedRevision: revision)
      let updated = try await runtime.load(address: address)
      if snapshot?.context.address == address { snapshot = updated }
      return nil
    } catch {
      let updated = try? await runtime.load(address: address)
      if snapshot?.context.address == address, let updated { snapshot = updated }
      return error.localizedDescription
    }
  }

  public func removeAnchor(id: UUID, address: SessionAddress, revision: UUID?) async -> String? {
    guard let runtime, snapshot?.context.address == address else { return "游玩线或分支已切换，请重新选择锚点。" }
    do {
      try await runtime.removeAnchor(id: id, address: address, expectedRevision: revision)
      let updated = try await runtime.load(address: address)
      if snapshot?.context.address == address { snapshot = updated }
      return nil
    } catch {
      let updated = try? await runtime.load(address: address)
      if snapshot?.context.address == address, let updated { snapshot = updated }
      return error.localizedDescription
    }
  }

  public func refreshCanonStatus() async {
    guard let runtime, let address = snapshot?.context.address else { return }
    do {
      let document = try await storyworldLibrary.load(storyworldID: address.storyworldID)
      let updated = try await runtime.load(address: address)
      guard snapshot?.context.address == address else { return }
      storyworld = document
      snapshot = updated
    } catch {
      if snapshot?.context.address == address { errorMessage = error.localizedDescription }
    }
  }

  public func confirmCanonBinding(_ reviewed: CanonBindingStatus) async {
    guard !isStreaming, let runtime, let address = snapshot?.context.address,
      let fingerprints = reviewed.current, reviewed.canRebind else { return }
    guard reviewed.address == address else {
      errorMessage = "当前游玩线已切换，请重新查看设定绑定提示。"
      return
    }
    do {
      try await runtime.confirmCanonBinding(address: address, expectedCurrent: fingerprints,
        expectedBindingID: reviewed.bindingID)
      retryTurn = nil
      pendingUserMessage = nil
      await refreshCanonStatus()
      try await reloadRuntimeLists()
    } catch {
      await refreshCanonStatus()
      errorMessage = error.localizedDescription
    }
  }

  public func setHistoryWindow(_ count: Int) async {
    guard !isStreaming, let runtime, let address = snapshot?.context.address else { return }
    do {
      try await runtime.setHistoryWindow(count, address: address)
      let updated = try await runtime.load(address: address)
      guard snapshot?.context.address == address else { return }
      snapshot = updated
      playthroughs = try await runtime.listPlaythroughs()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public var endingReadiness: EndingReadiness {
    EndingReadiness(effectiveTurnCount: snapshot?.effectiveTurns.count ?? 0)
  }

  public var currentPlayMode: StoryPlayMode? {
    snapshot.flatMap { StoryPlayMode.infer(from: $0.context.branch) }
  }

  public var currentBranchDisplayTitle: String {
    currentPlayMode?.displayName ?? snapshot?.context.branch.branch.title ?? "分支"
  }

  public var latestChoices: [String] {
    snapshot?.effectiveTurns.last?.choices ?? []
  }

  public func closeSessionView() {
    cancelStreaming()
    cancelEndingReportGeneration()
    pendingUserMessage = nil
    snapshot = nil
    branchGraph = nil
    recoveryNotice = nil
    clearEndingPresentation()
  }

  public func prepare(storyworldID: UUID) async {
    if self.storyworldID == storyworldID, runtime != nil {
      await reloadProviders()
      await refreshCanonStatus()
      return
    }
    streamTask?.cancel()
    self.storyworldID = storyworldID
    pendingUserMessage = nil
    snapshot = nil
    branches = []
    recoveryNotice = nil
    do {
      let packageURL = try await storyworldLibrary.managedPackageURL(
        storyworldID: storyworldID
      )
      storyworld = try await storyworldLibrary.load(storyworldID: storyworldID)
      let runtime = await StoryworldRuntimeStoreRegistry.shared.store(
        forPackageURL: packageURL
      )
      self.runtime = runtime
      playthroughs = try await runtime.listPlaythroughs()
      if let latest = playthroughs.first {
        snapshot = try await runtime.loadActive(playthroughID: latest.id)
        branches = try await runtime.listBranches(playthroughID: latest.id)
        branchGraph = try await runtime.loadBranchGraph(playthroughID: latest.id)
      } else {
        branchGraph = nil
      }
      await reloadProviders()
    } catch {
      errorMessage = "读取游玩记录失败：\(error.localizedDescription)"
    }
  }

  public func openOrCreatePlaythrough() async {
    guard let runtime else { return }
    do {
      var isNewPlaythrough = false
      if let latest = playthroughs.first {
        snapshot = try await runtime.loadActive(playthroughID: latest.id)
      } else {
        let context = try await runtime.createPlaythrough(title: "第一次游玩")
        snapshot = try await runtime.load(address: context.address)
        isNewPlaythrough = true
      }
      try await reloadRuntimeLists()
      if isNewPlaythrough { requestOpening() }
    } catch {
      errorMessage = "无法开始游玩：\(error.localizedDescription)"
    }
  }

  public func createPlaythrough(title: String, directiveProfile: DirectiveProfile = .green) async {
    guard let runtime else { return }
    do {
      let context = try await runtime.createPlaythrough(title: title, directiveProfile: directiveProfile)
      snapshot = try await runtime.load(address: context.address)
      try await reloadRuntimeLists()
      await refreshCanonStatus()
      requestOpening()
    } catch {
      errorMessage = "新建游玩线失败：\(error.localizedDescription)"
    }
  }

  /// 反馈 #3：首次进入世界（或新开游玩线）时主动生成开场白，
  /// 不让玩家面对空白界面。没有可用模型时静默跳过，玩家可直接发言。
  public func requestOpening() {
    guard !isStreaming,
      snapshot?.canonStatus?.requiresConfirmation != true,
      snapshot?.effectiveTurns.isEmpty == true,
      selectedProviderID != nil
    else { return }
    let retry = RetryTurn(
      id: UUID(),
      userMessage: StoryTurnEngine.openingPrompt(plotline: storyworld?.plotline),
      commitUserMessage: nil,
      showsPendingUserMessage: false
    )
    retryTurn = retry
    startStreaming(retry, isCorrectionRetry: false)
  }

  public func openPlaythrough(_ playthroughID: UUID) async {
    guard let runtime else { return }
    do {
      snapshot = try await runtime.loadActive(playthroughID: playthroughID)
      await refreshCanonStatus()
      try await reloadRuntimeLists()
    } catch {
      errorMessage = "续玩失败：\(error.localizedDescription)"
    }
  }

  /// “存档与分支”页的跨世界书索引。只读取本地运行时元数据与分支图，
  /// 不创建会话、不切换当前选择，也不修改任何包。
  func reloadArchiveCatalog() async {
    guard !isArchiveCatalogLoading else { return }
    isArchiveCatalogLoading = true
    defer { isArchiveCatalogLoading = false }
    do {
      let records = try await storyworldLibrary.list()
      var groups: [StoryworldArchiveGroup] = []
      for record in records {
        do {
          let packageURL = try await storyworldLibrary.managedPackageURL(
            storyworldID: record.id
          )
          let runtime = await StoryworldRuntimeStoreRegistry.shared.store(
            forPackageURL: packageURL
          )
          let playthroughs = try await runtime.listPlaythroughs()
          var summaries: [ArchivedPlaythroughSummary] = []
          for playthrough in playthroughs {
            let graph = try await runtime.loadBranchGraph(playthroughID: playthrough.id)
            let saveCount = graph.nodes.reduce(0) { $0 + $1.saves.count }
            summaries.append(
              ArchivedPlaythroughSummary(
                playthrough: playthrough,
                branchCount: graph.nodes.count,
                saveCount: saveCount
              )
            )
          }
          if !summaries.isEmpty {
            groups.append(
              StoryworldArchiveGroup(
                id: record.id,
                title: record.manifest.title,
                playthroughs: summaries
              )
            )
          }
        } catch {
          // 单个包损坏不能拖垮其它世界书的存档索引；详情页打开时会给出具体错误。
          continue
        }
      }
      archiveGroups = groups.sorted {
        $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
    } catch {
      errorMessage = "读取存档索引失败：\(error.localizedDescription)"
    }
  }

  func openArchive(storyworldID: UUID, playthroughID: UUID) async {
    await prepare(storyworldID: storyworldID)
    await openPlaythrough(playthroughID)
  }

  public func sendDraft() {
    let userMessage = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !userMessage.isEmpty else { return }
    draft = ""
    let retry = RetryTurn(
      id: UUID(),
      userMessage: userMessage,
      commitUserMessage: nil,
      showsPendingUserMessage: true
    )
    retryTurn = retry
    startStreaming(retry, isCorrectionRetry: false)
  }

  public func retryLastTurn() {
    guard let retryTurn else { return }
    startStreaming(retryTurn, isCorrectionRetry: true)
  }

  public func sendShortcut(_ text: String) {
    guard !isStreaming else { return }
    draft = text
    sendDraft()
  }

  public func sendDirective(_ name: String, prompt: String) {
    guard !isStreaming else { return }
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    let retry = RetryTurn(
      id: UUID(),
      userMessage: prompt,
      commitUserMessage: "（系统指令：导演·\(name)）",
      showsPendingUserMessage: false
    )
    retryTurn = retry
    startStreaming(retry, isCorrectionRetry: false)
  }

  public func cancelStreaming() {
    streamTask?.cancel()
    streamTask = nil
    isStreaming = false
    streamingNarrative = ""
  }

  public func openEndingReport(regenerate: Bool = false) {
    guard !isGeneratingEndingReport,
      let runtime,
      let snapshot,
      let storyworld,
      let branchGraph
    else { return }

    endingReportError = nil
    endingReport = nil
    endingStatistics = nil
    endingStatisticLines = []
    streamingEndingVerdict = ""
    isGeneratingEndingReport = true
    let selectedProviderID = selectedProviderID
    let providerStore = providerStore
    endingTask = Task { [weak self] in
      guard let self else { return }
      do {
        if !regenerate,
          let existing = try await runtime.loadEndingReport(address: snapshot.context.address)
        {
          endingReport = existing
          endingStatistics = existing.statistics
          endingStatisticLines = existing.statisticLines
          isGeneratingEndingReport = false
          endingTask = nil
          return
        }
        let provider: (any LLMProvider)?
        if let selectedProviderID {
          provider = try await providerStore.makeProvider(profileID: selectedProviderID)
        } else {
          provider = nil
        }
        for try await event in EndingReportWorkflow().open(
          provider: provider,
          runtime: runtime,
          storyworld: storyworld,
          snapshot: snapshot,
          branchGraph: branchGraph,
          regenerate: regenerate
        ) {
          try Task.checkCancellation()
          switch event {
          case .statistics(let statistics, let lines):
            endingStatistics = statistics
            endingStatisticLines = lines
          case .resetVerdict:
            streamingEndingVerdict = ""
          case .textDelta(let delta):
            streamingEndingVerdict += delta
          case .completed(let report, _):
            endingReport = report
            endingStatistics = report.statistics
            endingStatisticLines = report.statisticLines
            streamingEndingVerdict = ""
          }
        }
        isGeneratingEndingReport = false
        endingTask = nil
      } catch is CancellationError {
        isGeneratingEndingReport = false
        streamingEndingVerdict = ""
        endingTask = nil
      } catch {
        isGeneratingEndingReport = false
        streamingEndingVerdict = ""
        endingReportError = ProviderErrorMessage.message(for: error)
        endingTask = nil
      }
    }
  }

  public func cancelEndingReportGeneration() {
    endingTask?.cancel()
    endingTask = nil
    isGeneratingEndingReport = false
    streamingEndingVerdict = ""
  }

  public func clearEndingPresentation() {
    endingReport = nil
    endingStatistics = nil
    endingStatisticLines = []
    streamingEndingVerdict = ""
    endingReportError = nil
  }

  public func handleLifecycle(_ state: StorySessionLifecycleState) async {
    switch state {
    case .inactive:
      return
    case .background, .memoryPressure:
      let interrupted = isStreaming
      cancelStreaming()
      if interrupted {
        recoveryNotice = state == .background
          ? "应用进入后台，本轮没有提交；返回后可原样重试。"
          : "系统内存紧张，本轮没有提交；内容已保留，可原样重试。"
      }
    case .active:
      await reloadProviders()
      guard let runtime, let address = snapshot?.context.address else { return }
      do {
        snapshot = try await runtime.load(address: address)
        try await reloadRuntimeLists()
      } catch {
        errorMessage = "恢复会话失败：\(error.localizedDescription)"
      }
    }
  }

  public func createSave(title: String) async {
    guard let runtime, let address = snapshot?.context.address else { return }
    do {
      let save = try await runtime.createSave(address: address, title: title)
      snapshot = try await runtime.load(address: address)
      recoveryNotice = "已保存“\(save.title)”。"
        + (canonDeviationHint().map { " \($0)" } ?? "")
    } catch {
      errorMessage = "创建存档失败：\(error.localizedDescription)"
    }
  }

  /// 存档后的轻提示：已有节拍记录、但当前位置不在任何原著节拍上时，
  /// 视为与原著走向不同。还没进入过主线（一个节拍都没到过）不提示。
  private func canonDeviationHint(upTo sequence: Int? = nil) -> String? {
    guard let timeline = storyworld?.timeline, !timeline.beats.isEmpty,
      let snapshot
    else { return nil }
    let turns = sequence.map { upto in snapshot.turns.filter { $0.sequence <= upto } }
      ?? snapshot.turns
    guard turns.contains(where: { $0.beatID != nil }), turns.last?.beatID == nil
    else { return nil }
    return "此处与原著走向不同。"
  }

  /// 当前原著主线节点（正史剧情锚）；世界书没有 plotline 时为 nil
  public var currentPlotNodeTitle: String? {
    guard let plotline = storyworld?.plotline, !plotline.nodes.isEmpty, let snapshot
    else { return nil }
    let order = StoryTurnEngine.currentPlotOrder(state: snapshot.state.values)
    guard let node = plotline.node(order: order) else { return nil }
    return "剧情 \(node.order)/\(plotline.nodes.count) · \(node.title)"
  }

  public func createQuickSave() async {
    await createSave(title: "手动存档 \(Date().formatted(date: .abbreviated, time: .shortened))")
  }

  public func activatePlayMode(_ mode: StoryPlayMode) async {
    guard let runtime, let snapshot else { return }
    do {
      if let existing = branches.first(where: mode.matches) {
        let context = try await runtime.activateBranch(
          playthroughID: snapshot.context.playthrough.id,
          branchID: existing.id
        )
        self.snapshot = try await runtime.load(address: context.address)
      } else {
        guard mode != .canon else {
          throw StoryworldRuntimeError.branchNotFound(snapshot.context.branch.id)
        }
        let context = try await runtime.forkBranch(
          address: snapshot.context.address,
          title: mode.branchTitle
        )
        self.snapshot = try await runtime.load(address: context.address)
      }
      recoveryNotice = "已切换到\(mode.displayName)。各模式拥有独立后续记录，不会自动合并。"
      try await reloadRuntimeLists()
    } catch {
      errorMessage = "切换\(mode.displayName)失败：\(error.localizedDescription)"
    }
  }

  public func forkCurrentBranch(title: String) async {
    guard let runtime, let address = snapshot?.context.address else { return }
    do {
      let context = try await runtime.forkBranch(address: address, title: title)
      snapshot = try await runtime.load(address: context.address)
      try await reloadRuntimeLists()
    } catch {
      errorMessage = "创建分支失败：\(error.localizedDescription)"
    }
  }

  public func restoreSave(_ saveID: UUID, title: String) async {
    guard let runtime, let address = snapshot?.context.address else { return }
    do {
      let context = try await runtime.restoreSaveAsNewBranch(
        address: address,
        saveID: saveID,
        title: title
      )
      snapshot = try await runtime.load(address: context.address)
      try await reloadRuntimeLists()
    } catch {
      errorMessage = "从存档建立分支失败：\(error.localizedDescription)"
    }
  }

  /// 分支图入口：存档可能属于任意分支，直接用存档自带的地址恢复。
  public func restoreSaveFromGraph(_ save: StorySave) async {
    guard let runtime else { return }
    do {
      let context = try await runtime.restoreSaveAsNewBranch(
        address: save.address,
        saveID: save.id,
        title: "从 \(save.title) 继续"
      )
      snapshot = try await runtime.load(address: context.address)
      recoveryNotice = "已从「\(save.title)」切出新分支。"
      try await reloadRuntimeLists()
    } catch {
      errorMessage = "从存档建立分支失败：\(error.localizedDescription)"
    }
  }

  /// 供分支图页面在出现时主动刷新。
  public func refreshBranchGraph() async {
    guard let runtime, let playthroughID = snapshot?.context.playthrough.id else { return }
    do {
      branchGraph = try await runtime.loadBranchGraph(playthroughID: playthroughID)
    } catch {
      errorMessage = "读取分支图失败：\(error.localizedDescription)"
    }
  }

  /// 分支图操作卡：从任意历史事件切出新分支。
  public func forkBranchAtEvent(
    node: StoryBranchGraph.Node,
    sequence: Int,
    title: String
  ) async {
    guard let runtime, let address = graphAddress(for: node) else { return }
    do {
      let context = try await runtime.forkBranch(
        address: address,
        atEventSequence: sequence,
        title: title
      )
      snapshot = try await runtime.load(address: context.address)
      recoveryNotice = "已从事件 \(sequence) 切出「\(title)」。"
      try await reloadRuntimeLists()
    } catch {
      errorMessage = "从事件分叉失败：\(error.localizedDescription)"
    }
  }

  /// 分支图操作卡：把任意历史事件的状态存为存档。
  public func createSaveAtEvent(
    node: StoryBranchGraph.Node,
    sequence: Int,
    title: String
  ) async {
    guard let runtime, let address = graphAddress(for: node) else { return }
    do {
      let save = try await runtime.createSave(
        address: address,
        atEventSequence: sequence,
        title: title
      )
      let hint = node.id == snapshot?.context.branch.id
        ? canonDeviationHint(upTo: sequence)
        : nil
      recoveryNotice = "已在事件 \(sequence) 保存「\(save.title)」。"
        + (hint.map { " \($0)" } ?? "")
      try await reloadRuntimeLists()
    } catch {
      errorMessage = "创建存档失败：\(error.localizedDescription)"
    }
  }

  private func graphAddress(for node: StoryBranchGraph.Node) -> SessionAddress? {
    guard let storyworldID = snapshot?.context.address.storyworldID,
      let playthroughID = branchGraph?.playthroughID ?? snapshot?.context.playthrough.id
    else { return nil }
    return SessionAddress(
      storyworldID: storyworldID,
      playthroughID: playthroughID,
      branchID: node.id,
      sessionID: node.sessionID
    )
  }

  public func activateBranch(_ branchID: UUID) async {
    guard let runtime, let playthroughID = snapshot?.context.playthrough.id else { return }
    do {
      let context = try await runtime.activateBranch(
        playthroughID: playthroughID,
        branchID: branchID
      )
      snapshot = try await runtime.load(address: context.address)
      try await reloadRuntimeLists()
    } catch {
      errorMessage = "切换分支失败：\(error.localizedDescription)"
    }
  }

  /// 反馈 #2：删除整条游玩线（含分支、事件与存档）。删除当前打开的线时回到概览。
  public func deletePlaythrough(_ playthroughID: UUID) async {
    guard let runtime else { return }
    do {
      try await runtime.deletePlaythrough(playthroughID: playthroughID)
      if snapshot?.context.playthrough.id == playthroughID {
        closeSessionView()
      }
      playthroughs = try await runtime.listPlaythroughs()
      if snapshot != nil {
        try await reloadRuntimeLists()
      }
    } catch {
      errorMessage = "删除游玩线失败：\(error.localizedDescription)"
    }
  }

  public func reloadProviders() async {
    do {
      providerProfiles = try await providerStore.list()
      if selectedProviderID == nil
        || !providerProfiles.contains(where: { $0.id == selectedProviderID })
      {
        selectedProviderID = providerProfiles.first?.id
      }
    } catch {
      errorMessage = "读取模型配置失败：\(error.localizedDescription)"
    }
  }

  private func startStreaming(_ retry: RetryTurn, isCorrectionRetry: Bool) {
    guard !isStreaming else { return }
    guard snapshot?.canonStatus?.requiresConfirmation != true else {
      if retry.showsPendingUserMessage { draft = retry.userMessage }
      errorMessage = snapshot?.canonStatus?.notice
      return
    }
    guard let selectedProviderID else {
      draft = retry.userMessage
      errorMessage = "请先在“模型设置”中添加并选择模型。"
      return
    }
    guard let snapshot, let storyworld else {
      draft = retry.userMessage
      errorMessage = "请先开始或继续一条游玩线。"
      return
    }

    isStreaming = true
    streamingNarrative = ""
    if retry.showsPendingUserMessage {
      pendingUserMessage = retry.userMessage
    }
    recoveryNotice = nil
    streamTask = Task { [weak self] in
      guard let self else { return }
      do {
        let provider = try await providerStore.makeProvider(profileID: selectedProviderID)
        guard let runtime else { return }
        var result: StoryTurnResult?
        for try await event in StoryTurnEngine(tasteStore: tasteStore).runTurn(
          provider: provider,
          runtime: runtime,
          storyworld: storyworld,
          snapshot: snapshot,
          userMessage: retry.userMessage,
          commitUserMessage: retry.commitUserMessage,
          turnID: retry.id,
          isCorrectionRetry: isCorrectionRetry
        ) {
          try Task.checkCancellation()
          switch event {
          case .narrative(let visibleNarrative):
            streamingNarrative = visibleNarrative
          case .completed(let completed):
            result = completed
          }
        }
        if let result {
          self.snapshot = result.snapshot
          pendingUserMessage = nil
          recoveryNotice = result.warnings.isEmpty
            ? nil
            : result.warnings.joined(separator: " ")
          retryTurn = nil
        }
        streamingNarrative = ""
        isStreaming = false
        streamTask = nil
        try await reloadRuntimeLists()
      } catch is CancellationError {
        isStreaming = false
        streamingNarrative = ""
        streamTask = nil
      } catch let error as CanonBindingError {
        isStreaming = false
        streamingNarrative = ""
        streamTask = nil
        if retry.showsPendingUserMessage { draft = retry.userMessage }
        pendingUserMessage = nil
        retryTurn = nil
        await refreshCanonStatus()
        errorMessage = error.localizedDescription
      } catch let error as StoryworldRuntimeError {
        isStreaming = false
        streamingNarrative = ""
        streamTask = nil
        if case .staleTurnBase = error {
          if retry.showsPendingUserMessage {
            draft = retry.userMessage
          }
          pendingUserMessage = nil
          retryTurn = nil
          errorMessage = "剧情已在另一端更新，请刷新后重试"
        } else {
          errorMessage = "本轮没有提交：\(ProviderErrorMessage.message(for: error))"
        }
      } catch {
        isStreaming = false
        streamingNarrative = ""
        streamTask = nil
        errorMessage = "本轮没有提交：\(ProviderErrorMessage.message(for: error))"
      }
    }
  }

  private func reloadRuntimeLists() async throws {
    guard let runtime, let playthroughID = snapshot?.context.playthrough.id else { return }
    playthroughs = try await runtime.listPlaythroughs()
    branches = try await runtime.listBranches(playthroughID: playthroughID)
    branchGraph = try await runtime.loadBranchGraph(playthroughID: playthroughID)
  }
}
