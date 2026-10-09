import Foundation
import LLMProviderKit
import StoryworldCore
import Testing
@testable import WorldbookUI

@MainActor
struct PlayerTasteUITests {
  @Test func sharedPreferencesReopenAndStaleNativeEditorKeepsNewerValue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("taste-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let store = PlayerTasteStore(rootURL: root.appendingPathComponent("taste"))
    let providers = ProviderProfileStore(rootURL: root.appendingPathComponent("providers"), credentialStore: UISettingsCredentialStore())
    let model = StorySessionViewModel(storyworldLibrary: library, providerStore: providers, tasteStore: store)
    let second = StorySessionViewModel(storyworldLibrary: library, providerStore: providers, tasteStore: store)
    let initial = try #require(await model.playerTasteForEditing())
    #expect(initial.profile.isDefault)
    let profile = PlayerTasteProfile(pace: .unhurried, style: .vivid, styleIntensity: 1,
      avoidElements: ["昆虫特写"], notes: "多些自然对话。")
    #expect(await model.savePlayerTaste(profile, replacing: initial) == nil)
    let reopened = try #require(await second.playerTasteForEditing())
    #expect(reopened.profile == profile)
    #expect(await second.savePlayerTaste(.standard, replacing: reopened) == nil)
    #expect(await model.savePlayerTaste(.init(style: .concise), replacing: reopened) != nil)
    #expect(try await store.load().profile.isDefault)
  }
}
