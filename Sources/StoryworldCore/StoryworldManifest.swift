import Foundation

public struct StoryworldManifest: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let storyworldID: UUID
  public var revision: Int
  public var title: String
  public let createdAt: Date
  public var modifiedAt: Date
  public var minimumCoreVersion: String
  public var sourceReference: StoryworldSourceReference?
  public var content: ContentDescriptor
  public var checksums: [String: String]

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    storyworldID: UUID = UUID(),
    revision: Int = 1,
    title: String,
    createdAt: Date = Date(),
    modifiedAt: Date = Date(),
    minimumCoreVersion: String = "0.1.0",
    sourceReference: StoryworldSourceReference? = nil,
    content: ContentDescriptor = .init(),
    checksums: [String: String] = [:]
  ) {
    self.formatVersion = formatVersion
    self.storyworldID = storyworldID
    self.revision = revision
    self.title = title
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.minimumCoreVersion = minimumCoreVersion
    self.sourceReference = sourceReference
    self.content = content
    self.checksums = checksums
  }

  public struct ContentDescriptor: Codable, Equatable, Sendable {
    public var lorebookEntry: String
    public var defaultLanguage: String

    public init(
      lorebookEntry: String = "lorebook/lorebook.json",
      defaultLanguage: String = "zh-Hans"
    ) {
      self.lorebookEntry = lorebookEntry
      self.defaultLanguage = defaultLanguage
    }

    enum CodingKeys: String, CodingKey {
      case lorebookEntry = "lorebook_entry"
      case defaultLanguage = "default_language"
    }
  }

  enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case storyworldID = "storyworld_id"
    case revision
    case title
    case createdAt = "created_at"
    case modifiedAt = "modified_at"
    case minimumCoreVersion = "minimum_core_version"
    case sourceReference = "source_ref"
    case content
    case checksums
  }
}

/// A portable reference to the novel used to create or associate a storyworld.
/// The content hash is the cross-device identity; local library UUIDs stay out
/// of the transferable package.
public struct StoryworldSourceReference: Codable, Equatable, Sendable {
  public let contentHash: String
  public let sourceFormat: String
  public let sourceFileName: String
  public let title: String?

  public init(
    contentHash: String,
    sourceFormat: String,
    sourceFileName: String,
    title: String? = nil
  ) {
    self.contentHash = contentHash
    self.sourceFormat = sourceFormat
    self.sourceFileName = sourceFileName
    self.title = title
  }

  enum CodingKeys: String, CodingKey {
    case contentHash = "content_hash"
    case sourceFormat = "source_format"
    case sourceFileName = "source_file_name"
    case title
  }
}

public enum StoryworldCoding {
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
