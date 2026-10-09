import Foundation
import LLMProviderKit
import StoryworldCore
import Testing

@testable import StorySessionCore

@Suite("Player-confirmed continuity calibration")
struct ContinuityCalibrationTests {
  @Test func proposalsRequireExplicitDecisionAndReplayWithoutRewritingTurns() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let event = try await f.commit()
    let before = try await f.runtime.load(address: f.address)
    let eventURL = f.directory(f.address).appendingPathComponent("events.jsonl")
    let bytes = try Data(contentsOf: eventURL)
    let proposal = try await proposeScene(f, event: event, location: "渡口石阶")
    let pending = try await f.runtime.load(address: f.address)
    #expect(pending.continuity?.hash == before.continuity?.hash)
    #expect(pending.calibrationReviews.first?.decision == nil)
    try await f.runtime.decideContinuityCalibration(address: f.address, id: proposal.id, decision: .accepted)
    let logURL = f.directory(f.address).appendingPathComponent("continuity_calibrations.jsonl")
    let log = try Data(contentsOf: logURL)
    try await f.runtime.decideContinuityCalibration(address: f.address, id: proposal.id, decision: .accepted)
    #expect(try Data(contentsOf: logURL) == log)
    #expect(try Data(contentsOf: eventURL) == bytes)
    let calibrated = try await f.runtime.load(address: f.address)
    #expect(calibrated.continuity?.ledger.scene?.location == "渡口石阶")
    #expect(calibrated.continuity?.hash == proposal.resultingContinuityHash)
    #expect(calibrated.continuity?.ledger.calibrations?.last?.source.calibrationID == proposal.id)
    #expect(calibrated.turns == before.turns && calibrated.state == before.state)
    let next = try await f.runtime.commitTurn(address: f.address, turnID: UUID(),
      userMessage: "等待", narrative: "林舟仍在等待。", continuityInput: .init(data: Data("{}".utf8)))
    #expect(next.basedOnContinuityHash == calibrated.continuity?.hash)
    let reopened = StoryworldRuntimeStore(packageURL: f.package)
    #expect(try await reopened.load(address: f.address).continuity?.ledger.scene?.location == "渡口石阶")
    #expect(try await reopened.load(address: f.address).turns.count == 2)
    await #expect(throws: ContinuityCalibrationError.alreadyDecided) {
      try await f.runtime.decideContinuityCalibration(address: f.address, id: proposal.id, decision: .rejected)
    }
  }

  @Test func sameHeadSavesAndForksCaptureTheirOwnCalibrationPrefix() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let event = try await f.commit()
    let oldSave = try await f.runtime.createSave(address: f.address, title: "校准前")
    let oldChild = try await f.runtime.forkBranch(address: f.address, title: "校准前分支")
    let first = try await proposeScene(f, event: event, location: "渡口石阶")
    try await f.runtime.decideContinuityCalibration(address: f.address, id: first.id, decision: .accepted)
    let newSave = try await f.runtime.createSave(address: f.address, title: "第一次校准后")
    let newChild = try await f.runtime.forkBranch(address: f.address, title: "第一次校准后分支")
    let second = try await proposeScene(f, event: event, location: "渡口木桥")
    try await f.runtime.decideContinuityCalibration(address: f.address, id: second.id, decision: .accepted)
    let oldRestore = try await f.runtime.restoreSaveAsNewBranch(address: f.address, saveID: oldSave.id, title: "恢复旧记录")
    let newRestore = try await f.runtime.restoreSaveAsNewBranch(address: f.address, saveID: newSave.id, title: "恢复第一次校准")
    for address in [oldChild.address, oldRestore.address] {
      #expect(try await f.runtime.load(address: address).continuity?.ledger.scene?.location == "渡口")
    }
    for address in [newChild.address, newRestore.address] {
      #expect(try await f.runtime.load(address: address).continuity?.ledger.scene?.location == "渡口石阶")
      #expect(try await f.runtime.load(address: address).continuity?.ledger.calibrations?.count == 1)
    }
    #expect(try await f.runtime.load(address: f.address).continuity?.ledger.scene?.location == "渡口木桥")
    let grand = try await f.runtime.forkBranch(address: newChild.address, title: "第二级")
    #expect(try await f.runtime.load(address: grand.address).continuity?.ledger.scene?.location == "渡口石阶")
    let exported = f.root.appendingPathComponent("copy.storyworld")
    _ = try await f.library.exportPackage(storyworldID: f.world, to: exported)
    let imported = try await f.library.importPackage(from: exported, conflictPolicy: .importAsCopy)
    let importedURL = try await f.library.managedPackageURL(storyworldID: imported.id)
    let importedStore = StoryworldRuntimeStore(packageURL: importedURL)
    let importedAddress = SessionAddress(storyworldID: imported.id, playthroughID: f.address.playthroughID,
      branchID: f.address.branchID, sessionID: f.address.sessionID)
    let expected = try await f.runtime.load(address: f.address).continuity
    #expect(try await importedStore.load(address: importedAddress).continuity == expected)
  }

  @Test func staleAndConcurrentDecisionsCannotOverwriteNewerRecords() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let event = try await f.commit()
    var proposals: [ContinuityCalibrationProposal] = []
    for index in 0..<8 {
      proposals.append(try await proposeScene(f, event: event, location: "石阶\(index)"))
    }
    let accepted = await withTaskGroup(of: Bool.self) { group in
      for proposal in proposals {
        group.addTask {
          do {
            try await f.runtime.decideContinuityCalibration(address: f.address, id: proposal.id, decision: .accepted)
            return true
          } catch { return false }
        }
      }
      var count = 0
      for await success in group { if success { count += 1 } }
      return count
    }
    #expect(accepted == 1)
    let stale = try await proposeScene(f, event: event, location: "新提案")
    _ = try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "继续", narrative: "继续等待。")
    await #expect(throws: ContinuityCalibrationError.stale) {
      try await f.runtime.decideContinuityCalibration(address: f.address, id: stale.id, decision: .accepted)
    }
    try await f.runtime.decideContinuityCalibration(address: f.address, id: stale.id, decision: .rejected)
    #expect(try await f.runtime.calibrationReviews(address: f.address).last?.decision == .rejected)
  }

  @Test func correctionsKeepOldFactsAndKnowledgeAndIdentityAreExplicit() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let event = try await f.commit()
    let original = try #require(try await f.runtime.load(address: f.address).continuity?.ledger)
    let old = try #require(original.activeFacts.first { $0.kind == .promise })
    let item = try #require(original.entities.values.first { $0.kind == .item })
    let draft = ContinuityCalibrationDraft(reason: "纠正知情范围并确认物品身份", source: .init(event),
      quote: "承诺天亮归还铜钥匙", changes: .init(facts: [
        .init(kind: .promise, subjectID: "lin", objectID: "player", slot: "return",
          statement: "天亮归还铜钥匙", knownByEntityIDs: ["lin"], quote: "承诺天亮归还铜钥匙")
      ]), retractFactIDs: [old.id], confirmEntityIDs: [item.id])
    let proposal = try await propose(f, draft: draft)
    try await f.runtime.decideContinuityCalibration(address: f.address, id: proposal.id, decision: .accepted)
    let ledger = try #require(try await f.runtime.load(address: f.address).continuity?.ledger)
    #expect(ledger.facts[old.id]?.status == .retracted)
    #expect(ledger.facts[old.id]?.evidence.first == old.evidence.first)
    let replacement = try #require(ledger.activeFacts.first { $0.kind == .promise })
    #expect(replacement.id != old.id && replacement.knownByEntityIDs == ["lin"])
    #expect(replacement.evidence.first?.event == StoryAnchorEventRef(event))
    #expect(replacement.evidence.first?.calibrationID == proposal.id)
    #expect(ledger.entities[item.id]?.provisional == false)
    #expect(ledger.entities.count == original.entities.count)
  }

  @Test func invalidEvidenceAndDamagedAppendLogFailClosedWithoutErasingNarrative() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let event = try await f.commit()
    let child = try await f.runtime.forkBranch(address: f.address, atEventSequence: 0, title: "空历史")
    let draft = ContinuityCalibrationDraft(reason: "无效", source: .init(event), quote: "林舟", clearScene: true)
    let childSnapshot = try await f.runtime.load(address: child.address)
    await #expect(throws: ContinuityError.invalidEvidence) {
      try await f.runtime.proposeContinuityCalibration(address: child.address, id: UUID(), draft: draft,
        expectedEventSequence: 0, expectedStateHash: childSnapshot.state.stateHash,
        expectedContinuityHash: childSnapshot.continuity!.hash)
    }
    var bad = draft
    bad.quote = "原文没有这句话"
    await #expect(throws: ContinuityError.invalidEvidence) { try await propose(f, draft: bad) }
    let proposal = try await proposeScene(f, event: event, location: "石阶")
    let base = try await f.runtime.load(address: f.address)
    let path = f.directory(f.address).appendingPathComponent("continuity_calibrations.jsonl")
    let good = try Data(contentsOf: path)
    for damaged in [Data(), Data(good.dropLast()), good + Data("{}\n".utf8)] {
      try damaged.write(to: path)
      let loaded = try await f.runtime.load(address: f.address)
      #expect(loaded.turns == base.turns && loaded.continuity == nil)
      await #expect(throws: ContinuityCalibrationError.corruptLog) {
        try await f.runtime.decideContinuityCalibration(address: f.address, id: proposal.id, decision: .accepted)
      }
      #expect(try Data(contentsOf: path) == damaged)
    }
    try FileManager.default.removeItem(at: path)
    #expect(try await f.runtime.load(address: f.address).continuity == nil)
    try good.write(to: path)
    #expect(try await f.runtime.load(address: f.address).continuity?.hash == base.continuity?.hash)
  }

  @Test func calibrationDuringGenerationFailsIndependentContinuityCAS() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let event = try await f.commit()
    let before = try await f.runtime.load(address: f.address)
    let proposal = try await proposeScene(f, event: event, location: "玩家确认的渡口")
    let gate = CalibrationGenerationGate()
    let document = try await f.library.load(storyworldID: f.world)
    let task = Task { () -> ContinuityError? in
      do {
        for try await _ in StoryTurnEngine(recapInterval: 0).runTurn(
          provider: CalibrationWaitingProvider(gate: gate), runtime: f.runtime,
          storyworld: document, snapshot: before, userMessage: "继续等待",
          turnID: UUID(), isCorrectionRetry: false) {}
        return nil
      } catch { return error as? ContinuityError }
    }
    await gate.waitForStart()
    try await f.runtime.decideContinuityCalibration(address: f.address, id: proposal.id, decision: .accepted)
    await gate.release()
    #expect(await task.value == .staleBase)
    let after = try await f.runtime.load(address: f.address)
    #expect(after.turns == before.turns && after.state == before.state)
    #expect(after.continuity?.ledger.scene?.location == "玩家确认的渡口")
  }

  private func proposeScene(_ f: MemoryFixture, event: CommittedStoryTurn, location: String) async throws -> ContinuityCalibrationProposal {
    try await propose(f, draft: .init(reason: "玩家依据原文核对地点", source: .init(event), quote: "林舟在渡口",
      changes: .init(scene: .init(location: location, time: "夜晚", presentEntityIDs: ["lin"], quote: "林舟在渡口"))))
  }
  private func propose(_ f: MemoryFixture, draft: ContinuityCalibrationDraft) async throws -> ContinuityCalibrationProposal {
    let snapshot = try await f.runtime.load(address: f.address)
    return try await f.runtime.proposeContinuityCalibration(address: f.address, id: UUID(), draft: draft,
      expectedEventSequence: snapshot.state.lastEventSequence, expectedStateHash: snapshot.state.stateHash,
      expectedContinuityHash: try #require(snapshot.continuity?.hash))
  }
}

private actor CalibrationGenerationGate {
  private var started = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  func waitForStart() async {
    if started { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
  func pause() async {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    await withCheckedContinuation { releaseWaiter = $0 }
  }
  func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private struct CalibrationWaitingProvider: LLMProvider {
  let gate: CalibrationGenerationGate
  var profile: ProviderProfile {
    .init(displayName: "本地校准测试", kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!, modelID: "test", credentialReference: "test")
  }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await gate.pause()
        continuation.yield(.textDelta("<STORY>林舟仍在等待。</STORY><CHOICES>[\"继续等待\",\"询问安排\"]</CHOICES><STATE_PATCH>{}</STATE_PATCH><MEMORY_PATCH>{}</MEMORY_PATCH>"))
        continuation.yield(.completed)
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
