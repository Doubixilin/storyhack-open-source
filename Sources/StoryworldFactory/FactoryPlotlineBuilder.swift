import Foundation
import StoryworldCore

public struct FactoryPlotlineAssessment: Equatable, Sendable {
  public let nodes: [StoryPlotNode]
  public let coverage: StoryPlotlineCoverage
}

/// Local compilation only. Missing chapters stay explicit gaps; they are never
/// synthesized or treated as events the player has experienced.
public enum FactoryPlotlineBuilder {
  public static func makePlotline(
    analysis: FactoryAnalysis,
    manifest: FactoryInputManifest,
    generatedAt: Date = Date()
  ) -> StoryPlotline? {
    let result = assess(analysis: analysis, manifest: manifest)
    guard !result.nodes.isEmpty else { return nil }
    return StoryPlotline(nodes: result.nodes, source: "factory", generatedAt: generatedAt,
      coverage: result.coverage)
  }

  public static func assess(analysis: FactoryAnalysis, manifest: FactoryInputManifest)
    -> FactoryPlotlineAssessment
  {
    let chapters = manifest.chapters.filter(\.hasContent).sorted { $0.ordinal < $1.ordinal }
    let groups = Dictionary(grouping: analysis.chapterSummaries, by: \.chapterID)
    let covered = Set(analysis.coveredChapterIDs)
    var nodes: [StoryPlotNode] = []
    var gaps: [StoryPlotlineGap] = []
    var completeCount = 0
    let validIdentity = Set(manifest.chapters.map(\.id)).count == manifest.chapters.count
      && Set(manifest.chapters.map(\.ordinal)).count == manifest.chapters.count
      && manifest.chapters.allSatisfy { $0.ordinal >= 0 && $0.ordinal < Int.max }
      && analysis.sourceContentHash == manifest.contentHash
    for chapter in chapters {
      let units = groups[chapter.id] ?? []
      guard validIdentity, covered.contains(chapter.id),
        completeUnits(units, chapterOrdinal: chapter.ordinal) else {
        gaps.append(.init(chapterID: chapter.id, chapterOrdinal: chapter.ordinal,
          chapterTitle: chapter.title, reason: units.isEmpty ? .missing : .incomplete))
        continue
      }
      completeCount += 1
      // A non-narrative segment does not make the whole chapter front matter.
      guard !units.allSatisfy({ isFrontMatterSummary($0.summary) }) else { continue }
      let order = chapter.ordinal + 1
      nodes.append(.init(id: String(format: "plot-%04d", order), title: chapter.title,
        summary: units.sorted { $0.segmentIndex < $1.segmentIndex }.map(\.summary).joined(separator: "；"),
        order: order, chapterOrdinal: chapter.ordinal))
    }
    return .init(nodes: nodes, coverage: .init(sourceChapterCount: chapters.count,
      completeChapterCount: completeCount, gaps: gaps))
  }

  static func completeUnits(_ units: [FactoryChapterSummary], chapterOrdinal: Int) -> Bool {
    guard let count = units.first?.segmentCount, count > 0, count <= 10_000,
      units.count == count,
      units.allSatisfy({
        $0.chapterOrdinal == chapterOrdinal && $0.segmentCount == count
          && !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }) else { return false }
    let indices = Set(units.map(\.segmentIndex))
    // Existing synthetic/manual assets used zero-based segments; production
    // analysis uses one-based segments. Either complete sequence is accepted.
    return indices == Set(0..<count) || indices == Set(1...count)
  }

  static func isFrontMatterSummary(_ summary: String) -> Bool {
    ["无实际情节", "无实质情节", "无情节", "书籍信息页", "版权信息", "出版信息", "图书在版编目"]
      .contains { summary.contains($0) }
  }
}
