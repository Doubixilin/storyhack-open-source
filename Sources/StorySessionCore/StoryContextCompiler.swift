import Foundation
import LLMProviderKit

public enum StoryContextError: Error, Equatable, LocalizedError {
  case invalidBudget
  case mandatoryExceedsBudget

  public var errorDescription: String? {
    switch self {
    case .invalidBudget:
      "模型上下文窗口与输出上限不兼容，请检查模型设置。"
    case .mandatoryExceedsBudget:
      "当前输入、状态与必要规则超过模型上下文预算，请缩短输入或选择更大窗口的模型。"
    }
  }
}

public struct StoryContextSection: Sendable {
  public enum Flexibility: Sendable {
    case mandatory
    case whole
    case compressible(minimumCharacters: Int)
  }

  public let id: String
  public let content: String
  public let priority: Int
  public let flexibility: Flexibility

  public init(
    id: String, content: String, priority: Int = 80, flexibility: Flexibility = .whole
  ) {
    self.id = id
    self.content = content
    self.priority = priority
    self.flexibility = flexibility
  }
}

public struct StoryContextTurn: Sendable {
  public let id: String
  public let user: String
  public let narrative: String

  public init(id: String, user: String, narrative: String) {
    self.id = id
    self.user = user
    self.narrative = narrative
  }
}

/// Only identifiers, counts and selection reasons; never prompt or narrative text.
public struct StoryContextManifest: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public let id: String
    public let included: Bool
    public let estimatedTokens: Int
    public let reason: String
  }
  public let entries: [Entry]
  public let inputBudget: Int
  public let estimatedInputTokens: Int
  public let replayedTurns: Int
}

public struct CompiledStoryContext: Sendable {
  public let messages: [LLMMessage]
  public let manifest: StoryContextManifest
}

/// A deterministic local estimate, not a provider tokenizer. Non-ASCII text is
/// charged conservatively; a separate reserve covers estimation/framing error.
public enum StoryContextCompiler {
  public static let defaultContextWindow = 32_768
  public static let defaultOutputTokens = 4_096
  private static let messageOverhead = 32

  public static func estimatedTokens(_ text: String) -> Int {
    LLMTokenEstimate.tokens(text)
  }

  /// Includes the protocol fields absent from ordinary user/assistant text.
  public static func estimatedInputTokens(_ request: LLMRequest) -> Int {
    LLMTokenEstimate.inputTokens(request)
  }

  public static func compile(
    sections: [StoryContextSection],
    history: [StoryContextTurn] = [],
    userMessage: String,
    contextWindow: Int? = nil,
    maximumOutputTokens: Int = defaultOutputTokens,
    historyWindow: Int = 20,
    reservedInputTokens: Int = 0
  ) throws -> CompiledStoryContext {
    let window = contextWindow ?? defaultContextWindow
    guard (2_048...2_000_000).contains(window), maximumOutputTokens > 0,
      maximumOutputTokens < window, reservedInputTokens >= 0, reservedInputTokens < window
    else { throw StoryContextError.invalidBudget }
    let budget = window - maximumOutputTokens - max(512, window / 20)
    var used = estimatedTokens(userMessage) + messageOverhead * 2 + reservedInputTokens
    var selected: [Int: String] = [:]
    var entries: [Int: StoryContextManifest.Entry] = [:]
    for (index, section) in sections.enumerated() {
      if case .mandatory = section.flexibility {
        let cost = estimatedTokens(section.content)
        used += cost
        selected[index] = section.content
        entries[index] = .init(
          id: section.id, included: true, estimatedTokens: cost, reason: "required")
      }
    }
    guard used <= budget else { throw StoryContextError.mandatoryExceedsBudget }

    let optional = sections.indices.filter { selected[$0] == nil }.sorted {
      sections[$0].priority == sections[$1].priority
        ? $0 < $1 : sections[$0].priority < sections[$1].priority
    }
    func pack(_ index: Int) {
      let section = sections[index]
      let cost = estimatedTokens(section.content)
      var content: String? = cost <= budget - used ? section.content : nil
      if content == nil, case .compressible(let minimum) = section.flexibility {
        content = sentencePrefix(section.content, tokenBudget: budget - used, minimum: minimum)
      }
      if let content {
        let actual = estimatedTokens(content)
        selected[index] = content
        used += actual
        entries[index] = .init(
          id: section.id, included: true, estimatedTokens: actual,
          reason: content == section.content ? "selected" : "compressed")
      } else {
        entries[index] = .init(
          id: section.id, included: false, estimatedTokens: cost, reason: "budget")
      }
    }
    // Explicit contracts/anchors can rank above recent dialogue. Supplemental
    // lore and summaries use priority >= 50 and consume what remains afterwards.
    for index in optional where sections[index].priority < 50 { pack(index) }
    var replay: [StoryContextTurn] = []
    var historyEntries: [StoryContextManifest.Entry] = []
    var contiguous = true
    let cap = min(200, max(0, historyWindow))
    for (offset, turn) in history.reversed().enumerated() {
      let cost = estimatedTokens(turn.user) + estimatedTokens(turn.narrative) + messageOverhead * 2
      let included = offset < cap && contiguous && cost <= budget - used
      if included {
        replay.append(turn)
        used += cost
      } else if offset < cap {
        contiguous = false
      }
      historyEntries.append(
        .init(
          id: turn.id, included: included, estimatedTokens: cost,
          reason: included ? "recent" : (offset >= cap ? "window" : "budget")))
    }
    for index in optional where sections[index].priority >= 50 { pack(index) }
    let system = sections.indices.compactMap { selected[$0] }.joined()
    var messages = [LLMMessage(role: .system, content: system)]
    for turn in replay.reversed() {
      messages.append(.init(role: .user, content: turn.user))
      messages.append(.init(role: .assistant, content: turn.narrative))
    }
    messages.append(.init(role: .user, content: userMessage))
    return CompiledStoryContext(
      messages: messages,
      manifest: .init(
        entries: sections.indices.compactMap { entries[$0] } + historyEntries.reversed()
          + (reservedInputTokens > 0 ? [.init(id: "reserve.tool-exchange", included: true,
            estimatedTokens: reservedInputTokens, reason: "reserved")] : []),
        inputBudget: budget, estimatedInputTokens: used, replayedTurns: replay.count))
  }

  private static func sentencePrefix(_ text: String, tokenBudget: Int, minimum: Int) -> String? {
    var ascii = 0
    var other = 0
    var end: String.Index?
    for index in text.indices {
      let character = text[index]
      for scalar in character.unicodeScalars {
        if scalar.isASCII { ascii += 1 } else { other += 1 }
      }
      guard (ascii + 2) / 3 + other * 2 <= tokenBudget else { break }
      if "。！？；\n.!?;".contains(character) { end = text.index(after: index) }
    }
    guard let end else { return nil }
    let prefix = String(text[..<end])
    return prefix.count >= max(1, minimum) ? prefix : nil
  }
}
