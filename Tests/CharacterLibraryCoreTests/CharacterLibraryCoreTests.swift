import Foundation
import XCTest

@testable import CharacterLibraryCore

final class CharacterLibraryCoreTests: XCTestCase {
  private var rootURL: URL!

  override func setUpWithError() throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    if let rootURL {
      try? FileManager.default.removeItem(at: rootURL)
    }
    rootURL = nil
  }

  func testCharacterPersistenceRoundTripAndDeletion() async throws {
    let store = CharacterLibraryStore(rootURL: rootURL)
    let created = try await store.createCharacter(
      name: "  阿青  ",
      summary: "越女剑客",
      origin: .extracted(storyworldID: UUID(), entryID: "hero"),
      fields: CharacterFields(personality: "澄澈", abilities: "剑术"),
      category: "主角",
      tags: ["剑客", "少女"]
    )
    XCTAssertEqual(created.name, "阿青")

    let reloadedStore = CharacterLibraryStore(rootURL: rootURL)
    let reloaded = try await reloadedStore.listCharacters()
    XCTAssertEqual(reloaded.count, 1)
    XCTAssertEqual(reloaded.first?.id, created.id)
    XCTAssertEqual(reloaded.first?.fields.abilities, "剑术")

    var changed = try XCTUnwrap(reloaded.first)
    changed.summary = "更新后的简介"
    changed.promptProfile = "青衣少女，竹杖"
    try await reloadedStore.updateProfile(changed)

    let updatedStore = CharacterLibraryStore(rootURL: rootURL)
    let updated = try await updatedStore.listCharacters()
    XCTAssertEqual(updated.first?.summary, "更新后的简介")
    XCTAssertEqual(updated.first?.promptProfile, "青衣少女，竹杖")

    try await updatedStore.deleteCharacter(id: created.id)
    let emptyStore = CharacterLibraryStore(rootURL: rootURL)
    let remaining = try await emptyStore.listCharacters()
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: rootURL
          .appendingPathComponent(created.id.uuidString.lowercased())
          .path
      )
    )
  }

  func testEmptyNameIsRejected() async throws {
    let store = CharacterLibraryStore(rootURL: rootURL)
    do {
      _ = try await store.createCharacter(name: " \n\t ")
      XCTFail("空名称应被拒绝")
    } catch let error as CharacterLibraryError {
      XCTAssertEqual(error, .emptyName)
    }
  }

  func testImportRejectsUnsupportedExtensionAndSymbolicLink() async throws {
    let store = CharacterLibraryStore(rootURL: rootURL)
    let character = try await store.createCharacter(name: "测试角色")
    let unsupported = rootURL.appendingPathComponent("fixture.gif")
    try pngData.write(to: unsupported, options: [.atomic])

    do {
      _ = try await store.importImage(from: unsupported, characterID: character.id)
      XCTFail("不支持的扩展名应被拒绝")
    } catch let error as CharacterLibraryError {
      XCTAssertEqual(error, .unsupportedFile)
    }

    let target = rootURL.appendingPathComponent("target.png")
    let link = rootURL.appendingPathComponent("linked.png")
    try pngData.write(to: target, options: [.atomic])
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    do {
      _ = try await store.importImage(from: link, characterID: character.id)
      XCTFail("符号链接应被拒绝")
    } catch let error as CharacterLibraryError {
      XCTAssertEqual(error, .unsafeFile)
    }
  }

  func testApprovalPortraitFlowAndAssetPersistence() async throws {
    let store = CharacterLibraryStore(rootURL: rootURL)
    let character = try await store.createCharacter(name: "林月如")
    let firstImage = rootURL.appendingPathComponent("first.png")
    let secondImage = rootURL.appendingPathComponent("second.jpg")
    try pngData.write(to: firstImage, options: [.atomic])
    try pngData.write(to: secondImage, options: [.atomic])

    let first = try await store.importImage(
      from: firstImage,
      characterID: character.id,
      prompt: "红衣女侠"
    )
    let second = try await store.importImage(from: secondImage, characterID: character.id)
    XCTAssertEqual(first.status, .candidate)
    XCTAssertEqual(first.provider, "local_import")

    do {
      _ = try await store.setPortrait(characterID: character.id, assetID: second.id)
      XCTFail("未批准图片不能设为主形象")
    } catch let error as CharacterLibraryError {
      XCTAssertEqual(error, .portraitRequiresApprovedImage)
    }

    let approved = try await store.approveAsset(
      characterID: character.id,
      assetID: first.id
    )
    XCTAssertEqual(approved.status, .approved)
    XCTAssertNotNil(approved.approvedAt)
    let profile = try await store.setPortrait(
      characterID: character.id,
      assetID: approved.id
    )
    XCTAssertEqual(profile.portraitAssetID, approved.id)

    do {
      _ = try await store.approveAsset(characterID: character.id, assetID: first.id)
      XCTFail("已批准资产不能重复批准")
    } catch let error as CharacterLibraryError {
      XCTAssertEqual(error, .invalidTransition)
    }

    let reloadedStore = CharacterLibraryStore(rootURL: rootURL)
    let assets = try await reloadedStore.listAssets(characterID: character.id)
    XCTAssertEqual(Set(assets.map(\.id)), Set([first.id, second.id]))
    XCTAssertEqual(assets.first(where: { $0.id == first.id })?.status, .approved)
    let profiles = try await reloadedStore.listCharacters()
    XCTAssertEqual(profiles.first?.portraitAssetID, first.id)
    let fileURL = await reloadedStore.assetFileURL(characterID: character.id, asset: approved)
    XCTAssertNotNil(fileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL?.path ?? ""))
  }

  func testCategoriesAndTagsAreUniqueAndSorted() async throws {
    let store = CharacterLibraryStore(rootURL: rootURL)
    _ = try await store.createCharacter(
      name: "甲",
      category: "配角",
      tags: ["江湖", "剑客", "江湖"]
    )
    _ = try await store.createCharacter(
      name: "乙",
      category: "主角",
      tags: ["少女", "剑客"]
    )
    _ = try await store.createCharacter(
      name: "丙",
      category: "配角",
      tags: []
    )

    let categories = try await store.allCategories()
    let tags = try await store.allTags()
    XCTAssertEqual(categories, ["主角", "配角"].sorted())
    XCTAssertEqual(tags, ["少女", "江湖", "剑客"].sorted())
  }

  private var pngData: Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
  }

  func testLossyIndexSkipsBrokenCharacterButKeepsHealthyOnes() async throws {
    let store = CharacterLibraryStore(rootURL: rootURL)
    let created = try await store.createCharacter(name: "阿青", summary: "越女剑客")

    // 往索引里塞一条结构非法的角色记录，模拟部分写入/手工改坏
    let indexURL = rootURL.appendingPathComponent("library.json")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
    )
    var characters = try XCTUnwrap(object["characters"] as? [[String: Any]])
    characters.append(["id": 123, "name": 456])
    object["characters"] = characters
    try JSONSerialization.data(withJSONObject: object).write(to: indexURL)

    let reloaded = CharacterLibraryStore(rootURL: rootURL)
    let listed = try await reloaded.listCharacters()
    XCTAssertEqual(listed.map(\.id), [created.id])
    let diagnostics = await reloaded.loadDiagnostics
    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertTrue(diagnostics[0].contains("1 条记录无法解析"))
  }

  func testNewerFormatVersionIsRefused() async throws {
    let store = CharacterLibraryStore(rootURL: rootURL)
    _ = try await store.createCharacter(name: "阿青")

    let indexURL = rootURL.appendingPathComponent("library.json")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
    )
    object["format_version"] = 999
    try JSONSerialization.data(withJSONObject: object).write(to: indexURL)

    let reloaded = CharacterLibraryStore(rootURL: rootURL)
    do {
      _ = try await reloaded.listCharacters()
      XCTFail("未知的新版本索引应拒绝读取")
    } catch let error as CharacterLibraryError {
      XCTAssertEqual(error, .unsupportedFormatVersion(found: 999))
    }
  }

  func testAssetFileURLRejectsPathEscapingCharacterDirectory() async throws {
    let store = CharacterLibraryStore(rootURL: rootURL)
    let character = try await store.createCharacter(name: "阿青")
    let escaping = CharacterAsset(
      characterID: character.id,
      kind: .image,
      relativePath: "../../outside.png",
      mimeType: "image/png",
      fileSHA256: "deadbeef",
      provider: "test"
    )
    let url = await store.assetFileURL(characterID: character.id, asset: escaping)
    XCTAssertNil(url)
    let legal = CharacterAsset(
      characterID: character.id,
      kind: .image,
      relativePath: "images/x.png",
      mimeType: "image/png",
      fileSHA256: "deadbeef",
      provider: "test"
    )
    let legalURL = await store.assetFileURL(characterID: character.id, asset: legal)
    XCTAssertNotNil(legalURL)
  }
}
