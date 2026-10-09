import Foundation
import LLMProviderKit
@testable import StorySessionCore
import StoryworldCore
import Testing

@Suite("Canon binding and turn isolation")
struct CanonBindingTests {
  @Test func partialPlotlineStartsAtFirstAvailableNodeAndGapFillingPreservesRecordedProgress() async throws {
    var plot = StoryPlotline(nodes: [
      .init(id: "plot-0002", title: "渡口", summary: "林舟来到渡口。", order: 2, chapterOrdinal: 1),
      .init(id: "plot-0004", title: "未来密室", summary: "未揭露的钥匙。", order: 4, chapterOrdinal: 3),
    ], source: "factory", coverage: .init(sourceChapterCount: 4, completeChapterCount: 2, gaps: [
      .init(chapterID: "a", chapterOrdinal: 0, chapterTitle: "开篇缺口", reason: .missing),
      .init(chapterID: "c", chapterOrdinal: 2, chapterTitle: "中间缺口", reason: .incomplete),
    ]))
    let f = try await CanonFixture.make(plotline: plot)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let snapshot = try await f.runtime.load(address: f.address)
    let opening = StoryTurnEngine.openingPrompt(plotline: plot)
    #expect(opening.contains("最早可用场景"))
    #expect(opening.contains("原著开篇摘要缺失"))
    #expect(!opening.contains("未来密室"))
    #expect(StoryTurnEngine.currentPlotOrder(state: snapshot.state.values, plotline: plot) == 2)
    let request = try await StoryTurnEngine().makeRequest(turnID: UUID(), userMessage: opening,
      snapshot: snapshot, storyworld: try await f.document(), isCorrectionRetry: false)
    let system = request.messages.first?.content ?? ""
    #expect(system.contains("plot-0002") && system.contains("主线摘要完整 2/4 章"))
    #expect(!system.contains("未来密室") && !system.contains("未揭露的钥匙"))
    #expect(StoryChapterSearch(snapshot: snapshot, plotline: plot).cards.isEmpty)
    _ = try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "留在渡口",
      narrative: "林舟仍在渡口。", statePatchData: Data(#"{"plot":{"node":2}}"#.utf8))
    let events = try Data(contentsOf: f.events)
    plot.nodes += [
      .init(id: "plot-0001", title: "开篇", summary: "准备出发。", order: 1, chapterOrdinal: 0),
      .init(id: "plot-0003", title: "山路", summary: "登山。", order: 3, chapterOrdinal: 2),
    ]
    plot.coverage = .init(sourceChapterCount: 4, completeChapterCount: 4, gaps: [])
    try StoryworldCoding.makeEncoder().encode(plot).write(to: f.package.appendingPathComponent("plotline.json"))
    let changed = try await f.runtime.canonStatus(address: f.address)
    #expect(changed.canRebind && changed.requiresConfirmation)
    try await f.confirm(changed)
    let after = try await f.runtime.load(address: f.address)
    #expect(StoryTurnEngine.currentPlotOrder(state: after.state.values, plotline: plot) == 2)
    #expect(try Data(contentsOf: f.events) == events)
    #expect(StoryChapterSearch(snapshot: after, plotline: plot).cards.isEmpty)
  }

  @Test func newLinesBindAndEveryStaticAssetChangeIsDetected() async throws {
    let f = try await CanonFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(try await f.runtime.load(address: f.address).canonStatus?.state == .matched)
    let encoder = StoryworldCoding.makeEncoder()
    let assets: [(String, Data)] = [
      ("timeline.json", try encoder.encode(StoryTimeline(beats: [], source: "test"))),
      ("plotline.json", try encoder.encode(Self.plotline)),
      (
        "material_profile.json",
        try encoder.encode(
          MaterialProfile(primaryGenre: "fantasy", confidence: 0.9, source: "test"))
      ),
      ("character_contracts.json", Data("{\"schema_version\":1,\"contracts\":[]}".utf8)),
    ]
    for (path, bytes) in assets {
      try bytes.write(to: f.package.appendingPathComponent(path), options: .atomic)
      let status = try await f.runtime.canonStatus(address: f.address)
      #expect(status.state == .changed)
      #expect(status.canRebind)
      try await f.confirm(status)
      #expect(try await f.runtime.canonStatus(address: f.address).state == .matched)
    }
    let line = try await f.runtime.load(address: f.address).context.playthrough
    #expect(line.canonBinding?.history.count == 4)
    #expect(line.canonBinding?.fingerprints.assets.count == 5)
    // Removal is a change too, rather than silently dropping the old asset hash.
    try FileManager.default.removeItem(at: f.package.appendingPathComponent("timeline.json"))
    #expect(try await f.runtime.canonStatus(address: f.address).state == .changed)
  }

  @Test func legacyLineRequiresExplicitConfirmationAndKeepsEvents() async throws {
    let f = try await CanonFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try await f.runtime.commitTurn(
      address: f.address, turnID: UUID(), userMessage: "行动", narrative: "旧记录")
    let metadata = f.package.appendingPathComponent(
      "playthroughs/\(f.address.playthroughID.uuidString.lowercased())/metadata.json")
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
    object.removeValue(forKey: "canon_binding")
    try JSONSerialization.data(withJSONObject: object).write(to: metadata, options: .atomic)
    let status = try await f.runtime.canonStatus(address: f.address)
    #expect(status.state == .legacyUnbound)
    let document = try await f.document()
    await #expect(throws: CanonBindingError.confirmationRequired) {
      try await f.runtime.requireCanon(address: f.address, document: document, bindingID: nil)
    }
    let before = try Data(contentsOf: f.events)
    try await f.confirm(status)
    #expect(try Data(contentsOf: f.events) == before)
    let after = try await f.runtime.load(address: f.address)
    #expect(after.canonStatus?.state == .matched)
    #expect(after.context.playthrough.canonBinding?.history.count == 1)
    #expect(after.context.playthrough.canonBinding?.history.first?.previousBindingID == nil)
  }

  @Test func staleConfirmationCannotApproveUnseenChanges() async throws {
    let f = try await CanonFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try f.changeLore("第一次变更")
    let reviewed = try await f.runtime.canonStatus(address: f.address)
    try f.changeLore("第二次变更")
    await #expect(throws: CanonBindingError.changedDuringTurn) { try await f.confirm(reviewed) }
    #expect(
      try await f.runtime.load(address: f.address).context.playthrough.canonBinding?.history.isEmpty
        == true)
    try await f.confirm(try await f.runtime.canonStatus(address: f.address))
    #expect(
      try await f.runtime.load(address: f.address).context.playthrough.canonBinding?.history.count
        == 1)
  }

  @Test func deletedOrReorderedNodesCannotSilentlyRebindOldProgress() async throws {
    let f = try await CanonFixture.make(plotline: Self.plotline)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let old = try await f.runtime.load(address: f.address)
    let originalBinding = old.context.playthrough.canonBinding
    let changed = StoryPlotline(
      nodes: [
        StoryPlotNode(id: "p2", title: "第二章", summary: "改序", order: 1, chapterOrdinal: 2)
      ], source: "test")
    try StoryworldCoding.makeEncoder().encode(changed).write(
      to: f.package.appendingPathComponent("plotline.json"))
    let status = try await f.runtime.canonStatus(address: f.address)
    #expect(status.state == .changed)
    #expect(!status.canRebind)
    await #expect(throws: CanonBindingError.incompatiblePlotline) { try await f.confirm(status) }
    #expect(
      try await f.runtime.load(address: f.address).context.playthrough.canonBinding
        == originalBinding)
    let fresh = try await f.runtime.createPlaythrough(title: "新设定")
    #expect(try await f.runtime.load(address: fresh.address).canonStatus?.state == .matched)
    #expect(try await f.runtime.listPlaythroughs().count == 2)
  }

  @Test func changedAssetsDuringGenerationDoNotCommit() async throws {
    let f = try await CanonFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let provider = CanonMutatingProvider { try f.changeLore("生成期间改变") }
    let snapshot = try await f.runtime.load(address: f.address)
    let document = try await f.document()
    await #expect(throws: CanonBindingError.changedDuringTurn) {
      for try await _ in StoryTurnEngine(recapInterval: 0).runTurn(
        provider: provider, runtime: f.runtime, storyworld: document, snapshot: snapshot,
        userMessage: "继续", turnID: UUID(), isCorrectionRetry: false)
      {}
    }
    #expect(try await f.runtime.load(address: f.address).turns.isEmpty)
  }

  @Test func successfulTurnRecordsBindingAndTokenCannotCrossBranches() async throws {
    let f = try await CanonFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let snapshot = try await f.runtime.load(address: f.address)
    let document = try await f.document()
    let token = try await f.runtime.requireCanon(
      address: f.address, document: document,
      bindingID: snapshot.context.playthrough.canonBinding?.id)
    let branch = try await f.runtime.forkBranch(address: f.address, title: "分支")
    let child = try await f.runtime.load(address: branch.address)
    await #expect(throws: CanonBindingError.changedDuringTurn) {
      try await f.runtime.commitTurn(
        address: branch.address, turnID: UUID(), userMessage: "原线请求", narrative: "不能串线",
        expectedEventSequence: child.state.lastEventSequence,
        expectedStateHash: child.state.stateHash,
        expectedCanon: token)
    }
    for try await _ in StoryTurnEngine(recapInterval: 0).runTurn(
      provider: CanonMutatingProvider(mutation: {}), runtime: f.runtime, storyworld: document,
      snapshot: snapshot, userMessage: "继续", turnID: UUID(), isCorrectionRetry: false)
    {}
    let result = try await f.runtime.load(address: f.address)
    #expect(result.turns.last?.canonBindingID == token.bindingID)
    #expect(try await f.runtime.load(address: branch.address).turns.isEmpty)
  }

  @Test func staleUIAndRebindABAAreRejected() async throws {
    let f = try await CanonFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let originalBytes = try Data(contentsOf: f.loreURL)
    let snapshot = try await f.runtime.load(address: f.address)
    let document = try await f.document()
    let token = try await f.runtime.requireCanon(
      address: f.address, document: document,
      bindingID: snapshot.context.playthrough.canonBinding?.id)
    try f.changeLore("更新后的设定")
    try await f.confirm(try await f.runtime.canonStatus(address: f.address))
    let newID = try await f.runtime.load(address: f.address).context.playthrough.canonBinding?.id
    await #expect(throws: CanonBindingError.staleDocument) {
      try await f.runtime.requireCanon(address: f.address, document: document, bindingID: newID)
    }
    try originalBytes.write(to: f.loreURL)
    try await f.confirm(try await f.runtime.canonStatus(address: f.address))
    await #expect(throws: CanonBindingError.changedDuringTurn) {
      try await f.runtime.commitTurn(
        address: f.address, turnID: UUID(), userMessage: "旧请求", narrative: "不应落盘",
        expectedEventSequence: snapshot.state.lastEventSequence,
        expectedStateHash: snapshot.state.stateHash, expectedCanon: token)
    }
    #expect(try await f.runtime.load(address: f.address).turns.isEmpty)
  }

  @Test func malformedAndSymlinkAssetsBlockGenerationButHistoryRemainsReadable() async throws {
    let f = try await CanonFixture.make()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let optional = f.package.appendingPathComponent("timeline.json")
    try Data("bad JSON".utf8).write(to: optional)
    #expect(try await f.runtime.load(address: f.address).canonStatus?.state == .unavailable)
    try FileManager.default.removeItem(at: optional)
    let outside = f.root.appendingPathComponent("outside.json")
    try Data("{}".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: optional, withDestinationURL: outside)
    let status = try await f.runtime.canonStatus(address: f.address)
    #expect(status.state == .unavailable)
    #expect(!status.canRebind)
  }

  static var plotline: StoryPlotline {
    StoryPlotline(
      nodes: [
        StoryPlotNode(id: "p1", title: "第一章", summary: "开端", order: 1, chapterOrdinal: 1),
        StoryPlotNode(id: "p2", title: "第二章", summary: "推进", order: 2, chapterOrdinal: 2),
      ], source: "test")
  }
}

private struct CanonFixture: Sendable {
  let root: URL
  let package: URL
  let library: StoryworldLibrary
  let runtime: StoryworldRuntimeStore
  let address: SessionAddress
  var loreURL: URL { package.appendingPathComponent("lorebook/lorebook.json") }
  var events: URL {
    package.appendingPathComponent(
      "playthroughs/\(address.playthroughID.uuidString.lowercased())/branches/\(address.branchID.uuidString.lowercased())/events.jsonl"
    )
  }
  func document() async throws -> StoryworldDocument {
    try await library.load(storyworldID: address.storyworldID)
  }
  func changeLore(_ content: String) throws {
    var lore = try StoryworldCoding.makeDecoder().decode(
      Lorebook.self, from: Data(contentsOf: loreURL))
    lore.entries[0].content = content
    try StoryworldCoding.makeEncoder().encode(lore).write(to: loreURL, options: .atomic)
  }
  func confirm(_ status: CanonBindingStatus) async throws {
    try await runtime.confirmCanonBinding(
      address: address, expectedCurrent: #require(status.current),
      expectedBindingID: status.bindingID)
  }
  static func make(plotline: StoryPlotline? = nil) async throws -> CanonFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.create(
      lorebook: Lorebook(title: "测试世界", entries: [.init(title: "规则", content: "初始设定")]))
    let package = try await library.managedPackageURL(storyworldID: record.id)
    if let plotline {
      try StoryworldCoding.makeEncoder().encode(plotline).write(
        to: package.appendingPathComponent("plotline.json"))
    }
    let runtime = StoryworldRuntimeStore(packageURL: package)
    let context = try await runtime.createPlaythrough(title: "测试线")
    return CanonFixture(
      root: root, package: package, library: library, runtime: runtime, address: context.address)
  }
}

private struct CanonMutatingProvider: LLMProvider {
  let mutation: @Sendable () throws -> Void
  var profile: ProviderProfile {
    .init(
      displayName: "test", kind: .openAICompatible, modelID: "test", credentialReference: "test")
  }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      do {
        try mutation()
        continuation.yield(
          .textDelta(
            "<STORY>本回叙事</STORY><CHOICES>[\"留在这里\",\"返回门口\"]</CHOICES><STATE_PATCH>{}</STATE_PATCH>"
          ))
        continuation.yield(.completed)
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
  }
}
