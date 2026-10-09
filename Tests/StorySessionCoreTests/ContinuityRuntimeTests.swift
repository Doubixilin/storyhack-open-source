import Foundation
import LLMProviderKit
import StoryworldCore
import Testing

@testable import StorySessionCore

@Suite("Continuity event authority and runtime integration")
struct ContinuityRuntimeTests {
  @Test func commitStoresResolvedDeltaAndChecksPayloadAndThirdCAS() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let before = try await f.runtime.load(address: f.address)
    let turnID = UUID()
    let input = try f.input()
    let first = try await f.runtime.commitTurn(
      address: f.address, turnID: turnID,
      userMessage: "托付钥匙", narrative: MemoryFixture.narrative,
      statePatchData: Data(#"{"continuity":{"forged":true}}"#.utf8),
      continuityInput: input)
    let persisted = try #require(try await f.runtime.load(address: f.address).turns.first)
    let replay = try await f.runtime.commitTurn(
      address: f.address, turnID: turnID,
      userMessage: "托付钥匙", narrative: MemoryFixture.narrative,
      statePatchData: Data(#"{"continuity":{"forged":true}}"#.utf8),
      continuityInput: input)
    #expect(persisted == replay)
    #expect(first.continuityUpdate?.status == .recorded)
    #expect(first.basedOnContinuityHash == before.continuity?.hash)
    let loaded = try await f.runtime.load(address: f.address)
    #expect(first.resultingContinuityHash == loaded.continuity?.hash)
    #expect(loaded.continuity?.ledger.facts.count == 2)
    #expect(loaded.state.values["continuity"] == nil)
    await #expect(throws: StoryworldRuntimeError.turnPayloadConflict(turnID)) {
      try await f.runtime.commitTurn(
        address: f.address, turnID: turnID,
        userMessage: "托付钥匙", narrative: MemoryFixture.narrative,
        statePatchData: Data(#"{"continuity":{"forged":true}}"#.utf8),
        continuityInput: .init(data: Data("{}".utf8)))
    }
    await #expect(throws: ContinuityError.staleBase) {
      try await f.runtime.commitTurn(
        address: f.address, turnID: UUID(), userMessage: "继续", narrative: "无变化",
        expectedEventSequence: loaded.state.lastEventSequence,
        expectedStateHash: loaded.state.stateHash,
        continuityInput: .init(data: Data("{}".utf8)),
        expectedContinuityHash: before.continuity?.hash)
    }
    #expect(try await f.runtime.load(address: f.address).turns.count == 1)
  }

  @Test func missingAndInvalidUpdatesKeepNarrativeWithoutPartialFacts() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let first = try await f.commit()
    let original = try #require(try await f.runtime.load(address: f.address).continuity?.ledger)
    let missing = try await f.runtime.commitTurn(
      address: f.address, turnID: UUID(), userMessage: "继续", narrative: "风起。",
      continuityInput: .init(data: nil))
    let invalid = try await f.runtime.commitTurn(
      address: f.address, turnID: UUID(), userMessage: "继续", narrative: "风起。",
      continuityInput: .init(
        data: Data(
          #"{"scene":{"location":"凭空换场","time":"午后","presentEntityIDs":["ghost"],"quote":"风起"}}"#
            .utf8)))
    #expect(missing.continuityUpdate?.issue == "missing")
    #expect(invalid.continuityUpdate?.status == .needsReconciliation)
    #expect(invalid.continuityUpdate?.delta == nil)
    let snapshot = try await f.runtime.load(address: f.address)
    #expect(snapshot.turns.map(\.narrative) == [first.narrative, "风起。", "风起。"])
    #expect(snapshot.continuity?.ledger.facts == original.facts)
    #expect(snapshot.continuity?.ledger.scene == original.scene)
    #expect(snapshot.continuity?.ledger.unresolvedTurnCount == 2)
    #expect(snapshot.continuity?.ledger.latestGap == StoryAnchorEventRef(invalid))
  }

  @Test func disposableCacheCannotOverrideEventsAndDamagedBaseBlocksOnlyGeneration() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    _ = try await f.commit()
    let expected = try await f.runtime.load(address: f.address)
    let cache = f.directory(f.address).appendingPathComponent("continuity.json")
    let base = f.directory(f.address).appendingPathComponent("base_continuity.json")
    let originalBase = try Data(contentsOf: base)
    for corrupted in [
      Data("broken".utf8),
      try StoryworldCoding.makeEncoder().encode(
        ContinuitySnapshot(lastEventSequence: 999, ledger: .init())),
    ] {
      try corrupted.write(to: cache)
      let restarted = StoryworldRuntimeStore(packageURL: f.package)
      #expect(try await restarted.load(address: f.address).continuity == expected.continuity)
    }
    try FileManager.default.removeItem(at: cache)
    #expect(try await f.runtime.load(address: f.address).continuity == expected.continuity)
    try Data("{}".utf8).write(to: base)
    let damaged = try await f.runtime.load(address: f.address)
    #expect(damaged.turns == expected.turns)
    #expect(damaged.continuity == nil && damaged.continuityNotice != nil)
    await #expect(throws: ContinuityError.corruptHistory) { try await f.commit() }
    try originalBase.write(to: base)
    #expect(try await f.runtime.load(address: f.address).continuity == expected.continuity)
  }

  @Test func forksAndOldSavesKeepOnlyFactsAtTheirCutoff() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let first = try await f.commit()
    let old = try await f.runtime.createSave(address: f.address, title: "托付之后")
    let child = try await f.runtime.forkBranch(address: f.address, title: "保留承诺")
    let promise = try #require(old.continuity?.ledger.activeFacts.first { $0.kind == .promise })
    let later = ContinuityDelta(resolutions: [
      .init(factID: promise.id, status: .broken, quote: "他违背了承诺")
    ])
    _ = try await f.runtime.commitTurn(
      address: f.address, turnID: UUID(), userMessage: "后来", narrative: "他违背了承诺。",
      continuityInput: .init(data: try JSONEncoder().encode(later)))
    _ = try await f.runtime.commitTurn(
      address: child.address, turnID: UUID(), userMessage: "等待", narrative: "他仍在等待。",
      continuityInput: .init(data: Data("{}".utf8)))
    let childSnapshot = try await f.runtime.load(address: child.address)
    #expect(childSnapshot.turns.first?.sequence == first.sequence)
    #expect(childSnapshot.continuity?.ledger.facts[promise.id]?.status == .active)
    #expect(
      childSnapshot.continuity?.ledger.facts[promise.id]?.evidence.first?.event
        == StoryAnchorEventRef(first))
    #expect(
      try await f.runtime.load(address: f.address).continuity?.ledger.facts[promise.id]?.status
        == .broken)
    let restored = try await f.runtime.restoreSaveAsNewBranch(
      address: f.address, saveID: old.id, title: "从旧存档")
    #expect(
      try await f.runtime.load(address: restored.address).continuity?.ledger
        == old.continuity?.ledger)
    let grand = try await f.runtime.forkBranch(
      address: child.address, atEventSequence: 0, title: "多级分叉")
    #expect(
      try await f.runtime.load(address: grand.address).continuity?.ledger == old.continuity?.ledger)
  }

  @Test func legacyEventsStayUnchangedAndImportedCopiesReplayTheSameFacts() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    // Simulate an old branch with no continuity metadata and a pre-feature event.
    let old = try await f.runtime.commitTurn(
      address: f.address, turnID: UUID(), userMessage: "旧行动", narrative: "旧叙事")
    let events = f.directory(f.address).appendingPathComponent("events.jsonl")
    var event = try #require(
      JSONSerialization.jsonObject(with: StoryworldCoding.makeEncoder().encode(old))
        as? [String: Any])
    event.removeValue(forKey: "based_on_continuity_hash")
    event.removeValue(forKey: "resulting_continuity_hash")
    let bytes =
      try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) + Data([10])
    try bytes.write(to: events)
    let metadata = f.directory(f.address).appendingPathComponent("metadata.json")
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
    object.removeValue(forKey: "base_continuity_hash")
    try JSONSerialization.data(withJSONObject: object).write(to: metadata)
    let base = f.directory(f.address).appendingPathComponent("base_continuity.json")
    try FileManager.default.removeItem(at: base)
    let legacy = try await f.runtime.load(address: f.address)
    #expect(legacy.continuity?.ledger.legacyTurnCount == 1)
    #expect(legacy.continuity?.ledger.facts.isEmpty == true)
    #expect(try Data(contentsOf: events) == bytes)
    #expect(!FileManager.default.fileExists(atPath: base.path))
    _ = try await f.commit()
    #expect(try Data(contentsOf: events).starts(with: bytes))
    let before = try await f.runtime.load(address: f.address)
    let export = f.root.appendingPathComponent("export.storyworld")
    _ = try await f.library.exportPackage(storyworldID: f.world, to: export)
    let copied = try await f.library.importPackage(from: export, conflictPolicy: .importAsCopy)
    let copyURL = try await f.library.managedPackageURL(storyworldID: copied.id)
    let copyRuntime = StoryworldRuntimeStore(packageURL: copyURL)
    let copiedAddress = SessionAddress(
      storyworldID: copied.id, playthroughID: f.address.playthroughID,
      branchID: f.address.branchID, sessionID: f.address.sessionID)
    let after = try await copyRuntime.load(address: copiedAddress)
    #expect(after.continuity == before.continuity)
    #expect(after.turns.last?.address.storyworldID == copied.id)
  }

  @Test func changedEventMemoryCannotBeBlessedByAnUnchangedDerivedHash() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    _ = try await f.commit()
    let file = f.directory(f.address).appendingPathComponent("events.jsonl")
    var event = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var update = try #require(event["continuity_update"] as? [String: Any])
    var delta = try #require(update["delta"] as? [String: Any])
    var facts = try #require(delta["addedFacts"] as? [[String: Any]])
    facts[0]["statement"] = "伪造事实"
    delta["addedFacts"] = facts
    update["delta"] = delta
    event["continuity_update"] = update
    try (JSONSerialization.data(withJSONObject: event) + Data([10])).write(to: file)
    let state = try await f.runtime.load(address: f.address)
    #expect(state.continuity == nil && state.continuityNotice != nil)
    #expect(state.turns.first?.narrative == MemoryFixture.narrative)
  }

  @Test func enginePersistsPatchAndKeepsAbsentNameCharacterAndOldPromiseInContext() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let patch = String(decoding: try #require(f.input().data), as: UTF8.self)
    let response =
      "<STORY>" + MemoryFixture.narrative
      + "</STORY><CHOICES>[\"继续等待\",\"询问安排\"]</CHOICES><STATE_PATCH>{}</STATE_PATCH><MEMORY_PATCH>"
      + patch + "</MEMORY_PATCH>"
    let provider = MemoryReplyProvider(reply: response)
    let engine = StoryTurnEngine(recapInterval: 0)
    let document = try await f.library.load(storyworldID: f.world)
    let before = try await f.runtime.load(address: f.address)
    var result: StoryTurnResult?
    for try await event in engine.runTurn(
      provider: provider, runtime: f.runtime, storyworld: document,
      snapshot: before, userMessage: "托付钥匙", turnID: UUID(), isCorrectionRetry: false)
    {
      if case .completed(let completed) = event { result = completed }
    }
    #expect(result?.snapshot.turns.first?.continuityUpdate?.status == .recorded)
    for _ in 1...20 {
      _ = try await f.runtime.commitTurn(
        address: f.address, turnID: UUID(), userMessage: "继续", narrative: "他仍在等待。",
        continuityInput: .init(data: Data("{}".utf8)))
    }
    try await f.runtime.setHistoryWindow(2, address: f.address)
    let snapshot = try await f.runtime.load(address: f.address)
    let request = try await engine.makeRequest(
      turnID: UUID(), userMessage: "继续", snapshot: snapshot,
      storyworld: document, isCorrectionRetry: false)
    let system = try #require(request.messages.first?.content)
    #expect(system.contains("林舟只说短句"))
    #expect(system.contains("承诺天亮归还铜钥匙"))
    #expect(system.contains("knownByEntityIDs"))
    #expect(request.messages.count == 6)
    #expect(!request.messages.dropFirst().contains { $0.content.contains("承诺天亮归还铜钥匙") })
    let badProvider = MemoryReplyProvider(reply: "<STORY>风起。</STORY><STATE_PATCH>{}</STATE_PATCH>")
    var missing: StoryTurnResult?
    for try await event in engine.runTurn(
      provider: badProvider, runtime: f.runtime, storyworld: document,
      snapshot: snapshot, userMessage: "继续", turnID: UUID(), isCorrectionRetry: false)
    {
      if case .completed(let completed) = event { missing = completed }
    }
    #expect(missing?.snapshot.continuity?.ledger.unresolvedTurnCount == 1)
    #expect(missing?.warnings.contains(where: { $0.contains("连续性") }) == true)
  }

  @Test func memoryEnvelopeNeverLeaksIntoVisibleNarrative() throws {
    for raw in [
      "风起。<MEMORY_PATCH>{\"secret\":\"内部字段\"}</MEMORY_PATCH>",
      "<STORY>风起。<MEMORY_PATCH>{\"secret\":\"内部字段\"}</MEMORY_PATCH>",
    ] {
      #expect(!StoryResponseEnvelopeParser.visibleNarrative(from: raw).contains("内部字段"))
      let recovered = try StoryResponseEnvelopeParser.parseRecovering(raw)
      #expect(recovered.narrative == "风起。")
      #expect(recovered.memoryPatchData != nil)
    }
    let parsed = try StoryResponseEnvelopeParser.parse(
      "<STORY>风起。</STORY><STATE_PATCH>{}</STATE_PATCH><MEMORY_PATCH>bad-json</MEMORY_PATCH>")
    #expect(parsed.memoryPatchData == Data("bad-json".utf8))
  }
}

private struct MemoryReplyProvider: LLMProvider {
  let reply: String
  var profile: ProviderProfile {
    .init(
      displayName: "合成连续性测试", kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!, modelID: "local-test",
      credentialReference: "test")
  }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.textDelta(reply))
      continuation.yield(.completed)
      continuation.finish()
    }
  }
}

struct MemoryFixture: Sendable {
  static let narrative = "林舟在渡口接过铜钥匙，承诺天亮归还铜钥匙。"
  let root: URL
  let library: StoryworldLibrary
  let package: URL
  let world: UUID
  let runtime: StoryworldRuntimeStore
  let address: SessionAddress
  static func make() async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "memory-runtime-\(UUID())")
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("library"))
    let world = try await library.create(lorebook: .init(title: "合成渡口"))
    try await library.saveCharacterContracts(
      .init(contracts: [
        .init(entityID: "lin", displayName: "林舟", speechRules: ["林舟只说短句"]),
        .init(entityID: "wen", displayName: "温宁"),
      ]), storyworldID: world.id, expectedFingerprint: nil)
    let package = try await library.managedPackageURL(storyworldID: world.id)
    let runtime = await StoryworldRuntimeStoreRegistry.shared.store(forPackageURL: package)
    let line = try await runtime.createPlaythrough(title: "测试线")
    return .init(
      root: root, library: library, package: package, world: world.id, runtime: runtime,
      address: line.address)
  }
  func input() throws -> ContinuityInput {
    let delta = ContinuityDelta(
      entities: [.init(key: "new.key", name: "铜钥匙", kind: .item, quote: "接过铜钥匙")],
      scene: .init(
        location: "渡口", time: "夜晚", presentEntityIDs: ["lin", "player"], quote: "林舟在渡口"),
      facts: [
        .init(
          kind: .possession, subjectID: "lin", objectID: "new.key", slot: "holder",
          statement: "林舟保管铜钥匙", knownByEntityIDs: ["lin", "player"], quote: "接过铜钥匙"),
        .init(
          kind: .promise, subjectID: "lin", objectID: "player", slot: "return",
          statement: "承诺天亮归还铜钥匙", knownByEntityIDs: ["lin", "player"], quote: "承诺天亮归还铜钥匙"),
      ])
    return .init(data: try JSONEncoder().encode(delta))
  }
  func commit() async throws -> CommittedStoryTurn {
    try await runtime.commitTurn(
      address: address, turnID: UUID(), userMessage: "托付钥匙", narrative: Self.narrative,
      continuityInput: input())
  }
  func directory(_ address: SessionAddress) -> URL {
    package.appendingPathComponent(
      "playthroughs/\(address.playthroughID.uuidString.lowercased())/branches/\(address.branchID.uuidString.lowercased())"
    )
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}
