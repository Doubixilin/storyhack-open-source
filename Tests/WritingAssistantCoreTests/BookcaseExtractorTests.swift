import Foundation
import LLMProviderKit
import NovelDocumentCore
import Testing
@testable import WritingAssistantCore
import WritingCore

enum ExtractionAction: Sendable {
  case text(String, completed: Bool = true)
  case status(Int)
  case hang
  case pause
  case tool
}

actor ExtractionRecorder {
  var requests: [LLMRequest] = []
  var hanging: [UUID: AsyncThrowingStream<LLMStreamEvent, any Error>.Continuation] = [:]
  let action: @Sendable (LLMRequest, Int) throws -> ExtractionAction
  init(action: @escaping @Sendable (LLMRequest, Int) throws -> ExtractionAction = { request, _ in .text(try goodBatch(request)) }) {
    self.action = action
  }
  func respond(_ request: LLMRequest, continuation: AsyncThrowingStream<LLMStreamEvent, any Error>.Continuation) {
    requests.append(request)
    do {
      switch try action(request, requests.count) {
      case .text(let text, let completed):
        continuation.yield(.textDelta(text))
        if completed { continuation.yield(.completed) }
        continuation.finish()
      case .status(let code): continuation.finish(throwing: OpenAICompatibleError.httpStatus(code, "do-not-log-server-body"))
      case .hang:
        hanging[request.requestID] = continuation
        continuation.yield(.textDelta("未完成"))
      case .pause: hanging[request.requestID] = continuation
      case .tool:
        continuation.yield(.toolCall(.init(id: "call", name: "write_contract", arguments: "{}")))
        continuation.finish()
      }
    } catch { continuation.finish(throwing: error) }
  }
  func remove(_ id: UUID) { hanging.removeValue(forKey: id) }
  func count() -> Int { requests.count }
}

struct ExtractionProvider: LLMProvider {
  var profile: ProviderProfile
  let recorder: ExtractionRecorder
  init(recorder: ExtractionRecorder = .init(), window: Int = 32_768, output: Int = 4_096, model: String = "mock-bookcase") {
    self.recorder = recorder
    profile = .init(displayName: "合成模型", kind: .openAICompatible,
      baseURL: URL(string: "https://example.invalid/v1?private=not-for-checkpoints"), modelID: model,
      credentialReference: "DO-NOT-PERSIST-CREDENTIAL", capabilities: .init(contextWindow: window), maximumOutputTokens: output)
  }
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task { await recorder.respond(request, continuation: continuation) }
      continuation.onTermination = { _ in
        task.cancel()
        Task { await recorder.remove(request.requestID) }
      }
    }
  }
}

struct BatchInput {
  let chapterID: String
  let text: String
  let offset: Int
}

func input(_ request: LLMRequest) throws -> BatchInput {
  let prompt = try #require(request.messages.last?.content)
  let headEnd = try #require(prompt.range(of: "\n仅在下方原文中取证"))
  let header = String(prompt[prompt.index(prompt.startIndex, offsetBy: "元数据：\n".count)..<headEnd.lowerBound])
  let fields = try JSONDecoder().decode([String: String].self, from: Data(header.utf8))
  let start = try #require(prompt.range(of: "<source>\n"))
  let end = try #require(prompt.range(of: "\n</source>", options: .backwards))
  return .init(chapterID: try #require(fields["chapter_id"]), text: String(prompt[start.upperBound..<end.lowerBound]),
    offset: Int(fields["utf16_start"] ?? "") ?? 0)
}

private func goodObject(_ request: LLMRequest) throws -> [String: Any] {
  let value = try input(request)
  let quote = String(value.text.prefix(8))
  let evidence: [String: Any] = ["chapter_id": value.chapterID, "quote": quote, "utf16_location": value.offset]
  return [
    "characters": [["id": "p", "name": "林舟", "identity_core": "旅行者", "evidence": [evidence]]],
    "chapters": [["chapter_id": value.chapterID, "ordinal": 999, "title": "模型错误标题", "summary": "本段记录人物行动。", "evidence": [evidence]]],
  ]
}
func json(_ value: [String: Any]) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
}
private func goodBatch(_ request: LLMRequest) throws -> String { try json(goodObject(request)) }

struct ExtractionFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bookcase-extraction-" + UUID().uuidString)
  var store: AdaptationJobStore { .init(rootURL: root) }
  func document(chapters: [NovelChapter]? = nil) -> NovelDocument {
    let values = chapters ?? [
      .init(id: "river", ordinal: 0, title: "渡河", content: "林舟收起地图，准备渡河。船仍停在岸边。"),
      .init(id: "mountain", ordinal: 1, title: "入山", content: "林舟与老周一起进山。山中禁止点火。"),
      .init(id: "letter", ordinal: 2, title: "来信", content: "老周拆开来信，读完便把信收好。"),
    ]
    return NovelDocument(id: UUID(), title: "合成行记", sourceFormat: .text, sourceFileName: "合成.txt",
      contentHash: AdaptationCoding.hash(Data(values.map(\.content).joined(separator: "\n").utf8)), chapters: values)
  }
  func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".adaptationjob") }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct BookcaseExtractorTests {
  @Test func actualProviderPathCreatesPendingBookcaseAndRepeatIsFree() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, provider = ExtractionProvider(), job = try await store.create(document: fixture.document())
    let extractor = BookcaseExtractor(provider: provider, store: store)
    let report = try await extractor.extract(jobID: job.id)
    #expect(report.stage == .completed && report.newRequestCount == 3 && report.cacheHitCount == 0)
    #expect(report.completedUnitIDs.count == 3 && report.gaps.isEmpty)
    let proposal = try #require(try await store.bookcases(job.id).first)
    #expect(proposal.status == .pending && proposal.id == report.proposalID)
    #expect(try await store.load(job.id).approvedBookcaseID == nil)
    #expect(proposal.content.chapters.map(\.ordinal) == [0, 1, 2])
    #expect(proposal.content.chapters.map(\.title) == ["渡河", "入山", "来信"])
    #expect(Set(proposal.content.characters.map(\.id)).count == 3)
    #expect(report.warnings.contains { $0.contains("同名") })
    let repeated = try await BookcaseExtractor(provider: provider, store: fixture.store).extract(jobID: job.id, options: .init(maximumNewRequests: 0))
    #expect(repeated.proposalID == report.proposalID && repeated.newRequestCount == 0 && repeated.cacheHitCount == 3)
    #expect(await provider.recorder.count() == 3)
    #expect(try await store.bookcases(job.id).count == 1)
    let requests = await provider.recorder.requests
    for request in requests {
      #expect(request.modelOptions.maximumOutputTokens == 4_096)
      #expect(request.tools.isEmpty && request.modelOptions.reasoningEffort == "low")
      #expect(LLMTokenEstimate.inputTokens(request) <= (try AdaptationRequestBudget(profile: provider.profile).maximumInputTokens))
    }
  }

  @Test func invalidBatchIsRetriedAloneAndSuccessfulCacheDoesNotConsumeContinuationAllowance() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let recorder = ExtractionRecorder { request, index in
      .text(try input(request).chapterID == "mountain" && index == 2 ? "" : goodBatch(request))
    }
    let provider = ExtractionProvider(recorder: recorder), store = fixture.store
    let job = try await store.create(document: fixture.document()), extractor = BookcaseExtractor(provider: provider, store: store)
    let first = try await extractor.extract(jobID: job.id)
    #expect(first.stage == .partial && first.completedUnitIDs.count == 2 && first.gaps.count == 1)
    let old = try #require(try await store.bookcases(job.id).first { $0.id == first.proposalID })
    #expect(old.content.missingChapterIDs(in: fixture.document()) == ["mountain"])
    let next = try await extractor.extract(jobID: job.id, options: .init(maximumNewRequests: 1))
    #expect(next.stage == .completed && next.newRequestCount == 1 && next.cacheHitCount == 2)
    #expect(await recorder.count() == 4)
    #expect(try await store.pendingRequest(job.id) == nil)
    #expect(try await store.bookcases(job.id).contains { $0.id == old.id })
  }

  @Test func requestCapContinuesBeyondFirstUnitsInsteadOfRepeatingThem() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, provider = ExtractionProvider(), job = try await store.create(document: fixture.document())
    let extractor = BookcaseExtractor(provider: provider, store: store)
    let first = try await extractor.extract(jobID: job.id, options: .init(maximumNewRequests: 1))
    #expect(first.stage == .partial && first.completedUnitIDs == ["river-segment-0"])
    let second = try await extractor.extract(jobID: job.id, options: .init(maximumNewRequests: 1))
    #expect(second.completedUnitIDs.count == 2 && second.cacheHitCount == 1)
    let third = try await extractor.extract(jobID: job.id, options: .init(maximumNewRequests: 1))
    #expect(third.stage == .completed && third.cacheHitCount == 2 && third.newRequestCount == 1)
    #expect(await provider.recorder.count() == 3)
  }

  @Test func focusAndSelectedChaptersAreHashedAndExcludedCoverageIsExplicit() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, provider = ExtractionProvider(), job = try await store.create(document: fixture.document())
    let extractor = BookcaseExtractor(provider: provider, store: store)
    let focused = try await extractor.extract(jobID: job.id, options: .init(focusNames: [" 林舟 ", "林舟"]))
    #expect(focused.selectedChapterIDs == ["river", "mountain"] && focused.excludedChapterIDs == ["letter"])
    #expect(focused.newRequestCount == 2)
    let normalized = try await extractor.extract(jobID: job.id, options: .init(focusNames: ["林舟"]))
    #expect(normalized.cacheHitCount == 2 && normalized.planFingerprint == focused.planFingerprint)
    let selected = try await extractor.extract(jobID: job.id, options: .init(chapterIDs: ["river"], focusNames: ["林舟"]))
    #expect(selected.newRequestCount == 1 && selected.planFingerprint != focused.planFingerprint)
    let differentModel = ExtractionProvider(recorder: provider.recorder, model: "changed-model")
    let newModel = try await BookcaseExtractor(provider: differentModel, store: store).extract(jobID: job.id,
      options: .init(chapterIDs: ["river"], focusNames: ["林舟"]))
    #expect(newModel.newRequestCount == 1 && newModel.planFingerprint != selected.planFingerprint)
    await #expect(throws: AdaptationExecutionError.invalidSelection) {
      try await extractor.extract(jobID: job.id, options: .init(chapterIDs: ["not-a-real-chapter"]))
    }
    #expect(await provider.recorder.count() == 4)
  }

  @Test func unicodeSegmentsAreLosslessBudgetedAndFailedSegmentDoesNotClaimWholeChapter() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let text = "林舟👩🏽‍🚀走到桥边。\n老周修桥，林舟读信。\n第三段到山脚。"
    let source = fixture.document(chapters: [.init(id: "long", ordinal: 0, title: "长章", content: text)])
    let store = fixture.store, provider = ExtractionProvider(), job = try await store.create(document: source)
    let executor = AdaptationRequestExecutor(provider: provider, store: store)
    let options = BookcaseExtractionOptions(maximumUnitUTF16Length: 16)
    let plan = try BookcaseExtractionPlan(document: source, sourceHash: job.sourceSnapshotHash, options: options, executor: executor)
    #expect(plan.units.count >= 3 && plan.units.map(\.text).joined() == text)
    for (index, unit) in plan.units.enumerated() {
      #expect(unit.offset == plan.units.prefix(index).map { $0.text.utf16.count }.reduce(0, +))
      #expect(try executor.budget.fits(system: BookcaseExtractionPlan.system,
        prompt: BookcaseExtractionPlan.prompt(unit, planFingerprint: plan.fingerprint, focusNames: [])))
    }
    let failOne = ExtractionRecorder { request, index in .text(index == 2 ? "{}" : try goodBatch(request)) }
    let extractor = BookcaseExtractor(provider: ExtractionProvider(recorder: failOne), store: store)
    let partial = try await extractor.extract(jobID: job.id, options: options)
    let proposal = try #require(try await store.bookcases(job.id).first { $0.id == partial.proposalID })
    #expect(partial.stage == .partial && proposal.content.chapters.isEmpty)
    #expect(!proposal.content.characters.isEmpty)
    let complete = try await extractor.extract(jobID: job.id, options: options)
    #expect(complete.stage == .completed && complete.newRequestCount == 1)
    let final = try #require(try await store.bookcases(job.id).first { $0.id == complete.proposalID })
    #expect(final.content.chapters.count == 1)
    #expect(try final.content.characters.allSatisfy { card in
      try card.evidence.allSatisfy { try $0.anchor?.resolve(in: source) == $0.quote }
    })
  }

  @Test func unsupportedEvidenceIsDiscardedWhileValidAssetsAreRetained() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let recorder = ExtractionRecorder { request, _ in
      var object = try goodObject(request)
      var cards = try #require(object["characters"] as? [[String: Any]])
      cards.append(["id": "fake", "name": "虚构者", "evidence": [["chapter_id": "river", "quote": "原文没有这一句"]]])
      object["characters"] = cards
      object["relationships"] = [["id": "relation", "a": "p", "b": "fake", "summary": "错误关系", "evidence": cards[0]["evidence"]!]]
      return .text(try json(object))
    }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let report = try await BookcaseExtractor(provider: ExtractionProvider(recorder: recorder), store: store)
      .extract(jobID: job.id, options: .init(chapterIDs: ["river"]))
    let proposal = try #require(try await store.bookcases(job.id).first)
    #expect(report.stage == .partial && report.gaps[0].reason.contains("2"))
    #expect(proposal.content.characters.count == 1 && proposal.content.relationships.isEmpty)
    #expect(proposal.content.chapters.isEmpty)
    #expect(try await store.pendingRequest(job.id) == nil)
  }

  @Test func smallWindowAndInvalidBudgetStopBeforeAnyRequest() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, provider = ExtractionProvider(window: 2_048, output: 1_024)
    let job = try await store.create(document: fixture.document())
    await #expect(throws: AdaptationExecutionError.inputTooLarge) {
      try await BookcaseExtractor(provider: provider, store: store).extract(jobID: job.id)
    }
    #expect(await provider.recorder.count() == 0)
    #expect(try await store.pendingRequest(job.id) == nil)
    let bad = ExtractionProvider(recorder: provider.recorder, window: 2_048, output: 4_096)
    await #expect(throws: AdaptationExecutionError.invalidBudget) {
      try await BookcaseExtractor(provider: bad, store: store).extract(jobID: job.id)
    }
    #expect(await provider.recorder.count() == 0)
  }

  @Test func unknownRequestBlocksChangedModelSelectionAndRequiresExactAcknowledgement() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let recorder = ExtractionRecorder { _, _ in .text("partial", completed: false) }
    let provider = ExtractionProvider(recorder: recorder), store = fixture.store
    let job = try await store.create(document: fixture.document())
    await #expect(throws: AdaptationExecutionError.incompleteStream) {
      try await BookcaseExtractor(provider: provider, store: store).extract(jobID: job.id)
    }
    let pending = try #require(try await store.pendingRequest(job.id))
    #expect(try await store.bookcaseExtractionReport(job.id)?.stage == .awaitingConfirmation)
    let fresh = ExtractionProvider(), changed = BookcaseExtractor(provider: fresh, store: fixture.store)
    await #expect(throws: AdaptationRequestError.uncertain(pending)) {
      try await changed.extract(jobID: job.id, options: .init(chapterIDs: ["letter"], focusNames: ["老周"]))
    }
    #expect(await fresh.recorder.count() == 0)
    try await store.acknowledgeUnknownRequest(pending)
    await #expect(throws: AdaptationRequestError.staleCheckpoint) { try await store.acknowledgeUnknownRequest(pending) }
    _ = try await changed.extract(jobID: job.id, options: .init(chapterIDs: ["letter"]))
    #expect(await fresh.recorder.count() == 1)
    await #expect(throws: AdaptationRequestError.staleCheckpoint) { try await store.completeRequest(pending, text: "late response") }
    let approval = fixture.directory(job.id).appendingPathComponent("requests/retry-approved/\(pending.id.uuidString.lowercased()).json")
    #expect(FileManager.default.fileExists(atPath: approval.path))
  }

  @Test func cancelRetainsCompletedCacheAndPendingRequest() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let recorder = ExtractionRecorder { request, index in index == 2 ? .hang : .text(try goodBatch(request)) }
    let provider = ExtractionProvider(recorder: recorder), store = fixture.store
    let job = try await store.create(document: fixture.document()), extractor = BookcaseExtractor(provider: provider, store: store)
    let task = Task { try await extractor.extract(jobID: job.id) }
    for _ in 0..<200 {
      if await recorder.count() >= 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await recorder.count() == 2)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let pending = try #require(try await store.pendingRequest(job.id))
    #expect(try await store.bookcaseExtractionReport(job.id)?.completedUnitIDs == ["river-segment-0"])
    #expect(try await store.bookcaseExtractionReport(job.id)?.stage == .cancelled)
    try await store.acknowledgeUnknownRequest(pending)
    let resumed = try await BookcaseExtractor(provider: ExtractionProvider(), store: store).extract(jobID: job.id)
    #expect(resumed.cacheHitCount == 1 && resumed.newRequestCount == 2 && resumed.stage == .completed)
  }

  @Test func knownHTTPRejectionCanResumeButUnknownHTTPAndToolCallsCannot() async throws {
    for status in [401, 403, 429] {
      let fixture = ExtractionFixture(); defer { fixture.clean() }
      let provider = ExtractionProvider(recorder: ExtractionRecorder { _, _ in .status(status) }), store = fixture.store
      let job = try await store.create(document: fixture.document())
      await #expect(throws: status == 429 ? AdaptationExecutionError.rateLimited : .authentication) {
        try await BookcaseExtractor(provider: provider, store: store).extract(jobID: job.id)
      }
      #expect(try await store.pendingRequest(job.id) == nil)
      #expect(try await store.bookcaseExtractionReport(job.id)?.newRequestCount == 1)
    }
    for action in [ExtractionAction.status(500), .tool] {
      let fixture = ExtractionFixture(); defer { fixture.clean() }
      let provider = ExtractionProvider(recorder: ExtractionRecorder { _, _ in action }), store = fixture.store
      let job = try await store.create(document: fixture.document())
      await #expect(throws: (any Error).self) {
        try await BookcaseExtractor(provider: provider, store: store).extract(jobID: job.id)
      }
      #expect(try await store.pendingRequest(job.id) != nil)
      #expect(try await store.bookcaseExtractionReport(job.id)?.stage == .awaitingConfirmation)
    }
  }

  @Test func sourceChangeDuringProviderRunRejectsProposalButKeepsCompletedResponse() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, provider = ExtractionProvider(), job = try await store.create(document: fixture.document())
    let documentURL = fixture.directory(job.id).appendingPathComponent("input/document.json")
    await #expect(throws: AdaptationError.invalidSource) {
      try await BookcaseExtractor(provider: provider, store: store).extract(jobID: job.id,
        options: .init(chapterIDs: ["river"]), progress: { report in
          if report.completedUnitIDs.count == 1 { try? Data("changed".utf8).write(to: documentURL) }
        })
    }
    #expect(try await store.pendingRequest(job.id) == nil)
    #expect(await provider.recorder.count() == 1)
    let cache = fixture.directory(job.id).appendingPathComponent("requests/responses")
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
  }

  @Test func oversizedResponseLeavesCheckpointAndCredentialsNeverEnterRequestFiles() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let provider = ExtractionProvider(recorder: ExtractionRecorder { _, _ in .text(String(repeating: "长", count: 400_000)) })
    let store = fixture.store, job = try await store.create(document: fixture.document())
    await #expect(throws: AdaptationRequestError.responseTooLarge) {
      try await BookcaseExtractor(provider: provider, store: store).extract(jobID: job.id)
    }
    let pending = try #require(try await store.pendingRequest(job.id))
    let raw = String(decoding: try AdaptationCoding.encoder().encode(pending), as: UTF8.self)
    #expect(!raw.contains("DO-NOT-PERSIST-CREDENTIAL") && !raw.contains("not-for-checkpoints") && !raw.contains("https://"))
  }

  @Test func completedBytesResumeAfterCrashBeforeValidationAndDoNotNeedNewModelCall() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, provider = ExtractionProvider(), source = fixture.document(chapters: [
      .init(id: "one", ordinal: 0, title: "单章", content: "林舟收好地图，走向河岸。"),
    ])
    let job = try await store.create(document: source), executor = AdaptationRequestExecutor(provider: provider, store: store)
    let plan = try BookcaseExtractionPlan(document: source, sourceHash: job.sourceSnapshotHash, options: .init(), executor: executor)
    let unit = try #require(plan.units.first), prompt = BookcaseExtractionPlan.prompt(unit, planFingerprint: plan.fingerprint, focusNames: [])
    let identity = try executor.identity(sourceHash: job.sourceSnapshotHash, purpose: BookcaseExtractionPlan.version,
      unitID: unit.id, system: BookcaseExtractionPlan.system, prompt: prompt)
    let start = try await store.beginRequest(jobID: job.id, identity: identity)
    guard case .send(let checkpoint) = start else { Issue.record("expected first request"); return }
    let request = LLMRequest(requestID: checkpoint.id, messages: [.init(role: .user, content: prompt)])
    _ = try await store.completeRequest(checkpoint, text: goodBatch(request))
    let resumed = try await BookcaseExtractor(provider: provider, store: fixture.store).extract(jobID: job.id, options: .init(maximumNewRequests: 0))
    #expect(resumed.stage == .completed && resumed.cacheHitCount == 1 && resumed.newRequestCount == 0)
    #expect(await provider.recorder.count() == 0)
  }

  @Test func emptyChaptersDoNotUseModelAndMalformedPendingCannotBeIgnored() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, provider = ExtractionProvider(), source = fixture.document(chapters: [
      .init(id: "empty", ordinal: 0, title: "空章", content: " \n"),
    ])
    let job = try await store.create(document: source)
    let report = try await BookcaseExtractor(provider: provider, store: store).extract(jobID: job.id)
    #expect(report.stage == .completed && report.totalUnits == 0 && report.newRequestCount == 0)
    #expect(try await store.bookcases(job.id).first?.content.chapters[0].summary == "本章没有正文。")
    let pending = fixture.directory(job.id).appendingPathComponent("requests/pending.json")
    try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: pending)
    await #expect(throws: AdaptationError.corruptPackage) {
      try await BookcaseExtractor(provider: provider, store: store).extract(jobID: job.id)
    }
    #expect(await provider.recorder.count() == 0)
  }

  @Test func normalizerRejectsQuotesOutsideRequestedSegmentButResolvesLocalRepetition() throws {
    let fixture = ExtractionFixture(), source = fixture.document(chapters: [
      .init(id: "one", ordinal: 0, title: "回声", content: "林舟走过桥。林舟走过桥。最后收起地图。"),
    ])
    let hash = try AdaptationCoding.fingerprint(source)
    let unit = BookcaseExtractionUnit(chapterID: "one", title: "回声", ordinal: 0, offset: 6, text: "林舟走过桥。")
    let normalizer = BookcaseBatchNormalizer(document: source, sourceHash: hash, extractorVersion: "test")
    let evidence: [String: Any] = ["chapter_id": "one", "quote": "林舟走过桥。"]
    let text = try json(["chapters": [["chapter_id": "one", "summary": "再过桥。", "evidence": [evidence]]]])
    let result = try normalizer.normalize(text, unit: unit)
    #expect(result.complete && result.bookcase.chapters[0].evidence[0].utf16Location == 6)
    let outside = try json(["chapters": [["chapter_id": "one", "summary": "收地图。",
      "evidence": [["chapter_id": "one", "quote": "最后收起地图。", "utf16_location": 12]]]]])
    let refused = try normalizer.normalize(outside, unit: unit)
    #expect(!refused.complete && refused.bookcase.chapters.isEmpty)
  }

  @Test func explicitIdentityMergeUpdatesReferencesAndKeepsUnselectedCards() throws {
    let evidence = BookcaseEvidence(chapterID: "one", quote: "林舟见到老周。")
    let cards = [BookcaseCharacter(id: "lin1", name: "林舟", evidence: [evidence]),
      .init(id: "lin2", name: "林舟", evidence: [evidence]), .init(id: "zhou", name: "老周", evidence: [evidence])]
    var bookcase = NovelBookcase(meta: .init(sourceSnapshotHash: "hash", extractorVersion: "test"), characters: cards,
      relationships: [.init(id: "rel", a: "lin2", b: "zhou", summary: "相见", evidence: [evidence])],
      chapters: [.init(chapterID: "one", summary: "相见", moments: [
        .init(note: "见面", involvedCharacterIDs: ["lin1", "lin2", "zhou"], evidence: evidence),
      ], evidence: [evidence])])
    var retained = cards[0]; retained.identityCore = "作者确认的旅行者"
    let merged = try bookcase.mergingCharacters(["lin1", "lin2"], replacement: retained)
    #expect(Set(merged.characters.map(\.id)) == ["lin1", "zhou"])
    #expect(merged.relationships[0].a == "lin1" && merged.relationships[0].b == "zhou")
    #expect(merged.chapters[0].moments[0].involvedCharacterIDs == ["lin1", "zhou"])
    #expect(merged.characters.first { $0.id == "lin1" }?.origin == .author)
    #expect(merged.meta.manualCharacterIDs == ["lin1"])
    bookcase.relationships.append(.init(id: "bad", a: "lin1", b: "lin2", summary: "身份冲突", evidence: [evidence]))
    #expect(throws: AdaptationError.invalidBookcase) { try bookcase.mergingCharacters(["lin1", "lin2"], replacement: retained) }
    #expect(bookcase.characters.count == 3)
  }

  @Test func requestCheckpointCASProtectsConcurrentStartsAndLateResponses() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let hash = AdaptationCoding.hash(Data("test".utf8))
    let identity = AdaptationRequestIdentity(sourceSnapshotHash: job.sourceSnapshotHash, purpose: "test", unitID: "one",
      executorFingerprint: hash, inputFingerprint: hash)
    let starts = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<8 {
        group.addTask {
          do { _ = try await fixture.store.beginRequest(jobID: job.id, identity: identity); return true }
          catch { return false }
        }
      }
      var count = 0
      for await result in group { if result { count += 1 } }
      return count
    }
    #expect(starts == 1)
    let old = try #require(try await store.pendingRequest(job.id))
    try await store.acknowledgeUnknownRequest(old)
    let second = try await store.beginRequest(jobID: job.id, identity: identity)
    guard case .send(let current) = second else { Issue.record("expected retry"); return }
    await #expect(throws: AdaptationRequestError.staleCheckpoint) { try await store.completeRequest(old, text: "late") }
    #expect(try await store.pendingRequest(job.id) == current)
    let completed = try await store.completeRequest(current, text: "complete")
    #expect(try await store.cachedResponse(jobID: job.id, identity: identity) == completed)
    let cached = try await store.beginRequest(jobID: job.id, identity: identity)
    guard case .cached = cached else { Issue.record("completed result should be reused"); return }
  }

  @Test func interruptedCompletionRestoresPendingAndRemovesUncommittedCache() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let hash = AdaptationCoding.hash(Data("test".utf8))
    let identity = AdaptationRequestIdentity(sourceSnapshotHash: job.sourceSnapshotHash, purpose: "test", unitID: "one",
      executorFingerprint: hash, inputFingerprint: hash)
    guard case .send(let checkpoint) = try await store.beginRequest(jobID: job.id, identity: identity) else {
      Issue.record("expected pending"); return
    }
    let pendingURL = fixture.directory(job.id).appendingPathComponent("requests/pending.json")
    let before = try Data(contentsOf: pendingURL)
    _ = try await store.completeRequest(checkpoint, text: "completed bytes")
    let cacheURL = fixture.directory(job.id).appendingPathComponent("requests/responses/\(try identity.cacheKey()).json")
    let journal = fixture.root.appendingPathComponent(".replacement-journals/update-interrupted")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    try before.write(to: journal.appendingPathComponent("backup-0"))
    let entries: [[String: Any]] = [["path": pendingURL.path, "backupName": "backup-0"], ["path": cacheURL.path]]
    try JSONSerialization.data(withJSONObject: ["entries": entries, "createdAt": Date().timeIntervalSinceReferenceDate])
      .write(to: journal.appendingPathComponent("manifest.json"))
    #expect(try await fixture.store.pendingRequest(job.id) == checkpoint)
    #expect(try await store.cachedResponse(jobID: job.id, identity: identity) == nil)
    await #expect(throws: AdaptationRequestError.uncertain(checkpoint)) { try await store.beginRequest(jobID: job.id, identity: identity) }
  }

  @Test func longBookResumesSixHundredIndependentChaptersWithNoDuplicateRequests() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let source = fixture.document(chapters: (0..<600).map { index in
      .init(id: "chapter-\(index)", ordinal: index, title: "合成章节 \(index)", content: "第\(index)站，林舟收好地图。")
    })
    let store = fixture.store, provider = ExtractionProvider(), job = try await store.create(document: source)
    let extractor = BookcaseExtractor(provider: provider, store: store)
    var final: BookcaseExtractionReport?
    for turn in 1...6 {
      let report = try await extractor.extract(jobID: job.id, options: .init(maximumNewRequests: 100))
      #expect(report.newRequestCount == 100 && report.cacheHitCount == (turn - 1) * 100)
      #expect(report.completedUnitIDs.count == turn * 100)
      final = report
    }
    #expect(final?.stage == .completed)
    #expect(await provider.recorder.count() == 600)
    let proposal = try #require(try await store.bookcases(job.id).first { $0.id == final?.proposalID })
    #expect(proposal.content.chapters.count == 600)
    #expect(Set(proposal.content.characters.map(\.id)).count == 600)
    #expect(proposal.content.chapters.map(\.ordinal) == Array(0..<600).map(Optional.some))
    let retained = try #require(proposal.content.characters.first)
    let confirmedIdentity = try proposal.content.mergingCharacters(Set(proposal.content.characters.map(\.id)), replacement: retained)
      .validated(in: source, snapshotHash: job.sourceSnapshotHash)
    #expect(confirmedIdentity.characters.count == 1)
    #expect(proposal.content.characters.count == 600)
  }

  @Test func damagedCompletedCacheIsQuarantinedAndOnlyThatUnitConsumesRetryBudget() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, provider = ExtractionProvider(), source = fixture.document()
    let job = try await store.create(document: source), extractor = BookcaseExtractor(provider: provider, store: store)
    let first = try await extractor.extract(jobID: job.id)
    let cache = fixture.directory(job.id).appendingPathComponent("requests/responses")
    let file = try #require(try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
    try Data("corrupt completed cache".utf8).write(to: file)
    let noBudget = try await extractor.extract(jobID: job.id, options: .init(maximumNewRequests: 0))
    #expect(noBudget.newRequestCount == 0 && noBudget.cacheHitCount == 2 && noBudget.stage == .partial)
    #expect(await provider.recorder.count() == 3)
    let repaired = try await extractor.extract(jobID: job.id, options: .init(maximumNewRequests: 1))
    #expect(repaired.newRequestCount == 1 && repaired.cacheHitCount == 2 && repaired.stage == .completed)
    #expect(repaired.proposalID == first.proposalID)
    let archive = fixture.directory(job.id).appendingPathComponent("requests/rejected")
    #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).contains { $0.hasPrefix("corrupt-") })
  }
}
