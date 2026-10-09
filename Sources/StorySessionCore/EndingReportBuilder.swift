import Foundation
import StoryMaterialKit
import StoryworldCore

public enum EndingReadiness: Equatable, Sendable {
  public static let recommendedTurnCount = 10

  case short(effectiveTurnCount: Int)
  case ready(effectiveTurnCount: Int)

  public init(effectiveTurnCount: Int) {
    if effectiveTurnCount < Self.recommendedTurnCount {
      self = .short(effectiveTurnCount: effectiveTurnCount)
    } else {
      self = .ready(effectiveTurnCount: effectiveTurnCount)
    }
  }

  public var requiresConfirmation: Bool {
    if case .short = self { return true }
    return false
  }
}

/// 只做确定性计算，不读取文件、不调用模型，也不推断叙事内容。
public enum EndingReportBuilder {
  public static func build(
    effectiveTurns: [CommittedStoryTurn],
    branchGraph: StoryBranchGraph,
    saves: [StorySave]
  ) -> EndingReportStatistics {
    EndingReportStatistics(
      turnCount: effectiveTurns.count,
      narrativeCharacterCount: effectiveTurns.reduce(0) { $0 + $1.narrative.count },
      turnsWithChoicesCount: effectiveTurns.count {
        !($0.choices ?? []).isEmpty
      },
      branchCount: branchGraph.nodes.count,
      saveCount: saves.count
    )
  }

  /// 只为有真实数据源的维度请求素材模板；篇幅与分支没有素材维度，固定回退普通行。
  public static func renderedStatisticLines(
    statistics: EndingReportStatistics,
    templates: [String: [StatTemplate]]
  ) -> [String] {
    [
      render(
        dimension: .turns,
        number: statistics.turnCount,
        fallback: "共经历 \(statistics.turnCount) 回",
        templates: templates
      ),
      "叙事共 \(statistics.narrativeCharacterCount) 字",
      render(
        dimension: .choicesMade,
        number: statistics.turnsWithChoicesCount,
        fallback: "其中 \(statistics.turnsWithChoicesCount) 回出现行动选项",
        templates: templates
      ),
      "游玩线共有 \(statistics.branchCount) 条分支",
      render(
        dimension: .saves,
        number: statistics.saveCount,
        fallback: "留下 \(statistics.saveCount) 份存档",
        templates: templates
      ),
    ]
  }

  public static func renderedStatisticLines(
    statistics: EndingReportStatistics,
    materialStore: MaterialStore = .shared,
    tone: StatTone = .epic
  ) async -> [String] {
    var templates: [String: [StatTemplate]] = [:]
    for dimension in [StatDimension.turns, .choicesMade, .saves] {
      templates[dimension.rawValue] = await materialStore.statTemplates(
        dimension: dimension,
        tone: tone
      )
    }
    return renderedStatisticLines(statistics: statistics, templates: templates)
  }

  private static func render(
    dimension: StatDimension,
    number: Int,
    fallback: String,
    templates: [String: [StatTemplate]]
  ) -> String {
    templates[dimension.rawValue]?.first?.rendered(number: number) ?? fallback
  }
}
