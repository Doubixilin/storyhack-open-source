import CryptoKit
import Foundation

public enum ContinuityEntityKind: String, Codable, Sendable { case character, item, place, group }
public enum ContinuityFactKind: String, Codable, Sendable {
  case condition, relationship, possession, promise, secret, goal, unresolved
}
public enum ContinuityFactStatus: String, Codable, Sendable {
  case active, superseded, fulfilled, broken, released, resolved, retracted
}
public enum ContinuityRecordStatus: String, Codable, Sendable { case recorded, needsReconciliation }

/// One exact excerpt from the event being committed. The engine supplies the reference.
public struct ContinuityEvidence: Codable, Equatable, Sendable {
  public let event: StoryAnchorEventRef
  public let quote: String
  /// Present only for a player-confirmed correction, never supplied by MEMORY_PATCH.
  public let calibrationID: UUID?
  public init(event: StoryAnchorEventRef, quote: String, calibrationID: UUID? = nil) {
    self.event = event
    self.quote = quote
    self.calibrationID = calibrationID
  }
}

public struct ContinuityEntity: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var name: String
  public let kind: ContinuityEntityKind
  /// Generated entities are provisional. A similar name does not merge identities.
  public let provisional: Bool
  public let source: ContinuityEvidence?
}

public struct SceneContinuity: Codable, Equatable, Sendable {
  public let location: String
  public let time: String
  public let presentEntityIDs: [String]
  public let source: ContinuityEvidence
}

public struct ContinuityFact: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: ContinuityFactKind
  public let subjectID: String
  public let objectID: String?
  public let slot: String
  public let statement: String
  public var status: ContinuityFactStatus
  public var knownByEntityIDs: [String]
  public var evidence: [ContinuityEvidence]
}

/// The only mutable memory authority is the sequence of committed updates.
/// This value can be rebuilt; it never infers facts from narrative prose.
public struct ContinuityLedger: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public var entities: [String: ContinuityEntity]
  public var scene: SceneContinuity?
  public var facts: [String: ContinuityFact]
  public var legacyTurnCount: Int
  public var unresolvedTurnCount: Int
  public var latestGap: StoryAnchorEventRef?
  public var calibrations: [ContinuityCalibrationReceipt]?

  public init() {
    schemaVersion = 1
    entities = [
      "player": .init(id: "player", name: "玩家", kind: .character, provisional: false, source: nil)
    ]
    scene = nil
    facts = [:]
    legacyTurnCount = 0
    unresolvedTurnCount = 0
    latestGap = nil
  }

  public var activeFacts: [ContinuityFact] {
    facts.values.filter { $0.status == .active }.sorted { $0.id < $1.id }
  }

  public func fingerprint() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Self.digest(try encoder.encode(self))
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// Provider-independent bytes. Absence of a patch differs from disabled tracking.
public struct ContinuityInput: Sendable {
  public let data: Data?
  public init(data: Data?) { self.data = data }
  var fingerprint: String { data.map(ContinuityLedger.digest) ?? "missing" }
}

/// Untrusted model proposal. Unknown keys are rejected by decode(), not silently ignored.
public struct ContinuityDelta: Codable, Equatable, Sendable {
  public struct EntityDraft: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var kind: ContinuityEntityKind
    public var quote: String
    public init(key: String, name: String, kind: ContinuityEntityKind, quote: String) {
      self.key = key
      self.name = name
      self.kind = kind
      self.quote = quote
    }
  }
  public struct SceneDraft: Codable, Equatable, Sendable {
    public var location: String
    public var time: String
    public var presentEntityIDs: [String]
    public var quote: String
    public init(location: String, time: String, presentEntityIDs: [String], quote: String) {
      self.location = location
      self.time = time
      self.presentEntityIDs = presentEntityIDs
      self.quote = quote
    }
  }
  public struct FactDraft: Codable, Equatable, Sendable {
    public var kind: ContinuityFactKind
    public var subjectID: String
    public var objectID: String?
    public var slot: String
    public var statement: String
    public var knownByEntityIDs: [String]
    public var quote: String
    public var replacesFactID: String?
    public init(
      kind: ContinuityFactKind, subjectID: String, objectID: String? = nil,
      slot: String, statement: String, knownByEntityIDs: [String], quote: String,
      replacesFactID: String? = nil
    ) {
      self.kind = kind
      self.subjectID = subjectID
      self.objectID = objectID
      self.slot = slot
      self.statement = statement
      self.knownByEntityIDs = knownByEntityIDs
      self.quote = quote
      self.replacesFactID = replacesFactID
    }
  }
  public struct Resolution: Codable, Equatable, Sendable {
    public var factID: String
    public var status: ContinuityFactStatus
    public var quote: String
    public init(factID: String, status: ContinuityFactStatus, quote: String) {
      self.factID = factID
      self.status = status
      self.quote = quote
    }
  }
  public struct KnowledgeChange: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case learn, forget }
    public var factID: String
    public var entityID: String
    public var operation: Operation
    public var quote: String
    public init(factID: String, entityID: String, operation: Operation, quote: String) {
      self.factID = factID
      self.entityID = entityID
      self.operation = operation
      self.quote = quote
    }
  }

  public var entities: [EntityDraft]
  public var scene: SceneDraft?
  public var facts: [FactDraft]
  public var resolutions: [Resolution]
  public var knowledge: [KnowledgeChange]
  public init(
    entities: [EntityDraft] = [], scene: SceneDraft? = nil, facts: [FactDraft] = [],
    resolutions: [Resolution] = [], knowledge: [KnowledgeChange] = []
  ) {
    self.entities = entities
    self.scene = scene
    self.facts = facts
    self.resolutions = resolutions
    self.knowledge = knowledge
  }

  enum CodingKeys: String, CodingKey { case entities, scene, facts, resolutions, knowledge }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    entities = try c.decodeIfPresent([EntityDraft].self, forKey: .entities) ?? []
    scene = try c.decodeIfPresent(SceneDraft.self, forKey: .scene)
    facts = try c.decodeIfPresent([FactDraft].self, forKey: .facts) ?? []
    resolutions = try c.decodeIfPresent([Resolution].self, forKey: .resolutions) ?? []
    knowledge = try c.decodeIfPresent([KnowledgeChange].self, forKey: .knowledge) ?? []
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= 32 * 1_024 else { throw ContinuityError.limits }
    guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(o.keys).isSubset(of: ["entities", "scene", "facts", "resolutions", "knowledge"])
    else { throw ContinuityError.invalidOperation }
    let allowed: [String: Set<String>] = [
      "entities": ["key", "name", "kind", "quote"],
      "scene": ["location", "time", "presentEntityIDs", "quote"],
      "facts": [
        "kind", "subjectID", "objectID", "slot", "statement", "knownByEntityIDs", "quote",
        "replacesFactID",
      ],
      "resolutions": ["factID", "status", "quote"],
      "knowledge": ["factID", "entityID", "operation", "quote"],
    ]
    for (key, fields) in allowed {
      guard let value = o[key] else { continue }
      let rows: [[String: Any]]
      if key == "scene" {
        if value is NSNull { continue }
        guard let row = value as? [String: Any] else { throw ContinuityError.invalidOperation }
        rows = [row]
      } else {
        guard let array = value as? [[String: Any]] else { throw ContinuityError.invalidOperation }
        rows = array
      }
      guard rows.allSatisfy({ Set($0.keys).isSubset(of: fields) }) else {
        throw ContinuityError.invalidOperation
      }
    }
    return try JSONDecoder().decode(Self.self, from: data)
  }
}

/// The resolved delta is stored in the same event as its narrative. Model-supplied
/// IDs never become fact IDs or source references.
public struct CommittedContinuityDelta: Codable, Equatable, Sendable {
  public let entities: [ContinuityEntity]
  public let scene: SceneContinuity?
  public let addedFacts: [ContinuityFact]
  public let changedFacts: [ContinuityFact]
}

public struct ContinuityUpdate: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let status: ContinuityRecordStatus
  public let delta: CommittedContinuityDelta?
  public let issue: String?
  public let requestFingerprint: String
}

public struct ContinuitySnapshot: Codable, Equatable, Sendable {
  public let lastEventSequence: Int
  public let ledger: ContinuityLedger
  public let hash: String
  /// The branch-local review log prefix captured by this snapshot (nil on old saves).
  public let calibrationRevision: Int?
  public init(lastEventSequence: Int, ledger: ContinuityLedger, calibrationRevision: Int? = nil) throws {
    self.lastEventSequence = lastEventSequence
    self.ledger = ledger
    hash = try ledger.fingerprint()
    self.calibrationRevision = calibrationRevision == 0 ? nil : calibrationRevision
  }
}

public enum ContinuityError: String, Error, Equatable, LocalizedError {
  case limits, invalidOperation, unknownEntity, unknownFact, invalidLifecycle, slotConflict
  case invalidEvidence, corruptHistory, staleBase
  public var errorDescription: String? {
    switch self {
    case .limits: "连续性变更超过数量或文字限制。"
    case .invalidOperation: "连续性变更包含不支持的操作或字段。"
    case .unknownEntity: "连续性变更引用了未登记的人物或物品。"
    case .unknownFact: "连续性变更引用了不存在的事实。"
    case .invalidLifecycle: "连续性变更不符合承诺、事实或知情范围的变更规则。"
    case .slotConflict: "同一个状态位置已有活跃记录，需要明确替代关系。"
    case .invalidEvidence: "连续性变更的引文无法对应本轮正文。"
    case .corruptHistory: "连续性记录无法从事件可靠重建，请保留原文件并检查记录。"
    case .staleBase: "生成期间连续性记录已变化，本轮未提交，请刷新后重试。"
    }
  }
}
