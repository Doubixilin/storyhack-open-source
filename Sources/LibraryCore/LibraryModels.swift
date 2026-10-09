import Foundation
import NovelDocumentCore
import WritingCore

public enum ReaderTheme: String, Codable, CaseIterable, Sendable {
  case system
  case light
  case sepia
  case dark
}

public enum ReaderFlow: String, Codable, CaseIterable, Sendable {
  case verticalScroll = "vertical_scroll"
  case horizontalPages = "horizontal_pages"

  public var title: String {
    switch self {
    case .verticalScroll: "上下滚动"
    case .horizontalPages: "左右翻页"
    }
  }
}

public struct ReaderLocatorLocations: Codable, Equatable, Sendable {
  public var fragments: [String]
  public var progression: Double?
  public var position: Int?
  public var totalProgression: Double?

  public init(
    fragments: [String] = [],
    progression: Double? = nil,
    position: Int? = nil,
    totalProgression: Double? = nil
  ) {
    self.fragments = fragments
    self.progression = progression.map { min(max($0, 0), 1) }
    self.position = position
    self.totalProgression = totalProgression.map { min(max($0, 0), 1) }
  }

  enum CodingKeys: String, CodingKey {
    case fragments
    case progression
    case position
    case totalProgression = "total_progression"
  }
}

public struct ReaderLocatorText: Codable, Equatable, Sendable {
  public var before: String?
  public var highlight: String?
  public var after: String?

  public init(before: String? = nil, highlight: String? = nil, after: String? = nil) {
    self.before = before
    self.highlight = highlight
    self.after = after
  }
}

/// A stable, serializable reading location inspired by the Readium Locator model.
/// It is shared by progress, bookmarks, search results and future storyworld source references.
public struct ReaderLocator: Codable, Equatable, Sendable {
  public var href: String
  public var type: String
  public var title: String?
  public var locations: ReaderLocatorLocations
  public var text: ReaderLocatorText?

  public init(
    href: String,
    type: String,
    title: String? = nil,
    locations: ReaderLocatorLocations = .init(),
    text: ReaderLocatorText? = nil
  ) {
    self.href = href
    self.type = type
    self.title = title
    self.locations = locations
    self.text = text
  }
}

public struct ReaderPreferences: Codable, Equatable, Sendable {
  public var fontSize: Double
  public var lineSpacing: Double
  public var contentWidth: Double
  public var theme: ReaderTheme
  public var flow: ReaderFlow

  public init(
    fontSize: Double = 18,
    lineSpacing: Double = 8,
    contentWidth: Double = 920,
    theme: ReaderTheme = .system,
    flow: ReaderFlow = .horizontalPages
  ) {
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.contentWidth = min(max(contentWidth, 480), 1_400)
    self.theme = theme
    self.flow = flow
  }

  enum CodingKeys: String, CodingKey {
    case fontSize = "font_size"
    case lineSpacing = "line_spacing"
    case contentWidth = "content_width"
    case theme
    case flow = "reading_flow"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 18
    lineSpacing = try container.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 8
    contentWidth = min(
      max(try container.decodeIfPresent(Double.self, forKey: .contentWidth) ?? 920, 480),
      1_400
    )
    theme = try container.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .system
    flow = try container.decodeIfPresent(ReaderFlow.self, forKey: .flow) ?? .horizontalPages
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(fontSize, forKey: .fontSize)
    try container.encode(lineSpacing, forKey: .lineSpacing)
    try container.encode(contentWidth, forKey: .contentWidth)
    try container.encode(theme, forKey: .theme)
    try container.encode(flow, forKey: .flow)
  }
}

public struct ReaderBookmark: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let chapterID: String
  public let title: String
  public let locator: ReaderLocator?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    chapterID: String,
    title: String,
    locator: ReaderLocator? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.chapterID = chapterID
    self.title = title
    self.locator = locator
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case chapterID = "chapter_id"
    case title
    case locator
    case createdAt = "created_at"
  }
}

public struct ReaderState: Codable, Equatable, Sendable {
  public var currentChapterID: String?
  public var chapterProgress: Double
  public var currentLocator: ReaderLocator?
  public var preferences: ReaderPreferences
  public var bookmarks: [ReaderBookmark]
  public var updatedAt: Date

  public init(
    currentChapterID: String? = nil,
    chapterProgress: Double = 0,
    currentLocator: ReaderLocator? = nil,
    preferences: ReaderPreferences = .init(),
    bookmarks: [ReaderBookmark] = [],
    updatedAt: Date = Date()
  ) {
    self.currentChapterID = currentChapterID
    self.chapterProgress = min(max(chapterProgress, 0), 1)
    self.currentLocator = currentLocator
    self.preferences = preferences
    self.bookmarks = bookmarks
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case currentChapterID = "current_chapter_id"
    case chapterProgress = "chapter_progress"
    case currentLocator = "current_locator"
    case preferences
    case bookmarks
    case updatedAt = "updated_at"
  }
}

public struct ReaderSearchResult: Equatable, Identifiable, Sendable {
  public let id: String
  public let chapterID: String
  public let chapterTitle: String
  public let excerpt: String
  public let locator: ReaderLocator

  public init(
    id: String,
    chapterID: String,
    chapterTitle: String,
    excerpt: String,
    locator: ReaderLocator
  ) {
    self.id = id
    self.chapterID = chapterID
    self.chapterTitle = chapterTitle
    self.excerpt = excerpt
    self.locator = locator
  }
}

public struct ReaderSourceReference: Codable, Equatable, Sendable {
  public let documentID: UUID
  public let contentHash: String
  public let sourceFormat: NovelSourceFormat
  public let sourceFileName: String
  public let locator: ReaderLocator?

  public init(document: NovelDocument, locator: ReaderLocator? = nil) {
    documentID = document.id
    contentHash = document.contentHash
    sourceFormat = document.sourceFormat
    sourceFileName = document.sourceFileName
    self.locator = locator
  }

  enum CodingKeys: String, CodingKey {
    case documentID = "document_id"
    case contentHash = "content_hash"
    case sourceFormat = "source_format"
    case sourceFileName = "source_file_name"
    case locator
  }
}

public struct WorldbookGenerationRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let source: ReaderSourceReference
  public let requestedAt: Date

  public init(
    id: UUID = UUID(),
    source: ReaderSourceReference,
    requestedAt: Date = Date()
  ) {
    self.id = id
    self.source = source
    self.requestedAt = requestedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case source
    case requestedAt = "requested_at"
  }
}

public struct NovelLibraryRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { document.id }
  public let document: NovelDocument
  public var readerState: ReaderState

  public init(document: NovelDocument, readerState: ReaderState) {
    self.document = document
    self.readerState = readerState
  }

  enum CodingKeys: String, CodingKey {
    case document
    case readerState = "reader_state"
  }
}

public struct PublishedBookMetadata: Codable, Equatable, Sendable {
  public let projectID: UUID
  public let bookID: UUID
  public let currentRevisionID: UUID
  public let publishedAt: Date

  public init(
    projectID: UUID,
    bookID: UUID,
    currentRevisionID: UUID,
    publishedAt: Date = Date()
  ) {
    self.projectID = projectID
    self.bookID = bookID
    self.currentRevisionID = currentRevisionID
    self.publishedAt = publishedAt
  }

  enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case bookID = "book_id"
    case currentRevisionID = "current_revision_id"
    case publishedAt = "published_at"
  }
}
