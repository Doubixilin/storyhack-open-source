import Foundation
import LLMProviderKit
import NovelDocumentCore
import Testing

@testable import StoryworldFactory

/// DirectLLMFactoryWorker（直连模型工坊执行器）单元测试：
/// mock LLMProvider 验证完整闭环、修复、检查点恢复与取消语义。
struct DirectLLMFactoryWorkerTests {
  @Test
  func analyzeMergesMultipleBatchesAndPersistsBatchCaches() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(
          id: "chapter-000001", ordinal: 0, title: "第一章",
          content: String(repeating: "林舟在青石镇调查旧塔。\n", count: 550)
        ),
        NovelChapter(
          id: "chapter-000002", ordinal: 1, title: "第二章",
          content: String(repeating: "林舟决定留在青石镇守护旧塔。\n", count: 550)
        ),
      ]
    )
    let provider = StubFactoryProvider(responses: [
      """
      {"covered_chapter_ids":["chapter-000001"],"proposals":[{"kind":"location","title":"青石镇","content":"故事开始的小镇","activation_keys":["青石镇"],"always_active":false,"evidence":[{"chapter_id":"chapter-000001","quote":"林舟在青石镇调查旧塔。"}]}],"decisions":[]}
      """,
      """
      {"covered_chapter_ids":["chapter-000002"],"proposals":[{"kind":"character","title":"林舟","content":"主角，留下来守护旧塔","activation_keys":["林舟"],"always_active":true,"evidence":[{"chapter_id":"chapter-000002","quote":"林舟决定留在青石镇守护旧塔。"}]}],"decisions":[]}
      """,
    ])
    let worker = DirectLLMFactoryWorker(
      provider: provider,
      maximumBatchUTF16Length: 10_000,
      // 本测试的 stub 按请求顺序出响应，固定串行以保持确定性；
      // 并发行为由 FactoryAnalysisRunnerConcurrencyTests 覆盖。
      concurrency: 1
    )

    let result = try await worker.analyze(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshot
    ) { _ in }

    #expect(result.executorVersion.hasPrefix("direct-llm/3 (Stub, stub-model)/"))
    #expect(result.sessionID != nil)
    #expect(result.analysis.coveredChapterIDs == ["chapter-000001", "chapter-000002"])
    #expect(result.analysis.proposals.map(\.title).sorted() == ["林舟", "青石镇"])
    #expect(result.analysis.proposals.allSatisfy { !$0.evidence.isEmpty })
    #expect(provider.requestCount == 2)

    // 每批完成即落盘的缓存文件必须存在且内容与本批一致
    let batchesURL = snapshot.deletingLastPathComponent()
      .appendingPathComponent("analysis/batches", isDirectory: true)
    for (index, chapterID) in ["chapter-000001", "chapter-000002"].enumerated() {
      let cacheURL = batchesURL.appendingPathComponent(String(format: "%04d.json", index + 1))
      let data = try Data(contentsOf: cacheURL)
      let cache = try JSONDecoder().decode(BatchCache.self, from: data)
      #expect(cache.contentHash == manifest.contentHash)
      #expect(cache.chapterIDs == [chapterID])
      #expect(cache.output.coveredChapterIDs == [chapterID])
    }
  }

  @Test
  func malformedOutputIsRecoveredByModelAssistedRepair() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: "第一章", content: "林舟来到青石镇。")
      ]
    )
    let provider = StubFactoryProvider(responses: [
      "这不是 JSON 输出",
      """
      {"covered_chapter_ids":["chapter-000001"],"proposals":[{"kind":"location","title":"青石镇","content":"故事开始的小镇","activation_keys":[],"always_active":false,"evidence":[{"chapter_id":"chapter-000001","quote":"林舟来到青石镇。"}]}],"decisions":[]}
      """,
    ])
    let worker = DirectLLMFactoryWorker(provider: provider)

    let result = try await worker.analyze(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshot
    ) { _ in }

    #expect(result.analysis.proposals.map(\.title) == ["青石镇"])
    #expect(provider.requestCount == 2)
    #expect(
      result.analysis.warnings.contains { $0.contains("格式修复会话恢复") }
    )
  }

  @Test
  func unrepairableOutputEventuallyThrowsInvalidResponse() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: "第一章", content: "林舟来到青石镇。")
      ]
    )
    let provider = StubFactoryProvider(responses: ["这不是 JSON 输出"])
    let worker = DirectLLMFactoryWorker(provider: provider)

    let error = await #expect(throws: FactoryWorkerError.self) {
      try await worker.analyze(jobID: jobID, manifest: manifest, snapshotURL: snapshot) { _ in }
    }
    guard case .invalidResponse = error else {
      Issue.record("期望 invalidResponse，实际为 \(String(describing: error))")
      return
    }
    // 3 次初始重试 ×（请求 + 修复）+ 2 次缺章补全 ×（请求 + 修复）
    #expect(provider.requestCount == 10)
  }

  @Test
  func inflightCheckpointFallsIntoUncertainPriorRequestWithoutResend() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(
          id: "chapter-000001", ordinal: 0, title: "第一章",
          content: String(repeating: "林舟在青石镇调查旧塔。\n", count: 550)
        ),
        NovelChapter(
          id: "chapter-000002", ordinal: 1, title: "第二章",
          content: String(repeating: "林舟决定留在青石镇守护旧塔。\n", count: 550)
        ),
      ]
    )
    // 预写第一批的 inflight 检查点：直连模式无法查询上次请求结果
    let batchesURL = snapshot.deletingLastPathComponent()
      .appendingPathComponent("analysis/batches", isDirectory: true)
    try FileManager.default.createDirectory(at: batchesURL, withIntermediateDirectories: true)
    let checkpoint = BatchCheckpoint(
      contentHash: manifest.contentHash,
      chapterIDs: ["chapter-000001"],
      sessionID: "req-stale",
      runFingerprint: nil
    )
    try JSONEncoder().encode(checkpoint)
      .write(to: batchesURL.appendingPathComponent("0001.inflight.json"))

    let provider = StubFactoryProvider(responses: [
      """
      {"covered_chapter_ids":["chapter-000002"],"proposals":[{"kind":"character","title":"林舟","content":"主角","activation_keys":[],"always_active":false,"evidence":[{"chapter_id":"chapter-000002","quote":"林舟决定留在青石镇守护旧塔。"}]}],"decisions":[]}
      """
    ])
    let worker = DirectLLMFactoryWorker(provider: provider, maximumBatchUTF16Length: 10_000)

    let result = try await worker.analyze(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshot
    ) { _ in }

    // 第一批命中检查点：禁止自动重发，只发了第二批一个请求
    #expect(provider.requestCount == 1)
    #expect(
      provider.lastRequestTextContains("chapter-000001") == false
    )
    #expect(result.analysis.coveredChapterIDs == ["chapter-000002"])
    #expect(
      result.analysis.warnings.contains { $0.contains("上次请求状态无法确认") }
    )
  }

  @Test
  func cancelAbortsInFlightStream() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: "第一章", content: "林舟来到青石镇。")
      ]
    )
    let provider = HangingFactoryProvider()
    let worker = DirectLLMFactoryWorker(provider: provider)

    let task = Task {
      try await worker.analyze(jobID: jobID, manifest: manifest, snapshotURL: snapshot) { _ in }
    }
    await provider.waitForStreamStart()
    await worker.cancel(jobID: jobID)

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test
  func defaultProviderWorkerGuidesConfigurationWhenNoProfileExists() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: "第一章", content: "林舟来到青石镇。")
      ]
    )
    let store = ProviderProfileStore(
      rootURL: root.appendingPathComponent("providers", isDirectory: true)
    )
    let worker = DefaultProviderFactoryWorker(providerStore: store)

    let error = await #expect(throws: FactoryWorkerError.self) {
      try await worker.analyze(jobID: jobID, manifest: manifest, snapshotURL: snapshot) { _ in }
    }
    guard case .unavailable(let message) = error else {
      Issue.record("期望 unavailable，实际为 \(String(describing: error))")
      return
    }
    #expect(message.contains("模型设置"))
  }

  @Test
  func partialStreamThenTransportErrorIsUncertainWithoutResend() async throws {
    // 请求已产生部分文本后断流：结果不确定，禁止自动重发与缺章补全
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(
          id: "chapter-000001", ordinal: 0, title: "第一章",
          content: String(repeating: "林舟在青石镇调查旧塔。\n", count: 550)
        ),
        NovelChapter(
          id: "chapter-000002", ordinal: 1, title: "第二章",
          content: String(repeating: "林舟决定留在青石镇守护旧塔。\n", count: 550)
        ),
      ]
    )
    let provider = ScriptedFailureProvider(steps: [
      .fail(
        partial: "{\"covered_chapter_ids\":[\"chapter-000001\"],\"proposals\":[",
        error: URLError(.networkConnectionLost)
      ),
      .succeed(
        """
        {"covered_chapter_ids":["chapter-000002"],"proposals":[{"kind":"character","title":"林舟","content":"主角","activation_keys":[],"always_active":false,"evidence":[{"chapter_id":"chapter-000002","quote":"林舟决定留在青石镇守护旧塔。"}]}],"decisions":[]}
        """
      ),
    ])
    let worker = DirectLLMFactoryWorker(
      provider: provider,
      maximumBatchUTF16Length: 10_000,
      concurrency: 1
    )

    let result = try await worker.analyze(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshot
    ) { _ in }

    // 第一批 1 次请求（断流后未重发、未补全），第二批 1 次成功请求
    #expect(provider.requestCount == 2)
    #expect(provider.lastRequestTextContains("chapter-000001") == false)
    #expect(result.analysis.coveredChapterIDs == ["chapter-000002"])
    #expect(
      result.analysis.warnings.contains { $0.contains("上次请求状态无法确认") }
    )
  }

  @Test
  func authenticationFailureIsFatalWithoutAnyRetry() async throws {
    // 401 是确定性认证失败：立即致命上抛，不重试、不补全
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: "第一章", content: "林舟来到青石镇。")
      ]
    )
    let provider = ScriptedFailureProvider(steps: [
      .fail(partial: nil, error: OpenAICompatibleError.httpStatus(401, "invalid api key"))
    ])
    let worker = DirectLLMFactoryWorker(provider: provider)

    let error = await #expect(throws: FactoryWorkerError.self) {
      try await worker.analyze(jobID: jobID, manifest: manifest, snapshotURL: snapshot) { _ in }
    }
    guard case .authentication = error else {
      Issue.record("期望 authentication，实际为 \(String(describing: error))")
      return
    }
    #expect(provider.requestCount == 1)
  }

  @Test
  func uncertainRequestWithoutUsableAnalysisKeepsItsErrorAndCheckpoint() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(root: root, chapters: [
      NovelChapter(id: "chapter-000001", ordinal: 0, title: "第一章", content: "林舟在青石镇调查旧塔。")
    ])
    let provider = ScriptedFailureProvider(steps: [
      .fail(partial: nil, error: OpenAICompatibleError.httpStatus(500, "internal error"))
    ])
    let worker = DirectLLMFactoryWorker(provider: provider)
    // Reopening the failed job must keep the unknown outcome without sending again.
    for _ in 0..<2 {
      let error = await #expect(throws: FactoryWorkerError.self) {
        try await worker.analyze(jobID: jobID, manifest: manifest, snapshotURL: snapshot) { _ in }
      }
      #expect(error == .uncertainPriorRequest(1))
      #expect(provider.requestCount == 1)
      #expect(FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent()
        .appendingPathComponent("analysis/batches/0001.inflight.json").path))
    }
  }

  @Test
  func serverErrorIsUncertainWithoutRetryOrCoverage() async throws {
    // 非 429 的 HTTP 状态（如 500）：请求已到达服务端，结果不确定，
    // 不自动重试也不缺章补全
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(
          id: "chapter-000001", ordinal: 0, title: "第一章",
          content: String(repeating: "林舟在青石镇调查旧塔。\n", count: 550)
        ),
        NovelChapter(
          id: "chapter-000002", ordinal: 1, title: "第二章",
          content: String(repeating: "林舟决定留在青石镇守护旧塔。\n", count: 550)
        ),
      ]
    )
    let provider = ScriptedFailureProvider(steps: [
      .fail(partial: nil, error: OpenAICompatibleError.httpStatus(500, "internal error")),
      .succeed(
        """
        {"covered_chapter_ids":["chapter-000002"],"proposals":[{"kind":"character","title":"林舟","content":"主角","activation_keys":[],"always_active":false,"evidence":[{"chapter_id":"chapter-000002","quote":"林舟决定留在青石镇守护旧塔。"}]}],"decisions":[]}
        """
      ),
    ])
    let worker = DirectLLMFactoryWorker(
      provider: provider,
      maximumBatchUTF16Length: 10_000,
      concurrency: 1
    )

    let result = try await worker.analyze(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshot
    ) { _ in }

    #expect(provider.requestCount == 2)
    #expect(result.analysis.coveredChapterIDs == ["chapter-000002"])
    #expect(
      result.analysis.warnings.contains { $0.contains("上次请求状态无法确认") }
    )
  }

  @Test
  func rateLimitedBatchRetriesWithBackoff() async throws {
    // 429 是确定被拒绝（未计费）：允许指数退避自动重试
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: "第一章", content: "林舟来到青石镇。")
      ]
    )
    let provider = ScriptedFailureProvider(steps: [
      .fail(partial: nil, error: OpenAICompatibleError.httpStatus(429, "rate limited")),
      .succeed(
        """
        {"covered_chapter_ids":["chapter-000001"],"proposals":[{"kind":"location","title":"青石镇","content":"故事开始的小镇","activation_keys":[],"always_active":false,"evidence":[{"chapter_id":"chapter-000001","quote":"林舟来到青石镇。"}]}],"decisions":[]}
        """
      ),
    ])
    let worker = DirectLLMFactoryWorker(provider: provider)

    let result = try await worker.analyze(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshot
    ) { _ in }

    #expect(provider.requestCount == 2)
    #expect(result.analysis.coveredChapterIDs == ["chapter-000001"])
    #expect(result.analysis.warnings.contains { $0.contains("已自动重试") })
  }

  @Test
  func cacheWithMismatchedRunFingerprintIsIgnored() async throws {
    // 切换模型/执行器后，旧指纹的批次缓存不得复用（防止新旧模型输出混合）
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (manifest, snapshot, jobID) = try await makeJob(
      root: root,
      chapters: [
        NovelChapter(
          id: "chapter-000001", ordinal: 0, title: "第一章",
          content: String(repeating: "林舟在青石镇调查旧塔。\n", count: 550)
        )
      ]
    )
    let batchesURL = snapshot.deletingLastPathComponent()
      .appendingPathComponent("analysis/batches", isDirectory: true)
    try FileManager.default.createDirectory(at: batchesURL, withIntermediateDirectories: true)
    // 预写一个「完整覆盖但来自其它执行器」的缓存
    let foreignCache = BatchCache(
      contentHash: manifest.contentHash,
      chapterIDs: ["chapter-000001"],
      output: BatchOutput(coveredChapterIDs: ["chapter-000001"], proposals: [], decisions: []),
      warnings: nil,
      runFingerprint: "direct-llm/1 (其它服务, other-model)"
    )
    try JSONEncoder().encode(foreignCache)
      .write(to: batchesURL.appendingPathComponent("0001.json"))

    let provider = StubFactoryProvider(responses: [
      """
      {"covered_chapter_ids":["chapter-000001"],"proposals":[{"kind":"location","title":"青石镇","content":"故事开始的小镇","activation_keys":[],"always_active":false,"evidence":[{"chapter_id":"chapter-000001","quote":"林舟在青石镇调查旧塔。"}]}],"decisions":[]}
      """
    ])
    let worker = DirectLLMFactoryWorker(provider: provider)

    let result = try await worker.analyze(
      jobID: jobID,
      manifest: manifest,
      snapshotURL: snapshot
    ) { _ in }

    // 指纹不匹配 → 缓存被忽略，重新请求了一次
    #expect(provider.requestCount == 1)
    #expect(result.analysis.proposals.map(\.title) == ["青石镇"])
  }

  private func makeJob(
    root: URL,
    chapters: [NovelChapter]
  ) async throws -> (FactoryInputManifest, URL, UUID) {
    let store = FactoryJobStore(
      rootURL: root.appendingPathComponent("factory", isDirectory: true)
    )
    let document = NovelDocument(
      id: UUID(),
      title: "测试小说",
      sourceFormat: .text,
      sourceFileName: "测试小说.txt",
      contentHash: String(repeating: "e", count: 64),
      chapters: chapters
    )
    let job = try await store.create(document: document)
    let manifest = try await store.inputManifest(job.id)
    let snapshot = try await store.workspaceURL(jobID: job.id, relativePath: "input")
    return (manifest, snapshot, job.id)
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

/// 按顺序返回预置文本的 mock Provider；用完后重复最后一条，
/// 以适配重试/补全等不确定次数的后续请求。
private final class StubFactoryProvider: LLMProvider, @unchecked Sendable {
  let profile = ProviderProfile(
    displayName: "Stub",
    kind: .openAICompatible,
    modelID: "stub-model",
    credentialReference: "stub"
  )
  private let lock = NSLock()
  private var responses: [String]
  private var requests: [LLMRequest] = []

  init(responses: [String]) {
    self.responses = responses
  }

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.count
  }

  func lastRequestTextContains(_ text: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return requests.last?.messages.contains { $0.content.contains(text) } ?? false
  }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    lock.lock()
    requests.append(request)
    let response = responses.count > 1 ? responses.removeFirst() : (responses.first ?? "")
    lock.unlock()
    return AsyncThrowingStream { continuation in
      continuation.yield(.textDelta(response))
      continuation.yield(.completed)
      continuation.finish()
    }
  }
}

/// 按脚本出结果/抛错的 mock Provider：用于覆盖「部分文本后断流」
/// 「认证失败」「服务端错误」「限流重试」等错误分类路径。
/// 脚本用完后重复最后一步，以适配不确定次数的后续请求。
private final class ScriptedFailureProvider: LLMProvider, @unchecked Sendable {
  enum Step {
    case succeed(String)
    /// partial 非空时先产出一段文本再抛错，模拟「已产生部分输出后断流」
    case fail(partial: String?, error: any Error)
  }

  let profile = ProviderProfile(
    displayName: "Scripted",
    kind: .openAICompatible,
    modelID: "scripted-model",
    credentialReference: "scripted"
  )
  private let lock = NSLock()
  private var steps: [Step]
  private var requests: [LLMRequest] = []

  init(steps: [Step]) {
    self.steps = steps
  }

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.count
  }

  func lastRequestTextContains(_ text: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return requests.last?.messages.contains { $0.content.contains(text) } ?? false
  }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    lock.lock()
    requests.append(request)
    let step = steps.count > 1 ? steps.removeFirst() : steps[0]
    lock.unlock()
    return AsyncThrowingStream { continuation in
      switch step {
      case .succeed(let text):
        continuation.yield(.textDelta(text))
        continuation.yield(.completed)
        continuation.finish()
      case .fail(let partial, let error):
        if let partial { continuation.yield(.textDelta(partial)) }
        continuation.finish(throwing: error)
      }
    }
  }
}

/// 永不产出内容的 mock Provider，用于验证取消语义。
private final class HangingFactoryProvider: LLMProvider, @unchecked Sendable {
  let profile = ProviderProfile(
    displayName: "Hanging",
    kind: .openAICompatible,
    modelID: "hanging-model",
    credentialReference: "hanging"
  )
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var started = false

  func waitForStreamStart() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if started {
        lock.unlock()
        continuation.resume()
        return
      }
      self.continuation = continuation
      lock.unlock()
    }
  }

  func stream(_: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    lock.lock()
    started = true
    continuation?.resume()
    continuation = nil
    lock.unlock()
    return AsyncThrowingStream { _ in }
  }
}
