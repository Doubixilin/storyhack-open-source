import Foundation
import LLMProviderKit

struct StoryToolRunResult: Sendable {
  let rawResponse: String
  let usedFallback: Bool
  let calls: Int
  let cardIDs: [String]
}

/// No filesystem, network, state or arbitrary tool dispatch is available here.
enum StoryToolRunner {
  static func generate(provider: any LLMProvider, request: LLMRequest,
    fallback: LLMRequest, search: StoryChapterSearch?, inputBudget: Int,
    onNarrative: @Sendable (String) -> Void
  ) async throws -> StoryToolRunResult {
    var next = request
    var rounds = 0
    var count = 0
    var ids = Set<String>()
    var callIDs = Set<String>()
    // Two tool rounds followed by one forced final response; a definitive
    // protocol rejection may instead consume one plain fallback request.
    for _ in 0..<3 {
      try Task.checkCancellation()
      guard StoryContextCompiler.estimatedInputTokens(next) <= inputBudget else {
        throw StoryContextError.mandatoryExceedsBudget
      }
      var raw = ""
      var calls: [LLMToolCall] = []
      var completed = false
      do {
        for try await event in provider.stream(next) {
          try Task.checkCancellation()
          switch event {
          case .textDelta(let part):
            raw += part
            guard raw.utf8.count <= StoryResponseEnvelopeParser.maximumResponseByteCount else {
              throw StoryResponseEnvelopeError.responseTooLarge
            }
            // Tool-enabled responses are buffered until their finish marker:
            // intermediate assistant prose must never appear as a story turn.
            if next.tools.isEmpty || next.toolChoice == LLMToolChoice.none {
              onNarrative(StoryResponseEnvelopeParser.visibleNarrative(from: raw))
            }
          case .toolCall(let call):
            guard search != nil, !next.tools.isEmpty, next.toolChoice != LLMToolChoice.none,
              call.name == StoryChapterSearch.definition.name, call.isBounded,
              call.arguments.utf8.count <= 512, calls.count + count < 4,
              callIDs.insert(call.id).inserted else { throw LLMToolError.invalidCall }
            calls.append(call)
          case .completed: completed = true
          }
        }
      } catch {
        if !next.tools.isEmpty, LLMToolCapabilityProbe.isDefinitiveRejection(error) {
          // Never retry authentication, rate limits, cancellations or ambiguous errors.
          // Use the original plain context, with no tool output or preamble.
          let result = try await generate(provider: provider, request: fallback, fallback: fallback,
            search: nil, inputBudget: inputBudget, onNarrative: onNarrative)
          return .init(rawResponse: result.rawResponse, usedFallback: true, calls: count, cardIDs: ids.sorted())
        }
        throw error
      }
      guard completed else { throw OpenAICompatibleError.incompleteStream }
      if calls.isEmpty {
        onNarrative(StoryResponseEnvelopeParser.visibleNarrative(from: raw))
        return .init(rawResponse: raw, usedFallback: false, calls: count, cardIDs: ids.sorted())
      }
      guard let search, rounds < 2 else { throw LLMToolError.invalidCall }
      var messages = next.messages
      messages.append(.init(role: .assistant, content: "", toolCalls: calls))
      for call in calls {
        let result = try search.execute(call)
        ids.formUnion(result.cardIDs)
        messages.append(.init(role: .tool, content: result.text, toolCallID: call.id))
      }
      rounds += 1
      count += calls.count
      next = LLMRequest(requestID: UUID(), messages: messages, modelOptions: request.modelOptions,
        tools: request.tools, toolChoice: rounds >= 2 || count >= 4 ? LLMToolChoice.none : .auto)
    }
    throw LLMToolError.invalidCall
  }
}
