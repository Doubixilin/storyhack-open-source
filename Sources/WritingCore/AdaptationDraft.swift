import Foundation

public struct AdaptationDraftTarget: Codable, Equatable, Hashable, Sendable {
  public let chapterID: String
  public let anchorID: String?
  public init(chapterID: String, anchorID: String? = nil) { self.chapterID = chapterID; self.anchorID = anchorID }
  public var key: String { (anchorID == nil ? "chapter:" : "anchor:") + (anchorID ?? chapterID) }
  enum CodingKeys: String, CodingKey { case chapterID = "chapter_id", anchorID = "anchor_id" }
}

/// Neutral expression combinations, kept separate from publishable prose.
public struct AdaptationRecipe: Codable, Equatable, Sendable {
  public var trigger: String
  public var setting: String
  public var technique: String
  public init(trigger: String, setting: String, technique: String) {
    self.trigger = trigger; self.setting = setting; self.technique = technique
  }
  public func key() throws -> String {
    let parts = [trigger, setting, technique].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 120 }) else { throw AdaptationError.invalidDraft }
    return try AdaptationCoding.fingerprint(parts)
  }
}

public struct AdaptationDraftContent: Codable, Equatable, Sendable {
  public var title: String
  public var body: String
  public var recap: String
  /// Model self-report, never an author approval or a verified review.
  public var reviewLine: String
  public var recipe: AdaptationRecipe
  public init(title: String, body: String, recap: String, reviewLine: String, recipe: AdaptationRecipe) {
    self.title = title; self.body = body; self.recap = recap; self.reviewLine = reviewLine; self.recipe = recipe
  }
  public func validated() throws -> Self {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 40_000,
      !recap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, recap.count <= 80,
      !reviewLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reviewLine.count <= 2_000
    else { throw AdaptationError.invalidDraft }
    _ = try recipe.key()
    return self
  }
  enum CodingKeys: String, CodingKey { case title, body, recap, recipe, reviewLine = "review_line" }
}

public struct AdaptationDraftDependency: Codable, Equatable, Sendable {
  public let id: UUID
  public let contentHash: String
  enum CodingKeys: String, CodingKey { case id, contentHash = "content_hash" }
}

public struct AdaptationDraftContext: Codable, Equatable, Sendable {
  public let basis: AdaptationGenerationBasis
  public let target: AdaptationDraftTarget
  public let anchor: AdaptationAnchor?
  public let anchorReview: AdaptationAnchorReview?
  public let predecessors: [AdaptationDraftDependency]
  public var action: AdaptationAnchorAction { anchorReview?.generationAction ?? .rewrite }
  enum CodingKeys: String, CodingKey { case basis, target, anchor, predecessors, anchorReview = "anchor_review" }
}

public struct AdaptationDraft: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let parentID: UUID?
  public let context: AdaptationDraftContext
  public let generatorFingerprint: String
  public let content: AdaptationDraftContent
  public let contentHash: String
  public let warnings: [String]
  public let createdAt: Date
  public func fingerprint() throws -> String { try AdaptationCoding.fingerprint(self) }
  enum CodingKeys: String, CodingKey {
    case id, context, content, warnings, parentID = "parent_id", generatorFingerprint = "generator_fingerprint"
    case contentHash = "content_hash", createdAt = "created_at"
  }
}

public struct AdaptationDraftDecision: Codable, Equatable, Sendable {
  public let draftID: UUID
  public let draftFingerprint: String
  public let action: ApprovalAction
  public let note: String
  public let acknowledgedWarnings: Bool
  public let createdAt: Date
  enum CodingKeys: String, CodingKey {
    case action, note, draftID = "draft_id", draftFingerprint = "draft_fingerprint"
    case acknowledgedWarnings = "acknowledged_warnings", createdAt = "created_at"
  }
}

public struct AdaptationDraftView: Sendable {
  public let draft: AdaptationDraft
  public let decision: AdaptationDraftDecision?
  public let isStale: Bool
}

public struct AdaptationDraftSnapshot: Sendable {
  public let revision: UUID?
  public let current: [AdaptationDraftView]
}

struct AdaptationDraftIndex: Codable {
  var revision: UUID?
  var heads: [String: UUID] = [:]
  // The pointer ensures deleting an approval file cannot turn decided text
  // back into an undecided candidate that can be approved again silently.
  var decisions: [String: AdaptationDraftDecision] = [:]
}
