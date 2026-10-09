import Foundation
import LLMProviderKit
import StoryworldCore
import Testing
@testable import WorldbookUI

@MainActor
struct DirectiveProfileUITests {
  @Test func selectionPersistsAndRejectsEditorFromAnotherPlaythrough() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("directive-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let record = try await library.create(lorebook: .init(title: "合成小说", entries: [.init(title: "地点", content: "渡口")]))
    let store = DirectiveProfileStore(rootURL: root.appendingPathComponent("directives"))
    let providerStore = ProviderProfileStore(rootURL: root.appendingPathComponent("providers"), credentialStore: UISettingsCredentialStore())
    let model = StorySessionViewModel(storyworldLibrary: library, providerStore: providerStore, directiveStore: store)
    await model.prepare(storyworldID: record.id)
    await model.createPlaythrough(title: "第一条线")
    let first = try #require(model.snapshot)
    let profile = DirectiveProfile(name: "我的档案", preamble: "以简洁对白推进。")
    #expect(await model.saveDirectiveProfile(profile, replacing: nil) == nil)
    #expect(await model.applyDirectiveProfile(profile, address: first.context.address, revision: nil) == nil)
    #expect(model.snapshot?.context.playthrough.effectiveDirective == profile)
    await model.createPlaythrough(title: "第二条线", directiveProfile: DirectiveProfile.builtins[1])
    #expect(await model.applyDirectiveProfile(profile, address: first.context.address, revision: nil) != nil)
    #expect(model.snapshot?.context.playthrough.effectiveDirective == DirectiveProfile.builtins[1])
    await model.openPlaythrough(first.context.playthrough.id)
    #expect(model.snapshot?.context.playthrough.effectiveDirective == profile)
    #expect(await model.deleteDirectiveProfile(profile) == nil)
    #expect(model.snapshot?.context.playthrough.effectiveDirective == profile)
    #expect(try await store.resolve(profile.id) == .green)
  }
}
