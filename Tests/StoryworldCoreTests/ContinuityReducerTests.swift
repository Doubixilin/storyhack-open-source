import Foundation
import Testing

@testable import StoryworldCore

@Suite("Continuous memory finite operations")
struct ContinuityReducerTests {
  private let contracts = [
    CharacterContract(entityID: "lin", displayName: "林舟"),
    CharacterContract(entityID: "wen", displayName: "温宁"),
  ]

  @Test func twentyTurnChineseSpikePreservesSceneKnowledgeItemsAndPromises() throws {
    let branch = UUID()
    var ledger = ContinuityLedger()
    let first = ref(branch, 1)
    let text = "林舟在渡口接过铜钥匙，答应天亮归还。温宁在远方，不知此事。"
    let draft = ContinuityDelta(
      entities: [.init(key: "new.key", name: "铜钥匙", kind: .item, quote: "接过铜钥匙")],
      scene: .init(
        location: "渡口", time: "夜晚", presentEntityIDs: ["player", "lin"], quote: "林舟在渡口"),
      facts: [
        .init(
          kind: .possession, subjectID: "lin", objectID: "new.key", slot: "holder",
          statement: "林舟保管铜钥匙",
          knownByEntityIDs: ["player", "lin"], quote: "接过铜钥匙"),
        .init(
          kind: .promise, subjectID: "lin", objectID: "player", slot: "return-key",
          statement: "天亮归还铜钥匙",
          knownByEntityIDs: ["player", "lin"], quote: "答应天亮归还"),
        .init(
          kind: .secret, subjectID: "lin", slot: "key-secret", statement: "钥匙在林舟手里",
          knownByEntityIDs: ["player", "lin"], quote: "接过铜钥匙"),
      ])
    ledger = try commit(draft, ledger: ledger, source: first, narrative: text)
    let promise = try #require(ledger.facts.values.first { $0.kind == .promise })
    let item = try #require(ledger.facts.values.first { $0.kind == .possession })
    let secret = try #require(ledger.facts.values.first { $0.kind == .secret })
    for n in 2...19 {
      ledger = try commit(.init(), ledger: ledger, source: ref(branch, n), narrative: "他沉默片刻，仍在等待。")
        .validated()
      #expect(ledger.scene?.presentEntityIDs == ["lin", "player"])
      #expect(ledger.facts[secret.id]?.knownByEntityIDs.contains("wen") == false)
      #expect(ledger.facts[promise.id]?.evidence.first?.event == first)
    }
    let end = ref(branch, 20)
    ledger = try commit(
      .init(
        facts: [
          .init(
            kind: .possession, subjectID: "player", objectID: item.objectID, slot: "holder",
            statement: "玩家收回铜钥匙", knownByEntityIDs: ["lin", "player"], quote: "归还铜钥匙",
            replacesFactID: item.id)
        ],
        resolutions: [.init(factID: promise.id, status: .fulfilled, quote: "归还铜钥匙")]),
      ledger: ledger, source: end, narrative: "天亮了，林舟如约归还铜钥匙。")
    #expect(ledger.facts[promise.id]?.status == .fulfilled)
    #expect(ledger.facts[promise.id]?.evidence.first?.event == first)
    #expect(ledger.facts[promise.id]?.evidence.last?.event == end)
    #expect(ledger.facts[item.id]?.status == .superseded)
    #expect(ledger.activeFacts.first { $0.kind == .possession }?.subjectID == "player")
    #expect(ledger.legacyTurnCount == 0 && ledger.unresolvedTurnCount == 0)
  }

  @Test func knowledgeRequiresExplicitLearningAndExplicitForgetting() throws {
    let branch = UUID()
    var ledger = try commit(
      .init(
        scene: .init(
          location: "厅堂", time: "午后", presentEntityIDs: ["lin", "wen"], quote: "两人同在厅堂"),
        facts: [
          .init(
            kind: .secret, subjectID: "lin", slot: "letter", statement: "信藏在抽屉里",
            knownByEntityIDs: ["lin"], quote: "林舟独自知道信的下落")
        ]), ledger: .init(), source: ref(branch, 1),
      narrative: "两人同在厅堂。林舟独自知道信的下落。")
    let fact = try #require(ledger.activeFacts.first)
    #expect(fact.knownByEntityIDs == ["lin"])
    ledger = try commit(
      .init(knowledge: [
        .init(
          factID: fact.id, entityID: "wen", operation: .learn,
          quote: "林舟告诉温宁信在抽屉")
      ]), ledger: ledger, source: ref(branch, 2), narrative: "林舟告诉温宁信在抽屉。")
    #expect(ledger.facts[fact.id]?.knownByEntityIDs == ["lin", "wen"])
    ledger = try commit(
      .init(knowledge: [
        .init(
          factID: fact.id, entityID: "wen", operation: .forget,
          quote: "温宁失去了关于信的记忆")
      ]), ledger: ledger, source: ref(branch, 3), narrative: "温宁失去了关于信的记忆。")
    #expect(ledger.facts[fact.id]?.knownByEntityIDs == ["lin"])
    #expect(ledger.facts[fact.id]?.evidence.count == 3)
  }

  @Test func fortyMalformedProposalsAreRejectedAsWholeTransactions() throws {
    var malformed = [String]()
    for field in [
      "deleteFacts", "immutableTraits", "plot", "knownBy", "characterUpdates", "source", "id",
      "status",
    ] {
      malformed.append("{\"\(field)\":{}}")
    }
    for field in ["entities", "facts", "resolutions", "knowledge"] {
      for value in ["null", "3", "\"wrong\"", "{}"] { malformed.append("{\"\(field)\":\(value)}") }
    }
    for raw in [
      #"{"scene":[]}"#, #"{"scene":"渡口"}"#,
      #"{"scene":{"location":"渡口","time":"夜","presentEntityIDs":[],"quote":"风起","id":"forged"}}"#,
      #"{"entities":[{"key":"lin","name":"林舟","kind":"character","quote":"风起"}]}"#,
      #"{"entities":[{"key":"new.lin","name":"林舟","kind":"unknown","quote":"风起"}]}"#,
      #"{"entities":[{"key":"new.lin","name":"林舟","kind":"character","quote":"并不存在"}]}"#,
      #"{"facts":[{"kind":"static","subjectID":"lin","slot":"identity","statement":"新身份","knownByEntityIDs":[],"quote":"风起"}]}"#,
      #"{"facts":[{"kind":"secret","subjectID":"ghost","slot":"a","statement":"秘密","knownByEntityIDs":[],"quote":"风起"}]}"#,
      #"{"facts":[{"kind":"secret","subjectID":"lin","slot":"a","statement":"秘密","knownByEntityIDs":["ghost"],"quote":"风起"}]}"#,
      #"{"resolutions":[{"factID":"missing","status":"fulfilled","quote":"风起"}]}"#,
      #"{"knowledge":[{"factID":"missing","entityID":"lin","operation":"learn","quote":"风起"}]}"#,
      #"{"scene":{"location":"渡口","time":"夜","presentEntityIDs":["ghost"],"quote":"风起"}}"#,
      #"{"scene":{"location":"渡口","time":"夜","presentEntityIDs":["lin","lin"],"quote":"风起"}}"#,
      #"{"facts":[{"kind":"promise","subjectID":"lin","slot":"a","statement":"承诺","knownByEntityIDs":[],"quote":"风起","id":"forged"}]}"#,
      #"{"facts":[{"kind":"possession","subjectID":"lin","objectID":"wen","slot":"holder","statement":"错误物品","knownByEntityIDs":[],"quote":"风起"}]}"#,
      #"{"entities":[{"key":"new.a","name":"","kind":"item","quote":"风起"}]}"#,
    ] { malformed.append(raw) }
    #expect(malformed.count == 40)
    let ledger = ContinuityLedger()
    for raw in malformed {
      let update = ContinuityReducer.prepare(
        input: .init(data: Data(raw.utf8)), ledger: ledger,
        source: ref(UUID(), 1), narrative: "风起", contracts: contracts)
      #expect(update.status == .needsReconciliation, "Rejected input: \(raw)")
      #expect(update.delta == nil)
    }
    // A valid first operation must not survive an invalid second one.
    let partial = ContinuityDelta(
      scene: .init(location: "渡口", time: "夜", presentEntityIDs: ["lin"], quote: "风起"),
      resolutions: [.init(factID: "missing", status: .fulfilled, quote: "风起")])
    let update = ContinuityReducer.prepare(
      input: .init(data: try JSONEncoder().encode(partial)), ledger: ledger,
      source: ref(UUID(), 1), narrative: "风起", contracts: contracts)
    #expect(update.delta == nil)
    #expect(ledger == ContinuityLedger())
  }

  @Test func promisesCannotBeDeletedOrSilentlyReplacedAndSlotsRequireExplicitReplacement() throws {
    let b = UUID()
    let ledger = try commit(
      .init(facts: [
        .init(
          kind: .promise, subjectID: "lin", slot: "return", statement: "会回来", knownByEntityIDs: [],
          quote: "会回来"),
        .init(
          kind: .condition, subjectID: "lin", slot: "left-arm", statement: "左臂受伤",
          knownByEntityIDs: [], quote: "左臂受伤"),
      ]), ledger: .init(), source: ref(b, 1), narrative: "他左臂受伤，但答应会回来。")
    let promise = try #require(ledger.activeFacts.first { $0.kind == .promise })
    let condition = try #require(ledger.activeFacts.first { $0.kind == .condition })
    for status in [ContinuityFactStatus.active, .superseded, .resolved] {
      let draft = ContinuityDelta(resolutions: [
        .init(factID: promise.id, status: status, quote: "风起")
      ])
      #expect(
        try update(draft, ledger: ledger, source: ref(b, 2), narrative: "风起").status
          == .needsReconciliation)
    }
    let collision = ContinuityDelta(facts: [
      .init(
        kind: .condition, subjectID: "lin", slot: "left-arm",
        statement: "左臂康复", knownByEntityIDs: [], quote: "左臂康复")
    ])
    #expect(
      try update(collision, ledger: ledger, source: ref(b, 2), narrative: "左臂康复").issue
        == "slotConflict")
    var replacement = collision
    replacement.facts[0].replacesFactID = condition.id
    let recovered = try commit(replacement, ledger: ledger, source: ref(b, 2), narrative: "左臂康复")
    #expect(recovered.facts[condition.id]?.status == .superseded)
    #expect(recovered.facts[promise.id]?.status == .active)
  }

  @Test func sameNamesRemainIndependentAndFactsRetainFirstSourceAtTurn120() throws {
    let b = UUID()
    let first = ref(b, 1)
    var ledger = try commit(
      .init(
        entities: [
          .init(key: "new.one", name: "小林", kind: .character, quote: "两个小林"),
          .init(key: "new.two", name: "小林", kind: .character, quote: "两个小林"),
        ],
        facts: [
          .init(
            kind: .promise, subjectID: "new.one", objectID: "new.two", slot: "meet",
            statement: "明日重逢", knownByEntityIDs: ["new.one"], quote: "明日重逢")
        ]),
      ledger: .init(), source: first, narrative: "两个小林约好明日重逢。")
    let fact = try #require(ledger.activeFacts.first)
    #expect(fact.subjectID != fact.objectID)
    #expect(ledger.entities.values.filter { $0.name == "小林" }.count == 2)
    #expect(ledger.entities[fact.subjectID]?.provisional == true)
    for n in 2...120 {
      ledger = try commit(.init(), ledger: ledger, source: ref(b, n), narrative: "旅程继续。")
    }
    #expect(ledger.facts[fact.id]?.evidence.first?.event == first)
    #expect(ledger.facts[fact.id]?.knownByEntityIDs == [fact.subjectID])
    let decoded = try JSONDecoder().decode(
      ContinuityLedger.self, from: JSONEncoder().encode(ledger))
    #expect(try decoded.fingerprint() == ledger.fingerprint())
  }

  private func ref(_ branch: UUID, _ sequence: Int) -> StoryAnchorEventRef {
    .init(branchID: branch, sequence: sequence, turnID: UUID())
  }
  private func update(
    _ draft: ContinuityDelta, ledger: ContinuityLedger, source: StoryAnchorEventRef,
    narrative: String
  ) throws -> ContinuityUpdate {
    ContinuityReducer.prepare(
      input: .init(data: try JSONEncoder().encode(draft)), ledger: ledger,
      source: source, narrative: narrative, contracts: contracts)
  }
  private func commit(
    _ draft: ContinuityDelta, ledger: ContinuityLedger, source: StoryAnchorEventRef,
    narrative: String
  ) throws -> ContinuityLedger {
    let u = try update(draft, ledger: ledger, source: source, narrative: narrative)
    #expect(u.status == .recorded)
    return try ContinuityReducer.apply(u, to: ledger, source: source)
  }
}

extension ContinuityLedger {
  fileprivate func validated() throws -> Self {
    try ContinuityReducer.validateLedger(self)
    return self
  }
}
