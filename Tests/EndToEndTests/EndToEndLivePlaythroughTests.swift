import Foundation
import LLMProviderKit
import StoryworldCore
import Testing

/// 链路 C（联网）：真实模型回合 —— 扮演玩家，用配置的 DeepSeek 模型提交
/// 真实回合，验证 <STORY>/<STATE_PATCH> 信封解析与回合落库。
///
/// 门控：仅当 `WORLDBOOK_E2E_LIVE=1` 时运行。
/// 依赖环境变量：
/// - `DEEPSEEK_API_KEY`：模型 API Key
/// - `WORLDBOOK_E2E_MODEL`：模型 ID（缺省 deepseek-v4-flash）
struct EndToEndLivePlaythroughTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WORLDBOOK_E2E_LIVE"] == "1"))
  func realModelTurnCommitsThroughEnvelopeParser() async throws {
    guard ProcessInfo.processInfo.environment["WORLDBOOK_E2E_LIVE"] == "1" else { return }
    let apiKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
      ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    try #require(apiKey != nil, "需要 DEEPSEEK_API_KEY")

    let modelID = ProcessInfo.processInfo.environment["WORLDBOOK_E2E_MODEL"] ?? "deepseek-v4-flash"
    let profile = ProviderProfile(
      displayName: "E2E DeepSeek",
      kind: .openAICompatible,
      baseURL: URL(string: "https://api.deepseek.com/v1")!,
      modelID: modelID,
      credentialReference: "e2e-deepseek"
    )
    let provider = try OpenAICompatibleProvider(profile: profile, apiKey: apiKey!)

    // 扮演玩家发起一个回合
    let request = LLMRequest(
      requestID: UUID(),
      messages: [
        LLMMessage(
          role: .system,
          content: """
            你是互动小说叙事引擎。严格按以下格式回复，不要 Markdown 围栏：
            <STORY>给玩家的中文叙事</STORY>
            <STATE_PATCH>{"发生变化的字段":"新值"}</STATE_PATCH>
            没有状态变化时 STATE_PATCH 必须是 {}。
            """
        ),
        LLMMessage(role: .user, content: "我推开旧塔的门，走了进去。"),
      ]
    )

    var raw = ""
    for try await event in provider.stream(request) {
      if case .textDelta(let delta) = event { raw += delta }
    }
    #expect(!raw.isEmpty)
    print("E2E 模型原始回复：\(String(raw.prefix(200)))")

    let envelope = try StoryResponseEnvelopeParser.parseRecovering(raw)
    #expect(!envelope.narrative.isEmpty)
    print("E2E 模型叙事：\(envelope.narrative.prefix(120))")

    // 真实落库：建立世界书 + 游玩线，提交这一回合
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("e2e-live-play-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = StoryworldLibrary(
      rootURL: root.appendingPathComponent("storyworlds", isDirectory: true)
    )
    let record = try await library.create(
      lorebook: Lorebook(
        title: "旧塔",
        entries: [LoreEntry(title: "旧塔", content: "废弃古塔，塔内有云纹铜牌。", activationKeys: ["旧塔"])]
      ),
      title: "旧塔世界书"
    )
    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let runtime = StoryworldRuntimeStore(packageURL: packageURL)
    let context = try await runtime.createPlaythrough(title: "真实模型回合")
    let turn = try await runtime.commitTurn(
      address: context.address,
      turnID: request.requestID,
      userMessage: "我推开旧塔的门，走了进去。",
      narrative: envelope.narrative,
      statePatchData: envelope.statePatchData
    )
    #expect(turn.sequence == 1)

    let snapshot = try await runtime.load(address: context.address)
    #expect(snapshot.turns.count == 1)
    #expect(snapshot.turns.first?.narrative == envelope.narrative)
  }
}
