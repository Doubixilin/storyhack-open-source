import Foundation
import LLMProviderKit
import LibraryCore
import StorySessionCore
import StoryworldCore
import Testing

@testable import WorldbookUI

@MainActor
struct WorldbookUITests {
  @Test func chapterToolSettingPersistsOptInAndCanBeDisabledWithoutChangingCredential() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProviderProfileStore(rootURL: root, credentialStore: UISettingsCredentialStore())
    let model = ProviderSettingsViewModel(store: store)
    let saved = try #require(await model.save(id: nil, displayName: "fixture",
      baseURL: "https://example.com/v1", modelID: "fixture", apiKey: "synthetic-key",
      contextWindow: 32_768, maximumOutputTokens: 2_048, chapterToolCalling: true))
    #expect(saved.capabilities.toolCalling)
    await LLMToolCapabilityProbe.shared.recordDefinitiveRejection(saved)
    let disabled = try #require(await model.save(id: saved.id, displayName: "fixture",
      baseURL: "https://example.com/v1", modelID: "fixture", apiKey: "",
      contextWindow: 32_768, maximumOutputTokens: 2_048, chapterToolCalling: false))
    #expect(!disabled.capabilities.toolCalling)
    #expect(try await store.apiKey(for: saved.id) == "synthetic-key")
    #expect(try await store.list().count == 1)
    #expect(disabled.capabilities.contextWindow == 32_768 && disabled.maximumOutputTokens == 2_048)
  }
  @Test func nativeAnchorEditingRejectsStaleRevisionAndChangedBranch() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let world = try await library.create(lorebook: testLorebook())
    let package = try await library.managedPackageURL(storyworldID: world.id)
    let runtime = await StoryworldRuntimeStoreRegistry.shared.store(forPackageURL: package)
    let line = try await runtime.createPlaythrough(title: "原线")
    let turn = try await runtime.commitTurn(address: line.address, turnID: UUID(), userMessage: "行动", narrative: "留下承诺")
    let model = StorySessionViewModel(storyworldLibrary: library,
      providerStore: ProviderProfileStore(rootURL: root.appendingPathComponent("providers")))
    await model.prepare(storyworldID: world.id)
    let anchor = StoryAnchor(eventRef: .init(turn), label: "原承诺")
    model.draft = "尚未发送的行动"
    #expect(await model.saveAnchor(anchor, address: line.address, revision: nil) == nil)
    #expect(model.snapshot?.anchorState.anchors.first?.label == "原承诺")
    var edit = anchor
    edit.note = "另一端的修改"
    let revision = model.snapshot?.anchorState.revision
    try await runtime.saveAnchor(edit, address: line.address, expectedRevision: revision)
    #expect(await model.saveAnchor(anchor, address: line.address, revision: revision) != nil)
    #expect(model.snapshot?.anchorState.anchors.first?.note == "另一端的修改")
    #expect(model.draft == "尚未发送的行动")
    let child = try await runtime.forkBranch(address: line.address, title: "新分支")
    await model.activateBranch(child.branch.id)
    #expect(await model.removeAnchor(id: anchor.id, address: line.address, revision: revision) != nil)
    #expect(try await runtime.load(address: line.address).anchorState.anchors.count == 1)
    let childRevision = try #require(model.snapshot?.anchorState.revision)
    #expect(await model.removeAnchor(id: anchor.id, address: child.address, revision: childRevision) == nil)
    #expect(model.snapshot?.anchorState.anchors.isEmpty == true)
    #expect(try await runtime.load(address: line.address).anchorState.anchors.count == 1)
  }

  @Test func canonNoticeConfirmsReviewedVersionAndRejectsAnotherLine() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.create(lorebook: testLorebook())
    let package = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: package)
    let original = try await runtime.createPlaythrough(title: "原线")
    let model = StorySessionViewModel(storyworldLibrary: library,
      providerStore: ProviderProfileStore(rootURL: root.appendingPathComponent("providers")))
    await model.prepare(storyworldID: record.id)
    #expect(model.snapshot?.canonStatus?.state == .matched)
    try StoryworldCoding.makeEncoder().encode(CharacterContractFile()).write(to: package.appendingPathComponent("character_contracts.json"))
    await model.refreshCanonStatus()
    let reviewed = try #require(model.snapshot?.canonStatus)
    #expect(reviewed.state == .changed)
    model.draft = "尚未发送的行动"
    await model.confirmCanonBinding(reviewed)
    #expect(model.snapshot?.canonStatus?.state == .matched)
    #expect(model.draft == "尚未发送的行动")
    let other = try await runtime.createPlaythrough(title: "另一条线")
    await model.openPlaythrough(other.playthrough.id)
    await model.confirmCanonBinding(reviewed)
    #expect(model.errorMessage?.contains("已切换") == true)
    #expect(model.snapshot?.context.playthrough.id == other.playthrough.id)
    #expect(try await runtime.load(address: original.address).context.playthrough.canonBinding?.history.count == 1)
    #expect(try await runtime.load(address: other.address).context.playthrough.canonBinding?.history.isEmpty == true)
  }

  @Test
  func systemDirectiveMessagesRenderAsLowKeyStripsInsteadOfRawBubbles() {
    #expect(
      StoryTurnUserPresentation(userMessage: "自由输入")
        == .message("自由输入")
    )
    #expect(
      StoryTurnUserPresentation(userMessage: "（系统指令：导演·继续）")
        == .systemDirective("导演·继续")
    )
    #expect(
      StoryTurnUserPresentation(userMessage: StoryTurnEngine.openingPrompt)
        == .systemDirective("系统·开场")
    )
  }

  @Test
  func conflictResolutionCapturesPendingImportBeforeDialogDismissal() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("storyworlds"))
    let original = try await library.create(lorebook: testLorebook(), title: "冲突测试")
    let exported = try await library.exportPackage(
      storyworldID: original.id,
      to: root.appendingPathComponent("incoming.storyworld")
    )
    let model = StoryworldViewModel(library: library)

    await model.importStandaloneFiles(from: [exported])
    #expect(model.pendingConflict != nil)
    model.resolvePendingConflict(with: .importAsCopy)
    model.pendingConflict = nil

    let imported = await eventually {
      try await library.list().count == 2
    }
    #expect(imported)
    #expect(model.errorMessage == nil)
  }

  @Test
  func conflictReplacementCreatesBackupAfterDialogDismissal() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("storyworlds"))
    let original = try await library.create(lorebook: testLorebook(), title: "替换测试")
    let exported = try await library.exportPackage(
      storyworldID: original.id,
      to: root.appendingPathComponent("replacement.storyworld")
    )
    let model = StoryworldViewModel(library: library)

    await model.importStandaloneFiles(from: [exported])
    #expect(model.pendingConflict != nil)
    model.resolvePendingConflict(with: .replaceWithBackup)
    model.pendingConflict = nil

    let backedUp = await eventually {
      try await library.listBackups(storyworldID: original.id).count == 1
    }
    #expect(backedUp)
    #expect(try await library.list().count == 1)
    #expect(model.errorMessage == nil)
  }

  @Test
  func timelineExtractionAcceptsPortableContentHashAssociation() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let novelURL = root.appendingPathComponent("novel.md")
    try Data("# 第一章\n测试正文。".utf8).write(to: novelURL)
    let novelLibrary = NovelLibrary(rootURL: root.appendingPathComponent("library"))
    let novel = try await novelLibrary.importDocument(from: novelURL)
    let storyworldLibrary = StoryworldLibrary(rootURL: root.appendingPathComponent("storyworlds"))
    let storyworld = try await storyworldLibrary.create(
      lorebook: testLorebook(),
      sourceReference: StoryworldSourceReference(
        contentHash: novel.document.contentHash,
        sourceFormat: "md",
        sourceFileName: "novel.md",
        title: novel.document.title
      )
    )
    let providers = ProviderProfileStore(rootURL: root.appendingPathComponent("providers"))
    let model = StoryworldViewModel(
      library: storyworldLibrary,
      novelLibrary: novelLibrary,
      providerStore: providers
    )

    await model.reload()
    #expect(model.associatedRecords(for: novel).map(\.id) == [storyworld.id])
    await model.extractTimeline(storyworldID: storyworld.id)

    #expect(model.errorMessage == "请先在“模型设置”中添加模型。")
  }

  @Test
  func pageTapZonesReserveCenterAndMapEdges() {
    #expect(ReaderPageTapTarget.resolve(x: 0, width: 300) == .previous)
    #expect(ReaderPageTapTarget.resolve(x: 99, width: 300) == .previous)
    #expect(ReaderPageTapTarget.resolve(x: 100, width: 300) == .chrome)
    #expect(ReaderPageTapTarget.resolve(x: 200, width: 300) == .chrome)
    #expect(ReaderPageTapTarget.resolve(x: 201, width: 300) == .next)
  }

  @Test
  func chapterListIdentityIgnoresHighFrequencyReadingProgress() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("large.txt")
    try Data("第一章\n正文".utf8).write(to: sourceURL)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library"))
    let original = try await library.importDocument(from: sourceURL)
    let chapterID = try #require(original.readerState.currentChapterID)
    var progressed = original
    progressed.readerState.chapterProgress = 0.9
    progressed.readerState.updatedAt = Date().addingTimeInterval(1)

    let originalIdentity = ReaderChapterListIdentity(
      record: original,
      activeChapterID: chapterID,
      theme: .system,
      query: ""
    )
    let progressedIdentity = ReaderChapterListIdentity(
      record: progressed,
      activeChapterID: chapterID,
      theme: .system,
      query: ""
    )

    #expect(originalIdentity == progressedIdentity)
    #expect(
      originalIdentity
        != ReaderChapterListIdentity(
          record: progressed,
          activeChapterID: "chapter-2",
          theme: .system,
          query: ""
        )
    )
  }

  @Test
  func switchingToNewModeForksFromCurrentBranchAndKeepsEffectiveHistory() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("storyworlds"))
    let record = try await library.create(lorebook: testLorebook(), title: "模式分叉")
    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: packageURL)
    let canon = try await runtime.createPlaythrough(title: "主线")
    _ = try await runtime.commitTurn(
      address: canon.address,
      turnID: UUID(),
      userMessage: "正史行动",
      narrative: "正史剧情"
    )
    let god = try await runtime.forkBranch(
      address: canon.address, title: StoryPlayMode.godMode.branchTitle)
    _ = try await runtime.commitTurn(
      address: god.address,
      turnID: UUID(),
      userMessage: "God 行动",
      narrative: "God 剧情"
    )

    let model = StorySessionViewModel(
      storyworldLibrary: library,
      providerStore: ProviderProfileStore(rootURL: root.appendingPathComponent("providers"))
    )
    await model.prepare(storyworldID: record.id)
    #expect(model.snapshot?.context.branch.id == god.branch.id)
    await model.activatePlayMode(.evilGod)

    let branches = try await runtime.listBranches(playthroughID: canon.playthrough.id)
    let evil = try #require(branches.first(where: StoryPlayMode.evilGod.matches))
    #expect(evil.branch.parentBranchID == god.branch.id)
    #expect(model.snapshot?.turns.isEmpty == true)
    #expect(model.snapshot?.effectiveTurns.map(\.userMessage) == ["正史行动", "God 行动"])
  }

  @Test
  func pullBookmarkKeepsDistinctLocationsAndDeduplicatesSamePosition() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("reader.txt")
    try Data("第一章\n第一段。\n第二段。".utf8).write(to: sourceURL)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library"))
    let imported = try await library.importDocument(from: sourceURL)
    let model = LibraryViewModel(library: library)
    await model.reload()
    let chapterID = try #require(model.selectedRecord?.readerState.currentChapterID)

    model.updateReadingProgress(0.42, chapterID: chapterID, in: imported.id)
    #expect(model.addBookmarkAtCurrentLocation(in: imported.id))
    #expect(!model.addBookmarkAtCurrentLocation(in: imported.id))

    model.updateReadingProgress(0.421, chapterID: chapterID, in: imported.id)
    #expect(model.addBookmarkAtCurrentLocation(in: imported.id))

    model.updateReadingProgress(0.7, chapterID: chapterID, in: imported.id)
    #expect(model.addBookmarkAtCurrentLocation(in: imported.id))
    #expect(model.selectedRecord?.readerState.bookmarks.count == 3)
    #expect(
      model.selectedRecord?.readerState.bookmarks.map { $0.locator?.locations.progression }
        == [0.42, 0.421, 0.7]
    )
  }

  private func testLorebook() -> Lorebook {
    Lorebook(
      title: "测试世界",
      entries: [LoreEntry(title: "地点", content: "一座用于回归的城。")]
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("worldbook-ui-tests-\(UUID().uuidString)", isDirectory: true)
  }

  private func eventually(
    _ condition: () async throws -> Bool
  ) async -> Bool {
    for _ in 0..<100 {
      if (try? await condition()) == true { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return false
  }
}

// MARK: - 角色提取

@MainActor
struct CharacterExtractionTests {
  @Test
  func parseAcceptsFullJSON() throws {
    let json = """
      {"name":"小龙女","summary":"古墓派传人","category":"主角","tags":["武侠","清冷"],
      "appearance":"白衣胜雪","personality":"清冷","speech_style":"少言",
      "background":"古墓长大","abilities":"玉女心经","notes":"",
      "prompt_profile":"白衣女子，气质清冷"}
      """
    let draft = try CharacterExtractionService.parse(from: json)
    #expect(draft.name == "小龙女")
    #expect(draft.tags == ["武侠", "清冷"])
    #expect(draft.speechStyle == "少言")
    #expect(draft.promptProfile.contains("白衣"))
  }

  @Test
  func parseToleratesFencesAndMissingFields() throws {
    let fenced = "```json\n{\"name\":\"杨过\"}\n```"
    let draft = try CharacterExtractionService.parse(from: fenced)
    #expect(draft.name == "杨过")
    #expect(draft.summary.isEmpty)
    #expect(draft.tags.isEmpty)
  }

  @Test
  func parseRejectsPlainText() {
    #expect(throws: CharacterExtractionError.invalidModelResponse) {
      _ = try CharacterExtractionService.parse(from: "这不是 JSON")
    }
  }

  @Test
  func extractStreamsAndParses() async throws {
    let provider = StubProvider(text: """
      {"name":"甄嬛","category":"主角","tags":["宫斗"],"prompt_profile":"清宫装女子"}
      """)
    let draft = try await CharacterExtractionService.extract(
      entryTitle: "甄嬛",
      entryContent: "甄嬛，入宫为妃，心思缜密。",
      sourceTitle: "甄嬛传",
      provider: provider
    )
    #expect(draft.name == "甄嬛")
    #expect(draft.category == "主角")
  }

  @Test
  func extractRejectsEmptyContent() async {
    await #expect(throws: CharacterExtractionError.emptyEntryContent) {
      _ = try await CharacterExtractionService.extract(
        entryTitle: "空条目",
        entryContent: "   ",
        sourceTitle: "测试",
        provider: StubProvider(text: "{}")
      )
    }
  }

  private struct StubProvider: LLMProvider {
    let text: String
    var profile: ProviderProfile {
      ProviderProfile(
        displayName: "stub",
        kind: .openAICompatible,
        modelID: "stub",
        credentialReference: "stub"
      )
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
      AsyncThrowingStream { continuation in
        continuation.yield(.textDelta(text))
        continuation.yield(.completed)
        continuation.finish()
      }
    }
  }
}
