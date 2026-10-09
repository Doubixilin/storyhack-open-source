import CharacterLibraryCore
import Foundation
import StoryworldCore
import Testing

@testable import WorldbookUI

@MainActor
struct CharacterContractProjectionTests {
  @Test func explicitPreviewCopiesOnlyChosenStaticFieldsAndLaterEditsStayLocal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "contract-copy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let a = try await library.create(lorebook: .init(title: "甲"))
    let b = try await library.create(lorebook: .init(title: "乙"))
    let model = StoryworldViewModel(library: library)
    var profile = CharacterProfile(
      name: "林舟",
      fields: .init(
        personality: "谨慎\n守信", speechStyle: "短句", background: "不自动复制的经历", notes: "未核验的秘密"),
      promptProfile: "不复制的生成提示")
    var preview = CharacterContractProjection.preview(profile)
    #expect(preview.immutableTraits == ["谨慎", "守信"])
    #expect(preview.speechRules == ["短句"])
    #expect(try await model.characterContractState(a.id).file.contracts.isEmpty)
    // Editing the target preview does not mutate the source character profile.
    preview.neverDo = ["不会失约"]
    try await model.saveCharacterContracts(
      .init(contracts: [preview]), storyworldID: a.id, expectedFingerprint: nil)
    profile.fields.personality = "改变后的角色库性格"
    #expect(
      try await model.characterContractState(a.id).file.contracts.first?.immutableTraits == [
        "谨慎", "守信",
      ])
    #expect(try await model.characterContractState(b.id).file.contracts.isEmpty)
    let current = try await model.characterContractState(a.id)
    profile.name = "林远舟"
    let updated = CharacterContractProjection.preview(
      profile, existing: current.file.contracts.first)
    #expect(updated.entityID == preview.entityID)
    #expect(updated.neverDo == preview.neverDo)
    #expect(updated.sourceLibraryID == profile.id)
    try await model.saveCharacterContracts(
      .init(contracts: [updated]), storyworldID: a.id,
      expectedFingerprint: current.fingerprint)
    await #expect(throws: CharacterContractError.staleRevision) {
      try await model.saveCharacterContracts(
        current.file, storyworldID: a.id,
        expectedFingerprint: current.fingerprint)
    }
    let saved = try await model.characterContractState(a.id).file
    let text = String(decoding: try StoryworldCoding.makeEncoder().encode(saved), as: UTF8.self)
    #expect(!text.contains("不自动复制的经历"))
    #expect(!text.contains("未核验的秘密"))
    #expect(!text.contains("不复制的生成提示"))
    #expect(saved.contracts.first?.displayName == "林远舟")
  }
}
