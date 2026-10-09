import Foundation
import LibraryCore
import StoryworldCore
import StoryworldFactory
import Testing
@testable import WorldbookUI

@MainActor
struct FactoryTasteUITests {
  @Test func taskEditorPreservesInheritanceAndRejectsSwitchedOrStaleTargets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("factory-taste-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("synthetic.txt")
    try Data("第一章 渡口\n旅人站在渡口。".utf8).write(to: source)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library"))
    let record = try await library.importDocument(from: source)
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("jobs"))
    let tasteStore = PlayerTasteStore(rootURL: root.appendingPathComponent("taste"))
    let coordinator = FactoryCoordinator(library: library,
      storyworldLibrary: StoryworldLibrary(rootURL: root.appendingPathComponent("worlds")),
      store: store, worker: UnavailableFactoryAnalysisWorker(), tasteStore: tasteStore)
    let first = try await coordinator.createJob(documentID: record.id)
    let second = try await coordinator.createJob(documentID: record.id)
    let model = FactoryViewModel(coordinator: coordinator, store: store)
    await model.initialize()
    let global = try #require(await model.globalTasteForEditing())
    #expect(await model.saveGlobalTaste(.init(style: .vivid, avoidElements: ["虫群"]), replacing: global) == nil)
    await model.select(first.id)
    let reviewed = try #require(await model.tasteForEditing())
    #expect(reviewed.inherited.style == .vivid && reviewed.overrides.isEmpty)
    #expect(await model.saveTaste(.init(pace: .brisk), replacing: reviewed) == nil)
    #expect(try model.tasteSettings?.effective == .init(pace: .brisk, style: .vivid, avoidElements: ["虫群"]))
    let reopened = try #require(await model.tasteForEditing())
    #expect(reopened.overrides.style == nil && reopened.overrides.pace == .brisk)
    await model.select(second.id)
    #expect(await model.saveTaste(.init(styleIntensity: 1), replacing: reopened) != nil)
    #expect(try await store.load(second.id).tasteConfiguration == nil)
    await model.select(first.id)
    try await coordinator.updateTasteSettings(reopened, overrides: .init(styleIntensity: 5))
    #expect(await model.saveTaste(.init(styleIntensity: 1), replacing: reopened) != nil)
    #expect(try await store.load(first.id).tasteConfiguration?.overrides.styleIntensity == 5)
    #expect(try await store.load(first.id).stage == .queued)
    #expect(try await store.analysis(first.id) == nil)
  }
}
