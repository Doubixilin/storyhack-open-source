import Foundation
import LLMProviderKit
import StorySessionCore
import StoryworldCore
import Testing

@Suite("Player taste persistence and request boundaries")
struct PlayerTasteTests {
  @Test func normalizedProfilePersistsWithStableFingerprintAndStaleWritesCannotOverwrite() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PlayerTasteStore(rootURL: root)
    let original = try await store.load()
    #expect(original.profile.isDefault && original.revision == nil)
    #expect(try original.profile.fingerprintKey() == nil)
    #expect(try original.profile.promptSupplement().isEmpty)
    let profile = PlayerTasteProfile(pace: .brisk, style: .vivid, detail: .rich,
      styleIntensity: 4, avoidElements: [" 血腥细节 ", "虫群", "血腥细节", ""], notes: "  多用对白。\n")
    let saved = try await store.save(profile, replacing: original)
    #expect(saved.profile.avoidElements == ["虫群", "血腥细节"])
    #expect(saved.profile.notes == "多用对白。")
    #expect(try await PlayerTasteStore(rootURL: root).load() == saved)
    #expect(try profile.fingerprintKey() == saved.profile.fingerprintKey())
    let same = try await store.save(profile, replacing: original)
    #expect(same == saved)
    await #expect(throws: PlayerTasteError.staleEdit) {
      try await store.save(.init(style: .concise), replacing: original)
    }
    let reset = try await store.save(.standard, replacing: saved)
    #expect(reset.profile.isDefault && reset.revision != saved.revision)
    await #expect(throws: PlayerTasteError.staleEdit) { try await store.save(profile, replacing: original) }
  }

  @Test func invalidOrCorruptProfileCannotEraseExistingData() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PlayerTasteStore(rootURL: root)
    let saved = try await store.save(.init(style: .concise), replacing: .init())
    let url = root.appendingPathComponent("profile.json")
    let bytes = try Data(contentsOf: url)
    let invalid = [PlayerTasteProfile(styleIntensity: 0), .init(styleIntensity: 6),
      .init(avoidElements: Array(repeating: "项", count: 21)), .init(avoidElements: [String(repeating: "字", count: 81)]),
      .init(notes: String(repeating: "字", count: 1_001))]
    for profile in invalid {
      await #expect(throws: PlayerTasteError.invalidProfile) { try await store.save(profile, replacing: saved) }
      #expect(try Data(contentsOf: url) == bytes)
    }
    let bad = Data("corrupt".utf8); try bad.write(to: url)
    await #expect(throws: PlayerTasteError.corruptStore) { try await store.save(.standard, replacing: saved) }
    #expect(try Data(contentsOf: url) == bad)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("missing"))
    await #expect(throws: PlayerTasteError.corruptStore) { try await store.load() }
  }

  @Test func oneProfileAppliesAcrossBooksAndResetRestoresOriginalPromptBytes() async throws {
    let f = try await TasteFixture.make()
    defer { f.clean() }
    let engine = StoryTurnEngine(recapInterval: 0, continuityTracking: false, tasteStore: f.store)
    let snapshot = try await f.runtime.load(address: f.address)
    let document = try await f.document()
    let original = try await engine.makeRequest(turnID: UUID(), userMessage: "继续", snapshot: snapshot,
      storyworld: document, isCorrectionRetry: false)
    let selected = try await f.store.save(.init(pace: .brisk, style: .vivid, detail: .rich,
      styleIntensity: 5, avoidElements: ["虫群"], notes: "保留人物停顿。"), replacing: .init())
    let changed = try await engine.makeRequest(turnID: UUID(), userMessage: "继续", snapshot: snapshot,
      storyworld: document, isCorrectionRetry: false)
    #expect(changed.messages[0].content.contains(try selected.profile.promptSupplement()))
    #expect(changed.messages[0].content.contains(DirectiveProfile.basePreamble))
    #expect(changed.messages[0].content.contains("STATE_PATCH 必须是 JSON Merge Patch 对象"))
    let other = try await f.library.create(lorebook: .init(title: "另一部合成小说", entries: [.init(title: "地点", content: "山间客栈。")]))
    let otherRuntime = StoryworldRuntimeStore(packageURL: try await f.library.managedPackageURL(storyworldID: other.id))
    let context = try await otherRuntime.createPlaythrough(title: "另一线")
    let otherRequest = try await engine.makeRequest(turnID: UUID(), userMessage: "继续",
      snapshot: otherRuntime.load(address: context.address), storyworld: f.library.load(storyworldID: other.id),
      isCorrectionRetry: false)
    #expect(otherRequest.messages[0].content.contains(try selected.profile.promptSupplement()))
    try await f.store.save(.standard, replacing: selected)
    let reset = try await engine.makeRequest(turnID: UUID(), userMessage: "继续", snapshot: snapshot,
      storyworld: document, isCorrectionRetry: false)
    #expect(reset.messages.map(\.content) == original.messages.map(\.content))
    #expect(try await f.runtime.load(address: f.address).effectiveTurns.isEmpty)
  }

  @Test func preferencesAreFrozenForOneTurnAndDoNotRewriteEventPresentation() async throws {
    let f = try await TasteFixture.make()
    defer { f.clean() }
    let old = try await f.store.save(.init(notes: "保留短句节奏。"), replacing: .init())
    let provider = TasteProvider {
      try await f.store.save(.init(notes: "加入环境声音。"), replacing: old)
    }
    let engine = StoryTurnEngine(recapInterval: 0, continuityTracking: false, tasteStore: f.store)
    for try await _ in engine.runTurn(provider: provider, runtime: f.runtime, storyworld: try await f.document(),
      snapshot: try await f.runtime.load(address: f.address), userMessage: "模型实际导演输入",
      commitUserMessage: "（系统指令：导演·继续）", turnID: UUID(), isCorrectionRetry: false) {}
    #expect(provider.requests.count == 1)
    #expect(provider.requests[0].messages[0].content.contains("保留短句节奏"))
    #expect(!provider.requests[0].messages[0].content.contains("加入环境声音"))
    let snapshot = try await f.runtime.load(address: f.address)
    #expect(snapshot.effectiveTurns.last?.userMessage == "（系统指令：导演·继续）")
    #expect(snapshot.effectiveTurns.last?.narrative == "旅人站在渡口。")
    let next = try await engine.makeRequest(turnID: UUID(), userMessage: "继续", snapshot: snapshot,
      storyworld: f.document(), isCorrectionRetry: false)
    #expect(next.messages[0].content.contains("加入环境声音"))
    #expect(!next.messages[0].content.contains("保留短句节奏"))
  }

  @Test func mandatoryPreferencesExceedingWindowFailBeforeProviderCall() async throws {
    let f = try await TasteFixture.make()
    defer { f.clean() }
    let snapshot = try await f.runtime.load(address: f.address)
    let document = try await f.document()
    let provider = TasteProvider(window: 4_096)
    let engine = StoryTurnEngine(recapInterval: 0, continuityTracking: false, tasteStore: f.store)
    _ = try await engine.makeRequest(turnID: UUID(), userMessage: "继续", snapshot: snapshot,
      storyworld: document, isCorrectionRetry: false, providerProfile: provider.profile)
    try await f.store.save(.init(avoidElements: (1...20).map { String(repeating: "避", count: 78) + String($0) },
      notes: String(repeating: "字", count: 1_000)), replacing: .init())
    await #expect(throws: StoryContextError.mandatoryExceedsBudget) {
      for try await _ in engine.runTurn(provider: provider, runtime: f.runtime, storyworld: document,
        snapshot: snapshot, userMessage: "继续", turnID: UUID(), isCorrectionRetry: false) {}
    }
    #expect(provider.requests.isEmpty)
    #expect(try await f.runtime.load(address: f.address).effectiveTurns.isEmpty)
  }
}

private func temporaryRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("player-taste-\(UUID())")
}

private struct TasteFixture: Sendable {
  let root: URL
  let library: StoryworldLibrary
  let runtime: StoryworldRuntimeStore
  let address: SessionAddress
  let store: PlayerTasteStore
  static func make() async throws -> Self {
    let root = temporaryRoot()
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let record = try await library.create(lorebook: .init(title: "合成世界", entries: [.init(title: "地点", content: "渡口。")]))
    let runtime = StoryworldRuntimeStore(packageURL: try await library.managedPackageURL(storyworldID: record.id))
    let context = try await runtime.createPlaythrough(title: "偏好测试")
    return .init(root: root, library: library, runtime: runtime, address: context.address,
      store: PlayerTasteStore(rootURL: root.appendingPathComponent("taste")))
  }
  func document() async throws -> StoryworldDocument { try await library.load(storyworldID: address.storyworldID) }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class TasteProvider: LLMProvider, @unchecked Sendable {
  let profile: ProviderProfile
  private let lock = NSLock()
  private var recorded: [LLMRequest] = []
  var requests: [LLMRequest] { lock.withLock { recorded } }
  let mutation: @Sendable () async throws -> Void
  init(window: Int = 32_768, mutation: @escaping @Sendable () async throws -> Void = {}) {
    profile = .init(displayName: "合成模型", kind: .openAICompatible, modelID: "synthetic",
      credentialReference: "unused", capabilities: .init(contextWindow: window), maximumOutputTokens: 1_024)
    self.mutation = mutation
  }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
    lock.withLock { recorded.append(request) }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await mutation()
          continuation.yield(.textDelta("<STORY>旅人站在渡口。</STORY><CHOICES>[\"查看河岸\",\"询问船夫\"]</CHOICES><STATE_PATCH>{}</STATE_PATCH>"))
          continuation.yield(.completed); continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
