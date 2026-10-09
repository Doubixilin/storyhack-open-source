import Foundation
import LLMProviderKit
import WritingCore

public enum WritingSuggestionKind: String, Sendable {
  case theme
  case outline
}

public enum WritingAdvisorError: Error, Equatable, LocalizedError {
  case incompleteStream
  case emptyResponse

  public var errorDescription: String? {
    switch self {
    case .incompleteStream:
      "模型回复不完整，请重试"
    case .emptyResponse:
      "模型没有返回内容"
    }
  }
}

public struct WritingAdvisor: Sendable {
  public let provider: any LLMProvider

  public init(provider: any LLMProvider) {
    self.provider = provider
  }

  /// 流式建议只返回临时文本，不接触 WritingHarness 或正式写作状态。
  public func streamSuggestion(
    kind: WritingSuggestionKind,
    snapshot: WritingProjectSnapshot,
    currentDraft: String
  ) -> AsyncThrowingStream<String, any Error> {
    let request = makeRequest(
      kind: kind,
      snapshot: snapshot,
      currentDraft: currentDraft
    )
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var fullText = ""
          var receivedCompleted = false
          streamLoop: for try await event in provider.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .toolCall:
              throw LLMToolError.unexpectedCall
            case .textDelta(let delta):
              fullText += delta
              continuation.yield(delta)
            case .completed:
              receivedCompleted = true
              break streamLoop
            }
          }
          try Task.checkCancellation()
          guard receivedCompleted else {
            throw WritingAdvisorError.incompleteStream
          }
          guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WritingAdvisorError.emptyResponse
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  private func makeRequest(
    kind: WritingSuggestionKind,
    snapshot: WritingProjectSnapshot,
    currentDraft: String
  ) -> LLMRequest {
    let system = "你是中文长篇小说的协作写作伙伴，只做建议不替作者决定。"
    let user: String
    switch kind {
    case .theme:
      user = """
        请基于以下材料提供主题讨论建议。

        作者意图：
        \(limited(snapshot.authorIntent))

        风格：
        \(limited(snapshot.style))

        当前主题草案：
        \(limited(currentDraft))

        请输出 2–3 个主题方向，每个包含一句话题旨、核心冲突和潜在雷区；结尾给作者 3 个关键提问。仅输出 Markdown 纯文本。
        """
    case .outline:
      user = """
        请基于以下已确认材料提供大纲建议。

        已确认主题：
        \(limited(snapshot.theme))

        人物 JSON：
        \(limited(snapshot.charactersJSON))

        世界设定：
        \(limited(snapshot.world))

        时间线：
        \(limited(snapshot.timelineJSON))

        当前大纲草案：
        \(limited(currentDraft))

        请输出分层大纲草案（卷→章，每章一句话意图），并标注主要人物弧线节点。仅输出 Markdown 纯文本。
        """
    }
    return LLMRequest(
      requestID: UUID(),
      messages: [
        LLMMessage(role: .system, content: system),
        LLMMessage(role: .user, content: user),
      ]
    )
  }

  private func limited(_ material: String) -> String {
    let maximumCharacterCount = 20_000
    guard material.count > maximumCharacterCount else { return material }
    return String(material.prefix(maximumCharacterCount)) + "（已截断）"
  }
}
