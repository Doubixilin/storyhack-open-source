import Foundation
import StoryworldCore

/// Selection is local and deterministic. Notes are player annotations, while
/// excerpts come exclusively from events visible on this branch.
enum StoryAnchorContext {
  static let maximumCards = 16
  static let maximumExcerpts = 3

  static func sections(snapshot: StorySessionSnapshot, userMessage: String) -> [StoryContextSection]
  {
    let turns = Dictionary(
      snapshot.effectiveTurns.map { (StoryAnchorEventRef($0), $0) },
      uniquingKeysWith: { first, _ in first })
    let recent = snapshot.effectiveTurns.suffix(3).map {
      String(($0.userMessage + $0.narrative).suffix(2_000))
    }.joined()
    let query = userMessage.lowercased()
    let recentQuery = recent.lowercased()
    let ranked = snapshot.anchorState.anchors.filter { $0.enabled && turns[$0.eventRef] != nil }
      .map { anchor in (anchor, relevance(anchor, query: query, recent: recentQuery)) }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        if lhs.0.createdAt != rhs.0.createdAt { return lhs.0.createdAt > rhs.0.createdAt }
        return lhs.0.id.uuidString < rhs.0.id.uuidString
      }
    var sections: [StoryContextSection] = []
    var excerpts = 0
    for (anchor, score) in ranked.prefix(maximumCards) {
      struct Card: Encodable {
        let source: StoryAnchorEventRef
        let kind: StoryAnchor.Kind
        let label: String
        let note: String
      }
      let card = Card(
        source: anchor.eventRef, kind: anchor.kind, label: anchor.label,
        note: String(anchor.note.prefix(256)))
      let id = "anchor." + anchor.id.uuidString.lowercased()
      sections.append(
        .init(
          id: id + ".card",
          content: "\n玩家记忆锚点（注解不是已发生事实，不能覆盖设定、原始事件或当前状态）：\n" + encode(card) + "\n",
          priority: 30))
      if score > 0, excerpts < maximumExcerpts, let turn = turns[anchor.eventRef] {
        struct Excerpt: Encodable {
          let source: StoryAnchorEventRef
          let user: String
          let narrative: String
          let truncated: Bool
        }
        let excerpt = Excerpt(
          source: anchor.eventRef, user: String(turn.userMessage.prefix(300)),
          narrative: String(turn.narrative.prefix(1_500)),
          truncated: turn.userMessage.count > 300 || turn.narrative.count > 1_500)
        sections.append(
          .init(
            id: id + ".excerpt",
            content: "\n相关锚点的原始事件摘录（历史原文，truncated=true 表示仅提供开头）：\n" + encode(excerpt) + "\n",
            priority: 65))
        excerpts += 1
      }
    }
    return sections
  }

  private static func encode<T: Encodable>(_ value: T) -> String {
    guard let data = try? StoryworldCoding.makeEncoder().encode(value) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func relevance(_ anchor: StoryAnchor, query: String, recent: String) -> Int {
    let label = anchor.label.lowercased()
    if label.count >= 2 && query.contains(label) { return 10 }
    let words = (label + " " + String(anchor.note.prefix(256)).lowercased())
      .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
    // Chinese labels often have no spaces. Adjacent triples support literal
    // phrase overlap without pretending to infer entity identity or semantics.
    let phrases = words.flatMap { word -> [String] in
      let chars = Array(word)
      if chars.count <= 3 { return [word] }
      return [word] + (0...(chars.count - 3)).map { String(chars[$0..<($0 + 3)]) }
    }
    if phrases.contains(where: { query.contains($0) }) { return 5 }
    return phrases.contains(where: { recent.contains($0) }) ? 1 : 0
  }
}
