import Combine
import Foundation
import LibraryCore
import LLMProviderKit
import WritingAssistantCore
import WritingCore

@MainActor
public final class WritingViewModel: ObservableObject {
  @Published private(set) var projects: [WritingProjectSummary] = []
  @Published var selectedProjectID: UUID?
  @Published private(set) var snapshot: WritingProjectSnapshot?
  @Published var isWorking = false
  @Published var errorMessage: String?
  @Published var notice: String?

  @Published public private(set) var suggestionText = ""
  @Published public private(set) var isSuggesting = false
  @Published public private(set) var suggestionKind: WritingSuggestionKind?

  @Published var theme = ""
  @Published var charactersJSON = "[]"
  @Published var world = ""
  @Published var timelineJSON = "[]"
  @Published var outline = ""
  @Published var chapterID = "chapter-001"
  @Published var chapterTitle = "第一章"
  @Published var chapterIntent = ""
  @Published var draft = ""
  @Published var review = ""
  @Published var revision = ""
  @Published var storyStateJSON = "{}"
  @Published var foreshadowingJSON = "[]"

  private let projectLibrary: WritingProjectLibrary
  private let novelLibrary: NovelLibrary
  private let providerStore: ProviderProfileStore
  private var harness: WritingHarness?
  private var suggestionTask: Task<Void, Never>?

  init(
    projectLibrary: WritingProjectLibrary = WritingProjectLibrary(),
    novelLibrary: NovelLibrary,
    providerStore: ProviderProfileStore
  ) {
    self.projectLibrary = projectLibrary
    self.novelLibrary = novelLibrary
    self.providerStore = providerStore
  }

  func reload() async {
    resetSuggestion()
    do {
      projects = try await projectLibrary.list()
      if selectedProjectID == nil { selectedProjectID = projects.first?.id }
      if let selectedProjectID { await select(selectedProjectID) }
    } catch {
      errorMessage = "读取写作项目失败：\(error.localizedDescription)"
    }
  }

  func create(title: String, author: String) async {
    await perform {
      let project = try await projectLibrary.create(
        title: title,
        author: author.isEmpty ? nil : author
      )
      selectedProjectID = project.id
      try await refreshProjects()
      await select(project.id)
      notice = "已创建本地 .novelproject。"
    }
  }

  func select(_ id: UUID) async {
    resetSuggestion()
    guard let project = projects.first(where: { $0.id == id }) else { return }
    selectedProjectID = id
    let harness = WritingHarness(packageURL: project.packageURL)
    self.harness = harness
    do {
      let value = try await harness.load()
      snapshot = value
      hydrate(from: value)
    } catch {
      errorMessage = "打开写作项目失败：\(error.localizedDescription)"
    }
  }

  public func suggest(_ kind: WritingSuggestionKind) async {
    guard !isSuggesting else { return }
    guard harness != nil, let snapshot else { return }

    isSuggesting = true
    errorMessage = nil
    suggestionText = ""
    suggestionKind = kind
    let currentDraft = kind == .theme ? theme : outline

    let task = Task { [weak self, providerStore] in
      guard let self else { return }
      defer {
        self.isSuggesting = false
        self.suggestionTask = nil
      }

      do {
        let profiles = (try? await providerStore.list()) ?? []
        try Task.checkCancellation()
        guard let profile = profiles.first else {
          self.errorMessage = "请先在「模型设置」中添加模型。"
          return
        }
        let provider = try await providerStore.makeProvider(profileID: profile.id)
        try Task.checkCancellation()
        let advisor = WritingAdvisor(provider: provider)
        for try await delta in advisor.streamSuggestion(
          kind: kind,
          snapshot: snapshot,
          currentDraft: currentDraft
        ) {
          try Task.checkCancellation()
          self.suggestionText += delta
        }
      } catch is CancellationError {
        // 用户取消建议时保留已收到的文本，不显示错误。
      } catch {
        self.errorMessage = ProviderErrorMessage.message(for: error)
      }
    }
    suggestionTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func cancelSuggestion() {
    suggestionTask?.cancel()
  }

  public func applySuggestion() {
    guard !suggestionText.isEmpty, let suggestionKind else { return }
    switch suggestionKind {
    case .theme:
      theme = suggestionText
    case .outline:
      outline = suggestionText
    }
    suggestionText = ""
    self.suggestionKind = nil
  }

  func approveTheme() async {
    await perform {
      guard let harness else { return }
      let proposal = try await harness.proposeTheme(theme)
      _ = try await harness.approveTheme(proposalID: proposal.id)
      try await refreshSnapshot()
      notice = "主题候选已批准。"
    }
  }

  func saveBible() async {
    await perform {
      guard let harness else { return }
      try await harness.saveBible(
        charactersJSON: charactersJSON,
        world: world,
        timelineJSON: timelineJSON
      )
      try await refreshSnapshot()
      notice = "人物与世界基础已保存。"
    }
  }

  func freezeOutline() async {
    await perform {
      guard let harness else { return }
      let proposal = try await harness.proposeOutline(outline)
      _ = try await harness.approveAndFreezeOutline(proposalID: proposal.id)
      try await refreshSnapshot()
      notice = "大纲已冻结，正式写章门禁已打开。"
    }
  }

  func submitDraft() async {
    await perform {
      guard let harness else { return }
      let proposal = try await harness.proposeChapterDraft(
        chapterID: chapterID,
        ordinal: inferredOrdinal,
        title: chapterTitle,
        intent: chapterIntent,
        content: draft
      )
      _ = try await harness.approveDraftForReview(proposalID: proposal.id)
      try await refreshSnapshot()
      notice = "草稿已批准进入审稿。"
    }
  }

  func submitReview() async {
    await perform {
      guard let harness else { return }
      _ = try await harness.submitReview(chapterID: chapterID, report: review)
      try await refreshSnapshot()
      notice = "审稿意见已确认，请提交修订稿。"
    }
  }

  func approveFinal() async {
    await perform {
      guard let harness else { return }
      let proposal = try await harness.proposeRevision(
        chapterID: chapterID,
        ordinal: inferredOrdinal,
        title: chapterTitle,
        content: revision
      )
      _ = try await harness.approveFinal(
        proposalID: proposal.id,
        storyStateJSON: storyStateJSON,
        foreshadowingJSON: foreshadowingJSON
      )
      try await refreshSnapshot()
      notice = "本章已批准定稿。"
    }
  }

  func publish() async -> Bool {
    var published = false
    await perform {
      guard let harness else { return }
      let publication = try await harness.publish()
      do {
        _ = try await novelLibrary.publish(snapshot: publication)
      } catch {
        errorMessage = "发布快照已生成，书架发布失败，请直接重试（不会重复生成新版本）：\(error.localizedDescription)"
        return
      }
      try await refreshSnapshot()
      try await refreshProjects()
      notice = "已原子发布到正式书架，旧版本保留在恢复副本中。"
      published = true
    }
    return published
  }

  private var inferredOrdinal: Int {
    if let existing = snapshot?.finalChapters.first(where: { $0.chapterID == chapterID }) {
      return existing.ordinal
    }
    return snapshot?.finalChapters.count ?? 0
  }

  private func refreshProjects() async throws {
    projects = try await projectLibrary.list()
  }

  private func refreshSnapshot() async throws {
    guard let harness else { return }
    let value = try await harness.load()
    snapshot = value
    hydrate(from: value)
  }

  private func hydrate(from value: WritingProjectSnapshot) {
    theme = value.theme
    charactersJSON = value.charactersJSON
    world = value.world
    timelineJSON = value.timelineJSON
    outline = value.activeOutline?.content ?? outline
    storyStateJSON = value.storyStateJSON
    foreshadowingJSON = value.foreshadowingJSON
    if let current = value.manifest.currentChapterID { chapterID = current }
    let chapterProposals = value.proposals.filter { $0.chapterID == chapterID }
    if let latestDraft = chapterProposals.last(where: { $0.kind == .chapterDraft }) {
      chapterTitle = latestDraft.chapterTitle ?? chapterTitle
      draft = latestDraft.content
    }
    if let latestReview = chapterProposals.last(where: { $0.kind == .review }) {
      review = latestReview.content
    }
    if let latestRevision = chapterProposals.last(where: { $0.kind == .revision }) {
      revision = latestRevision.content
    } else if let final = value.finalChapters.first(where: { $0.chapterID == chapterID }) {
      revision = final.content
      chapterTitle = final.title
    }
  }

  private func resetSuggestion() {
    suggestionTask?.cancel()
    suggestionTask = nil
    suggestionText = ""
    suggestionKind = nil
  }

  private func perform(_ operation: () async throws -> Void) async {
    guard !isWorking else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await operation()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
