import Foundation
import StoryworldCore

enum ContinuityContext {
  static let protocolSection = StoryContextSection(
    id: "protocol.continuity",
    content: """

      在上述回复格式末尾追加 <MEMORY_PATCH>{连续性变更}</MEMORY_PATCH>；没有变更返回 {}。
      只记录本轮正文明确写出的变化，quote 必须逐字摘自本轮 STORY（1–300 字），不可把猜测、回忆、假设或被否定的行动当成已发生。
      顶层只支持 entities、scene、facts、resolutions、knowledge，可省略未改变部分。字段格式如下：
      entities:[{"key":"new.local-key","name":"名称","kind":"character/item/place/group","quote":"引文"}]
      scene:{"location":"地点","time":"时间","presentEntityIDs":["人物ID"],"quote":"引文"}
      facts:[{"kind":"condition/relationship/possession/promise/secret/goal/unresolved","subjectID":"主体ID","objectID":"对象ID（可省略）","slot":"状态位置英文键","statement":"事实","knownByEntityIDs":["明确知情的人物ID"],"quote":"引文","replacesFactID":"明确替代的旧事实ID（可省略）"}]
      resolutions:[{"factID":"已有事实ID","status":"fulfilled/broken/released/resolved","quote":"引文"}]
      knowledge:[{"factID":"已有事实ID","entityID":"人物ID","operation":"learn/forget","quote":"明确获知或遗忘的引文"}]
      斜线表示枚举选一项，不要原样输出斜线。玩家 ID 固定 player；使用已给定的实体 ID，新增实体用 new. 前缀的局部 key；不要用名字合并人物。不要生成事实 ID、事件来源或修改静态角色契约。
      possession 的 objectID 必须指物品；转移时用 replacesFactID 指旧持有记录。condition、relationship 同一状态位置发生变化也须明确替代。承诺只能 fulfilled/broken/released，不能删除或替代；其他事实可 resolved/released。仅同处一场景不会传播秘密；知情默认不减少，遗忘必须单独记录。每类数组最多 16 项，scene 最多 16 人，statement 最多 500 字。
      """, flexibility: .mandatory)

  static func sections(_ snapshot: ContinuitySnapshot) throws -> [StoryContextSection] {
    let ledger = snapshot.ledger
    let present = Set(ledger.scene?.presentEntityIDs ?? []).union(["player"])
    // Relevant state remains whole and required. Finished facts remain in the ledger
    // and their original events; they do not consume every later request's budget.
    let facts = ledger.activeFacts.filter {
      $0.kind == .promise || $0.kind == .secret || present.contains($0.subjectID)
        || $0.objectID.map(present.contains) == true
    }
    var ids = present
    for fact in facts {
      ids.insert(fact.subjectID)
      if let object = fact.objectID { ids.insert(object) }
      ids.formUnion(fact.knownByEntityIDs)
    }
    struct RegistryEntry: Encodable {
      let id: String
      let name: String
      let kind: ContinuityEntityKind
      let provisional: Bool
    }
    struct Packet: Encodable {
      let scene: SceneContinuity?
      let entities: [RegistryEntry]
      let facts: [ContinuityFact]
      let legacyTurns: Int
      let unresolvedTurns: Int
      let recentCalibrations: [ContinuityCalibrationReceipt]
    }
    let packet = Packet(
      scene: ledger.scene,
      entities: ids.sorted().compactMap { id in
        ledger.entities[id].map {
          .init(id: id, name: $0.name, kind: $0.kind, provisional: $0.provisional)
        }
      }, facts: facts, legacyTurns: ledger.legacyTurnCount,
      unresolvedTurns: ledger.unresolvedTurnCount,
      recentCalibrations: Array((ledger.calibrations ?? []).suffix(8)))
    let data = try StoryworldCoding.makeEncoder().encode(packet)
    return [
      .init(
        id: "continuity.current",
        content: "\n当前连续性记录（模型提取已通过结构和来源校验，语义仍需核对；有缺口不表示没有发生变化）：\n"
          + String(decoding: data, as: UTF8.self)
          + "\n遵循每条事实的 knownByEntityIDs；不在其中的人不能据此行动或说出秘密，也不要向不知情的玩家直接揭露。provisional 实体尚未确认身份；不得按同名合并。calibrationID 表示玩家已确认的校准，校准仅约束后续回合；旧正文和摘要不因校准而改变，遇到冲突以当前已校准记录为准。不要把撤回的错误记录当成新的剧情事件。\n",
        flexibility: .mandatory)
    ]
  }
}
