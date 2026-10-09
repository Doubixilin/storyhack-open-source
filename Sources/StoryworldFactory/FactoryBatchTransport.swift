import Foundation

/// 批次传输抽象：隔离「模型请求怎么发」与「批次编排逻辑」。
///
/// 注意：发起请求前必须先 `beginRequest` 拿到在途凭证（直连为本地
/// request id），编排器会把它写入 inflight 检查点；
/// 重跑命中检查点时凭它尝试 `recoverInflight` 恢复上次结果。
protocol FactoryBatchTransport: Sendable {
  /// 登记一次新请求，返回写入检查点的在途凭证。
  func beginRequest(title: String) async throws -> String
  /// 发送一个完整批次（或修复请求），返回模型原始文本输出。
  func send(checkpointToken: String, systemPrompt: String, prompt: String) async throws -> String
  func send(checkpointToken: String, systemPrompt: String, prompt: String,
    maximumOutputTokens: Int) async throws -> String
  /// 尝试恢复检查点记录的在途请求结果；返回 nil 表示无法查询（直连场景）。
  func recoverInflight(checkpointToken: String) async throws -> String?
  /// 尽力取消当前在途请求。
  func cancel() async
}

extension FactoryBatchTransport {
  func send(checkpointToken: String, systemPrompt: String, prompt: String,
    maximumOutputTokens: Int) async throws -> String {
    try await send(checkpointToken: checkpointToken, systemPrompt: systemPrompt, prompt: prompt)
  }
}

private struct FactoryInitialBatchResult {
  let output: BatchOutput
  let warnings: [String]
  let sessionID: String?
}

/// 待执行批次：cached 非空表示缓存命中但章节覆盖不完整，
/// 跳过初始请求、只做缺章补全。
private struct FactoryPendingBatch: Sendable {
  let index: Int
  let batch: [FactoryChapterText]
  let cacheURL: URL
  let cached: (output: BatchOutput, warnings: [String])?
  var context: FactoryBatchContext? = nil
}

/// 单批执行结果：非致命错误已降级为 warnings，只有致命错误/取消向外抛。
private struct FactoryBatchExecutionResult: Sendable {
  let index: Int
  let output: BatchOutput
  let warnings: [String]
  let sessionID: String?
  let uncertainRequest: Bool
}

/// 世界书分析批次编排器：批次循环（有界并发）、缓存读写、inflight 检查点、
/// 重试分类、缺章补全与最终合并。两条执行路径共用同一份编排，保证缓存/检查点
/// 文件格式、错误语义与恢复行为完全一致。
/// 每批仍是独立单元：发请求前写 inflight 检查点、完成后原子写独立缓存文件，
/// 批次间只通过 actor 共享已完成候选的摘要；每批首次使用的上下文独立冻结。
/// FileManager 官方文档保证其实例方法线程安全，故标记 @unchecked Sendable。
struct FactoryAnalysisRunner: @unchecked Sendable {
  let transport: any FactoryBatchTransport
  let maximumBatchUTF16Length: Int
  let executorVersion: String
  /// 批次并发度，构造时按 1–16 clamp。
  let concurrency: Int
  let budget: FactoryAnalysisBudget?
  let fileManager: FileManager

  init(
    transport: any FactoryBatchTransport,
    maximumBatchUTF16Length: Int,
    executorVersion: String,
    concurrency: Int = 3,
    budget: FactoryAnalysisBudget? = nil,
    fileManager: FileManager
  ) {
    self.transport = transport
    self.maximumBatchUTF16Length = maximumBatchUTF16Length
    self.executorVersion = executorVersion
    self.concurrency = min(16, max(1, concurrency))
    self.budget = budget
    self.fileManager = fileManager
  }

  func run(
    jobID: UUID,
    manifest: FactoryInputManifest,
    snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void
  ) async throws -> FactoryWorkerResult {
    let jobURL = snapshotURL.deletingLastPathComponent()
    let sourceChapters = try FactoryAnalysisPipeline.loadChapters(
      manifest: manifest,
      snapshotURL: snapshotURL
    )
    let analysisPlan = try budget?.plan(sourceChapters, maximumUTF16Length: maximumBatchUTF16Length)
      ?? FactoryAnalysisPipeline.makeAnalysisPlan(sourceChapters, maximumBatchUTF16Length: maximumBatchUTF16Length)
    let chapters = analysisPlan.units
    let batches = try budget?.batches(chapters, maximumUTF16Length: maximumBatchUTF16Length)
      ?? FactoryAnalysisPipeline.makeBatches(chapters, maximumBatchUTF16Length: maximumBatchUTF16Length)
    try validatePriorPlan(jobURL: jobURL, manifest: manifest, batches: batches)
    var outputs: [BatchOutput?] = Array(repeating: nil, count: batches.count)
    var warnings: [String] = []
    var pending: [FactoryPendingBatch] = []
    var completedCount = 0
    var lastSessionID: String?
    var uncertainBatches: [Int] = []
    let diversity = FactoryDiversityContext()

    // 预扫描：缓存命中且章节覆盖完整的批次直接采用，不进入并发组。
    for (index, batch) in batches.enumerated() {
      let cacheURL =
        jobURL
        .appendingPathComponent("analysis/batches", isDirectory: true)
        .appendingPathComponent(String(format: "%04d.json", index + 1))
      let context = try FactoryBatchContext.load(at: FactoryBatchContext.url(for: cacheURL),
        manifest: manifest, chapterIDs: batch.map(\.analysisID), executor: executorVersion,
        fileManager: fileManager)
      guard let cached = try FactoryAnalysisPipeline.loadCachedBatch(
        at: cacheURL,
        contentHash: manifest.contentHash,
        chapterIDs: batch.map(\.analysisID),
        runFingerprint: context?.runFingerprint ?? executorVersion + "/missing-context",
        fileManager: fileManager
      ) else {
        pending.append(
          FactoryPendingBatch(index: index, batch: batch, cacheURL: cacheURL, cached: nil, context: context)
        )
        continue
      }
      let normalized = FactoryAnalysisPipeline.normalizeBatchOutput(cached.output, batch: batch, isAggregate: true)
      let expected = Set(batch.map(\.analysisID))
      if expected.isSubset(of: Set(normalized.output.coveredChapterIDs)),
        expected.isSubset(of: Set(normalized.output.chapterSummaries.map(\.chapterID))) {
        outputs[index] = normalized.output
        warnings.append(contentsOf: cached.warnings ?? [])
        warnings.append(contentsOf: normalized.warnings.map { "第 \(index + 1) 批：\($0)" })
        completedCount += 1
        await diversity.ingest(normalized.output, batchIndex: index)
      } else {
        pending.append(
          FactoryPendingBatch(
            index: index,
            batch: batch,
            cacheURL: cacheURL,
            cached: (normalized.output, cached.warnings ?? []), context: context
          )
        )
      }
    }
    if completedCount > 0 {
      await progress(
        .init(
          fraction: Double(completedCount) / Double(max(1, batches.count)),
          executorVersion: executorVersion,
          sessionID: nil
        )
      )
    }

    if !pending.isEmpty {
      // 有界并发：始终最多 concurrency 个批次在途；进度回调只在 task group
      // 主体内串行发出，已完成数单调递增，进度不会回退。
      do {
        try await withThrowingTaskGroup(of: FactoryBatchExecutionResult.self) { group in
          var iterator = pending.makeIterator()
          for _ in 0..<min(concurrency, pending.count) {
            guard let item = iterator.next() else { break }
            group.addTask {
              try await self.executeBatch(item, batchCount: batches.count, manifest: manifest, diversity: diversity)
            }
          }
          while let result = try await group.next() {
            outputs[result.index] = result.output
            if result.uncertainRequest { uncertainBatches.append(result.index + 1) }
            await diversity.ingest(result.output, batchIndex: result.index)
            warnings.append(contentsOf: result.warnings)
            if let sessionID = result.sessionID { lastSessionID = sessionID }
            completedCount += 1
            await progress(
              .init(
                fraction: Double(completedCount) / Double(max(1, batches.count)),
                executorVersion: executorVersion,
                sessionID: lastSessionID
              )
            )
            if let item = iterator.next() {
              group.addTask {
                try await self.executeBatch(item, batchCount: batches.count, manifest: manifest, diversity: diversity)
              }
            }
          }
        }
      } catch {
        // 致命错误或取消：task group 已停掉剩余子任务，再尽力取消在途请求。
        await transport.cancel()
        throw error
      }
    }

    // Preserve partial usable analysis, but do not disguise an unknown request
    // outcome as malformed model output when no candidate could be recovered.
    if outputs.allSatisfy({ $0?.proposals.isEmpty ?? true }), let batch = uncertainBatches.min() {
      throw FactoryWorkerError.uncertainPriorRequest(batch)
    }
    let analysis = try FactoryAnalysisPipeline.buildAnalysis(
      jobID: jobID,
      manifest: manifest,
      chapters: chapters,
      outputs: outputs.map { $0 ?? .empty },
      automaticallyCoveredChapterIDs: analysisPlan.automaticallyCoveredChapterIDs,
      warnings: analysisPlan.warnings + warnings
    )
    return FactoryWorkerResult(
      analysis: analysis,
      executorVersion: executorVersion,
      sessionID: lastSessionID
    )
  }

  /// Replanning can shrink or reorder batches. Check every pending request
  /// before sending anything, including files no longer visited by the new plan.
  private func validatePriorPlan(jobURL: URL, manifest: FactoryInputManifest,
    batches: [[FactoryChapterText]]) throws {
    let directory = jobURL.appendingPathComponent("analysis/batches")
    guard fileManager.fileExists(atPath: directory.path) else { return }
    guard directory.resolvingSymlinksInPath().pathComponents.starts(
      with: jobURL.resolvingSymlinksInPath().pathComponents) else { throw FactoryRequestRetryError.invalidCheckpoint }
    for url in try fileManager.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      where url.lastPathComponent.hasSuffix(".inflight.json") {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw FactoryRequestRetryError.invalidCheckpoint
      }
      let index = Int(url.lastPathComponent.split(separator: ".").first ?? "") ?? 0
      let data = try Data(contentsOf: url)
      guard data.count <= 65_536, index > 0, index <= batches.count,
        let checkpoint = try? JSONDecoder().decode(BatchCheckpoint.self, from: data),
        checkpoint.contentHash == manifest.contentHash,
        Set(checkpoint.chapterIDs).isSubset(of: Set(batches[index - 1].map(\.analysisID))),
        checkpoint.runFingerprint.map({ $0 == executorVersion || $0.hasPrefix(executorVersion + "/diversity-v") }) ?? true
      else { throw FactoryWorkerError.uncertainPriorRequest(index) }
    }
  }

  /// 单批执行单元，与旧串行循环体等价：（可选）初始请求 → 归一化 →
  /// 缺章补全 → 校验 → 落盘缓存 → 清理检查点。
  private func executeBatch(
    _ pending: FactoryPendingBatch,
    batchCount: Int,
    manifest: FactoryInputManifest,
    diversity: FactoryDiversityContext
  ) async throws -> FactoryBatchExecutionResult {
    let index = pending.index
    let batch = pending.batch
    let cacheURL = pending.cacheURL
    let context: FactoryBatchContext
    if let stored = pending.context { context = stored }
    else {
      context = try await diversity.context(for: FactoryBatchContext.url(for: cacheURL),
        manifest: manifest, chapterIDs: batch.map(\.analysisID), executor: executorVersion,
        maximumTokens: budget?.diversityLimit,
        fileManager: fileManager)
    }
    var output: BatchOutput
    var outputIsAggregate = false
    var batchWarnings: [String] = []
    var shouldAttemptCoverage = true
    var preserveCheckpoints = false
    var sessionID: String?
    let hasInitialCheckpoint = (1...3).contains {
      fileManager.fileExists(atPath: FactoryAnalysisPipeline.requestCheckpointURL(for: cacheURL, attempt: $0).path)
    }
    if let cached = pending.cached, !hasInitialCheckpoint {
      output = cached.output
      outputIsAggregate = true
      batchWarnings.append(contentsOf: cached.warnings)
    } else {
      do {
        if pending.cached == nil, (1...2).contains(where: {
          fileManager.fileExists(atPath: FactoryAnalysisPipeline.coverageCheckpointURL(
            for: cacheURL, attempt: $0).path)
        }) {
          // Losing the partial cache is not evidence that a supplement request
          // was never sent. Preserve the outstanding checkpoint for review.
          throw FactoryWorkerError.uncertainPriorRequest(index + 1)
        }
        let initial = try await requestInitialBatch(
          batch: batch,
          batchIndex: index,
          batchCount: batchCount,
          manifest: manifest,
          cacheURL: cacheURL,
          context: context
        )
        output = initial.output
        batchWarnings.append(contentsOf: initial.warnings)
        sessionID = initial.sessionID
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if FactoryAnalysisPipeline.isFatalBatchError(error) { throw error }
        output = pending.cached?.output ?? .empty
        outputIsAggregate = pending.cached != nil
        if case FactoryWorkerError.uncertainPriorRequest = error {
          shouldAttemptCoverage = false
          preserveCheckpoints = true
          batchWarnings.append(
            "第 \(index + 1) 批上次请求状态无法确认，未自动重复发送；可稍后手动继续补全。"
          )
        } else if case FactoryWorkerError.httpStatus = error {
          // 三次请求均被 429 拒绝：不再经缺章补全继续发送，避免限流期间放大请求量
          shouldAttemptCoverage = false
          batchWarnings.append(
            "第 \(index + 1) 批模型服务持续限流（\(FactoryAnalysisPipeline.safeBatchFailureReason(error))），未继续发送；可稍后手动继续补全。"
          )
        } else {
          batchWarnings.append(
            "第 \(index + 1) 批初始输出不可用（\(FactoryAnalysisPipeline.safeBatchFailureReason(error))），已转入缺章补全。"
          )
        }
      }
    }

    let normalized = FactoryAnalysisPipeline.normalizeBatchOutput(output, batch: batch,
      isAggregate: outputIsAggregate)
    output = normalized.output
    batchWarnings.append(contentsOf: normalized.warnings.map { "第 \(index + 1) 批：\($0)" })
    if shouldAttemptCoverage {
      // Persist a known completed response before requesting more work. An
      // interruption during supplementation must not lose the initial result.
      try FactoryAnalysisPipeline.saveCachedBatch(output, warnings: batchWarnings, at: cacheURL,
        contentHash: manifest.contentHash, chapterIDs: batch.map(\.analysisID),
        runFingerprint: context.runFingerprint, fileManager: fileManager)
      FactoryAnalysisPipeline.removeRequestCheckpoints(for: cacheURL, fileManager: fileManager)
      let coverage = try await completeMissingCoverage(
        output,
        batch: batch,
        batchIndex: index,
        batchCount: batchCount,
        manifest: manifest,
        cacheURL: cacheURL,
        context: context,
        repairsSummaries: pending.cached != nil
      )
      output = coverage.output
      batchWarnings.append(contentsOf: coverage.warnings)
      if let recoverySessionID = coverage.sessionID { sessionID = recoverySessionID }
      preserveCheckpoints = preserveCheckpoints || coverage.uncertain
    }
    try FactoryAnalysisPipeline.validateBatchOutput(
      output,
      batch: batch,
      requiresProposal: false,
      requiresCompleteCoverage: false,
      isAggregate: true
    )
    try FactoryAnalysisPipeline.saveCachedBatch(
      output,
      warnings: batchWarnings,
      at: cacheURL,
      contentHash: manifest.contentHash,
      chapterIDs: batch.map(\.analysisID),
      runFingerprint: context.runFingerprint,
      fileManager: fileManager
    )
    if !preserveCheckpoints || shouldAttemptCoverage {
      FactoryAnalysisPipeline.removeRequestCheckpoints(for: cacheURL, fileManager: fileManager)
    }
    if !preserveCheckpoints {
      FactoryAnalysisPipeline.removeCoverageCheckpoints(for: cacheURL, fileManager: fileManager)
    }
    return FactoryBatchExecutionResult(
      index: index,
      output: output,
      warnings: batchWarnings,
      sessionID: sessionID,
      uncertainRequest: preserveCheckpoints
    )
  }

  private func requestInitialBatch(
    batch: [FactoryChapterText],
    batchIndex: Int,
    batchCount: Int,
    manifest: FactoryInputManifest,
    cacheURL: URL,
    context: FactoryBatchContext
  ) async throws -> FactoryInitialBatchResult {
    let prompt = FactoryAnalysisPrompts.makeBatchPrompt(batch: batch, batchIndex: batchIndex,
      batchCount: batchCount, diversityContext: context.text, maximumOutputTokens: budget?.output)
    try budget?.validate(system: FactoryAnalysisPrompts.analysisSystem, prompt: prompt)
    var warnings: [String] = []
    for attempt in 1...3 {
      let checkpointURL = FactoryAnalysisPipeline.requestCheckpointURL(
        for: cacheURL,
        attempt: attempt
      )
      do {
        let output: BatchOutput
        let sessionID: String
        if let checkpoint = try FactoryAnalysisPipeline.loadCheckpoint(
          at: checkpointURL,
          contentHash: manifest.contentHash,
          chapterIDs: batch.map(\.analysisID),
          runFingerprint: context.runFingerprint,
          fileManager: fileManager
        ) {
          sessionID = checkpoint.sessionID
          guard let recovered = try await transport.recoverInflight(checkpointToken: sessionID)
          else { throw FactoryWorkerError.uncertainPriorRequest(batchIndex + 1) }
          output = try await decodeBatchOutputWithRepair(recovered, sourceToken: sessionID)
        } else {
          sessionID = try await transport.beginRequest(
            title: "世界书分析 \(batchIndex + 1)/\(batchCount)-\(attempt)"
          )
          try FactoryAnalysisPipeline.saveCheckpoint(
            at: checkpointURL,
            contentHash: manifest.contentHash,
            chapterIDs: batch.map(\.analysisID),
            sessionID: sessionID,
            runFingerprint: context.runFingerprint,
            fileManager: fileManager
          )
          let rawOutput = try await transport.send(
            checkpointToken: sessionID,
            systemPrompt: FactoryAnalysisPrompts.analysisSystem,
            prompt: prompt
          )
          output = try await decodeBatchOutputWithRepair(rawOutput, sourceToken: sessionID)
        }
        return FactoryInitialBatchResult(
          output: output,
          warnings: warnings,
          sessionID: sessionID
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if error is FactoryAnalysisBudgetError {
          // Budget rejection is local, or follows a known completed response
          // too large to repair. It is not an uncertain paid request.
          try? fileManager.removeItem(at: checkpointURL)
          throw error
        }
        // 请求已发出但结果不确定：禁止自动重试，落入保守路径，
        // 避免同一批正文在用户不知情时被重复发送（重复计费）。
        if FactoryAnalysisPipeline.isOutcomeUnknown(error) {
          throw FactoryWorkerError.uncertainPriorRequest(batchIndex + 1)
        }
        guard attempt < 3, FactoryAnalysisPipeline.isSafeToRetry(error) else { throw error }
        warnings.append(
          "第 \(batchIndex + 1) 批第 \(attempt) 次输出不可用，已自动重试。"
        )
        try? fileManager.removeItem(at: checkpointURL)
        // 限流（429）按指数退避 2s/4s 后再重试，避免并发批次瞬时打满配额；
        // 叠加 0–0.5s 随机抖动，防止多个并发批次同步重试再次撞限流
        if case FactoryWorkerError.httpStatus(429, _) = error {
          let backoff = UInt64(2_000_000_000) << UInt64(attempt - 1)
          try await Task.sleep(nanoseconds: backoff &+ UInt64.random(in: 0...500_000_000))
        }
      }
    }
    throw FactoryWorkerError.invalidResponse("批次重试流程异常结束")
  }

  private func completeMissingCoverage(
    _ initialOutput: BatchOutput,
    batch: [FactoryChapterText],
    batchIndex: Int,
    batchCount: Int,
    manifest: FactoryInputManifest,
    cacheURL: URL,
    context: FactoryBatchContext,
    repairsSummaries: Bool
  ) async throws -> (output: BatchOutput, sessionID: String?, warnings: [String], uncertain: Bool) {
    let expectedIDs = batch.map(\.analysisID)
    let expected = Set(expectedIDs)
    var output = initialOutput
    var latestSessionID: String?
    var warnings: [String] = []
    var uncertain = false

    for attempt in 1...2 {
      let actual = Set(output.coveredChapterIDs)
      guard actual.isSubset(of: expected), actual.count == output.coveredChapterIDs.count else {
        throw FactoryWorkerError.incompleteCoverage(
          expected: expected.count,
          actual: output.coveredChapterIDs.count
        )
      }
      let missingCoverage = expected.subtracting(actual)
      let missingSummaries = expected.subtracting(output.chapterSummaries.map(\.chapterID))
      // Summary-only repair is paid work initiated by an explicit continuation,
      // not an extra request tacked onto an otherwise completed first analysis.
      let missingIDs = missingCoverage.union(repairsSummaries ? missingSummaries : [])
      if missingIDs.isEmpty { return (output, latestSessionID, warnings, uncertain) }
      let missingBatch = batch.filter { missingIDs.contains($0.analysisID) }
      let summariesOnly = missingCoverage.isEmpty
      let requestFingerprint = context.runFingerprint + (summariesOnly ? "/summary-repair-v1" : "/coverage-v1")
      let prompt = FactoryAnalysisPrompts.makeBatchPrompt(batch: missingBatch, batchIndex: batchIndex,
        batchCount: batchCount, diversityContext: context.text, summariesOnly: summariesOnly,
        maximumOutputTokens: budget?.output)
      try budget?.validate(system: FactoryAnalysisPrompts.analysisSystem, prompt: prompt)
      let checkpointURL = FactoryAnalysisPipeline.coverageCheckpointURL(
        for: cacheURL,
        attempt: attempt
      )
      do {
        let correction: BatchOutput
        if let checkpoint = try FactoryAnalysisPipeline.loadCheckpoint(
          at: checkpointURL,
          contentHash: manifest.contentHash,
          chapterIDs: missingBatch.map(\.analysisID),
          runFingerprint: requestFingerprint,
          fileManager: fileManager
        ) {
          latestSessionID = checkpoint.sessionID
          guard let recovered = try await transport.recoverInflight(
            checkpointToken: checkpoint.sessionID
          ) else { throw FactoryWorkerError.uncertainPriorRequest(batchIndex + 1) }
          correction = try await decodeBatchOutputWithRepair(
            recovered,
            sourceToken: checkpoint.sessionID
          )
        } else {
          let sessionID = try await transport.beginRequest(
            title: "世界书缺章补全 \(batchIndex + 1)/\(batchCount)-\(attempt)"
          )
          latestSessionID = sessionID
          try FactoryAnalysisPipeline.saveCheckpoint(
            at: checkpointURL,
            contentHash: manifest.contentHash,
            chapterIDs: missingBatch.map(\.analysisID),
            sessionID: sessionID,
            runFingerprint: requestFingerprint,
            fileManager: fileManager
          )
          let rawOutput = try await transport.send(
            checkpointToken: sessionID,
            systemPrompt: FactoryAnalysisPrompts.analysisSystem,
            prompt: prompt
          )
          correction = try await decodeBatchOutputWithRepair(rawOutput, sourceToken: sessionID)
        }

        let normalized = FactoryAnalysisPipeline.normalizeBatchOutput(
          correction,
          batch: missingBatch
        )
        warnings.append(contentsOf: normalized.warnings.map {
          "第 \(batchIndex + 1) 批补全：\($0)"
        })
        try FactoryAnalysisPipeline.validateBatchOutput(
          normalized.output,
          batch: missingBatch,
          requiresProposal: false,
          requiresCompleteCoverage: false
        )
        let covered = Set(output.coveredChapterIDs).union(normalized.output.coveredChapterIDs)
        let newlyCovered = Set(normalized.output.coveredChapterIDs).subtracting(actual)
        // A resumed summary request cannot silently revise accepted candidates
        // or decisions. Only newly analysed units contribute new proposals.
        let additions = normalized.output.proposals.filter {
          $0.evidence.contains { newlyCovered.contains($0.chapterID) }
        }
        let decisionAdditions = normalized.output.decisions.filter {
          $0.evidence.contains { newlyCovered.contains($0.chapterID) }
        }
        let oldSummaryIDs = Set(output.chapterSummaries.map(\.chapterID))
        output = BatchOutput(
          coveredChapterIDs: expectedIDs.filter(covered.contains),
          chapterSummaries: output.chapterSummaries + normalized.output.chapterSummaries.filter {
            covered.contains($0.chapterID) && !oldSummaryIDs.contains($0.chapterID)
          },
          proposals: output.proposals + additions,
          decisions: output.decisions + decisionAdditions
        )
        try FactoryAnalysisPipeline.saveCachedBatch(output, warnings: warnings, at: cacheURL,
          contentHash: manifest.contentHash, chapterIDs: expectedIDs,
          runFingerprint: context.runFingerprint, fileManager: fileManager)
        try? fileManager.removeItem(at: checkpointURL)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if error is FactoryAnalysisBudgetError {
          try? fileManager.removeItem(at: checkpointURL)
          throw error
        }
        if FactoryAnalysisPipeline.isFatalBatchError(error) { throw error }
        if case FactoryWorkerError.uncertainPriorRequest = error { uncertain = true }
        uncertain = uncertain || FactoryAnalysisPipeline.isOutcomeUnknown(error)
        // 结果不确定的错误（断流/看门狗/截断）不自动重发，保留检查点并停止补全
        let reason =
          FactoryAnalysisPipeline.isOutcomeUnknown(error)
          ? "上次请求状态无法确认，已停止自动发送以避免重复扣费"
          : FactoryAnalysisPipeline.safeBatchFailureReason(error)
        warnings.append(
          "第 \(batchIndex + 1) 批第 \(attempt) 次补全未完成（\(reason)）。"
        )
        if FactoryAnalysisPipeline.isSafeToRetry(error) {
          try? fileManager.removeItem(at: checkpointURL)
        }
        if !FactoryAnalysisPipeline.isSafeToRetry(error) { break }
      }
    }
    let missingCount = expected.subtracting(output.coveredChapterIDs).count
    if missingCount > 0 {
      warnings.append("第 \(batchIndex + 1) 批仍有 \(missingCount) 章未覆盖，可稍后继续补全。")
    }
    return (output, latestSessionID, warnings, uncertain)
  }

  /// 本地解码 → 失败时走一次模型辅助修复（两条路径同一套提示词与修复警告）。
  private func decodeBatchOutputWithRepair(
    _ rawOutput: String,
    sourceToken: String
  ) async throws -> BatchOutput {
    do {
      return try ModelBatchOutputContract.decode(rawOutput)
    } catch let localError {
      let prompt = FactoryAnalysisPrompts.makeRepairPrompt(rawOutput: rawOutput, sourceSessionID: sourceToken)
      if let budget, rawOutput.utf16.count > 100_000
        || !budget.fits(system: FactoryAnalysisPrompts.repairSystem, prompt: prompt) {
        throw FactoryAnalysisBudgetError.repairTooLarge
      }
      guard rawOutput.utf16.count <= 100_000 else { throw localError }
      try Task.checkCancellation()
      let repairToken = try await transport.beginRequest(title: "世界书输出格式修复")
      let repairedText = try await transport.send(
        checkpointToken: repairToken,
        systemPrompt: FactoryAnalysisPrompts.repairSystem,
        prompt: prompt
      )
      let repaired = try ModelBatchOutputContract.decode(repairedText)
      return BatchOutput(
        coveredChapterIDs: repaired.coveredChapterIDs,
        chapterSummaries: repaired.chapterSummaries,
        proposals: repaired.proposals,
        decisions: repaired.decisions,
        repairWarnings: ["本批模型输出已由受限模型格式修复会话恢复，并重新通过本地校验。"]
      )
    }
  }
}
