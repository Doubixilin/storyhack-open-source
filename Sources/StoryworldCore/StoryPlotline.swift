import Foundation

/// 原著主线节点：以章为粒度的有序剧情节点。
/// 正史模式据此锚定每回合叙事；跳转只能由玩家明确提出。
public struct StoryPlotNode: Codable, Equatable, Sendable, Identifiable {
  /// 稳定标识，<PLOT> 导演协议使用，格式 plot-0001
  public let id: String
  /// 节点标题（通常为章节题）
  public var title: String
  /// 本章主线摘要（一句话）
  public var summary: String
  /// 在原著主线中的顺序，从 1 开始
  public var order: Int
  /// 对应原文章节序号，便于回溯与调试
  public var chapterOrdinal: Int

  public init(
    id: String,
    title: String,
    summary: String,
    order: Int,
    chapterOrdinal: Int
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.order = order
    self.chapterOrdinal = chapterOrdinal
  }
}

public struct StoryPlotlineGap: Codable, Equatable, Sendable {
  public enum Reason: String, Codable, Sendable { case missing, incomplete }
  public let chapterID: String
  public let chapterOrdinal: Int
  public let chapterTitle: String
  public let reason: Reason

  public init(chapterID: String, chapterOrdinal: Int, chapterTitle: String, reason: Reason) {
    self.chapterID = chapterID
    self.chapterOrdinal = chapterOrdinal
    self.chapterTitle = chapterTitle
    self.reason = reason
  }
}

public struct StoryPlotlineCoverage: Codable, Equatable, Sendable {
  public let sourceChapterCount: Int
  public let completeChapterCount: Int
  public let gaps: [StoryPlotlineGap]

  public init(sourceChapterCount: Int, completeChapterCount: Int, gaps: [StoryPlotlineGap]) {
    self.sourceChapterCount = sourceChapterCount
    self.completeChapterCount = completeChapterCount
    self.gaps = gaps
  }

  public var notice: String? {
    guard !gaps.isEmpty else { return nil }
    return "主线摘要完整 \(completeChapterCount)/\(sourceChapterCount) 章，另有 \(gaps.count) 章缺失或分段不完整。已有节点仍可使用；缺口不代表事件已经发生，可回工坊补全。"
  }
}

/// 原著主线：工坊逐章摘要按章节序拼接而成的已知剧情顺序，
/// 是 .storyworld 包内的可选产物（plotline.json）。
/// 没有它时正史模式退化为自由叙事（旧行为）。
public struct StoryPlotline: Codable, Equatable, Sendable {
  public var nodes: [StoryPlotNode]
  /// 产出方式：factory（工坊批次分析附带）/ manual
  public var source: String
  public var generatedAt: Date
  /// nil means legacy/unknown coverage, not a claim of completeness.
  public var coverage: StoryPlotlineCoverage?

  public init(
    nodes: [StoryPlotNode],
    source: String,
    generatedAt: Date = Date(),
    coverage: StoryPlotlineCoverage? = nil
  ) {
    self.nodes = nodes.sorted { $0.order < $1.order }
    self.source = source
    self.generatedAt = generatedAt
    self.coverage = coverage
  }

  enum CodingKeys: String, CodingKey {
    case nodes
    case source
    case generatedAt = "generated_at"
    case coverage
  }

  public func node(id: String) -> StoryPlotNode? {
    nodes.first { $0.id == id }
  }

  public func node(order: Int) -> StoryPlotNode? {
    nodes.first { $0.order == order }
  }

  public var firstNode: StoryPlotNode? { nodes.min { $0.order < $1.order } }

  /// 引擎注入用的滑窗：当前节点 + 前一节点（回顾）+ 后两节点（仅标题）。
  public func window(around order: Int, trailing: Int = 2) -> (
    current: StoryPlotNode?, previous: StoryPlotNode?, upcoming: [StoryPlotNode]
  ) {
    let current = node(order: order)
    let previous = nodes.filter { $0.order < order }.max { $0.order < $1.order }
    let upcoming = Array(nodes.filter { $0.order > order }.sorted { $0.order < $1.order }
      .prefix(max(0, trailing)))
    return (current, previous, upcoming)
  }
}
