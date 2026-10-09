import Foundation
import NovelDocumentCore
import StoryworldCore

/// 从工坊分析产物推导原著节拍线：复用 kind == timeline 的候选条目，
/// 按证据锚定的章节顺序排列，零新增 LLM 调用。
public enum FactoryTimelineBuilder {
  /// 节拍数量上限，与端侧提取保持同一颗粒度
  public static let maximumBeatCount = 50

  public static func makeTimeline(
    analysis: FactoryAnalysis,
    document: NovelDocument,
    generatedAt: Date = Date()
  ) -> StoryTimeline? {
    let proposals = analysis.proposals.filter { $0.kind == .timeline }
    guard !proposals.isEmpty else { return nil }

    let chapterOrdinals = Dictionary(
      uniqueKeysWithValues: document.chapters.map { ($0.title, $0.ordinal) }
    )
    func firstChapterOrdinal(_ proposal: FactoryLoreProposal) -> Int {
      proposal.evidence.compactMap { chapterOrdinals[$0.chapterTitle] }.min() ?? .max
    }

    let sorted = proposals.sorted { lhs, rhs in
      let l = firstChapterOrdinal(lhs)
      let r = firstChapterOrdinal(rhs)
      return l == r ? lhs.title < rhs.title : l < r
    }

    let beats = sorted.prefix(maximumBeatCount).enumerated().map { index, proposal in
      StoryBeat(
        id: String(format: "beat-%02d", index + 1),
        title: proposal.title,
        summary: Self.summary(from: proposal.content),
        order: index + 1,
        keywords: proposal.activationKeys.filter { !$0.isEmpty }
      )
    }
    return StoryTimeline(beats: beats, source: "factory", generatedAt: generatedAt)
  }

  /// 候选正文首行截断为节拍摘要
  static func summary(from content: String) -> String {
    let line = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
  }
}
