import Foundation
import LLMProviderKit
import LibraryCore
import StoryworldCore
import StoryworldFactory
import StoryMaterialKit
import SwiftUI
import WorldbookUI

@main
struct WorldbookMacApp: App {

  private let library: NovelLibrary
  private let storyworldLibrary: StoryworldLibrary
  private let providerStore: ProviderProfileStore
  private let factoryStore: FactoryJobStore
  private let factoryWorker: any FactoryAnalysisWorker

  init() {
    // 打包验证使用真实资源解析路径，且不打开用户库或访问网络。
    if ProcessInfo.processInfo.arguments.contains("--verify-resources") {
      do {
        let root = MaterialStore.defaultResourceRoot
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(MaterialManifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.materialVersion == "v1" else { exit(1) }
        for (kind, genres) in manifest.shards {
          for (genre, count) in genres {
            let shard = try Data(contentsOf: root.appendingPathComponent("\(kind)/\(genre).json"))
            let rows = try JSONSerialization.jsonObject(with: shard) as? [Any]
            guard rows?.count == count else { exit(1) }
          }
        }
        print("Storyhack Community: bundled materials verified")
        exit(0)
      } catch {
        fputs("Bundled material verification failed: \(error)\n", stderr)
        exit(1)
      }
    }
    if let testRoot = ProcessInfo.processInfo.environment["WORLDBOOK_LIBRARY_ROOT"],
      testRoot.hasPrefix("/tmp/")
    {
      library = NovelLibrary(rootURL: URL(fileURLWithPath: testRoot, isDirectory: true))
    } else {
      library = NovelLibrary()
    }
    if let testRoot = ProcessInfo.processInfo.environment["WORLDBOOK_STORYWORLD_ROOT"],
      testRoot.hasPrefix("/tmp/")
    {
      storyworldLibrary = StoryworldLibrary(
        rootURL: URL(fileURLWithPath: testRoot, isDirectory: true)
      )
    } else {
      storyworldLibrary = StoryworldLibrary()
    }
    if let testRoot = ProcessInfo.processInfo.environment["WORLDBOOK_PROVIDER_ROOT"],
      testRoot.hasPrefix("/tmp/")
    {
      providerStore = ProviderProfileStore(
        rootURL: URL(fileURLWithPath: testRoot, isDirectory: true)
      )
    } else {
      providerStore = ProviderProfileStore()
    }
    if let testRoot = ProcessInfo.processInfo.environment["WORLDBOOK_FACTORY_ROOT"],
      testRoot.hasPrefix("/tmp/")
    {
      factoryStore = FactoryJobStore(
        rootURL: URL(fileURLWithPath: testRoot, isDirectory: true)
      )
    } else {
      factoryStore = FactoryJobStore()
    }
    factoryWorker = DefaultProviderFactoryWorker(providerStore: providerStore)
  }

  var body: some Scene {
    WindowGroup {
      WorldbookRootView(
        platform: .macOS,
        library: library,
        storyworldLibrary: storyworldLibrary,
        providerStore: providerStore,
        factoryStore: factoryStore,
        factoryWorker: factoryWorker
      )
      .frame(minWidth: 960, minHeight: 640)
    }
    .defaultSize(width: 1_320, height: 860)
    .windowStyle(.hiddenTitleBar)
  }
}
