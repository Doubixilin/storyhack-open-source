import Foundation

public enum CharacterOrigin: Codable, Equatable, Sendable {
  case manual
  case extracted(storyworldID: UUID, entryID: String)
  case imported

  private enum CodingKeys: String, CodingKey {
    case kind
    case storyworldID = "storyworld_id"
    case entryID = "entry_id"
  }

  private enum Kind: String, Codable {
    case manual
    case extracted
    case imported
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .manual:
      self = .manual
    case .extracted:
      self = .extracted(
        storyworldID: try container.decode(UUID.self, forKey: .storyworldID),
        entryID: try container.decode(String.self, forKey: .entryID)
      )
    case .imported:
      self = .imported
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .manual:
      try container.encode(Kind.manual, forKey: .kind)
    case .extracted(let storyworldID, let entryID):
      try container.encode(Kind.extracted, forKey: .kind)
      try container.encode(storyworldID, forKey: .storyworldID)
      try container.encode(entryID, forKey: .entryID)
    case .imported:
      try container.encode(Kind.imported, forKey: .kind)
    }
  }
}

public struct CharacterFields: Codable, Equatable, Sendable {
  public var appearance: String
  public var personality: String
  public var speechStyle: String
  public var background: String
  public var abilities: String
  public var notes: String

  public init(
    appearance: String = "",
    personality: String = "",
    speechStyle: String = "",
    background: String = "",
    abilities: String = "",
    notes: String = ""
  ) {
    self.appearance = appearance
    self.personality = personality
    self.speechStyle = speechStyle
    self.background = background
    self.abilities = abilities
    self.notes = notes
  }

  enum CodingKeys: String, CodingKey {
    case appearance
    case personality
    case speechStyle = "speech_style"
    case background
    case abilities
    case notes
  }
}

public struct CharacterProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var summary: String
  public var origin: CharacterOrigin
  public var fields: CharacterFields
  public var category: String?
  public var tags: [String]
  public var portraitAssetID: UUID?
  public var promptProfile: String
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    summary: String = "",
    origin: CharacterOrigin = .manual,
    fields: CharacterFields = CharacterFields(),
    category: String? = nil,
    tags: [String] = [],
    portraitAssetID: UUID? = nil,
    promptProfile: String = "",
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.origin = origin
    self.fields = fields
    self.category = category
    self.tags = tags
    self.portraitAssetID = portraitAssetID
    self.promptProfile = promptProfile
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case summary
    case origin
    case fields
    case category
    case tags
    case portraitAssetID = "portrait_asset_id"
    case promptProfile = "prompt_profile"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

public enum CharacterAssetKind: String, Codable, Equatable, Sendable {
  case image
  case video
}

public enum CharacterAssetStatus: String, Codable, Equatable, Sendable {
  case candidate
  case approved
  case rejected
}

public struct CharacterAsset: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let characterID: UUID
  public let kind: CharacterAssetKind
  public var status: CharacterAssetStatus
  public let relativePath: String
  public let thumbnailPath: String?
  public let mimeType: String
  public let fileSHA256: String
  public let pixelWidth: Int?
  public let pixelHeight: Int?
  public let provider: String
  public let prompt: String?
  public let createdAt: Date
  public var approvedAt: Date?

  public init(
    id: UUID = UUID(),
    characterID: UUID,
    kind: CharacterAssetKind,
    status: CharacterAssetStatus = .candidate,
    relativePath: String,
    thumbnailPath: String? = nil,
    mimeType: String,
    fileSHA256: String,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil,
    provider: String,
    prompt: String? = nil,
    createdAt: Date = Date(),
    approvedAt: Date? = nil
  ) {
    self.id = id
    self.characterID = characterID
    self.kind = kind
    self.status = status
    self.relativePath = relativePath
    self.thumbnailPath = thumbnailPath
    self.mimeType = mimeType
    self.fileSHA256 = fileSHA256
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.provider = provider
    self.prompt = prompt
    self.createdAt = createdAt
    self.approvedAt = approvedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case characterID = "character_id"
    case kind
    case status
    case relativePath = "relative_path"
    case thumbnailPath = "thumbnail_path"
    case mimeType = "mime_type"
    case fileSHA256 = "file_sha256"
    case pixelWidth = "pixel_width"
    case pixelHeight = "pixel_height"
    case provider
    case prompt
    case createdAt = "created_at"
    case approvedAt = "approved_at"
  }
}

public struct CharacterLibraryIndex: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public var characters: [CharacterProfile]
  public var updatedAt: Date

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    characters: [CharacterProfile] = [],
    updatedAt: Date = Date()
  ) {
    self.formatVersion = formatVersion
    self.characters = characters
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case characters
    case updatedAt = "updated_at"
  }
}

public enum CharacterLibraryError: Error, Equatable, LocalizedError {
  case characterNotFound(UUID)
  case assetNotFound(UUID)
  case unsupportedFile
  case unsafeFile
  case fileTooLarge
  case invalidTransition
  case portraitRequiresApprovedImage
  case emptyName
  case unsupportedFormatVersion(found: Int)

  public var errorDescription: String? {
    switch self {
    case .characterNotFound(let id):
      "没有找到角色：\(id.uuidString)"
    case .assetNotFound(let id):
      "没有找到角色资产：\(id.uuidString)"
    case .unsupportedFile:
      "只支持 PNG、JPEG、HEIC 和 WebP 图片"
    case .unsafeFile:
      "图片文件不安全或不可读取"
    case .fileTooLarge:
      "单张图片不能超过 100 MB"
    case .invalidTransition:
      "当前资产状态不能执行此操作"
    case .portraitRequiresApprovedImage:
      "主形象必须使用已批准的图片"
    case .emptyName:
      "角色名称不能为空"
    case .unsupportedFormatVersion(let found):
      "角色库索引格式版本（\(found)）比当前 App 新，已暂停读写；请升级 App"
    }
  }
}
