import Combine
import Foundation
import LibraryCore
import NovelDocumentCore

@MainActor
public final class LibraryViewModel: ObservableObject {
  @Published public private(set) var records: [NovelLibraryRecord] = []
  @Published public var selectedBookID: UUID?
  @Published public private(set) var isImporting = false
  @Published public private(set) var isLoadingBook = false
  @Published public var errorMessage: String?
  @Published public private(set) var factoryCandidate: NovelLibraryRecord?
  @Published public private(set) var factoryRequest: WorldbookGenerationRequest?
  @Published private var navigationTokens: [UUID: UUID] = [:]

  private let library: NovelLibrary
  private var delayedSaveTasks: [UUID: Task<Void, Never>] = [:]

  public init(library: NovelLibrary) {
    self.library = library
  }

  public var selectedRecord: NovelLibraryRecord? {
    records.first { $0.id == selectedBookID }
  }

  public func reload() async {
    do {
      records = try await library.list()
      if selectedBookID == nil {
        let lastOpenedID = try await library.lastOpenedDocumentID()
        selectedBookID = records.contains(where: { $0.id == lastOpenedID })
          ? lastOpenedID : records.first?.id
      } else if !records.contains(where: { $0.id == selectedBookID }) {
        selectedBookID = records.first?.id
      }
      await loadSelectedBook()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public func importDocuments(from urls: [URL]) async {
    guard !urls.isEmpty else { return }
    isImporting = true
    defer { isImporting = false }

    var lastImportedID: UUID?
    for url in urls {
      let hasAccess = url.startAccessingSecurityScopedResource()
      defer {
        if hasAccess {
          url.stopAccessingSecurityScopedResource()
        }
      }
      do {
        let record = try await library.importDocument(from: url)
        lastImportedID = record.id
      } catch {
        errorMessage = "无法导入《\(url.lastPathComponent)》：\(error.localizedDescription)"
        break
      }
    }
    do {
      records = try await library.list()
      if let lastImportedID {
        selectedBookID = lastImportedID
      }
      await loadSelectedBook()
    } catch {
      errorMessage = "刷新书架失败：\(error.localizedDescription)"
    }
  }

  /// 删除一本书：清本地数据并刷新书架；删的是选中书则改选第一本
  public func deleteBook(_ record: NovelLibraryRecord) async {
    do {
      try await library.delete(documentID: record.id)
      delayedSaveTasks[record.id]?.cancel()
      delayedSaveTasks.removeValue(forKey: record.id)
      navigationTokens.removeValue(forKey: record.id)
      records = try await library.list()
      if selectedBookID == record.id {
        selectedBookID = records.first?.id
      }
    } catch {
      errorMessage = "无法删除《\(record.document.title)》：\(error.localizedDescription)"
    }
  }

  public func loadSelectedBook() async {
    guard let selectedBookID else { return }
    if let current = selectedRecord,
      current.id == selectedBookID,
      current.document.chapters.contains(where: { !$0.content.isEmpty })
    {
      return
    }
    isLoadingBook = true
    defer { isLoadingBook = false }
    do {
      let loaded = try await library.load(documentID: selectedBookID)
      guard self.selectedBookID == selectedBookID else { return }
      records = records.map { record in
        record.id == selectedBookID ? loaded : summaryRecord(from: record)
      }
      try await library.saveLastOpenedDocumentID(selectedBookID)
    } catch {
      errorMessage = "无法打开小说：\(error.localizedDescription)"
    }
  }

  public func selectChapter(
    _ chapterID: String,
    in bookID: UUID,
    progression: Double = 0
  ) {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return }
    guard let chapter = records[index].document.chapters.first(where: { $0.id == chapterID })
    else { return }
    records[index].readerState.currentChapterID = chapterID
    records[index].readerState.chapterProgress = min(max(progression, 0), 1)
    records[index].readerState.currentLocator = ReaderNavigation.locator(
      in: records[index].document,
      chapter: chapter,
      progression: progression
    )
    records[index].readerState.updatedAt = Date()
    navigationTokens[bookID] = UUID()
    persistState(at: index)
  }

  public func moveChapter(by offset: Int, in bookID: UUID) {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return }
    let document = records[index].document
    guard !document.chapters.isEmpty else { return }
    let currentID = records[index].readerState.currentChapterID
    let currentIndex = document.chapters.firstIndex { $0.id == currentID } ?? 0
    let targetIndex = currentIndex + offset
    guard document.chapters.indices.contains(targetIndex) else { return }
    selectChapter(document.chapters[targetIndex].id, in: bookID)
  }

  public func canMoveChapter(by offset: Int, in bookID: UUID) -> Bool {
    guard let record = records.first(where: { $0.id == bookID }) else { return false }
    let currentIndex =
      record.document.chapters.firstIndex {
        $0.id == record.readerState.currentChapterID
      } ?? 0
    return record.document.chapters.indices.contains(currentIndex + offset)
  }

  public func updateReadingProgress(
    _ progression: Double,
    chapterID: String,
    in bookID: UUID
  ) {
    guard let index = records.firstIndex(where: { $0.id == bookID }),
      records[index].readerState.currentChapterID == chapterID,
      let chapter = records[index].document.chapters.first(where: { $0.id == chapterID })
    else { return }
    let normalized = min(max(progression, 0), 1)
    guard records[index].readerState.chapterProgress != normalized else { return }
    records[index].readerState.chapterProgress = normalized
    records[index].readerState.currentLocator = ReaderNavigation.locator(
      in: records[index].document,
      chapter: chapter,
      progression: normalized
    )
    records[index].readerState.updatedAt = Date()
    persistState(at: index, delayed: true)
  }

  public func adjustFontSize(by delta: Double, in bookID: UUID) {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return }
    let current = records[index].readerState.preferences.fontSize
    records[index].readerState.preferences.fontSize = min(max(current + delta, 12), 36)
    persistState(at: index)
  }

  public func setTheme(_ theme: ReaderTheme, in bookID: UUID) {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return }
    records[index].readerState.preferences.theme = theme
    persistState(at: index)
  }

  public func setReaderFlow(_ flow: ReaderFlow, in bookID: UUID) {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return }
    records[index].readerState.preferences.flow = flow
    navigationTokens[bookID] = UUID()
    persistState(at: index)
  }

  public func adjustLineSpacing(by delta: Double, in bookID: UUID) {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return }
    let current = records[index].readerState.preferences.lineSpacing
    records[index].readerState.preferences.lineSpacing = min(max(current + delta, 2), 18)
    persistState(at: index)
  }

  public func setContentWidth(_ width: Double, in bookID: UUID) {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return }
    records[index].readerState.preferences.contentWidth = min(max(width, 480), 1_400)
    persistState(at: index)
  }

  public func search(_ query: String, in bookID: UUID) async -> [ReaderSearchResult] {
    guard let document = records.first(where: { $0.id == bookID })?.document else { return [] }
    return await Task.detached(priority: .userInitiated) {
      ReaderNavigation.search(query, in: document)
    }.value
  }

  public func navigationToken(for bookID: UUID) -> UUID {
    navigationTokens[bookID] ?? bookID
  }

  public func toggleBookmark(in bookID: UUID) {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return }
    let record = records[index]
    guard let chapterID = record.readerState.currentChapterID,
      let chapter = record.document.chapters.first(where: { $0.id == chapterID })
    else { return }
    if records[index].readerState.bookmarks.contains(where: { $0.chapterID == chapterID }) {
      records[index].readerState.bookmarks.removeAll { $0.chapterID == chapterID }
    } else {
      let locator = ReaderNavigation.locator(
        in: record.document,
        chapter: chapter,
        progression: record.readerState.chapterProgress
      )
      records[index].readerState.bookmarks.append(
        ReaderBookmark(chapterID: chapterID, title: chapter.title, locator: locator)
      )
    }
    persistState(at: index)
  }

  /// 在当前阅读位置添加书签；同章内足够接近的位置视为同一处。
  @discardableResult
  public func addBookmarkAtCurrentLocation(in bookID: UUID) -> Bool {
    guard let index = records.firstIndex(where: { $0.id == bookID }) else { return false }
    let record = records[index]
    guard let chapterID = record.readerState.currentChapterID,
      let chapter = record.document.chapters.first(where: { $0.id == chapterID })
    else { return false }

    let progression = record.readerState.chapterProgress
    let isDuplicate = record.readerState.bookmarks.contains { bookmark in
      guard bookmark.chapterID == chapterID,
        let bookmarkedProgress = bookmark.locator?.locations.progression
      else { return false }
      return abs(bookmarkedProgress - progression) <= 0.000_001
    }
    guard !isDuplicate else { return false }

    let locator = ReaderNavigation.locator(
      in: record.document,
      chapter: chapter,
      progression: progression
    )
    records[index].readerState.bookmarks.append(
      ReaderBookmark(chapterID: chapterID, title: chapter.title, locator: locator)
    )
    persistState(at: index)
    return true
  }

  public func isCurrentChapterBookmarked(in bookID: UUID) -> Bool {
    guard let record = records.first(where: { $0.id == bookID }),
      let chapterID = record.readerState.currentChapterID
    else { return false }
    return record.readerState.bookmarks.contains { $0.chapterID == chapterID }
  }

  public func prepareFactory(for record: NovelLibraryRecord) {
    factoryCandidate = record
    factoryRequest = WorldbookGenerationRequest(
      source: ReaderSourceReference(
        document: record.document,
        locator: record.readerState.currentLocator
      )
    )
  }

  private func persistState(at index: Int, delayed: Bool = false) {
    let record = records[index]
    delayedSaveTasks[record.id]?.cancel()
    delayedSaveTasks[record.id] = Task { [weak self, library] in
      if delayed {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
      }
      do {
        try await library.saveReaderState(record.readerState, for: record.id)
      } catch {
        self?.errorMessage = "阅读进度保存失败：\(error.localizedDescription)"
      }
    }
  }

  private func summaryRecord(from record: NovelLibraryRecord) -> NovelLibraryRecord {
    let document = record.document
    let chapters = document.chapters.map { chapter in
      NovelChapter(
        id: chapter.id,
        ordinal: chapter.ordinal,
        title: chapter.title,
        content: "",
        characterCount: chapter.characterCount,
        sourceHref: chapter.sourceHref,
        mediaType: chapter.mediaType
      )
    }
    let summary = NovelDocument(
      id: document.id,
      title: document.title,
      author: document.author,
      sourceFormat: document.sourceFormat,
      sourceFileName: document.sourceFileName,
      contentHash: document.contentHash,
      importedAt: document.importedAt,
      chapters: chapters,
      totalCharacterCount: document.totalCharacterCount
    )
    return NovelLibraryRecord(document: summary, readerState: record.readerState)
  }
}
