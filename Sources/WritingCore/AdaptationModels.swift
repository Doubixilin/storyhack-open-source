import CryptoKit
import Foundation
import NovelDocumentCore

public enum AdaptationError: Error, Equatable, LocalizedError {
  case invalidSource
  case corruptPackage
  case staleEdit
  case invalidContract
  case invalidBookcase
  case evidenceMismatch
  case missingBookcase
  case alreadyDecided
  case invalidAnchor
  case invalidDraft
  case staleDraft
  case reviewRequired

  public var errorDescription: String? {
    switch self {
    case .invalidSource: "改编原文、章节标识或原始文件不一致。"
    case .corruptPackage: "改编任务损坏、版本不支持或包含不安全的路径；原文件已保留。"
    case .staleEdit: "改编任务已变化，请重新打开后核对。"
    case .invalidContract: "方向合同的字段、长度或章节引用无效。"
    case .invalidBookcase: "书案的字段、身份或章节覆盖无效。"
    case .evidenceMismatch: "书案引文无法唯一定位到所标记的原文章节。"
    case .missingBookcase: "请先审阅并批准书案，再创建正文方向。"
    case .alreadyDecided: "该书案候选已经处理。"
    case .invalidAnchor: "改编锚点、原文位置或审阅参数无效。"
    case .invalidDraft: "正文候选的内容、摘要、版本或审阅记录无效。"
    case .staleDraft: "正文依赖已变化，请先重新生成或修订过期章节。"
    case .reviewRequired: "请先批准生成位置；正文告警也需要作者明确核对。"
    }
  }
}

/// Codable bytes are canonicalized before hashing. Hashes detect changes;
/// the immutable files themselves provide version recovery.
public enum AdaptationCoding {
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
  public static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func fingerprint(_ value: some Encodable) throws -> String {
    hash(try encoder().encode(value))
  }
  static func timestamp() -> Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }
}

public struct AdaptationJob: Codable, Equatable, Identifiable, Sendable {
  public let schemaVersion: Int
  public let id: UUID
  public let title: String
  public let sourceSnapshotHash: String
  public let originalFileHash: String?
  public let originalFileExtension: String?
  public let isOriginalPlan: Bool?
  public let createdAt: Date
  public internal(set) var revision: UUID
  public internal(set) var approvedBookcaseID: UUID?
  public internal(set) var variants: [AdaptationVariant]

  init(document: NovelDocument, snapshotHash: String, originalHash: String?, originalPlan: Bool = false) {
    schemaVersion = 1; id = UUID(); title = document.title
    sourceSnapshotHash = snapshotHash; originalFileHash = originalHash
    originalFileExtension = originalHash == nil ? nil : document.sourceFormat.rawValue
    isOriginalPlan = originalPlan ? true : nil
    createdAt = AdaptationCoding.timestamp(); revision = UUID(); approvedBookcaseID = nil; variants = []
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version", id, title, revision, variants
    case sourceSnapshotHash = "source_snapshot_hash", originalFileHash = "original_file_hash"
    case originalFileExtension = "original_file_extension", createdAt = "created_at"
    case approvedBookcaseID = "approved_bookcase_id"
    case isOriginalPlan = "is_original_plan"
  }
}

public struct AdaptationVariant: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public internal(set) var contractRevisionID: UUID
  /// Frozen bookcase revision: later extraction never silently changes this variant.
  public internal(set) var bookcaseID: UUID?
  enum CodingKeys: String, CodingKey {
    case id, title, contractRevisionID = "contract_revision_id", bookcaseID = "bookcase_id"
  }
}

public struct AdaptationDirectionContract: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, CaseIterable, Sendable {
    case rewrite, expand, abridge, annotate, alternateEnding = "alternate_ending", original
  }
  public enum EventMobility: String, Codable, CaseIterable, Sendable { case fixed, reorder, free }

  public var mode: Mode = .rewrite
  public var protagonistIDs: [String] = []
  public var viewpoint = ""
  public var identityInvariants: [String] = []
  public var relationshipDirection = ""
  public var allowNewRelationships = false
  public var plotIntensity = 3
  public var eventMobility: EventMobility = .fixed
  public var ironEvents: [String] = []
  public var allowDropEvents = false
  public var allowedAdditions: [String] = []
  public var forbiddenAdditions: [String] = []
  public var targetCharacterCount = 1_600
  public var minimumCharacterCount = 1_200
  /// nil keeps legacy contracts unchanged: target is a preference, not a cap.
  public var maximumCharacterCount: Int?
  public var originalRetentionPercent = 80
  public var includeOriginalChapter = true
  public var style = ""
  public var notes = ""

  public init() {}
  public func validated(characterIDs: Set<String>? = nil) throws -> Self {
    guard (1...5).contains(plotIntensity), (0...100).contains(originalRetentionPercent),
      (0...20_000).contains(minimumCharacterCount),
      (1...20_000).contains(targetCharacterCount), minimumCharacterCount <= targetCharacterCount,
      maximumCharacterCount.map({ (1...20_000).contains($0) && targetCharacterCount <= $0 }) ?? true,
      viewpoint.count <= 500, relationshipDirection.count <= 2_000,
      style.count <= 2_000, notes.count <= 4_000,
      protagonistIDs.count <= 32, Set(protagonistIDs).count == protagonistIDs.count,
      protagonistIDs.allSatisfy({ !$0.isEmpty && $0.count <= 160 }),
      [identityInvariants, ironEvents, allowedAdditions, forbiddenAdditions].allSatisfy({
        $0.count <= 40 && $0.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500 }
      }), characterIDs.map({ Set(protagonistIDs).isSubset(of: $0) }) ?? true,
      try AdaptationCoding.encoder().encode(self).count <= 131_072
    else { throw AdaptationError.invalidContract }
    return self
  }
  public func fingerprint() throws -> String { try AdaptationCoding.fingerprint(validated()) }
  enum CodingKeys: String, CodingKey {
    case mode, viewpoint, style, notes
    case protagonistIDs = "protagonist_ids", identityInvariants = "identity_invariants"
    case relationshipDirection = "relationship_direction", allowNewRelationships = "allow_new_relationships"
    case plotIntensity = "plot_intensity", eventMobility = "event_mobility", ironEvents = "iron_events"
    case allowDropEvents = "allow_drop_events", allowedAdditions = "allowed_additions"
    case forbiddenAdditions = "forbidden_additions", targetCharacterCount = "target_character_count"
    case minimumCharacterCount = "minimum_character_count", originalRetentionPercent = "original_retention_percent"
    case maximumCharacterCount = "maximum_character_count"
    case includeOriginalChapter = "include_original_chapter"
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? mode
    protagonistIDs = try c.decodeIfPresent([String].self, forKey: .protagonistIDs) ?? []
    viewpoint = try c.decodeIfPresent(String.self, forKey: .viewpoint) ?? ""
    identityInvariants = try c.decodeIfPresent([String].self, forKey: .identityInvariants) ?? []
    relationshipDirection = try c.decodeIfPresent(String.self, forKey: .relationshipDirection) ?? ""
    allowNewRelationships = try c.decodeIfPresent(Bool.self, forKey: .allowNewRelationships) ?? false
    plotIntensity = try c.decodeIfPresent(Int.self, forKey: .plotIntensity) ?? plotIntensity
    eventMobility = try c.decodeIfPresent(EventMobility.self, forKey: .eventMobility) ?? eventMobility
    ironEvents = try c.decodeIfPresent([String].self, forKey: .ironEvents) ?? []
    allowDropEvents = try c.decodeIfPresent(Bool.self, forKey: .allowDropEvents) ?? false
    allowedAdditions = try c.decodeIfPresent([String].self, forKey: .allowedAdditions) ?? []
    forbiddenAdditions = try c.decodeIfPresent([String].self, forKey: .forbiddenAdditions) ?? []
    targetCharacterCount = try c.decodeIfPresent(Int.self, forKey: .targetCharacterCount) ?? targetCharacterCount
    minimumCharacterCount = try c.decodeIfPresent(Int.self, forKey: .minimumCharacterCount) ?? minimumCharacterCount
    maximumCharacterCount = try c.decodeIfPresent(Int.self, forKey: .maximumCharacterCount)
    originalRetentionPercent = try c.decodeIfPresent(Int.self, forKey: .originalRetentionPercent) ?? originalRetentionPercent
    includeOriginalChapter = try c.decodeIfPresent(Bool.self, forKey: .includeOriginalChapter) ?? true
    style = try c.decodeIfPresent(String.self, forKey: .style) ?? ""
    notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    _ = try validated()
  }
}

public struct AdaptationContractRevision: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let variantID: UUID
  public let bookcaseID: UUID?
  public let parentID: UUID?
  public let contentHash: String
  public let contract: AdaptationDirectionContract
  public let createdAt: Date
  enum CodingKeys: String, CodingKey {
    case id, contract, variantID = "variant_id", parentID = "parent_id", bookcaseID = "bookcase_id"
    case contentHash = "content_hash", createdAt = "created_at"
  }
}

public struct AdaptationGenerationBasis: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let variantID: UUID
  public let sourceSnapshotHash: String
  public let bookcaseID: UUID?
  public let bookcaseHash: String?
  public let contractRevisionID: UUID
  public let contractHash: String
  enum CodingKeys: String, CodingKey {
    case jobID = "job_id", variantID = "variant_id", sourceSnapshotHash = "source_snapshot_hash"
    case bookcaseID = "bookcase_id", bookcaseHash = "bookcase_hash"
    case contractRevisionID = "contract_revision_id", contractHash = "contract_hash"
  }
}
