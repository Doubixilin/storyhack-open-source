import Foundation
import DirectoryJournalCore
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore
import Testing
@testable import WritingAssistantCore
import WritingCore

private func writingInput(_ request: LLMRequest) throws -> [String: Any] {
  let prompt = try #require(request.messages.last?.content)
  let data = String(prompt.dropFirst("写作输入（结构化资料）：\n".count)).components(separatedBy: "\n")[0]
  return try #require(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any])
}
private func writingReply(_ request: LLMRequest, body: String = "林舟看了看岸边，收起地图继续前行。", recipe: String? = nil) throws -> String {
  let value = try writingInput(request), context = try #require(value["context"] as? [String: Any])
  let target = try #require(context["target"] as? [String: Any]), id = try #require(target["chapter_id"] as? String)
  let content = AdaptationDraftContent(title: "新章" + id, body: body, recap: "前情-" + id,
    reviewLine: "保留行程，补充细节，待作者核对。",
    recipe: .init(trigger: recipe ?? id, setting: "道路", technique: "动作细节"))
  return String(decoding: try AdaptationCoding.encoder().encode(content), as: UTF8.self)
}
private func standalone(_ fixture: ExtractionFixture, contract: AdaptationDirectionContract? = nil) async throws -> (AdaptationJob, AdaptationVariant) {
  let store = fixture.store, job = try await store.create(document: fixture.document())
  var direction = contract ?? .init()
  if contract == nil { direction.minimumCharacterCount = 1; direction.targetCharacterCount = 100 }
  let variant = try await store.createStandaloneVariant(jobID: job.id, title: "试写", contract: direction, expectedRevision: job.revision)
  return (job, variant)
}
private func writingProvider() -> ExtractionProvider {
  .init(recorder: .init { request, _ in .text(try writingReply(request)) })
}
private extension ExtractionRecorder {
  func finishWriting() throws {
    for (id, continuation) in hanging {
      let request = try #require(requests.first { $0.requestID == id })
      continuation.yield(.textDelta(try writingReply(request)))
      continuation.yield(.completed); continuation.finish()
    }
    hanging = [:]
  }
}

@Suite struct AdaptationWriterTests {
  @Test func sequentialChaptersPersistPendingVersionsRecapsAndResumeWithoutRequests() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture), provider = writingProvider(), store = fixture.store
    let writer = AdaptationWriter(provider: provider, store: store)
    let first = try await writer.write(jobID: job.id, variantID: variant.id, options: .init(maximumNewRequests: 1))
    #expect(first.stage == .partial && first.completedDraftIDs.count == 1)
    let completed = try await writer.write(jobID: job.id, variantID: variant.id)
    #expect(completed.stage == .completed && completed.newRequestCount == 2 && completed.reusedDraftCount == 1)
    let snapshot = try await store.drafts(jobID: job.id, variantID: variant.id)
    #expect(snapshot.current.count == 3 && snapshot.current.allSatisfy { !$0.isStale && $0.decision == nil })
    #expect(snapshot.current.last?.draft.context.predecessors.map(\.id) == Array(snapshot.current.prefix(2)).map { $0.draft.id })
    let requests = await provider.recorder.requests
    let last = try writingInput(try #require(requests.last)), prior = try #require(last["prior"] as? [[String: Any]])
    #expect(prior.compactMap { $0["recap"] as? String } == ["前情-river", "前情-mountain"])
    let repeated = try await writer.write(jobID: job.id, variantID: variant.id, options: .init(maximumNewRequests: 0))
    #expect(repeated.reusedDraftCount == 3 && repeated.newRequestCount == 0)
    #expect(await provider.recorder.count() == 3)
    #expect(try await store.source(job.id).chapters == fixture.document().chapters)
    #expect(try await store.writeReport(jobID: job.id, variantID: variant.id) == repeated)
  }

  @Test func authorEditInvalidatesAllSuccessorsAndRetainsOldVersions() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture), provider = writingProvider(), store = fixture.store
    let writer = AdaptationWriter(provider: provider, store: store)
    _ = try await writer.write(jobID: job.id, variantID: variant.id)
    let original = try await store.drafts(jobID: job.id, variantID: variant.id)
    let first = try #require(original.current.first?.draft)
    var edit = first.content; edit.body = "作者修改：林舟折返岸边。"; edit.recap = "林舟折返。"
    let revised = try await store.reviseDraft(jobID: job.id, variantID: variant.id, draftID: first.id, content: edit)
    #expect(revised.parentID == first.id)
    let state = try await store.drafts(jobID: job.id, variantID: variant.id)
    #expect(state.current.map(\.isStale) == [false, true, true])
    await #expect(throws: AdaptationError.staleDraft) {
      try await writer.write(jobID: job.id, variantID: variant.id, options: .init(targets: [.init(chapterID: "letter")]))
    }
    let next = try await writer.write(jobID: job.id, variantID: variant.id)
    #expect(next.newRequestCount == 2 && next.reusedDraftCount == 1)
    #expect(try await store.draft(jobID: job.id, variantID: variant.id, draftID: first.id) == first)
    #expect(try await store.drafts(jobID: job.id, variantID: variant.id).current.allSatisfy { !$0.isStale })
    let latest = await provider.recorder.requests
    #expect(latest.suffix(2).allSatisfy { $0.messages.last?.content.contains("林舟折返。") == true })
  }

  @Test func contractABAAndSeparateDirectionsDoNotReuseOldDrafts() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture), store = fixture.store, provider = writingProvider()
    let writer = AdaptationWriter(provider: provider, store: store)
    _ = try await writer.write(jobID: job.id, variantID: variant.id)
    let initial = try await store.direction(jobID: job.id, revisionID: variant.contractRevisionID).contract
    var changed = initial; changed.style = "另一方向"
    let next = try await store.updateDirection(jobID: job.id, variantID: variant.id,
      expectedContractRevisionID: variant.contractRevisionID, contract: changed)
    _ = try await store.updateDirection(jobID: job.id, variantID: variant.id,
      expectedContractRevisionID: next.contractRevisionID, contract: initial)
    #expect(try await store.drafts(jobID: job.id, variantID: variant.id).current.allSatisfy(\.isStale))
    let rerun = try await writer.write(jobID: job.id, variantID: variant.id)
    #expect(rerun.newRequestCount == 3)
    let current = try await store.load(job.id)
    let other = try await store.createStandaloneVariant(jobID: job.id, title: "另版", contract: initial, expectedRevision: current.revision)
    _ = try await writer.write(jobID: job.id, variantID: other.id)
    let a = try await store.drafts(jobID: job.id, variantID: variant.id), b = try await store.drafts(jobID: job.id, variantID: other.id)
    #expect(Set(a.current.map { $0.draft.id }).isDisjoint(with: b.current.map { $0.draft.id }))
    #expect(await provider.recorder.count() == 9)
  }

  @Test func reviewedAnchorActionsAndManualQuoteAreActualGenerationInputs() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture), store = fixture.store, provider = writingProvider()
    var map = try await store.anchorMap(job.id)
    let specs: [(String, String, AdaptationAnchorAction)] = [("river", "", .insertion), ("mountain", "山中禁止点火。", .rewrite), ("letter", "", .newChapter)]
    var targets: [AdaptationDraftTarget] = []
    for (chapter, quote, action) in specs {
      map = try await store.addManualAnchor(jobID: job.id, expectedRevision: map.revision,
        candidate: .init(chapterID: chapter, quote: quote, note: "作者位置"))
      let anchor = try #require(map.anchors.last)
      targets.append(.init(chapterID: chapter, anchorID: anchor.id))
      await #expect(throws: AdaptationError.reviewRequired) {
        try await store.draftContext(jobID: job.id, variantID: variant.id, target: .init(chapterID: chapter, anchorID: anchor.id))
      }
      map = try await store.reviewAnchor(jobID: job.id, anchorID: anchor.id, expectedRevision: map.revision,
        action: .approve, generationAction: action, intensity: 4)
    }
    let writer = AdaptationWriter(provider: provider, store: store)
    _ = try await writer.write(jobID: job.id, variantID: variant.id, options: .init(targets: targets.reversed()))
    let requests = await provider.recorder.requests
    #expect(try requests.map { try writingInput($0)["action"] as? String } == ["insertion", "rewrite", "new_chapter"])
    let point = try #require(map.anchors.first)
    _ = try await store.editAnchorNote(jobID: job.id, anchorID: point.id, expectedRevision: map.revision, note: "新要求")
    #expect(try await store.drafts(jobID: job.id, variantID: variant.id).current.allSatisfy(\.isStale))
  }

  @Test func malformedJSONRepairsAtMostOnceEvenAcrossReruns() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture)
    let provider = ExtractionProvider(recorder: .init { _, _ in .text("{}") })
    let writer = AdaptationWriter(provider: provider, store: fixture.store)
    for _ in 0..<2 {
      await #expect(throws: AdaptationExecutionError.invalidResponse) {
        try await writer.write(jobID: job.id, variantID: variant.id, options: .init(targets: [.init(chapterID: "river")]))
      }
    }
    #expect(await provider.recorder.count() == 2)
    #expect(try await fixture.store.pendingRequest(job.id) == nil)
    #expect(try await fixture.store.drafts(jobID: job.id, variantID: variant.id).current.isEmpty)
  }

  @Test func lengthRetryStopsAndWarningsRequireExplicitAuthorAcknowledgement() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    var contract = AdaptationDirectionContract(); contract.minimumCharacterCount = 80; contract.targetCharacterCount = 100
    let (job, variant) = try await standalone(fixture, contract: contract), provider = writingProvider(), store = fixture.store
    let writer = AdaptationWriter(provider: provider, store: store)
    _ = try await writer.write(jobID: job.id, variantID: variant.id, options: .init(targets: [.init(chapterID: "river")]))
    #expect(await provider.recorder.count() == 2)
    let state = try await store.drafts(jobID: job.id, variantID: variant.id), draft = try #require(state.current.first?.draft)
    #expect(draft.warnings.count == 1 && draft.content.recap.count <= 80)
    await #expect(throws: AdaptationError.reviewRequired) {
      try await store.decideDraft(jobID: job.id, variantID: variant.id, draftID: draft.id,
        expectedRevision: state.revision, action: .approve)
    }
    _ = try await store.decideDraft(jobID: job.id, variantID: variant.id, draftID: draft.id,
      expectedRevision: state.revision, action: .approve, acknowledgeWarnings: true)
    let repeated = try await writer.write(jobID: job.id, variantID: variant.id, options: .init(targets: [.init(chapterID: "river")]))
    #expect(repeated.reusedDraftCount == 1 && repeated.newRequestCount == 0)
    var edit = draft.content; edit.body += "作者追加。"
    let revision = try await store.reviseDraft(jobID: job.id, variantID: variant.id, draftID: draft.id, content: edit)
    #expect(revision.id != draft.id)
    #expect(try await store.drafts(jobID: job.id, variantID: variant.id).current.first?.decision == nil)
  }

  @Test func repairBudgetResumesFromInitialResponseWithoutPayingTwice() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture)
    let provider = ExtractionProvider(recorder: .init { request, count in .text(count == 1 ? "{}" : try writingReply(request)) })
    let writer = AdaptationWriter(provider: provider, store: fixture.store)
    let options = AdaptationWriteOptions(targets: [.init(chapterID: "river")], maximumNewRequests: 1)
    let first = try await writer.write(jobID: job.id, variantID: variant.id, options: options)
    #expect(first.stage == .partial && first.completedDraftIDs.isEmpty)
    let next = try await writer.write(jobID: job.id, variantID: variant.id, options: options)
    #expect(next.stage == .completed && next.newRequestCount == 1 && next.cacheHitCount == 1)
    #expect(await provider.recorder.count() == 2)
  }

  @Test func explicitMaximumRepairsOnceThenPreservesWarningUntilAuthorReview() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    var contract = AdaptationDirectionContract()
    contract.minimumCharacterCount = 1; contract.targetCharacterCount = 10; contract.maximumCharacterCount = 12
    let (job, variant) = try await standalone(fixture, contract: contract), store = fixture.store
    let provider = ExtractionProvider(recorder: .init { request, _ in
      .text(try writingReply(request, body: "林舟站在河边，收起地图继续等待。"))
    })
    let writer = AdaptationWriter(provider: provider, store: store)
    let options = AdaptationWriteOptions(targets: [.init(chapterID: "river")])
    let result = try await writer.write(jobID: job.id, variantID: variant.id, options: options)
    #expect(result.newRequestCount == 2)
    let snapshot = try await store.drafts(jobID: job.id, variantID: variant.id)
    let draft = try #require(snapshot.current.first?.draft)
    #expect(draft.content.body == "林舟站在河边，收起地图继续等待。") // not silently truncated
    #expect(draft.warnings.contains { $0.contains("超过合同上限 12 字") })
    let requests = await provider.recorder.requests
    #expect(requests.last?.messages.last?.content.contains("超过上限 12 字") == true)
    await #expect(throws: AdaptationError.reviewRequired) {
      try await store.decideDraft(jobID: job.id, variantID: variant.id, draftID: draft.id,
        expectedRevision: snapshot.revision, action: .approve)
    }
    let resumed = try await AdaptationWriter(provider: provider, store: store).write(
      jobID: job.id, variantID: variant.id, options: options)
    #expect(resumed.newRequestCount == 0 && resumed.reusedDraftCount == 1)
    #expect(await provider.recorder.count() == 2)
    var corrected = draft.content; corrected.body = "林舟等待。"
    let revision = try await store.reviseDraft(jobID: job.id, variantID: variant.id, draftID: draft.id, content: corrected)
    #expect(revision.warnings.isEmpty)
    #expect(try await store.draft(jobID: job.id, variantID: variant.id, draftID: draft.id).warnings == draft.warnings)
    let current = try await store.drafts(jobID: job.id, variantID: variant.id)
    _ = try await store.decideDraft(jobID: job.id, variantID: variant.id, draftID: revision.id,
      expectedRevision: current.revision, action: .approve)
  }

  @Test func maximumRepairResumesFromCacheAndAcceptsInclusiveUnicodeBoundary() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    // Count visible characters, not UTF-8 bytes or UTF-16 code units.
    let exact = "林舟👩🏽‍🚀等待。"
    var contract = AdaptationDirectionContract()
    contract.minimumCharacterCount = 1; contract.targetCharacterCount = exact.count; contract.maximumCharacterCount = exact.count
    let (job, variant) = try await standalone(fixture, contract: contract), store = fixture.store
    let provider = ExtractionProvider(recorder: .init { request, n in
      .text(try writingReply(request, body: n == 1 ? exact + "多余" : exact))
    })
    let writer = AdaptationWriter(provider: provider, store: store)
    let options = AdaptationWriteOptions(targets: [.init(chapterID: "river")], maximumNewRequests: 1)
    let first = try await writer.write(jobID: job.id, variantID: variant.id, options: options)
    #expect(first.stage == .partial && first.completedDraftIDs.isEmpty)
    let resumed = try await writer.write(jobID: job.id, variantID: variant.id, options: options)
    #expect(resumed.newRequestCount == 1 && resumed.cacheHitCount == 1)
    let draft = try #require(try await store.drafts(jobID: job.id, variantID: variant.id).current.first?.draft)
    #expect(draft.content.body == exact && draft.warnings.isEmpty)
    #expect(await provider.recorder.count() == 2)
  }

  @Test func legacyTargetAloneDoesNotBecomeMaximumOrTriggerRepair() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    var contract = AdaptationDirectionContract()
    contract.minimumCharacterCount = 1; contract.targetCharacterCount = 5
    let (job, variant) = try await standalone(fixture, contract: contract), provider = writingProvider()
    let result = try await AdaptationWriter(provider: provider, store: fixture.store).write(
      jobID: job.id, variantID: variant.id, options: .init(targets: [.init(chapterID: "river")]))
    #expect(result.newRequestCount == 1)
    let draft = try #require(try await fixture.store.drafts(jobID: job.id, variantID: variant.id).current.first?.draft)
    #expect(draft.content.body.count > contract.targetCharacterCount && draft.warnings.isEmpty)
  }

  @Test func recipeCollisionGetsOneRepairAndStillRepeatedCombinationIsVisible() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture)
    let provider = ExtractionProvider(recorder: .init { request, _ in .text(try writingReply(request, recipe: "same")) })
    let writer = AdaptationWriter(provider: provider, store: fixture.store)
    _ = try await writer.write(jobID: job.id, variantID: variant.id, options: .init(targets: [.init(chapterID: "river"), .init(chapterID: "mountain")]))
    #expect(await provider.recorder.count() == 3)
    let state = try await fixture.store.drafts(jobID: job.id, variantID: variant.id)
    #expect(state.current[0].draft.warnings.isEmpty)
    #expect(state.current[1].draft.warnings.contains { $0.contains("表达组合") })
    let requests = await provider.recorder.requests
    #expect(requests.last?.messages.last?.content.contains("配方完整组合已被使用") == true)
    #expect(!state.current[1].draft.content.body.contains("recipe"))
    await #expect(throws: AdaptationError.invalidDraft) {
      try await fixture.store.decideDraft(jobID: job.id, variantID: variant.id, draftID: state.current[1].draft.id,
        expectedRevision: state.revision, action: .approve, acknowledgeWarnings: true)
    }
  }

  @Test func originalModeOmitsSourceAndTaskTasteOverridesPersonalDefault() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    var contract = AdaptationDirectionContract(); contract.mode = .original; contract.includeOriginalChapter = false
    contract.minimumCharacterCount = 1; contract.targetCharacterCount = 100; contract.style = "作者合同要求保持冷静"
    let (job, variant) = try await standalone(fixture, contract: contract), provider = writingProvider()
    let writer = AdaptationWriter(provider: provider, store: fixture.store)
    let options = AdaptationWriteOptions(targets: [.init(chapterID: "river")], personalTaste: .init(pace: .unhurried),
      commandLineTaste: .init(pace: .brisk), taskTaste: .init(pace: .balanced, notes: "只影响表达"))
    _ = try await writer.write(jobID: job.id, variantID: variant.id, options: options)
    let request = try #require(await provider.recorder.requests.first), value = try writingInput(request)
    #expect(value["original"] == nil && value["bookcase"] == nil)
    #expect(request.messages.last?.content.contains("船仍停在岸边") == false)
    #expect(request.messages.last?.content.contains("作者合同要求保持冷静") == true)
    #expect(request.messages.last?.content.contains("\"pace\":\"平衡\"") == true)
    #expect(try await fixture.store.generationBasis(jobID: job.id, variantID: variant.id).bookcaseID == nil)
  }

  @Test func concurrentHeadCASAllowsOneRevisionAndMissingAuditFailsClosed() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture), store = fixture.store
    let context = try await store.draftContext(jobID: job.id, variantID: variant.id, target: .init(chapterID: "river"))
    let content = AdaptationDraftContent(title: "人工", body: "作者写下正文。", recap: "记录行动。", reviewLine: "人工核对。",
      recipe: .init(trigger: "行动", setting: "河边", technique: "白描"))
    let successes = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<8 {
        group.addTask {
          do { _ = try await fixture.store.proposeDraft(context: context, content: content, generatorFingerprint: "test", expectedHeadID: nil); return true }
          catch { return false }
        }
      }
      var count = 0; for await success in group where success { count += 1 }; return count
    }
    #expect(successes == 1)
    let state = try await store.drafts(jobID: job.id, variantID: variant.id), draft = try #require(state.current.first?.draft)
    _ = try await store.decideDraft(jobID: job.id, variantID: variant.id, draftID: draft.id, expectedRevision: state.revision, action: .approve)
    let audit = fixture.directory(job.id).appendingPathComponent("drafts/\(variant.id.uuidString.lowercased())/decisions/\(draft.id.uuidString.lowercased()).json")
    try FileManager.default.removeItem(at: audit)
    await #expect(throws: (any Error).self) { try await store.drafts(jobID: job.id, variantID: variant.id) }
  }

  @Test func hugeFixedContractIsRejectedBeforeAnyProviderRequest() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    var contract = AdaptationDirectionContract(); contract.notes = String(repeating: "约束", count: 2_000)
    let (job, variant) = try await standalone(fixture, contract: contract)
    let provider = ExtractionProvider(window: 2_048, output: 512)
    await #expect(throws: AdaptationExecutionError.inputTooLarge) {
      try await AdaptationWriter(provider: provider, store: fixture.store).write(jobID: job.id, variantID: variant.id)
    }
    #expect(await provider.recorder.count() == 0)
  }

  @Test func changingContractDuringResponseRejectsInstallationAndKeepsCompletedCache() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture), store = fixture.store
    let provider = ExtractionProvider(recorder: .init { _, _ in .pause })
    let writer = AdaptationWriter(provider: provider, store: store)
    let task = Task { try await writer.write(jobID: job.id, variantID: variant.id, options: .init(targets: [.init(chapterID: "river")])) }
    for _ in 0..<100 {
      if await provider.recorder.count() == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await provider.recorder.count() == 1)
    var contract = try await store.direction(jobID: job.id, revisionID: variant.contractRevisionID).contract
    contract.notes = "生成中改方向"
    _ = try await store.updateDirection(jobID: job.id, variantID: variant.id, expectedContractRevisionID: variant.contractRevisionID, contract: contract)
    try await provider.recorder.finishWriting()
    await #expect(throws: AdaptationError.staleDraft) { try await task.value }
    #expect(try await store.pendingRequest(job.id) == nil)
    #expect(try await store.drafts(jobID: job.id, variantID: variant.id).current.isEmpty)
    let folder = fixture.directory(job.id).appendingPathComponent("requests/responses")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    let nextProvider = writingProvider()
    let result = try await AdaptationWriter(provider: nextProvider, store: store).write(jobID: job.id, variantID: variant.id,
      options: .init(targets: [.init(chapterID: "river")]))
    #expect(result.newRequestCount == 1 && result.cacheHitCount == 0)
  }

  @Test func cancellationKeepsUnknownCheckpointAndBlocksDifferentModel() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let (job, variant) = try await standalone(fixture), store = fixture.store
    let provider = ExtractionProvider(recorder: .init { _, _ in .pause })
    let task = Task { try await AdaptationWriter(provider: provider, store: store).write(jobID: job.id, variantID: variant.id) }
    for _ in 0..<100 {
      if await provider.recorder.count() == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await provider.recorder.count() == 1)
    let live = try #require(try await store.pendingRequest(job.id))
    await #expect(throws: DirectoryProcessLockError.busy) { try await store.acknowledgeUnknownRequest(live) }
    await #expect(throws: DirectoryProcessLockError.busy) {
      try await AdaptationWriter(provider: writingProvider(), store: fixture.store).write(jobID: job.id, variantID: variant.id)
    }
    #expect(try await store.pendingRequest(job.id) == live)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let pending = try #require(try await store.pendingRequest(job.id))
    let other = ExtractionProvider(model: "different-model")
    await #expect(throws: AdaptationRequestError.uncertain(pending)) {
      try await AdaptationWriter(provider: other, store: store).write(jobID: job.id, variantID: variant.id)
    }
    #expect(await other.recorder.count() == 0)
    #expect(try await store.writeReport(jobID: job.id, variantID: variant.id)?.stage == .cancelled)
  }

  @Test func approvedBookcaseConstraintsAndChapterIndexReachWriter() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    var person = BookcaseCharacter(id: "lin", name: "林舟", evidence: [.init(chapterID: "river", quote: "林舟收起地图")])
    person.identityCore = "旅行者"; person.hardFacts = ["带着地图"]
    let content = NovelBookcase(meta: .init(sourceSnapshotHash: job.sourceSnapshotHash, extractorVersion: "synthetic"), characters: [person],
      chapters: [.init(chapterID: "river", summary: "准备渡河", evidence: [.init(chapterID: "river", quote: "准备渡河")])])
    let proposal = try await store.proposeBookcase(content, jobID: job.id, expectedRevision: job.revision)
    let revision = try await store.load(job.id).revision
    _ = try await store.decideBookcase(jobID: job.id, proposalID: proposal.id, expectedRevision: revision,
      action: .approve, acknowledgeMissingChapters: true)
    var contract = AdaptationDirectionContract(); contract.protagonistIDs = ["lin"]; contract.minimumCharacterCount = 1
    let variant = try await store.createVariant(jobID: job.id, title: "有书案", contract: contract,
      expectedRevision: store.load(job.id).revision)
    let provider = writingProvider()
    _ = try await AdaptationWriter(provider: provider, store: store).write(jobID: job.id, variantID: variant.id,
      options: .init(targets: [.init(chapterID: "river")]))
    let request = try #require(await provider.recorder.requests.first)
    #expect(request.messages.last?.content.contains("旅行者") == true)
    #expect(request.messages.last?.content.contains("带着地图") == true)
    #expect(request.messages.last?.content.contains("准备渡河") == true)
    #expect(try await store.generationBasis(jobID: job.id, variantID: variant.id).bookcaseID == proposal.id)
  }
}
