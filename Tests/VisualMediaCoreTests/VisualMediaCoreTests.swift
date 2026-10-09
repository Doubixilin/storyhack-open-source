import Foundation
import Testing

@testable import VisualMediaCore

struct VisualMediaCoreTests {
  @Test
  func candidateApprovalPreservesHashAndHonorsSpoilerBoundary() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storyworldID = UUID()
    let store = VisualAssetStore(storyworldID: storyworldID, rootURL: root)
    let bible = VisualBible(
      storyworldID: storyworldID,
      styleGuide: "水墨武侠，低饱和。",
      characters: [
        VisualCharacterProfile(
          id: "hero",
          name: "少年",
          immutableAppearance: "黑发，左眉有浅痕。"
        )
      ]
    )
    try await store.saveBible(bible)
    #expect(try await store.loadBible().styleGuide == bible.styleGuide)

    let image = root.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString + ".png"
    )
    defer { try? FileManager.default.removeItem(at: image) }
    try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: image)
    let cue = VisualCue(
      source: VisualSource(
        kind: .storyworld,
        sourceID: storyworldID.uuidString,
        storyworldID: storyworldID
      ),
      visibleFacts: ["少年已经抵达终南山"],
      prompt: "少年站在终南山脚"
    )
    let candidate = try await store.registerLocalCandidate(
      from: image,
      subjectIDs: ["hero"],
      cue: cue,
      spoilerBoundary: .afterChapter(5)
    )
    #expect(candidate.status == .candidate)
    #expect(try await store.visibleApprovedAssets(chapterOrdinal: 10).isEmpty)

    let approved = try await store.approve(assetID: candidate.id)
    #expect(approved.status == .approved)
    #expect(approved.relativePath.hasPrefix("approved/"))
    #expect(try await store.visibleApprovedAssets(chapterOrdinal: 4).isEmpty)
    #expect(try await store.visibleApprovedAssets(chapterOrdinal: 5).map(\.id) == [candidate.id])
    #expect(try await store.loadIndex(validatingFiles: true).assets.first?.fileSHA256 == approved.fileSHA256)
  }

  @Test
  func rejectedCandidateNeverBecomesVisible() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let store = VisualAssetStore(storyworldID: id, rootURL: root)
    let image = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".jpg")
    defer { try? FileManager.default.removeItem(at: image) }
    try Data("local-image-fixture".utf8).write(to: image)
    let candidate = try await store.registerLocalCandidate(
      from: image,
      subjectIDs: [],
      cue: VisualCue(
        source: VisualSource(kind: .cover, sourceID: id.uuidString, storyworldID: id),
        visibleFacts: [],
        prompt: "封面候选"
      )
    )
    _ = try await store.reject(assetID: candidate.id)
    #expect(try await store.visibleApprovedAssets().isEmpty)
    #expect(try await store.loadIndex().assets.first?.status == .rejected)
  }
}
