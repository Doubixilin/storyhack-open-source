import Foundation
import LLMProviderKit
import Testing
import WritingAssistantCore
import WritingCore

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequest: LLMRequest?

  func record(_ request: LLMRequest) {
    lock.lock()
    storedRequest = request
    lock.unlock()
  }

  var request: LLMRequest? {
    lock.lock()
    defer { lock.unlock() }
    return storedRequest
  }
}

private struct MockProvider: LLMProvider {
  let profile = ProviderProfile(
    displayName: "测试模型",
    kind: .openAICompatible,
    modelID: "mock-model",
    credentialReference: "mock-reference"
  )
  let events: [LLMStreamEvent]
  let recorder: RequestRecorder

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    recorder.record(request)
    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}

private func makeSnapshot(
  theme: String = "确认主题",
  authorIntent: String = "作者意图",
  style: String = "冷峻现实主义",
  charactersJSON: String = "[{\"name\":\"阿青\"}]",
  world: String = "海上城邦",
  timelineJSON: String = "[{\"year\":1}]"
) -> WritingProjectSnapshot {
  WritingProjectSnapshot(
    manifest: WritingProjectManifest(title: "测试小说"),
    theme: theme,
    authorIntent: authorIntent,
    style: style,
    charactersJSON: charactersJSON,
    world: world,
    timelineJSON: timelineJSON,
    storyStateJSON: "{}",
    foreshadowingJSON: "[]",
    activeOutline: nil,
    proposals: [],
    finalChapters: [],
    publications: []
  )
}

private func collect(
  _ stream: AsyncThrowingStream<String, any Error>
) async throws -> String {
  var result = ""
  for try await delta in stream {
    result += delta
  }
  return result
}

@Test
func themePromptContainsExpectedMaterialsAndRoles() async throws {
  let recorder = RequestRecorder()
  let provider = MockProvider(events: [.textDelta("建议"), .completed], recorder: recorder)
  let advisor = WritingAdvisor(provider: provider)

  _ = try await collect(
    advisor.streamSuggestion(
      kind: .theme,
      snapshot: makeSnapshot(),
      currentDraft: "当前草案"
    )
  )

  let request = try #require(recorder.request)
  #expect(request.messages.count == 2)
  #expect(request.messages[0].role == .system)
  #expect(request.messages[1].role == .user)
  #expect(request.messages[1].content.contains("作者意图"))
  #expect(request.messages[1].content.contains("冷峻现实主义"))
  #expect(request.messages[1].content.contains("当前草案"))
  #expect(request.responseContract.mode == .text)
  #expect(request.modelOptions.temperature == nil)
}

@Test
func outlinePromptContainsThemeAndBibleMaterials() async throws {
  let recorder = RequestRecorder()
  let provider = MockProvider(events: [.textDelta("大纲"), .completed], recorder: recorder)
  let advisor = WritingAdvisor(provider: provider)

  _ = try await collect(
    advisor.streamSuggestion(
      kind: .outline,
      snapshot: makeSnapshot(),
      currentDraft: "现有大纲"
    )
  )

  let request = try #require(recorder.request)
  let prompt = request.messages[1].content
  #expect(prompt.contains("确认主题"))
  #expect(prompt.contains("[{\"name\":\"阿青\"}]"))
  #expect(prompt.contains("海上城邦"))
  #expect(prompt.contains("[{\"year\":1}]"))
  #expect(prompt.contains("现有大纲"))
}

@Test
func textDeltasAreEmittedInOrder() async throws {
  let recorder = RequestRecorder()
  let provider = MockProvider(
    events: [.textDelta("第一段"), .textDelta("第二段"), .textDelta("第三段"), .completed],
    recorder: recorder
  )
  let advisor = WritingAdvisor(provider: provider)

  let text = try await collect(
    advisor.streamSuggestion(kind: .theme, snapshot: makeSnapshot(), currentDraft: "")
  )

  #expect(text == "第一段第二段第三段")
}

@Test
func streamWithoutCompletedThrowsIncompleteStream() async {
  let recorder = RequestRecorder()
  let provider = MockProvider(events: [.textDelta("未完成")], recorder: recorder)
  let advisor = WritingAdvisor(provider: provider)

  do {
    _ = try await collect(
      advisor.streamSuggestion(kind: .theme, snapshot: makeSnapshot(), currentDraft: "")
    )
    Issue.record("缺少 completed 时应抛出 incompleteStream")
  } catch let error as WritingAdvisorError {
    #expect(error == .incompleteStream)
  } catch {
    Issue.record("抛出了非预期错误：\(error)")
  }
}

@Test
func completedEmptyStreamThrowsEmptyResponse() async {
  let recorder = RequestRecorder()
  let provider = MockProvider(events: [.completed], recorder: recorder)
  let advisor = WritingAdvisor(provider: provider)

  do {
    _ = try await collect(
      advisor.streamSuggestion(kind: .theme, snapshot: makeSnapshot(), currentDraft: "")
    )
    Issue.record("空回复应抛出 emptyResponse")
  } catch let error as WritingAdvisorError {
    #expect(error == .emptyResponse)
  } catch {
    Issue.record("抛出了非预期错误：\(error)")
  }
}

@Test
func longMaterialIsTruncatedAndMarked() async throws {
  let recorder = RequestRecorder()
  let provider = MockProvider(events: [.textDelta("建议"), .completed], recorder: recorder)
  let advisor = WritingAdvisor(provider: provider)
  let longIntent = String(repeating: "长", count: 20_001)

  _ = try await collect(
    advisor.streamSuggestion(
      kind: .theme,
      snapshot: makeSnapshot(authorIntent: longIntent),
      currentDraft: ""
    )
  )

  let request = try #require(recorder.request)
  #expect(request.messages[1].content.contains("（已截断）"))
  #expect(!request.messages[1].content.contains(longIntent))
}
