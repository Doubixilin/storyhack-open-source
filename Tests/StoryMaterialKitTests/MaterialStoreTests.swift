import Foundation
import XCTest

@testable import StoryMaterialKit

final class MaterialStoreTests: XCTestCase {
  func testManifestAndTypedLookupsLoadExpectedShards() async throws {
    let store = MaterialStore(resourceRoot: sourceResourceRoot)
    let manifest = await store.manifest()
    XCTAssertEqual(manifest?.schemaVersion, 1)
    XCTAssertEqual(manifest?.packageCounts["choices"], 3_600)

    let choices = await store.choices(genre: .xianxia, scene: .liangnan)
    XCTAssertEqual(choices.count, 30)
    XCTAssertTrue(choices.allSatisfy { $0.genre == .xianxia && $0.scene == .liangnan })

    let endings = await store.endingVerdicts(
      genre: .gufeng,
      archetype: .beiju,
      forms: [.panci]
    )
    XCTAssertFalse(endings.isEmpty)
    XCTAssertTrue(endings.allSatisfy { $0.form == .panci })

    let prose = await store.proseSample(genre: .kehuan, stage: .opening)
    let roles = await store.rolePitches(genre: .wuxia, kind: .original)
    let stats = await store.statTemplates(dimension: .regrets, tone: .epic)
    XCTAssertNotNil(prose)
    XCTAssertFalse(roles.isEmpty)
    XCTAssertFalse(stats.isEmpty)
  }

  func testChoiceSceneIndexAndUnknownKeysFailOpen() async {
    let store = MaterialStore(resourceRoot: sourceResourceRoot)
    let indexed = await store.choices(genre: "dushi", scene: "tanpan")
    XCTAssertEqual(indexed.count, 30)
    XCTAssertTrue(indexed.allSatisfy { $0.scene == .tanpan })
    let unknownGenre = await store.choices(genre: "unknown", scene: "tanpan")
    let unknownScene = await store.choices(genre: "dushi", scene: "unknown")
    let unknownProse = await store.proseSample(genre: "unknown", stage: "opening")
    XCTAssertTrue(unknownGenre.isEmpty)
    XCTAssertTrue(unknownScene.isEmpty)
    XCTAssertNil(unknownProse)
  }

  func testSamplingIsDeterministicHonorsExclusionAndCharacterBudget() async throws {
    let store = MaterialStore(resourceRoot: sourceResourceRoot)
    let choices = await store.choices(genre: .xianxia, scene: .liangnan)
    let first = await store.sampled(
      choices,
      purpose: "choice-specificity",
      seed: "world/session/42",
      maxChars: 180
    )
    let second = await store.sampled(
      choices,
      purpose: "choice-specificity",
      seed: "world/session/42",
      maxChars: 180
    )
    XCTAssertEqual(first.map(\.id), second.map(\.id))
    XCTAssertLessThanOrEqual(first.map(\.text).joined(separator: "\n").count, 180)

    let excluded = Set(first.map(\.id))
    let afterLRU = await store.sampled(
      choices,
      purpose: "choice-specificity",
      seed: "world/session/42",
      excluding: excluded,
      maxChars: 180
    )
    XCTAssertTrue(Set(afterLRU.map(\.id)).isDisjoint(with: excluded))

    let one = try XCTUnwrap(choices.first)
    let tooSmall = await store.sampled(
      [one], purpose: "budget", seed: "fixed", maxChars: one.text.count - 1
    )
    XCTAssertTrue(tooSmall.isEmpty)
  }

  func testMissingShardAndSummaryMismatchReturnEmptyWithoutCrash() async throws {
    let missingRoot = try copiedResourceRoot()
    defer { try? FileManager.default.removeItem(at: missingRoot.deletingLastPathComponent()) }
    try FileManager.default.removeItem(
      at: missingRoot.appendingPathComponent("choices/dushi.json")
    )
    let missingStore = MaterialStore(resourceRoot: missingRoot)
    let missing = await missingStore.choices(genre: .dushi, scene: .duizhi)
    XCTAssertTrue(missing.isEmpty)

    let mismatchRoot = try copiedResourceRoot()
    defer { try? FileManager.default.removeItem(at: mismatchRoot.deletingLastPathComponent()) }
    let shardURL = mismatchRoot.appendingPathComponent("choices/gufeng.json")
    var shard = try JSONSerialization.jsonObject(with: Data(contentsOf: shardURL)) as! [[String: Any]]
    shard.removeLast()
    try JSONSerialization.data(withJSONObject: shard).write(to: shardURL, options: .atomic)
    let mismatchStore = MaterialStore(resourceRoot: mismatchRoot)
    let mismatched = await mismatchStore.choices(genre: .gufeng, scene: .duizhi)
    XCTAssertTrue(mismatched.isEmpty)
  }

  func testShardIsLazyAndThenCached() async throws {
    let root = try copiedResourceRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = MaterialStore(resourceRoot: root)
    let first = await store.choices(genre: .xianxia, scene: .duizhi)
    XCTAssertEqual(first.count, 30)

    try FileManager.default.removeItem(
      at: root.appendingPathComponent("choices/xianxia.json")
    )
    let cached = await store.choices(genre: .xianxia, scene: .duizhi)
    XCTAssertEqual(cached, first)

    try FileManager.default.removeItem(
      at: root.appendingPathComponent("choices/kehuan.json")
    )
    let lazyMissing = await store.choices(genre: .kehuan, scene: .duizhi)
    XCTAssertTrue(lazyMissing.isEmpty)
  }

  func testP6FixtureLoadsTenCategoriesWithOneHundredRowsEach() throws {
    let fixture = try XCTUnwrap(
      Bundle.module.url(
        forResource: "test_inputs",
        withExtension: "jsonl",
        subdirectory: "Fixtures"
      )
    )
    let rows = try String(contentsOf: fixture, encoding: .utf8)
      .split(separator: "\n")
      .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    XCTAssertEqual(rows.count, 1_000)
    let categories = Dictionary(grouping: rows, by: { $0["category"] as! String })
    XCTAssertEqual(categories.count, 10)
    XCTAssertTrue(categories.values.allSatisfy { $0.count == 100 })
  }

  func testRecentMaterialIDsKeepTwentyPerStoryworldBranchAndPurpose() async {
    let store = MaterialStore(resourceRoot: sourceResourceRoot)
    let storyworldID = UUID()
    let branchID = UUID()
    let ids = (1...25).map { "material-\($0)" }
    await store.recordUsedMaterialIDs(
      ids,
      storyworldID: storyworldID,
      branchID: branchID,
      purpose: "choices"
    )
    let recent = await store.recentMaterialIDs(
      storyworldID: storyworldID,
      branchID: branchID,
      purpose: "choices"
    )
    XCTAssertEqual(recent, Set(ids.suffix(20)))

    let otherBranch = await store.recentMaterialIDs(
      storyworldID: storyworldID,
      branchID: UUID(),
      purpose: "choices"
    )
    let otherPurpose = await store.recentMaterialIDs(
      storyworldID: storyworldID,
      branchID: branchID,
      purpose: "prose"
    )
    XCTAssertTrue(otherBranch.isEmpty)
    XCTAssertTrue(otherPurpose.isEmpty)
  }

  private var sourceResourceRoot: URL {
    repositoryRoot.appendingPathComponent("Sources/StoryMaterialKit/Resources/materials-v1")
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func copiedResourceRoot() throws -> URL {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = parent.appendingPathComponent("materials-v1", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: sourceResourceRoot, to: destination)
    return destination
  }
}
