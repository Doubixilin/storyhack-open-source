import Foundation
import LLMProviderKit
import StoryworldCore

/// Read-only projection of this canon's summaries, scoped to recorded past nodes
/// in the effective branch. Skipped chapters and sibling history never qualify.
struct StoryChapterSearch: Sendable {
  static let definition = LLMToolDefinition(name: "search_chapter_cards",
    description: "只读检索本分支有节点记录的过往原著章节摘要。query 为空格分隔的关键词，全部命中才返回该章；匹配标题或摘要。不是原文，也不是游玩事实；不能查未来、跳过章节或修改状态。",
    parameters: Data(#"{"type":"object","properties":{"query":{"type":"string","maxLength":100},"chapter_ids":{"type":"array","items":{"type":"string","maxLength":64},"maxItems":5},"limit":{"type":"integer","minimum":1,"maximum":5}},"additionalProperties":false}"#.utf8))
  static let instruction = """

    如需回顾原著旧章，可使用 search_chapter_cards；工具只提供有记录的过往节点。
    空结果不代表原书不存在该章节。摘要是静态参考，不能覆盖实际游玩历史、玩家校准或角色知情范围。
    最多调用两轮、合计四次；取不到时沿已有信息继续，不编造检索结果。最终回复仍须遵守 STORY 等标签协议。
    """
  static let reservedTokens = 8_192
  let cards: [StoryPlotNode]
  var isEmpty: Bool { cards.isEmpty }

  init(snapshot: StorySessionSnapshot, plotline: StoryPlotline?) {
    guard let plotline,
      Set(plotline.nodes.map(\.id)).count == plotline.nodes.count,
      Set(plotline.nodes.map(\.order)).count == plotline.nodes.count else { cards = []; return }
    let visited = Set(snapshot.effectiveTurns.compactMap { turn -> Int? in
      guard case .object(let plot) = turn.statePatch["plot"],
        case .number(let number) = plot["node"], let order = Int(exactly: number), order >= 1 else { return nil }
      return order
    })
    let current = StoryTurnEngine.currentPlotOrder(state: snapshot.state.values, plotline: plotline)
    cards = plotline.nodes.filter {
      $0.order < current && visited.contains($0.order)
        && !$0.id.isEmpty && $0.id.utf8.count <= 64
    }.sorted { $0.order < $1.order }
  }

  struct Result: Sendable { let text: String; let cardIDs: [String] }
  private struct Arguments: Decodable {
    var query: String?
    var chapterIDs: [String]?
    var limit: Int?
    enum CodingKeys: String, CodingKey { case query, limit; case chapterIDs = "chapter_ids" }
  }
  private struct Payload: Encodable {
    struct Card: Encodable {
      let id: String
      let chapterOrdinal: Int
      let title: String
      let summary: String
    }
    let source = "原著章节摘要；不等于逐字原文、实际游玩事实或角色已知信息。"
    let cards: [Card]
    let truncated: Bool
  }
  func execute(_ call: LLMToolCall) throws -> Result {
    guard call.name == Self.definition.name, call.isBounded,
      call.arguments.utf8.count <= 512 else { throw LLMToolError.invalidCall }
    let data = Data(call.arguments.utf8)
    guard let keys = try? JSONDecoder().decode([String: JSONValue].self, from: data),
      Set(keys.keys).isSubset(of: ["query", "chapter_ids", "limit"]),
      let args = try? JSONDecoder().decode(Arguments.self, from: data),
      (args.query?.count ?? 0) <= 100, (args.chapterIDs?.count ?? 0) <= 5,
      (args.chapterIDs ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
      (1...5).contains(args.limit ?? 3) else {
      return Result(text: #"{"error":"invalid_query","cards":[]}"#, cardIDs: [])
    }
    let query = (args.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // 模型常按检索习惯发送空格分隔的多个关键词；逐词全部命中才算匹配，
    // 整串连续子串会让包含完整标题加多余词的查询错误地返回空结果。
    let keywords = query.split { $0.isWhitespace }.map(String.init)
    // 模型常以空数组表示“不限定章节”；空数组视同未提供过滤，否则必然零命中。
    let idFilter = args.chapterIDs.flatMap { $0.isEmpty ? nil : Set($0) }
    let matches = cards.filter { node in
      (idFilter == nil || idFilter!.contains(node.id))
        && (keywords.isEmpty
          || keywords.allSatisfy { keyword in
            (node.title + "\n" + node.summary).localizedCaseInsensitiveContains(keyword)
          })
    }.sorted { $0.order > $1.order }
    var selected: [Payload.Card] = []
    func encode(_ values: [Payload.Card], truncated: Bool) throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(Payload(cards: values, truncated: truncated)), as: UTF8.self)
    }
    for node in matches {
      if selected.count >= (args.limit ?? 3) { break }
      let card = Payload.Card(id: node.id, chapterOrdinal: node.chapterOrdinal, title: node.title, summary: node.summary)
      let candidate = try encode(selected + [card], truncated: true)
      if candidate.utf8.count <= 2_048, StoryContextCompiler.estimatedTokens(candidate) <= 768 {
        selected.append(card)
      }
    }
    return Result(text: try encode(selected, truncated: selected.count < matches.count),
      cardIDs: selected.map(\.id))
  }
}
