import Foundation
import LLMProviderKit
import StorySessionCore
import Testing

@Suite("Context budget and contiguous replay")
struct StoryContextCompilerTests {
  @Test(arguments: [8_192, 16_384, 32_768, 131_072])
  func budgetsKeepProtocolAndWholeItems(window: Int) throws {
    let lore = (0..<80).map { index in
      StoryContextSection(
        id: "lore.\(index)",
        content: "START\(index)" + String(repeating: "设定", count: 500) + "END\(index)")
    }
    let sections =
      [StoryContextSection(id: "required", content: "PROTOCOL", flexibility: .mandatory)] + lore
    let history = (0..<20).map {
      StoryContextTurn(
        id: "t\($0)", user: "行动\($0)", narrative: String(repeating: "原文", count: 200))
    }
    let result = try StoryContextCompiler.compile(
      sections: sections, history: history, userMessage: "当前行动", contextWindow: window,
      maximumOutputTokens: 2_048)
    #expect(result.manifest.estimatedInputTokens <= result.manifest.inputBudget)
    #expect(result.messages.first?.content.hasPrefix("PROTOCOL") == true)
    #expect(result.messages.last?.content == "当前行动")
    for section in lore {
      let included = result.manifest.entries.first { $0.id == section.id }?.included == true
      #expect(result.messages[0].content.contains(section.content) == included)
    }
    let repeated = try StoryContextCompiler.compile(
      sections: sections, history: history, userMessage: "当前行动", contextWindow: window,
      maximumOutputTokens: 2_048)
    #expect(result.manifest == repeated.manifest)
    #expect(result.messages.map(\.content) == repeated.messages.map(\.content))
    let encoded = String(decoding: try JSONEncoder().encode(result.manifest), as: UTF8.self)
    #expect(!encoded.contains("设定"))
    #expect(!encoded.contains("原文"))
  }

  @Test func oversizedLatestTurnDoesNotReplayOlderTurnsOutOfContext() throws {
    let result = try StoryContextCompiler.compile(
      sections: [.init(id: "p", content: "rules", flexibility: .mandatory)],
      history: [
        .init(id: "old", user: "old", narrative: "short"),
        .init(id: "new", user: "new", narrative: String(repeating: "长", count: 5_000)),
      ], userMessage: "now", contextWindow: 2_048, maximumOutputTokens: 256)
    #expect(result.manifest.replayedTurns == 0)
    #expect(result.messages.count == 2)
  }

  @Test func mandatoryAndUserInputAreNeverSilentlyCut() throws {
    #expect(throws: StoryContextError.mandatoryExceedsBudget) {
      try StoryContextCompiler.compile(
        sections: [
          .init(
            id: "required", content: String(repeating: "规", count: 2_000), flexibility: .mandatory)
        ],
        userMessage: "继续", contextWindow: 2_048, maximumOutputTokens: 256)
    }
    #expect(throws: StoryContextError.mandatoryExceedsBudget) {
      try StoryContextCompiler.compile(
        sections: [], userMessage: String(repeating: "行", count: 2_000),
        contextWindow: 2_048, maximumOutputTokens: 256)
    }
    #expect(throws: StoryContextError.invalidBudget) {
      try StoryContextCompiler.compile(
        sections: [], userMessage: "继续", contextWindow: 2_048, maximumOutputTokens: 2_048)
    }
  }

  @Test func compressionStopsAtSentenceBoundaryAndRespectsFloor() throws {
    let sentence = String(repeating: "甲", count: 300) + "。"
    let result = try StoryContextCompiler.compile(
      sections: [
        .init(
          id: "summary", content: sentence + String(repeating: "乙", count: 800),
          flexibility: .compressible(minimumCharacters: 100))
      ],
      userMessage: "继续", contextWindow: 2_048, maximumOutputTokens: 256)
    #expect(result.messages[0].content == sentence)
    #expect(result.manifest.entries[0].reason == "compressed")
    let dropped = try StoryContextCompiler.compile(
      sections: [
        .init(
          id: "summary", content: sentence + String(repeating: "乙", count: 800),
          flexibility: .compressible(minimumCharacters: 500))
      ],
      userMessage: "继续", contextWindow: 2_048, maximumOutputTokens: 256)
    #expect(dropped.messages[0].content.isEmpty)
  }

  @Test func priorityAffectsSelectionWithoutReorderingPrompt() throws {
    let result = try StoryContextCompiler.compile(
      sections: [
        .init(id: "filler", content: String(repeating: "填", count: 550), priority: 90),
        .init(id: "contract", content: String(repeating: "约", count: 550), priority: 10),
        .init(id: "protocol", content: "END", flexibility: .mandatory),
      ], userMessage: "继续", contextWindow: 2_048, maximumOutputTokens: 256)
    #expect(!result.manifest.entries[0].included)
    #expect(result.manifest.entries[1].included)
    #expect(result.messages[0].content.hasSuffix("END"))
  }
}
