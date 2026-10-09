import Foundation
import LibraryCore
import LLMProviderKit
import NovelDocumentCore
import StoryworldCore
import Testing
import WritingCore
@testable import WorldbookUI

private actor AdaptationUIRecorder {
  var requests: [LLMRequest] = []
  var paused = false
  func setPaused(_ value: Bool) { paused = value }
  func send(_ request: LLMRequest, continuation: AsyncThrowingStream<LLMStreamEvent, any Error>.Continuation) {
    requests.append(request)
    guard !paused else { return }
    do {
      let prompt = request.messages.last?.content ?? ""
      let jsonLine = prompt.components(separatedBy: "\n")[1]
      let input = try JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as! [String: Any]
      let result: String
      if prompt.hasPrefix("元数据：") {
        let id = input["chapter_id"] as! String
        let begin = prompt.range(of: "<source>\n")!, end = prompt.range(of: "\n</source>", options: .backwards)!
        let quote = String(prompt[begin.upperBound..<end.lowerBound].prefix(5))
        let evidence: [String: Any] = ["chapter_id": id, "quote": quote, "utf16_location": Int(input["utf16_start"] as? String ?? "0") ?? 0]
        let value: [String: Any] = ["characters": [["id": "p", "name": "林舟", "identity_core": "模型提取", "evidence": [evidence]]],
          "chapters": [["chapter_id": id, "summary": "人物开始行动。", "evidence": [evidence]]]]
        result = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
      } else {
        let context = input["context"] as! [String: Any], target = context["target"] as! [String: Any], id = target["chapter_id"] as! String
        let content = AdaptationDraftContent(title: "新章" + id, body: "林舟按计划前行，留下这一章的记录。", recap: "前情" + id,
          reviewLine: "保留计划，待作者核对。", recipe: .init(trigger: id, setting: "旅途", technique: "白描"))
        result = String(decoding: try AdaptationCoding.encoder().encode(content), as: UTF8.self)
      }
      continuation.yield(.textDelta(result)); continuation.yield(.completed); continuation.finish()
    } catch { continuation.finish(throwing: error) }
  }
}
private struct AdaptationUIProvider: LLMProvider {
  let recorder: AdaptationUIRecorder
  let profile = ProviderProfile(displayName: "合成模型", kind: .openAICompatible,
    baseURL: URL(string: "https://example.invalid/v1"), modelID: "ui-synthetic", credentialReference: "synthetic-no-key", capabilities: .init(contextWindow: 32_768), maximumOutputTokens: 4_096)
  func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task { await recorder.send(request, continuation: continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
@MainActor private struct AdaptationUIFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("adaptation-ui-" + UUID().uuidString)
  let recorder = AdaptationUIRecorder()
  var store: AdaptationJobStore { .init(rootURL: root.appendingPathComponent("jobs")) }
  var library: NovelLibrary { .init(rootURL: root.appendingPathComponent("library")) }
  func model() -> AdaptationViewModel {
    AdaptationViewModel(store: store, library: library,
      providerStore: .init(rootURL: root.appendingPathComponent("providers"), credentialStore: UISettingsCredentialStore()),
      tasteStore: .init(rootURL: root.appendingPathComponent("taste")), providerFactory: { [recorder] _ in AdaptationUIProvider(recorder: recorder) })
  }
  func setup(_ model: AdaptationViewModel) async throws -> AdaptationJob {
    #expect(await model.createOriginal(title: "合成旅程", author: "测试", plan: "启程｜林舟从河岸出发。\n入山｜林舟遇到向导。"))
    let job = try #require(model.job), direction = try #require(model.direction)
    var contract = direction.contract; contract.minimumCharacterCount = 1; contract.targetCharacterCount = 100
    #expect(await model.saveDirection(title: "", contract: contract, expected: direction, bindApprovedBookcase: false))
    var config = model.configuration; config.providerID = UUID()
    #expect(await model.saveConfiguration(config, jobID: job.id, expected: config.revision))
    return try #require(model.job)
  }
  func idle(_ model: AdaptationViewModel) async throws {
    for _ in 0..<400 {
      if !model.busy { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("合成 UI 操作未在测试时限内完成"); model.cancel()
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor struct AdaptationUITests {
  @Test func maximumLengthSurvivesReopenAndCannotBeApprovedWithoutAcknowledgement() async throws {
    let f = AdaptationUIFixture(); defer { f.clean() }
    let model = f.model(), job = try await f.setup(model)
    let direction = try #require(model.direction)
    var contract = direction.contract
    contract.targetCharacterCount = 10; contract.maximumCharacterCount = 12
    #expect(await model.saveDirection(title: "", contract: contract, expected: direction, bindApprovedBookcase: false))
    let reopened = f.model(); await reopened.selectJob(job.id)
    #expect(reopened.direction?.contract.maximumCharacterCount == 12)
    reopened.start(.write); try await f.idle(reopened)
    let draft = try #require(reopened.drafts?.current.first?.draft)
    #expect(draft.warnings.contains { $0.contains("超过合同上限 12 字") })
    #expect(await reopened.decideDraft(draft, revision: reopened.drafts?.revision,
      action: .approve, note: "未确认告警", acknowledge: false) == false)
    #expect(reopened.drafts?.current.first?.decision == nil)
    #expect(await reopened.decideDraft(draft, revision: reopened.drafts?.revision,
      action: .approve, note: "作者已核对超限正文", acknowledge: true))
    #expect(try await f.store.drafts(jobID: job.id, variantID: direction.variantID).current.first?.decision?.acknowledgedWarnings == true)
  }

  @Test func originalPlanToResumedDraftApprovalExportAndReaderPublication() async throws {
    let f = AdaptationUIFixture(); defer { f.clean() }
    let model = f.model(), job = try await f.setup(model)
    var config = model.configuration; config.maximumNewRequests = 1
    #expect(await model.saveConfiguration(config, jobID: job.id, expected: config.revision))
    model.start(.write); try await f.idle(model)
    #expect(model.drafts?.current.count == 1 && model.errorMessage == nil)
    let reopened = f.model(); await reopened.selectJob(job.id)
    #expect(reopened.configuration.maximumNewRequests == 1)
    reopened.start(.write); try await f.idle(reopened)
    #expect(reopened.drafts?.current.count == 2 && reopened.errorMessage == nil)
    let requests = await f.recorder.requests
    #expect(requests.count == 2 && requests[0].messages.last?.content.contains("chapterPlan") == true)
    #expect(requests[0].messages.last?.content.contains("林舟从河岸出发") == true)
    #expect(requests[1].messages.last?.content.contains("前情chapter-000001") == true)
    for draft in reopened.drafts?.current.map(\.draft) ?? [] {
      #expect(await reopened.decideDraft(draft, revision: reopened.drafts?.revision, action: .approve, note: "作者核对", acknowledge: false))
    }
    await reopened.prepareAssembly()
    #expect(reopened.assembly?.unchangedChapterIDs.isEmpty == true)
    #expect(await reopened.export(acknowledge: false, publish: false))
    let epub = try #require(reopened.exported?.epubURL)
    #expect(try EPUBNovelParser().parse(at: epub).chapters.count == 2)
    #expect(await reopened.export(acknowledge: false, publish: true))
    #expect(try await f.library.list().first?.id == reopened.selectedVariantID)
  }

  @Test func configurationCASRejectsOtherEditorAndReopenRetainsFields() async throws {
    let f = AdaptationUIFixture(); defer { f.clean() }
    let first = f.model(), job = try await f.setup(first), second = f.model()
    await second.selectJob(job.id)
    let old = second.configuration
    var changed = first.configuration; changed.density = 5; changed.focusNames = ["林舟"]; changed.chapterIDs = ["chapter-000001"]
    changed.taskTaste = .init(pace: .unhurried, notes: "明确偏好")
    #expect(await first.saveConfiguration(changed, jobID: job.id, expected: changed.revision))
    #expect(await second.saveConfiguration(old, jobID: job.id, expected: old.revision) == false)
    #expect(second.errorMessage != nil)
    let reopened = f.model(); await reopened.selectJob(job.id)
    #expect(reopened.configuration.density == 5 && reopened.configuration.focusNames == ["林舟"])
    #expect(reopened.configuration.taskTaste.notes == "明确偏好")
  }

  @Test func changingDirectionDoesNotDisplayAnotherDirectionsRunSummary() async throws {
    let f = AdaptationUIFixture(); defer { f.clean() }
    let model = f.model(); _ = try await f.setup(model)
    let originalID = try #require(model.selectedVariantID)
    let contract = try #require(model.direction?.contract)
    model.start(.write); try await f.idle(model)
    #expect(model.drafts?.current.count == 2)
    #expect(model.progressText.contains("正文 2/2"))
    #expect(await model.saveDirection(title: "第二方向", contract: contract, expected: nil, bindApprovedBookcase: false))
    #expect(model.drafts?.current.isEmpty == true)
    #expect(model.progressText.isEmpty)
    var config = model.configuration; config.maximumNewRequests = 1
    #expect(await model.saveConfiguration(config, jobID: try #require(model.job?.id), expected: config.revision))
    model.start(.write); try await f.idle(model)
    #expect(model.drafts?.current.count == 1)
    #expect(model.progressText.contains("正文 1/2"))
    await model.selectVariant(originalID)
    #expect(model.drafts?.current.count == 2)
    #expect(model.progressText.isEmpty)
    #expect(await f.recorder.requests.count == 3)
  }

  @Test func cancellationLocksSelectionAndUnknownRequestCannotBeBypassed() async throws {
    let f = AdaptationUIFixture(); defer { f.clean() }
    let model = f.model(), job = try await f.setup(model)
    let other = try await f.store.createOriginal(title: "另一任务", chapters: [.init(id: "c", ordinal: 0, title: "章", content: "计划")])
    await f.recorder.setPaused(true)
    model.start(.write)
    for _ in 0..<100 {
      if await f.recorder.requests.count == 1 { break }; try await Task.sleep(for: .milliseconds(10))
    }
    await model.selectJob(other.id)
    #expect(model.job?.id == job.id && model.busy)
    model.cancel(); try await f.idle(model)
    let pending = try #require(model.pending)
    #expect(model.errorMessage?.contains("已取消") == true)
    await f.recorder.setPaused(false)
    model.start(.write, newRound: true); try await f.idle(model)
    #expect(await f.recorder.requests.count == 1)
    #expect(model.pending?.id == pending.id)
    await model.acknowledgeRequest(pending)
    #expect(model.pending == nil)
    model.start(.write); try await f.idle(model)
    #expect(model.drafts?.current.count == 2)
    #expect(await f.recorder.requests.count == 3)
  }

  @Test func manualCardSurvivesReExtractionAsPendingVersion() async throws {
    let f = AdaptationUIFixture(); defer { f.clean() }
    let model = f.model(); _ = try await f.setup(model)
    model.start(.bookcase); try await f.idle(model)
    let extracted = try #require(model.selectedBookcase)
    var card = try #require(extracted.content.characters.first); card.identityCore = "作者明确的身份"
    #expect(await model.saveCharacter(card, parent: extracted))
    let revised = try #require(model.selectedBookcase)
    await model.decideBookcase(revised, action: .approve, acknowledgeGaps: true)
    model.start(.bookcase); try await f.idle(model)
    let repeated = try #require(model.selectedBookcase)
    #expect(repeated.content.characters.first(where: { $0.id == card.id })?.identityCore == "作者明确的身份")
    #expect(repeated.content.characters.first(where: { $0.id == card.id })?.origin == .author)
    // An identical previously approved author revision may be reused; otherwise
    // the merged version remains pending. Extraction never adds a new approval.
    #expect(repeated.status == .pending || repeated.id == revised.id)
    #expect(await f.recorder.requests.count == 2)
  }

  @Test func staleAnchorEditorDoesNotApproveNewerMap() async throws {
    let f = AdaptationUIFixture(); defer { f.clean() }
    let model = f.model(), job = try await f.setup(model)
    #expect(await model.addAnchor(chapterID: "chapter-000001", quote: "林舟从河岸出发", offset: nil, note: "旧说明"))
    let anchor = try #require(model.anchors?.anchors.first), revision = model.anchors?.revision
    _ = try await f.store.editAnchorNote(jobID: job.id, anchorID: anchor.id, expectedRevision: revision, note: "另一窗口的新说明")
    #expect(await model.reviewAnchor(anchor, expectedRevision: revision, note: "旧说明", action: .approve, generationAction: .insertion, intensity: 3) == false)
    let map = try await f.store.anchorMap(job.id)
    #expect(map.anchors[0].note == "另一窗口的新说明" && map.reviews[anchor.id] == nil)
  }

  @Test func manualDraftEditsRemainPendingAndOldDecisionCannotApproveThem() async throws {
    let f = AdaptationUIFixture(); defer { f.clean() }
    let model = f.model(); _ = try await f.setup(model)
    model.start(.write); try await f.idle(model)
    let draft = try #require(model.drafts?.current.first?.draft), revision = model.drafts?.revision
    var edit = draft.content; edit.body = "人工改写正文。"; edit.recap = "前情改变。"
    #expect(await model.saveDraft(draft, content: edit))
    #expect(model.drafts?.current[0].decision == nil && model.drafts?.current[1].isStale == true)
    #expect(await model.decideDraft(draft, revision: revision, action: .approve, note: "过期窗口", acknowledge: false) == false)
    let current = try #require(model.drafts?.current.first?.draft)
    #expect(await model.previousDraft(current) == draft)
  }
}
