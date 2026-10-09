import CryptoKit
import Foundation
import StoryworldCore

public struct FactoryBakeInput: Sendable {
  public let jobID: UUID
  public let sourceContentHash: String
  public let sourceFingerprint: String
  public let proposals: [FactoryLoreProposal]
  public let decisions: [FactoryDecision]
  public let workspaceURL: URL
  public let playerTaste: PlayerTasteProfile

  public init(jobID: UUID, sourceContentHash: String, sourceFingerprint: String,
    proposals: [FactoryLoreProposal], decisions: [FactoryDecision], workspaceURL: URL,
    playerTaste: PlayerTasteProfile = .standard) {
    self.jobID = jobID
    self.sourceContentHash = sourceContentHash
    self.sourceFingerprint = sourceFingerprint
    self.proposals = proposals
    self.decisions = decisions
    self.workspaceURL = workspaceURL
    self.playerTaste = playerTaste
  }
}

public struct FactoryBakeTarget: Codable, Equatable, Sendable {
  public let proposalID: String
  public let decisionIDs: [UUID]
}

public struct FactoryBakeRewrite: Codable, Equatable, Sendable {
  public let proposalID: String
  public let content: String
  /// These IDs prove protocol coverage, not semantic correctness.
  public let decisionIDs: [UUID]
}

public struct FactoryBakeReport: Codable, Equatable, Sendable {
  public let sourceFingerprint: String
  public let executor: String
  public let targets: [FactoryBakeTarget]
  public let rewrites: [FactoryBakeRewrite]
  public let unresolvedDecisionIDs: [UUID]
  public let warnings: [String]

  public var isComplete: Bool { unresolvedDecisionIDs.isEmpty && retainedCount == 0 }
  public var retainedCount: Int { targets.count - rewrites.count }

  static func make(sourceFingerprint: String, executor: String, targets: [FactoryBakeTarget],
    rewrites: [FactoryBakeRewrite], decisions: [FactoryDecision], warnings: [String]) -> Self {
    let byID = Dictionary(rewrites.map { ($0.proposalID, $0) }, uniquingKeysWith: { a, _ in a })
    let unresolved = decisions.filter { decision in
      let affected = targets.filter { $0.decisionIDs.contains(decision.id) }
      return affected.isEmpty || affected.contains { byID[$0.proposalID]?.decisionIDs.contains(decision.id) != true }
    }.map(\.id).sorted { $0.uuidString < $1.uuidString }
    return .init(sourceFingerprint: sourceFingerprint, executor: executor, targets: targets,
      rewrites: rewrites.sorted { $0.proposalID < $1.proposalID }, unresolvedDecisionIDs: unresolved,
      warnings: ["已定向处理 \(rewrites.count) 条，\(targets.count - rewrites.count) 条保留原候选；\(unresolved.count) 个决策尚未完整应用，表达调整与改写语义请在发布前核对。"]
        + Array(Set(warnings)).sorted())
  }

  static func retained(sourceFingerprint: String, proposals: [FactoryLoreProposal],
    decisions: [FactoryDecision], reason: String, playerTaste: PlayerTasteProfile = .standard) -> Self {
    .make(sourceFingerprint: sourceFingerprint, executor: "unavailable",
      targets: FactoryBakePlanner.targets(proposals: proposals, decisions: decisions, playerTaste: playerTaste),
      rewrites: [], decisions: decisions, warnings: decisions.isEmpty && playerTaste.isDefault ? [] : [reason])
  }

  func applying(to proposals: [FactoryLoreProposal]) -> [FactoryLoreProposal] {
    let byID = Dictionary(rewrites.map { ($0.proposalID, $0.content) }, uniquingKeysWith: { a, _ in a })
    return proposals.map { original in
      var result = original
      if let content = byID[original.id] { result.content = content }
      return result
    }
  }

  func fingerprint() throws -> String {
    try FactoryBakeHash.value(self)
  }

  func validate(sourceFingerprint: String, proposals: [FactoryLoreProposal], decisions: [FactoryDecision],
    playerTaste: PlayerTasteProfile = .standard) throws {
    guard self.sourceFingerprint == sourceFingerprint,
      targets == FactoryBakePlanner.targets(proposals: proposals, decisions: decisions, playerTaste: playerTaste),
      Set(rewrites.map(\.proposalID)).count == rewrites.count else { throw FactoryBakeError.invalidReport }
    for rewrite in rewrites {
      guard let target = targets.first(where: { $0.proposalID == rewrite.proposalID }),
        rewrite.decisionIDs == target.decisionIDs,
        !rewrite.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        rewrite.content.count <= FactoryBakePlanner.maximumContentCharacters else {
        throw FactoryBakeError.invalidReport
      }
    }
    let verified = Self.make(sourceFingerprint: sourceFingerprint, executor: executor,
      targets: targets, rewrites: rewrites, decisions: decisions, warnings: [])
    guard unresolvedDecisionIDs == verified.unresolvedDecisionIDs else { throw FactoryBakeError.invalidReport }
  }

  /// Full answers remain in provenance. Unapplied decisions are visible,
  /// activated by their related titles rather than one giant always-on block.
  func fallbackEntries(decisions: [FactoryDecision], proposals: [FactoryLoreProposal]) -> [LoreEntry] {
    decisions.filter { unresolvedDecisionIDs.contains($0.id) }.map { decision in
      let ids = Set(targets.filter { $0.decisionIDs.contains(decision.id) }.map(\.proposalID))
      let keys = proposals.filter { ids.contains($0.id) }.flatMap { [$0.title] + $0.activationKeys }
      return LoreEntry(id: "factory-decision-" + decision.id.uuidString.lowercased(),
        title: "待核对决策 · " + String(decision.question.prefix(40)),
        content: "问题：\(decision.question)\n人工确认（尚未完整应用到相关设定）：\(decision.answer ?? decision.recommendation)",
        activationKeys: Array(Set(keys)).sorted(), alwaysActive: false, categoryID: nil)
    }
  }
}

enum FactoryBakeError: Error, LocalizedError {
  case invalidReport, invalidOutput, invalidBudget, oversizedInput, changedDuringGeneration
  var errorDescription: String? {
    switch self {
    case .invalidReport: "决策改写记录与当前输入不一致，请重新生成候选。"
    case .invalidOutput: "该块改写没有完整返回所需条目与决策编号。"
    case .invalidBudget: "模型窗口与输出上限不兼容，请调整模型设置。"
    case .oversizedInput: "该条目与必要决策超过模型预算，已保留原候选。"
    case .changedDuringGeneration: "生成期间输入或任务状态已变化，结果未用于候选。"
    }
  }
}

enum FactoryBakeHash {
  static func value<T: Encodable>(_ value: T) throws -> String {
    SHA256.hash(data: try StoryworldCoding.makeEncoder().encode(value))
      .map { String(format: "%02x", $0) }.joined()
  }
}
