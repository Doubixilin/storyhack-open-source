import Foundation
import LibraryCore
import StoryworldCore
import Testing

@testable import WritingCore

struct WritingCoreTests {
  @Test
  func localWritingLoopReopensImportsAndPublishesWithStableIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectLibrary = WritingProjectLibrary(
      rootURL: root.appendingPathComponent("projects", isDirectory: true)
    )
    let summary = try await projectLibrary.create(
      title: "终南山下",
      author: "测试作者",
      theme: "选择与责任",
      authorIntent: "人物行动必须有代价。",
      style: "克制的武侠叙事。"
    )
    let harness = WritingHarness(packageURL: summary.packageURL)

    await #expect(throws: WritingError.outlineNotFrozen) {
      try await harness.proposeChapterDraft(
        chapterID: "chapter-001",
        ordinal: 0,
        title: "故人之后",
        intent: "主角第一次作出选择。",
        content: "草稿"
      )
    }

    let theme = try await harness.proposeTheme("选择是否能够改变命运。")
    _ = try await harness.approveTheme(proposalID: theme.id)
    try await harness.saveBible(
      charactersJSON: #"[{"id":"hero","name":"杨遥"}]"#,
      world: "故事发生在终南山一带。",
      timelineJSON: #"[{"order":1,"event":"相遇"}]"#
    )
    let outline = try await harness.proposeOutline("# 第一卷\n\n1. 故人之后")
    let frozen = try await harness.approveAndFreezeOutline(proposalID: outline.id)
    #expect(frozen.frozen)

    let draftID = UUID()
    let draft = try await harness.proposeChapterDraft(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "故人之后",
      intent: "主角第一次作出选择。",
      content: "山雨将至，少年停在岔路前。",
      proposalID: draftID
    )
    let duplicate = try await harness.proposeChapterDraft(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "故人之后",
      intent: "主角第一次作出选择。",
      content: "山雨将至，少年停在岔路前。",
      proposalID: draftID
    )
    #expect(duplicate.id == draft.id)
    _ = try await harness.approveDraftForReview(proposalID: draft.id)
    _ = try await harness.submitReview(
      chapterID: "chapter-001",
      report: "选择的代价还应更明确。"
    )
    let revision = try await harness.proposeRevision(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "故人之后",
      content: "山雨将至，少年舍下旧伞，走向无人归来的山路。"
    )
    _ = try await harness.approveFinal(
      proposalID: revision.id,
      storyStateJSON: #"{"location":"终南山脚"}"#,
      foreshadowingJSON: #"["旧伞的来历"]"#
    )
    let firstPublication = try await harness.publish()
    #expect(firstPublication.chapters.map(\.chapterID) == ["chapter-001"])

    let reopened = WritingHarness(packageURL: summary.packageURL)
    let reopenedSnapshot = try await reopened.load()
    #expect(reopenedSnapshot.manifest.stage == .published)
    #expect(reopenedSnapshot.activeOutline?.id == frozen.id)
    #expect(reopenedSnapshot.finalChapters.first?.content.contains("旧伞") == true)
    #expect(reopenedSnapshot.proposals.allSatisfy { $0.status == .approved })

    let importedLibrary = WritingProjectLibrary(
      rootURL: root.appendingPathComponent("other-device", isDirectory: true)
    )
    let imported = try await importedLibrary.importPackage(from: summary.packageURL)
    #expect(imported.id == summary.id)
    #expect(try await WritingHarness(packageURL: imported.packageURL).load().manifest.stage == .published)

    let novelLibrary = NovelLibrary(
      rootURL: root.appendingPathComponent("novels", isDirectory: true)
    )
    let firstRecord = try await novelLibrary.publish(snapshot: firstPublication)
    #expect(firstRecord.id == firstPublication.publishedBookID)
    var readerState = firstRecord.readerState
    readerState.chapterProgress = 0.62
    readerState.bookmarks = [
      ReaderBookmark(chapterID: "chapter-001", title: "关键选择")
    ]
    try await novelLibrary.saveReaderState(readerState, for: firstRecord.id)

    let storyworldLibrary = StoryworldLibrary(
      rootURL: root.appendingPathComponent("storyworlds", isDirectory: true)
    )
    let world = try await storyworldLibrary.create(
      lorebook: Lorebook(
        title: "终南山下",
        entries: [LoreEntry(title: "终南山", content: "故事的起点。")]
      ),
      associateWith: StoryworldAssociationTarget(
        documentID: firstRecord.id,
        contentHash: firstRecord.document.contentHash
      )
    )

    let nextDraft = try await harness.proposeChapterDraft(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "故人之后",
      intent: "补足选择的后果。",
      content: "更新草稿"
    )
    _ = try await harness.approveDraftForReview(proposalID: nextDraft.id)
    _ = try await harness.submitReview(chapterID: "chapter-001", report: "通过。")
    let nextRevision = try await harness.proposeRevision(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "故人之后",
      content: "山雨将至，少年舍下旧伞，走向无人归来的山路。山门在身后合拢。"
    )
    _ = try await harness.approveFinal(proposalID: nextRevision.id)
    let secondPublication = try await harness.publish()
    let secondRecord = try await novelLibrary.publish(snapshot: secondPublication)

    #expect(secondRecord.id == firstRecord.id)
    #expect(secondRecord.readerState.chapterProgress == 0.62)
    #expect(secondRecord.readerState.bookmarks.map(\.title) == ["关键选择"])
    #expect(try await novelLibrary.publicationBackupCount(for: firstRecord.id) == 1)
    #expect(
      try await storyworldLibrary.listAssociated(
        with: StoryworldAssociationTarget(
          documentID: secondRecord.id,
          contentHash: secondRecord.document.contentHash
        )
      ).map(\.id) == [world.id]
    )
  }

  @Test
  func publishedProjectRejectsEarlyOperationsAndBibleDoesNotRegressStage() async throws {
    let context = try await makeHarness(stage: .published)
    defer { try? FileManager.default.removeItem(at: context.root) }

    await #expect(throws: WritingError.invalidStage(expected: "主题讨论", actual: .published)) {
      try await context.harness.proposeTheme("新主题")
    }
    await #expect(throws: WritingError.invalidStage(expected: "主题讨论", actual: .published)) {
      try await context.harness.approveTheme(proposalID: UUID())
    }
    await #expect(
      throws: WritingError.invalidStage(expected: "人物与世界基础、大纲已冻结", actual: .published)
    ) {
      try await context.harness.proposeOutline("新大纲")
    }
    await #expect(
      throws: WritingError.invalidStage(expected: "人物与世界基础、大纲已冻结", actual: .published)
    ) {
      try await context.harness.approveAndFreezeOutline(proposalID: UUID())
    }

    try await context.harness.saveBible(
      charactersJSON: "[]",
      world: "更新世界设定",
      timelineJSON: "[]"
    )
    #expect(try await context.harness.load().manifest.stage == .published)
  }

  @Test
  func crossChapterReviewAndRevisionAreRejectedBeforeStageValidation() async throws {
    let context = try await makeHarness(
      stage: .drafting,
      currentChapterID: "chapter-A"
    )
    defer { try? FileManager.default.removeItem(at: context.root) }

    let mismatch = WritingError.chapterLineageMismatch(
      expected: "chapter-A",
      actual: "chapter-B"
    )
    await #expect(throws: mismatch) {
      try await context.harness.submitReview(chapterID: "chapter-B", report: "误投审稿")
    }
    await #expect(throws: mismatch) {
      try await context.harness.proposeRevision(
        chapterID: "chapter-B",
        ordinal: 1,
        title: "错误章节",
        content: "误投修订"
      )
    }
    #expect(try await context.harness.load().manifest.stage == .drafting)
  }

  @Test
  func finalApprovalRejectsRevisionFromAnotherChapter() async throws {
    let context = try await makeHarness(
      stage: .revising,
      currentChapterID: "chapter-A"
    )
    defer { try? FileManager.default.removeItem(at: context.root) }
    let proposal = WritingProposal(
      kind: .revision,
      chapterID: "chapter-B",
      ordinal: 1,
      chapterTitle: "错误章节",
      content: "误投修订",
      inputHash: "test"
    )
    try writeProposal(proposal, packageURL: context.packageURL)

    await #expect(
      throws: WritingError.chapterLineageMismatch(
        expected: "chapter-A",
        actual: "chapter-B"
      )
    ) {
      try await context.harness.approveFinal(proposalID: proposal.id)
    }
    #expect(try await context.harness.load().manifest.stage == .revising)
  }

  @Test
  func finalApprovalRequiresApprovedReviewForSameChapter() async throws {
    let context = try await makeHarness(
      stage: .revising,
      currentChapterID: "chapter-A"
    )
    defer { try? FileManager.default.removeItem(at: context.root) }
    let proposal = WritingProposal(
      kind: .revision,
      chapterID: "chapter-A",
      ordinal: 0,
      chapterTitle: "第一章",
      content: "未经审稿的修订",
      inputHash: "test"
    )
    try writeProposal(proposal, packageURL: context.packageURL)

    await #expect(throws: WritingError.reviewRequired) {
      try await context.harness.approveFinal(proposalID: proposal.id)
    }
    #expect(try await context.harness.load().manifest.stage == .revising)
  }

  @Test
  func outlineFrozenProjectCannotPublish() async throws {
    let context = try await makeHarness(stage: .outlineFrozen)
    defer { try? FileManager.default.removeItem(at: context.root) }

    await #expect(
      throws: WritingError.invalidStage(
        expected: "章节已定稿、已发布",
        actual: .outlineFrozen
      )
    ) {
      try await context.harness.publish()
    }
  }

  @Test
  func fullFlowCanPublishAnotherChapterAfterFirstPublication() async throws {
    let context = try await makeHarness(stage: .themeDiscussion, activeOutlineRevisionID: nil)
    defer { try? FileManager.default.removeItem(at: context.root) }

    let theme = try await context.harness.proposeTheme("成长")
    _ = try await context.harness.approveTheme(proposalID: theme.id)
    try await context.harness.saveBible(
      charactersJSON: "[]",
      world: "世界",
      timelineJSON: "[]"
    )
    let outline = try await context.harness.proposeOutline("第一章与第二章")
    _ = try await context.harness.approveAndFreezeOutline(proposalID: outline.id)

    let firstDraft = try await context.harness.proposeChapterDraft(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "第一章",
      intent: "开场",
      content: "第一章草稿"
    )
    _ = try await context.harness.approveDraftForReview(proposalID: firstDraft.id)
    _ = try await context.harness.submitReview(chapterID: "chapter-001", report: "通过")
    let firstRevision = try await context.harness.proposeRevision(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "第一章",
      content: "第一章定稿"
    )
    _ = try await context.harness.approveFinal(proposalID: firstRevision.id)
    let firstPublication = try await context.harness.publish()
    #expect(firstPublication.chapters.map(\.chapterID) == ["chapter-001"])

    let secondDraft = try await context.harness.proposeChapterDraft(
      chapterID: "chapter-002",
      ordinal: 1,
      title: "第二章",
      intent: "推进",
      content: "第二章草稿"
    )
    _ = try await context.harness.approveDraftForReview(proposalID: secondDraft.id)
    _ = try await context.harness.submitReview(chapterID: "chapter-002", report: "通过")
    let secondRevision = try await context.harness.proposeRevision(
      chapterID: "chapter-002",
      ordinal: 1,
      title: "第二章",
      content: "第二章定稿"
    )
    _ = try await context.harness.approveFinal(proposalID: secondRevision.id)
    let secondPublication = try await context.harness.publish()

    #expect(secondPublication.chapters.map(\.chapterID) == ["chapter-001", "chapter-002"])
    #expect(try await context.harness.load().manifest.stage == .published)
  }

  @Test
  func finalApprovalCommitsSixConsistentFiles() async throws {
    let context = try await makeFinalizableHarness()
    defer { try? FileManager.default.removeItem(at: context.root) }
    let storyState = #"{"location":"山门","weather":"rain"}"#
    let foreshadowing = #"["旧伞","石门"]"#

    let final = try await context.harness.approveFinal(
      proposalID: context.proposal.id,
      storyStateJSON: storyState,
      foreshadowingJSON: foreshadowing
    )

    let revisionURL = context.packageURL.appendingPathComponent(
      "chapters/chapter-A/revisions/\(context.proposal.id.uuidString.lowercased()).json"
    )
    let storedRevision = try WritingCoding.decoder.decode(
      ChapterRevision.self,
      from: Data(contentsOf: revisionURL)
    )
    let finalText = try String(
      contentsOf: context.packageURL.appendingPathComponent("chapters/chapter-A/final.md"),
      encoding: .utf8
    )
    let manifest = try WritingCoding.decoder.decode(
      WritingProjectManifest.self,
      from: Data(contentsOf: context.packageURL.appendingPathComponent("manifest.json"))
    )
    let candidate = try WritingCoding.decoder.decode(
      WritingProposal.self,
      from: Data(contentsOf: proposalURL(context.proposal.id, packageURL: context.packageURL))
    )

    #expect(storedRevision == final)
    #expect(finalText == context.proposal.content)
    #expect(
      try String(
        contentsOf: context.packageURL.appendingPathComponent("state/story-state.json"),
        encoding: .utf8
      ) == storyState
    )
    #expect(
      try String(
        contentsOf: context.packageURL.appendingPathComponent("state/foreshadowing.json"),
        encoding: .utf8
      ) == foreshadowing
    )
    #expect(manifest.stage == .chapterFinalized)
    #expect(manifest.currentChapterID == "chapter-A")
    #expect(candidate.status == .approved)
    #expect(candidate.decidedAt != nil)
  }

  @Test
  func loadRollsBackInterruptedFinalApproval() async throws {
    let context = try await makeInterruptedFinalApproval()
    defer { try? FileManager.default.removeItem(at: context.root) }

    let snapshot = try await context.harness.load()

    #expect(snapshot.manifest.stage == .revising)
    #expect(snapshot.storyStateJSON == #"{"version":"old"}"#)
    #expect(snapshot.foreshadowingJSON == #"["old"]"#)
    #expect(snapshot.proposals.first(where: { $0.id == context.proposal.id })?.status == .pending)
    #expect(
      try String(
        contentsOf: context.packageURL.appendingPathComponent("chapters/chapter-A/final.md"),
        encoding: .utf8
      ) == "旧定稿"
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: context.packageURL.appendingPathComponent(
          "chapters/chapter-A/revisions/\(context.proposal.id.uuidString.lowercased()).json"
        ).path
      )
    )
  }

  @Test
  func finalApprovalSucceedsAfterInterruptedUpdateRecovery() async throws {
    let context = try await makeInterruptedFinalApproval()
    defer { try? FileManager.default.removeItem(at: context.root) }

    _ = try await context.harness.load()
    let final = try await context.harness.approveFinal(
      proposalID: context.proposal.id,
      storyStateJSON: #"{"version":"final"}"#,
      foreshadowingJSON: #"["final"]"#
    )
    let snapshot = try await context.harness.load()

    #expect(final.kind == .final)
    #expect(snapshot.manifest.stage == .chapterFinalized)
    #expect(snapshot.storyStateJSON == #"{"version":"final"}"#)
    #expect(snapshot.foreshadowingJSON == #"["final"]"#)
    #expect(snapshot.proposals.first(where: { $0.id == context.proposal.id })?.status == .approved)
    #expect(snapshot.finalChapters.first?.content == context.proposal.content)
  }

  @Test
  func publishedRetryReusesLatestMatchingSnapshot() async throws {
    let context = try await makeFinalizableHarness()
    defer { try? FileManager.default.removeItem(at: context.root) }
    _ = try await context.harness.approveFinal(proposalID: context.proposal.id)

    let first = try await context.harness.publish()
    let publicationsURL = context.packageURL.appendingPathComponent(
      "publications",
      isDirectory: true
    )
    let firstCount = try FileManager.default.contentsOfDirectory(
      at: publicationsURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.lowercased() == "json" }.count
    let manifestURL = context.packageURL.appendingPathComponent("manifest.json")
    let firstManifestData = try Data(contentsOf: manifestURL)

    let retry = try await context.harness.publish()
    let retryCount = try FileManager.default.contentsOfDirectory(
      at: publicationsURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.lowercased() == "json" }.count

    #expect(retry.revisionID == first.revisionID)
    #expect(retryCount == firstCount)
    #expect(try Data(contentsOf: manifestURL) == firstManifestData)
  }

  @Test
  func publishedProjectCreatesNewSnapshotAfterAnotherChapterIsFinalized() async throws {
    let context = try await makeFinalizableHarness()
    defer { try? FileManager.default.removeItem(at: context.root) }
    _ = try await context.harness.approveFinal(proposalID: context.proposal.id)
    let first = try await context.harness.publish()

    let draft = try await context.harness.proposeChapterDraft(
      chapterID: "chapter-B",
      ordinal: 1,
      title: "第二章",
      intent: "推进故事",
      content: "第二章草稿"
    )
    _ = try await context.harness.approveDraftForReview(proposalID: draft.id)
    _ = try await context.harness.submitReview(chapterID: "chapter-B", report: "通过")
    let revision = try await context.harness.proposeRevision(
      chapterID: "chapter-B",
      ordinal: 1,
      title: "第二章",
      content: "第二章定稿"
    )
    _ = try await context.harness.approveFinal(proposalID: revision.id)
    let second = try await context.harness.publish()

    #expect(second.revisionID != first.revisionID)
    #expect(second.chapters.map(\.chapterID) == ["chapter-A", "chapter-B"])
    #expect(try await context.harness.load().publications.count == 2)
  }

  @Test
  func chapterFinalizedFirstPublishCreatesRevisionAndMarksPublished() async throws {
    let context = try await makeFinalizableHarness()
    defer { try? FileManager.default.removeItem(at: context.root) }
    _ = try await context.harness.approveFinal(proposalID: context.proposal.id)
    let before = try await context.harness.load()

    let publication = try await context.harness.publish()
    let after = try await context.harness.load()

    #expect(before.manifest.stage == .chapterFinalized)
    #expect(before.publications.isEmpty)
    #expect(after.manifest.stage == .published)
    #expect(after.publications.map(\.revisionID) == [publication.revisionID])
    #expect(publication.chapters.map(\.chapterID) == ["chapter-A"])
  }

  private struct TestFileUpdateManifest: Encodable {
    struct Entry: Encodable {
      var path: String
      var backupName: String?
    }

    var entries: [Entry]
    var createdAt: Date
  }

  private func makeHarness(
    stage: WritingStage,
    currentChapterID: String? = nil,
    activeOutlineRevisionID: UUID? = UUID()
  ) async throws -> (root: URL, packageURL: URL, harness: WritingHarness) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let packageURL = root.appendingPathComponent("test.novelproject", isDirectory: true)
    let harness = WritingHarness(packageURL: packageURL)
    try await harness.initialize(
      manifest: WritingProjectManifest(
        title: "阶段测试",
        stage: stage,
        activeOutlineRevisionID: activeOutlineRevisionID,
        currentChapterID: currentChapterID
      ),
      theme: "",
      authorIntent: "",
      style: ""
    )
    return (root, packageURL, harness)
  }

  private func makeFinalizableHarness() async throws -> (
    root: URL,
    packageURL: URL,
    harness: WritingHarness,
    proposal: WritingProposal
  ) {
    let context = try await makeHarness(
      stage: .revising,
      currentChapterID: "chapter-A"
    )
    try FileManager.default.createDirectory(
      at: context.packageURL.appendingPathComponent(
        "chapters/chapter-A/revisions",
        isDirectory: true
      ),
      withIntermediateDirectories: true
    )
    let review = WritingProposal(
      kind: .review,
      chapterID: "chapter-A",
      content: "通过",
      inputHash: "review",
      status: .approved,
      decidedAt: Date()
    )
    let proposal = WritingProposal(
      kind: .revision,
      chapterID: "chapter-A",
      ordinal: 0,
      chapterTitle: "第一章",
      content: "新的定稿正文",
      inputHash: "revision"
    )
    try writeProposal(review, packageURL: context.packageURL)
    try writeProposal(proposal, packageURL: context.packageURL)
    return (context.root, context.packageURL, context.harness, proposal)
  }

  private func makeInterruptedFinalApproval() async throws -> (
    root: URL,
    packageURL: URL,
    harness: WritingHarness,
    proposal: WritingProposal
  ) {
    let context = try await makeFinalizableHarness()
    let finalURL = context.packageURL.appendingPathComponent("chapters/chapter-A/final.md")
    let storyStateURL = context.packageURL.appendingPathComponent("state/story-state.json")
    let foreshadowingURL = context.packageURL.appendingPathComponent("state/foreshadowing.json")
    try Data("旧定稿".utf8).write(to: finalURL, options: [.atomic])
    try Data(#"{"version":"old"}"#.utf8).write(to: storyStateURL, options: [.atomic])
    try Data(#"["old"]"#.utf8).write(to: foreshadowingURL, options: [.atomic])

    let revisionURL = context.packageURL.appendingPathComponent(
      "chapters/chapter-A/revisions/\(context.proposal.id.uuidString.lowercased()).json"
    )
    let manifestURL = context.packageURL.appendingPathComponent("manifest.json")
    let candidateURL = proposalURL(context.proposal.id, packageURL: context.packageURL)
    let targets = [
      revisionURL,
      finalURL,
      storyStateURL,
      foreshadowingURL,
      manifestURL,
      candidateURL,
    ]
    let transactionURL = context.packageURL.appendingPathComponent(
      ".replacement-journals/update-interrupted-final",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: transactionURL,
      withIntermediateDirectories: true
    )
    var entries: [TestFileUpdateManifest.Entry] = []
    for (index, target) in targets.enumerated() {
      if FileManager.default.fileExists(atPath: target.path) {
        let backupName = "backup-\(index)"
        try FileManager.default.copyItem(
          at: target,
          to: transactionURL.appendingPathComponent(backupName)
        )
        entries.append(.init(path: target.path, backupName: backupName))
      } else {
        entries.append(.init(path: target.path, backupName: nil))
      }
    }
    let transactionManifest = TestFileUpdateManifest(entries: entries, createdAt: Date())
    try JSONEncoder().encode(transactionManifest).write(
      to: transactionURL.appendingPathComponent("manifest.json"),
      options: [.atomic]
    )

    let interruptedRevision = ChapterRevision(
      id: context.proposal.id,
      chapterID: "chapter-A",
      ordinal: 0,
      title: "第一章",
      kind: .final,
      content: context.proposal.content,
      proposalID: context.proposal.id,
      createdAt: context.proposal.createdAt
    )
    try WritingCoding.encoder.encode(interruptedRevision).write(
      to: revisionURL,
      options: [.atomic]
    )
    try Data(context.proposal.content.utf8).write(to: finalURL, options: [.atomic])
    try Data(#"{"version":"new"}"#.utf8).write(to: storyStateURL, options: [.atomic])
    try Data(#"["new"]"#.utf8).write(to: foreshadowingURL, options: [.atomic])
    return context
  }

  private func proposalURL(_ id: UUID, packageURL: URL) -> URL {
    packageURL.appendingPathComponent("proposals/\(id.uuidString.lowercased()).json")
  }

  private func writeProposal(_ proposal: WritingProposal, packageURL: URL) throws {
    let url = proposalURL(proposal.id, packageURL: packageURL)
    try WritingCoding.encoder.encode(proposal).write(to: url, options: [.atomic])
  }
}
