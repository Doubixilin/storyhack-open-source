import Foundation
import LLMProviderKit
import StorySessionCore
import StoryworldCore
import Testing

@Suite("Directive profiles and playthrough isolation")
struct DirectiveProfileTests {
  @Test func catalogSupportsCustomProfilesFallbackAndRejectsStaleOrCorruptWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("directives-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DirectiveProfileStore(rootURL: root)
    #expect(try await store.list() == DirectiveProfile.builtins)
    #expect(try await store.resolve("missing") == .green)
    var profile = DirectiveProfile(name: "细腻叙事", preamble: "保留人物细微动作。", recapInterval: 30)
    try await store.save(profile, replacing: nil)
    #expect(try await DirectiveProfileStore(rootURL: root).resolve(profile.id) == profile)
    let previous = profile
    profile.preamble = "用简洁对白推动剧情。"
    try await store.save(profile, replacing: previous)
    await #expect(throws: DirectiveProfileError.staleEdit) { try await store.save(previous, replacing: previous) }
    await #expect(throws: DirectiveProfileError.staleEdit) { try await store.delete(previous) }
    await #expect(throws: DirectiveProfileError.readOnly) { try await store.save(.green, replacing: nil) }
    var invalid = profile; invalid.recapInterval = 201
    await #expect(throws: DirectiveProfileError.invalidProfile) { try await store.save(invalid, replacing: profile) }
    let file = root.appendingPathComponent("profiles.json")
    let bytes = Data("corrupt".utf8)
    try bytes.write(to: file)
    await #expect(throws: DirectiveProfileError.corruptStore) { try await store.save(profile, replacing: nil) }
    #expect(try Data(contentsOf: file) == bytes)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
    await #expect(throws: DirectiveProfileError.corruptStore) { try await store.list() }
  }

  @Test func selectionIsPlaythroughLocalAndStaleEditsAndABATurnsFail() async throws {
    let f = try await DirectiveFixture.make()
    defer { f.clean() }
    let other = try await f.runtime.createPlaythrough(title: "另一条线")
    _ = try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "旧行动", narrative: "旧叙事。")
    let baseline = try await f.runtime.load(address: f.address)
    let events = try Data(contentsOf: f.events)
    let token = try await f.runtime.requireDirective(address: f.address, expected: nil)
    let fast = DirectiveProfile.builtins[1]
    try await f.runtime.setDirectiveProfile(fast, address: f.address, expectedRevision: nil)
    let selected = try await f.runtime.load(address: f.address)
    #expect(selected.context.playthrough.effectiveDirective == fast)
    #expect(try await f.runtime.load(address: other.address).context.playthrough.effectiveDirective == .green)
    await #expect(throws: DirectiveProfileError.staleEdit) {
      try await f.runtime.setDirectiveProfile(.green, address: f.address, expectedRevision: nil)
    }
    try await f.runtime.setDirectiveProfile(.green, address: f.address,
      expectedRevision: selected.context.playthrough.directive?.revision)
    await #expect(throws: DirectiveProfileError.changedDuringTurn) {
      try await f.runtime.commitTurn(address: f.address, turnID: UUID(), userMessage: "旧请求", narrative: "不应提交",
        expectedEventSequence: baseline.state.lastEventSequence, expectedStateHash: baseline.state.stateHash,
        expectedDirective: token)
    }
    #expect(try Data(contentsOf: f.events) == events)
  }

  @Test func customRulesAndOutputCapApplyInEachModeWithoutReplacingProtocol() async throws {
    let f = try await DirectiveFixture.make()
    defer { f.clean() }
    let profile = DirectiveProfile(name: "合成档案", preamble: "先写场景中的光影。",
      modeRules: ["canon": "正史特有补充", "god_mode": "成功意图特有补充", "evil_god": "改写世界特有补充"],
      maximumOutputTokens: 4_096)
    try await f.runtime.setDirectiveProfile(profile, address: f.address, expectedRevision: nil)
    let provider = ProviderProfile(displayName: "测试", kind: .openAICompatible, modelID: "synthetic",
      credentialReference: "unused", capabilities: .init(contextWindow: 16_384), maximumOutputTokens: 1_024)
    for mode in StoryPlayMode.allCases {
      let context = try await f.runtime.forkBranch(address: f.address, title: mode.displayName)
      let snapshot = try await f.runtime.load(address: context.address)
      let request = try await StoryTurnEngine(continuityTracking: false).makeRequest(turnID: UUID(), userMessage: "继续",
        snapshot: snapshot, storyworld: try await f.document(), isCorrectionRetry: false, providerProfile: provider)
      let system = request.messages[0].content
      #expect(system.contains(DirectiveProfile.basePreamble))
      #expect(system.contains(mode.promptRule) && system.contains(profile.modeRules[mode.rawValue]!))
      #expect(system.contains(profile.preamble) && system.contains("STATE_PATCH 必须是 JSON Merge Patch 对象"))
      #expect(request.modelOptions.maximumOutputTokens == 1_024)
      for other in StoryPlayMode.allCases where other != mode { #expect(!system.contains(profile.modeRules[other.rawValue]!)) }
    }
  }

  @Test func staleSnapshotSendsNothingAndChangingProfileDuringGenerationCannotCommit() async throws {
    for aba in [false, true] {
      let f = try await DirectiveFixture.make()
      defer { f.clean() }
      let snapshot = try await f.runtime.load(address: f.address)
      let provider = DirectiveProvider {
        try await f.runtime.setDirectiveProfile(DirectiveProfile.builtins[1], address: f.address, expectedRevision: nil)
        if aba {
          let changed = try await f.runtime.load(address: f.address)
          try await f.runtime.setDirectiveProfile(.green, address: f.address,
            expectedRevision: changed.context.playthrough.directive?.revision)
        }
      }
      let document = try await f.document()
      await #expect(throws: DirectiveProfileError.changedDuringTurn) {
        for try await _ in StoryTurnEngine(recapInterval: 0).runTurn(provider: provider, runtime: f.runtime,
          storyworld: document, snapshot: snapshot, userMessage: "继续", turnID: UUID(), isCorrectionRetry: false) {}
      }
      #expect(provider.requests.count == 1)
      #expect(try await f.runtime.load(address: f.address).turns.isEmpty)
      await #expect(throws: DirectiveProfileError.changedDuringTurn) {
        for try await _ in StoryTurnEngine().runTurn(provider: provider, runtime: f.runtime,
          storyworld: document, snapshot: snapshot, userMessage: "旧页面请求", turnID: UUID(), isCorrectionRetry: false) {}
      }
      #expect(provider.requests.count == 1)
    }
  }

  @Test func recapIntervalCanBeEnabledOrDisabledPerProfileAndExplicitEngineOverrideWorks() async throws {
    for (interval, override, expectedCalls) in [(1, nil as Int?, 2), (0, nil, 1), (1, 0, 1)] {
      let f = try await DirectiveFixture.make()
      defer { f.clean() }
      let profile = DirectiveProfile(name: "摘要配置", maximumOutputTokens: 2_048, recapInterval: interval)
      try await f.runtime.setDirectiveProfile(profile, address: f.address, expectedRevision: nil)
      let provider = DirectiveProvider()
      let snapshot = try await f.runtime.load(address: f.address)
      for try await _ in StoryTurnEngine(recapInterval: override).runTurn(provider: provider, runtime: f.runtime,
        storyworld: try await f.document(), snapshot: snapshot, userMessage: "继续", turnID: UUID(), isCorrectionRetry: false) {}
      #expect(provider.requests.count == expectedCalls)
      #expect((try await f.runtime.load(address: f.address).recap != nil) == (expectedCalls == 2))
    }
  }

  @Test func catalogChangesAndDeletionDoNotChangeSelectedCopiesAndExportRetainsProfile() async throws {
    let f = try await DirectiveFixture.make()
    defer { f.clean() }
    let store = DirectiveProfileStore(rootURL: f.root.appendingPathComponent("profiles"))
    let original = DirectiveProfile(name: "已选择版本", preamble: "使用短句。")
    try await store.save(original, replacing: nil)
    try await f.runtime.setDirectiveProfile(original, address: f.address, expectedRevision: nil)
    var changed = original; changed.preamble = "使用长句。"
    try await store.save(changed, replacing: original)
    try await store.delete(changed)
    #expect(try await store.resolve(original.id) == .green)
    #expect(try await f.runtime.load(address: f.address).context.playthrough.effectiveDirective == original)
    let child = try await f.runtime.forkBranch(address: f.address, title: "分支")
    #expect(try await f.runtime.load(address: child.address).context.playthrough.effectiveDirective == original)
    let exported = try await f.library.exportPackage(storyworldID: f.address.storyworldID,
      to: f.root.appendingPathComponent("export.storyworld"))
    let copy = try await f.library.importPackage(from: exported, conflictPolicy: .importAsCopy)
    let runtime = StoryworldRuntimeStore(packageURL: try await f.library.managedPackageURL(storyworldID: copy.id))
    #expect(try await runtime.listPlaythroughs().first?.effectiveDirective == original)
  }
}

private struct DirectiveFixture: Sendable {
  let root: URL
  let package: URL
  let library: StoryworldLibrary
  let runtime: StoryworldRuntimeStore
  let address: SessionAddress
  var events: URL { package.appendingPathComponent("playthroughs/\(address.playthroughID.uuidString.lowercased())/branches/\(address.branchID.uuidString.lowercased())/events.jsonl") }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func document() async throws -> StoryworldDocument { try await library.load(storyworldID: address.storyworldID) }
  static func make() async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("directive-runtime-\(UUID())")
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let record = try await library.create(lorebook: .init(title: "合成世界", entries: [.init(title: "地点", content: "林舟在渡口。")]))
    let package = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: package)
    let line = try await runtime.createPlaythrough(title: "默认旧线")
    return .init(root: root, package: package, library: library, runtime: runtime, address: line.address)
  }
}

private final class DirectiveProvider: LLMProvider, @unchecked Sendable {
  let profile = ProviderProfile(displayName: "合成模型", kind: .openAICompatible, modelID: "synthetic", credentialReference: "unused")
  private let lock = NSLock()
  private var recorded: [LLMRequest] = []
  private let mutation: @Sendable () async throws -> Void
  var requests: [LLMRequest] { lock.withLock { recorded } }
  init(mutation: @escaping @Sendable () async throws -> Void = {}) { self.mutation = mutation }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
    lock.withLock { recorded.append(request) }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await mutation()
          let recap = request.messages.first?.content.hasPrefix("把给定前情与新增回合压缩") == true
          continuation.yield(.textDelta(recap ? "林舟留在渡口调查。"
            : "<STORY>林舟留在渡口调查。</STORY><CHOICES>[\"查看河岸\",\"询问船夫\"]</CHOICES><STATE_PATCH>{}</STATE_PATCH>"))
          continuation.yield(.completed); continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
