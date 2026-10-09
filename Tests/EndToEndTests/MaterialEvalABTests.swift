import Foundation
import LLMProviderKit
import StoryMaterialKit
import StorySessionCore
import StoryworldCore
import Testing

@Suite("P2 素材 A/B 评测")
struct MaterialEvalABTests {
  @Test("夹具覆盖 10 题材 × 12 场景，且 120 格均可由本地 Mock 完成回合")
  func allFixturesCompleteMockTurn() async throws {
    let payload = try MaterialEvalFixtures.load()
    #expect(payload.contexts.count == 120)
    #expect(Set(payload.contexts.map(\.id)).count == 120)
    #expect(Set(payload.contexts.map(\.genre)).count == 10)
    #expect(Set(payload.contexts.map(\.scene)).count == 12)

    let engine = StoryTurnEngine(materialStore: MaterialStore())
    for context in payload.contexts {
      #expect(context.worldbook.lorebook.entries.count >= 2)
      #expect(context.worldbook.lorebook.entries.count <= 3)
      #expect(context.worldbook.lorebook.entries.allSatisfy { (80...150).contains($0.content.count) })
      #expect(context.snapshot.turns.count == 2)
      #expect(context.worldbook.materialProfile.confidence == 0.9)

      let fixture = try await MaterialEvalRuntime.make(context: context)
      do {
        let request = try await engine.makeRequest(
          turnID: UUID(),
          userMessage: context.userMessage,
          snapshot: fixture.snapshot,
          storyworld: fixture.storyworld,
          isCorrectionRetry: false
        )
        let system = try #require(request.messages.first?.content)
        #expect(system.contains("<MATERIAL_REFERENCES"))
        #expect(MaterialEvalMetrics.materialSection(in: system).count <= 700)

        var result: StoryTurnResult?
        for try await event in engine.runTurn(
          provider: MaterialEvalMockProvider(),
          runtime: fixture.runtime,
          storyworld: fixture.storyworld,
          snapshot: fixture.snapshot,
          userMessage: context.userMessage,
          turnID: UUID(),
          isCorrectionRetry: false
        ) {
          if case .completed(let completed) = event { result = completed }
        }
        let completed = try #require(result)
        #expect(completed.snapshot.turns.count == 3)
        #expect(completed.choices.count == 2)
      } catch {
        try? FileManager.default.removeItem(at: fixture.container)
        throw error
      }
      try? FileManager.default.removeItem(at: fixture.container)
    }
  }

  @Test("真实评测必须同时满足双开关与 provider 配置")
  func liveGateRequiresAllConfiguration() {
    #expect(MaterialEvalConfiguration.live(environment: [:]) == nil)
    #expect(MaterialEvalConfiguration.live(environment: [
      "WORLDBOOK_MATERIAL_EVAL": "1",
      "DEEPSEEK_API_KEY": "test-only",
    ]) == nil)
    #expect(MaterialEvalConfiguration.live(environment: [
      "WORLDBOOK_E2E_LIVE": "1",
      "DEEPSEEK_API_KEY": "test-only",
    ]) == nil)
    #expect(MaterialEvalConfiguration.live(environment: [
      "WORLDBOOK_MATERIAL_EVAL": "1",
      "WORLDBOOK_E2E_LIVE": "1",
    ]) == nil)
    #expect(MaterialEvalConfiguration.live(environment: [
      "WORLDBOOK_MATERIAL_EVAL": "1",
      "WORLDBOOK_E2E_LIVE": "1",
      "DEEPSEEK_API_KEY": "test-only",
    ]) != nil)
  }

  @Test("sample=10 进行题材与场景分层抽样")
  func sampleTenIsStratified() throws {
    let contexts = try MaterialEvalFixtures.load().contexts
    let sample = MaterialEvalSampler.stratified(contexts, count: 10)
    #expect(sample.count == 10)
    #expect(Set(sample.map(\.genre)).count == 10)
    #expect(Set(sample.map(\.scene)).count == 10)
    #expect(sample.map(\.id) == MaterialEvalSampler.stratified(contexts, count: 10).map(\.id))
  }

  @Test("盲评包离线包含 D3 标准、120 格与 JSON 导出")
  func blindReviewPackageIsSelfContained() throws {
    let contexts = try MaterialEvalFixtures.load().contexts
    let records = contexts.flatMap { context in
      ["A", "B"].map { group in
        MaterialEvalCaseRecord.fixture(context: context, group: group)
      }
    }
    let html = try MaterialEvalBlindReview.render(contexts: contexts, records: records)
    #expect(html.contains("具体行动"))
    #expect(html.contains("策略互斥"))
    #expect(html.contains("风险可感知"))
    #expect(html.contains("语境一致"))
    #expect(html.contains("左好"))
    #expect(html.contains("右好"))
    #expect(html.contains("平"))
    #expect(html.contains("exportResults"))
    #expect(html.components(separatedBy: "class=\"review-card\"").count - 1 == 120)
    #expect(!html.contains("https://"))
    #expect(!html.contains("http://"))
  }

  /// 默认 guard 立即返回，不构造 provider、不发送网络请求、不写 Artifacts。
  /// 仅当 WORLDBOOK_MATERIAL_EVAL=1、WORLDBOOK_E2E_LIVE=1 且 API key 齐全时运行。
  @Test("真实模型 A/B（双环境变量门控）", .enabled(if: ProcessInfo.processInfo.environment["WORLDBOOK_MATERIAL_EVAL"] == "1" && ProcessInfo.processInfo.environment["WORLDBOOK_E2E_LIVE"] == "1"))
  func liveMaterialAB() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let configuration = MaterialEvalConfiguration.live(environment: environment) else {
      return
    }

    let payload = try MaterialEvalFixtures.load()
    let sampleCount = try MaterialEvalConfiguration.sampleCount(
      environment: environment,
      maximum: payload.contexts.count
    )
    let contexts = MaterialEvalSampler.stratified(payload.contexts, count: sampleCount)
    let profile = ProviderProfile(
      displayName: "Material Eval DeepSeek",
      kind: .openAICompatible,
      baseURL: URL(string: "https://api.deepseek.com/v1")!,
      modelID: configuration.modelID,
      credentialReference: "e2e-deepseek"
    )
    // 评测专用直连 transport：本机系统代理不可用时（如代理软件未运行）评测仍能执行；
    // 仅影响评测进程，生产 App 的 URLSession 行为不变
    let directConfiguration = URLSessionConfiguration.ephemeral
    directConfiguration.connectionProxyDictionary = [:]
    let provider = try OpenAICompatibleProvider(
      profile: profile,
      apiKey: configuration.apiKey,
      transport: URLSessionStreamingTransport(
        session: URLSession(configuration: directConfiguration)
      )
    )
    let runner = MaterialEvalLiveRunner(provider: provider)
    let materialStore = MaterialStore()
    let engine = StoryTurnEngine(materialStore: materialStore)
    var records: [MaterialEvalCaseRecord] = []

    for context in contexts {
      let fixture = try await MaterialEvalRuntime.make(context: context)
      do {
        let baseline = StoryworldDocument(
          manifest: fixture.storyworld.manifest,
          lorebook: fixture.storyworld.lorebook,
          timeline: fixture.storyworld.timeline,
          plotline: fixture.storyworld.plotline,
          materialProfile: nil
        )
        records.append(
          try await runner.run(
            context: context,
            group: "A",
            engine: engine,
            materialStore: materialStore,
            storyworld: baseline,
            snapshot: fixture.snapshot
          )
        )
        records.append(
          try await runner.run(
            context: context,
            group: "B",
            engine: engine,
            materialStore: materialStore,
            storyworld: fixture.storyworld,
            snapshot: fixture.snapshot
          )
        )
      } catch {
        try? FileManager.default.removeItem(at: fixture.container)
        throw error
      }
      try? FileManager.default.removeItem(at: fixture.container)
    }

    let artifactURL = try MaterialEvalArtifacts.write(
      contexts: contexts,
      records: records,
      modelID: configuration.modelID
    )
    print("Material A/B artifacts: \(artifactURL.path)")
  }
}

private struct MaterialEvalFixturePayload: Decodable {
  let schemaVersion: Int
  let fixtureVersion: String
  let contexts: [MaterialEvalContext]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case fixtureVersion = "fixture_version"
    case contexts
  }
}

private struct MaterialEvalContext: Decodable, Sendable {
  let id: String
  let genre: String
  let scene: String
  let userMessage: String
  let worldbook: MaterialEvalWorldbook
  let snapshot: MaterialEvalSnapshot

  enum CodingKeys: String, CodingKey {
    case id, genre, scene, worldbook, snapshot
    case userMessage = "user_message"
  }

  var allContextText: String {
    let lore = worldbook.lorebook.entries.map { $0.title + "\n" + $0.content }
    let plot = worldbook.plotline.nodes.map { $0.title + "\n" + $0.summary }
    let history = snapshot.turns.flatMap { [$0.userMessage, $0.narrative] }
    return (lore + plot + history + [userMessage]).joined(separator: "\n")
  }
}

private struct MaterialEvalWorldbook: Decodable, Sendable {
  let title: String
  let lorebook: Lorebook
  let plotline: StoryPlotline
  let materialProfile: MaterialProfile

  enum CodingKeys: String, CodingKey {
    case title, lorebook, plotline
    case materialProfile = "material_profile"
  }
}

private struct MaterialEvalSnapshot: Decodable, Sendable {
  let initialState: [String: JSONValue]
  let turns: [MaterialEvalTurn]

  enum CodingKeys: String, CodingKey {
    case initialState = "initial_state"
    case turns
  }
}

private struct MaterialEvalTurn: Decodable, Sendable {
  let userMessage: String
  let narrative: String
  let choices: [String]
  let statePatch: [String: JSONValue]
  let beatID: String?

  enum CodingKeys: String, CodingKey {
    case narrative, choices
    case userMessage = "user_message"
    case statePatch = "state_patch"
    case beatID = "beat_id"
  }
}

private enum MaterialEvalFixtures {
  static func load() throws -> MaterialEvalFixturePayload {
    let url = try #require(
      Bundle.module.url(
        forResource: "contexts",
        withExtension: "json",
        subdirectory: "Fixtures/material_eval"
      )
    )
    let payload = try StoryworldCoding.makeDecoder().decode(
      MaterialEvalFixturePayload.self,
      from: Data(contentsOf: url)
    )
    try #require(payload.schemaVersion == 1)
    try #require(payload.fixtureVersion == "material-eval-v1")
    return payload
  }
}

private struct MaterialEvalRuntime {
  let container: URL
  let runtime: StoryworldRuntimeStore
  let storyworld: StoryworldDocument
  let snapshot: StorySessionSnapshot

  static func make(context: MaterialEvalContext) async throws -> Self {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("material-eval-\(UUID().uuidString)", isDirectory: true)
    let library = StoryworldLibrary(
      rootURL: container.appendingPathComponent("library", isDirectory: true)
    )
    let record = try await library.create(
      lorebook: context.worldbook.lorebook,
      title: context.worldbook.title
    )
    let packageURL = try await library.managedPackageURL(storyworldID: record.id)
    let encoder = StoryworldCoding.makeEncoder()
    try encoder.encode(context.worldbook.plotline).write(to: packageURL.appendingPathComponent("plotline.json"))
    try encoder.encode(context.worldbook.materialProfile).write(to: packageURL.appendingPathComponent("material_profile.json"))
    let runtime = StoryworldRuntimeStore(packageURL: packageURL)
    let playthrough = try await runtime.createPlaythrough(
      title: "素材评测固定快照",
      initialState: context.snapshot.initialState
    )
    for turn in context.snapshot.turns {
      let patch = try JSONEncoder().encode(turn.statePatch)
      _ = try await runtime.commitTurn(
        address: playthrough.address,
        turnID: UUID(),
        userMessage: turn.userMessage,
        narrative: turn.narrative,
        choices: turn.choices,
        statePatchData: patch,
        beatID: turn.beatID
      )
    }
    let snapshot = try await runtime.load(address: playthrough.address)
    let storyworld = try await library.load(storyworldID: record.id)
    return Self(
      container: container,
      runtime: runtime,
      storyworld: storyworld,
      snapshot: snapshot
    )
  }
}

private struct MaterialEvalMockProvider: LLMProvider {
  let profile = ProviderProfile(
    displayName: "Material Eval Mock",
    kind: .openAICompatible,
    baseURL: URL(string: "https://example.invalid/v1")!,
    modelID: "mock",
    credentialReference: "none"
  )

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.textDelta(
        "<STORY>同伴压低声音，留给你决定下一步的时间已经不多。</STORY>"
          + "<CHOICES>[\"核对手中线索后当面追问\",\"带同伴退出现场并保存证据\"]</CHOICES>"
          + "<STATE_PATCH>{}</STATE_PATCH><PLOT>none</PLOT>"
      ))
      continuation.yield(.completed)
      continuation.finish()
    }
  }
}

private struct MaterialEvalConfiguration: Equatable {
  let apiKey: String
  let modelID: String

  static func live(environment: [String: String]) -> Self? {
    guard environment["WORLDBOOK_MATERIAL_EVAL"] == "1",
      environment["WORLDBOOK_E2E_LIVE"] == "1",
      let apiKey = environment["DEEPSEEK_API_KEY"] ?? environment["OPENAI_API_KEY"],
      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return Self(
      apiKey: apiKey,
      modelID: environment["WORLDBOOK_E2E_MODEL"] ?? "deepseek-v4-flash"
    )
  }

  static func sampleCount(environment: [String: String], maximum: Int) throws -> Int {
    guard let raw = environment["WORLDBOOK_MATERIAL_EVAL_SAMPLE"] else { return maximum }
    let count = try #require(Int(raw), "WORLDBOOK_MATERIAL_EVAL_SAMPLE 必须是正整数")
    try #require(count > 0, "WORLDBOOK_MATERIAL_EVAL_SAMPLE 必须大于 0")
    return min(count, maximum)
  }
}

private enum MaterialEvalSampler {
  /// 用稳定散列在当前最少覆盖的 genre/scene 中选下一格；同样输入永远得到同样样本。
  static func stratified(_ contexts: [MaterialEvalContext], count: Int) -> [MaterialEvalContext] {
    guard count < contexts.count else { return contexts }
    var remaining = contexts
    var selected: [MaterialEvalContext] = []
    var genreCounts: [String: Int] = [:]
    var sceneCounts: [String: Int] = [:]
    while selected.count < count {
      remaining.sort { lhs, rhs in
        let left = (
          genreCounts[lhs.genre, default: 0],
          sceneCounts[lhs.scene, default: 0],
          MaterialEvalMetrics.stableHash(lhs.id)
        )
        let right = (
          genreCounts[rhs.genre, default: 0],
          sceneCounts[rhs.scene, default: 0],
          MaterialEvalMetrics.stableHash(rhs.id)
        )
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
      }
      let next = remaining.removeFirst()
      selected.append(next)
      genreCounts[next.genre, default: 0] += 1
      sceneCounts[next.scene, default: 0] += 1
    }
    return selected
  }
}

private struct MaterialEvalLiveRunner {
  let provider: any LLMProvider

  func run(
    context: MaterialEvalContext,
    group: String,
    engine: StoryTurnEngine,
    materialStore: MaterialStore,
    storyworld: StoryworldDocument,
    snapshot: StorySessionSnapshot
  ) async throws -> MaterialEvalCaseRecord {
    let prepared = try await engine.makeRequest(
      turnID: UUID(),
      userMessage: context.userMessage,
      snapshot: snapshot,
      storyworld: storyworld,
      isCorrectionRetry: false
    )
    let request = LLMRequest(
      requestID: prepared.requestID,
      messages: prepared.messages,
      responseContract: prepared.responseContract,
      // 与生产游玩路径一致：不压低 temperature/reasoning（压 reasoning 会显著削弱协议履约率）
      modelOptions: LLMModelOptions()
    )
    let system = request.messages.first?.content ?? ""
    let materialSection = MaterialEvalMetrics.materialSection(in: system)
    let genre = try #require(MaterialGenre(rawValue: context.genre))
    let scene = try #require(ChoiceScene(rawValue: context.scene))
    let available = await materialStore.choices(genre: genre, scene: scene)
    let materials = available.filter { materialSection.contains($0.text) }
    try #require(group == "A" ? materials.isEmpty : !materials.isEmpty)
    try #require(materialSection.count <= 700)

    var raw = ""
    for try await event in provider.stream(request) {
      if case .textDelta(let delta) = event { raw += delta }
    }
    let parsedChoices = MaterialEvalMetrics.parsedChoices(from: raw)
    let overlap = MaterialEvalMetrics.overlap(choices: parsedChoices, materials: materials)
    let entities = MaterialEvalMetrics.entityMismatch(
      choices: parsedChoices,
      contextText: context.allContextText
    )
    let inputCharacters = request.messages.reduce(0) { $0 + $1.content.count }
    return MaterialEvalCaseRecord(
      contextID: context.id,
      group: group,
      genre: context.genre,
      scene: context.scene,
      systemPromptSummary: MaterialEvalMetrics.promptSummary(system),
      rawOutput: raw,
      choices: parsedChoices,
      materialIDs: materials.map(\.id),
      structureCompliant: MaterialEvalMetrics.choicesStructureCompliant(raw),
      overlap: overlap,
      entityMismatch: entities,
      materialInputCharacters: materialSection.count,
      requestInputCharacters: inputCharacters,
      estimatedRequestTokens: MaterialEvalMetrics.estimatedTokens(in: request.messages),
      providerReportedInputTokens: nil,
      tokenRecordNote: "当前 LLMProvider 流事件不暴露服务端 usage；estimated_request_tokens 为字符启发式估算，不是 provider 实测值。",
      provider: provider.profile.displayName,
      model: provider.profile.modelID
    )
  }
}

private struct MaterialEvalCaseRecord: Codable, Sendable {
  let contextID: String
  let group: String
  let genre: String
  let scene: String
  let systemPromptSummary: String
  let rawOutput: String
  let choices: [String]
  let materialIDs: [String]
  let structureCompliant: Bool
  let overlap: MaterialEvalOverlap
  let entityMismatch: MaterialEvalEntityMismatch
  let materialInputCharacters: Int
  let requestInputCharacters: Int
  let estimatedRequestTokens: Int
  let providerReportedInputTokens: Int?
  let tokenRecordNote: String
  let provider: String
  let model: String

  static func fixture(context: MaterialEvalContext, group: String) -> Self {
    Self(
      contextID: context.id,
      group: group,
      genre: context.genre,
      scene: context.scene,
      systemPromptSummary: "fixture",
      rawOutput: "",
      choices: group == "A"
        ? ["继续调查", "先离开这里"]
        : ["核对关键物证后当面追问", "带同伴撤往安全地点并封存记录"],
      materialIDs: [],
      structureCompliant: true,
      overlap: .zero,
      entityMismatch: .zero,
      materialInputCharacters: 0,
      requestInputCharacters: 0,
      estimatedRequestTokens: 0,
      providerReportedInputTokens: nil,
      tokenRecordNote: "fixture",
      provider: "fixture",
      model: "fixture"
    )
  }
}

private struct MaterialEvalOverlap: Codable, Sendable {
  let continuousTwelveHanMatch: Bool
  let maximumEightGramOverlap: Double
  let violated: Bool

  static let zero = Self(
    continuousTwelveHanMatch: false,
    maximumEightGramOverlap: 0,
    violated: false
  )
}

private struct MaterialEvalEntityMismatch: Codable, Sendable {
  let candidateCount: Int
  let mismatchedCount: Int
  let mismatchedTerms: [String]

  static let zero = Self(candidateCount: 0, mismatchedCount: 0, mismatchedTerms: [])
}

private enum MaterialEvalMetrics {
  static func materialSection(in system: String) -> String {
    guard let start = system.range(of: "<MATERIAL_REFERENCES"),
      let end = system.range(of: "只允许按以下格式回复")
    else { return "" }
    return String(system[start.lowerBound..<end.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func parsedChoices(from raw: String) -> [String] {
    (try? StoryResponseEnvelopeParser.parseRecovering(raw).choices) ?? []
  }

  static func choicesStructureCompliant(_ raw: String) -> Bool {
    guard let opening = raw.range(of: "<CHOICES>"),
      let closing = raw.range(of: "</CHOICES>", range: opening.upperBound..<raw.endIndex),
      opening.upperBound <= closing.lowerBound
    else { return false }
    let body = String(raw[opening.upperBound..<closing.lowerBound])
    guard let choices = try? JSONDecoder().decode([String].self, from: Data(body.utf8)) else {
      return false
    }
    let normalized = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return (2...4).contains(normalized.count)
      && normalized.allSatisfy { !$0.isEmpty && $0.count <= 120 }
      && Set(normalized).count == normalized.count
  }

  static func overlap(choices: [String], materials: [ChoiceMaterial]) -> MaterialEvalOverlap {
    guard !choices.isEmpty, !materials.isEmpty else { return .zero }
    var twelve = false
    var maximum = 0.0
    for choice in choices {
      for material in materials {
        twelve = twelve || containsTwelveContinuousHan(choice, material.text)
        maximum = max(maximum, eightGramOverlap(choice, material.text))
      }
    }
    return MaterialEvalOverlap(
      continuousTwelveHanMatch: twelve,
      maximumEightGramOverlap: maximum,
      violated: twelve || maximum > 0.5
    )
  }

  static func entityMismatch(choices: [String], contextText: String) -> MaterialEvalEntityMismatch {
    let candidates = Set(choices.flatMap(entityCandidates)).sorted()
    let mismatched = candidates.filter { !contextText.localizedCaseInsensitiveContains($0) }
    return MaterialEvalEntityMismatch(
      candidateCount: candidates.count,
      mismatchedCount: mismatched.count,
      mismatchedTerms: mismatched
    )
  }

  static func promptSummary(_ system: String) -> String {
    let compact = system.replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return "chars=\(system.count); fnv1a64=\(String(stableHash(system), radix: 16)); prefix=\(compact.prefix(220))"
  }

  static func estimatedTokens(in messages: [LLMMessage]) -> Int {
    var han = 0
    var other = 0
    for scalar in messages.flatMap({ $0.content.unicodeScalars }) {
      switch scalar.value {
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2FA1F: han += 1
      default:
        if !CharacterSet.whitespacesAndNewlines.contains(scalar) { other += 1 }
      }
    }
    return han + Int(ceil(Double(other) / 4.0))
  }

  static func stableHash(_ string: String) -> UInt64 {
    string.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }

  private static func entityCandidates(_ text: String) -> [String] {
    let suffixes = [
      "先生", "女士", "同学", "队长", "师父", "守卫", "公司", "学校", "医院", "车站",
      "实验室", "档案馆", "议会", "宗门", "山门", "家族", "营地", "码头", "港口", "大厦",
      "公寓", "礼堂", "驿馆", "书院", "客栈", "寺", "宫", "殿", "塔", "楼", "门", "城", "山",
    ]
    let removablePrefixes = [
      "立刻", "马上", "暗中", "主动", "返回", "回到", "前往", "进入", "潜入", "离开", "寻找",
      "询问", "追问", "联系", "通知", "跟随", "保护", "说服", "质问", "观察", "检查", "带着",
    ]
    var result: [String] = []
    for run in hanRuns(text) where run.count >= 2 {
      let characters = Array(run)
      for end in characters.indices {
        let prefix = String(characters[0...end])
        guard suffixes.contains(where: { prefix.hasSuffix($0) }) else { continue }
        let start = max(0, end - 7)
        var candidate = String(characters[start...end])
        var changed = true
        while changed {
          changed = false
          for removable in removablePrefixes where candidate.hasPrefix(removable) {
            candidate.removeFirst(removable.count)
            changed = true
          }
        }
        if candidate.count >= 2 { result.append(candidate) }
      }
    }
    for pair in [("「", "」"), ("“", "”")] {
      var remainder = text[...]
      while let open = remainder.range(of: pair.0),
        let close = remainder.range(of: pair.1, range: open.upperBound..<remainder.endIndex)
      {
        let candidate = String(remainder[open.upperBound..<close.lowerBound])
        if (2...16).contains(candidate.count) { result.append(candidate) }
        remainder = remainder[close.upperBound...]
      }
    }
    return result
  }

  private static func containsTwelveContinuousHan(_ lhs: String, _ rhs: String) -> Bool {
    let rightRuns = hanRuns(rhs)
    for run in hanRuns(lhs) where run.count >= 12 {
      let characters = Array(run)
      for start in 0...(characters.count - 12) {
        let fragment = String(characters[start..<(start + 12)])
        if rightRuns.contains(where: { $0.contains(fragment) }) { return true }
      }
    }
    return false
  }

  private static func hanRuns(_ text: String) -> [String] {
    var runs: [String] = []
    var current = ""
    for character in text {
      let isHan = character.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2FA1F: true
        default: false
        }
      }
      if isHan {
        current.append(character)
      } else if !current.isEmpty {
        runs.append(current)
        current = ""
      }
    }
    if !current.isEmpty { runs.append(current) }
    return runs
  }

  private static func eightGramOverlap(_ lhs: String, _ rhs: String) -> Double {
    let left = ngrams(lhs, size: 8)
    let right = ngrams(rhs, size: 8)
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    return Double(left.intersection(right).count) / Double(min(left.count, right.count))
  }

  private static func ngrams(_ text: String, size: Int) -> Set<String> {
    let characters = Array(text).filter { character in
      !character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    guard characters.count >= size else { return [] }
    return Set((0...(characters.count - size)).map { start in
      String(characters[start..<(start + size)])
    })
  }
}

private enum MaterialEvalArtifacts {
  static func write(
    contexts: [MaterialEvalContext],
    records: [MaterialEvalCaseRecord],
    modelID: String
  ) throws -> URL {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let artifactURL = root
      .appendingPathComponent("Tests/EndToEndTests/Artifacts/material_eval", isDirectory: true)
      .appendingPathComponent(timestamp, isDirectory: true)
    try FileManager.default.createDirectory(at: artifactURL, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let jsonl = try records.map { record in
      String(decoding: try encoder.encode(record), as: UTF8.self)
    }.joined(separator: "\n") + "\n"
    try Data(jsonl.utf8).write(to: artifactURL.appendingPathComponent("cases.jsonl"), options: .atomic)

    let summary = MaterialEvalSummary.render(records: records, modelID: modelID)
    try Data(summary.utf8).write(
      to: artifactURL.appendingPathComponent("summary.md"),
      options: .atomic
    )
    let html = try MaterialEvalBlindReview.render(contexts: contexts, records: records)
    try Data(html.utf8).write(
      to: artifactURL.appendingPathComponent("blind_review.html"),
      options: .atomic
    )
    return artifactURL
  }
}

private enum MaterialEvalSummary {
  static func render(records: [MaterialEvalCaseRecord], modelID: String) -> String {
    let a = records.filter { $0.group == "A" }
    let b = records.filter { $0.group == "B" }
    let aStructure = rate(a.filter(\.structureCompliant).count, a.count)
    let bStructure = rate(b.filter(\.structureCompliant).count, b.count)
    let aCopy = rate(a.filter { $0.overlap.violated }.count, a.count)
    let bCopy = rate(b.filter { $0.overlap.violated }.count, b.count)
    let aEntities = entityRate(a)
    let bEntities = entityRate(b)
    let averageMaterial = b.isEmpty ? 0 : Double(b.reduce(0) { $0 + $1.materialInputCharacters }) / Double(b.count)
    let budgetOK = b.allSatisfy { $0.materialInputCharacters <= 700 }
    return """
      # P2 素材 A/B 自动指标

      - 模型：`\(modelID)`
      - 上下文：\(a.count) 格；请求：\(records.count) 次（每格 A/B 各一次）
      - 固定参数：与生产游玩路径一致（不显式设置 temperature / reasoning_effort）
      - A = baseline（无 material_profile）；B = with-material

      | 指标 | A | B | 自动闸门 |
      |---|---:|---:|---|
      | `<CHOICES>` 结构合规率 | \(percent(aStructure)) | \(percent(bStructure)) | \(bStructure >= aStructure ? "通过" : "未通过")：B 不低于 A |
      | 照抄率（连续 12 汉字或 8-gram > 0.5） | \(percent(aCopy)) | \(percent(bCopy)) | \(bCopy == 0 ? "通过" : "未通过")：B 必须为 0 |
      | 新实体错配粗检 | \(percent(aEntities)) | \(percent(bEntities)) | \(bEntities <= 0.02 ? "通过" : "未通过")：B ≤ 2% |
      | 平均素材新增输入字符 | 0 | \(String(format: "%.1f", averageMaterial)) | \(budgetOK ? "通过" : "未通过")：每回合 ≤ 700 |

      ## Token 记录口径

      `cases.jsonl` 逐请求记录 `request_input_characters` 与 `estimated_request_tokens`。当前 `LLMProvider` 流事件不暴露 provider usage，因此 `provider_reported_input_tokens` 为 null；估算值只用于本次成本观察，不能当作服务端实测 token。

      ## 新实体错配粗检口径

      这是词典法粗检：提取引号实体，以及以人物、机构、地点类后缀结尾的 2–8 字候选词，再检查是否出现于 Lorebook、plot、历史两回合或当前输入。它不能替代人工语境审查。

      ## 人评闸门（待盲评结果）

      打开同目录 `blind_review.html`，按 D3 四维逐格选择“左好 / 右好 / 平”并导出 JSON。最终达标要求：B 胜率至少比 A 高 15 个百分点；同时结构合规率不低于基线、新实体错配 ≤2%、照抄率 = 0。未导入人评结果前，不得宣称通过 G1 价值闸门或继续 G2。
      """
  }

  private static func rate(_ numerator: Int, _ denominator: Int) -> Double {
    denominator == 0 ? 0 : Double(numerator) / Double(denominator)
  }

  private static func entityRate(_ records: [MaterialEvalCaseRecord]) -> Double {
    let candidates = records.reduce(0) { $0 + $1.entityMismatch.candidateCount }
    let mismatched = records.reduce(0) { $0 + $1.entityMismatch.mismatchedCount }
    return rate(mismatched, candidates)
  }

  private static func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
  }
}

private enum MaterialEvalBlindReview {
  private struct Pair: Codable {
    let contextID: String
    let genre: String
    let scene: String
    let leftChoices: [String]
    let rightChoices: [String]
    let leftGroup: String
    let rightGroup: String
  }

  static func render(
    contexts: [MaterialEvalContext],
    records: [MaterialEvalCaseRecord]
  ) throws -> String {
    let byKey = Dictionary(uniqueKeysWithValues: records.map { ("\($0.contextID):\($0.group)", $0) })
    let pairs = try contexts.map { context -> Pair in
      let a = try #require(byKey["\(context.id):A"])
      let b = try #require(byKey["\(context.id):B"])
      let bOnLeft = MaterialEvalMetrics.stableHash(context.id) % 2 == 0
      return Pair(
        contextID: context.id,
        genre: context.genre,
        scene: context.scene,
        leftChoices: bOnLeft ? b.choices : a.choices,
        rightChoices: bOnLeft ? a.choices : b.choices,
        leftGroup: bOnLeft ? "B" : "A",
        rightGroup: bOnLeft ? "A" : "B"
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let payload = String(decoding: try encoder.encode(pairs), as: UTF8.self)
      .replacingOccurrences(of: "<", with: "\\u003c")
    let cards = pairs.enumerated().map { index, _ in
      "<section class=\"review-card\" data-index=\"\(index)\"></section>"
    }.joined(separator: "\n")
    return #"""
      <!doctype html>
      <html lang="zh-Hans">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>P2 素材 A/B 双盲评审</title>
        <style>
          :root { color-scheme: light; font-family: -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; }
          body { max-width: 1120px; margin: 0 auto; padding: 24px; background: #f5f3ee; color: #23211e; }
          header { position: sticky; top: 0; z-index: 2; background: #fffdf8; border: 1px solid #ddd5c8; padding: 18px; border-radius: 14px; }
          .criteria { display: grid; grid-template-columns: repeat(4,1fr); gap: 8px; margin: 12px 0; }
          .criteria div { background: #eee8dd; padding: 10px; border-radius: 8px; }
          .review-card { background: white; border: 1px solid #ddd5c8; border-radius: 14px; padding: 18px; margin: 16px 0; }
          .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
          .candidate { background: #faf8f3; padding: 12px; border-radius: 10px; min-height: 108px; }
          .candidate li { margin: 8px 0; }
          .vote { display: flex; gap: 10px; justify-content: center; margin-top: 14px; }
          button { border: 1px solid #857865; background: white; padding: 9px 16px; border-radius: 9px; cursor: pointer; }
          button.selected { background: #2d5c4d; color: white; }
          @media (max-width: 720px) { .criteria,.columns { grid-template-columns: 1fr; } header { position: static; } }
        </style>
      </head>
      <body>
        <header>
          <h1>P2 素材 A/B 双盲评审</h1>
          <p>每格只比较两组行动选项，不猜组别。按 D3 四维综合判断：</p>
          <div class="criteria"><div><b>具体行动</b><br>此刻能直接执行</div><div><b>策略互斥</b><br>方向与后果真不同</div><div><b>风险可感知</b><br>代价与张力清楚</div><div><b>语境一致</b><br>不凭空新增世界事实</div></div>
          <p id="progress">已评 0 / 0</p>
          <button onclick="exportResults()">导出 JSON 结果</button>
        </header>
        <main>
          \#(cards)
        </main>
        <script id="review-data" type="application/json">\#(payload)</script>
        <script>
          const pairs = JSON.parse(document.getElementById('review-data').textContent);
          const storageKey = 'worldbook-material-eval-v1';
          const votes = JSON.parse(localStorage.getItem(storageKey) || '{}');
          const cards = document.querySelectorAll('.review-card');
          function list(items) { const ol=document.createElement('ol'); if(!items.length){const li=document.createElement('li');li.textContent='（本组未产出有效选项）';li.style.listStyle='none';li.style.opacity='.55';ol.appendChild(li);return ol;} items.forEach(x=>{const li=document.createElement('li');li.textContent=x;ol.appendChild(li)}); return ol; }
          function render() {
            pairs.forEach((pair,index)=>{
              const card=cards[index]; card.replaceChildren();
              const title=document.createElement('h2'); title.textContent=`${index+1}. ${pair.genre} / ${pair.scene}`; card.appendChild(title);
              const columns=document.createElement('div'); columns.className='columns';
              [['左',pair.left_choices],['右',pair.right_choices]].forEach(([label,choices])=>{const box=document.createElement('div');box.className='candidate';const h=document.createElement('b');h.textContent=label;box.append(h,list(choices));columns.appendChild(box)}); card.appendChild(columns);
              const vote=document.createElement('div');vote.className='vote';
              [['left','左好'],['right','右好'],['tie','平']].forEach(([value,label])=>{const button=document.createElement('button');button.textContent=label;if(votes[pair.context_id]===value)button.className='selected';button.onclick=()=>choose(pair.context_id,value);vote.appendChild(button)});card.appendChild(vote);
            });
            document.getElementById('progress').textContent=`已评 ${Object.keys(votes).length} / ${pairs.length}`;
          }
          function choose(id,value){votes[id]=value;localStorage.setItem(storageKey,JSON.stringify(votes));render();}
          function exportResults(){
            const results=pairs.map(pair=>{const selection=votes[pair.context_id]||null;let preferred_group=null;if(selection==='left')preferred_group=pair.left_group;if(selection==='right')preferred_group=pair.right_group;if(selection==='tie')preferred_group='tie';return {context_id:pair.context_id,genre:pair.genre,scene:pair.scene,selection,left_group:pair.left_group,right_group:pair.right_group,preferred_group};});
            const data={schema_version:1,reviewed_count:Object.keys(votes).length,total_count:pairs.length,results};
            const blob=new Blob([JSON.stringify(data,null,2)],{type:'application/json'});const link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download='material_eval_blind_results.json';link.click();setTimeout(()=>URL.revokeObjectURL(link.href),1000);
          }
          render();
        </script>
      </body>
      </html>
      """#
  }
}
