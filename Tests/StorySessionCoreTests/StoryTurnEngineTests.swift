import CryptoKit
import Foundation
import LLMProviderKit
import StoryMaterialKit
import StorySessionCore
import StoryworldCore
import Testing

@Suite("StoryTurnEngine")
struct StoryTurnEngineTests {
  @Test("makeRequest 按启用状态与关键词过滤 Lore 条目")
  func makeRequestFiltersLoreEntries() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(
        title: "测试世界",
        entries: [
          LoreEntry(title: "宫门", content: "宫门内容", activationKeys: ["宫门"]),
          LoreEntry(title: "常驻", content: "常驻内容", alwaysActive: true),
          LoreEntry(title: "停用", content: "停用内容", enabled: false),
          LoreEntry(title: "边关", content: "边关内容", activationKeys: ["边关"]),
        ]
      )
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }

    let request = try await StoryTurnEngine().makeRequest(
      turnID: UUID(),
      userMessage: "我推开宫门。",
      snapshot: fixture.snapshot,
      storyworld: fixture.storyworld,
      isCorrectionRetry: false
    )
    let system = try #require(request.messages.first).content
    #expect(system.contains("宫门内容"))
    #expect(system.contains("常驻内容"))
    #expect(!system.contains("停用内容"))
    #expect(!system.contains("边关内容"))
  }

  @Test("makeRequest 含节拍线指令与纠错规则")
  func makeRequestBeatSectionAndCorrection() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = StoryworldDocument(
      manifest: fixture.storyworld.manifest,
      lorebook: fixture.storyworld.lorebook,
      timeline: StoryTimeline(
        beats: [
          StoryBeat(id: "b1", title: "初入宫", summary: "玩家入宫。", order: 1, keywords: ["宫门"])
        ],
        source: "test"
      )
    )

    let engine = StoryTurnEngine()
    let plain = try await engine.makeRequest(
      turnID: UUID(),
      userMessage: "四处看看。",
      snapshot: fixture.snapshot,
      storyworld: storyworld,
      isCorrectionRetry: false
    )
    let plainSystem = try #require(plain.messages.first).content
    #expect(!plainSystem.contains("b1：初入宫——玩家入宫。"))
    #expect(!plainSystem.contains("格式纠错重试"))

    let retry = try await engine.makeRequest(
      turnID: UUID(),
      userMessage: "四处看看。",
      snapshot: fixture.snapshot,
      storyworld: storyworld,
      isCorrectionRetry: true
    )
    #expect(try #require(retry.messages.first).content.contains("格式纠错重试"))

    let noTimeline = try await engine.makeRequest(
      turnID: UUID(),
      userMessage: "四处看看。",
      snapshot: fixture.snapshot,
      storyworld: fixture.storyworld,
      isCorrectionRetry: false
    )
    #expect(try !#require(noTimeline.messages.first).content.contains("原著节拍线"))
  }

  @Test("makeRequest 历史回放只保留最近 20 回合")
  func makeRequestCapsHistoryAtTwentyTurns() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }

    for index in 1...25 {
      _ = try await fixture.runtime.commitTurn(
        address: fixture.snapshot.context.address,
        turnID: UUID(),
        userMessage: "消息 \(index)",
        narrative: "叙事 \(index)"
      )
    }
    let snapshot = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    let request = try await StoryTurnEngine().makeRequest(
      turnID: UUID(),
      userMessage: "最新消息",
      snapshot: snapshot,
      storyworld: fixture.storyworld,
      isCorrectionRetry: false
    )
    // system + 最近 20 回合 × 2 + 当前用户消息
    #expect(request.messages.count == 42)
    #expect(request.messages[1].content == "消息 6")
    #expect(request.messages.last?.content == "最新消息")
  }

  @Test("recap 按间隔生成，刷新后仍保留近期逐字回合")
  func recapTriggersInjectsAndFiltersReplay() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    _ = try await fixture.runtime.commitTurn(
      address: fixture.snapshot.context.address,
      turnID: UUID(),
      userMessage: "第一回玩家行动",
      narrative: "第一回剧情"
    )
    let beforeSecond = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    let provider = RecapAwareProvider()
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine(recapInterval: 2).runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: beforeSecond,
      userMessage: "第二回玩家行动",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }
    let completed = try #require(result)
    #expect(completed.snapshot.recap?.throughEffectiveTurnCount == 2)
    #expect(completed.snapshot.recap?.narrative == "第一回到第二回的累计前情。")
    #expect(provider.recapCallCount == 1)
    let recapInput = try #require(provider.recapRequests.first?.messages.last?.content)
    #expect(recapInput.contains("第一回玩家行动"))
    #expect(recapInput.contains("第二回玩家行动"))

    let summarizedRequest = try await StoryTurnEngine(recapInterval: 2).makeRequest(
      turnID: UUID(),
      userMessage: "摘要后的行动",
      snapshot: completed.snapshot,
      storyworld: fixture.storyworld,
      isCorrectionRetry: false
    )
    let summarizedSystem = try #require(summarizedRequest.messages.first).content
    #expect(summarizedSystem.contains("<STORY_RECAP through_effective_turn=\"2\">"))
    #expect(summarizedSystem.contains("第一回到第二回的累计前情。"))
    #expect(summarizedRequest.messages.map(\.content) == [summarizedSystem, "第一回玩家行动", "第一回剧情", "第二回玩家行动", "剧情继续。", "摘要后的行动"])

    _ = try await fixture.runtime.commitTurn(
      address: fixture.snapshot.context.address,
      turnID: UUID(),
      userMessage: "第三回玩家行动",
      narrative: "第三回剧情"
    )
    let afterThird = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    let replayRequest = try await StoryTurnEngine(recapInterval: 2).makeRequest(
      turnID: UUID(),
      userMessage: "第四回玩家行动",
      snapshot: afterThird,
      storyworld: fixture.storyworld,
      isCorrectionRetry: false
    )
    #expect(replayRequest.messages[5].content == "第三回玩家行动")
    #expect(replayRequest.messages[6].content == "第三回剧情")
    #expect(replayRequest.messages[1].content == "第一回玩家行动")
  }

  @Test("recap 生成失败不阻断主回合且按间隔节流重试")
  func recapFailureDegradesAndDoesNotRetryEveryTurn() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    _ = try await fixture.runtime.commitTurn(
      address: fixture.snapshot.context.address,
      turnID: UUID(),
      userMessage: "第一回",
      narrative: "第一回剧情"
    )
    let provider = RecapAwareProvider(failRecap: true)
    let engine = StoryTurnEngine(recapInterval: 2)
    var snapshot = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    for userMessage in ["第二回", "第三回"] {
      var completed: StoryTurnResult?
      for try await event in engine.runTurn(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: snapshot,
        userMessage: userMessage,
        turnID: UUID(),
        isCorrectionRetry: false
      ) {
        if case .completed(let result) = event { completed = result }
      }
      snapshot = try #require(completed).snapshot
    }
    #expect(snapshot.effectiveTurns.count == 3)
    #expect(snapshot.recap?.narrative == nil)
    #expect(snapshot.recap?.lastAttemptedEffectiveTurnCount == 2)
    #expect(provider.mainCallCount == 2)
    #expect(provider.recapCallCount == 1)
  }

  @Test("新分支首次 recap 覆盖继承前缀与本分支回合")
  func recapUsesProjectedHistoryOnNewBranch() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    _ = try await fixture.runtime.commitTurn(
      address: fixture.snapshot.context.address,
      turnID: UUID(),
      userMessage: "父分支行动",
      narrative: "父分支剧情"
    )
    let child = try await fixture.runtime.forkBranch(
      address: fixture.snapshot.context.address,
      title: "God Mode"
    )
    let childSnapshot = try await fixture.runtime.load(address: child.address)
    #expect(childSnapshot.turns.isEmpty)
    #expect(childSnapshot.effectiveTurns.count == 1)
    let provider = RecapAwareProvider()
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine(recapInterval: 2).runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: childSnapshot,
      userMessage: "子分支行动",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }
    let completed = try #require(result)
    #expect(completed.snapshot.turns.count == 1)
    #expect(completed.snapshot.effectiveTurns.count == 2)
    #expect(completed.snapshot.recap?.throughEffectiveTurnCount == 2)
    let recapInput = try #require(provider.recapRequests.first?.messages.last?.content)
    #expect(recapInput.contains("父分支行动"))
    #expect(recapInput.contains("子分支行动"))
  }

  @Test("无可用 recap 时请求逐字节保持基线，摘要优先于素材段")
  func absentRecapPreservesBaselineAndRecapPrecedesMaterials() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let engine = StoryTurnEngine(materialStore: MaterialStore(), continuityTracking: false)
    let baseline = try await engine.makeRequest(
      turnID: UUID(), userMessage: "继续", snapshot: fixture.snapshot,
      storyworld: fixture.storyworld, isCorrectionRetry: false
    )
    let failureOnlySnapshot = StorySessionSnapshot(
      context: fixture.snapshot.context,
      state: fixture.snapshot.state,
      turns: fixture.snapshot.turns,
      effectiveTurns: fixture.snapshot.effectiveTurns,
      recap: StoryRecap(
        throughEffectiveTurnCount: 0,
        lastAttemptedEffectiveTurnCount: 20,
        narrative: nil
      ),
      saves: fixture.snapshot.saves
    )
    let failureOnly = try await engine.makeRequest(
      turnID: UUID(), userMessage: "继续", snapshot: failureOnlySnapshot,
      storyworld: fixture.storyworld, isCorrectionRetry: false
    )
    #expect(baseline.messages.count == failureOnly.messages.count)
    #expect(
      zip(baseline.messages, failureOnly.messages).allSatisfy {
        $0.role == $1.role && Data($0.content.utf8) == Data($1.content.utf8)
      }
    )

    try await fixture.runtime.saveRecap(
      StoryRecap(
        throughEffectiveTurnCount: 0,
        lastAttemptedEffectiveTurnCount: 0,
        narrative: "素材之前的前情"
      ),
      address: fixture.snapshot.context.address
    )
    let recapSnapshot = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    let request = try await engine.makeRequest(
      turnID: UUID(), userMessage: "继续", snapshot: recapSnapshot,
      storyworld: profiledStoryworld(fixture, profile: sampleMaterialProfile()),
      isCorrectionRetry: false
    )
    let system = try #require(request.messages.first).content
    let recapRange = try #require(system.range(of: "<STORY_RECAP"))
    let materialRange = try #require(system.range(of: "<MATERIAL_REFERENCES"))
    let contractRange = try #require(system.range(of: "只允许按以下格式回复"))
    #expect(recapRange.lowerBound < materialRange.lowerBound)
    #expect(materialRange.lowerBound < contractRange.lowerBound)
  }

  @Test("runTurn 流式产出叙事并提交完整回合")
  func runTurnStreamsAndCommits() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }

    let provider = MockLLMProvider(script: [
      .event(.textDelta("<STORY>你推开")),
      .event(.textDelta("宫门，风很大。</STORY>\n<STATE_PATCH>{\"位置\":\"宫门\"}</STATE_PATCH><MEMORY_PATCH>{}</MEMORY_PATCH>")),
      .event(.completed),
    ])
    var narratives: [String] = []
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: fixture.snapshot,
      userMessage: "推开宫门",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      switch event {
      case .narrative(let text): narratives.append(text)
      case .completed(let completed): result = completed
      }
    }

    #expect(narratives.first == "你推开")
    #expect(narratives.last == "你推开宫门，风很大。")
    let completed = try #require(result)
    #expect(completed.warnings.isEmpty)
    #expect(completed.snapshot.turns.count == 1)
    #expect(completed.snapshot.turns[0].userMessage == "推开宫门")
    #expect(completed.snapshot.turns[0].narrative == "你推开宫门，风很大。")
    #expect(completed.choices.count == 2)
    #expect(completed.choices[0].contains("方向"))
    #expect(completed.snapshot.turns[0].choices == completed.choices)
    #expect(completed.snapshot.state.values["位置"] == .string("宫门"))

    let reloaded = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    #expect(reloaded.turns.count == 1)
  }

  @Test("runTurn 将 missingNarrative 包装为带摘要的解析错误")
  func runTurnWrapsMissingNarrativeWithRawSummary() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let raw = #"{"finish_reason":"content_filter"}"#
    let provider = SequentialRecordingProvider(responses: [.text(raw)])
    var caught: (any Error)?

    do {
      for try await _ in StoryTurnEngine().runTurn(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: fixture.snapshot,
        userMessage: "继续",
        turnID: UUID(),
        isCorrectionRetry: false
      ) {}
    } catch {
      caught = error
    }

    #expect((caught as? ModelResponseParseFailure)?.responseSummary == raw)
    #expect(provider.requests.count == 1)
    #expect(try await fixture.runtime.load(address: fixture.snapshot.context.address).turns.isEmpty)
  }

  @Test("commitUserMessage 为 nil 时请求与事件日志保持原行为")
  func runTurnNilCommitMessagePreservesPromptAndLog() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let turnID = UUID()
    let userMessage = "调查窗边的脚印"
    let expectedRequest = try await StoryTurnEngine().makeRequest(
      turnID: turnID,
      userMessage: userMessage,
      snapshot: fixture.snapshot,
      storyworld: fixture.storyworld,
      isCorrectionRetry: false
    )
    let provider = SequentialRecordingProvider(responses: [
      .text(
        "<STORY>窗沿留着新泥。</STORY>"
          + "<CHOICES>[\"沿脚印追查\",\"先封锁房间\"]</CHOICES><STATE_PATCH>{}</STATE_PATCH>"
      )
    ])

    for try await _ in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: fixture.snapshot,
      userMessage: userMessage,
      turnID: turnID,
      isCorrectionRetry: false
    ) {}

    let actualRequest = try #require(provider.requests.first)
    #expect(actualRequest.requestID == expectedRequest.requestID)
    #expect(actualRequest.messages.map(\.role) == expectedRequest.messages.map(\.role))
    #expect(
      actualRequest.messages.map { Data($0.content.utf8) }
        == expectedRequest.messages.map { Data($0.content.utf8) }
    )
    let committed = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    #expect(committed.turns.last?.userMessage == userMessage)
  }

  @Test("元通道提示词用真实输入且事件日志用展示文本")
  func runTurnSeparatesDirectivePromptFromCommittedDisplay() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let provider = SequentialRecordingProvider(responses: [
      .text(
        "<STORY>雨声里，门后的脚步逼近。</STORY>"
          + "<CHOICES>[\"推门查看\",\"退到暗处\"]</CHOICES><STATE_PATCH>{}</STATE_PATCH>"
      )
    ])

    for try await _ in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: fixture.snapshot,
      userMessage: "继续",
      commitUserMessage: "（系统指令：导演·继续）",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {}

    #expect(provider.requests.first?.messages.last?.content == "继续")
    let committed = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    #expect(committed.turns.last?.userMessage == "（系统指令：导演·继续）")
  }

  @Test("开局缺少 CHOICES 时修复通道并入去重截断后的选项")
  func runTurnRepairsOpeningChoicesOnce() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let provider = SequentialRecordingProvider(responses: [
      .text("<STORY>钟声响起，广场人群骤然散开。</STORY><STATE_PATCH>{}</STATE_PATCH>"),
      .text("<CHOICES>[\"追上报信人\",\"追上报信人\",\"躲进钟楼\",\"拦住守卫\",\"退回巷口\",\"等待\"]</CHOICES>"),
    ])
    var result: StoryTurnResult?

    for try await event in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: fixture.snapshot,
      userMessage: "继续",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }

    let completed = try #require(result)
    #expect(completed.snapshot.turns.last?.narrative == "钟声响起，广场人群骤然散开。")
    #expect(completed.choices == ["追上报信人", "躲进钟楼", "拦住守卫", "退回巷口"])
    #expect(completed.warnings.contains("行动选项已由修复通道补齐"))
    #expect(provider.requests.count == 2)
    #expect(provider.requests[1].messages.first?.content.contains("只输出缺失的协议标签") == true)
    #expect(provider.requests[1].messages.last?.content.contains("钟声响起，广场人群骤然散开。") == true)
  }

  @Test("开局 CHOICES 修复失败后静默回落 R20 且不重试")
  func runTurnRepairFailureFallsBackWithoutRetry() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let provider = SequentialRecordingProvider(responses: [
      .text("<STORY>雾里只剩一盏灯。</STORY><STATE_PATCH>{}</STATE_PATCH>"),
      .failure(URLError(.networkConnectionLost)),
    ])
    var result: StoryTurnResult?

    for try await event in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: fixture.snapshot,
      userMessage: "观察四周",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }

    let completed = try #require(result)
    #expect(completed.choices.count == 2)
    #expect(!completed.warnings.contains("行动选项已由修复通道补齐"))
    #expect(provider.requests.count == 2)
  }

  @Test("有效历史达到三回合后不触发 CHOICES 修复")
  func runTurnDoesNotRepairChoicesOutsideOpeningWindow() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    for index in 1...3 {
      _ = try await fixture.runtime.commitTurn(
        address: fixture.snapshot.context.address,
        turnID: UUID(),
        userMessage: "行动 \(index)",
        narrative: "叙事 \(index)"
      )
    }
    let current = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    let provider = SequentialRecordingProvider(responses: [
      .text("<STORY>道路继续伸向远方。</STORY><STATE_PATCH>{}</STATE_PATCH>")
    ])
    var result: StoryTurnResult?

    for try await event in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: current,
      userMessage: "赶路",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }

    #expect(try #require(result).choices.isEmpty)
    #expect(provider.requests.count == 1)
  }

  @Test("runTurn 状态补丁越界时以空补丁兜底提交并告警")
  func runTurnFallsBackToEmptyPatch() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }

    // 嵌套 40 层，超过 maximumStatePatchDepth(32) → statePatchTooComplex
    let deepPatch = String(repeating: "{\"a\":", count: 40) + "1" + String(repeating: "}", count: 40)
    let provider = MockLLMProvider(script: [
      .event(.textDelta("<STORY>风雨欲来。</STORY>\n<STATE_PATCH>\(deepPatch)</STATE_PATCH>")),
      .event(.completed),
    ])
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: fixture.snapshot,
      userMessage: "等待",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }

    let completed = try #require(result)
    #expect(completed.snapshot.turns.count == 1)
    #expect(completed.snapshot.state.values.isEmpty)
    #expect(completed.warnings.contains { $0.contains("模型状态补丁超过运行安全边界") })
  }

  @Test("runTurn 流中途出错不提交任何回合")
  func runTurnMidStreamErrorCommitsNothing() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }

    let provider = MockLLMProvider(script: [
      .event(.textDelta("<STORY>半截叙事")),
      .failure(URLError(.networkConnectionLost)),
    ])
    var caught: (any Error)?
    do {
      for try await _ in StoryTurnEngine().runTurn(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: fixture.snapshot,
        userMessage: "出发",
        turnID: UUID(),
        isCorrectionRetry: false
      ) {}
    } catch {
      caught = error
    }
    #expect((caught as? URLError)?.code == .networkConnectionLost)
    let reloaded = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    #expect(reloaded.turns.isEmpty)
  }

  @Test("runTurn 回复超过 2MB 上限抛 responseTooLarge")
  func runTurnRejectsOversizedResponse() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }

    let oversized = String(repeating: "啊", count: StoryResponseEnvelopeParser.maximumResponseByteCount)
    let provider = MockLLMProvider(script: [.event(.textDelta(oversized))])
    var caught: (any Error)?
    do {
      for try await _ in StoryTurnEngine().runTurn(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: fixture.snapshot,
        userMessage: "出发",
        turnID: UUID(),
        isCorrectionRetry: false
      ) {}
    } catch {
      caught = error
    }
    #expect(caught as? StoryResponseEnvelopeError == .responseTooLarge)
    let reloaded = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    #expect(reloaded.turns.isEmpty)
  }

  @Test("makeRequest 正史模式注入原著主线段与 PLOT 协议")
  func makeRequestInjectsPlotlineInCanonMode() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = StoryworldDocument(
      manifest: fixture.storyworld.manifest,
      lorebook: fixture.storyworld.lorebook,
      plotline: Self.samplePlotline
    )

    let request = try await StoryTurnEngine().makeRequest(
      turnID: UUID(),
      userMessage: "继续前进。",
      snapshot: fixture.snapshot,
      storyworld: storyworld,
      isCorrectionRetry: false
    )
    let system = try #require(request.messages.first).content
    #expect(system.contains("原著主线"))
    #expect(system.contains("当前剧情节点：plot-0001「第一章 开端」——主角踏上旅程。"))
    #expect(!system.contains("后续走向"))
    #expect(!system.contains("第二章 遇袭") && !system.contains("第三章 入城"))
    #expect(!system.contains("主角遭遇山贼。"))
    #expect(!system.contains("主角进入京城。"))
    #expect(system.contains("<PLOT>本回合结束时所处的节点ID</PLOT>"))
    #expect(system.contains("<CHOICES>"))
    #expect(system.contains("第一项贴近原著重点剧情，第二项为创新方向"))
    #expect(system.contains("非小说材料"))
    #expect(system.contains("柔性转向健康"))

    // 无主线时不注入
    let plain = try await StoryTurnEngine().makeRequest(
      turnID: UUID(),
      userMessage: "继续前进。",
      snapshot: fixture.snapshot,
      storyworld: fixture.storyworld,
      isCorrectionRetry: false
    )
    #expect(try !#require(plain.messages.first).content.contains("原著主线"))
  }

  @Test("openingPrompt 有主线时锚定第一节点，无主线时回退")
  func openingPromptAnchorsFirstPlotNode() {
    let anchored = StoryTurnEngine.openingPrompt(plotline: Self.samplePlotline)
    #expect(anchored.contains("第一章 开端"))
    #expect(anchored.contains("主角踏上旅程。"))
    #expect(StoryTurnEngine.openingPrompt(plotline: nil) == StoryTurnEngine.openingPrompt)
  }

  @Test("applyingPlotNode 无条件剥离模型 plot，仅合法节点由引擎写回")
  func applyingPlotNodeMergesOnlyValidNode() throws {
    let base = Data("{\"位置\":\"宫门\"}".utf8)
    let patched = StoryTurnEngine.applyingPlotNode(
      "plot-0002", plotline: Self.samplePlotline, to: base)
    let values = try JSONDecoder().decode([String: JSONValue].self, from: patched)
    #expect(values["位置"] == .string("宫门"))
    #expect(values["plot"] == .object(["node": .number(2)]))

    let untouched = StoryTurnEngine.applyingPlotNode(
      "plot-9999", plotline: Self.samplePlotline, to: base)
    let untouchedValues = try JSONDecoder().decode([String: JSONValue].self, from: untouched)
    #expect(untouchedValues == ["位置": .string("宫门")])
    let noPlotline = StoryTurnEngine.applyingPlotNode("plot-0001", plotline: nil, to: base)
    let noPlotlineValues = try JSONDecoder().decode([String: JSONValue].self, from: noPlotline)
    #expect(noPlotlineValues == ["位置": .string("宫门")])

    let unauthorized = StoryTurnEngine.applyingPlotNode(
      nil,
      plotline: Self.samplePlotline,
      to: Data("{\"plot\":{\"node\":99},\"位置\":\"宫门\"}".utf8)
    )
    let unauthorizedValues = try JSONDecoder().decode(
      [String: JSONValue].self,
      from: unauthorized
    )
    #expect(unauthorizedValues["plot"] == nil)
    #expect(unauthorizedValues["位置"] == .string("宫门"))

    // 模型补丁里的 plot 字段以引擎判定为准
    let modelPlot = Data("{\"plot\":{\"node\":99}}".utf8)
    let overridden = StoryTurnEngine.applyingPlotNode(
      "plot-0003", plotline: Self.samplePlotline, to: modelPlot)
    let overriddenValues = try JSONDecoder().decode([String: JSONValue].self, from: overridden)
    #expect(overriddenValues["plot"] == .object(["node": .number(3)]))
  }

  @Test("runTurn 无 PLOT 时模型 STATE_PATCH.plot 不能改写已有节点")
  func runTurnStripsUnauthorizedPlotPatch() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    _ = try await fixture.runtime.commitTurn(
      address: fixture.snapshot.context.address,
      turnID: UUID(),
      userMessage: "进入第一章",
      narrative: "第一章开始。",
      statePatchData: Data("{\"plot\":{\"node\":1}}".utf8)
    )
    let current = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    let provider = MockLLMProvider(script: [
      .event(
        .textDelta(
          "<STORY>你仍在第一章。</STORY>"
            + "<STATE_PATCH>{\"plot\":{\"node\":99},\"safe\":true}</STATE_PATCH>"
        )
      ),
      .event(.completed),
    ])

    let bound = try await persistCanon(fixture, document: StoryworldDocument(
      manifest: fixture.storyworld.manifest, lorebook: fixture.storyworld.lorebook,
      plotline: Self.samplePlotline))
    for try await _ in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: bound.document,
      snapshot: bound.snapshot,
      userMessage: "继续",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {}
    let completed = try await fixture.runtime.load(address: current.context.address)
    #expect(completed.state.values["plot"] == .object(["node": .number(1)]))
    #expect(completed.state.values["safe"] == .bool(true))
  }

  @Test("runTurn 基于旧快照时生成前失败且不覆盖新 head")
  func runTurnRejectsStaleSnapshot() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    _ = try await fixture.runtime.commitTurn(
      address: fixture.snapshot.context.address,
      turnID: UUID(),
      userMessage: "另一端行动",
      narrative: "另一端已更新剧情。"
    )
    let provider = MockLLMProvider(script: [
      .event(.textDelta("<STORY>旧快照生成的剧情。</STORY><STATE_PATCH>{}</STATE_PATCH>")),
      .event(.completed),
    ])

    await #expect(throws: ContinuityError.staleBase) {
      for try await _ in StoryTurnEngine().runTurn(
        provider: provider,
        runtime: fixture.runtime,
        storyworld: fixture.storyworld,
        snapshot: fixture.snapshot,
        userMessage: "旧客户端行动",
        turnID: UUID(),
        isCorrectionRetry: false
      ) {}
    }
    let current = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    #expect(current.turns.count == 1)
    #expect(current.turns.first?.userMessage == "另一端行动")
  }

  @Test("runTurn 模型回报 <PLOT> 后状态记录当前主线节点")
  func runTurnCommitsPlotNodeFromEnvelope() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = StoryworldDocument(
      manifest: fixture.storyworld.manifest,
      lorebook: fixture.storyworld.lorebook,
      plotline: Self.samplePlotline
    )
    let bound = try await persistCanon(fixture, document: storyworld)
    let provider = MockLLMProvider(script: [
      .event(.textDelta(
        "<STORY>你击退山贼。</STORY>\n<STATE_PATCH>{}</STATE_PATCH>\n"
          + "<BEAT>none</BEAT>\n<PLOT>plot-0002</PLOT>")),
      .event(.completed),
    ])
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: bound.document,
      snapshot: bound.snapshot,
      userMessage: "迎战山贼",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }
    let completed = try #require(result)
    #expect(completed.snapshot.state.values["plot"] == .object(["node": .number(2)]))
  }

  @Test("runTurn 持久化选项并在完成事件返回")
  func runTurnPersistsChoices() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let provider = MockLLMProvider(script: [
      .event(
        .textDelta(
          "<STORY>门外传来脚步声。</STORY>"
            + "<CHOICES>[\"按原计划开门\",\"从窗户悄悄离开\"]</CHOICES>"
            + "<STATE_PATCH>{}</STATE_PATCH>"
        )
      ),
      .event(.completed),
    ])
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: fixture.storyworld,
      snapshot: fixture.snapshot,
      userMessage: "听一听",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }
    let completed = try #require(result)
    #expect(completed.choices == ["按原计划开门", "从窗户悄悄离开"])
    #expect(completed.snapshot.turns.last?.choices == completed.choices)
  }

  @Test("runTurn 模型漏选项时兜底引用正文已显露的节拍")
  func runTurnFallbackChoicesUseBeatContext() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = StoryworldDocument(
      manifest: fixture.storyworld.manifest,
      lorebook: fixture.storyworld.lorebook,
      timeline: StoryTimeline(
        beats: [
          StoryBeat(id: "b1", title: "初入宫", summary: "玩家入宫。", order: 1, keywords: ["宫门"])
        ],
        source: "test"
      )
    )
    let bound = try await persistCanon(fixture, document: storyworld)
    let provider = MockLLMProvider(script: [
      .event(.textDelta("<STORY>初入宫时，宫门缓缓打开。</STORY>\n<STATE_PATCH>{}</STATE_PATCH>")),
      .event(.completed),
    ])
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine().runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: bound.document,
      snapshot: bound.snapshot,
      userMessage: "推门",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }
    let completed = try #require(result)
    // R20：开局前三轮模型漏 CHOICES 时，兜底选项必须引用当前节拍，不是固定模板
    #expect(completed.choices.count == 2)
    #expect(completed.choices.allSatisfy { $0.contains("初入宫") })
    #expect(completed.choices.allSatisfy { !$0.contains("推进当前事件") })
    #expect(completed.snapshot.turns.last?.choices == completed.choices)
  }

  @Test("固定 profile 注入两条 P2 参照且素材段不超过 700 字符")
  func makeRequestInjectsBoundedP2References() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = profiledStoryworld(
      fixture,
      profile: sampleMaterialProfile()
    )
    let request = try await StoryTurnEngine(materialStore: MaterialStore()).makeRequest(
      turnID: UUID(),
      userMessage: "继续前进。",
      snapshot: fixture.snapshot,
      storyworld: storyworld,
      isCorrectionRetry: false
    )
    let system = try #require(request.messages.first).content
    let section = try #require(materialSection(in: system))
    #expect(section.count <= 700)
    #expect(section.contains("purpose=\"choice-specificity\""))
    #expect(section.contains("rewrite_required=\"true\""))
    #expect(section.components(separatedBy: "参照 ").count - 1 == 2)
    #expect(section.contains("张力："))
    #expect(section.contains("代价："))
    #expect(section.contains("不得复用参照中的人名、地点、物品、数字或完整短语"))
    let plotRange = try #require(system.range(of: "原著主线"))
    let materialRange = try #require(system.range(of: "<MATERIAL_REFERENCES"))
    let contractRange = try #require(system.range(of: "只允许按以下格式回复"))
    #expect(plotRange.lowerBound < materialRange.lowerBound)
    #expect(materialRange.lowerBound < contractRange.lowerBound)
  }

  @Test("unknown、低置信与无 scene 不改变无 profile 请求")
  func makeRequestSkipsReferencesWithoutQualifiedProfileAndPreservesBaseline() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let engine = StoryTurnEngine(materialStore: MaterialStore())
    let unprofiledStoryworld = StoryworldDocument(
      manifest: fixture.storyworld.manifest,
      lorebook: fixture.storyworld.lorebook,
      plotline: Self.samplePlotline
    )
    let baseline = try await engine.makeRequest(
      turnID: UUID(),
      userMessage: "继续前进。",
      snapshot: fixture.snapshot,
      storyworld: unprofiledStoryworld,
      isCorrectionRetry: false
    )
    let baselineSystem = try #require(baseline.messages.first).content

    let profiles = [
      sampleMaterialProfile(primaryGenre: "unknown"),
      sampleMaterialProfile(confidence: 0.649),
      sampleMaterialProfile(plotSceneMap: [:]),
    ]
    for profile in profiles {
      let request = try await engine.makeRequest(
        turnID: UUID(),
        userMessage: "继续前进。",
        snapshot: fixture.snapshot,
        storyworld: profiledStoryworld(fixture, profile: profile),
        isCorrectionRetry: false
      )
      let system = try #require(request.messages.first).content
      #expect(!system.contains("MATERIAL_REFERENCES"))
      #expect(Data(system.utf8) == Data(baselineSystem.utf8))
    }
  }

  @Test("同 seed 可复现，同一分支连续回合不重复素材")
  func materialSamplingIsDeterministicAndBranchLRUAvoidsRepeats() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = profiledStoryworld(fixture, profile: sampleMaterialProfile())

    let deterministicStore = MaterialStore()
    let deterministicEngine = StoryTurnEngine(materialStore: deterministicStore)
    let first = try await deterministicEngine.makeRequest(
      turnID: UUID(), userMessage: "继续", snapshot: fixture.snapshot,
      storyworld: storyworld, isCorrectionRetry: false
    )
    let repeated = try await deterministicEngine.makeRequest(
      turnID: UUID(), userMessage: "继续", snapshot: fixture.snapshot,
      storyworld: storyworld, isCorrectionRetry: false
    )
    let firstSystem = try #require(first.messages.first).content
    let repeatedSystem = try #require(repeated.messages.first).content
    let firstSection = try #require(materialSection(in: firstSystem))
    let repeatedSection = try #require(materialSection(in: repeatedSystem))
    #expect(firstSection == repeatedSection)

    let store = MaterialStore()
    let engine = StoryTurnEngine(materialStore: store)
    let turnOne = try await engine.makeRequest(
      turnID: UUID(), userMessage: "继续", snapshot: fixture.snapshot,
      storyworld: storyworld, isCorrectionRetry: false
    )
    _ = try await fixture.runtime.commitTurn(
      address: fixture.snapshot.context.address,
      turnID: UUID(),
      userMessage: "继续",
      narrative: "局势向前推进。"
    )
    let nextSnapshot = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    let turnTwo = try await engine.makeRequest(
      turnID: UUID(), userMessage: "再继续", snapshot: nextSnapshot,
      storyworld: storyworld, isCorrectionRetry: false
    )
    let firstTexts = Set(referenceTexts(in: try #require(turnOne.messages.first).content))
    let secondTexts = Set(referenceTexts(in: try #require(turnTwo.messages.first).content))
    #expect(firstTexts.count == 2)
    #expect(secondTexts.count == 2)
    #expect(firstTexts.isDisjoint(with: secondTexts))
  }

  @Test("beat scene map 在无 plot scene 时提供参照")
  func makeRequestFallsBackToBeatSceneMap() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    _ = try await fixture.runtime.commitTurn(
      address: fixture.snapshot.context.address,
      turnID: UUID(),
      userMessage: "试探守卫",
      narrative: "守卫没有让路。",
      beatID: "beat-guard"
    )
    let snapshot = try await fixture.runtime.load(address: fixture.snapshot.context.address)
    let profile = MaterialProfile(
      primaryGenre: "dushi",
      confidence: 0.9,
      source: "test",
      beatSceneMap: ["beat-guard": ["tanpan"]]
    )
    let storyworld = StoryworldDocument(
      manifest: fixture.storyworld.manifest,
      lorebook: fixture.storyworld.lorebook,
      materialProfile: profile
    )
    let request = try await StoryTurnEngine(materialStore: MaterialStore()).makeRequest(
      turnID: UUID(), userMessage: "与他谈条件", snapshot: snapshot,
      storyworld: storyworld, isCorrectionRetry: false
    )
    #expect(try #require(request.messages.first).content.contains("MATERIAL_REFERENCES"))
  }

  @Test("模型照抄素材时丢弃整组选项并安静回退")
  func runTurnDiscardsCopiedMaterialChoices() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = profiledStoryworld(fixture, profile: sampleMaterialProfile())
    let bound = try await persistCanon(fixture, document: storyworld)
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine(materialStore: MaterialStore()).runTurn(
      provider: CopyingMaterialProvider(),
      runtime: fixture.runtime,
      storyworld: bound.document,
      snapshot: bound.snapshot,
      userMessage: "继续前进",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }
    let completed = try #require(result)
    #expect(completed.choices.count == 2)
    #expect(completed.choices.allSatisfy { !$0.contains("第一章 开端") })
    #expect(completed.choices.allSatisfy { !$0.contains("朋友圈") })
    #expect(completed.warnings.isEmpty)
  }

  @Test("不足十二个连续汉字但八元组高重合仍回退")
  func runTurnDiscardsHighEightGramOverlap() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = profiledStoryworld(fixture, profile: sampleMaterialProfile())
    let bound = try await persistCanon(fixture, document: storyworld)
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine(materialStore: MaterialStore()).runTurn(
      provider: CopyingMaterialProvider(characterLimit: 10),
      runtime: fixture.runtime,
      storyworld: bound.document,
      snapshot: bound.snapshot,
      userMessage: "继续前进",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }
    let completed = try #require(result)
    #expect(completed.choices.count == 2)
    #expect(completed.choices.allSatisfy { !$0.contains("第一章 开端") })
    #expect(completed.warnings.isEmpty)
  }

  @Test("正常模型选项在启用素材时保持不变")
  func runTurnKeepsNonCopyingChoices() async throws {
    let fixture = try await makeFixture(
      lorebook: Lorebook(title: "测试世界", entries: [])
    )
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let storyworld = profiledStoryworld(fixture, profile: sampleMaterialProfile())
    let bound = try await persistCanon(fixture, document: storyworld)
    let provider = MockLLMProvider(script: [
      .event(.textDelta(
        "<STORY>门外雨声渐急。</STORY>"
          + "<CHOICES>[\"询问守卫今夜换岗时间\",\"退到檐下等待接应者\"]</CHOICES>"
          + "<STATE_PATCH>{}</STATE_PATCH>"
      )),
      .event(.completed),
    ])
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine(materialStore: MaterialStore()).runTurn(
      provider: provider,
      runtime: fixture.runtime,
      storyworld: bound.document,
      snapshot: bound.snapshot,
      userMessage: "观察门口",
      turnID: UUID(),
      isCorrectionRetry: false
    ) {
      if case .completed(let completed) = event { result = completed }
    }
    let completed = try #require(result)
    #expect(completed.choices == ["询问守卫今夜换岗时间", "退到檐下等待接应者"])
  }

  private static let samplePlotline = StoryPlotline(
    nodes: [
      StoryPlotNode(
        id: "plot-0001", title: "第一章 开端", summary: "主角踏上旅程。", order: 1,
        chapterOrdinal: 0),
      StoryPlotNode(
        id: "plot-0002", title: "第二章 遇袭", summary: "主角遭遇山贼。", order: 2,
        chapterOrdinal: 1),
      StoryPlotNode(
        id: "plot-0003", title: "第三章 入城", summary: "主角进入京城。", order: 3,
        chapterOrdinal: 2),
    ],
    source: "test"
  )

  private func profiledStoryworld(
    _ fixture: SessionFixture,
    profile: MaterialProfile
  ) -> StoryworldDocument {
    StoryworldDocument(
      manifest: fixture.storyworld.manifest,
      lorebook: fixture.storyworld.lorebook,
      timeline: fixture.storyworld.timeline,
      plotline: Self.samplePlotline,
      materialProfile: profile
    )
  }

  private func sampleMaterialProfile(
    primaryGenre: String = "dushi",
    confidence: Double = 0.9,
    plotSceneMap: [String: [String]] = ["plot-0001": ["duizhi"]]
  ) -> MaterialProfile {
    MaterialProfile(
      primaryGenre: primaryGenre,
      confidence: confidence,
      source: "test",
      plotSceneMap: plotSceneMap
    )
  }

  private func materialSection(in system: String) -> String? {
    guard let start = system.range(of: "<MATERIAL_REFERENCES"),
      let end = system.range(of: "只允许按以下格式回复")
    else { return nil }
    return String(system[start.lowerBound..<end.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func referenceTexts(in system: String) -> [String] {
    system.split(separator: "\n").compactMap { line in
      guard line.hasPrefix("参照 "),
        let colon = line.firstIndex(of: "："),
        let tension = line.range(of: "；张力：")
      else { return nil }
      return String(line[line.index(after: colon)..<tension.lowerBound])
    }
  }
}

private struct SessionFixture {
  let container: URL
  let runtime: StoryworldRuntimeStore
  let storyworld: StoryworldDocument
  let snapshot: StorySessionSnapshot
}

private func makeFixture(lorebook: Lorebook) async throws -> SessionFixture {
  let container = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let library = StoryworldLibrary(
    rootURL: container.appendingPathComponent("library", isDirectory: true)
  )
  let record = try await library.create(lorebook: lorebook)
  let packageURL = try await library.managedPackageURL(storyworldID: record.id)
  let runtime = StoryworldRuntimeStore(packageURL: packageURL)
  let context = try await runtime.createPlaythrough(title: "测试线")
  let snapshot = try await runtime.load(address: context.address)
  let storyworld = try await library.load(storyworldID: record.id)
  return SessionFixture(
    container: container,
    runtime: runtime,
    storyworld: storyworld,
    snapshot: snapshot
  )
}

private struct MockLLMProvider: LLMProvider, @unchecked Sendable {
  enum Step {
    case event(LLMStreamEvent)
    case failure(any Error)
  }

  let script: [Step]

  var profile: ProviderProfile {
    ProviderProfile(
      displayName: "测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "example-model",
      credentialReference: "credential-test"
    )
  }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      for step in script {
        switch step {
        case .event(let event):
          continuation.yield(event)
        case .failure(let error):
          continuation.finish(throwing: error)
          return
        }
      }
      continuation.finish()
    }
  }
}

private final class SequentialRecordingProvider: LLMProvider, @unchecked Sendable {
  enum Response {
    case text(String)
    case failure(any Error)
  }

  private let lock = NSLock()
  private let responses: [Response]
  private var nextResponseIndex = 0
  private var recordedRequests: [LLMRequest] = []

  init(responses: [Response]) {
    self.responses = responses
  }

  var profile: ProviderProfile {
    ProviderProfile(
      displayName: "顺序测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "sequential-model",
      credentialReference: "credential-test"
    )
  }

  var requests: [LLMRequest] {
    lock.withLock { recordedRequests }
  }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    let response: Response = lock.withLock {
      recordedRequests.append(request)
      defer { nextResponseIndex += 1 }
      guard nextResponseIndex < responses.count else {
        return .failure(URLError(.badServerResponse))
      }
      return responses[nextResponseIndex]
    }
    return AsyncThrowingStream { continuation in
      switch response {
      case .text(let text):
        continuation.yield(.textDelta(text))
        continuation.yield(.completed)
        continuation.finish()
      case .failure(let error):
        continuation.finish(throwing: error)
      }
    }
  }
}

private struct CopyingMaterialProvider: LLMProvider, Sendable {
  let characterLimit: Int?

  init(characterLimit: Int? = nil) {
    self.characterLimit = characterLimit
  }

  var profile: ProviderProfile {
    ProviderProfile(
      displayName: "照抄测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "copying-model",
      credentialReference: "credential-test"
    )
  }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    let system = request.messages.first?.content ?? ""
    let fullText = system.split(separator: "\n").compactMap { line -> String? in
      guard line.hasPrefix("参照 "),
        let colon = line.firstIndex(of: "："),
        let tension = line.range(of: "；张力：")
      else { return nil }
      return String(line[line.index(after: colon)..<tension.lowerBound])
    }.first ?? "照抄素材失败"
    let copied = characterLimit.map { String(fullText.prefix($0)) } ?? fullText
    let encodedChoices = (try? JSONEncoder().encode([copied, "另找一条安全退路"]))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    let response = "<STORY>雨幕遮住了门外的人影。</STORY>"
      + "<CHOICES>\(encodedChoices)</CHOICES><STATE_PATCH>{}</STATE_PATCH><MEMORY_PATCH>{}</MEMORY_PATCH>"
    return AsyncThrowingStream { continuation in
      continuation.yield(.textDelta(response))
      continuation.yield(.completed)
      continuation.finish()
    }
  }
}

private final class RecapAwareProvider: LLMProvider, @unchecked Sendable {
  private let lock = NSLock()
  private let failRecap: Bool
  private let contextWindow: Int?
  private var requests: [LLMRequest] = []

  init(failRecap: Bool = false, contextWindow: Int? = nil) {
    self.failRecap = failRecap
    self.contextWindow = contextWindow
  }

  var profile: ProviderProfile {
    ProviderProfile(
      displayName: "摘要测试服务",
      kind: .openAICompatible,
      baseURL: URL(string: "https://example.com/v1")!,
      modelID: "recap-model",
      credentialReference: "credential-test",
      capabilities: .init(contextWindow: contextWindow)
    )
  }

  var mainCallCount: Int {
    lock.withLock { requests.filter { !Self.isRecap($0) }.count }
  }

  var recapCallCount: Int {
    lock.withLock { requests.filter(Self.isRecap).count }
  }

  var recapRequests: [LLMRequest] {
    lock.withLock { requests.filter(Self.isRecap) }
  }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    lock.withLock { requests.append(request) }
    let recap = Self.isRecap(request)
    return AsyncThrowingStream { continuation in
      if recap, self.failRecap {
        continuation.finish(throwing: URLError(.cannotConnectToHost))
      } else {
        continuation.yield(
          .textDelta(
            recap
              ? "第一回到第二回的累计前情。"
              : "<STORY>剧情继续。</STORY><CHOICES>[\"继续调查\",\"暂时撤退\"]</CHOICES><STATE_PATCH>{}</STATE_PATCH>"
          )
        )
        continuation.yield(.completed)
        continuation.finish()
      }
    }
  }

  private static func isRecap(_ request: LLMRequest) -> Bool {
    request.messages.first?.content.hasPrefix("把给定前情与新增回合压缩") == true
  }
}


extension StoryTurnEngineTests {
  @Test("模型预算接入，停用分类不注入，大条目整条退出")
  func providerBudgetAndDisabledCategories() async throws {
    let fixture = try await makeFixture(lorebook: Lorebook(
      title: "预算测试",
      entries: [
        LoreEntry(id: "huge", title: "巨型设定", content: String(repeating: "大设定", count: 8_000), alwaysActive: true),
        LoreEntry(id: "disabled", title: "停用分类", content: "不应出现的分类内容", alwaysActive: true, categoryID: "off"),
        LoreEntry(id: "small", title: "线索", content: "青铜钥匙藏在门后", alwaysActive: true),
      ], categories: [LorebookCategory(id: "off", name: "停用", enabled: false)]))
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let profile = ProviderProfile(
      displayName: "small", kind: .openAICompatible, modelID: "test", credentialReference: "test",
      capabilities: .init(contextWindow: 8_192), maximumOutputTokens: 512)
    let request = try await StoryTurnEngine().makeRequest(
      turnID: UUID(), userMessage: "找钥匙", snapshot: fixture.snapshot,
      storyworld: fixture.storyworld, isCorrectionRetry: false, providerProfile: profile)
    #expect(request.modelOptions.maximumOutputTokens == 512)
    #expect(!request.messages[0].content.contains("巨型设定"))
    #expect(!request.messages[0].content.contains("不应出现的分类内容"))
    #expect(request.messages[0].content.contains("青铜钥匙藏在门后"))
    #expect(request.messages[0].content.contains("STATE_PATCH 必须是 JSON Merge Patch 对象"))
  }

  @Test("游玩线回放设置持久化、范围收敛且旧格式可读取")
  func replayPreferencePersistsAndOldMetadataDecodes() async throws {
    let fixture = try await makeFixture(lorebook: Lorebook(title: "测试", entries: []))
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let address = fixture.snapshot.context.address
    let oldData = try StoryworldCoding.makeEncoder().encode(fixture.snapshot.context.playthrough)
    var oldJSON = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
    oldJSON.removeValue(forKey: "history_window")
    let old = try StoryworldCoding.makeDecoder().decode(PlaythroughDescriptor.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    #expect(old.effectiveHistoryWindow == 20)
    for i in 1...4 {
      _ = try await fixture.runtime.commitTurn(address: address, turnID: UUID(), userMessage: "行动\(i)", narrative: "正文\(i)")
    }
    try await fixture.runtime.setHistoryWindow(-1, address: address)
    let snapshot = try await fixture.runtime.load(address: address)
    #expect(snapshot.context.playthrough.effectiveHistoryWindow == 2)
    let request = try await StoryTurnEngine().makeRequest(
      turnID: UUID(), userMessage: "下一步", snapshot: snapshot, storyworld: fixture.storyworld, isCorrectionRetry: false)
    #expect(request.messages.dropFirst().map(\.content) == ["行动3", "正文3", "行动4", "正文4", "下一步"])
    try await fixture.runtime.setHistoryWindow(999, address: address)
    #expect(try await fixture.runtime.load(address: address).context.playthrough.effectiveHistoryWindow == 200)
    #expect(try await fixture.runtime.load(address: address).turns.count == 4)
  }
}


extension StoryTurnEngineTests {
  @Test("摘要预算只覆盖实际装入的连续前缀，不越过缺口")
  func boundedRecapReportsActualCoverage() async throws {
    let fixture = try await makeFixture(lorebook: Lorebook(title: "长线", entries: []))
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let address = fixture.snapshot.context.address
    for index in 1...15 {
      _ = try await fixture.runtime.commitTurn(
        address: address, turnID: UUID(), userMessage: "行动[\(index)]",
        narrative: "剧情[\(index)]" + String(repeating: "合成叙事", count: 250))
    }
    let provider = RecapAwareProvider(contextWindow: 8_192)
    let before = try await fixture.runtime.load(address: address)
    var result: StoryTurnResult?
    for try await event in StoryTurnEngine(recapInterval: 1).runTurn(
      provider: provider, runtime: fixture.runtime, storyworld: fixture.storyworld,
      snapshot: before, userMessage: "继续", turnID: UUID(), isCorrectionRetry: false) {
      if case .completed(let value) = event { result = value }
    }
    let completed = try #require(result)
    let recap = try #require(completed.snapshot.recap)
    #expect(recap.throughEffectiveTurnCount > 0)
    #expect(recap.throughEffectiveTurnCount < 15)
    #expect(recap.lastAttemptedEffectiveTurnCount == 16)
    let request = try #require(provider.recapRequests.first)
    let input = try #require(request.messages.last?.content)
    #expect(input.contains("剧情[1]"))
    #expect(input.contains("剧情[\(recap.throughEffectiveTurnCount)]"))
    #expect(!input.contains("剧情[\(recap.throughEffectiveTurnCount + 1)]"))
    let manifest = try #require(completed.contextManifest)
    #expect(manifest.estimatedInputTokens <= manifest.inputBudget)
    #expect(completed.snapshot.turns.count == 16)
  }
}


extension StoryTurnEngineTests {
  @Test("无增强的小请求保持 df75124 原始系统提示词字节基线")
  func defaultProtocolMatchesOriginalBytes() async throws {
    let fixture = try await makeFixture(lorebook: Lorebook(title: "测试世界", entries: []))
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let request = try await StoryTurnEngine(continuityTracking: false).makeRequest(
      turnID: UUID(), userMessage: "继续", snapshot: fixture.snapshot,
      storyworld: fixture.storyworld, isCorrectionRetry: false)
    let content = try #require(request.messages.first?.content)
    let hash = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(hash == "c40e9fe79a936b4449d6bf50594495786527f94578520deafea0e7e24414155f")
  }
}


/// Runtime tests use the same persisted asset snapshot as production. Changing
/// only an in-memory document must now fail the canon preflight.
private func persistCanon(_ fixture: SessionFixture, document: StoryworldDocument) async throws
  -> (document: StoryworldDocument, snapshot: StorySessionSnapshot) {
  let library = StoryworldLibrary(rootURL: fixture.container.appendingPathComponent("library"))
  let package = try await library.managedPackageURL(storyworldID: document.manifest.storyworldID)
  let encoder = StoryworldCoding.makeEncoder()
  try encoder.encode(document.lorebook).write(to: package.appendingPathComponent(document.manifest.content.lorebookEntry))
  if let plotline = document.plotline { try encoder.encode(plotline).write(to: package.appendingPathComponent("plotline.json")) }
  if let timeline = document.timeline { try encoder.encode(timeline).write(to: package.appendingPathComponent("timeline.json")) }
  if let material = document.materialProfile { try encoder.encode(material).write(to: package.appendingPathComponent("material_profile.json")) }
  let address = fixture.snapshot.context.address
  let status = try await fixture.runtime.canonStatus(address: address)
  try await fixture.runtime.confirmCanonBinding(address: address, expectedCurrent: #require(status.current), expectedBindingID: status.bindingID)
  return (try await library.load(storyworldID: document.manifest.storyworldID), try await fixture.runtime.load(address: address))
}
