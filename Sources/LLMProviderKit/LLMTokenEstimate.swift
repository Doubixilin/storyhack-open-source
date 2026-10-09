import Foundation

/// Shared conservative local estimate, not a provider tokenizer.
public enum LLMTokenEstimate {
  public struct Accumulator: Sendable {
    private var ascii = 0
    private var other = 0
    public init() {}
    public var tokens: Int { (ascii + 2) / 3 + other * 2 }
    public mutating func append(_ text: some StringProtocol) {
      for scalar in text.unicodeScalars {
        if scalar.isASCII { ascii += 1 } else { other += 1 }
      }
    }
  }

  public static func tokens(_ text: String) -> Int {
    var estimate = Accumulator()
    estimate.append(text)
    return estimate.tokens
  }

  public static func inputTokens(_ request: LLMRequest) -> Int {
    request.messages.reduce(0) { total, message in
      total + 32 + tokens(message.content) + tokens(message.toolCallID ?? "")
        + (message.toolCalls ?? []).reduce(0) { $0 + 32 + tokens($1.id + $1.name + $1.arguments) }
    } + request.tools.reduce(0) {
      $0 + 32 + tokens($1.name + $1.description)
        + tokens(String(data: $1.parameters, encoding: .utf8) ?? "")
    }
  }
}
