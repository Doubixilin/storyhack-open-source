import Foundation

public struct SessionAddress: Codable, Hashable, Sendable {
  public let storyworldID: UUID
  public let playthroughID: UUID
  public let branchID: UUID
  public let sessionID: UUID

  public init(
    storyworldID: UUID,
    playthroughID: UUID,
    branchID: UUID,
    sessionID: UUID
  ) {
    self.storyworldID = storyworldID
    self.playthroughID = playthroughID
    self.branchID = branchID
    self.sessionID = sessionID
  }

  enum CodingKeys: String, CodingKey {
    case storyworldID = "storyworld_id"
    case playthroughID = "playthrough_id"
    case branchID = "branch_id"
    case sessionID = "session_id"
  }
}

public struct BranchDescriptor: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let playthroughID: UUID
  public let parentBranchID: UUID?
  public let forkedAtEventSequence: Int?
  public var title: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    playthroughID: UUID,
    parentBranchID: UUID? = nil,
    forkedAtEventSequence: Int? = nil,
    title: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.playthroughID = playthroughID
    self.parentBranchID = parentBranchID
    self.forkedAtEventSequence = forkedAtEventSequence
    self.title = title
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case playthroughID = "playthrough_id"
    case parentBranchID = "parent_branch_id"
    case forkedAtEventSequence = "forked_at_event_sequence"
    case title
    case createdAt = "created_at"
  }
}

public struct TurnCommit: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let address: SessionAddress
  public let sequence: Int
  public let narrative: String
  public let statePatch: Data
  public let committedAt: Date

  public init(
    id: UUID,
    address: SessionAddress,
    sequence: Int,
    narrative: String,
    statePatch: Data,
    committedAt: Date = Date()
  ) {
    self.id = id
    self.address = address
    self.sequence = sequence
    self.narrative = narrative
    self.statePatch = statePatch
    self.committedAt = committedAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case address
    case sequence
    case narrative
    case statePatch = "state_patch"
    case committedAt = "committed_at"
  }
}
