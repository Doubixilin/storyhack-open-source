import Foundation
import LLMProviderKit
import StoryworldCore
import Testing

@testable import StorySessionCore

@Suite("World-local stable character contracts")
struct CharacterContractTests {
  @Test func namesAreLabelsAndSchemaIsBounded() throws {
    let a = CharacterContract(entityID: "person.a", displayName: "林舟", aliases: ["小林"])
    let b = CharacterContract(entityID: "person.b", displayName: "林舟", aliases: ["小林"])
    try CharacterContractFile(contracts: [a, b]).validate()
    #expect(throws: CharacterContractError.invalidFile) {
      try CharacterContractFile(contracts: [a, a]).validate()
    }
    #expect(throws: CharacterContractError.invalidFile) {
      try CharacterContractFile(contracts: [.init(entityID: "../scene", displayName: "越界")])
        .validate()
    }
    let minimal = Data(
      #"{"schema_version":1,"contracts":[{"entity_id":"person.a","display_name":"林舟"}]}"#.utf8)
    let decoded = try StoryworldCoding.makeDecoder().decode(
      CharacterContractFile.self, from: minimal)
    try decoded.validate()
    #expect(decoded.contracts.first?.speechRules == [])
    let wide = String(repeating: "\u{301}", count: 600_000)
    #expect(throws: CharacterContractError.invalidFile) {
      try CharacterContractFile(contracts: [.init(displayName: "林", immutableTraits: [wide])])
        .validate()
    }
    let object = try #require(
      JSONSerialization.jsonObject(with: StoryworldCoding.makeEncoder().encode(decoded))
        as? [String: Any])
    let contracts = try #require(object["contracts"] as? [[String: Any]])
    #expect(contracts[0]["entity_id"] as? String == "person.a")
    #expect(contracts[0]["entityID"] == nil)
  }

  @Test func savesRequireReviewedVersionAndDoNotRewritePlaythroughs() async throws {
    let f = try await ContractFixture.make()
    defer { f.clean() }
    _ = try await f.runtime.commitTurn(
      address: f.address, turnID: UUID(), userMessage: "行动", narrative: "原始记录")
    let before = try Data(contentsOf: f.events)
    let oldDocument = try await f.library.load(storyworldID: f.world)
    var file = CharacterContractFile(contracts: [
      .init(entityID: "a", displayName: "林舟", speechRules: ["言简意赅"])
    ])
    try await f.library.saveCharacterContracts(
      file, storyworldID: f.world, expectedFingerprint: nil)
    let reviewed = try await f.library.characterContractState(storyworldID: f.world)
    #expect(try await f.runtime.load(address: f.address).canonStatus?.state == .changed)
    let revision = try await f.library.load(storyworldID: f.world).manifest.revision
    try await f.library.saveCharacterContracts(
      file, storyworldID: f.world, expectedFingerprint: reviewed.fingerprint)
    #expect(try await f.library.load(storyworldID: f.world).manifest.revision == revision)
    file.contracts[0].displayName = "林远舟"
    await #expect(throws: CharacterContractError.staleRevision) {
      try await f.library.saveCharacterContracts(
        file, storyworldID: f.world, expectedFingerprint: nil)
    }
    try await f.library.saveCharacterContracts(
      file, storyworldID: f.world, expectedFingerprint: reviewed.fingerprint)
    let status = try await f.runtime.canonStatus(address: f.address)
    try await f.runtime.confirmCanonBinding(
      address: f.address,
      expectedCurrent: #require(status.current), expectedBindingID: status.bindingID)
    let bound = try await f.runtime.load(address: f.address)
    await #expect(throws: CanonBindingError.staleDocument) {
      try await f.runtime.requireCanon(
        address: f.address, document: oldDocument,
        bindingID: bound.context.playthrough.canonBinding?.id)
    }
    #expect(
      try await f.library.load(storyworldID: f.world).characterContracts?.contracts.first?.entityID
        == "a")
    #expect(try Data(contentsOf: f.events) == before)
  }

  @Test func malformedOptionalFileKeepsHistoryReadableButCannotBeOverwritten() async throws {
    let f = try await ContractFixture.make()
    defer { f.clean() }
    let file = f.package.appendingPathComponent("character_contracts.json")
    let bad = Data(#"{"schema_version":1,"contracts":[{"name":"name-is-not-an-id"}]}"#.utf8)
    try bad.write(to: file)
    #expect(try await f.library.load(storyworldID: f.world).characterContracts == nil)
    #expect(try await f.runtime.load(address: f.address).canonStatus?.state == .unavailable)
    await #expect(throws: CharacterContractError.invalidFile) {
      try await f.library.saveCharacterContracts(
        .init(), storyworldID: f.world, expectedFingerprint: nil)
    }
    #expect(try Data(contentsOf: file) == bad)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(
      at: file, withDestinationURL: f.root.appendingPathComponent("missing"))
    await #expect(throws: CharacterContractError.invalidFile) {
      try await f.library.characterContractState(storyworldID: f.world)
    }
    #expect(try await f.runtime.load(address: f.address).canonStatus?.state == .unavailable)
  }

  @Test func competingEditorsHaveOneWinner() async throws {
    let f = try await ContractFixture.make()
    defer { f.clean() }
    let count = await withTaskGroup(of: Bool.self) { group in
      for n in 0..<8 {
        group.addTask {
          do {
            try await f.library.saveCharacterContracts(
              .init(contracts: [.init(displayName: "版本\(n)")]),
              storyworldID: f.world, expectedFingerprint: nil)
            return true
          } catch { return false }
        }
      }
      var total = 0
      for await result in group { total += result ? 1 : 0 }
      return total
    }
    #expect(count == 1)
    #expect(
      try await f.library.characterContractState(storyworldID: f.world).file.contracts.count == 1)
  }

  @Test func contractCopiesKeepStableIDsAcrossTransfer() async throws {
    let f = try await ContractFixture.make()
    defer { f.clean() }
    let card = CharacterContract(entityID: "stable-a", displayName: "林舟", sourceLibraryID: UUID())
    try await f.library.saveCharacterContracts(
      .init(contracts: [card]), storyworldID: f.world, expectedFingerprint: nil)
    let exported = f.root.appendingPathComponent("export.storyworld")
    _ = try await f.library.exportPackage(storyworldID: f.world, to: exported)
    let copy = try await f.library.importPackage(from: exported, conflictPolicy: .importAsCopy)
    #expect(copy.id != f.world)
    #expect(try await f.library.load(storyworldID: copy.id).characterContracts?.contracts == [card])
  }

  @Test func mentionIsNotPresenceAndConfirmedMembershipSurvivesAbsentNames() throws {
    let a = CharacterContract(entityID: "person.a", displayName: "林舟", speechRules: ["短句"])
    let b = CharacterContract(entityID: "person.b", displayName: "林舟", speechRules: ["文言"])
    let unseen = CharacterContract(
      entityID: "person.c", displayName: "远方人物", immutableTraits: ["UNSEEN_SECRET"])
    let file = CharacterContractFile(contracts: [b, unseen, a])
    let mentioned = try CharacterContractContext.sections(
      file: file, userMessage: "回忆林舟", recentNarrative: "")
    #expect(mentioned.map(\.id) == ["contract.person.a", "contract.person.b"])
    #expect(mentioned.allSatisfy { $0.content.contains("提及不表示在场") })
    #expect(!mentioned.map(\.content).joined().contains("UNSEEN_SECRET"))
    let present = try CharacterContractContext.sections(
      file: file, presentEntityIDs: ["person.a"],
      userMessage: "继续说吧", recentNarrative: "他抬起头。")
    #expect(present.map(\.id) == ["contract.person.a"])
    #expect(present[0].content.contains("当前场景记录中的在场角色"))
    if case .mandatory = present[0].flexibility {
    } else {
      Issue.record("Present contract was optional")
    }
    let huge = CharacterContract(
      entityID: "huge", displayName: "甲",
      immutableTraits: Array(repeating: String(repeating: "内核", count: 200), count: 20))
    let mandatory = try CharacterContractContext.sections(
      file: .init(contracts: [huge]), presentEntityIDs: ["huge"],
      userMessage: "", recentNarrative: "")
    #expect(throws: StoryContextError.mandatoryExceedsBudget) {
      try StoryContextCompiler.compile(
        sections: mandatory, userMessage: "继续", contextWindow: 2048, maximumOutputTokens: 512)
    }
  }
}

private struct ContractFixture: Sendable {
  let root: URL
  let library: StoryworldLibrary
  let package: URL
  let world: UUID
  let runtime: StoryworldRuntimeStore
  let address: SessionAddress
  var events: URL {
    package.appendingPathComponent(
      "playthroughs/\(address.playthroughID.uuidString.lowercased())/branches/\(address.branchID.uuidString.lowercased())/events.jsonl"
    )
  }
  static func make() async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("contracts-\(UUID())")
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.create(lorebook: .init(title: "合成世界"))
    let package = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = await StoryworldRuntimeStoreRegistry.shared.store(forPackageURL: package)
    let line = try await runtime.createPlaythrough(title: "合成线")
    return .init(
      root: root, library: library, package: package, world: record.id, runtime: runtime,
      address: line.address)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}
