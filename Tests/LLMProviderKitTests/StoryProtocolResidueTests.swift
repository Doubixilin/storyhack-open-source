import Foundation
import Testing
@testable import LLMProviderKit

@Suite("Story protocol residue")
struct StoryProtocolResidueTests {
  private let narrative = "铜钥匙贴着肌肤，沉甸甸的，齿纹分明。"
  private let residue = "</｜｜DSML｜｜parameter>\n</｜｜DSML｜｜invoke>\n</｜｜DSML｜｜tool_calls>"

  @Test func realOrphanToolClosersAreRemovedFromStrictAndRecoveredNarrative() throws {
    let raw = "<STORY>" + narrative + residue
    let recovered = try StoryResponseEnvelopeParser.parseRecovering(raw)
    #expect(recovered.narrative == narrative)
    #expect(recovered.statePatchStatus == .missing)
    #expect(recovered.recoveryWarnings.contains { $0.contains("工具协议") })
    let patch = #"{"note":"保留 <注释> 和 DSML 字样"}"#
    let strict = try StoryResponseEnvelopeParser.parse(raw + "</STORY><STATE_PATCH>" + patch + "</STATE_PATCH>")
    #expect(strict.narrative == narrative)
    #expect(strict.statePatchData == Data(patch.utf8))
    #expect(strict.recoveryWarnings.contains { $0.contains("工具协议") })
  }

  @Test func embeddedToolPayloadIsHiddenAsAWholeAndProtocolOnlyRepliesCannotCommit() throws {
    for marker in ["<｜｜DSML｜｜", "<｜DSML｜", "<||DSML||", "<|DSML|"] {
      let tool = marker + "tool_calls>" + marker + "invoke name=\"read_file\">秘密参数</invoke>"
      #expect(try StoryResponseEnvelopeParser.parseRecovering(narrative + tool).narrative == narrative)
      #expect(StoryResponseEnvelopeParser.visibleNarrative(from: narrative + tool) == narrative)
      #expect(throws: StoryResponseEnvelopeError.missingNarrative) {
        try StoryResponseEnvelopeParser.parseRecovering(tool)
      }
    }
  }

  @Test func everyStreamingSplitWithholdsProtocolFragments() {
    let raw = "<STORY>" + narrative + residue + "</STORY><STATE_PATCH>{}</STATE_PATCH>"
    for end in raw.indices {
      let visible = StoryResponseEnvelopeParser.visibleNarrative(from: String(raw[...end]))
      #expect(narrative.hasPrefix(visible))
    }
    #expect(StoryResponseEnvelopeParser.visibleNarrative(from: raw) == narrative)
  }

  @Test func ordinaryAngleBracketsAndProtocolWordsRemainLiteral() throws {
    let plain = "记录写着 2 < 3，<注释>只是正文</注释>，DSML 也是普通字样。末尾 <ST"
    #expect(try StoryResponseEnvelopeParser.parseRecovering(plain).narrative == plain)
    let complete = "<STORY>" + plain + "</STORY><STATE_PATCH>{}</STATE_PATCH>"
    #expect(try StoryResponseEnvelopeParser.parse(complete).narrative == plain)
    #expect(StoryResponseEnvelopeParser.visibleNarrative(from: complete) == plain)
    #expect(StoryResponseEnvelopeParser.visibleNarrative(from: "2 < 3") == "2 < 3")
  }
}
