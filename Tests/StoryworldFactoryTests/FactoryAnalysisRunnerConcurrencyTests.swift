import Foundation
import NovelDocumentCore
import Testing

@testable import StoryworldFactory

/// FactoryAnalysisRunner 批次并发单元测试：mock 传输验证并发合并结果与串行一致、
/// 有界并发度、429 退避重试、检查点恢复语义与取消语义。
struct FactoryAnalysisRunnerConcurrencyTests {
  @Test
  func concurrentBatchesMergeMatchesSerialResult() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    // 串行基线：并发度 1
    let serialJob = try await makeJob(root: root.appendingPathComponent("serial"))
    let serialTransport = FakeBatchTransport(delay: .milliseconds(10))
    let serialProgress = ProgressRecorder()
    let serialRunner = FactoryAnalysisRunner(
      transport: serialTransport,
      maximumBatchUTF16Length: 10_000,
      executorVersion: "test",
      concurrency: 1,
      fileManager: .default
    )
    let serialResult = try await serialRunner.run(
      jobID: serialJob.jobID,
      manifest: serialJob.manifest,
      snapshotURL: serialJob.snapshot
    ) { progress in serialProgress.record(progress.fraction) }

    // 并发：并发度 4
    let concurrentJob = try await makeJob(root: root.appendingPathComponent("concurrent"))
    let concurrentTransport = FakeBatchTransport(delay: .milliseconds(10), firstWaveTarget: 4)
    let concurrentProgress = ProgressRecorder()
    let concurrentRunner = FactoryAnalysisRunner(
      transport: concurrentTransport,
      maximumBatchUTF16Length: 10_000,
      executorVersion: "test",
      concurrency: 4,
      fileManager: .default
    )
    let concurrentResult = try await concurrentRunner.run(
      jobID: concurrentJob.jobID,
      manifest: concurrentJob.manifest,
      snapshotURL: concurrentJob.snapshot
    ) { progress in concurrentProgress.record(progress.fraction) }

    // 合并结果与串行一致：覆盖章节与候选集合相等
    #expect(concurrentResult.analysis.coveredChapterIDs == serialResult.analysis.coveredChapterIDs)
    #expect(
      Set(concurrentResult.analysis.proposals.map(\.title))
        == Set(serialResult.analysis.proposals.map(\.title))
    )
    // 并发组确实并行推进；串行基线始终单批在途
    #expect(await concurrentTransport.maxConcurrentSends > 1)
    #expect(await serialTransport.maxConcurrentSends == 1)
    // 进度单调不回退且收尾到 1.0
    let fractions = concurrentProgress.fractions
    #expect(fractions == fractions.sorted())
    #expect(fractions.last == 1.0)
  }

  @Test
  func concurrentExecutionOverlapsBatchLatency() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let job = try await makeJob(root: root)
    // 直接观察在途调用重叠，不用整机负载敏感的总耗时阈值证明并发。
    let transport = FakeBatchTransport(delay: .milliseconds(10), firstWaveTarget: 4)
    let runner = FactoryAnalysisRunner(
      transport: transport,
      maximumBatchUTF16Length: 10_000,
      executorVersion: "test",
      concurrency: 4,
      fileManager: .default
    )
    let result = try await runner.run(
      jobID: job.jobID,
      manifest: job.manifest,
      snapshotURL: job.snapshot
    ) { _ in }
    #expect(result.analysis.coveredChapterIDs.count == 4)
    #expect(await transport.maxConcurrentSends == 4)
  }

  @Test
  func rateLimitedBatchRetriesWithBackoffAndSucceeds() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let job = try await makeJob(root: root)
    let transport = FakeBatchTransport(
      delay: .milliseconds(10),
      rateLimitFailures: ["chapter-000002": 1]
    )
    let runner = FactoryAnalysisRunner(
      transport: transport,
      maximumBatchUTF16Length: 10_000,
      executorVersion: "test",
      concurrency: 4,
      fileManager: .default
    )

    let result = try await runner.run(
      jobID: job.jobID,
      manifest: job.manifest,
      snapshotURL: job.snapshot
    ) { _ in }

    // 429 经退避后重试成功：全部章节覆盖，该批发了 2 次请求
    #expect(result.analysis.coveredChapterIDs.count == 4)
    #expect(await transport.sendCount(for: "chapter-000002") == 2)
    #expect(
      result.analysis.warnings.contains { $0.contains("已自动重试") }
    )
  }

  @Test
  func inflightCheckpointMarksBatchUncertainWithoutAffectingOthers() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let job = try await makeJob(root: root)
    // 预写第一批的 inflight 检查点：mock 传输无法恢复，落入保守路径
    let batchesURL = job.snapshot.deletingLastPathComponent()
      .appendingPathComponent("analysis/batches", isDirectory: true)
    try FileManager.default.createDirectory(at: batchesURL, withIntermediateDirectories: true)
    let checkpoint = BatchCheckpoint(
      contentHash: job.manifest.contentHash,
      chapterIDs: ["chapter-000001"],
      sessionID: "req-stale",
      runFingerprint: nil
    )
    try JSONEncoder().encode(checkpoint)
      .write(to: batchesURL.appendingPathComponent("0001.inflight.json"))

    let transport = FakeBatchTransport(delay: .milliseconds(10))
    let runner = FactoryAnalysisRunner(
      transport: transport,
      maximumBatchUTF16Length: 10_000,
      executorVersion: "test",
      concurrency: 4,
      fileManager: .default
    )
    let result = try await runner.run(
      jobID: job.jobID,
      manifest: job.manifest,
      snapshotURL: job.snapshot
    ) { _ in }

    // 第一批禁止自动重发，其余批次正常完成
    #expect(await transport.sendCount(for: "chapter-000001") == 0)
    #expect(
      Set(result.analysis.coveredChapterIDs)
        == Set(job.chapterIDs.filter { $0 != "chapter-000001" })
    )
    #expect(
      result.analysis.warnings.contains { $0.contains("上次请求状态无法确认") }
    )
  }

  @Test
  func cancelStopsAllInFlightBatches() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let job = try await makeJob(root: root)
    let transport = FakeBatchTransport(delay: .seconds(60))
    let runner = FactoryAnalysisRunner(
      transport: transport,
      maximumBatchUTF16Length: 10_000,
      executorVersion: "test",
      concurrency: 4,
      fileManager: .default
    )
    let task = Task {
      try await runner.run(
        jobID: job.jobID,
        manifest: job.manifest,
        snapshotURL: job.snapshot
      ) { _ in }
    }
    await transport.waitForFirstSend()
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    // 取消后编排器会尽力取消传输层的在途请求
    #expect(await transport.cancelCallCount >= 1)
  }

  // MARK: - 工具

  private struct TestJob {
    let manifest: FactoryInputManifest
    let snapshot: URL
    let jobID: UUID
    let chapterIDs: [String]
  }

  /// 4 章、每章约 7.7k utf16：10_000 的批次上限下每章独立成批，共 4 批。
  private func makeJob(root: URL) async throws -> TestJob {
    let store = FactoryJobStore(
      rootURL: root.appendingPathComponent("factory", isDirectory: true)
    )
    let chapters = (1...4).map { index in
      NovelChapter(
        id: String(format: "chapter-%06d", index),
        ordinal: index - 1,
        title: "第\(index)章",
        content: String(repeating: "林舟在青石镇调查旧塔之\(index)。\n", count: 550)
      )
    }
    let document = NovelDocument(
      id: UUID(),
      title: "并发测试小说",
      sourceFormat: .text,
      sourceFileName: "并发测试小说.txt",
      contentHash: String(repeating: "f", count: 64),
      chapters: chapters
    )
    let job = try await store.create(document: document)
    let manifest = try await store.inputManifest(job.id)
    let snapshot = try await store.workspaceURL(jobID: job.id, relativePath: "input")
    return TestJob(
      manifest: manifest,
      snapshot: snapshot,
      jobID: job.id,
      chapterIDs: chapters.map(\.id)
    )
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

/// 可编程 mock 批次传输：按提示词中的章节 ID 路由响应，支持人工延迟
/// （验证并发）、429 注入与取消观测。
private actor FakeBatchTransport: FactoryBatchTransport {
  private let delay: Duration
  private let firstWaveTarget: Int?
  private var rateLimitFailures: [String: Int]
  private var currentSends = 0
  private(set) var maxConcurrentSends = 0
  private(set) var cancelCallCount = 0
  private var sendCounts: [String: Int] = [:]
  private var firstSendContinuations: [CheckedContinuation<Void, Never>] = []

  init(delay: Duration, rateLimitFailures: [String: Int] = [:], firstWaveTarget: Int? = nil) {
    self.delay = delay
    self.rateLimitFailures = rateLimitFailures
    self.firstWaveTarget = firstWaveTarget
  }

  func beginRequest(title _: String) async throws -> String {
    UUID().uuidString
  }

  func send(checkpointToken _: String, systemPrompt _: String, prompt: String) async throws -> String {
    currentSends += 1
    maxConcurrentSends = max(maxConcurrentSends, currentSends)
    if !firstSendContinuations.isEmpty {
      firstSendContinuations.forEach { $0.resume() }
      firstSendContinuations.removeAll()
    }
    defer { currentSends -= 1 }
    // Hold the first wave until all expected calls overlap. A fixed sleep can
    // expire before the other tasks are scheduled on a busy test host.
    if let target = firstWaveTarget {
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while maxConcurrentSends < target && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    let chapterID = (1...4)
      .map { String(format: "chapter-%06d", $0) }
      .first { prompt.contains($0) }
    if let chapterID {
      sendCounts[chapterID, default: 0] += 1
    }
    try await Task.sleep(for: delay)
    guard let chapterID else {
      throw FactoryWorkerError.invalidResponse("无法路由的提示词")
    }
    if let remaining = rateLimitFailures[chapterID], remaining > 0 {
      rateLimitFailures[chapterID] = remaining - 1
      throw FactoryWorkerError.httpStatus(429, "rate limited")
    }
    return """
      {"covered_chapter_ids":["\(chapterID)"],"proposals":[{"kind":"location","title":"青石镇\(chapterID.suffix(2))","content":"小镇","activation_keys":[],"always_active":false,"evidence":[{"chapter_id":"\(chapterID)","quote":"林舟在青石镇调查旧塔之\(chapterID.suffix(1))。"}]}],"decisions":[]}
      """
  }

  func recoverInflight(checkpointToken _: String) async throws -> String? {
    nil
  }

  func cancel() async {
    cancelCallCount += 1
  }

  func sendCount(for chapterID: String) -> Int {
    sendCounts[chapterID] ?? 0
  }

  func waitForFirstSend() async {
    if currentSends > 0 { return }
    await withCheckedContinuation { continuation in
      firstSendContinuations.append(continuation)
    }
  }
}

/// 线程安全的进度记录器。
private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Double] = []

  var fractions: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record(_ fraction: Double) {
    lock.lock()
    recorded.append(fraction)
    lock.unlock()
  }
}
