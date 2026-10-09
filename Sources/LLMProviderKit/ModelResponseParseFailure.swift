import Foundation

/// 模型回复连可恢复叙事都没有时的用户可诊断错误。
/// 仅保留开头摘要；完整原文由调用层写入 OSLog，不随错误向 UI 传播。
public struct ModelResponseParseFailure: Error, Equatable, LocalizedError, Sendable {
  public let responseSummary: String

  public init(rawResponse: String) {
    let compact = rawResponse.replacingOccurrences(
      of: #"[ \t]*[\r\n]+[ \t]*"#,
      with: " ",
      options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    responseSummary = compact.isEmpty ? "（空回复）" : String(compact.prefix(120))
  }

  public var errorDescription: String? {
    "模型回复没有可恢复的叙事；摘要：\(responseSummary)"
  }
}
