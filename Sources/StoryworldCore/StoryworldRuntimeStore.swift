import CryptoKit
import Foundation

public enum StoryworldRuntimeError: Error, Equatable, LocalizedError {
  case playthroughNotFound(UUID)
  case branchNotFound(UUID)
  case sessionNotFound(UUID)
  case saveNotFound(UUID)
  case addressMismatch
  case malformedStatePatch
  case statePatchTooLarge(Int)
  case statePatchTooComplex
  case corruptedEventLog
  case stateAheadOfEventLog
  case baseStateUnavailable
  case eventSequenceOutOfRange(Int)
  case staleTurnBase(
    currentEventSequence: Int,
    currentStateHash: String
  )
  case turnPayloadConflict(UUID)

  public var errorDescription: String? {
    switch self {
    case .playthroughNotFound(let id):
      "没有找到游玩线：\(id.uuidString)"
    case .branchNotFound(let id):
      "没有找到分支：\(id.uuidString)"
    case .sessionNotFound(let id):
      "没有找到会话：\(id.uuidString)"
    case .saveNotFound(let id):
      "没有找到存档：\(id.uuidString)"
    case .addressMismatch:
      "会话地址与 Storyworld、游玩线或分支不一致"
    case .malformedStatePatch:
      "状态补丁必须是 JSON 对象"
    case .statePatchTooLarge(let maximum):
      "状态补丁超过 \(maximum) 字节限制"
    case .statePatchTooComplex:
      "状态补丁层级或字段数量超过安全限制"
    case .corruptedEventLog:
      "事件日志损坏或序号不连续"
    case .stateAheadOfEventLog:
      "状态快照领先于事件日志，无法安全恢复"
    case .baseStateUnavailable:
      "该分支创建于旧版本，缺少初始状态，只能从最新位置分叉或存档"
    case .eventSequenceOutOfRange(let sequence):
      "事件序号 \(sequence) 超出分支范围"
    case .staleTurnBase:
      "剧情已在另一端更新，请刷新后重试"
    case .turnPayloadConflict(let turnID):
      "回合 \(turnID.uuidString) 已存在，但提交内容不一致"
    }
  }
}

/// Durable runtime for one managed `.storyworld` package. The append-only turn
/// log is authoritative; a state snapshot that lags after a crash is replayed
/// from the log before any read or write continues.
public actor StoryworldRuntimeStore {
  public static let maximumStatePatchByteCount = 256 * 1_024
  public static let maximumStatePatchDepth = 32
  public static let maximumStatePatchValueCount = 10_000

  private let packageURL: URL
  private let fileManager: FileManager
  private let validator: StoryworldPackageValidator

  public init(packageURL: URL, fileManager: FileManager = .default) {
    self.packageURL = packageURL
    self.fileManager = fileManager
    validator = StoryworldPackageValidator(fileManager: fileManager)
  }

  func updateGeneratedPackage(from candidate: URL, libraryRoot: URL) throws {
    try GeneratedPackageUpdater.update(candidate: candidate, live: packageURL, libraryRoot: libraryRoot)
  }

  func saveCharacterContracts(_ file: CharacterContractFile, libraryRoot: URL,
    expectedFingerprint: String?) throws {
    try CharacterContractStorage.save(file, at: packageURL, libraryRoot: libraryRoot,
      expectedFingerprint: expectedFingerprint)
  }

  public func createPlaythrough(
    title: String,
    initialState: [String: JSONValue] = [:],
    directiveProfile: DirectiveProfile = .green
  ) throws -> PlaythroughContext {
    _ = try directiveProfile.validated()
    let manifest = try validator.validate(at: packageURL)
    let canon = try CanonAssets.read(at: packageURL)
    try ensureRuntimeDirectories()
    let playthroughID = UUID()
    let branchID = UUID()
    let sessionID = UUID()
    let now = Date()
    let address = SessionAddress(
      storyworldID: manifest.storyworldID,
      playthroughID: playthroughID,
      branchID: branchID,
      sessionID: sessionID
    )
    let state = try makeState(values: initialState, sequence: 0, updatedAt: now)
    let branch = RuntimeBranchDescriptor(
      branch: BranchDescriptor(
        id: branchID,
        playthroughID: playthroughID,
        title: StoryPlayMode.canon.branchTitle,
        createdAt: now
      ),
      sessionID: sessionID,
      baseStateHash: state.stateHash,
      baseContinuityHash: try ContinuityLedger().fingerprint()
    )
    let session = StorySessionDescriptor(address: address, createdAt: now, updatedAt: now)
    let playthrough = PlaythroughDescriptor(
      id: playthroughID,
      storyworldID: manifest.storyworldID,
      title: normalizedTitle(title, fallback: "新的游玩线"),
      createdAt: now,
      updatedAt: now,
      activeBranchID: branchID,
      activeSessionID: sessionID,
      canonBinding: CanonBinding(assets: canon),
      directive: directiveProfile == .green ? nil : PlaythroughDirective(profile: directiveProfile)
    )

    let stagingURL = playthroughsURL.appendingPathComponent(
      ".staging-\(UUID().uuidString)",
      isDirectory: true
    )
    let finalPlaythroughURL = playthroughURL(playthroughID)
    let finalSessionURL = sessionURL(sessionID)
    do {
      try writePlaythrough(
        playthrough,
        branch: branch,
        state: state,
        to: stagingURL
      )
      try fileManager.moveItem(at: stagingURL, to: finalPlaythroughURL)
      try fileManager.createDirectory(at: finalSessionURL, withIntermediateDirectories: true)
      try write(session, to: finalSessionURL.appendingPathComponent("metadata.json"))
      return PlaythroughContext(
        playthrough: playthrough,
        branch: branch,
        session: session
      )
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      try? fileManager.removeItem(at: finalPlaythroughURL)
      try? fileManager.removeItem(at: finalSessionURL)
      throw error
    }
  }

  public func listPlaythroughs() throws -> [PlaythroughDescriptor] {
    _ = try validator.validate(at: packageURL)
    try ensureRuntimeDirectories()
    return try fileManager.contentsOfDirectory(
      at: playthroughsURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
      let metadataURL = url.appendingPathComponent("metadata.json")
      guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
      return try read(PlaythroughDescriptor.self, from: metadataURL)
    }.sorted { $0.updatedAt > $1.updatedAt }
  }

  public func listBranches(playthroughID: UUID) throws -> [RuntimeBranchDescriptor] {
    let directory = branchesURL(playthroughID)
    guard fileManager.fileExists(atPath: directory.path) else {
      throw StoryworldRuntimeError.playthroughNotFound(playthroughID)
    }
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
      let metadataURL = url.appendingPathComponent("metadata.json")
      guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
      return try read(RuntimeBranchDescriptor.self, from: metadataURL)
    }.sorted { $0.branch.createdAt < $1.branch.createdAt }
  }

  /// 读取包内可选的原著节拍线；缺失返回 nil，损坏同样按缺失处理。
  public func loadTimeline() throws -> StoryTimeline? {
    _ = try validator.validate(at: packageURL)
    let url = packageURL.appendingPathComponent(StoryworldPackageLayout.timeline)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
    return try? StoryworldCoding.makeDecoder().decode(StoryTimeline.self, from: data)
  }

  /// 组装一条游玩线的分支图。事件日志是权威数据源，分支头与回合节点
  /// 都直接读 events.jsonl，不做状态重放。
  public func loadBranchGraph(playthroughID: UUID) throws -> StoryBranchGraph {
    let manifest = try validator.validate(at: packageURL)
    let playthrough = try loadPlaythrough(playthroughID)
    let branches = try listBranches(playthroughID: playthroughID)
    var headSequences: [UUID: Int] = [:]
    var savesByBranch: [UUID: [StorySave]] = [:]
    var turnsByBranch: [UUID: [CommittedStoryTurn]] = [:]
    for branch in branches {
      let address = SessionAddress(
        storyworldID: manifest.storyworldID,
        playthroughID: playthroughID,
        branchID: branch.id,
        sessionID: branch.sessionID
      )
      let events = try loadEvents(address: address)
      headSequences[branch.id] = events.count
      turnsByBranch[branch.id] = events
      savesByBranch[branch.id] = try listSaves(address: address)
    }
    return StoryBranchGraph(
      playthrough: playthrough,
      branches: branches,
      headSequences: headSequences,
      saves: savesByBranch,
      turns: turnsByBranch,
      timeline: try loadTimeline()
    )
  }

  public func loadActive(playthroughID: UUID) throws -> StorySessionSnapshot {
    let playthrough = try loadPlaythrough(playthroughID)
    let address = SessionAddress(
      storyworldID: playthrough.storyworldID,
      playthroughID: playthrough.id,
      branchID: playthrough.activeBranchID,
      sessionID: playthrough.activeSessionID
    )
    return try load(address: address)
  }

  /// 删除整条游玩线（反馈 #2）：移除其目录及所有分支的会话目录，
  /// 世界书设定本身不受影响。调用方负责在删除后重新选择或回到概览。
  public func deletePlaythrough(playthroughID: UUID) throws {
    let directory = playthroughURL(playthroughID)
    guard fileManager.fileExists(atPath: directory.path) else {
      throw StoryworldRuntimeError.playthroughNotFound(playthroughID)
    }
    for branch in (try? listBranches(playthroughID: playthroughID)) ?? [] {
      let sessionDirectory = sessionURL(branch.sessionID)
      if fileManager.fileExists(atPath: sessionDirectory.path) {
        try fileManager.removeItem(at: sessionDirectory)
      }
    }
    try fileManager.removeItem(at: directory)
  }

  public func load(address: SessionAddress) throws -> StorySessionSnapshot {
    let context = try loadContext(address: address)
    let reconciled = try reconcileState(address: address)
    let effectiveTurns = try projectedTurns(address: address, own: reconciled.events)
    let recap = loadRecap(address: address).flatMap {
      $0.throughEffectiveTurnCount <= effectiveTurns.count
        && $0.lastAttemptedEffectiveTurnCount <= effectiveTurns.count ? $0 : nil
    }
    let continuity: ContinuitySnapshot?
    let continuityNotice: String?
    do {
      continuity = try continuitySnapshot(address: address, ownEvents: reconciled.events)
      continuityNotice = nil
    } catch {
      continuity = nil
      continuityNotice = error.localizedDescription
    }
    return StorySessionSnapshot(
      context: context,
      state: reconciled.state,
      turns: reconciled.events,
      effectiveTurns: effectiveTurns,
      recap: recap,
      saves: try listSaves(address: address),
      canonStatus: try canonStatus(address: address),
      anchorState: anchorStore(address).state(visible: Set(effectiveTurns.map(StoryAnchorEventRef.init))),
      continuity: continuity, continuityNotice: continuityNotice,
      calibrationReviews: (try? calibrationReviews(address: address)) ?? []
    )
  }

  public func continuitySnapshot(address: SessionAddress, atEventSequence sequence: Int? = nil,
    throughCalibrationRevision revision: Int? = nil) throws -> ContinuitySnapshot {
    _ = try loadContext(address: address)
    return try continuitySnapshot(address: address,
      ownEvents: reconcileState(address: address).events, atEventSequence: sequence,
      throughCalibrationRevision: revision)
  }

  /// Replaying is intentionally independent of continuity.json. This first version
  /// prefers one clear authority to a second cache-repair algorithm.
  private func continuitySnapshot(address: SessionAddress, ownEvents: [CommittedStoryTurn],
    atEventSequence sequence: Int? = nil, throughCalibrationRevision revision: Int? = nil) throws -> ContinuitySnapshot {
    let target = sequence ?? ownEvents.count
    guard target >= 0, target <= ownEvents.count else {
      throw StoryworldRuntimeError.eventSequenceOutOfRange(target)
    }
    let branch = try loadBranch(playthroughID: address.playthroughID, branchID: address.branchID)
    var ledger: ContinuityLedger
    let events: [CommittedStoryTurn]
    if let expected = branch.baseContinuityHash {
      let url = branchURL(address).appendingPathComponent("base_continuity.json")
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true,
        (values?.fileSize ?? Int.max) <= 64 * 1_024 * 1_024,
        let base = try? read(ContinuitySnapshot.self, from: url), base.lastEventSequence == 0,
        base.hash == expected, try base.ledger.fingerprint() == expected
      else { throw ContinuityError.corruptHistory }
      ledger = base.ledger
      events = Array(ownEvents.prefix(target))
    } else {
      // Old branches have no trustworthy baseline. Project their actual ancestor
      // events and keep missing coverage explicit; never infer from recap or prose.
      ledger = .init()
      events = try projectedTurns(address: address, own: Array(ownEvents.prefix(target)))
    }
    try ContinuityReducer.validateLedger(ledger)
    let entries = try calibrationLog(address).read()
    let cutoff = revision ?? entries.last(where: { $0.body.afterEventSequence <= target })?.body.revision ?? 0
    guard cutoff >= 0, cutoff <= entries.count,
      entries.last?.body.afterEventSequence ?? 0 <= ownEvents.count
    else { throw ContinuityCalibrationError.corruptLog }
    let proposals = Dictionary(uniqueKeysWithValues: entries.compactMap { $0.body.proposal }.map { ($0.id, $0) })
    let history = try projectedTurns(address: address, own: ownEvents)
    var appliedRevision = 0
    func applyCalibrations(through limit: Int, at head: Int) throws {
      guard limit >= appliedRevision, limit <= cutoff else { throw ContinuityCalibrationError.corruptLog }
      for entry in entries[appliedRevision..<limit] {
        guard entry.body.afterEventSequence <= head else { throw ContinuityCalibrationError.corruptLog }
        if entry.body.action == .accepted {
          guard entry.body.afterEventSequence == head,
            let proposal = proposals[entry.body.proposalID], proposal.branchID == address.branchID,
            proposal.expectedEventSequence == head,
            proposal.expectedContinuityHash == (try ledger.fingerprint()),
            let source = history.first(where: { StoryAnchorEventRef($0) == proposal.draft.source }),
            source.address.branchID != address.branchID || source.sequence <= head
          else { throw ContinuityCalibrationError.corruptLog }
          let result = try ContinuityCalibrationReducer.apply(id: proposal.id,
            branchID: proposal.branchID, afterEventSequence: head, draft: proposal.draft,
            to: ledger, narrative: source.narrative)
          guard try result.ledger.fingerprint() == proposal.resultingContinuityHash,
            result.preview == proposal.preview else { throw ContinuityCalibrationError.corruptLog }
          ledger = result.ledger
        }
      }
      appliedRevision = limit
    }
    for event in events {
      if event.address.branchID == address.branchID {
        try applyCalibrations(through: event.continuityCalibrationRevision ?? 0, at: event.sequence - 1)
      } else if event.continuityCalibrationRevision != nil {
        throw ContinuityCalibrationError.corruptLog
      }
      if let expected = event.basedOnContinuityHash, try ledger.fingerprint() != expected {
        throw ContinuityError.corruptHistory
      }
      ledger = try ContinuityReducer.apply(event.continuityUpdate, to: ledger, source: .init(event))
      if let expected = event.resultingContinuityHash, try ledger.fingerprint() != expected {
        throw ContinuityError.corruptHistory
      }
    }
    try applyCalibrations(through: cutoff, at: target)
    return try ContinuitySnapshot(lastEventSequence: target, ledger: ledger, calibrationRevision: cutoff)
  }

  private func calibrationLog(_ address: SessionAddress) -> ContinuityCalibrationLog {
    .init(url: branchURL(address).appendingPathComponent("continuity_calibrations.jsonl"))
  }

  public func calibrationReviews(address: SessionAddress) throws -> [ContinuityCalibrationReview] {
    _ = try loadContext(address: address)
    return ContinuityCalibrationLog.reviews(try calibrationLog(address).read())
  }

  @discardableResult
  public func proposeContinuityCalibration(address: SessionAddress, id: UUID,
    draft: ContinuityCalibrationDraft, expectedEventSequence: Int,
    expectedStateHash: String, expectedContinuityHash: String
  ) throws -> ContinuityCalibrationProposal {
    _ = try loadContext(address: address)
    let log = calibrationLog(address)
    let entries = try log.read()
    if let existing = entries.compactMap({ $0.body.proposal }).first(where: { $0.id == id }) {
      guard existing.draft == draft, existing.expectedEventSequence == expectedEventSequence,
        existing.expectedStateHash == expectedStateHash,
        existing.expectedContinuityHash == expectedContinuityHash
      else { throw ContinuityCalibrationError.conflict }
      return existing
    }
    let reconciled = try reconcileState(address: address)
    let base = try continuitySnapshot(address: address, ownEvents: reconciled.events)
    guard reconciled.events.count == expectedEventSequence,
      reconciled.state.stateHash == expectedStateHash, base.hash == expectedContinuityHash
    else { throw ContinuityCalibrationError.stale }
    let history = try projectedTurns(address: address, own: reconciled.events)
    guard let source = history.first(where: { StoryAnchorEventRef($0) == draft.source })
    else { throw ContinuityError.invalidEvidence }
    let result = try ContinuityCalibrationReducer.apply(id: id, branchID: address.branchID,
      afterEventSequence: expectedEventSequence, draft: draft, to: base.ledger, narrative: source.narrative)
    let proposal = ContinuityCalibrationProposal(id: id, branchID: address.branchID,
      expectedEventSequence: expectedEventSequence, expectedStateHash: expectedStateHash,
      expectedContinuityHash: expectedContinuityHash,
      resultingContinuityHash: try result.ledger.fingerprint(), draft: draft, preview: result.preview)
    try log.append(action: .proposed, id: id, proposal: proposal,
      afterEventSequence: reconciled.events.count, existing: entries)
    return proposal
  }

  public func decideContinuityCalibration(address: SessionAddress, id: UUID,
    decision: ContinuityCalibrationDecision
  ) throws {
    _ = try loadContext(address: address)
    let log = calibrationLog(address)
    let entries = try log.read()
    guard let review = ContinuityCalibrationLog.reviews(entries).first(where: { $0.id == id })
    else { throw ContinuityCalibrationError.missing }
    if let existing = review.decision {
      guard existing == decision else { throw ContinuityCalibrationError.alreadyDecided }
      return
    }
    let reconciled = try reconcileState(address: address)
    if decision == .accepted {
      let base = try continuitySnapshot(address: address, ownEvents: reconciled.events)
      let proposal = review.proposal
      guard proposal.branchID == address.branchID,
        proposal.expectedEventSequence == reconciled.events.count,
        proposal.expectedStateHash == reconciled.state.stateHash,
        proposal.expectedContinuityHash == base.hash
      else { throw ContinuityCalibrationError.stale }
      let history = try projectedTurns(address: address, own: reconciled.events)
      guard let source = history.first(where: { StoryAnchorEventRef($0) == proposal.draft.source })
      else { throw ContinuityError.invalidEvidence }
      let result = try ContinuityCalibrationReducer.apply(id: proposal.id, branchID: address.branchID,
        afterEventSequence: reconciled.events.count, draft: proposal.draft,
        to: base.ledger, narrative: source.narrative)
      guard try result.ledger.fingerprint() == proposal.resultingContinuityHash,
        result.preview == proposal.preview else { throw ContinuityCalibrationError.corruptLog }
    }
    try log.append(action: decision == .accepted ? .accepted : .rejected, id: id,
      afterEventSequence: reconciled.events.count, existing: entries)
  }

  /// 读取可删除的前情缓存。缺失、损坏或字段不自洽时均按无摘要处理，
  /// 不让增强层阻断主回合。
  public func loadRecap(address: SessionAddress) -> StoryRecap? {
    guard let recap = try? read(StoryRecap.self, from: recapURL(address)),
      recap.schemaVersion == StoryRecap.currentSchemaVersion,
      recap.throughEffectiveTurnCount >= 0,
      recap.lastAttemptedEffectiveTurnCount >= recap.throughEffectiveTurnCount,
      recap.narrative?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
    else { return nil }
    return recap
  }

  /// 写入运行时摘要缓存。调用方只提交由有效历史生成的投影回合数量。
  public func saveRecap(_ recap: StoryRecap, address: SessionAddress) throws {
    _ = try loadContext(address: address)
    guard recap.schemaVersion == StoryRecap.currentSchemaVersion,
      recap.throughEffectiveTurnCount >= 0,
      recap.lastAttemptedEffectiveTurnCount >= recap.throughEffectiveTurnCount,
      recap.narrative?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
    else { return }
    try write(recap, to: recapURL(address))
  }

  /// 结局报告是当前分支的旁路 sidecar；缺失或损坏时按尚未生成处理。
  public func loadEndingReport(address: SessionAddress) throws -> StoryEndingReport? {
    _ = try loadContext(address: address)
    guard let report = try? read(StoryEndingReport.self, from: endingReportURL(address)),
      report.schemaVersion == StoryEndingReport.currentSchemaVersion,
      report.generatedAtEffectiveTurnCount >= 0,
      !report.verdict.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return report
  }

  public func saveEndingReport(_ report: StoryEndingReport, address: SessionAddress) throws {
    _ = try loadContext(address: address)
    guard report.schemaVersion == StoryEndingReport.currentSchemaVersion,
      report.generatedAtEffectiveTurnCount >= 0,
      !report.verdict.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    try write(report, to: endingReportURL(address))
  }

  @discardableResult
  public func commitTurn(
    address: SessionAddress,
    turnID: UUID,
    userMessage: String,
    narrative: String,
    choices: [String]? = nil,
    statePatchData: Data = Data("{}".utf8),
    beatID: String? = nil,
    continuityInput: ContinuityInput? = nil
  ) throws -> CommittedStoryTurn {
    _ = try loadContext(address: address)
    let head = try reconcileState(address: address).state
    return try commitTurn(
      address: address,
      turnID: turnID,
      userMessage: userMessage,
      narrative: narrative,
      choices: choices,
      statePatchData: statePatchData,
      beatID: beatID,
      expectedEventSequence: head.lastEventSequence,
      expectedStateHash: head.stateHash,
      continuityInput: continuityInput,
      expectedContinuityHash: try continuitySnapshot(address: address).hash
    )
  }

  @discardableResult
  public func commitTurn(
    address: SessionAddress,
    turnID: UUID,
    userMessage: String,
    narrative: String,
    choices: [String]? = nil,
    statePatchData: Data = Data("{}".utf8),
    beatID: String? = nil,
    expectedEventSequence: Int,
    expectedStateHash: String,
    expectedCanon: CanonTurnToken? = nil,
    continuityInput: ContinuityInput? = nil,
    expectedContinuityHash: String? = nil,
    expectedDirective: DirectiveTurnToken? = nil
  ) throws -> CommittedStoryTurn {
    _ = try loadContext(address: address)
    var reconciled = try reconcileState(address: address)
    let fingerprint = try payloadFingerprint(
      turnID: turnID,
      userMessage: userMessage,
      narrative: narrative,
      statePatchData: statePatchData,
      continuityRequestFingerprint: continuityInput?.fingerprint
    )
    if let existing = reconciled.events.first(where: { $0.turnID == turnID }) {
      let existingFingerprint = try existing.payloadFingerprint
        ?? legacyPayloadFingerprint(for: existing)
      let candidateFingerprint: String
      if existing.payloadFingerprint == nil,
        let patch = try? decodeStatePatch(statePatchData)
      {
        candidateFingerprint = try payloadFingerprint(
          turnID: turnID,
          userMessage: userMessage,
          narrative: narrative,
          statePatchData: canonicalStatePatchData(patch),
          continuityRequestFingerprint: continuityInput?.fingerprint
        )
      } else {
        candidateFingerprint = fingerprint
      }
      guard existingFingerprint == candidateFingerprint else {
        throw StoryworldRuntimeError.turnPayloadConflict(turnID)
      }
      return existing
    }
    if expectedEventSequence != reconciled.events.count
      || expectedStateHash != reconciled.state.stateHash
    {
      throw StoryworldRuntimeError.staleTurnBase(
        currentEventSequence: reconciled.events.count,
        currentStateHash: reconciled.state.stateHash
      )
    }
    if let expectedCanon {
      let current = try loadPlaythrough(address.playthroughID).canonBinding
      guard expectedCanon.address == address, current?.id == expectedCanon.bindingID,
        current?.fingerprints == expectedCanon.fingerprints,
        let assets = try? CanonAssets.read(at: packageURL),
        assets.fingerprints == expectedCanon.fingerprints
      else { throw CanonBindingError.changedDuringTurn }
    }
    if let expectedDirective {
      guard expectedDirective.address == address,
        try loadPlaythrough(address.playthroughID).directive == expectedDirective.selection else {
        throw DirectiveProfileError.changedDuringTurn
      }
    }
    let continuityBase = try continuitySnapshot(address: address, ownEvents: reconciled.events)
    if let expectedContinuityHash, expectedContinuityHash != continuityBase.hash {
      throw ContinuityError.staleBase
    }
    if continuityInput != nil && expectedContinuityHash == nil { throw ContinuityError.staleBase }
    let source = StoryAnchorEventRef(branchID: address.branchID,
      sequence: reconciled.events.count + 1, turnID: turnID)
    let continuityUpdate = try continuityInput.map { input in
      let assets = try CanonAssets.read(at: packageURL)
      return ContinuityReducer.prepare(input: input, ledger: continuityBase.ledger,
        source: source, narrative: narrative, contracts: assets.characterContracts?.contracts ?? [])
    }
    let ledger = try ContinuityReducer.apply(continuityUpdate, to: continuityBase.ledger, source: source)
    let continuity = try ContinuitySnapshot(lastEventSequence: source.sequence, ledger: ledger)
    var patch = try decodeStatePatch(statePatchData)
    patch.removeValue(forKey: "continuity")
    let newValues = merge(patch: patch, into: reconciled.state.values)
    let newHash = try hashState(newValues)
    let event = CommittedStoryTurn(
      turnID: turnID,
      address: address,
      sequence: reconciled.events.count + 1,
      userMessage: userMessage,
      narrative: narrative,
      choices: choices,
      statePatch: patch,
      resultingStateHash: newHash,
      payloadFingerprint: fingerprint,
      beatID: beatID,
      canonBindingID: expectedCanon?.bindingID,
      continuityUpdate: continuityUpdate,
      basedOnContinuityHash: continuityBase.hash,
      resultingContinuityHash: continuity.hash,
      continuityCalibrationRevision: continuityBase.calibrationRevision
    )

    try append(event: event, to: eventsURL(address))
    reconciled.state = BranchStateSnapshot(
      lastEventSequence: event.sequence,
      values: newValues,
      stateHash: newHash,
      updatedAt: event.committedAt
    )
    try write(reconciled.state, to: stateURL(address))
    try write(continuity, to: branchURL(address).appendingPathComponent("continuity.json"))
    try touchContext(address: address, at: event.committedAt)
    return event
  }

  /// 回放得到指定事件处的状态。nil 表示最新位置；回放历史事件依赖
  /// base_state.json，旧版本创建且已有事件的分支缺失该文件时会抛出
  /// baseStateUnavailable。
  public func stateSnapshot(
    address: SessionAddress,
    atEventSequence sequence: Int? = nil
  ) throws -> BranchStateSnapshot {
    _ = try loadContext(address: address)
    let reconciled = try reconcileState(address: address)
    let target = sequence ?? reconciled.events.count
    guard target >= 0, target <= reconciled.events.count else {
      throw StoryworldRuntimeError.eventSequenceOutOfRange(target)
    }
    if target == reconciled.events.count {
      return reconciled.state
    }
    guard fileManager.fileExists(atPath: baseStateURL(address).path) else {
      throw StoryworldRuntimeError.baseStateUnavailable
    }
    var values = try read(BranchStateSnapshot.self, from: baseStateURL(address)).values
    for event in reconciled.events.prefix(target) {
      values = merge(patch: event.statePatch, into: values)
    }
    return BranchStateSnapshot(
      lastEventSequence: target,
      values: values,
      stateHash: try hashState(values),
      updatedAt: Date()
    )
  }

  public func createSave(
    address: SessionAddress,
    atEventSequence sequence: Int? = nil,
    title: String
  ) throws -> StorySave {
    let snapshot = try stateSnapshot(address: address, atEventSequence: sequence)
    let save = StorySave(
      address: address,
      title: normalizedTitle(title, fallback: "手动存档"),
      eventSequence: snapshot.lastEventSequence,
      state: snapshot.values,
      stateHash: snapshot.stateHash,
      continuity: try continuitySnapshot(address: address, atEventSequence: snapshot.lastEventSequence)
    )
    let directory = savesURL(address)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try write(save, to: directory.appendingPathComponent(save.id.uuidString.lowercased() + ".json"))
    return save
  }

  public func listSaves(address: SessionAddress) throws -> [StorySave] {
    let directory = savesURL(address)
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url in
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        url.pathExtension.lowercased() == "json"
      else { return nil }
      return try read(StorySave.self, from: url)
    }.sorted { $0.createdAt > $1.createdAt }
  }

  @discardableResult
  public func forkBranch(
    address: SessionAddress,
    atEventSequence sequence: Int? = nil,
    title: String
  ) throws -> PlaythroughContext {
    let snapshot = try stateSnapshot(address: address, atEventSequence: sequence)
    return try createBranch(
      from: address,
      state: snapshot.values,
      stateHash: snapshot.stateHash,
      forkedAtEventSequence: snapshot.lastEventSequence,
      title: title
    )
  }

  public func restoreSaveAsNewBranch(
    address: SessionAddress,
    saveID: UUID,
    title: String
  ) throws -> PlaythroughContext {
    guard let save = try listSaves(address: address).first(where: { $0.id == saveID }) else {
      throw StoryworldRuntimeError.saveNotFound(saveID)
    }
    let storedContinuity: ContinuitySnapshot
    if let stored = save.continuity {
      let current = try continuitySnapshot(address: address, atEventSequence: save.eventSequence,
        throughCalibrationRevision: stored.calibrationRevision ?? 0)
      guard stored == current else { throw ContinuityError.corruptHistory }
      storedContinuity = current
    } else {
      storedContinuity = try continuitySnapshot(address: address, atEventSequence: save.eventSequence,
        throughCalibrationRevision: 0)
    }
    return try createBranch(
      from: address,
      state: save.state,
      stateHash: save.stateHash,
      forkedAtEventSequence: save.eventSequence,
      title: title,
      continuityAtFork: storedContinuity
    )
  }

  public func activateBranch(
    playthroughID: UUID,
    branchID: UUID
  ) throws -> PlaythroughContext {
    var playthrough = try loadPlaythrough(playthroughID)
    let branch = try loadBranch(playthroughID: playthroughID, branchID: branchID)
    let manifest = try validator.validate(at: packageURL)
    let address = SessionAddress(
      storyworldID: manifest.storyworldID,
      playthroughID: playthroughID,
      branchID: branchID,
      sessionID: branch.sessionID
    )
    let session = try loadSession(branch.sessionID)
    guard session.address == address else { throw StoryworldRuntimeError.addressMismatch }
    playthrough.activeBranchID = branchID
    playthrough.activeSessionID = branch.sessionID
    playthrough.updatedAt = Date()
    try write(playthrough, to: playthroughURL(playthroughID).appendingPathComponent("metadata.json"))
    return PlaythroughContext(playthrough: playthrough, branch: branch, session: session)
  }

  private var playthroughsURL: URL {
    packageURL.appendingPathComponent(StoryworldPackageLayout.playthroughsDirectory, isDirectory: true)
  }

  private func anchorStore(_ address: SessionAddress) -> StoryAnchorFileStore {
    StoryAnchorFileStore(url: branchURL(address).appendingPathComponent("anchors.json"))
  }

  public func saveAnchor(_ anchor: StoryAnchor, address: SessionAddress, expectedRevision: UUID?) throws {
    _ = try loadContext(address: address)
    let events = try reconcileState(address: address).events
    let visible = try projectedTurns(address: address, own: events)
    try anchorStore(address).upsert(anchor, expectedRevision: expectedRevision,
      visible: Set(visible.map(StoryAnchorEventRef.init)))
  }

  public func removeAnchor(id: UUID, address: SessionAddress, expectedRevision: UUID?) throws {
    _ = try loadContext(address: address)
    try anchorStore(address).remove(id: id, expectedRevision: expectedRevision)
  }

  public func setHistoryWindow(_ count: Int, address: SessionAddress) throws {
    _ = try load(address: address)
    var playthrough = try loadPlaythrough(address.playthroughID)
    playthrough.historyWindow = min(200, max(2, count))
    playthrough.updatedAt = Date()
    try write(playthrough, to: playthroughURL(playthrough.id).appendingPathComponent("metadata.json"))
  }

  public func setDirectiveProfile(_ profile: DirectiveProfile, address: SessionAddress,
    expectedRevision: UUID?) throws {
    _ = try loadContext(address: address)
    _ = try profile.validated()
    var playthrough = try loadPlaythrough(address.playthroughID)
    guard playthrough.directive?.revision == expectedRevision else { throw DirectiveProfileError.staleEdit }
    if playthrough.effectiveDirective == profile { return }
    playthrough.directive = PlaythroughDirective(profile: profile)
    playthrough.updatedAt = Date()
    try write(playthrough, to: playthroughURL(playthrough.id).appendingPathComponent("metadata.json"))
  }

  public func requireDirective(address: SessionAddress, expected: PlaythroughDirective?) throws -> DirectiveTurnToken {
    let current = try loadContext(address: address).playthrough
    guard current.directive == expected else { throw DirectiveProfileError.changedDuringTurn }
    _ = try current.effectiveDirective.validated()
    return DirectiveTurnToken(address: address, selection: current.directive)
  }

  public func canonStatus(address: SessionAddress) throws -> CanonBindingStatus {
    let context = try loadContext(address: address)
    let binding = context.playthrough.canonBinding
    do {
      let assets = try CanonAssets.read(at: packageURL)
      let state: CanonBindingStatus.State = binding == nil ? .legacyUnbound
        : (binding?.fingerprints == assets.fingerprints ? .matched : .changed)
      let compatible = try state == .matched || (assets.canPreservePlotReferences(from: binding)
        && plotReferencesAreValid(playthroughID: address.playthroughID, assets: assets))
      let notice: String
      if state == .matched {
        notice = "世界设定与这条游玩线的绑定一致。"
      } else if !compatible {
        notice = CanonBindingError.incompatiblePlotline.localizedDescription
      } else if state == .legacyUnbound {
        notice = "这是一条旧版本游玩线，尚未绑定世界设定。请确认使用当前设定后继续。"
      } else {
        let names = ["lorebook": "世界设定", "timeline": "节拍线", "plotline": "原著主线",
          "character_contracts": "角色契约", "material_profile": "素材配置"]
        let changed = Set(assets.fingerprints.assets.keys).union(binding?.fingerprints.assets.keys.map { $0 } ?? [])
          .filter { assets.fingerprints.assets[$0] != binding?.fingerprints.assets[$0] }
          .sorted().map { names[$0] ?? $0 }.joined(separator: "、")
        notice = "以下内容已变化：\(changed)。可确认让本条游玩线的后续使用新设定，或保留旧线并新开游玩线。旧记录不会改写。"
      }
      return CanonBindingStatus(state: state, address: address, current: assets.fingerprints, bindingID: binding?.id,
        canRebind: compatible, notice: notice)
    } catch {
      return CanonBindingStatus(state: .unavailable, address: address, current: nil, bindingID: binding?.id,
        canRebind: false, notice: error.localizedDescription)
    }
  }

  public func requireCanon(
    address: SessionAddress, document: StoryworldDocument, bindingID: UUID?
  ) throws -> CanonTurnToken {
    let context = try loadContext(address: address)
    let assets = try CanonAssets.read(at: packageURL)
    guard let binding = context.playthrough.canonBinding,
      binding.fingerprints == assets.fingerprints
    else { throw CanonBindingError.confirmationRequired }
    guard binding.id == bindingID, document.manifest.storyworldID == address.storyworldID,
      assets.matches(document)
    else { throw CanonBindingError.staleDocument }
    return CanonTurnToken(address: address, fingerprints: assets.fingerprints, bindingID: binding.id)
  }

  /// Only a user's explicit confirmation calls this API. Fingerprints and the
  /// previous decision ID must still match the notice the user reviewed.
  public func confirmCanonBinding(
    address: SessionAddress, expectedCurrent: CanonFingerprints, expectedBindingID: UUID?
  ) throws {
    _ = try loadContext(address: address)
    var playthrough = try loadPlaythrough(address.playthroughID)
    let assets = try CanonAssets.read(at: packageURL)
    guard assets.fingerprints == expectedCurrent, playthrough.canonBinding?.id == expectedBindingID else {
      throw CanonBindingError.changedDuringTurn
    }
    if playthrough.canonBinding?.fingerprints == assets.fingerprints { return }
    guard assets.canPreservePlotReferences(from: playthrough.canonBinding),
      try plotReferencesAreValid(playthroughID: playthrough.id, assets: assets)
    else { throw CanonBindingError.incompatiblePlotline }
    playthrough.canonBinding = CanonBinding(assets: assets, previous: playthrough.canonBinding, isConfirmation: true)
    playthrough.updatedAt = Date()
    try write(playthrough, to: playthroughURL(playthrough.id).appendingPathComponent("metadata.json"))
    // Summaries are disposable. The binding history and original events remain.
    for branch in try listBranches(playthroughID: playthrough.id) {
      let branchAddress = SessionAddress(storyworldID: address.storyworldID,
        playthroughID: playthrough.id, branchID: branch.id, sessionID: branch.sessionID)
      try? fileManager.removeItem(at: recapURL(branchAddress))
    }
  }

  private func plotReferencesAreValid(playthroughID: UUID, assets: CanonAssets) throws -> Bool {
    guard let plotline = assets.plotline else { return true }
    for branch in try listBranches(playthroughID: playthroughID) {
      let playthrough = try loadPlaythrough(playthroughID)
      let address = SessionAddress(storyworldID: playthrough.storyworldID, playthroughID: playthroughID,
        branchID: branch.id, sessionID: branch.sessionID)
      let values = try reconcileState(address: address).state.values
      if case .object(let plot) = values["plot"], case .number(let order) = plot["node"] {
        guard order.isFinite, order >= 1, order < Double(Int.max), order.rounded() == order,
          plotline.node(order: Int(order)) != nil else { return false }
      } else if plotline.firstNode == nil { return false }
    }
    return true
  }

  private var sessionsURL: URL {
    packageURL.appendingPathComponent(StoryworldPackageLayout.sessionsDirectory, isDirectory: true)
  }

  private func playthroughURL(_ playthroughID: UUID) -> URL {
    playthroughsURL.appendingPathComponent(playthroughID.uuidString.lowercased(), isDirectory: true)
  }

  private func branchesURL(_ playthroughID: UUID) -> URL {
    playthroughURL(playthroughID).appendingPathComponent("branches", isDirectory: true)
  }

  private func branchURL(_ address: SessionAddress) -> URL {
    branchesURL(address.playthroughID)
      .appendingPathComponent(address.branchID.uuidString.lowercased(), isDirectory: true)
  }

  private func stateURL(_ address: SessionAddress) -> URL {
    branchURL(address).appendingPathComponent("state.json")
  }

  /// 分支创建时的初始状态，写入后不再变化，用于回放任意历史事件处的状态。
  private func baseStateURL(_ address: SessionAddress) -> URL {
    branchURL(address).appendingPathComponent("base_state.json")
  }

  private func eventsURL(_ address: SessionAddress) -> URL {
    branchURL(address).appendingPathComponent("events.jsonl")
  }

  private func recapURL(_ address: SessionAddress) -> URL {
    branchURL(address).appendingPathComponent("recap.json")
  }

  private func endingReportURL(_ address: SessionAddress) -> URL {
    branchURL(address).appendingPathComponent("ending_report.json")
  }

  private func savesURL(_ address: SessionAddress) -> URL {
    branchURL(address).appendingPathComponent("saves", isDirectory: true)
  }

  private func sessionURL(_ sessionID: UUID) -> URL {
    sessionsURL.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
  }

  private func ensureRuntimeDirectories() throws {
    try fileManager.createDirectory(at: playthroughsURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
  }

  private func writePlaythrough(
    _ playthrough: PlaythroughDescriptor,
    branch: RuntimeBranchDescriptor,
    state: BranchStateSnapshot,
    to stagingURL: URL
  ) throws {
    let branchURL = stagingURL
      .appendingPathComponent("branches", isDirectory: true)
      .appendingPathComponent(branch.id.uuidString.lowercased(), isDirectory: true)
    try fileManager.createDirectory(
      at: branchURL.appendingPathComponent("saves", isDirectory: true),
      withIntermediateDirectories: true
    )
    try write(playthrough, to: stagingURL.appendingPathComponent("metadata.json"))
    try write(branch, to: branchURL.appendingPathComponent("metadata.json"))
    try write(state, to: branchURL.appendingPathComponent("state.json"))
    try write(state, to: branchURL.appendingPathComponent("base_state.json"))
    try write(ContinuitySnapshot(lastEventSequence: 0, ledger: .init()),
      to: branchURL.appendingPathComponent("base_continuity.json"))
    try Data().write(to: branchURL.appendingPathComponent("events.jsonl"), options: [.atomic])
  }

  private func loadPlaythrough(_ id: UUID) throws -> PlaythroughDescriptor {
    let url = playthroughURL(id).appendingPathComponent("metadata.json")
    guard fileManager.fileExists(atPath: url.path) else {
      throw StoryworldRuntimeError.playthroughNotFound(id)
    }
    return try read(PlaythroughDescriptor.self, from: url)
  }

  private func loadBranch(
    playthroughID: UUID,
    branchID: UUID
  ) throws -> RuntimeBranchDescriptor {
    let url = branchesURL(playthroughID)
      .appendingPathComponent(branchID.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent("metadata.json")
    guard fileManager.fileExists(atPath: url.path) else {
      throw StoryworldRuntimeError.branchNotFound(branchID)
    }
    return try read(RuntimeBranchDescriptor.self, from: url)
  }

  private func loadSession(_ id: UUID) throws -> StorySessionDescriptor {
    let url = sessionURL(id).appendingPathComponent("metadata.json")
    guard fileManager.fileExists(atPath: url.path) else {
      throw StoryworldRuntimeError.sessionNotFound(id)
    }
    return try read(StorySessionDescriptor.self, from: url)
  }

  private func loadContext(address: SessionAddress) throws -> PlaythroughContext {
    let manifest = try validator.validate(at: packageURL)
    guard address.storyworldID == manifest.storyworldID else {
      throw StoryworldRuntimeError.addressMismatch
    }
    let playthrough = try loadPlaythrough(address.playthroughID)
    let branch = try loadBranch(
      playthroughID: address.playthroughID,
      branchID: address.branchID
    )
    let session = try loadSession(address.sessionID)
    guard playthrough.storyworldID == address.storyworldID,
      branch.branch.playthroughID == address.playthroughID,
      branch.id == address.branchID,
      branch.sessionID == address.sessionID,
      session.address == address
    else {
      throw StoryworldRuntimeError.addressMismatch
    }
    return PlaythroughContext(playthrough: playthrough, branch: branch, session: session)
  }

  private func reconcileState(
    address: SessionAddress
  ) throws -> (state: BranchStateSnapshot, events: [CommittedStoryTurn]) {
    let events = try loadEvents(address: address)
    var expectedSequence = 1
    for event in events {
      guard event.sequence == expectedSequence, event.address == address else {
        throw StoryworldRuntimeError.corruptedEventLog
      }
      expectedSequence += 1
    }

    var state: BranchStateSnapshot
    do {
      state = try read(BranchStateSnapshot.self, from: stateURL(address))
    } catch {
      state = try rebuildState(address: address, events: events)
      try write(state, to: stateURL(address))
      return (state, events)
    }
    guard state.lastEventSequence <= events.count else {
      throw StoryworldRuntimeError.stateAheadOfEventLog
    }
    let stateHashMatches = try hashState(state.values) == state.stateHash
    let authorityHashMatches: Bool
    if state.lastEventSequence == 0 {
      let branch = try loadBranch(
        playthroughID: address.playthroughID,
        branchID: address.branchID
      )
      authorityHashMatches = state.stateHash == branch.baseStateHash
    } else {
      authorityHashMatches =
        events[state.lastEventSequence - 1].resultingStateHash == state.stateHash
    }
    if !stateHashMatches || !authorityHashMatches {
      state = try rebuildState(address: address, events: events)
      try write(state, to: stateURL(address))
      return (state, events)
    }
    if state.lastEventSequence < events.count {
      for event in events.dropFirst(state.lastEventSequence) {
        state.values = merge(patch: event.statePatch, into: state.values)
        state.lastEventSequence = event.sequence
        state.stateHash = try hashState(state.values)
        state.updatedAt = event.committedAt
        guard state.stateHash == event.resultingStateHash else {
          throw StoryworldRuntimeError.corruptedEventLog
        }
      }
      try write(state, to: stateURL(address))
    }
    return (state, events)
  }

  private func rebuildState(
    address: SessionAddress,
    events: [CommittedStoryTurn]
  ) throws -> BranchStateSnapshot {
    guard fileManager.fileExists(atPath: baseStateURL(address).path) else {
      throw StoryworldRuntimeError.baseStateUnavailable
    }
    var state = try read(BranchStateSnapshot.self, from: baseStateURL(address))
    let branch = try loadBranch(
      playthroughID: address.playthroughID,
      branchID: address.branchID
    )
    guard state.lastEventSequence == 0,
      try hashState(state.values) == state.stateHash,
      state.stateHash == branch.baseStateHash
    else {
      throw StoryworldRuntimeError.corruptedEventLog
    }
    for event in events {
      state.values = merge(patch: event.statePatch, into: state.values)
      state.lastEventSequence = event.sequence
      state.stateHash = try hashState(state.values)
      state.updatedAt = event.committedAt
      guard state.stateHash == event.resultingStateHash else {
        throw StoryworldRuntimeError.corruptedEventLog
      }
    }
    return state
  }

  private func loadEvents(address: SessionAddress) throws -> [CommittedStoryTurn] {
    let url = eventsURL(address)
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard !data.isEmpty else { return [] }

    var events: [CommittedStoryTurn] = []
    var recordStart = data.startIndex
    var truncationOffset = data.startIndex
    for index in data.indices where data[index] == 0x0A {
      do {
        events.append(
          try StoryworldCoding.makeDecoder().decode(
            CommittedStoryTurn.self,
            from: Data(data[recordStart..<index])
          )
        )
      } catch {
        throw StoryworldRuntimeError.corruptedEventLog
      }
      recordStart = data.index(after: index)
      truncationOffset = recordStart
    }

    let tail = Data(data[recordStart..<data.endIndex])
    guard !tail.isEmpty else { return events }
    do {
      events.append(
        try StoryworldCoding.makeDecoder().decode(CommittedStoryTurn.self, from: tail)
      )
      return events
    } catch {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
      let backupURL = url.deletingLastPathComponent().appendingPathComponent(
        "\(url.lastPathComponent).torn-\(timestamp).bak"
      )
      do {
        try tail.write(to: backupURL, options: [.atomic])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(truncationOffset))
        try handle.synchronize()
      } catch {
        throw StoryworldRuntimeError.corruptedEventLog
      }
      return events
    }
  }

  /// 组装当前分支的有效历史。每一层只取父分支在子分支分叉点处的
  /// branch-local 前缀；最多回溯 32 个父分支，遇到环立即停止。
  private func projectedTurns(
    address: SessionAddress,
    own: [CommittedStoryTurn]
  ) throws -> [CommittedStoryTurn] {
    var segments = [own]
    var child = try loadBranch(
      playthroughID: address.playthroughID,
      branchID: address.branchID
    )
    var visited: Set<UUID> = [address.branchID]
    var depth = 0

    while depth < 32, let parentID = child.branch.parentBranchID {
      guard visited.insert(parentID).inserted else { break }
      let parent = try loadBranch(
        playthroughID: address.playthroughID,
        branchID: parentID
      )
      let parentAddress = SessionAddress(
        storyworldID: address.storyworldID,
        playthroughID: address.playthroughID,
        branchID: parentID,
        sessionID: parent.sessionID
      )
      _ = try loadContext(address: parentAddress)
      let parentEvents = try reconcileState(address: parentAddress).events
      let forkSequence = max(0, child.branch.forkedAtEventSequence ?? 0)
      segments.append(Array(parentEvents.prefix(min(forkSequence, parentEvents.count))))
      child = parent
      depth += 1
    }

    return segments.reversed().flatMap { $0 }
  }

  private func append(event: CommittedStoryTurn, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(event)
    data.append(0x0A)
    if !fileManager.fileExists(atPath: url.path) {
      try Data().write(to: url, options: [.atomic])
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }

  private func createBranch(
    from parentAddress: SessionAddress,
    state: [String: JSONValue],
    stateHash: String,
    forkedAtEventSequence: Int,
    title: String,
    continuityAtFork: ContinuitySnapshot? = nil
  ) throws -> PlaythroughContext {
    _ = try loadContext(address: parentAddress)
    var playthrough = try loadPlaythrough(parentAddress.playthroughID)
    let branchID = UUID()
    let sessionID = UUID()
    let now = Date()
    let address = SessionAddress(
      storyworldID: parentAddress.storyworldID,
      playthroughID: parentAddress.playthroughID,
      branchID: branchID,
      sessionID: sessionID
    )
    let snapshot = try makeState(values: state, sequence: 0, updatedAt: now)
    let inheritedContinuity = try continuityAtFork ?? continuitySnapshot(address: parentAddress,
      atEventSequence: forkedAtEventSequence)
    let continuityBase = try ContinuitySnapshot(lastEventSequence: 0, ledger: inheritedContinuity.ledger)
    guard snapshot.stateHash == stateHash else {
      throw StoryworldRuntimeError.corruptedEventLog
    }
    let branch = RuntimeBranchDescriptor(
      branch: BranchDescriptor(
        id: branchID,
        playthroughID: parentAddress.playthroughID,
        parentBranchID: parentAddress.branchID,
        forkedAtEventSequence: forkedAtEventSequence,
        title: normalizedTitle(title, fallback: "新分支"),
        createdAt: now
      ),
      sessionID: sessionID,
      baseStateHash: stateHash,
      baseContinuityHash: continuityBase.hash
    )
    let session = StorySessionDescriptor(address: address, createdAt: now, updatedAt: now)
    let branchDirectory = branchesURL(parentAddress.playthroughID)
      .appendingPathComponent(branchID.uuidString.lowercased(), isDirectory: true)
    let sessionDirectory = sessionURL(sessionID)
    let parentEvents = try reconcileState(address: parentAddress).events
    let inheritedHistory = try projectedTurns(address: parentAddress,
      own: Array(parentEvents.prefix(forkedAtEventSequence)))
    let inheritedRefs = Set(inheritedHistory.map(StoryAnchorEventRef.init))
    let inheritedAnchors = (try anchorStore(parentAddress).read()?.anchors ?? [])
      .filter { inheritedRefs.contains($0.eventRef) }
    do {
      try fileManager.createDirectory(
        at: branchDirectory.appendingPathComponent("saves", isDirectory: true),
        withIntermediateDirectories: true
      )
      try write(branch, to: branchDirectory.appendingPathComponent("metadata.json"))
      try write(snapshot, to: branchDirectory.appendingPathComponent("state.json"))
      try write(snapshot, to: branchDirectory.appendingPathComponent("base_state.json"))
      try write(continuityBase, to: branchDirectory.appendingPathComponent("base_continuity.json"))
      if !inheritedAnchors.isEmpty {
        try StoryAnchorFileStore(url: branchDirectory.appendingPathComponent("anchors.json")).write(inheritedAnchors)
      }
      try Data().write(
        to: branchDirectory.appendingPathComponent("events.jsonl"),
        options: [.atomic]
      )
      try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
      try write(session, to: sessionDirectory.appendingPathComponent("metadata.json"))
      playthrough.activeBranchID = branchID
      playthrough.activeSessionID = sessionID
      playthrough.updatedAt = now
      try write(
        playthrough,
        to: playthroughURL(playthrough.id).appendingPathComponent("metadata.json")
      )
      return PlaythroughContext(playthrough: playthrough, branch: branch, session: session)
    } catch {
      try? fileManager.removeItem(at: branchDirectory)
      try? fileManager.removeItem(at: sessionDirectory)
      throw error
    }
  }

  private func touchContext(address: SessionAddress, at date: Date) throws {
    var playthrough = try loadPlaythrough(address.playthroughID)
    playthrough.activeBranchID = address.branchID
    playthrough.activeSessionID = address.sessionID
    playthrough.updatedAt = date
    try write(
      playthrough,
      to: playthroughURL(address.playthroughID).appendingPathComponent("metadata.json")
    )
    var session = try loadSession(address.sessionID)
    session.updatedAt = date
    try write(session, to: sessionURL(address.sessionID).appendingPathComponent("metadata.json"))
  }

  private func decodeStatePatch(_ data: Data) throws -> [String: JSONValue] {
    guard data.count <= Self.maximumStatePatchByteCount else {
      throw StoryworldRuntimeError.statePatchTooLarge(Self.maximumStatePatchByteCount)
    }
    do {
      guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
        throw StoryworldRuntimeError.malformedStatePatch
      }
      var valueCount = 0
      try validateComplexity(.object(object), depth: 0, valueCount: &valueCount)
      return object
    } catch let error as StoryworldRuntimeError {
      throw error
    } catch {
      throw StoryworldRuntimeError.malformedStatePatch
    }
  }

  private func validateComplexity(
    _ value: JSONValue,
    depth: Int,
    valueCount: inout Int
  ) throws {
    guard depth <= Self.maximumStatePatchDepth else {
      throw StoryworldRuntimeError.statePatchTooComplex
    }
    valueCount += 1
    guard valueCount <= Self.maximumStatePatchValueCount else {
      throw StoryworldRuntimeError.statePatchTooComplex
    }
    switch value {
    case .object(let object):
      for child in object.values {
        try validateComplexity(child, depth: depth + 1, valueCount: &valueCount)
      }
    case .array(let array):
      for child in array {
        try validateComplexity(child, depth: depth + 1, valueCount: &valueCount)
      }
    case .string, .number, .bool, .null:
      break
    }
  }

  private func merge(
    patch: [String: JSONValue],
    into state: [String: JSONValue]
  ) -> [String: JSONValue] {
    var result = state
    for (key, patchValue) in patch {
      switch patchValue {
      case .null:
        result.removeValue(forKey: key)
      case .object(let nestedPatch):
        let existing: [String: JSONValue]
        if let currentValue = result[key], case .object(let object) = currentValue {
          existing = object
        } else {
          existing = [:]
        }
        result[key] = .object(merge(patch: nestedPatch, into: existing))
      default:
        result[key] = patchValue
      }
    }
    return result
  }

  private func makeState(
    values: [String: JSONValue],
    sequence: Int,
    updatedAt: Date
  ) throws -> BranchStateSnapshot {
    BranchStateSnapshot(
      lastEventSequence: sequence,
      values: values,
      stateHash: try hashState(values),
      updatedAt: updatedAt
    )
  }

  private func hashState(_ values: [String: JSONValue]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(JSONValue.object(values))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct PayloadFingerprintInput: Encodable {
    let turnID: UUID
    let userMessage: String
    let narrative: String
    let statePatchData: Data
    let continuityRequestFingerprint: String?
  }

  private func payloadFingerprint(
    turnID: UUID,
    userMessage: String,
    narrative: String,
    statePatchData: Data,
    continuityRequestFingerprint: String? = nil
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(
      PayloadFingerprintInput(
        turnID: turnID,
        userMessage: userMessage,
        narrative: narrative,
        statePatchData: statePatchData,
        continuityRequestFingerprint: continuityRequestFingerprint
      )
    )
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func legacyPayloadFingerprint(for event: CommittedStoryTurn) throws -> String {
    try payloadFingerprint(
      turnID: event.turnID,
      userMessage: event.userMessage,
      narrative: event.narrative,
      statePatchData: canonicalStatePatchData(event.statePatch),
      continuityRequestFingerprint: event.continuityUpdate?.requestFingerprint
    )
  }

  private func canonicalStatePatchData(_ patch: [String: JSONValue]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(JSONValue.object(patch))
  }

  private func normalizedTitle(_ title: String, fallback: String) -> String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? fallback : title
  }

  private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
    try StoryworldCoding.makeDecoder().decode(
      type,
      from: Data(contentsOf: url, options: [.mappedIfSafe])
    )
  }

  private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try StoryworldCoding.makeEncoder().encode(value).write(to: url, options: [.atomic])
  }
}

/// 同一进程内按标准化包路径复用运行时，确保同一世界书的所有提交
/// 都由同一个 actor 串行处理。
public actor StoryworldRuntimeStoreRegistry {
  public static let shared = StoryworldRuntimeStoreRegistry()

  private var stores: [String: StoryworldRuntimeStore] = [:]

  public init() {}

  public func store(forPackageURL packageURL: URL) -> StoryworldRuntimeStore {
    let key = packageURL.standardizedFileURL.path
    if let store = stores[key] {
      return store
    }
    let store = StoryworldRuntimeStore(packageURL: packageURL.standardizedFileURL)
    stores[key] = store
    return store
  }

  public func evict(forPackageURL packageURL: URL) {
    stores.removeValue(forKey: packageURL.standardizedFileURL.path)
  }
}
