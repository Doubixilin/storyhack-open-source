import CryptoKit
import DirectoryJournalCore
import Foundation
import NovelDocumentCore
import WritingCore

public enum NovelLibraryError: Error, LocalizedError {
  case recordNotFound(UUID)
  case unsafeSourceName

  public var errorDescription: String? {
    switch self {
    case .recordNotFound(let id):
      "没有找到书籍记录：\(id.uuidString)"
    case .unsafeSourceName:
      "导入文件名不安全"
    }
  }
}

public actor NovelLibrary {
  private struct LibraryState: Codable {
    var lastOpenedDocumentID: UUID?
  }

  public static var defaultRootURL: URL {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("StoryhackCommunity", isDirectory: true)
      .appendingPathComponent("Library", isDirectory: true)
  }

  private let rootURL: URL
  private let parser: NovelDocumentParser
  // Foundation's FileManager instance methods are thread-safe, but the SDK
  // does not declare it Sendable. This immutable reference is used only inside
  // withLibraryAccess, which also serializes injected test implementations.
  private nonisolated(unsafe) let fileManager: FileManager

  public init(
    rootURL: URL = NovelLibrary.defaultRootURL,
    parser: NovelDocumentParser = .init(),
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL
    self.parser = parser
    self.fileManager = fileManager
  }

  /// 最近一次 list() 跳过的损坏记录诊断；健康记录照常列出
  public private(set) var listDiagnostics: [String] = []

  public func list() throws -> [NovelLibraryRecord] {
    try withLibraryAccess { try listUnlocked() }
  }

  private func listUnlocked() throws -> [NovelLibraryRecord] {
    try ensureRootExists()
    let children = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )

    var diagnostics: [String] = []
    let records = children.compactMap { child -> NovelLibraryRecord? in
      do {
        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let metadataURL = child.appendingPathComponent("document.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        return try loadRecord(from: child)
      } catch {
        // 单条记录损坏不拖垮整个书架；记录保留在盘上，等待人工处理
        diagnostics.append("书架记录「\(child.lastPathComponent)」读取失败：\(error.localizedDescription)")
        return nil
      }
    }
    .sorted { $0.document.importedAt > $1.document.importedAt }
    listDiagnostics = diagnostics
    return records
  }

  public func importDocument(from sourceURL: URL) throws -> NovelLibraryRecord {
    try withLibraryAccess { try importDocumentUnlocked(from: sourceURL) }
  }

  private func importDocumentUnlocked(from sourceURL: URL) throws -> NovelLibraryRecord {
    try ensureRootExists()
    let sourceName = sourceURL.lastPathComponent
    guard !sourceName.isEmpty, sourceName != ".", sourceName != "..", !sourceName.contains("/")
    else {
      throw NovelLibraryError.unsafeSourceName
    }

    let documentID = UUID()
    let stagingURL = rootURL.appendingPathComponent(
      ".staging-\(documentID.uuidString)", isDirectory: true)
    let finalURL = recordDirectory(for: documentID)

    do {
      try fileManager.createDirectory(
        at: stagingURL.appendingPathComponent("source", isDirectory: true),
        withIntermediateDirectories: true
      )
      let managedSourceURL =
        stagingURL
        .appendingPathComponent("source", isDirectory: true)
        .appendingPathComponent(sourceName)
      try fileManager.copyItem(at: sourceURL, to: managedSourceURL)

      let document = try parser.parse(at: managedSourceURL, documentID: documentID)
      if let existing = try list().first(where: {
        $0.document.contentHash == document.contentHash
      }) {
        try fileManager.removeItem(at: stagingURL)
        return try load(documentID: existing.id)
      }
      let firstChapter = document.chapters.first
      let state = ReaderState(
        currentChapterID: firstChapter?.id,
        currentLocator: firstChapter.map {
          ReaderNavigation.locator(in: document, chapter: $0, progression: 0)
        }
      )
      let record = NovelLibraryRecord(document: document, readerState: state)

      let chaptersURL = stagingURL.appendingPathComponent("chapters", isDirectory: true)
      try fileManager.createDirectory(at: chaptersURL, withIntermediateDirectories: true)
      for chapter in document.chapters {
        try Data(chapter.content.utf8).write(
          to: chaptersURL.appendingPathComponent("\(chapter.id).txt"),
          options: [.atomic]
        )
      }
      try write(
        summaryDocument(from: document),
        to: stagingURL.appendingPathComponent("document.json")
      )
      try write(state, to: stagingURL.appendingPathComponent("reader_state.json"))
      try fileManager.moveItem(at: stagingURL, to: finalURL)
      return record
    } catch {
      if fileManager.fileExists(atPath: stagingURL.path) {
        try? fileManager.removeItem(at: stagingURL)
      }
      throw error
    }
  }

  public func saveReaderState(_ state: ReaderState, for documentID: UUID) throws {
    try withLibraryAccess { try saveReaderStateUnlocked(state, for: documentID) }
  }

  private func saveReaderStateUnlocked(_ state: ReaderState, for documentID: UUID) throws {
    let directory = recordDirectory(for: documentID)
    guard fileManager.fileExists(atPath: directory.path) else {
      throw NovelLibraryError.recordNotFound(documentID)
    }
    var normalized = state
    normalized.chapterProgress = min(max(normalized.chapterProgress, 0), 1)
    normalized.updatedAt = Date()
    try write(normalized, to: directory.appendingPathComponent("reader_state.json"))
  }

  public func lastOpenedDocumentID() throws -> UUID? {
    try withLibraryAccess { try lastOpenedDocumentIDUnlocked() }
  }

  private func lastOpenedDocumentIDUnlocked() throws -> UUID? {
    try ensureRootExists()
    let stateURL = rootURL.appendingPathComponent("library_state.json")
    guard fileManager.fileExists(atPath: stateURL.path) else { return nil }
    let data = try Data(contentsOf: stateURL)
    return try NovelDocumentCoding.makeDecoder().decode(LibraryState.self, from: data)
      .lastOpenedDocumentID
  }

  public func saveLastOpenedDocumentID(_ documentID: UUID) throws {
    try withLibraryAccess { try saveLastOpenedDocumentIDUnlocked(documentID) }
  }

  private func saveLastOpenedDocumentIDUnlocked(_ documentID: UUID) throws {
    guard fileManager.fileExists(atPath: recordDirectory(for: documentID).path) else {
      throw NovelLibraryError.recordNotFound(documentID)
    }
    try write(
      LibraryState(lastOpenedDocumentID: documentID),
      to: rootURL.appendingPathComponent("library_state.json")
    )
  }

  public func load(documentID: UUID) throws -> NovelLibraryRecord {
    try withLibraryAccess { try loadUnlocked(documentID: documentID) }
  }

  private nonisolated func loadUnlocked(documentID: UUID) throws -> NovelLibraryRecord {
    let directory = recordDirectory(for: documentID)
    guard fileManager.fileExists(atPath: directory.path) else {
      throw NovelLibraryError.recordNotFound(documentID)
    }
    return try loadRecord(from: directory, includeContent: true)
  }

  /// 删除一本书的全部本地数据（书库目录整体移除）。
  /// 若删的正是最近打开的书，一并清掉 lastOpened 指针。
  public func delete(documentID: UUID) throws {
    try withLibraryAccess { try deleteUnlocked(documentID: documentID) }
  }

  private func deleteUnlocked(documentID: UUID) throws {
    let directory = recordDirectory(for: documentID)
    guard fileManager.fileExists(atPath: directory.path) else {
      throw NovelLibraryError.recordNotFound(documentID)
    }
    try fileManager.removeItem(at: directory)
    if try lastOpenedDocumentID() == documentID {
      try write(
        LibraryState(lastOpenedDocumentID: nil),
        to: rootURL.appendingPathComponent("library_state.json")
      )
    }
  }

  public func managedSourceURL(for documentID: UUID) throws -> URL {
    try withLibraryAccess { try managedSourceURLUnlocked(for: documentID) }
  }

  private func managedSourceURLUnlocked(for documentID: UUID) throws -> URL {
    let sourceDirectory = recordDirectory(for: documentID)
      .appendingPathComponent("source", isDirectory: true)
    let files = try fileManager.contentsOfDirectory(
      at: sourceDirectory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    guard let source = files.first else {
      throw NovelLibraryError.recordNotFound(documentID)
    }
    return source
  }

  /// Publishes an immutable writing snapshot while keeping the book identity
  /// stable. The previous managed record is moved to a recoverable revision
  /// backup before the new version becomes visible.
  @discardableResult
  public func publish(snapshot: PublicationSnapshot) throws -> NovelLibraryRecord {
    try withLibraryAccess { try installPublication(snapshot: snapshot) }
  }

  /// Publish the reviewed assembly under its direction's stable identity.
  /// Reuse the existing reader migration and recoverable publication backup.
  public func publishAdaptation(_ assembly: AdaptationAssembly, store: AdaptationJobStore = .shared,
    acknowledgeUnchangedChapters: Bool = false) async throws -> NovelLibraryRecord {
    try await store.withValidatedExport(assembly, acknowledgeUnchangedChapters: acknowledgeUnchangedChapters) { export in
      try self.withLibraryAccess { try self.installAdaptation(assembly, export: export) }
    }
  }

  // These private synchronous disk helpers use immutable dependencies only.
  // Both publication entry points hold withLibraryAccess; adaptation publication
  // also retains the source store's lock through the final destination move.
  // No actor hop or unlocked library operation is exposed to the consumer.
  private nonisolated func installAdaptation(_ assembly: AdaptationAssembly, export: AdaptationExport) throws -> NovelLibraryRecord {
    let data = try Data(contentsOf: export.epubURL)
    guard data.count <= 100 * 1_048_576, AdaptationCoding.hash(data) == export.epubHash else { throw AdaptationAssemblyError.unsafeArchive }
    let parsed = try parser.parse(at: export.epubURL, documentID: assembly.variantID)
    guard parsed.chapters.count == assembly.chapters.count, parsed.title == assembly.title,
      parsed.contentHash == export.epubHash else { throw AdaptationAssemblyError.invalidEPUB }
    let chapters = zip(assembly.chapters, parsed.chapters).enumerated().map { index, pair in
      NovelChapter(id: pair.0.id, ordinal: index, title: pair.1.title, content: pair.1.content,
        sourceHref: pair.1.sourceHref, mediaType: pair.1.mediaType)
    }
    let hash = try assembly.fingerprint(), digest = String(hash.prefix(32))
    let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
    guard let revision = UUID(uuidString: ranges.map { String(digest.dropFirst($0.lowerBound).prefix($0.count)) }.joined(separator: "-"))
    else { throw AdaptationError.corruptPackage }
    let snapshot = PublicationSnapshot(projectID: assembly.jobID, publishedBookID: assembly.variantID, revisionID: revision,
      title: assembly.title, author: assembly.author,
      chapters: chapters.map { .init(chapterID: $0.id, ordinal: $0.ordinal, title: $0.title, content: $0.content) })
    let document = NovelDocument(id: assembly.variantID, title: assembly.title, author: assembly.author, sourceFormat: .epub,
      sourceFileName: export.epubURL.lastPathComponent, contentHash: AdaptationCoding.hash(data), chapters: chapters)
    if fileManager.fileExists(atPath: recordDirectory(for: assembly.variantID).path) {
      guard let metadata = try currentPublicationMetadataUnlocked(for: assembly.variantID), metadata.projectID == assembly.jobID else {
        throw AdaptationError.staleEdit
      }
      if metadata.currentRevisionID == revision {
        let existing = try loadUnlocked(documentID: assembly.variantID)
        guard existing.document.contentHash == document.contentHash else { throw AdaptationError.corruptPackage }
        return existing
      }
    }
    return try installPublication(snapshot: snapshot, sourceDocument: document, sourceBytes: data)
  }

  private nonisolated func installPublication(snapshot: PublicationSnapshot, sourceDocument: NovelDocument? = nil,
    sourceBytes: Data? = nil) throws -> NovelLibraryRecord {
    try ensureRootExists()
    let finalURL = recordDirectory(for: snapshot.publishedBookID)
    let stagingURL = rootURL.appendingPathComponent(
      ".publishing-\(snapshot.publishedBookID.uuidString)-\(snapshot.revisionID.uuidString)",
      isDirectory: true
    )
    if fileManager.fileExists(atPath: stagingURL.path) {
      try fileManager.removeItem(at: stagingURL)
    }
    let existing = try? loadUnlocked(documentID: snapshot.publishedBookID)
    let chapters = sourceDocument?.chapters ?? snapshot.chapters.sorted { $0.ordinal < $1.ordinal }.map { chapter in
      NovelChapter(
        id: chapter.chapterID,
        ordinal: chapter.ordinal,
        title: chapter.title,
        content: chapter.content,
        sourceHref: "chapters/\(chapter.chapterID).txt",
        mediaType: "text/plain"
      )
    }
    let contentHash = publicationHash(snapshot)
    let document = sourceDocument ?? NovelDocument(
      id: snapshot.publishedBookID,
      title: snapshot.title,
      author: snapshot.author,
      sourceFormat: .markdown,
      sourceFileName: safeFileName(snapshot.title) + ".md",
      contentHash: contentHash,
      importedAt: snapshot.createdAt,
      chapters: chapters
    )
    let readerState = migratedReaderState(from: existing, to: document)
    let record = NovelLibraryRecord(document: document, readerState: readerState)
    do {
      let sourceDirectory = stagingURL.appendingPathComponent("source", isDirectory: true)
      let chaptersDirectory = stagingURL.appendingPathComponent("chapters", isDirectory: true)
      try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: chaptersDirectory, withIntermediateDirectories: true)
      let markdown = snapshot.chapters.sorted { $0.ordinal < $1.ordinal }.map {
        "# \($0.title)\n\n\($0.content)"
      }.joined(separator: "\n\n")
      try (sourceBytes ?? Data(markdown.utf8)).write(
        to: sourceDirectory.appendingPathComponent(document.sourceFileName),
        options: [.atomic]
      )
      for chapter in chapters {
        try Data(chapter.content.utf8).write(
          to: chaptersDirectory.appendingPathComponent("\(chapter.id).txt"),
          options: [.atomic]
        )
      }
      try write(
        summaryDocument(from: document),
        to: stagingURL.appendingPathComponent("document.json")
      )
      try write(readerState, to: stagingURL.appendingPathComponent("reader_state.json"))
      try write(
        PublishedBookMetadata(
          projectID: snapshot.projectID,
          bookID: snapshot.publishedBookID,
          currentRevisionID: snapshot.revisionID,
          publishedAt: snapshot.createdAt
        ),
        to: stagingURL.appendingPathComponent("publication.json")
      )

      if fileManager.fileExists(atPath: finalURL.path) {
        let backupDirectory = publicationBackupsURL.appendingPathComponent(
          snapshot.publishedBookID.uuidString.lowercased(),
          isDirectory: true
        )
        let oldRevision = try currentPublicationMetadataUnlocked(for: snapshot.publishedBookID)?
          .currentRevisionID.uuidString.lowercased() ?? "legacy-\(UUID().uuidString.lowercased())"
        let resolved = backupDirectory.appendingPathComponent(
          oldRevision + ".libraryrecord",
          isDirectory: true
        )
        // 带事务日志的目录替换：进程在两次移动之间被杀时，
        // 下次列库由 recoverPendingReplacements 回滚或完成
        try DirectoryReplacementJournal(rootURL: rootURL, fileManager: fileManager)
          .replaceDirectory(stagingURL: stagingURL, finalURL: finalURL, backupURL: resolved)
      } else {
        // final 不存在时是单次原子移动，无崩溃窗口
        try fileManager.moveItem(at: stagingURL, to: finalURL)
      }
      return record
    } catch {
      if fileManager.fileExists(atPath: stagingURL.path) {
        try? fileManager.removeItem(at: stagingURL)
      }
      throw error
    }
  }

  public func currentPublicationMetadata(for bookID: UUID) throws -> PublishedBookMetadata? {
    try withLibraryAccess { try currentPublicationMetadataUnlocked(for: bookID) }
  }

  private nonisolated func currentPublicationMetadataUnlocked(for bookID: UUID) throws -> PublishedBookMetadata? {
    let url = recordDirectory(for: bookID).appendingPathComponent("publication.json")
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try NovelDocumentCoding.makeDecoder().decode(
      PublishedBookMetadata.self,
      from: Data(contentsOf: url)
    )
  }

  public func publicationBackupCount(for bookID: UUID) throws -> Int {
    try withLibraryAccess { try publicationBackupCountUnlocked(for: bookID) }
  }

  private func publicationBackupCountUnlocked(for bookID: UUID) throws -> Int {
    let directory = publicationBackupsURL.appendingPathComponent(
      bookID.uuidString.lowercased(),
      isDirectory: true
    )
    guard fileManager.fileExists(atPath: directory.path) else { return 0 }
    return try fileManager.contentsOfDirectory(atPath: directory.path).count
  }

  private nonisolated func withLibraryAccess<T>(_ operation: () throws -> T) throws -> T {
    let journal = DirectoryReplacementJournal(rootURL: rootURL, fileManager: fileManager)
    return try journal.withExclusiveAccess {
      try journal.recoverPendingReplacements()
      return try operation()
    }
  }

  private nonisolated func ensureRootExists() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  private nonisolated var publicationBackupsURL: URL {
    rootURL.appendingPathComponent(".publication-backups", isDirectory: true)
  }

  private nonisolated func recordDirectory(for id: UUID) -> URL {
    rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private nonisolated func loadRecord(
    from directory: URL,
    includeContent: Bool = false
  ) throws -> NovelLibraryRecord {
    let documentData = try Data(contentsOf: directory.appendingPathComponent("document.json"))
    let storedDocument = try NovelDocumentCoding.makeDecoder().decode(
      NovelDocument.self, from: documentData)
    let document: NovelDocument
    if includeContent {
      let chaptersURL = directory.appendingPathComponent("chapters", isDirectory: true)
      if fileManager.fileExists(atPath: chaptersURL.path) {
        let chapters = try storedDocument.chapters.map { chapter in
          let contentURL = chaptersURL.appendingPathComponent("\(chapter.id).txt")
          let contentData = try Data(contentsOf: contentURL, options: [.mappedIfSafe])
          guard let content = String(data: contentData, encoding: .utf8) else {
            throw NovelDocumentParserError.unreadableText
          }
          return NovelChapter(
            id: chapter.id,
            ordinal: chapter.ordinal,
            title: chapter.title,
            content: content,
            characterCount: chapter.characterCount,
            sourceHref: chapter.sourceHref,
            mediaType: chapter.mediaType
          )
        }
        document = replacingChapters(in: storedDocument, with: chapters)
      } else {
        document = storedDocument
      }
    } else {
      document = summaryDocument(from: storedDocument)
    }
    let stateURL = directory.appendingPathComponent("reader_state.json")
    var state: ReaderState
    if fileManager.fileExists(atPath: stateURL.path) {
      let stateData = try Data(contentsOf: stateURL)
      state = try NovelDocumentCoding.makeDecoder().decode(ReaderState.self, from: stateData)
    } else {
      state = ReaderState(currentChapterID: document.chapters.first?.id)
    }
    if let currentID = state.currentChapterID,
      let chapter = document.chapters.first(where: { $0.id == currentID })
    {
      if state.currentLocator == nil {
        state.currentLocator = ReaderNavigation.locator(
          in: document,
          chapter: chapter,
          progression: state.chapterProgress
        )
      }
    } else if let firstChapter = document.chapters.first {
      state.currentChapterID = firstChapter.id
      state.chapterProgress = 0
      state.currentLocator = ReaderNavigation.locator(
        in: document,
        chapter: firstChapter,
        progression: 0
      )
    }
    return NovelLibraryRecord(document: document, readerState: state)
  }

  private nonisolated func summaryDocument(from document: NovelDocument) -> NovelDocument {
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
    return replacingChapters(in: document, with: chapters)
  }

  private nonisolated func replacingChapters(
    in document: NovelDocument,
    with chapters: [NovelChapter]
  ) -> NovelDocument {
    NovelDocument(
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
  }

  private nonisolated func migratedReaderState(
    from existing: NovelLibraryRecord?,
    to document: NovelDocument
  ) -> ReaderState {
    guard let existing else {
      let first = document.chapters.first
      return ReaderState(
        currentChapterID: first?.id,
        currentLocator: first.map {
          ReaderNavigation.locator(in: document, chapter: $0, progression: 0)
        }
      )
    }
    let oldState = existing.readerState
    let oldOrdinal = existing.document.chapters.first {
      $0.id == oldState.currentChapterID
    }?.ordinal ?? 0
    let targetChapter = document.chapters.first { $0.id == oldState.currentChapterID }
      ?? document.chapters.min { lhs, rhs in
        abs(lhs.ordinal - oldOrdinal) < abs(rhs.ordinal - oldOrdinal)
      }
    let keptProgress = targetChapter?.id == oldState.currentChapterID
      ? oldState.chapterProgress
      : 0
    let chapterIDs = Set(document.chapters.map(\.id))
    let bookmarks = oldState.bookmarks.compactMap { bookmark -> ReaderBookmark? in
      guard chapterIDs.contains(bookmark.chapterID),
        let chapter = document.chapters.first(where: { $0.id == bookmark.chapterID })
      else { return nil }
      return ReaderBookmark(
        id: bookmark.id,
        chapterID: bookmark.chapterID,
        title: bookmark.title,
        locator: ReaderNavigation.locator(
          in: document,
          chapter: chapter,
          progression: bookmark.locator?.locations.progression ?? 0
        ),
        createdAt: bookmark.createdAt
      )
    }
    return ReaderState(
      currentChapterID: targetChapter?.id,
      chapterProgress: keptProgress,
      currentLocator: targetChapter.map {
        ReaderNavigation.locator(in: document, chapter: $0, progression: keptProgress)
      },
      preferences: oldState.preferences,
      bookmarks: bookmarks
    )
  }

  private nonisolated func publicationHash(_ snapshot: PublicationSnapshot) -> String {
    let content = snapshot.chapters.sorted { $0.ordinal < $1.ordinal }.map {
      "\($0.chapterID)|\($0.ordinal)|\($0.title)|\($0.content)"
    }.joined(separator: "\u{1f}")
    return SHA256.hash(data: Data(content.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private nonisolated func safeFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:")
    let sanitized = value.components(separatedBy: invalid).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "未命名小说" : sanitized
  }

  private nonisolated func write<Value: Encodable>(_ value: Value, to destination: URL) throws {
    let data = try NovelDocumentCoding.makeEncoder().encode(value)
    try data.write(to: destination, options: [.atomic])
  }
}
