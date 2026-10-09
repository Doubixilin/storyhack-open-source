import Foundation
import LLMProviderKit
import StoryMaterialKit
import StoryworldCore

public enum EndingOratorError: Error, LocalizedError, Equatable {
  case emptyVerdict
  case responseTooLarge

  public var errorDescription: String? {
    switch self {
    case .emptyVerdict: "模型没有返回终局判词。"
    case .responseTooLarge: "终局判词超过允许长度。"
    }
  }
}

public enum EndingOratorEvent: Equatable, Sendable {
  case textDelta(String)
  case completed(String)
}

/// 独立于回合引擎的终局判词请求。它不提交事件，也不修改分支状态。
public struct EndingOrator: Sendable {
  public static let maximumInputCharacterCount = 8_000
  public static let forbiddenProductTerms = [
    "语域", "回合", "游玩线", "世界书", "分支", "存档", "平台", "模型", "AI",
  ]

  private let materialStore: MaterialStore

  public init(materialStore: MaterialStore = .shared) {
    self.materialStore = materialStore
  }

  public func makeRequest(
    requestID: UUID = UUID(),
    storyworld: StoryworldDocument,
    snapshot: StorySessionSnapshot
  ) async -> LLMRequest {
    let mode = StoryPlayMode.infer(from: snapshot.context.branch) ?? .canon
    let genre = storyworld.materialProfile.flatMap {
      MaterialGenre(rawValue: $0.primaryGenre)
    }
    let references: [EndingVerdict]
    if let genre {
      references = await endingReferences(genre: genre)
    } else {
      references = []
    }
    let referenceSection: String
    if references.isEmpty {
      referenceSection = ""
    } else {
      referenceSection = """

        以下是同题材、不同文体的笔法参照。它们非世界事实，只学笔法，严禁照搬人物、事件或句子：
        \(references.enumerated().map { "参照 \($0.offset + 1)（\($0.element.form.rawValue)）：\($0.element.text)" }.joined(separator: "\n"))
        """
    }
    let forbidden = Self.forbiddenProductTerms.joined(separator: "、")
    let genreRule = endingStyleRule(for: genre)
    let system = """
      你是为角色一生写终局判词的作者。判词是世界之内流传的文书，不是产品报告。
      正文严禁出现以下工程与产品词：\(forbidden)。不得用同义的技术说明绕开禁令。
      若需概括数量，必须化成世界语言，如“洋洋数万言”“几番生死取舍”，不得罗列统计字段。
      此人走过的是“\(modeMetaphor(mode))”；正文不得写出模式名称。
      只采用 classic 笔法，以角色一生的选择、代价、所得与未竟之事为骨架；情色笔法明确排除。
      \(genreRule)
      只输出 150–350 个中文字符的判词正文，不加标题、项目符号、解释或 Markdown。
      \(referenceSection)
      """

    let prefix = "请依据以下生平材料写判词。材料只提供事实，不可复述其中的工程词：\n"
    let history = historyMaterial(snapshot: snapshot)
    let budget = max(0, Self.maximumInputCharacterCount - prefix.count)
    let user = prefix + String(history.suffix(budget))
    return LLMRequest(
      requestID: requestID,
      messages: [
        LLMMessage(role: .system, content: system),
        LLMMessage(role: .user, content: user),
      ],
      modelOptions: LLMModelOptions(temperature: 0.7, maximumOutputTokens: 700)
    )
  }

  public func streamVerdict(
    provider: any LLMProvider,
    storyworld: StoryworldDocument,
    snapshot: StorySessionSnapshot,
    requestID: UUID = UUID()
  ) -> AsyncThrowingStream<EndingOratorEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = await makeRequest(
            requestID: requestID,
            storyworld: storyworld,
            snapshot: snapshot
          )
          var verdict = ""
          for try await event in provider.stream(request) {
            try Task.checkCancellation()
            guard case .textDelta(let delta) = event else { continue }
            verdict += delta
            guard verdict.utf8.count <= 16 * 1_024 else {
              throw EndingOratorError.responseTooLarge
            }
            continuation.yield(.textDelta(delta))
          }
          verdict = verdict.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !verdict.isEmpty else { throw EndingOratorError.emptyVerdict }
          continuation.yield(.completed(verdict))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func endingReferences(genre: MaterialGenre) async -> [EndingVerdict] {
    var candidates: [EndingVerdict] = []
    let forms = Set(EndingForm.allCases)
    for archetype in EndingArchetype.allCases {
      candidates += await materialStore.endingVerdicts(
        genre: genre,
        archetype: archetype,
        forms: forms
      )
    }
    let ordered = candidates.sorted { $0.id < $1.id }
    guard let first = ordered.first else { return [] }
    guard let second = ordered.first(where: { $0.form != first.form }) else { return [first] }
    return [first, second]
  }

  private func historyMaterial(snapshot: StorySessionSnapshot) -> String {
    var sections: [String] = []
    let start: Int
    if let recap = snapshot.recap,
      let narrative = recap.narrative,
      recap.throughEffectiveTurnCount <= snapshot.effectiveTurns.count
    {
      sections.append("前情：\(narrative)")
      start = recap.throughEffectiveTurnCount
    } else {
      start = max(0, snapshot.effectiveTurns.count - 20)
    }
    for turn in snapshot.effectiveTurns.dropFirst(start).suffix(20) {
      sections.append("行动：\(turn.userMessage)\n经历：\(turn.narrative)")
    }
    return sections.joined(separator: "\n\n")
  }

  private func modeMetaphor(_ mode: StoryPlayMode) -> String {
    switch mode {
    case .canon: "循着原本的命数"
    case .godMode: "逆写乾坤"
    case .evilGod: "走上歧天之路"
    }
  }

  private func endingStyleRule(for genre: MaterialGenre?) -> String {
    switch genre {
    case .gufeng, .lishi, .wuxia, .wuxianliu, .xianxia:
      "文风贴合古风题材，并以诗词般的判词收尾。"
    case .dushi, .kehuan, .xiaoyuan, .xihuan, .xuanyi:
      "文风贴合都市、科幻或现代题材，并以现代诗般的句子收尾。"
    case nil:
      "自行辨认题材：古风或修仙以诗词判词收尾，都市、科幻或现代以现代诗收尾。"
    }
  }
}
