import Foundation
import Testing

@testable import MediaCore

struct MediaCoreTests {
  @Test
  func singleNarratorPlanPreservesCanonicalTextAndUsesStableCacheKey() {
    let text = String(repeating: "郭靖说道：守住襄阳。\n", count: 140)
    let first = SpeechPlanBuilder.singleNarrator(
      kind: .publishedChapter,
      sourceID: "chapter-1",
      text: text,
      maximumSegmentCharacterCount: 120
    )
    let second = SpeechPlanBuilder.singleNarrator(
      kind: .publishedChapter,
      sourceID: "chapter-1",
      text: text,
      maximumSegmentCharacterCount: 120
    )

    #expect(first.segments.map(\.text).joined() == text)
    #expect(first.segments.count > 1)
    #expect(first.id == second.id)
    #expect(first.source.contentHash == second.source.contentHash)
    #expect(first.segments.first?.utf16Location == 0)
    #expect(first.segments.last.map { $0.utf16Location + $0.utf16Length } == text.utf16.count)
  }

  @Test
  func planAndPlaybackStoresRoundTripAndRejectStaleContent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let planStore = SpeechPlanStore(rootURL: root.appendingPathComponent("plans"))
    let playbackStore = SpeechPlaybackStore(rootURL: root.appendingPathComponent("plans"))
    let plan = SpeechPlanBuilder.singleNarrator(
      kind: .committedTurn,
      sourceID: "turn-1",
      text: "杨过抬头望向终南山。"
    )
    try await planStore.save(plan)
    #expect(try await planStore.load(id: plan.id) == plan)

    let location = SpeechPlaybackLocation(
      sourceID: plan.source.sourceID,
      sourceContentHash: plan.source.contentHash,
      segmentIndex: 0,
      characterOffset: 4
    )
    try await playbackStore.save(location)
    #expect(
      try await playbackStore.load(
        sourceID: plan.source.sourceID,
        contentHash: plan.source.contentHash
      )?.characterOffset == 4
    )
    #expect(
      try await playbackStore.load(sourceID: plan.source.sourceID, contentHash: "changed") == nil
    )
  }
}
