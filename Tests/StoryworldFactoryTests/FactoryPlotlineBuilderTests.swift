import Foundation
import NovelDocumentCore
import StoryworldCore
import StoryworldFactory
import Testing

@Suite("FactoryPlotlineBuilder")
struct FactoryPlotlineBuilderTests {
  private func summary(_ id: String, ordinal: Int, segment: Int = 1, count: Int = 1,
    text: String = "林舟抵达渡口，发现石塔。") -> FactoryChapterSummary {
    .init(chapterID: id, chapterOrdinal: ordinal, chapterTitle: "模型标题不作权威",
      segmentIndex: segment, segmentCount: count, summary: text)
  }
  private func analysis(_ summaries: [FactoryChapterSummary], covered: [String]? = nil) -> FactoryAnalysis {
    .init(sourceContentHash: "hash", coveredChapterIDs: covered ?? Array(Set(summaries.map(\.chapterID))).sorted(),
      proposals: [], decisions: [], chapterSummaries: summaries)
  }
  private func manifest(_ ids: [String]) -> FactoryInputManifest {
    .init(document: .init(id: UUID(), title: "合成书", sourceFormat: .text,
      sourceFileName: "synthetic.txt", contentHash: "hash", chapters: ids.enumerated().map {
        .init(id: $0.element, ordinal: $0.offset, title: "第\($0.offset + 1)章", content: "合成正文")
      }))
  }

  @Test func ordersNodesAndUsesSourceChapterIdentity() throws {
    let plot = try #require(FactoryPlotlineBuilder.makePlotline(
      analysis: analysis([summary("b", ordinal: 1), summary("a", ordinal: 0)]), manifest: manifest(["a", "b"])))
    #expect(plot.nodes.map(\.id) == ["plot-0001", "plot-0002"])
    #expect(plot.nodes.map(\.title) == ["第1章", "第2章"])
    #expect(plot.coverage?.gaps.isEmpty == true)
    #expect(plot.coverage?.completeChapterCount == 2)
  }

  @Test func mergesOnlyCompleteSegmentsAndSupportsLegacyZeroBasedAssets() throws {
    for start in [0, 1] {
      let plot = try #require(FactoryPlotlineBuilder.makePlotline(analysis: analysis([
        summary("a", ordinal: 0, segment: start + 1, count: 2, text: "下半章。"),
        summary("a", ordinal: 0, segment: start, count: 2, text: "上半章。"),
      ]), manifest: manifest(["a"])))
      #expect(plot.nodes.first?.summary == "上半章。；下半章。")
    }
  }

  @Test func partialCoverageRetainsNodesAndFillingGapsNeverRenumbersThem() throws {
    let source = manifest(["a", "b", "c", "d"])
    let before = try #require(FactoryPlotlineBuilder.makePlotline(analysis: analysis([
      summary("b", ordinal: 1), summary("d", ordinal: 3),
    ]), manifest: source))
    #expect(before.nodes.map(\.id) == ["plot-0002", "plot-0004"])
    #expect(before.coverage?.gaps.map(\.chapterID) == ["a", "c"])
    #expect(before.coverage?.completeChapterCount == 2)
    let after = try #require(FactoryPlotlineBuilder.makePlotline(analysis: analysis([
      summary("a", ordinal: 0), summary("b", ordinal: 1),
      summary("c", ordinal: 2), summary("d", ordinal: 3),
    ]), manifest: source))
    for node in before.nodes { #expect(after.node(id: node.id) == node) }
    #expect(before.firstNode?.order == 2)
    #expect(before.window(around: 4).previous?.order == 2)
    #expect(before.window(around: 2, trailing: 0).upcoming.isEmpty)
    #expect(before.window(around: 2, trailing: -1).upcoming.isEmpty)
  }

  @Test func partialDuplicateConflictingAndEmptySegmentsAreGaps() {
    let invalid: [[FactoryChapterSummary]] = [
      [summary("a", ordinal: 0, count: 2)],
      [summary("a", ordinal: 0, count: 2), summary("a", ordinal: 0, count: 2)],
      [summary("a", ordinal: 0, count: 2), summary("a", ordinal: 0, segment: 2, count: 3)],
      [summary("a", ordinal: 7)],
      [summary("a", ordinal: 0, text: "  ")],
      [summary("a", ordinal: 0, count: 0)],
    ]
    for units in invalid {
      let result = FactoryPlotlineBuilder.assess(analysis: analysis(units), manifest: manifest(["a"]))
      #expect(result.nodes.isEmpty)
      #expect(result.coverage.completeChapterCount == 0)
      #expect(result.coverage.gaps.first?.reason == .incomplete)
    }
    let a = analysis([summary("unknown", ordinal: 0), summary("b", ordinal: 1)], covered: ["a"])
    let result = FactoryPlotlineBuilder.assess(analysis: a, manifest: manifest(["a", "b"]))
    #expect(result.nodes.isEmpty)
    #expect(result.coverage.gaps.count == 2)
  }

  @Test func frontMatterDoesNotHideGapsOrMixedNarrativeChapters() throws {
    let source = manifest(["info", "a", "b", "missing"])
    let result = FactoryPlotlineBuilder.assess(analysis: analysis([
      summary("info", ordinal: 0, text: "书籍信息页，无实际情节。"),
      summary("a", ordinal: 1, count: 2, text: "出版信息，无实际情节。"),
      summary("a", ordinal: 1, segment: 2, count: 2),
      summary("b", ordinal: 2),
    ]), manifest: source)
    #expect(result.nodes.map(\.order) == [2, 3])
    #expect(result.coverage.completeChapterCount == 3)
    #expect(result.coverage.gaps.map(\.chapterID) == ["missing"])
    #expect(FactoryPlotlineBuilder.makePlotline(analysis: analysis([
      summary("info", ordinal: 0, text: "版权信息，无情节。")
    ]), manifest: manifest(["info"])) == nil)
  }

  @Test func emptySourceChaptersAreExcludedButMissingSummariesEnableSupplement() {
    let document = NovelDocument(id: UUID(), title: "合成书", sourceFormat: .text,
      sourceFileName: "synthetic.txt", contentHash: "hash", chapters: [
        .init(id: "blank", ordinal: 0, title: "空白", content: " \n "),
        .init(id: "a", ordinal: 1, title: "正文", content: "合成正文"),
      ])
    let coverage = FactoryCoverageSummary(manifest: .init(document: document),
      analysis: analysis([], covered: ["blank", "a"]))
    #expect(coverage.percentage == 100)
    #expect(coverage.plotlineCoverage.sourceChapterCount == 1)
    #expect(coverage.plotlineCoverage.completeChapterCount == 0)
    #expect(coverage.needsSupplement)
    #expect(coverage.plotlineCoverage.gaps.map(\.chapterID) == ["a"])
  }

  @Test func legacyPlotlineDecodesWithoutClaimingCompleteCoverage() throws {
    let bytes = Data(#"{"nodes":[],"source":"manual","generated_at":"2026-09-07T00:00:00Z"}"#.utf8)
    let plot = try StoryworldCoding.makeDecoder().decode(StoryPlotline.self, from: bytes)
    #expect(plot.coverage == nil)
    #expect(plot.firstNode == nil)
  }
}
