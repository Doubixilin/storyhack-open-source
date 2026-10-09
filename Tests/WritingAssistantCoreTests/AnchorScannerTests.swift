import Foundation
import LLMProviderKit
import NovelDocumentCore
import Testing
@testable import WritingAssistantCore
import WritingCore

private func anchorReply(_ request: LLMRequest, names: [String] = []) throws -> String {
  let unit = try input(request)
  return try json(["anchors": [["chapter_id": unit.chapterID, "quote": String(unit.text.prefix(8)),
    "utf16_location": unit.offset, "note": "补充过渡细节", "action": "insertion", "focus_names": names]]])
}

@Suite struct AnchorScannerTests {
  @Test func thirtyChaptersKeepUniqueLocalIDsAcrossSixContinuations() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let chapters = (0..<30).map { index in NovelChapter(id: "c\(index)", ordinal: index, title: "第\(index)章",
      content: "林舟走向河岸，准备乘船。\n老周收起地图，随即跟上。") }
    let store = fixture.store, job = try await store.create(document: fixture.document(chapters: chapters))
    let provider = ExtractionProvider(recorder: ExtractionRecorder { request, _ in .text(try anchorReply(request)) })
    let scanner = AdaptationAnchorScanner(provider: provider, store: store)
    let options = AnchorScanOptions(selection: .init(maximumUnitUTF16Length: 16, maximumNewRequests: 10))
    var report: AnchorScanReport?
    for _ in 0..<6 { report = try await scanner.scan(jobID: job.id, options: options) }
    #expect(report?.stage == .completed)
    let map = try await store.anchorMap(job.id)
    #expect(map.anchors.count == 60 && Set(map.anchors.map(\.id)).count == 60)
    for chapter in chapters {
      #expect(map.anchors.filter { $0.source.chapterID == chapter.id }.map(\.id) == [chapter.id + "-a-00001", chapter.id + "-a-00002"])
    }
    #expect(await provider.recorder.count() == 60)
    #expect(map.reviews.isEmpty)
    let repeated = try await scanner.scan(jobID: job.id,
      options: .init(selection: .init(maximumUnitUTF16Length: 16, maximumNewRequests: 0)))
    #expect(repeated.newRequestCount == 0 && repeated.cacheHitCount == 60 && repeated.addedAnchorCount == 0)
    #expect(try await store.anchorMap(job.id) == map)
  }

  @Test func fallbackOnlyFillsFullyScannedEmptyChaptersAndNeverReappearsAfterRejection() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let provider = ExtractionProvider(recorder: ExtractionRecorder { _, _ in .text("{\"anchors\":[]}") })
    let scanner = AdaptationAnchorScanner(provider: provider, store: store)
    let partial = try await scanner.scan(jobID: job.id, options: .init(selection: .init(maximumNewRequests: 1)))
    #expect(partial.stage == .partial)
    let first = try await store.anchorMap(job.id)
    #expect(first.anchors.map(\.id) == ["river-f-00001"])
    #expect(first.anchors[0].source.range.location == 0 && first.anchors[0].quote.isEmpty)
    let rejected = try await store.reviewAnchor(jobID: job.id, anchorID: first.anchors[0].id,
      expectedRevision: first.revision, action: .reject, generationAction: .insertion)
    _ = try await scanner.scan(jobID: job.id)
    let final = try await store.anchorMap(job.id)
    #expect(final.anchors.count == 3)
    #expect(final.reviews["river-f-00001"] == rejected.reviews["river-f-00001"])
    #expect(final.anchors.allSatisfy { $0.note.contains("不得新增人物") && $0.note.contains("原章开头") })
  }

  @Test func manualQuoteAndChapterStartUseSeparateStableNamespaceAndReopen() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let first = try await store.addManualAnchor(jobID: job.id, expectedRevision: nil,
      candidate: .init(chapterID: "river", quote: "林舟收起地图", note: "作者补点", action: .rewrite))
    #expect(first.anchors[0].id == "river-m-00001")
    let second = try await store.addManualAnchor(jobID: job.id, expectedRevision: first.revision,
      candidate: .init(chapterID: "river", quote: "", note: "章首"))
    #expect(second.anchors[1].id == "river-m-00002" && second.anchors[1].source.range.length == 0)
    await #expect(throws: AdaptationError.staleEdit) {
      try await store.addManualAnchor(jobID: job.id, expectedRevision: first.revision,
        candidate: .init(chapterID: "river", quote: "", note: "旧窗口"))
    }
    #expect(try await fixture.store.anchorMap(job.id) == second)
    await #expect(throws: AdaptationError.evidenceMismatch) {
      try await store.addManualAnchor(jobID: job.id, expectedRevision: second.revision,
        candidate: .init(chapterID: "river", quote: "不存在的引文", note: "错误"))
    }
  }

  @Test func changedNoteRevokesCurrentReviewAndPreservesAuditWithCAS() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let initial = try await store.addManualAnchor(jobID: job.id, expectedRevision: nil,
      candidate: .init(chapterID: "river", quote: "", note: "初稿"))
    let id = initial.anchors[0].id
    let approved = try await store.reviewAnchor(jobID: job.id, anchorID: id, expectedRevision: initial.revision,
      action: .approve, generationAction: .newChapter, intensity: 4, note: "作者确认位置")
    let review = try #require(approved.reviews[id])
    let same = try await store.reviewAnchor(jobID: job.id, anchorID: id, expectedRevision: approved.revision,
      action: .approve, generationAction: .newChapter, intensity: 4, note: "作者确认位置")
    #expect(same == approved)
    let edited = try await store.editAnchorNote(jobID: job.id, anchorID: id, expectedRevision: approved.revision, note: "新说明")
    #expect(edited.reviews[id] == nil && edited.anchors[0].id == id)
    let audit = fixture.directory(job.id).appendingPathComponent("anchor-reviews/\(review.id.uuidString.lowercased()).json")
    #expect(try AdaptationCoding.decoder().decode(AdaptationAnchorReview.self, from: Data(contentsOf: audit)) == review)
    await #expect(throws: AdaptationError.staleEdit) {
      try await store.reviewAnchor(jobID: job.id, anchorID: id, expectedRevision: approved.revision,
        action: .approve, generationAction: .newChapter)
    }
  }

  @Test func invalidResponseDoesNotCausePrematureFallbackAndRetriesOnlyFailedUnit() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let provider = ExtractionProvider(recorder: ExtractionRecorder { request, count in
      .text(count == 2 ? "{}" : try anchorReply(request))
    })
    let scanner = AdaptationAnchorScanner(provider: provider, store: store)
    let first = try await scanner.scan(jobID: job.id)
    #expect(first.stage == .partial && first.gaps.count == 1)
    #expect(try await store.anchorMap(job.id).anchors.allSatisfy { $0.source.chapterID != "mountain" })
    let next = try await scanner.scan(jobID: job.id, options: .init(selection: .init(maximumNewRequests: 1)))
    #expect(next.stage == .completed && next.newRequestCount == 1 && next.cacheHitCount == 2)
    #expect(try await store.anchorMap(job.id).anchors.count == 3)
    #expect(await provider.recorder.count() == 4)
  }

  @Test func focusFilteringRetainsOnlyMatchingLocationsAndDensityChangesCacheIdentity() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let provider = ExtractionProvider(recorder: ExtractionRecorder { request, _ in
      let name = try input(request).chapterID == "river" ? "林舟" : "老周"
      return .text(try anchorReply(request, names: [name]))
    })
    let scanner = AdaptationAnchorScanner(provider: provider, store: store)
    let selected = BookcaseExtractionOptions(focusNames: ["林舟"])
    let report = try await scanner.scan(jobID: job.id, options: .init(selection: selected, addChapterStarts: false))
    #expect(report.selectedChapterIDs == ["river", "mountain"] && report.filteredAnchorCount == 1)
    let map = try await store.anchorMap(job.id)
    #expect(map.anchors.count == 1 && map.anchors[0].focusNames == ["林舟"])
    let other = try await scanner.scan(jobID: job.id, options: .init(selection: selected, density: 4, addChapterStarts: false))
    #expect(other.planFingerprint != report.planFingerprint && other.newRequestCount == 2)
    #expect(try await store.anchorMap(job.id) == map)
  }

  @Test func manualEditDuringScanRejectsStaleMapInstallationButKeepsResponseCache() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let provider = ExtractionProvider(recorder: ExtractionRecorder { request, _ in .text(try anchorReply(request)) })
    let scanner = AdaptationAnchorScanner(provider: provider, store: store)
    await #expect(throws: AdaptationError.staleEdit) {
      try await scanner.scan(jobID: job.id, progress: { report in
        if report.completedUnitIDs.count == 1 {
          _ = try? await store.addManualAnchor(jobID: job.id, expectedRevision: nil,
            candidate: .init(chapterID: "river", quote: "", note: "在扫描中人工补点"))
        }
      })
    }
    #expect(try await store.anchorMap(job.id).anchors.map(\.origin) == [.manual])
    let resumed = try await scanner.scan(jobID: job.id)
    #expect(resumed.cacheHitCount == 3 && resumed.newRequestCount == 0)
    #expect(try await store.anchorMap(job.id).anchors.count == 4)
  }

  @Test func otherPipelineUnknownRequestBlocksScanningAndReadOnlyBudgetDoesNotSend() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let hash = AdaptationCoding.hash(Data("identity".utf8))
    let start = try await store.beginRequest(jobID: job.id, identity: .init(sourceSnapshotHash: job.sourceSnapshotHash,
      purpose: "bookcase", unitID: "old-unit", executorFingerprint: hash, inputFingerprint: hash))
    guard case .send(let pending) = start else { Issue.record("expected checkpoint"); return }
    let provider = ExtractionProvider(), scanner = AdaptationAnchorScanner(provider: provider, store: store)
    await #expect(throws: AdaptationRequestError.uncertain(pending)) { try await scanner.scan(jobID: job.id) }
    #expect(await provider.recorder.count() == 0)
    try await store.acknowledgeUnknownRequest(pending)
    let report = try await scanner.scan(jobID: job.id, options: .init(selection: .init(maximumNewRequests: 0)))
    #expect(report.stage == .partial && report.newRequestCount == 0)
    #expect(try await store.anchorMap(job.id).anchors.isEmpty)
    #expect(await provider.recorder.count() == 0)
  }

  @Test func missingApprovalAuditAndMalformedRangeFailClosed() async throws {
    let fixture = ExtractionFixture(); defer { fixture.clean() }
    let store = fixture.store, job = try await store.create(document: fixture.document())
    let initial = try await store.addManualAnchor(jobID: job.id, expectedRevision: nil,
      candidate: .init(chapterID: "river", quote: "林舟", note: "人工"))
    let approved = try await store.reviewAnchor(jobID: job.id, anchorID: initial.anchors[0].id,
      expectedRevision: initial.revision, action: .approve, generationAction: .insertion)
    let review = try #require(approved.reviews.values.first)
    try FileManager.default.removeItem(at: fixture.directory(job.id).appendingPathComponent("anchor-reviews/\(review.id.uuidString.lowercased()).json"))
    await #expect(throws: (any Error).self) { try await store.anchorMap(job.id) }
    let url = fixture.directory(job.id).appendingPathComponent("anchor-map.json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var anchors = try #require(object["anchors"] as? [[String: Any]])
    var source = try #require(anchors[0]["source"] as? [String: Any])
    source["range"] = ["location": Int.max, "length": Int.max]; anchors[0]["source"] = source
    object["anchors"] = anchors; object["reviews"] = [String: Any]()
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    await #expect(throws: AdaptationError.invalidAnchor) { try await store.anchorMap(job.id) }
  }
}
