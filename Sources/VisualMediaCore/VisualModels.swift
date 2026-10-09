import Foundation

public struct VisualCharacterProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var name: String
  public var immutableAppearance: String
  public var wardrobeVariants: [String]
  public var expressionNotes: [String]

  public init(
    id: String,
    name: String,
    immutableAppearance: String,
    wardrobeVariants: [String] = [],
    expressionNotes: [String] = []
  ) {
    self.id = id
    self.name = name
    self.immutableAppearance = immutableAppearance
    self.wardrobeVariants = wardrobeVariants
    self.expressionNotes = expressionNotes
  }

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case immutableAppearance = "immutable_appearance"
    case wardrobeVariants = "wardrobe_variants"
    case expressionNotes = "expression_notes"
  }
}

public struct VisualLocationProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var name: String
  public var appearance: String

  public init(id: String, name: String, appearance: String) {
    self.id = id
    self.name = name
    self.appearance = appearance
  }
}

public struct VisualBible: Codable, Equatable, Sendable {
  public let storyworldID: UUID
  public var styleGuide: String
  public var characters: [VisualCharacterProfile]
  public var locations: [VisualLocationProfile]
  public var updatedAt: Date

  public init(
    storyworldID: UUID,
    styleGuide: String = "",
    characters: [VisualCharacterProfile] = [],
    locations: [VisualLocationProfile] = [],
    updatedAt: Date = Date()
  ) {
    self.storyworldID = storyworldID
    self.styleGuide = styleGuide
    self.characters = characters
    self.locations = locations
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case storyworldID = "storyworld_id"
    case styleGuide = "style_guide"
    case characters
    case locations
    case updatedAt = "updated_at"
  }
}

public enum VisualSourceKind: String, Codable, Sendable {
  case storyworld
  case committedTurn = "committed_turn"
  case publishedChapter = "published_chapter"
  case character
  case cover
}

public struct VisualSource: Codable, Equatable, Sendable {
  public let kind: VisualSourceKind
  public let sourceID: String
  public let storyworldID: UUID?
  public let branchID: UUID?
  public let turnID: UUID?

  public init(
    kind: VisualSourceKind,
    sourceID: String,
    storyworldID: UUID? = nil,
    branchID: UUID? = nil,
    turnID: UUID? = nil
  ) {
    self.kind = kind
    self.sourceID = sourceID
    self.storyworldID = storyworldID
    self.branchID = branchID
    self.turnID = turnID
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case sourceID = "source_id"
    case storyworldID = "storyworld_id"
    case branchID = "branch_id"
    case turnID = "turn_id"
  }
}

public struct VisualCue: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let source: VisualSource
  public var visibleFacts: [String]
  public var prompt: String
  public var negativePrompt: String?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    source: VisualSource,
    visibleFacts: [String],
    prompt: String,
    negativePrompt: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.source = source
    self.visibleFacts = visibleFacts
    self.prompt = prompt
    self.negativePrompt = negativePrompt
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case source
    case visibleFacts = "visible_facts"
    case prompt
    case negativePrompt = "negative_prompt"
    case createdAt = "created_at"
  }
}

public enum SpoilerBoundary: Codable, Equatable, Sendable {
  case immediate
  case afterChapter(Int)
  case afterTurn(UUID)

  private enum CodingKeys: String, CodingKey { case kind, value }
  private enum Kind: String, Codable { case immediate, afterChapter, afterTurn }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .immediate: self = .immediate
    case .afterChapter: self = .afterChapter(try container.decode(Int.self, forKey: .value))
    case .afterTurn: self = .afterTurn(try container.decode(UUID.self, forKey: .value))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .immediate:
      try container.encode(Kind.immediate, forKey: .kind)
    case .afterChapter(let ordinal):
      try container.encode(Kind.afterChapter, forKey: .kind)
      try container.encode(ordinal, forKey: .value)
    case .afterTurn(let id):
      try container.encode(Kind.afterTurn, forKey: .kind)
      try container.encode(id, forKey: .value)
    }
  }

  public func isUnlocked(chapterOrdinal: Int?, visibleTurnIDs: Set<UUID>) -> Bool {
    switch self {
    case .immediate: true
    case .afterChapter(let required): (chapterOrdinal ?? -1) >= required
    case .afterTurn(let required): visibleTurnIDs.contains(required)
    }
  }
}

public enum VisualAssetStatus: String, Codable, Sendable {
  case candidate
  case approved
  case rejected
}

public struct VisualAssetRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var subjectIDs: [String]
  public var status: VisualAssetStatus
  public let cue: VisualCue
  public var spoilerBoundary: SpoilerBoundary
  public let provider: String
  public let model: String?
  public let modelVersion: String?
  public let seed: Int?
  public let referenceImageHashes: [String]
  public let mimeType: String
  public let pixelWidth: Int?
  public let pixelHeight: Int?
  public let fileSHA256: String
  public let relativePath: String
  public let aiGenerated: Bool
  public let createdAt: Date
  public var approvedAt: Date?

  public init(
    id: UUID = UUID(),
    subjectIDs: [String],
    status: VisualAssetStatus = .candidate,
    cue: VisualCue,
    spoilerBoundary: SpoilerBoundary = .immediate,
    provider: String,
    model: String? = nil,
    modelVersion: String? = nil,
    seed: Int? = nil,
    referenceImageHashes: [String] = [],
    mimeType: String,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil,
    fileSHA256: String,
    relativePath: String,
    aiGenerated: Bool,
    createdAt: Date = Date(),
    approvedAt: Date? = nil
  ) {
    self.id = id
    self.subjectIDs = subjectIDs
    self.status = status
    self.cue = cue
    self.spoilerBoundary = spoilerBoundary
    self.provider = provider
    self.model = model
    self.modelVersion = modelVersion
    self.seed = seed
    self.referenceImageHashes = referenceImageHashes
    self.mimeType = mimeType
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.fileSHA256 = fileSHA256
    self.relativePath = relativePath
    self.aiGenerated = aiGenerated
    self.createdAt = createdAt
    self.approvedAt = approvedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case subjectIDs = "subject_ids"
    case status
    case cue
    case spoilerBoundary = "spoiler_boundary"
    case provider
    case model
    case modelVersion = "model_version"
    case seed
    case referenceImageHashes = "reference_image_hashes"
    case mimeType = "mime_type"
    case pixelWidth = "pixel_width"
    case pixelHeight = "pixel_height"
    case fileSHA256 = "file_sha256"
    case relativePath = "relative_path"
    case aiGenerated = "ai_generated"
    case createdAt = "created_at"
    case approvedAt = "approved_at"
  }
}

public struct VisualAssetIndex: Codable, Equatable, Sendable {
  public let formatVersion: Int
  public var assets: [VisualAssetRecord]
  public var updatedAt: Date

  public init(formatVersion: Int = 1, assets: [VisualAssetRecord] = [], updatedAt: Date = Date()) {
    self.formatVersion = formatVersion
    self.assets = assets
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case assets
    case updatedAt = "updated_at"
  }
}
