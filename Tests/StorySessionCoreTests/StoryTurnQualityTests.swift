import Foundation
import LLMProviderKit
import StoryworldCore
import Testing

@testable import StorySessionCore

@Suite("Bounded turn quality improvements")
struct StoryTurnQualityTests {
  @Test func repairAllowlistRejectsUnknownKeysCollectionsDeletionsTypesAndBadEvidence() throws {
    let state: [String: JSONValue] = [
      "player": .object(["mood": .string("平静"), "hp": .number(10)]),
      "flag": .bool(false), "inventory": .array([.string("钥匙")]),
      "plot": .object(["node": .number(1)]),
      "continuity": .object(["forged": .bool(false)]),
    ]
    let fields = StoryProtocolRepair.allowedFields(in: state, excluding: StoryTurnEngine.engineOwnedStateKeys)
    #expect(Set(fields.map(\.path)) == Set([["flag"], ["player", "hp"], ["player", "mood"]]))
    let evidence = #"<STATE_EVIDENCE>[{"path":["player","mood"],"quote":"心情轻松"}]</STATE_EVIDENCE>"#
    let valid = #"<STATE_PATCH>{"player":{"mood":"轻松"}}</STATE_PATCH>"# + evidence
    #expect(StoryProtocolRepair.validatedPatch(valid, fields: fields, narrative: "他的心情轻松了。") != nil)
    let badPatches = [
      #"{"player":{"mood":null}}"#, #"{"player":{"mood":123}}"#,
      #"{"player":{"mood":"轻松","new":"凭空增加"}}"#,
      #"{"inventory":[]}"#, #"{"plot":{"node":99}}"#, #"{"continuity":{"forged":true}}"#,
      #"{"unknown":"新增"}"#, #"{"player":{}}"#,
    ]
    for patch in badPatches {
      #expect(StoryProtocolRepair.validatedPatch("<STATE_PATCH>" + patch + "</STATE_PATCH>" + evidence,
        fields: fields, narrative: "他的心情轻松了。") == nil)
    }
    #expect(StoryProtocolRepair.validatedPatch(valid, fields: fields, narrative: "他仍然焦虑。") == nil)
    #expect(StoryProtocolRepair.validatedPatch(valid.replacingOccurrences(of: #""mood":"轻松""#, with: #""mood":"激动""#),
      fields: fields, narrative: "他的心情轻松了。") == nil)
    #expect(StoryProtocolRepair.validatedPatch(
      #"<STATE_PATCH>{"player":{"hp":99}}</STATE_PATCH><STATE_EVIDENCE>[{"path":["player","hp"],"quote":"体力10"}]</STATE_EVIDENCE>"#,
      fields: fields, narrative: "体力10") == nil)
    #expect(StoryProtocolRepair.validatedPatch(
      #"<STATE_PATCH>{"player":{"mood":"轻松"}}</STATE_PATCH><STATE_EVIDENCE>[]</STATE_EVIDENCE>"#,
      fields: fields, narrative: "心情轻松") == nil)
  }

  @Test func missingChoicesAndPatchShareOneRepairWithInputAndOldState() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    _ = try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "开始", narrative: "他原本心情平静。",
      statePatchData: Data(#"{"player":{"mood":"平静","hp":10}}"#.utf8))
    let before = try await f.runtime.load(address: f.address)
    let provider = QualityProvider(responses: [
      "<STORY>听到答复后，他的心情轻松了。</STORY><MEMORY_PATCH>{}</MEMORY_PATCH>",
      #"<CHOICES>["想一想刚才的答复","继续听下去"]</CHOICES><STATE_PATCH>{"player":{"mood":"轻松"}}</STATE_PATCH><STATE_EVIDENCE>[{"path":["player","mood"],"quote":"心情轻松"}]</STATE_EVIDENCE>"#,
    ])
    let result = try await run(f, provider: provider, snapshot: before)
    #expect(provider.requests.count == 2)
    #expect(result.snapshot.turns.count == before.turns.count + 1)
    #expect(result.snapshot.turns.last?.statePatch["player"] == .object(["mood": .string("轻松")]))
    #expect(result.choices == ["想一想刚才的答复", "继续听下去"])
    #expect(result.warnings.contains { $0.contains("既有字段") })
    #expect(!result.warnings.contains { $0.contains("状态保持不变") })
    let repair = provider.requests[1]
    let contents = repair.messages.map(\.content).joined()
    #expect(contents.contains("请他解释清楚") && contents.contains("平静") && contents.contains("心情轻松"))
    #expect(contents.contains("禁止新增键") && contents.contains("STATE_EVIDENCE"))
  }

  @Test func failedRepairNeverInventsStateAndDoesNotRepeat() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    _ = try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "开始", narrative: "原地等待",
      statePatchData: Data(#"{"mood":"平静"}"#.utf8))
    let before = try await f.runtime.load(address: f.address)
    let provider = QualityProvider(responses: [
      "<STORY>他仍在等待。</STORY><MEMORY_PATCH>{}</MEMORY_PATCH>",
      #"<STATE_PATCH>{"mood":"激动","inventory":["新物品"]}</STATE_PATCH><STATE_EVIDENCE>[{"path":["mood"],"quote":"仍在等待"}]</STATE_EVIDENCE>"#,
    ])
    let result = try await run(f, provider: provider, snapshot: before)
    #expect(provider.requests.count == 2)
    #expect(result.snapshot.state.values == before.state.values)
    #expect(result.choices.count == 2 && result.choices[1].contains("等待"))
    #expect(result.snapshot.turns.last?.narrative == "他仍在等待。")
  }

  @Test func patchRepairWorksAfterOpeningAndSkipsWhenNoSafeFieldOrBudget() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    for index in 1...3 {
      _ = try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "开始", narrative: "原地等待",
        statePatchData: Data((index == 1 ? #"{"mood":"平静"}"# : "{}").utf8))
    }
    let before = try await f.runtime.load(address: f.address)
    let provider = QualityProvider(responses: [
      "<STORY>心情轻松了。</STORY><MEMORY_PATCH>{}</MEMORY_PATCH>",
      #"<STATE_PATCH>{"mood":"轻松"}</STATE_PATCH><STATE_EVIDENCE>[{"path":["mood"],"quote":"心情轻松"}]</STATE_EVIDENCE>"#,
    ])
    let result = try await run(f, provider: provider, snapshot: before)
    #expect(provider.requests.count == 2 && result.snapshot.state.values["mood"] == .string("轻松"))
    #expect(result.choices.isEmpty)
    let unused = QualityProvider(responses: [])
    let skipped = try await StoryProtocolRepair.repair(provider: unused, narrative: "叙事", userMessage: "输入",
      state: [:], reserved: [], needsChoices: false, needsPatch: true)
    #expect(unused.requests.isEmpty && skipped.statePatch == nil)
    let huge = try await StoryProtocolRepair.repair(provider: unused,
      narrative: String(repeating: "超长叙事", count: 30_000), userMessage: "输入",
      state: ["mood": .string("平静")], reserved: [], needsChoices: true, needsPatch: true)
    #expect(unused.requests.isEmpty && huge.choices.isEmpty && huge.statePatch == nil)
  }

  @Test func contextualFallbackAvoidsUnrevealedMetadataAndCompletedOutcomes() {
    let travel = StoryFallbackChoices.choices(narrative: "你抵达渡口。")
    let discussion = StoryFallbackChoices.choices(narrative: "他问道：为什么要这样做？")
    let clue = StoryFallbackChoices.choices(narrative: "纸上留着清晰的字迹。")
    #expect(travel != discussion && discussion != clue)
    let calm = StoryFallbackChoices.choices(narrative: "这里没有危险。他想起曾经被人追赶。")
    #expect(!calm.joined().contains("危险"))
    #expect(!travel.joined().contains("获得") && !clue.joined().contains("破解"))
    #expect(StoryFallbackChoices.choices(narrative: "宮门", revealedBeat: "已知章节").allSatisfy { $0.contains("已知章节") })
  }

  @Test func advancePlanUsesOneTurnAndPersistsOnlyTheDirectiveLabel() async throws {
    #expect(StoryAdvancePlan(targetCharacters: -1).targetCharacters == 600)
    #expect(StoryAdvancePlan(targetCharacters: 100_000).targetCharacters == 2_400)
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let before = try await f.runtime.load(address: f.address)
    let prompt = StoryAdvancePlan(targetCharacters: 1_200).prompt
    let provider = QualityProvider(responses: [
      #"<STORY>林舟等到天亮，接下来需要你决定。</STORY><CHOICES>["继续等待","先想清楚"]</CHOICES><STATE_PATCH>{}</STATE_PATCH><MEMORY_PATCH>{}</MEMORY_PATCH>"#
    ])
    let document = try await f.library.load(storyworldID: f.world)
    for try await _ in StoryTurnEngine(recapInterval: 0).runTurn(provider: provider, runtime: f.runtime,
      storyworld: document, snapshot: before, userMessage: prompt,
      commitUserMessage: "（系统指令：导演·自动推进）", turnID: UUID(), isCorrectionRetry: false) {}
    #expect(provider.requests.count == 1)
    #expect(provider.requests[0].messages.last?.content == prompt)
    #expect(provider.requests[0].modelOptions.maximumOutputTokens != nil)
    let loaded = try await f.runtime.load(address: f.address)
    #expect(loaded.turns.count == 1 && loaded.turns[0].userMessage == "（系统指令：导演·自动推进）")
    #expect(!loaded.turns[0].narrative.contains("1/6"))
  }

  @Test func cancellingRepairKeepsTheEntireTurnUncommitted() async throws {
    let f = try await MemoryFixture.make()
    defer { f.clean() }
    let before = try await f.runtime.load(address: f.address)
    let provider = QualityProvider(responses: [
      "<STORY>天亮了。</STORY><STATE_PATCH>{}</STATE_PATCH><MEMORY_PATCH>{}</MEMORY_PATCH>", ""
    ], cancelAt: 1)
    await #expect(throws: CancellationError.self) {
      try await run(f, provider: provider, snapshot: before)
    }
    #expect(try await f.runtime.load(address: f.address).turns == before.turns)
  }

  private func run(_ f: MemoryFixture, provider: QualityProvider, snapshot: StorySessionSnapshot) async throws -> StoryTurnResult {
    let document = try await f.library.load(storyworldID: f.world)
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine(recapInterval: 0).runTurn(provider: provider, runtime: f.runtime,
      storyworld: document, snapshot: snapshot, userMessage: "请他解释清楚",
      turnID: UUID(), isCorrectionRetry: false) {
      if case .completed(let value) = event { result = value }
    }
    return try #require(result)
  }
}

private final class QualityProvider: LLMProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [LLMRequest] = []
  private let responses: [String]
  private let cancelAt: Int?
  init(responses: [String], cancelAt: Int? = nil) { self.responses = responses; self.cancelAt = cancelAt }
  var requests: [LLMRequest] { lock.withLock { recorded } }
  var profile: ProviderProfile {
    .init(displayName: "本地协议测试", kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!, modelID: "test", credentialReference: "test")
  }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    let reply: (String?, Bool) = lock.withLock {
      let index = recorded.count
      recorded.append(request)
      return (responses.indices.contains(index) ? responses[index] : nil, index == cancelAt)
    }
    return AsyncThrowingStream { continuation in
      if reply.1 { continuation.finish(throwing: CancellationError()) }
      else if let response = reply.0 {
        continuation.yield(.textDelta(response)); continuation.yield(.completed); continuation.finish()
      } else { continuation.finish(throwing: URLError(.badServerResponse)) }
    }
  }
}
