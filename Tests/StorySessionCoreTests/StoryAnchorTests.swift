import Foundation
import StoryworldCore
import Testing

@testable import StorySessionCore

@Suite("Branch-local player anchors")
struct StoryAnchorTests {
  @Test func mutationsUseSidecarCASAndNeverRewriteEvents() async throws {
    let f = try await AnchorFixture.make()
    defer { f.clean() }
    let turn = try await f.commit("铜钥匙交给林舟保管。")
    let bytes = try Data(contentsOf: f.events(f.address))
    let anchor = StoryAnchor(eventRef: .init(turn), kind: .pledge, label: "铜钥匙", note: "记得归还")
    #expect(anchor.eventRef.turnID == turn.turnID)
    #expect(anchor.eventRef.turnID != turn.id)
    try await f.runtime.saveAnchor(anchor, address: f.address, expectedRevision: nil)
    let state = try await f.runtime.load(address: f.address).anchorState
    #expect(state.anchors.count == 1)
    var updated = try #require(state.anchors.first)
    updated.label = "保管承诺"
    updated.enabled = false
    await #expect(throws: StoryAnchorError.staleRevision) {
      try await f.runtime.saveAnchor(updated, address: f.address, expectedRevision: nil)
    }
    try await f.runtime.saveAnchor(updated, address: f.address, expectedRevision: state.revision)
    let after = try await f.runtime.load(address: f.address).anchorState
    #expect(after.anchors.first?.enabled == false)
    #expect(after.anchors.first?.createdAt == state.anchors.first?.createdAt)
    await #expect(throws: StoryAnchorError.staleRevision) {
      try await f.runtime.removeAnchor(
        id: anchor.id, address: f.address, expectedRevision: state.revision)
    }
    try await f.runtime.removeAnchor(
      id: anchor.id, address: f.address, expectedRevision: after.revision)
    #expect(try await f.runtime.load(address: f.address).anchorState.anchors.isEmpty)
    #expect(try Data(contentsOf: f.events(f.address)) == bytes)
  }

  @Test func forksCopyOnlyExperiencedAnchorsAndThenEvolveIndependently() async throws {
    let f = try await AnchorFixture.make()
    defer { f.clean() }
    let first = try await f.commit("先前的承诺")
    _ = try await f.commit("路过")
    let future = try await f.commit("后来的秘密")
    let initial = try await f.add(first, label: "先前承诺")
    _ = try await f.add(future, label: "未来秘密")
    let child = try await f.runtime.forkBranch(
      address: f.address, atEventSequence: 1, title: "提前分叉")
    let childState = try await f.runtime.load(address: child.address).anchorState
    #expect(childState.anchors.map(\.id) == [initial.id])
    let childTurn = try await f.commit("孩子自己的回合", address: child.address)
    #expect(childTurn.sequence == first.sequence)
    let childAnchor = try await f.add(childTurn, label: "支线锚点", address: child.address)
    let grandchild = try await f.runtime.forkBranch(
      address: child.address, atEventSequence: 0, title: "再次提前分叉")
    let grand = try await f.runtime.load(address: grandchild.address)
    #expect(grand.anchorState.anchors.map(\.id) == [initial.id])
    #expect(!grand.anchorState.anchors.contains(where: { $0.id == childAnchor.id }))
    var parentEdit = initial
    parentEdit.label = "父分支后改"
    let parentRevision = try await f.runtime.load(address: f.address).anchorState.revision
    try await f.runtime.saveAnchor(parentEdit, address: f.address, expectedRevision: parentRevision)
    #expect(
      try await f.runtime.load(address: child.address).anchorState.anchors.contains(where: {
        $0.label == "先前承诺"
      }))
    #expect(
      try await f.runtime.load(address: grandchild.address).anchorState.anchors.first?.label
        == "先前承诺")
    let saved = try await f.runtime.createSave(address: f.address, atEventSequence: 1, title: "旧位置")
    let restored = try await f.runtime.restoreSaveAsNewBranch(
      address: f.address, saveID: saved.id, title: "从旧存档继续")
    #expect(
      try await f.runtime.load(address: restored.address).anchorState.anchors.map(\.id) == [
        initial.id
      ])
  }

  @Test func futureSiblingAndForgedReferencesCannotEnterContext() async throws {
    let f = try await AnchorFixture.make()
    defer { f.clean() }
    let first = try await f.commit("允许的历史")
    let child = try await f.runtime.forkBranch(address: f.address, title: "子分支")
    let future = try await f.commit("父分支后来的秘密")
    let sibling = try await f.runtime.forkBranch(
      address: f.address, atEventSequence: 1, title: "兄弟分支")
    let siblingTurn = try await f.commit("兄弟秘密", address: sibling.address)
    for forbidden in [future, siblingTurn] {
      await #expect(throws: StoryAnchorError.invalidReference) {
        try await f.runtime.saveAnchor(
          StoryAnchor(eventRef: .init(forbidden), label: "不准越界"),
          address: child.address, expectedRevision: nil)
      }
    }
    _ = try await f.add(first, label: "可用", address: child.address)
    let file = f.anchorFile(child.address)
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var anchors = try #require(object["anchors"] as? [[String: Any]])
    let poisoned = StoryAnchor(
      eventRef: .init(siblingTurn), label: "SIBLING_SECRET", note: "不能进入上下文")
    anchors.append(
      try #require(
        JSONSerialization.jsonObject(with: StoryworldCoding.makeEncoder().encode(poisoned))
          as? [String: Any]))
    object["anchors"] = anchors
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    let snapshot = try await f.runtime.load(address: child.address)
    #expect(snapshot.anchorState.anchors.count == 1)
    #expect(snapshot.anchorState.notice != nil)
    let context = StoryAnchorContext.sections(snapshot: snapshot, userMessage: "SIBLING_SECRET")
      .map(\.content).joined()
    #expect(!context.contains("SIBLING_SECRET"))
    #expect(!context.contains("兄弟秘密"))
  }

  @Test func corruptAnnotationsAreNotSilentlyOverwrittenOrCopied() async throws {
    let f = try await AnchorFixture.make()
    defer { f.clean() }
    let turn = try await f.commit("可阅读的故事")
    let broken = Data("cannot decode user notes".utf8)
    try broken.write(to: f.anchorFile(f.address))
    let snapshot = try await f.runtime.load(address: f.address)
    #expect(snapshot.turns.count == 1)
    #expect(snapshot.anchorState.notice != nil)
    await #expect(throws: StoryAnchorError.unreadable) {
      try await f.runtime.saveAnchor(
        StoryAnchor(eventRef: .init(turn), label: "新注解"), address: f.address, expectedRevision: nil)
    }
    await #expect(throws: StoryAnchorError.unreadable) {
      try await f.runtime.forkBranch(address: f.address, title: "不可丢失原注解")
    }
    #expect(try Data(contentsOf: f.anchorFile(f.address)) == broken)
    #expect(try await f.runtime.listBranches(playthroughID: f.address.playthroughID).count == 1)
  }

  @Test func annotationsRoundTripThroughExportAndImportAsCopy() async throws {
    let f = try await AnchorFixture.make()
    defer { f.clean() }
    let turn = try await f.commit("分享的原文")
    let anchor = try await f.add(turn, label: "分享锚点")
    let exported = try await f.library.exportPackage(
      storyworldID: f.address.storyworldID,
      to: f.root.appendingPathComponent("shared.storyworld"))
    let copy = try await f.library.importPackage(from: exported, conflictPolicy: .importAsCopy)
    let copiedURL = try await f.library.managedPackageURL(storyworldID: copy.id)
    let copiedRuntime = StoryworldRuntimeStore(packageURL: copiedURL)
    let loaded = try await copiedRuntime.loadActive(playthroughID: f.address.playthroughID)
    #expect(loaded.anchorState.anchors.map(\.id) == [anchor.id])
    #expect(loaded.anchorState.anchors.first?.eventRef == anchor.eventRef)
    #expect(loaded.effectiveTurns.first?.address.storyworldID == copy.id)
    #expect(loaded.anchorState.notice == nil)
  }

  @Test func oldRelevantExcerptSurvivesReplayWindowAndIsBudgeted() async throws {
    let f = try await AnchorFixture.make()
    defer { f.clean() }
    let old = try await f.commit("铜钥匙交给林舟保管，天亮后归还。")
    _ = try await f.add(old, label: "铜钥匙")
    for n in 1...24 { _ = try await f.commit("普通经过 \(n)") }
    try await f.runtime.setHistoryWindow(2, address: f.address)
    let snapshot = try await f.runtime.load(address: f.address)
    let sections = StoryAnchorContext.sections(snapshot: snapshot, userMessage: "归还铜钥匙")
    #expect(sections.contains { $0.id.hasSuffix(".excerpt") && $0.content.contains(old.narrative) })
    let compiled = try StoryContextCompiler.compile(
      sections: sections, userMessage: "归还铜钥匙",
      contextWindow: 2_048, maximumOutputTokens: 512)
    #expect(compiled.manifest.estimatedInputTokens <= compiled.manifest.inputBudget)
    let request = try await StoryTurnEngine().makeRequest(
      turnID: UUID(), userMessage: "归还铜钥匙",
      snapshot: snapshot, storyworld: f.library.load(storyworldID: f.address.storyworldID),
      isCorrectionRetry: false)
    #expect(request.messages.first?.content.contains(old.narrative) == true)
    #expect(!request.messages.dropFirst().contains { $0.content.contains(old.narrative) })
    let unrelated = StoryAnchorContext.sections(snapshot: snapshot, userMessage: "天气怎样")
    #expect(unrelated.contains { $0.id.hasSuffix(".card") })
    #expect(!unrelated.contains { $0.id.hasSuffix(".excerpt") })
  }

  @Test func cardAndExcerptCapsExcludeDisabledAndInvalidAnchors() async throws {
    let f = try await AnchorFixture.make()
    defer { f.clean() }
    for n in 0..<24 { _ = try await f.commit("铜钥匙经历 \(n)") }
    let snapshot = try await f.runtime.load(address: f.address)
    var anchors = snapshot.turns.map {
      StoryAnchor(eventRef: .init($0), label: "铜钥匙", note: String(repeating: "笔记", count: 500))
    }
    anchors[0].enabled = false
    anchors[0].label = "DISABLED_SECRET"
    anchors.append(
      StoryAnchor(
        eventRef: .init(branchID: UUID(), sequence: 1, turnID: UUID()), label: "INVALID_SECRET"))
    let enriched = StorySessionSnapshot(
      context: snapshot.context, state: snapshot.state, turns: snapshot.turns,
      saves: snapshot.saves, anchorState: .init(anchors: anchors))
    let sections = StoryAnchorContext.sections(snapshot: enriched, userMessage: "铜钥匙")
    #expect(sections.filter { $0.id.hasSuffix(".card") }.count == 16)
    #expect(sections.filter { $0.id.hasSuffix(".excerpt") }.count == 3)
    #expect(!sections.map(\.content).joined().contains("SECRET"))
    let compact = try StoryContextCompiler.compile(
      sections: sections, userMessage: "铜钥匙", contextWindow: 2_048, maximumOutputTokens: 512)
    #expect(compact.manifest.estimatedInputTokens <= compact.manifest.inputBudget)
    #expect(compact.manifest.entries.contains { !$0.included })
  }

  @Test func textLimitsAndConcurrentEditsFailWithoutLosingAnnotations() async throws {
    let f = try await AnchorFixture.make()
    defer { f.clean() }
    let first = try await f.commit("一")
    let second = try await f.commit("二")
    await #expect(throws: StoryAnchorError.invalidText) {
      try await f.runtime.saveAnchor(
        StoryAnchor(eventRef: .init(first), label: String(repeating: "字", count: 101)),
        address: f.address, expectedRevision: nil)
    }
    await #expect(throws: StoryAnchorError.fileTooLarge) {
      try await f.runtime.saveAnchor(
        StoryAnchor(
          eventRef: .init(first), label: "大笔记", note: String(repeating: "\u{0301}", count: 600_000)),
        address: f.address, expectedRevision: nil)
    }
    let successes = try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
      for turn in [first, second] {
        group.addTask {
          do {
            try await f.runtime.saveAnchor(
              StoryAnchor(eventRef: .init(turn), label: "标记"), address: f.address,
              expectedRevision: nil)
            return true
          } catch StoryAnchorError.staleRevision { return false }
        }
      }
      var count = 0
      for try await success in group where success { count += 1 }
      return count
    }
    #expect(successes == 1)
    #expect(try await f.runtime.load(address: f.address).anchorState.anchors.count == 1)
  }
}

private struct AnchorFixture: Sendable {
  let root: URL
  let package: URL
  let library: StoryworldLibrary
  let runtime: StoryworldRuntimeStore
  let address: SessionAddress
  static func make() async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anchors-\(UUID().uuidString)")
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("library"))
    let world = try await library.create(lorebook: Lorebook(title: "合成锚点世界"))
    let package = try await library.managedPackageURL(storyworldID: world.id)
    let runtime = StoryworldRuntimeStore(packageURL: package)
    let line = try await runtime.createPlaythrough(title: "合成游玩线")
    return Self(
      root: root, package: package, library: library, runtime: runtime, address: line.address)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func commit(_ narrative: String, address: SessionAddress? = nil) async throws
    -> CommittedStoryTurn
  {
    try await runtime.commitTurn(
      address: address ?? self.address, turnID: UUID(), userMessage: "行动", narrative: narrative)
  }
  func anchorFile(_ address: SessionAddress) -> URL {
    events(address).deletingLastPathComponent().appendingPathComponent("anchors.json")
  }
  func events(_ address: SessionAddress) -> URL {
    package.appendingPathComponent(
      "playthroughs/\(address.playthroughID.uuidString.lowercased())/branches/\(address.branchID.uuidString.lowercased())/events.jsonl"
    )
  }
  func add(_ turn: CommittedStoryTurn, label: String, address: SessionAddress? = nil) async throws
    -> StoryAnchor
  {
    let address = address ?? self.address
    let snapshot = try await runtime.load(address: address)
    let anchor = StoryAnchor(eventRef: .init(turn), label: label)
    try await runtime.saveAnchor(
      anchor, address: address, expectedRevision: snapshot.anchorState.revision)
    return anchor
  }
}
