import Foundation
import LLMProviderKit
import OSLog
import StoryMaterialKit
import StoryworldCore

public enum StoryTurnEvent: Sendable {
  /// 累计的可见叙事（已剥离标签），用于流式展示
  case narrative(String)
  case completed(StoryTurnResult)
}

public struct StoryTurnResult: Sendable {
  public let snapshot: StorySessionSnapshot
  public let warnings: [String]
  public let choices: [String]
  public let contextManifest: StoryContextManifest?

  public init(
    snapshot: StorySessionSnapshot, warnings: [String], choices: [String] = [],
    contextManifest: StoryContextManifest? = nil
  ) {
    self.snapshot = snapshot
    self.warnings = warnings
    self.choices = choices
    self.contextManifest = contextManifest
  }
}

/// 回合执行引擎：构造提示词、流式调用模型、解析回复并提交回合。
/// 从 StorySessionViewModel 下沉，供 SwiftUI 与内嵌 HTTP 服务共用。
public struct StoryTurnEngine: Sendable {
  private static let logger = Logger(
    subsystem: "org.doubixilin.storyhack.community",
    category: "StoryMaterialReferences"
  )
  private static let responseLogger = Logger(
    subsystem: "org.doubixilin.storyhack.community",
    category: "ModelResponseParsing"
  )

  private let materialStore: MaterialStore
  private let recapInterval: Int?
  private let continuityTracking: Bool
  private let tasteStore: PlayerTasteStore

  public init(
    materialStore: MaterialStore = .shared,
    recapInterval: Int? = nil,
    continuityTracking: Bool = true,
    tasteStore: PlayerTasteStore = .shared
  ) {
    self.materialStore = materialStore
    self.recapInterval = recapInterval.map { max(0, $0) }
    self.continuityTracking = continuityTracking
    self.tasteStore = tasteStore
  }

  /// 开场指令以「（系统指令：」前缀写入事件日志并参与上下文回放；
  /// UI 据此隐藏这条用户气泡。
  public static let openingPrompt =
    "（系统指令：玩家刚刚进入这个世界，还没有采取任何行动。请直接输出开场叙事："
    + "把玩家放进故事开端的场景里，交代其身份、处境与眼前正在发生的事，"
    + "结尾留给玩家行动的空间，并给出原著方向与创新方向的行动选项。不要替玩家做关键选择，不要输出旁白说明。）"

  /// 有原著主线时，开场锚定到第一节点的场景（即小说开端）。
  public static func openingPrompt(plotline: StoryPlotline?) -> String {
    guard let first = plotline?.firstNode else { return openingPrompt }
    if plotline?.coverage?.gaps.contains(where: { $0.chapterOrdinal < first.chapterOrdinal }) == true {
      return """
        （系统指令：玩家刚刚进入这个世界，还没有采取任何行动。原著开篇摘要缺失，\
        从现有主线最早可用场景「\(first.title)」开始：\(first.summary)。\
        不补造此前缺失章节，不将缺口事件视为玩家已经经历。交代眼前处境，\
        留给玩家行动空间，并给出原著方向与创新方向选项。不要替玩家做关键选择。）
        """
    }
    return """
      （系统指令：玩家刚刚进入这个世界，还没有采取任何行动。请直接输出开场叙事：\
      故事必须从原著主线开篇开始——「\(first.title)」：\(first.summary)\
      把玩家放进这个开端场景里，交代其身份、处境与眼前正在发生的事，\
      结尾留给玩家行动的空间，并给出原著方向与创新方向的行动选项。不要替玩家做关键选择，不要输出旁白说明。）
      """
  }

  /// 会话状态中记录当前主线节点的键；缺省视为第 1 节点
  public static let plotStateKey = "plot"
  public static let plotNodeStateKey = "node"
  public static let engineOwnedStateKeys: Set<String> = [plotStateKey, "continuity", "character_contracts"]

  /// 从会话状态读取当前主线节点序号（1-based），缺省为 1
  public static func currentPlotOrder(state: [String: JSONValue], plotline: StoryPlotline? = nil) -> Int {
    guard case .object(let plot) = state[plotStateKey],
      case .number(let value) = plot[plotNodeStateKey],
      let order = Int(exactly: value), order >= 1
    else { return plotline?.firstNode?.order ?? 1 }
    return order
  }

  public func makeRequest(
    turnID: UUID,
    userMessage: String,
    snapshot: StorySessionSnapshot,
    storyworld: StoryworldDocument,
    isCorrectionRetry: Bool,
    providerProfile: ProviderProfile? = nil
  ) async throws -> LLMRequest {
    try await prepareRequest(
      turnID: turnID,
      userMessage: userMessage,
      snapshot: snapshot,
      storyworld: storyworld,
      isCorrectionRetry: isCorrectionRetry,
      providerProfile: providerProfile
    ).request
  }

  private func prepareRequest(
    turnID: UUID,
    userMessage: String,
    snapshot: StorySessionSnapshot,
    storyworld: StoryworldDocument,
    isCorrectionRetry: Bool,
    providerProfile: ProviderProfile? = nil,
    continuityOverride: ContinuitySnapshot? = nil,
    chapterTools: Bool = false
  ) async throws -> PreparedTurnRequest {
    let directive = try snapshot.context.playthrough.effectiveDirective.validated()
    let taste = try await tasteStore.load().profile.promptSupplement()
    let effectiveTurns = snapshot.effectiveTurns
    let continuity = continuityTracking ? (continuityOverride ?? snapshot.continuity) : nil
    if continuityTracking, snapshot.continuityNotice != nil { throw ContinuityError.corruptHistory }
    let recentText =
      effectiveTurns.suffix(10).map {
        $0.userMessage + "\n" + $0.narrative
      }.joined(separator: "\n") + "\n" + userMessage
    let disabledCategories = Set(storyworld.lorebook.categories.filter { !$0.enabled }.map(\.id))
    let activatedLore = storyworld.lorebook.entries.filter { entry in
      guard entry.enabled, !disabledCategories.contains(entry.categoryID ?? "") else { return false }
      return entry.alwaysActive
        || entry.activationKeys.isEmpty
        || entry.activationKeys.contains { recentText.localizedCaseInsensitiveContains($0) }
    }
    let stateValues = snapshot.state.values.filter { !["continuity", "character_contracts"].contains($0.key) }
    let stateData = try JSONEncoder().encode(JSONValue.object(stateValues))
    let stateText = String(data: stateData, encoding: .utf8) ?? "{}"
    let mode = StoryPlayMode.infer(from: snapshot.context.branch) ?? .canon
    let requiresChoices = effectiveTurns.count < 3
    let correctionRule = isCorrectionRetry
      ? "\n这是一次格式纠错重试。上一份回复没有提交；必须完整输出 <STORY> 与 <STATE_PATCH> 两个标签，尤其不要遗漏 <STORY>。"
      : ""
    let beatSection: String
    let recordedBeatIDs = Set(effectiveTurns.compactMap(\.beatID))
    let recordedBeats = storyworld.timeline?.beats.filter { recordedBeatIDs.contains($0.id) } ?? []
    if !recordedBeats.isEmpty {
      let beatList = recordedBeats
        .map { "\($0.id)：\($0.title)——\($0.summary)" }
        .joined(separator: "\n")
      beatSection = """

        已有回合记录的原著节拍（仅用于标记位置，不等于该节拍摘要全部发生）：
        \(beatList)
        每回合必须在 <STATE_PATCH> 之后追加 <BEAT>当前所处节拍ID</BEAT>；
        剧情不在任何已知节拍上时输出 <BEAT>none</BEAT>。
        """
    } else {
      beatSection = ""
    }
    let plotSection: String
    if mode == .canon, let plotline = storyworld.plotline, !plotline.nodes.isEmpty {
      let currentOrder = Self.currentPlotOrder(state: snapshot.state.values, plotline: plotline)
      let past = StoryChapterSearch(snapshot: snapshot, plotline: plotline)
      var lines = ""
      if let previous = past.cards.last {
        lines += "\n曾记录的原著节点（静态参考，以实际游玩历史为准）：\(previous.title)——\(previous.summary)"
      }
      if let current = plotline.node(order: currentOrder) {
        lines += "\n当前剧情节点：\(current.id)「\(current.title)」——\(current.summary)"
      }
      if let notice = plotline.coverage?.notice {
        lines += "\n\(notice)\n缺失节点没有可用原著依据；不得补造缺口内容或把跳过的节点写成玩家已经历的事实。"
      }
      plotSection = """

        原著主线（正史模式必须沿主线按顺序推进）：
        \(lines)
        规则：玩家行动可以改变过程与细节，但当前节点的主事件按主线发生；
        只有玩家在本回合明确表达跳剧情/快进/回退时，才允许离开当前节点；
        每回合必须在 <BEAT> 之后追加 <PLOT>本回合结束时所处的节点ID</PLOT>。
        """
    } else {
      plotSection = ""
    }
    let materialInjection = await choiceMaterialInjection(
      storyworld: storyworld,
      snapshot: snapshot
    )
    let systemPrefix = """
      \(DirectiveProfile.basePreamble)

      当前模式：\(mode.displayName)
      \(mode.promptRule)\(directive.supplement(mode: mode))

      当前 Lorebook：
      """ + "\n"
    let stateSection = "\n\n" + """
      当前状态：
      \(stateText)
      \(beatSection)
      \(plotSection)
      """ + "\n"
    let formatRules = """
      只允许按以下格式回复，不要添加 Markdown 代码围栏或额外文字：
      <STORY>给玩家阅读的中文叙事</STORY>
      <CHOICES>["贴近原著重点剧情的具体行动","AI 创新的具体行动"]</CHOICES>
      <STATE_PATCH>{"发生变化的字段":"新值"}</STATE_PATCH>
      CHOICES 必须是 2–4 个简短具体行动的 JSON 字符串数组；第一项贴近原著重点剧情，第二项为创新方向。
      每个选项必须是玩家此刻可执行的具体行动，结合当前场景、在场人物、已知线索、风险与玩家上一步行动。
      选项之间的语义与后果必须真正不同，可覆盖调查、交涉、隐瞒、借助关系、冒险、撤退、改变目标等方向，不得把同一件事换词重述。
      叙事中已经隐式抛出的可选行动必须镜像进 <CHOICES>，使选项卡与正文互文。
      禁止输出“观察眼前线索，顺势推进”“采取意料之外的行动”等放之四海皆准的模板话。
      \(requiresChoices ? "当前属于开局引导阶段，本回合必须提供 CHOICES。" : "重大剧情或决策点必须提供 CHOICES；普通过渡回合也优先提供，确无选择时可返回 []。")
      STATE_PATCH 必须是 JSON Merge Patch 对象；没有状态变化时必须返回 {}。
      \(correctionRule)
      """
    let usableRecap = snapshot.recap.flatMap {
      $0.throughEffectiveTurnCount <= effectiveTurns.count ? $0 : nil
    }
    var sections = [StoryContextSection(
      id: "protocol.preamble", content: systemPrefix, flexibility: .mandatory)]
    for (index, entry) in activatedLore.enumerated() {
      sections.append(.init(
        id: "lore.\(entry.id)",
        content: (index == 0 ? "" : "\n\n") + "## \(entry.title)\n\(entry.content)",
        priority: entry.alwaysActive ? 55 : 80))
    }
    sections.append(.init(id: "state", content: stateSection, flexibility: .mandatory))
    if !taste.isEmpty {
      sections.append(.init(id: "player-taste", content: taste, flexibility: .mandatory))
    }
    sections.append(contentsOf: try CharacterContractContext.sections(
      file: storyworld.characterContracts,
      presentEntityIDs: Set(continuity?.ledger.scene?.presentEntityIDs ?? []), userMessage: userMessage,
      recentNarrative: effectiveTurns.last?.narrative ?? ""))
    sections.append(contentsOf: StoryAnchorContext.sections(snapshot: snapshot, userMessage: userMessage))
    let recapSection = Self.recapSection(usableRecap)
    if !recapSection.isEmpty {
      sections.append(.init(id: "recap", content: recapSection + "\n\n", priority: 60))
    }
    if !materialInjection.section.isEmpty {
      sections.append(.init(id: "materials", content: materialInjection.section + "\n\n", priority: 90))
    }
    sections.append(.init(id: "protocol.format", content: formatRules, flexibility: .mandatory))
    if chapterTools {
      sections.append(.init(id: "protocol.chapter-search",
        content: StoryChapterSearch.instruction, flexibility: .mandatory))
    }
    if let continuity {
      sections.append(contentsOf: try ContinuityContext.sections(continuity))
      sections.append(ContinuityContext.protocolSection)
    }
    let window = providerProfile?.capabilities.contextWindow ?? StoryContextCompiler.defaultContextWindow
    let output = min(directive.maximumOutputTokens
      ?? providerProfile?.maximumOutputTokens ?? min(StoryContextCompiler.defaultOutputTokens, window / 4),
      providerProfile?.maximumOutputTokens ?? Int.max)
    let compiled = try StoryContextCompiler.compile(
      sections: sections,
      history: effectiveTurns.map {
        StoryContextTurn(id: "turn." + $0.turnID.uuidString, user: $0.userMessage, narrative: $0.narrative)
      },
      userMessage: userMessage,
      contextWindow: window,
      maximumOutputTokens: output,
      historyWindow: snapshot.context.playthrough.effectiveHistoryWindow,
      reservedInputTokens: chapterTools ? StoryChapterSearch.reservedTokens : 0)
    return PreparedTurnRequest(
      request: LLMRequest(
        requestID: turnID,
        messages: compiled.messages,
        modelOptions: .init(maximumOutputTokens: output),
        tools: chapterTools ? [StoryChapterSearch.definition] : [],
        toolChoice: chapterTools ? .auto : nil
      ),
      referencedChoices: compiled.manifest.entries.contains { $0.id == "materials" && $0.included }
        ? materialInjection.items : [],
      manifest: compiled.manifest
    )
  }

  /// 把 <PLOT> 回报合成进状态补丁：仅当节点存在于 plotline 时生效；
  /// plot.node 由引擎写入，模型补丁里的同名字段以引擎为准。
  public static func applyingPlotNode(
    _ plotNodeID: String?,
    plotline: StoryPlotline?,
    to statePatchData: Data
  ) -> Data {
    guard var values = try? JSONDecoder().decode(
      [String: JSONValue].self,
      from: statePatchData
    ) else { return statePatchData }
    for key in engineOwnedStateKeys {
      values.removeValue(forKey: key)
    }
    if let plotNodeID, let node = plotline?.node(id: plotNodeID) {
      values[plotStateKey] = .object([plotNodeStateKey: .number(Double(node.order))])
    }
    return (try? JSONEncoder().encode(values)) ?? statePatchData
  }

  /// 执行一个完整回合：流式产出可见叙事，结束后解析并提交，
  /// 最后 yield 携带最新快照的 `.completed`。
  /// 流中途出错（含取消、incompleteStream）时不提交任何回合，错误原样抛出。
  public func runTurn(
    provider: any LLMProvider,
    runtime: StoryworldRuntimeStore,
    storyworld: StoryworldDocument,
    snapshot: StorySessionSnapshot,
    userMessage: String,
    commitUserMessage: String? = nil,
    turnID: UUID,
    isCorrectionRetry: Bool
  ) -> AsyncThrowingStream<StoryTurnEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let canon = try await runtime.requireCanon(
            address: snapshot.context.address, document: storyworld,
            bindingID: snapshot.context.playthrough.canonBinding?.id)
          let directiveToken = try await runtime.requireDirective(address: snapshot.context.address,
            expected: snapshot.context.playthrough.directive)
          let continuityBase: ContinuitySnapshot? = continuityTracking
            ? try await runtime.continuitySnapshot(address: snapshot.context.address) : nil
          if let continuityBase {
            guard continuityBase.lastEventSequence == snapshot.state.lastEventSequence,
              snapshot.continuity == nil || snapshot.continuity?.hash == continuityBase.hash
            else { throw ContinuityError.staleBase }
          }
          let plain = try await prepareRequest(
            turnID: turnID,
            userMessage: userMessage,
            snapshot: snapshot,
            storyworld: storyworld,
            isCorrectionRetry: isCorrectionRetry,
            providerProfile: provider.profile,
            continuityOverride: continuityBase
          )
          var prepared = plain
          var search: StoryChapterSearch?
          var toolWarning: String?
          let available = StoryChapterSearch(snapshot: snapshot, plotline: storyworld.plotline)
          if provider.profile.capabilities.toolCalling, !available.isEmpty {
            // Budget first: a small model must not spend requests probing a tool
            // that cannot fit alongside this turn's required context.
            do {
              let toolRequest = try await prepareRequest(turnID: turnID, userMessage: userMessage,
                snapshot: snapshot, storyworld: storyworld, isCorrectionRetry: isCorrectionRetry,
                providerProfile: provider.profile, continuityOverride: continuityBase, chapterTools: true)
              let support = await LLMToolCapabilityProbe.shared.check(provider)
              try Task.checkCancellation()
              if support == .supported { prepared = toolRequest; search = available }
              else { toolWarning = "本轮章节回读检测未通过，已使用普通上下文继续。" }
            } catch is StoryContextError {
              toolWarning = "当前上下文没有足够的回读余量，本轮使用普通上下文。"
            }
          }
          Self.logger.debug("Context budget=\(prepared.manifest.inputBudget) used_estimate=\(prepared.manifest.estimatedInputTokens) replayed_turns=\(prepared.manifest.replayedTurns)")
          let generated = try await StoryToolRunner.generate(provider: provider,
            request: prepared.request, fallback: plain.request, search: search,
            inputBudget: prepared.manifest.inputBudget) {
              continuation.yield(.narrative($0))
            }
          if generated.usedFallback {
            prepared = plain
            await LLMToolCapabilityProbe.shared.recordDefinitiveRejection(provider.profile)
            toolWarning = "模型服务未接受章节回读协议，本轮已回退普通上下文。"
          } else if generated.calls > 0 {
            toolWarning = "本轮回读 \(generated.calls) 次，取得 \(generated.cardIDs.count) 张原著章节摘要卡。"
          }
          let rawResponse = generated.rawResponse
          let envelope: StoryResponseEnvelope
          do {
            envelope = try StoryResponseEnvelopeParser.parseRecovering(rawResponse)
          } catch StoryResponseEnvelopeError.missingNarrative {
            Self.responseLogger.error(
              "Model response missing recoverable narrative; response_bytes=\(rawResponse.utf8.count, privacy: .public)"
            )
            throw ModelResponseParseFailure(rawResponse: rawResponse)
          }
          var recoveredChoices = envelope.choices
          var recoveryWarnings = envelope.recoveryWarnings
          var recoveredPatch = envelope.statePatchData
          var didRepairChoices = false
          let needsChoices = recoveredChoices.isEmpty && snapshot.effectiveTurns.count < 3
          if needsChoices || envelope.statePatchStatus == .missing {
            let repair = try await StoryProtocolRepair.repair(provider: provider,
              narrative: envelope.narrative, userMessage: userMessage,
              state: snapshot.state.values, reserved: Self.engineOwnedStateKeys,
              needsChoices: needsChoices, needsPatch: envelope.statePatchStatus == .missing)
            if !repair.choices.isEmpty { recoveredChoices = repair.choices; didRepairChoices = true }
            if let patch = repair.statePatch {
              recoveredPatch = patch
              // Repair resolves the missing patch, not other recovery losses.
              recoveryWarnings.removeAll { $0 == "模型未提供状态补丁；本轮叙事已保存，状态保持不变。" }
              if patch != Data("{}".utf8) { recoveryWarnings.append("缺失状态补丁已按既有字段和原文依据补齐。") }
            }
          }
          let modelChoices: [String]
          if let violation = Self.choiceOverlapViolation(
            choices: recoveredChoices,
            materials: prepared.referencedChoices
          ) {
            Self.logger.warning(
              "Discarded copied model choices; material_ids=\(violation.materialIDs.joined(separator: ","), privacy: .public) overlap=\(violation.maximumEightGramOverlap, privacy: .public)"
            )
            modelChoices = []
          } else {
            modelChoices = recoveredChoices
          }
          if didRepairChoices, !modelChoices.isEmpty {
            recoveryWarnings.append("行动选项已由修复通道补齐")
          }
          if let toolWarning { recoveryWarnings.append(toolWarning) }
          let choices = Self.resolvedChoices(
            modelChoices,
            snapshot: snapshot,
            storyworld: storyworld,
            narrative: envelope.narrative
          )
          // Only recorded or explicitly named beats can supply metadata. A
          // shared keyword must not reveal a later beat's title or summary.
          let visibleTimeline = Self.visibleTimeline(snapshot: snapshot, timeline: storyworld.timeline,
            narrative: envelope.narrative)
          let beatID = envelope.beatID.flatMap { visibleTimeline?.beat(id: $0)?.id }
            ?? visibleTimeline?.matchedBeatID(
              for: userMessage + "\n" + envelope.narrative
            )
          // <PLOT> 由引擎合成进状态补丁（非法节点 ID 自动忽略）
          let patchedData = Self.applyingPlotNode(
            envelope.plotNodeID,
            plotline: storyworld.plotline,
            to: recoveredPatch
          )
          do {
            _ = try await runtime.commitTurn(
              address: snapshot.context.address,
              turnID: turnID,
              userMessage: commitUserMessage ?? userMessage,
              narrative: envelope.narrative,
              choices: choices.isEmpty ? nil : choices,
              statePatchData: patchedData,
              beatID: beatID,
              expectedEventSequence: snapshot.state.lastEventSequence,
              expectedStateHash: snapshot.state.stateHash,
              expectedCanon: canon,
              continuityInput: continuityTracking ? .init(data: envelope.memoryPatchData) : nil,
              expectedContinuityHash: continuityBase?.hash,
              expectedDirective: directiveToken
            )
          } catch let error as StoryworldRuntimeError {
            switch error {
            case .malformedStatePatch, .statePatchTooLarge, .statePatchTooComplex:
              _ = try await runtime.commitTurn(
                address: snapshot.context.address,
                turnID: turnID,
                userMessage: commitUserMessage ?? userMessage,
                narrative: envelope.narrative,
                choices: choices.isEmpty ? nil : choices,
                statePatchData: Self.applyingPlotNode(
                  envelope.plotNodeID,
                  plotline: storyworld.plotline,
                  to: Data("{}".utf8)
                ),
                beatID: beatID,
                expectedEventSequence: snapshot.state.lastEventSequence,
                expectedStateHash: snapshot.state.stateHash,
                expectedCanon: canon,
                continuityInput: continuityTracking ? .init(data: envelope.memoryPatchData) : nil,
                expectedContinuityHash: continuityBase?.hash,
                expectedDirective: directiveToken
              )
              recoveryWarnings.append(
                "模型状态补丁超过运行安全边界；本轮叙事已保存，但未应用状态变化。"
              )
            default:
              throw error
            }
          }
          let committedSnapshot = try await runtime.load(address: snapshot.context.address)
          if committedSnapshot.turns.last?.continuityUpdate?.status == .needsReconciliation {
            recoveryWarnings.append("本轮连续性提取缺失或未通过校验；叙事已保存，记忆记录留有待核对缺口。")
          }
          await refreshRecapIfNeeded(
            provider: provider,
            runtime: runtime,
            snapshot: committedSnapshot
          )
          let reloaded = try await runtime.load(address: snapshot.context.address)
          continuation.yield(
            .completed(
              StoryTurnResult(
                snapshot: reloaded,
                warnings: recoveryWarnings,
                choices: choices,
                contextManifest: prepared.manifest
              )
            )
          )
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func choiceMaterialInjection(
    storyworld: StoryworldDocument,
    snapshot: StorySessionSnapshot
  ) async -> ChoiceMaterialInjection {
    guard let profile = storyworld.materialProfile,
      profile.schemaVersion == 1,
      profile.confidence >= 0.65,
      let genre = MaterialGenre(rawValue: profile.primaryGenre),
      let scene = Self.resolvedScene(profile: profile, storyworld: storyworld, snapshot: snapshot),
      let manifest = await materialStore.manifest()
    else { return .empty }

    let available = await materialStore.choices(genre: genre, scene: scene)
    guard !available.isEmpty else { return .empty }
    let address = snapshot.context.address
    let purpose = "choices"
    let recent = await materialStore.recentMaterialIDs(
      storyworldID: address.storyworldID,
      branchID: address.branchID,
      purpose: purpose
    )
    let seed = [
      manifest.materialVersion,
      address.storyworldID.uuidString.lowercased(),
      address.branchID.uuidString.lowercased(),
      String(snapshot.state.lastEventSequence + 1),
      purpose,
    ].joined(separator: "|")
    if let cachedIDs = await materialStore.cachedMaterialIDs(
      seed: seed,
      storyworldID: address.storyworldID,
      branchID: address.branchID,
      purpose: purpose
    ) {
      let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
      let cached = cachedIDs.compactMap { byID[$0] }
      let section = Self.materialReferenceSection(cached)
      if !cached.isEmpty, section.count <= 700 {
        return ChoiceMaterialInjection(section: section, items: cached)
      }
    }
    let ranked = await materialStore.sampled(
      available,
      purpose: purpose,
      seed: seed,
      excluding: recent,
      maxChars: 100_000
    )

    var selected: [ChoiceMaterial] = []
    for item in ranked {
      let candidate = selected + [item]
      guard Self.materialReferenceSection(candidate).count <= 700 else { continue }
      selected = candidate
      if selected.count == 2 { break }
    }
    guard !selected.isEmpty else { return .empty }
    await materialStore.recordUsedMaterialIDs(
      selected.map(\.id),
      storyworldID: address.storyworldID,
      branchID: address.branchID,
      purpose: purpose,
      seed: seed
    )
    return ChoiceMaterialInjection(
      section: Self.materialReferenceSection(selected),
      items: selected
    )
  }

  private static func resolvedScene(
    profile: MaterialProfile,
    storyworld: StoryworldDocument,
    snapshot: StorySessionSnapshot
  ) -> ChoiceScene? {
    let currentOrder = currentPlotOrder(state: snapshot.state.values, plotline: storyworld.plotline)
    if let plotID = storyworld.plotline?.node(order: currentOrder)?.id,
      let scene = profile.plotSceneMap[plotID]?.lazy.compactMap(ChoiceScene.init(rawValue:)).first
    {
      return scene
    }
    if let beatID = snapshot.effectiveTurns.last?.beatID,
      let scene = profile.beatSceneMap[beatID]?.lazy.compactMap(ChoiceScene.init(rawValue:)).first
    {
      return scene
    }
    return nil
  }

  private static func materialReferenceSection(_ items: [ChoiceMaterial]) -> String {
    let references = items.enumerated().map { index, item in
      "参照 \(index + 1)：\(item.text)；张力：\(item.tension)；代价：\(item.stakes)"
    }.joined(separator: "\n")
    return """
      <MATERIAL_REFERENCES purpose="choice-specificity" rewrite_required="true">
      \(references)
      </MATERIAL_REFERENCES>
      规则：只学习行动的具体性、风险与张力；不得复用参照中的人名、地点、物品、数字或完整短语，所有行动必须只绑定当前世界已经存在的实体。
      """
  }

  private static func recapSection(_ recap: StoryRecap?) -> String {
    guard let recap,
      let narrative = recap.narrative?.trimmingCharacters(in: .whitespacesAndNewlines),
      !narrative.isEmpty
    else { return "" }
    return """
      <STORY_RECAP through_effective_turn="\(recap.throughEffectiveTurnCount)">
      \(narrative)
      </STORY_RECAP>
      这是累计前情，可能与近期原文重叠；重复内容不代表事件再次发生。当前 Lorebook、状态与事件原文优先，摘要不得覆盖它们。
      """
  }

  /// 主回合已经提交后再尝试刷新摘要。任何生成、解析或落盘失败都只
  /// 更新失败节流点并静默返回，不撤销叙事，也不在每个后续回合重试。
  private func refreshRecapIfNeeded(
    provider: any LLMProvider,
    runtime: StoryworldRuntimeStore,
    snapshot: StorySessionSnapshot
  ) async {
    let interval = recapInterval ?? snapshot.context.playthrough.effectiveDirective.recapInterval ?? 20
    guard interval > 0 else { return }
    let historyCount = snapshot.effectiveTurns.count
    let existing = snapshot.recap
    let lastAttempt = existing?.lastAttemptedEffectiveTurnCount ?? 0
    guard historyCount - lastAttempt >= interval else { return }

    do {
      let uncovered = snapshot.effectiveTurns.dropFirst(
        min(existing?.throughEffectiveTurnCount ?? 0, historyCount)
      )
      let previous = existing?.narrative.map { "上一次累计前情：\n\($0)\n\n" } ?? ""
      let instructions = StoryContextSection(
        id: "recap.protocol",
        content: "把给定前情与新增回合压缩为一段连贯的中文前情摘要。保留人物、目标、关系、关键事件与未决悬念；不要添加原文没有的事实。只输出摘要正文，不要标签或说明。",
        flexibility: .mandatory)
      let window = provider.profile.capabilities.contextWindow ?? StoryContextCompiler.defaultContextWindow
      let output = min(1_200, provider.profile.maximumOutputTokens ?? 1_200, window / 4)
      let base = try StoryContextCompiler.compile(
        sections: [instructions], userMessage: previous,
        contextWindow: window, maximumOutputTokens: output)
      var remaining = base.manifest.inputBudget - base.manifest.estimatedInputTokens
      var covered = 0
      var turnsText = ""
      // Oldest uncovered turns first. Never claim coverage of a skipped turn.
      for turn in uncovered {
        let ordinal = (existing?.throughEffectiveTurnCount ?? 0) + covered + 1
        let text = "回合 \(ordinal)\n玩家：\(turn.userMessage)\n剧情：\(turn.narrative)\n\n"
        let cost = StoryContextCompiler.estimatedTokens(text)
        guard cost <= remaining else { break }
        turnsText += text
        remaining -= cost
        covered += 1
      }
      guard covered > 0 else { throw StoryContextError.mandatoryExceedsBudget }
      let compiled = try StoryContextCompiler.compile(
        sections: [instructions], userMessage: previous + turnsText,
        contextWindow: window, maximumOutputTokens: output)
      let request = LLMRequest(
        requestID: UUID(), messages: compiled.messages,
        modelOptions: LLMModelOptions(temperature: 0.2, maximumOutputTokens: output))
      var recapText = ""
      for try await event in provider.stream(request) {
        try Task.checkCancellation()
        if case .textDelta(let delta) = event {
          recapText += delta
          guard recapText.utf8.count <= 64 * 1_024 else {
            throw StoryResponseEnvelopeError.responseTooLarge
          }
        }
      }
      recapText = recapText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !recapText.isEmpty else { throw EmptyRecapError() }
      try await runtime.saveRecap(
        StoryRecap(
          throughEffectiveTurnCount: (existing?.throughEffectiveTurnCount ?? 0) + covered,
          lastAttemptedEffectiveTurnCount: historyCount,
          narrative: recapText,
          generatedAt: Date()
        ),
        address: snapshot.context.address
      )
    } catch {
      try? await runtime.saveRecap(
        StoryRecap(
          throughEffectiveTurnCount: existing?.throughEffectiveTurnCount ?? 0,
          lastAttemptedEffectiveTurnCount: historyCount,
          narrative: existing?.narrative,
          generatedAt: existing?.generatedAt
        ),
        address: snapshot.context.address
      )
    }
  }

  private static func choiceOverlapViolation(
    choices: [String],
    materials: [ChoiceMaterial]
  ) -> ChoiceOverlapViolation? {
    guard !choices.isEmpty, !materials.isEmpty else { return nil }
    var offendingIDs = Set<String>()
    var maximumOverlap = 0.0
    for choice in choices {
      for material in materials {
        let overlap = eightGramOverlap(choice, material.text)
        maximumOverlap = max(maximumOverlap, overlap)
        if containsTwelveContinuousMatchingHanCharacters(choice, material.text)
          || overlap > 0.5
        {
          offendingIDs.insert(material.id)
        }
      }
    }
    guard !offendingIDs.isEmpty else { return nil }
    return ChoiceOverlapViolation(
      materialIDs: offendingIDs.sorted(),
      maximumEightGramOverlap: maximumOverlap
    )
  }

  private static func containsTwelveContinuousMatchingHanCharacters(
    _ lhs: String,
    _ rhs: String
  ) -> Bool {
    let rhsRuns = chineseRuns(rhs)
    for run in chineseRuns(lhs) where run.count >= 12 {
      let characters = Array(run)
      for start in 0...(characters.count - 12) {
        let fragment = String(characters[start..<(start + 12)])
        if rhsRuns.contains(where: { $0.contains(fragment) }) { return true }
      }
    }
    return false
  }

  private static func chineseRuns(_ text: String) -> [String] {
    var runs: [String] = []
    var current = ""
    for character in text {
      if character.unicodeScalars.allSatisfy({ scalar in
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2FA1F: true
        default: false
        }
      }) {
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
    let left = characterNGrams(lhs, size: 8)
    let right = characterNGrams(rhs, size: 8)
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    return Double(left.intersection(right).count) / Double(min(left.count, right.count))
  }

  private static func characterNGrams(_ text: String, size: Int) -> Set<String> {
    let characters = Array(text).filter { character in
      !character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    guard characters.count >= size else { return [] }
    return Set((0...(characters.count - size)).map { start in
      String(characters[start..<(start + size)])
    })
  }

  /// 模型偶尔会漏掉增强标签。开局前三轮不能因此再次把新玩家留在空白输入框前，
  /// 所以缺失时补两个确定性方向；后续普通过渡回合仍允许没有选项。
  private static func resolvedChoices(
    _ modelChoices: [String],
    snapshot: StorySessionSnapshot,
    storyworld: StoryworldDocument,
    narrative: String
  ) -> [String] {
    guard modelChoices.isEmpty, snapshot.effectiveTurns.count < 3 else { return modelChoices }
    let currentOrder = currentPlotOrder(state: snapshot.state.values, plotline: storyworld.plotline)
    if let node = storyworld.plotline?.node(order: currentOrder),
      narrative.contains(node.title)
    {
      return StoryFallbackChoices.choices(narrative: narrative, revealedBeat: node.title)
    }
    if let timeline = visibleTimeline(snapshot: snapshot, timeline: storyworld.timeline, narrative: narrative),
      let beatID = timeline.matchedBeatID(for: narrative),
      let beat = timeline.beats.first(where: { $0.id == beatID }) {
      return StoryFallbackChoices.choices(narrative: narrative, revealedBeat: beat.title)
    }
    return StoryFallbackChoices.choices(narrative: narrative)
  }

  private static func visibleTimeline(snapshot: StorySessionSnapshot, timeline: StoryTimeline?,
    narrative: String) -> StoryTimeline? {
    guard var timeline else { return nil }
    let recorded = Set(snapshot.effectiveTurns.compactMap(\.beatID))
    timeline.beats = timeline.beats.filter {
      recorded.contains($0.id) || (!$0.title.isEmpty && narrative.contains($0.title))
    }
    return timeline
  }
}

private struct PreparedTurnRequest: Sendable {
  let request: LLMRequest
  let referencedChoices: [ChoiceMaterial]
  let manifest: StoryContextManifest
}

private struct ChoiceMaterialInjection: Sendable {
  static let empty = ChoiceMaterialInjection(section: "", items: [])

  let section: String
  let items: [ChoiceMaterial]
}

private struct ChoiceOverlapViolation: Sendable {
  let materialIDs: [String]
  let maximumEightGramOverlap: Double
}

private struct EmptyRecapError: Error {}
