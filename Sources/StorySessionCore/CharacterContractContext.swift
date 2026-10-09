import Foundation
import StoryworldCore

enum CharacterContractContext {
  /// Confirmed scene membership comes from runtime continuity, not name matching.
  /// Mentioned characters can supply a reference card without being put in the scene.
  static func sections(
    file: CharacterContractFile?, presentEntityIDs: Set<String> = [],
    userMessage: String, recentNarrative: String
  ) throws -> [StoryContextSection] {
    guard let file, !file.contracts.isEmpty else { return [] }
    try file.validate()
    let referenced = file.contracts.filter { contract in
      ([contract.displayName] + contract.aliases).contains { name in
        userMessage.localizedCaseInsensitiveContains(name)
          || recentNarrative.localizedCaseInsensitiveContains(name)
      }
    }.sorted { $0.entityID < $1.entityID }
    let present = file.contracts.filter { presentEntityIDs.contains($0.entityID) }
      .sorted { $0.entityID < $1.entityID }
    let selected = present + referenced.filter { !presentEntityIDs.contains($0.entityID) }.prefix(6)
    return try selected.map { contract in
      let data = try StoryworldCoding.makeEncoder().encode(contract)
      let status =
        presentEntityIDs.contains(contract.entityID)
          ? "当前场景记录中的在场角色；模型提取的在场记录仍需核对"
        : "本轮提及角色的静态参考；提及不表示在场、已知秘密或已发生关系"
      return StoryContextSection(
        id: "contract." + contract.entityID,
        content: "\n角色契约（\(status)）：\n" + String(decoding: data, as: UTF8.self)
          + "\n按 entity_id 区分同名角色；契约是静态约束，示例台词只示范表达方式。\n",
        priority: 25,
        flexibility: presentEntityIDs.contains(contract.entityID) ? .mandatory : .whole)
    }
  }
}
