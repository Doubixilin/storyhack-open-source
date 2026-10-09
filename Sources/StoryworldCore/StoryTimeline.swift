import Foundation

/// 一个原著节拍：大事件/关键事项级别的剧情节点（一本书 20~50 个）。
public struct StoryBeat: Codable, Equatable, Sendable, Identifiable {
  /// 稳定标识，导演协议与关键词兜底匹配都用它
  public let id: String
  public var title: String
  public var summary: String
  /// 在原著主线中的顺序，从 1 开始
  public var order: Int
  /// 兜底匹配关键词（人物、地名、事件别名）
  public var keywords: [String]

  public init(
    id: String,
    title: String,
    summary: String,
    order: Int,
    keywords: [String] = []
  ) {
    self.id = id
    self.title = title
    self.summary = summary
    self.order = order
    self.keywords = keywords
  }
}

/// 原著节拍线：解析原著时产出的大事件序列，是 .storyworld 包内的可选产物
/// （timeline.json）。没有它时分支图退化为纯游玩历史图。
public struct StoryTimeline: Codable, Equatable, Sendable {
  public var beats: [StoryBeat]
  /// 产出方式：factory（Mac 工坊）/ device_extraction（端侧提取）/ manual
  public var source: String
  public var generatedAt: Date

  public init(
    beats: [StoryBeat],
    source: String,
    generatedAt: Date = Date()
  ) {
    self.beats = beats.sorted { $0.order < $1.order }
    self.source = source
    self.generatedAt = generatedAt
  }

  enum CodingKeys: String, CodingKey {
    case beats
    case source
    case generatedAt = "generated_at"
  }

  public func beat(id: String) -> StoryBeat? {
    beats.first { $0.id == id }
  }

  /// 关键词兜底匹配：导演协议没有给出节拍 ID 时，用标题与关键词
  /// 在回合文本里找最靠后的一个命中节拍（顺序最大者胜）。
  public func matchedBeatID(for text: String) -> String? {
    beats
      .filter { beat in
        beat.keywords.contains { !$0.isEmpty && text.contains($0) }
          || (!beat.title.isEmpty && text.contains(beat.title))
      }
      .max { $0.order < $1.order }?
      .id
  }
}
