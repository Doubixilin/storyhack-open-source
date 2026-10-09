import Foundation
import LibraryCore
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore
import Testing

@testable import StoryworldFactory

struct StoryworldFactoryTests {
  #if os(macOS)
    @Test
    func exactEvidenceQuoteRepairsOnlyLiteralSentenceFragments() {
      let chapter = "另外短短二十年。\n\n喝喝茶，听听曲，修为也到了所有人未知的高度。"

      #expect(
        ExactEvidenceQuote.canonicalQuote(
          "短短二十年。喝喝茶，听听曲，修为也到了所有人未知的高度。",
          in: chapter,
          maximumLength: 80
        ) == "喝喝茶，听听曲，修为也到了所有人未知的高度。"
      )
      #expect(
        ExactEvidenceQuote.canonicalQuote(
          "修为已经到了无人知晓的高度。",
          in: chapter,
          maximumLength: 80
        ) == nil
      )

      let longQuote = String(repeating: "甲", count: 90)
      let longChapter = "前文\(longQuote)后文"
      let canonical = ExactEvidenceQuote.canonicalQuote(
        longQuote,
        in: longChapter,
        maximumLength: 80
      )
      #expect(canonical?.count == 80)
      #expect(canonical.map { longChapter.contains($0) } == true)
      #expect(canonical.map { longQuote.contains($0) } == true)
    }

    @Test
    func modelJSONRepairOnlyEscapesStringContent() throws {
      let invalid = #"{"content":"她自称"是保护不是跟踪"。","value":"ok"}"#
      let repaired = try #require(ModelJSONRepair.repairingUnescapedStringContent(invalid))
      let object = try #require(
        try JSONSerialization.jsonObject(with: repaired) as? [String: String]
      )

      #expect(object["content"] == "她自称\"是保护不是跟踪\"。")
      #expect(object["value"] == "ok")
      #expect(ModelJSONRepair.repairingUnescapedStringContent(#"{"value":"ok"}"#) == nil)

      let escapedTerminator = #"[{"quote":"原文句子。\"},{"quote":"下一句"}]"#
      let repairedTerminator = try #require(
        ModelJSONRepair.repairingUnescapedStringContent(escapedTerminator)
      )
      let array = try #require(
        try JSONSerialization.jsonObject(with: repairedTerminator) as? [[String: String]]
      )
      #expect(array.map { $0["quote"] } == ["原文句子。", "下一句"])
    }

    @Test
    func modelBatchContractDefaultsMissingArraysAndExtractsCodeFence() throws {
      let missingDecisions = """
        {"covered_chapter_ids":["chapter-1"],"proposals":[]}
        """
      let summary = try ModelBatchOutputContract.summary(from: missingDecisions)
      #expect(summary.coveredChapterCount == 1)
      #expect(summary.proposalCount == 0)
      #expect(summary.decisionCount == 0)

      let fenced = """
        这是修复结果：
        ```json
        {"covered_chapter_ids":[],"proposals":[],"decisions":[]}
        ```
        """
      let fencedSummary = try ModelBatchOutputContract.summary(from: fenced)
      #expect(fencedSummary == FactoryBatchContractSummary(
        coveredChapterCount: 0,
        proposalCount: 0,
        decisionCount: 0
      ))
    }

    @Test
    func bareObjectEvidenceDecodesToSingleEntryAndStillRequiresExactAnchor() throws {
      // 真实模型曾把单条 evidence 写成裸对象，导致有效证据被静默清空、整批候选丢失。
      let raw = """
        {"covered_chapter_ids":["chapter-000001"],
        "chapter_summaries":[{"chapter_id":"chapter-000001","summary":"本章摘要"}],
        "proposals":[{"kind":"character","title":"灯塔守望员","content":"守望员守时如钟。",
        "activation_keys":["灯塔"],"always_active":false,
        "evidence":{"chapter_id":"chapter-000001","quote":"雾夜必须点灯"}}],
        "decisions":[{"question":"是否离塔？","recommendation":"不离塔","rationale":"规则","impact":"安全",
        "evidence":{"chapter_id":"chapter-000001","quote":"守望员不得离塔过夜"}}]}
        """
      let output = try ModelBatchOutputContract.decode(raw)
      #expect(output.proposals.count == 1 && output.proposals[0].evidence.count == 1)
      #expect(output.decisions.count == 1 && output.decisions[0].evidence.count == 1)
      let snapshot = FactoryChapterSnapshot(
        id: "chapter-000001", ordinal: 1, title: "第一章", relativePath: "chapters/000001.txt",
        utf16Length: 26)
      let chapters = [FactoryChapterText(
        descriptor: snapshot, analysisID: "chapter-000001",
        text: "规则写在手册首页：雾夜必须点灯，守望员不得离塔过夜。",
        fullText: "规则写在手册首页：雾夜必须点灯，守望员不得离塔过夜。",
        utf16Offset: 0, segmentIndex: 1, segmentCount: 1)]
      let normalized = FactoryAnalysisPipeline.normalizeBatchOutput(output, batch: chapters)
      #expect(normalized.output.proposals.count == 1)
      #expect(normalized.output.decisions.count == 1)
      // 引文锚不回原文时，形态归一不能替代逐字校验。
      let hallucinated = """
        {"covered_chapter_ids":["chapter-000001"],
        "proposals":[{"kind":"character","title":"守望员","content":"内容",
        "activation_keys":[],"always_active":false,
        "evidence":{"chapter_id":"chapter-000001","quote":"原文里没有这句话"}}],
        "decisions":[]}
        """
      let badOutput = try ModelBatchOutputContract.decode(hallucinated)
      let badNormalized = FactoryAnalysisPipeline.normalizeBatchOutput(badOutput, batch: chapters)
      #expect(badNormalized.output.proposals.isEmpty)
    }

    @Test
    func oversizedChapterIsSplitIntoBoundedTraceableAnalysisUnits() async throws {
      let root = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = FactoryJobStore(rootURL: root.appendingPathComponent("factory", isDirectory: true))
      let longText = (0..<1_500).map { "第\($0)段正文，包含可定位的原文。" }.joined(separator: "\n")
      let document = NovelDocument(
        id: UUID(),
        title: "超长单章",
        sourceFormat: .text,
        sourceFileName: "超长单章.txt",
        contentHash: String(repeating: "a", count: 64),
        chapters: [
          NovelChapter(id: "empty", ordinal: 0, title: "空目录", content: ""),
          NovelChapter(id: "long", ordinal: 1, title: "正文", content: longText),
        ]
      )
      let job = try await store.create(document: document)
      let manifest = try await store.inputManifest(job.id)
      let snapshot = try await store.workspaceURL(jobID: job.id, relativePath: "input")

      let summary = try FactoryAnalysisPipeline.inspectAnalysisPlan(
        manifest: manifest,
        snapshotURL: snapshot,
        maximumBatchUTF16Length: 10_000
      )

      #expect(summary.sourceChapterCount == 2)
      #expect(summary.emptyChapterCount == 1)
      #expect(summary.segmentedChapterCount == 1)
      #expect(summary.analysisUnitCount > 1)
      #expect(summary.maximumUnitUTF16Length <= 10_000)
      #expect(summary.warnings.count == 2)
    }

    @Test
    func segmentedEvidenceResolvesAgainstOriginalChapter() throws {
      let prefix = String(repeating: "前文。", count: 80)
      let quote = "后段证据原文。"
      let segment = "分段开头。\n\(quote)\n分段结尾。"
      let fullText = prefix + segment
      let chapter = NovelChapter(
        id: "chapter-1",
        ordinal: 0,
        title: "正文",
        content: fullText
      )
      let document = NovelDocument(
        id: UUID(),
        title: "分段锚点测试",
        sourceFormat: .text,
        sourceFileName: "分段锚点测试.txt",
        contentHash: String(repeating: "b", count: 64),
        chapters: [chapter]
      )
      let manifest = FactoryInputManifest(document: document)
      let descriptor = try #require(manifest.chapters.first)

      let builtEvidence = try AnalysisUnitEvidenceBuilder.make(
        manifest: manifest,
        descriptor: descriptor,
        fullText: fullText,
        segmentText: segment,
        segmentUTF16Offset: prefix.utf16.count,
        rawQuote: quote
      )
      let evidence = try #require(builtEvidence)

      #expect(evidence.anchor.chapterID == chapter.id)
      #expect(try evidence.anchor.resolve(in: document) == quote)
    }

    @Test
    func malformedRealFactorySnapshotPlanWhenExplicitlyConfigured() async throws {
      guard let jobPath = ProcessInfo.processInfo.environment["WORLDBOOK_FACTORY_PLAN_JOB_ROOT"]
      else { return }
      let jobURL = URL(fileURLWithPath: jobPath, isDirectory: true)
      let manifest = try JSONDecoder().decode(
        FactoryInputManifest.self,
        from: Data(contentsOf: jobURL.appendingPathComponent("input/manifest.json"))
      )
      let summary = try FactoryAnalysisPipeline.inspectAnalysisPlan(
        manifest: manifest,
        snapshotURL: jobURL.appendingPathComponent("input", isDirectory: true),
        maximumBatchUTF16Length: 50_000
      )

      #expect(summary.emptyChapterCount > 0)
      #expect(summary.segmentedChapterCount > 0)
      #expect(summary.maximumUnitUTF16Length <= 50_000)
    }
  #endif

  @Test
  func storePersistsSnapshotAndRecoversInterruptedTask() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FactoryJobStore(rootURL: root)
    let document = fixtureDocument()

    var job = try await store.create(document: document)
    let manifest = try await store.inputManifest(job.id)
    #expect(manifest.contentHash == document.contentHash)
    #expect(manifest.chapters.map(\.id) == document.chapters.map(\.id))

    job.stage = .analyzing
    job.progress = 0.4
    try await store.save(job)
    let liveLease = try store.acquireOperation(job.id)
    #expect(try await store.recoverInterruptedJobs().isEmpty)
    #expect(try await store.load(job.id).stage == .analyzing)
    liveLease.release()
    let recovered = try await store.recoverInterruptedJobs()
    let loaded = try await store.load(job.id)

    #expect(recovered.map(\.id) == [job.id])
    #expect(loaded.stage == .failed)
    #expect(loaded.failure?.category == .interrupted)
    #expect(loaded.failure?.retryable == true)
  }

  @Test
  func legacyBridgeNamedJobJSONStillDecodes() throws {
    // 波次 3 之前的存量 .factoryjob 使用旧桥接层命名字段，必须能正常解码。
    let legacyJSON = """
      {
        "schemaVersion": 1,
        "id": "5F7E57D4-9A0A-4A6B-9F33-9E0D7B1E2A01",
        "documentID": "6F7E57D4-9A0A-4A6B-9F33-9E0D7B1E2A02",
        "sourceName": "旧任务.txt",
        "sourceFormat": "txt",
        "sourceTitle": "旧任务",
        "sourceContentHash": "deadbeef",
        "sourceSnapshotRelativePath": "input",
        "bridgeProtocolVersion": 1,
        "inputSchemaVersion": 1,
        "outputSchemaVersion": 1,
        "openCodeVersion": "1.18.16",
        "openCodeSessionID": "session-legacy",
        "stage": "waiting_for_user",
        "progress": 0.82,
        "retryCount": 1,
        "createdAt": "2026-08-11T08:00:00Z",
        "updatedAt": "2026-08-11T09:00:00Z"
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let job = try decoder.decode(FactoryJob.self, from: Data(legacyJSON.utf8))

    #expect(job.executorProtocolVersion == 1)
    #expect(job.executorVersion == "1.18.16")
    #expect(job.executorSessionID == "session-legacy")
    #expect(job.stage == .waitingForUser)
    #expect(job.retryCount == 1)

    // 重新编码后只写新字段名，旧 key 不再出现。
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let reencoded = try #require(
      String(data: try encoder.encode(job), encoding: .utf8)
    )
    #expect(reencoded.contains("\"executorVersion\""))
    #expect(reencoded.contains("\"executorSessionID\""))
    #expect(reencoded.contains("\"executorProtocolVersion\""))
    #expect(!reencoded.contains("openCode"))
    #expect(!reencoded.contains("bridgeProtocolVersion"))
  }

  @Test
  func coordinatorCompletesDecisionCandidateValidationAndAtomicPublish() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("测试小说.txt")
    try Data("第一章 初见\n主角林舟在雨夜抵达青石镇。\n第二章 决定\n林舟决定留下调查旧塔。".utf8)
      .write(to: sourceURL)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library", isDirectory: true))
    let storyworldLibrary = StoryworldLibrary(
      rootURL: root.appendingPathComponent("storyworlds", isDirectory: true)
    )
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("factory", isDirectory: true))
    let record = try await library.importDocument(from: sourceURL)
    let coordinator = FactoryCoordinator(
      library: library,
      storyworldLibrary: storyworldLibrary,
      store: store,
      worker: ScriptedWorker()
    )

    let created = try await coordinator.createJob(documentID: record.id)
    try await coordinator.startAnalysis(jobID: created.id)
    var job = try await store.load(created.id)
    #expect(job.stage == .waitingForUser)
    #expect(job.executorVersion == "test-worker")

    let decisions = try await store.decisions(created.id)
    #expect(decisions.count == 1)
    try await coordinator.acceptAllRecommendations(jobID: created.id)
    try await coordinator.reopenDecision(decisionID: decisions[0].id, jobID: created.id)
    let reopened = try await store.decisions(created.id)
    #expect(reopened[0].resolution == .unanswered)
    #expect(reopened[0].answer == nil)
    try await coordinator.acceptRecommendation(decisionID: decisions[0].id, jobID: created.id)
    try await coordinator.generateCandidate(jobID: created.id)
    job = try await store.load(created.id)
    #expect(job.stage == .readyToPublish)
    #expect(try await store.validation(created.id)?.lorebookEntryCount == 2)
    #expect(try await store.preview(created.id)?.newEntryTitles == ["林舟"])

    let published = try await coordinator.publish(jobID: created.id)
    job = try await store.load(created.id)
    let associated = try await storyworldLibrary.listAssociated(
      with: .init(documentID: record.id, contentHash: record.document.contentHash)
    )
    #expect(job.stage == .completed)
    #expect(job.publishedStoryworldID == published.id)
    #expect(associated.map(\.id) == [published.id])
    let document = try await storyworldLibrary.load(storyworldID: published.id)
    #expect(document.lorebook.entries.contains { $0.title.hasPrefix("待核对决策") && !$0.alwaysActive })
    #expect(!document.lorebook.entries.contains { $0.id == "factory-decisions" })
  }

  @Test
  func partialAnalysisCanGenerateAndPublishWithWarnings() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("部分覆盖.txt")
    try Data("第一章 初见\n林舟来到青石镇。\n第二章 留下\n林舟决定留下。".utf8).write(to: sourceURL)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library", isDirectory: true))
    let storyworldLibrary = StoryworldLibrary(
      rootURL: root.appendingPathComponent("storyworlds", isDirectory: true)
    )
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("factory", isDirectory: true))
    let record = try await library.importDocument(from: sourceURL)
    let coordinator = FactoryCoordinator(
      library: library,
      storyworldLibrary: storyworldLibrary,
      store: store,
      worker: ProgressiveWorker()
    )

    let job = try await coordinator.createJob(documentID: record.id)
    try await coordinator.startAnalysis(jobID: job.id)
    let analysis = try #require(try await store.analysis(job.id))
    #expect(analysis.coveredChapterIDs.count == 1)
    #expect(!analysis.warnings.isEmpty)

    try await coordinator.acceptAllRecommendations(jobID: job.id)
    try await coordinator.generateCandidate(jobID: job.id)
    let validation = try #require(try await store.validation(job.id))
    #expect(Set(analysis.warnings).isSubset(of: Set(validation.warnings)))
    #expect(validation.warnings.contains { $0.contains("主线摘要完整 0/2 章") })
    let prepared = try await store.load(job.id)
    let candidatePath = try #require(prepared.candidatePackageRelativePath)
    let candidateURL = try await store.workspaceURL(jobID: job.id, relativePath: candidatePath)
    let provenance = try StoryworldCoding.makeDecoder().decode(
      FactoryCandidateProvenance.self,
      from: Data(
        contentsOf: candidateURL.appendingPathComponent("factory/provenance.json")
      )
    )
    #expect(provenance.coveredChapterIDs == analysis.coveredChapterIDs)
    #expect(provenance.warnings == analysis.warnings)
    _ = try await coordinator.publish(jobID: job.id)
    #expect(try await store.load(job.id).stage == .completed)
  }

  @Test
  func supplementPreservesAnswersAndCompletesMissingCoverage() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("继续补全.txt")
    try Data("第一章 初见\n林舟来到青石镇。\n第二章 留下\n林舟决定留下。".utf8).write(to: sourceURL)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library", isDirectory: true))
    let storyworldLibrary = StoryworldLibrary(
      rootURL: root.appendingPathComponent("storyworlds", isDirectory: true)
    )
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("factory", isDirectory: true))
    let record = try await library.importDocument(from: sourceURL)
    let worker = ProgressiveWorker()
    let coordinator = FactoryCoordinator(
      library: library,
      storyworldLibrary: storyworldLibrary,
      store: store,
      worker: worker
    )

    let job = try await coordinator.createJob(documentID: record.id)
    try await coordinator.startAnalysis(jobID: job.id)
    try await coordinator.acceptAllRecommendations(jobID: job.id)
    try await coordinator.supplementAnalysis(jobID: job.id)

    let analysis = try #require(try await store.analysis(job.id))
    let decisions = try await store.decisions(job.id)
    #expect(analysis.coveredChapterIDs == record.document.chapters.map(\.id))
    #expect(decisions.count == 1)
    #expect(decisions.first?.resolution == .acceptedRecommendation)
    #expect(decisions.first?.answer == decisions.first?.recommendation)
    #expect(await worker.analysisCount() == 2)
  }

  @Test
  func supplementKeepsDifferentAnswersSeparateAndLeavesNewRecommendationUnanswered() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("决策继承.txt")
    try Data("第一章 初见\n林舟来到青石镇。\n第二章 留下\n林舟决定留下。".utf8).write(to: sourceURL)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library"))
    let worlds = StoryworldLibrary(rootURL: root.appendingPathComponent("worlds"))
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("factory"))
    let record = try await library.importDocument(from: sourceURL)
    let coordinator = FactoryCoordinator(library: library, storyworldLibrary: worlds,
      store: store, worker: ProgressiveWorker(conflictingRecommendations: true))
    let job = try await coordinator.createJob(documentID: record.id)
    try await coordinator.startAnalysis(jobID: job.id)
    let before = try await store.decisions(job.id)
    let accepted = try #require(before.first { $0.recommendation.hasPrefix("是") })
    let customized = try #require(before.first { $0.recommendation.hasPrefix("否") })
    try await coordinator.acceptRecommendation(decisionID: accepted.id, jobID: job.id)
    try await coordinator.answerDecision(decisionID: customized.id, jobID: job.id, answer: "从港口出发。")
    try await coordinator.supplementAnalysis(jobID: job.id)
    let after = try await store.decisions(job.id)
    #expect(after.count == 3)
    let same = try #require(after.first { $0.recommendation == accepted.recommendation })
    let custom = try #require(after.first { $0.recommendation == customized.recommendation })
    let added = try #require(after.first { $0.recommendation.hasPrefix("新增") })
    #expect(same.resolution == .acceptedRecommendation && same.answer == accepted.recommendation)
    #expect(custom.resolution == .customAnswer && custom.answer == "从港口出发。")
    #expect(added.resolution == .unanswered && added.answer == nil && added.resolvedAt == nil)
  }

  @Test
  func failedSupplementKeepsUsableAnalysisAndAcceptedAnswers() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("补全失败.txt")
    try Data("第一章 初见\n林舟来到青石镇。\n第二章 留下\n林舟决定留下。".utf8).write(to: sourceURL)
    let library = NovelLibrary(rootURL: root.appendingPathComponent("library", isDirectory: true))
    let storyworldLibrary = StoryworldLibrary(
      rootURL: root.appendingPathComponent("storyworlds", isDirectory: true)
    )
    let store = FactoryJobStore(rootURL: root.appendingPathComponent("factory", isDirectory: true))
    let record = try await library.importDocument(from: sourceURL)
    let coordinator = FactoryCoordinator(
      library: library,
      storyworldLibrary: storyworldLibrary,
      store: store,
      worker: ProgressiveWorker(failsOnSupplement: true)
    )

    let job = try await coordinator.createJob(documentID: record.id)
    try await coordinator.startAnalysis(jobID: job.id)
    try await coordinator.acceptAllRecommendations(jobID: job.id)
    try await coordinator.supplementAnalysis(jobID: job.id)

    let restoredJob = try await store.load(job.id)
    let analysis = try #require(try await store.analysis(job.id))
    let decisions = try await store.decisions(job.id)
    #expect(restoredJob.stage == .waitingForUser)
    #expect(restoredJob.failure == nil)
    #expect(analysis.coveredChapterIDs.count == 1)
    #expect(analysis.warnings.contains { $0.contains("现有结果仍可继续使用") })
    #expect(decisions.first?.resolution == .acceptedRecommendation)
  }

  @Test
  func factoryAnalysisDecodesLegacyFilesWithoutWarnings() throws {
    let json = """
      {
        "schemaVersion": 1,
        "sourceContentHash": "legacy-hash",
        "coveredChapterIDs": [],
        "proposals": [],
        "decisions": []
      }
      """
    let analysis = try JSONDecoder().decode(FactoryAnalysis.self, from: Data(json.utf8))
    #expect(analysis.warnings.isEmpty)
  }

  @Test
  func seedFactoryUIFixtureWhenExplicitRootsAreConfigured() async throws {
    guard let libraryPath = ProcessInfo.processInfo.environment["WORLDBOOK_UI_SEED_LIBRARY_ROOT"],
      let factoryPath = ProcessInfo.processInfo.environment["WORLDBOOK_UI_SEED_FACTORY_ROOT"]
    else { return }
    let library = NovelLibrary(rootURL: URL(fileURLWithPath: libraryPath, isDirectory: true))
    let records = try await library.list()
    let summary = try #require(records.first)
    let record = try await library.load(documentID: summary.id)
    let chapter = try #require(record.document.chapters.first)
    let excerpt = String(chapter.content.prefix(24))
    let range = (chapter.content as NSString).range(of: excerpt)
    let anchor = try TextAnchor(
      document: record.document,
      chapter: chapter,
      range: .init(location: range.location, length: range.length)
    )
    let evidence = FactoryEvidence(
      chapterTitle: chapter.title,
      anchor: anchor,
      excerpt: excerpt
    )
    let store = FactoryJobStore(rootURL: URL(fileURLWithPath: factoryPath, isDirectory: true))
    var job = try await store.create(document: record.document)
    let analysis = FactoryAnalysis(
      sourceContentHash: record.document.contentHash,
      coveredChapterIDs: record.document.chapters.map(\.id),
      proposals: [
        FactoryLoreProposal(
          id: "character-demo",
          kind: .character,
          title: "陈怀安",
          content: "UI 验收候选：真实生成时由全文分析替换。",
          activationKeys: ["陈怀安"],
          evidence: [evidence]
        )
      ],
      decisions: [
        FactoryDecision(
          jobID: job.id,
          question: "是否把主角进入新世界的初始处境设为开局背景？",
          recommendation: "作为常驻背景，但不替玩家预设后续选择。",
          rationale: "用于验证决策卡、接受全部和发布交互。",
          impact: "影响世界书开局提示。",
          evidence: [evidence]
        )
      ]
    )
    try await store.saveAnalysis(analysis, jobID: job.id)
    job.stage = .waitingForUser
    job.progress = 0.82
    job.executorVersion = "1.18.16"
    job.updatedAt = Date()
    try await store.save(job)
  }

  private func fixtureDocument() -> NovelDocument {
    NovelDocument(
      id: UUID(),
      title: "测试小说",
      sourceFormat: .text,
      sourceFileName: "测试小说.txt",
      contentHash: String(repeating: "e", count: 64),
      chapters: [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: "第一章", content: "林舟来到青石镇。"),
        NovelChapter(id: "chapter-000002", ordinal: 1, title: "第二章", content: "林舟决定留下。"),
      ]
    )
  }

  private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private struct ScriptedWorker: FactoryAnalysisWorker {
  func analyze(
    jobID: UUID,
    manifest: FactoryInputManifest,
    snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void
  ) async throws -> FactoryWorkerResult {
    let first = try #require(manifest.chapters.first)
    let text = try String(
      contentsOf: snapshotURL.appendingPathComponent(first.relativePath), encoding: .utf8)
    let chapter = NovelChapter(
      id: first.id,
      ordinal: first.ordinal,
      title: first.title,
      content: text
    )
    let document = NovelDocument(
      id: manifest.documentID,
      title: manifest.title,
      sourceFormat: NovelSourceFormat(rawValue: manifest.sourceFormat.rawValue) ?? .text,
      sourceFileName: manifest.sourceFileName,
      contentHash: manifest.contentHash,
      chapters: [chapter]
    )
    let anchor = try TextAnchor(
      document: document,
      chapter: chapter,
      range: .init(location: 0, length: min(4, text.utf16.count))
    )
    let evidence = FactoryEvidence(
      chapterTitle: first.title,
      anchor: anchor,
      excerpt: String(text.prefix(4))
    )
    await progress(.init(fraction: 1, executorVersion: "test-worker", sessionID: "test-session"))
    return FactoryWorkerResult(
      analysis: FactoryAnalysis(
        sourceContentHash: manifest.contentHash,
        coveredChapterIDs: manifest.chapters.map(\.id),
        proposals: [
          FactoryLoreProposal(
            id: "character-linzhou",
            kind: .character,
            title: "林舟",
            content: "主角，来到青石镇并调查旧塔。",
            activationKeys: ["林舟"],
            evidence: [evidence]
          )
        ],
        decisions: [
          FactoryDecision(
            jobID: jobID,
            question: "工坊是否把旧塔作为开局主线？",
            recommendation: "是，作为可选调查线索。",
            rationale: "原文明确写到主角留下调查旧塔。",
            impact: "影响初始可用剧情钩子。",
            evidence: [evidence]
          )
        ]
      ),
      executorVersion: "test-worker",
      sessionID: "test-session"
    )
  }

  func cancel(jobID _: UUID) async {}
}

private actor ProgressiveWorker: FactoryAnalysisWorker {
  private var count = 0
  private let failsOnSupplement: Bool
  private let conflictingRecommendations: Bool

  init(failsOnSupplement: Bool = false, conflictingRecommendations: Bool = false) {
    self.failsOnSupplement = failsOnSupplement
    self.conflictingRecommendations = conflictingRecommendations
  }

  func analyze(
    jobID: UUID,
    manifest: FactoryInputManifest,
    snapshotURL: URL,
    progress: @escaping @Sendable (FactoryWorkerProgress) async -> Void
  ) async throws -> FactoryWorkerResult {
    count += 1
    if failsOnSupplement, count > 1 {
      throw FactoryWorkerError.sessionFailed("test supplement failure")
    }
    let first = try #require(manifest.chapters.first)
    let text = try String(
      contentsOf: snapshotURL.appendingPathComponent(first.relativePath), encoding: .utf8)
    let chapter = NovelChapter(
      id: first.id,
      ordinal: first.ordinal,
      title: first.title,
      content: text
    )
    let document = NovelDocument(
      id: manifest.documentID,
      title: manifest.title,
      sourceFormat: NovelSourceFormat(rawValue: manifest.sourceFormat.rawValue) ?? .text,
      sourceFileName: manifest.sourceFileName,
      contentHash: manifest.contentHash,
      chapters: [chapter]
    )
    let anchor = try TextAnchor(
      document: document,
      chapter: chapter,
      range: .init(location: 0, length: min(4, text.utf16.count))
    )
    let evidence = FactoryEvidence(
      chapterTitle: first.title,
      anchor: anchor,
      excerpt: String(text.prefix(4))
    )
    let isFirstPass = count == 1
    let recommendations = conflictingRecommendations
      ? ["是，作为可选开局地点。", "否，从另一处地点出发。"] + (isFirstPass ? [] : ["新增推荐：由玩家指定。"])
      : ["是，作为可选开局地点。"]
    await progress(.init(fraction: 1, executorVersion: "progressive-worker"))
    return FactoryWorkerResult(
      analysis: FactoryAnalysis(
        sourceContentHash: manifest.contentHash,
        coveredChapterIDs: isFirstPass ? [first.id] : manifest.chapters.map(\.id),
        proposals: [
          FactoryLoreProposal(
            id: "character-linzhou",
            kind: .character,
            title: "林舟",
            content: "主角来到青石镇。",
            activationKeys: ["林舟"],
            evidence: [evidence]
          )
        ],
        decisions: recommendations.map { recommendation in
          FactoryDecision(
            jobID: jobID,
            question: "是否把青石镇作为开局地点？",
            recommendation: recommendation,
            evidence: [evidence]
          )
        },
        warnings: isFirstPass ? ["当前结果覆盖 1/2 章，可直接使用或继续补全。"] : []
      ),
      executorVersion: "progressive-worker"
    )
  }

  func cancel(jobID _: UUID) async {}

  func analysisCount() -> Int { count }
}

// MARK: - 节拍线生成（M3b）

struct TimelineGenerationTests {
  private func makeDocument() -> NovelDocument {
    NovelDocument(
      id: UUID(),
      title: "测试书",
      sourceFormat: .text,
      sourceFileName: "test.txt",
      contentHash: "hash",
      chapters: [
        NovelChapter(id: "c1", ordinal: 0, title: "第一回 风起", content: "风起了。"),
        NovelChapter(id: "c2", ordinal: 1, title: "第二回 宴起", content: "大宴开场。"),
        NovelChapter(id: "c3", ordinal: 2, title: "第三回 决战", content: "谷中决战。"),
      ]
    )
  }

  private func evidence(chapter: NovelChapter, document: NovelDocument) -> FactoryEvidence {
    FactoryEvidence(
      chapterTitle: chapter.title,
      anchor: TextAnchor(
        contentHash: document.contentHash,
        chapterID: chapter.id,
        range: .init(location: 0, length: 1)
      ),
      excerpt: String(chapter.content.prefix(1))
    )
  }

  @Test
  func timelineBuilderOrdersBeatsByEvidenceChapter() throws {
    let document = makeDocument()
    func proposal(_ title: String, chapter: NovelChapter) -> FactoryLoreProposal {
      FactoryLoreProposal(
        id: "p-\(title)",
        kind: .timeline,
        title: title,
        content: "\(title)的详细描述。\n第二行。",
        activationKeys: [title, "别名"],
        evidence: [evidence(chapter: chapter, document: document)]
      )
    }
    let analysis = FactoryAnalysis(
      sourceContentHash: document.contentHash,
      coveredChapterIDs: document.chapters.map(\.id),
      proposals: [
        proposal("决战绝情谷", chapter: document.chapters[2]),
        FactoryLoreProposal(id: "pc", kind: .character, title: "某人", content: "人物。"),
        proposal("官道启程", chapter: document.chapters[0]),
      ],
      decisions: []
    )

    let timeline = try #require(
      FactoryTimelineBuilder.makeTimeline(analysis: analysis, document: document)
    )
    #expect(timeline.source == "factory")
    #expect(timeline.beats.map(\.title) == ["官道启程", "决战绝情谷"])
    #expect(timeline.beats.map(\.order) == [1, 2])
    #expect(timeline.beats.map(\.id) == ["beat-01", "beat-02"])
    #expect(timeline.beats.first?.keywords == ["官道启程", "别名"])
    #expect(timeline.beats.first?.summary == "官道启程的详细描述。")

    let noTimeline = FactoryAnalysis(
      sourceContentHash: "h",
      coveredChapterIDs: [],
      proposals: [FactoryLoreProposal(id: "pc", kind: .character, title: "某人", content: "。")],
      decisions: []
    )
    #expect(FactoryTimelineBuilder.makeTimeline(analysis: noTimeline, document: document) == nil)
  }

  @Test
  func extractorChunksParsesAndMerges() async throws {
    let document = makeDocument()

    // 分块：上限压小后每章一批
    let chunks = StoryTimelineExtractor.makeChunks(document: document, maxCharacters: 40)
    #expect(chunks.count == 3)

    // 解析：容忍前后杂质，章节标题映射回章节序，未知章节回退本批首章
    let parsed = try StoryTimelineExtractor.parseBeats(
      from: """
        好的，结果如下：
        {"beats":[
          {"title":"英雄大宴","summary":"丐帮换帮主","chapter":"第二回 宴起","keywords":["陆家庄"]},
          {"title":"  ","summary":"无效"},
          {"title":"后续之战","summary":"谷中决战","chapter":"不存在的章节","keywords":[]}
        ]}
        以上。
        """,
      chapters: Array(document.chapters[1...2])
    )
    #expect(parsed.count == 2)
    #expect(parsed[0].chapterOrdinal == 1)
    #expect(parsed[1].chapterOrdinal == 1)  // 回退本批首章

    // 合并：按章节序排列、标题去重、统一编号
    let merged = try StoryTimelineExtractor.merge(
      chunks: [
        [
          StoryTimelineExtractor.RawBeat(title: "决战", summary: "s", keywords: [], chapterOrdinal: 2),
          StoryTimelineExtractor.RawBeat(title: "启程", summary: "s", keywords: [], chapterOrdinal: 0),
        ],
        [StoryTimelineExtractor.RawBeat(title: "决战", summary: "重复", keywords: [], chapterOrdinal: 2)],
      ]
    )
    #expect(merged.source == "device_extraction")
    #expect(merged.beats.map(\.title) == ["启程", "决战"])
    #expect(merged.beats.map(\.id) == ["beat-01", "beat-02"])

    // 端到端：把章节撑大到两批，桩 provider 逐批返回
    let bigDocument = NovelDocument(
      id: UUID(),
      title: "测试书",
      sourceFormat: .text,
      sourceFileName: "test.txt",
      contentHash: "hash",
      chapters: [
        NovelChapter(
          id: "c1", ordinal: 0, title: "第一回 风起",
          content: String(repeating: "风", count: 50_000)
        ),
        NovelChapter(
          id: "c2", ordinal: 1, title: "第二回 宴起",
          content: String(repeating: "宴", count: 50_000)
        ),
        NovelChapter(id: "c3", ordinal: 2, title: "第三回 决战", content: "谷中决战。"),
      ]
    )
    let provider = StubTimelineProvider(responses: [
      #"{"beats":[{"title":"启程","summary":"s","chapter":"第一回 风起","keywords":["官道"]}]}"#,
      #"{"beats":[{"title":"决战","summary":"s","chapter":"第三回 决战","keywords":["绝情谷"]}]}"#,
    ])
    let timeline = try await StoryTimelineExtractor.extract(
      document: bigDocument,
      provider: provider
    )
    #expect(timeline.beats.map(\.title) == ["启程", "决战"])
    #expect(timeline.beats.last?.keywords == ["绝情谷"])
  }

  @Test
  func analysisCodableRoundTripPreservesChapterSummaries() throws {
    let analysis = FactoryAnalysis(
      sourceContentHash: "h",
      coveredChapterIDs: ["c1"],
      proposals: [],
      decisions: [],
      chapterSummaries: [
        FactoryChapterSummary(
          chapterID: "c1",
          chapterOrdinal: 0,
          chapterTitle: "第一章",
          segmentIndex: 0,
          segmentCount: 1,
          summary: "主角启程。"
        )
      ]
    )
    let data = try JSONEncoder().encode(analysis)
    let decoded = try JSONDecoder().decode(FactoryAnalysis.self, from: data)
    #expect(decoded.chapterSummaries == analysis.chapterSummaries)
    // 旧版 analysis.json（无 chapterSummaries 字段）解码为空数组而非失败
    let legacy = Data(
      #"{"schemaVersion":1,"sourceContentHash":"h","coveredChapterIDs":[],"proposals":[],"decisions":[],"warnings":[]}"#
        .utf8)
    let legacyDecoded = try JSONDecoder().decode(FactoryAnalysis.self, from: legacy)
    #expect(legacyDecoded.chapterSummaries.isEmpty)
  }
}

private final class StubTimelineProvider: LLMProvider, @unchecked Sendable {
  let profile = ProviderProfile(
    displayName: "stub",
    kind: .openAICompatible,
    modelID: "stub",
    credentialReference: "stub"
  )
  private var responses: [String]

  init(responses: [String]) {
    self.responses = responses
  }

  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    let response = responses.isEmpty ? #"{"beats":[]}"# : responses.removeFirst()
    return AsyncThrowingStream { continuation in
      continuation.yield(.textDelta(response))
      continuation.yield(.completed)
      continuation.finish()
    }
  }
}
