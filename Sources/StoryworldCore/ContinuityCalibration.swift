import Foundation

/// Human-authored corrections are proposals first. They are not part of the model protocol.
public struct ContinuityCalibrationDraft: Codable, Equatable, Sendable {
  public var reason: String
  public var source: StoryAnchorEventRef
  public var quote: String
  public var changes: ContinuityDelta
  public var retractFactIDs: [String]
  public var confirmEntityIDs: [String]
  public var clearScene: Bool

  public init(reason: String, source: StoryAnchorEventRef, quote: String,
    changes: ContinuityDelta = .init(), retractFactIDs: [String] = [],
    confirmEntityIDs: [String] = [], clearScene: Bool = false) {
    self.reason = reason
    self.source = source
    self.quote = quote
    self.changes = changes
    self.retractFactIDs = retractFactIDs
    self.confirmEntityIDs = confirmEntityIDs
    self.clearScene = clearScene
  }
}

public struct ContinuityCalibrationReceipt: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let branchID: UUID
  public let afterEventSequence: Int
  public let reason: String
  public let source: ContinuityEvidence
}

public struct ContinuityCalibrationProposal: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let branchID: UUID
  public let expectedEventSequence: Int
  public let expectedStateHash: String
  public let expectedContinuityHash: String
  public let resultingContinuityHash: String
  public let draft: ContinuityCalibrationDraft
  public let preview: [String]
}

public enum ContinuityCalibrationDecision: String, Codable, Sendable { case accepted, rejected }

public struct ContinuityCalibrationReview: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { proposal.id }
  public let proposal: ContinuityCalibrationProposal
  public let decision: ContinuityCalibrationDecision?
}

public enum ContinuityCalibrationError: String, Error, Equatable, LocalizedError {
  case stale, alreadyDecided, conflict, missing, corruptLog, noChanges
  public var errorDescription: String? {
    switch self {
    case .stale: "提案所依据的回合或连续性记录已经变化，请重新核对并创建提案。"
    case .alreadyDecided: "这份校准提案已经作出决定，不能更改原决定；可另建提案。"
    case .conflict: "同一提案编号对应了不同内容，请刷新后重试。"
    case .missing: "未找到这份校准提案。"
    case .corruptLog: "校准日志不完整或已损坏，请保留原文件；不能继续生成或覆盖。"
    case .noChanges: "提案没有改变连续性记录。"
    }
  }
}

enum ContinuityCalibrationReducer {
  static func apply(id: UUID, branchID: UUID, afterEventSequence: Int,
    draft: ContinuityCalibrationDraft, to original: ContinuityLedger, narrative: String
  ) throws -> (ledger: ContinuityLedger, preview: [String]) {
    guard try JSONEncoder().encode(draft).count <= 32 * 1_024,
      !draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      draft.reason.count <= 500, draft.retractFactIDs.count <= 16,
      draft.confirmEntityIDs.count <= 16, (original.calibrations?.count ?? 0) < 1_000,
      Set(draft.retractFactIDs).count == draft.retractFactIDs.count,
      Set(draft.confirmEntityIDs).count == draft.confirmEntityIDs.count
    else { throw ContinuityError.limits }
    guard !draft.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      draft.quote.count <= 300, narrative.contains(draft.quote)
    else { throw ContinuityError.invalidEvidence }
    guard !(draft.clearScene && draft.changes.scene != nil) else { throw ContinuityError.invalidOperation }
    let evidence = ContinuityEvidence(event: draft.source, quote: draft.quote, calibrationID: id)
    var ledger = original
    var preview: [String] = []
    for factID in draft.retractFactIDs {
      guard var fact = ledger.facts[factID] else { throw ContinuityError.unknownFact }
      guard fact.status != .retracted else { throw ContinuityError.invalidLifecycle }
      fact.status = .retracted
      fact.evidence.append(evidence)
      if fact.evidence.count > 32 { fact.evidence.removeSubrange(1..<(fact.evidence.count - 31)) }
      ledger.facts[factID] = fact
      preview.append("撤回错误记录：" + fact.statement + "（保留原记录与依据）")
    }
    for entityID in draft.confirmEntityIDs {
      guard let entity = ledger.entities[entityID], entity.provisional else {
        throw ContinuityError.unknownEntity
      }
      ledger.entities[entityID] = .init(id: entity.id, name: entity.name, kind: entity.kind,
        provisional: false, source: evidence)
      preview.append("确认独立身份：" + entity.name + " [" + entity.id + "]；不与同名人物合并")
    }
    if draft.clearScene, ledger.scene != nil {
      ledger.scene = nil
      preview.append("清空当前场景记录；后续不再沿用原在场名单")
    }
    let delta = try ContinuityReducer.resolve(draft.changes, ledger: ledger,
      source: draft.source, narrative: narrative, contracts: [], calibrationID: id)
    ledger = try ContinuityReducer.apply(.init(schemaVersion: 1, status: .recorded,
      delta: delta, issue: nil, requestFingerprint: "player-calibration"), to: ledger, source: draft.source)
    for entity in delta.entities { preview.append("登记待确认身份：" + entity.name + " [" + entity.id + "]") }
    if let scene = delta.scene {
      let names = scene.presentEntityIDs.map { ledger.entities[$0]?.name ?? $0 }.joined(separator: "、")
      preview.append("场景改为：\(scene.location) · \(scene.time)；在场：\(names)")
    }
    for fact in delta.addedFacts {
      let names = fact.knownByEntityIDs.map { ledger.entities[$0]?.name ?? $0 }.joined(separator: "、")
      preview.append("新增记录：\(fact.statement)；明确知情：\(names.isEmpty ? "未记录" : names)")
    }
    for fact in delta.changedFacts {
      let names = fact.knownByEntityIDs.map { ledger.entities[$0]?.name ?? $0 }.joined(separator: "、")
      preview.append("更新记录：\(fact.statement)；状态：\(fact.status.rawValue)；明确知情：\(names)")
    }
    guard ledger != original else { throw ContinuityCalibrationError.noChanges }
    ledger.calibrations = (ledger.calibrations ?? []) + [
      .init(id: id, branchID: branchID, afterEventSequence: afterEventSequence,
        reason: draft.reason, source: evidence)
    ]
    try ContinuityReducer.validateLedger(ledger)
    return (ledger, preview)
  }
}

/// A separate append-only log avoids fake narrative turns and preserves turn statistics.
/// Accepted entries are interleaved with narrative replay using the revision captured by each turn.
struct ContinuityCalibrationLog {
  struct Entry: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case proposed, accepted, rejected }
    struct Body: Codable, Equatable, Sendable {
      let revision: Int
      let afterEventSequence: Int
      let action: Action
      let proposalID: UUID
      let proposal: ContinuityCalibrationProposal?
    }
    let body: Body
    let checksum: String
  }
  let url: URL
  private let maximumBytes = 16 * 1_024 * 1_024
  private var checkpointURL: URL { url.deletingPathExtension().appendingPathExtension("head.json") }
  private struct Checkpoint: Codable { let revision: Int; let checksum: String? }

  func read() throws -> [Entry] {
    let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    if !FileManager.default.fileExists(atPath: url.path), info?.isSymbolicLink != true,
      (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil {
      guard !FileManager.default.fileExists(atPath: checkpointURL.path),
        (try? FileManager.default.destinationOfSymbolicLink(atPath: checkpointURL.path)) == nil
      else { throw ContinuityCalibrationError.corruptLog }
      return []
    }
    guard info?.isRegularFile == true, info?.isSymbolicLink != true,
      (info?.fileSize ?? Int.max) <= maximumBytes else { throw ContinuityCalibrationError.corruptLog }
    let bytes = try Data(contentsOf: url)
    guard bytes.isEmpty || bytes.last == 10 else { throw ContinuityCalibrationError.corruptLog }
    let lines = bytes.split(separator: 10, omittingEmptySubsequences: false).dropLast()
    guard lines.count <= 2_000 else { throw ContinuityCalibrationError.corruptLog }
    var result: [Entry] = []
    var proposals: [UUID: ContinuityCalibrationProposal] = [:]
    var decisions = Set<UUID>()
    for line in lines {
      guard let entry = try? StoryworldCoding.makeDecoder().decode(Entry.self, from: Data(line)),
        entry.body.revision == result.count + 1,
        entry.body.afterEventSequence >= (result.last?.body.afterEventSequence ?? 0),
        entry.checksum == (try checksum(entry.body, previous: result.last?.checksum))
      else { throw ContinuityCalibrationError.corruptLog }
      switch entry.body.action {
      case .proposed:
        guard let proposal = entry.body.proposal, proposal.id == entry.body.proposalID,
          proposal.expectedEventSequence == entry.body.afterEventSequence,
          proposals[proposal.id] == nil else { throw ContinuityCalibrationError.corruptLog }
        proposals[proposal.id] = proposal
      case .accepted, .rejected:
        guard entry.body.proposal == nil, proposals[entry.body.proposalID] != nil,
          decisions.insert(entry.body.proposalID).inserted
        else { throw ContinuityCalibrationError.corruptLog }
      }
      result.append(entry)
    }
    let checkpointInfo = try? checkpointURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    if result.isEmpty, !FileManager.default.fileExists(atPath: checkpointURL.path),
      checkpointInfo?.isSymbolicLink != true,
      (try? FileManager.default.destinationOfSymbolicLink(atPath: checkpointURL.path)) == nil {
      return []
    }
    guard checkpointInfo?.isRegularFile == true, checkpointInfo?.isSymbolicLink != true,
      (checkpointInfo?.fileSize ?? Int.max) <= 1_024,
      let checkpoint = try? StoryworldCoding.makeDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL)),
      checkpoint.revision >= 0, checkpoint.revision <= result.count,
      checkpoint.checksum == (checkpoint.revision == 0 ? nil : result[checkpoint.revision - 1].checksum)
    else { throw ContinuityCalibrationError.corruptLog }
    // A complete append may precede its checkpoint if the process stopped after fsync.
    // The validated log remains authority; a missing/truncated committed prefix fails closed.
    return result
  }

  func append(action: Entry.Action, id: UUID, proposal: ContinuityCalibrationProposal? = nil,
    afterEventSequence: Int, existing: [Entry]) throws {
    guard existing.count < 2_000 else { throw ContinuityError.limits }
    let body = Entry.Body(revision: existing.count + 1, afterEventSequence: afterEventSequence,
      action: action, proposalID: id, proposal: proposal)
    let entry = Entry(body: body, checksum: try checksum(body, previous: existing.last?.checksum))
    let encoder = StoryworldCoding.makeEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = try encoder.encode(entry)
    bytes.append(10)
    let info = try? url.resourceValues(forKeys: [.fileSizeKey])
    guard (info?.fileSize ?? 0) + bytes.count <= maximumBytes else { throw ContinuityError.limits }
    if !FileManager.default.fileExists(atPath: url.path) {
      guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
        throw ContinuityCalibrationError.corruptLog
      }
    }
    if existing.isEmpty {
      try StoryworldCoding.makeEncoder().encode(Checkpoint(revision: 0, checksum: nil))
        .write(to: checkpointURL, options: .atomic)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
    try StoryworldCoding.makeEncoder().encode(Checkpoint(revision: body.revision, checksum: entry.checksum))
      .write(to: checkpointURL, options: .atomic)
  }

  static func reviews(_ entries: [Entry]) -> [ContinuityCalibrationReview] {
    let decisions: [UUID: ContinuityCalibrationDecision] = Dictionary(uniqueKeysWithValues:
      entries.compactMap { entry in
        guard entry.body.action != .proposed else { return nil }
        return (entry.body.proposalID, entry.body.action == .accepted ? .accepted : .rejected)
      })
    return entries.compactMap { $0.body.proposal }.map {
      .init(proposal: $0, decision: decisions[$0.id])
    }
  }

  private func checksum(_ body: Entry.Body, previous: String?) throws -> String {
    var bytes = Data((previous ?? "continuity-calibration-v1").utf8)
    bytes.append(try StoryworldCoding.makeEncoder().encode(body))
    return ContinuityLedger.digest(bytes)
  }
}
