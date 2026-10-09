import Foundation
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore

public enum StoryTimelineExtractorError: Error, Equatable, LocalizedError {
  case emptyDocument
  case noBeatsExtracted
  case invalidChunkResponse(Int)

  public var errorDescription: String? {
    switch self {
    case .emptyDocument:
      "原著没有可分析的章节内容"
    case .noBeatsExtracted:
      "模型没有提取到任何关键节拍"
    case .invalidChunkResponse(let index):
      "第 \(index) 批章节的节拍结果无法解析"
    }
  }
}

/// 端侧节拍线提取：把原著分块喂给当前配置的模型，逐块产出大事件级
/// 节拍，再按剧情顺序合并去重。Mac 与 iOS 共用。
public enum StoryTimelineExtractor {
  /// 单批章节正文字符上限（含章节标题开销）
  public static let maximumChunkCharacterCount = 80_000
  /// 与工坊推导保持同一颗粒度
  public static let maximumBeatCount = FactoryTimelineBuilder.maximumBeatCount
  /// 单批最多产出的节拍数
  public static let maximumBeatsPerChunk = 8

  /// 解析出的原始节拍：顺序信息靠所在批次与章节序推断
  public struct RawBeat: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var keywords: [String]
    public var chapterOrdinal: Int

    public init(title: String, summary: String, keywords: [String], chapterOrdinal: Int) {
      self.title = title
      self.summary = summary
      self.keywords = keywords
      self.chapterOrdinal = chapterOrdinal
    }
  }

  /// 按字符上限把章节切成连续批次
  public static func makeChunks(
    document: NovelDocument,
    maxCharacters: Int = maximumChunkCharacterCount
  ) -> [[NovelChapter]] {
    var chunks: [[NovelChapter]] = []
    var current: [NovelChapter] = []
    var currentCount = 0
    for chapter in document.chapters {
      let cost = chapter.content.utf16.count + chapter.title.utf16.count + 32
      if !current.isEmpty, currentCount + cost > maxCharacters {
        chunks.append(current)
        current = []
        currentCount = 0
      }
      current.append(chapter)
      currentCount += cost
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  public static func makePrompt(
    chapters: [NovelChapter],
    index: Int,
    total: Int,
    bookTitle: String
  ) -> LLMRequest {
    let chapterText = chapters.map { chapter in
      "<chapter title=\"\(chapter.title)\">\n\(chapter.content)\n</chapter>"
    }.joined(separator: "\n\n")
    let system = """
      你是严谨的中文小说剧情分析器，不调用任何工具，只返回符合约定的 JSON 对象。
      """
    let user = """
      你正在为长篇小说《\(bookTitle)》提取「关键剧情节拍」——大事件级别的剧情节点 \
      （如「终南山拜师」「英雄大宴」），不要每章流水账。
      这是全书第 \(index)/\(total) 批章节。只提取本批内发生的关键事件，按剧情先后排列，
      本批最多 \(maximumBeatsPerChunk) 个节拍。只输出一个 JSON 对象，不要输出其他文字：
      {"beats":[{"title":"短标题","summary":"一句话概括","chapter":"该事件开始发生的章节标题（必须来自本批）","keywords":["相关人物或地点别名，最多4个"]}]}

      \(chapterText)
      """
    return LLMRequest(
      requestID: UUID(),
      messages: [
        LLMMessage(role: .system, content: system),
        LLMMessage(role: .user, content: user),
      ]
    )
  }

  /// 容错解析单批返回：截取最外层 JSON 对象，章节标题映射回本批章节序
  public static func parseBeats(from text: String, chapters: [NovelChapter]) throws -> [RawBeat] {
    guard let start = text.firstIndex(of: "{"),
      let end = text.lastIndex(of: "}"),
      start <= end
    else { throw StoryTimelineExtractorError.invalidChunkResponse(0) }
    let data = Data(text[start...end].utf8)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawBeats = object["beats"] as? [[String: Any]]
    else { throw StoryTimelineExtractorError.invalidChunkResponse(0) }

    let ordinals = Dictionary(
      uniqueKeysWithValues: chapters.map { ($0.title, $0.ordinal) }
    )
    let fallbackOrdinal = chapters.first?.ordinal ?? 0
    return rawBeats.compactMap { raw in
      guard let title = (raw["title"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !title.isEmpty
      else { return nil }
      let summary = (raw["summary"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let keywords = (raw["keywords"] as? [String] ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      let chapterTitle = (raw["chapter"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return RawBeat(
        title: title,
        summary: summary,
        keywords: keywords,
        chapterOrdinal: ordinals[chapterTitle] ?? fallbackOrdinal
      )
    }
  }

  /// 按（批次顺序 + 章节序）排列，标题去重，统一编号
  public static func merge(chunks: [[RawBeat]], generatedAt: Date = Date()) throws -> StoryTimeline {
    var seen = Set<String>()
    var ordered: [RawBeat] = []
    for chunk in chunks {
      for beat in chunk.sorted(by: { $0.chapterOrdinal < $1.chapterOrdinal }) {
        let key = beat.title.replacingOccurrences(of: " ", with: "")
        guard seen.insert(key).inserted else { continue }
        ordered.append(beat)
      }
    }
    guard !ordered.isEmpty else { throw StoryTimelineExtractorError.noBeatsExtracted }
    let beats = ordered.prefix(maximumBeatCount).enumerated().map { index, raw in
      StoryBeat(
        id: String(format: "beat-%02d", index + 1),
        title: raw.title,
        summary: raw.summary,
        order: index + 1,
        keywords: raw.keywords
      )
    }
    return StoryTimeline(beats: beats, source: "device_extraction", generatedAt: generatedAt)
  }

  /// 端到端提取：逐批调用模型并汇总进度
  public static func extract(
    document: NovelDocument,
    provider: any LLMProvider,
    onChunk: ((Int, Int) -> Void)? = nil
  ) async throws -> StoryTimeline {
    let chunks = makeChunks(document: document)
    guard !chunks.isEmpty else { throw StoryTimelineExtractorError.emptyDocument }
    var parsed: [[RawBeat]] = []
    for (index, chunk) in chunks.enumerated() {
      onChunk?(index + 1, chunks.count)
      let request = makePrompt(
        chapters: chunk,
        index: index + 1,
        total: chunks.count,
        bookTitle: document.title
      )
      var text = ""
      for try await event in provider.stream(request) {
        try Task.checkCancellation()
        if case .textDelta(let delta) = event { text += delta }
      }
      do {
        parsed.append(try parseBeats(from: text, chapters: chunk))
      } catch {
        throw StoryTimelineExtractorError.invalidChunkResponse(index + 1)
      }
    }
    return try merge(chunks: parsed)
  }
}
