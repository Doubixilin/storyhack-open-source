import Foundation
import LLMProviderKit
import NovelDocumentCore
import WritingCore

public actor BookcaseExtractor {
  private let executor: AdaptationRequestExecutor
  private var runningJobs: Set<UUID> = []
  public init(provider: any LLMProvider, store: AdaptationJobStore = .shared) {
    executor = .init(provider: provider, store: store)
  }

  /// Independent source units retain completed responses. An explicit new run
  /// may retry failed units, while this run sends each unit at most once.
  /// Generated bookcases remain pending until a separate author approval.
  public func extract(jobID: UUID, options: BookcaseExtractionOptions = .init(),
    progress: @escaping @Sendable (BookcaseExtractionReport) async -> Void = { _ in }) async throws -> BookcaseExtractionReport {
    guard runningJobs.insert(jobID).inserted else { throw AdaptationError.staleEdit }
    defer { runningJobs.remove(jobID) }
    let store = executor.store
    let lease = try await store.acquireExecution(jobID)
    defer { lease.release() }
    if let pending = try await store.pendingRequest(jobID) { throw AdaptationRequestError.uncertain(pending) }
    let job = try await store.load(jobID), source = try await store.source(jobID)
    let plan = try BookcaseExtractionPlan(document: source, sourceHash: job.sourceSnapshotHash, options: options, executor: executor)
    let extractorVersion = BookcaseExtractionPlan.version + "/" + plan.fingerprint
    let normalizer = BookcaseBatchNormalizer(document: source, sourceHash: job.sourceSnapshotHash, extractorVersion: extractorVersion)
    var report = BookcaseExtractionReport(sourceSnapshotHash: job.sourceSnapshotHash, planFingerprint: plan.fingerprint,
      selectedChapterIDs: plan.selectedChapterIDs, excludedChapterIDs: plan.excludedChapterIDs, totalUnits: plan.units.count)
    if !plan.options.focusNames.isEmpty { report.warnings.append("按名字/别名逐字命中筛选章节；命中不等于人物实际在场，同名身份需作者核对。") }
    if !plan.excludedChapterIDs.isEmpty { report.warnings.append("本次范围排除了 \(plan.excludedChapterIDs.count) 章；这些章节未纳入书案覆盖。") }
    try await store.saveBookcaseExtractionReport(report, jobID: jobID)
    await progress(report)
    var batches: [BookcaseBatchResult] = []
    do {
      for unit in plan.units {
        try Task.checkCancellation()
        let prompt = BookcaseExtractionPlan.prompt(unit, planFingerprint: plan.fingerprint, focusNames: plan.options.focusNames)
        let identity = try executor.identity(sourceHash: job.sourceSnapshotHash, purpose: BookcaseExtractionPlan.version,
          unitID: unit.id, system: BookcaseExtractionPlan.system, prompt: prompt)
        let response: AdaptationResponseRecord
        do {
          let result = try await executor.response(jobID: jobID, identity: identity, system: BookcaseExtractionPlan.system,
            prompt: prompt, allowNewRequest: report.newRequestCount < plan.options.maximumNewRequests)
          response = result.record
          if result.fromCache { report.cacheHitCount += 1 } else { report.newRequestCount += 1 }
        } catch let error as AdaptationRequestAttemptError {
          report.newRequestCount += 1
          throw error.underlying
        } catch AdaptationExecutionError.requestLimitReached {
          report.gaps.append(.init(unitID: unit.id, chapterID: unit.chapterID, reason: "尚未请求：本次数量上限"))
          continue
        }
        let batch: BookcaseBatchResult
        do { batch = try normalizer.normalize(response.text, unit: unit) }
        catch {
          report.gaps.append(.init(unitID: unit.id, chapterID: unit.chapterID, reason: "回复为空或 JSON/资产结构无效"))
          try await store.rejectCompletedResponse(response, reason: "invalid-bookcase-schema")
          try await store.saveBookcaseExtractionReport(report, jobID: jobID)
          await progress(report)
          continue
        }
        batches.append(batch)
        if batch.complete { report.completedUnitIDs.append(unit.id) }
        else {
          let reason = "丢弃 \(batch.discardedCount) 项无效资产；" + (batch.bookcase.chapters.isEmpty ? "缺少有效章节摘要" : "有效部分已保留")
          report.gaps.append(.init(unitID: unit.id, chapterID: unit.chapterID, reason: reason))
          try await store.rejectCompletedResponse(response, reason: reason)
        }
        try await store.saveBookcaseExtractionReport(report, jobID: jobID)
        await progress(report)
      }
      try Task.checkCancellation()
      let assembled = try assemble(batches: batches, plan: plan, source: source, sourceHash: job.sourceSnapshotHash,
        extractorVersion: extractorVersion, report: &report)
      if !assembled.chapters.isEmpty || !assembled.characters.isEmpty || !assembled.worldRules.isEmpty {
        let digest = try AdaptationCoding.fingerprint(assembled)
        let proposalID = try uuid(digest)
        let proposal = try await store.proposeBookcase(assembled, jobID: jobID, expectedRevision: job.revision, proposalID: proposalID)
        report.proposalID = proposal.id
      }
      report.stage = report.gaps.isEmpty ? .completed : .partial
      report = try await store.retainingApprovedManualCards(report, jobID: jobID)
      try await store.saveBookcaseExtractionReport(report, jobID: jobID)
      await progress(report)
      return report
    } catch {
      let pending = try? await store.pendingRequest(jobID)
      report.stage = error is CancellationError ? .cancelled : (pending != nil ? .awaitingConfirmation : .failed)
      report.warnings.append(error is CancellationError ? "已取消；完成批次保留，未确认请求仍需核对。" : "本次执行已停止；完成批次保留，请核对状态后继续。")
      try await store.saveBookcaseExtractionReport(report, jobID: jobID)
      await progress(report)
      throw error
    }
  }

  private func assemble(batches: [BookcaseBatchResult], plan: BookcaseExtractionPlan, source: NovelDocument,
    sourceHash: String, extractorVersion: String, report: inout BookcaseExtractionReport) throws -> NovelBookcase {
    var bookcase = NovelBookcase(meta: .init(sourceSnapshotHash: sourceHash, extractorVersion: extractorVersion),
      characters: batches.flatMap { $0.bookcase.characters }, relationships: batches.flatMap { $0.bookcase.relationships },
      worldRules: batches.flatMap { $0.bookcase.worldRules })
    let byChapter = Dictionary(grouping: batches, by: { $0.unit.chapterID })
    let planned = Dictionary(grouping: plan.units, by: \.chapterID)
    for original in source.chapters where plan.selectedChapterIDs.contains(original.id) {
      if original.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        bookcase.chapters.append(.init(chapterID: original.id, summary: "本章没有正文。", evidence: []))
        continue
      }
      let parts = (byChapter[original.id] ?? []).sorted { $0.unit.offset < $1.unit.offset }
      guard parts.count == planned[original.id]?.count, parts.allSatisfy(\.complete) else { continue }
      let chapters = parts.flatMap { $0.bookcase.chapters }
      let combined = BookcaseChapter(chapterID: original.id,
        summary: chapters.map(\.summary).joined(separator: "\n"),
        moments: chapters.flatMap(\.moments), evidence: chapters.flatMap(\.evidence))
      do {
        let referencedIDs = Set(combined.moments.flatMap(\.involvedCharacterIDs))
        _ = try NovelBookcase(meta: bookcase.meta,
          characters: bookcase.characters.filter { referencedIDs.contains($0.id) }, chapters: [combined])
          .validated(in: source, snapshotHash: sourceHash)
        bookcase.chapters.append(combined)
      } catch {
        report.gaps.append(.init(unitID: original.id + "-assembly", chapterID: original.id,
          reason: "分段汇总超过书案限制；片段缓存保留，请调整分段大小或模型窗口后继续。"))
      }
    }
    let names = Dictionary(grouping: bookcase.characters, by: \.name).filter { $0.value.count > 1 }
    if !names.isEmpty {
      report.warnings.append("有 \(names.count) 组同名人物卡跨片段重复。它们保留独立来源 ID，请作者确认身份及合并；未自动按名字归并。")
    }
    bookcase = try bookcase.validated(in: source, snapshotHash: sourceHash)
    return bookcase
  }

  private func uuid(_ hash: String) throws -> UUID {
    let text = String(hash.prefix(32)), lengths = [8, 4, 4, 4, 12]
    var start = text.startIndex, parts: [String] = []
    for length in lengths {
      let end = text.index(start, offsetBy: length); parts.append(String(text[start..<end])); start = end
    }
    guard let id = UUID(uuidString: parts.joined(separator: "-")) else { throw AdaptationError.invalidBookcase }
    return id
  }
}
