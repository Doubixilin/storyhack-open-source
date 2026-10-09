import Foundation
import LibraryCore
import NovelDocumentCore
import Testing
import WritingCore

/// 链路 A：写作台写小说 → 发布 → 阅读器。
/// 全部离线、确定性，始终运行，不依赖网络。
struct EndToEndWritingToReaderTests {
  @Test
  func writingDeskPublishesNovelAndReaderOpensIt() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectLibrary = WritingProjectLibrary(
      rootURL: root.appendingPathComponent("writing", isDirectory: true)
    )
    let novelLibrary = NovelLibrary(
      rootURL: root.appendingPathComponent("library", isDirectory: true)
    )

    // 1. 新建写作项目
    let project = try await projectLibrary.create(
      title: "风起青石镇",
      author: "测试作者"
    )
    let harness = WritingHarness(packageURL: project.packageURL)

    // 2. 主题 → 批准
    let theme = try await harness.proposeTheme("少年林舟在雨夜抵达边陲青石镇，卷入旧塔失踪案。")
    _ = try await harness.approveTheme(proposalID: theme.id)

    // 3. 人物与世界基础
    try await harness.saveBible(
      charactersJSON: #"[{"name":"林舟","role":"主角"}]"#,
      world: "青石镇位于大夏边陲，镇外有废弃旧塔。",
      timelineJSON: #"["林舟入镇"]"#
    )

    // 4. 大纲 → 冻结
    let outline = try await harness.proposeOutline("第一章 雨夜入镇；第二章 旧塔夜探；第三章 真相浮现")
    _ = try await harness.approveAndFreezeOutline(proposalID: outline.id)

    // 5. 写第一章：草稿 → 审稿 → 修订 → 定稿
    let draft1 = try await harness.proposeChapterDraft(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "第一章 雨夜入镇",
      intent: "铺垫主角身份与小镇氛围。",
      content: "炎炎雨夜，林舟背着一把油纸伞走进青石镇。镇口的青石板路被雨水洗得发亮，街边酒肆还亮着昏黄的灯。"
    )
    _ = try await harness.approveDraftForReview(proposalID: draft1.id)
    _ = try await harness.submitReview(chapterID: "chapter-001", report: "节奏合适，细节可再补一笔。")
    let revision1 = try await harness.proposeRevision(
      chapterID: "chapter-001",
      ordinal: 0,
      title: "第一章 雨夜入镇",
      content: "炎炎雨夜，林舟背着一把油纸伞走进青石镇。镇口的青石板路被雨水洗得发亮，街边酒肆还亮着昏黄的灯，一个更夫正贴着墙根避雨。"
    )
    _ = try await harness.approveFinal(
      proposalID: revision1.id,
      storyStateJSON: #"{"location":"青石镇","time":"雨夜"}"#,
      foreshadowingJSON: #"["旧塔失踪案"]"#
    )

    // 6. 写第二章
    let draft2 = try await harness.proposeChapterDraft(
      chapterID: "chapter-002",
      ordinal: 1,
      title: "第二章 旧塔夜探",
      intent: "主角夜探旧塔，发现云纹铜牌。",
      content: "子时过后，林舟独自来到镇外旧塔。塔门虚掩，他在第三层捡到一枚刻着云纹的铜牌。"
    )
    _ = try await harness.approveDraftForReview(proposalID: draft2.id)
    _ = try await harness.submitReview(chapterID: "chapter-002", report: "通过。")
    let revision2 = try await harness.proposeRevision(
      chapterID: "chapter-002",
      ordinal: 1,
      title: "第二章 旧塔夜探",
      content: "子时过后，林舟独自来到镇外旧塔。塔门虚掩，塔内浮尘不散，他在第三层捡到一枚刻着云纹的铜牌，铜牌还残留着一丝温热。"
    )
    _ = try await harness.approveFinal(proposalID: revision2.id)

    // 7. 发布到阅读器书架
    let publication = try await harness.publish()
    #expect(publication.chapters.count == 2)
    _ = try await novelLibrary.publish(snapshot: publication)

    // 8. 阅读器验证
    let records = try await novelLibrary.list()
    #expect(records.count == 1)
    let bookID = try #require(records.first?.id)
    let book = try await novelLibrary.load(documentID: bookID)
    #expect(book.document.title == "风起青石镇")
    #expect(book.document.author == "测试作者")
    #expect(book.document.chapters.count == 2)
    #expect(book.document.chapters.map(\.title) == ["第一章 雨夜入镇", "第二章 旧塔夜探"])
    #expect(book.document.chapters[1].content.contains("云纹的铜牌"))

    // 9. 全文搜索能定位到第二章
    let results = ReaderNavigation.search("云纹", in: book.document)
    #expect(results.count == 1)
    #expect(results.first?.chapterID == "chapter-002")

    // 10. 阅读进度 + 书签持久化
    var state = book.readerState
    state.currentChapterID = "chapter-002"
    state.chapterProgress = 0.5
    state.bookmarks = [
      ReaderBookmark(chapterID: "chapter-002", title: "第二章 旧塔夜探", locator: nil)
    ]
    try await novelLibrary.saveReaderState(state, for: bookID)
    let reopened = try await novelLibrary.load(documentID: bookID)
    #expect(reopened.readerState.currentChapterID == "chapter-002")
    #expect(reopened.readerState.chapterProgress == 0.5)
    #expect(reopened.readerState.bookmarks.count == 1)
  }

  @Test
  func republishingSameBookKeepsIdentityAndMigratesProgress() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectLibrary = WritingProjectLibrary(
      rootURL: root.appendingPathComponent("writing", isDirectory: true)
    )
    let novelLibrary = NovelLibrary(
      rootURL: root.appendingPathComponent("library", isDirectory: true)
    )

    let project = try await projectLibrary.create(title: "再版测试", author: "作者")
    let harness = WritingHarness(packageURL: project.packageURL)
    let theme = try await harness.proposeTheme("再版主题")
    _ = try await harness.approveTheme(proposalID: theme.id)
    try await harness.saveBible(charactersJSON: "[]", world: "世界", timelineJSON: "[]")
    let outline = try await harness.proposeOutline("第一章 内容")
    _ = try await harness.approveAndFreezeOutline(proposalID: outline.id)
    let draft = try await harness.proposeChapterDraft(
      chapterID: "chapter-001", ordinal: 0, title: "第一章", intent: "", content: "第一版内容。"
    )
    _ = try await harness.approveDraftForReview(proposalID: draft.id)
    _ = try await harness.submitReview(chapterID: "chapter-001", report: "ok")
    let revision = try await harness.proposeRevision(
      chapterID: "chapter-001", ordinal: 0, title: "第一章", content: "第一版内容。"
    )
    _ = try await harness.approveFinal(proposalID: revision.id)
    let publication = try await harness.publish()
    _ = try await novelLibrary.publish(snapshot: publication)
    let firstID = try #require(try await novelLibrary.list().first?.id)

    // 设定阅读进度，再版发布后应保留
    var state = try await novelLibrary.load(documentID: firstID).readerState
    state.chapterProgress = 0.7
    try await novelLibrary.saveReaderState(state, for: firstID)

    // 再发布（相同 publishedBookID）
    let secondPub = try await harness.publish()
    let republished = try await novelLibrary.publish(snapshot: secondPub)

    #expect(republished.id == firstID)
    let records = try await novelLibrary.list()
    #expect(records.count == 1)
    #expect(records.first?.id == firstID)
    let reopened = try await novelLibrary.load(documentID: firstID)
    #expect(reopened.readerState.chapterProgress == 0.7)
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("e2e-writing-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
