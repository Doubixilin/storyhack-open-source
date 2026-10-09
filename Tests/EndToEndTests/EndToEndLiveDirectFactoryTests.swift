import Foundation
import LibraryCore
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore
import StoryworldFactory
import Testing

/// 链路 B（联网）：直连模型工坊 —— 用 App 内同款 ProviderKit 直连配置，
/// 把真实小说前 3 章解析成世界书并发布，作为工坊链路的联网冒烟。
///
/// 门控：仅当 `WORLDBOOK_E2E_LIVE=1` 时运行，否则自动跳过。
///
/// 依赖环境变量：
/// - `DEEPSEEK_API_KEY`：模型 API Key（缺省回退 `OPENAI_API_KEY`）
/// - `WORLDBOOK_E2E_MODEL`：模型 ID（缺省 deepseek-v4-flash）
/// - `WORLDBOOK_E2E_SOURCE`：小说 TXT 路径（默认取 Examples/雾港来信.md）
/// - `WORLDBOOK_E2E_CHAPTER_LIMIT`：只分析前 N 章（缺省 3 章冒烟）
struct EndToEndLiveDirectFactoryTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WORLDBOOK_E2E_LIVE"] == "1"))
  func realDirectFactoryPublishesStoryworldForSelectedNovel() async throws {
    guard ProcessInfo.processInfo.environment["WORLDBOOK_E2E_LIVE"] == "1" else { return }
    let apiKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
      ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    try #require(apiKey != nil, "需要 DEEPSEEK_API_KEY")

    let modelID = ProcessInfo.processInfo.environment["WORLDBOOK_E2E_MODEL"] ?? "deepseek-v4-flash"
    let profile = ProviderProfile(
      displayName: "E2E DeepSeek",
      kind: .openAICompatible,
      baseURL: URL(string: "https://api.deepseek.com/v1")!,
      modelID: modelID,
      credentialReference: "e2e-deepseek"
    )
    let provider = try OpenAICompatibleProvider(profile: profile, apiKey: apiKey!)

    let sourcePath = ProcessInfo.processInfo.environment["WORLDBOOK_E2E_SOURCE"]
      ?? defaultSourcePath()
    let sourceURL = URL(fileURLWithPath: sourcePath)
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("e2e-direct-factory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = NovelLibrary(
      rootURL: root.appendingPathComponent("library", isDirectory: true)
    )
    let storyworldLibrary = StoryworldLibrary(
      rootURL: root.appendingPathComponent("storyworlds", isDirectory: true)
    )
    let store = FactoryJobStore(
      rootURL: root.appendingPathComponent("factory", isDirectory: true)
    )

    // 导入真实小说（缺省截断到前 3 章，保证导入指纹与工坊输入一致）
    let limitText = ProcessInfo.processInfo.environment["WORLDBOOK_E2E_CHAPTER_LIMIT"] ?? "3"
    let importURL: URL
    if let limit = Int(limitText), limit > 0 {
      importURL = try truncatedCopy(of: sourceURL, chapters: limit, root: root)
    } else {
      importURL = sourceURL
    }
    let record = try await library.importDocument(from: importURL)
    print("E2E 直连工坊源：\(record.document.title)")
    print("E2E 直连工坊章节：\(record.document.chapters.count) 章，"
      + "约 \(record.document.totalCharacterCount) 字")

    let worker = DirectLLMFactoryWorker(provider: provider)
    let coordinator = FactoryCoordinator(
      library: library,
      storyworldLibrary: storyworldLibrary,
      store: store,
      worker: worker
    )

    var job = try await coordinator.createJob(documentID: record.id)

    // 驱动状态机直至完成
    for _ in 0..<8 {
      switch job.stage {
      case .queued:
        try await coordinator.startAnalysis(jobID: job.id)
      case .failed, .cancelled:
        guard job.failure?.retryable != false else {
          throw FactoryWorkerError.unavailable(job.failure?.message ?? "任务不可重试")
        }
        try await coordinator.retry(jobID: job.id)
      case .waitingForUser:
        try await coordinator.acceptAllRecommendations(jobID: job.id)
        try await coordinator.generateCandidate(jobID: job.id)
      case .readyToPublish:
        _ = try await coordinator.publish(jobID: job.id)
      case .completed:
        break
      case .parsing, .indexing, .analyzing, .generating, .validating:
        throw FactoryWorkerError.invalidResponse("驱动循环遇到运行态")
      }
      job = try await store.load(job.id)
      print("E2E 直连工坊阶段：\(job.stage.rawValue) progress=\(job.progress)")
      if job.stage == .completed { break }
    }

    #expect(job.stage == .completed)
    #expect(job.executorVersion?.hasPrefix("direct-llm/1") == true)
    let analysis = try #require(try await store.analysis(job.id))
    #expect(!analysis.proposals.isEmpty)
    #expect(analysis.proposals.allSatisfy { !$0.evidence.isEmpty })
    #expect(try await store.validation(job.id) != nil)

    // 发布后的世界书可在 StoryworldLibrary 中加载，且与小说关联
    let publishedID = try #require(job.publishedStoryworldID)
    let document = try await storyworldLibrary.load(storyworldID: publishedID)
    #expect(!document.lorebook.entries.isEmpty)
    let associated = try await storyworldLibrary.listAssociated(
      with: .init(documentID: record.document.id, contentHash: record.document.contentHash)
    )
    #expect(associated.map(\.id).contains(publishedID))

    print("E2E 直连工坊发布世界书：\(document.manifest.title)，"
      + "\(document.lorebook.entries.count) 条设定")
  }

  /// 生成只含前 N 章的截断 Markdown 副本，保证导入后的文档指纹与工坊输入一致。
  private func truncatedCopy(of sourceURL: URL, chapters limit: Int, root: URL) throws -> URL {
    let parser = TextNovelParser()
    let document = try parser.parse(at: sourceURL)
    let kept = Array(document.chapters.prefix(limit))
    let markdown = kept.map { "# \($0.title)\n\n\($0.content)" }.joined(separator: "\n\n")
    let url = root.appendingPathComponent("截断-前\(limit)章.md")
    try Data(markdown.utf8).write(to: url)
    return url
  }

  private func defaultSourcePath() -> String {
    let candidate = "Examples/雾港来信.md"
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(candidate)
  }
}
