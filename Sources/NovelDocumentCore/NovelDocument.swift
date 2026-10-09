import Foundation

public enum NovelSourceFormat: String, Codable, CaseIterable, Sendable {
  case text = "txt"
  case markdown = "md"
  case epub
}

public struct NovelChapter: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let ordinal: Int
  public let title: String
  public let content: String
  public let characterCount: Int
  public let sourceHref: String?
  public let mediaType: String?

  public init(
    id: String,
    ordinal: Int,
    title: String,
    content: String,
    characterCount: Int? = nil,
    sourceHref: String? = nil,
    mediaType: String? = nil
  ) {
    self.id = id
    self.ordinal = ordinal
    self.title = title
    self.content = content
    self.characterCount = characterCount ?? content.count
    self.sourceHref = sourceHref
    self.mediaType = mediaType
  }

  enum CodingKeys: String, CodingKey {
    case id
    case ordinal
    case title
    case content
    case characterCount = "character_count"
    case sourceHref = "source_href"
    case mediaType = "media_type"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    ordinal = try container.decode(Int.self, forKey: .ordinal)
    title = try container.decode(String.self, forKey: .title)
    content = try container.decode(String.self, forKey: .content)
    characterCount =
      try container.decodeIfPresent(Int.self, forKey: .characterCount)
      ?? content.count
    sourceHref = try container.decodeIfPresent(String.self, forKey: .sourceHref)
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
  }
}

public struct NovelDocument: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let author: String?
  public let sourceFormat: NovelSourceFormat
  public let sourceFileName: String
  public let contentHash: String
  public let importedAt: Date
  public let chapters: [NovelChapter]
  public let totalCharacterCount: Int

  public init(
    id: UUID,
    title: String,
    author: String? = nil,
    sourceFormat: NovelSourceFormat,
    sourceFileName: String,
    contentHash: String,
    importedAt: Date = Date(),
    chapters: [NovelChapter],
    totalCharacterCount: Int? = nil
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.sourceFormat = sourceFormat
    self.sourceFileName = sourceFileName
    self.contentHash = contentHash
    self.importedAt = importedAt
    self.chapters = chapters
    self.totalCharacterCount =
      totalCharacterCount
      ?? chapters.reduce(into: 0) { count, chapter in
        count += chapter.characterCount
      }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case author
    case sourceFormat = "source_format"
    case sourceFileName = "source_file_name"
    case contentHash = "content_hash"
    case importedAt = "imported_at"
    case chapters
    case totalCharacterCount = "total_character_count"
  }
}

public enum NovelDocumentCoding {
  public static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  public static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
