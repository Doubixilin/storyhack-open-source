import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public enum StoryPlayMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case canon
  case godMode = "god_mode"
  case evilGod = "evil_god"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .canon: "正史"
    case .godMode: "God Mode"
    case .evilGod: "邪神线"
    }
  }

  public var branchTitle: String { displayName }

  public var promptRule: String {
    switch self {
    case .canon:
      "正史模式：玩家扮演当前角色，行动受其已有能力、身份、环境和社会关系约束；世界可以拒绝不可能的行动，但必须给出自然反馈。"
    case .godMode:
      "God Mode：玩家仍扮演当前角色，但明确表达的行动意图必然成功；NPC、势力、社会和自然后果仍须按世界逻辑真实反应。"
    case .evilGod:
      "邪神线：玩家是亲自置身世界的全能者，可以改规则、改设定、改人物或化身任意角色；改写是世界内可感知并会引发反应的事件，不是幕后导演旁白。"
    }
  }

  public func matches(_ branch: RuntimeBranchDescriptor) -> Bool {
    if self == .canon, branch.branch.parentBranchID == nil { return true }
    let normalized = branch.branch.title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
    switch self {
    case .canon:
      return ["正史", "主线", "canon"].contains(normalized)
    case .godMode:
      return ["godmode", "god模式", "上帝模式"].contains(normalized)
    case .evilGod:
      return ["邪神", "邪神线", "evilgod", "evilgodline"].contains(normalized)
    }
  }

  public static func infer(from branch: RuntimeBranchDescriptor) -> StoryPlayMode? {
    allCases.first { $0.matches(branch) }
  }
}

public struct PlaythroughDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let storyworldID: UUID
  public var title: String
  public let createdAt: Date
  public var updatedAt: Date
  public var activeBranchID: UUID
  public var activeSessionID: UUID
  /// Optional for backward-compatible decoding. Applies independently of recap coverage.
  public var historyWindow: Int?
  public var canonBinding: CanonBinding?
  public var directive: PlaythroughDirective?
  public var effectiveDirective: DirectiveProfile { directive?.profile ?? .green }

  public var effectiveHistoryWindow: Int { min(200, max(2, historyWindow ?? 20)) }

  public init(
    id: UUID = UUID(),
    storyworldID: UUID,
    title: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    activeBranchID: UUID,
    activeSessionID: UUID,
    historyWindow: Int? = nil,
    canonBinding: CanonBinding? = nil,
    directive: PlaythroughDirective? = nil
  ) {
    self.id = id
    self.storyworldID = storyworldID
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.activeBranchID = activeBranchID
    self.activeSessionID = activeSessionID
    self.historyWindow = historyWindow
    self.canonBinding = canonBinding
    self.directive = directive
  }

  enum CodingKeys: String, CodingKey {
    case id
    case storyworldID = "storyworld_id"
    case title
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case activeBranchID = "active_branch_id"
    case activeSessionID = "active_session_id"
    case historyWindow = "history_window"
    case canonBinding = "canon_binding"
    case directive
  }
}

public struct RuntimeBranchDescriptor: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { branch.id }
  public let branch: BranchDescriptor
  public let sessionID: UUID
  public let baseStateHash: String
  public let baseContinuityHash: String?

  public init(branch: BranchDescriptor, sessionID: UUID, baseStateHash: String, baseContinuityHash: String? = nil) {
    self.branch = branch
    self.sessionID = sessionID
    self.baseStateHash = baseStateHash
    self.baseContinuityHash = baseContinuityHash
  }

  enum CodingKeys: String, CodingKey {
    case branch
    case sessionID = "session_id"
    case baseStateHash = "base_state_hash"
    case baseContinuityHash = "base_continuity_hash"
  }
}

public struct StorySessionDescriptor: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { address.sessionID }
  public let address: SessionAddress
  public let createdAt: Date
  public var updatedAt: Date

  public init(address: SessionAddress, createdAt: Date = Date(), updatedAt: Date = Date()) {
    self.address = address
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case address
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

public struct BranchStateSnapshot: Codable, Equatable, Sendable {
  public var lastEventSequence: Int
  public var values: [String: JSONValue]
  public var stateHash: String
  public var updatedAt: Date

  public init(
    lastEventSequence: Int = 0,
    values: [String: JSONValue] = [:],
    stateHash: String,
    updatedAt: Date = Date()
  ) {
    self.lastEventSequence = lastEventSequence
    self.values = values
    self.stateHash = stateHash
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case lastEventSequence = "last_event_sequence"
    case values
    case stateHash = "state_hash"
    case updatedAt = "updated_at"
  }
}

public struct CommittedStoryTurn: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let turnID: UUID
  public let address: SessionAddress
  public let sequence: Int
  public let userMessage: String
  public let narrative: String
  /// 回合结束后提供给玩家的下一步行动；旧事件日志缺失时为 nil。
  public let choices: [String]?
  public let statePatch: [String: JSONValue]
  public let resultingStateHash: String
  /// 提交载荷的幂等指纹；旧事件日志缺失时在重复提交检查中按已有字段重算。
  public let payloadFingerprint: String?
  /// 导演协议判定的原著节拍 ID；nil 表示不在任何已知节拍上
  public let beatID: String?
  /// The confirmed canon revision used for this generated turn; absent on old/manual events.
  public let canonBindingID: UUID?
  public let continuityUpdate: ContinuityUpdate?
  public let basedOnContinuityHash: String?
  public let resultingContinuityHash: String?
  public let continuityCalibrationRevision: Int?
  public let committedAt: Date

  public init(
    id: UUID = UUID(),
    turnID: UUID,
    address: SessionAddress,
    sequence: Int,
    userMessage: String,
    narrative: String,
    choices: [String]? = nil,
    statePatch: [String: JSONValue],
    resultingStateHash: String,
    payloadFingerprint: String? = nil,
    beatID: String? = nil,
    canonBindingID: UUID? = nil,
    continuityUpdate: ContinuityUpdate? = nil,
    basedOnContinuityHash: String? = nil,
    resultingContinuityHash: String? = nil,
    continuityCalibrationRevision: Int? = nil,
    committedAt: Date = Date()
  ) {
    self.id = id
    self.turnID = turnID
    self.address = address
    self.sequence = sequence
    self.userMessage = userMessage
    self.narrative = narrative
    self.choices = choices
    self.statePatch = statePatch
    self.resultingStateHash = resultingStateHash
    self.payloadFingerprint = payloadFingerprint
    self.beatID = beatID
    self.canonBindingID = canonBindingID
    self.continuityUpdate = continuityUpdate
    self.basedOnContinuityHash = basedOnContinuityHash
    self.resultingContinuityHash = resultingContinuityHash
    self.continuityCalibrationRevision = continuityCalibrationRevision
    self.committedAt = committedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case turnID = "turn_id"
    case address
    case sequence
    case userMessage = "user_message"
    case narrative
    case choices
    case statePatch = "state_patch"
    case resultingStateHash = "resulting_state_hash"
    case payloadFingerprint = "payload_fingerprint"
    case beatID = "beat_id"
    case canonBindingID = "canon_binding_id"
    case continuityUpdate = "continuity_update"
    case basedOnContinuityHash = "based_on_continuity_hash"
    case resultingContinuityHash = "resulting_continuity_hash"
    case continuityCalibrationRevision = "continuity_calibration_revision"
    case committedAt = "committed_at"
  }
}

public struct StorySave: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let address: SessionAddress
  public let title: String
  public let eventSequence: Int
  public let state: [String: JSONValue]
  public let stateHash: String
  public let continuity: ContinuitySnapshot?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    address: SessionAddress,
    title: String,
    eventSequence: Int,
    state: [String: JSONValue],
    stateHash: String,
    continuity: ContinuitySnapshot? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.address = address
    self.title = title
    self.eventSequence = eventSequence
    self.state = state
    self.stateHash = stateHash
    self.continuity = continuity
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case address
    case title
    case eventSequence = "event_sequence"
    case state
    case stateHash = "state_hash"
    case continuity
    case createdAt = "created_at"
  }
}

public struct PlaythroughContext: Equatable, Sendable {
  public let playthrough: PlaythroughDescriptor
  public let branch: RuntimeBranchDescriptor
  public let session: StorySessionDescriptor

  public var address: SessionAddress { session.address }

  public init(
    playthrough: PlaythroughDescriptor,
    branch: RuntimeBranchDescriptor,
    session: StorySessionDescriptor
  ) {
    self.playthrough = playthrough
    self.branch = branch
    self.session = session
  }
}

public struct StorySessionSnapshot: Equatable, Sendable {
  public let context: PlaythroughContext
  public let state: BranchStateSnapshot
  /// 当前分支自己的事件。该字段保留原有 branch-local 语义，供分支图、
  /// 存档等依赖本地 sequence 的调用方继续使用。
  public let turns: [CommittedStoryTurn]
  /// 沿祖先分叉点投影后，本次游玩实际经历的完整历史。
  /// 每个事件仍保留其原分支地址与 branch-local sequence。
  public let effectiveTurns: [CommittedStoryTurn]
  /// 可删除、可重建的滚动前情缓存；缺失或损坏时为 nil。
  public let recap: StoryRecap?
  public let canonStatus: CanonBindingStatus?
  public let anchorState: StoryAnchorState
  public let continuity: ContinuitySnapshot?
  public let continuityNotice: String?
  public let calibrationReviews: [ContinuityCalibrationReview]
  public let saves: [StorySave]

  public init(
    context: PlaythroughContext,
    state: BranchStateSnapshot,
    turns: [CommittedStoryTurn],
    effectiveTurns: [CommittedStoryTurn]? = nil,
    recap: StoryRecap? = nil,
    saves: [StorySave],
    canonStatus: CanonBindingStatus? = nil,
    anchorState: StoryAnchorState = .init(),
    continuity: ContinuitySnapshot? = nil,
    continuityNotice: String? = nil,
    calibrationReviews: [ContinuityCalibrationReview] = []
  ) {
    self.context = context
    self.state = state
    self.turns = turns
    self.effectiveTurns = effectiveTurns ?? turns
    self.recap = recap
    self.saves = saves
    self.canonStatus = canonStatus
    self.anchorState = anchorState
    self.continuity = continuity
    self.continuityNotice = continuityNotice
    self.calibrationReviews = calibrationReviews
  }
}

/// 分支目录中的滚动前情缓存。`throughEffectiveTurnCount` 使用投影后的
/// 1-based 回合数量，不借用或改写任何分支的本地事件 sequence。
public struct StoryRecap: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let throughEffectiveTurnCount: Int
  public let lastAttemptedEffectiveTurnCount: Int
  public let narrative: String?
  public let generatedAt: Date?

  public init(
    schemaVersion: Int = StoryRecap.currentSchemaVersion,
    throughEffectiveTurnCount: Int,
    lastAttemptedEffectiveTurnCount: Int,
    narrative: String?,
    generatedAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.throughEffectiveTurnCount = throughEffectiveTurnCount
    self.lastAttemptedEffectiveTurnCount = lastAttemptedEffectiveTurnCount
    self.narrative = narrative
    self.generatedAt = generatedAt
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case throughEffectiveTurnCount = "through_effective_turn_count"
    case lastAttemptedEffectiveTurnCount = "last_attempted_effective_turn_count"
    case narrative
    case generatedAt = "generated_at"
  }
}

/// 分支结局报告的内容中立统计。数值只来自投影后的有效历史、分支图与存档列表。
public struct EndingReportStatistics: Codable, Equatable, Sendable {
  public let turnCount: Int
  public let narrativeCharacterCount: Int
  public let turnsWithChoicesCount: Int
  public let branchCount: Int
  public let saveCount: Int

  public init(
    turnCount: Int,
    narrativeCharacterCount: Int,
    turnsWithChoicesCount: Int,
    branchCount: Int,
    saveCount: Int
  ) {
    self.turnCount = turnCount
    self.narrativeCharacterCount = narrativeCharacterCount
    self.turnsWithChoicesCount = turnsWithChoicesCount
    self.branchCount = branchCount
    self.saveCount = saveCount
  }

  enum CodingKeys: String, CodingKey {
    case turnCount = "turn_count"
    case narrativeCharacterCount = "narrative_character_count"
    case turnsWithChoicesCount = "turns_with_choices_count"
    case branchCount = "branch_count"
    case saveCount = "save_count"
  }
}

/// 当前分支的持久化结局报告。报告是可重复进入的旁路产物，不改变分支可写状态。
public struct StoryEndingReport: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let statistics: EndingReportStatistics
  public let statisticLines: [String]
  public let verdict: String
  public let generatedAtEffectiveTurnCount: Int
  public let generatedAt: Date

  public init(
    schemaVersion: Int = StoryEndingReport.currentSchemaVersion,
    statistics: EndingReportStatistics,
    statisticLines: [String],
    verdict: String,
    generatedAtEffectiveTurnCount: Int,
    generatedAt: Date = Date()
  ) {
    self.schemaVersion = schemaVersion
    self.statistics = statistics
    self.statisticLines = statisticLines
    self.verdict = verdict
    self.generatedAtEffectiveTurnCount = generatedAtEffectiveTurnCount
    self.generatedAt = generatedAt
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case statistics
    case statisticLines = "statistic_lines"
    case verdict
    case generatedAtEffectiveTurnCount = "generated_at_effective_turn_count"
    case generatedAt = "generated_at"
  }
}
