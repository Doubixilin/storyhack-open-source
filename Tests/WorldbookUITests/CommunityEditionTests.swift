import Foundation
import LibraryCore
import LLMProviderKit
import StoryworldCore
import StoryworldFactory
import WritingCore
import CharacterLibraryCore
import VisualMediaCore
import MediaCore
import Testing
@testable import WorldbookUI

@MainActor
struct CommunityEditionTests {
  @Test func publicDemoImportsWithoutAProvider() async throws {
    let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Examples")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let books = NovelLibrary(rootURL: root.appendingPathComponent("books"))
    let book = try await books.importDocument(from: examples.appendingPathComponent("雾港来信.md"))
    #expect(book.document.chapters.count >= 3)
    let worlds = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let model = StoryworldViewModel(library: worlds, novelLibrary: books)
    await model.importFiles(from: [examples.appendingPathComponent("雾港来信.lorebook")], associateWith: book)
    #expect(model.errorMessage == nil)
    let world = try #require(try await worlds.list().first)
    #expect(world.lorebookEntryCount == 4)
    #expect(world.associatedDocumentIDs.contains(book.id))
    #expect(model.selectedDocument?.lorebook.title == "雾港来信")
  }

  @Test func defaultsKeepCommunityDataAndCredentialsSeparate() {
    let roots = [
      NovelLibrary.defaultRootURL, StoryworldLibrary.defaultRootURL,
      ProviderProfileStore.defaultRootURL, FactoryJobStore.defaultRootURL,
      WritingProjectLibrary.defaultRootURL, AdaptationJobStore.defaultRootURL,
      DirectiveProfileStore.defaultRootURL, PlayerTasteStore.defaultRootURL,
      CharacterLibraryStore.defaultRootURL(),
      VisualAssetStore.defaultRootURL(storyworldID: UUID()), SpeechPlanStore.defaultRootURL,
    ]
    for root in roots {
      #expect(root.pathComponents.contains("StoryhackCommunity"))
      #expect(!root.pathComponents.contains("WorldbookApp"))
    }
    #expect(KeychainCredentialStore().service == "org.doubixilin.storyhack.community.llm")
  }

  @Test func createsAndImportsMoreThanThreeWorldsThroughTheViewModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let model = StoryworldViewModel(library: library)
    for index in 1...5 {
      await model.createEmptyStoryworld(title: "社区测试世界 \(index)")
      #expect(model.errorMessage == nil)
    }
    #expect(try await library.list().count == 5)
    let first = try #require(try await library.list().first)
    let exported = try await library.managedPackageURL(storyworldID: first.id)
    let copied = root.appendingPathComponent("import.storyworld")
    try FileManager.default.copyItem(at: exported, to: copied)
    await model.importStandaloneFiles(from: [copied])
    model.resolvePendingConflict(with: .importAsCopy)
    // Conflict resolution starts a Task; poll boundedly for its actual persisted result.
    for _ in 0..<100 {
      if try await library.list().count == 6 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await library.list().count == 6)
    #expect(model.errorMessage == nil)
  }
}
