import Combine
import Foundation
import LibraryCore
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore
import WritingAssistantCore
import WritingCore

@MainActor final class AdaptationViewModel: ObservableObject {
  enum Work { case bookcase, anchors, write }
  @Published private(set) var jobs: [AdaptationJob] = []
  @Published private(set) var job: AdaptationJob?
  @Published private(set) var source: NovelDocument?
  @Published private(set) var bookcases: [BookcaseProposal] = []
  @Published var selectedBookcaseID: UUID?
  @Published private(set) var anchors: AdaptationAnchorMap?
  @Published private(set) var drafts: AdaptationDraftSnapshot?
  @Published private(set) var direction: AdaptationContractRevision?
  @Published private(set) var selectedVariantID: UUID? {
    didSet {
      // A completed run summary belongs to the direction that produced it.
      if oldValue != selectedVariantID { progressText = "" }
    }
  }
  @Published private(set) var configuration = AdaptationRunConfiguration()
  @Published private(set) var providers: [ProviderProfile] = []
  @Published private(set) var pending: AdaptationRequestCheckpoint?
  @Published private(set) var busy = false
  @Published private(set) var generating = false
  @Published private(set) var progressText = ""
  @Published private(set) var reportDetails: [String] = []
  @Published var errorMessage: String?
  @Published private(set) var notice: String?
  @Published private(set) var assembly: AdaptationAssembly?
  @Published private(set) var exported: AdaptationExport?
  private let store: AdaptationJobStore
  private let library: NovelLibrary
  private let providerStore: ProviderProfileStore
  private let tasteStore: PlayerTasteStore
  private let providerFactory: (@Sendable (UUID) async throws -> any LLMProvider)?
  private var generationTask: Task<Void, Never>?
  private var selectionEpoch = UUID()

  init(store: AdaptationJobStore = .shared, library: NovelLibrary, providerStore: ProviderProfileStore,
    tasteStore: PlayerTasteStore = .shared, providerFactory: (@Sendable (UUID) async throws -> any LLMProvider)? = nil) {
    self.store = store; self.library = library; self.providerStore = providerStore; self.tasteStore = tasteStore
    self.providerFactory = providerFactory
  }
  var selectedBookcase: BookcaseProposal? { bookcases.first { $0.id == selectedBookcaseID } }
  var sparseChapterIDs: [String] {
    guard let source, let anchors else { return [] }
    return source.chapters.filter { chapter in
      !anchors.anchors.contains { $0.source.chapterID == chapter.id && anchors.reviews[$0.id]?.action != .reject }
    }.map(\.id)
  }
  func reload() async {
    guard !busy else { return }
    do { jobs = try await store.list(); providers = try await providerStore.list() }
    catch { errorMessage = error.localizedDescription }
  }
  func selectJob(_ id: UUID) async {
    guard !busy else { return }
    selectionEpoch = UUID(); let epoch = selectionEpoch
    job = nil; source = nil; anchors = nil; drafts = nil; direction = nil; bookcases = []
    selectedVariantID = nil; selectedBookcaseID = nil; assembly = nil; exported = nil; pending = nil; progressText = ""; errorMessage = nil; notice = nil
    do { try await refresh(id, epoch: epoch) } catch { if selectionEpoch == epoch { errorMessage = error.localizedDescription } }
  }
  func leaveJob() { guard !busy else { return }; selectionEpoch = UUID(); job = nil; source = nil; assembly = nil; exported = nil }
  func refreshCurrent() async {
    guard let id = job?.id else { return }
    _ = await operation { try await refresh(id, epoch: selectionEpoch) }
  }
  func selectVariant(_ id: UUID) async {
    guard !busy, let job, job.variants.contains(where: { $0.id == id }) else { return }
    selectedVariantID = id; assembly = nil; exported = nil; notice = nil
    do { try await refresh(job.id, epoch: selectionEpoch) } catch { errorMessage = error.localizedDescription }
  }
  func importFiles(_ urls: [URL]) async {
    _ = await operation {
      for url in urls {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let value = try await store.create(from: url)
        try await refresh(value.id, epoch: selectionEpoch)
      }
      notice = "已保存独立原文副本，可以继续提取书案或扫描锚点。"
    }
  }
  func createOriginal(title: String, author: String, plan: String) async -> Bool {
    await operation {
      let lines = plan.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      guard !lines.isEmpty, lines.count <= 1_000 else { throw AdaptationError.invalidSource }
      let chapters = lines.enumerated().map { index, line in
        let parts = line.components(separatedBy: "｜")
        return NovelChapter(id: String(format: "chapter-%06d", index + 1), ordinal: index,
          title: parts[0], content: parts.dropFirst().joined(separator: "｜"))
      }
      let created = try await store.createOriginal(title: title, author: author.isEmpty ? nil : author, chapters: chapters)
      var contract = AdaptationDirectionContract(); contract.mode = .original; contract.includeOriginalChapter = false; contract.originalRetentionPercent = 0
      let variant = try await store.createStandaloneVariant(jobID: created.id, title: title, contract: contract, expectedRevision: created.revision)
      selectedVariantID = variant.id
      try await refresh(created.id, epoch: selectionEpoch)
      notice = "原创计划已保存。请先核对方向合同，再选择模型生成。"
    }
  }
  func saveConfiguration(_ value: AdaptationRunConfiguration, jobID: UUID, expected: UUID?) async -> Bool {
    await operation {
      guard job?.id == jobID else { throw AdaptationError.staleEdit }
      configuration = try await store.saveRunConfiguration(value, jobID: jobID, expectedRevision: expected)
      notice = "本任务配置已保存。"
    }
  }
  func saveDirection(title: String, contract: AdaptationDirectionContract, expected: AdaptationContractRevision?,
    bindApprovedBookcase: Bool) async -> Bool {
    await operation {
      guard let job else { throw AdaptationError.staleEdit }
      let variant: AdaptationVariant
      if let expected {
        guard selectedVariantID == expected.variantID else { throw AdaptationError.staleEdit }
        variant = try await store.updateDirection(jobID: job.id, variantID: expected.variantID, expectedContractRevisionID: expected.id,
          contract: contract, bookcaseID: bindApprovedBookcase ? job.approvedBookcaseID : nil)
      } else if bindApprovedBookcase {
        variant = try await store.createVariant(jobID: job.id, title: title, contract: contract, expectedRevision: job.revision)
      } else {
        variant = try await store.createStandaloneVariant(jobID: job.id, title: title, contract: contract, expectedRevision: job.revision)
      }
      selectedVariantID = variant.id; try await refresh(job.id, epoch: selectionEpoch)
    }
  }
  func decideBookcase(_ proposal: BookcaseProposal, action: ApprovalAction, acknowledgeGaps: Bool) async {
    _ = await operation {
      guard let job else { throw AdaptationError.staleEdit }
      _ = try await store.decideBookcase(jobID: job.id, proposalID: proposal.id, expectedRevision: job.revision,
        action: action, acknowledgeMissingChapters: acknowledgeGaps)
      try await refresh(job.id, epoch: selectionEpoch)
    }
  }
  func saveBookcase(_ content: NovelBookcase, parent: BookcaseProposal) async -> Bool {
    await operation {
      guard let job else { throw AdaptationError.staleEdit }
      let changedCharacters = content.characters.filter { card in parent.content.characters.first(where: { $0.id == card.id }) != card }
      let value = try content.applyingManualCharacters(changedCharacters)
      let proposal = try await store.proposeBookcase(value, jobID: job.id, expectedRevision: job.revision, parentID: parent.id, authorRevision: true)
      selectedBookcaseID = proposal.id; try await refresh(job.id, epoch: selectionEpoch)
      notice = "作者修订已保存为新待审书案，旧版本仍可对照。"
    }
  }
  func saveCharacter(_ card: BookcaseCharacter, parent: BookcaseProposal, mergeIDs: Set<String> = []) async -> Bool {
    do {
      let content = try mergeIDs.isEmpty ? parent.content.applyingManualCharacters([card]) : parent.content.mergingCharacters(mergeIDs, replacement: card)
      return await saveBookcase(content, parent: parent)
    } catch { errorMessage = error.localizedDescription; return false }
  }
  func addAnchor(chapterID: String, quote: String, offset: Int?, note: String) async -> Bool {
    await operation {
      guard let job else { throw AdaptationError.staleEdit }
      _ = try await store.addManualAnchor(jobID: job.id, expectedRevision: anchors?.revision,
        candidate: .init(chapterID: chapterID, quote: quote, utf16Location: offset, note: note))
      try await refresh(job.id, epoch: selectionEpoch)
    }
  }
  func reviewAnchor(_ anchor: AdaptationAnchor, expectedRevision: UUID?, note: String, action: ApprovalAction,
    generationAction: AdaptationAnchorAction, intensity: Int) async -> Bool {
    await operation {
      guard let job else { throw AdaptationError.staleEdit }
      var revision = expectedRevision
      if note != anchor.note {
        revision = try await store.editAnchorNote(jobID: job.id, anchorID: anchor.id, expectedRevision: revision, note: note).revision
      }
      _ = try await store.reviewAnchor(jobID: job.id, anchorID: anchor.id, expectedRevision: revision,
        action: action, generationAction: generationAction, intensity: intensity)
      try await refresh(job.id, epoch: selectionEpoch)
    }
  }
  func saveDraft(_ draft: AdaptationDraft, content: AdaptationDraftContent) async -> Bool {
    await operation {
      guard job?.id == draft.context.basis.jobID, selectedVariantID == draft.context.basis.variantID else { throw AdaptationError.staleEdit }
      _ = try await store.reviseDraft(jobID: draft.context.basis.jobID, variantID: draft.context.basis.variantID, draftID: draft.id, content: content)
      try await refresh(draft.context.basis.jobID, epoch: selectionEpoch)
    }
  }
  func decideDraft(_ draft: AdaptationDraft, revision: UUID?, action: ApprovalAction, note: String, acknowledge: Bool) async -> Bool {
    await operation {
      guard job?.id == draft.context.basis.jobID, selectedVariantID == draft.context.basis.variantID else { throw AdaptationError.staleEdit }
      _ = try await store.decideDraft(jobID: draft.context.basis.jobID, variantID: draft.context.basis.variantID, draftID: draft.id,
        expectedRevision: revision, action: action, note: note, acknowledgeWarnings: acknowledge)
      try await refresh(draft.context.basis.jobID, epoch: selectionEpoch)
    }
  }
  func previousDraft(_ draft: AdaptationDraft) async -> AdaptationDraft? {
    guard let parent = draft.parentID else { return nil }
    do { return try await store.draft(jobID: draft.context.basis.jobID, variantID: draft.context.basis.variantID, draftID: parent) }
    catch { errorMessage = error.localizedDescription; return nil }
  }
  func acknowledgeRequest(_ checkpoint: AdaptationRequestCheckpoint) async {
    _ = await operation {
      guard job?.id == checkpoint.jobID else { throw AdaptationError.staleEdit }
      try await store.acknowledgeUnknownRequest(checkpoint, note: "作者在写作台核对后允许继续；知悉可能重复计费。")
      try await refresh(checkpoint.jobID, epoch: selectionEpoch)
    }
  }
  func prepareAssembly() async {
    _ = await operation {
      guard let job, let variantID = selectedVariantID else { throw AdaptationError.staleEdit }
      assembly = try await store.prepareAssembly(jobID: job.id, variantID: variantID, expectedDraftRevision: drafts?.revision)
      exported = nil
    }
  }
  func export(acknowledge: Bool, publish: Bool) async -> Bool {
    await operation {
      guard let assembly else { throw AdaptationError.staleEdit }
      if publish {
        _ = try await library.publishAdaptation(assembly, store: store, acknowledgeUnchangedChapters: acknowledge)
        notice = "已将当前方向加入书架，原书保留。"
      } else { exported = try await store.exportAssembly(assembly, acknowledgeUnchangedChapters: acknowledge) }
    }
  }
  func start(_ work: Work, newRound: Bool = false) {
    guard !busy, let job else { return }
    let jobID = job.id, epoch = selectionEpoch, variantID = selectedVariantID
    var config = configuration
    busy = true; generating = true; errorMessage = nil; notice = nil; assembly = nil; exported = nil; progressText = "准备请求…"
    generationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.busy = false; self.generating = false; self.generationTask = nil }
      do {
        if newRound {
          config = try await store.beginRegeneration(jobID: jobID, expectedConfigurationRevision: configuration.revision)
          configuration = config
        }
        guard let providerID = config.providerID else { throw AdaptationUIError.selectModel }
        let provider: any LLMProvider
        if let providerFactory { provider = try await providerFactory(providerID) }
        else { provider = try await providerStore.makeProvider(profileID: providerID) }
        try Task.checkCancellation()
        let selection = BookcaseExtractionOptions(chapterIDs: config.chapterIDs, focusNames: config.focusNames,
          maximumUnitUTF16Length: config.maximumUnitUTF16Length, maximumNewRequests: config.maximumNewRequests)
        switch work {
        case .bookcase:
          let result = try await BookcaseExtractor(provider: provider, store: store).extract(jobID: jobID, options: selection) { [weak self] report in
            await self?.setProgress("书案 \(report.completedUnitIDs.count)/\(report.totalUnits)；新请求 \(report.newRequestCount)，缓存 \(report.cacheHitCount)，缺口 \(report.gaps.count)", epoch: epoch)
          }
          selectedBookcaseID = result.proposalID
        case .anchors:
          _ = try await AdaptationAnchorScanner(provider: provider, store: store).scan(jobID: jobID,
            options: .init(selection: selection, density: config.density, addChapterStarts: config.addChapterStarts)) { [weak self] report in
            await self?.setProgress("锚点 \(report.completedUnitIDs.count)/\(report.totalUnits)；新增 \(report.addedAnchorCount)，新请求 \(report.newRequestCount)，缺口 \(report.gaps.count)", epoch: epoch)
          }
        case .write:
          guard let variantID, let source else { throw AdaptationError.staleEdit }
          let targets: [AdaptationDraftTarget]
          if config.writeScope == .anchors {
            let map = try await store.anchorMap(jobID)
            targets = map.anchors.filter { map.reviews[$0.id]?.action == .approve && (config.chapterIDs.isEmpty || config.chapterIDs.contains($0.source.chapterID)) }
              .map { .init(chapterID: $0.source.chapterID, anchorID: $0.id) }
            guard !targets.isEmpty else { throw AdaptationError.reviewRequired }
          } else { targets = source.chapters.filter { config.chapterIDs.isEmpty || config.chapterIDs.contains($0.id) }.map { .init(chapterID: $0.id) } }
          let taste = try await tasteStore.load().profile
          _ = try await AdaptationWriter(provider: provider, store: store).write(jobID: jobID, variantID: variantID,
            options: .init(targets: targets, maximumNewRequests: config.maximumNewRequests, focusNames: config.focusNames,
              personalTaste: taste, taskTaste: config.taskTaste, regenerationID: config.regenerationID)) { [weak self] report in
            await self?.setProgress("正文 \(report.completedDraftIDs.count)/\(report.targets.count)；新请求 \(report.newRequestCount)，复用 \(report.reusedDraftCount)，缺口 \(report.gaps.count)", epoch: epoch)
          }
        }
      } catch { if selectionEpoch == epoch { errorMessage = error is CancellationError ? "已取消；完成结果保留，未完成请求请核对。" : error.localizedDescription } }
      do { try await refresh(jobID, epoch: epoch) } catch { errorMessage = error.localizedDescription }
    }
  }
  func cancel() { generationTask?.cancel() }
  private func setProgress(_ value: String, epoch: UUID) { if selectionEpoch == epoch { progressText = value } }
  private func operation(_ action: () async throws -> Void) async -> Bool {
    guard !busy else { return false }
    busy = true; errorMessage = nil; notice = nil; defer { busy = false }
    do { try await action(); return true } catch { errorMessage = error.localizedDescription; return false }
  }
  private func refresh(_ id: UUID, epoch: UUID) async throws {
    let value = try await store.load(id), document = try await store.source(id), cards = try await store.bookcases(id)
    let map = try await store.anchorMap(id), config = try await store.runConfiguration(id), request = try await store.pendingRequest(id)
    let variantID = value.variants.first(where: { $0.id == selectedVariantID })?.id ?? value.variants.first?.id
    var draftState: AdaptationDraftSnapshot?, contract: AdaptationContractRevision?
    if let variant = value.variants.first(where: { $0.id == variantID }) {
      draftState = try await store.drafts(jobID: id, variantID: variant.id)
      contract = try await store.direction(jobID: id, revisionID: variant.contractRevisionID)
    }
    let list = try await store.list()
    let bookcaseReport = try await store.bookcaseExtractionReport(id), anchorReport = try await store.anchorScanReport(id)
    var writingReport: AdaptationWriteReport?
    if let variantID { writingReport = try await store.writeReport(jobID: id, variantID: variantID) }
    guard selectionEpoch == epoch else { return }
    job = value; source = document; bookcases = cards; anchors = map; configuration = config; pending = request
    drafts = draftState; direction = contract; selectedVariantID = variantID; jobs = list
    reportDetails = (bookcaseReport?.gaps.map { "书案 \($0.chapterID)：\($0.reason)" } ?? [])
      + (bookcaseReport?.warnings ?? []) + (anchorReport?.gaps.map { "锚点 \($0.chapterID)：\($0.reason)" } ?? [])
      + (writingReport?.gaps ?? [])
    if !cards.contains(where: { $0.id == selectedBookcaseID }) { selectedBookcaseID = cards.first?.id }
    assembly = nil; exported = nil
  }
}

private enum AdaptationUIError: Error, LocalizedError {
  case selectModel
  var errorDescription: String? { "请在任务配置中选择模型。" }
}
