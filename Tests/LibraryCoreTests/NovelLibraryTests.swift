import Foundation
import DirectoryJournalCore
import Testing

@testable import LibraryCore

struct NovelLibraryTests {
  @Test func concurrentImportersShareOneRecordAndOccupiedLibraryCannotBeReadOrEdited() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-lock-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("synthetic.txt"), libraryRoot = root.appendingPathComponent("library")
    try Data("第一章 渡口\n林舟在渡口等船。".utf8).write(to: source)
    let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
      for _ in 0..<8 {
        group.addTask { try await NovelLibrary(rootURL: libraryRoot).importDocument(from: source).id }
      }
      var ids = Set<UUID>()
      for try await id in group { ids.insert(id) }
      return ids
    }
    #expect(ids.count == 1)
    let id = try #require(ids.first), library = NovelLibrary(rootURL: libraryRoot)
    let initial = try await library.load(documentID: id)
    let stateURL = libraryRoot.appendingPathComponent(id.uuidString.lowercased() + "/reader_state.json")
    let bytes = try Data(contentsOf: stateURL)
    // A raw kernel lease is not in the journal's recursive registry, just as
    // a lease held by another process is not. Real process interoperability is
    // tested in DirectoryProcessLockTests.
    let lease = try DirectoryProcessLease(directoryURL: libraryRoot, name: ".directory-access.lock")
    defer { lease.release() }
    await #expect(throws: DirectoryProcessLockError.busy) { try await library.list() }
    await #expect(throws: DirectoryProcessLockError.busy) { try await library.load(documentID: id) }
    await #expect(throws: DirectoryProcessLockError.busy) { try await library.saveReaderState(initial.readerState, for: id) }
    await #expect(throws: DirectoryProcessLockError.busy) { try await library.importDocument(from: source) }
    await #expect(throws: DirectoryProcessLockError.busy) { try await library.delete(documentID: id) }
    #expect(try Data(contentsOf: stateURL) == bytes)
    lease.release()
    #expect(try await library.list().count == 1)
    #expect(try await library.load(documentID: id).document == initial.document)
  }

  @Test
  func oldReaderPreferencesUseCurrentDefaults() throws {
    let legacyJSON = Data(
      #"{"font_size":19,"line_spacing":9,"theme":"sepia"}"#.utf8
    )

    let preferences = try JSONDecoder().decode(ReaderPreferences.self, from: legacyJSON)

    #expect(preferences.fontSize == 19)
    #expect(preferences.lineSpacing == 9)
    #expect(preferences.contentWidth == 920)
    #expect(preferences.theme == .sepia)
    #expect(preferences.flow == .horizontalPages)
  }

  @Test
  func explicitVerticalScrollPreferenceRemainsCompatible() throws {
    let storedJSON = Data(
      #"{"font_size":19,"line_spacing":9,"theme":"sepia","reading_flow":"vertical_scroll"}"#.utf8
    )

    let preferences = try JSONDecoder().decode(ReaderPreferences.self, from: storedJSON)

    #expect(preferences.flow == .verticalScroll)
    #expect(ReaderFlow.verticalScroll.rawValue == "vertical_scroll")
    #expect(ReaderFlow.horizontalPages.rawValue == "horizontal_pages")
  }

  @Test
  func readerPreferencesPersistHorizontalPaging() throws {
    let preferences = ReaderPreferences(
      fontSize: 21,
      lineSpacing: 10,
      contentWidth: 760,
      theme: .dark,
      flow: .horizontalPages
    )

    let data = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)

    #expect(decoded == preferences)
  }

  @Test
  func importsManagedCopyAndRestoresReaderState() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = container.appendingPathComponent("incoming", isDirectory: true)
    let libraryRoot = container.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let sourceURL = sourceDirectory.appendingPathComponent("测试小说.txt")
    try Data("第一章 开始\n正文。\n第二章 继续\n更多正文。".utf8).write(to: sourceURL)

    let library = NovelLibrary(rootURL: libraryRoot)
    let imported = try await library.importDocument(from: sourceURL)
    let managedURL = try await library.managedSourceURL(for: imported.id)

    #expect(managedURL.lastPathComponent == "测试小说.txt")
    #expect(FileManager.default.fileExists(atPath: managedURL.path))
    #expect(imported.document.chapters.count == 2)
    let persistedIndex = try String(
      contentsOf:
        libraryRoot
        .appendingPathComponent(imported.id.uuidString.lowercased(), isDirectory: true)
        .appendingPathComponent("document.json"),
      encoding: .utf8
    )
    #expect(!persistedIndex.contains("更多正文"))

    var state = imported.readerState
    state.currentChapterID = imported.document.chapters[1].id
    state.chapterProgress = 0.4
    state.currentLocator = ReaderNavigation.locator(
      in: imported.document,
      chapter: imported.document.chapters[1],
      progression: 0.4
    )
    state.bookmarks = [
      ReaderBookmark(
        chapterID: imported.document.chapters[1].id,
        title: imported.document.chapters[1].title,
        locator: state.currentLocator
      )
    ]
    state.preferences.fontSize = 24
    try await library.saveReaderState(state, for: imported.id)
    try await library.saveLastOpenedDocumentID(imported.id)

    let reopenedLibrary = NovelLibrary(rootURL: libraryRoot)
    let reopened = try #require(try await reopenedLibrary.list().first)
    #expect(reopened.id == imported.id)
    #expect(reopened.readerState.currentChapterID == "chapter-000002")
    #expect(reopened.readerState.chapterProgress == 0.4)
    #expect(reopened.readerState.currentLocator?.locations.totalProgression != nil)
    #expect(reopened.readerState.bookmarks.count == 1)
    #expect(reopened.readerState.preferences.fontSize == 24)
    #expect(reopened.document.chapters.allSatisfy { $0.content.isEmpty })
    #expect(try await reopenedLibrary.lastOpenedDocumentID() == imported.id)

    let loaded = try await reopenedLibrary.load(documentID: imported.id)
    #expect(loaded.document.chapters[1].content == "更多正文。")
    #expect(loaded.document.totalCharacterCount == imported.document.totalCharacterCount)
  }

  @Test
  func failedImportDoesNotLeaveVisibleRecord() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = container.appendingPathComponent("incoming", isDirectory: true)
    let libraryRoot = container.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let sourceURL = sourceDirectory.appendingPathComponent("空文件.txt")
    try Data().write(to: sourceURL)
    let library = NovelLibrary(rootURL: libraryRoot)

    await #expect(throws: (any Error).self) {
      try await library.importDocument(from: sourceURL)
    }
    #expect(try await library.list().isEmpty)
  }

  @Test
  func importingSameContentIsIdempotent() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = container.appendingPathComponent("incoming", isDirectory: true)
    let libraryRoot = container.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let firstURL = sourceDirectory.appendingPathComponent("第一份.txt")
    let secondURL = sourceDirectory.appendingPathComponent("改名后的同一本书.txt")
    let content = Data("第一章 开始\n相同正文。".utf8)
    try content.write(to: firstURL)
    try content.write(to: secondURL)

    let library = NovelLibrary(rootURL: libraryRoot)
    let first = try await library.importDocument(from: firstURL)
    let second = try await library.importDocument(from: secondURL)

    #expect(first.id == second.id)
    #expect(try await library.list().count == 1)
  }
}
